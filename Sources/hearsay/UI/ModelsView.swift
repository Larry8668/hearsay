import AppKit
import FluidAudio
import SwiftUI

/// Settings ▸ Models…: every model hearsay can use, what it does, what it costs in disk space, and
/// Use / Download / Delete. The decisions (status text, which buttons) live in `ModelCatalog`.
final class ModelsWindow: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) { self.model = model }

    func show() {
        if let w = window { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: ModelsView(model: model)))
        w.title = "Models"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

/// Downloads started from this window for models the session is not loading (the session's own
/// model reports through `AppModel`). Keyed "speech.<raw>" / "speaker.<raw>".
@MainActor
final class ModelsViewModel: ObservableObject {
    @Published var states: [String: ModelState] = [:]
    /// Bumped after a delete so rows re-read the disk.
    @Published var refresh = 0
    @Published var error: String?

    func downloadSpeech(_ v: StreamingModelVariant) {
        let id = "speech.\(v.rawValue)"
        states[id] = .downloading(fraction: -1)
        Task {
            do {
                try await ModelStore.shared.ensureDownloaded(v) { s in Task { @MainActor in self.setState(id, s) } }
                states[id] = nil
            } catch is CancellationError { states[id] = nil } catch {
                states[id] = .failed(error.localizedDescription)
            }
            refresh += 1
        }
    }

    func downloadSpeaker(_ s: ModelCatalog.Speaker) {
        guard let kind = ModelCatalog.kind(s) else { return }
        let id = "speaker.\(s.rawValue)"
        states[id] = .downloading(fraction: -1)
        Task {
            do {
                // Loads the weights too (cheap once on disk); only the files matter here.
                _ = try await ModelStore.shared.loadDiarizer(kind) { st in Task { @MainActor in self.setState(id, st) } }
                states[id] = nil
            } catch {
                states[id] = (error is CancellationError) ? nil : .failed(error.localizedDescription)
            }
            refresh += 1
        }
    }

    func cancelSpeech(_ v: StreamingModelVariant) { Task { await ModelStore.shared.cancelDownload(v) } }
    func cancelSpeaker(_ s: ModelCatalog.Speaker) {
        guard let kind = ModelCatalog.kind(s) else { return }
        Task { await ModelStore.shared.cancelDiarizerDownload(kind); states["speaker.\(s.rawValue)"] = nil; refresh += 1 }
    }

    func deleteSpeech(_ v: StreamingModelVariant) { remove("speech \(v.rawValue)") { try ModelStore.delete(v) } }
    func deleteSpeaker(_ s: ModelCatalog.Speaker) {
        guard let kind = ModelCatalog.kind(s) else { return }
        remove("speaker \(s.rawValue)") { try ModelStore.delete(kind) }
    }

    private func remove(_ what: String, _ body: () throws -> Void) {
        do { try body(); error = nil; Log.info(.model, "models: deleted \(what)") } catch {
            self.error = "Couldn't delete it: \(error.localizedDescription)"
            Log.warn(.model, "models: could not delete \(what): \(error)")
        }
        refresh += 1
    }

    private func setState(_ id: String, _ s: ModelState) {
        if case .ready = s { states[id] = nil } else if states[id] != nil { states[id] = s }
    }
}

struct ModelsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var vm = ModelsViewModel()

    var body: some View {
        let _ = vm.refresh   // re-read the disk after a delete or download
        VStack(alignment: .leading, spacing: 14) {
            section("Speech to text", note: "Required. One is used for every call; changing it applies from the next session.") {
                ForEach(Array(ModelCatalog.speech.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Divider().padding(.leading, 12) }
                    speechRow(s)
                }
            }
            section("Tell speakers apart", note: "Optional. Which one is used is chosen here; a change applies the next time hearsay starts.") {
                ForEach(Array(ModelCatalog.Speaker.models.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Divider().padding(.leading, 12) }
                    speakerRow(s)
                }
            }
            if let e = vm.error { Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red) }
            Text("Models stay on this Mac, in ~/Library/Application Support/hearsay/models (\(ModelCatalog.sizeText(ModelStore.diskSize())) now). Deleting one frees that space; you can download it again any time.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 540)
    }

    // MARK: Rows

    private func speechRow(_ s: ModelCatalog.Speech) -> some View {
        let selected = s.variant == ParakeetEngine.configuredVariant()
        let state: ModelState? = selected ? model.modelState : vm.states["speech.\(s.id)"]
        let downloaded = ModelStore.isDownloaded(s.variant)
        let active = selected && downloaded
        return rowView(title: "\(s.title) · \(s.name)", detail: s.detail, badge: active ? "In use" : selected ? "Selected" : nil,
                       downloaded: downloaded, bytes: ModelStore.diskSize(s.variant), declared: s.bytes, state: state,
                       selected: selected, active: active) { action in
            switch action {
            case .use: model.actions.useSpeechModel(s.variant)
            case .download: if selected { model.actions.resumeDownload() } else { vm.downloadSpeech(s.variant) }
            case .delete: vm.deleteSpeech(s.variant)
            case .cancel: if selected { model.actions.cancelDownload() } else { vm.cancelSpeech(s.variant) }
            }
        }
    }

    private func speakerRow(_ s: ModelCatalog.Speaker) -> some View {
        let selected = s == ModelCatalog.configuredSpeaker()
        let live = selected && model.diarization != .off
        // The session's own speaker model reports through AppModel; others through this window.
        let state: ModelState? = live ? model.diarizerState : vm.states["speaker.\(s.rawValue)"]
        let downloaded = ModelStore.isDownloaded(s)
        let active = live && downloaded
        return rowView(title: "\(s.title) · \(s.name)", detail: s.detail,
                       badge: active ? "In use" : selected ? "Selected" : nil,
                       downloaded: downloaded, bytes: ModelStore.diskSize(s), declared: s.bytes, state: state,
                       selected: selected, active: active) { action in
            switch action {
            case .use: Prefs.store.set(s.rawValue, forKey: ModelCatalog.diarizerKey); vm.refresh += 1
            case .download: if live { model.actions.resumeSpeakerDownload() } else { vm.downloadSpeaker(s) }
            case .delete: vm.deleteSpeaker(s)
            case .cancel: if live { model.actions.cancelSpeakerDownload() } else { vm.cancelSpeaker(s) }
            }
        }
    }

    private func rowView(title: String, detail: String, badge: String?, downloaded: Bool, bytes: Int64, declared: Int64,
                         state: ModelState?, selected: Bool, active: Bool, perform: @escaping (ModelCatalog.RowAction) -> Void) -> some View {
        let busy = ModelCatalog.isBusy(state)
        let status = ModelCatalog.statusText(downloaded: downloaded, bytes: bytes, state: state)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    if let badge { Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.green)) }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    if !downloaded && !busy { Text("· about \(ModelCatalog.sizeText(declared))").font(.caption).foregroundStyle(.secondary) }
                    if case .downloading(let f)? = state, f >= 0 { ProgressView(value: f).frame(width: 80).controlSize(.small) }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                ForEach(ModelCatalog.rowActions(downloaded: downloaded, busy: busy, selected: selected, active: active), id: \.self) { a in
                    Button(label(a)) { perform(a) }.controlSize(.small)
                        .help(a == .delete ? "Delete the files and free the disk space" : "")
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func label(_ a: ModelCatalog.RowAction) -> String {
        switch a {
        case .use: return "Use"
        case .download: return "Download"
        case .delete: return "Delete"
        case .cancel: return "Cancel"
        }
    }

    private func section<C: View>(_ title: String, note: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) { content() }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }
}
