import AppKit
import SwiftUI

/// The lines of one transcript, live or saved: `time │ chip │ text`, grouped by voice, in-progress
/// partials dimmed at the end, and (live) auto-follow with a "New lines" pill once the reader
/// scrolls up. Observes nothing itself: the parent decides what it shows (the voice filter is
/// applied before the lines get here) and re-renders it on change. Rows live in a `LazyVStack`,
/// so a partial arriving several times a second only re-evaluates the rows on screen.
struct TranscriptView: View {
    let lines: [TranscriptLine]
    var partials: [Voice: String] = [:]
    /// Pause markers for a saved transcript ("— paused 4 min —"), placed like in the Markdown.
    var pauses: [PauseInterval] = []
    let fontSize: Double
    /// Live: start at the bottom and follow new lines. Saved: start at the top, no following.
    var follow = false
    /// What the chips call each voice. A value: a rename re-renders the list once, like a filter change.
    var names = VoiceNames()
    @State private var atBottom = true
    @State private var newLines = false

    /// Same speaker within this many seconds continues a "paragraph": the chip is shown once.
    static let groupGap: TimeInterval = 20
    private static let timeWidth: CGFloat = 56, maxText: CGFloat = 640
    private var rowMaxWidth: CGFloat { Self.timeWidth + chipWidth + Self.maxText + 20 }

    var body: some View {
        GeometryReader { outer in
            let compact = outer.size.width < 560
            let textWidth = compact ? outer.size.width - 40
                : min(rowMaxWidth, outer.size.width - 40) - Self.timeWidth - chipWidth - 20
            ScrollViewReader { proxy in
                ScrollView {
                    // The sentinel lives OUTSIDE the lazy stack so it always exists and reports
                    // its position; inside, it wouldn't be instantiated while off-screen.
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                                ForEach(pausesBefore(i), id: \.start) { marker($0) }
                                row(line, chip: startsGroup(i), compact: compact)
                            }
                            ForEach(pausesBefore(lines.count), id: \.start) { marker($0) }
                        }
                        ForEach(partials.keys.sorted(by: Voice.displayOrder), id: \.self) { v in
                            if let p = partials[v] { partialRow(v, p, compact: compact, textWidth: textWidth).padding(.top, 8) }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .background(GeometryReader { g in
                                Color.clear.preference(key: BottomKey.self, value: g.frame(in: .named("scroll")).maxY)
                            })
                    }
                    .frame(maxWidth: rowMaxWidth)
                    .frame(maxWidth: .infinity)          // centred when the window is wide
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    .textSelection(.enabled)
                }
                .coordinateSpace(name: "scroll")
                .defaultScrollAnchor(follow ? .bottom : .top)
                .onPreferenceChange(BottomKey.self) { maxY in
                    // "At bottom" = the end is visible (with a little slack). Scrolling up to
                    // reread pauses auto-scroll; scrolling back down resumes it.
                    atBottom = maxY <= outer.size.height + 40
                    if atBottom { newLines = false }
                }
                .onChange(of: lines.count) { if follow { followTail(proxy, newLine: true) } }
                .onChange(of: partials) { if follow { followTail(proxy, newLine: false) } }
                .onAppear { if follow { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom); atBottom = true } } }
                .overlay(alignment: .bottom) {
                    if newLines {
                        Button { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }; newLines = false } label: {
                            Label("New lines", systemImage: "arrow.down")
                                .font(.system(size: 11.5, weight: .semibold))
                                .padding(.horizontal, 11).padding(.vertical, 5)
                                .foregroundStyle(.white)
                                .background(Capsule().fill(Color.accentColor))
                                .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: newLines)
            }
        }
    }

    private func followTail(_ proxy: ScrollViewProxy, newLine: Bool) {
        guard atBottom else { if newLine { newLines = true }; return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    /// The chip shows on the first line of a run: new speaker (lane or diarized), different app,
    /// or a 20 s gap.
    private func startsGroup(_ i: Int) -> Bool {
        guard i > 0 else { return true }
        let a = lines[i - 1], b = lines[i]
        return a.speaker != b.speaker || a.sourceApp != b.sourceApp || a.speakerID != b.speakerID
            || b.start.timeIntervalSince(a.start) > Self.groupGap
    }

    /// Pauses that belong above line `i` (same rule as the Markdown: before the first line that
    /// started after the pause began); `i == lines.count` collects the trailing ones.
    private func pausesBefore(_ i: Int) -> [PauseInterval] {
        guard !pauses.isEmpty else { return [] }
        let lower = i > 0 ? lines[i - 1].start : Date.distantPast
        let upper = i < lines.count ? lines[i].start : Date.distantFuture
        return pauses.filter { $0.start > lower && $0.start <= upper }
    }

    private func marker(_ p: PauseInterval) -> some View {
        Text(p.end.map { "— paused \(TranscriptFormatter.shortDuration($0.timeIntervalSince(p.start))) —" } ?? "— paused —")
            .font(.system(size: 11)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity).padding(.vertical, 6)
    }

    private var textFont: Font { .system(size: fontSize) }
    /// 1.3 × the font size, measured line to line (SF's natural leading is ≈1.2).
    private var lineGap: CGFloat { fontSize * 0.1 }

    /// Width of the chip column: the widest label this transcript actually uses, so one with
    /// only "me" / "them" doesn't reserve room for "them · Microsoft Teams".
    private var chipWidth: CGFloat {
        var labels = Set(["them"])
        for v in Set(lines.map { Voice($0) }).union(partials.keys) { labels.insert(LaneColors.chipLabel(v, names: names)) }   // partials: a voice with no line yet
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let widest = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 30
        return min(130, ceil(widest) + 16)
    }

    /// Wide: `time │ chip │ text`. Narrow (under 560 pt, a window tucked beside the call): chip
    /// and time on one line above the text, which then gets the full width.
    @ViewBuilder
    private func layout<C: View, T: View, B: View>(compact: Bool, @ViewBuilder chip: () -> C,
                                                   @ViewBuilder time: () -> T, @ViewBuilder text: () -> B) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) { chip(); time() }
                text()
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                time().frame(width: Self.timeWidth, alignment: .leading)
                chip().frame(width: chipWidth, alignment: .trailing)
                text()
            }
        }
    }

    private func row(_ line: TranscriptLine, chip: Bool, compact: Bool) -> some View {
        layout(compact: compact) {
            if chip {
                Chip(text: LaneColors.chipLabel(Voice(line), names: names), color: LaneColors.adaptive(Voice(line), names.roster), size: 11)
            } else if !compact {
                // Invisible stand-in keeps the column's width and the row's text baseline.
                Chip(text: "me", color: .clear, size: 11).hidden()
            }
        } time: {
            Text(TranscriptFormatter().clock(line.start))
                .font(.system(size: compact ? 10.5 : 11, design: .monospaced))
                .foregroundStyle(chip ? .secondary : .tertiary)
                .lineLimit(1).fixedSize()
        } text: {
            Text(line.text)
                .font(textFont)
                .lineSpacing(lineGap)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, chip && line.id != lines.first?.id ? 6 : 0)   // a little air between runs
    }

    /// Words in progress: the normal font, dimmed, and only the last ~3 lines of it, so a long
    /// hypothesis that hasn't committed yet never fills the window.
    private func partialRow(_ v: Voice, _ text: String, compact: Bool, textWidth: CGFloat) -> some View {
        layout(compact: compact) {
            Chip(text: LaneColors.chipLabel(v, names: names), color: LaneColors.adaptive(v, names.roster), size: 11)
        } time: {
            TypingDots()
        } text: {
            Text(Self.tail(text, lines: 3, width: textWidth, fontSize: fontSize))
                .font(textFont)
                .lineSpacing(lineGap)
                .foregroundStyle(.primary.opacity(0.65))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The end of `s` that fits in about `lines` lines, cut at a word and led by "…".
    /// Estimated from an average glyph width of half the point size; no text layout.
    static func tail(_ s: String, lines: Int, width: CGFloat, fontSize: CGFloat) -> String {
        let maxChars = max(20, Int(width / (fontSize * 0.5))) * lines
        guard s.count > maxChars else { return s }
        var t = s.suffix(maxChars - 2)
        if let sp = t.firstIndex(of: " ") { t = t[t.index(after: sp)...] }
        return "…" + t
    }
}

private struct BottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// One toggle chip per voice in the shown transcript. Off = the voice's lines are hidden from the
/// view (and its Copy / exports), drawn hollow so it can be turned back on; "Show all" when
/// anything is off. Each chip can also be renamed in place (`VoiceChip`); `renaming` is the
/// one being edited.
struct VoiceFilterBar: View {
    let voices: [Voice]
    let hidden: Set<Voice>
    var names = VoiceNames()
    @Binding var renaming: Voice?
    let toggle: (Voice) -> Void
    let showAll: () -> Void
    var rename: (Voice, String?) -> Void = { _, _ in }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(voices, id: \.self) { v in
                VoiceChip(voice: v, label: LaneColors.chipLabel(v, names: names), customName: names.names[v.key], roster: names.roster,
                          off: hidden.contains(v),
                          renaming: Binding(get: { renaming == v }, set: { renaming = $0 ? v : (renaming == v ? nil : renaming) }),
                          toggle: { toggle(v) }, rename: { rename(v, $0) })
            }
            if !hidden.isEmpty {
                Button("Show all", action: showAll)
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                    .padding(.leading, 4)
            }
        }
    }
}

/// Nothing said yet in the live view: what's happening, and what the two colours mean.
struct LiveEmptyState: View {
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
        case .idle: return "Press \(Hotkey.toggleListening.display) to start listening."
        }
    }
}

/// First run: no session and nothing saved yet.
struct FirstRunEmptyState: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.primary.opacity(0.06)))
            VStack(spacing: 5) {
                Text("No transcripts yet").font(.system(size: 15, weight: .semibold))
                Text("Press \(Hotkey.toggleListening.display) at the start of a call, or click Start listening. Each session is saved to Documents ▸ hearsay and listed here.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            HStack(spacing: 16) {
                HStack(spacing: 6) { Chip(text: "me", color: LaneColors.adaptive(.me), size: 11); Text("your microphone") }
                HStack(spacing: 6) { Chip(text: "them", color: LaneColors.adaptive(.them), size: 11); Text("what your Mac plays") }
            }
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
            if model.phase == .idle {
                Button("Start listening") { model.actions.toggleListening() }
                    .buttonStyle(.borderedProminent).padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
