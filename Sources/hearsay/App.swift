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
        Log.start(role: "app")

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
        func others() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: "dev.hearsay.app")
                .filter { $0.processIdentifier != me && !$0.isTerminated && kill($0.processIdentifier, 0) == 0 }
                // A CLI diagnostic run of the same binary (--audio-probe …) never becomes a UI app.
                .filter { $0.activationPolicy != .prohibited }
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
    private lazy var panel = LivePanel(model: model)
    private lazy var welcome = WelcomeWindow(model: model)
    private let updates = UpdateChecker()
    private let hotkey = Hotkey.toggleListening
    private var menuBar: MenuBar!
    private var ticker: Timer?
    private var quitting = false

    override init() { super.init(); AppDelegate.shared = self }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBar(actions: menuActions(), hotkey: hotkey)
        menuBar.onMenuWillOpen = { [weak self] in
            guard let self = self else { return }
            WelcomeWindow.refreshMic(self.model)
            self.refresh()
        }
        model.actions = AppModel.Actions(
            toggleListening: { [weak self] in self?.session.toggle() },
            copyAll: { [weak self] in self?.session.store?.copyAll() },
            requestMic: { [weak self] in if let m = self?.model { WelcomeWindow.requestMic(m) } },
            openTranscript: { [weak self] in self?.openTranscript() },
            closeWelcome: { [weak self] in self?.welcome.close() })

        session.onChange = { [weak self] in self?.refresh() }
        panel.onVisibilityChange = { [weak self] in self?.refresh() }
        hotkey.register { [weak self] in
            Log.info("hotkey \(Hotkey.toggleListening.display)")
            self?.session.toggle()
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
        Log.info("launched (engine \(model.engineID))")
    }

    /// Accessory app: there's no Dock icon to click, but `open -a hearsay` while running lands here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return true
    }

    /// Quit (menu, SIGTERM, logout): stop listening and finalise the transcript first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        guard model.phase != .idle else { return .terminateNow }
        quitting = true
        Log.info("quit: stopping session first")
        session.stopForQuit(timeout: 4) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.unregister()
        Log.info("quit")
    }

    // MARK: Menu

    private func menuActions() -> MenuBar.Actions {
        MenuBar.Actions(
            toggleListening: { [weak self] in self?.session.toggle() },
            togglePanel: { [weak self] in self?.panel.toggle() },
            openTranscript: { [weak self] in self?.openTranscript() },
            openFolder: { TranscriptStore.openFolder() },
            exportSRT: { [weak self] in
                if let url = self?.session.store?.exportSRT() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            },
            copyAll: { [weak self] in self?.session.store?.copyAll() },
            toggleSource: { [weak self] s in self?.session.setEnabled(s, !SessionController.isEnabled(s)) },
            toggleLoginItem: { [weak self] in self?.toggleLoginItem() },
            setFontSize: { [weak self] size in self?.model.fontSize = size; self?.refresh() },
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
            quit: { NSApp.terminate(nil) })
    }

    private func refresh() {
        guard let menuBar = menuBar else { return }
        let failed: Bool
        if case .failed = model.modelState { failed = true } else { failed = false }
        var s = MenuBar.State()
        s.icon = model.isListening ? .listening : (failed || !model.permissionDenied.isEmpty ? .error : .idle)
        s.status = model.statusLine()
        s.warning = model.warning
        s.permissionDenied = model.permissionDenied
        s.listening = model.isListening
        s.busy = model.phase == .starting || model.phase == .stopping
        s.panelVisible = panel.isVisible
        s.hasTranscript = !(session.store?.lines.isEmpty ?? true)
        s.sources = Dictionary(uniqueKeysWithValues: Speaker.allCases.map { ($0, SessionController.isEnabled($0)) })
        s.launchAtLogin = SMAppService.mainApp.status == .enabled
        s.fontSize = model.fontSize
        s.engine = model.engineID
        menuBar.update(s)
        panel.setTitle("hearsay — \(s.status)")
    }

    private func refreshVersion() {
        menuBar?.updateVersion(current: UpdateChecker.currentVersion, status: updates.status,
                               checksEnabled: updates.enabled, homebrew: UpdateChecker.installedWithHomebrew)
    }

    private func openTranscript() {
        if let store = session.store, store.hasFile { store.open() } else { TranscriptStore.openLast() }
    }

    /// Login item via SMAppService. Registers THIS bundle's path, so do it from the installed copy
    /// (/Applications), not from build/.
    private func toggleLoginItem() {
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
        task.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(Bundle.main.bundleURL.path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
