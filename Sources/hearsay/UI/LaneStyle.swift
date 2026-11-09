import AppKit
import SwiftUI

/// Lane colours and the small pieces both the recording bar and the live panel draw them with.
///
/// The two lane colours used everywhere: me = cool blue, them = warm orange.
///
/// The bright tints (#5AA9FF / #FF9F5A) read well on dark backgrounds but are too pale on white
/// (≈2.5:1), so the adaptive variants darken them in light mode to clear 4.5:1 for small text.
enum LaneColors {
    static let meBright = NSColor(srgbRed: 0x5A / 255, green: 0xA9 / 255, blue: 0xFF / 255, alpha: 1)
    static let themBright = NSColor(srgbRed: 0xFF / 255, green: 0x9F / 255, blue: 0x5A / 255, alpha: 1)
    private static let meDeep = NSColor(srgbRed: 0x0B / 255, green: 0x5C / 255, blue: 0xC4 / 255, alpha: 1)
    private static let themDeep = NSColor(srgbRed: 0xB0 / 255, green: 0x4A / 255, blue: 0x06 / 255, alpha: 1)

    /// Fixed bright tint (the recording bar is always dark).
    static func bright(_ s: Speaker) -> Color { Color(nsColor: s == .me ? meBright : themBright) }

    /// Follows the window's light/dark appearance.
    static func adaptive(_ s: Speaker) -> Color {
        let (dark, light) = s == .me ? (meBright, meDeep) : (themBright, themDeep)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// "me", "them · Zoom", or "them" when the app is unknown.
    static func chipLabel(_ s: Speaker, app: String?) -> String {
        guard s == .them, let app = app else { return s.rawValue }
        return "them · \(AppNames.name(for: app))"
    }
}

/// Small capsule label: "me", "them · Zoom".
struct Chip: View {
    let text: String
    let color: Color
    var size: CGFloat = 10.5

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
    }
}

/// Three dots pulsing in turn: "someone is talking, text on its way".
struct TypingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
            let phase = Int(ctx.date.timeIntervalSinceReferenceDate * 5) % 6
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().frame(width: 4, height: 4).opacity(phase == i || phase == i + 1 ? 0.75 : 0.25)
                }
            }
            .foregroundStyle(.secondary)
            .animation(.easeInOut(duration: 0.2), value: phase)
        }
    }
}
