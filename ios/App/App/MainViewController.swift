import UIKit
import Capacitor

/*
 The app's one screen: Capacitor's web view, plus the plugins that live inside this project
 rather than in an npm package. A plugin compiled into the app target has to be handed to the
 bridge by hand, and capacitorDidLoad is the moment the bridge exists to take it.
*/
class MainViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(HealthBridgePlugin())
    }
}
