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
///
/// The bar is wider than `AudioLevels.history` (36 frames, ≈2.4 s): a bar is drawn for every
/// frame and another between each pair (their mean), so the strip is twice as dense without
/// touching the level meter.
final class WaveformNSView: NSView {
    static let barWidth: CGFloat = 2, gap: CGFloat = 2, height: CGFloat = 24
    static let barCount = 2 * AudioLevels.barCount - 1
    static var size: CGSize { CGSize(width: CGFloat(barCount) * (barWidth + gap) - gap, height: height) }

    private var frames: [AudioLevels.Frame] = []
    private var sub: AnyCancellable?

    func bind(_ audio: AudioLevels) {
        frames = audio.history
        sub = audio.$history.sink { [weak self] h in self?.frames = h; self?.needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { WaveformNSView.size }
    override var isOpaque: Bool { false }

    // (Tried: rendering into our own bitmap and setting it as the layer's contents each tick.
    // Measurably MORE expensive than draw(_:): a new image upload per frame.)
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        var bars: [AudioLevels.Frame] = []
        bars.reserveCapacity(Self.barCount)
        for (i, f) in frames.enumerated() {
            if i > 0 { let p = frames[i - 1]; bars.append(.init(me: (p.me + f.me) / 2, them: (p.them + f.them) / 2)) }
            bars.append(f)
        }
        let n = bars.count
        let mid = bounds.height / 2
        let half = min(11, bounds.height / 2)
        // Plain pixel-aligned rects, batched per (lane, quantised opacity) and filled without
        // antialiasing: ~20 cheap fills a frame. Per-bar rounded-rect paths cost ~5% CPU at
        // 142 bars × 20 frames/s, nearly all of it rasterising the antialiased corner curves.
        var rects = Array(repeating: Array(repeating: [CGRect](), count: Self.alphaSteps + 1), count: 2)
        let scale = window?.backingScaleFactor ?? 2
        for (i, f) in bars.enumerated() {
            let x = CGFloat(i) * (Self.barWidth + Self.gap)
            // Older bars fade toward the left edge so the newest audio draws the eye.
            let age = min(1, 0.3 + CGFloat(i) / CGFloat(n) * 1.4)
            for (lane, level) in [f.me, f.them].enumerated() {
                let h = CGFloat(level) * half
                let len = (max(1.5, h) * scale).rounded() / scale
                let alpha = (h < 1.5 ? 0.4 : 0.95) * age
                rects[lane][Int((alpha * CGFloat(Self.alphaSteps)).rounded())]
                    .append(CGRect(x: x, y: lane == 0 ? mid : mid - len, width: Self.barWidth, height: len))
            }
        }
        ctx.setShouldAntialias(false)
        for (lane, color) in [Self.meColor, Self.themColor].enumerated() {
            for (step, group) in rects[lane].enumerated() where !group.isEmpty {
                ctx.setFillColor(color.copy(alpha: CGFloat(step) / CGFloat(Self.alphaSteps)) ?? color)
                ctx.fill(group)
            }
        }
    }

    private static let alphaSteps = 12
    private static let meColor = LaneColors.meBright.cgColor, themColor = LaneColors.themBright.cgColor
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
