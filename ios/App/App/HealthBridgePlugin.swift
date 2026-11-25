import Foundation
import Capacitor
import HealthKit

/*
 THE HEALTHKIT BRIDGE.

 One job: read what Apple Health already holds for the last few days and hand it to the web
 app as one record per local calendar day, in plain numbers. Everything the app does with the
 numbers (baselines, the score) stays in index.html, where it already lives; this file only
 fetches. It is written for whatever writes to Health: an Oura ring, a Garmin watch, an Apple
 Watch, or several at once. HRV is not read: neither Oura nor Garmin shares it with Health.

 Read-only. The app never writes to Health, so it asks for no write permission at all.

 Called from JS as:
   const HB = Capacitor.registerPlugin('HealthBridge');
   await HB.isAvailable()            -> { available: Bool }
   await HB.requestAuthorization()   -> { requested: Bool }
   await HB.readDays({ days: 14 })   -> { days: [ { date: 'YYYY-MM-DD', ... } ] }

 Per day (each field only present when Health had something for it):
   restingHR        bpm, the daily resting heart rate, where something writes one (Apple Watch)
   sleepingHR       bpm, the lowest 30 minutes of heart rate while asleep. Oura and Garmin write
                    plain heart rate, not a resting figure, so this is the one they both give.
   hrNadirFrac      where in the night that low came: 0 falling asleep, 1 waking
   respiratoryRate  breaths/min, overnight average
   wristTempC       degrees C, Apple's sleeping wrist temperature (absolute, iOS 16+)
   weightKg         the day's first weigh-in, kg (a smart scale such as Withings writes it)
   bodyFatPct       the day's first body-fat reading, percent
   steps            count for the day
   activeCalories   kcal for the day
   sleepHours       time asleep in the night ending that morning, from ONE source (see readSleep)
   deepMin, remMin, coreMin, awakeMin   sleep stages, minutes, where that source writes them
   bedStart, wakeAt ISO timestamps of the first and last asleep moments
   sleepSource      the app that wrote that night, e.g. "Oura"
   mindfulMin       minutes of mindful sessions that day (Calm, Headspace, Apple Watch Mindfulness and others), overlapping ones counted once
   runs             [{ start, distanceKm, durationMin, avgHR, source }] running workouts that day, with
                    the same run recorded by two apps kept once
*/
@objc(HealthBridgePlugin)
public class HealthBridgePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "HealthBridgePlugin"
    public let jsName = "HealthBridge"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isAvailable", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestAuthorization", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "readDays", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "readVO2", returnType: CAPPluginReturnPromise)
    ]

    private let store = HKHealthStore()
    private let lock = NSLock()

    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        let ids: [HKQuantityTypeIdentifier] = [
            .heartRate, .restingHeartRate, .respiratoryRate, .stepCount, .activeEnergyBurned,
            .bodyMass, .bodyFatPercentage, .vo2Max,
            .dietaryEnergyConsumed, .dietaryProtein, .dietaryWater
        ]
        for id in ids {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        if #available(iOS 16.0, *) {
            if let t = HKObjectType.quantityType(forIdentifier: .appleSleepingWristTemperature) { types.insert(t) }
        }
        if let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(t) }
        if let t = HKObjectType.categoryType(forIdentifier: .mindfulSession) { types.insert(t) }
        types.insert(HKObjectType.workoutType())
        return types
    }

    /* VO2 MAX, as Apple Watch estimates it from outdoor walks and runs (other watches can write
       it too). Every sample in the last `days` (default 365), oldest first:
         { samples: [ { date: 'YYYY-MM-DD', value: ml/kg/min, source } ] } */
    @objc func readVO2(_ call: CAPPluginCall) {
        guard HKHealthStore.isHealthDataAvailable(),
              let type = HKQuantityType.quantityType(forIdentifier: .vo2Max) else { call.resolve(["samples": []]); return }
        let days = call.getInt("days") ?? 365
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let unit = HKUnit(from: "ml/kg*min")
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
            let out: [[String: Any]] = (samples as? [HKQuantitySample] ?? []).map { s in
                ["date": fmt.string(from: s.startDate), "value": s.quantity.doubleValue(for: unit), "source": s.sourceRevision.source.name]
            }
            call.resolve(["samples": out])
        }
        store.execute(query)
    }

    @objc func isAvailable(_ call: CAPPluginCall) {
        call.resolve(["available": HKHealthStore.isHealthDataAvailable()])
    }

    // HealthKit never says whether read access was granted (that is deliberate, for privacy):
    // `requested` only means the sheet was shown. A refused type simply reads back empty.
    @objc func requestAuthorization(_ call: CAPPluginCall) {
        guard HKHealthStore.isHealthDataAvailable() else {
            call.reject("Health data is not available on this device")
            return
        }
        store.requestAuthorization(toShare: nil, read: readTypes) { success, error in
            if let error = error {
                call.reject(error.localizedDescription)
                return
            }
            call.resolve(["requested": success])
        }
    }

    @objc func readDays(_ call: CAPPluginCall) {
        guard HKHealthStore.isHealthDataAvailable() else {
            call.reject("Health data is not available on this device")
            return
        }
        let days = max(1, min(60, call.getInt("days") ?? 14))
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let group = DispatchGroup()
        var results: [String: [String: Any]] = [:]

        let keyFormatter = DateFormatter()
        keyFormatter.calendar = cal
        keyFormatter.locale = Locale(identifier: "en_US_POSIX")
        keyFormatter.timeZone = TimeZone.current
        keyFormatter.dateFormat = "yyyy-MM-dd"
        let iso = ISO8601DateFormatter()

        func set(_ key: String, _ field: String, _ value: Any?) {
            guard let value = value else { return }
            if let d = value as? Double, !d.isFinite { return }
            self.lock.lock()
            var day = results[key] ?? ["date": key]
            day[field] = value
            results[key] = day
            self.lock.unlock()
        }

        for offset in 0..<days {
            guard let dayStart = cal.date(byAdding: .day, value: -offset, to: todayStart),
                  let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart),
                  // The night that ends on this morning: 6pm the evening before until 2pm.
                  let nightStart = cal.date(byAdding: .hour, value: -6, to: dayStart),
                  let nightEnd = cal.date(byAdding: .hour, value: 14, to: dayStart) else { continue }
            let key = keyFormatter.string(from: dayStart)
            set(key, "date", key)

            let perMinute = HKUnit.count().unitDivided(by: HKUnit.minute())
            average(.restingHeartRate, perMinute, dayStart, dayEnd, group) { value in set(key, "restingHR", value) }
            average(.respiratoryRate, perMinute, nightStart, nightEnd, group) { value in set(key, "respiratoryRate", value) }
            if #available(iOS 16.0, *) {
                average(.appleSleepingWristTemperature, HKUnit.degreeCelsius(), nightStart, nightEnd, group) { value in set(key, "wristTempC", value) }
            }
            sum(.stepCount, HKUnit.count(), dayStart, dayEnd, group) { total in
                if let total = total { set(key, "steps", Int(total.rounded())) }
            }
            sum(.activeEnergyBurned, HKUnit.kilocalorie(), dayStart, dayEnd, group) { total in
                if let total = total { set(key, "activeCalories", Int(total.rounded())) }
            }
            // What was eaten and drunk that day, as MyFitnessPal and other food apps write it to Health.
            sum(.dietaryEnergyConsumed, HKUnit.kilocalorie(), dayStart, dayEnd, group) { total in
                if let total = total, total > 0 { set(key, "dietaryKcal", Int(total.rounded())) }
            }
            sum(.dietaryProtein, HKUnit.gram(), dayStart, dayEnd, group) { total in
                if let total = total, total > 0 { set(key, "dietaryProteinG", Int(total.rounded())) }
            }
            sum(.dietaryWater, HKUnit.literUnit(with: .milli), dayStart, dayEnd, group) { total in
                if let total = total, total > 0 { set(key, "dietaryWaterMl", Int(total.rounded())) }
            }
            // Mindful minutes: sessions meditation apps write to Health, overlapping ones counted once.
            readMindful(dayStart, dayEnd, group) { mins in
                if let mins = mins, mins > 0 { set(key, "mindfulMin", mins) }
            }
            // The day's FIRST weigh-in: the morning one, before food and water move it.
            firstSample(.bodyMass, HKUnit.gramUnit(with: .kilo), dayStart, dayEnd, group) { v in
                if let v = v { set(key, "weightKg", (v * 10).rounded() / 10) }
            }
            firstSample(.bodyFatPercentage, HKUnit.percent(), dayStart, dayEnd, group) { v in
                if let v = v { set(key, "bodyFatPct", (v * 1000).rounded() / 10) }
            }
            readSleep(nightStart, nightEnd, group, { fields in
                for (field, value) in fields {
                    if field == "bedStart" || field == "wakeAt", let d = value as? Date {
                        set(key, field, iso.string(from: d))
                    } else {
                        set(key, field, value)
                    }
                }
            }, { bed, wake in
                self.lowestHeartRate(bed, wake, group) { value, frac in
                    set(key, "sleepingHR", value)
                    set(key, "hrNadirFrac", frac)
                }
            })
            readRuns(dayStart, dayEnd, group) { list in
                if !list.isEmpty {
                    set(key, "runs", list.map { run -> [String: Any] in
                        var out: [String: Any] = ["start": iso.string(from: run.start), "durationMin": run.durationMin, "source": run.source]
                        if let km = run.distanceKm { out["distanceKm"] = km }
                        if let hr = run.avgHR { out["avgHR"] = hr }
                        return out
                    })
                }
            }
        }

        group.notify(queue: .main) {
            let ordered = results.keys.sorted().compactMap { results[$0] }
            call.resolve(["days": ordered])
        }
    }

    // MARK: - Queries

    private func average(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ start: Date, _ end: Date,
                         _ group: DispatchGroup, _ done: @escaping (Double?) -> Void) {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return }
        group.enter()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                      options: .discreteAverage) { _, stats, _ in
            done(stats?.averageQuantity()?.doubleValue(for: unit))
            group.leave()
        }
        store.execute(query)
    }

    /* The earliest sample of a type in the span, for things measured once a day on a scale
       (a Withings writes weight and body fat to Health). The first, not the mean: a second
       weigh-in after breakfast is a different body from the morning one. */
    private func firstSample(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ start: Date, _ end: Date,
                             _ group: DispatchGroup, _ done: @escaping (Double?) -> Void) {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return }
        group.enter()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
            let q = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
            done(q)
            group.leave()
        }
        store.execute(query)
    }

    private func sum(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ start: Date, _ end: Date,
                     _ group: DispatchGroup, _ done: @escaping (Double?) -> Void) {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return }
        group.enter()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        // cumulativeSum merges overlapping sources (iPhone + Watch steps) the way the Health app does.
        let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                      options: .cumulativeSum) { _, stats, _ in
            done(stats?.sumQuantity()?.doubleValue(for: unit))
            group.leave()
        }
        store.execute(query)
    }

    /* ONE SOURCE PER NIGHT. A ring and a watch worn to bed both write the night, a few minutes
       apart at each end, and merging them makes the night longer than either device saw. So the
       samples are grouped by the app that wrote them and one source is kept: the one that
       wrote sleep stages (a ring's staging is the better instrument), then the one with more
       time asleep. Within that source each stage is still the UNION of its intervals, because
       one app can write the same span twice. Raw values, not the enum cases, so this compiles
       the same against the pre-iOS 16 names:
       0 inBed, 1 asleep (unspecified), 2 awake, 3 core, 4 deep, 5 REM.
       `window` hands the asleep span on, for the overnight heart-rate read. */
    private func readSleep(_ start: Date, _ end: Date, _ group: DispatchGroup,
                           _ done: @escaping ([String: Any]) -> Void,
                           _ window: @escaping (Date, Date) -> Void) {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return }
        group.enter()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [sort]) { _, samples, _ in
            var bySource: [String: [HKCategorySample]] = [:]
            var names: [String: String] = [:]
            for case let s as HKCategorySample in samples ?? [] {
                let id = s.sourceRevision.source.bundleIdentifier
                bySource[id, default: []].append(s)
                names[id] = s.sourceRevision.source.name
            }
            var best: (id: String, staged: Bool, secs: Double, parts: [Int: [(Date, Date)]])? = nil
            for (id, list) in bySource {
                var parts: [Int: [(Date, Date)]] = [:]
                for s in list {
                    let span = (max(s.startDate, start), min(s.endDate, end))
                    if span.0 >= span.1 { continue }
                    parts[s.value, default: []].append(span)
                }
                let asleep = [1, 3, 4, 5].flatMap { v in parts[v] ?? [] }
                let secs = HealthBridgePlugin.unionSeconds(asleep)
                if secs <= 0 { continue }
                let staged = !(parts[3] ?? []).isEmpty || !(parts[4] ?? []).isEmpty || !(parts[5] ?? []).isEmpty
                if let b = best {
                    if (staged && !b.staged) || (staged == b.staged && secs > b.secs) { best = (id, staged, secs, parts) }
                } else {
                    best = (id, staged, secs, parts)
                }
            }
            var out: [String: Any] = [:]
            if let b = best {
                let asleep = [1, 3, 4, 5].flatMap { v in b.parts[v] ?? [] }
                out["sleepHours"] = (b.secs / 3600 * 100).rounded() / 100
                out["sleepSource"] = names[b.id] ?? b.id
                let first = asleep.map({ span in span.0 }).min()
                let last = asleep.map({ span in span.1 }).max()
                if let first = first { out["bedStart"] = first }
                if let last = last { out["wakeAt"] = last }
                let mins = { (v: Int) -> Int? in
                    guard let spans = b.parts[v], !spans.isEmpty else { return nil }
                    return Int((HealthBridgePlugin.unionSeconds(spans) / 60).rounded())
                }
                if let m = mins(4) { out["deepMin"] = m }
                if let m = mins(5) { out["remMin"] = m }
                if let m = mins(3) { out["coreMin"] = m }
                if let m = mins(2) { out["awakeMin"] = m }
                if let first = first, let last = last { window(first, last) }
            }
            done(out)
            group.leave()
        }
        store.execute(query)
    }

    /* MINDFUL MINUTES for one day: every mindful session that touches it, clipped to the day, overlapping
       sessions counted once. Nil when there were none. */
    private func readMindful(_ start: Date, _ end: Date, _ group: DispatchGroup, _ done: @escaping (Int?) -> Void) {
        guard let type = HKObjectType.categoryType(forIdentifier: .mindfulSession) else { return }
        group.enter()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, samples, _ in
            var spans: [(Date, Date)] = []
            for case let s as HKCategorySample in samples ?? [] {
                let span = (max(s.startDate, start), min(s.endDate, end))
                if span.0 < span.1 { spans.append(span) }
            }
            let secs = HealthBridgePlugin.unionSeconds(spans)
            done(secs > 0 ? Int((secs / 60).rounded()) : nil)
            group.leave()
        }
        store.execute(query)
    }

    /* THE LOWEST HALF HOUR ASLEEP. Every app writes heart rate, few write a resting figure, so
       this is worked out the way the rings work theirs: the lowest mean over any 30 minutes
       between falling asleep and waking. A window needs five readings, so a watch that samples
       every few minutes still counts and one stray low reading does not. All sources together:
       a beat per minute is the same beat whichever device heard it. */
    private func lowestHeartRate(_ start: Date, _ end: Date, _ group: DispatchGroup,
                                 _ done: @escaping (Double?, Double?) -> Void) {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        group.enter()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let unit = HKUnit.count().unitDivided(by: HKUnit.minute())
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [sort]) { _, samples, _ in
            let points: [(Date, Double)] = (samples ?? []).compactMap { s in
                guard let q = s as? HKQuantitySample else { return nil }
                return (q.startDate, q.quantity.doubleValue(for: unit))
            }
            // Two pointers: [i, j) is every reading within 30 minutes of reading i.
            var lowest: Double? = nil
            var lowestAt: Date? = nil
            var j = 0
            var total: Double = 0
            for i in 0..<points.count {
                if j < i { j = i; total = 0 }
                while j < points.count && points[j].0.timeIntervalSince(points[i].0) < 1800 {
                    total += points[j].1
                    j += 1
                }
                let n = j - i
                if n >= 5 {
                    let mean = total / Double(n)
                    if lowest == nil || mean < lowest! {
                        lowest = mean
                        // The middle of the lowest half hour, for WHEN the night bottomed out.
                        lowestAt = points[i].0.addingTimeInterval(points[j - 1].0.timeIntervalSince(points[i].0) / 2)
                    }
                }
                total -= points[i].1
            }
            /* Where in the night the low came, 0 at falling asleep and 1 at waking. A low that
               arrives late, near waking, is the body still working through something: a drink,
               a late meal, a hard day, a bug. */
            let span = end.timeIntervalSince(start)
            let frac = lowestAt.flatMap { t in span > 0 ? ((t.timeIntervalSince(start) / span) * 100).rounded() / 100 : nil }
            done(lowest.map { v in (v * 10).rounded() / 10 }, frac)
            group.leave()
        }
        store.execute(query)
    }

    private struct Run { let start: Date; let end: Date; let durationMin: Double; let distanceKm: Double?; let source: String; let avgHR: Double? }

    /* A run recorded by the watch and noticed by the ring arrives twice. Two runs that share
       more than half of the shorter one are the same run, and the one kept is the one with a
       distance, then the longer one: the watch's, which has the GPS. */
    private func readRuns(_ start: Date, _ end: Date, _ group: DispatchGroup, _ done: @escaping ([Run]) -> Void) {
        group.enter()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
            var all: [Run] = []
            for case let w as HKWorkout in samples ?? [] where w.workoutActivityType == .running {
                var km: Double? = nil
                if #available(iOS 16.0, *) {
                    if let t = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning),
                       let q = w.statistics(for: t)?.sumQuantity() {
                        km = q.doubleValue(for: HKUnit.meterUnit(with: .kilo))
                    }
                } else {
                    km = w.totalDistance?.doubleValue(for: HKUnit.meterUnit(with: .kilo))
                }
                let roundedKm = km.flatMap { v in v > 0 ? (v * 100).rounded() / 100 : nil }
                // The run's average heart rate, which Garmin writes with the workout: speed per
                // heartbeat is the app's measure of how fit you ran.
                var hr: Double? = nil
                if #available(iOS 16.0, *) {
                    if let t = HKQuantityType.quantityType(forIdentifier: .heartRate),
                       let q = w.statistics(for: t)?.averageQuantity() {
                        hr = (q.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute())) * 10).rounded() / 10
                    }
                }
                all.append(Run(start: w.startDate, end: w.endDate, durationMin: (w.duration / 60 * 10).rounded() / 10,
                               distanceKm: roundedKm, source: w.sourceRevision.source.name, avgHR: hr))
            }
            let better = { (a: Run, b: Run) -> Bool in
                if (a.distanceKm != nil) != (b.distanceKm != nil) { return a.distanceKm != nil }
                if (a.avgHR != nil) != (b.avgHR != nil) { return a.avgHR != nil }
                return a.durationMin > b.durationMin
            }
            var kept: [Run] = []
            for run in all {
                if let i = kept.firstIndex(where: { k in
                    let overlap = min(k.end, run.end).timeIntervalSince(max(k.start, run.start))
                    let shorter = min(k.end.timeIntervalSince(k.start), run.end.timeIntervalSince(run.start))
                    return shorter > 0 && overlap > shorter / 2
                }) {
                    if better(run, kept[i]) { kept[i] = run }
                } else {
                    kept.append(run)
                }
            }
            done(kept)
            group.leave()
        }
        store.execute(query)
    }

    private static func unionSeconds(_ spans: [(Date, Date)]) -> Double {
        let sorted = spans.sorted { a, b in a.0 < b.0 }
        var total: Double = 0
        var current: (Date, Date)? = nil
        for span in sorted {
            if let c = current, span.0 <= c.1 {
                current = (c.0, max(c.1, span.1))
            } else {
                if let c = current { total += c.1.timeIntervalSince(c.0) }
                current = span
            }
        }
        if let c = current { total += c.1.timeIntervalSince(c.0) }
        return total
    }
}
