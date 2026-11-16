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
        CAPPluginMethod(name: "end", returnType: CAPPluginReturnPromise)
    ]

    @objc func update(_ call: CAPPluginCall) {
        guard #available(iOS 16.2, *) else { call.resolve(["ok": false]); return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { call.resolve(["ok": false]); return }
        let state = SessionActivityAttributes.ContentState(
            exercise: call.getString("exercise") ?? "",
            detail: call.getString("detail") ?? "",
            restEnds: call.getDouble("restEnds").map { Date(timeIntervalSince1970: $0 / 1000) },
            charge: call.getInt("charge")
        )
        // Stale when the rest is up, which makes iOS redraw it then: the clock reads "Go" rather
        // than sitting on 0:00.
        let content = ActivityContent(state: state, staleDate: state.restEnds)
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
