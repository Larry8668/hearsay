import AppKit
import SwiftUI

/// Lane colours and the small pieces both the recording bar and the main window draw them with.
///
/// The two lane colours used everywhere: me = cool blue, them = warm orange. With speakers told
/// apart, each speaker of a lane gets its own tint of the lane's colour (blues for the
/// microphone, oranges for system audio) in the order they first spoke.
///
/// The bright tints (#5AA9FF / #FF9F5A) read well on dark backgrounds but are too pale on white
/// (≈2.5:1), so the adaptive variants darken them in light mode to clear 4.5:1 for small text;
/// every speaker tint has such a pair.
enum LaneColors {
    static let meBright = NSColor(srgbRed: 0x5A / 255, green: 0xA9 / 255, blue: 0xFF / 255, alpha: 1)
    static let themBright = NSColor(srgbRed: 0xFF / 255, green: 0x9F / 255, blue: 0x5A / 255, alpha: 1)
    private static let meDeep = NSColor(srgbRed: 0x0B / 255, green: 0x5C / 255, blue: 0xC4 / 255, alpha: 1)
    private static let themDeep = NSColor(srgbRed: 0xB0 / 255, green: 0x4A / 255, blue: 0x06 / 255, alpha: 1)

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// (dark background, light background) per speaker position; the first is the lane colour.
    private static let meTints: [(NSColor, NSColor)] = [
        (meBright, meDeep), (rgb(0x4FD1C5), rgb(0x0E7C7B)), (rgb(0x9A8CFF), rgb(0x4A3BC9)), (rgb(0x3EC9F5), rgb(0x0A6E99)),
    ]
    private static let themTints: [(NSColor, NSColor)] = [
        (themBright, themDeep), (rgb(0xFFC24A), rgb(0x8A5A00)), (rgb(0xFF7A6E), rgb(0xB3261E)), (rgb(0xE8A67A), rgb(0x7A4A2A)),
    ]

    private static func tint(_ v: Voice, _ roster: SpeakerRoster) -> (NSColor, NSColor) {
        let table = v.speaker == .me ? meTints : themTints
        guard let id = v.speakerID, let i = roster.ids(in: v.stream).firstIndex(of: id) else { return table[0] }
        return table[i % table.count]
    }

    /// Fixed bright tint (the recording bar is always dark).
    static func bright(_ s: Speaker) -> Color { Color(nsColor: s == .me ? meBright : themBright) }
    static func bright(_ v: Voice, _ roster: SpeakerRoster) -> Color { Color(nsColor: tint(v, roster).0) }

    /// Follows the window's light/dark appearance.
    static func adaptive(_ s: Speaker) -> Color { adaptive(Voice(speaker: s), SpeakerRoster()) }
    static func adaptive(_ v: Voice, _ roster: SpeakerRoster) -> Color {
        let (dark, light) = tint(v, roster)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// "me", "them · Zoom", or "them" when the app is unknown: the built-in label.
    static func chipLabel(_ s: Speaker, app: String?) -> String {
        VoiceNames.defaultChipLabel(Voice(speaker: s, app: app))
    }

    /// The label with names applied: the transcript's own name for the voice, else Settings ▸
    /// Your name where it would say "me", else the generated label, with a diarized speaker
    /// appended ("Speaker 2", "them · Zoom · Speaker 2"); see `VoiceNames`.
    static func chipLabel(_ v: Voice, names: VoiceNames) -> String { names.chipLabel(v) }

    /// Generated labels only (no names): "Speaker 2" on the microphone lane (still "me" while it
    /// is the only voice, or for the enrolled voice), "them · Zoom · Speaker 2" for system audio.
    static func chipLabel(_ v: Voice, _ roster: SpeakerRoster) -> String { chipLabel(v, names: VoiceNames(roster: roster)) }
    static func chipLabel(_ line: TranscriptLine, _ roster: SpeakerRoster) -> String { chipLabel(Voice(line), roster) }
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
