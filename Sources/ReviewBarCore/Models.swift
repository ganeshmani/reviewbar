import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case gitlab, github
    public var name: String { self == .gitlab ? "GitLab" : "GitHub" }
    public var mrPrefix: String { self == .gitlab ? "!" : "#" }
    public var defaultHost: String { self == .gitlab ? "gitlab.com" : "github.com" }
    public func loginCommand(host: String) -> String {
        self == .gitlab ? "glab auth login --hostname \(host)" : "gh auth login --hostname \(host)"
    }
}

public enum MRState: String, Codable, Sendable { case open, merged, closed }

public enum PipelineStatus: String, Codable, Sendable {
    case none, pending, running, success, failed, canceled
    public var label: String {
        switch self {
        case .none: "No pipeline"
        case .pending: "Pipeline pending"
        case .running: "Pipeline running"
        case .success: "Pipeline passed"
        case .failed: "Pipeline failed"
        case .canceled: "Pipeline canceled"
        }
    }
    public static func from(_ raw: String?) -> PipelineStatus {
        switch raw?.lowercased() {
        case nil, "": .none
        case "success", "passed": .success
        case "failed", "failure", "timed_out", "action_required": .failed
        case "running", "in_progress": .running
        case "canceled", "cancelled", "skipped": .canceled
        default: .pending
        }
    }
}

public enum ScopeReason: String, Codable, Sendable { case reviewRequested, assigned, authored, watched, manual }

public struct MergeRequest: Codable, Identifiable, Equatable, Sendable {
    public var provider: Provider
    public var host: String
    public var projectPath: String      // group/sub/repo or owner/repo
    public var projectID: String        // GitLab numeric id, GitHub owner/repo
    public var number: Int
    public var title: String
    public var description: String = ""
    public var author: String
    public var authorName: String = ""
    public var webURL: String
    public var sourceBranch: String = ""
    public var targetBranch: String = ""
    public var headSHA: String
    public var baseSHA: String?
    public var startSHA: String?
    public var isDraft: Bool = false
    public var state: MRState = .open
    public var labels: [String] = []
    public var pipeline: PipelineStatus = .none
    public var approvalsGiven: Int = 0
    public var approvalsRequired: Int = 0
    public var approvedByMe: Bool = false
    public var unresolvedThreads: Int = 0
    public var updatedAt: Date
    public var scope: [ScopeReason] = []

    public init(provider: Provider, host: String, projectPath: String, projectID: String, number: Int, title: String,
                author: String, webURL: String, headSHA: String, updatedAt: Date) {
        self.provider = provider; self.host = host; self.projectPath = projectPath; self.projectID = projectID
        self.number = number; self.title = title; self.author = author; self.webURL = webURL
        self.headSHA = headSHA; self.updatedAt = updatedAt
    }

    public var id: String { MergeRequest.makeID(provider, host, projectPath, number) }
    public static func makeID(_ p: Provider, _ host: String, _ path: String, _ n: Int) -> String {
        "\(p.rawValue):\(host)/\(path)\(p.mrPrefix)\(n)"
    }
    public var repoShort: String { String(projectPath.split(separator: "/").last ?? Substring(projectPath)) }
    public var ref: String { "\(provider.mrPrefix)\(number)" }
}

public enum RunStatus: String, Codable, Sendable { case discovered, queued, running, completed, failed, interrupted, skipped }
public enum Verdict: String, Codable, Sendable { case findings, clean, incomplete }
public enum Decision: String, Codable, Sendable {
    case none, needsDecision, findingsPosted, approved, approvedWithComments, dismissed, handledManually
    public var label: String {
        switch self {
        case .none: ""
        case .needsDecision: "Needs decision"
        case .findingsPosted: "Waiting on author"
        case .approved: "Approved by you"
        case .approvedWithComments: "Approved with comments"
        case .dismissed: "Dismissed"
        case .handledManually: "Handled manually"
        }
    }
    public var isFinal: Bool { [.approved, .approvedWithComments, .dismissed, .handledManually].contains(self) }
}

public enum QueueReason: String, Codable, Sendable {
    case reviewRequested, assigned, authored, newPush, manual, rerun, secondOpinion, macBusy, retry
    public var label: String {
        switch self {
        case .reviewRequested: "review requested"
        case .assigned: "assigned"
        case .authored: "self-review"
        case .newPush: "new push"
        case .manual: "manual"
        case .rerun: "re-run"
        case .secondOpinion: "second opinion"
        case .macBusy: "Mac busy"
        case .retry: "retry"
        }
    }
    /// FR-7: manual > re-review > new request.
    public var priority: Int {
        switch self {
        case .manual, .rerun, .secondOpinion, .retry: 0
        case .newPush, .macBusy: 1
        default: 2
        }
    }
}

public enum EngineKind: String, Codable, CaseIterable, Sendable {
    case claude, codex
    public var name: String { self == .claude ? "Claude" : "Codex" }
}

public enum Severity: String, Codable, CaseIterable, Sendable, Comparable {
    case blocker, shouldFix = "should_fix", optional, nit
    public var rank: Int { Severity.allCases.firstIndex(of: self)! }
    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    public var label: String {
        switch self { case .blocker: "Blocker"; case .shouldFix: "Should-fix"; case .optional: "Optional"; case .nit: "Nit" }
    }
}

public enum Side: String, Codable, Sendable { case new, old }
public enum Carry: String, Codable, Sendable { case new, stillOpen = "still_open", regressed, resolved }

/// Exact diff position a finding can be posted to. Never invented: only built from the reviewed diff.
public struct Anchor: Codable, Hashable, Sendable {
    public var oldPath: String
    public var newPath: String
    public var newLine: Int?
    public var oldLine: Int?
}

public struct Finding: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var severity: Severity
    public var path: String
    public var line: Int?
    public var side: Side = .new
    public var title: String
    public var body: String
    public var evidence: String?
    public var confidence: Double?
    public var security: Bool = false
    public var engines: [EngineKind] = []
    public var alreadyDiscussed: Bool = false
    public var anchor: Anchor?
    public var carry: Carry?
    public var previousID: String?
    public var selected: Bool = false
    public var posted: Bool = false

    public init(id: String = UUID().uuidString, severity: Severity, path: String, line: Int?, title: String, body: String) {
        self.id = id; self.severity = severity; self.path = path; self.line = line; self.title = title; self.body = body
    }
    public var location: String { line.map { "\(path):\($0)" } ?? path }
}

public struct SeverityCounts: Codable, Equatable, Sendable {
    public var blocker = 0, shouldFix = 0, optional = 0, nit = 0
    public init() {}
    public init(_ findings: [Finding]) {
        for f in findings {
            switch f.severity {
            case .blocker: blocker += 1
            case .shouldFix: shouldFix += 1
            case .optional: optional += 1
            case .nit: nit += 1
            }
        }
    }
    public var total: Int { blocker + shouldFix + optional + nit }
    public var summary: String {
        var parts: [String] = []
        if blocker > 0 { parts.append("\(blocker) blocker\(blocker == 1 ? "" : "s")") }
        if shouldFix > 0 { parts.append("\(shouldFix) should-fix") }
        if optional > 0 { parts.append("\(optional) optional") }
        if nit > 0 { parts.append("\(nit) nit\(nit == 1 ? "" : "s")") }
        return parts.isEmpty ? "No issues found" : parts.joined(separator: ", ")
    }
    /// Short form for rows: blockers and should-fix only.
    public var short: String {
        var parts: [String] = []
        if blocker > 0 { parts.append("\(blocker) blocker\(blocker == 1 ? "" : "s")") }
        if shouldFix > 0 { parts.append("\(shouldFix) should-fix") }
        if parts.isEmpty { parts.append("\(optional + nit) minor") }
        return parts.joined(separator: " · ")
    }
}

public struct ReviewRun: Codable, Identifiable, Sendable {
    public var id: String
    public var mrID: String
    public var engine: EngineKind
    public var model: String?
    public var sha: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: RunStatus            // running / completed / failed / interrupted
    public var verdict: Verdict?
    public var findings: [Finding] = []
    public var resolved: [Finding] = []     // re-review: earlier findings now resolved
    public var summary: String?
    public var complete: Bool = true
    public var incompleteReason: String?
    public var error: String?
    public var exitCode: Int32?
    public var costUSD: Double?
    public var previousRunID: String?
    public var secondOpinionOf: String?
    public var logPath: String

    public init(id: String = UUID().uuidString, mrID: String, engine: EngineKind, sha: String, logPath: String) {
        self.id = id; self.mrID = mrID; self.engine = engine; self.sha = sha
        self.startedAt = Date(); self.status = .running; self.logPath = logPath
    }
    public var isReReview: Bool { previousRunID != nil }
    public var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}

/// Local state for one tracked MR. Run status and decision status are separate axes (PRD 5.1).
public struct Tracked: Codable, Identifiable, Sendable {
    public var mr: MergeRequest
    public var id: String { mr.id }
    public var run: RunStatus = .discovered
    public var verdict: Verdict?
    public var decision: Decision = .none
    public var queueReason: QueueReason?
    public var queueOrder: Double = 0
    public var priorityOverride: Int?       // set when the user drags a queued row
    public var enqueuedAt: Date?
    public var notBefore: Date?
    public var engine: EngineKind = .claude
    public var currentRunID: String?
    public var reviewRunID: String?
    public var reviewedSHA: String?
    public var counts: SeverityCounts?
    public var failure: String?
    public var fixCommand: String?
    public var postedCount: Int = 0
    public var decidedAt: Date?
    public var decidedSHA: String?
    public var completedAt: Date?
    public var snoozedUntil: Date?
    public var snoozeUntilPush: Bool = false
    public var nudged: Bool = false
    public var accountID: UUID?

    public init(mr: MergeRequest) { self.mr = mr }

    /// Completed review whose SHA no longer matches the head (PRD G5).
    public var isOutdated: Bool { reviewedSHA != nil && reviewedSHA != mr.headSHA }
    public var queuePriority: Int { priorityOverride ?? queueReason?.priority ?? 2 }
}

public struct AuditEntry: Codable, Identifiable, Sendable {
    public var id: Int64
    public var mrID: String
    public var at: Date
    public var sha: String
    public var action: String
    public var detail: String
}

public struct ExistingThread: Codable, Sendable {
    public var path: String?
    public var line: Int?
    public var body: String
    public var resolved: Bool
    public init(path: String?, line: Int?, body: String, resolved: Bool) {
        self.path = path; self.line = line; self.body = body; self.resolved = resolved
    }
}

public struct Scope: Codable, Equatable, Sendable {
    public var reviewRequested = true
    public var assigned = true
    public var authored = false
    public var skipDrafts = true
    public var watchedRepos: [String] = []
    public var labelsInclude: [String] = []
    public var labelsExclude: [String] = []
    public init() {}
}

public struct Account: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var provider: Provider
    public var host: String
    public var useCLIAuth: Bool
    public var username: String?
    public var enabled = true
    public var scope = Scope()
    public init(provider: Provider, host: String, useCLIAuth: Bool) {
        self.provider = provider; self.host = host; self.useCLIAuth = useCLIAuth
    }
    public var apiBase: String {
        switch provider {
        case .gitlab: "https://\(host)/api/v4"
        case .github: host == "github.com" ? "https://api.github.com" : "https://\(host)/api/v3"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var accounts: [Account] = []
    public var pollMinutes = 5
    public var defaultEngine: EngineKind = .claude
    public var claudeModel = ""
    public var codexModel = ""
    public var claudePath = ""
    public var codexPath = ""
    public var concurrency = 1
    public var timeoutMinutes = 20
    public var debounceMinutes = 10
    public var dailyCostCapUSD: Double = 0
    public var gateCommand = ""
    public var guidancePath = ""
    public var autoReviewPaused = false
    public var notifyCompleted = true
    public var notifyFailed = true
    public var notifyOutdated = true
    public var notifyReReview = true
    public var notifyQueued = false
    public var notifyMerged = false
    public var quietHoursEnabled = false
    public var quietStartMinutes = 20 * 60
    public var quietEndMinutes = 8 * 60
    public var digestEnabled = false
    public var digestMinutes = 9 * 60 + 30
    public var nudgeEnabled = true
    public var preselect: [Severity] = [.blocker, .shouldFix]
    public var neverPostSecurityInline = true
    public var hotkeyEnabled = true
    public init() {}

    // Tolerate settings files written by older versions (missing keys fall back to defaults).
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ k: CodingKeys, _ v: inout T) { if let x = try? c.decode(T.self, forKey: k) { v = x } }
        d(.accounts, &accounts); d(.pollMinutes, &pollMinutes); d(.defaultEngine, &defaultEngine)
        d(.claudeModel, &claudeModel); d(.codexModel, &codexModel); d(.claudePath, &claudePath); d(.codexPath, &codexPath)
        d(.concurrency, &concurrency); d(.timeoutMinutes, &timeoutMinutes); d(.debounceMinutes, &debounceMinutes)
        d(.dailyCostCapUSD, &dailyCostCapUSD); d(.gateCommand, &gateCommand); d(.guidancePath, &guidancePath)
        d(.autoReviewPaused, &autoReviewPaused); d(.notifyCompleted, &notifyCompleted); d(.notifyFailed, &notifyFailed)
        d(.notifyOutdated, &notifyOutdated); d(.notifyReReview, &notifyReReview); d(.notifyQueued, &notifyQueued)
        d(.notifyMerged, &notifyMerged); d(.quietHoursEnabled, &quietHoursEnabled); d(.quietStartMinutes, &quietStartMinutes)
        d(.quietEndMinutes, &quietEndMinutes); d(.digestEnabled, &digestEnabled); d(.digestMinutes, &digestMinutes)
        d(.nudgeEnabled, &nudgeEnabled); d(.preselect, &preselect); d(.neverPostSecurityInline, &neverPostSecurityInline)
        d(.hotkeyEnabled, &hotkeyEnabled)
    }
}
