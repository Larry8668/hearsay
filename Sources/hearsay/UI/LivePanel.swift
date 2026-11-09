import AppKit
import Combine
import SwiftUI

/// Floating live transcript. A non-activating panel: clicking it (copy, font size) never steals
/// focus from the call app, which matters while you are talking and typing in Zoom.
final class LivePanel: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var panel: NSPanel?
    private var pinSub: AnyCancellable?
    var onVisibilityChange: (() -> Void)?

    init(model: AppModel) { self.model = model }

    var isVisible: Bool { panel?.isVisible ?? false }
    /// Title-bar height of a utility panel; the SwiftUI header fills exactly that strip.
    static var titlebarHeight: CGFloat = 19

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let p = panel ?? make()
        panel = p
        p.orderFrontRegardless()   // no activation: we are an accessory app and don't want focus
        onVisibilityChange?()
    }

    func hide() { panel?.orderOut(nil); onVisibilityChange?() }

    /// Hidden in the title bar, but still what Mission Control and accessibility report.
    func setTitle(_ title: String) { if panel?.title != title { panel?.title = title } }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = "hearsay"
        // Content runs under a transparent title bar; the SwiftUI header sits beside the close button.
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false        // accessory apps are "inactive" almost always
        p.becomesKeyOnlyIfNeeded = true
        p.minSize = NSSize(width: 360, height: 220)
        LivePanel.titlebarHeight = p.frame.height - p.contentLayoutRect.height
        p.contentView = NSHostingView(rootView: LiveTranscriptView(model: model))
        p.delegate = self
        // Restore the user's last frame; first time, park it in the top-right corner.
        if !p.setFrameUsingName("hearsay.LivePanel"), let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.maxX - p.frame.width - 20, y: screen.maxY - p.frame.height - 20))
        }
        p.setFrameAutosaveName("hearsay.LivePanel")
        pinSub = model.$pinned.sink { [weak p] pinned in LivePanel.applyPin(pinned, to: p) }
        return p
    }

    /// Pinned: float above everything, including a full-screen call window on its own Space.
    private static func applyPin(_ pinned: Bool, to p: NSPanel?) {
        guard let p = p else { return }
        p.level = pinned ? .floating : .normal
        p.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.managed]
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.onVisibilityChange?() }
    }
}

// MARK: - SwiftUI

struct LiveTranscriptView: View {
    @ObservedObject var model: AppModel
    @State private var atBottom = true
    @State private var newLines = false

    /// Same speaker within this many seconds continues a "paragraph": the chip is shown once.
    static let groupGap: TimeInterval = 20
    private static let timeWidth: CGFloat = 56, maxText: CGFloat = 640
    private var rowMaxWidth: CGFloat { Self.timeWidth + chipWidth + Self.maxText + 20 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                if model.lines.isEmpty && model.partials.isEmpty { empty } else { transcript }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()   // lines must not scroll up under the header in the transparent title bar
            Divider()
            footer
        }
        // The header lives in the transparent title bar, beside the window buttons: an overlay
        // that ignores the safe area, so the scroll view keeps its normal insets below the bar.
        .overlay(alignment: .top) {
            header.frame(maxHeight: .infinity, alignment: .top).ignoresSafeArea(edges: .top).allowsHitTesting(false)
        }
        .frame(minWidth: 360, minHeight: 220)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    }

    // MARK: Header

    /// "Live transcript · 12 min · 48 lines", in the title bar beside the close button.
    private var header: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            HStack(spacing: 6) {
                if model.phase == .listening {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                } else if model.phase == .paused {
                    Image(systemName: "pause.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.orange)
                }
                Text(headerText(now: ctx.date))
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 64)   // clear of the window buttons
        .padding(.trailing, 12)
        .frame(height: LivePanel.titlebarHeight)
    }

    private func headerText(now: Date) -> String {
        var parts = ["Live transcript"]
        if model.startedAt != nil {
            parts.append("\(Int(model.listeningTime(now: now) / 60)) min")
            parts.append("\(model.lines.count) line\(model.lines.count == 1 ? "" : "s")")
        }
        if model.phase == .paused { parts.append("paused") }
        return parts.joined(separator: " · ")
    }

    // MARK: Empty state

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolEffect(.variableColor.iterative, isActive: model.phase == .listening)
            Text(emptyText).font(.system(size: 13.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.phase == .idle {
                Button("Start listening") { model.actions.toggleListening() }.controlSize(.regular)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyText: String {
        switch model.phase {
        case .listening: return "Listening… say something, or play audio."
        case .starting: return "Getting ready…"
        case .paused: return "Paused. Press ⌃⌥P to resume."
        case .stopping: return "Saving transcript…"
        case .idle: return "Press ⌃⌥H to start listening."
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        GeometryReader { outer in
            let compact = outer.size.width < 540
            ScrollViewReader { proxy in
                ScrollView {
                    // The sentinel lives OUTSIDE the lazy stack so it always exists and reports
                    // its position; inside, it wouldn't be instantiated while off-screen.
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(model.lines.enumerated()), id: \.element.id) { i, line in
                                row(line, chip: startsGroup(i), compact: compact)
                            }
                        }
                        ForEach(Speaker.allCases, id: \.self) { s in
                            if let p = model.partials[s] { partialRow(s, p, compact: compact).padding(.top, 8) }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .background(GeometryReader { g in
                                Color.clear.preference(key: BottomKey.self, value: g.frame(in: .named("scroll")).maxY)
                            })
                    }
                    .frame(maxWidth: rowMaxWidth)
                    .frame(maxWidth: .infinity)          // centred when the window is wide
                    .padding(16)
                    .textSelection(.enabled)
                }
                .coordinateSpace(name: "scroll")
                .defaultScrollAnchor(.bottom)
                .onPreferenceChange(BottomKey.self) { maxY in
                    // "At bottom" = the end is visible (with a little slack). Scrolling up to
                    // reread pauses auto-scroll; scrolling back down resumes it.
                    atBottom = maxY <= outer.size.height + 40
                    if atBottom { newLines = false }
                }
                .onChange(of: model.lines.count) { follow(proxy, newLine: true) }
                .onChange(of: model.partials) { follow(proxy, newLine: false) }
                .onAppear { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom); atBottom = true } }
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
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: newLines)
            }
        }
    }

    private func follow(_ proxy: ScrollViewProxy, newLine: Bool) {
        guard atBottom else { if newLine { newLines = true }; return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    /// The chip shows on the first line of a run: new speaker, different app, or a 20 s gap.
    private func startsGroup(_ i: Int) -> Bool {
        guard i > 0 else { return true }
        let a = model.lines[i - 1], b = model.lines[i]
        return a.speaker != b.speaker || a.sourceApp != b.sourceApp || b.start.timeIntervalSince(a.start) > Self.groupGap
    }

    private var textFont: Font { .system(size: model.fontSize) }
    /// 1.3 × the font size, measured line to line (SF's natural leading is ≈1.2).
    private var lineGap: CGFloat { model.fontSize * 0.1 }

    /// Width of the chip column: the widest label this session actually uses, so a transcript
    /// with only "me" / "them" doesn't reserve room for "them · Microsoft Teams".
    private var chipWidth: CGFloat {
        var labels = Set(["them"])
        for case let app? in Set(model.lines.map(\.sourceApp)) { labels.insert(LaneColors.chipLabel(.them, app: app)) }
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let widest = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 30
        return min(130, ceil(widest) + 16)
    }

    /// Wide: `time │ chip │ text`. Narrow (a panel tucked beside the call): the time moves under
    /// the chip, so the text keeps a readable measure instead of a 200 pt sliver.
    private func gutter<C: View, T: View>(compact: Bool, @ViewBuilder chip: () -> C, @ViewBuilder time: () -> T) -> some View {
        Group {
            if compact {
                VStack(alignment: .trailing, spacing: 3) { chip(); time() }
                    .frame(width: max(chipWidth, 60), alignment: .trailing)   // room for "14:03:12"
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    time().frame(width: Self.timeWidth, alignment: .leading)
                    chip().frame(width: chipWidth, alignment: .trailing)
                }
            }
        }
    }

    private func row(_ line: TranscriptLine, chip: Bool, compact: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            gutter(compact: compact) {
                if chip {
                    Chip(text: LaneColors.chipLabel(line.speaker, app: line.sourceApp), color: LaneColors.adaptive(line.speaker), size: 11)
                } else if !compact {
                    // Invisible stand-in keeps the column's width and the row's text baseline.
                    Chip(text: "me", color: .clear, size: 11).hidden()
                }
            } time: {
                Text(TranscriptFormatter().clock(line.start))
                    .font(.system(size: compact ? 10.5 : 11, design: .monospaced))
                    .foregroundStyle(chip ? .secondary : .tertiary)
                    .lineLimit(1).fixedSize()
            }
            Text(line.text)
                .font(textFont)
                .lineSpacing(lineGap)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, chip && line.id != model.lines.first?.id ? 6 : 0)   // a little air between runs
    }

    private func partialRow(_ s: Speaker, _ text: String, compact: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            gutter(compact: compact) {
                Chip(text: LaneColors.chipLabel(s, app: s == .them ? lastThemApp : nil), color: LaneColors.adaptive(s), size: 11)
            } time: {
                TypingDots()
            }
            Text(text).font(textFont).italic()
                .lineSpacing(lineGap)
                .foregroundStyle(.primary.opacity(0.65))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lastThemApp: String? { model.lines.last(where: { $0.speaker == .them && $0.sourceApp != nil })?.sourceApp }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button { model.actions.copyAll() } label: { Label("Copy all", systemImage: "doc.on.doc") }
                .disabled(model.lines.isEmpty).opacity(model.lines.isEmpty ? 0.45 : 1).help("Copy the transcript as plain text")
            Button { model.actions.exportSRT() } label: { Label("Export SRT", systemImage: "captions.bubble") }
                .disabled(model.lines.isEmpty).opacity(model.lines.isEmpty ? 0.45 : 1).help("Write subtitles next to the transcript and show them in Finder")
            Button { model.actions.revealInFinder() } label: { Label("Reveal in Finder", systemImage: "folder") }
                .help("Show the transcript file in Finder")
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Button { model.bumpFont(-1) } label: { Text("A").font(.system(size: 10.5, weight: .medium)).frame(width: 20) }
                    .help("Smaller text")
                Button { model.bumpFont(1) } label: { Text("A").font(.system(size: 14, weight: .medium)).frame(width: 20) }
                    .help("Larger text")
            }
            Button { model.pinned.toggle() } label: {
                Image(systemName: model.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(model.pinned ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
            }
            .help(model.pinned ? "Pinned above other windows" : "Keep above other windows")
        }
        .labelStyle(FooterLabelStyle())
        .font(.system(size: 12))
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

/// Icon + label, 12 pt, tight spacing.
private struct FooterLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.system(size: 11)); configuration.title }
    }
}

private struct BottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
