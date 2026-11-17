import AppKit
import SwiftUI
import ReviewBarCore

enum Route: Equatable {
    case inbox
    case detail(String)
    case post(String)
    case approve(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var items: [String: Tracked] = [:]
    @Published var settings: AppSettings { didSet { settingsChanged(oldValue) } }
    @Published var lastSync: Date?
    @Published var syncing = false
    @Published var offline = false
    @Published var accountErrors: [UUID: String] = [:]
    @Published var usernames: [UUID: String] = [:]
    /// Per-account note when some MRs could not be refreshed in the last sync (the rest still synced).
    @Published var skippedMRs: [UUID: String] = [:]
    /// MR ids already seen per inbox tab, so tabs can badge new arrivals. Memory only: a relaunch starts with nothing new.
    @Published var seenByTab: [String: Set<String>] = [:]
    @Published var route: Route = .inbox
    @Published var toast: String?
    @Published var selection: String?

    let store: Store
    let demo: Bool
    let notifier = Notifier()
    let power = PowerAssertion()
    private var forges: [UUID: Forge] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var backoff: [UUID: Date] = [:]
    private var timers: [Timer] = []
    private var lastDigestDay: Int?
    var onOpenDetail: ((String) -> Void)?

    private var settingsURL: URL { store.dir.appendingPathComponent("settings.json") }

    init(demo: Bool) {
        self.demo = demo
        let dir = demo ? FileManager.default.temporaryDirectory.appendingPathComponent("ReviewBar-Demo") : Store.defaultDir
        if demo { try? FileManager.default.removeItem(at: dir) }
        do { store = try Store(dir: dir) } catch { fatalError("Cannot open state store at \(dir.path): \(error)") }
        settings = AppSettings()
        if let d = try? Data(contentsOf: settingsURL), let s = try? JSONDecoder().decode(AppSettings.self, from: d) { settings = s }
        if demo { Demo.seed(self) }
        for t in store.loadTracked() { items[t.id] = t }
        recoverInterrupted()
        rebuildForges()
    }

    func start() {
        notifier.onOpen = { [weak self] id in self?.openDetail(id) }
        notifier.onSnooze = { [weak self] id in self?.snooze(id, until: Date().addingTimeInterval(3600)) }
        notifier.setup()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.poll(); self?.pump() }
        }
        scheduleTimers()
        if settings.autoReviewPaused { unqueueAutomatic() }
        if demo { lastSync = Date() } else { poll() }
        pump()
    }

    // MARK: - Derived state

    var visible: [InboxGroup: [Tracked]] {
        let now = Date()
        var g: [InboxGroup: [Tracked]] = [:]
        for t in items.values { if let k = inboxGroup(t, now: now) { g[k, default: []].append(t) } }
        for (k, v) in g { g[k] = sortForGroup(k, v) }
        return g
    }
    func count(_ g: InboxGroup) -> Int { visible[g]?.count ?? 0 }
    var runningCount: Int { items.values.filter { $0.run == .running }.count }
    var queuedSorted: [Tracked] { items.values.filter { $0.run == .queued }.sorted(by: queueOrder) }
    func queuePosition(_ id: String) -> Int? { queuedSorted.firstIndex { $0.id == id }.map { $0 + 1 } }
    var costToday: Double { store.runs(since: Calendar.current.startOfDay(for: Date())).compactMap(\.costUSD).reduce(0, +) }
    var capReached: Bool { settings.dailyCostCapUSD > 0 && costToday >= settings.dailyCostCapUSD }
    var autoBlocked: Bool { settings.autoReviewPaused || capReached }
    func run(_ id: String?) -> ReviewRun? { id.flatMap(store.run(id:)) }
    func runs(for mrID: String) -> [ReviewRun] { store.runs(mrID: mrID) }
    func tracked(_ id: String) -> Tracked? { items[id] }

    // MARK: - Persistence helpers

    private func put(_ t: Tracked) {
        items[t.id] = t
        store.save(t)
        updatePower()
    }

    private func mutate(_ id: String, _ f: (inout Tracked) -> Void) {
        guard var t = items[id] else { return }
        f(&t)
        put(t)
    }

    /// NFR reliability: runs that were in flight when the app quit become "Interrupted, retry".
    private func recoverInterrupted() {
        for var r in store.runningRuns() {
            r.status = .interrupted; r.error = "Interrupted, retry"; r.endedAt = Date()
            store.save(r)
        }
        for var t in items.values where t.run == .running {
            t.run = .interrupted; t.failure = "Interrupted, retry"; t.currentRunID = nil
            put(t)
        }
    }

    private func settingsChanged(_ old: AppSettings) {
        if let d = try? JSONEncoder().encode(settings) { try? d.write(to: settingsURL, options: .atomic) }
        if old.accounts != settings.accounts { rebuildForges() }
        if old.pollMinutes != settings.pollMinutes { scheduleTimers() }
        if !old.autoReviewPaused && settings.autoReviewPaused { unqueueAutomatic() }
        if old.autoReviewPaused != settings.autoReviewPaused || old.concurrency != settings.concurrency { pump() }
        if old.hotkeyEnabled != settings.hotkeyEnabled { HotKey.shared.setEnabled(settings.hotkeyEnabled) }
    }

    private func rebuildForges() {
        if demo { let f = DemoForge(model: self); forges = [Demo.accountID: f]; return }
        forges = Dictionary(uniqueKeysWithValues: settings.accounts.filter(\.enabled).map { ($0.id, makeForge($0)) })
    }

    private func forge(for t: Tracked) -> Forge? {
        if let id = t.accountID, let f = forges[id] { return f }
        return forges.values.first { $0.account.provider == t.mr.provider && $0.account.host == t.mr.host }
    }

    // MARK: - Timers

    private func scheduleTimers() {
        timers.forEach { $0.invalidate() }
        let interval = TimeInterval(max(2, min(30, settings.pollMinutes)) * 60)
        timers = [
            Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } },
            Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.pump() } },
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.minuteTick() } },
        ]
    }

    private func minuteTick() {
        let now = Date(), cal = Calendar.current
        let minute = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let needs = visible[.needsDecision] ?? []
        // FR-18 daily digest
        if settings.digestEnabled, minute == settings.digestMinutes, lastDigestDay != cal.component(.day, from: now) {
            lastDigestDay = cal.component(.day, from: now)
            let old = needs.filter { ($0.completedAt ?? now) < now.addingTimeInterval(-86400) }.count
            if !needs.isEmpty {
                notify(id: "digest", title: "\(needs.count) MR\(needs.count == 1 ? "" : "s") need your decision",
                       body: old > 0 ? "\(old) waiting over 24 h" : "Open ReviewBar to decide", actions: false)
            }
        }
        // D8: nudge once after 4 h without a decision, working hours only
        let weekday = cal.component(.weekday, from: now)
        if settings.nudgeEnabled, (2...6).contains(weekday), (9 * 60..<18 * 60).contains(minute) {
            for t in needs where !t.nudged && (t.completedAt ?? now) < now.addingTimeInterval(-4 * 3600) {
                mutate(t.id) { $0.nudged = true }
                notify(id: t.id, title: "Still waiting · \(t.mr.repoShort) \(t.mr.ref)",
                       body: "\(t.counts?.short ?? "Review done") · \(t.mr.title)", actions: true)
            }
        }
        // Archive merged/closed after 7 days
        for t in items.values where t.mr.state != .open && t.mr.updatedAt < now.addingTimeInterval(-7 * 86400) {
            items[t.id] = nil; store.deleteTracked(t.id)
        }
        objectWillChange.send()   // refresh relative times
    }

    // MARK: - Polling (FR-3, FR-4)

    func poll() {
        guard !syncing else { return }
        if demo { lastSync = Date(); return }
        syncing = true
        Task {
            var anyOK = false, anyNetwork = false
            for (id, forge) in forges {
                if let until = backoff[id], until > Date() { continue }
                do {
                    try await pollAccount(id, forge)
                    accountErrors[id] = nil; anyOK = true
                } catch let e as ForgeError {
                    if case .rateLimited(let until) = e { backoff[id] = until }
                    if case .network = e { anyNetwork = true }
                    accountErrors[id] = e.localizedDescription
                } catch {
                    accountErrors[id] = error.localizedDescription
                }
            }
            offline = anyNetwork && !anyOK
            if anyOK { lastSync = Date() }
            syncing = false
            pump()
        }
    }

    private func pollAccount(_ accountID: UUID, _ forge: Forge) async throws {
        let username: String
        if let u = usernames[accountID] { username = u } else { username = try await forge.currentUser(); usernames[accountID] = username }
        // First sync of an account: list the existing backlog as Not reviewed instead of queueing all of it.
        let backlog = !items.values.contains { $0.accountID == accountID }
        let inScope = try await forge.listInScope(username: username)
        let watched = (try? await forge.listWatched()) ?? []
        var seen = Set<String>()
        var skipped: [String] = []
        for var mr in inScope + watched.filter({ w in !inScope.contains { $0.id == w.id } }) {
            seen.insert(mr.id)
            let existing = items[mr.id]
            let needsDetail = existing == nil || mr.headSHA.isEmpty || existing!.mr.headSHA != mr.headSHA || existing!.mr.updatedAt != mr.updatedAt
            if needsDetail {
                let scope = mr.scope
                do {
                    mr = try await forge.fetch(ref(mr), username: username)
                } catch let e as ForgeError where e.isAccountWide {
                    throw e   // login, rate limit, network: the whole account is affected
                } catch {
                    // One broken MR (lost access, server error) must not stop the rest of the sync.
                    skipped.append("\(mr.repoShort) \(mr.ref)")
                    continue
                }
                mr.scope = scope
            } else if let e = existing {
                let scope = mr.scope; mr = e.mr; mr.scope = scope
            }
            ingest(mr, accountID: accountID, backlog: backlog)
        }
        if !skipped.isEmpty {
            skippedMRs[accountID] = "Couldn't refresh \(skipped.count) MR\(skipped.count == 1 ? "" : "s"): \(skipped.prefix(3).joined(separator: ", "))"
        } else {
            skippedMRs[accountID] = nil
        }
        // Tracked open MRs that left the lists: check whether they merged or closed.
        for t in items.values where t.accountID == accountID && t.mr.state == .open && !seen.contains(t.id) {
            if var mr = try? await forge.fetch(ref(t.mr), username: username) {
                mr.scope = t.mr.scope
                ingest(mr, accountID: accountID)
            }
        }
    }

    /// Apply a fresh MR snapshot: new MR → queue, new head → outdated + debounced re-review (FR-5, J4).
    func ingest(_ mr: MergeRequest, accountID: UUID?, manual: Bool = false, backlog: Bool = false) {
        // Automatic queueing: auto-review on, not the first-sync backlog, open (checked below) and not a draft.
        let autoQueue = !backlog && !settings.autoReviewPaused && !mr.isDraft
        var t = items[mr.id] ?? Tracked(mr: mr)
        let isNew = items[mr.id] == nil
        let oldScope = Set(t.mr.scope)
        let oldSHA = t.mr.headSHA
        let oldState = t.mr.state
        var mr = mr
        mr.scope = Array(Set(t.mr.scope + mr.scope + (manual ? [.manual] : [])))
        t.mr = mr
        t.accountID = accountID ?? t.accountID
        put(t)

        if mr.state != .open {
            if oldState == .open {
                if t.run == .queued { mutate(t.id) { $0.run = $0.reviewRunID == nil ? .skipped : .completed; $0.queueReason = nil } }
                tasks[t.id]?.cancel()
                if settings.notifyMerged && mr.state == .merged {
                    notify(id: t.id, title: "Merged · \(mr.repoShort) \(mr.ref)", body: mr.title, actions: false)
                }
            }
            return
        }
        // Moved back to draft while auto-queued: take it out again. Reviews you asked for stay.
        if mr.isDraft, t.run == .queued, t.queueReason != .manual {
            mutate(t.id) { $0.run = $0.reviewRunID == nil ? .discovered : .completed; $0.queueReason = nil; $0.notBefore = nil }
        }
        if isNew && !manual {
            let auto = mr.scope.first { $0 != .watched }
            if let auto, autoQueue {
                let reason: QueueReason = auto == .assigned ? .assigned : auto == .authored ? .authored : .reviewRequested
                enqueue(t.id, reason: reason)
            } else {
                mutate(t.id) { $0.run = .discovered }
            }
            return
        }
        // A watched/discovered MR that now requests my review gets queued like a new one.
        // Only a new request counts: backlog MRs left in Not reviewed stay there when auto-review is turned on.
        if autoQueue, t.run == .discovered, t.reviewRunID == nil,
           let auto = mr.scope.first(where: { [.reviewRequested, .assigned, .authored].contains($0) && !oldScope.contains($0) }) {
            enqueue(t.id, reason: auto == .assigned ? .assigned : auto == .authored ? .authored : .reviewRequested)
            return
        }
        if !oldSHA.isEmpty && oldSHA != mr.headSHA {
            mutate(t.id) { $0.snoozeUntilPush = false }
            if autoQueue && t.reviewedSHA != nil && t.run != .running {
                let decided = t.decision.isFinal || t.decision == .findingsPosted
                if decided && settings.notifyOutdated {
                    notify(id: t.id, title: "New commits on \(mr.repoShort) \(mr.ref)",
                           body: "Your earlier review is outdated, re-review queued", actions: true)
                }
                enqueue(t.id, reason: .newPush, notBefore: Date().addingTimeInterval(TimeInterval(settings.debounceMinutes * 60)))
            }
        }
    }

    // MARK: - Queue (FR-5 … FR-8a)

    /// Auto-review off: take back everything it queued. Reviews you asked for stay queued.
    func unqueueAutomatic() {
        for t in items.values where t.run == .queued && t.queueReason != .manual {
            mutate(t.id) { $0.run = $0.reviewRunID == nil ? .discovered : .completed; $0.queueReason = nil; $0.notBefore = nil }
        }
    }

    func enqueue(_ id: String, reason: QueueReason, engine: EngineKind? = nil, notBefore: Date? = nil) {
        guard var t = items[id], t.run != .running else { return }
        if t.run == .queued && reason == .newPush {   // already queued: just push the debounce out
            t.notBefore = notBefore; put(t); return
        }
        t.run = .queued
        t.queueReason = reason
        t.priorityOverride = nil
        t.enqueuedAt = Date()
        t.queueOrder = Date().timeIntervalSince1970
        t.notBefore = notBefore
        t.engine = engine ?? settings.defaultEngine
        t.failure = nil; t.fixCommand = nil
        t.snoozedUntil = nil
        put(t)
        if settings.notifyQueued && reason != .macBusy {
            notify(id: id, title: "Queued · \(t.mr.repoShort) \(t.mr.ref)", body: "\(reason.label) · \(t.mr.title)", actions: false)
        }
        pump()
    }

    func pump() {
        let slots = max(1, min(2, settings.concurrency)) - runningCount
        guard slots > 0 else { updatePower(); return }
        let now = Date()
        let ready = queuedSorted.filter { ($0.notBefore ?? .distantPast) <= now && (!autoBlocked || $0.queuePriority == 0) }
        for t in ready.prefix(slots) { start(t.id) }
        updatePower()
    }

    private func updatePower() {
        let busy = items.values.contains { $0.run == .running || $0.run == .queued }
        busy ? power.hold() : power.release()
    }

    func cancel(_ id: String) {
        if let task = tasks[id] { task.cancel(); return }
        mutate(id) { $0.run = $0.reviewRunID == nil ? .discovered : .completed; $0.queueReason = nil }
    }

    /// Drag-to-reorder (FR-7): place `id` just before `target`, adopting its priority.
    func moveQueued(_ id: String, before target: String) {
        guard id != target, let tgt = items[target], tgt.run == .queued else { return }
        mutate(id) { $0.priorityOverride = tgt.queuePriority; $0.queueOrder = tgt.queueOrder - 0.001 }
    }

    private func start(_ id: String) {
        guard var t = items[id] else { return }
        let dir = store.runDir(UUID().uuidString)
        var r = ReviewRun(id: dir.lastPathComponent, mrID: id, engine: t.engine, sha: t.mr.headSHA,
                          logPath: dir.appendingPathComponent("run.log").path)
        r.model = (t.engine == .claude ? settings.claudeModel : settings.codexModel).nilIfEmpty
        if t.queueReason == .secondOpinion { r.secondOpinionOf = t.reviewRunID }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store.save(r)                       // persisted before work starts: never lost (FR-8)
        t.run = .running; t.currentRunID = r.id; t.failure = nil
        put(t)
        tasks[id] = Task { [weak self] in
            await self?.perform(r, dir: dir)
            self?.tasks[id] = nil
            self?.pump()
        }
    }

    private func perform(_ initial: ReviewRun, dir: URL) async {
        var r = initial
        let id = r.mrID
        guard let t0 = items[id] else { return }
        guard let forge = forge(for: t0) else {
            return fail(id, &r, "No \(t0.mr.provider.name) account for \(t0.mr.host)", fix: nil)
        }
        do {
            let username = usernames[forge.account.id]
            var fresh = try await forge.fetch(ref(t0.mr), username: username)
            fresh.scope = t0.mr.scope
            mutate(id) { $0.mr = fresh }
            if fresh.state != .open {
                r.status = .skipped; r.endedAt = Date(); store.save(r)
                mutate(id) { $0.run = .skipped; $0.currentRunID = nil }
                return
            }
            r.sha = fresh.headSHA
            store.save(r)
            let secondOpinion = r.secondOpinionOf != nil
            let prev = secondOpinion ? nil : run(t0.reviewRunID).flatMap { $0.status == .completed && $0.sha != fresh.headSHA ? $0 : nil }
            r.previousRunID = prev?.id
            let bundle = try await forge.bundle(fresh, maxBytes: 1_500_000)
            r.complete = bundle.complete; r.incompleteReason = bundle.incompleteReason
            var mrForPost = fresh
            mrForPost.baseSHA = bundle.baseSHA ?? fresh.baseSHA
            mrForPost.startSHA = bundle.startSHA ?? fresh.startSHA
            mutate(id) { $0.mr.baseSHA = mrForPost.baseSHA; $0.mr.startSHA = mrForPost.startSHA }
            let interdiff = prev == nil ? nil : (try? await forge.interdiff(fresh, from: prev!.sha, to: fresh.headSHA)) ?? nil
            let threads = (try? await forge.threads(fresh)) ?? []

            let outcome: EngineOutcome
            if demo {
                outcome = await Demo.engine(fresh, previous: prev)
            } else {
                let exeName = r.engine == .claude ? "claude" : "codex"
                let configured = r.engine == .claude ? settings.claudePath : settings.codexPath
                let found = configured.isEmpty ? await Task.detached { Shell.which(exeName) }.value : nil
                guard let exe = configured.nilIfEmpty.map({ ($0 as NSString).expandingTildeInPath }) ?? found else {
                    return fail(id, &r, "\(exeName) CLI not found", fix: r.engine == .claude ? "npm install -g @anthropic-ai/claude-code" : "npm install -g @openai/codex")
                }
                let job = EngineJob(engine: r.engine, executable: exe, model: r.model ?? "", gate: Shell.split(settings.gateCommand),
                                    guidanceFile: settings.guidancePath, timeout: TimeInterval(settings.timeoutMinutes * 60),
                                    mr: fresh, bundle: bundle, previous: prev?.findings ?? [], interdiff: interdiff, dir: dir)
                outcome = await Engine.run(job)
            }

            switch outcome {
            case .macBusy:
                r.status = .skipped; r.error = "Mac busy"; r.endedAt = Date(); store.save(r)
                mutate(id) {
                    $0.run = .queued; $0.queueReason = .macBusy; $0.currentRunID = nil
                    $0.notBefore = Date().addingTimeInterval(60)
                }
            case .failed(let msg, let code):
                if Task.isCancelled || msg == "Cancelled" {
                    r.status = .failed; r.error = "Cancelled"; r.endedAt = Date(); store.save(r)
                    mutate(id) { $0.run = $0.reviewRunID == nil ? .discovered : .completed; $0.currentRunID = nil; $0.queueReason = nil }
                    return
                }
                r.exitCode = code
                fail(id, &r, msg, fix: nil)
            case .done(let result):
                complete(id, &r, result: result, bundle: bundle, threads: threads, previous: prev)
            }
        } catch let e as ForgeError {
            if case .headMoved = e {
                r.status = .skipped; r.error = "Head moved while bundling"; r.endedAt = Date(); store.save(r)
                mutate(id) { $0.run = .queued; $0.queueReason = .newPush; $0.currentRunID = nil; $0.notBefore = Date().addingTimeInterval(30) }
                return
            }
            if case .rateLimited(let until) = e {
                r.status = .skipped; r.error = e.localizedDescription; r.endedAt = Date(); store.save(r)
                mutate(id) { $0.run = .queued; $0.currentRunID = nil; $0.notBefore = until }
                return
            }
            fail(id, &r, e.localizedDescription, fix: e.fixCommand)
        } catch {
            fail(id, &r, error.localizedDescription, fix: nil)
        }
    }

    private func fail(_ id: String, _ r: inout ReviewRun, _ msg: String, fix: String?) {
        r.status = .failed; r.error = msg; r.endedAt = Date()
        store.save(r)
        appendLog(r, "Failed: \(msg)\n")
        mutate(id) { $0.run = .failed; $0.failure = msg; $0.fixCommand = fix; $0.currentRunID = nil }
        if settings.notifyFailed, let t = items[id] {
            notify(id: id, title: "Review failed · \(t.mr.repoShort) \(t.mr.ref)", body: msg, actions: false)
        }
    }

    private func appendLog(_ r: ReviewRun, _ s: String) {
        let url = URL(fileURLWithPath: r.logPath)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(s.utf8)); try? h.close() }
        else { try? s.write(to: url, atomically: true, encoding: .utf8) }
    }

    private func complete(_ id: String, _ r: inout ReviewRun, result: EngineResult, bundle: ReviewBundle, threads: [ExistingThread], previous: ReviewRun?) {
        let preselect = Set(settings.preselect)
        var (findings, resolved) = previous.map { applyCarry(result, previous: $0.findings) } ?? (result.findings, [])
        findings = prepare(findings, files: bundle.files, threads: threads, preselect: preselect)
        r.summary = result.summary; r.costUSD = result.costUSD; r.endedAt = Date(); r.status = .completed

        // J7: second opinion merges into the review it complements.
        if let baseID = r.secondOpinionOf, var base = run(baseID), base.sha == r.sha {
            let before = Set(base.findings.map(\.id))
            base.findings = prepare(mergeSecondOpinion(base.findings, findings), files: bundle.files, threads: threads, preselect: preselect)
            r.findings = findings; r.verdict = findings.isEmpty ? .clean : .findings
            store.save(r); store.save(base)
            let both = base.findings.filter { $0.engines.count > 1 }.count
            let added = base.findings.filter { !before.contains($0.id) }.count
            mutate(id) { $0.run = .completed; $0.currentRunID = nil; $0.counts = SeverityCounts(base.findings); $0.queueReason = nil }
            notify(id: id, title: "Second opinion · \(items[id]!.mr.repoShort) \(items[id]!.mr.ref)",
                   body: "\(r.engine.name): \(both) found by both, \(added) new", actions: true)
            return
        }

        r.findings = findings; r.resolved = resolved
        r.verdict = !r.complete ? .incomplete : findings.isEmpty ? .clean : .findings
        store.save(r)
        let counts = SeverityCounts(findings)
        mutate(id) {
            $0.run = .completed; $0.verdict = r.verdict; $0.reviewedSHA = r.sha; $0.reviewRunID = r.id
            $0.currentRunID = nil; $0.queueReason = nil; $0.decision = .needsDecision; $0.counts = counts
            $0.completedAt = Date(); $0.nudged = false; $0.decidedAt = nil; $0.postedCount = 0
        }
        guard let t = items[id] else { return }
        let label = "\(t.mr.repoShort) \(t.mr.ref)"
        if previous != nil {
            if settings.notifyReReview { notify(id: id, title: "Re-review \(label)", body: reReviewSummary(r), actions: true) }
        } else if settings.notifyCompleted {
            switch r.verdict {
            case .clean: notify(id: id, title: "Clean review · \(label)", body: "No issues found · ready to approve", actions: false)
            case .incomplete: notify(id: id, title: "Partial review · \(label)", body: "\(counts.summary) · \(r.incompleteReason ?? "diff incomplete")", actions: true)
            default: notify(id: id, title: "Review done · \(label)", body: "\(counts.summary) · \(t.mr.title)", actions: true)
            }
        }
        if t.mr.headSHA != r.sha {   // author pushed while we were reviewing
            enqueue(id, reason: .newPush, notBefore: Date().addingTimeInterval(TimeInterval(settings.debounceMinutes * 60)))
        }
    }

    // MARK: - Manual add (J6)

    func add(urlString: String) {
        guard let r = parseMRURL(urlString) else { showToast("Not a GitLab MR or GitHub PR URL"); return }
        if items[r.id] != nil {
            enqueue(r.id, reason: .manual); showToast("Queued \(r.projectPath)\(r.provider.mrPrefix)\(r.number) with priority"); return
        }
        guard let forge = forges.values.first(where: { $0.account.provider == r.provider && $0.account.host == r.host }) else {
            showToast("No \(r.provider.name) account for \(r.host). Add one in Settings."); return
        }
        Task {
            do {
                var mr = try await forge.fetch(r, username: usernames[forge.account.id])
                mr.scope = [.manual]
                ingest(mr, accountID: forge.account.id, manual: true)
                enqueue(mr.id, reason: .manual)
                showToast("Queued \(mr.repoShort) \(mr.ref) with priority")
            } catch {
                showToast("Couldn't add: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Decisions (FR-13 … FR-16)

    func updateFinding(_ runID: String, _ f: Finding) {
        guard var r = store.run(id: runID), let i = r.findings.firstIndex(where: { $0.id == f.id }) else { return }
        r.findings[i] = f
        store.save(r)
        objectWillChange.send()
    }

    struct PostCheck { var headOK: Bool; var head: String; var duplicates: [String]; var general: [String]; var local: [String] }

    /// Preview safety checks: head SHA unchanged, duplicates, unanchorable findings.
    func checkPost(_ id: String, findings: [Finding], allowGeneral: Bool) async throws -> PostCheck {
        guard let t = items[id], let forge = forge(for: t) else { throw ForgeError.notFound }
        let fresh = try await forge.fetch(ref(t.mr), username: usernames[forge.account.id])
        let threads = (try? await forge.threads(fresh)) ?? []
        let dup = findings.filter { f in threads.contains { overlaps(f, $0) } }.map(\.id)
        let noAnchor = findings.filter { $0.anchor == nil && !dup.contains($0.id) }.map(\.id)
        return PostCheck(headOK: fresh.headSHA == t.reviewedSHA, head: fresh.headSHA, duplicates: dup,
                         general: allowGeneral ? noAnchor : [], local: allowGeneral ? [] : noAnchor)
    }

    /// Posts selected findings. Refuses if the head moved. Reconciles uncertain POSTs before retrying.
    func post(_ id: String, findings: [Finding], allowGeneral: Bool) async throws -> Int {
        guard let t = items[id], let forge = forge(for: t), let reviewed = t.reviewedSHA, var r = run(t.reviewRunID) else { throw ForgeError.notFound }
        var fresh = try await forge.fetch(ref(t.mr), username: usernames[forge.account.id])
        guard fresh.headSHA == reviewed else {
            mutate(id) { $0.mr = fresh }
            throw ForgeError.headMoved(expected: reviewed, actual: fresh.headSHA)
        }
        fresh.baseSHA = t.mr.baseSHA ?? fresh.baseSHA
        fresh.startSHA = t.mr.startSHA ?? fresh.startSHA
        var threads = (try? await forge.threads(fresh)) ?? []
        var posted: [String] = [], skipped: [String] = []
        for f in findings {
            if threads.contains(where: { overlaps(f, $0) }) || (f.security && settings.neverPostSecurityInline) { skipped.append(f.id); continue }
            if f.anchor == nil && !allowGeneral { skipped.append(f.id); continue }
            let body = commentBody(f, includeLocation: f.anchor == nil)
            func send() async throws {
                if let a = f.anchor { try await forge.postInline(fresh, sha: reviewed, anchor: a, body: body) }
                else { try await forge.postGeneral(fresh, body: body) }
            }
            do { try await send() }
            catch let e as ForgeError where e.uncertain {
                threads = (try? await forge.threads(fresh)) ?? threads
                if !threads.contains(where: { $0.body.contains(marker(f)) }) { try await send() }
            }
            posted.append(f.id)
            if let i = r.findings.firstIndex(where: { $0.id == f.id }) { r.findings[i].posted = true; r.findings[i].body = f.body }
            store.save(r)
        }
        store.audit(mrID: id, sha: reviewed, action: "post_findings",
                    detail: "posted \(posted.count) [\(posted.joined(separator: ","))], skipped \(skipped.count)")
        mutate(id) {
            if posted.count > 0 { $0.decision = .findingsPosted }
            $0.postedCount += posted.count; $0.decidedAt = Date(); $0.decidedSHA = reviewed
        }
        route = .inbox
        showToast("Posted \(posted.count) comment\(posted.count == 1 ? "" : "s") · Undo not available, open in \(t.mr.provider.name)")
        return posted.count
    }

    func approve(_ id: String, override: Bool) async throws {
        guard let t = items[id], let forge = forge(for: t) else { throw ForgeError.notFound }
        let fresh = try await forge.fetch(ref(t.mr), username: usernames[forge.account.id])
        let risky = fresh.headSHA != t.reviewedSHA || t.verdict == .incomplete || t.reviewedSHA == nil
        if risky && !override { throw ForgeError.headMoved(expected: t.reviewedSHA ?? "", actual: fresh.headSHA) }
        let sha = override ? fresh.headSHA : t.reviewedSHA!
        try await forge.approve(fresh, sha: sha)
        let after = (try? await forge.fetch(ref(t.mr), username: usernames[forge.account.id])) ?? fresh
        store.audit(mrID: id, sha: sha, action: override ? "approve_override" : "approve",
                    detail: "approvals \(after.approvalsGiven) of \(after.approvalsRequired) required; pipeline \(after.pipeline.rawValue)")
        mutate(id) {
            var mr = after; mr.scope = $0.mr.scope; $0.mr = mr
            $0.decision = $0.postedCount > 0 ? .approvedWithComments : .approved
            $0.decidedAt = Date(); $0.decidedSHA = sha
        }
        route = .inbox
        let req = after.approvalsRequired > 0 ? " · \(after.approvalsGiven) of \(after.approvalsRequired) required approvals" : ""
        showToast("Approved \(t.mr.repoShort) \(t.mr.ref)\(req)")
    }

    /// Fresh MR state for confirmation sheets; also notices pushes (→ Outdated + re-review).
    func refresh(_ id: String) async throws -> MergeRequest {
        guard let t = items[id], let forge = forge(for: t) else { throw ForgeError.notFound }
        var mr = try await forge.fetch(ref(t.mr), username: usernames[forge.account.id])
        mr.scope = t.mr.scope
        mr.baseSHA = t.mr.baseSHA ?? mr.baseSHA
        mr.startSHA = t.mr.startSHA ?? mr.startSHA
        ingest(mr, accountID: t.accountID)
        return mr
    }

    func dismiss(_ id: String) { decide(id, .dismissed, "dismiss") }
    func markHandled(_ id: String) { decide(id, .handledManually, "mark_handled_manually") }

    private func decide(_ id: String, _ d: Decision, _ action: String) {
        guard let t = items[id] else { return }
        store.audit(mrID: id, sha: t.reviewedSHA ?? t.mr.headSHA, action: action)
        if t.run == .queued || t.run == .failed || t.run == .interrupted || t.run == .discovered {
            mutate(id) { $0.run = $0.reviewRunID == nil ? .skipped : .completed; $0.queueReason = nil }
        }
        mutate(id) { $0.decision = d; $0.decidedAt = Date(); $0.decidedSHA = $0.reviewedSHA }
        route = .inbox
    }

    func snooze(_ id: String, until: Date?) {
        store.audit(mrID: id, sha: items[id]?.mr.headSHA ?? "", action: until == nil ? "snooze_until_push" : "snooze",
                    detail: until.map { $0.formatted() } ?? "")
        mutate(id) { if let until { $0.snoozedUntil = until } else { $0.snoozeUntilPush = true } }
        if route != .inbox { route = .inbox }
    }

    func copyMarkdown(_ id: String, onlySelected: Bool = true) {
        guard let t = items[id] else { return }
        let r = run(t.reviewRunID)
        let fs = (r?.findings ?? []).filter { !onlySelected || $0.selected }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdownSummary(t, run: r, findings: fs), forType: .string)
        showToast("Copied as Markdown")
    }

    func copy(_ s: String, toast: String?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        if let toast { showToast(toast) }
    }

    func open(_ urlString: String) { if let u = URL(string: urlString) { NSWorkspace.shared.open(u) } }

    func openDetail(_ id: String) {
        route = .detail(id)
        onOpenDetail?(id)
    }

    func showToast(_ s: String) {
        toast = s
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); if toast == s { toast = nil } }
    }

    // MARK: - Notifications (FR-17 … FR-19)

    func notify(id: String, title: String, body: String, actions: Bool) {
        let now = Date(), cal = Calendar.current
        let minute = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let quiet = settings.quietHoursEnabled && inQuietHours(minute, start: settings.quietStartMinutes, end: settings.quietEndMinutes)
        notifier.post(thread: id, title: title, body: body, snoozable: actions, quiet: quiet)
    }

    // MARK: - Accounts

    func testAccount(_ a: Account) async -> String {
        do { let u = try await makeForge(a).currentUser(); usernames[a.id] = u; return "Connected as \(u)" }
        catch { return error.localizedDescription }
    }

    func exportAudit(to url: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted; enc.dateEncodingStrategy = .iso8601
        try enc.encode(store.auditLog()).write(to: url)
    }

    // MARK: - Menu bar icon state (FR-20)

    enum IconState: Equatable { case idle, running, needs(Int), failure(Int), paused }
    var iconState: IconState {
        let failed = count(.failed), needs = count(.needsDecision)
        if failed > 0 { return .failure(needs) }
        if runningCount > 0 { return .running }
        if settings.autoReviewPaused || capReached { return .paused }
        if needs > 0 { return .needs(needs) }
        return .idle
    }
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
