import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// The mail providers email import can read. Each is offered only once its OAuth client ID is
/// configured (Info.plist, from Secrets.xcconfig), so Outlook stays hidden until Microsoft issues one.
enum MailProvider: String, Codable, CaseIterable, Sendable {
    case google, microsoft

    /// The user's own account, so naming it is fine (it isn't a data source).
    var name: String {
        switch self {
        case .google: "Gmail"
        case .microsoft: "Outlook"
        }
    }

    var clientID: String? {
        let key = self == .google ? "GoogleClientID" : "MicrosoftClientID"
        let value = (Bundle.main.infoDictionary?[key] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        // An unset build setting can come through as its own "$(…)" text.
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }

    var isAvailable: Bool { clientID != nil && callbackScheme != nil }

    static var available: [MailProvider] { allCases.filter(\.isAvailable) }

    var callbackScheme: String? {
        switch self {
        case .google:
            let scheme = (Bundle.main.infoDictionary?["GoogleRedirectScheme"] as? String) ?? ""
            return scheme.isEmpty || scheme.hasPrefix("$(") ? nil : scheme
        case .microsoft:
            return "msauth.ca.akinyemi.bumpcast"
        }
    }

    var redirectURI: String {
        switch self {
        case .google: "\(callbackScheme ?? ""):/oauth2redirect"
        case .microsoft: "msauth.ca.akinyemi.bumpcast://auth"
        }
    }

    var authorizeURL: URL {
        switch self {
        case .google: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        case .microsoft: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        }
    }

    var tokenURL: URL {
        switch self {
        case .google: URL(string: "https://oauth2.googleapis.com/token")!
        case .microsoft: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
        }
    }

    /// Read-only mail, plus who's signed in so Settings can show the account.
    var scopes: String {
        switch self {
        case .google: "openid email https://www.googleapis.com/auth/gmail.readonly"
        case .microsoft: "openid email offline_access User.Read Mail.Read"
        }
    }
}

/// A connected mailbox. Lives only in the Keychain, on this phone.
struct MailAccount: Codable, Sendable {
    let provider: MailProvider
    var email: String
    var refreshToken: String
    var accessToken: String
    var expiresAt: Date
}

enum MailError: Error {
    case notConfigured
    case cancelled
    /// The provider refused the sign-in or the refresh (access was removed): connect again.
    case signedOut
    case failed
}

/// Sign-in (authorization code with PKCE in ASWebAuthenticationSession, no provider SDK), token
/// refresh and disconnect. One at a time, so two scans never refresh the same token at once.
actor MailSession {
    static let shared = MailSession()

    private var account: MailAccount?
    private var loaded = false

    /// The connected account, from the Keychain (nil before the first unlock, when it can't be read).
    func current() -> MailAccount? {
        if !loaded {
            account = MailKeychain.load()
            loaded = account != nil
        }
        return account
    }

    func connect(_ provider: MailProvider) async throws -> MailAccount {
        guard let clientID = provider.clientID, let scheme = provider.callbackScheme else { throw MailError.notConfigured }
        let verifier = Self.randomString(64)
        let state = Self.randomString(24)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        var components = URLComponents(url: provider.authorizeURL, resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: provider.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: provider.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        switch provider {
        // Offline access returns a refresh token; consent each time makes sure Google sends one.
        case .google: query += [.init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent")]
        case .microsoft: query += [.init(name: "prompt", value: "select_account")]
        }
        components.queryItems = query
        let callback = try await WebSignIn.run(url: components.url!, scheme: scheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state,
            let code = items.first(where: { $0.name == "code" })?.value
        else { throw items.contains { $0.name == "error" } ? MailError.signedOut : MailError.failed }

        let tokens = try await Self.token(
            provider,
            [
                "grant_type": "authorization_code", "code": code, "redirect_uri": provider.redirectURI,
                "client_id": clientID, "code_verifier": verifier,
            ])
        guard let refresh = tokens.refreshToken else { throw MailError.failed }
        let new = MailAccount(
            provider: provider, email: tokens.idToken.flatMap { Self.email(fromIDToken: $0) } ?? "",
            refreshToken: refresh, accessToken: tokens.accessToken,
            expiresAt: .now.addingTimeInterval(TimeInterval(tokens.expiresIn ?? 3600)))
        MailKeychain.save(new)
        account = new
        loaded = true
        return new
    }

    /// A current access token, refreshed a minute before it runs out.
    func accessToken() async throws -> (MailProvider, String) {
        guard var account = current() else { throw MailError.signedOut }
        if account.expiresAt > .now.addingTimeInterval(60) { return (account.provider, account.accessToken) }
        guard let clientID = account.provider.clientID else { throw MailError.notConfigured }
        var body = ["grant_type": "refresh_token", "refresh_token": account.refreshToken, "client_id": clientID]
        if account.provider == .microsoft { body["scope"] = account.provider.scopes }
        let tokens = try await Self.token(account.provider, body)
        account.accessToken = tokens.accessToken
        account.expiresAt = .now.addingTimeInterval(TimeInterval(tokens.expiresIn ?? 3600))
        // Microsoft hands out a new refresh token each time.
        if let refresh = tokens.refreshToken { account.refreshToken = refresh }
        MailKeychain.save(account)
        self.account = account
        return (account.provider, account.accessToken)
    }

    /// Revokes access with Google (Microsoft has no revoke endpoint for a single token; removing
    /// it here ends it) and deletes the tokens. Deleted even if the revoke can't be reached.
    func disconnect() async {
        if let account = current(), account.provider == .google {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(["token": account.refreshToken])
            _ = try? await URLSession.shared.data(for: request)
        }
        MailKeychain.delete()
        account = nil
        loaded = true
    }

    // MARK: Token endpoint

    private struct Tokens: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int?
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case idToken = "id_token"
        }
    }

    private static func token(_ provider: MailProvider, _ body: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: provider.tokenURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 400/401 with invalid_grant: the access was removed or expired for good.
        if status == 400 || status == 401 { throw MailError.signedOut }
        guard status == 200 else { throw MailError.failed }
        return try JSONDecoder().decode(Tokens.self, from: data)
    }

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8) ?? Data()
    }

    /// The account's address from the ID token, which came straight from the token endpoint.
    private static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count > 1, let data = Data(base64URLEncoded: String(parts[1])),
            let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (claims["email"] as? String) ?? (claims["preferred_username"] as? String)
    }

    private static func randomString(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncoded
    }
}

/// The system sign-in sheet, on the main actor.
@MainActor
private final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static var running: WebSignIn?
    private var session: ASWebAuthenticationSession?

    static func run(url: URL, scheme: String) async throws -> URL {
        let signIn = WebSignIn()
        running = signIn
        defer { running = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { @Sendable callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: MailError.cancelled)
                } else {
                    continuation.resume(throwing: MailError.failed)
                }
            }
            session.presentationContextProvider = signIn
            session.prefersEphemeralWebBrowserSession = false
            signIn.session = session
            if !session.start() { continuation.resume(throwing: MailError.failed) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            if let window = scene?.keyWindow ?? scene?.windows.first { return window }
            // Sign-in starts from a button on screen, so there's always a scene.
            return UIWindow(windowScene: scene ?? scenes[0])
        }
    }
}

/// The connected account's tokens and address: this device only, readable after the first
/// unlock so background refresh can scan.
enum MailKeychain {
    private static let service = "ca.akinyemi.bumpcast.mail"
    private static let accountKey = "account"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: accountKey]
    }

    static func load() -> MailAccount? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(MailAccount.self, from: data)
    }

    static func save(_ account: MailAccount) {
        guard let data = try? JSONEncoder().encode(account) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
