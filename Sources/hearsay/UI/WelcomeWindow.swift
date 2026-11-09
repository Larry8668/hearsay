import AppKit
import AVFoundation
import SwiftUI

/// First-launch window (and Settings ▸ Welcome & permissions… later). One page: what hearsay does,
/// the two permissions, the model download, and a Start button. Everything is bound to AppModel so
/// the download bar moves and the mic row flips to "Allowed" live.
final class WelcomeWindow: NSObject, NSWindowDelegate {
    static let shownKey = "welcomeShown"
    static var shouldShowAutomatically: Bool { !UserDefaults.standard.bool(forKey: shownKey) }

    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) { self.model = model }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        WelcomeWindow.refreshMic(model)
        if let w = window { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: WelcomeView(model: model)))
        w.title = "Welcome to hearsay"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        Log.info("welcome shown (mic \(model.micAuthorized ? "allowed" : "not allowed"), model \(model.modelState))")
    }

    func close() { window?.close() }

    static func refreshMic(_ model: AppModel) {
        let ok = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if model.micAuthorized != ok { model.micAuthorized = ok }
    }

    /// Shows the system prompt the first time; once denied macOS never asks again, so then we
    /// open the Microphone pane instead.
    static func requestMic(_ model: AppModel) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            Log.info("welcome: requesting microphone access")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.info("microphone access \(granted ? "granted" : "denied")")
                DispatchQueue.main.async { refreshMic(model) }
            }
        case .authorized: refreshMic(model)
        default: SettingsLinks.open(for: .me)
        }
    }
}

struct WelcomeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "waveform").font(.system(size: 34, weight: .medium)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("hearsay").font(.system(size: 26, weight: .bold))
                    Text("Live “me / them” transcripts of your calls.").foregroundStyle(.secondary)
                }
            }
            Text("hearsay listens to your microphone (me) and to what your Mac plays (them: Zoom, Meet, Teams, a browser tab) and writes one transcript, saved to Documents ▸ hearsay as the call goes on.")
                .fixedSize(horizontal: false, vertical: true)
            Label("Everything happens on this Mac. Audio and text never leave it.", systemImage: "lock.fill")
                .font(.callout).foregroundStyle(.secondary)

            VStack(spacing: 0) {
                row(symbol: "mic.fill", tint: .blue, title: "Microphone",
                    note: model.micAuthorized ? "Allowed" : "Needed to transcribe what you say") {
                    if model.micAuthorized {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                    } else {
                        Button("Allow…") { model.actions.requestMic() }
                    }
                }
                Divider().padding(.leading, 44)
                row(symbol: "speaker.wave.2.fill", tint: .orange, title: "System audio",
                    note: "macOS asks the first time you start listening") {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                        .help("Allow hearsay under Screen & System Audio Recording ▸ System Audio Recording Only. It records sound only, never your screen.")
                }
                Divider().padding(.leading, 44)
                row(symbol: "cpu", tint: .purple, title: "Speech model", note: modelNote) { modelAccessory }
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))

            HStack {
                Text("Toggle any time with ⌃⌥H or from the menu-bar waveform.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(model.isListening ? "Listening" : "Start listening") {
                    model.actions.closeWelcome()
                    if !model.isListening { model.actions.toggleListening() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.isListening)
            }
        }
        .padding(26)
        .frame(width: 540)
    }

    private var modelNote: String {
        switch model.modelState {
        case .notDownloaded: return "Downloaded once (a few hundred MB), stays on this Mac"
        case .downloading(let f): return f < 0 ? "Preparing…" : "Downloading \(Int(f * 100))% · stays on this Mac"
        case .ready: return "Ready · \(model.engineID) · stays on this Mac"
        case .failed(let e): return "Failed: \(e)"
        }
    }

    @ViewBuilder private var modelAccessory: some View {
        switch model.modelState {
        case .downloading(let f) where f >= 0: ProgressView(value: f).frame(width: 110)
        case .downloading, .notDownloaded: ProgressView().controlSize(.small)
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).font(.title3)
        }
    }

    private func row<A: View>(symbol: String, tint: Color, title: String, note: String, @ViewBuilder accessory: () -> A) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.white).frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            accessory()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}
