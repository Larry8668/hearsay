import Foundation

/// Settings ▸ Tell speakers apart. Persisted under `diarization`; `microphone` is the default:
/// the common case is a meeting room with several people around one MacBook, while a call's
/// other side is usually one person per app.
enum DiarizationMode: String, CaseIterable, Sendable {
    case off, microphone, all

    static let key = "diarization"
    static var current: DiarizationMode {
        get { Prefs.store.string(forKey: key).flatMap(DiarizationMode.init) ?? .microphone }
        set { Prefs.store.set(newValue.rawValue, forKey: key) }
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .microphone: return "Microphone only"
        case .all: return "All sources"
        }
    }

    func covers(_ s: Speaker) -> Bool {
        switch self {
        case .off: return false
        case .microphone: return s == .me
        case .all: return true
        }
    }
}

/// Hands each audio stream its diarizer for the current session, and owns the loaded weights.
///
/// Streams are keyed like speaker ids ("me", "them", "them:us.zoom.xos"): one instance per key
/// per session, so a per-app stream that closes after 20 s of silence and reopens gets the same
/// slots back, and pause/resume keeps them too. `beginSession` forgets them: a new transcript
/// starts with fresh "Speaker 1". Nothing is loaded while the mode is Off.
///
/// The user's enrolled voice (`Enrolment`) is played into every new microphone-lane instance
/// first, so the slot it takes can be labelled "me" in the transcript.
actor DiarizerRegistry {
    static let shared = DiarizerRegistry()

    private(set) var mode = DiarizationMode.current
    private(set) var kind = DiarizerKind.configured()
    private var weights: DiarizerWeights?
    private var instances: [String: FluidDiarizer] = [:]
    /// Stream key → speaker id of the enrolled voice.
    private var enrolled: [String: String] = [:]
    /// Enrolment clip for this session (read once per session; nil = none).
    private var clip: [Float]?
    private var clipLoaded = false
    /// CLI / tests (`configure`): used instead of the stored clip, nil meaning none at all.
    private var overrideClip: [Float]?
    private var configured = false

    var isReady: Bool { weights != nil }

    func setMode(_ m: DiarizationMode) { mode = m }

    /// Overrides the UserDefaults choices and the stored enrolment clip (CLI, tests).
    func configure(mode: DiarizationMode, kind: DiarizerKind? = nil, clip: [Float]? = nil) {
        self.mode = mode
        if let kind, kind != self.kind { self.kind = kind; weights = nil; instances = [:] }
        overrideClip = clip
        configured = true
    }

    /// Downloads (once) and loads the weights unless the mode is Off. Progress goes to the menu's
    /// status line through `ModelState`.
    func prepare(progress: @escaping @Sendable (ModelState) -> Void) async throws {
        guard mode != .off else { return }
        if weights != nil { progress(.ready); return }
        weights = try await ModelStore.shared.loadDiarizer(kind, progress: progress)
    }

    /// Releases the weights (Off with no session running): zero cost while off.
    func unload() {
        guard instances.isEmpty else { return }
        weights = nil
    }

    func beginSession() {
        instances = [:]
        enrolled = [:]
        clipLoaded = false
    }

    func endSession() {
        instances = [:]
        if mode == .off { weights = nil }
    }

    /// The stream's diarizer for this session, created on first use; nil when speakers are not
    /// told apart on this lane or the weights are not loaded (yet).
    func diarizer(for lane: Speaker, stream: String) -> SpeakerDiarizer? {
        guard mode.covers(lane), let weights else { return nil }
        if let d = instances[stream] { return d }
        do {
            let d = try ModelStore.makeDiarizer(kind, weights: weights)
            instances[stream] = d
            if lane == .me, let clip = enrolmentClip() {
                if let slot = try d.enrol(clip) {
                    enrolled[stream] = SpeakerID.make(stream: stream, slot: slot)
                    Log.info("diarizer: \(stream): enrolled voice took slot \(slot + 1)")
                } else {
                    Log.warn("diarizer: \(stream): enrolment clip was not recognised as a speaker")
                }
            }
            Log.info("diarizer: \(kind.rawValue) started for \(stream)")
            return d
        } catch {
            Log.error("diarizer: could not start for \(stream): \(error.localizedDescription)")
            return nil
        }
    }

    /// Speaker ids that are the user's enrolled voice, by stream.
    func enrolledIDs() -> [String: String] { enrolled }

    private func enrolmentClip() -> [Float]? {
        if configured { return overrideClip }
        if !clipLoaded { clip = Enrolment.load(); clipLoaded = true }
        return clip
    }
}
