import SwiftUI
import UIKit

/// App-wide state and the small services every page uses: dialogs, toasts, sharing, copying and opening links.
/// Feature services are singletons (`X.shared`) so each feature stays in its own files.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let prefs = Prefs.shared
    let store = Store.shared
    let nav = Navigator.shared

    struct DialogAction: Identifiable {
        let id = UUID()
        let label: String
        var role: ButtonRole? = nil
        let run: (String) -> Void
    }

    struct Dialog: Identifiable {
        let id = UUID()
        let title: String
        var message: String? = nil
        var field: (hint: String, initial: String, keyboard: UIKeyboardType)? = nil
        var actions: [DialogAction]
    }

    @Published var dialog: Dialog? = nil
    @Published var toastMessage: String? = nil
    private var toastWork: DispatchWorkItem?

    /// A short message at the foot of the screen (Android's Toast.LENGTH_LONG).
    func toast(_ message: String) {
        DispatchQueue.main.async {
            self.toastWork?.cancel()
            withAnimation { self.toastMessage = message }
            let work = DispatchWorkItem { withAnimation { self.toastMessage = nil } }
            self.toastWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
        }
    }

    func info(_ title: String, _ message: String) {
        dialog = Dialog(title: title, message: message, actions: [DialogAction(label: "OK", role: .cancel) { _ in }])
    }

    func confirm(_ title: String, _ message: String, ok: String, danger: Bool = false, onOk: @escaping () -> Void) {
        dialog = Dialog(title: title, message: message, actions: [
            DialogAction(label: ok, role: danger ? .destructive : nil) { _ in onOk() },
            DialogAction(label: "Cancel", role: .cancel) { _ in },
        ])
    }

    func choose(_ title: String, _ message: String? = nil, options: [(String, () -> Void)], cancel: String = "Cancel") {
        dialog = Dialog(title: title, message: message,
                        actions: options.map { option in DialogAction(label: option.0) { _ in option.1() } }
                            + [DialogAction(label: cancel, role: .cancel) { _ in }])
    }

    func prompt(_ title: String, initial: String = "", hint: String = "", message: String? = nil,
                keyboard: UIKeyboardType = .default, ok: String = "OK", onOk: @escaping (String) -> Void) {
        dialog = Dialog(title: title, message: message, field: (hint, initial, keyboard), actions: [
            DialogAction(label: ok) { onOk($0.trimmingCharacters(in: .whitespacesAndNewlines)) },
            DialogAction(label: "Cancel", role: .cancel) { _ in },
        ])
    }

    func copy(_ label: String, _ text: String) {
        UIPasteboard.general.string = text
        toast("\(label) copied")
    }

    func open(_ url: URL) { UIApplication.shared.open(url) }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    /// The system share sheet for text, links or files.
    func share(_ items: [Any], subject: String? = nil) {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let subject { vc.setValue(subject, forKey: "subject") }
        present(vc)
    }

    /// Writes `content` to a temporary file with `fileName` and offers it with the share sheet (GPX export).
    func shareFile(_ fileName: String, _ content: String) {
        guard let url = writeTemp(fileName, content) else { toast("Could not write \(fileName)"); return }
        share([url])
    }

    /// "Save to Files": the system document exporter for a file written from `content`.
    func saveFile(_ fileName: String, _ content: String) {
        guard let url = writeTemp(fileName, content) else { toast("Could not write \(fileName)"); return }
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        present(picker)
    }

    func writeTemp(_ fileName: String, _ content: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(AppModel.safeFileName(fileName))
        do { try content.data(using: .utf8)?.write(to: url, options: .atomic); return url } catch { return nil }
    }

    static func safeFileName(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "[^A-Za-z0-9 ._-]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let name = String(cleaned.prefix(60))
        return name.isEmpty ? "trailmind" : name
    }

    /// Presents a UIKit controller over whatever is on screen (share sheets, document pickers, message composers).
    func present(_ vc: UIViewController) {
        DispatchQueue.main.async {
            guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController else { return }
            var top = root
            while let next = top.presentedViewController { top = next }
            if let pop = vc.popoverPresentationController {
                pop.sourceView = top.view
                pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
                pop.permittedArrowDirections = []
            }
            top.present(vc, animated: true)
        }
    }
}

/// Shows `AppModel.dialog` as a system alert, with a text field when it asks for one.
struct DialogHost: ViewModifier {
    @ObservedObject var app: AppModel
    @State private var text = ""

    func body(content: Content) -> some View {
        content.alert(app.dialog?.title ?? "", isPresented: Binding(
            get: { app.dialog != nil },
            set: { if !$0 { app.dialog = nil } }
        ), presenting: app.dialog) { dialog in
            if let field = dialog.field {
                TextField(field.hint, text: $text)
                    .keyboardType(field.keyboard)
                    .onAppear { text = field.initial }
            }
            ForEach(dialog.actions) { action in
                Button(action.label, role: action.role) {
                    let value = text
                    app.dialog = nil
                    action.run(value)
                }
            }
        } message: { dialog in
            if let message = dialog.message { Text(message) }
        }
    }
}

/// The floating toast at the foot of the screen.
struct ToastHost: View {
    @Environment(\.palette) private var p
    @ObservedObject var app: AppModel
    var bottom: CGFloat

    var body: some View {
        VStack {
            Spacer()
            if let message = app.toastMessage {
                Text(message)
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(p.onInverse)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(p.inverse))
                    .padding(.horizontal, 24)
                    .padding(.bottom, bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .allowsHitTesting(false)
    }
}
