import AppKit
import Combine
import SwiftUI

/// hearsay's main window: a sidebar of saved transcripts with "Live" on top, the transcript on
/// the right, and a unified toolbar holding the session control (Start / Pause / Stop), text
/// size, Copy and the per-transcript actions. AppKit owns the shell (`NSSplitViewController`
/// gives the full-height sidebar material, the collapsible divider and the window-level
/// toolbar); SwiftUI draws the panes.
///
/// Opened from the menu ("Open hearsay…"), a second launch, or the recording bar's transcript
/// button (which toggles it). Closing it drops the window and its SwiftUI tree so nothing keeps
/// re-rendering per partial while hidden; `MainWindowState` keeps the selection across openings.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate, NSToolbarDelegate, NSMenuDelegate {
    /// What the content pane asks of the window (Delete needs the library and the selection).
    struct ContentActions {
        var delete: (TranscriptLibrary.Entry) -> Void
        var deleteMany: ([TranscriptLibrary.Entry]) -> Void
    }

    let state: MainWindowState
    private let model: AppModel
    private let library: TranscriptLibrary
    /// The live session's transcript file (listed as "Live", not as a past transcript).
    private let currentFile: () -> URL?
    private var window: NSWindow?
    private var split: NSSplitViewController?
    private var subs: Set<AnyCancellable> = []
    var onVisibilityChange: (() -> Void)?

    private static let frameName = "hearsay.Main"

    init(model: AppModel, library: TranscriptLibrary, currentFile: @escaping () -> URL?) {
        self.model = model
        self.library = library
        self.currentFile = currentFile
        state = MainWindowState(library: library, model: model, currentFile: currentFile)
        super.init()
        state.$picked.removeDuplicates().sink { [weak self] _ in
            self?.updateTitle()
            self?.onVisibilityChange?()
        }.store(in: &subs)
        // A title given or changed (saved transcript, or the live session) renames the window too.
        state.$document.map { $0?.meta.title }.removeDuplicates().dropFirst().sink { [weak self] _ in self?.updateTitle() }.store(in: &subs)
        model.$liveMeta.map(\.title).removeDuplicates().dropFirst().sink { [weak self] _ in self?.updateTitle() }.store(in: &subs)
    }

    var isVisible: Bool { window?.isVisible ?? false }
    /// The recording bar's transcript button is "on" while the window shows the live transcript.
    var showingLive: Bool { isVisible && state.selection == .live }

    /// Brings the window up (built on first use). `activate`: take focus, as the menu and a
    /// relaunch do. The recording bar's button passes false: a click on it must never take focus
    /// from the call, so the window comes to the front without the app activating (its title bar
    /// reads as inactive); the first click inside activates it like any background window.
    func show(live: Bool = false, activate: Bool = true) {
        library.start()
        if live || model.isActive && window == nil { state.selection = .live }
        let w = window ?? make()
        window = w
        // A Dock icon and a real menu bar while the window is up; back to a menu-bar-only app
        // when it closes (windowWillClose). Set before activating so the menu bar comes along.
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        } else {
            w.orderFrontRegardless()
        }
        onVisibilityChange?()
    }

    /// The bar's button: show the live transcript, or close the window if that is already up.
    func toggleLive() { showingLive ? close() : show(live: true, activate: false) }

    func close() { window?.close() }

    private func make() -> NSWindow {
        let split = NSSplitViewController()
        split.splitView.autosaveName = "hearsay.MainSplit"
        let sidebar = NSHostingController(rootView: MainSidebarView(state: state, library: library, model: model, currentFile: currentFile))
        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = 200
        side.maximumThickness = 320
        side.canCollapse = true
        split.addSplitViewItem(side)
        let actions = ContentActions(delete: { [weak self] in self?.delete($0) }, deleteMany: { [weak self] in self?.deleteMany($0) })
        let content = NSHostingController(rootView: MainContentView(state: state, library: library, model: model, actions: actions))
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        self.split = split

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.contentViewController = split
        w.titleVisibility = .hidden          // the content header carries the title; see updateTitle
        w.toolbarStyle = .unified
        w.titlebarSeparatorStyle = .automatic
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 640, height: 400)
        w.delegate = self
        let toolbar = NSToolbar(identifier: "hearsay.MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        w.toolbar = toolbar
        // Setting the content view controller sized the window to its fitting size; first run
        // gets a proper default, later runs the remembered frame.
        if !w.setFrameUsingName(Self.frameName) { w.setContentSize(NSSize(width: 980, height: 640)); w.center() }
        w.setFrameAutosaveName(Self.frameName)
        updateTitle(w)
        return w
    }

    /// Mission Control, the Window menu and accessibility see the title; the title bar hides it.
    private func updateTitle(_ w: NSWindow? = nil) {
        guard let w = w ?? window else { return }
        if state.isBulk { w.title = "\(state.picked.count) transcripts — hearsay"; return }
        switch state.selection {
        case .live: w.title = (model.liveMeta.title ?? "Live transcript") + " — hearsay"
        case .transcript:
            let e = state.selectedEntry
            w.title = e.map { ($0.meta.title ?? TranscriptFormatter().dateRange(start: $0.startedAt, end: $0.endedAt)) + " — hearsay" } ?? "hearsay"
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Free the SwiftUI tree so nothing re-renders per partial while the window is closed.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.window?.contentViewController = nil
            self.window = nil
            self.split = nil
            // Menu-bar-only again: the Dock icon goes, and the menu bar returns to the app the
            // user is about to click into anyway (the welcome and About panels are fine without).
            if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
            self.onVisibilityChange?()
        }
    }

    // MARK: Toolbar

    private enum Item {
        static let session = NSToolbarItem.Identifier("hearsay.session")
        static let fontSize = NSToolbarItem.Identifier("hearsay.fontSize")
        static let copy = NSToolbarItem.Identifier("hearsay.copy")
        static let more = NSToolbarItem.Identifier("hearsay.more")
        static let separator = NSToolbarItem.Identifier("hearsay.separator")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, Item.separator, Item.session, .flexibleSpace, Item.fontSize, Item.copy, Item.more]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Item.separator:
            guard let split = split else { return nil }
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 0)
        case Item.session:
            return hosted(id, SessionControl(state: state, model: model), label: "Session")
        case Item.fontSize:
            return hosted(id, FontSizeControl(model: model), label: "Text size")
        case Item.copy:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Copy"
            item.toolTip = "Copy the shown transcript as plain text"
            item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
            item.isBordered = true
            item.target = self
            item.action = #selector(copyTranscript)
            return item
        case Item.more:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "More"
            item.toolTip = "Export, copy, reveal, open, delete"
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
            item.showsIndicator = false
            let menu = NSMenu()
            menu.delegate = self        // rebuilt for the selection each time it opens
            item.menu = menu
            moreMenu = menu
            return item
        default:
            return nil
        }
    }

    private func hosted<V: View>(_ id: NSToolbarItem.Identifier, _ view: V, label: String) -> NSToolbarItem {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = .intrinsicContentSize
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = host
        item.label = label
        return item
    }

    /// The ⋯ menu, kept so the dev script can open it.
    private var moreMenu: NSMenu?

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if state.isBulk {
            let mi = NSMenuItem(title: "Move \(state.picked.count) Transcripts to Trash…", action: #selector(askDelete), keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
            return
        }
        let past = state.selectedEntry != nil
        let add = { (title: String, sel: Selector, key: String) -> NSMenuItem in
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            mi.target = self
            menu.addItem(mi)
            return mi
        }
        let some = !shownLines().isEmpty
        add("Export…", #selector(exportTranscript), "e").isEnabled = some
        add("Export subtitles (.srt)", #selector(exportSRT), "").isEnabled = some
        menu.addItem(.separator())
        add("Copy as text", #selector(copyTranscript), "").isEnabled = some
        add("Copy as Markdown", #selector(copyMarkdown), "").isEnabled = some
        menu.addItem(.separator())
        _ = add("Reveal in Finder", #selector(revealInFinder), "")
        _ = add(past ? "Open in editor" : "Open transcript file", #selector(openTranscript), "")
        if past {
            menu.addItem(.separator())
            _ = add("Move to Trash…", #selector(askDelete), "")
        }
    }

    // MARK: Actions on the shown transcript (filtered like the view)

    /// The lines on screen: the saved transcript or the live session, minus hidden voices.
    private func shownLines() -> [TranscriptLine] {
        if let doc = state.document { return doc.lines.visible(hiding: state.hidden(for: doc.entry.jsonURL)) }
        return model.lines.visible(hiding: model.hiddenVoices)
    }

    /// What is on screen, with its names, ready for any format: the saved transcript, or the
    /// live session straight from its store (so a title given mid-call is in the export).
    private func shownExport() -> TranscriptExport? {
        if let doc = state.document { return TranscriptExport(document: doc, hiding: state.hidden(for: doc.entry.jsonURL), yourName: model.yourName) }
        return liveStore().map { TranscriptExport(store: $0, hiding: model.hiddenVoices) }
    }

    /// Copy (toolbar) and "Copy as text": "[14:03:12] me: …" per line.
    @objc private func copyTranscript() {
        guard !state.isBulk else { return }
        if state.selectedEntry != nil, let e = shownExport() { TranscriptStore.copy(e.formatter.plainText(lines: e.lines)) }
        else { model.actions.copyAll(model.hiddenVoices) }
    }

    @objc private func copyMarkdown() {
        guard !state.isBulk else { return }
        if let e = shownExport() { TranscriptStore.copy(e.render(.markdown)) }
    }

    /// Export… (⋯ menu, File ▸ Export…, ⌘E): the save panel with the format popup.
    @objc func exportTranscript() {
        guard !state.isBulk else { return }
        if let e = shownExport() { ExportPanel.run(e, in: window) }
    }

    @objc private func exportSRT() {
        guard !state.isBulk else { return }
        if let doc = state.document {
            let hidden = state.hidden(for: doc.entry.jsonURL)
            if let url = TranscriptStore.writeSRT(lines: doc.lines.visible(hiding: hidden), start: doc.entry.startedAt, nextTo: doc.entry.markdownURL) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } else {
            model.actions.exportSRT(model.hiddenVoices)
        }
    }

    @objc private func revealInFinder() {
        guard !state.isBulk else { return }
        if let e = state.selectedEntry { NSWorkspace.shared.activateFileViewerSelecting([e.markdownURL]) } else { model.actions.revealInFinder() }
    }

    @objc private func openTranscript() {
        guard !state.isBulk else { return }
        if let e = state.selectedEntry { NSWorkspace.shared.open(e.markdownURL) } else { model.actions.openTranscript() }
    }

    @objc private func askDelete() { if state.isBulk || state.selectedEntry != nil { state.confirmingDelete = true } }

    private func delete(_ entry: TranscriptLibrary.Entry) {
        state.confirmingDelete = false
        library.delete(entry, except: currentFile())
        state.selection = .live     // the watcher would do this a moment later; don't show a trashed file meanwhile
    }

    /// Bulk delete (one Undo-able Finder operation), then the row after the last deleted one in
    /// the sidebar as it stands (search included), else Live.
    private func deleteMany(_ entries: [TranscriptLibrary.Entry]) {
        state.confirmingDelete = false
        let gone = Set(entries.map(\.jsonURL))
        let order = state.visibleEntries
        let next = order.lastIndex { gone.contains($0.jsonURL) }.flatMap { i in order[(i + 1)...].first { !gone.contains($0.jsonURL) } }
        library.delete(entries, except: currentFile())
        state.pick([next.map { .transcript($0.jsonURL) } ?? .live])
    }

    // MARK: Dev aids (HEARSAY_UI_SCRIPT)

    /// `window`: open · `past`: select the newest saved transcript · `hideme`: toggle the "me"
    /// chip · `delete`: show the Trash confirm · `selectall`: pick every listed transcript · `bulkdelete`: trash the picked ones (no confirm) · `dark` / `light`: force the appearance ·
    /// `small` / `large`: 700×480 / 1200×800 · `title=…`: set the shown transcript's title ·
    /// `tags=a;b`: set its tags · `edittitle` / `addtag` / `rename`: open those inline editors
    /// (rename: the first voice chip) · `name=…`: name the first voice · `search=…`: filter the
    /// sidebar · `yourname=…`: Settings ▸ Your name · `more`: open the ⋯ menu · `export`: the
    /// Export… panel.
    @objc private func popUpMoreMenu() {
        guard let menu = moreMenu, let view = window?.contentView else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX - 40, y: view.bounds.maxY - 4), in: view)
    }

    func scriptActions() -> [String: () -> Void] {
        [
            "window": { [weak self] in self?.show() },
            "title": { [weak self] in self?.editMeta { $0.setTitle(DebugSnapshot.scriptArgument) } },
            "tags": { [weak self] in self?.editMeta { $0.setTags(DebugSnapshot.scriptArgument.split(separator: ";").map(String.init)) } },
            "name": { [weak self] in
                guard let self = self, let v = self.shownVoices().first else { return }
                self.editMeta { $0.setName(DebugSnapshot.scriptArgument, for: v) }
            },
            "edittitle": { [weak self] in self?.state.editing = .title },
            "addtag": { [weak self] in self?.state.editing = .tag },
            "rename": { [weak self] in if let v = self?.shownVoices().first { self?.state.editing = .rename(v) } },
            "search": { [weak self] in self?.state.query = DebugSnapshot.scriptArgument },
            "yourname": { [weak self] in self?.model.yourName = TranscriptMeta.cleanTitle(DebugSnapshot.scriptArgument) },
            // A pop-up menu tracks modally. Opened from inside a main-queue block it would keep that
            // block (and every later one: the next script step, the SIGTERM quit) waiting until it
            // closes; a zero-delay perform runs from the run loop, outside any GCD block.
            "more": { [weak self] in
                guard let self = self else { return }
                self.perform(#selector(self.popUpMoreMenu), with: nil, afterDelay: 0)
            },
            // Pop-up menus track modally; this closes one opened by "more" so a scripted run can go on.
            "closemenu": { [weak self] in self?.moreMenu?.cancelTracking() },
            "export": { [weak self] in self?.exportTranscript() },
            "past": { [weak self] in
                guard let self = self else { return }
                if let e = self.library.entries.first(where: { $0.jsonURL != self.currentFile() }) { self.state.selection = .transcript(e.jsonURL) }
            },
            "hideme": { [weak self] in
                guard let self = self else { return }
                if let e = self.state.selectedEntry { self.state.toggle(.me, for: e.jsonURL) }
                else if self.model.hiddenVoices.contains(.me) { self.model.hiddenVoices.remove(.me) } else { self.model.hiddenVoices.insert(.me) }
            },
            "delete": { [weak self] in self?.askDelete() },
            "selectall": { [weak self] in
                guard let self = self else { return }
                self.state.pick(Set(self.state.visibleEntries.map { MainSelection.transcript($0.jsonURL) }))
            },
            "bulkdelete": { [weak self] in
                guard let self = self, self.state.isBulk else { return }
                self.deleteMany(self.state.bulkEntries)
            },
            "dark": { [weak self] in self?.window?.appearance = NSAppearance(named: .darkAqua) },
            "light": { [weak self] in self?.window?.appearance = NSAppearance(named: .aqua) },
            "small": { [weak self] in self?.window?.setContentSize(NSSize(width: 700, height: 480)) },
            "large": { [weak self] in self?.window?.setContentSize(NSSize(width: 1200, height: 800)) },
        ]
    }

    /// The session's store while it runs, or the last one (Copy / Export of the live view).
    private func liveStore() -> TranscriptStore? { model.actions.liveStore() }

    private func shownVoices() -> [Voice] {
        if let doc = state.document { return doc.lines.voices }
        return model.lines.voices
    }

    /// Applies a change to the shown transcript's title / tags / names, saved or live.
    private func editMeta(_ change: (inout TranscriptMeta) -> Void) {
        if let doc = state.document {
            var m = doc.meta; change(&m); state.setMeta(m)
        } else {
            var m = model.liveMeta; change(&m); model.actions.setLiveMeta(m)
        }
    }
}
