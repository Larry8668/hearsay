import AppKit
import AVFoundation
import FluidAudio
import SwiftUI

/// First-launch window (and Settings ▸ Welcome & permissions… later). One page: what hearsay does,
/// the two permissions, the model download, and a Start button. Everything is bound to AppModel so
/// the download bar moves and the mic row flips to "Allowed" live.
final class WelcomeWindow: NSObject, NSWindowDelegate {
    static let shownKey = "welcomeShown"
    static var shouldShowAutomatically: Bool { !Prefs.store.bool(forKey: shownKey) }

    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) { self.model = model }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        Prefs.store.set(true, forKey: Self.shownKey)
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
        Log.info(.ui, "welcome shown (mic \(model.micAuthorized ? "allowed" : "not allowed"), model \(model.modelState))")
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
            Log.info(.ui, "welcome: requesting microphone access")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.info(.ui, "microphone access \(granted ? "granted" : "denied")")
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
            Text("hearsay listens to your microphone (me) and to each app your Mac plays sound from (them: Zoom, Meet, Teams, a video), shows live captions on a small bar at the bottom of the screen, and saves the transcript to Documents ▸ hearsay as the call goes on.")
                .fixedSize(horizontal: false, vertical: true)
            Label("Everything happens on this Mac. Audio and text never leave it.", systemImage: "lock.fill")
                .font(.callout).foregroundStyle(.secondary)

            VStack(spacing: 0) {
                // Once denied, macOS never asks again: say so, and send the user to the pane.
                let micDenied = !model.micAuthorized && Permissions.microphone == .denied
                row(symbol: "mic.fill", tint: .blue, title: "Microphone",
                    note: model.micAuthorized ? "Allowed"
                        : micDenied ? "Turned off in System Settings ▸ Privacy & Security ▸ Microphone" : "Needed to transcribe what you say") {
                    if model.micAuthorized {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                    } else {
                        Button(micDenied ? "Open settings…" : "Allow…") { model.actions.requestMic() }
                    }
                }
                Divider().padding(.leading, 44)
                row(symbol: "speaker.wave.2.fill", tint: .orange, title: "System audio",
                    note: "macOS asks the first time you start listening") {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                        .help("Allow hearsay under Screen & System Audio Recording ▸ System Audio Recording Only. It records sound only, never your screen.")
                }
                if !model.chooserPending {
                    Divider().padding(.leading, 44)
                    row(symbol: "cpu", tint: .purple, title: "Speech model", note: modelNote) { modelAccessory }
                    if showsSpeakerRow {
                        Divider().padding(.leading, 44)
                        row(symbol: "person.2.fill", tint: .teal, title: "Speaker model", note: speakerNote) { speakerAccessory }
                    }
                }
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))

            if model.chooserPending { chooser }

            HStack {
                Text("⌃⌥H starts and stops from any app. The bar's ≡ button opens the hearsay window with the full transcript.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                Button(model.isActive ? "Listening" : "Start listening") {
                    model.actions.closeWelcome()
                    if !model.isActive { model.actions.toggleListening() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.isActive || model.modelState != .ready)
            }
        }
        .padding(26)
        .frame(width: 540)
    }

    // MARK: Choose your models

    @State private var speechPick = ParakeetEngine.configuredVariant()
    @State private var speakerPick: ModelCatalog.Speaker = Prefs.store.string(forKey: "diarization") == "off" ? .off : ModelCatalog.configuredSpeaker()

    private var speech: ModelCatalog.Speech { ModelCatalog.speech.first { $0.variant == speechPick } ?? ModelCatalog.speech[0] }

    private var downloadBytes: Int64 {
        ModelCatalog.bytesToDownload(speech: speech, speaker: speakerPick,
                                     speechOnDisk: ModelStore.isDownloaded(speech.variant), speakerOnDisk: ModelStore.isDownloaded(speakerPick))
    }

    /// One card in the style of the rows above: a header row with a coloured tile, then the options.
    private var chooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose your models").font(.headline)
            VStack(spacing: 0) {
                row(symbol: "cpu", tint: .purple, title: "Speech to text", note: "Required · pick one") { EmptyView() }
                ForEach(ModelCatalog.speech) { s in
                    option(selected: speechPick == s.variant, title: s.title, detail: "\(s.name) · \(s.detail)",
                           size: ModelStore.isDownloaded(s.variant) ? "On this Mac" : "~\(s.megabytes) MB") { speechPick = s.variant }
                }
                Divider().padding(.leading, 44)
                row(symbol: "person.2.fill", tint: .teal, title: "Tell speakers apart", note: "Optional · labels who is talking within me and them") { EmptyView() }
                ForEach(ModelCatalog.Speaker.allCases) { s in
                    option(selected: speakerPick == s, title: s.title, detail: s == .off ? s.detail : "\(s.name) · \(s.detail)",
                           size: s == .off ? "" : ModelStore.isDownloaded(s) ? "On this Mac" : "~\(s.megabytes) MB") { speakerPick = s }
                }
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            HStack {
                Label(ModelCatalog.totalText(bytes: downloadBytes), systemImage: "arrow.down.circle")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Button(downloadBytes == 0 ? "Continue" : "Download") {
                    model.actions.startModelDownload(speech.variant, speakerPick)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }

    /// A radio-style choice, indented under its header row.
    private func option(selected: Bool, title: String, detail: String, size: String, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(size).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Speaker model row

    /// Only after a chooser download this launch (existing users see the same rows as before).
    private var showsSpeakerRow: Bool { model.chosenThisRun && model.diarization != .off }

    private var speakerNote: String {
        switch model.diarizerState {
        case .notDownloaded: return model.modelState == .ready ? "Preparing…" : "Starts after the speech model"
        case .downloading(let f): return f < 0 ? "Preparing…" : "Downloading \(Int(f * 100))% · stays on this Mac"
        case .paused(let f): return f < 0 ? "Download paused" : "Paused at \(Int(f * 100))% · resumes from here"
        case .ready: return "Ready · stays on this Mac"
        case .failed(let e): return "Couldn't download or load it: \(e)"
        }
    }

    @ViewBuilder private var speakerAccessory: some View {
        switch model.diarizerState {
        case .downloading(let f):
            HStack(spacing: 8) {
                if f >= 0 { ProgressView(value: f).frame(width: 90) } else { ProgressView().controlSize(.small) }
                smallButton("pause.fill", "Pause the download; it resumes from the same point") { model.actions.pauseSpeakerDownload() }
                smallButton("xmark", "Cancel, delete what was downloaded and turn speakers off") { model.actions.cancelSpeakerDownload() }
            }
        case .paused(let f):
            HStack(spacing: 8) {
                if f >= 0 { ProgressView(value: f).frame(width: 90).tint(.secondary) }
                smallButton("play.fill", "Resume the download") { model.actions.resumeSpeakerDownload() }
                smallButton("xmark", "Cancel, delete what was downloaded and turn speakers off") { model.actions.cancelSpeakerDownload() }
            }
        case .notDownloaded:
            if model.modelState == .ready { ProgressView().controlSize(.small) }
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
        case .failed:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).font(.title3)
                Button("Retry") { model.actions.resumeSpeakerDownload() }.controlSize(.small)
            }
        }
    }

    private var modelNote: String {
        switch model.modelState {
        case .notDownloaded: return "Downloaded once, stays on this Mac"
        case .downloading(let f): return f < 0 ? "Preparing…" : "Downloading \(Int(f * 100))% · stays on this Mac"
        case .paused(let f): return f < 0 ? "Download paused" : "Paused at \(Int(f * 100))% · resumes from here"
        case .ready: return "Ready · \(model.engineID) · stays on this Mac"
        case .failed(let e): return "Couldn't download or load it: \(e)"
        }
    }

    @ViewBuilder private var modelAccessory: some View {
        switch model.modelState {
        case .downloading(let f):
            HStack(spacing: 8) {
                if f >= 0 { ProgressView(value: f).frame(width: 90) } else { ProgressView().controlSize(.small) }
                smallButton("pause.fill", "Pause the download; it resumes from the same point") { model.actions.pauseDownload() }
                smallButton("xmark", "Cancel and delete what was downloaded") { model.actions.cancelDownload() }
            }
        case .paused(let f):
            HStack(spacing: 8) {
                if f >= 0 { ProgressView(value: f).frame(width: 90).tint(.secondary) }
                smallButton("play.fill", "Resume the download") { model.actions.resumeDownload() }
                smallButton("xmark", "Cancel and delete what was downloaded") { model.actions.cancelDownload() }
            }
        case .notDownloaded:
            Button("Download") { model.actions.resumeDownload() }.controlSize(.small)
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
        case .failed:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).font(.title3)
                Button("Retry") { model.actions.resumeDownload() }.controlSize(.small)
            }
        }
    }

    private func smallButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 14) }
            .controlSize(.small).help(help)
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
