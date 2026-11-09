import AVFoundation
import CoreAudio
import Foundation

/// Keeps a stopped voice-processing engine around after a session ends, so releasing it does not
/// stutter whatever is playing.
///
/// Measured (docs/PERFORMANCE.md, "Audio glitches"): starting a VPIO engine stops the output
/// device's IO twice for ~0.5 s, and so does *releasing* one (disposing the unit), while
/// `engine.stop()` alone is silent, and restarting a parked engine is silent too. A video playing
/// while you pressed Stop froze twice. So on stop MicCapture parks its stopped engine here and the
/// next session on the same devices reuses it (Start without the stall). It is released once it
/// has been parked for `keep` AND the output is idle (nobody playing: the reconfiguration is
/// inaudible), or when the output device changes. A stopped engine does not hold the microphone
/// (the input device stops running; no recording indicator).
enum VoiceProcessingPark {
    private struct Parked { let engine: AVAudioEngine; let input: AudioDeviceID; let output: AudioDeviceID; let since: Date }
    static let keep: TimeInterval = 600
    private static let queue = DispatchQueue(label: "hearsay.vp-park", qos: .utility)
    private nonisolated(unsafe) static var parked: Parked?
    private nonisolated(unsafe) static var timer: DispatchSourceTimer?

    /// Takes ownership of a stopped engine with voice processing enabled (tap already removed).
    static func park(_ engine: AVAudioEngine, input: AudioDeviceID) {
        let output = CA.defaultOutputDevice
        queue.async {
            releaseLocked(reason: "replaced")
            parked = Parked(engine: engine, input: input, output: output, since: Date())
            Log.info("mic: voice processing parked for reuse (releasing it now would stutter playback)")
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
            t.setEventHandler {
                guard let p = parked else { return }
                if CA.defaultOutputDevice != p.output { releaseLocked(reason: "output device changed") }
                else if Date().timeIntervalSince(p.since) >= keep, !outputBusy(p.output) { releaseLocked(reason: "unused, output idle") }
            }
            t.resume()
            timer = t
        }
    }

    /// The parked engine if it was built for these devices; otherwise releases it and returns nil.
    static func take(input: AudioDeviceID) -> AVAudioEngine? {
        queue.sync {
            guard let p = parked else { return nil }
            if p.input == input, p.output == CA.defaultOutputDevice {
                parked = nil
                timer?.cancel(); timer = nil
                return p.engine
            }
            releaseLocked(reason: "devices changed")
            return nil
        }
    }

    private static func releaseLocked(reason: String) {
        timer?.cancel(); timer = nil
        guard parked != nil else { return }
        parked = nil   // the engine deinit disposes the voice-processing unit
        Log.info("mic: voice processing released (\(reason))")
    }

    /// Some process is doing IO on the device (playing, or holding the output open).
    private static func outputBusy(_ device: AudioDeviceID) -> Bool {
        ((try? CA.get(device, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: UInt32(0))) ?? 0) != 0
    }
}
