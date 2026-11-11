import Foundation
import os

/// Logging façade. Every line goes to three places so problems can be reconstructed after the fact:
///
/// 1. **File**: `~/Library/Logs/hearsay/hearsay.log` (`hearsay-dev.log` in dev mode), append; rolled
///    at 5 MB to `.1` (newest) … `.3` (oldest), so disk use is capped at ~20 MB per flavour and
///    rolled files older than 30 days are deleted. Survives relaunches and crashes; readable
///    with `tail -f` or Console.app. Lines read `time [LEVEL] [category] message`.
/// 2. **Unified log**: subsystem `dev.hearsay.app` at notice/error level (info-level entries are
///    NOT persisted by macOS, so we never log below notice).
///    `/usr/bin/log show --last 1h --info --predicate 'subsystem == "dev.hearsay.app"'`
/// 3. **stderr** when attached to a terminal or `HEARSAY_VERBOSE` is set.
///
/// Uncaught exceptions and fatal signals write a final line before the process dies.
enum Log {
    enum Category: String, CaseIterable { case mic, tap, engine, session, ui, update, model, diarize, app }

    private static let loggers: [Category: Logger] = Dictionary(uniqueKeysWithValues:
        Category.allCases.map { ($0, Logger(subsystem: "dev.hearsay.app", category: $0.rawValue)) })
    private static let stderrIsTTY = isatty(STDERR_FILENO) != 0
    private static let verbose = ProcessInfo.processInfo.environment["HEARSAY_VERBOSE"] != nil
    private static let queue = DispatchQueue(label: "hearsay.log", qos: .utility)
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/hearsay", isDirectory: true)
    static let fileURL = directory.appendingPathComponent(DevMode.logFileName)
    private static let maxBytes = 5 * 1024 * 1024
    /// Rolled copies kept next to the live file (`.1` newest … `.3` oldest).
    static let rolledCount = 3
    static let maxRolledAge: TimeInterval = 30 * 24 * 3600
    private static var handle: FileHandle?

    static func info(_ message: String) { info(.app, message) }
    static func warn(_ message: String) { warn(.app, message) }
    static func error(_ message: String) { error(.app, message) }
    static func info(_ c: Category, _ message: String) { emit("INFO", c, message); loggers[c]?.notice("\(message, privacy: .public)") }
    static func warn(_ c: Category, _ message: String) { emit("WARN", c, message); loggers[c]?.warning("\(message, privacy: .public)") }
    static func error(_ c: Category, _ message: String) { emit("ERROR", c, message); loggers[c]?.error("\(message, privacy: .public)") }

    /// Settings: Troubleshooting ▸ "Verbose logging (includes transcript text)". Off by default; while
    /// off, nothing that was spoken reaches the log (only lengths and word counts).
    static let verboseKey = "verboseLogging"
    static var verboseText: Bool {
        get { Prefs.store.bool(forKey: verboseKey) }
        set { Prefs.store.set(newValue, forKey: verboseKey); info(.app, "verbose logging \(newValue ? "on (transcript text is logged)" : "off")") }
    }

    /// How to mention spoken text in a log line: the (trimmed) text when verbose, else its size.
    static func describe(text: String, verbose: Bool = verboseText) -> String {
        if verbose { return "\"\(text.prefix(60))\"" }
        return "\(text.split(whereSeparator: \.isWhitespace).count) words, \(text.count) chars"
    }

    /// `2026-11-12 10:03:12.345 [INFO] [engine] message`
    static func format(date: Date, level: String, category: Category, message: String) -> String {
        "\(formatter.string(from: date)) [\(level)] [\(category.rawValue)] \(message)\n"
    }

    static func sessionStartLine(at date: Date, sources: [String], engine: String, echo: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "===== session start \(f.string(from: date)) · sources \(sources.joined(separator: "+")) · engine \(engine) · echo \(echo) ====="
    }

    static func sessionEndLine(duration: TimeInterval, lines: Int, saved: String?) -> String {
        let d = duration < 90 ? "\(Int(duration.rounded())) s" : "\(Int((duration / 60).rounded())) min"
        return "===== session end · \(d) · \(lines) lines · saved \(saved ?? "nothing (no speech)") ====="
    }

    /// Call once at launch: opens the file, logs a session header, installs crash hooks.
    static func start(role: String) {
        queue.sync { openFile(); pruneStrays() }
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        info("=== hearsay \(v) \(role) started · pid \(getpid()) · macOS \(os) · \(Bundle.main.bundlePath)")
        installCrashHooks()
    }

    private static func emit(_ level: String, _ category: Category, _ message: String) {
        let line = format(date: Date(), level: level, category: category, message: message)
        if stderrIsTTY || verbose { FileHandle.standardError.write(line.data(using: .utf8)!) }
        queue.async { writeLine(line) }
    }

    private static func openFile() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
    }

    private static func writeLine(_ line: String) {
        if handle == nil { openFile() }
        guard let h = handle, let data = line.data(using: .utf8) else { return }
        h.write(data)
        if h.offsetInFile > maxBytes { rotate() }
    }

    /// Every log file either flavour (installed / dev) keeps: the base name plus its rolled copies.
    /// Pruning must spare the other flavour's files, since both apps share this folder.
    static func managedNames(baseNames: [String] = DevMode.logBaseNames, rolled: Int = rolledCount) -> Set<String> {
        Set(baseNames.flatMap { base in [base] + (1...max(rolled, 1)).map { "\(base).\($0)" } })
    }
    static let managedFileNames = managedNames()

    /// Removes anything in the log folder other than the files we manage (older layouts, crash
    /// dumps copied there by hand, …) and rolled files older than 30 days, so the folder can never
    /// grow unbounded. The live files are never age-pruned.
    static func prune(in dir: URL, now: Date = Date(), baseNames: [String] = DevMode.logBaseNames) {
        let keep = managedNames(baseNames: baseNames)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in items {
            let name = url.lastPathComponent
            var remove = !keep.contains(name)
            if !remove, !baseNames.contains(name),
               let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               now.timeIntervalSince(m) > maxRolledAge { remove = true }
            if remove { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static func pruneStrays() { prune(in: directory) }

    private static func rotate() {
        handle?.closeFile(); handle = nil
        let fm = FileManager.default
        func rolled(_ n: Int) -> URL { directory.appendingPathComponent("\(DevMode.logFileName).\(n)") }
        try? fm.removeItem(at: rolled(rolledCount))
        for n in stride(from: rolledCount - 1, through: 1, by: -1) { try? fm.moveItem(at: rolled(n), to: rolled(n + 1)) }
        try? fm.moveItem(at: fileURL, to: rolled(1))
        openFile()
    }

    /// Synchronous, async-signal-unsafe-but-last-resort write used from crash handlers.
    private static func writeNow(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: fileURL) { h.seekToEndOfFile(); h.write(data); h.closeFile() }
        FileHandle.standardError.write(data)
    }

    private static func installCrashHooks() {
        NSSetUncaughtExceptionHandler { exc in
            Log.writeNow("\(Log.formatter.string(from: Date())) [FATAL] uncaught exception \(exc.name.rawValue): \(exc.reason ?? "") \n\(exc.callStackSymbols.joined(separator: "\n"))\n")
        }
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE] {
            signal(sig) { s in
                Log.writeNow("\(Log.formatter.string(from: Date())) [FATAL] signal \(s) — see ~/Library/Logs/DiagnosticReports for the crash report\n")
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }
}
