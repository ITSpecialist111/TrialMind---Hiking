import Foundation
import SafariServices
import UIKit

/// Uploading a hike by hand on Strava's own site (HikeDetailPage.uploadByHand): the way in that works for everyone, with
/// no subscription or Strava application. The GPX is saved to Files, then Strava's upload page opens in Safari, where
/// Choose file picks it up.
enum StravaHandUpload {
    /// The save sheet's delegate, kept until the sheet closes (the sheet only holds it weakly).
    private static var saving: SaveThenOpen?

    static func start(_ hikeId: Int64) {
        DispatchQueue.global(qos: .userInitiated).async {
            let hike = Store.shared.hike(hikeId)
            let segments = hike == nil ? [] : Store.shared.hikeSegments(hikeId)
            DispatchQueue.main.async { save(hike, segments) }
        }
    }

    private static func save(_ hike: HikeMeta?, _ segments: [[TrackPoint]]) {
        guard let hike else {
            AppModel.shared.toast("This hike no longer exists.")
            return
        }
        if hike.status != .done {
            AppModel.shared.toast("You can upload it to Strava once it's finished.")
            return
        }
        let gpx = StravaRequests.handUploadGpx(name: hike.name, segments: segments)
        // Short enough that the file keeps its .gpx ending (file names are cut at 60 characters).
        let fileName = String(AppModel.safeFileName(hike.name).prefix(56)) + ".gpx"
        guard let file = AppModel.shared.writeTemp(fileName, gpx) else {
            help(fileName, gpx)
            return
        }
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        let delegate = SaveThenOpen(fileName: file.lastPathComponent) { saving = nil }
        picker.delegate = delegate
        saving = delegate
        AppModel.shared.present(picker)
    }

    /// Where the file couldn't be written for the save sheet, the steps by hand, as Android's help dialog.
    private static func help(_ fileName: String, _ gpx: String) {
        AppModel.shared.choose("Upload to Strava",
                               "To upload this hike to Strava:\n1. Save the GPX (to Files, say).\n" +
                                   "2. Open Strava's upload page in Safari and choose the file.\n\n" +
                                   "The GPX includes timestamps, elevation and the activity type 'hiking'.",
                               options: [("Save GPX", { AppModel.shared.saveFile(fileName, gpx) }),
                                         ("Open upload page", { openUploadPage() })],
                               cancel: "Close")
    }

    static func openUploadPage() {
        if let url = URL(string: StravaPolicy.uploadPageUrl) { AppModel.shared.open(url) }
    }
}

/// Opens Strava's upload page once the GPX is saved; nothing happens if the user cancels the save.
private final class SaveThenOpen: NSObject {
    private let fileName: String
    private let closed: () -> Void

    init(fileName: String, closed: @escaping () -> Void) {
        self.fileName = fileName
        self.closed = closed
    }

    fileprivate func saved() {
        closed()
        AppModel.shared.toast("Saved \(fileName). On Strava, tap Choose file and pick it.")
        // Long enough to read the toast before Safari opens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { StravaHandUpload.openUploadPage() }
    }

    fileprivate func cancelled() { closed() }
}

extension SaveThenOpen: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { saved() }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { cancelled() }
}

/// Strava's pages that the Strava app would otherwise take over (it claims strava.com/settings links but has no API
/// settings), opened in an in-app Safari sheet instead.
enum StravaWeb {
    static func openInBrowser(_ link: String) {
        guard let url = URL(string: link) else { return }
        let browser = SFSafariViewController(url: url)
        browser.dismissButtonStyle = .done
        AppModel.shared.present(browser)
    }
}
