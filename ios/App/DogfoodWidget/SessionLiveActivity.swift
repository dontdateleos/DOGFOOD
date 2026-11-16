import WidgetKit
import SwiftUI
import ActivityKit

/*
 THE SESSION, ON THE LOCK SCREEN AND IN THE DYNAMIC ISLAND, while you lift.

 The lift in hand, the set you just logged and the rest countdown, so the next set can start
 without unlocking the phone. The countdown runs on the lock screen's own clock from an end
 time (see SessionActivityAttributes); once it is up the line says so instead of sitting at 0:00.
*/
private let ground = Color(red: 0.047, green: 0.051, blue: 0.043)
private let lime = Color(red: 0.776, green: 0.953, blue: 0.2)

private struct RestClock: View {
    let ends: Date?
    var body: some View {
        if let end = ends, end > Date() {
            Text(timerInterval: Date()...end, countsDown: true)
                .monospacedDigit()
        } else {
            Text("Go")
        }
    }
}

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.title.uppercased())
                        .font(.system(size: 11, weight: .bold)).foregroundColor(Color(white: 0.7))
                    Text(context.state.exercise).font(.headline).foregroundColor(.white).lineLimit(1)
                    Text(context.state.detail).font(.subheadline).foregroundColor(Color(white: 0.85)).lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("REST").font(.system(size: 11, weight: .bold)).foregroundColor(Color(white: 0.7))
                    RestClock(ends: context.state.restEnds)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(lime)
                        .frame(minWidth: 70, alignment: .trailing)
                    if let c = context.state.charge {
                        Text("Charge \(c)").font(.caption).foregroundColor(Color(white: 0.7))
                    }
                }
            }
            .padding(16)
            .activityBackgroundTint(ground)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.exercise).font(.headline).lineLimit(1)
                        Text(context.state.detail).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RestClock(ends: context.state.restEnds)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(lime)
                        .frame(minWidth: 64, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.attributes.title).font(.caption).foregroundColor(.secondary)
                        Spacer()
                        if let c = context.state.charge { Text("Charge \(c)").font(.caption).foregroundColor(.secondary) }
                    }
                }
            } compactLeading: {
                Image(systemName: "dumbbell.fill").foregroundColor(lime)
            } compactTrailing: {
                RestClock(ends: context.state.restEnds)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(lime)
                    .frame(maxWidth: 48)
            } minimal: {
                Image(systemName: "dumbbell.fill").foregroundColor(lime)
            }
            .keylineTint(lime)
        }
    }
}
