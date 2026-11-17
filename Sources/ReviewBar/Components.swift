import SwiftUI
import ReviewBarCore

/// Status language from the design: icon + label + colour, never colour alone.
struct StatusStyle {
    var symbol: String
    var color: Color
    var label: String
    var animated = false
}

// Icon map mirrors design-source/Inbox.dc.html RUN/DEC tables.
@MainActor
func runStyle(_ t: Tracked, model: AppModel) -> StatusStyle {
    switch t.run {
    case .queued where t.reviewedSHA != nil && t.isOutdated && t.queueReason == .newPush:
        return StatusStyle(symbol: "arrow.triangle.2.circlepath", color: RB.purple, label: "New commits · re-review queued")
    case .queued:
        var label = "Queued"
        if let pos = model.queuePosition(t.id) {
            label += " · #\(pos)"
            let q = model.queuedSorted
            if pos > 1 { label += " · after \(q[pos - 2].mr.ref)" }
            else if let r = model.items.values.first(where: { $0.run == .running }) { label += " · after \(r.mr.ref)" }
        }
        return StatusStyle(symbol: "clock", color: RB.grey, label: label)
    case .running:
        return StatusStyle(symbol: "circle.dashed", color: RB.blue, label: "Reviewing", animated: true)
    case .failed:
        return StatusStyle(symbol: "xmark.octagon", color: RB.red, label: "Failed · \(shortFailure(t.failure))")
    case .interrupted:
        return StatusStyle(symbol: "xmark.octagon", color: RB.red, label: "Interrupted")
    case .discovered:
        return StatusStyle(symbol: "circle.dashed", color: RB.faint, label: "Not reviewed")
    case .skipped:
        return StatusStyle(symbol: "minus.circle", color: RB.grey, label: "Skipped")
    case .completed:
        if t.isOutdated { return StatusStyle(symbol: "arrow.triangle.2.circlepath", color: RB.purple, label: "New commits since review") }
        switch t.verdict {
        case .clean: return StatusStyle(symbol: "checkmark.seal", color: RB.green, label: "Clean")
        case .incomplete: return StatusStyle(symbol: "circle.lefthalf.filled", color: RB.yellow, label: "Partial review")
        default:
            let c = t.counts ?? SeverityCounts()
            return StatusStyle(symbol: "exclamationmark.triangle", color: c.blocker > 0 ? RB.red : RB.orange, label: c.short)
        }
    }
}

func shortFailure(_ s: String?) -> String {
    guard let s else { return "error" }
    if s.localizedCaseInsensitiveContains("auth") { return "auth expired" }
    if s.localizedCaseInsensitiveContains("timed out") { return "timed out" }
    if s.localizedCaseInsensitiveContains("not found") { return "CLI missing" }
    return String(s.prefix(28))
}

func decisionStyle(_ t: Tracked) -> StatusStyle? {
    switch t.decision {
    case .approved, .approvedWithComments: StatusStyle(symbol: "checkmark.circle", color: RB.green, label: t.decision.label)
    case .findingsPosted: StatusStyle(symbol: "bubble.left", color: RB.blue, label: "\(t.postedCount) comment\(t.postedCount == 1 ? "" : "s") posted")
    case .dismissed: StatusStyle(symbol: "nosign", color: RB.grey, label: "Dismissed")
    case .handledManually: StatusStyle(symbol: "nosign", color: RB.grey, label: t.decision.label)
    case .needsDecision: t.run == .completed && !t.isOutdated ? StatusStyle(symbol: "smallcircle.filled.circle", color: RB.ink, label: "Needs decision") : nil
    case .none: nil
    }
}

struct Chip: View {
    var style: StatusStyle
    var body: some View {
        HStack(spacing: 4) {
            if style.animated { Spinner(color: style.color) }
            else if !style.symbol.isEmpty { Image(systemName: style.symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(style.color) }
            Text(style.label).foregroundStyle(RB.ink)
        }
        .font(RB.small)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(style.label)
    }
}

/// Dashed ring that turns once every 2.5 s, as in the design's "running" icon.
struct Spinner: View {
    var color: Color
    var size: CGFloat = 11
    @State private var spin = false
    var body: some View {
        Circle()
            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [2.4, 2]))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 2.5).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
            .accessibilityHidden(true)
    }
}

struct SeverityChip: View {
    var severity: Severity
    var body: some View {
        let (bg, fg, border): (Color, Color, Color) = switch severity {
        case .blocker: (RB.red.opacity(0.14), RB.red, .clear)
        case .shouldFix: (RB.orange.opacity(0.14), RB.orange, .clear)
        case .optional: (RB.btn, RB.mute, .clear)
        case .nit: (.clear, RB.mute, RB.edge)
        }
        Text(severity.label)
            .font(.system(size: 10, weight: .medium)).tracking(0.3)
            .padding(.horizontal, 6).frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 6).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border))
            .foregroundStyle(fg)
            .accessibilityLabel("Severity \(severity.label)")
    }
}

struct Tag: View {
    var text: String
    var symbol: String? = nil
    var color: Color = RB.faint
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(color)
    }
}

struct ProviderGlyph: View {
    var provider: Provider
    var body: some View {
        Image(systemName: provider == .gitlab ? "chevron.left.forwardslash.chevron.right" : "arrow.triangle.pull")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(RB.mute)
            .frame(width: 12)
            .accessibilityLabel(provider.name)
    }
}

struct Avatar: View {
    var name: String
    var body: some View {
        Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(RB.mute)
            .frame(width: 18, height: 18)
            .background(Circle().fill(RB.sunk))
            .overlay(Circle().strokeBorder(RB.line))
            .help(name)
            .accessibilityHidden(true)
    }
}

struct MRRow: View {
    @EnvironmentObject var model: AppModel
    var t: Tracked
    var selected: Bool
    var showRepo = true   // off under a repo header
    @State private var hover = false

    private var active: Bool { hover || selected }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProviderGlyph(provider: t.mr.provider)
                    if showRepo { Text(t.mr.repoShort).foregroundStyle(RB.mute).fixedSize() }
                    Text(t.mr.ref).font(RB.mono).foregroundStyle(RB.mute).fixedSize()
                    Text(t.mr.title).fontWeight(.medium).foregroundStyle(RB.head).lineLimit(1).truncationMode(.tail)
                }
                HStack(spacing: 10) {
                    runChip
                    if let d = decisionStyle(t) {
                        HStack(spacing: 4) {
                            Image(systemName: d.symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(d.color)
                            Text(d.label).foregroundStyle(RB.mute).lineLimit(1)
                        }
                    }
                }
                .font(RB.small)
            }
            Spacer(minLength: 0)
            ZStack(alignment: .trailing) {
                HStack(spacing: 8) {
                    Avatar(name: t.mr.authorName.isEmpty ? t.mr.author : t.mr.authorName)
                    Text(relative(t.mr.updatedAt)).font(RB.small.monospacedDigit()).foregroundStyle(RB.faint).frame(width: 28, alignment: .trailing)
                }
                .opacity(active && quickAction != nil ? 0 : 1)
                if let a = quickAction {
                    Group {
                        if a.primary { Button(a.label, action: a.run).buttonStyle(KeyButton(height: 24)) }
                        else { Button(a.label, action: a.run).buttonStyle(SoftButton(height: 24)) }
                    }
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                }
            }
            .frame(width: 76, alignment: .trailing)
            .animation(.easeOut(duration: 0.12), value: active)
        }
        .font(RB.body)
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 8).fill(active ? RB.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0; if $0 { model.selection = t.id } }
        .onTapGesture { model.selection = t.id; model.openDetail(t.id) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(t.mr.repoShort) \(t.mr.ref), \(t.mr.title), \(runStyle(t, model: model).label)\(decisionStyle(t).map { ", " + $0.label } ?? "")")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder var runChip: some View {
        let s = runStyle(t, model: model)
        if t.run == .running, let r = model.run(t.currentRunID) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Chip(style: StatusStyle(symbol: s.symbol, color: s.color, label: "Reviewing · \(elapsed(ctx.date.timeIntervalSince(r.startedAt)))", animated: true))
            }
        } else {
            Chip(style: s)
        }
    }

    var quickAction: (label: String, primary: Bool, run: () -> Void)? {
        switch t.run {
        case .running, .queued: ("Cancel", false, { model.cancel(t.id) })
        case .failed, .interrupted: ("Retry", true, { model.enqueue(t.id, reason: .retry) })
        case .discovered, .skipped: ("Review", true, { model.enqueue(t.id, reason: .manual) })
        case .completed:
            if t.isOutdated { ("Re-review", true, { model.enqueue(t.id, reason: .rerun) }) }
            else if t.decision == .needsDecision {
                t.verdict == .clean ? ("Approve", true, { model.route = .approve(t.id) }) : ("Review", true, { model.openDetail(t.id) })
            } else { ("Open", false, { model.openDetail(t.id) }) }
        }
    }
}

struct Toast: View {
    var text: String
    var body: some View {
        Text(text)
            .font(RB.body)
            .foregroundStyle(RB.head)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(RB.seg))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RB.edge))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
            .padding(.bottom, 64)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Inline notice card. Colour lives in the icon only; the card stays neutral.
struct Banner: View {
    var symbol: String
    var color: Color
    var title: String
    var message: String? = nil
    var actions: [(String, () -> Void)] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(color).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium).foregroundStyle(RB.head)
                    if let message { Text(message).foregroundStyle(RB.mute).fixedSize(horizontal: false, vertical: true) }
                }
            }
            if !actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(actions.indices, id: \.self) { i in
                        if i == 0 { Button(actions[i].0, action: actions[i].1).buttonStyle(KeyButton(height: 24)) }
                        else { Button(actions[i].0, action: actions[i].1).buttonStyle(SoftButton(height: 24)) }
                    }
                }
                .padding(.leading, 19)
            }
        }
        .font(RB.body)
        .lineSpacing(2)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rbCard(fill: RB.sunk)
    }
}

/// Back button + trailing "Open in GitLab ↗", shared by every non-inbox screen.
struct TopBar<Trailing: View>: View {
    var title = "Inbox"
    var back: () -> Void
    @ViewBuilder var trailing: Trailing
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: back) {
                    HStack(spacing: 2) { Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)); Text(title) }
                }
                .buttonStyle(GhostButton())
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityLabel("Back to \(title)")
                Spacer()
                trailing
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Hairline()
        }
    }
}

/// Repo · ref · author, title, branch → target and SHA pill.
struct MRHeader: View {
    @EnvironmentObject var model: AppModel
    var mr: MergeRequest
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ProviderGlyph(provider: mr.provider)
                Text(mr.repoShort)
                Text(mr.ref).font(RB.mono)
                Text("·")
                Text(mr.authorName.isEmpty ? mr.author : mr.authorName)
            }
            .foregroundStyle(RB.mute)
            Text(mr.title).font(RB.title).foregroundStyle(RB.head).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack(spacing: 6) {
                if !mr.sourceBranch.isEmpty {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                    Text(mr.sourceBranch).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "arrow.right").font(.system(size: 9))
                    Text(mr.targetBranch).fixedSize()
                }
                Spacer(minLength: 4)
                Button {
                    model.copy(mr.headSHA, toast: nil); copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    HStack(spacing: 4) { Text(copied ? "Copied" : String(mr.headSHA.prefix(7))); Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9)) }
                        .font(RB.monoSmall).foregroundStyle(RB.head)
                        .padding(.horizontal, 5).frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 8).fill(RB.btn))
                }
                .buttonStyle(.plain).help("Copy head SHA")
            }
            .font(RB.mono).foregroundStyle(RB.mute)
        }
        .font(RB.body)
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}
