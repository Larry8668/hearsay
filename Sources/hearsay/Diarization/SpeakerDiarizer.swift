import CoreML
import FluidAudio
import Foundation

/// Which FluidAudio streaming diarizer tells speakers apart: Settings ▸ Tell speakers apart ▸
/// Model, stored under `diarizer` in `Prefs.store` (the first-run model chooser writes the same
/// key). `defaults write dev.hearsay.app diarizer lseend-ami` reaches the variant the menu does
/// not offer. See `SpeakerDiarizer` for the comparison.
enum DiarizerKind: String, CaseIterable, Sendable {
    /// NVIDIA Streaming Sortformer v2.1 (fast tier): 4 slots, stable identities, robust to noise.
    case sortformer
    /// LS-EEND trained on DIHARD III (podcasts, field recordings): up to 10 speakers, 100 ms steps.
    case lseend
    /// LS-EEND trained on AMI (meeting rooms, distant mics): up to 4 speakers.
    case lseendAmi = "lseend-ami"

    static let `default`: DiarizerKind = .sortformer
    static let key = "diarizer"
    /// The choices the menu and the model chooser offer; `lseendAmi` stays a defaults-only experiment.
    static let offered: [DiarizerKind] = [.sortformer, .lseend]

    static func configured(_ defaults: UserDefaults = Prefs.store) -> DiarizerKind {
        guard let raw = defaults.string(forKey: key) else { return .default }
        guard let k = DiarizerKind(rawValue: raw) else {
            Log.warn(.diarize, "diarizer: unknown diarizer '\(raw)', using \(DiarizerKind.default.rawValue)")
            return .default
        }
        return k
    }

    /// The stored choice. Setting it only persists: `SessionController.setDiarizer` also swaps
    /// the loaded model (or queues the swap for the next session).
    static var current: DiarizerKind {
        get { configured() }
        set { Prefs.store.set(newValue.rawValue, forKey: key) }
    }

    /// The model's name: "Sortformer", "LS-EEND".
    var displayName: String {
        switch self {
        case .sortformer: return "Sortformer"
        case .lseend: return "LS-EEND"
        case .lseendAmi: return "LS-EEND (AMI)"
        }
    }

    /// What choosing it means, in people's terms: "Steady, up to 4 speakers".
    var summary: String {
        switch self {
        case .sortformer: return "Steady, up to 4 speakers"
        case .lseend: return "More speakers, up to 10"
        case .lseendAmi: return "Meeting rooms, up to 4 speakers"
        }
    }

    /// Voices one stream can tell apart; a further voice is merged into the closest slot.
    var maxSpeakers: Int { self == .lseend ? 10 : 4 }

    /// Approximate download (the compiled models on disk), in bytes.
    var downloadSize: Int64 {
        switch self {
        case .sortformer: return 234 << 20
        case .lseend, .lseendAmi: return 43 << 20
        }
    }

    /// "Steady, up to 4 speakers (Sortformer, 234 MB)": the menu item.
    var menuTitle: String { "\(summary) (\(displayName), \(downloadSize >> 20) MB)" }

    /// Complete on disk: choosing it needs no download.
    var isDownloaded: Bool { ModelStore.isDownloaded(self) }

    var sortformerConfig: SortformerConfig { .fastV2_1 }
    var lseendVariant: LSEENDVariant { self == .lseendAmi ? .ami : .dihard3 }
    var lseendStep: LSEENDStepSize { .step100ms }
}

/// One stretch of a lane's audio (sample indices in the lane's own clock, 16 kHz) during which
/// one diarizer slot was the active speaker. `tentative` runs are the model's look-ahead and are
/// replaced on the next update; finalized runs never change.
struct SpeakerRun: Equatable, Sendable {
    var start: Int
    var end: Int
    var speaker: Int
}

/// Frames newly decided by the diarizer, already mapped onto the lane's sample clock.
struct SpeakerFrames: Sendable {
    var finalized: [SpeakerRun]
    var tentative: [SpeakerRun]
}

/// A streaming speaker diarizer for ONE audio stream (a lane, or one app's stream of a lane):
/// fed the same 16 kHz chunks as the speech model, it says which of its speaker slots is
/// talking when. Slots are stable for the life of the instance, so an instance lives for a whole
/// session (pause/resume keep it; a new transcript gets a fresh one). Not thread-safe: the
/// engine's worker task owns it.
protocol SpeakerDiarizer: AnyObject, Sendable {
    var kind: DiarizerKind { get }
    /// Number of speaker slots the model can tell apart (4 for Sortformer).
    var slots: Int { get }
    /// Samples fed to the model so far (the model's own clock; skipped silence is not in it).
    var modelSamples: Int { get }
    /// Feeds audio that starts at `laneSample` of the lane's clock. Returns the frames the model
    /// decided on, or nil while it is still buffering (Sortformer decides every 480 ms).
    func feed(_ samples: [Float], laneSample: Int) throws -> SpeakerFrames?
    /// Warms the model with a known voice before live audio; returns the slot it took, or nil
    /// when the model could not tell it apart from a slot already taken.
    func enrol(_ samples: [Float]) throws -> Int?
}

/// `SpeakerDiarizer` over FluidAudio's `Diarizer` protocol (Sortformer and LS-EEND both conform).
///
/// The model counts frames from the first sample it was given; the lane counts every captured
/// sample, including the silence we never feed (silence costs the model as much as speech, see
/// `ParakeetEngine`). `anchors` map one clock to the other the way `SampleClock` maps samples
/// to dates: an anchor is recorded whenever feeding resumes after a skip.
final class FluidDiarizer: SpeakerDiarizer, @unchecked Sendable {
    let kind: DiarizerKind
    let slots: Int
    private let model: any Diarizer
    /// Seconds per output frame (0.08 Sortformer, 0.1 LS-EEND) in lane samples.
    private let frameSamples: Int
    private(set) var modelSamples = 0
    private var anchors: [(model: Int, lane: Int)] = []
    /// Frames before this model sample were decided for a lane clock that no longer exists.
    private var ignoreBefore = 0
    /// A frame is "speaker s" when s's probability is the highest and at least this. Below it
    /// the frame is silence (or a background voice the model was trained to ignore).
    private let onset: Float = 0.5

    init(kind: DiarizerKind, model: any Diarizer) {
        self.kind = kind
        self.model = model
        slots = model.numSpeakers ?? 4
        let hz = model.modelFrameHz ?? 12.5
        frameSamples = Int((AudioChunk.sampleRate / hz).rounded())
    }

    func feed(_ samples: [Float], laneSample: Int) throws -> SpeakerFrames? {
        guard !samples.isEmpty else { return nil }
        if let last = anchors.last, last.lane + (modelSamples - last.model) == laneSample {
            // contiguous with the previous feed: the last anchor still holds
        } else {
            if let last = anchors.last, laneSample < last.lane + (modelSamples - last.model) {
                // The lane's clock restarted (resume, a per-app stream reopened): frames still in
                // the model's look-ahead belong to the old clock and must not reach the new tracker.
                anchors = []
                ignoreBefore = modelSamples
            }
            anchors.append((modelSamples, laneSample))
        }
        modelSamples += samples.count
        // Always state the rate: LS-EEND wants 8 kHz and resamples, Sortformer takes 16 kHz as is.
        guard let update = try model.process(samples: samples, sourceSampleRate: AudioChunk.sampleRate) else { return nil }
        let r = update.chunkResult
        let finalized = runs(from: r.finalizedPredictions, frames: r.finalizedFrameCount, firstFrame: r.startFrame)
        let tentative = runs(from: r.tentativePredictions, frames: r.tentativeFrameCount, firstFrame: r.tentativeStartFrame)
        // Anchors before the oldest frame that can still be asked about are dead weight.
        let oldest = laneSampleOf(modelSample: r.startFrame * frameSamples)
        if let i = anchors.lastIndex(where: { $0.lane <= oldest }), i > 0 { anchors.removeFirst(i) }
        return SpeakerFrames(finalized: finalized, tentative: tentative)
    }

    func enrol(_ samples: [Float]) throws -> Int? {
        // Enrolment runs the clip through the model and then resets its frame counter and
        // timeline, so the live stream still starts at frame 0; our own clocks must match.
        let speaker = try model.enrollSpeaker(withAudio: samples, sourceSampleRate: AudioChunk.sampleRate, named: "me",
                                              overwritingAssignedSpeakerName: true)
        modelSamples = 0
        anchors = []
        return speaker?.index
    }

    /// Row-major `[frames × slots]` probabilities → runs of the dominant slot, in lane samples.
    /// Consecutive frames with the same winner merge; silent frames end a run.
    private func runs(from probs: [Float], frames: Int, firstFrame: Int) -> [SpeakerRun] {
        guard frames > 0, probs.count >= frames * slots else { return [] }
        var out: [SpeakerRun] = []
        for f in 0..<frames where (firstFrame + f) * frameSamples >= ignoreBefore {
            var best = -1, bestP = onset
            for s in 0..<slots where probs[f * slots + s] >= bestP { best = s; bestP = probs[f * slots + s] }
            guard best >= 0 else { continue }
            let start = laneSampleOf(modelSample: (firstFrame + f) * frameSamples)
            let end = laneSampleOf(modelSample: (firstFrame + f + 1) * frameSamples)
            if var last = out.last, last.speaker == best, last.end == start {
                last.end = end
                out[out.count - 1] = last
            } else {
                out.append(SpeakerRun(start: start, end: end, speaker: best))
            }
        }
        return out
    }

    private func laneSampleOf(modelSample: Int) -> Int {
        guard let first = anchors.first else { return modelSample }
        var lo = 0, hi = anchors.count - 1
        if modelSample < first.model { return first.lane + (modelSample - first.model) }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if anchors[mid].model <= modelSample { lo = mid } else { hi = mid - 1 }
        }
        return anchors[lo].lane + (modelSample - anchors[lo].model)
    }
}
