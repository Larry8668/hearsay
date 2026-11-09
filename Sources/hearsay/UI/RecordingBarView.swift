import AppKit
import SwiftUI

/// The recording bar's content. Always rendered dark (the panel forces .darkAqua).
///
///          me  …and the deadline moves to Friday   expanded: latest words per lane,
///     them · Zoom  …sounds good, I'll send it over       growing upward
///     ───────────────────────────────
///     ● ▁▃▅▂▇▃▁▂▅  12:34   ⏸  ■  ≡  ˄          collapsed, 44 pt
struct RecordingBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bar: RecordingBarState
    let actions: RecordingBar.Actions
    let toggleExpanded: () -> Void
    let hover: (Bool) -> Void
    let dragBegan: () -> Void
    let snapBack: () -> Void

    private static let amber = Color(red: 1, green: 0.74, blue: 0.27)

    private var size: CGSize { bar.expanded ? RecordingBar.expanded : RecordingBar.collapsed }
    private var paused: Bool { model.phase == .paused }

    var body: some View {
        capsule
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(RecordingBar.margin)
            .environment(\.colorScheme, .dark)
    }

    private var capsule: some View {
        let shape = RoundedRectangle(cornerRadius: RecordingBar.collapsed.height / 2, style: .continuous)
        // The words go ABOVE the controls: the capsule grows upward and the buttons stay exactly
        // where the pointer is. With hover-to-expand, controls that jumped 60 pt up 350 ms after
        // the pointer arrived would be clicked out from under you.
        return VStack(spacing: 0) {
            if bar.expanded {
                lanes.allowsHitTesting(false).transition(.opacity.combined(with: .move(edge: .bottom)))
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 16)
            }
            controls.frame(height: RecordingBar.collapsed.height)
        }
        .frame(width: size.width, height: size.height, alignment: .bottom)
        .background(BarDragArea(dragBegan: dragBegan, doubleClick: snapBack, hover: hover))
        .background(VisualEffect(cornerRadius: RecordingBar.collapsed.height / 2).overlay(Color.black.opacity(0.22)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        // Shadow from a plain SwiftUI shape behind the capsule rather than .shadow on the capsule:
        // shadowing a group that contains AppKit views renders a stray edge.
        .background(shape.fill(Color.black.opacity(0.25))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5))
    }

    // MARK: Controls row

    private var controls: some View {
        HStack(spacing: 10) {
            // Everything but the buttons ignores clicks, so they fall through to the drag area
            // behind: the whole bar is a handle.
            Group {
                StatusDot(state: dotState).id(dotState)   // fresh view per state: no leftover pulse
                Waveform(audio: model.audio).opacity(paused ? 0.4 : 1)
                    .animation(.easeInOut(duration: 0.25), value: paused)
                elapsed
            }
            .allowsHitTesting(false)
            HStack(spacing: 0) {
                BarIconButton(symbol: paused ? "play.fill" : "pause.fill",
                              help: paused ? "Resume (⌃⌥P)" : "Pause (⌃⌥P)", action: actions.togglePause)
                    .disabled(!(model.phase == .listening || paused))
                BarIconButton(symbol: "stop.fill", help: "Stop and save the transcript (⌃⌥H)",
                              hoverTint: Color(red: 1, green: 0.36, blue: 0.33), action: actions.stop)
                BarIconButton(symbol: "text.alignleft",
                              help: model.panelVisible ? "Hide live transcript" : "Show live transcript",
                              active: model.panelVisible, action: actions.togglePanel)
            }
            BarIconButton(symbol: "chevron.up", help: bar.expanded ? "Collapse" : "Show latest words",
                          size: 10, width: 18, rotation: bar.expanded ? 180 : 0, action: toggleExpanded)
        }
        .padding(.horizontal, 12)
    }

    private var dotState: StatusDot.State {
        switch model.phase {
        case .paused: return .paused
        case .listening: return .live
        default: return .loading
        }
    }

    private var elapsed: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Group {
                if paused {
                    Text("Paused").foregroundStyle(Self.amber)
                } else {
                    Text(Self.clock(model.listeningTime(now: ctx.date))).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
            .frame(minWidth: 42, maxWidth: .infinity, alignment: .leading)   // absorbs spare width
            .lineLimit(1)
        }
    }

    /// "4:07", "12:34", "1:02:09".
    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Expanded: latest words per lane

    private var lanes: some View {
        let rows = Speaker.allCases.compactMap(latest)
        return VStack(alignment: .leading, spacing: 5) {
            if rows.isEmpty {
                Text(paused ? "Paused — nothing said yet" : "Listening…")
                    .font(.system(size: 12.5)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
            } else {
                ForEach(rows, id: \.speaker) { r in
                    HStack(spacing: 8) {
                        Chip(text: r.chip, color: LaneColors.bright(r.speaker))
                            .frame(width: 84, alignment: .trailing)
                        Text(r.text)
                            .font(.system(size: 12.5)).italic(r.partial)
                            .foregroundStyle(Color.white.opacity(r.partial ? 0.7 : 0.92))
                            .lineLimit(1).truncationMode(.head)   // the newest words stay visible
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .frame(maxHeight: .infinity)
    }

    private struct LaneRow { var speaker: Speaker; var chip: String; var text: String; var partial: Bool }

    /// Partial if one is in progress, else that lane's last committed line.
    private func latest(_ s: Speaker) -> LaneRow? {
        let last = model.lines.last { $0.speaker == s }
        let app = s == .them ? model.lines.last(where: { $0.speaker == .them && $0.sourceApp != nil })?.sourceApp : nil
        let chip = LaneColors.chipLabel(s, app: app)
        if let p = model.partials[s], !p.isEmpty { return LaneRow(speaker: s, chip: chip, text: p, partial: true) }
        if let l = last { return LaneRow(speaker: s, chip: chip, text: l.text, partial: false) }
        return nil
    }
}

// MARK: - Pieces

/// 28×28 icon button: dim until hovered, soft circular highlight, optional red-on-hover tint.
struct BarIconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 13
    var width: CGFloat = 28
    var hoverTint: Color?
    var active = false
    var rotation: Double = 0
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .rotationEffect(.degrees(rotation))
                .foregroundStyle(foreground)
                .frame(width: width, height: 28)
                .background(Circle().fill(Color.white.opacity(active ? 0.16 : hovering ? 0.11 : 0)).frame(width: 26, height: 26))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help(help)
        .opacity(enabled ? 1 : 0.35)
    }

    private var foreground: Color {
        if hovering, let t = hoverTint { return t }
        if active { return LaneColors.bright(.me) }
        return Color.white.opacity(hovering ? 1 : 0.75)
    }
}

/// Behind-window blur, so the bar takes on the colours of whatever is under it. Rounded by its
/// own layer: SwiftUI's clipShape doesn't reliably clip an AppKit view's behind-window material.
struct VisualEffect: NSViewRepresentable {
    var cornerRadius: CGFloat
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// The bar's background: drag to move the window, double-click to snap back to bottom-centre,
/// and hover tracking for auto-expand.
/// AppKit rather than a SwiftUI gesture because `performDrag` moves the window smoothly in the
/// window server, and SwiftUI gestures would fight the buttons for the same clicks. Hover uses an
/// always-active tracking area rather than SwiftUI's onHover, which only sees hit-testable views
/// (most of the bar opts out of hit-testing so that it drags).
struct BarDragArea: NSViewRepresentable {
    let dragBegan: () -> Void
    let doubleClick: () -> Void
    let hover: (Bool) -> Void

    final class DragView: NSView {
        var dragBegan: () -> Void = {}
        var doubleClick: () -> Void = {}
        var hover: (Bool) -> Void = { _ in }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
        override func mouseEntered(with event: NSEvent) { hover(true) }
        override func mouseExited(with event: NSEvent) { hover(false) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { doubleClick(); return }
            dragBegan()
            window?.performDrag(with: event)       // the window server moves it from here on
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ v: DragView, context: Context) { v.dragBegan = dragBegan; v.doubleClick = doubleClick; v.hover = hover }
}
