import WidgetKit
import SwiftUI

/*
 THE CHARGE, ON THE LOCK SCREEN AND THE HOME SCREEN.

 The app works the number out (Charge: the morning readiness less what the day has spent) and
 hands it here through the shared App Group, by WidgetBridgePlugin, each time it changes. This
 file only draws what it is given, so it can never disagree with the app. Charge only ever
 falls through the day and refills overnight, so a widget showing the last number the app
 worked out is at worst a little optimistic, and it says when that was.
*/
let dogfoodAppGroup = "group.com.touringgroup.dogfood"

struct ChargeSnapshot: Codable {
    var day: String?        // the app's date for this reading, yyyy-MM-dd
    var charge: Int?        // what the headline showed when it was sent
    var base: Int?          // that, before the long-day points
    var start: Int?         // what you woke with (Charge only)
    var drain: String?      // "lift −13 · run −9"; long day is added here, by the clock
    var session: String?
    var longFrom: Double?   // ms: when the long-day points start (wake + 12 h)
    var longMax: Int?
    var updatedAt: Double?
}

/* One reading of the snapshot at a moment. The app cannot run in the background, so the clock
   part of the drain (a point an hour past twelve hours awake, up to longMax, the same sum as
   computeCharge) is carried on here, and a snapshot from another day reads as no reading at
   all: Charge refills overnight, and the number the app last saw yesterday evening is not it. */
struct ChargeReading {
    let charge: Int?
    let start: Int?
    let drain: String
    let session: String?
    let updatedAt: Date?

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(_ snap: ChargeSnapshot?, at date: Date) {
        guard let s = snap, let c = s.charge, let day = s.day, day == ChargeReading.dayFormat.string(from: date) else {
            // Today's session still shows before there is a reading; yesterday's does not.
            let sameDay = snap?.day == ChargeReading.dayFormat.string(from: date)
            charge = nil; start = nil; drain = ""; updatedAt = nil
            session = sameDay ? snap?.session.flatMap { $0.isEmpty ? nil : $0 } : nil
            return
        }
        var now = c
        var long = 0
        if let base = s.base, let from = s.longFrom {
            let hours = (date.timeIntervalSince1970 * 1000 - from) / 3_600_000
            long = Int(min(Double(s.longMax ?? 6), max(0, hours)).rounded())
            now = max(0, base - long)
        }
        charge = now
        start = s.start
        var parts = (s.drain ?? "").isEmpty ? [] : [s.drain!]
        if long > 0 { parts.append("long day \u{2212}\(long)") }
        drain = parts.joined(separator: " \u{00B7} ")
        session = (s.session ?? "").isEmpty ? nil : s.session
        updatedAt = s.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

struct ChargeEntry: TimelineEntry {
    let date: Date
    let reading: ChargeReading
}

struct ChargeProvider: TimelineProvider {
    static let sample = ChargeSnapshot(day: ChargeReading.dayFormat.string(from: Date()), charge: 72, base: 72, start: 85,
                                       drain: "lift \u{2212}13", session: "Full body", longFrom: nil, longMax: nil, updatedAt: nil)
    func placeholder(in context: Context) -> ChargeEntry {
        ChargeEntry(date: Date(), reading: ChargeReading(ChargeProvider.sample, at: Date()))
    }
    func getSnapshot(in context: Context, completion: @escaping (ChargeEntry) -> Void) {
        let now = Date()
        completion(ChargeEntry(date: now, reading: ChargeReading(load() ?? ChargeProvider.sample, at: now)))
    }
    /* An entry every fifteen minutes to the end of the day, so the long-day drain moves on its
       own, then one at midnight that clears it, and WidgetKit asks again after that. */
    func getTimeline(in context: Context, completion: @escaping (Timeline<ChargeEntry>) -> Void) {
        let snap = load()
        let now = Date()
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400))
        var entries: [ChargeEntry] = []
        var t = now
        while t < midnight && entries.count < 96 {
            entries.append(ChargeEntry(date: t, reading: ChargeReading(snap, at: t)))
            t = t.addingTimeInterval(15 * 60)
        }
        entries.append(ChargeEntry(date: midnight, reading: ChargeReading(snap, at: midnight)))
        completion(Timeline(entries: entries, policy: .after(midnight.addingTimeInterval(60))))
    }
    private func load() -> ChargeSnapshot? {
        guard let data = UserDefaults(suiteName: dogfoodAppGroup)?.data(forKey: "chargeSnapshot") else { return nil }
        return try? JSONDecoder().decode(ChargeSnapshot.self, from: data)
    }
}

extension View {
    @ViewBuilder func dogfoodBackground(_ accessory: Bool) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            if accessory { self.containerBackground(for: .widget) { Color.clear } }
            else { self.containerBackground(for: .widget) { Color(red: 0.047, green: 0.051, blue: 0.043) } }
        } else {
            if accessory { self } else { self.background(Color(red: 0.047, green: 0.051, blue: 0.043)) }
        }
    }
}

struct ChargeView: View {
    @Environment(\.widgetFamily) var family
    let entry: ChargeEntry

    var r: ChargeReading { entry.reading }
    var chargeText: String { r.charge.map { String($0) } ?? "\u{2013}" }
    /* With no reading today, the line under the number says what would give it one. */
    var subline: String? {
        guard r.charge != nil else { return "Open Dogfood" }
        if let start = r.start {
            return r.drain.isEmpty ? "woke at \(start)" : "woke \(start) \u{00B7} \(r.drain)"
        }
        return nil
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(r.charge ?? 0), in: 0...100) {
                Text("CHG")
            } currentValueLabel: {
                Text(chargeText)
            }
            .gaugeStyle(.accessoryCircular)
            .widgetAccentable()
            .dogfoodBackground(true)
        case .accessoryInline:
            Text(r.charge == nil ? "Charge \u{2013} open Dogfood" : "Charge \(chargeText)\(r.session.map { " \u{00B7} \($0)" } ?? "")")
                .dogfoodBackground(true)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("Charge \(chargeText)").font(.headline).widgetAccentable()
                if let line = subline { Text(line).font(.caption).lineLimit(1).minimumScaleFactor(0.8) }
                if let s = r.session { Text(s).font(.caption).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dogfoodBackground(true)
        default:
            VStack(alignment: .leading, spacing: 4) {
                Text("CHARGE").font(.system(size: 11, weight: .bold)).foregroundColor(Color(white: 0.75))
                Text(chargeText).font(.system(size: 46, weight: .heavy, design: .rounded)).foregroundColor(.white)
                if let line = subline {
                    Text(line).font(.system(size: 12)).foregroundColor(Color(white: 0.8)).lineLimit(2).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                if let s = r.session {
                    Text(s).font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                }
                if let u = r.updatedAt {
                    Text(u, style: .time).font(.system(size: 10)).foregroundColor(Color(white: 0.6))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(2)
            .dogfoodBackground(false)
        }
    }
}

struct ChargeWidget: Widget {
    let kind = "DogfoodCharge"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ChargeProvider()) { entry in
            ChargeView(entry: entry)
        }
        .configurationDisplayName("Charge")
        .description("What you have left to perform with today, and your next session.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .systemSmall])
    }
}

@main
struct DogfoodWidgetBundle: WidgetBundle {
    var body: some Widget { ChargeWidget() }
}
