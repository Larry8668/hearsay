import AppKit
import Combine
import SwiftUI

/// The floating controls while a session is listening or paused, in one of two shapes
/// (`AppModel.BarMode`):
///
/// - the **full bar** at the bottom of the screen: a captions card (the last two lines from each
///   speaker) above a controls capsule (status dot, two-lane waveform, elapsed time, pause /
///   stop / transcript / captions / shrink buttons);
/// - the **pill**: a 44 pt capsule with just the dot, a short waveform and pause / stop /
///   expand, which the user can park anywhere (its spot is remembered separately).
///
/// Window mechanics live here; the looks are `RecordingBarView` and `RecordingPillView`. Like
/// the menu bar it's a pure view: it shows `AppModel` and does everything through `actions`
/// (the mode is the one thing it writes back, as a preference).
///
/// Never steals focus from the call app: non-activating panels that refuse key/main status,
/// with a hosting view that accepts the first click (otherwise the first click on a button in an
/// inactive app's window would be swallowed).
///
/// Each shape is its own window and neither ever changes size while visible (see
/// "Captions on / off"); switching shapes crossfades one window into the other.
final class RecordingBar: NSObject {
    struct Actions {
        var togglePause: () -> Void
        var stop: () -> Void
        var togglePanel: () -> Void
    }
    typealias Mode = AppModel.BarMode

    /// Width of both of the bar's shapes (pt); the controls capsule and the pill are
    /// `controlsHeight` tall.
    static let width: CGFloat = 560
    static let controlsHeight: CGFloat = 44
    /// Gap between the captions card and the controls.
    static let gap: CGFloat = 8
    /// Transparent border around the shapes: room for their shadow (radius 18, y 6).
    static let margin: CGFloat = 26
    /// Gap between the capsule and the bottom of the visible frame (the Dock's top edge).
    static let bottomGap: CGFloat = 14
    /// The pill is as narrow as its content: leading pad, dot, waveform, three buttons, trailing pad.
    static let pillWaveFrames = 7
    static let pillWidth: CGFloat = 14 + 12 + 10 + WaveformNSView.size(frames: pillWaveFrames).width + 10 + 3 * 28 + 8
    private static let anchorKeys: [Mode: String] = [.full: "recordingBar.anchor", .pill: "recordingBar.pillAnchor"]
    static let captionsKey = "recordingBar.captions"

    /// Height of the bar's shapes' area: controls + the tallest captions card (three blocks). The
    /// window is always this tall; see "Captions on / off".
    static let fullHeight = controlsHeight + gap + CaptionMetrics.cardHeight(CaptionsFeed.maxBlocks)

    private let model: AppModel
    private let actions: Actions
    let state = RecordingBarState()
    private lazy var feed = CaptionsFeed(model: model)
    private var panels: [Mode: NSPanel] = [:]
    /// The shape currently (or last) shown; follows `model.barMode`.
    private var mode: Mode
    /// What we were last asked for; animations check it so a quick show→hide→show ends right.
    private var wantVisible = false
    /// When the user last pressed on a shape's background. `performDrag` returns before the
    /// window moves, so moves seen shortly after this are the user's and get remembered; our own
    /// moves (slide in/out, captions, snap back) never set it.
    private var userDragAt: Date?
    private var saveWork: DispatchWorkItem?
    private var subs: Set<AnyCancellable> = []

    init(model: AppModel, actions: Actions) {
        self.model = model
        self.actions = actions
        mode = model.barMode
        super.init()
        state.captions = UserDefaults.standard.object(forKey: Self.captionsKey) as? Bool ?? true
        // Only real changes reach the SwiftUI trees (see RecordingBarState).
        model.$phase.removeDuplicates().sink { [weak self] in self?.state.phase = $0 }.store(in: &subs)
        model.$panelVisible.removeDuplicates().sink { [weak self] in self?.state.panelVisible = $0 }.store(in: &subs)
        model.$barMode.removeDuplicates().dropFirst().sink { [weak self] in self?.apply(mode: $0) }.store(in: &subs)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    var isVisible: Bool { wantVisible }

    // MARK: Show / hide

    func setVisible(_ visible: Bool) {
        guard visible != wantVisible else { return }
        wantVisible = visible
        feed.setActive(visible && mode == .full)
        visible ? show(mode, slide: true) : hide(mode, slide: true)
    }

    /// Bar ⇄ pill (from either shape's button or the menu). The preference is the source of
    /// truth: writing it brings `apply(mode:)` round.
    func setMode(_ m: Mode) {
        guard m != model.barMode else { return }
        Log.info("recording bar: \(m.rawValue)")
        model.barMode = m
    }

    private func apply(mode new: Mode) {
        guard new != mode else { return }
        let old = mode
        mode = new
        guard wantVisible else { return }
        feed.setActive(new == .full)
        hide(old, slide: false)
        show(new, slide: false)
    }

    /// `slide`: the full bar rises from below the screen's bottom edge with a slight overshoot
    /// (session start) and sinks back (stop). The pill, which may be anywhere on the screen, and
    /// either shape when swapping modes, fade with a small rise instead.
    private func show(_ m: Mode, slide: Bool) {
        let p = panels[m] ?? make(m)
        panels[m] = p
        let target = frame(for: m)
        let slide = slide && m == .full
        var start = target
        if slide { start.origin.y = (screen(containing: target)?.frame.minY ?? 0) - target.height }
        p.setFrame(start, display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        Log.info("recording \(m.rawValue) shown at \(Int(target.midX)),\(Int(target.minY + Self.margin))")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = slide ? 0.5 : 0.25
            // y control point > 1 overshoots a little: a cheap spring for a window frame.
            ctx.timingFunction = slide ? CAMediaTimingFunction(controlPoints: 0.2, 1.18, 0.35, 1) : CAMediaTimingFunction(name: .easeOut)
            if slide { p.animator().setFrame(target, display: true) }
            p.animator().alphaValue = 1
        }
        // With the display asleep the frame animation never runs and the window would stay off
        // its spot; make sure it ends up in place either way.
        guard slide else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self = self, self.wantVisible, self.mode == m, p.frame.minY < target.minY - 1 else { return }
            p.setFrame(self.frame(for: m), display: true)
            p.alphaValue = 1
        }
    }

    private func hide(_ m: Mode, slide: Bool) {
        userDragAt = nil
        guard let p = panels[m], p.isVisible else { return }
        let slide = slide && m == .full
        var end = p.frame
        end.origin.y = (p.screen?.frame.minY ?? 0) - end.height
        let duration = slide ? 0.28 : 0.2
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if slide { p.animator().setFrame(end, display: true) }
            p.animator().alphaValue = 0
        }
        // Ordered out on a timer, not the group's completion handler: that handler never ran
        // for a group that animates only a window's alpha (the pill stayed on screen, invisible
        // but catching clicks).
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
            guard let self = self, !(self.wantVisible && self.mode == m) else { return }
            p.orderOut(nil)
            p.alphaValue = 0
            Log.info("recording \(m.rawValue) hidden")
        }
    }

    private func make(_ m: Mode) -> NSPanel {
        let p = RecordingBarPanel(contentRect: NSRect(origin: .zero, size: Self.windowSize(m)),
                                  styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
                                  backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false          // accessory apps are "inactive" almost always
        p.canHide = false                    // ⌘H (Hide hearsay) must not take the bar off a call
        // .statusBar sits above full-screen apps when combined with .fullScreenAuxiliary (what
        // worked for sharemask's HUD); .floating would hide behind a full-screen Zoom.
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isMovableByWindowBackground = true
        p.isOpaque = false
        p.backgroundColor = .clear
        // The shapes draw their own SwiftUI shadow: a window shadow is computed from the alpha
        // mask and would lag behind the captions card fading in and out.
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .darkAqua)   // reads the same over any content
        p.identifier = NSUserInterfaceItemIdentifier(m == .full ? "RecordingBar" : "RecordingPill")   // names the debug snapshots
        let hosting: NSView
        switch m {
        case .full:
            p.setAccessibilityLabel("hearsay recording bar")
            let view = RecordingBarView(model: model, bar: state, feed: feed, actions: actions,
                                        toggleCaptions: { [weak self] in self?.toggleCaptions() },
                                        shrink: { [weak self] in self?.setMode(.pill) },
                                        dragBegan: { [weak self] in self?.userDragAt = Date() },
                                        snapBack: { [weak self] in self?.snapBack(.full) })
            hosting = Self.host(view)
        case .pill:
            p.setAccessibilityLabel("hearsay recording pill")
            let view = RecordingPillView(model: model, bar: state, actions: actions,
                                         expand: { [weak self] in self?.setMode(.full) },
                                         dragBegan: { [weak self] in self?.userDragAt = Date() },
                                         snapBack: { [weak self] in self?.snapBack(.pill) })
            hosting = Self.host(view)
        }
        p.contentView = hosting
        NotificationCenter.default.addObserver(self, selector: #selector(windowMoved(_:)), name: NSWindow.didMoveNotification, object: p)
        return p
    }

    private static func host<V: View>(_ view: V) -> NSView {
        let hosting = FirstMouseHostingView(rootView: view)
        // The panel is sized explicitly; without this, every SwiftUI change made AppKit re-run
        // constraint layout for the whole window to re-derive the intrinsic size.
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        return hosting
    }

    // MARK: Captions on / off

    /// WHY the window never changes size: growing a window that shows SwiftUI content let the
    /// window server show one frame of the new content top-anchored in the old frame (the
    /// controls vanished and the card flashed where they had been; the old hover-expand's "moves
    /// up, then down"). So the window is always tall enough for the caption blocks and the card
    /// comes and goes inside it, with the controls bottom-anchored and never moving. The space
    /// above a short card is fully transparent, and transparent pixels of a non-opaque window
    /// let clicks through to the app underneath, like the shadow margin always has. The same
    /// rule is why the pill is a second window rather than the bar shrinking.
    func toggleCaptions() {
        let on = !state.captions
        Log.info("recording bar: captions \(on ? "shown" : "hidden")")
        UserDefaults.standard.set(on, forKey: Self.captionsKey)
        withAnimation(on ? .easeOut(duration: 0.25) : .easeIn(duration: 0.2)) { state.captions = on }
    }

    // MARK: Position

    static let windowSize = windowSize(.full)
    static func windowSize(_ m: Mode) -> CGSize {
        m == .full ? CGSize(width: width + 2 * margin, height: fullHeight + 2 * margin)
            : CGSize(width: pillWidth + 2 * margin, height: controlsHeight + 2 * margin)
    }

    /// Window frame whose shape's bottom-centre sits at `anchor`.
    static func frame(anchor: NSPoint, mode: Mode = .full) -> NSRect {
        let size = windowSize(mode)
        return NSRect(x: (anchor.x - size.width / 2).rounded(), y: (anchor.y - margin).rounded(),
                      width: size.width, height: size.height)
    }

    /// Shape bottom-centre: the user's dragged spot if it's still on a screen, else bottom-centre
    /// of the main screen, just above the Dock. The pill may hug a screen's left or right edge,
    /// so only its middle has to be on screen; the bar keeps 40 pt of itself on.
    private func anchor(for m: Mode) -> NSPoint {
        if let key = Self.anchorKeys[m], let a = UserDefaults.standard.array(forKey: key) as? [Double], a.count == 2 {
            let pt = NSPoint(x: a[0], y: a[1])
            let dx: CGFloat = m == .full ? 40 : 0
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: dx, dy: -1).contains(pt) }) { return pt }
        }
        return Self.defaultAnchor()
    }

    private static func defaultAnchor() -> NSPoint {
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: vf.midX, y: vf.minY + bottomGap)
    }

    private func frame(for m: Mode) -> NSRect { Self.frame(anchor: anchor(for: m), mode: m) }

    private func screen(containing r: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSPoint(x: r.midX, y: r.minY + Self.margin)) } ?? NSScreen.main
    }

    private func mode(of window: NSWindow) -> Mode? { panels.first { $0.value === window }?.key }

    @objc private func windowMoved(_ note: Notification) {
        guard let t = userDragAt, Date().timeIntervalSince(t) < 10,
              let w = note.object as? NSWindow, let m = mode(of: w) else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.userDragAt = nil; self?.saveAnchor(m) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)   // after the last move
    }

    private func saveAnchor(_ m: Mode) {
        guard let p = panels[m], let key = Self.anchorKeys[m] else { return }
        let a = NSPoint(x: p.frame.midX, y: p.frame.minY + Self.margin)
        UserDefaults.standard.set([Double(a.x), Double(a.y)], forKey: key)
        Log.info("recording \(m.rawValue) moved to \(Int(a.x)),\(Int(a.y))")
    }

    /// Double-click on the background: forget the dragged spot, back to bottom-centre.
    private func snapBack(_ m: Mode) {
        userDragAt = nil
        saveWork?.cancel()
        if let key = Self.anchorKeys[m] { UserDefaults.standard.removeObject(forKey: key) }
        guard let p = panels[m] else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            p.animator().setFrame(Self.frame(anchor: Self.defaultAnchor(), mode: m), display: true)
        }
    }

    /// Display added/removed/rearranged, Dock moved: re-place (a stale spot falls back to default).
    @objc private func screensChanged() {
        guard let p = panels[mode], wantVisible else { return }
        userDragAt = nil
        p.setFrame(frame(for: mode), display: true)
    }
}

/// What the shapes' SwiftUI trees observe instead of `AppModel`.
/// WHY: `AppModel` publishes a change for every partial transcript event (several a second per
/// lane, often with unchanged text), and a view observing it re-runs its body and the hosting
/// view's update pass each time. These copies change only when the value does.
final class RecordingBarState: ObservableObject {
    @Published var captions = true
    @Published var phase: AppModel.Phase = .idle
    @Published var panelVisible = false

    var paused: Bool { phase == .paused }
    /// Pause/Resume applies while listening or paused (not while starting or stopping).
    var canPause: Bool { phase == .listening || phase == .paused }
    var dotState: StatusDot.State {
        switch phase {
        case .paused: return .paused
        case .listening: return .live
        default: return .loading
        }
    }
}

/// Never key, never main: clicking the bar must leave the call app frontmost and focused.
final class RecordingBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on an inactive window reach the SwiftUI buttons.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
