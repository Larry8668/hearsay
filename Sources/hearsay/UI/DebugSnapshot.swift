import AppKit

/// Development aid: with `HEARSAY_SNAPSHOT_DIR=/some/dir` in the environment
/// (`open --env HEARSAY_SNAPSHOT_DIR=/tmp/hs build/hearsay.app`), every 2 s (or HEARSAY_SNAPSHOT_INTERVAL) the app renders its
/// visible windows to PNGs and the status menu to `menu.txt` in that folder. Renders in-process
/// (cacheDisplay), so it works where `screencapture` lacks Screen Recording permission, e.g. CI or
/// an agent's terminal. Does nothing when the variable is unset.
enum DebugSnapshot {
    private static var timer: Timer?

    static func installIfRequested(menu: @escaping () -> String) {
        guard let path = ProcessInfo.processInfo.environment["HEARSAY_SNAPSHOT_DIR"], !path.isEmpty else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Log.info(.ui, "debug snapshots → \(dir.path)")
        // HEARSAY_SNAPSHOT_INTERVAL=0.25 catches short-lived states (an empty transcript at start).
        let every = Double(ProcessInfo.processInfo.environment["HEARSAY_SNAPSHOT_INTERVAL"] ?? "") ?? 2
        let t = Timer(timeInterval: max(0.1, every), repeats: true) { _ in
            MainActor.assumeIsolated { dump(to: dir, menu: menu()) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static let sequence = ProcessInfo.processInfo.environment["HEARSAY_SNAPSHOT_SEQ"] == "1"
    private static var count = 0
    private static var frameLog = ""

    @MainActor private static func dump(to dir: URL, menu: String) {
        count += 1
        defer { if sequence { try? frameLog.write(to: dir.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8) } }
        try? menu.write(to: dir.appendingPathComponent("menu.txt"), atomically: true, encoding: .utf8)
        for w in NSApp.windows where w.isVisible {
            guard let view = (w.isOpaque ? w.contentView?.superview : nil) ?? w.contentView,
                  var rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if !w.isOpaque {
                // A transparent window (the recording bar): cacheDisplay misses its material and
                // shadow, so prefer the window server's own picture of it, laid over a stand-in
                // desktop so the PNG shows roughly what a user would see.
                if let img = windowServerImage(w) { rep = NSBitmapImageRep(cgImage: img) }
                if let composed = overBackdrop(rep) { rep = composed }
            }
            // Autosave name, else the window's identifier (the recording bar's two shapes), else its class.
            let name = (w.frameAutosaveName.isEmpty ? (w.identifier?.rawValue ?? String(describing: type(of: w))) : w.frameAutosaveName)
                .replacingOccurrences(of: "/", with: "-")
            // HEARSAY_SNAPSHOT_SEQ=1 keeps every frame (name-0001.png …) to step through an animation.
            let suffix = sequence ? String(format: "-%04d", count) : ""
            if sequence { frameLog += "\(count) \(name) \(NSStringFromRect(w.frame))\n" }
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + suffix + ".png"))
        }
        if ProcessInfo.processInfo.environment["HEARSAY_SNAPSHOT_ALL"] == "1" { dumpOtherWindows(to: dir) }
    }

    /// `HEARSAY_SNAPSHOT_ALL=1`: also the process's on-screen windows that aren't `NSApp.windows`
    /// (an open menu, a save panel), as the window server draws them, to `extra-<id>.png`.
    /// Capturing one's own windows needs no Screen Recording permission.
    @MainActor private static func dumpOtherWindows(to dir: URL) {
        let known = Set(NSApp.windows.map(\.windowNumber))
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == getpid(), let id = info[kCGWindowNumber as String] as? UInt32,
                  !known.contains(Int(id)), let img = createImage?(.null, 1 << 3, id, 1 << 3)?.takeRetainedValue() else { continue }
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("extra-\(id).png"))
        }
    }

    /// The window as the window server composites it (real material and shadow; what is behind
    /// it is not included). Capturing your own window needs no Screen
    /// Recording permission. Looked up dynamically: CGWindowListCreateImage is deprecated
    /// (ScreenCaptureKit is async and overkill for a debug aid) and a direct call would warn.
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let createImage: CreateImage? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
        .map { unsafeBitCast($0, to: CreateImage.self) }

    @MainActor private static func windowServerImage(_ w: NSWindow) -> CGImage? {
        // .optionIncludingWindow (1 << 3); .bestResolution (1 << 3)
        guard let id = UInt32(exactly: w.windowNumber) else { return nil }   // status item window: not a CGWindowID
        return createImage?(.null, 1 << 3, id, 1 << 3)?.takeRetainedValue()
    }

    /// Light-to-dark diagonal gradient: the bar has to read over both a white page and a dark app.
    @MainActor private static func overBackdrop(_ rep: NSBitmapImageRep) -> NSBitmapImageRep? {
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        let r = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSGradient(starting: NSColor(white: 0.93, alpha: 1), ending: NSColor(calibratedRed: 0.16, green: 0.2, blue: 0.3, alpha: 1))?
            .draw(in: r, angle: 0)
        rep.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    /// Development aid: `HEARSAY_UI_SCRIPT="panel@5,captions@12,pause@20"` runs the named actions
    /// that many seconds after launch, so UI states that need a click can be snapshotted unattended.
    /// An action can take text: `title=Design review@6` runs `title` with `scriptArgument` set
    /// to "Design review" (no "," or "@" in it, as they delimit the script).
    static func runScriptIfRequested(_ actions: [String: () -> Void]) {
        guard let script = ProcessInfo.processInfo.environment["HEARSAY_UI_SCRIPT"] else { return }
        for step in script.split(separator: ",") {
            let parts = step.split(separator: "@")
            guard parts.count == 2, let at = Double(parts[1]) else { continue }
            let call = parts[0].split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = call.first, let action = actions[name] else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                Log.info(.ui, "ui script: \(parts[0])")
                scriptArgument = call.count > 1 ? call[1] : ""
                action()
            }
        }
    }

    /// The text after "=" of the script step being run ("" when none).
    @MainActor static var scriptArgument = ""

    /// "✓ Me (microphone)", "  Start listening ⌃⌥H", "(disabled) Not listening", nested by indent.
    static func describe(_ menu: NSMenu, indent: String = "") -> String {
        var out = ""
        for mi in menu.items where !mi.isHidden {
            if mi.isSeparatorItem { out += indent + "----\n"; continue }
            let mark = mi.state == .on ? "✓ " : "  "
            let key = mi.keyEquivalent.isEmpty ? "" : "  [\(mi.keyEquivalent)]"
            out += indent + mark + (mi.isEnabled ? "" : "(disabled) ") + mi.title + key + "\n"
            if let sub = mi.submenu { out += describe(sub, indent: indent + "    ") }
        }
        return out
    }
}
