import Foundation

public final class GitHubForge: Forge, @unchecked Sendable {
    public let account: Account
    let http: HTTPClient
    public init(account: Account) { self.account = account; self.http = HTTPClient(account: account) }

    private func repo(_ mr: MergeRequest) -> String { "/repos/\(mr.projectPath)" }
    private var graphqlURL: String { account.host == "github.com" ? "https://api.github.com/graphql" : "https://\(account.host)/api/graphql" }

    public func currentUser() async throws -> String {
        guard let login = (try await http.getJSON("/user") as? [String: Any])?["login"] as? String else {
            throw ForgeError.auth(.github, account.host)
        }
        return login
    }

    /// Search results lack the head SHA; the poller fetches detail for new or updated items.
    func parseIssue(_ d: [String: Any]) -> MergeRequest? {
        guard let n = d["number"] as? Int, let repoURL = d["repository_url"] as? String else { return nil }
        let path = repoURL.components(separatedBy: "/repos/").last ?? repoURL
        var mr = MergeRequest(provider: .github, host: account.host, projectPath: path, projectID: path, number: n,
                              title: d["title"] as? String ?? "", author: (d["user"] as? [String: Any])?["login"] as? String ?? "",
                              webURL: d["html_url"] as? String ?? "", headSHA: "", updatedAt: iso(d["updated_at"]))
        mr.authorName = mr.author
        mr.isDraft = d["draft"] as? Bool ?? false
        mr.labels = (d["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return mr
    }

    public func listInScope(username: String) async throws -> [MergeRequest] {
        let s = account.scope
        var queries: [(String, ScopeReason)] = []
        if s.reviewRequested { queries.append(("user-review-requested:@me", .reviewRequested)) }
        if s.assigned { queries.append(("assignee:@me", .assigned)) }
        if s.authored { queries.append(("author:@me", .authored)) }
        var byID: [String: MergeRequest] = [:]
        for (q, reason) in queries {
            let query = enc("is:pr is:open archived:false \(q)")
            let res = try await http.getJSON("/search/issues?q=\(query)&per_page=100") as? [String: Any]
            for d in res?["items"] as? [[String: Any]] ?? [] {
                guard var mr = parseIssue(d) else { continue }
                mr.scope = (byID[mr.id]?.scope ?? []) + [reason]
                byID[mr.id] = mr
            }
        }
        return byID.values.filter { filterScope($0, s) }
    }

    public func listWatched() async throws -> [MergeRequest] {
        var out: [MergeRequest] = []
        for r in account.scope.watchedRepos where !r.isEmpty {
            for d in try await http.getPages("/repos/\(r)/pulls?state=open", limit: 2) {
                if var mr = parsePull(d, path: r), filterScope(mr, account.scope) { mr.scope = [.watched]; out.append(mr) }
            }
        }
        return out
    }

    func parsePull(_ d: [String: Any], path: String) -> MergeRequest? {
        guard let n = d["number"] as? Int else { return nil }
        let head = d["head"] as? [String: Any], base = d["base"] as? [String: Any]
        var mr = MergeRequest(provider: .github, host: account.host, projectPath: path, projectID: path, number: n,
                              title: d["title"] as? String ?? "", author: (d["user"] as? [String: Any])?["login"] as? String ?? "",
                              webURL: d["html_url"] as? String ?? "", headSHA: head?["sha"] as? String ?? "", updatedAt: iso(d["updated_at"]))
        mr.authorName = mr.author
        mr.description = d["body"] as? String ?? ""
        mr.sourceBranch = head?["ref"] as? String ?? ""
        mr.targetBranch = base?["ref"] as? String ?? ""
        mr.baseSHA = base?["sha"] as? String
        mr.isDraft = d["draft"] as? Bool ?? false
        mr.labels = (d["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        mr.state = d["merged_at"] is String ? .merged : (d["state"] as? String == "closed" ? .closed : .open)
        return mr
    }

    public func fetch(_ r: MRRef, username: String?) async throws -> MergeRequest {
        guard let d = try await http.getJSON("/repos/\(r.projectPath)/pulls/\(r.number)") as? [String: Any],
              var mr = parsePull(d, path: r.projectPath) else { throw ForgeError.notFound }
        if let reviews = try? await http.getPages("/repos/\(r.projectPath)/pulls/\(r.number)/reviews", limit: 3) {
            var latest: [String: String] = [:]
            for rv in reviews {
                guard let who = (rv["user"] as? [String: Any])?["login"] as? String, let st = rv["state"] as? String,
                      st != "COMMENTED" else { continue }
                latest[who] = st
            }
            mr.approvalsGiven = latest.values.filter { $0 == "APPROVED" }.count
            mr.approvedByMe = username.map { latest[$0] == "APPROVED" } ?? false
        }
        if !mr.headSHA.isEmpty, let checks = try? await http.getJSON("/repos/\(r.projectPath)/commits/\(mr.headSHA)/check-runs?per_page=100") as? [String: Any] {
            let runs = checks["check_runs"] as? [[String: Any]] ?? []
            let conclusions = runs.map { ($0["status"] as? String ?? "", $0["conclusion"] as? String ?? "") }
            if runs.isEmpty { mr.pipeline = .none }
            else if conclusions.contains(where: { ["failure", "timed_out", "action_required"].contains($0.1) }) { mr.pipeline = .failed }
            else if conclusions.contains(where: { $0.0 != "completed" }) { mr.pipeline = .running }
            else { mr.pipeline = .success }
        }
        mr.unresolvedThreads = (try? await threads(mr))?.filter { !$0.resolved }.count ?? 0
        return mr
    }

    public func bundle(_ mr: MergeRequest, maxBytes: Int) async throws -> ReviewBundle {
        guard let base = mr.baseSHA else { throw ForgeError.http(0, "Missing base SHA") }
        // compare base...head is pinned to the exact head SHA.
        var b = ReviewBundle(files: [], complete: true, baseSHA: base, startSHA: base, headSHA: mr.headSHA)
        var bytes = 0, total = 0
        pages: for page in 1...3 {
            guard let c = try await http.getJSON("\(repo(mr))/compare/\(base)...\(mr.headSHA)?per_page=100&page=\(page)") as? [String: Any] else { break }
            if page == 1, let mb = (c["merge_base_commit"] as? [String: Any])?["sha"] as? String { b.baseSHA = mb; b.startSHA = mb }
            let files = c["files"] as? [[String: Any]] ?? []
            for d in files {
                let name = d["filename"] as? String ?? ""
                var f = DiffFile(oldPath: d["previous_filename"] as? String ?? name, newPath: name, diff: d["patch"] as? String ?? "")
                let status = d["status"] as? String ?? ""
                f.newFile = status == "added"; f.deletedFile = status == "removed"; f.renamed = status == "renamed"
                if d["patch"] == nil, (d["changes"] as? Int ?? 0) > 0 {
                    b.complete = false; b.incompleteReason = "GitHub omitted the patch for \(name) (too large)"
                }
                bytes += f.diff.utf8.count
                if bytes > maxBytes { b.complete = false; b.incompleteReason = "Diff capped at \(maxBytes / 1024) KB"; break pages }
                b.files.append(f)
            }
            total += files.count
            if files.count < 100 { break }
            if page == 3 { b.complete = false; b.incompleteReason = "More than 300 files changed" }
        }
        for f in b.files.prefix(40) where !f.deletedFile {
            if let (d, _) = try? await http.request("GET", "\(repo(mr))/contents/\(f.newPath.split(separator: "/").map { enc(String($0)) }.joined(separator: "/"))?ref=\(mr.headSHA)",
                                                    accept: "application/vnd.github.raw"), d.count < 300_000 {
                b.contents[f.newPath] = String(decoding: d, as: UTF8.self)
            }
        }
        return b
    }

    public func interdiff(_ mr: MergeRequest, from: String, to: String) async throws -> String? {
        let (d, _) = try await http.request("GET", "\(repo(mr))/compare/\(from)...\(to)", accept: "application/vnd.github.diff")
        let s = String(decoding: d.prefix(1_000_000), as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    public func threads(_ mr: MergeRequest) async throws -> [ExistingThread] {
        let parts = mr.projectPath.split(separator: "/")
        guard parts.count == 2 else { return [] }
        let q = """
        query($o:String!,$n:String!,$num:Int!){repository(owner:$o,name:$n){pullRequest(number:$num){
          reviewThreads(first:100){nodes{isResolved path line originalLine comments(first:20){nodes{body}}}}
          comments(last:100){nodes{body}}}}}
        """
        let (d, _) = try await http.request("POST", graphqlURL, json: ["query": q, "variables": ["o": String(parts[0]), "n": String(parts[1]), "num": mr.number]])
        let root = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        let pr = ((root?["data"] as? [String: Any])?["repository"] as? [String: Any])?["pullRequest"] as? [String: Any]
        var out: [ExistingThread] = ((pr?["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).map { t in
            let bodies = ((t["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { $0["body"] as? String }
            return ExistingThread(path: t["path"] as? String, line: (t["line"] ?? t["originalLine"]) as? Int,
                                  body: bodies.joined(separator: "\n"), resolved: t["isResolved"] as? Bool ?? false)
        }
        // General comments count for dedupe (they carry our marker), not as unresolved threads.
        out += ((pr?["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap {
            ($0["body"] as? String).map { ExistingThread(path: nil, line: nil, body: $0, resolved: true) }
        }
        return out
    }

    public func postInline(_ mr: MergeRequest, sha: String, anchor: Anchor, body: String) async throws {
        let left = anchor.newLine == nil
        _ = try await http.request("POST", "\(repo(mr))/pulls/\(mr.number)/comments", json: [
            "body": body, "commit_id": sha, "path": left ? anchor.oldPath : anchor.newPath,
            "line": left ? anchor.oldLine! : anchor.newLine!, "side": left ? "LEFT" : "RIGHT",
        ])
    }

    public func postGeneral(_ mr: MergeRequest, body: String) async throws {
        _ = try await http.request("POST", "\(repo(mr))/issues/\(mr.number)/comments", json: ["body": body])
    }

    public func approve(_ mr: MergeRequest, sha: String) async throws {
        _ = try await http.request("POST", "\(repo(mr))/pulls/\(mr.number)/reviews", json: ["commit_id": sha, "event": "APPROVE"])
    }
}
