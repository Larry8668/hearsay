import AppKit
import SwiftUI

/// Observable snapshot of app state for the SwiftUI views (live panel, welcome window).
/// SessionController writes it; AppDelegate supplies `actions`; views never touch the session.
final class AppModel: ObservableObject {
    enum Phase: Equatable { case idle, starting, listening, paused, stopping }

    @Published var phase: Phase = .idle
    @Published var startedAt: Date?
    /// Total length of the session's finished pauses, and when the current pause began (nil while
    /// not paused). Together they give the listening time the recording bar shows.
    @Published var pausedTotal: TimeInterval = 0
    @Published var pausedAt: Date?
    /// Live input levels. A separate object so 30 Hz updates don't re-render every AppModel view.
    let audio = AudioLevels()
    /// Smoothed level per lane, 0…1 (−60…−10 dBFS), updated ≤30×/s while listening.
    var levels: [Speaker: Float] { audio.levels }
    /// Mirrors the live panel's visibility (the recording bar's transcript button shows it).
    @Published var panelVisible = false
    @Published var showRecordingBar: Bool = UserDefaults.standard.object(forKey: AppModel.barKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showRecordingBar, forKey: Self.barKey) }
    }
    @Published var expandBarOnHover: Bool = UserDefaults.standard.object(forKey: AppModel.barHoverKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(expandBarOnHover, forKey: Self.barHoverKey) }
    }
    /// Committed lines of the current (or last) session, sorted by start time.
    @Published var lines: [TranscriptLine] = []
    /// In-progress text per speaker; cleared when that speaker's final arrives.
    @Published var partials: [Speaker: String] = [:]
    @Published var modelState: ModelState = .notDownloaded
    @Published var engineID = ""
    /// Last engine/source warning, cleared after a while.
    @Published var warning: String?
    /// Sources that failed with `permissionDenied` on the last start.
    @Published var permissionDenied: Set<Speaker> = []
    @Published var micAuthorized = false
    @Published var fontSize: Double = AppModel.storedFontSize { didSet { UserDefaults.standard.set(fontSize, forKey: Self.fontKey) } }
    @Published var pinned: Bool = UserDefaults.standard.object(forKey: AppModel.pinKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(pinned, forKey: Self.pinKey) }
    }

    struct Actions {
        var toggleListening: () -> Void = {}
        var copyAll: () -> Void = {}
        var requestMic: () -> Void = {}
        var openTranscript: () -> Void = {}
        var closeWelcome: () -> Void = {}
        var exportSRT: () -> Void = {}
        var revealInFinder: () -> Void = {}
    }
    var actions = Actions()

    static let fontKey = "panelFontSize", pinKey = "panelPinned"
    static let barKey = "recordingBarShown", barHoverKey = "recordingBarExpandOnHover"
    static let fontRange: ClosedRange<Double> = 10...28
    static let fontChoices: [(Double, String)] = [(12, "Small"), (14.5, "Medium"), (17, "Large"), (21, "Extra large")]
    private static var storedFontSize: Double {
        let v = UserDefaults.standard.double(forKey: fontKey)
        return v == 0 ? 14.5 : min(max(v, fontRange.lowerBound), fontRange.upperBound)
    }

    func bumpFont(_ delta: Double) {
        fontSize = min(max(fontSize + delta, Self.fontRange.lowerBound), Self.fontRange.upperBound)
    }

    var isListening: Bool { phase == .listening || phase == .starting }
    /// A session exists: listening, starting or paused (Stop applies, the recording bar shows).
    var isActive: Bool { isListening || phase == .paused }

    /// Time spent actually listening: since start, minus pauses.
    func listeningTime(now: Date = Date()) -> TimeInterval {
        guard let start = startedAt else { return 0 }
        let paused = pausedTotal + (pausedAt.map { now.timeIntervalSince($0) } ?? 0)
        return max(0, now.timeIntervalSince(start) - paused)
    }

    /// The menu's status line: "Not listening" / "Listening · 12 min · 48 lines" / "Downloading model 43%".
    func statusLine(now: Date = Date()) -> String {
        switch modelState {
        case .downloading(let f):
            let what = f < 0 ? "Preparing speech model…" : "Downloading model \(Int(f * 100))%"
            return phase == .starting ? what + " · will start when ready" : what
        case .failed: return "Speech model unavailable"
        default: break
        }
        switch phase {
        case .idle: return "Not listening"
        case .starting: return "Starting…"
        case .stopping: return "Saving transcript…"
        case .listening, .paused:
            let mins = Int(listeningTime(now: now) / 60)
            return "\(phase == .paused ? "Paused" : "Listening") · \(mins) min · \(lines.count) line\(lines.count == 1 ? "" : "s")"
        }
    }

    /// Inserts keeping start-time order (same rule as TranscriptStore).
    func insert(_ line: TranscriptLine) {
        lines.insert(line, at: TranscriptStore.insertionIndex(for: line.start, in: lines))
        partials[line.speaker] = nil
    }
}
