import AVFoundation
import XCTest
@testable import hearsay

final class AudioConversionTests: XCTestCase {
    /// 1 s of a 48 kHz stereo sine, fed in 10 ms buffers like a device would.
    private func feedSine(interleaved: Bool, frequency: Double = 440, seconds: Double = 1) -> [Float] {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved)!
        let rs = Resampler16k(inputFormat: format)!
        let total = Int(48_000 * seconds), block = 480
        var out: [Float] = []
        var n = 0
        while n < total {
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block))!
            buf.frameLength = AVAudioFrameCount(block)
            for f in 0..<block {
                let v = Float(0.5 * sin(2 * .pi * frequency * Double(n + f) / 48_000))
                if interleaved {
                    buf.floatChannelData![0][2 * f] = v; buf.floatChannelData![0][2 * f + 1] = v
                } else {
                    buf.floatChannelData![0][f] = v; buf.floatChannelData![1][f] = v
                }
            }
            out += rs.convert(buf)
            n += block
        }
        return out + rs.flush()
    }

    private func zeroCrossingFrequency(_ s: [Float]) -> Double {
        let body = s.dropFirst(200).dropLast(200)   // skip resampler warm-up / tail
        var crossings = 0
        var prev = body.first ?? 0
        for v in body.dropFirst() { if (prev < 0) != (v < 0) { crossings += 1 }; prev = v }
        return Double(crossings) / 2 / (Double(body.count) / 16_000)
    }

    func testStereo48kSineBecomes16kMono() {
        for interleaved in [false, true] {
            let out = feedSine(interleaved: interleaved)
            XCTAssertEqual(Double(out.count), 16_000, accuracy: 64, "interleaved=\(interleaved)")
            XCTAssertEqual(zeroCrossingFrequency(out), 440, accuracy: 3, "interleaved=\(interleaved)")
            let peak = out.dropFirst(200).map(abs).max() ?? 0
            XCTAssertEqual(Double(peak), 0.5, accuracy: 0.05, "mixdown of identical channels keeps amplitude")
        }
    }

    func testOppositeChannelsCancel() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: false)!
        let rs = Resampler16k(inputFormat: format)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
        buf.frameLength = 100
        for f in 0..<100 { buf.floatChannelData![0][f] = 0.3; buf.floatChannelData![1][f] = -0.3 }
        let out = rs.convert(buf)
        XCTAssertEqual(out.count, 100)   // 16 kHz input passes through without resampling
        XCTAssertTrue(out.allSatisfy { abs($0) < 1e-6 })
    }

    func testChunksAreGaplessDespiteJitter() {
        let a = ChunkAssembler(speaker: .them)
        let t0 = Date()
        var chunks: [AudioChunk] = []
        for i in 0..<50 {
            let jitter = Double(i % 3 - 1) * 0.002   // ±2 ms host-time noise
            chunks += a.append([Float](repeating: 0, count: 160), startTime: t0.addingTimeInterval(Double(i) * 0.01 + jitter))
        }
        XCTAssertEqual(chunks.count, 5)
        XCTAssertTrue(chunks.allSatisfy { $0.samples.count == 1600 && $0.speaker == .them })
        for (x, y) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(y.startTime.timeIntervalSince(x.endTime), 0, accuracy: 1e-6)
        }
        // A real gap (device switch) re-anchors forward instead of compressing time.
        let later = a.append([Float](repeating: 0, count: 1600), startTime: t0.addingTimeInterval(2))
        XCTAssertEqual(later.last!.startTime.timeIntervalSince(t0), 2, accuracy: 1e-6)
    }
}
