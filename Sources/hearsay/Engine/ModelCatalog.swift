import FluidAudio
import Foundation

/// The models hearsay offers, what each does and how big it is: the welcome window's "Choose your
/// models" step and Settings ▸ Models… read this one table, and the decisions they take (does the
/// chooser show, how much will be downloaded, which buttons a row gets) are pure functions here.
///
/// Sizes are the download sizes measured in ParakeetEngine's doc comment and the speaker repos
/// (decimal MB, as Finder shows them). Kept here rather than read from `DiarizerKind` so this file
/// stands on its own; the `diarizer` preference is read and written by raw value.
enum ModelCatalog {
    static let chosenKey = "modelsChosen"
    static let engineKey = "engineVariant", diarizerKey = "diarizer"

    struct Speech: Identifiable {
        let variant: StreamingModelVariant
        let title: String       // "Best accuracy"
        let name: String        // "Parakeet Unified 0.6B"
        let detail: String
        let megabytes: Int
        var id: String { variant.rawValue }
        var bytes: Int64 { Int64(megabytes) * 1_000_000 }
    }

    /// Unified 640 ms is the default (see `ParakeetEngine.defaultVariant`). EOU 320 ms measured ~6
    /// word errors in ~160 words against 2 for Unified, always lowercase and without punctuation,
    /// but 214 MB, a third of the compute and about the same memory.
    static let speech: [Speech] = [
        Speech(variant: .parakeetUnified640ms, title: "Best accuracy", name: "Parakeet Unified 0.6B",
               detail: "Punctuation and numbers, ready to read.", megabytes: 580),
        Speech(variant: .parakeetEou320ms, title: "Smaller and faster", name: "Parakeet EOU 120M",
               detail: "Less accurate (about three times the mistakes), all lowercase, no punctuation.", megabytes: 214),
    ]

    /// Tell speakers apart: Off, or one of two models (raw values of `DiarizerKind`).
    enum Speaker: String, CaseIterable, Identifiable {
        case off, sortformer, lseend
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return "Off"
            case .sortformer: return "Up to 4 speakers, steadiest"
            case .lseend: return "Up to 10 speakers"
            }
        }
        var name: String {
            switch self {
            case .off: return ""
            case .sortformer: return "Sortformer"
            case .lseend: return "LS-EEND"
            }
        }
        var detail: String {
            switch self {
            case .off: return "Lines are labelled me or them only. Nothing to download."
            case .sortformer: return "Keeps each voice's identity best, and copes with noise."
            case .lseend: return "Handles bigger groups but can swap voices more often."
            }
        }
        var megabytes: Int { self == .sortformer ? 234 : self == .lseend ? 43 : 0 }
        var bytes: Int64 { Int64(megabytes) * 1_000_000 }
        static let models: [Speaker] = [.sortformer, .lseend]
    }

    // MARK: Chooser decisions

    /// Whether the welcome window shows "Choose your models". Only before a choice was made
    /// (`chosen`), and only when something wanted is missing: the speech model always; the speaker
    /// model too on a first run, with speakers on. Models already on disk (reinstall, upgrade)
    /// never bring the chooser back, and an existing user with the speech model sees no change.
    static func needsChooser(speechOnDisk: Bool, speakersWanted: Bool, speakerOnDisk: Bool, firstRun: Bool, chosen: Bool) -> Bool {
        guard !chosen else { return false }
        return !speechOnDisk || (firstRun && speakersWanted && !speakerOnDisk)
    }

    /// Bytes the Download button will fetch: whatever was picked and is not already on disk.
    static func bytesToDownload(speech: Speech, speaker: Speaker, speechOnDisk: Bool, speakerOnDisk: Bool) -> Int64 {
        (speechOnDisk ? 0 : speech.bytes) + (speaker == .off || speakerOnDisk ? 0 : speaker.bytes)
    }

    static func totalText(bytes: Int64) -> String {
        bytes == 0 ? "Everything you picked is already on this Mac"
            : "Downloads about \(sizeText(bytes)), stays on this Mac"
    }

    static func sizeText(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : "\(Int((Double(bytes) / 1e6).rounded())) MB"
    }

    // MARK: Models window rows

    enum RowAction: Equatable { case use, download, delete, cancel }

    /// Buttons a row gets. Delete only for a model that is not in use (it frees the disk space);
    /// a download in progress offers only Cancel (Pause/Resume live in the welcome window).
    static func rowActions(downloaded: Bool, busy: Bool, selected: Bool, active: Bool) -> [RowAction] {
        if busy { return [.cancel] }
        if !downloaded { return [.download] }
        if active { return [] }
        return selected ? [.delete] : [.use, .delete]
    }

    static func statusText(downloaded: Bool, bytes: Int64, state: ModelState?) -> String {
        switch state {
        case .downloading(let f)?: return f < 0 ? "Preparing…" : "Downloading \(Int(f * 100))%"
        case .paused(let f)?: return f < 0 ? "Download paused" : "Paused at \(Int(f * 100))%"
        case .failed?: return "Couldn't download"
        default: return downloaded ? "Downloaded · \(sizeText(bytes))" : "Not downloaded"
        }
    }

    static func isBusy(_ state: ModelState?) -> Bool {
        switch state {
        case .downloading?, .paused?: return true
        default: return false
        }
    }

    // MARK: Stored choices

    static func configuredSpeaker(_ defaults: UserDefaults = Prefs.store) -> Speaker {
        defaults.string(forKey: diarizerKey).flatMap(Speaker.init) ?? .sortformer
    }
    static func kind(_ s: Speaker) -> DiarizerKind? { s == .off ? nil : DiarizerKind(rawValue: s.rawValue) }
}

extension ModelStore {
    nonisolated static func isDownloaded(_ s: ModelCatalog.Speaker) -> Bool {
        ModelCatalog.kind(s).map { isDownloaded($0) } ?? true
    }
    nonisolated static func diskSize(_ s: ModelCatalog.Speaker) -> Int64 {
        ModelCatalog.kind(s).map { diskSize($0) } ?? 0
    }

    /// Removes a speech model's files. The Unified tiers share one repo folder, so only the files
    /// no other downloaded tier needs go; the folder goes when nothing else lives there.
    nonisolated static func delete(_ variant: StreamingModelVariant) throws {
        let dir = directory(for: variant), fm = FileManager.default
        let others = ModelCatalog.speech.map(\.variant).filter { $0 != variant && directory(for: $0) == dir && isDownloaded($0) }
        guard !others.isEmpty else {
            if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
            return
        }
        let keep = Set(others.flatMap { requiredFiles($0) })
        for name in requiredFiles(variant) where !keep.contains(name) {
            let url = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
    }

    nonisolated static func delete(_ kind: DiarizerKind) throws {
        let dir = directory(for: kind)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }

    /// Stops a speaker-model download, keeping the partial files for a resume.
    func pauseDiarizerDownload(_ kind: DiarizerKind) {
        Log.info(.model, "models: pausing download of \(kind.rawValue)")
        diarizerLoads[kind]?.cancel()
    }

    /// Stops it and deletes what was fetched.
    func cancelDiarizerDownload(_ kind: DiarizerKind) async {
        if let task = diarizerLoads[kind] {
            Log.info(.model, "models: cancelling download of \(kind.rawValue)")
            task.cancel()
            _ = try? await task.value
        }
        try? Self.delete(kind)
    }
}
