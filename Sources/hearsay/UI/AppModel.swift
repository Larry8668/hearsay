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
    /// True while the main window is showing the live transcript (the recording bar's transcript
    /// button shows a filled icon then, and toggles the window).
    @Published var panelVisible = false
    /// Voices turned off in the live view's speaker chips: their lines and partials are hidden
    /// from the window and from its Copy / Export SRT. The files on disk always get every line.
    /// Reset when a session starts.
    @Published var hiddenVoices: Set<Voice> = []
    @Published var showRecordingBar: Bool = UserDefaults.standard.object(forKey: AppModel.barKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showRecordingBar, forKey: Self.barKey) }
    }
    /// The recording bar's shape: the full bar with captions, or a small pill with just the
    /// controls that can sit anywhere (its spot is remembered separately).
    enum BarMode: String, CaseIterable {
        case full, pill
        var title: String { self == .full ? "Full bar with captions" : "Small pill" }
    }
    @Published var barMode: BarMode = BarMode(rawValue: UserDefaults.standard.string(forKey: AppModel.barModeKey) ?? "") ?? .full {
        didSet { UserDefaults.standard.set(barMode.rawValue, forKey: Self.barModeKey) }
    }
    /// Committed lines of the current (or last) session, sorted by start time.
    @Published var lines: [TranscriptLine] = []
    /// In-progress text per voice (speaker, and app for "them"); cleared when that voice's final arrives.
    @Published var partials: [Voice: String] = [:]
    @Published var modelState: ModelState = .notDownloaded
    @Published var engineID = ""
    /// Last engine/source warning, cleared after a while.
    @Published var warning: String?
    /// Sources that failed with `permissionDenied` on the last start.
    @Published var permissionDenied: Set<Speaker> = []
    @Published var micAuthorized = false
    @Published var fontSize: Double = AppModel.storedFontSize { didSet { UserDefaults.standard.set(fontSize, forKey: Self.fontKey) } }

    /// What the windows can ask of the session. `copyAll` / `exportSRT` take the voices the view
    /// is hiding, so the clipboard and the .srt match what is on screen.
    struct Actions {
        var toggleListening: () -> Void = {}
        var togglePause: () -> Void = {}
        var stop: () -> Void = {}
        var copyAll: (Set<Voice>) -> Void = { _ in }
        var requestMic: () -> Void = {}
        var openTranscript: () -> Void = {}
        var closeWelcome: () -> Void = {}
        var exportSRT: (Set<Voice>) -> Void = { _ in }
        var revealInFinder: () -> Void = {}
        var pauseDownload: () -> Void = {}
        var resumeDownload: () -> Void = {}
        var cancelDownload: () -> Void = {}
    }
    var actions = Actions()

    static let fontKey = "panelFontSize"
    static let barKey = "recordingBarShown", barModeKey = "recordingBarMode"
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
        case .paused(let f): return "Model download paused\(f >= 0 ? " at \(Int(f * 100))%" : "") · Start listening resumes it"
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
        clearPartial(for: line)
    }

    /// Drops the in-progress text the line replaces: its voice, and for "them" also the entry
    /// that had no app yet (the app is a running vote, so a partial can precede its label).
    func clearPartial(for line: TranscriptLine) {
        partials[Voice(line)] = nil
        if line.speaker == .them { partials[Voice(speaker: .them)] = nil }
    }

    func clearPartials(_ speaker: Speaker) {
        for v in partials.keys where v.speaker == speaker { partials[v] = nil }
    }

    /// Per voice, how many times its in-progress text was thrown away (a "me" line that was an
    /// echo of the speakers). The captions keep a block's last words through a gap in the
    /// hypothesis, but not through this: the words were never said by that speaker.
    @Published private(set) var discards: [Voice: Int] = [:]
    func discardPartial(_ v: Voice) {
        partials[v] = nil
        discards[v, default: 0] += 1
    }
}
