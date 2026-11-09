import AppKit

/// NSStatusItem + menu. Pure view: everything it does goes through `actions`, everything it shows
/// comes in through `update(_:)`.
final class MenuBar: NSObject, NSMenuDelegate {
    enum IconState { case idle, listening, error }

    struct Actions {
        var toggleListening: () -> Void
        var togglePanel: () -> Void
        var openTranscript: () -> Void
        var openFolder: () -> Void
        var exportSRT: () -> Void
        var copyAll: () -> Void
        var toggleSource: (Speaker) -> Void
        var toggleLoginItem: () -> Void
        var setFontSize: (Double) -> Void
        var showWelcome: () -> Void
        var openLogs: () -> Void
        var openSettings: (Speaker) -> Void
        var relaunch: () -> Void
        var checkUpdates: () -> Void
        var updateNow: () -> Void
        var copyUpdateCommand: () -> Void
        var openReleasePage: () -> Void
        var toggleUpdateChecks: () -> Void
        var quit: () -> Void
    }

    /// Everything the menu displays, computed by AppDelegate.
    struct State {
        var icon: IconState = .idle
        var status = "Not listening"
        var warning: String?
        var permissionDenied: Set<Speaker> = []
        var listening = false
        var busy = false              // starting / stopping
        var panelVisible = false
        var hasTranscript = false
        var sources: [Speaker: Bool] = [:]
        var launchAtLogin = false
        var fontSize: Double = 13
        var engine = ""
    }

    private let item: NSStatusItem
    private let menu = NSMenu()
    private let actions: Actions
    private let hotkey: Hotkey

    private let statusLine = NSMenuItem()
    private let warningLine = NSMenuItem()
    private let micPermissionItem = NSMenuItem()
    private let tapPermissionItem = NSMenuItem()
    private let startStopItem = NSMenuItem()
    private let panelItem = NSMenuItem()
    private let openItem = NSMenuItem()
    private let srtItem = NSMenuItem()
    private let copyItem = NSMenuItem()
    private let meItem = NSMenuItem()
    private let themItem = NSMenuItem()
    private let loginItem = NSMenuItem()
    private let updateChecksItem = NSMenuItem()
    private let fontItem = NSMenuItem()
    private let engineItem = NSMenuItem()
    private let versionItem = NSMenuItem()
    var onMenuWillOpen: (() -> Void)?
    var menuDescription: String { DebugSnapshot.describe(menu) }

    init(actions: Actions, hotkey: Hotkey) {
        self.actions = actions
        self.hotkey = hotkey
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        build()
        setIcon(.idle)
    }

    /// Top level = essentials only:
    ///   status · warning · permission fixes
    ///   Start/Stop listening · Show live transcript
    ///   Open transcript · Open transcripts folder · More ▸ (SRT, copy)
    ///   Sources ▸  Settings ▸  Troubleshooting ▸
    ///   version/update ▸ · Quit
    private func build() {
        menu.delegate = self
        menu.autoenablesItems = false

        statusLine.isEnabled = false
        warningLine.isEnabled = false
        warningLine.isHidden = true
        micPermissionItem.title = "⚠ Microphone access denied — Open settings…"
        tapPermissionItem.title = "⚠ System audio recording denied — Open settings…"
        bind(micPermissionItem, #selector(openMicSettings))
        bind(tapPermissionItem, #selector(openTapSettings))
        menu.addItem(statusLine)
        menu.addItem(warningLine)
        menu.addItem(micPermissionItem)
        menu.addItem(tapPermissionItem)
        menu.addItem(.separator())

        bind(startStopItem, #selector(toggleListening))
        startStopItem.keyEquivalent = hotkey.display.last.map { String($0).lowercased() } ?? ""
        startStopItem.keyEquivalentModifierMask = hotkey.menuModifiers
        menu.addItem(startStopItem)
        panelItem.title = "Show live transcript"
        bind(panelItem, #selector(togglePanel))
        menu.addItem(panelItem)
        menu.addItem(.separator())

        openItem.title = "Open transcript"
        bind(openItem, #selector(openTranscript))
        menu.addItem(openItem)
        menu.addItem(item("Open transcripts folder", #selector(openFolder)))
        copyItem.title = "Copy transcript"
        bind(copyItem, #selector(copyAll))
        srtItem.title = "Export subtitles (.srt)"
        bind(srtItem, #selector(exportSRT))
        menu.addItem(copyItem)
        menu.addItem(srtItem)
        menu.addItem(.separator())

        // Sources ▸
        let sources = NSMenu()
        meItem.title = "Me (microphone)"
        themItem.title = "Them (system audio)"
        bind(meItem, #selector(toggleMe))
        bind(themItem, #selector(toggleThem))
        sources.addItem(meItem)
        sources.addItem(themItem)
        menu.addItem(submenu("Sources", sources))

        // Settings ▸
        let settings = NSMenu()
        settings.addItem(item("Welcome & permissions…", #selector(showWelcome)))
        settings.addItem(.separator())
        loginItem.title = "Launch at login"
        bind(loginItem, #selector(toggleLoginItem))
        settings.addItem(loginItem)
        updateChecksItem.title = "Check for updates daily"
        bind(updateChecksItem, #selector(toggleUpdateChecks))
        settings.addItem(updateChecksItem)
        fontItem.title = "Live panel font size"
        let fonts = NSMenu()
        for (size, name) in AppModel.fontChoices {
            let mi = item(name, #selector(chooseFont(_:)))
            mi.tag = Int(size)
            fonts.addItem(mi)
        }
        fontItem.submenu = fonts
        settings.addItem(fontItem)
        engineItem.isEnabled = false
        settings.addItem(engineItem)
        menu.addItem(submenu("Settings", settings))

        // Troubleshooting ▸
        let trouble = NSMenu()
        trouble.addItem(item("Open logs", #selector(openLogs)))
        trouble.addItem(item("Microphone settings…", #selector(openMicSettings)))
        trouble.addItem(item("System audio settings…", #selector(openTapSettings)))
        trouble.addItem(item("Relaunch hearsay", #selector(relaunch)))
        menu.addItem(submenu("Troubleshooting", trouble))
        menu.addItem(.separator())

        versionItem.submenu = NSMenu()
        menu.addItem(versionItem)
        menu.addItem(item("Quit hearsay", #selector(quit), key: "q"))
        item.menu = menu
    }

    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.target = self
        return mi
    }

    private func submenu(_ title: String, _ m: NSMenu) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.submenu = m
        return mi
    }

    private func bind(_ mi: NSMenuItem, _ sel: Selector) { mi.target = self; mi.action = sel }

    // MARK: State → UI

    private var currentIcon: IconState?

    func setIcon(_ state: IconState) {
        guard state != currentIcon else { return }   // refreshed every second; only redraw on change
        currentIcon = state
        let symbol: String, tip: String, color: NSColor?
        switch state {
        case .idle: (symbol, color, tip) = ("waveform", nil, "hearsay: not listening")
        case .listening: (symbol, color, tip) = ("waveform.badge.mic", .systemRed, "hearsay: listening")
        case .error: (symbol, color, tip) = ("exclamationmark.triangle", .systemYellow, "hearsay: needs attention")
        }
        var img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: tip)
        img = img?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        if let c = color {
            // Tinted while listening so it is obvious at a glance that the mic is being transcribed.
            img = img?.withSymbolConfiguration(.init(paletteColors: [c, .labelColor]))
            img?.isTemplate = false
        } else {
            img?.isTemplate = true   // follows the menu bar's light/dark appearance
        }
        item.button?.image = img
        item.button?.toolTip = tip
    }

    func update(_ s: State) {
        setIcon(s.icon)
        statusLine.title = s.status
        warningLine.title = s.warning.map { "⚠ \($0)" } ?? ""
        warningLine.isHidden = s.warning == nil
        micPermissionItem.isHidden = !s.permissionDenied.contains(.me)
        tapPermissionItem.isHidden = !s.permissionDenied.contains(.them)
        startStopItem.title = s.listening ? "Stop listening" : "Start listening"
        startStopItem.isEnabled = !s.busy || s.listening
        panelItem.state = s.panelVisible ? .on : .off
        copyItem.isEnabled = s.hasTranscript
        srtItem.isEnabled = s.hasTranscript
        meItem.state = s.sources[.me] == true ? .on : .off
        themItem.state = s.sources[.them] == true ? .on : .off
        loginItem.state = s.launchAtLogin ? .on : .off
        for mi in fontItem.submenu?.items ?? [] { mi.state = Double(mi.tag) == s.fontSize ? .on : .off }
        engineItem.title = "Engine: \(s.engine.isEmpty ? "—" : s.engine)"
    }

    /// Footer: "hearsay 0.1.0 — up to date" or "⬆ Update available: 0.1.1", submenu with actions.
    func updateVersion(current: String, status: UpdateChecker.Status, checksEnabled: Bool, homebrew: Bool) {
        updateChecksItem.state = checksEnabled ? .on : .off
        switch status {
        case .available(let v): versionItem.title = "⬆ Update available: \(v) (you have \(current))"
        case .upToDate: versionItem.title = "hearsay \(current) — up to date"
        case .checking: versionItem.title = "hearsay \(current) — checking…"
        case .failed: versionItem.title = "hearsay \(current) — update check failed"
        case .unknown: versionItem.title = "hearsay \(current)"
        }
        let m = versionItem.submenu!
        m.removeAllItems()
        if case .available = status {
            m.addItem(item(homebrew ? "Update now (runs Homebrew in Terminal)" : "Download update…", #selector(updateNow)))
        }
        if homebrew {
            let copy = item("Copy update command", #selector(copyUpdateCommand))
            copy.toolTip = UpdateChecker.brewCommand
            m.addItem(copy)
        }
        m.addItem(item("Release notes", #selector(openReleasePage)))
        m.addItem(item("Check for updates now", #selector(checkUpdates)))
    }

    // MARK: Actions

    @objc private func toggleListening() { actions.toggleListening() }
    @objc private func togglePanel() { actions.togglePanel() }
    @objc private func openTranscript() { actions.openTranscript() }
    @objc private func openFolder() { actions.openFolder() }
    @objc private func exportSRT() { actions.exportSRT() }
    @objc private func copyAll() { actions.copyAll() }
    @objc private func toggleMe() { actions.toggleSource(.me) }
    @objc private func toggleThem() { actions.toggleSource(.them) }
    @objc private func toggleLoginItem() { actions.toggleLoginItem() }
    @objc private func chooseFont(_ sender: NSMenuItem) { actions.setFontSize(Double(sender.tag)) }
    @objc private func showWelcome() { actions.showWelcome() }
    @objc private func openLogs() { actions.openLogs() }
    @objc private func openMicSettings() { actions.openSettings(.me) }
    @objc private func openTapSettings() { actions.openSettings(.them) }
    @objc private func relaunch() { actions.relaunch() }
    @objc private func checkUpdates() { actions.checkUpdates() }
    @objc private func updateNow() { actions.updateNow() }
    @objc private func copyUpdateCommand() { actions.copyUpdateCommand() }
    @objc private func openReleasePage() { actions.openReleasePage() }
    @objc private func toggleUpdateChecks() { actions.toggleUpdateChecks() }
    @objc private func quit() { actions.quit() }

    func menuWillOpen(_ menu: NSMenu) { onMenuWillOpen?() }
}
