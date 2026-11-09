import AppKit
import Combine
import SwiftUI

/// The floating bar at the bottom of the screen while a session is listening or paused: a
/// captions card (the last two lines from each speaker) above a controls capsule (status dot,
/// two-lane waveform, elapsed time, pause / stop / transcript / captions buttons).
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

    /// Width of both shapes (pt); the controls capsule is `controlsHeight` tall.
    static let width: CGFloat = 560
    static let controlsHeight: CGFloat = 44
    /// Gap between the captions card and the controls.
    static let gap: CGFloat = 8
    /// Transparent border around the shapes: room for their shadow (radius 18, y 6).
    static let margin: CGFloat = 26
    /// Gap between the capsule and the bottom of the visible frame (the Dock's top edge).
    static let bottomGap: CGFloat = 14
    private static let anchorKey = "recordingBar.anchor"
    static let captionsKey = "recordingBar.captions"

    /// Height of the shapes' area: controls + the tallest captions card (two blocks). The window
    /// is always this tall; see "Captions on / off".
    static let fullHeight = controlsHeight + gap + CaptionMetrics.cardHeight(CaptionsFeed.maxBlocks)

    private let model: AppModel
    private let actions: Actions
    let state = RecordingBarState()
    private lazy var feed = CaptionsFeed(model: model)
    private var panel: NSPanel?
    /// What we were last asked for; animations check it so a quick show→hide→show ends right.
    private var wantVisible = false
    /// When the user last pressed on the bar's background. `performDrag` returns before the
    /// window moves, so moves seen shortly after this are the user's and get remembered; our own
    /// moves (slide in/out, captions, snap back) never set it.
    private var userDragAt: Date?
    private var saveWork: DispatchWorkItem?
    private var subs: Set<AnyCancellable> = []

    init(model: AppModel, actions: Actions) {
        self.model = model
        self.actions = actions
        super.init()
        state.captions = UserDefaults.standard.object(forKey: Self.captionsKey) as? Bool ?? true
        // Only real changes reach the bar's SwiftUI tree (see RecordingBarState).
        model.$phase.removeDuplicates().sink { [weak self] in self?.state.phase = $0 }.store(in: &subs)
        model.$panelVisible.removeDuplicates().sink { [weak self] in self?.state.panelVisible = $0 }.store(in: &subs)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    var isVisible: Bool { wantVisible }

    // MARK: Show / hide

    func setVisible(_ visible: Bool) {
        guard visible != wantVisible else { return }
        wantVisible = visible
        feed.setActive(visible)
        visible ? slideIn() : slideOut()
    }

    /// Slides up from below the screen's bottom edge with a slight overshoot.
    private func slideIn() {
        let p = panel ?? make()
        panel = p
        let target = frame()
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
        // With the display asleep the frame animation never runs and the bar would stay below
        // the screen; make sure it ends up in place either way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self = self, self.wantVisible, p.frame.minY < target.minY - 1 else { return }
            p.setFrame(self.frame(), display: true)
            p.alphaValue = 1
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
        let p = RecordingBarPanel(contentRect: NSRect(origin: .zero, size: Self.windowSize),
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
        // The shapes draw their own SwiftUI shadow: a window shadow is computed from the alpha
        // mask and would lag behind the captions card fading in and out.
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .darkAqua)   // reads the same over any content
        p.setAccessibilityLabel("hearsay recording bar")
        let view = RecordingBarView(model: model, bar: state, feed: feed, actions: actions,
                                    toggleCaptions: { [weak self] in self?.toggleCaptions() },
                                    dragBegan: { [weak self] in self?.userDragAt = Date() },
                                    snapBack: { [weak self] in self?.snapBack() })
        let hosting = FirstMouseHostingView(rootView: view)
        // The panel is sized explicitly; without this, every SwiftUI change made AppKit re-run
        // constraint layout for the whole window to re-derive the intrinsic size.
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        p.contentView = hosting
        NotificationCenter.default.addObserver(self, selector: #selector(windowMoved), name: NSWindow.didMoveNotification, object: p)
        return p
    }

    // MARK: Captions on / off

    /// WHY the window never changes size: growing a window that shows SwiftUI content let the
    /// window server show one frame of the new content top-anchored in the old frame (the
    /// controls vanished and the card flashed where they had been; the old hover-expand's "moves
    /// up, then down"). So the window is always tall enough for two caption blocks and the card
    /// comes and goes inside it, with the controls bottom-anchored and never moving. The space
    /// above a short card is fully transparent, and transparent pixels of a non-opaque window
    /// let clicks through to the app underneath, like the shadow margin always has.
    func toggleCaptions() {
        let on = !state.captions
        Log.info("recording bar: captions \(on ? "shown" : "hidden")")
        UserDefaults.standard.set(on, forKey: Self.captionsKey)
        withAnimation(on ? .easeOut(duration: 0.25) : .easeIn(duration: 0.2)) { state.captions = on }
    }

    // MARK: Position

    static let windowSize = CGSize(width: width + 2 * margin, height: fullHeight + 2 * margin)

    /// Window frame whose capsule's bottom-centre sits at `anchor`.
    static func frame(anchor: NSPoint) -> NSRect {
        let size = windowSize
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

    private func frame() -> NSRect { Self.frame(anchor: anchor()) }

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
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            p.animator().setFrame(Self.frame(anchor: Self.defaultAnchor()), display: true)
        }
    }

    /// Display added/removed/rearranged, Dock moved: re-place (a stale spot falls back to default).
    @objc private func screensChanged() {
        guard let p = panel, wantVisible else { return }
        userDragAt = nil
        p.setFrame(frame(), display: true)
    }
}

/// What the bar's SwiftUI tree observes instead of `AppModel`.
/// WHY: `AppModel` publishes a change for every partial transcript event (several a second per
/// lane, often with unchanged text), and a view observing it re-runs its body and the hosting
/// view's update pass each time. These copies change only when the value does.
final class RecordingBarState: ObservableObject {
    @Published var captions = true
    @Published var phase: AppModel.Phase = .idle
    @Published var panelVisible = false
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
