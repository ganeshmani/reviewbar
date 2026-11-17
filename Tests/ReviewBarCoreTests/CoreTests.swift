import Testing
import Foundation
@testable import ReviewBarCore

func mr(sha: String = "aaa") -> MergeRequest {
    MergeRequest(provider: .gitlab, host: "gitlab.com", projectPath: "acme/payments-api", projectID: "1", number: 628,
                 title: "Add billing sync guard", author: "rmoss", webURL: "https://gitlab.com/acme/payments-api/-/merge_requests/628",
                 headSHA: sha, updatedAt: Date())
}

@Test func parsesURLs() {
    #expect(parseMRURL("https://gitlab.com/acme/team/payments-api/-/merge_requests/628")
            == MRRef(provider: .gitlab, host: "gitlab.com", projectPath: "acme/team/payments-api", number: 628))
    #expect(parseMRURL("https://github.com/acme/web-app/pull/12762/files")
            == MRRef(provider: .github, host: "github.com", projectPath: "acme/web-app", number: 12762))
    #expect(parseMRURL("not a url") == nil)
}

let diff = """
@@ -10,4 +10,5 @@ class Sync
 context10
-removed11
+added11
+added12
 context12
"""

@Test func anchorsOnlyOnDiffLines() {
    let files = [DiffFile(oldPath: "src/a.ts", newPath: "src/a.ts", diff: diff)]
    var f = Finding(severity: .blocker, path: "src/a.ts", line: 11, title: "t", body: "b")
    #expect(anchor(for: f, in: files) == Anchor(oldPath: "src/a.ts", newPath: "src/a.ts", newLine: 11, oldLine: nil))
    f.line = 13   // context line: both sides
    #expect(anchor(for: f, in: files)?.oldLine == 12)
    f.line = 200  // outside the diff: never invent an anchor
    #expect(anchor(for: f, in: files) == nil)
    f.line = 11; f.side = .old
    #expect(anchor(for: f, in: files)?.oldLine == 11)
}

@Test func twoAxisGrouping() {
    var t = Tracked(mr: mr())
    t.run = .queued
    #expect(inboxGroup(t) == .queued)
    t.run = .completed; t.reviewedSHA = "aaa"; t.decision = .needsDecision
    #expect(inboxGroup(t) == .needsDecision)
    t.mr.headSHA = "bbb"                       // author pushed: outdated
    #expect(t.isOutdated && inboxGroup(t) == .outdated)
    t.run = .queued; t.queueReason = .newPush            // debounced re-review stays visible as Outdated
    #expect(inboxGroup(t) == .outdated)
    t.run = .completed
    t.mr.headSHA = "aaa"; t.decision = .findingsPosted
    #expect(inboxGroup(t) == .waitingOnAuthor)
    t.decision = .approved; t.decidedAt = Date()
    #expect(inboxGroup(t) == .doneToday)
    t.run = .interrupted
    #expect(inboxGroup(t) == .failed)
    t.run = .queued; t.snoozedUntil = Date().addingTimeInterval(3600)
    #expect(inboxGroup(t) == nil)
}

@Test func queuePriority() {
    var a = Tracked(mr: mr()); a.queueReason = .reviewRequested; a.enqueuedAt = Date(timeIntervalSince1970: 1)
    var b = a; b.mr.number = 2; b.queueReason = .manual; b.enqueuedAt = Date(timeIntervalSince1970: 5)
    var c = a; c.mr.number = 3; c.queueReason = .newPush; c.enqueuedAt = Date(timeIntervalSince1970: 3)
    #expect(sortForGroup(.queued, [a, b, c]).map(\.mr.number) == [2, 3, 628])
}

@Test func defaultSelectionAndDedupe() {
    let files = [DiffFile(oldPath: "src/a.ts", newPath: "src/a.ts", diff: diff)]
    let raw = [
        Finding(severity: .blocker, path: "src/a.ts", line: 11, title: "Null deref", body: ""),
        Finding(severity: .nit, path: "src/a.ts", line: 12, title: "Naming", body: ""),
        Finding(severity: .shouldFix, path: "src/b.ts", line: 40, title: "SQL injection in query", body: ""),
        Finding(severity: .shouldFix, path: "src/c.ts", line: 9, title: "Retry missing", body: ""),
    ]
    let threads = [ExistingThread(path: "src/c.ts", line: 10, body: "retry?", resolved: false)]
    let out = prepare(raw, files: files, threads: threads, preselect: [.blocker, .shouldFix])
    let by = Dictionary(uniqueKeysWithValues: out.map { ($0.title, $0) })
    #expect(by["Null deref"]!.selected && by["Null deref"]!.anchor != nil)
    #expect(!by["Naming"]!.selected)
    #expect(by["SQL injection in query"]!.security && !by["SQL injection in query"]!.selected)
    #expect(by["Retry missing"]!.alreadyDiscussed && !by["Retry missing"]!.selected)
    #expect(by["SQL injection in query"]!.anchor == nil)
}

@Test func parsesClaudeWrapperAndCarry() throws {
    let inner = #"{"summary":"s","findings":[{"severity":"blocker","path":"a.ts","line":3,"side":"new","title":"T","body":"B","evidence":null,"confidence":0.9,"security":false,"previous_id":"p1"}],"previous":[{"id":"p1","status":"still_open"},{"id":"p2","status":"resolved"}]}"#
    let wrapper = try String(data: JSONSerialization.data(withJSONObject: ["type": "result", "is_error": false, "result": "```json\n\(inner)\n```", "total_cost_usd": 0.42]), encoding: .utf8)!
    let r = try parseEngineOutput(wrapper, engine: .claude)
    #expect(r.findings.count == 1 && r.costUSD == 0.42 && r.findings[0].engines == [.claude])
    var p1 = Finding(id: "p1", severity: .blocker, path: "a.ts", line: 3, title: "T", body: "B"); p1.posted = true
    let p2 = Finding(id: "p2", severity: .shouldFix, path: "b.ts", line: 9, title: "U", body: "")
    let (cur, resolved) = applyCarry(r, previous: [p1, p2])
    #expect(cur[0].carry == .stillOpen && resolved.map(\.id) == ["p2"])
    var run = ReviewRun(mrID: "x", engine: .claude, sha: "b", logPath: ""); run.findings = cur; run.resolved = resolved
    #expect(reReviewSummary(run) == "1 of 2 resolved, 0 new")
}

@Test func secondOpinionMerge() {
    var a = Finding(severity: .shouldFix, path: "a.ts", line: 10, title: "x", body: ""); a.engines = [.claude]
    var b = Finding(severity: .blocker, path: "a.ts", line: 12, title: "y", body: ""); b.engines = [.codex]
    var c = Finding(severity: .nit, path: "z.ts", line: 1, title: "z", body: ""); c.engines = [.codex]
    let m = mergeSecondOpinion([a], [b, c])
    #expect(m.count == 2 && m[0].engines == [.claude, .codex] && m[0].severity == .blocker)
}

@Test func storeSurvivesReopen() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    do {
        let s = try Store(dir: dir)
        var t = Tracked(mr: mr()); t.run = .queued
        s.save(t)
        s.save(ReviewRun(mrID: t.id, engine: .claude, sha: "aaa", logPath: ""))
        s.audit(mrID: t.id, sha: "aaa", action: "approve")
    }
    let s = try Store(dir: dir)
    #expect(s.loadTracked().first?.run == .queued)
    #expect(s.runningRuns().count == 1)
    #expect(s.auditLog().first?.action == "approve")
}

@Test func misc() {
    #expect(inQuietHours(23 * 60, start: 20 * 60, end: 8 * 60))
    #expect(!inQuietHours(12 * 60, start: 20 * 60, end: 8 * 60))
    #expect(Shell.split("gate run --slots 2 -- ") == ["gate", "run", "--slots", "2", "--"])
    let f = Finding(id: "F1", severity: .blocker, path: "a", line: 1, title: "t", body: "b")
    #expect(overlaps(f, ExistingThread(path: nil, line: nil, body: commentBody(f), resolved: true)))
}

@Test func gateExit75RequeuesNotFails() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bundle = ReviewBundle(files: [], complete: true, baseSHA: nil, startSHA: nil, headSHA: "a")
    func job(_ gate: [String]) -> EngineJob {
        EngineJob(engine: .claude, executable: "/usr/bin/true", model: "", gate: gate, guidanceFile: "", timeout: 10,
                  mr: mr(), bundle: bundle, previous: [], interdiff: nil, dir: dir)
    }
    guard case .macBusy = await Engine.run(job(["/bin/sh", "-c", "exit 75", "gate"])) else { Issue.record("expected macBusy"); return }
    guard case .failed = await Engine.run(job(["/bin/sh", "-c", "exit 3", "gate"])) else { Issue.record("expected failed"); return }
}

@Test func readsGlabStatusToken() {
    let s = "gitlab.example.com\n  ✓ Logged in to gitlab.example.com as rhea\n  ✓ Token: glpat-abc123\n"
    #expect(HTTPClient.tokenLine(s) == "glpat-abc123")
    #expect(HTTPClient.tokenLine("  ✓ Token: **************************") == nil)
    #expect(HTTPClient.tokenLine("no login") == nil)
}
