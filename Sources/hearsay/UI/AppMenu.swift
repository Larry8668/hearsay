import AppKit

/// The app's main menu (hearsay ▸ File ▸ Edit ▸ View ▸ Window). An accessory app shows no menu bar,
/// but key equivalents still route through `NSApp.mainMenu`: without an Edit menu ⌘C does
/// nothing in the transcript's selectable text, and without a Window menu ⌘W won't close the
/// window. While the main window is up the app is a regular one (see `MainWindow.show`) and
/// the menu bar shows these for real, so they are laid out like any Mac app's.
///
/// Actions that need the app's objects come in as closures; the rest are standard responder
/// chain selectors.
enum AppMenu {
    struct Actions {
        var about: () -> Void
        var showSettings: () -> Void
        var bumpFont: (Double) -> Void
    }

    private static var actions: Actions?
    private static let target = Target()

    @MainActor static func install(_ a: Actions) {
        actions = a
        let main = NSMenu()

        let app = NSMenu(title: "hearsay")
        app.addItem(withTitle: "About hearsay", action: #selector(Target.about), keyEquivalent: "").target = target
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(Target.settings), keyEquivalent: ",").target = target
        app.addItem(.separator())
        app.addItem(withTitle: "Hide hearsay", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit hearsay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File ▸ Export… reaches the main window's delegate through the responder chain, so ⌘E
        // works whenever that window is key and is disabled otherwise.
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Export…", action: #selector(MainWindow.exportTranscript), keyEquivalent: "e")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        view.addItem(.separator())
        // ⌘+ / ⌘- like a browser: "=" so the unshifted key works, with "+" as a hidden alternate.
        view.addItem(withTitle: "Larger Text", action: #selector(Target.larger), keyEquivalent: "=").target = target
        let plus = NSMenuItem(title: "Larger Text", action: #selector(Target.larger), keyEquivalent: "+")
        plus.target = target; plus.isAlternate = true; plus.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(plus)
        view.addItem(withTitle: "Smaller Text", action: #selector(Target.smaller), keyEquivalent: "-").target = target

        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        win.addItem(.separator())
        win.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        for m in [app, file, edit, view, win] {
            let mi = NSMenuItem(title: m.title, action: nil, keyEquivalent: "")
            mi.submenu = m
            main.addItem(mi)
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }

    /// Objective-C target for the items that call back into the app.
    private final class Target: NSObject {
        @objc func about() { AppMenu.actions?.about() }
        @objc func settings() { AppMenu.actions?.showSettings() }
        @objc func larger() { AppMenu.actions?.bumpFont(1) }
        @objc func smaller() { AppMenu.actions?.bumpFont(-1) }
    }
}
