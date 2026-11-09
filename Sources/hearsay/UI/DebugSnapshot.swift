import AppKit

/// Development aid: with `HEARSAY_SNAPSHOT_DIR=/some/dir` in the environment
/// (`open --env HEARSAY_SNAPSHOT_DIR=/tmp/hs build/hearsay.app`), every 2 s the app renders its
/// visible windows to PNGs and the status menu to `menu.txt` in that folder. Renders in-process
/// (cacheDisplay), so it works where `screencapture` lacks Screen Recording permission, e.g. CI or
/// an agent's terminal. Does nothing when the variable is unset.
enum DebugSnapshot {
    private static var timer: Timer?

    static func installIfRequested(menu: @escaping () -> String) {
        guard let path = ProcessInfo.processInfo.environment["HEARSAY_SNAPSHOT_DIR"], !path.isEmpty else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Log.info("debug snapshots → \(dir.path)")
        let t = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { dump(to: dir, menu: menu()) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @MainActor private static func dump(to dir: URL, menu: String) {
        try? menu.write(to: dir.appendingPathComponent("menu.txt"), atomically: true, encoding: .utf8)
        for w in NSApp.windows where w.isVisible {
            guard let view = w.contentView?.superview ?? w.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = (w.frameAutosaveName.isEmpty ? String(describing: type(of: w)) : w.frameAutosaveName)
                .replacingOccurrences(of: "/", with: "-")
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
        }
    }

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
