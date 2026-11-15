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
   respiratoryRate  breaths/min, overnight average
   wristTempC       degrees C, Apple's sleeping wrist temperature (absolute, iOS 16+)
   steps            count for the day
   activeCalories   kcal for the day
   sleepHours       time asleep in the night ending that morning, from ONE source (see readSleep)
   deepMin, remMin, coreMin, awakeMin   sleep stages, minutes, where that source writes them
   bedStart, wakeAt ISO timestamps of the first and last asleep moments
   sleepSource      the app that wrote that night, e.g. "Oura"
   runs             [{ start, distanceKm, durationMin, source }] running workouts that day, with
                    the same run recorded by two apps kept once
*/
@objc(HealthBridgePlugin)
public class HealthBridgePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "HealthBridgePlugin"
    public let jsName = "HealthBridge"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isAvailable", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestAuthorization", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "readDays", returnType: CAPPluginReturnPromise)
    ]

    private let store = HKHealthStore()
    private let lock = NSLock()

    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        let ids: [HKQuantityTypeIdentifier] = [
            .heartRate, .restingHeartRate, .respiratoryRate, .stepCount, .activeEnergyBurned
        ]
        for id in ids {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        if #available(iOS 16.0, *) {
            if let t = HKObjectType.quantityType(forIdentifier: .appleSleepingWristTemperature) { types.insert(t) }
        }
        if let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(t) }
        types.insert(HKObjectType.workoutType())
        return types
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
            readSleep(nightStart, nightEnd, group, { fields in
                for (field, value) in fields {
                    if field == "bedStart" || field == "wakeAt", let d = value as? Date {
                        set(key, field, iso.string(from: d))
                    } else {
                        set(key, field, value)
                    }
                }
            }, { bed, wake in
                self.lowestHeartRate(bed, wake, group) { value in set(key, "sleepingHR", value) }
            })
            readRuns(dayStart, dayEnd, group) { list in
                if !list.isEmpty {
                    set(key, "runs", list.map { run -> [String: Any] in
                        var out: [String: Any] = ["start": iso.string(from: run.start), "durationMin": run.durationMin, "source": run.source]
                        if let km = run.distanceKm { out["distanceKm"] = km }
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

    /* THE LOWEST HALF HOUR ASLEEP. Every app writes heart rate, few write a resting figure, so
       this is worked out the way the rings work theirs: the lowest mean over any 30 minutes
       between falling asleep and waking. A window needs five readings, so a watch that samples
       every few minutes still counts and one stray low reading does not. All sources together:
       a beat per minute is the same beat whichever device heard it. */
    private func lowestHeartRate(_ start: Date, _ end: Date, _ group: DispatchGroup,
                                 _ done: @escaping (Double?) -> Void) {
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
                    if lowest == nil || mean < lowest! { lowest = mean }
                }
                total -= points[i].1
            }
            done(lowest.map { v in (v * 10).rounded() / 10 })
            group.leave()
        }
        store.execute(query)
    }

    private struct Run { let start: Date; let end: Date; let durationMin: Double; let distanceKm: Double?; let source: String }

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
                all.append(Run(start: w.startDate, end: w.endDate, durationMin: (w.duration / 60 * 10).rounded() / 10,
                               distanceKm: roundedKm, source: w.sourceRevision.source.name))
            }
            let better = { (a: Run, b: Run) -> Bool in
                if (a.distanceKm != nil) != (b.distanceKm != nil) { return a.distanceKm != nil }
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
