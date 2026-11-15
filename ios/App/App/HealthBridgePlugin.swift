import Foundation
import Capacitor
import HealthKit

/*
 THE HEALTHKIT BRIDGE.

 One job: read what Apple Health already holds for the last few days and hand it to the web
 app as one record per local calendar day, in plain numbers. Everything the app does with the
 numbers (baselines, the score, which device's HRV to trust) stays in index.html, where it
 already lives; this file only fetches.

 Read-only. The app never writes to Health, so it asks for no write permission at all.

 Called from JS as:
   const HB = Capacitor.registerPlugin('HealthBridge');
   await HB.isAvailable()            -> { available: Bool }
   await HB.requestAuthorization()   -> { requested: Bool }
   await HB.readDays({ days: 14 })   -> { days: [ { date: 'YYYY-MM-DD', ... } ] }

 Per day (each field only present when Health had something for it):
   hrvSDNN          ms, average of the overnight readings (Apple's HRV is SDNN, not RMSSD)
   restingHR        bpm, Apple's daily resting heart rate
   respiratoryRate  breaths/min, overnight average
   wristTempC       degrees C, Apple's sleeping wrist temperature (absolute, iOS 16+)
   steps            count for the day
   activeCalories   kcal for the day
   sleepHours       time asleep in the night ending that morning, overlaps between sources merged
   deepMin, remMin, coreMin, awakeMin   sleep stages, minutes (iOS 16+ watches)
   bedStart, wakeAt ISO timestamps of the first and last asleep moments
   runs             [{ start, distanceKm, durationMin }] running workouts that day
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
            .heartRateVariabilitySDNN, .restingHeartRate, .respiratoryRate, .stepCount, .activeEnergyBurned
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
            average(.heartRateVariabilitySDNN, HKUnit.secondUnit(with: .milli), nightStart, nightEnd, group) { value in set(key, "hrvSDNN", value) }
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
            readSleep(nightStart, nightEnd, group) { fields in
                for (field, value) in fields {
                    if field == "bedStart" || field == "wakeAt", let d = value as? Date {
                        set(key, field, iso.string(from: d))
                    } else {
                        set(key, field, value)
                    }
                }
            }
            readRuns(dayStart, dayEnd, group) { list in
                if !list.isEmpty {
                    set(key, "runs", list.map { run -> [String: Any] in
                        var out: [String: Any] = ["start": iso.string(from: run.start), "durationMin": run.durationMin]
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

    /* Sleep from every source at once (Watch, iPhone, a ring writing to Health), so the same
       hour can arrive two or three times. Each stage is the UNION of its intervals, never the
       sum, or one night with two sources reads as fourteen hours. Raw values, not the enum
       cases, so this compiles the same against the pre-iOS 16 names:
       0 inBed, 1 asleep (unspecified), 2 awake, 3 core, 4 deep, 5 REM. */
    private func readSleep(_ start: Date, _ end: Date, _ group: DispatchGroup,
                       _ done: @escaping ([String: Any]) -> Void) {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return }
        group.enter()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [sort]) { _, samples, _ in
            var asleep: [(Date, Date)] = [], deep: [(Date, Date)] = [], rem: [(Date, Date)] = [],
                core: [(Date, Date)] = [], awake: [(Date, Date)] = []
            for case let s as HKCategorySample in samples ?? [] {
                let span = (max(s.startDate, start), min(s.endDate, end))
                if span.0 >= span.1 { continue }
                switch s.value {
                case 1: asleep.append(span)
                case 2: awake.append(span)
                case 3: asleep.append(span); core.append(span)
                case 4: asleep.append(span); deep.append(span)
                case 5: asleep.append(span); rem.append(span)
                default: break
                }
            }
            var out: [String: Any] = [:]
            let asleepSec = HealthBridgePlugin.unionSeconds(asleep)
            if asleepSec > 0 {
                out["sleepHours"] = (asleepSec / 3600 * 100).rounded() / 100
                if let first = asleep.map({ span in span.0 }).min() { out["bedStart"] = first }
                if let last = asleep.map({ span in span.1 }).max() { out["wakeAt"] = last }
            }
            if !deep.isEmpty { out["deepMin"] = Int((HealthBridgePlugin.unionSeconds(deep) / 60).rounded()) }
            if !rem.isEmpty { out["remMin"] = Int((HealthBridgePlugin.unionSeconds(rem) / 60).rounded()) }
            if !core.isEmpty { out["coreMin"] = Int((HealthBridgePlugin.unionSeconds(core) / 60).rounded()) }
            if !awake.isEmpty { out["awakeMin"] = Int((HealthBridgePlugin.unionSeconds(awake) / 60).rounded()) }
            done(out)
            group.leave()
        }
        store.execute(query)
    }

    private struct Run { let start: Date; let durationMin: Double; let distanceKm: Double? }

    private func readRuns(_ start: Date, _ end: Date, _ group: DispatchGroup, _ done: @escaping ([Run]) -> Void) {
        group.enter()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
            var out: [Run] = []
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
                let roundedKm = km.map { v in (v * 100).rounded() / 100 }
                out.append(Run(start: w.startDate, durationMin: (w.duration / 60 * 10).rounded() / 10, distanceKm: roundedKm))
            }
            done(out)
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
