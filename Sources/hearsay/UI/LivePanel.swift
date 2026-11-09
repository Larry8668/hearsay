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

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let p = panel ?? make()
        panel = p
        p.orderFrontRegardless()   // no activation: we are an accessory app and don't want focus
        onVisibilityChange?()
    }

    func hide() { panel?.orderOut(nil); onVisibilityChange?() }

    func setTitle(_ title: String) { panel?.title = title }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = "hearsay"
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false        // accessory apps are "inactive" almost always
        p.becomesKeyOnlyIfNeeded = true
        p.minSize = NSSize(width: 280, height: 160)
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
    @State private var viewportHeight: CGFloat = 0

    static let meColor = Color(nsColor: .systemBlue)
    static let themColor = Color(nsColor: .systemOrange)

    var body: some View {
        VStack(spacing: 0) {
            if model.lines.isEmpty && model.partials.isEmpty { empty } else { transcript }
            Divider()
            footer
        }
        .frame(minWidth: 280, minHeight: 160)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform").font(.system(size: 28)).foregroundStyle(.secondary)
            Text(model.isListening ? "Listening… lines appear here as people speak." : "Not listening.")
                .foregroundStyle(.secondary)
            if !model.isListening {
                Button("Start listening  ⌃⌥H") { model.actions.toggleListening() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    // The sentinel lives OUTSIDE the lazy stack so it always exists and reports
                    // its position; inside, it wouldn't be instantiated while off-screen.
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: model.fontSize * 0.5) {
                            ForEach(model.lines) { line in row(line) }
                        }
                        ForEach(Speaker.allCases, id: \.self) { s in
                            if let p = model.partials[s] { partialRow(s, p).padding(.top, model.fontSize * 0.5) }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .background(GeometryReader { g in
                                Color.clear.preference(key: BottomKey.self, value: g.frame(in: .named("scroll")).maxY)
                            })
                    }
                    .padding(12)
                    .textSelection(.enabled)
                }
                .coordinateSpace(name: "scroll")
                .defaultScrollAnchor(.bottom)
                .onPreferenceChange(BottomKey.self) { maxY in
                    // "At bottom" = the end is visible (with a little slack). Scrolling up to
                    // reread pauses auto-scroll; scrolling back down resumes it.
                    atBottom = maxY <= outer.size.height + 40
                }
                .onChange(of: model.lines.count) { follow(proxy) }
                .onChange(of: model.partials) { follow(proxy) }
                .onAppear { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom); atBottom = true } }
            }
        }
    }

    private func follow(_ proxy: ScrollViewProxy) {
        guard atBottom else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    private var labelWidth: CGFloat { model.fontSize * 4.2 }

    private func row(_ line: TranscriptLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            label(line.speaker, app: line.sourceApp)
            Text(line.text).font(.system(size: model.fontSize)).frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(TranscriptFormatter().clock(line.start))
    }

    private func partialRow(_ s: Speaker, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            label(s, app: nil).opacity(0.6)
            Text(text).font(.system(size: model.fontSize)).italic().foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func label(_ s: Speaker, app: String?) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(s.rawValue).font(.system(size: model.fontSize, weight: .semibold))
                .foregroundStyle(s == .me ? Self.meColor : Self.themColor)
            if let app = app {
                Text(AppNames.name(for: app)).font(.system(size: model.fontSize * 0.75)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: labelWidth, alignment: .trailing)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { model.actions.toggleListening() } label: {
                Image(systemName: model.isListening ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(model.isListening ? Color.red : Color.primary)
            }
            .help(model.isListening ? "Stop listening (⌃⌥H)" : "Start listening (⌃⌥H)")
            Button("Copy all") { model.actions.copyAll() }.disabled(model.lines.isEmpty)
            Spacer()
            Button { model.bumpFont(-1) } label: { Image(systemName: "textformat.size.smaller") }.help("Smaller text")
            Button { model.bumpFont(1) } label: { Image(systemName: "textformat.size.larger") }.help("Larger text")
            Toggle(isOn: $model.pinned) { Image(systemName: model.pinned ? "pin.fill" : "pin") }
                .toggleStyle(.button).help("Keep above all windows")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 7)
    }
}

private struct BottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
