import AppKit
import SwiftUI

/// The recording bar's status dot, animated by Core Animation rather than SwiftUI.
/// WHY: a SwiftUI animation (even a TimelineView-driven one) re-renders the hosting view every
/// frame while it runs, and for a window that is movable by background SwiftUI also recomputes
/// the opaque/draggable regions per frame; the breathing dot alone cost ~7% CPU. A CABasicAnimation
/// runs entirely in the render server: zero main-thread work after it starts.
final class PulsingDotNSView: NSView {
    enum State { case live, paused, loading }
    private let halo = CALayer(), dot = CALayer()
    private var state: State?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [halo, dot] { l.frame = CGRect(x: 2, y: 3, width: 8, height: 8); l.cornerRadius = 4; layer?.addSublayer(l) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 12, height: 14) }

    func apply(_ s: State) {
        guard s != state else { return }
        state = s
        let color: NSColor = s == .live ? NSColor(red: 1, green: 0.27, blue: 0.23, alpha: 1)
            : s == .paused ? NSColor(red: 1, green: 0.74, blue: 0.27, alpha: 1) : NSColor.white.withAlphaComponent(0.35)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.backgroundColor = color.cgColor
        halo.backgroundColor = color.withAlphaComponent(0.35).cgColor
        dot.removeAllAnimations(); halo.removeAllAnimations()
        dot.opacity = 1; dot.transform = CATransform3DIdentity
        halo.isHidden = s != .live
        if s == .live {
            func pulse(_ key: String, _ from: Any, _ to: Any) -> CABasicAnimation {
                let a = CABasicAnimation(keyPath: key)
                a.fromValue = from; a.toValue = to
                a.duration = 0.8; a.autoreverses = true; a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                return a
            }
            halo.add(pulse("transform.scale", 1.25, 1.9), forKey: "scale")
            halo.add(pulse("opacity", 0.8, 0.0), forKey: "opacity")
            dot.add(pulse("opacity", 0.55, 1.0), forKey: "opacity")
            dot.add(pulse("transform.scale", 0.92, 1.0), forKey: "scale")
        }
        CATransaction.commit()
    }
}

/// 8 pt dot: red with a breathing halo while listening, amber when paused, grey while loading.
struct StatusDot: NSViewRepresentable {
    enum State { case live, paused, loading }
    let state: State
    func makeNSView(context: Context) -> PulsingDotNSView { PulsingDotNSView(frame: CGRect(x: 0, y: 0, width: 12, height: 14)) }
    func updateNSView(_ v: PulsingDotNSView, context: Context) {
        v.apply(state == .live ? .live : state == .paused ? .paused : .loading)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PulsingDotNSView, context: Context) -> CGSize? { CGSize(width: 12, height: 14) }
}
