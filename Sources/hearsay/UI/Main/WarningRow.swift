import SwiftUI

/// A line under the live transcript's header while something needs attention: a permission
/// that was refused (with a button to the right System Settings pane) or the session's last
/// warning (shown for 15 s, like the menu's ⚠ line). Nothing when all is well. Takes values,
/// not `AppModel`, so it costs nothing per partial beyond its parent's own body.
struct WarningRow: View {
    let warning: String?
    let denied: Set<Speaker>

    var body: some View {
        if let text = text {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(text).font(.system(size: 12)).lineLimit(2)
                Spacer(minLength: 8)
                if let s = denied.sorted(by: { $0.rawValue < $1.rawValue }).first {
                    Button("Open settings…") { SettingsLinks.open(for: s) }.controlSize(.small)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.yellow.opacity(0.08))
            Divider()
        }
    }

    private var text: String? {
        if denied.contains(.me) && denied.contains(.them) { return "Microphone and system audio access were refused. Allow hearsay in System Settings, then start again." }
        if denied.contains(.me) { return "Microphone access was refused. Allow hearsay under Privacy & Security ▸ Microphone, then start again." }
        if denied.contains(.them) { return "System audio recording was refused. Allow hearsay under Privacy & Security ▸ Screen & System Audio Recording, then start again." }
        return warning
    }
}
