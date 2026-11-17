import SwiftUI
import AppKit

/// "Ink after midnight" tokens, copied from design-source/rb.js. Dark and light resolve per appearance.
/// Status colours (red…yellow) are for status only: never for chrome or emphasis.
enum RB {
    private static func c(_ light: UInt32, _ dark: UInt32, la: CGFloat = 1, da: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let isDark = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let v = isDark ? dark : light, a = isDark ? da : la
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
        })
    }
    static let desk   = c(0xf6f6f8, 0x08090a)
    static let pop    = c(0xffffff, 0x0f1011)
    static let sunk   = c(0xf2f2f5, 0x141516)
    static let hover  = sunk
    static let head   = c(0x1d1d1f, 0xf7f8f8)
    static let ink    = c(0x3a3a40, 0xd0d6e0)
    static let mute   = c(0x6b6b73, 0x8a8f98)
    static let faint  = c(0x8e8e95, 0x62666d)
    static let line   = c(0x000000, 0xffffff, la: 0.08, da: 0.08)
    static let edge   = c(0x000000, 0xffffff, la: 0.12, da: 0.12)
    static let btn    = c(0x000000, 0xffffff, la: 0.05, da: 0.05)
    static let btnH   = c(0x000000, 0xffffff, la: 0.08, da: 0.09)
    static let key    = c(0x1d1d1f, 0xe6e6e6)
    static let keyH   = c(0x2c2c30, 0xf2f2f2)
    static let keyTx  = c(0xf6f6f8, 0x111214)
    static let seg    = c(0xffffff, 0x26272a)
    static let red    = c(0xc8302b, 0xff6b66)
    static let orange = c(0xa65500, 0xffa54d)
    static let green  = c(0x1a7f43, 0x4ccb7a)
    static let blue   = c(0x0b62c4, 0x5aa6ff)
    static let purple = c(0x7b45c9, 0xc39bff)
    static let yellow = c(0x8a6a00, 0xf2c94c)
    static let grey   = mute

    // Type: SF Pro (the design's first choice), 510 weight ≈ .medium.
    static let body = Font.system(size: 12)
    static let small = Font.system(size: 11)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let title = Font.system(size: 16, weight: .medium)
    static let label = Font.system(size: 10.5, weight: .medium)
}

/// Primary action: the pale "key" button. One per surface.
struct KeyButton: ButtonStyle {
    var height: CGFloat = 36
    var fill = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: height > 28 ? 12 : 11, weight: .medium))
            .padding(.horizontal, height > 28 ? 12 : 10)
            .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
            .frame(height: height)
            .foregroundStyle(RB.keyTx)
            .background(RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? RB.keyH : RB.key))
            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// Secondary action: quiet translucent button.
struct SoftButton: ButtonStyle {
    var height: CGFloat = 36
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: height > 28 ? 12 : 11, weight: .medium))
            .padding(.horizontal, height > 28 ? 12 : 10)
            .frame(height: height)
            .foregroundStyle(RB.head)
            .background(RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? RB.btnH : RB.btn))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// Toolbar text/icon button: transparent until hovered.
struct GhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Ghost(configuration: configuration) }
    private struct Ghost: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(RB.body)
                .padding(.horizontal, 6)
                .frame(minWidth: 26, minHeight: 26)
                .foregroundStyle(hover ? RB.ink : RB.mute)
                .background(RoundedRectangle(cornerRadius: 8).fill(hover || configuration.isPressed ? RB.hover : .clear))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

extension View {
    /// Bordered card from the design: 1px line, 12px radius.
    func rbCard(fill: Color = .clear) -> some View {
        background(RoundedRectangle(cornerRadius: 12).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(RB.line))
    }
}

/// 1px hairline in the line token.
struct Hairline: View {
    var body: some View { Rectangle().fill(RB.line).frame(height: 1) }
}

/// The Signal Bar mark: one line (the menu bar), a solid bead (what the AI did), an open bead (what you decided).
struct SignalBar: Shape {
    var youDecided = false
    func path(in r: CGRect) -> Path {
        var p = Path()
        let y = r.midY, rad = r.height * 0.24
        p.addRoundedRect(in: CGRect(x: r.minX, y: y - r.height * 0.055, width: r.width, height: r.height * 0.11), cornerSize: CGSize(width: 1, height: 1))
        p.addEllipse(in: CGRect(x: r.minX + r.width * 0.33 - rad, y: y - rad, width: rad * 2, height: rad * 2))
        return p
    }
}

struct SignalBarMark: View {
    var size: CGFloat = 15
    var color: Color = RB.head
    var body: some View {
        let w = size * 1.7, h = size * 0.9, rad = h * 0.24
        ZStack {
            SignalBar().fill(color)
            Circle().fill(RB.pop).frame(width: rad * 2, height: rad * 2).offset(x: w * 0.68 - w / 2)
            Circle().strokeBorder(color, lineWidth: max(1.2, size / 11)).frame(width: rad * 2, height: rad * 2).offset(x: w * 0.68 - w / 2)
        }
        .frame(width: w, height: h)
        .accessibilityHidden(true)
    }
}
