import AppKit
import Combine
import SwiftUI

/// The recording bar's scrolling waveform, drawn by an NSView instead of a SwiftUI `Canvas`.
/// WHY: a `@Published` change 20×/s made SwiftUI invalidate the hosting view, and each
/// invalidation ran a full constraint layout pass of the panel (NSWindow layoutIfNeeded) — about
/// 12% CPU for a 36-bar strip. This view subscribes to `AudioLevels` itself and only calls
/// `needsDisplay`, so SwiftUI never hears about a tick.
///
/// Upper half = me (blue), lower half = them (orange), meeting on the centre line; a silent lane
/// keeps a faint 1.5 pt line so both lanes are always visible.
final class WaveformNSView: NSView {
    static let barWidth: CGFloat = 2, gap: CGFloat = 2, height: CGFloat = 24
    static var size: CGSize { CGSize(width: CGFloat(AudioLevels.barCount) * (barWidth + gap) - gap, height: height) }

    private var frames: [AudioLevels.Frame] = []
    private var sub: AnyCancellable?

    func bind(_ audio: AudioLevels) {
        frames = audio.history
        sub = audio.$history.sink { [weak self] h in self?.frames = h; self?.needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { WaveformNSView.size }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let n = AudioLevels.barCount
        let mid = bounds.height / 2
        let half = min(11, bounds.height / 2)
        let me = NSColor(LaneColors.bright(.me)), them = NSColor(LaneColors.bright(.them))
        for (i, f) in frames.enumerated() {
            let x = CGFloat(i) * (Self.barWidth + Self.gap)
            // Older bars fade toward the left edge so the newest audio draws the eye.
            let age = min(1, 0.3 + CGFloat(i) / CGFloat(n) * 1.4)
            for (level, color, up) in [(f.me, me, true), (f.them, them, false)] {
                let h = CGFloat(level) * half
                let silent = h < 1.5
                let len = max(1.5, h)
                let r = CGRect(x: x, y: up ? mid : mid - len, width: Self.barWidth, height: len)
                ctx.setFillColor(color.withAlphaComponent((silent ? 0.4 : 0.95) * age).cgColor)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(Self.barWidth, len) / 2, cornerHeight: min(Self.barWidth, len) / 2, transform: nil))
                ctx.fillPath()
            }
        }
    }
}

/// SwiftUI wrapper. `audio` is captured once in `makeNSView`; SwiftUI has nothing to observe, so
/// level ticks never re-render the bar.
struct Waveform: NSViewRepresentable {
    let audio: AudioLevels
    func makeNSView(context: Context) -> WaveformNSView {
        let v = WaveformNSView(frame: CGRect(origin: .zero, size: WaveformNSView.size))
        v.bind(audio)
        return v
    }
    func updateNSView(_ view: WaveformNSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WaveformNSView, context: Context) -> CGSize? { WaveformNSView.size }
}
