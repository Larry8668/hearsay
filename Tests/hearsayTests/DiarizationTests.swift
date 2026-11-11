import XCTest
@testable import hearsay

/// Speaker turns drive line cuts: the tracker is fed a fake diarizer timeline (lane samples)
/// the way `ParakeetEngine` feeds it `SpeakerFrames`.
final class SpeakerTurnTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 10_000)
    var fed = 0
    let rate = Int(AudioChunk.sampleRate)

    func feed(_ t: inout UtteranceTracker, seconds: Double, loud: Bool = true) {
        for _ in 0..<Int((seconds * 10).rounded()) {
            let base = fed
            let samples = (0..<1600).map { i in loud ? 0.2 * sin(Float(base + i) * 2 * .pi * 440 / 16_000) : 0 }
            t.ingest(AudioChunk(samples: samples, startTime: t0.addingTimeInterval(Double(fed) / 16_000), speaker: .me))
            fed += 1600
        }
    }

    func run(_ speaker: Int, _ from: Double, _ to: Double) -> SpeakerRun {
        SpeakerRun(start: Int(from * 16_000), end: Int(to * 16_000), speaker: speaker)
    }

    func tracker() -> UtteranceTracker {
        UtteranceTracker(config: .init(silenceGap: 1.2, modelLatency: 0.64, stableFor: 1.0, speakerHold: 0.6))
    }

    func testNewSpeakerCutsTheLineOnceTheyHoldTheFloor() {
        var t = tracker()
        feed(&t, seconds: 3)
        t.update(transcript: "hello from me")
        t.observe(SpeakerFrames(finalized: [run(0, 0.3, 3.0)], tentative: []))
        XCTAssertNil(t.finalReason(modelSignalledEnd: false))
        feed(&t, seconds: 1)
        t.observe(SpeakerFrames(finalized: [run(1, 3.2, 4.0)], tentative: []))
        // Speaker 2 has held 0.8 s, but the speech model (0.64 s lag) may still owe speaker 1 words.
        XCTAssertNil(t.finalReason(modelSignalledEnd: false), "wait for the model to catch up")
        feed(&t, seconds: 0.3)
        t.observe(SpeakerFrames(finalized: [run(1, 4.0, 4.3)], tentative: []))
        XCTAssertEqual(t.speakerTurn(), Int(3.2 * 16_000))
        XCTAssertEqual(t.finalReason(modelSignalledEnd: false), .speakerChange)
        let line = t.commit(reason: .speakerChange, speaker: .me, engine: "x", modelWillReset: false, stream: "me")!
        XCTAssertEqual(line.text, "hello from me")
        XCTAssertEqual(line.speakerID, "me#1")
        XCTAssertEqual(line.start.timeIntervalSince(t0), 0, accuracy: 0.001, "the audio was loud from the first sample")
        XCTAssertEqual(line.end.timeIntervalSince(t0), 3.2, accuracy: 0.001)
        XCTAssertEqual(t.pending, "", "the newcomer's words have not shown up yet")
        XCTAssertNil(t.finalReason(modelSignalledEnd: false))

        // The newcomer's words arrive and end in silence: their own line, from the turn.
        t.update(transcript: "hello from me and now I answer")
        feed(&t, seconds: 1.7)
        t.observe(SpeakerFrames(finalized: [run(1, 4.3, 6.0)], tentative: []))
        XCTAssertNil(t.finalReason(modelSignalledEnd: false))
        XCTAssertEqual(t.currentSpeaker, 1)
        feed(&t, seconds: 1.3, loud: false)
        XCTAssertEqual(t.finalReason(modelSignalledEnd: false), .silence)
        let second = t.commit(reason: .silence, speaker: .me, engine: "x", modelWillReset: true, stream: "me")!
        XCTAssertEqual(second.text, "and now I answer")
        XCTAssertEqual(second.speakerID, "me#2")
        XCTAssertEqual(second.start.timeIntervalSince(t0), 3.2, accuracy: 0.001)
    }

    func testWordsAreSplitBetweenSpeakersByWhenTheyAppeared() {
        var t = tracker()
        feed(&t, seconds: 3)
        t.update(transcript: "hello from me")
        t.observe(SpeakerFrames(finalized: [run(0, 0.3, 3.0)], tentative: []))
        feed(&t, seconds: 1.5)
        t.update(transcript: "hello from me and now I answer")   // seen at 4.5 s: spoken ≈ 3.6–4.4, speaker 2's stretch
        t.observe(SpeakerFrames(finalized: [run(1, 3.2, 4.5)], tentative: []))
        feed(&t, seconds: 1.1)
        t.observe(SpeakerFrames(finalized: [], tentative: [run(1, 4.5, 5.6)]))
        XCTAssertEqual(t.finalReason(modelSignalledEnd: false), .speakerChange)
        let line = t.commit(reason: .speakerChange, speaker: .me, engine: "x", modelWillReset: false, stream: "me")!
        XCTAssertEqual(line.text, "hello from me")
        XCTAssertEqual(line.speakerID, "me#1")
        XCTAssertEqual(t.pending, "and now I answer")
        XCTAssertEqual(t.currentSpeaker, 1)
        XCTAssertNil(t.finalReason(modelSignalledEnd: false), "one speaker left on the line")
    }

    func testFlickerAndBackChannelDoNotCut() {
        var t = tracker()
        feed(&t, seconds: 3)
        t.update(transcript: "hello from me and more")
        t.observe(SpeakerFrames(finalized: [run(0, 0.3, 3.0)], tentative: []))
        // A 0.3 s "yes" from speaker 2, then speaker 1 carries on.
        feed(&t, seconds: 2)
        t.observe(SpeakerFrames(finalized: [run(1, 3.0, 3.3), run(0, 3.3, 5.0)], tentative: []))
        XCTAssertNil(t.speakerTurn())
        XCTAssertNil(t.finalReason(modelSignalledEnd: false))
        // Alternating frames (crosstalk) never let the newcomer hold the floor.
        feed(&t, seconds: 2)
        var runs: [SpeakerRun] = []
        for i in 0..<20 { runs.append(run(i % 2, 5.0 + Double(i) * 0.1, 5.1 + Double(i) * 0.1)) }
        t.observe(SpeakerFrames(finalized: runs, tentative: []))
        XCTAssertNil(t.speakerTurn())
        XCTAssertEqual(t.dominantSpeaker(from: 0, to: 7 * rate), 0)
    }

    func testABriefFirstVoiceIsNotWorthALine() {
        var t = tracker()
        feed(&t, seconds: 2)
        t.update(transcript: "yes so here is the thing")
        // Speaker 1 said "yes" (0.3 s), speaker 2 has the rest: one line, dominated by speaker 2.
        t.observe(SpeakerFrames(finalized: [run(0, 0.2, 0.5), run(1, 0.6, 2.0)], tentative: []))
        XCTAssertNil(t.speakerTurn())
        feed(&t, seconds: 1.3, loud: false)
        let line = t.commit(reason: .silence, speaker: .me, engine: "x", modelWillReset: true, stream: "me")!
        XCTAssertEqual(line.speakerID, "me#2")
    }

    func testDominantSpeakerIsByTimeWithStableTies() {
        var t = tracker()
        feed(&t, seconds: 4)
        t.observe(SpeakerFrames(finalized: [run(0, 0, 1), run(1, 1, 2.5), run(0, 2.5, 3)], tentative: [run(2, 3, 4)]))
        XCTAssertEqual(t.dominantSpeaker(from: 0, to: 3 * rate), 0, "1.5 s each: the lower slot wins the tie")
        XCTAssertEqual(t.dominantSpeaker(from: rate, to: 3 * rate), 1)
        XCTAssertEqual(t.dominantSpeaker(from: 3 * rate, to: 4 * rate), 2, "tentative frames count too")
        XCTAssertNil(t.dominantSpeaker(from: 4 * rate, to: 5 * rate))
        XCTAssertNil(UtteranceTracker().dominantSpeaker(from: 0, to: 100))
    }

    /// The model's own token timings place words: the "." that ends "then." is emitted 1.3 s
    /// later, after the next speaker has started, and must not drag "then." into their line.
    func testTokenTimingsPlaceWordsAndLatePunctuation() {
        var t = tracker()
        func piece(_ text: String, _ a: Double, _ b: Double) -> (text: String, start: Int, end: Int) {
            (text, Int(a * 16_000), Int(b * 16_000))
        }
        feed(&t, seconds: 9.3)
        t.update(transcript: "the notes before then")
        t.addPieceTimes([piece(" the", 8.10, 8.18), piece(" notes", 8.18, 8.34), piece(" before", 8.58, 8.66), piece(" then", 8.90, 8.98)])
        XCTAssertTrue(t.pieceTimesAligned)
        t.observe(SpeakerFrames(finalized: [run(0, 0, 9.12)], tentative: []))
        feed(&t, seconds: 1.2)
        t.update(transcript: "the notes before then.")
        t.addPieceTimes([piece(".", 10.26, 10.34)])
        feed(&t, seconds: 0.7)
        t.update(transcript: "the notes before then. Sounds good")
        t.addPieceTimes([piece(" Sounds", 10.42, 10.50), piece(" good", 10.66, 10.74)])
        XCTAssertTrue(t.pieceTimesAligned)
        t.observe(SpeakerFrames(finalized: [run(1, 10.0, 11.04)], tentative: [run(1, 11.04, 11.2)]))
        XCTAssertNil(t.finalReason(modelSignalledEnd: false), "the full stop arrived 0.7 s ago; it could still change")
        feed(&t, seconds: 0.4)
        t.observe(SpeakerFrames(finalized: [run(1, 11.04, 11.52)], tentative: []))
        XCTAssertEqual(t.finalReason(modelSignalledEnd: false), .speakerChange)
        let line = t.commit(reason: .speakerChange, speaker: .me, engine: "x", modelWillReset: false, stream: "me")!
        XCTAssertEqual(line.text, "the notes before then.")
        XCTAssertEqual(line.speakerID, "me#1")
        XCTAssertEqual(line.end.timeIntervalSince(t0), 10.0, accuracy: 0.001)
        XCTAssertEqual(t.pending, "Sounds good")
        // A revision the pieces know nothing about turns the timings off rather than misapplying them.
        t.update(transcript: "the notes before then. Sounds good to")
        XCTAssertFalse(t.pieceTimesAligned)
    }

    /// Partials name the speaker of settled frames only: the look-ahead's guess ("a fourth voice")
    /// is often revised into a voice already heard, and must never reach a chip.
    func testPartialsFollowSettledFramesOnly() {
        var t = tracker()
        feed(&t, seconds: 2.6)
        t.update(transcript: "so as I was saying")
        t.observe(SpeakerFrames(finalized: [run(0, 0.2, 2.0)], tentative: [run(3, 2.0, 2.6)]))
        XCTAssertEqual(t.currentSpeaker, 0, "the look-ahead's #4 is not shown")
        XCTAssertEqual(t.dominantSpeaker(from: Int(2.0 * 16_000), to: Int(2.6 * 16_000)), 3, "commits still see it")
        XCTAssertTrue(t.takeSpeakerEvents().isEmpty)
        // It settles as the first voice after all: a revision for the log, and no label changed.
        feed(&t, seconds: 0.5)
        t.observe(SpeakerFrames(finalized: [run(0, 2.0, 2.6)], tentative: [run(0, 2.6, 3.1)]))
        XCTAssertEqual(t.currentSpeaker, 0)
        XCTAssertEqual(t.takeSpeakerEvents().revisions, [.init(tentative: 3, settled: 0, at: Int(2.0 * 16_000))])
        XCTAssertTrue(t.takeSpeakerEvents().isEmpty, "taken once")
        // A new line with nothing settled yet has no speaker of its own (the engine keeps the last one).
        feed(&t, seconds: 1.3, loud: false)
        _ = t.commit(reason: .silence, speaker: .me, engine: "x", modelWillReset: true, stream: "me")
        feed(&t, seconds: 0.5)
        t.update(transcript: "next")
        t.observe(SpeakerFrames(finalized: [], tentative: [run(1, 4.4, 4.9)]))
        XCTAssertNil(t.currentSpeaker)
        // Once frames settle, the line's only voice is shown at once…
        feed(&t, seconds: 1.5)
        t.observe(SpeakerFrames(finalized: [run(1, 4.4, 5.4)], tentative: []))
        XCTAssertEqual(t.currentSpeaker, 1)
        // …a second voice only once it has held the floor as long as a line cut needs (until
        // then nil: the engine keeps showing the previous speaker)…
        t.observe(SpeakerFrames(finalized: [run(2, 5.4, 5.8)], tentative: []))
        XCTAssertNil(t.currentSpeaker, "a 0.4 s stint does not get a chip")
        feed(&t, seconds: 0.5)
        t.observe(SpeakerFrames(finalized: [run(2, 5.8, 6.2)], tentative: []))
        XCTAssertEqual(t.currentSpeaker, 2)
    }

    func testSpeakerChangeReportsTheTurn() {
        var t = tracker()
        feed(&t, seconds: 3)
        t.update(transcript: "hello from me")
        t.observe(SpeakerFrames(finalized: [run(0, 0.3, 3.0)], tentative: []))
        feed(&t, seconds: 1.3)
        t.observe(SpeakerFrames(finalized: [run(1, 3.2, 4.3)], tentative: []))
        XCTAssertEqual(t.finalReason(modelSignalledEnd: false), .speakerChange)
        _ = t.commit(reason: .speakerChange, speaker: .me, engine: "x", modelWillReset: false, stream: "me")
        XCTAssertEqual(t.takeSpeakerEvents().turns, [.init(from: 0, to: 1, at: Int(3.2 * 16_000), held: Int(1.1 * 16_000))])
    }

    func testNoSpeakerIDWithoutAStream() {
        var t = tracker()
        feed(&t, seconds: 2)
        t.update(transcript: "hi")
        t.observe(SpeakerFrames(finalized: [run(0, 0, 2)], tentative: []))
        feed(&t, seconds: 1.3, loud: false)
        XCTAssertNil(t.commit(reason: .silence, speaker: .me, engine: "x", modelWillReset: true)?.speakerID)
    }
}

/// Labels: "me" until a second voice appears, then "Speaker 1" / "Speaker 2"; the enrolled voice
/// stays "me"; them lanes append the speaker to the app ("them · Zoom · Speaker 2").
final class SpeakerRosterTests: XCTestCase {
    func testSpeakerIDs() {
        XCTAssertEqual(SpeakerID.make(stream: "me", slot: 0), "me#1")
        XCTAssertEqual(SpeakerID.make(stream: "them:us.zoom.xos", slot: 1), "them:us.zoom.xos#2")
        XCTAssertEqual(SpeakerID.stream(of: "them:us.zoom.xos#2"), "them:us.zoom.xos")
        XCTAssertEqual(SpeakerID.slot(of: "them:us.zoom.xos#2"), 2)
        XCTAssertEqual(SpeakerID.stream(.them, app: "us.zoom.xos"), "them:us.zoom.xos")
        XCTAssertEqual(SpeakerID.stream(.them, app: nil), "them")
        XCTAssertEqual(SpeakerID.stream(.me, app: "ignored"), "me")
        XCTAssertEqual(Voice(speaker: .them, app: "us.zoom.xos", speakerID: "them:us.zoom.xos#2").stream, "them:us.zoom.xos")
    }

    /// One format: a diarized speaker's id is its voice's key, the key names are stored under,
    /// and parses back into the same voice.
    func testSpeakerIDIsTheVoiceKey() {
        let v = Voice(speaker: .them, app: "us.zoom.xos", speakerID: "them:us.zoom.xos#2")
        XCTAssertEqual(v.key, "them:us.zoom.xos#2")
        XCTAssertEqual(Voice(key: v.key), v)
        XCTAssertEqual(Voice(speaker: .them, app: "us.zoom.xos").key, "them:us.zoom.xos")
        XCTAssertEqual(Voice(key: "me#1"), Voice(speaker: .me, speakerID: "me#1"))
        XCTAssertEqual(SpeakerID.stream(.them, app: "us.zoom.xos"), Voice(speaker: .them, app: "us.zoom.xos").key)
    }

    func testMicLaneStaysMeUntilASecondVoice() {
        var r = SpeakerRoster()
        XCTAssertEqual(LaneColors.chipLabel(Voice.me, r), "me")
        XCTAssertTrue(r.note("me#1"))
        XCTAssertFalse(r.note("me#1"))
        XCTAssertEqual(LaneColors.chipLabel(Voice(speaker: .me, speakerID: "me#1"), r), "me")
        XCTAssertNil(r.displayName("me#1"))
        r.note("me#2")
        XCTAssertEqual(LaneColors.chipLabel(Voice(speaker: .me, speakerID: "me#1"), r), "Speaker 1")
        XCTAssertEqual(LaneColors.chipLabel(Voice(speaker: .me, speakerID: "me#2"), r), "Speaker 2")
        XCTAssertEqual(LaneColors.chipLabel(Voice.me, r), "me", "a line without a speaker keeps the lane label")
        // A name given to a speaker (the chip's rename) wins over the roster's label.
        var meta = TranscriptMeta()
        meta.setName("Anna", for: Voice(speaker: .me, speakerID: "me#2"))
        XCTAssertEqual(meta.names, ["me#2": "Anna"])
        var names = VoiceNames(meta, yourName: nil, roster: r)
        XCTAssertEqual(names.chipLabel(Voice(speaker: .me, speakerID: "me#2")), "Anna")
        XCTAssertEqual(names.chipLabel(Voice(speaker: .me, speakerID: "me#1")), "Speaker 1", "numbers never shift")
        meta.setName("  ", for: Voice(speaker: .me, speakerID: "me#2"))
        names = VoiceNames(meta, yourName: nil, roster: r)
        XCTAssertEqual(names.chipLabel(Voice(speaker: .me, speakerID: "me#2")), "Speaker 2")
        XCTAssertEqual(r.map, ["me#1": "Speaker 1", "me#2": "Speaker 2"])
        XCTAssertEqual(r.order.map { names.speakerName($0) }, ["Speaker 1", "Speaker 2"])
    }

    func testEnrolledVoiceIsMeAndOthersAreNumbered() {
        var r = SpeakerRoster()
        XCTAssertTrue(r.markEnrolled("me#1"))
        XCTAssertFalse(r.markEnrolled("me#1"))
        r.note("me#2")
        XCTAssertEqual(LaneColors.chipLabel(Voice(speaker: .me, speakerID: "me#1"), r), "me")
        XCTAssertEqual(LaneColors.chipLabel(Voice(speaker: .me, speakerID: "me#2"), r), "Speaker 1")
        r.note("me#3")
        XCTAssertEqual(r.displayName("me#3"), "Speaker 2")
    }

    /// Settings ▸ Your name replaces "me" wherever the label would be "me" (a lone mic voice, the
    /// enrolled voice), never a numbered speaker; a transcript's own name wins over both.
    func testYourNameAppliesOnlyWhereTheLabelIsMe() {
        var r = SpeakerRoster()
        r.note("me#1")
        let one = Voice(speaker: .me, speakerID: "me#1"), two = Voice(speaker: .me, speakerID: "me#2")
        XCTAssertEqual(VoiceNames(yourName: "Aditya", roster: r).chipLabel(one), "Aditya", "lone mic voice")
        r.note("me#2")
        XCTAssertEqual(VoiceNames(yourName: "Aditya", roster: r).chipLabel(one), "Speaker 1")
        r.markEnrolled("me#1")
        XCTAssertEqual(VoiceNames(yourName: "Aditya", roster: r).chipLabel(one), "Aditya", "enrolled voice")
        XCTAssertEqual(VoiceNames(yourName: "Aditya", roster: r).chipLabel(two), "Speaker 1")
        XCTAssertEqual(VoiceNames(names: ["me#1": "Adi"], yourName: "Aditya", roster: r).chipLabel(one), "Adi")
        var f = TranscriptFormatter()
        f.names = VoiceNames(names: ["me#2": "Anna"], yourName: "Aditya", roster: r)
        let l = TranscriptLine(speaker: .me, sourceApp: nil, start: Date(), end: Date(), text: "x", engine: "e", speakerID: "me#2")
        XCTAssertEqual(f.label(l), "Anna")
    }

    func testThemLaneAppendsTheSpeakerToTheApp() {
        var r = SpeakerRoster()
        let a = Voice(speaker: .them, app: "us.zoom.xos", speakerID: "them:us.zoom.xos#1")
        let b = Voice(speaker: .them, app: "us.zoom.xos", speakerID: "them:us.zoom.xos#2")
        r.note(a.speakerID!)
        XCTAssertEqual(LaneColors.chipLabel(a, r), "them · Zoom")
        r.note(b.speakerID!)
        XCTAssertEqual(LaneColors.chipLabel(a, r), "them · Zoom · Speaker 1")
        XCTAssertEqual(LaneColors.chipLabel(b, r), "them · Zoom · Speaker 2")
        XCTAssertEqual(LaneColors.chipLabel(Voice(speaker: .them, app: "us.zoom.xos"), r), "them · Zoom")
        // Another app's lone speaker is not numbered by Zoom's count.
        let c = Voice(speaker: .them, app: "com.apple.Safari", speakerID: "them:com.apple.Safari#1")
        r.note(c.speakerID!)
        XCTAssertEqual(LaneColors.chipLabel(c, r), "them · Safari")
        XCTAssertEqual(r.map["them:com.apple.Safari#1"], "Speaker 1")
    }

    func testVoicesOfOneLaneKeepTheirOrderAndColours() {
        let v1 = Voice(speaker: .me, speakerID: "me#1"), v2 = Voice(speaker: .me, speakerID: "me#2")
        XCTAssertTrue(Voice.displayOrder(v1, v2))
        XCTAssertTrue(Voice.displayOrder(v2, Voice(speaker: .them, app: "a", speakerID: "them:a#1")))
        var r = SpeakerRoster()
        r.note("me#1"); r.note("me#2")
        XCTAssertNotEqual(LaneColors.bright(v1, r), LaneColors.bright(v2, r))
        XCTAssertEqual(LaneColors.bright(v1, r), LaneColors.bright(.me), "the first speaker keeps the lane colour")
    }

    /// A voice seen only in partials so far is not numbered: it may still settle as someone else.
    func testAVoiceWithoutALineHasNoNumber() {
        var r = SpeakerRoster()
        r.note("them:us.zoom.xos#1"); r.note("them:us.zoom.xos#2")
        let newcomer = Voice(speaker: .them, app: "us.zoom.xos", speakerID: "them:us.zoom.xos#4")
        XCTAssertTrue(r.isProvisional("them:us.zoom.xos#4"))
        XCTAssertEqual(LaneColors.chipLabel(newcomer, r), "them · Zoom")
        XCTAssertEqual(LaneColors.bright(newcomer, r), LaneColors.bright(.them), "the lane's own colour")
        XCTAssertNil(r.map["them:us.zoom.xos#4"])
        // On the microphone it must not read "me" (or your name) while others are numbered.
        r.note("me#1"); r.note("me#2")
        let mic = Voice(speaker: .me, speakerID: "me#3")
        XCTAssertEqual(VoiceNames(yourName: "Aditya", roster: r).chipLabel(mic), "Speaker …")
        // The very first voice of a stream is not provisional: it reads as the lone voice.
        XCTAssertFalse(SpeakerRoster().isProvisional("me#1"))
        XCTAssertEqual(LaneColors.chipLabel(Voice(speaker: .me, speakerID: "me#1"), SpeakerRoster()), "me")
    }

    /// The user's report: captions showed "Speaker 4", the file had no Speaker 4 lines, yet the
    /// sidecar listed one. A speaker only joins the roster (live and on disk) with a line.
    @MainActor
    func testAPartialOnlySpeakerNeverReachesTheStore() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hearsay-partial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let t0 = Date(timeIntervalSince1970: 1_794_232_980)
        let store = TranscriptStore(directory: tmp, startedAt: t0, engine: "e", debounce: 0, yourName: { nil })
        let model = AppModel()
        let session = SessionController(model: model)
        session.attach(store: store)
        let zen = "app.zen-browser.zen"
        func line(_ offset: TimeInterval, _ slot: Int) -> TranscriptLine {
            TranscriptLine(speaker: .them, sourceApp: zen, start: t0.addingTimeInterval(offset), end: t0.addingTimeInterval(offset + 2),
                           text: "words \(offset)", engine: "e", speakerID: "them:\(zen)#\(slot)")
        }
        session.handle(.final(line(1, 1)))
        session.handle(.final(line(4, 2)))
        session.handle(.partial(text: "and then", speaker: .them, app: zen, speakerID: "them:\(zen)#4"))
        XCTAssertEqual(model.partials[Voice(speaker: .them, app: zen, speakerID: "them:\(zen)#4")], "and then", "shown live")
        XCTAssertEqual(model.speakers.order, ["them:\(zen)#1", "them:\(zen)#2"])
        // …but those words settle as speaker 2's line.
        session.handle(.final(line(7, 2)))
        store.finish(at: t0.addingTimeInterval(60))
        XCTAssertEqual(store.speakers.order, ["them:\(zen)#1", "them:\(zen)#2"])
        let side = try TranscriptStore.jsonDecoder.decode(TranscriptStore.Sidecar.self, from: Data(contentsOf: store.jsonURL))
        XCTAssertEqual(side.speakers, ["them:\(zen)#1": "Speaker 1", "them:\(zen)#2": "Speaker 2"])
        XCTAssertEqual(Set(side.speakers?.keys.map { $0 } ?? []), Set(side.lines.compactMap(\.speakerID)), "every listed speaker has lines")
    }

    @MainActor
    func testFinalClearsEverySpeakerPartialOfItsStream() {
        let model = AppModel()
        let s1 = Voice(speaker: .me, speakerID: "me#1"), s2 = Voice(speaker: .me, speakerID: "me#2")
        let zoom = Voice(speaker: .them, app: "us.zoom.xos", speakerID: "them:us.zoom.xos#1")
        model.partials = [s1: "old words", s2: "new words", zoom: "other side"]
        model.insert(TranscriptLine(speaker: .me, sourceApp: nil, start: Date(), end: Date(), text: "old words", engine: "t", speakerID: "me#1"))
        XCTAssertEqual(model.partials, [zoom: "other side"])
    }
}

final class SpeakerTranscriptTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_794_232_980)
    var fmt: TranscriptFormatter { TranscriptFormatter(timeZone: TimeZone(identifier: "UTC")!, appName: { ["us.zoom.xos": "Zoom"][$0] ?? $0 }) }
    var tmp: URL!
    override func setUp() { tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hearsay-diar-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func line(_ s: Speaker, _ offset: TimeInterval, _ text: String, app: String? = nil, id: String? = nil) -> TranscriptLine {
        TranscriptLine(speaker: s, sourceApp: app, start: t0.addingTimeInterval(offset), end: t0.addingTimeInterval(offset + 2),
                       text: text, engine: "e", speakerID: id)
    }

    func testSpeakerIDAndSpeakersMapRoundTripThroughTheSidecar() throws {
        let store = TranscriptStore(directory: tmp, startedAt: t0, engine: "e", formatter: fmt, debounce: 0, yourName: { nil })
        store.note(speaker: "me#1")
        store.insert(line(.me, 1, "first", id: "me#1"))
        store.note(speaker: "me#2")
        store.insert(line(.me, 5, "second", id: "me#2"))
        store.insert(line(.them, 8, "other", app: "us.zoom.xos", id: "them:us.zoom.xos#1"))
        store.note(speaker: "them:us.zoom.xos#1")
        store.rename(speaker: "me#2", to: "Anna")
        store.finish(at: t0.addingTimeInterval(60))

        let side = try TranscriptStore.jsonDecoder.decode(TranscriptStore.Sidecar.self, from: Data(contentsOf: store.jsonURL))
        XCTAssertEqual(side.lines.map(\.speakerID), ["me#1", "me#2", "them:us.zoom.xos#1"])
        // One naming system: the roster's generated labels, and the name given, under the same id.
        XCTAssertEqual(side.speakers, ["me#1": "Speaker 1", "me#2": "Speaker 2", "them:us.zoom.xos#1": "Speaker 1"])
        XCTAssertEqual(side.names, ["me#2": "Anna"])
        XCTAssertEqual(side.roster.order, ["me#1", "me#2", "them:us.zoom.xos#1"])
        XCTAssertEqual(side.roster.displayName("me#2"), "Speaker 2", "a saved transcript numbers its speakers as the live one did")

        let md = try String(contentsOf: store.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.contains("_Speakers: Speaker 1, Anna, Speaker 1 · Apps heard: Zoom"), md)
        XCTAssertTrue(md.contains("**14:03:01 Speaker 1** first"), md)
        XCTAssertTrue(md.contains("**14:03:05 Anna** second"), md)
        XCTAssertTrue(md.contains("**14:03:08 them (Zoom)** other"), md)
        XCTAssertTrue(store.plainText().contains("] Anna: second"))
    }

    func testOldSidecarsWithoutSpeakersStillDecode() throws {
        let json = """
        {"version":1,"startedAt":"2026-11-09T14:03:00.000Z","engine":"e","lines":[{"id":"\(UUID().uuidString)","speaker":"me",
        "start":"2026-11-09T14:03:01.000Z","end":"2026-11-09T14:03:03.000Z","text":"hi","engine":"e"}]}
        """
        let side = try TranscriptStore.jsonDecoder.decode(TranscriptStore.Sidecar.self, from: Data(json.utf8))
        XCTAssertNil(side.lines[0].speakerID)
        XCTAssertNil(side.speakers)
    }

    func testLoneVoiceLeavesTheHeaderAndLabelsAlone() throws {
        let store = TranscriptStore(directory: tmp, startedAt: t0, engine: "e", formatter: fmt, debounce: 0, yourName: { nil })
        store.note(speaker: "me#1")
        store.insert(line(.me, 1, "only me", id: "me#1"))
        store.finish(at: t0.addingTimeInterval(60))
        let md = try String(contentsOf: store.markdownURL, encoding: .utf8)
        XCTAssertFalse(md.contains("Speakers:"), md)
        XCTAssertTrue(md.contains("**14:03:01 me** only me"), md)
        let side = try TranscriptStore.jsonDecoder.decode(TranscriptStore.Sidecar.self, from: Data(contentsOf: store.jsonURL))
        XCTAssertEqual(side.speakers, ["me#1": "me"])
    }

    /// An enrolled voice reads "me" in the file, is restored as enrolled from the sidecar, and
    /// the others are numbered without it.
    func testEnrolledVoiceRoundTripsThroughTheSidecar() throws {
        let store = TranscriptStore(directory: tmp, startedAt: t0, engine: "e", formatter: fmt, debounce: 0, yourName: { nil })
        store.markEnrolled(speaker: "me#2")
        store.insert(line(.me, 1, "a guest", id: "me#1"))
        store.note(speaker: "me#1")
        store.insert(line(.me, 4, "it's me", id: "me#2"))
        store.finish(at: t0.addingTimeInterval(60))
        let md = try String(contentsOf: store.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.contains("**14:03:01 Speaker 1** a guest"), md)
        XCTAssertTrue(md.contains("**14:03:04 me** it's me"), md)
        let side = try TranscriptStore.jsonDecoder.decode(TranscriptStore.Sidecar.self, from: Data(contentsOf: store.jsonURL))
        XCTAssertEqual(side.speakers, ["me#1": "Speaker 1", "me#2": "me"])
        XCTAssertEqual(side.roster.enrolled, ["me#2"])
        XCTAssertEqual(side.roster.displayName("me#1"), "Speaker 1")
    }
}
