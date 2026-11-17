import Foundation
import Security

// MARK: - Keychain (FR-1: PATs only in the macOS Keychain)

public enum Keychain {
    static let service = "ReviewBar"
    public static func key(_ a: Account) -> String { "\(a.provider.rawValue):\(a.host)" }

    public static func token(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    public static func set(_ token: String, for account: String) -> Bool {
        delete(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(token.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    public static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Errors

public enum ForgeError: Error, LocalizedError, Equatable {
    case auth(Provider, String)
    case notLoggedIn(Provider, String)
    case rateLimited(Date)
    case http(Int, String)
    case notFound
    case headMoved(expected: String, actual: String)
    case network(String)
    case missingCLI(String)

    public var errorDescription: String? {
        switch self {
        case .auth(let p, let h): "\(p.name) rejected the token for \(h). Log in again."
        case .notLoggedIn(let p, let h): "\(p == .gitlab ? "glab" : "gh") is not logged in to \(h). Check the host, or log in."
        case .rateLimited(let d): "Rate limited until \(d.formatted(date: .omitted, time: .shortened))"
        case .http(let c, let m): "HTTP \(c): \(m.prefix(160))"
        case .notFound: "Not found or no access"
        case .headMoved: "MR changed since review. Re-review before posting."
        case .network(let m): "Network: \(m)"
        case .missingCLI(let n): "\(n) not found"
        }
    }
    /// Errors that affect every request for the account, not just one MR.
    public var isAccountWide: Bool {
        switch self {
        case .auth, .notLoggedIn, .rateLimited, .network, .missingCLI: true
        default: false
        }
    }
    public var fixCommand: String? {
        if case .auth(let p, let host) = self { return p.loginCommand(host: host) }
        if case .notLoggedIn(let p, let host) = self { return p.loginCommand(host: host) }
        return nil
    }
    /// True when the request may have reached the server (POST outcome unknown → reconcile).
    public var uncertain: Bool {
        switch self {
        case .network: true
        case .http(let c, _): c >= 500
        default: false
        }
    }
}

// MARK: - Forge protocol (GitLab and GitHub share one adapter shape)

public struct ReviewBundle: Sendable {
    public var files: [DiffFile]
    public var complete: Bool
    public var incompleteReason: String?
    public var baseSHA: String?
    public var startSHA: String?
    public var headSHA: String
    public var contents: [String: String] = [:]   // path -> file content at head
    public init(files: [DiffFile], complete: Bool, incompleteReason: String? = nil, baseSHA: String?, startSHA: String?, headSHA: String) {
        self.files = files; self.complete = complete; self.incompleteReason = incompleteReason
        self.baseSHA = baseSHA; self.startSHA = startSHA; self.headSHA = headSHA
    }
}

public protocol Forge: AnyObject, Sendable {
    var account: Account { get }
    func currentUser() async throws -> String
    /// MRs matching the account's automatic scope rules (FR-2).
    func listInScope(username: String) async throws -> [MergeRequest]
    /// Open MRs in watched/team repos (listed as Discovered, never auto-queued).
    func listWatched() async throws -> [MergeRequest]
    /// Full detail: head SHA, pipeline, approvals, unresolved threads (FR-4).
    func fetch(_ ref: MRRef, username: String?) async throws -> MergeRequest
    func bundle(_ mr: MergeRequest, maxBytes: Int) async throws -> ReviewBundle
    func interdiff(_ mr: MergeRequest, from: String, to: String) async throws -> String?
    func threads(_ mr: MergeRequest) async throws -> [ExistingThread]
    func postInline(_ mr: MergeRequest, sha: String, anchor: Anchor, body: String) async throws
    func postGeneral(_ mr: MergeRequest, body: String) async throws
    func approve(_ mr: MergeRequest, sha: String) async throws
}

public func makeForge(_ a: Account) -> Forge {
    a.provider == .gitlab ? GitLabForge(account: a) : GitHubForge(account: a)
}

public func ref(_ mr: MergeRequest) -> MRRef {
    MRRef(provider: mr.provider, host: mr.host, projectPath: mr.projectPath, number: mr.number)
}

// MARK: - HTTP with conditional requests and rate-limit back-off (FR-3)

public final class HTTPClient: @unchecked Sendable {
    let account: Account
    private var token: String?
    private var etags: [String: (etag: String, data: Data)] = [:]
    private let lock = NSLock()
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    init(account: Account) { self.account = account }

    /// Pulls the value from a `Token: …` line of `glab auth status --show-token`; ignores masked output.
    static func tokenLine(_ s: String) -> String? {
        for line in s.split(separator: "\n") {
            guard let r = line.range(of: "Token: ") else { continue }
            let v = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if !v.isEmpty, !v.contains("*") { return v }
        }
        return nil
    }

    func resolveToken(refresh: Bool = false) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let token, !refresh { return token }
        var t: String?
        if account.useCLIAuth {
            let (cli, args) = account.provider == .gitlab
                ? ("glab", ["config", "get", "token", "--host", account.host])
                : ("gh", ["auth", "token", "--hostname", account.host])
            guard let path = Shell.which(cli) else { throw ForgeError.missingCLI(cli) }
            // glab's browser-login token expires after ~2 h and only glab refreshes it; any glab API call does.
            if refresh, account.provider == .gitlab {
                _ = try? Shell.capture([path, "api", "user", "--hostname", account.host])
            }
            if let out = try? Shell.capture([path] + args), out.status == 0 {
                t = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // glab can keep the token in the macOS keychain, where `config get` returns nothing.
            if account.provider == .gitlab, t?.isEmpty ?? true,
               let out = try? Shell.capture([path, "auth", "status", "--hostname", account.host, "--show-token"]) {
                t = Self.tokenLine(out.stdout + "\n" + out.stderr)
            }
            guard let t, !t.isEmpty else { throw ForgeError.notLoggedIn(account.provider, account.host) }
        } else {
            t = Keychain.token(Keychain.key(account))
        }
        guard let t, !t.isEmpty else { throw ForgeError.auth(account.provider, account.host) }
        token = t
        return t
    }

    public func request(_ method: String, _ url: String, json: Any? = nil, accept: String? = nil, retried: Bool = false) async throws -> (Data, HTTPURLResponse) {
        guard let u = URL(string: url.hasPrefix("http") ? url : account.apiBase + url) else { throw ForgeError.http(0, "bad url \(url)") }
        var req = URLRequest(url: u)
        req.httpMethod = method
        let tok = try resolveToken()
        // Bearer works for GitLab personal access tokens and for glab's OAuth tokens; PRIVATE-TOKEN rejects OAuth.
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        if account.provider == .github { req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version") }
        req.setValue(accept ?? "application/json", forHTTPHeaderField: "Accept")
        req.setValue("ReviewBar", forHTTPHeaderField: "User-Agent")
        let cacheKey = u.absoluteString
        if method == "GET", let cached = lock.withLock({ etags[cacheKey] }) {
            req.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, resp: HTTPURLResponse
        do {
            let (d, r) = try await session.data(for: req)
            guard let h = r as? HTTPURLResponse else { throw ForgeError.network("no response") }
            data = d; resp = h
        } catch let e as ForgeError { throw e }
        catch { throw ForgeError.network(error.localizedDescription) }

        switch resp.statusCode {
        case 304:
            if let cached = lock.withLock({ etags[cacheKey] }) { return (cached.data, resp) }
            throw ForgeError.http(304, "stale cache")
        case 200..<300:
            if method == "GET", let tag = resp.value(forHTTPHeaderField: "ETag") {
                lock.withLock { etags[cacheKey] = (tag, data) }
            }
            return (data, resp)
        case 401:
            if !retried { _ = try? resolveToken(refresh: true); return try await request(method, url, json: json, accept: accept, retried: true) }
            throw ForgeError.auth(account.provider, account.host)
        case 403 where resp.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0", 429:
            let reset = resp.value(forHTTPHeaderField: "retry-after").flatMap(Double.init).map { Date().addingTimeInterval($0) }
                ?? resp.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
                ?? Date().addingTimeInterval(300)
            throw ForgeError.rateLimited(reset)
        case 404: throw ForgeError.notFound
        default:
            throw ForgeError.http(resp.statusCode, String(decoding: data.prefix(400), as: UTF8.self))
        }
    }

    func getJSON(_ url: String) async throws -> Any {
        let (d, _) = try await request("GET", url)
        return try JSONSerialization.jsonObject(with: d)
    }

    /// Follows page numbers until a short page (both forges support page/per_page).
    func getPages(_ url: String, limit: Int = 30) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        let sep = url.contains("?") ? "&" : "?"
        for page in 1...limit {
            let arr = try await getJSON("\(url)\(sep)per_page=100&page=\(page)") as? [[String: Any]] ?? []
            out += arr
            if arr.count < 100 { break }
        }
        return out
    }
}

func iso(_ s: Any?) -> Date {
    guard let s = s as? String else { return Date() }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s) ?? Date()
}

func enc(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
}

/// Unified diff text for the engine and the anchor index.
public func unifiedPatch(_ files: [DiffFile]) -> String {
    files.map { f in "diff --git a/\(f.oldPath) b/\(f.newPath)\n--- a/\(f.oldPath)\n+++ b/\(f.newPath)\n\(f.diff)" }.joined(separator: "\n")
}
