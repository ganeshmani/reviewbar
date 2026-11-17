import Foundation

public final class GitLabForge: Forge, @unchecked Sendable {
    public let account: Account
    let http: HTTPClient
    public init(account: Account) { self.account = account; self.http = HTTPClient(account: account) }

    private func project(_ mr: MergeRequest) -> String { "/projects/\(enc(mr.projectPath))" }
    private func mrPath(_ mr: MergeRequest) -> String { "\(project(mr))/merge_requests/\(mr.number)" }

    public func currentUser() async throws -> String {
        let u = try await http.getJSON("/user") as? [String: Any]
        guard let name = u?["username"] as? String else { throw ForgeError.auth(.gitlab, account.host) }
        return name
    }

    func parse(_ d: [String: Any]) -> MergeRequest? {
        guard let iid = d["iid"] as? Int, let full = (d["references"] as? [String: Any])?["full"] as? String else { return nil }
        let path = full.components(separatedBy: "!").first ?? full
        let author = d["author"] as? [String: Any]
        var mr = MergeRequest(provider: .gitlab, host: account.host, projectPath: path,
                              projectID: String(describing: d["project_id"] ?? path), number: iid,
                              title: d["title"] as? String ?? "", author: author?["username"] as? String ?? "",
                              webURL: d["web_url"] as? String ?? "", headSHA: d["sha"] as? String ?? "",
                              updatedAt: iso(d["updated_at"]))
        mr.authorName = author?["name"] as? String ?? mr.author
        mr.description = d["description"] as? String ?? ""
        mr.sourceBranch = d["source_branch"] as? String ?? ""
        mr.targetBranch = d["target_branch"] as? String ?? ""
        mr.isDraft = (d["draft"] as? Bool) ?? (d["work_in_progress"] as? Bool) ?? false
        mr.labels = d["labels"] as? [String] ?? []
        switch d["state"] as? String {
        case "merged": mr.state = .merged
        case "closed", "locked": mr.state = .closed
        default: mr.state = .open
        }
        if let refs = d["diff_refs"] as? [String: Any] {
            mr.baseSHA = refs["base_sha"] as? String
            mr.startSHA = refs["start_sha"] as? String
            if let h = refs["head_sha"] as? String { mr.headSHA = h }
        }
        if let p = d["head_pipeline"] as? [String: Any] { mr.pipeline = .from(p["status"] as? String) }
        return mr
    }

    public func listInScope(username: String) async throws -> [MergeRequest] {
        let s = account.scope
        var queries: [(String, ScopeReason)] = []
        if s.reviewRequested { queries.append(("reviewer_username=\(enc(username))", .reviewRequested)) }
        if s.assigned { queries.append(("assignee_username=\(enc(username))", .assigned)) }
        if s.authored { queries.append(("author_username=\(enc(username))", .authored)) }
        var byID: [String: MergeRequest] = [:]
        for (q, reason) in queries {
            for d in try await http.getPages("/merge_requests?state=opened&scope=all&\(q)", limit: 5) {
                guard var mr = parse(d) else { continue }
                mr.scope = (byID[mr.id]?.scope ?? []) + [reason]
                byID[mr.id] = mr
            }
        }
        return byID.values.filter { filterScope($0, s) }
    }

    public func listWatched() async throws -> [MergeRequest] {
        var out: [MergeRequest] = []
        for repo in account.scope.watchedRepos where !repo.isEmpty {
            for d in try await http.getPages("/projects/\(enc(repo))/merge_requests?state=opened", limit: 2) {
                if var mr = parse(d), filterScope(mr, account.scope) { mr.scope = [.watched]; out.append(mr) }
            }
        }
        return out
    }

    public func fetch(_ r: MRRef, username: String?) async throws -> MergeRequest {
        let base = "/projects/\(enc(r.projectPath))/merge_requests/\(r.number)"
        guard let d = try await http.getJSON(base) as? [String: Any], var mr = parse(d) else { throw ForgeError.notFound }
        if let a = try? await http.getJSON("\(base)/approvals") as? [String: Any] {
            let by = (a["approved_by"] as? [[String: Any]] ?? []).compactMap { ($0["user"] as? [String: Any])?["username"] as? String }
            mr.approvalsGiven = by.count
            mr.approvalsRequired = a["approvals_required"] as? Int ?? 0
            mr.approvedByMe = username.map { by.contains($0) } ?? false
        }
        mr.unresolvedThreads = (try? await threads(mr))?.filter { !$0.resolved }.count ?? 0
        return mr
    }

    public func bundle(_ mr: MergeRequest, maxBytes: Int) async throws -> ReviewBundle {
        // SHA-pinned: use the MR diff version whose head matches the SHA we review.
        let versions = try await http.getJSON("\(mrPath(mr))/versions") as? [[String: Any]] ?? []
        guard let v = versions.first(where: { $0["head_commit_sha"] as? String == mr.headSHA }), let vid = v["id"] as? Int,
              let detail = try await http.getJSON("\(mrPath(mr))/versions/\(vid)") as? [String: Any] else {
            throw ForgeError.headMoved(expected: mr.headSHA, actual: (versions.first?["head_commit_sha"] as? String) ?? "?")
        }
        var b = ReviewBundle(files: [], complete: true, baseSHA: v["base_commit_sha"] as? String,
                             startSHA: v["start_commit_sha"] as? String, headSHA: mr.headSHA)
        var bytes = 0
        for d in detail["diffs"] as? [[String: Any]] ?? [] {
            var f = DiffFile(oldPath: d["old_path"] as? String ?? "", newPath: d["new_path"] as? String ?? "", diff: d["diff"] as? String ?? "")
            f.newFile = d["new_file"] as? Bool ?? false
            f.deletedFile = d["deleted_file"] as? Bool ?? false
            f.renamed = d["renamed_file"] as? Bool ?? false
            if (d["too_large"] as? Bool) == true || (d["collapsed"] as? Bool) == true {
                b.complete = false; b.incompleteReason = "Diff for \(f.newPath) is too large and was collapsed"
            }
            bytes += f.diff.utf8.count
            if bytes > maxBytes { b.complete = false; b.incompleteReason = "Diff capped at \(maxBytes / 1024) KB"; break }
            b.files.append(f)
        }
        if (detail["real_size"] as? String)?.hasSuffix("+") == true {
            b.complete = false; b.incompleteReason = "GitLab truncated the file list (\(detail["real_size"]!))"
        }
        for f in b.files.prefix(40) where !f.deletedFile {
            if let (d, _) = try? await http.request("GET", "\(project(mr))/repository/files/\(enc(f.newPath))/raw?ref=\(mr.headSHA)", accept: "*/*"),
               d.count < 300_000 {
                b.contents[f.newPath] = String(decoding: d, as: UTF8.self)
            }
        }
        return b
    }

    public func interdiff(_ mr: MergeRequest, from: String, to: String) async throws -> String? {
        guard let c = try await http.getJSON("\(project(mr))/repository/compare?from=\(from)&to=\(to)&straight=true") as? [String: Any] else { return nil }
        let files = (c["diffs"] as? [[String: Any]] ?? []).map {
            DiffFile(oldPath: $0["old_path"] as? String ?? "", newPath: $0["new_path"] as? String ?? "", diff: $0["diff"] as? String ?? "")
        }
        return files.isEmpty ? nil : unifiedPatch(files)
    }

    public func threads(_ mr: MergeRequest) async throws -> [ExistingThread] {
        try await http.getPages("\(mrPath(mr))/discussions", limit: 10).compactMap { d in
            let notes = (d["notes"] as? [[String: Any]] ?? []).filter { ($0["system"] as? Bool) != true }
            guard let first = notes.first else { return nil }
            let resolvable = notes.contains { ($0["resolvable"] as? Bool) == true }
            let resolved = !resolvable || notes.allSatisfy { ($0["resolvable"] as? Bool) != true || ($0["resolved"] as? Bool) == true }
            let pos = first["position"] as? [String: Any]
            return ExistingThread(path: (pos?["new_path"] ?? pos?["old_path"]) as? String,
                                  line: (pos?["new_line"] ?? pos?["old_line"]) as? Int,
                                  body: notes.compactMap { $0["body"] as? String }.joined(separator: "\n"),
                                  resolved: resolved)
        }
    }

    public func postInline(_ mr: MergeRequest, sha: String, anchor: Anchor, body: String) async throws {
        guard let base = mr.baseSHA, let start = mr.startSHA else { throw ForgeError.http(0, "Missing diff refs") }
        var pos: [String: Any] = ["position_type": "text", "base_sha": base, "start_sha": start, "head_sha": sha,
                                  "old_path": anchor.oldPath, "new_path": anchor.newPath]
        if let n = anchor.newLine { pos["new_line"] = n }
        if let o = anchor.oldLine { pos["old_line"] = o }
        _ = try await http.request("POST", "\(mrPath(mr))/discussions", json: ["body": body, "position": pos])
    }

    public func postGeneral(_ mr: MergeRequest, body: String) async throws {
        _ = try await http.request("POST", "\(mrPath(mr))/notes", json: ["body": body])
    }

    public func approve(_ mr: MergeRequest, sha: String) async throws {
        // GitLab rejects the approval if `sha` is no longer the head: a server-side guard on top of ours.
        _ = try await http.request("POST", "\(mrPath(mr))/approve", json: ["sha": sha])
    }
}

func filterScope(_ mr: MergeRequest, _ s: Scope) -> Bool {
    if s.skipDrafts && mr.isDraft { return false }
    let labels = Set(mr.labels.map { $0.lowercased() })
    if !s.labelsInclude.isEmpty && labels.isDisjoint(with: s.labelsInclude.map { $0.lowercased() }) { return false }
    if !labels.isDisjoint(with: s.labelsExclude.map { $0.lowercased() }) { return false }
    return true
}
