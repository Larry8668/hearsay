import Foundation

/// A-B-A smoothing (`--smooth-aba`, an experiment): a short line by B between two lines by A,
/// with small gaps either side, is most often A's own words that the diarizer briefly gave to
/// another slot, so it is handed back to A. Needs the NEXT line to decide, so live it costs a
/// short line its emission until the next line is final.
enum SpeakerSmoothing {
    struct Rule { var maxWords = 3; var maxSeconds: TimeInterval = 2.5; var maxGap: TimeInterval = 1.0 }

    struct Line { var start: TimeInterval; var end: TimeInterval; var speaker: String?; var words: Int }

    /// The speakers after smoothing, one per line (lines in time order). Decisions use the
    /// original speakers, so one relabel never enables the next.
    static func relabelABA(_ lines: [Line], rule: Rule) -> [String?] {
        var out = lines.map(\.speaker)
        guard lines.count >= 3 else { return out }
        for i in 1..<(lines.count - 1) {
            let a = lines[i - 1], b = lines[i], c = lines[i + 1]
            guard let s = a.speaker, c.speaker == s, b.speaker != s,
                  b.words <= rule.maxWords, b.end - b.start <= rule.maxSeconds,
                  b.start - a.end <= rule.maxGap, c.start - b.end <= rule.maxGap else { continue }
            out[i] = s
        }
        return out
    }
}
