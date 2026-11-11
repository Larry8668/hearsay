import AppKit
import CoreAudio
import Foundation
import UniformTypeIdentifiers

/// Troubleshooting ▸ "Export diagnostics…": a zip with the log files and a `report.txt` describing
/// the machine, permissions, settings, audio devices and model folder. Never any transcript text
/// (only how many transcripts exist and where).
enum Diagnostics {
    /// Everything `report.txt` says, gathered up front so the formatting is a pure function.
    struct Inputs {
        var appVersion = "?"
        var isDev = false
        var macOS = ""
        var macModel = ""
        var microphone = ""
        var systemAudio = ""
        var settings: [String: String] = [:]
        var inputDevices: [String] = []
        var outputDevices: [String] = []
        var defaultInput = "none"
        var defaultOutput = "none"
        var models: [String] = []
        var modelFolder = ""
        var transcriptCount = 0
        var transcriptFolder = ""
        var logFiles: [String] = []
    }

    static func report(_ i: Inputs, date: Date = Date()) -> String {
        func list(_ items: [String]) -> String { items.isEmpty ? "  (none)\n" : items.map { "  \($0)\n" }.joined() }
        var out = "hearsay diagnostics · \(ISO8601DateFormatter().string(from: date))\n\n"
        out += "app: hearsay \(i.appVersion)\(i.isDev ? " (dev build)" : "") · \(Bundle.main.bundlePath)\n"
        out += "macOS: \(i.macOS)\nMac: \(i.macModel)\n\n"
        out += "permissions:\n  microphone = \(i.microphone)\n  system audio = \(i.systemAudio)\n\n"
        out += "settings (\(i.isDev ? Prefs.devSuite : "dev.hearsay.app")):\n"
        out += list(i.settings.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" })
        out += "\naudio input devices (default: \(i.defaultInput)):\n" + list(i.inputDevices)
        out += "\naudio output devices (default: \(i.defaultOutput)):\n" + list(i.outputDevices)
        out += "\nmodel folder: \(i.modelFolder)\n" + list(i.models)
        out += "\ntranscripts: \(i.transcriptCount) in \(i.transcriptFolder)\n"
        out += "\nlog files:\n" + list(i.logFiles)
        return out
    }

    // MARK: Collecting

    @MainActor static func collect() -> Inputs {
        var i = Inputs()
        i.appVersion = DevMode.versionString
        i.isDev = DevMode.isDev
        i.macOS = ProcessInfo.processInfo.operatingSystemVersionString
        i.macModel = sysctlString("hw.model")
        i.microphone = Permissions.microphone.rawValue
        i.systemAudio = Permissions.systemAudio.rawValue
        let domain = DevMode.isDev ? Prefs.devSuite : "dev.hearsay.app"
        let prefs = Prefs.store.persistentDomain(forName: domain) ?? [:]
        i.settings = prefs.mapValues { "\($0)" }
        let devices = ((try? CA.getArray(CA.system, kAudioHardwarePropertyDevices, zero: CA.unknown)) ?? [])
        for d in devices {
            let name = CA.name(d) ?? "?"
            if channelCount(d, scope: kAudioObjectPropertyScopeInput) > 0 { i.inputDevices.append(name) }
            if channelCount(d, scope: kAudioObjectPropertyScopeOutput) > 0 { i.outputDevices.append(name) }
        }
        i.defaultInput = CA.name(CA.defaultInputDevice) ?? "none"
        i.defaultOutput = CA.name(CA.defaultOutputDevice) ?? "none"
        i.modelFolder = ModelStore.modelDirectory.path
        i.models = modelInventory(ModelStore.modelDirectory)
        let tdir = TranscriptStore.defaultDirectory
        i.transcriptFolder = tdir.path
        i.transcriptCount = ((try? FileManager.default.contentsOfDirectory(atPath: tdir.path)) ?? []).filter { $0.hasSuffix(".json") }.count
        i.logFiles = logFiles().map { "\($0.lastPathComponent) (\(byteString(size($0))))" }
        return i
    }

    /// This flavour's log files: the live one and its rolled copies.
    static func logFiles() -> [URL] {
        let names = [DevMode.logFileName] + (1...Log.rolledCount).map { "\(DevMode.logFileName).\($0)" }
        return names.map { Log.directory.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// `name  size` for each folder two levels down (e.g. `parakeet-eou-streaming/160ms`).
    static func modelInventory(_ root: URL) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for top in ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path }) {
            let subs = ((try? fm.contentsOfDirectory(at: top, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
            if subs.isEmpty { out.append("\(top.lastPathComponent)  \(byteString(size(top)))"); continue }
            for s in subs { out.append("\(top.lastPathComponent)/\(s.lastPathComponent)  \(byteString(size(s)))") }
        }
        return out
    }

    static func size(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0 }
        var total: Int64 = 0
        let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let f = e?.nextObject() as? URL { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return total
    }

    static func byteString(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private static func sysctlString(_ name: String) -> String {
        var len = 0
        guard sysctlbyname(name, nil, &len, nil, 0) == 0, len > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: len)
        guard sysctlbyname(name, &buf, &len, nil, 0) == 0 else { return "?" }
        return String(cString: buf)
    }

    private static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = CA.address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    // MARK: Exporting

    /// Writes the zip to `destination` (replacing a file there). Throws if `ditto` fails.
    @MainActor static func export(to destination: URL) throws {
        let fm = FileManager.default
        let stamp = dateStamp()
        let folderName = "hearsay-diagnostics-\(stamp)"
        let staging = fm.temporaryDirectory.appendingPathComponent("hearsay-diag-\(UUID().uuidString)", isDirectory: true)
        let root = staging.appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for f in logFiles() { try? fm.copyItem(at: f, to: root.appendingPathComponent(f.lastPathComponent)) }
        try report(collect()).write(to: root.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: destination)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", root.path, destination.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "hearsay.diagnostics", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "ditto failed (\(p.terminationStatus))"])
        }
        Log.info(.app, "diagnostics exported to \(destination.lastPathComponent)")
    }

    static func dateStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }

    /// The menu action: a save panel, then `export`, then reveal the zip.
    @MainActor static func exportInteractively() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "hearsay-diagnostics-\(dateStamp()).zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try export(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            Log.error(.app, "diagnostics export failed: \(error)")
            let a = NSAlert(); a.messageText = "Could not export diagnostics"; a.informativeText = "\(error.localizedDescription)"
            a.runModal()
        }
    }
}
