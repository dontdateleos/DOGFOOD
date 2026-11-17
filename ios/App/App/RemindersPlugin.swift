import Foundation
import Capacitor
import UserNotifications

/*
 PHONE NOTIFICATIONS, SCHEDULED BY THE WEB APP.

   permission({ ask })                      -> { granted, denied? }  asks only when ask is true
   schedule({ id, title, body, at, link })  -> { scheduled }         at is epoch milliseconds
   cancel({ id })

 Used for the bedtime nudge: the web app works out tonight's "in bed by" and schedules one
 notification half an hour before it, replacing the last one by id. Local only: nothing is
 sent through a server, and nothing is scheduled until you say yes to notifications.
*/
@objc(RemindersPlugin)
public class RemindersPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "RemindersPlugin"
    public let jsName = "Reminders"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "permission", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "schedule", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancel", returnType: CAPPluginReturnPromise)
    ]

    @objc func permission(_ call: CAPPluginCall) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                call.resolve(["granted": true])
            case .denied:
                call.resolve(["granted": false, "denied": true])
            default:
                guard call.getBool("ask") ?? false else { call.resolve(["granted": false]); return }
                center.requestAuthorization(options: [.alert, .sound]) { ok, _ in call.resolve(["granted": ok]) }
            }
        }
    }

    @objc func schedule(_ call: CAPPluginCall) {
        guard let id = call.getString("id"), let at = call.getDouble("at") else {
            call.reject("schedule needs an id and a time"); return
        }
        let interval = Date(timeIntervalSince1970: at / 1000).timeIntervalSinceNow
        guard interval > 1 else { call.resolve(["scheduled": false]); return }
        let content = UNMutableNotificationContent()
        content.title = call.getString("title") ?? "Dogfood"
        content.body = call.getString("body") ?? ""
        content.sound = .default
        if let link = call.getString("link") { content.userInfo = ["link": link] }
        let request = UNNotificationRequest(identifier: id, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
        UNUserNotificationCenter.current().add(request) { error in call.resolve(["scheduled": error == nil]) }
    }

    @objc func cancel(_ call: CAPPluginCall) {
        if let id = call.getString("id") {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        }
        call.resolve()
    }
}
