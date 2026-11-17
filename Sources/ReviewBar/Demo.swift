import AppKit
import SwiftUI
import ReviewBarCore

/// `--demo`: realistic sample data in a throwaway store, a fake forge and a fake engine. No network, no tokens.
enum Demo {
    static let accountID = UUID(uuidString: "00000000-0000-0000-0000-00000000DE70")!

    static let diffs: [DiffFile] = [
        DiffFile(oldPath: "src/billing/sync.service.ts", newPath: "src/billing/sync.service.ts",
                 diff: "@@ -128,6 +128,24 @@ export class SyncService {\n" + (128..<152).map { $0 < 131 ? " ctx\($0)" : "+line\($0)" }.joined(separator: "\n")),
        DiffFile(oldPath: "src/billing/stripe.client.ts", newPath: "src/billing/stripe.client.ts",
                 diff: "@@ -50,4 +50,12 @@\n" + (50..<62).map { $0 < 52 ? " ctx\($0)" : "+line\($0)" }.joined(separator: "\n")),
        DiffFile(oldPath: "src/billing/webhook.controller.ts", newPath: "src/billing/webhook.controller.ts",
                 diff: "@@ -15,3 +15,10 @@\n" + (15..<25).map { $0 < 17 ? " ctx\($0)" : "+line\($0)" }.joined(separator: "\n")),
    ]

    static func f(_ s: Severity, _ path: String, _ line: Int?, _ title: String, _ body: String, engine: EngineKind = .claude) -> Finding {
        var x = Finding(severity: s, path: path, line: line, title: title, body: body)
        x.engines = [engine]; x.confidence = 0.8
        return x
    }

    static var billingFindings: [Finding] {
        [
            f(.blocker, "src/billing/sync.service.ts", 142, "Sync can double-charge on retry",
              "The retry loop re-sends `createInvoice` after a timeout without checking whether the first call succeeded. Pass the sync id as an idempotency key or look up the invoice before retrying."),
            f(.blocker, "src/billing/stripe.client.ts", 58, "Missing idempotency key on charge",
              "`charges.create` is called without `idempotencyKey`. Network retries in the client will create duplicate charges."),
            f(.shouldFix, "src/billing/sync.service.ts", 147, "Swallowed error hides failed syncs",
              "The catch block logs at debug level and returns `ok`. Failed syncs will never surface in alerts. Re-throw or record a failed status."),
            { var x = f(.shouldFix, "src/billing/webhook.controller.ts", 22, "Webhook signature is not verified",
              "The handler parses the body before calling `constructEvent`, so unsigned requests are accepted. Verify the signature on the raw body first."); x.security = true; return x }(),
            f(.optional, "src/billing/sync.service.ts", 135, "Extract the retry policy",
              "Max attempts and delay are inlined in two places. A shared constant keeps them in sync."),
            f(.optional, "src/billing/sync.service.ts", 310, "Batch size is not configurable",
              "Line is outside the changed hunks, so this cannot be anchored inline."),
            f(.nit, "src/billing/sync.service.ts", 139, "Typo in log message", "\"recieved\" → \"received\"."),
        ]
    }

    static func mr(_ repo: String, _ n: Int, _ title: String, _ author: String, ago: TimeInterval, provider: Provider = .gitlab,
                   pipeline: PipelineStatus = .success, sha: String? = nil) -> MergeRequest {
        let host = provider == .gitlab ? "gitlab.example.com" : "github.com"
        let path = "acme/\(repo)"
        var m = MergeRequest(provider: provider, host: host, projectPath: path, projectID: path, number: n, title: title, author: author,
                             webURL: provider == .gitlab ? "https://\(host)/\(path)/-/merge_requests/\(n)" : "https://\(host)/\(path)/pull/\(n)",
                             headSHA: sha ?? String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(40)),
                             updatedAt: Date().addingTimeInterval(-ago))
        m.authorName = author.capitalized.replacingOccurrences(of: ".", with: " ")
        m.sourceBranch = "feature/\(title.lowercased().split(separator: " ").prefix(3).joined(separator: "-"))"
        m.targetBranch = "main"
        m.pipeline = pipeline
        m.approvalsRequired = 2
        m.approvalsGiven = 1
        m.unresolvedThreads = n % 4
        m.scope = [.reviewRequested]
        m.baseSHA = "b4se"; m.startSHA = "st4rt"
        m.description = "Demo merge request."
        return m
    }

    @MainActor
    static func seed(_ model: AppModel) {
        let store = model.store
        var s = AppSettings()
        s.accounts = [Account(provider: .gitlab, host: "gitlab.example.com", useCLIAuth: true)]
        s.accounts[0].id = accountID
        model.settings = s

        func track(_ m: MergeRequest, _ f: (inout Tracked) -> Void) {
            var t = Tracked(mr: m); t.accountID = accountID; f(&t); store.save(t)
        }
        func completed(_ m: MergeRequest, findings: [Finding], ago: TimeInterval, engine: EngineKind = .claude, complete: Bool = true,
                       resolved: [Finding] = [], previous: String? = nil, reviewedSHA: String? = nil, _ f: (inout Tracked) -> Void = { _ in }) {
            var r = ReviewRun(mrID: m.id, engine: engine, sha: reviewedSHA ?? m.headSHA, logPath: store.runDir(UUID().uuidString).appendingPathComponent("run.log").path)
            r.startedAt = Date().addingTimeInterval(-ago - 190); r.endedAt = Date().addingTimeInterval(-ago)
            r.findings = prepare(findings, files: diffs, threads: [ExistingThread(path: "src/billing/sync.service.ts", line: 146, body: "Should this throw?", resolved: false)],
                                 preselect: [.blocker, .shouldFix])
            r.resolved = resolved; r.previousRunID = previous
            r.status = .completed; r.complete = complete; r.costUSD = 0.38
            r.incompleteReason = complete ? nil : "Diff capped at 1464 KB"
            r.verdict = !complete ? .incomplete : findings.isEmpty ? .clean : .findings
            r.summary = findings.isEmpty ? "Changes look correct and are covered by tests." : "Retry handling in the billing sync can double-charge; webhook input is trusted without verification."
            r.model = engine == .claude ? "claude-opus-5-5" : nil
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: r.logPath).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "[demo] \(engine.name) review of \(m.projectPath)\(m.ref) at \(m.headSHA)\nbundle: 3 files, complete=\(complete)\nexit 0\n".write(toFile: r.logPath, atomically: true, encoding: .utf8)
            store.save(r)
            track(m) {
                $0.run = .completed; $0.verdict = r.verdict; $0.reviewRunID = r.id; $0.reviewedSHA = r.sha
                $0.counts = SeverityCounts(r.findings); $0.decision = .needsDecision; $0.completedAt = r.endedAt
                f(&$0)
            }
        }

        let h = 3600.0
        completed(mr("payments-api", 628, "Add billing sync guard", "rmoss", ago: 840, sha: "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"), findings: billingFindings, ago: 600)
        completed(mr("web-app", 12762, "Migrate checkout to the new pricing API", "j.okafor", ago: 1.5 * h), findings: [], ago: 1.2 * h)
        completed(mr("design-tokens", 54, "Generate dark palette from tokens", "lina.v", ago: 3 * h, provider: .github),
                  findings: [f(.shouldFix, "src/billing/sync.service.ts", 144, "Contrast below 4.5:1 for muted text", "`--text-muted` on `--surface-2` is 3.9:1.")],
                  ago: 2.6 * h, complete: false)
        var resolvedOld = f(.blocker, "src/billing/sync.service.ts", 133, "Cache key ignores tenant", "Fixed in the last push."); resolvedOld.carry = .resolved
        var resolvedOld2 = f(.shouldFix, "src/billing/stripe.client.ts", 55, "Timeout too short", "Now 10 s."); resolvedOld2.carry = .resolved
        var still = f(.shouldFix, "src/billing/sync.service.ts", 149, "Partial failures still reported as success", "Same as before: the batch returns ok when one item fails.")
        still.carry = .stillOpen
        completed(mr("mobile-bff", 903, "Cache session lookups per tenant", "dev.ranga", ago: 0.4 * h), findings: [still], ago: 0.3 * h,
                  resolved: [resolvedOld, resolvedOld2], previous: "earlier")
        completed(mr("payments-api", 631, "Refund flow for partial captures", "rmoss", ago: 0.2 * h), findings: [billingFindings[2]], ago: 5 * h,
                  reviewedSHA: "0ld5ha00000000000000000000000000000000")
        completed(mr("search-api", 77, "Tokenizer handles CJK input", "m.haddad", ago: 26 * h), findings: [billingFindings[0], billingFindings[2]], ago: 27 * h) {
            $0.decision = .findingsPosted; $0.postedCount = 3; $0.decidedAt = Date().addingTimeInterval(-25 * h)
        }
        completed(mr("auth-gateway", 415, "Rotate signing keys without downtime", "p.nakamura", ago: 2 * h), findings: [], ago: 2.5 * h) {
            $0.decision = .approved; $0.decidedAt = Date().addingTimeInterval(-1.9 * h)
        }
        completed(mr("web-app", 12701, "Bump eslint config", "j.okafor", ago: 4 * h), findings: [billingFindings[6]], ago: 4 * h) {
            $0.decision = .dismissed; $0.decidedAt = Date().addingTimeInterval(-3 * h)
        }
        track(mr("orders-service", 2017, "Retry failed webhooks with backoff", "t.berg", ago: 50 * 60, pipeline: .failed)) {
            $0.run = .failed; $0.failure = "GitLab rejected the token for gitlab.example.com. Log in again."; $0.fixCommand = "glab auth login --hostname gitlab.example.com"
        }
        track(mr("inventory-svc", 341, "Reserve stock atomically", "a.silva", ago: 300)) {
            $0.run = .queued; $0.queueReason = .manual; $0.enqueuedAt = Date(); $0.queueOrder = 0
        }
        track(mr("web-app", 12780, "Lazy-load the order history page", "lina.v", ago: 700)) {
            $0.run = .queued; $0.queueReason = .newPush; $0.enqueuedAt = Date(); $0.queueOrder = 1
        }
        track(mr("notifications", 88, "Digest emails respect user timezone", "k.osei", ago: 1100)) {
            $0.run = .queued; $0.queueReason = .reviewRequested; $0.enqueuedAt = Date(); $0.queueOrder = 2
        }
        var watched = mr("analytics-etl", 12, "Partition events by day", "s.ito", ago: 6 * h); watched.scope = [.watched]
        track(watched) { $0.run = .discovered }
    }

    static func engine(_ mr: MergeRequest, previous: ReviewRun?) async -> EngineOutcome {
        try? await Task.sleep(nanoseconds: 20_000_000_000)
        if Task.isCancelled { return .failed("Cancelled", nil) }
        return .done(EngineResult(findings: Array(billingFindings.prefix(3)), previous: [:], summary: "Demo review.", costUSD: 0.21))
    }
}

final class DemoForge: Forge, @unchecked Sendable {
    let account: Account
    weak var model: AppModel?
    init(model: AppModel) {
        var a = Account(provider: .gitlab, host: "gitlab.example.com", useCLIAuth: true); a.id = Demo.accountID
        account = a; self.model = model
    }
    func currentUser() async throws -> String { "demo" }
    func listInScope(username: String) async throws -> [MergeRequest] { [] }
    func listWatched() async throws -> [MergeRequest] { [] }
    func fetch(_ ref: MRRef, username: String?) async throws -> MergeRequest {
        guard let mr = await MainActor.run(body: { model?.tracked(ref.id)?.mr }) else { throw ForgeError.notFound }
        return mr
    }
    func bundle(_ mr: MergeRequest, maxBytes: Int) async throws -> ReviewBundle {
        ReviewBundle(files: Demo.diffs, complete: true, baseSHA: "b4se", startSHA: "st4rt", headSHA: mr.headSHA)
    }
    func interdiff(_ mr: MergeRequest, from: String, to: String) async throws -> String? { nil }
    func threads(_ mr: MergeRequest) async throws -> [ExistingThread] {
        [ExistingThread(path: "src/billing/sync.service.ts", line: 146, body: "Should this throw?", resolved: false)]
    }
    func postInline(_ mr: MergeRequest, sha: String, anchor: ReviewBarCore.Anchor, body: String) async throws { try await Task.sleep(nanoseconds: 150_000_000) }
    func postGeneral(_ mr: MergeRequest, body: String) async throws { try await Task.sleep(nanoseconds: 150_000_000) }
    func approve(_ mr: MergeRequest, sha: String) async throws { try await Task.sleep(nanoseconds: 300_000_000) }
}

/// `--demo --snapshot DIR`: renders the main screens to PNGs (light and dark) for visual checks, then quits.
@MainActor
enum Snapshot {
    static func run(model: AppModel, router: WindowRouter, dir: String) {
        let out = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let pr = "gitlab:gitlab.example.com/acme/payments-api!628"
        let g = "gitlab:gitlab.example.com/acme/"
        let shots: [(String, Route)] = [
            ("inbox", .inbox), ("inbox-progress", .inbox), ("inbox-done", .inbox),
            ("detail", .detail(pr)), ("post", .post(pr)), ("approve", .approve(g + "web-app!12762")),
            ("outdated", .detail(g + "payments-api!631")),
            ("rereview", .detail(g + "mobile-bff!903")),
            ("failed", .detail(g + "orders-service!2017")),
            ("queued", .detail(g + "inventory-svc!341")),
            ("posted", .detail(g + "search-api!77")),
            ("approved", .detail(g + "auth-gateway!415")),
            ("dismissed", .detail(g + "web-app!12701")),
            ("notreviewed", .detail(g + "analytics-etl!12")),
        ]
        var steps: [() -> Void] = []
        for appearance in ["light", "dark"] {
            for (name, route) in shots {
                steps.append {
                    UserDefaults.standard.set(name == "inbox-progress" ? "progress" : name == "inbox-done" ? "done" : "decide", forKey: "reviewbar.inbox.tab")
                    model.route = route
                }
                steps.append { capture(RootView().environmentObject(model).environmentObject(router), size: NSSize(width: 380, height: 600),
                                       appearance: appearance, to: out.appendingPathComponent("\(name)-\(appearance).png")) }
            }
        }
        for appearance in ["light", "dark"] {
            for t in SettingsTab.allCases {
                steps.append { UserDefaults.standard.set(t.rawValue, forKey: "reviewbar.settings.tab") }
                steps.append { capture(SettingsView().environmentObject(model), size: NSSize(width: 620, height: 520), appearance: appearance,
                                       to: out.appendingPathComponent("settings-\(t.rawValue)-\(appearance).png")) }
            }
        }
        steps.append { NSApp.terminate(nil) }
        var i = 0
        func next() {
            guard i < steps.count else { return }
            steps[i](); i += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { next() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { next() }
    }

    static var windows: [NSWindow] = []

    static func capture<V: View>(_ view: V, size: NSSize, appearance: String, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        w.backgroundColor = appearance == "dark" ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)
        w.contentView = host
        w.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        w.orderFrontRegardless()
        windows.append(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            w.orderOut(nil)
        }
    }
}
