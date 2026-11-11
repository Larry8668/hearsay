import SwiftUI

/// The recording bar's small shape: a 44 pt capsule the user can park anywhere.
///
///     (●  ▁▃▅▂▇▃▁  ⏸  ■  ⤢)
///
/// Status dot, the newest seven level frames of the two-lane waveform, pause / stop, and the
/// button back to the full bar. No captions and no clock: it is for a call where the bar would
/// be in the way, and the live transcript window has the rest. Same dark surface and hairline
/// as the bar; the dot and the waveform are the same AppKit views (nothing here re-renders per
/// frame, see PERFORMANCE.md). Fixed size, like the bar: the window never changes size.
struct RecordingPillView: View {
    /// Not observed: read once for the waveform's level source.
    let model: AppModel
    @ObservedObject var bar: RecordingBarState
    let actions: RecordingBar.Actions
    /// Switch to the full bar.
    let expand: () -> Void
    let dragBegan: () -> Void
    let snapBack: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // The dot and the waveform ignore clicks, so a press on them drags the pill.
            Group {
                StatusDot(state: bar.dotState).id(bar.dotState)
                Waveform(audio: model.audio, frames: RecordingBar.pillWaveFrames).opacity(bar.paused ? 0.4 : 1)
                    .animation(.easeInOut(duration: 0.25), value: bar.paused)
            }
            .allowsHitTesting(false)
            HStack(spacing: 0) {
                PauseButton(bar: bar, action: actions.togglePause)
                StopButton(action: actions.stop)
                BarIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Full bar with captions", action: expand)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(width: RecordingBar.pillWidth, height: RecordingBar.controlsHeight)
        .background(BarDragArea(dragBegan: dragBegan, doubleClick: snapBack))
        .modifier(Surface(cornerRadius: RecordingBar.controlsHeight / 2))
        .padding(RecordingBar.margin)
        // A fixed size (see RecordingBarView): nothing the hosting view proposes can move it.
        .frame(width: RecordingBar.windowSize(.pill).width, height: RecordingBar.windowSize(.pill).height)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}
