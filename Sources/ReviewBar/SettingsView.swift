import SwiftUI
import UniformTypeIdentifiers
import ReviewBarCore

// Layout from design-source/Settings.dc.html: icon tab bar on sunk, then 180px label column + control column, hairline rows.

enum SettingsTab: String, CaseIterable {
    case accounts, scope, engine, notifications, safety, general
    var title: String {
        switch self {
        case .accounts: "Accounts"
        case .scope: "Scope"
        case .engine: "Review engine"
        case .notifications: "Notifications"
        case .safety: "Safety"
        case .general: "General"
        }
    }
    var icon: String {
        switch self {
        case .accounts: "person.crop.circle"
        case .scope: "line.3.horizontal.decrease"
        case .engine: "cpu"
        case .notifications: "bell"
        case .safety: "checkmark.shield"
        case .general: "slider.horizontal.3"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("reviewbar.settings.tab") private var tab: SettingsTab = .accounts

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(SettingsTab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.icon).font(.system(size: 16)).frame(height: 20)
                            Text(t.title).font(RB.small)
                        }
                        .frame(width: 84).padding(.top, 6).padding(.bottom, 5)
                        .foregroundStyle(tab == t ? RB.head : RB.mute)
                        .background(RoundedRectangle(cornerRadius: 8).fill(tab == t ? RB.btnH : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(SettingsTab.allCases.firstIndex(of: t)! + 1)")), modifiers: .command)
                }
            }
            .padding(.top, 4).padding(.bottom, 6)
            .frame(maxWidth: .infinity)
            .background(RB.sunk)
            Hairline()
            ScrollView {
                VStack(spacing: 0) {
                    switch tab {
                    case .accounts: AccountsTab()
                    case .scope: ScopeTab()
                    case .engine: EngineTab()
                    case .notifications: NotificationsTab()
                    case .safety: SafetyTab()
                    case .general: GeneralTab()
                    }
                }
                .padding(.horizontal, 28).padding(.top, 6).padding(.bottom, 20)
            }
        }
        .font(RB.body)
        .foregroundStyle(RB.ink)
        .toggleStyle(RBSwitch())
        .background(RB.pop)
        .frame(minWidth: 620, minHeight: 480)
    }
}

// MARK: Building blocks

/// One settings row: label on the left, controls and an optional note on the right.
struct SRow<Content: View>: View {
    var label: String
    var note: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(RB.ink)
                    .frame(width: 180, alignment: .leading).padding(.top, 3)
                VStack(alignment: .leading, spacing: 6) {
                    content
                    if let note {
                        Text(note).font(RB.small).foregroundStyle(RB.mute).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 11)
            Hairline()
        }
    }
}

/// The design's 28×16 switch: key colour when on, faint when off.
struct RBSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { SwitchBody(configuration: configuration) }
    private struct SwitchBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 8) {
                    Capsule().fill(configuration.isOn ? RB.key : RB.faint)
                        .frame(width: 28, height: 16)
                        .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                            Circle().fill(RB.pop).frame(width: 12, height: 12).padding(2)
                        }
                        .animation(.easeOut(duration: 0.12), value: configuration.isOn)
                        .opacity(enabled ? 1 : 0.4)
                    configuration.label.font(RB.body).foregroundStyle(RB.ink).multilineTextAlignment(.leading)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

extension View {
    /// Sunk, hairline-bordered field from the design.
    func rbField(width: CGFloat? = 220, mono: Bool = false) -> some View {
        textFieldStyle(.plain)
            .font(mono ? RB.mono : RB.body)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(RB.sunk))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RB.line))
    }
}

/// A value with − / + controls, shown like the design's select.
struct RBStepper: View {
    var text: String
    @Binding var value: Int
    var `in`: ClosedRange<Int>
    var step = 1
    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(RB.body).frame(width: 150, alignment: .leading)
                .padding(.horizontal, 8).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 8).fill(RB.sunk))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RB.line))
            Stepper("", value: $value, in: `in`, step: step).labelsHidden()
        }
    }
}

// MARK: Accounts

struct AccountsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var provider: Provider = .gitlab
    @State private var host = "gitlab.com"
    @State private var useCLI = true
    @State private var token = ""
    @State private var status: [UUID: String] = [:]
    @State private var cliFound: Bool?

    var body: some View {
        if model.settings.accounts.isEmpty {
            SRow(label: "Accounts", note: "Add GitLab or GitHub below. ReviewBar reads diffs and posts only when you confirm.") {
                Text("No accounts yet.").foregroundStyle(RB.mute).padding(.top, 3)
            }
        }
        ForEach(model.settings.accounts) { a in
            let s = status[a.id] ?? model.accountErrors[a.id] ?? model.usernames[a.id].map { "Connected as \($0)" }
            let ok = s?.hasPrefix("Connected") ?? true
            SRow(label: a.provider.name,
                 note: a.useCLIAuth ? "Uses your \(a.provider == .gitlab ? "glab" : "gh") login." : "Token stored in the macOS Keychain. Needs \(a.provider == .gitlab ? "api" : "repo") scope.") {
                HStack(spacing: 10) {
                    ProviderGlyph(provider: a.provider)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.host + (model.usernames[a.id].map { " · @\($0)" } ?? "")).font(RB.mono).foregroundStyle(RB.head).lineLimit(1)
                        if let s {
                            HStack(spacing: 4) {
                                Image(systemName: ok ? "checkmark.circle" : "xmark.octagon").foregroundStyle(ok ? RB.green : RB.red)
                                Text(ok ? "Connected" : s).foregroundStyle(RB.mute).lineLimit(2)
                            }
                            .font(RB.small)
                        }
                        if let note = model.skippedMRs[a.id] {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(RB.orange)
                                Text(note).foregroundStyle(RB.mute).lineLimit(2)
                            }
                            .font(RB.small)
                        }
                    }
                    Spacer(minLength: 4)
                    Toggle("", isOn: binding(a.id, \.enabled)).labelsHidden().help("Enabled")
                    Button("Test") { Task { status[a.id] = await model.testAccount(a) } }.buttonStyle(SoftButton(height: 24))
                    Button {
                        if !a.useCLIAuth { Keychain.delete(Keychain.key(a)) }
                        model.settings.accounts.removeAll { $0.id == a.id }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(GhostButton()).help("Remove account")
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RB.line))
            }
        }
        SRow(label: "Add account") {
            Picker("", selection: $provider) {
                ForEach(Provider.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            .onChange(of: provider) { _, p in host = p.defaultHost }
            TextField("", text: $host, prompt: Text("gitlab.example.com")).rbField(mono: true)
            Picker("", selection: $useCLI) {
                Text("Reuse \(cli) login").tag(true)
                Text("Access token").tag(false)
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            if useCLI {
                if let found = cliFound {
                HStack(spacing: 4) {
                    Image(systemName: found ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(found ? RB.green : RB.orange)
                    Text(found ? "\(cli) found" : "\(cli) not found. Install it or use a token.").foregroundStyle(RB.mute)
                }
                .font(RB.small)
                }
            } else {
                SecureField("", text: $token, prompt: Text("Token")).rbField(mono: true)
                Text("Scope: \(provider == .gitlab ? "api" : "repo"). Stored only in the macOS Keychain.").font(RB.small).foregroundStyle(RB.mute)
            }
            Button("Add and test") { add() }
                .buttonStyle(KeyButton(height: 26))
                .disabled(host.isEmpty || duplicate || (!useCLI && token.isEmpty))
                .padding(.top, 2)
            if duplicate {
                Text("\(provider.name) · \(host) is already added. Use Test on it above.").font(RB.small).foregroundStyle(RB.mute)
            }
        }
        // Lookup can spawn a login shell, so never run it during layout.
        .task(id: provider) {
            cliFound = nil
            let c = cli
            cliFound = await Task.detached { Shell.which(c) != nil }.value
        }
    }

    var cli: String { provider == .gitlab ? "glab" : "gh" }

    func binding<T>(_ id: UUID, _ kp: WritableKeyPath<Account, T>) -> Binding<T> {
        Binding(get: { model.settings.accounts.first { $0.id == id }![keyPath: kp] },
                set: { v in if let i = model.settings.accounts.firstIndex(where: { $0.id == id }) { model.settings.accounts[i][keyPath: kp] = v } })
    }

    var duplicate: Bool {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        return model.settings.accounts.contains { $0.provider == provider && $0.host.lowercased() == h }
    }

    func add() {
        guard !duplicate else { return }
        let a = Account(provider: provider, host: host.trimmingCharacters(in: .whitespaces), useCLIAuth: useCLI)
        if !useCLI { Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: Keychain.key(a)) }
        token = ""
        model.settings.accounts.append(a)
        Task {
            status[a.id] = await model.testAccount(a)
            model.poll()
        }
    }
}

// MARK: Scope

struct ScopeTab: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: UUID?

    var body: some View {
        if model.settings.accounts.isEmpty {
            SRow(label: "Scope", note: "Scope is set per account.") {
                Text("Add an account first.").foregroundStyle(RB.mute).padding(.top, 3)
            }
        } else {
            if model.settings.accounts.count > 1 {
                SRow(label: "Account") {
                    Picker("", selection: $selected) {
                        ForEach(model.settings.accounts) { Text("\($0.provider.name) · \($0.host)").tag(Optional($0.id)) }
                    }
                    .labelsHidden().frame(width: 260)
                }
            }
            if let i = model.settings.accounts.firstIndex(where: { $0.id == (selected ?? model.settings.accounts.first?.id) }) {
                let s = $model.settings.accounts[i].scope
                SRow(label: "Review when I am") {
                    Toggle("Reviewer", isOn: s.reviewRequested)
                    Toggle("Assignee", isOn: s.assigned)
                    Toggle("Author (self-review)", isOn: s.authored)
                }
                SRow(label: "Draft MRs") {
                    Toggle("Skip drafts until marked ready", isOn: s.skipDrafts)
                }
                SRow(label: "Watched repos", note: "One per line. Open MRs there show as Not reviewed with a Review button; they are not queued automatically.") {
                    TextField("", text: listBinding(s.watchedRepos, separator: "\n"), prompt: Text("group/repo"), axis: .vertical)
                        .lineLimit(3...8).rbField(width: nil, mono: true)
                }
                SRow(label: "Only with labels", note: "Comma separated. Empty means every label.") {
                    TextField("", text: listBinding(s.labelsInclude), prompt: Text("backend, payments")).rbField(width: nil, mono: true)
                }
                SRow(label: "Skip labels") {
                    TextField("", text: listBinding(s.labelsExclude), prompt: Text("wip, do-not-review")).rbField(width: nil, mono: true)
                }
            }
        }
    }

    func listBinding(_ b: Binding<[String]>, separator: String = ", ") -> Binding<String> {
        Binding(get: { b.wrappedValue.joined(separator: separator) },
                set: { b.wrappedValue = $0.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
    }
}

// MARK: Engine

struct EngineTab: View {
    @EnvironmentObject var model: AppModel
    @State private var testResult = ""
    @State private var testing = false
    @State private var found: [String: String] = [:]

    var body: some View {
        SRow(label: "Engine", note: "Claude and Codex both run as local CLIs. Your forge tokens are never passed to them.") {
            Picker("", selection: $model.settings.defaultEngine) {
                ForEach(EngineKind.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
        }
        SRow(label: "Models", note: "Leave empty to use each CLI's default.") {
            labeled("Claude") { TextField("", text: $model.settings.claudeModel, prompt: Text("default")).rbField(mono: true) }
            labeled("Codex") { TextField("", text: $model.settings.codexModel, prompt: Text("default")).rbField(mono: true) }
        }
        SRow(label: "CLI paths") {
            labeled("claude") { TextField("", text: $model.settings.claudePath, prompt: Text(found["claude"] ?? "looking…")).rbField(width: nil, mono: true) }
            labeled("codex") { TextField("", text: $model.settings.codexPath, prompt: Text(found["codex"] ?? "looking…")).rbField(width: nil, mono: true) }
        }
        // Lookup can spawn a login shell, so never run it during layout.
        .task {
            for c in ["claude", "codex"] { found[c] = await Task.detached { Shell.which(c) }.value ?? "not found" }
        }
        SRow(label: "Parallel reviews", note: "More slots finish sooner but use more of your plan.") {
            RBStepper(text: "\(model.settings.concurrency) slot\(model.settings.concurrency == 1 ? "" : "s")", value: $model.settings.concurrency, in: 1...2)
        }
        SRow(label: "Timeout") {
            RBStepper(text: "\(model.settings.timeoutMinutes) minutes", value: $model.settings.timeoutMinutes, in: 5...60, step: 5)
        }
        SRow(label: "Re-review after commits", note: "Waits this long after the last push before reviewing again.") {
            RBStepper(text: "\(model.settings.debounceMinutes) minutes", value: $model.settings.debounceMinutes, in: 0...60, step: 5)
        }
        SRow(label: "Daily cost cap", note: String(format: "0 turns the cap off. Spent today: $%.2f.", model.costToday)) {
            HStack(spacing: 6) {
                Text("$").foregroundStyle(RB.mute)
                TextField("", value: $model.settings.dailyCostCapUSD, format: .number).rbField(width: 90, mono: true)
            }
        }
        SRow(label: "Resource gate", note: "Prefixed to every engine run. Exit code 75 puts the review back in the queue as “Mac busy”.") {
            TextField("", text: $model.settings.gateCommand, prompt: Text("~/bin/gate run --")).rbField(width: nil, mono: true)
        }
        SRow(label: "Review guidance", note: "Optional Markdown file added to every review prompt.") {
            HStack(spacing: 8) {
                TextField("", text: $model.settings.guidancePath, prompt: Text("guidance.md")).rbField(width: nil, mono: true)
                Button("Choose…") {
                    let p = NSOpenPanel(); p.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
                    if p.runModal() == .OK, let u = p.url { model.settings.guidancePath = u.path }
                }
                .buttonStyle(SoftButton(height: 26))
            }
        }
        SRow(label: "Check") {
            HStack(spacing: 8) {
                Button(testing ? "Testing…" : "Test \(model.settings.defaultEngine.name) on a sample diff") { test() }
                    .buttonStyle(SoftButton(height: 26)).disabled(testing)
                if testing { ProgressView().controlSize(.small) }
            }
            if !testResult.isEmpty {
                Text(testResult).font(RB.monoSmall).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(RB.sunk))
            }
        }
    }

    func labeled<C: View>(_ name: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(name).font(RB.small).foregroundStyle(RB.mute).frame(width: 44, alignment: .leading)
            c()
        }
    }

    func test() {
        let s = model.settings, kind = s.defaultEngine
        testing = true; testResult = ""
        Task {
            let configured = (kind == .claude ? s.claudePath : s.codexPath).nilIfEmpty.map { ($0 as NSString).expandingTildeInPath }
            let found = await Task.detached { Shell.which(kind.rawValue) }.value
            guard let exe = configured ?? found else { testResult = "\(kind.rawValue) CLI not found"; testing = false; return }
            testResult = await Diagnostics.testEngine(kind, executable: exe, model: kind == .claude ? s.claudeModel : s.codexModel,
                                                      gate: Shell.split(s.gateCommand))
            testing = false
        }
    }
}

// MARK: Notifications

struct NotificationsTab: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        SRow(label: "Notify when") {
            Toggle("A review finishes, with severity counts", isOn: $model.settings.notifyCompleted)
            Toggle("A review fails", isOn: $model.settings.notifyFailed)
            Toggle("New commits land after my decision", isOn: $model.settings.notifyOutdated)
            Toggle("A re-review finishes", isOn: $model.settings.notifyReReview)
            Toggle("A review is queued", isOn: $model.settings.notifyQueued)
            Toggle("An MR is merged", isOn: $model.settings.notifyMerged)
        }
        SRow(label: "Nudge", note: "Once, during working hours.") {
            Toggle("Remind me after 4 hours without a decision", isOn: $model.settings.nudgeEnabled)
        }
        SRow(label: "Quiet hours", note: "Notifications still arrive, without sound or banners.") {
            Toggle("Deliver silently", isOn: $model.settings.quietHoursEnabled)
            HStack(spacing: 8) {
                time($model.settings.quietStartMinutes)
                Text("to").foregroundStyle(RB.mute)
                time($model.settings.quietEndMinutes)
            }
            .disabled(!model.settings.quietHoursEnabled)
        }
        SRow(label: "Daily digest") {
            Toggle("Send a digest", isOn: $model.settings.digestEnabled)
            HStack(spacing: 8) {
                Text("at").foregroundStyle(RB.mute)
                time($model.settings.digestMinutes)
            }
            .disabled(!model.settings.digestEnabled)
        }
        SRow(label: "Check") {
            Button("Send test notification") {
                model.notify(id: "test", title: "Review done · payments-api !628", body: "2 blockers, 1 should-fix · Add billing sync guard", actions: true)
            }
            .buttonStyle(SoftButton(height: 26))
        }
    }

    func time(_ b: Binding<Int>) -> some View {
        DatePicker("", selection: Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(b.wrappedValue * 60)) },
            set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); b.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0) }),
                   displayedComponents: .hourAndMinute)
            .labelsHidden().datePickerStyle(.field).fixedSize()
    }
}

// MARK: Safety

struct SafetyTab: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        SRow(label: "Posting", note: "ReviewBar never posts, approves or merges on its own. This cannot be turned off.") {
            Toggle("Always show the post sheet before commenting", isOn: .constant(true)).disabled(true)
        }
        SRow(label: "Head SHA check") {
            Toggle("Refuse to post or approve if the MR changed since review", isOn: .constant(true)).disabled(true)
        }
        SRow(label: "Risky approvals", note: "Applies when the review is outdated, partial, or the pipeline is failing.") {
            Toggle("Require a second confirmation", isOn: .constant(true)).disabled(true)
        }
        SRow(label: "Security findings", note: "Offers “Share privately” instead of an inline comment.") {
            Toggle("Never post security findings inline", isOn: $model.settings.neverPostSecurityInline)
        }
        SRow(label: "Pre-select severities", note: "Checked by default in the post sheet.") {
            ForEach(Severity.allCases, id: \.self) { s in
                Toggle(s.label, isOn: Binding(get: { model.settings.preselect.contains(s) },
                                              set: { on in
                                                  model.settings.preselect.removeAll { $0 == s }
                                                  if on { model.settings.preselect.append(s) }
                                              }))
            }
        }
    }
}

// MARK: General

struct GeneralTab: View {
    @EnvironmentObject var model: AppModel
    @State private var launch = LaunchAtLogin.enabled
    @State private var launchError: String?

    var body: some View {
        SRow(label: "Startup", note: launchError) {
            Toggle("Open at login", isOn: $launch)
                .onChange(of: launch) { _, on in
                    do { try LaunchAtLogin.set(on); launchError = nil } catch { launchError = error.localizedDescription; launch = LaunchAtLogin.enabled }
                }
        }
        SRow(label: "Sync every") {
            RBStepper(text: "\(model.settings.pollMinutes) minutes", value: $model.settings.pollMinutes, in: 2...30)
        }
        SRow(label: "Global shortcut", note: "Opens the ReviewBar popover from anywhere.") {
            Toggle(isOn: $model.settings.hotkeyEnabled) {
                HStack(spacing: 6) {
                    Text("Enable")
                    Text("⌥⌘R").font(RB.mono).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 5).fill(RB.sunk))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(RB.line))
                }
            }
        }
        SRow(label: "Data", note: "All state stays on this Mac. No analytics and no crash reporting.") {
            HStack(spacing: 8) {
                Text(model.store.dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(RB.mono).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(RB.sunk))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RB.line))
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([model.store.dir]) }
                    .buttonStyle(SoftButton(height: 26))
            }
            Button("Export audit log…") {
                let p = NSSavePanel(); p.nameFieldStringValue = "reviewbar-audit.json"
                if p.runModal() == .OK, let u = p.url { try? model.exportAudit(to: u) }
            }
            .buttonStyle(SoftButton(height: 26))
        }
        SRow(label: "Quit") {
            Button("Quit ReviewBar") { NSApp.terminate(nil) }.buttonStyle(SoftButton(height: 26))
        }
    }
}

// MARK: Run log viewer

struct RunLogView: View {
    @EnvironmentObject var model: AppModel
    let runID: String
    @State private var text = ""

    var body: some View {
        let r = model.run(runID)
        VStack(alignment: .leading, spacing: 8) {
            if let r {
                HStack(spacing: 14) {
                    Chip(style: r.status == .completed ? StatusStyle(symbol: "checkmark.circle", color: .green, label: "Completed")
                         : r.status == .running ? StatusStyle(symbol: "circle.dashed", color: .blue, label: "Running")
                         : StatusStyle(symbol: "xmark.octagon", color: .red, label: r.error ?? r.status.rawValue.capitalized))
                    Text("Started \(r.startedAt.formatted(date: .abbreviated, time: .standard))").font(.caption)
                    if let e = r.endedAt { Text("Ended \(e.formatted(date: .omitted, time: .standard))").font(.caption) }
                    if let c = r.exitCode { Text("Exit \(c)").font(.caption.monospaced()) }
                    Spacer()
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.logPath)]) }
                }
            }
            ScrollView {
                Text(text.isEmpty ? "(empty log)" : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
        .task {
            while !Task.isCancelled {
                if let r = model.run(runID) { text = (try? String(contentsOfFile: r.logPath, encoding: .utf8)) ?? "" }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
