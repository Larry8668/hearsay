import AppKit
import SwiftUI

/// The floating capsule at the bottom of the screen while a session is listening or paused:
/// status dot, two-lane waveform, elapsed time, pause / stop / transcript buttons, and an
/// expanded state with the latest words from each lane.
///
/// Window mechanics live here; the look is `RecordingBarView`. Like the menu bar it's a pure
/// view: it shows `AppModel` and does everything through `actions`.
///
/// Never steals focus from the call app: a non-activating panel that refuses key/main status,
/// with a hosting view that accepts the first click (otherwise the first click on a button in an
/// inactive app's window would be swallowed).
final class RecordingBar: NSObject {
    struct Actions {
        var togglePause: () -> Void
        var stop: () -> Void
        var togglePanel: () -> Void
    }

    /// Capsule sizes (pt). The window is the capsule plus `margin` on every side for the shadow.
    static let collapsed = CGSize(width: 372, height: 44)
    /// Same width as collapsed: the buttons must not move when hover expands the bar.
    static let expanded = CGSize(width: 372, height: 104)
    static let margin: CGFloat = 22
    /// Gap between the capsule and the bottom of the visible frame (the Dock's top edge).
    static let bottomGap: CGFloat = 14
    private static let anchorKey = "recordingBar.anchor"

    private let model: AppModel
    private let actions: Actions
    let state = RecordingBarState()
    private var panel: NSPanel?
    /// What we were last asked for; animations check it so a quick show→hide→show ends right.
    private var wantVisible = false
    private var collapseWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    /// When the user last pressed on the bar's background. `performDrag` returns before the
    /// window moves, so moves seen shortly after this are the user's and get remembered; our own
    /// moves (slide in/out, expand, snap back) never set it.
    private var userDragAt: Date?
    private var saveWork: DispatchWorkItem?

    init(model: AppModel, actions: Actions) {
        self.model = model
        self.actions = actions
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    var isVisible: Bool { wantVisible }

    // MARK: Show / hide

    func setVisible(_ visible: Bool) {
        guard visible != wantVisible else { return }
        wantVisible = visible
        visible ? slideIn() : slideOut()
    }

    /// Slides up from below the screen's bottom edge with a slight overshoot.
    private func slideIn() {
        let p = panel ?? make()
        panel = p
        state.pin = .auto            // a new session starts un-pinned
        state.hovering = false
        applyExpanded(false, animated: false)
        let target = frame(for: Self.collapsed)
        var start = target
        start.origin.y = (screen(containing: target)?.frame.minY ?? 0) - target.height
        p.setFrame(start, display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        Log.info("recording bar shown at \(Int(target.midX)),\(Int(target.minY + Self.margin))")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.5
            // y control point > 1 overshoots a little: a cheap spring for a window frame.
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.18, 0.35, 1)
            p.animator().setFrame(target, display: true)
            p.animator().alphaValue = 1
        }
    }

    private func slideOut() {
        userDragAt = nil
        guard let p = panel, p.isVisible else { return }
        var end = p.frame
        end.origin.y = (p.screen?.frame.minY ?? 0) - end.height
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().setFrame(end, display: true)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, !self.wantVisible else { return }
            p.orderOut(nil)
        })
    }

    private func make() -> NSPanel {
        let p = RecordingBarPanel(contentRect: NSRect(origin: .zero, size: Self.windowSize(Self.collapsed)),
                                  styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
                                  backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false          // accessory apps are "inactive" almost always
        // .statusBar sits above full-screen apps when combined with .fullScreenAuxiliary (what
        // worked for sharemask's HUD); .floating would hide behind a full-screen Zoom.
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isMovableByWindowBackground = true
        p.isOpaque = false
        p.backgroundColor = .clear
        // The capsule draws its own SwiftUI shadow: a window shadow is computed from the alpha mask
        // once and would lag behind the expand/collapse animation.
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .darkAqua)   // reads the same over any content
        p.setAccessibilityLabel("hearsay recording bar")
        let view = RecordingBarView(model: model, bar: state, actions: actions,
                                    toggleExpanded: { [weak self] in self?.toggleExpanded() },
                                    hover: { [weak self] in self?.hover($0) },
                                    dragBegan: { [weak self] in self?.userDragAt = Date() },
                                    snapBack: { [weak self] in self?.snapBack() })
        let hosting = FirstMouseHostingView(rootView: view)
        // The panel is sized explicitly (resizeWindow); without this, every SwiftUI change made
        // AppKit re-run constraint layout for the whole window to re-derive the intrinsic size.
        hosting.sizingOptions = []
        p.contentView = hosting
        NotificationCenter.default.addObserver(self, selector: #selector(windowMoved), name: NSWindow.didMoveNotification, object: p)
        return p
    }

    // MARK: Expanded state

    private func toggleExpanded() {
        // The chevron pins: open stays open; closing it stops hover from re-opening this session.
        state.pin = state.expanded ? .collapsed : .expanded
        updateExpanded()
    }

    /// Hover expands after 350 ms (so passing the pointer over the bar doesn't flap it) and
    /// collapses shortly after the pointer leaves.
    private func hover(_ inside: Bool) {
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.state.hovering = inside
            self?.updateExpanded()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.35 : 0.5), execute: work)
    }

    func updateExpanded() {
        let want: Bool
        switch state.pin {
        case .expanded: want = true
        case .collapsed: want = false
        case .auto: want = state.hovering && model.expandBarOnHover
        }
        if want != state.expanded { applyExpanded(want, animated: true) }
    }

    /// Growing: enlarge the window first (the capsule is bottom-anchored inside it, so nothing
    /// moves), then animate the capsule. Shrinking: animate, then trim the window so its
    /// transparent part never sits over the call app's controls.
    private func applyExpanded(_ on: Bool, animated: Bool) {
        collapseWork?.cancel()
        let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)
        if on {
            resizeWindow(to: Self.expanded)
            if animated { withAnimation(spring) { state.expanded = true } } else { state.expanded = true }
        } else {
            if animated { withAnimation(spring) { state.expanded = false } } else { state.expanded = false }
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, !self.state.expanded else { return }
                self.resizeWindow(to: Self.collapsed)
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.45 : 0), execute: work)
        }
    }

    private func resizeWindow(to capsule: CGSize) {
        guard let p = panel else { return }
        let anchor = NSPoint(x: p.frame.midX, y: p.frame.minY + Self.margin)
        p.setFrame(Self.frame(capsule, anchor: anchor), display: true)
    }

    // MARK: Position

    static func windowSize(_ capsule: CGSize) -> CGSize {
        CGSize(width: capsule.width + 2 * margin, height: capsule.height + 2 * margin)
    }

    /// Window frame whose capsule's bottom-centre sits at `anchor`.
    static func frame(_ capsule: CGSize, anchor: NSPoint) -> NSRect {
        let size = windowSize(capsule)
        return NSRect(x: (anchor.x - size.width / 2).rounded(), y: (anchor.y - margin).rounded(),
                      width: size.width, height: size.height)
    }

    /// Capsule bottom-centre: the user's dragged spot if it's still on a screen, else bottom-centre
    /// of the main screen, just above the Dock.
    private func anchor() -> NSPoint {
        if let a = UserDefaults.standard.array(forKey: Self.anchorKey) as? [Double], a.count == 2 {
            let pt = NSPoint(x: a[0], y: a[1])
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: 40, dy: -1).contains(pt) }) { return pt }
        }
        return Self.defaultAnchor()
    }

    private static func defaultAnchor() -> NSPoint {
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: vf.midX, y: vf.minY + bottomGap)
    }

    private func frame(for capsule: CGSize) -> NSRect { Self.frame(capsule, anchor: anchor()) }

    private func screen(containing r: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSPoint(x: r.midX, y: r.minY + Self.margin)) } ?? NSScreen.main
    }

    @objc private func windowMoved() {
        guard let t = userDragAt, Date().timeIntervalSince(t) < 10 else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.userDragAt = nil; self?.saveAnchor() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)   // after the last move
    }

    private func saveAnchor() {
        guard let p = panel else { return }
        let a = NSPoint(x: p.frame.midX, y: p.frame.minY + Self.margin)
        UserDefaults.standard.set([Double(a.x), Double(a.y)], forKey: Self.anchorKey)
        Log.info("recording bar moved to \(Int(a.x)),\(Int(a.y))")
    }

    /// Double-click on the background: forget the dragged spot, back to bottom-centre.
    private func snapBack() {
        userDragAt = nil
        saveWork?.cancel()
        UserDefaults.standard.removeObject(forKey: Self.anchorKey)
        guard let p = panel else { return }
        let size = state.expanded ? Self.expanded : Self.collapsed
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            p.animator().setFrame(Self.frame(size, anchor: Self.defaultAnchor()), display: true)
        }
    }

    /// Display added/removed/rearranged, Dock moved: re-place (a stale spot falls back to default).
    @objc private func screensChanged() {
        guard let p = panel, wantVisible else { return }
        userDragAt = nil
        p.setFrame(frame(for: state.expanded ? Self.expanded : Self.collapsed), display: true)
    }
}

/// Expanded/hover state shared by the controller (window size) and the view (layout).
final class RecordingBarState: ObservableObject {
    enum Pin { case auto, expanded, collapsed }
    @Published var expanded = false
    @Published var hovering = false
    var pin: Pin = .auto
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
