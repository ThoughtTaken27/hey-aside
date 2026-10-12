import Foundation

/// Decides when the user has finished speaking. Pure logic so it can be unit-tested.
///
/// Signals: time since the last voiced audio frame and since the transcript last changed.
/// Heuristic "smart turn": a trailing conjunction or filler, or a missing end punctuation,
/// means the thought is probably unfinished, so we wait longer before sending.
struct Endpointer {
    var baseSilence: TimeInterval          // e.g. 1.2 s
    var initialWait: TimeInterval = 8.0    // said only "Hey Jarvis" and paused (Sep 25: people wait for "Yes, sir?")
    var maxDuration: TimeInterval = 45.0

    enum Decision: Equatable { case keepListening, finish, timeoutNoCommand, maxLength }

    static let danglingWords: Set<String> = [
        "and", "or", "but", "so", "um", "uh", "the", "a", "an", "to", "with", "of", "for", "in", "on",
        "my", "your", "about", "like", "then", "because", "that", "if", "is", "at", "from", "hmm"
    ]

    /// Sep 30 "smart turn": a finished-looking request doesn't wait the whole silence window. Humans answer within
    /// ~250 ms; a flat 1.2 s after every request read as slow. The recognizer puts "?" / "." on a finished sentence about
    /// 0.3 s after the voice stops, so: a finished sentence of 3+ words waits `finishedSilence`, a 4+ word question or
    /// command waits `likelyDoneSilence`, a trailing "and"/"um" still waits longer. Off: `defaults write
    /// app.heyaside.mac smartEndpoint -bool false`.
    var smart: Bool = UserDefaults.standard.object(forKey: "smartEndpoint") as? Bool ?? true
    var finishedSilence: TimeInterval = 0.6
    var likelyDoneSilence: TimeInterval = 0.85

    static let openers: Set<String> = [
        "what", "what's", "whats", "who", "who's", "whos", "when", "where", "where's", "why", "how", "how's", "hows", "which",
        "is", "are", "was", "can", "could", "would", "will", "do", "does", "did", "should", "tell", "open", "play", "set",
        "remind", "search", "find", "check", "send", "show", "give", "make", "turn", "add", "look", "read", "summarize",
    ]

    func requiredSilence(for command: String) -> TimeInterval {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return baseSilence }
        let words = trimmed.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        let lastWord = words.last ?? ""
        let lastChar = trimmed.last!
        let endsSentence = ".?!".contains(lastChar)
        if !endsSentence && Endpointer.danglingWords.contains(lastWord) { return baseSilence + 1.2 }
        guard smart else { return baseSilence }
        if endsSentence && words.count >= 3 { return min(baseSilence, finishedSilence) }
        if words.count >= 4, let first = words.first, Endpointer.openers.contains(first) { return min(baseSilence, likelyDoneSilence) }
        return baseSilence
    }

    func decide(now: TimeInterval, wakeAt: TimeInterval, lastActivity: TimeInterval, command: String) -> Decision {
        if now - wakeAt > maxDuration { return command.isEmpty ? .timeoutNoCommand : .maxLength }
        if command.trimmingCharacters(in: .whitespaces).isEmpty {
            return (now - max(wakeAt, lastActivity) > initialWait) ? .timeoutNoCommand : .keepListening
        }
        return (now - lastActivity >= requiredSilence(for: command)) ? .finish : .keepListening
    }
}
