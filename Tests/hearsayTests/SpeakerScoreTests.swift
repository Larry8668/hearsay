import XCTest
@testable import hearsay

/// The measuring stick of `hearsay --eval-speakers`: alignment, slot mapping and the turn metrics.
final class SpeakerScoreTests: XCTestCase {
    typealias W = SpeakerScore.RefWord
    typealias L = SpeakerScore.HypLine

    /// "one two three" by A at 0–3 s, "yes" by B at 3.5 s, "four five six" by A at 4–7 s.
    let ref: [W] = [
        W(start: 0, end: 1, speaker: "A", text: "One"), W(start: 1, end: 2, speaker: "A", text: "two"),
        W(start: 2, end: 3, speaker: "A", text: "three"), W(start: 3.4, end: 3.7, speaker: "B", text: "Yes."),
        W(start: 4.6, end: 5, speaker: "A", text: "four"), W(start: 5, end: 6, speaker: "A", text: "five"),
        W(start: 6, end: 7, speaker: "A", text: "six"),
    ]

    func testPerfectOutputScoresPerfectlyWhateverTheSlotNames() {
        let s = SpeakerScore(reference: ref, lines: [
            L(start: 0, end: 3, speaker: "me#2", text: "One, two, three."),
            L(start: 3.3, end: 3.8, speaker: "me#1", text: "Yes."),
            L(start: 4.5, end: 7, speaker: "me#2", text: "four five six"),
        ])
        XCTAssertEqual(s.aligned, 7)
        XCTAssertEqual(s.accuracy, 1)
        XCTAssertEqual(s.wer, 0)
        // A's two stretches are 1.6 s apart: two turns, plus B's.
        XCTAssertEqual(s.turns, 3)
        XCTAssertEqual(s.splitTurns, 0)
        XCTAssertEqual(s.mergedLines, 0)
        XCTAssertEqual(s.interjections, 1)
        XCTAssertEqual(s.interjectionsHit, 1)
    }

    func testASentenceCutAcrossTwoSlotsIsASplitTurn() {
        let s = SpeakerScore(reference: ref, lines: [
            L(start: 0, end: 2, speaker: "me#1", text: "one two"),
            L(start: 2, end: 3.8, speaker: "me#2", text: "three yes"),
            L(start: 4.5, end: 7, speaker: "me#1", text: "four five six"),
        ])
        XCTAssertEqual(s.splitTurns, 1, "A's first turn spans me#1 and me#2")
        XCTAssertEqual(s.splitWords, 1)
        XCTAssertEqual(s.strictSplit, 0, "one stray word is not a strict split")
        // me#2 maps to B (its one "yes" agrees), so "three" is the one wrong word.
        XCTAssertEqual(s.correct, 6)
        XCTAssertEqual(s.mergedLines, 1, "the second line holds A's and B's words")
        XCTAssertEqual(s.mergedWords, 1)
        XCTAssertEqual(s.interjectionsHit, 1)
    }

    func testAnInterjectionSwallowedByTheMainSpeakerIsMissed() {
        let s = SpeakerScore(reference: ref, lines: [
            L(start: 0, end: 7, speaker: "me#1", text: "one two three yes four five six"),
        ])
        XCTAssertEqual(s.accuracy, 6.0 / 7, accuracy: 1e-9)
        XCTAssertEqual(s.interjectionsHit, 0)
        XCTAssertEqual(s.mergedWords, 1)
        XCTAssertEqual(s.splitTurns, 0)
    }

    func testWordsOnlyPairInsideTheirLinesTime() {
        // The same words, but the line sits 10 s away: nothing may pair, all are errors.
        let s = SpeakerScore(reference: Array(ref.prefix(3)), lines: [L(start: 20, end: 23, speaker: "me#1", text: "one two three")])
        XCTAssertEqual(s.aligned, 0)
        XCTAssertEqual(s.deletions, 3)
        XCTAssertEqual(s.insertions, 3)
        XCTAssertEqual(s.wer, 2)
    }

    func testLinesWithoutSpeakerAndSpareSlotsCountAsWrong() {
        let s = SpeakerScore(reference: ref, lines: [
            L(start: 0, end: 3, speaker: nil, text: "one two three"),
            L(start: 3.3, end: 3.8, speaker: "me#1", text: "yes"),
            L(start: 4.5, end: 7, speaker: "me#2", text: "four five six"),
        ])
        // me#2 → A (3 words) and me#1 → B (1): the unlabelled line's 3 words are wrong.
        XCTAssertEqual(s.correct, 4)
    }

    func testMappingIsOneToOneAndOptimal() {
        let counts = ["s1": ["A": 5, "B": 4], "s2": ["A": 6, "B": 1], "s3": ["A": 1]]
        // Greedy would give s2 → A, s1 → B (6 + 4 = 10); s1 → A, s2 → B is 5 + 1 = 6; optimum is 10.
        XCTAssertEqual(SpeakerScore.bestMapping(slots: ["s1", "s2", "s3"], people: ["A", "B"], counts: counts), ["s1": "B", "s2": "A"])
    }

    func testNormalizeDropsPunctuationAndSplitsHyphens() {
        XCTAssertEqual(SpeakerScore.normalize("Kick-off, it's 15% — OK."), ["kick", "off", "it's", "15", "ok"])
    }

    func testABAShortLineGoesBackToTheSurroundingSpeaker() {
        typealias S = SpeakerSmoothing.Line
        let lines = [S(start: 0, end: 3, speaker: "a", words: 8), S(start: 3, end: 4, speaker: "b", words: 2),
                     S(start: 4.2, end: 8, speaker: "a", words: 9), S(start: 8, end: 9, speaker: "b", words: 1),
                     S(start: 12, end: 14, speaker: "a", words: 5)]
        let rule = SpeakerSmoothing.Rule(maxWords: 3, maxSeconds: 2.5, maxGap: 1)
        // The second "b" line is followed by a 3 s gap: a real interjection may stand.
        XCTAssertEqual(SpeakerSmoothing.relabelABA(lines, rule: rule), ["a", "a", "a", "b", "a"])
    }
}
