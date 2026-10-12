import Foundation

/// Decides whether a transcript segment starts with the wake phrase, and extracts the command after it.
///
/// Design notes (from offline tests with `say` voices on Apple's SpeechTranscriber):
/// - "Hey Aside" is often heard as "Pay aside", "Hey, aside", "Hey a side".
/// - Everyday phrases must NOT trigger: "put that aside", "aside from that", "okay, a side note".
/// So the phrase must sit at the start of a segment (after at most a few filler words),
/// needs a "hey"-like lead word, and is rejected when followed by words that make it ordinary English.
enum WakeMatcher {
    /// Which phrase wakes it (menu: Wake Phrase). Sep 25: switched the default to "Hey Jarvis"; the recognizer heard it
    /// correctly in 30/30 accent clips (Indian, US, British voices at two speeds).
    enum Phrase: String, CaseIterable { case jarvis, aside, both
        var title: String { switch self { case .jarvis: return "\u{201C}Hey Jarvis\u{201D}"; case .aside: return "\u{201C}Hey Aside\u{201D}"; case .both: return "Either one" } }
    }
    nonisolated(unsafe) static var phrase: Phrase = .jarvis

    private static let fillers = #"(?:um+|uh+|so|oh|well|and|yeah|hmm+|okay|ok)"#
    // Sep 24 accent test (Edge voices incl. Indian English, fed silently into the recognizer) added:
    // "He aside", "Hit aside", "Hey side", "Hey, side", "Hey as side". "Hey Siri" is deliberately NOT matched (Siri's phrase).
    private static let heyLike = #"(?:hey|hay|hei|hae|pay|hi|here|he|hit|h)"#
    private static let asideWord = #"(?:aside(?:'s)?|a[\s,-]+side|asides|a-side|as[\s,-]+side|side)"#
    private static let okayLead = #"(?:okay|ok)"#
    private static let jarvisWord = #"(?:jarvis(?:'s)?|jervis|javis|jarvus|jarves|jarvi|jar[\s-]+vis)"#
    private static let jarvisLead = #"(?:hey|hay|hei|hae|hi|he|a|okay|ok|yo)"#
    /// Bare "Jarvis ..." (no "hey") only counts when it isn't just talking about Jarvis.
    private static let jarvisOrdinary = #"(?:is|was|from|in|and|or|the|movie|voice|thing|said|says|would|could|can't|cant|isn't|isnt|has|had|of|to|like|in|on)"#
    private static let sep = #"[\s,.!?-]+"#
    /// Words that turn "aside"/"a side" into ordinary English.
    private static let ordinaryFollowers = #"(?:from|note|notes|dish|dishes|effect|effects|salad|quest|hustle|project|projects|bar|eye|table|door|order|of|by|to|mirror|bet|with|dishes|walk|walks|street|door|view|kick|kicks|ways)"#

    private static let jarvisRegex: NSRegularExpression = {
        let lead = "^\\s*(?:\(fillers)\(sep)){0,3}"
        let core = "(?:\(jarvisLead)\(sep)\(jarvisWord)\\b|\(jarvisWord)\\b(?![\\s]+\(jarvisOrdinary)\\b))"
        return try! NSRegularExpression(pattern: lead + core + "[\\s,.!?:;-]*", options: [.caseInsensitive])
    }()

    private static let asideRegex: NSRegularExpression = {
        let lead = "^\\s*(?:\(fillers)\(sep)){0,3}"
        let core = "(?:\(heyLike)\(sep)\(asideWord)|\(okayLead)\(sep)aside(?:'s)?)"
        let guardFollow = "(?![\\s,]+\(ordinaryFollowers)\\b)"
        let tail = "\\b\(guardFollow)[\\s,.!?:;-]*"
        return try! NSRegularExpression(pattern: lead + core + tail, options: [.caseInsensitive])
    }()

    /// Loose fallback used only to strip the wake phrase when the recognizer revised the text after we already woke.
    private static let looseStrip: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^\s*(?:\S+[\s,.!?-]+){0,3}?(?:aside(?:'s)?|a[\s,-]+side|side|jarvis(?:'s)?|jervis|javis|jarvus)\b[\s,.!?:;-]*"#, options: [.caseInsensitive])
    }()

    private static let cancelRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^\s*(?:cancel|never\s*mind|nevermind|stop|forget\s+it|nothing|scratch\s+that)[\s.!,]*(?:that|it)?[\s.!]*$"#, options: [.caseInsensitive])
    }()

    private static let cancelAnywhere: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\b(?:cancel|never\s*mind|nevermind|stop|don'?t\s+send|forget\s+it)\b"#, options: [.caseInsensitive])
    }()

    struct Match: Equatable {
        /// Text after the wake phrase (may be empty if the user paused after "Hey Aside").
        let command: String
    }

    static func match(_ text: String) -> Match? {
        let ns = text as NSString
        let regs: [NSRegularExpression] = phrase == .jarvis ? [jarvisRegex] : phrase == .aside ? [asideRegex] : [jarvisRegex, asideRegex]
        guard let m = regs.lazy.compactMap({ $0.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) }).first else { return nil }
        let rest = ns.substring(from: m.range.location + m.range.length)
        return Match(command: clean(rest))
    }

    /// Strips the wake phrase from an assembled transcript. Falls back to a looser rule if the strict one no longer matches.
    static func stripWake(_ text: String) -> String {
        dropWakeTail(stripWakeRaw(text))
    }

    /// Sep 27: the recognizer often hears "Hey Jarvis Ja" (a repeated tail of the wake word). That "Ja" counted
    /// as a command, so a bare "Hey Jarvis" never got its spoken reply. Drop leftover wake-word fragments.
    private static let wakeTail: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^\s*(?:(?:ja|jar|jarv|jarvi|jarvis|jervis|javis)\b[\s,.!?-]*)+"#, options: [.caseInsensitive])
    }()
    static func dropWakeTail(_ c: String) -> String {
        let ns = c as NSString
        guard let m = wakeTail.firstMatch(in: c, range: NSRange(location: 0, length: ns.length)) else { return c }
        return clean(ns.substring(from: m.range.location + m.range.length))
    }

    private static func stripWakeRaw(_ text: String) -> String {
        if let m = match(text) { return m.command }
        let ns = text as NSString
        if let m = looseStrip.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            return clean(ns.substring(from: m.range.location + m.range.length))
        }
        return clean(text)
    }

    /// The whole command is just "cancel" / "never mind" etc.
    static func isCancel(_ text: String) -> Bool {
        let ns = text as NSString
        return cancelRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// Used during the send countdown: any cancel word at all aborts.
    static func containsCancel(_ text: String) -> Bool {
        let ns = text as NSString
        return cancelAnywhere.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// Near-miss detector for tuning logs: segment starts with a hey-like word or mentions aside.
    static func isNearMiss(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("aside") || t.contains("a side") || t.contains("jarv") || t.contains("jerv") || t.hasPrefix("hey") || t.hasPrefix("pay ")
    }

    static func clean(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let f = out.first, ",.;:-!".contains(f) { out.removeFirst(); out = out.trimmingCharacters(in: .whitespaces) }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if let f = out.first, f.isLowercase { out = f.uppercased() + out.dropFirst() }
        return out
    }
}
