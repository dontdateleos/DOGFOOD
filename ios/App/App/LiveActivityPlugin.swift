import Foundation
import Capacitor
import ActivityKit

/*
 THE SESSION ON THE LOCK SCREEN.

   update({ title, exercise, detail, restEnds, charge })   starts the Live Activity if none is
                                                           running, otherwise updates it
   end()                                                   takes it down

 The web app calls update when a set is ticked or a rest starts or stops, and end when the
 session is saved or thrown away (putting the session away on the bar keeps it). restEnds is
 epoch milliseconds, or absent for no rest. iOS 16.2 and later; on anything older, and when
 Live Activities are switched off in Settings, both calls resolve without doing anything.
*/
@objc(LiveActivityPlugin)
public class LiveActivityPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "LiveActivityPlugin"
    public let jsName = "LiveActivity"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "update", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "end", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "endStale", returnType: CAPPluginReturnPromise)
    ]
    private static let lastKey = "liveActivityLastUpdate"

    @objc func update(_ call: CAPPluginCall) {
        guard #available(iOS 16.2, *) else { call.resolve(["ok": false]); return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { call.resolve(["ok": false]); return }
        let state = SessionActivityAttributes.ContentState(
            exercise: call.getString("exercise") ?? "",
            detail: call.getString("detail") ?? "",
            restEnds: call.getDouble("restEnds").map { Date(timeIntervalSince1970: $0 / 1000) },
            charge: call.getInt("charge"),
            next: call.getString("next")
        )
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: LiveActivityPlugin.lastKey)
        // Stale when the rest is up, which makes iOS redraw it then: the clock reads "Go" rather
        // than sitting on 0:00.
        // With no rest running it goes stale after 90 minutes without a set: a session left open.
        let content = ActivityContent(state: state, staleDate: state.restEnds ?? Date().addingTimeInterval(90 * 60))
        if let current = Activity<SessionActivityAttributes>.activities.first {
            Task {
                await current.update(content)
                call.resolve(["ok": true])
            }
            return
        }
        do {
            let attrs = SessionActivityAttributes(title: call.getString("title") ?? "Session")
            _ = try Activity.request(attributes: attrs, content: content, pushType: nil)
            call.resolve(["ok": true])
        } catch {
            call.resolve(["ok": false, "error": error.localizedDescription])
        }
    }

    /* A SESSION LEFT OPEN. Called when the app opens or comes back: if no set has been logged
       for `minutes` (default 90), whatever is still on the lock screen is taken down. */
    @objc func endStale(_ call: CAPPluginCall) {
        guard #available(iOS 16.2, *) else { call.resolve(["ended": false]); return }
        let minutes = Double(call.getInt("minutes") ?? 90)
        let last = UserDefaults.standard.double(forKey: LiveActivityPlugin.lastKey)
        let idle = last > 0 ? Date().timeIntervalSince1970 - last : .infinity
        guard idle > minutes * 60, !Activity<SessionActivityAttributes>.activities.isEmpty else { call.resolve(["ended": false]); return }
        Task {
            for activity in Activity<SessionActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            call.resolve(["ended": true])
        }
    }

    @objc func end(_ call: CAPPluginCall) {
        guard #available(iOS 16.2, *) else { call.resolve(); return }
        Task {
            for activity in Activity<SessionActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            call.resolve()
        }
    }
}
