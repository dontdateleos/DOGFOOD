import UIKit
import Capacitor
import UniformTypeIdentifiers

/*
 BACKUP TO A FILE, AND BACK.

   share({ text, filename })  -> { saved }           writes the backup to a file and opens the share
                                                     sheet, so it can go to Files, iCloud Drive,
                                                     AirDrop or Mail
   pick()                     -> { text, name } or { cancelled: true }
                                                     opens Files to choose a backup to restore

 The app's data lives only on the phone; a file saved to iCloud Drive is what survives
 deleting the app or changing phones. The web app builds the text (the same JSON its Export
 writes) and does the restoring; this file only moves it in and out.
*/
@objc(BackupPlugin)
public class BackupPlugin: CAPPlugin, CAPBridgedPlugin, UIDocumentPickerDelegate {
    public let identifier = "BackupPlugin"
    public let jsName = "Backup"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "share", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pick", returnType: CAPPluginReturnPromise)
    ]
    private var pickCall: CAPPluginCall?

    @objc func share(_ call: CAPPluginCall) {
        guard let text = call.getString("text"), let data = text.data(using: .utf8) else {
            call.reject("Nothing to back up"); return
        }
        let name = call.getString("filename") ?? "dogfood-backup.json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic) } catch {
            call.reject("Could not write the backup file"); return
        }
        DispatchQueue.main.async {
            guard let vc = self.bridge?.viewController else { call.reject("No screen to show the share sheet on"); return }
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = vc.view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 1, height: 1)
            sheet.completionWithItemsHandler = { _, completed, _, _ in call.resolve(["saved": completed]) }
            vc.present(sheet, animated: true)
        }
    }

    @objc func pick(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let vc = self.bridge?.viewController else { call.reject("No screen to show Files on"); return }
            self.pickCall = call
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .plainText, .text], asCopy: true)
            picker.delegate = self
            vc.present(picker, animated: true)
        }
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let call = pickCall else { return }
        pickCall = nil
        guard let url = urls.first else { call.resolve(["cancelled": true]); return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            call.resolve(["text": text, "name": url.lastPathComponent])
        } catch {
            call.reject("Could not read that file")
        }
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pickCall?.resolve(["cancelled": true])
        pickCall = nil
    }
}
