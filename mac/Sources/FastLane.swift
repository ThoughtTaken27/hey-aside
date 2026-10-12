import Foundation
import QuartzCore

/// Sep 28 "fast lane": how Jarvis answers plain questions and starts real requests without making you wait.
///
/// Before, one turn ran its stages in a row: Jev decided (~0.9 s), then the text model wrote the whole reply
/// (1.8-4.5 s, with a 13 s stall seen), and only then did the agent start. Now they overlap:
///   - the moment your words look finished (half the silence window, or the end of a sentence), Jev's route
///     question and the text model's streamed reply start together; the send countdown hides the rest;
///   - speech waits only for Jev's verdict and starts at the first finished sentence, not the whole reply;
///   - requests that plainly need tools start the agent at once, with the spoken acknowledgement written alongside;
///   - time, date and day come from the clock, with no network at all.
/// Jev still only decides (it cannot write words): it stays the gate, the text model only ever writes.
/// Anything doubtful goes to the agent exactly as before. `defaults write app.heyaside.mac fastLane -bool false`
/// turns the whole thing off.
enum Lane {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "fastLane") as? Bool ?? true }

    /// Lowercase words only: letters, digits and apostrophes, single-spaced.
    nonisolated static func norm(_ s: String) -> String {
        let t = s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let kept = t.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "'" ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    // Words that mean live data, his own data, or doing something: straight to the agent, no waiting on anyone.
    // Same list Jev's door uses, except "today", "now" and "text", which small talk uses too ("how's it going
    // today?"): Jev's route question judges those.
    private nonisolated static let needsAgent = try! NSRegularExpression(pattern:
        #"\b(tonight|tomorrow|yesterday|current(ly)?|latest|recent|news|weather|forecast|score|price|stock|open|close[sd]?|hours|near me|my|mine|remind|schedule|agenda|meetings?|appointments?|to[- ]?dos?|tasks?|deadlines?|calendar|email|mail|inbox|message|send|search|look up|find|google|play|book|buy|order|set|turn|tab|browser|file|folder|download|homework|assignment|grade|schoology|due|next week|this week|what time|what day|what's the date|date today)\b"#,
        options: [.caseInsensitive])

    // Text that looks private never goes to a model from here (mirrors the door's privateText guard).
    private nonisolated static let privateRules: [NSRegularExpression] = [
        #"\b(verification|security|one[- ]?time|login|log[- ]in|sign[- ]?in|access|confirmation|authentication|2fa|two[- ]factor|passcode|otp|pin)\s*(code|number|pin|link)\b"#,
        #"\b\d{4,8}\b\s*(is|as)\s*(your|the)\b"#,
        #"\b(your|the)\s+code\s*(is|:)\s*\S+"#,
        #"\b(reset|change|recover)\s+(your\s+)?password\b|\bpassword\s+(reset|recovery|change)\b|\bmagic\s+link\b"#,
        #"\b(new|unusual|suspicious)\s+(sign[- ]?in|login|log[- ]in|device|activity)\b|\bsecurity\s+(alert|notice|check)\b|\baccount\s+(locked|suspended|compromised)\b"#,
        #"\b(account|card)\s+(ending|number)\b|\bstatement\s+is\s+(ready|available)\b|\b(balance|deposit|withdrawal|transfer|wire|direct deposit|payment\s+(received|sent|due|failed)|transaction|refund\s+issued|overdraft)\b"#,
        #"\b(routing|iban|swift|ifsc)\b"#,
        #"\b(uscis|i-?94|i-?797|i-?20|i-?539|ds-?160|ds-?2019|sevis|ead|green\s*card|visa|passport|consulate|embassy|immigration|biometrics|naturali[sz]ation|h-?4|l-?2|l-?1|h-?1b|f-?1|social\s+security|ssn|itin|aadhaar|pan\s+card|oci)\b"#,
        #"\b(diagnos\w*|prescription|pharmacy|lab\s+results?|test\s+results?|patient\s+portal|medical|doctor|appointment\s+(reminder|confirmed)|insurance\s+(claim|card)|explanation\s+of\s+benefits|vaccin\w*|therap\w*|dental|dentist)\b"#,
        #"\b(tax\s+(return|document|form)|w-?2|1099|1098|irs|subpoena|lawsuit|attorney|notari[sz]\w*|court)\b"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private nonisolated static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    nonisolated static func looksPrivate(_ s: String) -> Bool { privateRules.contains { matches($0, s) } }

    /// True when the words plainly need the agent (live data, his data, or an action), or are too long for a quick reply.
    nonisolated static func mustUseAgent(_ s: String) -> Bool {
        let n = norm(s)
        return n.count > 240 || matches(needsAgent, n)
    }

    /// Have you probably finished? Used to start work early, during the silence window (never to end your turn).
    nonisolated static func looksFinished(_ cmd: String, silence: TimeInterval) -> Bool {
        let t = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = norm(t).split(separator: " ").map(String.init)
        guard words.count >= 2, let last = t.last else { return false }
        let ended = ".?!".contains(last)
        if !ended, let lw = words.last, Endpointer.danglingWords.contains(lw) { return false }
        // Sep 30: earlier than the (now shorter) end of turn, so the answer still gets its head start.
        return (ended && silence >= 0.35) || (words.count >= 4 && silence >= 0.6)
    }
}

// MARK: - answers that need no network

/// "What time is it", "what's the date": answered from the Mac's clock, instantly and always right.
enum LocalAnswers {
    private nonisolated static let timeAsks: Set<String> = [
        "what time is it", "what's the time", "whats the time", "what is the time", "what time do you have", "the time",
        "what time it is", "got the time", "what time is it there", "have the time", "what's the time now",
    ]
    private nonisolated static let dateAsks: Set<String> = [
        "what's the date", "whats the date", "what is the date", "what's today's date", "whats todays date", "what is today's date",
        "what is todays date", "what date is it", "what's the date today", "what is the date today", "whats the date today",
        "what day is it", "what day is it today", "what day of the week is it", "what day of the week is it today", "what's today",
        "whats today", "what is today", "what's the day today", "what is the day today", "the date", "today's date", "todays date",
        "what day it is", "what date it is",
    ]
    private nonisolated static let lead: Set<String> = ["hey", "hi", "hello", "jarvis", "ok", "okay", "so", "um", "uh", "and", "quick", "question", "please", "just"]
    private nonisolated static let trail: Set<String> = ["please", "sir", "jarvis", "now", "right", "again", "there"]
    private nonisolated static let asks: [[String]] = [["can", "you", "tell", "me"], ["could", "you", "tell", "me"], ["would", "you", "tell", "me"],
                                                       ["do", "you", "know"], ["do", "you", "have"], ["tell", "me"], ["i", "was", "wondering"]]

    nonisolated static func instant(_ raw: String, now: Date = Date(), calendar: Calendar = .current, sir: Bool = false) -> String? {
        var w = Lane.norm(raw).split(separator: " ").map(String.init)
        while let f = w.first, lead.contains(f) { w.removeFirst() }
        while let l = w.last, trail.contains(l), w.count > 2 { w.removeLast() }
        for a in asks where w.count > a.count && Array(w.prefix(a.count)) == a { w.removeFirst(a.count); break }
        let core = w.joined(separator: " ")
        let tail = sir ? ", sir." : "."
        if timeAsks.contains(core) { return "It's \(spokenTime(now, calendar))\(tail)" }
        if dateAsks.contains(core) { return "It's \(spokenDate(now, calendar))\(tail)" }
        return nil
    }

    private nonisolated static let hourWords = ["twelve", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven"]
    private nonisolated static let minuteWords = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
                                                  "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "twenty-one", "twenty-two", "twenty-three",
                                                  "twenty-four", "twenty-five", "twenty-six", "twenty-seven", "twenty-eight", "twenty-nine"]

    /// "ten past two in the afternoon", "quarter to eight in the morning", "noon", "midnight".
    nonisolated static func spokenTime(_ d: Date, _ cal: Calendar = .current) -> String {
        let h = cal.component(.hour, from: d), m = cal.component(.minute, from: d)
        func period(_ hour: Int) -> String { hour < 12 ? "in the morning" : hour < 17 ? "in the afternoon" : hour < 21 ? "in the evening" : "at night" }
        func hourWord(_ hour: Int) -> String { hourWords[hour % 12] }
        if m == 0 {
            if h == 0 { return "midnight" }
            if h == 12 { return "noon" }
            return "\(hourWord(h)) o'clock \(period(h))"
        }
        if m <= 30 {
            let mins: String
            switch m { case 15: mins = "quarter past"; case 30: mins = "half past"
            case 5, 10, 20, 25: mins = "\(minuteWords[m]) past"
            default: mins = "\(minuteWords[m]) minute\(m == 1 ? "" : "s") past" }
            return "\(mins) \(hourWord(h)) \(period(h))"
        }
        let left = 60 - m, next = (h + 1) % 24
        let mins: String
        switch left { case 15: mins = "quarter to"
        case 5, 10, 20, 25: mins = "\(minuteWords[left]) to"
        default: mins = "\(minuteWords[left]) minute\(left == 1 ? "" : "s") to" }
        if next == 0 { return "\(mins) midnight" }
        if next == 12 { return "\(mins) noon" }
        return "\(mins) \(hourWord(next)) \(period(next))"
    }

    private nonisolated static let ordinals = ["", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth",
                                               "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth", "twentieth",
                                               "twenty-first", "twenty-second", "twenty-third", "twenty-fourth", "twenty-fifth", "twenty-sixth", "twenty-seventh",
                                               "twenty-eighth", "twenty-ninth", "thirtieth", "thirty-first"]

    /// "Monday the twenty-eighth of September".
    nonisolated static func spokenDate(_ d: Date, _ cal: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = cal; f.locale = Locale(identifier: "en_GB"); f.timeZone = cal.timeZone
        f.dateFormat = "EEEE"
        let weekday = f.string(from: d)
        f.dateFormat = "MMMM"
        let month = f.string(from: d)
        let day = cal.component(.day, from: d)
        return "\(weekday) the \(ordinals[min(max(day, 1), 31)]) of \(month)"
    }
}

// MARK: - what is fit to say out loud

enum Speakable {
    private nonisolated static let banned = try! NSRegularExpression(pattern: #"^(got it|on it|sure|certainly|absolutely|of course|great|okay|ok|no problem|will do|understood)\b"#, options: [.caseInsensitive])
    private nonisolated static let claimsDone = try! NSRegularExpression(pattern: #"\b(done|i've|i have|completed|all set|is set|are set|has been|have been|sent|booked|scheduled|finished|sorted|handled|taken care|on it|here (is|are))\b"#, options: [.caseInsensitive])
    private nonisolated static let cutOff = try! NSRegularExpression(pattern: #"\b(a|an|the|to|of|for|near|and|with|what|at|in|on|your)$"#, options: [.caseInsensitive])
    private nonisolated static let refusal = try! NSRegularExpression(pattern: #"^(i (can'?t|cannot|don'?t have|do not have|am unable to|'m unable to)\b.{0,40}\b(access|browse|check|real[- ]time|live|current|up[- ]to[- ]date|look up|internet|search)|as an ai\b)"#, options: [.caseInsensitive])

    private nonisolated static func has(_ re: NSRegularExpression, _ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    /// No markdown, no dashes, no stage directions: one clean spoken line.
    nonisolated static func clean(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\\s*[\u{2014}\u{2013}]\\s*", with: ", ", options: .regularExpression)
            .replacingOccurrences(of: #"[*_`#]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"^[,;:\s]+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(jarvis|assistant)\s*:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019} ")).trimmingCharacters(in: .whitespaces)
    }

    /// The first sentence of a quick answer: a real answer, not a refusal to know, a list, or a runaway.
    nonisolated static func answerOK(_ s: String) -> Bool {
        let words = s.split(separator: " ").count
        if s.isEmpty || words > 60 || s.count > 400 { return false }
        if s.hasPrefix("-") || s.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil { return false }
        return !has(refusal, s)
    }

    /// A short model-written line said while the agent works (a status). nil = say nothing rather than something off.
    nonisolated static func ack(_ raw: String) -> String? {
        var out = clean(raw)
        if let r = out.range(of: #"^[^.!?]+[.!?]?"#, options: .regularExpression) { out = String(out[r]).trimmingCharacters(in: .whitespaces) }
        let words = out.split(separator: " ").count
        let cut = !(out.hasSuffix(".") || out.hasSuffix("!")) && has(cutOff, out)
        if out.isEmpty || cut || words < 2 || words > 18 || out.contains("?") || has(banned, out) || has(claimsDone, out) { return nil }
        return (out.hasSuffix(".") || out.hasSuffix("!")) ? out : out + "."
    }
}

/// Cuts a token stream into sentences as they finish. A sentence is released only once the next one has started
/// (or the stream ends), so "Dr.", "U.S." and "3.5" never split a sentence in half.
struct SentenceSplitter {
    private var buf = ""
    private nonisolated static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "st", "vs", "etc", "jr", "sr", "prof", "inc", "ltd", "co", "no", "approx", "e.g", "i.e", "u.s", "u.k"]

    mutating func push(_ delta: String) -> [String] {
        buf += delta
        var out: [String] = []
        while let cut = SentenceSplitter.boundary(in: buf) {
            let s = String(buf[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            buf = String(buf[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
        }
        return out
    }

    /// The unfinished remainder at the end of the stream (nil if there is none).
    mutating func flush() -> String? {
        let s = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        buf = ""
        return s.isEmpty ? nil : s
    }

    /// Index just past the first finished sentence, only when the next sentence has visibly begun.
    nonisolated static func boundary(in s: String) -> String.Index? {
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "." || c == "!" || c == "?" || c == "\u{2026}" {
                var j = s.index(after: i)
                while j < s.endIndex, "\"')\u{201D}\u{2019}".contains(s[j]) { j = s.index(after: j) }
                guard j < s.endIndex, s[j].isWhitespace else { i = s.index(after: i); continue }
                var k = j
                while k < s.endIndex, s[k].isWhitespace { k = s.index(after: k) }
                guard k < s.endIndex else { return nil }   // wait: the next sentence hasn't started yet
                if c == "." {
                    // "Dr. Smith", "J. K. Rowling", "vs. the": not the end of a sentence.
                    var b = i
                    while b > s.startIndex, s[s.index(before: b)].isLetter || s[s.index(before: b)] == "." { b = s.index(before: b) }
                    let word = String(s[b..<i])
                    if abbreviations.contains(word.lowercased()) || (word.count == 1 && word.first!.isUppercase) || s[k].isLowercase { i = s.index(after: i); continue }
                }
                return k
            }
            i = s.index(after: i)
        }
        return nil
    }
}

// MARK: - the two services

struct LaneVerdict {
    let route: String, p: Double, confidence: Double
    let ms: Int
    /// Sep 29: small talk Jev is sure of ("yo what's good my guy"), answered with a ready line. nil: not small talk.
    var social: SocialKind? = nil
    var fast: Bool { route == "chat" && p >= 0.85 && confidence >= 0.6 }
}

/// Jev's route question, asked through the same budgeted door as everything else on this Mac (`jev ask`): same
/// budget, same seven-day cache, same private-text refusal. The question is word for word the one `jev route` asks,
/// so answers already cached there are reused.
enum LaneJev {
    // Sep 29: asked in the same call as the route, so telling small talk apart costs nothing extra.
    nonisolated static let socialQuestion = #""social":{"type":"choice","instructions":"Is this only small talk aimed at the assistant, with nothing else asked for? If so, which kind? Choose other if it also asks a real question, asks for anything, or is about something else.","criteria":{"hello":"Only saying hello or greeting the assistant","wellbeing":"Only asking how the assistant is doing or how its day is going","whatsup":"Only asking what is up or what is new, as small talk","thanks":"Only thanking the assistant","praise":"Only praising or complimenting the assistant","checkin":"Only checking the assistant is there, awake, or can hear them","back":"Only saying they are back or home","other":"A question, a request, a reaction to something, or anything else"}}"#
    private nonisolated static let questions = #""route":{"type":"choice","instructions":"What does answering this need?","criteria":{"chat":"Nothing beyond general knowledge: small talk, a joke, a definition, a fact that does not change, simple math or unit conversion, or general advice","live":"Current or changing information: news, weather, sports, prices, opening hours, recent events, or today's date","personal":"Their own things: their email, calendar, schoolwork, grades, files, notes, browser, or past conversations","action":"Doing something: opening, searching, sending, reminding, writing a document, buying, booking, or controlling the computer"}}"#

    nonisolated static func requestJSON(_ raw: String) -> Data? {
        let t = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let lit = try? JSONEncoder().encode(String("Someone just said this to their voice assistant: \"\(t.prefix(400))\"")),
              let state = String(data: lit, encoding: .utf8) else { return nil }
        return Data(#"{"state":\#(state),"tier":"you","feature":"jarvis.turn","questions":{\#(questions),\#(socialQuestion)}}"#.utf8)
    }

    /// Only the small-talk question (mid-conversation, where the route doesn't matter).
    nonisolated static func socialJSON(_ raw: String) -> Data? {
        let t = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let lit = try? JSONEncoder().encode(String("Someone just said this to their voice assistant: \"\(t.prefix(200))\"")),
              let state = String(data: lit, encoding: .utf8) else { return nil }
        return Data(#"{"state":\#(state),"tier":"you","feature":"jarvis.social","questions":{\#(socialQuestion)}}"#.utf8)
    }

    /// Small talk Jev is sure of: its choice above 0.8 with confidence 0.6 or more.
    nonisolated static func socialKind(_ answers: [String: Any]?) -> SocialKind? {
        guard let q = answers?["social"] as? [String: Any], let choice = q["choice"] as? String,
              let conf = q["confidence"] as? Double, let probs = q["probabilities"] as? [String: Double],
              (probs[choice] ?? 0) >= 0.8, conf >= 0.6 else { return nil }
        return Social.kind(fromJev: choice)
    }

    nonisolated static func parse(_ data: Data) -> LaneVerdict? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["ok"] as? Bool == true,
              let route = (obj["answers"] as? [String: Any])?["route"] as? [String: Any],
              let choice = route["choice"] as? String, let conf = route["confidence"] as? Double,
              let probs = route["probabilities"] as? [String: Double] else { return nil }
        return LaneVerdict(route: choice, p: probs[choice] ?? 0, confidence: conf, ms: obj["ms"] as? Int ?? 0,
                           social: socialKind(obj["answers"] as? [String: Any]))
    }

    /// Mid-conversation: is this short thing small talk? nil when not, unsure, or Jev is slow or unavailable.
    static func social(_ text: String, timeout: TimeInterval = 1.5) async -> SocialKind? {
        guard FastPath.available, let input = socialJSON(text) else { return nil }
        let started = CACurrentMediaTime()
        let (code, data) = await ask(input, timeout: timeout)
        let ms = Int((CACurrentMediaTime() - started) * 1000)
        guard code == 0, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["ok"] as? Bool == true else {
            Log.write("social: jev unavailable (exit \(code), \(ms) ms\(why(data)))"); return nil
        }
        let k = socialKind(obj["answers"] as? [String: Any])
        Log.write("social: jev says \(k?.rawValue ?? "not small talk") in \(ms) ms")
        return k
    }

    static func route(_ text: String, timeout: TimeInterval = 3.5) async -> LaneVerdict? {
        guard FastPath.available, let input = requestJSON(text) else { return nil }
        let started = CACurrentMediaTime()
        let result = await ask(input, timeout: timeout)
        let ms = Int((CACurrentMediaTime() - started) * 1000)
        guard result.0 == 0, let v = parse(result.1) else {
            Log.write("lane: jev route unavailable (exit \(result.0), \(ms) ms\(why(result.1)))")
            return nil
        }
        return v
    }

    /// ", private" / ", budget" ...: why the door said no, when it said (the reason was dropped before Sep 30).
    nonisolated static func why(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let w = obj["why"] as? String else { return "" }
        return ", " + String(w.prefix(60))
    }

    /// One question to Jev's door: (0, reply) when it answered, (3, reply) when it said no, -2 on timeout.
    /// Sep 30: straight over the socket (no Node start-up); the `jev ask` command only if the socket can't be reached.
    private static func ask(_ input: Data, timeout: TimeInterval) async -> (Int32, Data) {
        if JevSocket.available {
            switch await JevSocket.post("/ask", body: input, timeout: timeout) {
            case .body(let d):
                let ok = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["ok"] as? Bool == true
                return (ok ? 0 : 3, d)
            case .failed: return (-2, Data())
            case .unreachable: break
            }
        }
        return await askCLI(input, timeout: timeout)
    }

    private static func askCLI(_ input: Data, timeout: TimeInterval) async -> (Int32, Data) {
        await withCheckedContinuation { (c: CheckedContinuation<(Int32, Data), Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: FastPath.node)
            p.arguments = [FastPath.script, "ask"]
            let inPipe = Pipe(), outPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = FileHandle.nullDevice
            let once = OnceFlag()
            p.terminationHandler = { proc in
                let d = outPipe.fileHandleForReading.readDataToEndOfFile()
                if once.fire() { c.resume(returning: (proc.terminationStatus, d)) }
            }
            do { try p.run() } catch { if once.fire() { c.resume(returning: (-1, Data())) }; return }
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
                if once.fire() { c.resume(returning: (-2, Data())) }
            }
        }
    }
}

/// The quick voice model: a text model behind your local 9router (configured in Aside as the provider "9router"),
/// called directly with no Aside session, so the first word comes in about a second. Never a Claude model.
/// Override with `defaults write app.heyaside.mac fastModel -string <9router model id>`.
enum LaneModel {
    struct Endpoint { let url: URL; let key: String; let model: String; var codexAccount: String? = nil }

    nonisolated static var modelID: String { UserDefaults.standard.string(forKey: "fastModel") ?? "oc/space-bunny-free" }

    private nonisolated(unsafe) static var cached: (at: CFTimeInterval, ep: Endpoint?)?
    /// Drop the cached token (after a 401, or when Aside may have refreshed it).
    static func invalidate() { cached = nil }

    static func endpoint() -> Endpoint? {
        if let c = cached, CACurrentMediaTime() - c.at < 30 { return c.ep }
        var ep: Endpoint?
        let model = modelID
        let home = FileManager.default.homeDirectoryForCurrentUser
        if model.range(of: "claude|anthropic|bedrock", options: [.regularExpression, .caseInsensitive]) != nil {
            ep = nil
        } else {
            let file = URL(fileURLWithPath: AsideRoot.path + "/models.json")
            if let data = try? Data(contentsOf: file), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let providers = (root["providers"] as? [String: Any]) ?? root
                if let p = providers["9router"] as? [String: Any], let base = p["baseUrl"] as? String, let key = p["apiKey"] as? String,
                   let u = URL(string: base.hasSuffix("/") ? String(base.dropLast()) + "/chat/completions" : base + "/chat/completions"),
                   u.host == "localhost" || u.host == "127.0.0.1" {
                    ep = Endpoint(url: u, key: key, model: model)
                }
            }
        }
        cached = (CACurrentMediaTime(), ep)
        return ep
    }

    /// One request body for either transport. Codex speaks the Responses API: system text becomes `instructions`.
    nonisolated static func requestBody(_ ep: Endpoint, messages: [[String: String]], maxTokens: Int, temperature: Double) -> Data? {
        guard ep.codexAccount != nil else {
            return try? JSONSerialization.data(withJSONObject: ["model": ep.model, "messages": messages, "temperature": temperature, "max_tokens": maxTokens, "stream": true] as [String: Any])
        }
        let instructions = messages.filter { $0["role"] == "system" }.compactMap { $0["content"] }.joined(separator: "\n\n")
        let input: [[String: Any]] = messages.filter { $0["role"] != "system" }.map { m in
            let assistant = m["role"] == "assistant"
            return ["type": "message", "role": assistant ? "assistant" : "user",
                    "content": [["type": assistant ? "output_text" : "input_text", "text": m["content"] ?? ""]]]
        }
        var body: [String: Any] = ["model": ep.model, "instructions": instructions, "input": input, "stream": true, "store": false,
                                   "reasoning": ["effort": UserDefaults.standard.string(forKey: "fastEffort") ?? "none"]]
        if (UserDefaults.standard.string(forKey: "fastSpeed") ?? "fast") == "fast" { body["service_tier"] = "priority" }
        return try? JSONSerialization.data(withJSONObject: body)
    }

    /// The text piece in one streamed line (nil when the line carries none).
    nonisolated static func delta(fromLine line: String, codex: Bool) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let d = payload.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        if codex {
            guard j["type"] as? String == "response.output_text.delta", let t = j["delta"] as? String, !t.isEmpty else { return nil }
            return t
        }
        guard let t = (((j["choices"] as? [[String: Any]])?.first?["delta"]) as? [String: Any])?["content"] as? String, !t.isEmpty else { return nil }
        return t
    }

    private final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var winner = -1
        func claim(_ id: Int) -> Bool { lock.lock(); defer { lock.unlock() }; if winner == -1 { winner = id }; return winner == id }
        var decided: Bool { lock.lock(); defer { lock.unlock() }; return winner != -1 }
    }

    private nonisolated static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.httpMaximumConnectionsPerHost = 4
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private nonisolated(unsafe) static var lastWarm: CFTimeInterval = 0
    /// Oct 2: opens the connection to the model while you are still talking (the wake phrase), so the first reply
    /// doesn't pay the ~0.3-0.8 s handshake. The empty request is refused and ignored; no tokens are used.
    static func warmUp() {
        guard CACurrentMediaTime() - lastWarm > 40, let ep = endpoint() else { return }
        lastWarm = CACurrentMediaTime()
        var req = URLRequest(url: ep.url)
        req.httpMethod = "HEAD"
        session.dataTask(with: req).resume()
    }

    /// Streams the reply as text deltas, in order. If nothing has arrived after `hedgeAfter` seconds a second identical
    /// request is sent and whichever speaks first wins (a 13 s stall was seen; the second one is normally 1-2 s).
    /// Cancelling the consuming task, or dropping the stream, closes the connection.
    nonisolated static func stream(_ ep: Endpoint, messages: [[String: String]], maxTokens: Int, temperature: Double, hedgeAfter: TimeInterval = 2.0) -> AsyncStream<String> {
        AsyncStream { cont in
            let body = requestBody(ep, messages: messages, maxTokens: maxTokens, temperature: temperature)
            let codex = ep.codexAccount != nil
            let race = Race()
            let producer = Task.detached {
                @Sendable func attempt(_ id: Int) async {
                    var req = URLRequest(url: ep.url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.setValue("Bearer \(ep.key)", forHTTPHeaderField: "authorization")
                    if let account = ep.codexAccount {
                        req.setValue(account, forHTTPHeaderField: "chatgpt-account-id")
                        req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
                        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
                        req.setValue(UUID().uuidString, forHTTPHeaderField: "session_id")
                        req.setValue("text/event-stream", forHTTPHeaderField: "accept")
                    }
                    req.httpBody = body
                    do {
                        let (bytes, resp) = try await session.bytes(for: req)
                        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                        guard code == 200 else {
                            if code == 401 || code == 403 { LaneModel.invalidate() }
                            Log.write("lane: \(ep.model) HTTP \(code)")
                            return
                        }
                        for try await line in bytes.lines {
                            if Task.isCancelled { return }
                            if !codex, line.hasPrefix("data:"), line.contains("[DONE]") { return }
                            guard let delta = LaneModel.delta(fromLine: line, codex: codex) else { continue }
                            if !race.claim(id) { return }
                            cont.yield(delta)
                        }
                    } catch { }
                }
                await withTaskGroup(of: Void.self) { g in
                    g.addTask { await attempt(0) }
                    g.addTask {
                        try? await Task.sleep(nanoseconds: UInt64(hedgeAfter * 1e9))
                        if Task.isCancelled || race.decided { return }
                        await attempt(1)
                    }
                }
                cont.finish()
            }
            cont.onTermination = { _ in producer.cancel() }
        }
    }

    // MARK: prompts

    nonisolated static func clock(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US"); f.dateFormat = "EEEE, MMMM d, h:mm a"
        return f.string(from: d)
    }

    /// Said instead of an answer when the question needs tools (live data, his things, or doing something).
    nonisolated static let handoff = "HANDOFF"

    nonisolated static func answerPrompt(_ now: Date = Date()) -> String {
        [
            "You are Jarvis, the user's voice assistant on their Mac; your reply is read aloud in a British voice.",
            "It is \(clock(now)) where he is.",
            "Be composed, precise, and quietly witty, like a sharp friend rather than a customer-service bot. Call him \"sir\" now and then, not every reply. Dry humour only when it fits, never on serious or school answers.",
            "Match his register: casual if he is casual, brief if he is brief. Work out what he actually meant even if speech recognition garbled a word.",
            "Lead with the actual answer (the number, the name, the fact) in one or two short natural sentences, each under 20 words; it is spoken, so keep it brisk. No markdown, no lists, no lead-ins like \"Great question\", never open with \"Sure\" or \"Certainly\".",
            "If his words look cut off or too garbled to act on, ask one short question about what he meant instead of guessing.",
            "Never claim feelings or experiences of your own (not \"that surprised me\").",
            "Only state facts you are sure of. Never add trivia or colour you are not certain is true, and never make a joke a claim of fact.",
            "If he is just chatting (\"thanks\", \"nice\", \"how are you\"), reply in one short natural line.",
            "If a good answer needs live or changing information (news, weather, prices, scores, today's events), his own things (email, calendar, schoolwork, grades, files, notes, browser) beyond what this conversation already says, or doing something on his Mac or online, reply with exactly \(handoff) and nothing else.",
        ].joined(separator: " ")
    }

    /// Oct 2: the first thing Jarvis says when he takes a job to the agent, written for this request (no canned "On it").
    nonisolated static func openerPrompt(now: Date = Date()) -> String {
        [
            "You are JARVIS, the user's voice assistant on their Mac, speaking out loud in a British voice. Composed, warm, quietly witty; say \"sir\" only now and then.",
            "It is \(clock(now)).",
            "He just asked for something you are now starting to do with tools. Output only the exact words to speak: one short line, 3 to 11 words, that shows you understood exactly what he wants, the way a sharp human assistant would before going off to do it. Name the specific thing (the place, the class, the item).",
            "Never state a result, fact, number, time or name you were not told; never say or imply it is done; never ask a question. No quotes, no emoji, no markdown.",
            "Never open with \"Got it\", \"On it\", \"Sure\", \"Certainly\", \"Okay\", \"Understood\" or \"Let me look into that\".",
            "Examples of the register only (never reuse their words): \"Boone's weekend forecast, coming up.\" / \"Pulling what's due this week.\" / \"Checking the AP Lit syllabus for that.\"",
        ].joined(separator: "\n")
    }

    /// Sep 28: the short spoken status while the agent works, written from its real steps, never from imagination.
    nonisolated static func statusPrompt(now: Date = Date()) -> String {
        [
            "You are JARVIS, the user's voice assistant on their Mac, speaking out loud in a British voice. Composed, warm, quietly witty; say \"sir\" now and then, not every time.",
            "It is \(clock(now)).",
            "He asked for something and you are in the middle of doing it with tools. You will be told his request, the steps you have taken so far (latest last), and what you already said to him.",
            "Output only the exact words to speak: one short status line, 3 to 12 words, about what you are doing right now. No quotes, no emoji, no markdown.",
            "Ground it only in the steps and his request. Never state a result, fact, number, name, price or time you were not told, and never describe what you have found so far (not \"prices are high\", \"lots of options\", \"being stubborn\"); never say or imply it is done; never ask a question.",
            "Never open with \"Got it\", \"On it\", \"Sure\", \"Certainly\", \"Okay\" or \"Understood\". Use different words from anything you already said.",
            "If you have already given an update, this one may note that it is taking a little while. Examples of the register only (never reuse their words): \"Going through tomorrow's forecast now.\" / \"Still combing through your inbox, sir.\" / \"Cross-checking a couple of sources.\"",
        ].joined(separator: "\n")
    }
}

// MARK: - one spoken line from the model

/// Writes one short spoken line in the background and hands it over the moment it is ready (nil: nothing fit to say).
@MainActor
final class LaneLine {
    private(set) var line: String?
    private(set) var done = false
    private var task: Task<Void, Never>?

    init?(system: String, messages: [[String: String]], label: String) {
        guard let ep = LaneModel.endpoint() else { return nil }
        let msgs = [["role": "system", "content": system]] + messages
        let started = CACurrentMediaTime()
        task = Task { @MainActor in
            var splitter = SentenceSplitter()
            var raw = ""
            // Sep 30: Space Bunny sometimes reasons before it writes, and 60 tokens were spent thinking: every status line came
            // back empty ("rejected (\"\")" six times running). The room is for thinking; the line itself is cut at one sentence.
            for await delta in LaneModel.stream(ep, messages: msgs, maxTokens: 400, temperature: 0.7, hedgeAfter: 1.6) {
                if let first = splitter.push(delta).first { raw = first; break }
            }
            if raw.isEmpty, !Task.isCancelled { raw = splitter.flush() ?? "" }
            self.line = Speakable.ack(raw)
            self.done = true
            Log.write("lane: \(label) \(self.line == nil ? "rejected (\"\(raw.prefix(80))\")" : "ready") in \(Int((CACurrentMediaTime() - started) * 1000)) ms")
        }
    }

    func wait(timeout: TimeInterval) async -> String? {
        let deadline = CACurrentMediaTime() + timeout
        while !done, CACurrentMediaTime() < deadline, !Task.isCancelled { try? await Task.sleep(nanoseconds: 15_000_000) }
        return line
    }

    func cancel() { task?.cancel(); if !done { done = true } }
}

// MARK: - what Jarvis says while he works

/// The instant line when Jarvis takes something on. Local and voiced in advance, so it plays with no wait at all;
/// picked by what you asked for, never the same line twice running.
enum Fillers {
    nonisolated static let lookup = ["Let me look into that.", "Let me check, sir.", "Looking into it now.", "One moment, sir.", "Let me find out."]
    nonisolated static let schedule = ["Let me check your schedule.", "Pulling up your calendar, sir.", "One moment, checking your calendar."]
    nonisolated static let mail = ["Let me check your inbox.", "Opening your mail now, sir.", "One moment, going through your mail."]
    nonisolated static let remind = ["Setting that up now.", "Right away, sir.", "One moment, sir."]
    nonisolated static let action = ["On it.", "Right away, sir.", "On it, sir.", "Straight away.", "Leave it with me."]
    nonisolated static let general = ["On it.", "One moment, sir.", "Let me look into that.", "Leave it with me, sir.", "Right away."]
    nonisolated static let thinking = ["Let me think.", "Hmm, one moment.", "Let me see."]
    nonisolated static let adding = ["Noted, sir.", "I'll fold that in.", "Adding that now.", "Noted."]
    nonisolated static var all: [String] { lookup + schedule + mail + remind + action + general + thinking + adding }

    private nonisolated static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    private nonisolated static let mailWords = re(#"\b(e-?mails?|inbox|mail|messages?|texts?|imessages?|slack|dms?)\b"#)
    private nonisolated static let scheduleWords = re(#"\b(calendar|schedule|agenda|meetings?|appointments?|events?|free (time|slot)|busy)\b"#)
    private nonisolated static let remindWords = re(#"\b(remind|reminder|timer|alarm|wake me)\b"#)
    private nonisolated static let actionWords = re(#"^(please |can you |could you |would you |jarvis,? )*(open|send|play|make|write|draft|create|order|book|turn|start|close|add|save|move|put|reply|text|call|pause|stop|delete|rename|download|install|run|fill|submit|post|share|clean|organi[sz]e|set)\b"#)
    private nonisolated static let lookupWords = re(#"\b(search|find|look ?up|look into|check|what|what's|whats|who|when|where|which|how|why|is there|are there|weather|news|price|cost|score|latest|due)\b"#)

    nonisolated static func kind(_ text: String) -> [String] {
        let t = Lane.norm(text)
        func has(_ r: NSRegularExpression) -> Bool { r.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil }
        if has(remindWords) { return remind }
        if has(mailWords) { return mail }
        if has(scheduleWords) { return schedule }
        if has(actionWords) { return action }
        if has(lookupWords) { return lookup }
        return general
    }

    nonisolated static func pick(for text: String, busy: Bool = false) -> String { Acks.pick(busy ? adding : kind(text)) }
    nonisolated static func thinkingLine() -> String { Acks.pick(thinking) }
}

/// Spoken status while the agent works: the model writes it from the real steps; if it's slow, off, or the words look
/// private, a plain line built from the latest step ("Searching the web now.") is used instead.
enum LaneStatus {
    @MainActor
    static func line(request: String, steps: [String], said: [String], allowSir: Bool = true, timeout: TimeInterval) async -> String? {
        let clean = steps.filter { !Lane.looksPrivate($0) }.suffix(4)
        guard !Lane.looksPrivate(request), clean.count == steps.suffix(4).count else { return nil }
        var user = "His request: \"\(String(request.prefix(300)))\"\nSteps so far: " + (clean.isEmpty ? "(just starting)" : clean.joined(separator: "; "))
        if !said.isEmpty { user += "\nAlready said to him: " + said.map { "\"\($0)\"" }.joined(separator: " ") }
        guard let l = LaneLine(system: LaneModel.statusPrompt(), messages: [["role": "user", "content": user]], label: "status") else { return nil }
        let out = await l.wait(timeout: timeout)
        l.cancel()
        guard let out, !said.contains(where: { similar($0, out) }) else { return nil }
        return allowSir ? out : dropSir(out)
    }

    /// The model says "sir" in nearly every line; the controller allows it only now and then.
    nonisolated static func dropSir(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #",\s*sir\s*([,.!])"#, with: "$1", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"^sir,\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #",,"#, with: ",", options: .regularExpression)
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    /// "Searching the web" -> "Searching the web now." first, "Still searching the web." later. nil without a usable step.
    nonisolated static func fallback(step: String?, said: [String]) -> String? {
        guard let step = step?.trimmingCharacters(in: CharacterSet(charactersIn: " .\u{2026}")), step.split(separator: " ").count >= 2,
              !step.lowercased().hasPrefix("thinking") else {
            return said.isEmpty ? nil : (said.contains("Still working on it, sir.") ? nil : "Still working on it, sir.")
        }
        let lower = step.prefix(1).lowercased() + step.dropFirst()
        let line = said.isEmpty ? "\(step) now." : "Still \(lower)."
        return said.contains(where: { similar($0, line) }) ? nil : line
    }

    /// Same opening three words, ignoring case: close enough to sound repetitive.
    nonisolated static func similar(_ a: String, _ b: String) -> Bool {
        func head(_ s: String) -> String { s.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).prefix(3).joined(separator: " ") }
        return head(a) == head(b)
    }
}

// MARK: - one turn

/// Everything decided about one thing you said: answer it from the clock, hand it straight to the agent, or (for plain
/// questions) let Jev judge while the reply is already being written. Started early (speculation) when your words look
/// finished; the controller picks it up when your turn really ends, or throws it away if the words changed.
@MainActor
final class LaneTurn {
    enum Plan { case instant(String), social(String), agent, candidate }

    let text: String, key: String
    let plan: Plan
    /// Sep 29: a greeting before the request ("Morning, sir."), said first; the rest is judged on its own.
    let opener: String?
    /// The request with any greeting in front taken off (what Jev, the clock and the quick answer see).
    let core: String
    let startedAt = CACurrentMediaTime()
    private let history: [(q: String, a: String)]
    private(set) var verdict: LaneVerdict?
    private(set) var verdictDone = false
    private(set) var sentences: [String] = []
    private(set) var streamEnded = false
    private(set) var cancelled = false
    private(set) var firstSentenceMs: Int?
    private(set) var verdictMs: Int?
    private var failed = false
    /// Luna said the question needs tools (HANDOFF).
    private(set) var handedOff = false
    private var openerLine: LaneLine?
    private var tasks: [Task<Void, Never>] = []

    init(text: String, history: [(q: String, a: String)], now: Date = Date(), sir: Bool = Double.random(in: 0..<1) < 0.4, afterQuestion: Bool = false, agentOnly: Bool = false) {
        self.text = text
        self.key = Lane.norm(text)
        self.history = history
        let social = Social.read(text, afterQuestion: afterQuestion)
        let core = (social?.rest).flatMap { r in social?.weakOnly == true ? nil : r } ?? text
        self.core = core
        if agentOnly { plan = .agent; opener = social.flatMap { $0.rest == nil ? nil : Social.opener(for: $0, now: now) } }
        else if let s = social, s.isPure { plan = .social(Social.line(for: s, now: now)); opener = nil }
        else {
            opener = social.flatMap { $0.rest == nil ? nil : Social.opener(for: $0, now: now) }
            if let line = LocalAnswers.instant(core, now: now, sir: sir && opener == nil) { plan = .instant(line) }
            else if Lane.looksPrivate(text) || Lane.mustUseAgent(core) { plan = .agent }
            else { plan = .candidate }
        }
        switch plan {
        case .instant, .social: verdictDone = true; streamEnded = true
        case .agent: startOpener()
        case .candidate: startDecision(); startAnswer(now)
        }
    }

    /// Oct 2: the spoken first line for a job going to the agent, written by the model while you finish talking.
    func startOpener() {
        guard openerLine == nil, !Lane.looksPrivate(text) else { return }
        var user = "His request: \"\(String(core.prefix(400)))\""
        if let h = history.last { user = "Just before, he asked \"\(String(h.q.prefix(200)))\".\n" + user }
        openerLine = LaneLine(system: LaneModel.openerPrompt(), messages: [["role": "user", "content": user]], label: "opener")
    }

    /// The opener, once written (nil: none fit to say within `timeout`).
    func opener(timeout: TimeInterval) async -> String? {
        if openerLine == nil { startOpener() }
        return await openerLine?.wait(timeout: timeout)
    }

    var planName: String { switch plan { case .instant: return "instant"; case .social: return "social"; case .agent: return "agent"; case .candidate: return "candidate" } }

    /// Safe to speak this instant, so the send countdown can end early: nothing here is sent to Aside.
    var readyToSpeak: Bool {
        switch plan {
        case .instant, .social: return true
        case .agent: return false
        case .candidate: return (verdict?.social != nil && opener == nil) || (verdict?.fast == true && !sentences.isEmpty)
        }
    }

    private func startDecision() {
        tasks.append(Task { @MainActor in
            let v = await LaneJev.route(self.core)
            self.verdict = v
            self.verdictDone = true
            self.verdictMs = Int((CACurrentMediaTime() - self.startedAt) * 1000)
            if let v { Log.write("lane: jev \(v.route) p=\(String(format: "%.2f", v.p)) conf=\(String(format: "%.2f", v.confidence))\(v.social.map { " social=\($0.rawValue)" } ?? "") in \(self.verdictMs!) ms") }
        })
    }

    private func startAnswer(_ now: Date) {
        guard let ep = LaneModel.endpoint() else { streamEnded = true; return }
        var msgs: [[String: String]] = [["role": "system", "content": LaneModel.answerPrompt(now)]]
        for h in history.suffix(3) { msgs.append(["role": "user", "content": String(h.q.prefix(400))]); msgs.append(["role": "assistant", "content": String(h.a.prefix(600))]) }
        msgs.append(["role": "user", "content": String(core.prefix(400))])
        tasks.append(Task { @MainActor in
            var splitter = SentenceSplitter()
            for await delta in LaneModel.stream(ep, messages: msgs, maxTokens: 500, temperature: 0.3, hedgeAfter: 1.5) {   // room to reason first; cut at two sentences
                for s in splitter.push(delta) { self.accept(s) }
                if self.sentences.count >= 2 || self.failed || self.cancelled { break }
            }
            // The last sentence only counts if it finished (a reply cut off by the length limit is not worth saying).
            if !self.failed, self.sentences.count < 2, let tail = splitter.flush() {
                if tail.uppercased().hasPrefix(LaneModel.handoff) { self.handedOff = true; self.failed = true }
                else if let last = tail.last, ".!?\u{201D}\"')".contains(last) { self.accept(tail) }
            }
            self.streamEnded = true
            if !self.cancelled { Log.write("lane: reply \(self.handedOff ? "handed off" : "\(self.sentences.count) sentence(s)"), first at \(self.firstSentenceMs.map { "\($0) ms" } ?? "never")") }
        })
    }

    private func accept(_ raw: String) {
        let s = Speakable.clean(raw)
        if s.uppercased().hasPrefix(LaneModel.handoff) { handedOff = true; failed = true; return }
        guard !s.isEmpty, sentences.count < 2 else { return }
        if sentences.isEmpty {
            guard Speakable.answerOK(s) else { failed = true; return }
            firstSentenceMs = Int((CACurrentMediaTime() - startedAt) * 1000)
        } else if s.split(separator: " ").count > 32 || (sentences + [s]).joined(separator: " ").split(separator: " ").count > 70 {
            // A runaway sentence is a mouthful out loud: stop at what's been said.
            streamEnded = true; return
        }
        sentences.append(s)
    }

    /// Jev's verdict (nil if it was unavailable, private, or took longer than `timeout`).
    func decision(timeout: TimeInterval) async -> LaneVerdict? {
        let deadline = CACurrentMediaTime() + timeout
        while !verdictDone, !cancelled, CACurrentMediaTime() < deadline { try? await Task.sleep(nanoseconds: 15_000_000) }
        return verdict
    }

    /// Sentence `i` of the reply, as soon as it exists (nil: the reply ended, failed, or was too slow).
    func sentence(_ i: Int, timeout: TimeInterval) async -> String? {
        let deadline = CACurrentMediaTime() + timeout
        while !cancelled {
            if i < sentences.count { return sentences[i] }
            if streamEnded || failed || CACurrentMediaTime() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return nil
    }

    func cancel() {
        cancelled = true
        tasks.forEach { $0.cancel() }
        openerLine?.cancel()
    }
}
