import CryptoKit
import Foundation

/// Public attribution only. Credentials and JWTs never enter snapshots or caches.
public struct CodexAccountContext: Codable, Equatable, Sendable {
    public let codexHome: String
    public let authenticationSource: String
    public let accountKey: String?
    public let accountLabel: String?
    public let limitID: String

    public var scopeKey: String? {
        accountKey.map { Self.digest([codexHome, authenticationSource, $0, limitID]) }
    }

    static func digest(_ components: [String]) -> String {
        let data = try! JSONEncoder().encode(components)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Captured once per official request so its authentication and attribution agree.
struct CodexAccountSource {
    let codexHome: URL
    let authFile: URL
    let credentials: [String: Any]?
    let usesFileCredentials: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let path = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        codexHome = (path.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex"))
            .standardizedFileURL.resolvingSymlinksInPath()
        // Codex app-server owns its credentials. A separate CODEX_AUTH_FILE must
        // not redirect only the reset-credit request to a different login.
        authFile = codexHome.appendingPathComponent("auth.json").resolvingSymlinksInPath()
        credentials = (try? Data(contentsOf: authFile)).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }
        let config = (try? String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        let otherStore = config.range(of: #"(?m)^\s*cli_auth_credentials_store\s*=\s*["'](keyring|auto|ephemeral)["']"#,
                                      options: .regularExpression) != nil
        usesFileCredentials = !otherStore
    }

    var tokens: [String: Any] { credentials?["tokens"] as? [String: Any] ?? [:] }

    private var claims: [String: Any] {
        for key in ["id_token", "access_token"] {
            guard let token = tokens[key] as? String else { continue }
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            if let data = Data(base64Encoded: encoded),
               let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return value }
        }
        return [:]
    }

    var identityKey: String? {
        guard usesFileCredentials,
              let accountID = tokens["account_id"] as? String, !accountID.isEmpty,
              let user = (claims["sub"] as? String) ?? (claims["email"] as? String), !user.isEmpty
        else { return nil }
        return CodexAccountContext.digest([accountID, user])
    }

    func context(account: [String: Any]?, limitID: String = "codex") -> CodexAccountContext {
        let email = account?["email"] as? String
        let localEmail = claims["email"] as? String
        let matches = account?["type"] as? String == "chatgpt"
            && (email == nil || localEmail == nil || email?.lowercased() == localEmail?.lowercased())
        return CodexAccountContext(codexHome: codexHome.path,
                                   authenticationSource: usesFileCredentials ? authFile.path : "app-server managed credentials",
                                   accountKey: matches ? identityKey : nil, accountLabel: email, limitID: limitID)
    }

    func matches(_ other: CodexAccountSource) -> Bool {
        refreshIdentity == other.refreshIdentity
    }

    var refreshIdentity: String {
        let fallback = credentials.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .map { CodexAccountContext.digest([$0.base64EncodedString()]) } ?? "no-file-credentials"
        return CodexAccountContext.digest([codexHome.path, authFile.path, String(usesFileCredentials), identityKey ?? fallback])
    }
}
