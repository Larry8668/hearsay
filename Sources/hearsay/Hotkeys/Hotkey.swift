import Carbon
import AppKit

/// A global hotkey via Carbon `RegisterEventHotKey`: works whichever app is frontmost and needs
/// no Accessibility permission (unlike an NSEvent global monitor). Same approach as sharemask's
/// Hotkeys, trimmed to the two shortcuts hearsay has.
final class Hotkey {
    /// ⌃⌥H — Control-Option is rarely taken by call apps, and H for "hear".
    static let toggleListening = Hotkey(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey | (DevMode.isDev ? shiftKey : 0)), display: DevMode.isDev ? "⌃⌥⇧H" : "⌃⌥H")
    /// ⌃⌥P — pause / resume, same modifier family. Dev mode adds ⇧ to both so it can run beside the installed app.
    static let togglePause = Hotkey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey | (DevMode.isDev ? shiftKey : 0)), display: DevMode.isDev ? "⌃⌥⇧P" : "⌃⌥P")

    let keyCode: UInt32
    let modifiers: UInt32
    let display: String
    private var ref: EventHotKeyRef?
    private var handler: (() -> Void)?

    private static var handlerRef: EventHandlerRef?
    private static var registry: [UInt32: Hotkey] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
        id = Hotkey.nextID
        Hotkey.nextID += 1
    }

    /// AppKit modifier flags for showing the same shortcut in a menu item.
    var menuModifiers: NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { m.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { m.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { m.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { m.insert(.command) }
        return m
    }

    func register(_ handler: @escaping () -> Void) {
        unregister()
        Hotkey.installHandlerIfNeeded()
        self.handler = handler
        Hotkey.registry[id] = self
        var r: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x48535259) /* 'HSRY' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &r)
        if status == noErr, let r = r {
            ref = r
            Log.info(.ui, "hotkey \(display) registered")
        } else {
            // Another app owns the combo (eventHotKeyExistsErr). The menu item still works.
            Log.warn(.ui, "RegisterEventHotKey(\(display)) failed: \(status)")
        }
    }

    func unregister() {
        if let r = ref { UnregisterEventHotKey(r) }
        ref = nil
        handler = nil
        Hotkey.registry[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event = event else { return noErr }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            Hotkey.registry[hk.id]?.handler?()
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}
