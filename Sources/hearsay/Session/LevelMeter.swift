import Foundation

/// Thread-safe "latest level per lane", written by the lanes' feed tasks at audio rate.
///
/// The feed task runs off the main actor and sees every chunk (10–20 per second per lane), so it
/// only stores a number here; `AudioLevels` reads it from a 20 Hz main-thread timer. That decouples
/// publishing from chunk rate (at most 20 UI updates/s however chunks arrive) and gives a clock to
/// decay an idle lane: the system tap delivers NOTHING while no app plays, so without one the last
/// value would freeze on screen.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [Speaker: (level: Float, at: TimeInterval)] = [:]

    /// One pass over the chunk (≤3200 floats at 16 kHz); cheap next to the engine's work.
    func report(_ speaker: Speaker, samples: [Float]) {
        let l = LevelMeter.level(rms: LevelMeter.rms(samples))
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); latest[speaker] = (l, now); lock.unlock()
    }

    /// Latest level and when it was reported (system uptime), per lane that reported.
    func snapshot() -> [Speaker: (level: Float, at: TimeInterval)] {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func clear() { lock.lock(); latest = [:]; lock.unlock() }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for x in samples { sum += x * x }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// dBFS mapped linearly from −60…−10 to 0…1. −60 is below a quiet room through a laptop mic;
    /// −10 is loud speech close to it, so normal talking lands mid-scale instead of pegging the top.
    static func level(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 60) / 50))
    }
}

/// Smoothed levels + a short history for the recording bar's waveform. Lives on AppModel but as
/// its own ObservableObject, so the 20 Hz updates re-render only the waveform, not every view that
/// observes AppModel (the live panel with hundreds of lines).
///
/// Main thread only.
final class AudioLevels: ObservableObject {
    struct Frame: Equatable { var me: Float = 0; var them: Float = 0 }

    static let barCount = 36
    /// Smoothed level per lane, 0…1, updated ≤20×/s.
    @Published private(set) var levels: [Speaker: Float] = [:]
    /// Oldest first; the last frame is the live one (it follows the level every tick and is
    /// committed every second tick, so 36 bars cover ≈2.4 s).
    @Published private(set) var history = Array(repeating: Frame(), count: AudioLevels.barCount)

    let meter = LevelMeter()
    private var timer: Timer?
    private var tickCount = 0
    var isRunning: Bool { timer != nil }

    /// Starts ticking (listening). Idempotent.
    func run() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // keep moving while a menu is open
        timer = t
    }

    /// Stops ticking but keeps the picture (paused: the bar shows the frozen, dimmed waveform).
    func freeze() { timer?.invalidate(); timer = nil; meter.clear() }

    /// Stops and flattens (session ended).
    func reset() {
        freeze()
        levels = [:]
        history = Array(repeating: Frame(), count: Self.barCount)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let raw = meter.snapshot()
        var next = levels
        for s in Speaker.allCases {
            // A lane that hasn't reported for 120 ms is idle: target 0. Fast attack, slower release;
            // release 0.3/frame leaves ~4% after 9 frames, i.e. flat within ~300 ms.
            let target: Float = raw[s].map { now - $0.at < 0.12 ? $0.level : 0 } ?? 0
            let cur = levels[s] ?? 0
            let v = cur + (target - cur) * (target > cur ? 0.6 : 0.3)
            next[s] = v < 0.005 ? 0 : v
        }
        if next != levels { levels = next }
        var h = history
        let frame = Frame(me: next[.me] ?? 0, them: next[.them] ?? 0)
        tickCount += 1
        if tickCount % 2 == 0 { h.removeFirst(); h.append(frame) } else { h[h.count - 1] = frame }
        if h != history { history = h }
    }
}
