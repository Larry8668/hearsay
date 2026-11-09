import AVFoundation
import Foundation

/// Converts device-native PCM (any rate, any channel count, Float32 interleaved or not) to the
/// engines' format: 16 kHz mono Float32.
///
/// Mixdown is done by hand (plain average of channels) and only the mono resample goes through
/// AVAudioConverter. WHY: AVAudioConverter refuses or silently picks channel 0 for channel counts
/// without a layout (voice-processing inputs report 3–9 channels on some Macs, aggregate taps
/// report whatever the tap was built with); averaging works for every count.
///
/// Stateful: the resampler keeps filter history between calls so consecutive buffers join without
/// clicks. Not thread-safe; call from one serial queue. Create a new one when the input format changes.
final class Resampler16k {
    static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioChunk.sampleRate,
                                            channels: 1, interleaved: false)!
    let inputFormat: AVAudioFormat
    private let monoFormat: AVAudioFormat
    private let converter: AVAudioConverter?   // nil when the input is already 16 kHz
    private var warnedUnsupported = false

    init?(inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                                       channels: 1, interleaved: false) else { return nil }
        self.inputFormat = inputFormat
        self.monoFormat = mono
        if inputFormat.sampleRate == AudioChunk.sampleRate {
            converter = nil
        } else {
            guard let c = AVAudioConverter(from: mono, to: Resampler16k.outputFormat) else { return nil }
            c.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter = c
        }
    }

    /// Converts one buffer; returns the 16 kHz samples it produced (may be a few samples more or
    /// less than the exact ratio because the resampler has a small internal delay).
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let mono = mixdown(buffer) else { return [] }
        guard let converter else { return Array(UnsafeBufferPointer(start: mono.floatChannelData![0], count: Int(mono.frameLength))) }
        return resample(mono, converter: converter, endOfStream: false)
    }

    /// Drains the resampler's tail at end of stream (otherwise the last ~1 ms is lost).
    func flush() -> [Float] {
        guard let converter, let empty = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 1) else { return [] }
        let out = resample(empty, converter: converter, endOfStream: true)
        converter.reset()
        return out
    }

    private func mixdown(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        guard buffer.format.commonFormat == .pcmFormatFloat32, let src = buffer.floatChannelData else {
            if !warnedUnsupported { warnedUnsupported = true; Log.warn("audio: unsupported sample format \(buffer.format); dropping audio") }
            return nil
        }
        let channels = Int(buffer.format.channelCount)
        let dst = mono.floatChannelData![0]
        let scale = 1 / Float(channels)
        if buffer.format.isInterleaved {
            // Interleaved: only channel pointer 0 is valid; frames are `stride` floats apart.
            let p = src[0], stride = buffer.stride
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += p[f * stride + c] }
                dst[f] = sum * scale
            }
        } else {
            for f in 0..<frames { dst[f] = src[0][f] }
            if channels > 1 {
                for c in 1..<channels { let p = src[c]; for f in 0..<frames { dst[f] += p[f] } }
                for f in 0..<frames { dst[f] *= scale }
            }
        }
        mono.frameLength = AVAudioFrameCount(frames)
        return mono
    }

    private func resample(_ mono: AVAudioPCMBuffer, converter: AVAudioConverter, endOfStream: Bool) -> [Float] {
        let ratio = AudioChunk.sampleRate / monoFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(mono.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Resampler16k.outputFormat, frameCapacity: capacity) else { return [] }
        var supplied = endOfStream
        var error: NSError?
        // `.noDataNow` (not `.endOfStream`) between buffers: end-of-stream would flush the filter
        // and force a reset, putting a discontinuity at every buffer boundary.
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = endOfStream ? .endOfStream : .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return mono
        }
        if status == .error {
            Log.warn("audio: resample failed: \(error?.localizedDescription ?? "unknown")")
            return []
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}

/// Slices a continuous 16 kHz sample stream into fixed-size `AudioChunk`s with wall-clock times.
///
/// Timestamps come from a single anchor (the host time of the first buffer) plus a running sample
/// count, NOT from each buffer's own host time: per-buffer host times jitter by a millisecond or
/// two, which would make chunks overlap or leave gaps. We only re-anchor when the device clock has
/// run ahead of our count by more than `gapTolerance` (a real gap: device switch, IO overload),
/// and never backwards, so start times stay monotonic.
final class ChunkAssembler {
    let speaker: Speaker
    let chunkSamples: Int
    var gapTolerance: TimeInterval = 0.25
    private var pending: [Float] = []
    private var anchor: Date?
    private var emitted = 0          // samples emitted (or pending) since `anchor`

    init(speaker: Speaker, chunkDuration: TimeInterval = 0.1) {
        self.speaker = speaker
        self.chunkSamples = Int(AudioChunk.sampleRate * chunkDuration)
    }

    /// `startTime` = wall-clock time of the first input frame that produced `samples`.
    func append(_ samples: [Float], startTime: Date?, sourceApps: [String] = []) -> [AudioChunk] {
        var out: [AudioChunk] = []
        let counted = emitted + pending.count
        if let startTime {
            if let anchor {
                let expected = anchor.addingTimeInterval(Double(counted) / AudioChunk.sampleRate)
                let drift = startTime.timeIntervalSince(expected)
                if drift > gapTolerance {
                    Log.info("audio[\(speaker.rawValue)]: \(String(format: "%.0f", drift * 1000)) ms gap in device clock; re-anchoring")
                    if !pending.isEmpty { out.append(makeChunk(pending, offset: emitted, apps: sourceApps)) }
                    pending.removeAll(keepingCapacity: true)
                    self.anchor = startTime; emitted = 0
                }
            } else {
                anchor = startTime.addingTimeInterval(-Double(counted) / AudioChunk.sampleRate)
            }
        } else if anchor == nil {
            anchor = Date()
        }
        pending.append(contentsOf: samples)
        while pending.count >= chunkSamples {
            out.append(makeChunk(Array(pending.prefix(chunkSamples)), offset: emitted, apps: sourceApps))
            pending.removeFirst(chunkSamples)
            emitted += chunkSamples
        }
        return out
    }

    /// Emits whatever is pending as a final short chunk.
    func flush(sourceApps: [String] = []) -> AudioChunk? {
        guard !pending.isEmpty, anchor != nil else { return nil }
        let c = makeChunk(pending, offset: emitted, apps: sourceApps)
        emitted += pending.count
        pending.removeAll()
        return c
    }

    private func makeChunk(_ samples: [Float], offset: Int, apps: [String]) -> AudioChunk {
        let start = (anchor ?? Date()).addingTimeInterval(Double(offset) / AudioChunk.sampleRate)
        return AudioChunk(samples: samples, startTime: start, speaker: speaker, sourceApps: apps)
    }
}
