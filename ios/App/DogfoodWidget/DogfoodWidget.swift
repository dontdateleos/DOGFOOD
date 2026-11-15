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
    var charge: Int?
    var start: Int?
    var drain: String?
    var session: String?
    var updatedAt: Double?
}

struct ChargeEntry: TimelineEntry {
    let date: Date
    let snap: ChargeSnapshot?
}

struct ChargeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ChargeEntry {
        ChargeEntry(date: Date(), snap: ChargeSnapshot(charge: 72, start: 80, drain: "lift −8", session: "Full body", updatedAt: nil))
    }
    func getSnapshot(in context: Context, completion: @escaping (ChargeEntry) -> Void) {
        completion(ChargeEntry(date: Date(), snap: load() ?? placeholder(in: context).snap))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ChargeEntry>) -> Void) {
        let entry = ChargeEntry(date: Date(), snap: load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
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

    var chargeText: String { entry.snap?.charge.map { String($0) } ?? "–" }
    var updated: Date? { entry.snap?.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(entry.snap?.charge ?? 0), in: 0...100) {
                Text("CH")
            } currentValueLabel: {
                Text(chargeText)
            }
            .gaugeStyle(.accessoryCircular)
            .dogfoodBackground(true)
        case .accessoryInline:
            Text("Charge \(chargeText)\(entry.snap?.session.map { " · \($0)" } ?? "")")
                .dogfoodBackground(true)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("Charge \(chargeText)").font(.headline).widgetAccentable()
                if let start = entry.snap?.start, let drain = entry.snap?.drain, !drain.isEmpty {
                    Text("woke \(start) · \(drain)").font(.caption).lineLimit(1)
                } else if let start = entry.snap?.start {
                    Text("woke at \(start)").font(.caption)
                }
                if let s = entry.snap?.session { Text(s).font(.caption).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dogfoodBackground(true)
        default:
            VStack(alignment: .leading, spacing: 4) {
                Text("CHARGE").font(.system(size: 11, weight: .bold)).foregroundColor(Color(white: 0.75))
                Text(chargeText).font(.system(size: 46, weight: .heavy, design: .rounded)).foregroundColor(.white)
                if let start = entry.snap?.start {
                    Text("woke at \(start)").font(.system(size: 12)).foregroundColor(Color(white: 0.8))
                }
                Spacer(minLength: 0)
                if let s = entry.snap?.session {
                    Text(s).font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                }
                if let u = updated {
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
