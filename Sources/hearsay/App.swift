import AppKit
import ServiceManagement

@main
enum Main {
    static var signalSources: [DispatchSourceSignal] = []

    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        // CLI diagnostics. These never become a UI app; run them through LaunchServices so TCC
        // attributes the permission request to hearsay, not the terminal:
        //   open -W -n --stdout out.txt build/hearsay.app --args --audio-probe system
        if args.first == "--audio-probe" { exit(AudioProbe.run(arguments: Array(args.dropFirst()))) }
        if args.first == "--transcribe" { exit(EngineProbe.run(arguments: Array(args.dropFirst()))) }
        Log.start(role: DevMode.isDev ? "app (dev)" : "app")

        // SIGTERM/SIGINT (pkill, the Homebrew update script, logout, Ctrl-C) → a normal quit, so the
        // running session is stopped and the transcript's header gets its end time and duration.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                Log.info("signal \(sig): quitting")
                // Not terminate() right here: this handler is a main-QUEUE block, and terminate()'s
                // .terminateLater wait would then starve the main queue (main-actor tasks, asyncAfter)
                // that the session needs to stop. A run-loop perform runs outside any GCD block.
                RunLoop.main.perform { NSApp.terminate(nil) }
            }
            src.resume()
            signalSources.append(src)
        }

        // One hearsay at a time: two would transcribe the same call into two files. Wait briefly
        // for a quitting instance (Relaunch, Homebrew update) before giving up. LaunchServices keeps
        // listing a dead process for a few seconds, so confirm each candidate with kill(pid, 0).
        let me = getpid()
        // Only a copy at the same bundle path blocks us; a dev build runs beside /Applications/hearsay.app.
        func others() -> [NSRunningApplication] {
            let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.hearsay.app")
                .filter { $0.processIdentifier != me && !$0.isTerminated && kill($0.processIdentifier, 0) == 0 }
                // A CLI diagnostic run of the same binary (--audio-probe …) never becomes a UI app.
                .filter { $0.activationPolicy != .prohibited }
            let blocking = Set(InstanceGuard.conflicts(running: candidates.compactMap { $0.bundleURL },
                                                       mine: Bundle.main.bundleURL, dev: DevMode.isDev).map { $0.standardizedFileURL.path })
            return candidates.filter { $0.bundleURL.map { blocking.contains($0.standardizedFileURL.path) } ?? false }
        }
        var waited = 0.0
        while !others().isEmpty && waited < 3 { Thread.sleep(forTimeInterval: 0.1); waited += 0.1 }
        if let other = others().first {
            Log.info("another hearsay (pid \(other.processIdentifier)) is running; exiting")
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private let model = AppModel()
    private lazy var session = SessionController(model: model)
    private let library = TranscriptLibrary()
    /// The running session's file is the sidebar's "Live" entry, not a past transcript; once
    /// stopped it is listed like any other. It stays out of the list through "Saving…" and
    /// until the library has re-read the finalised file, or the row would briefly say
    /// "unfinished" (the sidecar on disk has no end time until `finish` writes it).
    private lazy var mainWindow = MainWindow(model: model, library: library, currentFile: { [weak self] in
        guard let self = self, let store = self.session.store else { return nil }
        if self.model.phase != .idle { return store.jsonURL }
        if let e = self.library.entries.first(where: { $0.jsonURL == store.jsonURL }), e.endedAt == nil { return store.jsonURL }
        return nil
    })
    private lazy var welcome = WelcomeWindow(model: model)
    private let updates = UpdateChecker()
    private let enrolment = EnrolmentRecorder()
    private let hotkey = Hotkey.toggleListening
    private let pauseHotkey = Hotkey.togglePause
    private var bar: RecordingBar!
    private var menuBar: MenuBar!
    private var ticker: Timer?
    private var quitting = false

    override init() { super.init(); AppDelegate.shared = self }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBar(actions: menuActions(), hotkey: hotkey, pauseHotkey: pauseHotkey)
        menuBar.onMenuWillOpen = { [weak self] in
            guard let self = self else { return }
            WelcomeWindow.refreshMic(self.model)
            self.refresh()
        }
        AppMenu.install(AppMenu.Actions(
            about: { About.show() },
            showSettings: { [weak self] in self?.welcome.show() },
            bumpFont: { [weak self] in self?.model.bumpFont($0) }))
        model.actions = AppModel.Actions(
            toggleListening: { [weak self] in self?.session.toggle() },
            togglePause: { [weak self] in self?.session.togglePause() },
            stop: { [weak self] in self?.session.stop() },
            copyAll: { [weak self] hidden in self?.session.store?.copyAll(hiding: hidden) },
            requestMic: { [weak self] in if let m = self?.model { WelcomeWindow.requestMic(m) } },
            openTranscript: { [weak self] in self?.openTranscript() },
            closeWelcome: { [weak self] in self?.welcome.close() },
            exportSRT: { [weak self] hidden in self?.exportSRT(hiding: hidden) },
            revealInFinder: { [weak self] in
                if let store = self?.session.store { store.revealInFinder() } else { TranscriptStore.openFolder() }
            },
            pauseDownload: { [weak self] in self?.session.pauseDownload() },
            resumeDownload: { [weak self] in self?.session.resumeDownload() },
            cancelDownload: { [weak self] in self?.session.cancelDownload() },
            setLiveMeta: { [weak self] meta in
                guard let self = self else { return }
                self.session.store?.meta = meta     // written with the next save (or at once, once a file exists)
                if self.model.liveMeta != meta { self.model.liveMeta = meta }
            },
            liveStore: { [weak self] in self?.session.store })
        // The bar's transcript button toggles the main window on its Live view.
        bar = RecordingBar(model: model, actions: RecordingBar.Actions(
            togglePause: { [weak self] in self?.session.togglePause() },
            stop: { [weak self] in self?.session.stop() },
            togglePanel: { [weak self] in self?.mainWindow.toggleLive() }))

        session.onChange = { [weak self] in self?.refresh() }
        mainWindow.onVisibilityChange = { [weak self] in self?.refresh() }
        hotkey.register { [weak self] in
            Log.info(.ui, "hotkey \(Hotkey.toggleListening.display)")
            self?.session.toggle()
        }
        pauseHotkey.register { [weak self] in
            Log.info(.ui, "hotkey \(Hotkey.togglePause.display)")
            self?.session.togglePause()
        }
        updates.onChange = { [weak self] in self?.refreshVersion() }
        updates.start()
        refreshVersion()

        // Model download/load starts now, in the background, so it's usually done by the time
        // the user first presses Start.
        session.prepareEngines()
        // Dev aid / automation: HEARSAY_AUTOSTART=1 starts listening as soon as the models are ready
        // (`open --env HEARSAY_AUTOSTART=1 build/hearsay.app`). Lets an end-to-end test run without
        // anyone pressing the hotkey.
        if ProcessInfo.processInfo.environment["HEARSAY_AUTOSTART"] == "1" { session.start() }

        // The status line shows elapsed minutes; .common so it also ticks while the menu is open.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        ticker = t

        refresh()
        if WelcomeWindow.shouldShowAutomatically { welcome.show() }
        DebugSnapshot.installIfRequested { [weak self] in self?.menuBar.menuDescription ?? "" }
        DebugSnapshot.runScriptIfRequested(mainWindow.scriptActions().merging([
            "panel": { [weak self] in self?.mainWindow.toggleLive() },
            "pause": { [weak self] in self?.session.togglePause() },
            "captions": { [weak self] in self?.bar.toggleCaptions() },
            "pauseDownload": { [weak self] in self?.session.pauseDownload() },
            // HEARSAY_DIAGNOSTICS_OUT=/path.zip: Export diagnostics without the save panel.
            "diagnostics": {
                let out = ProcessInfo.processInfo.environment["HEARSAY_DIAGNOSTICS_OUT"] ?? NSTemporaryDirectory() + "hearsay-diagnostics.zip"
                do { try Diagnostics.export(to: URL(fileURLWithPath: out)) } catch { Log.error(.app, "diagnostics export failed: \(error)") }
            },
            "verbose": { Log.verboseText.toggle() },
            "resumeDownload": { [weak self] in self?.session.resumeDownload() },
            "cancelDownload": { [weak self] in self?.session.cancelDownload() },
            "welcome": { [weak self] in self?.welcome.show() },
            "learnvoice": { [weak self] in self?.learnVoice() },
            "enrolstart": { [weak self] in self?.enrolment.pressStart() },
            "about": { About.show() },
            "warn": { [weak self] in self?.session.showWarning("Microphone stopped.") },
            "pill": { [weak self] in self?.model.barMode = .pill },
            "full": { [weak self] in self?.model.barMode = .full },
            // `diarize=off|microphone|all`: Settings ▸ Tell speakers apart.
            "diarize": { [weak self] in
                if let m = DiarizationMode(rawValue: DebugSnapshot.scriptArgument) { self?.session.setDiarization(m) }
            },
            // `diarizer=sortformer|lseend`: Settings ▸ Tell speakers apart ▸ Model.
            "diarizer": { [weak self] in
                if let k = DiarizerKind(rawValue: DebugSnapshot.scriptArgument) { self?.session.setDiarizer(k) }
            },
        ]) { _, b in b })
        Log.info("launched (engine \(model.engineID))")
    }

    /// Accessory app: there's no Dock icon to click, but `open -a hearsay` while running lands here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return true
    }

    /// Quit (menu, SIGTERM, logout): stop listening and finalise the transcript first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        guard model.phase != .idle else { return .terminateNow }
        quitting = true
        Log.info(.session, "quit: stopping session first")
        session.stopForQuit(timeout: 4) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.unregister()
        pauseHotkey.unregister()
        Log.info(.session, "quit")
    }

    // MARK: Menu

    private func menuActions() -> MenuBar.Actions {
        MenuBar.Actions(
            toggleListening: { [weak self] in self?.session.toggle() },
            togglePause: { [weak self] in self?.session.togglePause() },
            togglePanel: { [weak self] in self?.mainWindow.show() },
            openTranscript: { [weak self] in self?.openTranscript() },
            openFolder: { TranscriptStore.openFolder() },
            exportSRT: { [weak self] in self?.exportSRT(hiding: []) },
            copyAll: { [weak self] in self?.session.store?.copyAll() },
            toggleSource: { [weak self] s in self?.session.setEnabled(s, !SessionController.isEnabled(s)) },
            toggleLoginItem: { [weak self] in self?.toggleLoginItem() },
            toggleRecordingBar: { [weak self] in self?.model.showRecordingBar.toggle(); self?.refresh() },
            setRecordingBarMode: { [weak self] raw in self?.model.barMode = AppModel.BarMode(rawValue: raw) ?? .full; self?.refresh() },
            setFontSize: { [weak self] size in self?.model.fontSize = size; self?.refresh() },
            setEchoCancellation: { [weak self] raw in
                guard let self, let choice = EchoCancellation(rawValue: raw), choice != EchoCancellation.current else { return }
                EchoCancellation.current = choice
                Log.info("echo cancellation set to \(raw)")
                // The decision is baked into the mic engine: bounce the me lane if it's live.
                if self.model.phase == .listening, SessionController.isEnabled(.me) {
                    self.session.setEnabled(.me, false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.session.setEnabled(.me, true) }
                }
                self.refresh()
            },
            setYourName: { [weak self] in self?.askYourName() },
            setDiarization: { [weak self] raw in
                if let mode = DiarizationMode(rawValue: raw) { self?.session.setDiarization(mode) }
            },
            setDiarizer: { [weak self] raw in
                if let kind = DiarizerKind(rawValue: raw) { self?.session.setDiarizer(kind) }
            },
            learnVoice: { [weak self] in self?.learnVoice() },
            forgetVoice: { [weak self] in Enrolment.forget(); self?.refresh() },
            showWelcome: { [weak self] in self?.welcome.show() },
            openLogs: { NSWorkspace.shared.open(Log.fileURL) },
            openSettings: { SettingsLinks.open(for: $0) },
            relaunch: { [weak self] in self?.relaunch() },
            checkUpdates: { [weak self] in self?.updates.check(manual: true) },
            updateNow: { [weak self] in self?.updates.updateNow() },
            copyUpdateCommand: { [weak self] in self?.updates.copyCommand() },
            openReleasePage: { [weak self] in self?.updates.openReleasePage() },
            toggleUpdateChecks: { [weak self] in
                guard let self = self else { return }
                self.updates.enabled.toggle()
                self.refreshVersion()
            },
            about: { About.show() },
            quit: { NSApp.terminate(nil) })
    }

    /// `SMAppService.status` is an XPC round trip (~100 ms blocked on the main thread); refresh()
    /// runs every second, so cache it briefly and drop the cache when the user toggles it.
    private var loginStatusCache: (at: Date, enabled: Bool)?
    private func launchAtLoginEnabled() -> Bool {
        if let c = loginStatusCache, Date().timeIntervalSince(c.at) < 5 { return c.enabled }
        let enabled = SMAppService.mainApp.status == .enabled
        loginStatusCache = (Date(), enabled)
        return enabled
    }

    private func refresh() {
        guard let menuBar = menuBar else { return }
        let failed: Bool
        if case .failed = model.modelState { failed = true } else { failed = false }
        var s = MenuBar.State()
        s.icon = model.phase == .paused ? .paused
            : model.isListening ? .listening : (failed || !model.permissionDenied.isEmpty ? .error : .idle)
        s.status = model.statusLine()
        s.warning = model.warning
        s.permissionDenied = model.permissionDenied
        s.listening = model.isActive
        s.paused = model.phase == .paused
        s.canPause = model.phase == .listening
        s.showBar = model.showRecordingBar
        s.barMode = model.barMode.rawValue
        s.busy = model.phase == .starting || model.phase == .stopping
        // The bar's transcript button is "on" while the main window shows the live transcript.
        if model.panelVisible != mainWindow.showingLive { model.panelVisible = mainWindow.showingLive }
        // The bar follows the session: up while listening/paused (and while the model loads for
        // a requested start), down as soon as Stop is pressed.
        bar?.setVisible(model.isActive && model.showRecordingBar)
        s.hasTranscript = !(session.store?.lines.isEmpty ?? true)
        s.sources = Dictionary(uniqueKeysWithValues: Speaker.allCases.map { ($0, SessionController.isEnabled($0)) })
        s.launchAtLogin = launchAtLoginEnabled()
        s.fontSize = model.fontSize
        s.echoCancellation = EchoCancellation.current.rawValue
        s.diarization = model.diarization.rawValue
        s.diarizer = DiarizerKind.current.rawValue
        s.voiceEnrolled = Enrolment.exists
        s.engine = model.engineID
        s.yourName = model.yourName
        menuBar.update(s)
    }

    /// Settings ▸ Your name…: the default label for "me" in chips, captions, Markdown and SRT
    /// (a transcript's own rename still wins). An alert with a field: it is set once, so a
    /// settings window for one line would be more than it deserves. Blank clears it.
    private func askYourName() {
        let a = NSAlert()
        a.messageText = "Your name"
        a.informativeText = "Used instead of \"me\" in transcripts, captions and exports. Leave empty to keep \"me\"."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "me"
        field.stringValue = model.yourName ?? ""
        a.accessoryView = field
        a.window.initialFirstResponder = field
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        model.yourName = TranscriptMeta.cleanTitle(field.stringValue)
        Log.info("your name \(model.yourName == nil ? "cleared" : "set")")
        refresh()
    }

    private func refreshVersion() {
        menuBar?.updateVersion(current: UpdateChecker.currentVersion, status: updates.status,
                               checksEnabled: updates.enabled, homebrew: UpdateChecker.installedWithHomebrew)
    }

    /// Settings ▸ Tell speakers apart ▸ Learn my voice…: a passage read aloud for 15 s, saved for
    /// the diarizer to label the user "me" (see Enrolment). The panel reports the outcome itself.
    private func learnVoice() {
        enrolment.start(canStart: model.phase == .idle) { [weak self] result in
            switch result {
            case .success(let speech):
                Log.info(.diarize, String(format: "enrolment: voice learned, %.0f s of speech", speech))
            case .failure(let error):
                if case EnrolmentRecorder.Failure.busy = error { self?.session.showWarning(error.localizedDescription) }
            }
            self?.refresh()
        }
    }

    /// `hiding`: the voices the main window has turned off (the menu passes none).
    private func exportSRT(hiding hidden: Set<Voice>) {
        if let url = session.store?.exportSRT(hiding: hidden) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private func openTranscript() {
        if let store = session.store, store.hasFile { store.open() } else { TranscriptStore.openLast() }
    }

    /// Login item via SMAppService. Registers THIS bundle's path, so do it from the installed copy
    /// (/Applications), not from build/.
    private func toggleLoginItem() {
        loginStatusCache = nil
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            Log.info("launch at login \(SMAppService.mainApp.status == .enabled ? "enabled" : "disabled") for \(Bundle.main.bundlePath)")
        } catch {
            Log.error("login item: \(error)")
            let a = NSAlert()
            a.messageText = "Could not change login item"
            a.informativeText = "\(error.localizedDescription)\n\nmacOS may require approval under System Settings → General → Login Items."
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
        refresh()
    }

    /// Quit (finalising any session) and start a fresh instance, e.g. after granting a permission
    /// that macOS only applies to newly launched processes. The new instance waits for us to exit.
    private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open -n \(DevMode.isDev ? "--env HEARSAY_DEV=1 " : "")\"\(Bundle.main.bundleURL.path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
