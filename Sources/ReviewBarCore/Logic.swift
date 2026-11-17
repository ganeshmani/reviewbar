import Foundation
import CryptoKit

// MARK: - Inbox grouping (PRD 5.2)

public enum InboxGroup: Int, CaseIterable, Sendable {
    case needsDecision, running, queued, outdated, waitingOnAuthor, failed, discovered, doneToday
    public var title: String {
        switch self {
        case .needsDecision: "Needs your decision"
        case .running: "Running"
        case .queued: "Queued"
        case .outdated: "Outdated"
        case .waitingOnAuthor: "Waiting on author"
        case .failed: "Failed"
        case .discovered: "Discovered"
        case .doneToday: "Done today"
        }
    }
}

public func inboxGroup(_ t: Tracked, now: Date = Date(), calendar: Calendar = .current) -> InboxGroup? {
    let doneToday = t.decidedAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false
    if t.mr.state != .open { return doneToday ? .doneToday : nil }
    if let s = t.snoozedUntil, s > now, t.run != .running { return nil }
    if t.snoozeUntilPush, t.run != .running { return nil }
    switch t.run {
    case .running: return .running
    case .queued: return t.reviewedSHA != nil && t.isOutdated && t.queueReason == .newPush ? .outdated : .queued
    case .failed, .interrupted: return .failed
    case .discovered: return .discovered
    case .skipped: return nil
    case .completed:
        if t.isOutdated { return .outdated }
        switch t.decision {
        case .needsDecision, .none: return .needsDecision
        case .findingsPosted: return .waitingOnAuthor
        default: return doneToday ? .doneToday : nil
        }
    }
}

/// Sort within a group. Needs decision: severity then age. Queued: priority, manual order, then FIFO.
public func sortForGroup(_ g: InboxGroup, _ items: [Tracked]) -> [Tracked] {
    switch g {
    case .needsDecision:
        return items.sorted {
            let a = $0.counts ?? SeverityCounts(), b = $1.counts ?? SeverityCounts()
            if a.blocker != b.blocker { return a.blocker > b.blocker }
            if a.shouldFix != b.shouldFix { return a.shouldFix > b.shouldFix }
            return ($0.completedAt ?? .distantFuture) < ($1.completedAt ?? .distantFuture)
        }
    case .queued:
        return items.sorted(by: queueOrder)
    default:
        return items.sorted { $0.mr.updatedAt > $1.mr.updatedAt }
    }
}

public func queueOrder(_ a: Tracked, _ b: Tracked) -> Bool {
    if a.queuePriority != b.queuePriority { return a.queuePriority < b.queuePriority }
    if a.queueOrder != b.queueOrder { return a.queueOrder < b.queueOrder }
    return (a.enqueuedAt ?? .distantPast) < (b.enqueuedAt ?? .distantPast)
}

// MARK: - MR URL parsing (J6)

public struct MRRef: Equatable, Sendable {
    public var provider: Provider
    public var host: String
    public var projectPath: String
    public var number: Int
    public var id: String { MergeRequest.makeID(provider, host, projectPath, number) }
}

public func parseMRURL(_ raw: String) -> MRRef? {
    guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          let host = url.host, ["http", "https"].contains(url.scheme ?? "") else { return nil }
    let parts = url.path.split(separator: "/").map(String.init)
    if let dash = parts.firstIndex(of: "-"), dash + 2 < parts.count, parts[dash + 1] == "merge_requests",
       let n = Int(parts[dash + 2]), dash >= 2 {
        return MRRef(provider: .gitlab, host: host, projectPath: parts[..<dash].joined(separator: "/"), number: n)
    }
    if parts.count >= 4, parts[2] == "pull", let n = Int(parts[3]) {
        return MRRef(provider: .github, host: host, projectPath: "\(parts[0])/\(parts[1])", number: n)
    }
    return nil
}

// MARK: - Diff anchors (FR-13: never invent an anchor)

public struct DiffFile: Codable, Sendable {
    public var oldPath: String
    public var newPath: String
    public var diff: String
    public var newFile = false
    public var deletedFile = false
    public var renamed = false
    public init(oldPath: String, newPath: String, diff: String) { self.oldPath = oldPath; self.newPath = newPath; self.diff = diff }
}

/// Lines visible in one file's diff. `new[n]` gives the old line for context lines (nil for added).
public struct FileAnchors: Sendable {
    public var new: [Int: Int?] = [:]
    public var removed: Set<Int> = []
    public init(diff: String) {
        var o = 0, n = 0, inHunk = false
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                // @@ -a,b +c,d @@
                let nums = line.split(separator: " ")
                if nums.count >= 3 {
                    o = Int(nums[1].dropFirst().split(separator: ",")[0]) ?? 0
                    n = Int(nums[2].dropFirst().split(separator: ",")[0]) ?? 0
                    inHunk = true
                }
                continue
            }
            guard inHunk else { continue }
            if line.hasPrefix("+") { new[n] = .some(nil); n += 1 }
            else if line.hasPrefix("-") { removed.insert(o); o += 1 }
            else if line.hasPrefix("\\") { continue }
            else if line.hasPrefix(" ") || line.isEmpty { new[n] = .some(o); n += 1; o += 1 }
        }
    }
}

public func anchor(for f: Finding, in files: [DiffFile]) -> Anchor? {
    guard let line = f.line, let file = files.first(where: { $0.newPath == f.path || $0.oldPath == f.path }) else { return nil }
    let idx = FileAnchors(diff: file.diff)
    if f.side == .old {
        return idx.removed.contains(line) ? Anchor(oldPath: file.oldPath, newPath: file.newPath, newLine: nil, oldLine: line) : nil
    }
    guard let old = idx.new[line] else { return nil }
    return Anchor(oldPath: file.oldPath, newPath: file.newPath, newLine: line, oldLine: old)
}

// MARK: - Finding post-processing

public let commentMarkerPrefix = "<!-- reviewbar:"

public func marker(_ f: Finding) -> String { "\(commentMarkerPrefix)\(f.id) -->" }

/// Comment body exactly as it will be posted. The hidden marker lets us dedupe and reconcile uncertain POSTs.
public func commentBody(_ f: Finding, includeLocation: Bool = false) -> String {
    var s = "**\(f.severity.label):** \(f.title)\n\n\(f.body)"
    if includeLocation { s = "`\(f.location)`\n\n" + s }
    return s + "\n\n" + marker(f)
}

func normalized(_ s: String) -> String {
    s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
}

/// A finding overlaps an existing thread when it is ours (marker), or an unresolved thread sits on the same file within 3 lines.
public func overlaps(_ f: Finding, _ t: ExistingThread) -> Bool {
    if t.body.contains(marker(f)) { return true }
    if let pid = f.previousID, t.body.contains("\(commentMarkerPrefix)\(pid) -->") { return true }
    guard !t.resolved, let p = t.path, p == f.path else { return false }
    if let a = f.line, let b = t.line { return abs(a - b) <= 3 }
    return normalized(t.body).contains(normalized(f.title))
}

public func looksSecurity(_ f: Finding) -> Bool {
    if f.security { return true }
    let s = (f.title + " " + f.body).lowercased()
    return ["security", "injection", "xss", "csrf", "secret", "credential", "vulnerab", "auth bypass", "ssrf", "rce", "signature", "unauthenticated", "privilege", "token leak", "sanitiz"].contains { s.contains($0) }
}

/// Apply anchors, already-discussed tags, security flags and default selection (PRD 5.3).
public func prepare(_ findings: [Finding], files: [DiffFile], threads: [ExistingThread], preselect: Set<Severity>) -> [Finding] {
    findings.map { f in
        var f = f
        f.anchor = anchor(for: f, in: files)
        f.security = looksSecurity(f)
        f.alreadyDiscussed = threads.contains { overlaps(f, $0) }
        f.selected = preselect.contains(f.severity) && !f.alreadyDiscussed && !f.security && f.carry != .resolved
        return f
    }.sorted { ($0.severity, $0.path, $0.line ?? 0) < ($1.severity, $1.path, $1.line ?? 0) }
}

private func < (a: (Severity, String, Int), b: (Severity, String, Int)) -> Bool {
    if a.0 != b.0 { return a.0 < b.0 }
    if a.1 != b.1 { return a.1 < b.1 }
    return a.2 < b.2
}

/// J7: merge a second engine's findings. Same file within 3 lines = "found by both".
public func mergeSecondOpinion(_ base: [Finding], _ other: [Finding]) -> [Finding] {
    var out = base
    for o in other {
        if let i = out.firstIndex(where: { $0.path == o.path && abs(($0.line ?? -99) - (o.line ?? -999)) <= 3 }) {
            for e in o.engines where !out[i].engines.contains(e) { out[i].engines.append(e) }
            if o.severity < out[i].severity { out[i].severity = o.severity }
        } else {
            out.append(o)
        }
    }
    return out
}

// MARK: - Engine output (FR-9)

public struct EngineResult: Sendable {
    public var findings: [Finding]
    public var previous: [String: Carry]
    public var summary: String?
    public var costUSD: Double?
    public init(findings: [Finding], previous: [String: Carry], summary: String?, costUSD: Double?) {
        self.findings = findings; self.previous = previous; self.summary = summary; self.costUSD = costUSD
    }
}

public enum EngineParseError: Error, LocalizedError {
    case noJSON(String), engineError(String)
    public var errorDescription: String? {
        switch self {
        case .noJSON(let s): "Engine output had no findings JSON: \(s.prefix(200))"
        case .engineError(let s): "Engine error: \(s.prefix(300))"
        }
    }
}

/// Accepts Claude's `--output-format json` wrapper (structured_output or result text) or a bare findings object.
public func parseEngineOutput(_ text: String, engine: EngineKind) throws -> EngineResult {
    var cost: Double?
    var payload: Any?
    if let obj = jsonObject(text) as? [String: Any] {
        if obj["findings"] != nil { payload = obj }
        else {
            cost = obj["total_cost_usd"] as? Double
            if (obj["is_error"] as? Bool) == true { throw EngineParseError.engineError(obj["result"] as? String ?? text) }
            if let s = obj["structured_output"] as? [String: Any] { payload = s }
            else if let r = obj["result"] as? String { payload = jsonObject(r) }
        }
    } else {
        payload = jsonObject(text)
    }
    guard let p = payload as? [String: Any], let raw = p["findings"] as? [[String: Any]] else { throw EngineParseError.noJSON(text) }
    let findings: [Finding] = raw.compactMap { d in
        guard let title = d["title"] as? String, let path = d["path"] as? String else { return nil }
        let sev = Severity(rawValue: (d["severity"] as? String ?? "").lowercased().replacingOccurrences(of: "-", with: "_")) ?? .optional
        var f = Finding(severity: sev, path: path, line: d["line"] as? Int, title: title, body: d["body"] as? String ?? "")
        f.side = Side(rawValue: d["side"] as? String ?? "new") ?? .new
        f.evidence = d["evidence"] as? String
        f.confidence = d["confidence"] as? Double
        f.security = d["security"] as? Bool ?? false
        f.previousID = d["previous_id"] as? String
        f.engines = [engine]
        return f
    }
    var prev: [String: Carry] = [:]
    for d in p["previous"] as? [[String: Any]] ?? [] {
        if let id = d["id"] as? String, let c = Carry(rawValue: d["status"] as? String ?? "") { prev[id] = c }
    }
    return EngineResult(findings: findings, previous: prev, summary: p["summary"] as? String, costUSD: cost)
}

/// Parses a JSON object from text that may be wrapped in prose or ``` fences.
func jsonObject(_ text: String) -> Any? {
    if let d = text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) { return o }
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
    return try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))
}

/// FR-11: carry earlier findings forward. Returns (current findings, resolved earlier findings).
public func applyCarry(_ result: EngineResult, previous: [Finding]) -> ([Finding], [Finding]) {
    var current = result.findings.map { f -> Finding in
        var f = f
        if let pid = f.previousID, previous.contains(where: { $0.id == pid }) {
            f.carry = result.previous[pid] == .regressed ? .regressed : .stillOpen
        } else { f.carry = previous.isEmpty ? nil : .new }
        return f
    }
    var resolved: [Finding] = []
    for p in previous where p.carry != .resolved {
        let status = result.previous[p.id]
        let mentioned = current.contains { $0.previousID == p.id }
        if status == .resolved && !mentioned {
            var r = p; r.carry = .resolved; r.selected = false; resolved.append(r)
        } else if !mentioned, let status, status != .resolved {
            // Engine said still open but didn't restate it: keep the earlier finding.
            var k = p; k.carry = status == .regressed ? .regressed : .stillOpen; k.previousID = p.id
            k.id = UUID().uuidString; k.posted = false
            current.append(k)
        }
    }
    return (current, resolved)
}

public func reReviewSummary(_ run: ReviewRun) -> String {
    let resolved = run.resolved.count
    let open = run.findings.filter { $0.carry == .stillOpen || $0.carry == .regressed }.count
    let new = run.findings.filter { $0.carry == .new }.count
    return "\(resolved) of \(resolved + open) resolved, \(new) new"
}

// MARK: - Sharing and links

/// J8: Copy as Markdown.
public func markdownSummary(_ t: Tracked, run: ReviewRun?, findings: [Finding]) -> String {
    var s = "**[\(t.mr.repoShort) \(t.mr.ref)](\(t.mr.webURL))** \(t.mr.title)\n"
    if let run {
        s += "Reviewed `\(run.sha.prefix(8))` with \(run.engine.name): \(SeverityCounts(run.findings).summary)"
        if !run.complete { s += " _(partial review)_" }
        s += "\n"
    }
    for f in findings {
        s += "\n- **\(f.severity.label)** \(f.title) (`\(f.location)`)"
        let body = f.body.split(separator: "\n").first.map(String.init) ?? ""
        if !body.isEmpty { s += "\n  \(body)" }
    }
    return s
}

/// FR-15: deep link to the file and line in the browser diff.
public func deepLink(_ mr: MergeRequest, _ f: Finding) -> URL? {
    switch mr.provider {
    case .gitlab:
        let hash = Insecure.SHA1.hash(data: Data(f.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let lineAnchor = f.line.map { f.side == .old ? "_\($0)_" : "__\($0)" } ?? ""
        return URL(string: "\(mr.webURL)/diffs#\(hash)\(lineAnchor)")
    case .github:
        let hash = SHA256.hash(data: Data(f.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let lineAnchor = f.line.map { (f.side == .old ? "L" : "R") + String($0) } ?? ""
        return URL(string: "\(mr.webURL)/files#diff-\(hash)\(lineAnchor)")
    }
}

public func relative(_ date: Date, now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(date))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

public func elapsed(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
}

/// Quiet hours window in minutes since midnight; handles windows that cross midnight.
public func inQuietHours(_ minute: Int, start: Int, end: Int) -> Bool {
    start <= end ? (minute >= start && minute < end) : (minute >= start || minute < end)
}
