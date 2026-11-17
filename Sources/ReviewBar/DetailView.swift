import SwiftUI
import ReviewBarCore

/// Finished review waiting on you → findings + post/approve. Every other state → StateDetail.
struct DetailView: View {
    @EnvironmentObject var model: AppModel
    let id: String

    var body: some View {
        if let t = model.tracked(id) {
            if t.run == .completed && (t.decision == .needsDecision || t.decision == .none) {
                ReviewDetail(id: id)
            } else {
                StateDetail(id: id)
            }
        } else {
            VStack(spacing: 10) {
                Text("This MR is no longer tracked.").foregroundStyle(RB.mute)
                Button("Back to Inbox") { model.route = .inbox }.buttonStyle(SoftButton(height: 28))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct OpenInHost: View {
    @EnvironmentObject var model: AppModel
    var mr: MergeRequest
    var body: some View {
        Button { model.open(mr.webURL) } label: {
            HStack(spacing: 5) { Text("Open in \(mr.provider.name)"); Image(systemName: "arrow.up.right.square").font(.system(size: 10)) }
        }
        .buttonStyle(GhostButton())
    }
}

/// Pipeline · approvals · unresolved threads.
struct MRFacts: View {
    var mr: MergeRequest
    var body: some View {
        let p = pipelineStyle(mr.pipeline)
        HStack(spacing: 12) {
            HStack(spacing: 4) { Image(systemName: p.symbol).foregroundStyle(p.color); Text(p.label).foregroundStyle(RB.ink) }
            Label(mr.approvalsRequired > 0 ? "\(mr.approvalsGiven) of \(mr.approvalsRequired) approvals" : "\(mr.approvalsGiven) approval\(mr.approvalsGiven == 1 ? "" : "s")",
                  systemImage: mr.approvedByMe ? "checkmark.circle" : "person")
            Label("\(mr.unresolvedThreads) unresolved", systemImage: "bubble.left")
        }
        .labelStyle(TightLabel())
        .font(RB.small).foregroundStyle(RB.mute)
        .padding(.horizontal, 14).padding(.bottom, 12)
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { HStack(spacing: 4) { configuration.icon; configuration.title } }
}

func pipelineStyle(_ p: PipelineStatus) -> StatusStyle {
    switch p {
    case .success: StatusStyle(symbol: "checkmark.circle", color: RB.green, label: "Pipeline passed")
    case .failed: StatusStyle(symbol: "xmark.circle", color: RB.red, label: "Pipeline failed")
    case .running, .pending: StatusStyle(symbol: "clock", color: RB.blue, label: "Pipeline \(p.label.lowercased())")
    case .canceled, .none: StatusStyle(symbol: "minus.circle", color: RB.grey, label: p.label)
    }
}

// MARK: - Review detail (design: MR Detail.dc.html)

struct ReviewDetail: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var router: WindowRouter
    let id: String
    @State private var reviewAnyway = false

    var body: some View {
        if let t = model.tracked(id) {
            let run = model.run(t.reviewRunID)
            VStack(spacing: 0) {
                TopBar(back: { model.route = .inbox }) { OpenInHost(mr: t.mr) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        MRHeader(mr: t.mr).padding(.bottom, -12)
                        MRFacts(mr: t.mr).padding(.top, 14)
                        if t.isOutdated && !reviewAnyway {
                            Banner(symbol: "arrow.triangle.2.circlepath", color: RB.purple, title: "New commits since review.",
                                   message: "Head is now \(t.mr.headSHA.prefix(7)); findings may not match the diff.",
                                   actions: [("Re-review now", { model.enqueue(t.id, reason: .rerun) }), ("Review anyway", { reviewAnyway = true })])
                                .padding(.horizontal, 14).padding(.bottom, 12)
                        }
                        if let run, !run.complete {
                            Banner(symbol: "circle.lefthalf.filled", color: RB.yellow, title: "Partial review",
                                   message: (run.incompleteReason ?? "The diff bundle was incomplete") + ". Never treated as clean.")
                                .padding(.horizontal, 14).padding(.bottom, 12)
                        }
                        if let run {
                            summaryCard(run).padding(.horizontal, 14)
                            findings(run)
                        }
                    }
                    .padding(.bottom, 12)
                }
                Hairline()
                actionBar(t, run: run)
            }
        }
    }

    func summaryCard(_ r: ReviewRun) -> some View {
        let c = SeverityCounts(r.findings)
        let (sym, color, title): (String, Color, String) =
            r.verdict == .clean ? ("checkmark.seal", RB.green, "Clean · no issues found")
            : !r.complete ? ("circle.lefthalf.filled", RB.yellow, "Partial review")
            : c.blocker > 0 ? ("exclamationmark.triangle", RB.red, "Changes requested")
            : ("exclamationmark.triangle", RB.orange, "Suggestions")
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: sym).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                Text(title).fontWeight(.medium).foregroundStyle(RB.head)
                if r.verdict != .clean { Text("· " + (r.isReReview ? reReviewSummary(r) : c.summary)).foregroundStyle(RB.mute).lineLimit(1) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Hairline()
            HStack(spacing: 0) {
                cell("Engine", r.engine.name)
                cell("Reviewed", String(r.sha.prefix(7)), mono: true)
                cell("Duration", r.duration.map(elapsed) ?? "–")
                cell("Cost", r.costUSD.map { String(format: "$%.2f", $0) } ?? "–", last: true)
            }
            if let s = r.summary, !s.isEmpty {
                Hairline()
                Text(md(s)).foregroundStyle(RB.mute).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .rbCard()
    }

    func cell(_ k: String, _ v: String, mono: Bool = false, last: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).foregroundStyle(RB.mute)
            Text(v).font(mono ? RB.monoSmall : RB.small.weight(.medium).monospacedDigit()).foregroundStyle(RB.ink)
        }
        .font(RB.small)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) { if !last { Rectangle().fill(RB.line).frame(width: 1) } }
    }

    @ViewBuilder func findings(_ r: ReviewRun) -> some View {
        let selectable = r.findings.filter { !$0.posted && !($0.security && model.settings.neverPostSecurityInline) }
        let selected = selectable.filter(\.selected).count
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("FINDINGS").font(RB.label).tracking(0.6).foregroundStyle(RB.ink)
            Text("\(r.findings.count) · \(selected) selected").monospacedDigit().foregroundStyle(RB.mute)
            Spacer()
            Button(selected > 0 ? "Clear" : "Select all") {
                for var f in selectable { f.selected = selected == 0; model.updateFinding(r.id, f) }
            }
            .buttonStyle(.plain).font(RB.small).foregroundStyle(RB.mute)
        }
        .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 6)
        Hairline()
        if r.isReReview {
            section("Still open", r.findings.filter { $0.carry == .stillOpen || $0.carry == .regressed }, r)
            section("New since last review", r.findings.filter { $0.carry == .new || $0.carry == nil }, r)
            section("Resolved", r.resolved, r, readOnly: true)
        } else {
            section(nil, r.findings, r)
        }
    }

    @ViewBuilder func section(_ title: String?, _ fs: [Finding], _ r: ReviewRun, readOnly: Bool = false) -> some View {
        if !fs.isEmpty {
            if let title {
                Text("\(title) · \(fs.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(RB.faint)
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
            }
            ForEach(fs) { f in FindingRow(finding: f, runID: r.id, mrID: id, readOnly: readOnly).padding(.horizontal, 6).padding(.vertical, 1) }
        }
    }

    // MARK: sticky action bar

    func actionBar(_ t: Tracked, run: ReviewRun?) -> some View {
        let selected = run?.findings.filter { $0.selected && !$0.posted && !($0.security && model.settings.neverPostSecurityInline) } ?? []
        let postBlock: String? = run == nil ? "No finished review" : t.isOutdated ? "Review is outdated — re-review first" : nil
        let approveBlock: String? = run == nil ? "No finished review" : t.decision.isFinal && t.mr.approvedByMe ? "Already approved" : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(selected.isEmpty ? "Select findings to post" : "Post \(selected.count) finding\(selected.count == 1 ? "" : "s")…") { model.route = .post(id) }
                    .buttonStyle(KeyButton(fill: true))
                    .disabled(postBlock != nil || selected.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Approve…") { model.route = .approve(id) }
                    .buttonStyle(SoftButton())
                    .disabled(approveBlock != nil)
                overflow(t, run: run)
            }
            if let reason = postBlock ?? approveBlock {
                Text(reason).font(RB.small).foregroundStyle(RB.mute)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    func overflow(_ t: Tracked, run: ReviewRun?) -> some View {
        let other: EngineKind = (run?.engine ?? model.settings.defaultEngine) == .claude ? .codex : .claude
        return Menu {
            Button("Copy as Markdown") { model.copyMarkdown(id) }.disabled(run == nil)
            Button("Snooze until tomorrow") { model.snooze(id, until: tomorrowMorning()) }
            Button("Snooze until next push") { model.snooze(id, until: nil) }
            Button("Re-review") { model.enqueue(id, reason: .rerun) }.disabled(t.run == .running)
            Button("Second opinion with \(other.name)") { model.enqueue(id, reason: .secondOpinion, engine: other) }
                .disabled(run == nil || t.run == .running || t.isOutdated)
            Divider()
            Button("Dismiss review") { model.dismiss(id) }
            Button("Mark handled manually") { model.markHandled(id) }
            Divider()
            Button("View run log") { if let r = model.runs(for: id).first { router.log(r.id) } }.disabled(model.runs(for: id).isEmpty)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(RB.head)
                .frame(width: 36, height: 36).background(RoundedRectangle(cornerRadius: 8).fill(RB.btn))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More actions")
    }
}

struct FindingRow: View {
    @EnvironmentObject var model: AppModel
    var finding: Finding
    var runID: String
    var mrID: String
    var readOnly = false
    @State private var expanded = false
    @State private var hover = false

    var blockedSecurity: Bool { finding.security && model.settings.neverPostSecurityInline }
    var toggleable: Bool { !readOnly && !finding.posted && !blockedSecurity }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            marker.padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                FlowTitle(finding: finding)
                Button {
                    if let t = model.tracked(mrID), let u = deepLink(t.mr, finding) { NSWorkspace.shared.open(u) }
                } label: { Text(finding.location).font(RB.mono).foregroundStyle(RB.mute) }
                .buttonStyle(.plain).help("Open in browser at this line")
                Text(md(finding.body)).foregroundStyle(RB.mute).lineSpacing(2).lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if expanded, let e = finding.evidence, !e.isEmpty {
                    Text(e).font(RB.monoSmall).foregroundStyle(RB.mute)
                        .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(RB.btn))
                }
                tags
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(finding.selected && toggleable ? RB.sunk : hover ? RB.hover : .clear))
        .opacity(finding.alreadyDiscussed || readOnly ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if toggleable { var f = finding; f.selected.toggle(); model.updateFinding(runID, f) } }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(toggleable ? .isButton : [])
        .accessibilityLabel("\(finding.severity.label): \(finding.title)\(toggleable ? (finding.selected ? ", selected" : ", not selected") : "")")
    }

    @ViewBuilder var marker: some View {
        if readOnly {
            Image(systemName: "checkmark.circle").font(.system(size: 12)).foregroundStyle(RB.green).accessibilityLabel("Resolved")
        } else if finding.posted {
            Image(systemName: "bubble.left").font(.system(size: 11)).foregroundStyle(RB.blue).help("Posted").accessibilityLabel("Posted")
        } else {
            let on = finding.selected && !blockedSecurity
            RoundedRectangle(cornerRadius: 4)
                .fill(on ? RB.key : .clear)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? RB.key : RB.faint, lineWidth: 1.5))
                .overlay { if on { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(RB.pop) } }
                .frame(width: 14, height: 14)
                .opacity(blockedSecurity ? 0.4 : 1)
        }
    }

    var tags: some View {
        HStack(spacing: 8) {
            if finding.alreadyDiscussed { Tag(text: "Already discussed", symbol: "bubble.left") }
            if finding.engines.count > 1 { Tag(text: "Found by both engines", symbol: "checkmark") }
            if finding.anchor == nil && !readOnly { Tag(text: "Can't anchor to diff line", symbol: "link") }
            if blockedSecurity && !readOnly {
                Button("Share privately") {
                    model.copy("**\(finding.severity.label) (security):** \(finding.title)\n`\(finding.location)`\n\n\(finding.body)", toast: "Copied, share it privately")
                }.buttonStyle(.plain).foregroundStyle(RB.ink)
                    .help("Security findings are not posted as MR comments (Settings → Safety). Copy it to send privately.")
                Button("Not sensitive, allow posting") {
                    var f = finding; f.security = false; f.selected = true; model.updateFinding(runID, f)
                }.buttonStyle(.plain).foregroundStyle(RB.ink)
                    .help("Removes the Security tag from this finding only, so you can post it as a comment.")
            }
            Spacer(minLength: 0)
            if finding.body.count > 110 || !(finding.evidence ?? "").isEmpty {
                Button(expanded ? "Less" : "More") { expanded.toggle() }.buttonStyle(.plain).foregroundStyle(RB.mute)
            }
        }
        .font(.system(size: 10.5))
    }
}

/// Severity pill, security pill and title on one wrapping line.
struct FlowTitle: View {
    var finding: Finding
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            SeverityChip(severity: finding.severity).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 5 }
            if finding.security {
                HStack(spacing: 3) { Image(systemName: "lock").font(.system(size: 8, weight: .bold)); Text("Security") }
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(RB.head)
                    .padding(.horizontal, 6).frame(height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(RB.edge))
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 5 }
            }
            if finding.carry == .regressed { Tag(text: "Regressed", color: RB.red) }
            Text(finding.title).fontWeight(.medium).foregroundStyle(RB.head).lineSpacing(1).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - State detail (design: State Detail.dc.html)

struct StateDetail: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var router: WindowRouter
    let id: String
    @State private var copied = false

    var body: some View {
        if let t = model.tracked(id) {
            VStack(spacing: 0) {
                TopBar(back: { model.route = .inbox }) { OpenInHost(mr: t.mr) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        MRHeader(mr: t.mr)
                        statusCard(t).padding(.horizontal, 14)
                        extra(t)
                        if t.decision.isFinal && t.decision != .dismissed && t.decision != .handledManually {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "lock").font(.system(size: 9))
                                Text("Undo isn't possible from ReviewBar. Edit, resolve or withdraw this in \(t.mr.provider.name).")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(RB.small).foregroundStyle(RB.faint)
                            .padding(.horizontal, 14).padding(.top, 12)
                        }
                    }
                    .padding(.bottom, 12)
                }
                Hairline()
                footer(t)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }

    // Status card: icon + title + aside, one line of context, then facts or steps.
    func statusCard(_ t: Tracked) -> some View {
        let s = status(t)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if s.spin { Spinner(color: s.color, size: 12) } else { Image(systemName: s.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(s.color) }
                Text(s.title).fontWeight(.medium).foregroundStyle(RB.head)
                Spacer()
                if t.run == .running, let r = model.run(t.currentRunID) {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in Text(elapsed(ctx.date.timeIntervalSince(r.startedAt))).monospacedDigit() }
                        .font(RB.small).foregroundStyle(RB.mute)
                } else {
                    Text(s.aside).font(RB.small).foregroundStyle(RB.mute)
                }
            }
            if !s.line.isEmpty { Text(s.line).foregroundStyle(RB.mute).lineSpacing(2).fixedSize(horizontal: false, vertical: true) }
            if !s.facts.isEmpty {
                HStack(spacing: 0) {
                    ForEach(s.facts.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.facts[i].0).foregroundStyle(RB.mute)
                            Text(s.facts[i].1).font(s.facts[i].2 ? RB.monoSmall : RB.small.weight(.medium)).foregroundStyle(RB.ink).lineLimit(1)
                        }
                        .font(RB.small)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .trailing) { if i < s.facts.count - 1 { Rectangle().fill(RB.line).frame(width: 1) } }
                    }
                }
                .rbCard()
            }
            if t.run == .running, let r = model.run(t.currentRunID) { steps(r) }
        }
        .padding(12)
        .rbCard(fill: RB.sunk)
    }

    func steps(_ r: ReviewRun) -> some View {
        VStack(spacing: 2) {
            step("checkmark.circle", RB.green, "Fetched diff at \(r.sha.prefix(7))", RB.mute, active: false)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                step("", RB.blue, "Reviewing with \(r.engine.name) · \(elapsed(ctx.date.timeIntervalSince(r.startedAt)))", RB.head, active: true)
            }
            step("circle.dashed", RB.faint, "Checking findings", RB.faint, active: false, aside: "pending")
        }
    }

    func step(_ symbol: String, _ c: Color, _ label: String, _ fg: Color, active: Bool, aside: String = "") -> some View {
        HStack(spacing: 8) {
            if symbol.isEmpty { Spinner(color: c, size: 12) } else { Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(c) }
            Text(label).foregroundStyle(fg)
            Spacer()
            Text(aside).font(RB.small).foregroundStyle(RB.faint)
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? RB.btn : .clear))
    }

    struct Status { var symbol: String; var color: Color; var title: String; var aside: String; var line: String; var facts: [(String, String, Bool)] = []; var spin = false }

    func status(_ t: Tracked) -> Status {
        let run = model.run(t.reviewRunID)
        let when = { (d: Date?) -> String in
            guard let d else { return "" }
            return Calendar.current.isDateInToday(d) ? "Today" : d.formatted(date: .abbreviated, time: .omitted)
        }
        let at = { (sha: String?, d: Date?) -> String in
            let parts = [sha.map { "At " + $0.prefix(7) }, d.map { ($0.formatted(date: .omitted, time: .shortened)) }].compactMap { $0 }
            return parts.isEmpty ? "" : parts.joined(separator: " · ") + "."
        }
        switch t.run {
        case .queued:
            let pos = model.queuePosition(t.id) ?? 1
            let ahead = pos > 1 ? model.queuedSorted[pos - 2] : model.items.values.first { $0.run == .running }
            var line = ahead.map { "Starts after \($0.mr.repoShort) \($0.mr.ref)." } ?? "Starts next."
            if let nb = t.notBefore, nb > Date() { line += " Not before \(nb.formatted(date: .omitted, time: .shortened))." }
            return Status(symbol: "clock", color: RB.grey, title: "Queued · #\(pos) in queue",
                          aside: t.enqueuedAt.map { "added \(relative($0)) ago" } ?? "", line: line,
                          facts: [("Reason", t.queueReason?.label ?? "–", false), ("Engine", t.engine.name, false), ("Head", String(t.mr.headSHA.prefix(7)), true)])
        case .running:
            let r = model.run(t.currentRunID)
            return Status(symbol: "", color: RB.blue, title: "Reviewing", aside: "", line: "With \(r?.engine.name ?? t.engine.name)\(r?.model.map { " · \($0)" } ?? "") at \(t.mr.headSHA.prefix(7)).", spin: true)
        case .failed, .interrupted:
            let last = model.runs(for: t.id).first
            let title = t.run == .interrupted ? "Interrupted when ReviewBar quit" : failureTitle(t)
            return Status(symbol: "xmark.octagon", color: RB.red, title: title,
                          aside: "\(t.run == .interrupted ? "Stopped" : "Failed")\(last?.endedAt.map { " · \(relative($0)) ago" } ?? "")",
                          line: t.run == .interrupted ? "Partial results were discarded."
                            : t.fixCommand != nil ? "\(t.failure ?? "Login problem.") Nothing was sent to the engine."
                            : "\((t.failure ?? "The review didn't finish.").trimmingCharacters(in: CharacterSet(charactersIn: ". "))). Nothing was posted.")
        case .discovered, .skipped:
            return Status(symbol: "circle.dashed", color: RB.faint, title: t.run == .skipped ? "Skipped" : "Not reviewed yet", aside: "",
                          line: model.settings.autoReviewPaused ? "Auto-review is paused. Review it now, or turn auto-review back on." : "It's outside your auto-review scope. Review it now to queue it.")
        case .completed:
            switch t.decision {
            case .approved, .approvedWithComments:
                return Status(symbol: "checkmark.circle", color: RB.green, title: "Approved by you", aside: when(t.decidedAt),
                              line: (at(t.decidedSHA, t.decidedAt) + (run?.verdict == .clean ? " Clean review by \(run?.engine.name ?? "the engine"), no findings to post." : "")).trimmingCharacters(in: .whitespaces),
                              facts: [("Approved", String((t.decidedSHA ?? t.mr.headSHA).prefix(7)), true), ("Pipeline", t.mr.pipeline.label, false),
                                      ("Approvals", t.mr.approvalsRequired > 0 ? "\(t.mr.approvalsGiven) of \(t.mr.approvalsRequired)" : "\(t.mr.approvalsGiven)", false)])
            case .findingsPosted:
                let left = (run?.findings.filter { !$0.posted }.count) ?? 0
                return Status(symbol: "bubble.left", color: RB.blue, title: "Posted \(t.postedCount) comment\(t.postedCount == 1 ? "" : "s")", aside: when(t.decidedAt),
                              line: at(t.decidedSHA, t.decidedAt) + (left > 0 ? " You left \(left) other finding\(left == 1 ? "" : "s") unposted." : ""))
            default:
                return Status(symbol: "nosign", color: RB.grey, title: t.decision == .handledManually ? "Handled manually" : "Dismissed by you", aside: when(t.decidedAt),
                              line: at(t.decidedSHA, t.decidedAt) + " Nothing was posted or approved. It comes back if the author pushes new commits.")
            }
        }
    }

    func failureTitle(_ t: Tracked) -> String {
        let f = t.failure ?? ""
        if f.localizedCaseInsensitiveContains("auth") { return "\(t.mr.provider.name) auth expired" }
        if f.localizedCaseInsensitiveContains("timed out") { return "Review timed out" }
        if f.localizedCaseInsensitiveContains("not found") { return "Review engine not found" }
        return "Review failed"
    }

    @ViewBuilder func extra(_ t: Tracked) -> some View {
        let run = model.run(t.reviewRunID)
        switch t.run {
        case .failed, .interrupted:
            VStack(alignment: .leading, spacing: 8) {
                Text(t.fixCommand == nil ? "BEFORE RETRYING" : "FIX").font(RB.label).tracking(0.6).foregroundStyle(RB.ink)
                if let cmd = t.fixCommand {
                    HStack(spacing: 8) {
                        Text(cmd).font(RB.mono).foregroundStyle(RB.head).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button {
                            model.copy(cmd, toast: nil); copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                        } label: {
                            HStack(spacing: 4) { Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9)); Text(copied ? "Copied" : "Copy") }
                        }
                        .buttonStyle(SoftButton(height: 22))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .rbCard(fill: RB.sunk)
                }
                Text(t.fixCommand != nil ? "Run in Terminal, or reconnect in Settings → Accounts. Then Retry."
                     : t.run == .interrupted ? "Retry starts from the beginning."
                     : (t.failure ?? "").localizedCaseInsensitiveContains("timed out") ? "Raise the timeout in Settings → Review engine, then Retry."
                     : "Check the run log, then Retry.")
                    .font(RB.small).foregroundStyle(RB.mute)
            }
            .padding(.horizontal, 14).padding(.top, 16)
        case .queued where run != nil:
            findingList("From the previous review at \(run!.sha.prefix(7))", run!.findings, faded: true, note: { $0.posted ? ("bubble.left", "Posted") : ("smallcircle.filled.circle", "Open") })
        case .completed where t.decision == .findingsPosted:
            findingList("Posted findings · read-only", run?.findings.filter(\.posted) ?? [], faded: false, note: { _ in ("bubble.left", "Posted") })
        case .completed where t.decision == .dismissed || t.decision == .handledManually:
            findingList("Review findings · not posted", run?.findings ?? [], faded: true, note: { _ in ("nosign", "Not posted") })
        default:
            EmptyView()
        }
    }

    @ViewBuilder func findingList(_ title: String, _ fs: [Finding], faded: Bool, note: @escaping (Finding) -> (String, String)) -> some View {
        if !fs.isEmpty {
            Text(title).font(RB.small).foregroundStyle(RB.mute)
                .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 6)
            VStack(spacing: 0) {
                ForEach(Array(fs.enumerated()), id: \.element.id) { i, f in
                    if i > 0 { Hairline() }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) { SeverityChip(severity: f.severity); Text(f.title).fontWeight(.medium).foregroundStyle(RB.head).lineLimit(2) }
                        HStack {
                            Text(f.location).font(RB.monoSmall).foregroundStyle(RB.mute).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            let (sym, label) = note(f)
                            HStack(spacing: 3) { Image(systemName: sym).font(.system(size: 9)); Text(label) }.font(.system(size: 10.5)).foregroundStyle(RB.faint)
                        }
                    }
                    .padding(10)
                }
            }
            .rbCard()
            .opacity(faded ? 0.55 : 1)
            .padding(.horizontal, 14)
        }
    }

    /// The review <-> implement loop without extra tooling: the author's own Claude session works the threads via glab/gh.
    func implementerPrompt(_ mr: MergeRequest) -> String {
        let cli = mr.provider == .gitlab ? "glab" : "gh"
        return "Using \(cli), read the open review threads on \(mr.webURL). For each one: fix it if it's right, or reply explaining why you disagree. Reply on every thread with what you did, then push."
    }

    @ViewBuilder func footer(_ t: Tracked) -> some View {
        switch t.run {
        case .queued:
            HStack(spacing: 6) {
                if let top = model.queuedSorted.first, top.id != t.id {
                    Button("Move to top") { model.moveQueued(t.id, before: top.id) }.buttonStyle(KeyButton(height: 32))
                }
                Menu {
                    ForEach(EngineKind.allCases, id: \.self) { e in
                        Button(e.name + (e == t.engine ? " ✓" : "")) { model.enqueue(t.id, reason: t.queueReason ?? .manual, engine: e) }
                    }
                } label: { HStack(spacing: 4) { Text(t.engine.name); Image(systemName: "chevron.down").font(.system(size: 9)) } }
                    .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Button("Cancel") { model.cancel(t.id) }.buttonStyle(SoftButton(height: 32))
            }
        case .running:
            HStack(spacing: 8) {
                Text("Results land in Decide when done. You'll get a notification.").font(RB.small).foregroundStyle(RB.mute).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Cancel review") { model.cancel(t.id) }.buttonStyle(SoftButton(height: 32))
            }
        case .failed, .interrupted:
            HStack {
                Button("Retry") { model.enqueue(t.id, reason: .retry) }.buttonStyle(KeyButton(height: 32))
                Spacer()
                if let r = model.runs(for: t.id).first {
                    Button { router.log(r.id) } label: { HStack(spacing: 3) { Text("View full run log"); Image(systemName: "chevron.right").font(.system(size: 9)) } }
                        .buttonStyle(.plain).font(RB.small).foregroundStyle(RB.mute)
                }
            }
        case .discovered, .skipped:
            HStack { Button("Review now") { model.enqueue(t.id, reason: .manual) }.buttonStyle(KeyButton(height: 32)); Spacer() }
        case .completed:
            HStack(spacing: 6) {
                if t.decision == .dismissed || t.decision == .handledManually {
                    Button("Review again") { model.enqueue(t.id, reason: .rerun) }.buttonStyle(KeyButton(height: 32))
                } else {
                    Button("Re-review") { model.enqueue(t.id, reason: .rerun) }.buttonStyle(SoftButton(height: 32))
                }
                if t.decision == .findingsPosted {
                    Button("Copy fix prompt") { model.copy(implementerPrompt(t.mr), toast: "Copied. Send it to the author for their Claude session.") }
                        .buttonStyle(SoftButton(height: 32))
                        .help("A prompt the MR author pastes into their own Claude Code session to work through your comments")
                }
                Spacer()
                if t.decision != .findingsPosted {   // posted: the top bar already has Open, the footer has Copy fix prompt
                    Button { model.open(t.mr.webURL) } label: {
                        HStack(spacing: 5) { Text("Open in \(t.mr.provider.name)"); Image(systemName: "arrow.up.right.square").font(.system(size: 10)) }
                    }
                    .buttonStyle(SoftButton(height: 32))
                }
            }
        }
    }
}

// MARK: - Post findings confirmation (FR-13, acceptance 7) — design: Post Sheet.dc.html

struct SheetHeader: View {
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(RB.head)
            Text(subtitle).font(RB.small).foregroundStyle(RB.mute).lineLimit(2)
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CheckRow: View {
    var symbol: String
    var color: Color
    var label: String
    var mono = ""
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            Text(label).foregroundStyle(RB.ink)
            if !mono.isEmpty { Text(mono).font(RB.monoSmall).foregroundStyle(RB.mute) }
            Spacer(minLength: 0)
        }
        .font(RB.small)
    }
}

struct PostSheet: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @State private var drafts: [Finding] = []
    @State private var check: AppModel.PostCheck?
    @State private var checkError: String?
    @State private var allowGeneral = true
    @State private var posting = false
    @State private var refused = false

    var postable: [Finding] {
        guard let c = check else { return [] }
        return drafts.filter { !c.duplicates.contains($0.id) && ($0.anchor != nil || allowGeneral) }
    }

    var body: some View {
        let t = model.tracked(id)
        VStack(spacing: 0) {
            SheetHeader(title: "Post \(drafts.count) finding\(drafts.count == 1 ? "" : "s")",
                        subtitle: "As inline comments on \(t?.mr.repoShort ?? "") \(t?.mr.ref ?? "") · signed as you")
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if refused {
                        Banner(symbol: "xmark.octagon", color: RB.red, title: "MR changed since review.",
                               message: "Re-review before posting — line anchors may point at the wrong code. Nothing was posted.")
                    }
                    ForEach($drafts) { $f in draft($f) }
                    safety
                    Toggle("Post findings without a diff line as general comments", isOn: $allowGeneral)
                        .toggleStyle(.checkbox).font(RB.small).foregroundStyle(RB.mute)
                }
                .padding(14)
                .opacity(refused ? 0.55 : 1)
            }
            Hairline()
            HStack(spacing: 6) {
                if posting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { model.route = .detail(id) }.buttonStyle(SoftButton(height: 32)).keyboardShortcut(.cancelAction)
                if refused {
                    Button("Re-review now") { model.enqueue(id, reason: .rerun); model.route = .inbox }.buttonStyle(KeyButton(height: 32))
                } else {
                    Button("Post \(postable.count) comment\(postable.count == 1 ? "" : "s")") { post() }
                        .buttonStyle(KeyButton(height: 32))
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(check?.headOK != true || postable.isEmpty || posting)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .task { await load() }
    }

    func draft(_ f: Binding<Finding>) -> some View {
        let dup = check?.duplicates.contains(f.wrappedValue.id) == true
        let general = f.wrappedValue.anchor == nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SeverityChip(severity: f.wrappedValue.severity)
                Image(systemName: general ? "bubble.left" : "link").font(.system(size: 9)).foregroundStyle(RB.faint)
                Text(f.wrappedValue.anchor.map { "\($0.newLine == nil ? $0.oldPath : $0.newPath):\($0.newLine ?? $0.oldLine ?? 0)" } ?? f.wrappedValue.location)
                    .font(RB.monoSmall).foregroundStyle(RB.mute).lineLimit(1).truncationMode(.middle)
                if dup { Tag(text: "Duplicate · skipped", color: RB.orange) }
            }
            TextField("Title", text: f.title).textFieldStyle(.plain).fontWeight(.medium).foregroundStyle(RB.head)
            TextEditor(text: f.body)
                .font(RB.body).foregroundStyle(RB.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60, maxHeight: 110)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(RB.sunk))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RB.line))
                .disabled(refused)
            if general {
                Text(allowGeneral ? "Line isn't in the diff — posts as a general comment with the file reference." : "Line isn't in the diff — kept local.")
                    .font(RB.small).foregroundStyle(RB.mute)
            }
        }
        .opacity(dup ? 0.5 : 1)
    }

    @ViewBuilder var safety: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SAFETY CHECKS").font(RB.label).tracking(0.6).foregroundStyle(RB.ink)
            if let c = check {
                CheckRow(symbol: c.headOK ? "checkmark.circle" : "xmark.circle", color: c.headOK ? RB.green : RB.red,
                         label: c.headOK ? "Head SHA unchanged" : "Head moved",
                         mono: c.headOK ? String(c.head.prefix(7)) : "\(model.tracked(id)?.reviewedSHA?.prefix(7) ?? "?") → \(c.head.prefix(7))")
                CheckRow(symbol: c.duplicates.isEmpty ? "checkmark.circle" : "exclamationmark.triangle", color: c.duplicates.isEmpty ? RB.green : RB.orange,
                         label: c.duplicates.isEmpty ? "No duplicate comments" : "\(c.duplicates.count) duplicate\(c.duplicates.count == 1 ? "" : "s") of existing threads will be skipped")
                let general = drafts.filter { $0.anchor == nil && !c.duplicates.contains($0.id) }.count
                if general > 0 {
                    CheckRow(symbol: "bubble.left", color: RB.mute, label: "\(general) \(allowGeneral ? "post\(general == 1 ? "s" : "") as a general comment" : "kept local (no diff line)")")
                }
            } else if let e = checkError {
                CheckRow(symbol: "xmark.circle", color: RB.red, label: e)
            } else {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking head SHA and existing threads…").font(RB.small).foregroundStyle(RB.mute) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rbCard(fill: RB.sunk)
    }

    func load() async {
        guard let t = model.tracked(id), let r = model.run(t.reviewRunID) else { return }
        drafts = r.findings.filter { $0.selected && !$0.posted && !($0.security && model.settings.neverPostSecurityInline) }
        do {
            let c = try await model.checkPost(id, findings: drafts, allowGeneral: allowGeneral)
            check = c
            refused = !c.headOK
        } catch { checkError = error.localizedDescription }
    }

    func post() {
        posting = true
        let toPost = postable
        Task {
            for f in toPost { model.updateFinding(model.tracked(id)?.reviewRunID ?? "", f) }
            do { _ = try await model.post(id, findings: toPost, allowGeneral: allowGeneral) }
            catch ForgeError.headMoved { refused = true }
            catch { checkError = error.localizedDescription; check = nil }
            posting = false
        }
    }
}

// MARK: - Approve confirmation (FR-14, acceptance 5 and 9) — design: Approve Sheet.dc.html

struct ApproveSheet: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @State private var fresh: MergeRequest?
    @State private var loadError: String?
    @State private var armed = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let t = model.tracked(id)
        let run = model.run(t?.reviewRunID)
        let mr = fresh ?? t?.mr
        let open = run?.findings.filter { !$0.posted && ($0.severity == .blocker || $0.severity == .shouldFix) } ?? []
        let risks = riskList(t, run: run, mr: mr, openFindings: open.count)
        let back = { model.route = t?.reviewRunID == nil ? .inbox : .detail(id) }
        VStack(spacing: 0) {
            SheetHeader(title: risks.isEmpty ? "Approve merge request" : "Approve with open issues?",
                        subtitle: "\(t?.mr.repoShort ?? "") \(t?.mr.ref ?? "") · \(t?.mr.title ?? "")")
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let mr, let t {
                        VStack(spacing: 0) {
                            let headOK = t.reviewedSHA == mr.headSHA
                            row(headOK ? "checkmark.circle" : "arrow.triangle.2.circlepath", headOK ? RB.green : RB.purple, "Head SHA", String(mr.headSHA.prefix(7)), mono: true,
                                note: headOK ? "Matches the reviewed commit" : t.reviewedSHA.map { "Reviewed \($0.prefix(7)) · new commits not reviewed" } ?? "Not reviewed")
                            Hairline()
                            let p = pipelineStyle(mr.pipeline)
                            row(p.symbol, p.color, "Pipeline", mr.pipeline.label)
                            Hairline()
                            row(mr.unresolvedThreads == 0 ? "checkmark.circle" : "bubble.left", mr.unresolvedThreads == 0 ? RB.green : RB.orange,
                                "Unresolved threads", mr.unresolvedThreads == 0 ? "None" : "\(mr.unresolvedThreads)")
                            Hairline()
                            row(open.isEmpty ? "checkmark.seal" : "exclamationmark.triangle", open.isEmpty ? RB.green : RB.red, "Open findings",
                                open.isEmpty ? "None" : SeverityCounts(open).summary,
                                note: open.isEmpty ? (run?.verdict == .clean ? "Clean review by \(run?.engine.name ?? "the engine")" : "") : "Not posted or dismissed")
                            Hairline()
                            row("person", RB.mute, "Approvals", mr.approvalsRequired > 0 ? "\(mr.approvalsGiven) of \(mr.approvalsRequired) required" : "\(mr.approvalsGiven) given")
                        }
                        .rbCard()
                    } else if let loadError {
                        Banner(symbol: "exclamationmark.triangle", color: RB.red, title: "Couldn't refresh the MR", message: loadError)
                    } else {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Refreshing MR state…").font(RB.small).foregroundStyle(RB.mute) }
                    }
                    if !risks.isEmpty {
                        Banner(symbol: "exclamationmark.triangle", color: RB.orange,
                               title: "\(risks.count) check\(risks.count == 1 ? " needs" : "s need") attention.",
                               message: risks.joined(separator: ". ") + ". ReviewBar won't approve without a second confirmation.")
                    }
                    if armed, let mr {
                        (Text("Confirm approval? ").fontWeight(.medium).foregroundStyle(RB.head)
                         + Text("You're approving ") + Text(mr.headSHA.prefix(7)).font(RB.mono)
                         + Text("\(t?.reviewedSHA == mr.headSHA ? "" : ", which ReviewBar hasn't reviewed"). This is recorded as your approval on \(mr.provider.name)."))
                            .foregroundStyle(RB.mute).fixedSize(horizontal: false, vertical: true)
                    }
                    if let error { Banner(symbol: "xmark.octagon", color: RB.red, title: "Approve failed", message: error) }
                }
                .padding(14)
            }
            Hairline()
            HStack(spacing: 6) {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button(armed ? "Back" : "Cancel") { if armed { armed = false } else { back() } }
                    .buttonStyle(SoftButton(height: 32)).keyboardShortcut(.cancelAction)
                if risks.isEmpty {
                    Button("Approve \(t?.mr.ref ?? "")") { approve(override: false) }.buttonStyle(KeyButton(height: 32))
                        .keyboardShortcut(.return, modifiers: .command).disabled(working || fresh == nil)
                } else if !armed {
                    Button("Approve anyway…") { armed = true }.buttonStyle(SoftButton(height: 32)).disabled(working || fresh == nil)
                } else {
                    Button("Yes, approve \(mr?.headSHA.prefix(7) ?? "")") { approve(override: true) }.buttonStyle(KeyButton(height: 32)).disabled(working)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .task {
            do { fresh = try await model.refresh(id) } catch { loadError = error.localizedDescription }
        }
    }

    func row(_ symbol: String, _ color: Color, _ label: String, _ value: String, mono: Bool = false, note: String = "") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color).frame(width: 14)
            Text(label).foregroundStyle(RB.mute).lineLimit(1).frame(width: 124, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(mono ? RB.monoSmall : RB.body).foregroundStyle(RB.head)
                if !note.isEmpty { Text(note).font(RB.small).foregroundStyle(RB.mute).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    func riskList(_ t: Tracked?, run: ReviewRun?, mr: MergeRequest?, openFindings: Int) -> [String] {
        guard let t, let mr else { return [] }
        var r: [String] = []
        if t.reviewedSHA == nil { r.append("No completed review") }
        else if mr.headSHA != t.reviewedSHA { r.append("The review is outdated: new commits since \(t.reviewedSHA!.prefix(7))") }
        if run?.complete == false { r.append("Partial review: \(run?.incompleteReason ?? "diff incomplete")") }
        if mr.pipeline == .failed { r.append("The pipeline is failing") }
        if openFindings > 0 { r.append("\(openFindings) blocker/should-fix finding\(openFindings == 1 ? "" : "s") not posted") }
        return r
    }

    func approve(override: Bool) {
        working = true; error = nil
        Task {
            do { try await model.approve(id, override: override) }
            catch ForgeError.headMoved { self.error = "MR changed since review. Re-review or approve anyway."; armed = false }
            catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

/// Engine text uses Markdown (**bold**, `code`). Render inline syntax, keep line breaks and "- " bullets as typed.
func md(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}
