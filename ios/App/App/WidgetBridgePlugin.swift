import Foundation
import Capacitor
import WidgetKit

/*
 HANDS THE CHARGE TO THE WIDGET.

 The web app calls update({ day, charge, base, start, drain, session, longFrom, longMax,
 nextLabel, nextCost, lastPerf, link, bedtime, bedtimeFrom })
 whenever the number changes (just { day } on a day with no reading yet); this writes it to the App Group the widget reads (DogfoodWidget.swift) and asks WidgetKit to redraw.
 Built without the App Group (TestFlight runs before it has been set up), the write lands in the
 app's own defaults instead, no widget reads it, and nothing breaks.
*/
@objc(WidgetBridgePlugin)
public class WidgetBridgePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "WidgetBridgePlugin"
    public let jsName = "WidgetBridge"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "update", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "takeLink", returnType: CAPPluginReturnPromise)
    ]
    static let group = "group.com.touringgroup.dogfood"

    /* A TAP ON THE WIDGET opens dogfood://today or dogfood://session. SceneDelegate passes the
       URL here. On a cold start the page is not running yet, so the host is kept until the page
       asks for it (takeLink); with the app already open it is announced straight away. */
    static var pendingLink: String?
    static weak var shared: WidgetBridgePlugin?

    static func receive(_ url: URL) {
        guard url.scheme == "dogfood" else { return }
        let to = url.host ?? "today"
        if let plugin = shared, plugin.bridge?.webView != nil {
            plugin.notifyListeners("link", data: ["to": to])
        } else {
            pendingLink = to
        }
    }

    override public func load() {
        WidgetBridgePlugin.shared = self
    }

    @objc func takeLink(_ call: CAPPluginCall) {
        let to = WidgetBridgePlugin.pendingLink
        WidgetBridgePlugin.pendingLink = nil
        call.resolve(to.map { ["to": $0] } ?? [:])
    }

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
        if let v = call.getString("nextLabel"), !v.isEmpty { snap["nextLabel"] = v }
        if let v = call.getInt("nextCost"), v > 0 { snap["nextCost"] = v }
        if let v = call.getString("lastPerf"), !v.isEmpty { snap["lastPerf"] = v }
        if let v = call.getString("link") { snap["link"] = v }
        if let v = call.getString("bedtime"), !v.isEmpty { snap["bedtime"] = v }
        if let v = call.getDouble("bedtimeFrom") { snap["bedtimeFrom"] = v }
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
