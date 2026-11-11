import Foundation

/// Engine events → AppModel / TranscriptStore, with the echo filter in between (see EchoFilter
/// for the rules). Main actor, like the rest of SessionController.
extension SessionController {
    func handle(_ event: EngineEvent) {
        switch event {
        case .partial(let text, let speaker, let app, let speakerID):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let voice = Voice(speaker: speaker, app: app, speakerID: speakerID)
            if speaker == .them {
                echo.observeThemPartial(text: t, now: Date())
                // The app of a line is a running vote; once it is known the unlabelled entry is stale.
                if app != nil { model.partials[Voice(speaker: .them)] = nil }
            } else if !t.isEmpty, echo.checkMePartial(text: t, now: Date()) {
                // Looks like the speakers heard by the mic: don't show it. The final decides.
                model.discardPartials(.me)
                return
            }
            if let id = speakerID, !t.isEmpty { noteSpeaker(id) }
            // A stream has one hypothesis; when its speaker changes the old voice's entry is stale.
            for v in model.partials.keys where v.speaker == speaker && v.app == voice.app && v != voice { model.partials[v] = nil }
            model.partials[voice] = t.isEmpty ? nil : t
        case .final(let line):
            guard !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                model.clearPartial(for: line); return
            }
            if let id = line.speakerID { noteSpeaker(id) }
            if line.speaker == .them {
                echo.observeThemFinal(text: line.text, start: line.start, end: line.end)
            } else if case .echo(let why) = echo.checkMeFinal(text: line.text, start: line.start, end: line.end,
                                                              levelGap: levelGap(from: line.start, to: line.end)) {
                Log.info(.engine, "echo filter: dropped me-line (\(why)): \(Log.describe(text: line.text))")
                model.discardPartials(.me)
                return
            }
            store?.insert(line)
            model.insert(line)
        case .warning(let message):
            Log.warn(.engine, "engine: \(message)")
            showWarning(message)
        }
    }

    /// How much quieter the mic was than system audio over `from…to`, in dB; nil when either lane
    /// has no level for that stretch (the tap delivers nothing while no app plays).
    private func levelGap(from: Date, to: Date) -> Double? {
        guard let them = levelHistory.level(.them, from: from, to: to),
              let me = levelHistory.level(.me, from: from, to: to) else { return nil }
        return them - me
    }

    /// A diarized speaker was heard: number it in order of appearance (file and live views).
    private func noteSpeaker(_ id: String) {
        store?.note(speaker: id)
        var r = model.speakers
        if r.note(id) { model.speakers = r }
    }

    func showWarning(_ message: String) {
        model.warning = message
        warningToken += 1
        let token = warningToken
        onChange()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self, self.warningToken == token else { return }
            self.model.warning = nil
            self.onChange()
        }
    }
}
