import Foundation

/// Engine events → AppModel / TranscriptStore, with the echo filter in between (see EchoFilter
/// for the rules). Main actor, like the rest of SessionController.
extension SessionController {
    func handle(_ event: EngineEvent) {
        switch event {
        case .partial(let text, let speaker, let app):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let voice = Voice(speaker: speaker, app: app)
            if speaker == .them {
                echo.observeThemPartial(text: t, now: Date())
                // The app of a line is a running vote; once it is known the unlabelled entry is stale.
                if app != nil { model.partials[Voice(speaker: .them)] = nil }
            } else if !t.isEmpty, echo.checkMePartial(text: t, now: Date()) {
                // Looks like the speakers heard by the mic: don't show it. The final decides.
                model.partials[.me] = nil
                return
            }
            model.partials[voice] = t.isEmpty ? nil : t
        case .final(let line):
            guard !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                model.clearPartial(for: line); return
            }
            if line.speaker == .them {
                echo.observeThemFinal(text: line.text, start: line.start, end: line.end)
            } else if case .echo(let why) = echo.checkMeFinal(text: line.text, start: line.start, end: line.end,
                                                              levelGap: levelGap(from: line.start, to: line.end)) {
                Log.info("echo filter: dropped me-line (\(why)): \"\(line.text.prefix(60))\"")
                model.partials[.me] = nil
                return
            }
            store?.insert(line)
            model.insert(line)
        case .warning(let message):
            Log.warn("engine: \(message)")
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
