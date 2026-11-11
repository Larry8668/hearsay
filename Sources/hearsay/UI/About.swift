import AppKit

/// The standard About panel: icon, name, version, a one-line credit. Reached from the status
/// menu's version line and from the hearsay menu while the main window is up.
enum About {
    static let credits = "Speech recognition by FluidAudio (Apache-2.0), running NVIDIA's Parakeet models (CC-BY-4.0)."

    @MainActor static func show() {
        // The panel is a normal window: it needs the app active to come to the front and take ⌘W.
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(string: credits, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "hearsay",
            .applicationVersion: UpdateChecker.currentVersion,
            .version: "",                        // no "(build)" suffix: the build number is the version
            .credits: credits,
        ]
        // The bundle's icon, drawn large; an LSUIElement app without one gets the generic icon.
        if let icon = NSImage(named: NSImage.applicationIconName) { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
