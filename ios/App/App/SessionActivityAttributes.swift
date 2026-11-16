import Foundation
import ActivityKit

/*
 WHAT THE LIVE ACTIVITY CARRIES. Compiled into both the app (LiveActivityPlugin starts and
 updates it) and the widget extension (SessionLiveActivity draws it), so the two agree on the
 shape by construction.

 The rest countdown is an end time, not a number of seconds: the lock screen counts it down
 itself (Text(timerInterval:)), so it keeps time while the app is closed and nothing has to
 send an update every second.
*/
@available(iOS 16.1, *)
struct SessionActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var exercise: String      // the lift in hand
        var detail: String        // "Set 3 of 5 · 8 × 60 kg"
        var restEnds: Date?       // when the rest is up, if one is running
        var charge: Int?          // Charge when the set was logged
    }
    var title: String             // the session, "Full body A"
}
