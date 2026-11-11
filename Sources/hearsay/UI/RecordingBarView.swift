import AppKit
import SwiftUI

/// The recording bar's content. Always rendered dark (the panel forces .darkAqua).
///
///     ┌──────────────────────────────────────────────┐
///     │ me           …and the deadline moves to       │  captions: the last two lines
///     │              Friday, so we have a week        │  per speaker, scrolling up
///     │ them · Zoom  sounds good, I'll send it over   │
///     └──────────────────────────────────────────────┘
///     (●  ▁▃▅▂▇▃▁▂▅▃▁▂▅▃▁▂  12:34        ⏸  ■  ≡  ˅ )   controls, 44 pt
///
/// The window is the size of the tallest layout and never resizes (see `RecordingBar`);
/// everything is bottom-aligned in it, so the controls sit still whatever the card does.
struct RecordingBarView: View {
    /// Not observed here: only the leaves that show model state observe it, so a partial
    /// transcript update doesn't re-evaluate the whole bar.
    let model: AppModel
    @ObservedObject var bar: RecordingBarState
    let feed: CaptionsFeed
    let actions: RecordingBar.Actions
    let toggleCaptions: () -> Void
    /// Switch to the pill.
    let shrink: () -> Void
    let dragBegan: () -> Void
    let snapBack: () -> Void

    /// Near-opaque so it reads the same over a red wallpaper, a white page or a dark app.
    static let surface = Color(white: 0.08).opacity(0.92)

    var body: some View {
        VStack(spacing: RecordingBar.gap) {
            if bar.captions {
                CaptionsSlot(feed: feed, bar: bar, dragBegan: dragBegan, snapBack: snapBack)
                    .transition(.opacity.combined(with: .offset(y: 10)))
            }
            BarControls(model: model, bar: bar, actions: actions, toggleCaptions: toggleCaptions, shrink: shrink)
                .frame(height: RecordingBar.controlsHeight)
                .background(BarDragArea(dragBegan: dragBegan, doubleClick: snapBack))
                .modifier(Surface(cornerRadius: RecordingBar.controlsHeight / 2))
        }
        .frame(width: RecordingBar.width)
        .padding(RecordingBar.margin)
        // A fixed size, not maxWidth/maxHeight: .infinity. Nothing the hosting view proposes
        // (it is never resized, but SwiftUI may still measure it) can move the content.
        .frame(width: RecordingBar.windowSize.width, height: RecordingBar.windowSize.height, alignment: .bottom)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}

/// The captions card on its surface. Blocks fading in and out and the card resizing animate
/// here, scoped to this view (not a global withAnimation, which would sweep up whatever else
/// in the bar changes in the same update).
private struct CaptionsSlot: View {
    @ObservedObject var feed: CaptionsFeed
    let bar: RecordingBarState
    let dragBegan: () -> Void
    let snapBack: () -> Void

    var body: some View {
        CaptionsCard(feed: feed, bar: bar)
            .allowsHitTesting(false)
            .background(BarDragArea(dragBegan: dragBegan, doubleClick: snapBack))
            .modifier(Surface(cornerRadius: 16))
            .animation(.easeInOut(duration: 0.45), value: feed.blocks.map(\.id))
            .animation(.easeInOut(duration: 0.3), value: feed.chipColumn)
    }
}

/// Dark fill, 1 px hairline, soft shadow: the bar's shapes and the pill.
struct Surface: ViewModifier {
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(RecordingBarView.surface))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            // Shadow from a plain shape behind, not .shadow on the content: shadowing a group
            // that contains AppKit views renders a stray edge.
            .background(shape.fill(Color.black.opacity(0.3)).shadow(color: .black.opacity(0.35), radius: 18, y: 6))
    }
}

/// Status dot, waveform, time, buttons.
private struct BarControls: View {
    /// Not observed: read for the waveform's level source and, once a second, the elapsed time.
    let model: AppModel
    @ObservedObject var bar: RecordingBarState
    let actions: RecordingBar.Actions
    let toggleCaptions: () -> Void
    let shrink: () -> Void

    private static let amber = Color(red: 1, green: 0.74, blue: 0.27)
    private var paused: Bool { bar.paused }
    private var captions: Bool { bar.captions }

    var body: some View {
        HStack(spacing: 10) {
            // Everything but the buttons ignores clicks, so they fall through to the drag area
            // behind: the whole bar is a handle.
            Group {
                StatusDot(state: bar.dotState).id(bar.dotState)   // fresh view per state: no leftover pulse
                Waveform(audio: model.audio).opacity(paused ? 0.4 : 1)
                    .animation(.easeInOut(duration: 0.25), value: paused)
                elapsed
            }
            .allowsHitTesting(false)
            HStack(spacing: 0) {
                PauseButton(bar: bar, action: actions.togglePause)
                StopButton(action: actions.stop)
                BarIconButton(symbol: "text.alignleft",
                              help: bar.panelVisible ? "Hide live transcript" : "Show live transcript",
                              active: bar.panelVisible, action: actions.togglePanel)
                BarIconButton(symbol: "arrow.down.right.and.arrow.up.left", help: "Shrink to a pill", action: shrink)
                BarIconButton(symbol: "chevron.up", help: captions ? "Hide captions" : "Show captions",
                              size: 10, width: 24, rotation: captions ? 180 : 0, action: toggleCaptions)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
    }

    private var elapsed: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Group {
                if paused {
                    Text("Paused").foregroundStyle(Self.amber)
                } else {
                    Text(RecordingBarView.clock(model.listeningTime(now: ctx.date))).foregroundStyle(Color.white.opacity(0.6))
                }
            }
            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
            .frame(minWidth: 42, maxWidth: .infinity, alignment: .leading)   // absorbs spare width
            .lineLimit(1)
        }
    }
}

extension RecordingBarView {
    /// "4:07", "12:34", "1:02:09".
    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Pieces

/// Pause / Resume, the same on the bar and the pill.
struct PauseButton: View {
    @ObservedObject var bar: RecordingBarState
    let action: () -> Void
    var body: some View {
        BarIconButton(symbol: bar.paused ? "play.fill" : "pause.fill",
                      help: bar.paused ? "Resume (⌃⌥P)" : "Pause (⌃⌥P)", action: action)
            .disabled(!bar.canPause)
    }
}

/// Stop: red on hover.
struct StopButton: View {
    let action: () -> Void
    var body: some View {
        BarIconButton(symbol: "stop.fill", help: "Stop and save the transcript (⌃⌥H)",
                      hoverTint: Color(red: 1, green: 0.36, blue: 0.33), action: action)
    }
}

/// 28 pt icon button: dim until hovered, soft circular highlight, optional red-on-hover tint.
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

/// The bar's background: drag to move the window, double-click to snap back to bottom-centre.
/// AppKit rather than a SwiftUI gesture because `performDrag` moves the window smoothly in the
/// window server, and SwiftUI gestures would fight the buttons for the same clicks.
struct BarDragArea: NSViewRepresentable {
    let dragBegan: () -> Void
    let doubleClick: () -> Void

    final class DragView: NSView {
        var dragBegan: () -> Void = {}
        var doubleClick: () -> Void = {}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { doubleClick(); return }
            dragBegan()
            window?.performDrag(with: event)       // the window server moves it from here on
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ v: DragView, context: Context) { v.dragBegan = dragBegan; v.doubleClick = doubleClick }
}
