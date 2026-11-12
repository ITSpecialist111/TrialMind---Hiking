import AuthenticationServices
import UIKit

/// Strava's sign-in in the system's secure browser sheet, coming back to TrailMind on its trailmind:// redirect
/// (Android opens the browser or the Strava app, which then opens TrailMind's link). The sheet shares Safari's sign-in,
/// so most people only have to approve. Used from the main thread.
final class StravaSignIn {
    static let shared = StravaSignIn()

    enum Outcome {
        /// Strava sent the user back with this link (approved or not: the link says which).
        case redirect(URL)
        case cancelled
        case failed(String)
    }

    private var session: ASWebAuthenticationSession?
    private var anchor: WindowAnchor?

    func start(_ url: URL, done: @escaping (Outcome) -> Void) {
        session?.cancel()
        session = nil
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first else {
            done(.failed("Strava's sign-in couldn't open here."))
            return
        }
        let finished: ASWebAuthenticationSession.CompletionHandler = { callback, error in
            let outcome: Outcome
            if let callback {
                outcome = .redirect(callback)
            } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                outcome = .cancelled
            } else {
                outcome = .failed(error?.localizedDescription ?? "Strava's sign-in didn't finish.")
            }
            DispatchQueue.main.async {
                StravaSignIn.shared.ended()
                done(outcome)
            }
        }
        let scheme = "trailmind"
        let signIn: ASWebAuthenticationSession
        if #available(iOS 17.4, *) {
            signIn = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme), completionHandler: finished)
        } else {
            signIn = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme, completionHandler: finished)
        }
        let anchor = WindowAnchor(window)
        signIn.presentationContextProvider = anchor
        signIn.prefersEphemeralWebBrowserSession = false
        // The session and its anchor must stay alive until the sheet closes.
        self.anchor = anchor
        session = signIn
        if !signIn.start() {
            ended()
            done(.failed("Strava's sign-in couldn't open here."))
        }
    }

    private func ended() {
        session = nil
        anchor = nil
    }
}

/// The window the sign-in sheet is shown over.
private final class WindowAnchor: NSObject {
    fileprivate let window: UIWindow

    init(_ window: UIWindow) { self.window = window }
}

extension WindowAnchor: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
}
