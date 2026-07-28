import Foundation
import AuthenticationServices
import SeismicServices

/// The browser half of Google sign-in.
///
/// `ASWebAuthenticationSession` rather than opening Safari, for three reasons
/// that all showed up in the previous implementation. It owns the callback, so
/// the redirect returns to the app instead of stranding the user on a blank
/// page. It runs in a sheet over the app, so the app is never backgrounded and
/// nothing is lost. And it can share the Safari cookie jar, so somebody already
/// signed in to Google taps once rather than typing a password during the worst
/// possible week to be typing passwords.
///
/// `prefersEphemeralWebBrowserSession` is deliberately left off: a shared
/// household on a shared iPad is a real case, and the one-tap path is worth
/// more here than a private session would be.
@MainActor
final class WebSignIn: NSObject {

    enum Failure: Error {
        case notConfigured
        case cancelled
        case noCallback
    }

    /// Held for the lifetime of the sheet. Without a strong reference the
    /// session is deallocated the moment this function returns and the browser
    /// closes itself mid-sign-in.
    private var session: ASWebAuthenticationSession?

    func authenticate(_ attempt: CloudService.OAuthAttempt) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: attempt.url,
                callbackURLScheme: attempt.callbackScheme
            ) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    // Closing the sheet is a decision, not a fault. Reporting it
                    // as an error would put a red banner in front of somebody
                    // who simply changed their mind.
                    continuation.resume(throwing: Failure.cancelled)
                } else {
                    continuation.resume(throwing: error ?? Failure.noCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session

            if !session.start() {
                continuation.resume(throwing: Failure.noCallback)
            }
        }
    }
}

extension WebSignIn: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession)
    -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
                ?? UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }.first
            return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
        }
    }
}
