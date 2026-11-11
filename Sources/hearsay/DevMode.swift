import Foundation

/// Dev mode: a build that is not the installed `/Applications/hearsay.app` (or any launch with
/// `HEARSAY_DEV=1`) runs side by side with the installed app. It gets its own preferences suite,
/// transcripts folder, log file, hotkeys and automation channel; see docs/BUILDING.md.
enum DevMode {
    static let installedDirectory = "/Applications"

    static let isDev: Bool = isDev(bundleURL: Bundle.main.bundleURL, environment: ProcessInfo.processInfo.environment)

    static func isDev(bundleURL: URL, environment: [String: String]) -> Bool {
        environment["HEARSAY_DEV"] == "1" || !isInstalled(bundleURL)
    }

    static func isInstalled(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(installedDirectory + "/")
    }

    static var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// `~/Documents/hearsay`, or `~/Documents/hearsay-dev` in dev mode; `HEARSAY_TRANSCRIPTS_DIR` wins.
    static func transcriptsDirectory(dev: Bool, environment: [String: String], documents: URL) -> URL {
        if let dir = environment["HEARSAY_TRANSCRIPTS_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        return documents.appendingPathComponent(dev ? "hearsay-dev" : "hearsay", isDirectory: true)
    }

    /// Distributed-notification name for `HEARSAY_AUTOMATION=1` control; the dev instance listens on `.dev`.
    static func controlNotificationName(dev: Bool) -> String { dev ? "dev.hearsay.control.dev" : "dev.hearsay.control" }

    static var logFileName: String { isDev ? "hearsay-dev.log" : "hearsay.log" }
}

/// Every preference goes through `Prefs.store`, so dev mode never touches the installed app's settings.
enum Prefs {
    static let devSuite = "dev.hearsay.app.dev"

    /// nil means `UserDefaults.standard` (the installed app's domain).
    static func suiteName(dev: Bool) -> String? { dev ? devSuite : nil }

    static let store: UserDefaults = {
        suiteName(dev: DevMode.isDev).flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }()
}

/// The single-instance policy: which already-running copies block this launch.
enum InstanceGuard {
    /// Only a copy running from the same bundle path blocks (two of one path would transcribe the
    /// same call twice). A dev launch ignores copies under /Applications: that is the installed app.
    static func conflicts(running: [URL], mine: URL, dev: Bool) -> [URL] {
        let me = mine.standardizedFileURL.path
        return running.filter { url in
            url.standardizedFileURL.path == me && !(dev && DevMode.isInstalled(url))
        }
    }
}
