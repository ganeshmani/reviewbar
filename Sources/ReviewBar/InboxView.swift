import SwiftUI
import ReviewBarCore

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch model.route {
                case .inbox: InboxView()
                case .detail(let id): DetailView(id: id)
                case .post(let id): PostSheet(id: id)
                case .approve(let id): ApproveSheet(id: id)
                }
            }
            if let toast = model.toast { Toast(text: toast) }
        }
        .animation(.easeOut(duration: 0.15), value: model.toast)
        .frame(width: 380, height: 600)
        .background(RB.pop)
        .foregroundStyle(RB.ink)
        .font(RB.body)
        .onKeyPress(.escape) {
            guard model.route != .inbox else { return .ignored }
            if case .detail = model.route { model.route = .inbox }
            else if case .post(let id) = model.route { model.route = .detail(id) }
            else if case .approve(let id) = model.route { model.route = .detail(id) }
            return .handled
        }
    }
}

/// Tabs segment the inbox by what you can do next (design: Inbox.dc.html TABS).
enum InboxTab: String, CaseIterable {
    case decide, progress, waiting, failed, done
    var label: String {
        switch self { case .decide: "Decide"; case .progress: "In progress"; case .waiting: "Waiting"; case .failed: "Failed"; case .done: "Done" }
    }
    var groups: [(InboxGroup, String)] {
        switch self {
        case .decide: [(.needsDecision, "Needs decision"), (.outdated, "Outdated")]
        case .progress: [(.running, "Running"), (.queued, "Queued"), (.discovered, "Not reviewed")]
        case .waiting: [(.waitingOnAuthor, "Waiting on author")]
        case .failed: [(.failed, "Failed")]
        case .done: [(.doneToday, "Done today")]
        }
    }
}

struct InboxView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var router: WindowRouter
    @AppStorage("reviewbar.inbox.tab") private var storedTab = InboxTab.decide.rawValue
    @AppStorage("reviewbar.inbox.groupByRepo") private var byRepo = false
    @State private var field = ""
    @FocusState private var fieldFocused: Bool
    @FocusState private var listFocused: Bool
    @State private var dropTarget: String?

    private var isURL: Bool { field.hasPrefix("http") }
    private var filter: String { isURL ? "" : field.trimmingCharacters(in: .whitespaces).lowercased() }

    private func items(_ g: InboxGroup) -> [Tracked] {
        let all = model.visible[g] ?? []
        guard !filter.isEmpty else { return all }
        return all.filter { "\($0.mr.repoShort) \($0.mr.ref) \($0.mr.title) \($0.mr.author)".lowercased().contains(filter) }
    }
    private func count(_ tab: InboxTab) -> Int { tab.groups.reduce(0) { $0 + items($1.0).count } }
    /// All MR ids in a tab, ignoring the text filter.
    private func ids(_ t: InboxTab) -> Set<String> { Set(t.groups.flatMap { (model.visible[$0.0] ?? []).map(\.id) }) }
    /// True when the tab holds MRs you have not looked at since you last opened it.
    private func hasNew(_ t: InboxTab) -> Bool { t != tab && !ids(t).subtracting(model.seenByTab[t.rawValue] ?? ids(t)).isEmpty }
    private func markSeen() {
        for t in InboxTab.allCases where model.seenByTab[t.rawValue] == nil { model.seenByTab[t.rawValue] = ids(t) }
        model.seenByTab[tab.rawValue] = ids(tab)
    }
    private var tabs: [InboxTab] { InboxTab.allCases.filter { $0 != .failed || count($0) > 0 } }
    private var tab: InboxTab { tabs.first { $0.rawValue == storedTab } ?? tabs[0] }
    private var sections: [(InboxGroup, String, [Tracked])] {
        tab.groups.compactMap { g, title in
            var i = items(g)
            if regroups(g) {   // stable sort by repo, so rows of one repo sit together under a repo header
                i = i.enumerated().sorted { ($0.element.mr.projectPath.lowercased(), $0.offset) < ($1.element.mr.projectPath.lowercased(), $1.offset) }.map(\.element)
            }
            return i.isEmpty ? nil : (g, title, i)
        }
    }
    /// Running and queued keep their order: it is the queue.
    private func regroups(_ g: InboxGroup) -> Bool { byRepo && g != .running && g != .queued }
    private var flat: [Tracked] { sections.flatMap(\.2) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.settings.accounts.isEmpty && !model.demo {
                Hairline()
                FirstRunView().frame(maxHeight: .infinity, alignment: .top)
            } else {
                if model.offline { offlineNotice }
                inputField
                Text(summary).font(RB.small.monospacedDigit()).foregroundStyle(RB.mute)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 8)
                tabBar
                Hairline()
                if sections.isEmpty { emptyLine } else { list }
            }
            Hairline()
            footer
        }
    }

    // MARK: header

    var header: some View {
        HStack(spacing: 8) {
            SignalBarMark(size: 13)
            Text("ReviewBar").font(.system(size: 13, weight: .medium)).foregroundStyle(RB.head)
            syncLabel
            if model.demo { Tag(text: "Demo data", color: RB.purple) }
            Spacer()
            Button { byRepo.toggle() } label: { Image(systemName: byRepo ? "folder.fill" : "folder") }
                .buttonStyle(GhostButton()).help(byRepo ? "Show as one list" : "Group by repository")
                .accessibilityLabel("Group by repository").accessibilityAddTraits(byRepo ? .isSelected : [])
            Button { model.poll() } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(model.syncing ? 360 : 0))
                    .animation(model.syncing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: model.syncing)
            }
            .buttonStyle(GhostButton()).help("Refresh now").accessibilityLabel("Refresh")
            Button { router.settings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(GhostButton()).help("Settings").accessibilityLabel("Settings")
                .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.top, 10).padding(.bottom, 8)
    }

    var syncLabel: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            Group {
                if model.settings.accounts.isEmpty && !model.demo { Text("Not connected") }
                else if model.syncing { Text("Syncing…") }
                else if model.offline { Text("Last synced \(model.lastSync?.formatted(date: .omitted, time: .shortened) ?? "never")") }
                else if let d = model.lastSync { Text(relative(d) == "just now" ? "Synced just now" : "Synced \(relative(d)) ago") }
                else { Text("Not synced") }
            }
            .font(RB.small).foregroundStyle(RB.mute).lineLimit(1)
        }
    }

    var offlineNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wifi.slash").font(.system(size: 11))
            (Text("Offline. ").foregroundStyle(RB.head).fontWeight(.medium)
             + Text("Showing results from \(model.lastSync?.formatted(date: .omitted, time: .shortened) ?? "earlier"). Queued reviews resume on reconnect."))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(RB.small).foregroundStyle(RB.mute)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(RB.sunk))
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    var summary: String {
        let need = model.count(.needsDecision), run = model.count(.running), q = model.count(.queued), out = model.count(.outdated), f = model.count(.failed)
        let parts = [(need, "need decision"), (run, "running"), (q, "queued"), (out, "outdated"), (f, "failed")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        if parts.isEmpty { return "Nothing needs you · \(model.count(.doneToday)) closed today" }
        return parts.joined(separator: " · ")
    }

    // MARK: paste / filter field (J6, ⌘F)

    var inputField: some View {
        HStack(spacing: 7) {
            Image(systemName: isURL ? "plus.circle" : "link").font(.system(size: 11)).foregroundStyle(RB.faint)
            TextField("Paste MR/PR URL to review…", text: $field)
                .textFieldStyle(.plain)
                .foregroundStyle(RB.ink)
                .focused($fieldFocused)
                .onSubmit { submit() }
            if isURL {
                Button("Review", action: submit).buttonStyle(KeyButton(height: 20))
            } else if !field.isEmpty {
                Button { field = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(RB.faint)
            }
        }
        .padding(.horizontal, 9).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8).fill(RB.sunk))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RB.line))
        .padding(.horizontal, 10).padding(.bottom, 8)
        .dropDestination(for: URL.self) { urls, _ in
            if let u = urls.first { model.add(urlString: u.absoluteString); return true }
            return false
        }
        .background(Button("") { fieldFocused = true }.keyboardShortcut("f", modifiers: .command).hidden())
    }

    func submit() {
        guard isURL else { return }
        model.add(urlString: field)
        field = ""
    }

    // MARK: tabs

    var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Array(tabs.enumerated()), id: \.element) { i, t in
                let on = t == tab, n = count(t)
                Button { select(t) } label: {
                    HStack(spacing: 4) {
                        Text(t.label)
                        if n > 0 && (t == .decide || hasNew(t)) {
                            Text("\(n)").font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(t == .failed ? Color.white : RB.keyTx)
                                .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                                .background(RoundedRectangle(cornerRadius: 5).fill(t == .failed ? RB.red : RB.key))
                        } else {
                            Text("\(n)").monospacedDigit().foregroundStyle(t == .failed ? RB.red : RB.faint)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(on ? RB.head : RB.mute)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? RB.seg : .clear).shadow(color: .black.opacity(on ? 0.25 : 0), radius: 1, y: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                .help("\(t.label) (⌘\(i + 1))")
                .accessibilityLabel("\(t.label), \(n)\(hasNew(t) ? ", new" : "")")
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(2)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8).fill(RB.btn))
        .padding(.horizontal, 10).padding(.bottom, 8)
        .onAppear { markSeen() }
        .onChange(of: storedTab) { markSeen() }
        .onChange(of: ids(tab)) { markSeen() }   // arrivals in the tab you are looking at are seen
    }

    func select(_ t: InboxTab) {
        storedTab = t.rawValue
        model.selection = nil
    }

    // MARK: list

    var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if tab == .progress, model.runningCount > 0 { runningStrip }
                    ForEach(sections, id: \.0) { g, title, rows in
                        if tab.groups.count > 1 {
                            HStack {
                                Text(title)
                                Spacer()
                                if g == .failed && rows.count > 1 {
                                    Button("Retry all") { rows.forEach { model.enqueue($0.id, reason: .retry) } }.buttonStyle(.plain)
                                }
                                if g == .discovered {
                                    // Local only: nothing is posted to GitLab/GitHub. Dismissed MRs move to Done.
                                    Button("Dismiss all") { rows.forEach { model.dismiss($0.id) } }.buttonStyle(.plain)
                                        .help("Hide these MRs from ReviewBar. Nothing is posted. They move to Done, where you can still review them.")
                                }
                                Text("\(rows.count)").monospacedDigit()
                            }
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(RB.faint)
                            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, t in
                            if regroups(g), i == 0 || rows[i - 1].mr.projectPath != t.mr.projectPath {
                                let n = rows.filter { $0.mr.projectPath == t.mr.projectPath }.count
                                HStack(spacing: 5) {
                                    Image(systemName: "folder").font(.system(size: 10))
                                    Text(t.mr.repoShort).lineLimit(1).truncationMode(.middle)
                                    Text("\(n)").monospacedDigit().foregroundStyle(RB.faint)
                                    Spacer()
                                }
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(RB.mute)
                                .padding(.horizontal, 16).padding(.top, i == 0 ? 2 : 8).padding(.bottom, 2)
                                .help(t.mr.projectPath)
                            }
                            row(t, group: g).id(t.id).padding(.horizontal, 6)
                        }
                    }
                }
                .padding(.top, 4).padding(.bottom, 6)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.downArrow) { move(1, proxy); return .handled }
            .onKeyPress(.upArrow) { move(-1, proxy); return .handled }
            .onKeyPress(.return) {
                guard let id = model.selection else { return .ignored }
                if NSEvent.modifierFlags.contains(.command), let t = model.tracked(id) { primary(t); return .handled }
                model.openDetail(id); return .handled
            }
            .onAppear { listFocused = true }
        }
    }

    var runningStrip: some View {
        HStack(spacing: 7) {
            Spinner(color: RB.blue)
            Text("Reviewing \(model.runningCount)").foregroundStyle(RB.head)
            Text("· \(model.count(.queued)) waiting")
        }
        .font(RB.small.monospacedDigit()).foregroundStyle(RB.mute)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(RB.btn))
        .padding(.horizontal, 6).padding(.top, 4).padding(.bottom, 2)
    }

    func move(_ d: Int, _ proxy: ScrollViewProxy) {
        let ids = flat.map(\.id)
        guard !ids.isEmpty else { return }
        let i = model.selection.flatMap { ids.firstIndex(of: $0) } ?? (d > 0 ? -1 : ids.count)
        let next = ids[max(0, min(ids.count - 1, i + d))]
        model.selection = next
        proxy.scrollTo(next)
    }

    func primary(_ t: Tracked) {
        switch t.run {
        case .failed, .interrupted: model.enqueue(t.id, reason: .retry)
        case .completed where t.isOutdated: model.enqueue(t.id, reason: .rerun)
        case .completed where t.verdict == .clean: model.route = .approve(t.id)
        case .completed: model.route = .post(t.id)
        case .running, .queued: model.cancel(t.id)
        default: model.enqueue(t.id, reason: .manual)
        }
    }

    @ViewBuilder func row(_ t: Tracked, group g: InboxGroup) -> some View {
        let base = MRRow(t: t, selected: model.selection == t.id, showRepo: !regroups(g))
            .contextMenu { contextMenu(t) }
            .overlay(alignment: .top) {
                if dropTarget == t.id { Rectangle().fill(RB.key).frame(height: 2) }
            }
        if g == .queued {
            base
                .draggable(t.id)
                .dropDestination(for: String.self) { ids, _ in
                    ids.first.map { model.moveQueued($0, before: t.id) }
                    return true
                } isTargeted: { dropTarget = $0 ? t.id : (dropTarget == t.id ? nil : dropTarget) }
        } else {
            base
        }
    }

    @ViewBuilder func contextMenu(_ t: Tracked) -> some View {
        Button("Open details") { model.openDetail(t.id) }
        if t.run == .completed && t.decision == .needsDecision && t.verdict == .clean && !t.isOutdated {
            Button("Approve…") { model.route = .approve(t.id) }
        }
        if t.reviewRunID != nil { Button("Copy as Markdown") { model.copyMarkdown(t.id) } }
        Divider()
        if t.run == .queued, let top = model.queuedSorted.first, top.id != t.id {
            Button("Run next") { model.moveQueued(t.id, before: top.id) }
        }
        if t.run == .running || t.run == .queued { Button(t.run == .running ? "Cancel review" : "Remove from queue") { model.cancel(t.id) } }
        if t.run != .running && t.run != .queued { Button(t.run == .failed ? "Retry" : "Re-review") { model.enqueue(t.id, reason: t.run == .failed ? .retry : .rerun) } }
        Menu("Snooze") {
            Button("1 hour") { model.snooze(t.id, until: Date().addingTimeInterval(3600)) }
            Button("Until tomorrow") { model.snooze(t.id, until: tomorrowMorning()) }
            Button("Until next push") { model.snooze(t.id, until: nil) }
        }
        Button("Dismiss") { model.dismiss(t.id) }
        Divider()
        Button("Open in \(t.mr.provider.name)") { model.open(t.mr.webURL) }
        Button("Copy link") { model.copy(t.mr.webURL, toast: "Copied link") }
    }

    // MARK: empty + footer

    var emptyLine: some View {
        let (text, symbol, color): (String, String, Color) = filter.isEmpty ? emptyCopy : ("No matches.", "magnifyingglass", RB.faint)
        return VStack {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                Text(text).foregroundStyle(RB.mute)
            }
            .padding(.horizontal, 16).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
    }

    var emptyCopy: (String, String, Color) {
        switch tab {
        case .decide: model.runningCount > 0
            ? ("Nothing to decide. \(model.runningCount) review\(model.runningCount == 1 ? "" : "s") running.", "checkmark.seal", RB.green)
            : ("You're up to date. Nothing to decide.", "checkmark.seal", RB.green)
        case .progress: ("No reviews running or queued.", "clock", RB.faint)
        case .waiting: ("No one owes you changes.", "hourglass", RB.faint)
        case .failed: ("No failures.", "checkmark.circle", RB.green)
        case .done: ("Nothing closed today yet.", "tray", RB.faint)
        }
    }

    var footer: some View {
        let busy = model.runningCount > 0 && !model.offline
        let slots = model.settings.concurrency
        return HStack(spacing: 12) {
            HStack(spacing: 5) {
                if busy { Spinner(color: RB.blue) } else { Image(systemName: "pause").font(.system(size: 9, weight: .bold)).foregroundStyle(RB.grey) }
                Text(model.offline ? "Paused · offline" : busy ? "Running \(model.runningCount) of \(slots) slot\(slots == 1 ? "" : "s")" : "Idle · 0 of \(slots) slot\(slots == 1 ? "" : "s")")
                    .monospacedDigit()
            }
            if model.capReached { Tag(text: "Daily cap reached", symbol: "dollarsign.circle", color: RB.orange) }
            Spacer()
            Button { model.settings.autoReviewPaused.toggle() } label: {
                HStack(spacing: 6) {
                    Capsule().fill(model.settings.autoReviewPaused ? RB.faint : RB.key)
                        .frame(width: 24, height: 14)
                        .overlay(alignment: model.settings.autoReviewPaused ? .leading : .trailing) { Circle().fill(RB.pop).frame(width: 10, height: 10).padding(2) }
                    Text("Auto-review")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Pause automatic reviews. Manual reviews still run.")
            .accessibilityLabel("Auto-review \(model.settings.autoReviewPaused ? "off" : "on")")
            Menu {
                Picker("Default engine", selection: $model.settings.defaultEngine) {
                    ForEach(EngineKind.allCases, id: \.self) { Text($0.name).tag($0) }
                }
            } label: {
                HStack(spacing: 4) { Image(systemName: "cpu"); Text(model.settings.defaultEngine.name) }
                    .fontWeight(.medium).foregroundStyle(RB.ink)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Engine \(model.settings.defaultEngine.name)")
        }
        .font(RB.small).foregroundStyle(RB.mute)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

func tomorrowMorning() -> Date {
    let cal = Calendar.current
    let t = cal.date(byAdding: .day, value: 1, to: Date())!
    return cal.date(bySettingHour: 9, minute: 0, second: 0, of: t)!
}

struct FirstRunView: View {
    @EnvironmentObject var router: WindowRouter
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect a code host").font(.system(size: 15, weight: .medium)).foregroundStyle(RB.head)
                Text("ReviewBar reviews MRs where you're reviewer or assignee. It drafts findings — you decide what gets posted. Nothing is posted or approved on its own.")
                    .foregroundStyle(RB.mute).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                hostButton("Connect GitLab", "gitlab.com or self-managed · api scope", .gitlab)
                Hairline()
                hostButton("Connect GitHub", "github.com or Enterprise · repo scope", .github)
            }
            .rbCard()
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("Tokens are stored in the macOS Keychain, or reused from your glab / gh login. Review engine: Claude (change later in Settings).")
                .font(RB.small).foregroundStyle(RB.faint).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.vertical, 22)
    }

    func hostButton(_ title: String, _ sub: String, _ p: Provider) -> some View {
        Button { router.settings() } label: {
            HStack(spacing: 10) {
                ProviderGlyph(provider: p).scaleEffect(1.4).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium).foregroundStyle(RB.head)
                    Text(sub).font(RB.small).foregroundStyle(RB.mute)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(RB.mute)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
