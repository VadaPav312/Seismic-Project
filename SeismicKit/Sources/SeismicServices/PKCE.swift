import Foundation
import CryptoKit

/// Proof Key for Code Exchange, RFC 7636.
///
/// This app is a public client: anything it knows, an attacker with a copy of
/// the binary also knows, so there is no client secret to protect the token
/// exchange with. PKCE replaces that secret with a value invented fresh for
/// each attempt — the app sends a hash of it when it asks for authorisation,
/// and the value itself only when it redeems the code. An attacker who
/// intercepts the redirect gets a code that is useless without the verifier.
///
/// The reason it matters here specifically: the callback arrives over a custom
/// URL scheme, and any app on the device may claim `seismic://`. Without PKCE
/// that interception is a complete account takeover; with it, it is a code
/// nobody can spend.
enum PKCE {

    /// A high-entropy random string, 43–128 characters from the unreserved set.
    ///
    /// 32 random bytes base64url-encoded lands at 43 characters, the minimum
    /// the specification allows and comfortably beyond guessing.
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        // SecRandomCopyBytes is the platform CSPRNG. If it ever fails — which
        // requires the system entropy pool to be broken — falling back to
        // SystemRandomNumberGenerator is still cryptographically seeded, and
        // failing the sign-in outright would be a worse answer than a second
        // sound source of randomness.
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
        }
        return base64URL(Data(bytes))
    }

    /// The S256 challenge: base64url(SHA256(verifier)), hashed over the ASCII
    /// bytes of the verifier rather than its decoded form.
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    /// Base64 with the two URL-hostile characters swapped and the padding
    /// dropped, as the specification requires. Ordinary base64 here produces a
    /// challenge the server computes differently and every exchange fails.
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
