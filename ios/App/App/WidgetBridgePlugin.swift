import Foundation
import Capacitor
import WidgetKit

/*
 HANDS THE CHARGE TO THE WIDGET.

 The web app calls update({ day, charge, base, start, drain, session, longFrom, longMax })
 whenever the number changes (just { day } on a day with no reading yet); this writes it to the App Group the widget reads (DogfoodWidget.swift) and asks WidgetKit to redraw.
 Built without the App Group (TestFlight runs before it has been set up), the write lands in the
 app's own defaults instead, no widget reads it, and nothing breaks.
*/
@objc(WidgetBridgePlugin)
public class WidgetBridgePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "WidgetBridgePlugin"
    public let jsName = "WidgetBridge"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "update", returnType: CAPPluginReturnPromise)
    ]
    static let group = "group.com.touringgroup.dogfood"

    @objc func update(_ call: CAPPluginCall) {
        var snap: [String: Any] = ["updatedAt": Date().timeIntervalSince1970 * 1000]
        if let v = call.getString("day") { snap["day"] = v }
        if let v = call.getInt("charge") { snap["charge"] = v }
        if let v = call.getInt("base") { snap["base"] = v }
        if let v = call.getInt("start") { snap["start"] = v }
        if let v = call.getString("drain") { snap["drain"] = v }
        if let v = call.getString("session") { snap["session"] = v }
        if let v = call.getDouble("longFrom") { snap["longFrom"] = v }
        if let v = call.getInt("longMax") { snap["longMax"] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: snap) else {
            call.reject("could not encode")
            return
        }
        let defaults = UserDefaults(suiteName: WidgetBridgePlugin.group) ?? UserDefaults.standard
        defaults.set(data, forKey: "chargeSnapshot")
        if #available(iOS 14.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        call.resolve(["ok": true])
    }
}
