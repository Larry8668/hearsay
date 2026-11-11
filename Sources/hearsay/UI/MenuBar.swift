import AppKit

/// NSStatusItem + menu. Pure view: everything it does goes through `actions`, everything it shows
/// comes in through `update(_:)`.
final class MenuBar: NSObject, NSMenuDelegate {
    enum IconState { case idle, listening, paused, error }

    struct Actions {
        var toggleListening: () -> Void
        var togglePause: () -> Void
        var togglePanel: () -> Void
        var openTranscript: () -> Void
        var openFolder: () -> Void
        var exportSRT: () -> Void
        /// Export the current or last session as `ExportFormat` raw value ("markdown", "json", …).
        var exportAs: (String) -> Void = { _ in }
        var copyAs: (String) -> Void = { _ in }
        var copyAll: () -> Void
        var toggleSource: (Speaker) -> Void
        var toggleLoginItem: () -> Void
        var toggleRecordingBar: () -> Void
        /// AppModel.BarMode raw value. Defaulted so the delegate wires it up when it can.
        var setRecordingBarMode: (String) -> Void = { _ in }
        var setFontSize: (Double) -> Void
        var setEchoCancellation: (String) -> Void   // EchoCancellation raw value
        /// Settings ▸ Your name…: asks for the name used for "me". Defaulted so the delegate wires it up when it can.
        var setYourName: () -> Void = {}
        var setDiarization: (String) -> Void       // DiarizationMode raw value
        var learnVoice: () -> Void
        var forgetVoice: () -> Void
        var showWelcome: () -> Void
        var showModels: () -> Void = {}
        var openLogs: () -> Void
        var openSettings: (Speaker) -> Void
        var relaunch: () -> Void
        var checkUpdates: () -> Void
        var updateNow: () -> Void
        var copyUpdateCommand: () -> Void
        var openReleasePage: () -> Void
        var toggleUpdateChecks: () -> Void
        var about: () -> Void = {}
        var quit: () -> Void
    }

    /// Everything the menu displays, computed by AppDelegate.
    struct State {
        var icon: IconState = .idle
        var status = "Not listening"
        var warning: String?
        var permissionDenied: Set<Speaker> = []
        var listening = false         // a session exists (listening, starting or paused)
        var paused = false
        var canPause = false
        var showBar = true
        var barMode = AppModel.BarMode.full.rawValue
        var busy = false              // starting / stopping
        var hasTranscript = false
        var sources: [Speaker: Bool] = [:]
        var launchAtLogin = false
        var fontSize: Double = 13
        var echoCancellation = "auto"
        var diarization = "microphone"
        var voiceEnrolled = false
        var engine = ""
        /// Settings ▸ Your name, shown in the item's title.
        var yourName: String?
    }

    private let item: NSStatusItem
    private let menu = NSMenu()
    private let actions: Actions
    private let hotkey: Hotkey
    private let pauseHotkey: Hotkey

    private let statusLine = NSMenuItem()
    private let warningLine = NSMenuItem()
    private let micPermissionItem = NSMenuItem()
    private let tapPermissionItem = NSMenuItem()
    private let startStopItem = NSMenuItem()
    private let pauseItem = NSMenuItem()
    private let barItem = NSMenuItem()
    private let barModeItem = NSMenuItem()
    private let panelItem = NSMenuItem()
    private let openItem = NSMenuItem()
    private let srtItem = NSMenuItem()
    private let copyItem = NSMenuItem()
    private let meItem = NSMenuItem()
    private let themItem = NSMenuItem()
    private let loginItem = NSMenuItem()
    private let updateChecksItem = NSMenuItem()
    private let fontItem = NSMenuItem()
    private let echoItem = NSMenuItem()
    private let yourNameItem = NSMenuItem()
    private let diarizationItem = NSMenuItem()
    private let learnVoiceItem = NSMenuItem()
    private let forgetVoiceItem = NSMenuItem()
    private let engineItem = NSMenuItem()
    private let versionItem = NSMenuItem()
    private let verboseItem = NSMenuItem()
    var onMenuWillOpen: (() -> Void)?
    var menuDescription: String { DebugSnapshot.describe(menu) }

    init(actions: Actions, hotkey: Hotkey, pauseHotkey: Hotkey) {
        self.actions = actions
        self.hotkey = hotkey
        self.pauseHotkey = pauseHotkey
        item = NSStatusBar.system.statusItem(withLength: DevMode.isDev ? NSStatusItem.variableLength : NSStatusItem.squareLength)
        super.init()
        build()
        setIcon(.idle)
    }

    /// Top level = essentials only:
    ///   status · warning · permission fixes
    ///   Start/Stop listening · Pause/Resume · Open hearsay…
    ///   Open transcript · Open transcripts folder · More ▸ (SRT, copy)
    ///   Sources ▸  Settings ▸  Troubleshooting ▸
    ///   version/update ▸ · Quit
    private func build() {
        menu.delegate = self
        menu.autoenablesItems = false

        if DevMode.isDev {
            let dev = NSMenuItem(title: "hearsay dev build · \(DevMode.versionString)", action: nil, keyEquivalent: "")
            dev.isEnabled = false
            menu.addItem(dev)
        }
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
        pauseItem.title = "Pause"
        bind(pauseItem, #selector(togglePause))
        pauseItem.keyEquivalent = pauseHotkey.display.last.map { String($0).lowercased() } ?? ""
        pauseItem.keyEquivalentModifierMask = pauseHotkey.menuModifiers
        menu.addItem(pauseItem)
        panelItem.title = "Open hearsay…"
        bind(panelItem, #selector(togglePanel))
        menu.addItem(panelItem)
        menu.addItem(.separator())

        openItem.title = "Open transcript"
        bind(openItem, #selector(openTranscript))
        menu.addItem(openItem)
        menu.addItem(item("Open transcripts folder", #selector(openFolder)))
        copyItem.title = "Copy transcript"
        bind(copyItem, #selector(copyAll))
        srtItem.title = "Export transcript"
        let exportMenu = NSMenu()
        for f in ExportFormat.allCases {
            let mi = NSMenuItem(title: "\(f.title)…", action: #selector(exportAs(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = f.rawValue
            exportMenu.addItem(mi)
        }
        exportMenu.addItem(.separator())
        for (title, f) in [("Copy as Markdown (for an AI chat)", ExportFormat.markdown), ("Copy as JSON", .json)] {
            let mi = NSMenuItem(title: title, action: #selector(copyAs(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = f.rawValue
            exportMenu.addItem(mi)
        }
        srtItem.submenu = exportMenu
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
        settings.addItem(item("Models…", #selector(showModels)))
        settings.addItem(.separator())
        loginItem.title = "Launch at login"
        bind(loginItem, #selector(toggleLoginItem))
        settings.addItem(loginItem)
        updateChecksItem.title = "Check for updates daily"
        bind(updateChecksItem, #selector(toggleUpdateChecks))
        settings.addItem(updateChecksItem)
        // Recording bar ▸: the on/off toggle and the two shapes.
        barModeItem.title = "Recording bar"
        let barMenu = NSMenu()
        barItem.title = "Show recording bar"
        bind(barItem, #selector(toggleRecordingBar))
        barMenu.addItem(barItem)
        barMenu.addItem(.separator())
        for mode in AppModel.BarMode.allCases {
            let mi = item(mode.title, #selector(chooseBarMode(_:)))
            mi.representedObject = mode.rawValue
            barMenu.addItem(mi)
        }
        barModeItem.submenu = barMenu
        settings.addItem(barModeItem)
        echoItem.title = "Echo cancellation"
        let echo = NSMenu()
        for choice in EchoCancellation.allCases {
            let mi = item(choice.title, #selector(chooseEcho(_:)))
            mi.representedObject = choice.rawValue
            echo.addItem(mi)
        }
        echo.addItem(.separator())
        let note = NSMenuItem(title: "Stops the speakers leaking into \"me\"; costs ~25% CPU", action: nil, keyEquivalent: "")
        note.isEnabled = false
        echo.addItem(note)
        echoItem.submenu = echo
        settings.addItem(echoItem)
        diarizationItem.title = "Tell speakers apart"
        let diarization = NSMenu()
        for choice in DiarizationMode.allCases {
            let mi = item(choice.title, #selector(chooseDiarization(_:)))
            mi.representedObject = choice.rawValue
            diarization.addItem(mi)
        }
        diarization.addItem(.separator())
        let dnote = NSMenuItem(title: "Labels Speaker 1, 2… when several people share one source", action: nil, keyEquivalent: "")
        dnote.isEnabled = false
        diarization.addItem(dnote)
        diarization.addItem(.separator())
        learnVoiceItem.title = "Learn my voice…"
        bind(learnVoiceItem, #selector(learnVoice))
        diarization.addItem(learnVoiceItem)
        forgetVoiceItem.title = "Forget my voice"
        bind(forgetVoiceItem, #selector(forgetVoice))
        diarization.addItem(forgetVoiceItem)
        diarizationItem.submenu = diarization
        settings.addItem(diarizationItem)
        fontItem.title = "Transcript text size"
        let fonts = NSMenu()
        for (size, name) in AppModel.fontChoices {
            let mi = item(name, #selector(chooseFont(_:)))
            mi.tag = Int(size * 10)   // tags are Int; sizes like 14.5 need the extra digit
            fonts.addItem(mi)
        }
        fontItem.submenu = fonts
        settings.addItem(fontItem)
        yourNameItem.title = "Your name…"
        yourNameItem.toolTip = "What \"me\" is called in transcripts, captions and exports"
        bind(yourNameItem, #selector(setYourName))
        settings.addItem(yourNameItem)
        engineItem.isEnabled = false
        settings.addItem(engineItem)
        menu.addItem(submenu("Settings", settings))

        // Troubleshooting ▸
        let trouble = NSMenu()
        trouble.addItem(item("Open logs", #selector(openLogs)))
        trouble.addItem(item("Export diagnostics…", #selector(exportDiagnostics)))
        verboseItem.title = "Verbose logging (includes transcript text)"
        verboseItem.target = self
        verboseItem.action = #selector(toggleVerbose)
        trouble.addItem(verboseItem)
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

    /// Reads like a switch: dimmed and monochrome when off, green when listening, orange when
    /// paused, yellow when something needs attention (the same code as sharemask's icon).
    func setIcon(_ state: IconState) {
        guard state != currentIcon else { return }   // refreshed every second; only redraw on change
        currentIcon = state
        let symbol: String, tip: String, color: NSColor?
        switch state {
        case .idle: (symbol, color, tip) = ("waveform", nil, "hearsay: not listening")
        case .listening: (symbol, color, tip) = ("waveform", .systemGreen, "hearsay: listening")
        case .paused: (symbol, color, tip) = ("pause.circle", .systemOrange, "hearsay: paused")
        case .error: (symbol, color, tip) = ("exclamationmark.triangle", .systemYellow, "hearsay: needs attention")
        }
        var img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: tip)
        img = img?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        if let c = color {
            // One flat colour (no label-colour secondary layer): the state is the colour.
            img = img?.withSymbolConfiguration(.init(paletteColors: [c]))
            img?.isTemplate = false
        } else {
            img?.isTemplate = true   // follows the menu bar's light/dark appearance
        }
        item.button?.image = img
        item.button?.toolTip = tip
        if DevMode.isDev {
            item.button?.imagePosition = .imageLeft
            item.button?.attributedTitle = NSAttributedString(string: "dev", attributes: [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold), .baselineOffset: 5])
        }
        // Off: the template symbol at reduced alpha, so it reads as greyed out next to the
        // other menu bar icons. The button's contentTintColor does nothing for a template image.
        item.button?.alphaValue = state == .idle ? 0.45 : 1
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
        pauseItem.title = s.paused ? "Resume" : "Pause"
        pauseItem.isHidden = !s.listening
        pauseItem.isEnabled = s.canPause || s.paused
        barItem.state = s.showBar ? .on : .off
        for mi in barModeItem.submenu?.items ?? [] where mi.representedObject != nil {
            mi.state = (mi.representedObject as? String) == s.barMode ? .on : .off
        }
        copyItem.isEnabled = s.hasTranscript
        srtItem.isEnabled = s.hasTranscript
        meItem.state = s.sources[.me] == true ? .on : .off
        themItem.state = s.sources[.them] == true ? .on : .off
        loginItem.state = s.launchAtLogin ? .on : .off
        for mi in fontItem.submenu?.items ?? [] { mi.state = Double(mi.tag) / 10 == s.fontSize ? .on : .off }
        for mi in echoItem.submenu?.items ?? [] { mi.state = (mi.representedObject as? String) == s.echoCancellation ? .on : .off }
        for mi in diarizationItem.submenu?.items ?? [] where mi.representedObject != nil {
            mi.state = (mi.representedObject as? String) == s.diarization ? .on : .off
        }
        learnVoiceItem.title = s.voiceEnrolled ? "Learn my voice again…" : "Learn my voice…"
        learnVoiceItem.isEnabled = !s.listening
        forgetVoiceItem.isHidden = !s.voiceEnrolled
        engineItem.title = "Engine: \(s.engine.isEmpty ? "—" : s.engine)"
        yourNameItem.title = s.yourName.map { "Your name: \($0)…" } ?? "Your name…"
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
        m.addItem(.separator())
        m.addItem(item("About hearsay", #selector(about)))
    }

    // MARK: Actions

    @objc private func toggleListening() { actions.toggleListening() }
    @objc private func togglePause() { actions.togglePause() }
    @objc private func togglePanel() { actions.togglePanel() }
    @objc private func toggleRecordingBar() { actions.toggleRecordingBar() }
    @objc private func chooseBarMode(_ sender: NSMenuItem) { actions.setRecordingBarMode(sender.representedObject as? String ?? "full") }
    @objc private func openTranscript() { actions.openTranscript() }
    @objc private func openFolder() { actions.openFolder() }
    @objc private func exportSRT() { actions.exportSRT() }
    @objc private func exportAs(_ sender: NSMenuItem) { if let raw = sender.representedObject as? String { actions.exportAs(raw) } }
    @objc private func copyAs(_ sender: NSMenuItem) { if let raw = sender.representedObject as? String { actions.copyAs(raw) } }
    @objc private func copyAll() { actions.copyAll() }
    @objc private func toggleMe() { actions.toggleSource(.me) }
    @objc private func toggleThem() { actions.toggleSource(.them) }
    @objc private func toggleLoginItem() { actions.toggleLoginItem() }
    @objc private func chooseFont(_ sender: NSMenuItem) { actions.setFontSize(Double(sender.tag) / 10) }
    @objc private func showWelcome() { actions.showWelcome() }
    @objc private func showModels() { actions.showModels() }
    @objc private func openLogs() { actions.openLogs() }
    @objc private func exportDiagnostics() { MainActor.assumeIsolated { Diagnostics.exportInteractively() } }
    @objc private func toggleVerbose() { Log.verboseText.toggle(); verboseItem.state = Log.verboseText ? .on : .off }
    @objc private func chooseEcho(_ sender: NSMenuItem) { actions.setEchoCancellation(sender.representedObject as? String ?? "auto") }
    @objc private func setYourName() { actions.setYourName() }
    @objc private func chooseDiarization(_ sender: NSMenuItem) { actions.setDiarization(sender.representedObject as? String ?? "microphone") }
    @objc private func learnVoice() { actions.learnVoice() }
    @objc private func forgetVoice() { actions.forgetVoice() }
    @objc private func openMicSettings() { actions.openSettings(.me) }
    @objc private func openTapSettings() { actions.openSettings(.them) }
    @objc private func relaunch() { actions.relaunch() }
    @objc private func checkUpdates() { actions.checkUpdates() }
    @objc private func updateNow() { actions.updateNow() }
    @objc private func copyUpdateCommand() { actions.copyUpdateCommand() }
    @objc private func openReleasePage() { actions.openReleasePage() }
    @objc private func toggleUpdateChecks() { actions.toggleUpdateChecks() }
    @objc private func about() { actions.about() }
    @objc private func quit() { actions.quit() }

    func menuWillOpen(_ menu: NSMenu) {
        verboseItem.state = Log.verboseText ? .on : .off
        onMenuWillOpen?()
    }
}
