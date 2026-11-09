import AppKit
import SwiftUI

/// The live panel's title-bar header and empty state. Same vocabulary as the recording bar:
/// red / amber status dot, mm:ss listening time, blue "me" and orange "them" chips.

/// "● Live transcript   12:34 · 48 lines", in the title bar beside the close button.
struct LivePanelHeader: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            Text("Live transcript").font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary.opacity(0.85))
            if model.startedAt != nil {
                // Ticks once a second; only this text re-renders.
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(details(now: ctx.date))
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.leading, 64)   // clear of the window buttons
        .padding(.trailing, 12)
        .frame(height: LivePanel.titlebarHeight)
    }

    private var dotColor: Color {
        switch model.phase {
        case .listening: return Color(red: 1, green: 0.27, blue: 0.23)
        case .paused: return Color(red: 1, green: 0.66, blue: 0.1)
        default: return Color.secondary.opacity(0.5)
        }
    }

    private func details(now: Date) -> String {
        let n = model.lines.count
        var s = RecordingBarView.clock(model.listeningTime(now: now)) + " · \(n) line\(n == 1 ? "" : "s")"
        if model.phase == .paused { s += " · paused" }
        return s
    }
}

/// Nothing said yet: what's happening, and what the two colours mean.
struct LivePanelEmpty: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.primary.opacity(0.06)))
            VStack(spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                legend(.me, "your microphone")
                legend(.them, "what your Mac plays")
            }
            .padding(.top, 2)
            if model.phase == .idle {
                Button("Start listening") { model.actions.toggleListening() }
                    .buttonStyle(.borderedProminent).controlSize(.regular).padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func legend(_ s: Speaker, _ what: String) -> some View {
        HStack(spacing: 6) {
            Chip(text: s.rawValue, color: LaneColors.adaptive(s), size: 11)
            Text(what).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch model.phase {
        case .listening: return "Listening…"
        case .starting: return "Getting ready…"
        case .paused: return "Paused"
        case .stopping: return "Saving transcript…"
        case .idle: return "Not listening"
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .listening: return "Say something, or play audio. Lines appear here as they're spoken."
        case .starting: return "Loading the speech model."
        case .paused: return "Nothing is captured while paused. Press ⌃⌥P to resume."
        case .stopping: return "Writing the transcript to Documents ▸ hearsay."
        case .idle: return "Press ⌃⌥H to start listening."
        }
    }
}
