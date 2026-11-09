import AppKit
import Combine
import SwiftUI

/// What the recording bar's captions card shows: one block per speaker who spoke in the last
/// `silence` seconds, each with that speaker's recent lines and the words in progress.
///
/// Derived here, in the controller, rather than in the view: the view only re-renders when a
/// block's text actually changes (a partial update, ~1–2×/s per lane while someone talks) or a
/// block comes or goes. A 1 s timer expires silent speakers and publishes nothing otherwise.
final class CaptionsFeed: ObservableObject {
    struct Block: Equatable, Identifiable {
        var voice: Voice
        var chip: String
        /// Lines committed while this block has been up, oldest first, one per utterance.
        var committed: [String]
        var partial: String
        var speaker: Speaker { voice.speaker }
        var id: Voice { voice }
    }

    /// Blocks shown at once: me plus up to two apps. The bar's window is sized for this many.
    static let maxBlocks = 3

    /// Order is fixed (me first, then "them" voices in order of first appearance) so blocks never
    /// swap places.
    @Published private(set) var blocks: [Block] = []
    /// Width of the chip column: fits the widest chip seen this session ("them" at least) and
    /// never shrinks, so text doesn't shift sideways when the other speaker's block comes or goes.
    @Published private(set) var chipColumn = CaptionsFeed.chipWidth("them")

    static func chipWidth(_ label: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        return min(140, ceil((label as NSString).size(withAttributes: [.font: font]).width) + 14)
    }

    /// A speaker silent this long drops off the card.
    static let silence: TimeInterval = 10
    /// Committed lines kept per block. Only the last two visual lines show; a little more keeps
    /// the scroll continuous. Whole lines are dropped, so the visible text never re-wraps.
    static let keepLines = 3

    private let model: AppModel
    private var subs: Set<AnyCancellable> = []
    private var timer: Timer?
    private var seen: Set<UUID> = []
    private var lines: [Voice: [String]] = [:]
    private var lastActivity: [Voice: Date] = [:]
    private var lastPartial: [Voice: String] = [:]
    /// Voices in order of first appearance this session.
    private var order: [Voice] = []

    init(model: AppModel) {
        self.model = model
        seen = Set(model.lines.map(\.id))
        // Coalesced to the next turn of the run loop: committing a line changes `lines` and then
        // clears the partial, and the in-between state would show the words twice.
        model.objectWillChange.sink { [weak self] in self?.schedule() }.store(in: &subs)
    }

    private var pending = false
    private var lastRun = Date.distantPast
    /// At most ~5 updates a second: both lanes' partials (each several a second while talking)
    /// land in one SwiftUI update instead of one each.
    private static let minInterval: TimeInterval = 0.2

    private func schedule() {
        guard !pending else { return }
        pending = true
        let wait = max(0, Self.minInterval - Date().timeIntervalSince(lastRun))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self = self else { return }
            self.pending = false
            self.lastRun = Date()
            self.update(lines: self.model.lines, partials: self.model.partials)
        }
    }

    /// Runs the expiry clock only while the bar is up.
    func setActive(_ on: Bool) {
        timer?.invalidate(); timer = nil
        guard on else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.update(lines: self.model.lines, partials: self.model.partials)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func noteActivity(_ v: Voice, at now: Date) {
        lastActivity[v] = now
        if !order.contains(v) { order.append(v) }
    }

    private func update(lines all: [TranscriptLine], partials: [Voice: String], now: Date = Date()) {
        // New lines can land anywhere near the end (they're sorted by start time); a short
        // suffix is enough to find them without walking a long transcript.
        for line in all.suffix(24) where !seen.contains(line.id) {
            seen.insert(line.id)
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let v = Voice(line)
            lines[v, default: []].append(text)
            lines[v] = Array(lines[v]!.suffix(Self.keepLines))
            noteActivity(v, at: now)
        }
        if all.isEmpty {   // a new session
            seen.removeAll(); lines.removeAll(); order.removeAll(); lastActivity.removeAll()
            if chipColumn != Self.chipWidth("them") { chipColumn = Self.chipWidth("them") }
        }
        for v in Set(partials.keys).union(lastPartial.keys) {
            let p = partials[v] ?? ""
            if p != lastPartial[v] ?? "" {
                lastPartial[v] = p.isEmpty ? nil : p
                if !p.isEmpty { noteActivity(v, at: now) }
            }
        }

        // me first, then "them" voices as they appeared. Expired voices drop out of the order so
        // a later return puts them at the end again.
        order.sort { a, b in a.speaker != b.speaker ? a.speaker == .me : false }   // stable: keeps appearance order within them
        var next: [Block] = []
        for v in order {
            guard let at = lastActivity[v] else { continue }
            let partial = Self.capped(lastPartial[v] ?? "")
            if now.timeIntervalSince(at) > Self.silence && partial.isEmpty {
                lines[v] = nil; lastActivity[v] = nil
                continue
            }
            let committed = lines[v] ?? []
            guard !committed.isEmpty || !partial.isEmpty else { continue }
            next.append(Block(voice: v, chip: LaneColors.chipLabel(v.speaker, app: v.app), committed: committed, partial: partial))
        }
        order.removeAll { lastActivity[$0] == nil }
        // Too many voices: keep me and the most recently active apps.
        while next.count > Self.maxBlocks, let i = next.indices.filter({ next[$0].speaker == .them })
                .min(by: { (lastActivity[next[$0].voice] ?? .distantPast) < (lastActivity[next[$1].voice] ?? .distantPast) }) {
            next.remove(at: i)
        }
        for b in next where b.speaker == .them {
            let w = Self.chipWidth(b.chip)
            if w > chipColumn { chipColumn = w }
        }
        guard next != blocks else { return }
        // Not withAnimation: the view animates blocks coming and going itself (CaptionsSlot).
        blocks = next
    }

    /// A runaway hypothesis is cut from the front in 200-character steps, at a word boundary:
    /// the text only re-wraps when a step is taken, not on every word.
    static func capped(_ s: String) -> String {
        let step = 200
        guard s.count > 2 * step else { return s }
        let drop = (s.count - step) / step * step
        var tail = s.dropFirst(drop)
        if let sp = tail.firstIndex(of: " ") { tail = tail[tail.index(after: sp)...] }
        return "…" + tail
    }
}

// MARK: - Views

enum CaptionMetrics {
    static let font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
    /// The font's own line height; `lineSpacing` tops it up to 1.25 × the point size.
    static let natural = ceil(NSLayoutManager().defaultLineHeight(for: font))
    static let lineSpacing = max(0, (13.5 * 1.25).rounded() - natural)
    /// Exactly two lines.
    static let box = 2 * natural + lineSpacing
    static let padH: CGFloat = 14, padV: CGFloat = 12, blockGap: CGFloat = 10
    /// Card height with `n` blocks ("Listening…" counts as one).
    static func cardHeight(_ n: Int) -> CGFloat {
        let n = max(1, n)
        return 2 * padV + CGFloat(n) * box + CGFloat(n - 1) * blockGap
    }
}

/// The captions card: up to two speaker blocks, or a single muted status line.
struct CaptionsCard: View {
    @ObservedObject var feed: CaptionsFeed
    let bar: RecordingBarState

    var body: some View {
        VStack(alignment: .leading, spacing: CaptionMetrics.blockGap) {
            if feed.blocks.isEmpty {
                IdleLine(bar: bar)
                    .frame(maxWidth: .infinity, minHeight: CaptionMetrics.box, maxHeight: CaptionMetrics.box, alignment: .leading)
                    .transition(.opacity)
            } else {
                ForEach(feed.blocks) { b in
                    HStack(alignment: .top, spacing: 10) {
                        Chip(text: b.chip, color: LaneColors.bright(b.speaker), size: 11)
                            .frame(width: chipWidth, alignment: .trailing)   // a gutter: every chip 10 pt from its text
                            .padding(.top, (CaptionMetrics.natural - 17) / 2)   // centred on line 1
                        CaptionText(committed: b.committed, partial: b.partial)
                    }
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, CaptionMetrics.padH)
        .padding(.vertical, CaptionMetrics.padV)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chipWidth: CGFloat { feed.chipColumn }
}

/// "Listening…" while nobody has spoken for a while.
private struct IdleLine: View {
    @ObservedObject var bar: RecordingBarState
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "captions.bubble").font(.system(size: 12, weight: .medium))
            Text(text).font(.system(size: 13.5, weight: .medium))
        }
        .foregroundStyle(Color.white.opacity(0.4))
    }
    private var text: String {
        switch bar.phase {
        case .paused: return "Paused · nothing is being captured"
        case .starting: return "Getting ready…"
        default: return "Listening…"
        }
    }
}

/// Two lines of caption text that scroll up like subtitles.
///
/// The text is laid out at its full height in a two-line clip; once it is longer than two lines
/// it is bottom-aligned, so the newest words are always on the bottom line. The scroll is
/// animated by hand: the text sits in a frame of the LAST measured height, top-aligned, so when
/// a new line appears it starts below the clip (invisible); the measured height then animates to
/// the new value and everything slides up.
struct CaptionText: View {
    let committed: [String]
    let partial: String
    @State private var shownHeight: CGFloat = 0
    private var scrolled: Bool { shownHeight > CaptionMetrics.box + 0.5 }

    var body: some View {
        text
            .font(Font(CaptionMetrics.font))
            .lineSpacing(CaptionMetrics.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.identity)
            .background(GeometryReader { g in Color.clear.preference(key: TextHeightKey.self, value: g.size.height) })
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: max(shownHeight, 1), alignment: .top)
            // Up to two lines the text starts on the top line, beside the chip; from the third
            // on it is bottom-aligned and scrolls.
            .frame(height: CaptionMetrics.box, alignment: scrolled ? .bottom : .top)
            // Scoped to this view: a withAnimation here would animate everything else that
            // happens to change in the bar in the same update.
            .animation(.easeOut(duration: 0.25), value: shownHeight)
            .clipped()
            // The line sliding out of the top dims instead of being chopped.
            .mask(VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(scrolled ? 0.15 : 1), .black], startPoint: .top, endPoint: .bottom).frame(height: 10)
                Color.black
            })
            .onPreferenceChange(TextHeightKey.self) { h in
                guard abs(h - shownHeight) > 0.5 else { return }
                var t = Transaction()
                t.disablesAnimations = shownHeight == 0   // a new block starts in place
                withTransaction(t) { shownHeight = h }
            }
    }

    /// Committed utterances one per line; the partial continues on its own line, dimmer.
    private var text: Text {
        let done = committed.joined(separator: "\n")
        var t = Text(done).foregroundStyle(Color.white.opacity(0.92))
        if !partial.isEmpty {
            t = t + Text((done.isEmpty ? "" : "\n") + partial).foregroundStyle(Color.white.opacity(0.7))
        }
        return t
    }
}

private struct TextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
