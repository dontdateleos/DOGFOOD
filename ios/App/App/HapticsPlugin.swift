import UIKit
import Capacitor

/*
 THE TAPTIC ENGINE, FOR THE WEB APP.

 Three calls, matching the three kinds of feedback iOS has:
   impact({ style })        light | medium | heavy | soft | rigid. A press landing.
   selection()              the tick a picker wheel makes passing each row.
   notification({ type })   success | warning | error. Something finished, or did not.

 Which gesture gets which feel is decided in index.html (see haptic() there). This file only
 plays them. The generators are kept and prepared ahead of time so a tick lands on the frame
 it was asked for, not a few milliseconds later. iOS's own Settings → Sounds & Haptics →
 System Haptics switch silences all of them; nothing here needs to check it.
*/
@objc(HapticsPlugin)
public class HapticsPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "HapticsPlugin"
    public let jsName = "Haptics"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "impact", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "selection", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "notification", returnType: CAPPluginReturnPromise)
    ]

    private var impacts: [String: UIImpactFeedbackGenerator] = [:]
    private let selectionGen = UISelectionFeedbackGenerator()
    private let notificationGen = UINotificationFeedbackGenerator()

    private func impactGenerator(_ style: String) -> UIImpactFeedbackGenerator {
        if let g = impacts[style] { return g }
        let s: UIImpactFeedbackGenerator.FeedbackStyle
        switch style {
        case "medium": s = .medium
        case "heavy": s = .heavy
        case "soft": s = .soft
        case "rigid": s = .rigid
        default: s = .light
        }
        let g = UIImpactFeedbackGenerator(style: s)
        impacts[style] = g
        return g
    }

    @objc func impact(_ call: CAPPluginCall) {
        let style = call.getString("style") ?? "light"
        DispatchQueue.main.async {
            let g = self.impactGenerator(style)
            g.impactOccurred()
            g.prepare()
            call.resolve()
        }
    }

    @objc func selection(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.selectionGen.selectionChanged()
            self.selectionGen.prepare()
            call.resolve()
        }
    }

    @objc func notification(_ call: CAPPluginCall) {
        let type = call.getString("type") ?? "success"
        DispatchQueue.main.async {
            let t: UINotificationFeedbackGenerator.FeedbackType
            switch type {
            case "warning": t = .warning
            case "error": t = .error
            default: t = .success
            }
            self.notificationGen.notificationOccurred(t)
            self.notificationGen.prepare()
            call.resolve()
        }
    }
}
