import Foundation

/// Sep 29 "social layer": greetings and small talk get an instant, fitting reply instead of "On it."
///
/// Three tiers, cheapest first:
///   1. Words: a phrase table catches the usual greetings in ~0 ms with no network ("hey, how's it going today?",
///      "good morning", "you there?", "thanks"). A greeting in front of a request ("morning, what's due?") is split
///      off: Jarvis greets back, then the request goes on as normal.
///   2. Jev: odd phrasings ("yo what's good my guy", "long time no see") are judged by Jev in the same call that
///      already routes the turn, so it costs no extra call; mid-conversation, only short words with a social cue ask.
///   3. Otherwise nothing changes: the question goes to the quick answer or the agent exactly as before.
/// Every reply is a fixed line voiced in advance, so it plays the moment you stop talking. Replies know the time of
/// day, a greeting said at the wrong time, and when Jarvis has just asked how you are.
enum SocialKind: String, CaseIterable {
    case hello, wellbeing, yourDay, whatsup, thanks, praise, checkin, back, fine
    case askBack    // "and you?" on its own
    case fineAsk    // "I'm good, you?": his answer plus the question back, so Jarvis answers without asking again
}

enum DayPart: Equatable { case morning, afternoon, evening, late }

struct SocialRead {
    let kind: SocialKind
    let named: DayPart?     // the part of day he said ("good morning"), if any
    let rest: String?       // the request after the greeting; nil when it was only small talk
    let weakOnly: Bool      // only "hey"/"yo": attention, not a greeting worth answering before a request
    var isPure: Bool { rest == nil }
}

enum Social {
    // MARK: reading the words

    /// One word, lowercased, punctuation and apostrophes dropped ("How's" -> "hows").
    nonisolated static func token(_ w: Substring) -> String {
        String(w.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    private struct Phrase { let words: [String]; let kind: SocialKind; let part: DayPart?; let weak: Bool }

    private nonisolated static func p(_ s: String, _ k: SocialKind, _ part: DayPart? = nil, weak: Bool = false) -> Phrase {
        Phrase(words: s.split(separator: " ").map(String.init), kind: k, part: part, weak: weak)
    }

    private nonisolated static let table: [Phrase] = [
        // hello
        p("hey", .hello, weak: true), p("yo", .hello, weak: true), p("hey hey", .hello, weak: true), p("oi", .hello, weak: true),
        p("hi", .hello), p("hello", .hello), p("hiya", .hello), p("heya", .hello), p("howdy", .hello), p("greetings", .hello),
        p("hello hello", .hello), p("hi hi", .hello), p("ello", .hello), p("hullo", .hello), p("wassup", .whatsup), p("hey hi", .hello),
        p("good morning", .hello, .morning), p("morning", .hello, .morning, weak: true), p("mornin", .hello, .morning, weak: true), p("top of the morning", .hello, .morning),
        p("good afternoon", .hello, .afternoon), p("good morning to you", .hello, .morning), p("good afternoon to you", .hello, .afternoon),
        p("good evening to you", .hello, .evening), p("and a good morning to you", .hello, .morning), p("a good morning to you", .hello, .morning), p("afternoon", .hello, .afternoon, weak: true),
        p("good evening", .hello, .evening), p("evening", .hello, .evening, weak: true), p("good day", .hello),
        p("good to see you", .hello), p("nice to see you", .hello), p("long time no see", .hello), p("good to hear you", .hello),
        p("nice to hear you", .hello), p("good to hear your voice", .hello), p("guess who", .back),
        // how are you
        p("how are you", .wellbeing), p("how are ya", .wellbeing), p("how r you", .wellbeing), p("how r u", .wellbeing), p("how are u", .wellbeing),
        p("howre you", .wellbeing), p("how you doing", .wellbeing), p("how you doin", .wellbeing), p("how ya doing", .wellbeing), p("how ya doin", .wellbeing),
        p("how are you doing", .wellbeing), p("how are you doin", .wellbeing), p("how are you feeling", .wellbeing), p("how you feeling", .wellbeing),
        p("hows it going", .wellbeing), p("how is it going", .wellbeing), p("hows it goin", .wellbeing), p("how goes it", .wellbeing), p("how goes", .wellbeing),
        p("hows everything", .wellbeing), p("how is everything", .wellbeing), p("hows things", .wellbeing), p("how are things", .wellbeing),
        p("hows life", .wellbeing), p("how is life", .wellbeing), p("how have you been", .wellbeing), p("how you been", .wellbeing), p("howve you been", .wellbeing),
        p("how you holding up", .wellbeing), p("how are you holding up", .wellbeing), p("hows it hanging", .wellbeing), p("how do you do", .wellbeing),
        p("you good", .wellbeing), p("you alright", .wellbeing), p("are you alright", .wellbeing), p("you okay", .wellbeing), p("are you okay", .wellbeing),
        p("you doing okay", .wellbeing), p("you doing ok", .wellbeing), p("you doing well", .wellbeing), p("you doing alright", .wellbeing),
        p("are you doing well", .wellbeing), p("are you well", .wellbeing), p("hows you", .wellbeing), p("how are we", .wellbeing), p("how are we doing", .wellbeing),
        p("hows your day", .yourDay), p("how is your day", .yourDay), p("hows your day going", .yourDay), p("how is your day going", .yourDay),
        p("hows your day been", .yourDay), p("how has your day been", .yourDay), p("hows your day been going", .yourDay), p("how was your day", .yourDay),
        p("hows your morning", .yourDay), p("hows your morning going", .yourDay), p("how is your morning going", .yourDay),
        p("hows your afternoon", .yourDay), p("hows your afternoon going", .yourDay), p("hows your evening", .yourDay),
        p("hows your evening going", .yourDay), p("how is your evening going", .yourDay), p("hows your night", .yourDay), p("hows your night going", .yourDay),
        p("hows your week", .yourDay), p("hows your week going", .yourDay), p("hows your weekend", .yourDay), p("how was your weekend", .yourDay),
        // what's up
        p("whats up", .whatsup), p("what is up", .whatsup), p("sup", .whatsup), p("whatsup", .whatsup), p("wazzup", .whatsup), p("whats good", .whatsup),
        p("whats new", .whatsup), p("whats cracking", .whatsup), p("whats crackin", .whatsup), p("whats poppin", .whatsup), p("whats popping", .whatsup),
        p("anything new", .whatsup), p("whats happening", .whatsup), p("whats the word", .whatsup), p("what are you up to", .whatsup), p("what you up to", .whatsup),
        // thanks
        p("thanks", .thanks), p("thank you", .thanks), p("thankyou", .thanks), p("thanks a lot", .thanks), p("thanks so much", .thanks),
        p("thank you so much", .thanks), p("thank you very much", .thanks), p("thanks a bunch", .thanks), p("thanks a ton", .thanks), p("cheers", .thanks),
        p("much appreciated", .thanks), p("appreciate it", .thanks), p("i appreciate it", .thanks), p("appreciate you", .thanks), p("i appreciate you", .thanks),
        p("ty", .thanks), p("thx", .thanks), p("many thanks", .thanks), p("thank you kindly", .thanks), p("thanks for that", .thanks), p("thanks for the help", .thanks),
        p("thank you for that", .thanks), p("thank you for the help", .thanks), p("thanks for your help", .thanks), p("thank you for your help", .thanks),
        // praise
        p("good job", .praise), p("great job", .praise), p("nice job", .praise), p("nice work", .praise), p("great work", .praise), p("good work", .praise),
        p("well done", .praise), p("nicely done", .praise), p("good stuff", .praise), p("youre the best", .praise), p("you are the best", .praise),
        p("you rock", .praise), p("youre amazing", .praise), p("you are amazing", .praise), p("youre awesome", .praise), p("you are awesome", .praise),
        p("youre a legend", .praise), p("you legend", .praise), p("love you", .praise), p("i love you", .praise), p("good boy", .praise), p("smart", .praise),
        p("youre smart", .praise), p("youre so smart", .praise), p("youre a genius", .praise), p("genius", .praise), p("brilliant", .praise), p("impressive", .praise),
        // are you there
        p("you there", .checkin), p("are you there", .checkin), p("you awake", .checkin), p("are you awake", .checkin), p("can you hear me", .checkin),
        p("do you hear me", .checkin), p("you listening", .checkin), p("are you listening", .checkin), p("you hear me", .checkin), p("anybody there", .checkin),
        p("anyone there", .checkin), p("anyone home", .checkin), p("testing", .checkin), p("testing testing", .checkin), p("test", .checkin), p("mic check", .checkin),
        p("is this thing on", .checkin), p("you up", .checkin), p("are you up", .checkin), p("still there", .checkin), p("you still there", .checkin),
        p("are you still there", .checkin), p("wake up", .checkin),
        // I'm back
        p("im back", .back), p("i am back", .back), p("im home", .back), p("i am home", .back), p("back again", .back), p("im back home", .back),
        p("guess whos back", .back), p("its me", .back), p("its me again", .back), p("me again", .back), p("honey im home", .back), p("i have returned", .back),
    ]

    /// His answer after Jarvis asked how he is ("good, you?"): only read as such right after that question.
    private nonisolated static let fineTable: [Phrase] = [
        "good", "great", "fine", "okay", "ok", "alright", "well", "not bad", "not too bad", "pretty good", "pretty well", "very good", "very well",
        "good thanks", "great thanks", "fine thanks", "im good", "im great", "im fine", "im okay", "im ok", "im alright", "im well", "im doing good",
        "im doing well", "im doing great", "im doing fine", "im doing okay", "im doing alright", "doing good", "doing well", "doing great", "doing fine",
        "doing okay", "doing alright", "all good", "cant complain", "no complaints", "same old", "same as always", "ive been good", "been good",
        "its been good", "it was good", "it was great", "it was fine", "it was okay", "it went well", "went well", "went good", "good day", "great day",
        "pretty good day", "not bad at all", "really good", "super good", "amazing", "awesome", "fantastic", "excellent", "never better", "good good",
    ].map { p($0, .fine) } + ["you", "and you", "how about you", "what about you", "and yourself", "yourself", "you too", "and u", "u", "hbu", "wbu"]
        .map { p($0, .askBack) }

    /// Words that may sit around a greeting without changing it ("hey jarvis, how's it going today, buddy").
    private nonisolated static let padding: [[String]] = [
        "jarvis", "sir", "um", "uh", "umm", "uhh", "oh", "ah", "so", "well", "okay", "ok", "and", "buddy", "bro", "dude", "mate", "man", "boss",
        "chief", "pal", "friend", "there", "again", "today", "tonight", "lol", "haha", "hahaha", "anyway",
        "my guy", "my man", "my friend", "my dude", "old friend", "old man", "this morning", "this afternoon", "this evening", "so far",
        "yourself", "and you", "and yourself", "how about you", "what about you", "my boy",
        "big guy", "good sir", "clint", "travis", "bud", "lately", "recently", "these days", "treating you", "been treating you",
        "life been treating you", "going for you", "on your end", "over there", "my friend jarvis", "old chap", "sir jarvis",
    ].map { $0.split(separator: " ").map(String.init) }

    /// A greeting followed by one of these is really a question ("what's up with my email", "how are you at chess").
    private nonisolated static let joiners: Set<String> = ["with", "about", "for", "on", "in", "to", "at", "of", "from", "like", "if", "when", "is", "are", "was",
                                                           "were", "that", "this", "the", "a", "an", "my", "your", "his", "her", "their", "our", "than", "as"]

    private nonisolated static let requestStarts: Set<String> = [
        "what", "whats", "when", "whens", "where", "wheres", "who", "whos", "why", "how", "hows", "which", "can", "could", "would", "will", "should",
        "do", "does", "did", "is", "are", "check", "open", "tell", "show", "find", "set", "play", "remind", "send", "search", "look", "give", "get",
        "make", "help", "please", "start", "stop", "turn", "read", "write", "draft", "call", "text", "email", "pull", "any", "whats", "summarize"]

    /// Reads small talk out of what he said. nil: not small talk (or not at the start).
    nonisolated static func read(_ raw: String, afterQuestion: Bool = false) -> SocialRead? {
        let rawWords = raw.split(whereSeparator: { $0.isWhitespace })
        var toks: [String] = [], at: [Int] = []
        for (i, w) in rawWords.enumerated() { let t = token(w); if !t.isEmpty { toks.append(t); at.append(i) } }
        guard !toks.isEmpty, toks.count <= 40 else { return nil }
        // Goodbyes belong to the router, which ends the conversation ("thanks, bye").
        if toks.contains(where: { ["bye", "goodbye", "byebye", "goodnight", "cya"].contains($0) }) { return nil }
        let phrases = fineTable + table

        func matchAt(_ i: Int, _ list: [[String]]) -> Int {
            var best = 0
            for w in list where w.count > best && i + w.count <= toks.count && Array(toks[i..<(i + w.count)]) == w { best = w.count }
            return best
        }

        var i = 0
        var kinds: [SocialKind] = [], part: DayPart?, weakOnly = true
        while i < toks.count {
            // Longest phrase first; padding only counts once something social has been heard, or before it ("so, hi").
            var best: Phrase?
            for ph in phrases where (best == nil || ph.words.count > best!.words.count) && i + ph.words.count <= toks.count
                && Array(toks[i..<(i + ph.words.count)]) == ph.words { best = ph }
            let pad = matchAt(i, padding)
            if let b = best, b.words.count >= pad {
                kinds.append(b.kind)
                if let pp = b.part { part = pp }
                if !b.weak { weakOnly = false }
                i += b.words.count
            } else if pad > 0 {
                i += pad
            } else { break }
        }
        guard !kinds.isEmpty else { return nil }
        // "Good" or "fine" only means "I'm fine" right after Jarvis asked, or when he asks back ("good, you?").
        let asksBack = kinds.contains(.askBack) || kinds.contains(.wellbeing) || kinds.contains(.yourDay)
        if kinds.contains(.fine) && !afterQuestion && !asksBack { return nil }
        if !afterQuestion && !kinds.contains(.fine) { kinds.removeAll { $0 == .askBack } }   // "hey you" is just hello
        if kinds.isEmpty { return nil }
        if kinds.contains(.fine) && asksBack { kinds = [.fineAsk] }
        let order: [SocialKind] = [.fineAsk, .fine, .wellbeing, .yourDay, .askBack, .whatsup, .back, .checkin, .thanks, .praise, .hello]
        let kind = order.first { kinds.contains($0) } ?? .hello

        if i >= toks.count { return SocialRead(kind: kind, named: part, rest: nil, weakOnly: weakOnly) }
        // Words left over: a request after the greeting, unless they bend the greeting into a question.
        if joiners.contains(toks[i]) { return nil }
        // "Thanks, can you..." / "good job, now..." carry on as a request with a short opener; "you there? check..." too.
        let rest = rawWords[at[i]...].joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!?-\u{2014}"))
        // A word or two left over is part of the small talk ("how you been lately"), unless it opens a question or request.
        if toks.count - i <= 2 && !requestStarts.contains(toks[i]) { return SocialRead(kind: kind, named: part, rest: nil, weakOnly: weakOnly) }
        return SocialRead(kind: kind, named: part, rest: rest, weakOnly: weakOnly)
    }

    /// Short words that might be small talk the table missed: worth one Jev check mid-conversation.
    nonisolated static func worthAsking(_ raw: String) -> Bool {
        let toks = raw.split(whereSeparator: { $0.isWhitespace }).map { token($0) }.filter { !$0.isEmpty }
        guard (1...7).contains(toks.count), !Lane.mustUseAgent(raw), !Lane.looksPrivate(raw) else { return false }
        let cues: Set<String> = ["hey", "hi", "hello", "yo", "sup", "wassup", "whats", "how", "hows", "howre", "good", "morning", "evening", "afternoon",
                                 "thanks", "thank", "cheers", "there", "back", "awake", "hear", "listening", "up", "doing", "day", "night", "going",
                                 "see", "miss", "missed", "love", "best", "job", "work", "legend", "buddy", "bro", "dude", "mate", "welcome", "greetings"]
        return toks.contains { cues.contains($0) }
    }

    // MARK: what Jarvis says

    nonisolated static func dayPart(_ d: Date = Date(), _ cal: Calendar = .current) -> DayPart {
        let h = cal.component(.hour, from: d)
        return (4..<12).contains(h) ? .morning : (12..<17).contains(h) ? .afternoon : (17..<22).contains(h) ? .evening : .late
    }

    static let helloMorning = ["Good morning, sir.", "Morning, sir. What can I do for you?", "Good morning. What's on the agenda?", "Morning, sir."]
    static let helloAfternoon = ["Good afternoon, sir.", "Afternoon, sir. What can I do for you?", "Hello, sir. What do you need?", "Good afternoon. What can I do for you?"]
    static let helloEvening = ["Good evening, sir.", "Evening, sir. What can I do for you?", "Hello, sir. What can I do for you this evening?", "Evening, sir."]
    static let helloLate = ["Hello, sir. Up late, I see.", "Evening, sir. Burning the midnight oil?", "Hello, sir. What can I do for you at this hour?"]
    static let helloAny = ["Hello, sir.", "Hello, sir. What can I do for you?", "Hi, sir. What do you need?", "At your service, sir."]

    // A greeting said at the wrong time of day gets a gentle, dry correction.
    static let wrongMorningAfternoon = ["Good afternoon, sir, strictly speaking.", "Afternoon already, sir, but good morning all the same."]
    static let wrongMorningEvening = ["Good evening, sir. Morning was some hours ago.", "Evening, sir, though I admire the optimism."]
    static let wrongMorningLate = ["Good morning, sir. Technically correct.", "Morning, sir, in the loosest sense. Shouldn't you be asleep?"]
    static let wrongEveningMorning = ["Good morning, sir. Evening's a while off yet.", "Morning, sir. You're a little ahead of the clock."]
    static let wrongEveningAfternoon = ["Good afternoon, sir. Evening's not quite here.", "Afternoon, sir. Evening soon enough."]
    static let wrongAfternoonMorning = ["Good morning, sir. The afternoon's still a way off.", "Morning, sir. Getting ahead of the day?"]
    static let wrongAfternoonEvening = ["Good evening, sir. The afternoon got away from us.", "Evening, sir, as it happens."]

    static let wellbeing = ["Very well, thank you, sir. And you?", "All systems running smoothly, sir. How are you?", "Quite well, sir. And yourself?",
                            "Can't complain, sir. What can I do for you?", "In fine form, sir. How about you?", "Running like clockwork, sir. And you?"]
    static let wellbeingLate = ["Wide awake, sir, which is more than I'd expect of you. How are you holding up?", "Perfectly well, sir. The question is how you are at this hour."]
    static let wellbeingAfterGreeting = ["Very well, thank you. And you?", "All running smoothly. How are you?", "Quite well. And yourself?"]
    static var greetedWellbeing: [String] {
        ["Good morning, sir.", "Good afternoon, sir.", "Good evening, sir."].flatMap { g in wellbeingAfterGreeting.map { g + " " + $0 } }
    }
    static let yourDay = ["Quiet, sir, which is how I like it. How was yours?", "Uneventful, sir. How's yours been?", "Pleasantly dull, sir. And yours?",
                          "Steady, thank you. How about yours, sir?"]
    static let whatsup = ["Not much, sir. What can I do for you?", "All quiet on my end, sir. What do you need?", "Just keeping an eye on things. What's on your mind?",
                          "Nothing I can't handle, sir. What can I do for you?", "The usual, sir. What do you need?"]
    static let thanks = ["My pleasure, sir.", "Anytime, sir.", "Happy to help.", "Of course, sir.", "Don't mention it, sir.", "Always a pleasure."]
    static let praise = ["I do try, sir.", "Just doing my job, sir.", "Kind of you to say, sir.", "Thank you, sir. I'll try not to let it go to my head."]
    static let checkin = ["Right here, sir.", "Loud and clear, sir.", "Always, sir. What do you need?", "I'm here, sir.", "Present and listening, sir."]
    static let back = ["Welcome back, sir.", "Welcome back. What can I do for you?", "Good to have you back, sir.", "Ah, welcome back, sir."]
    static let backFromSchool = ["Welcome back, sir. How was school?", "Welcome home, sir. How did today go?"]
    static let fineAsk = ["Glad to hear it, sir. All's well on my end.", "Good to hear. I'm well, thank you, sir.", "Excellent. All running smoothly here, sir.",
                          "Glad to hear it. Quite well myself, thank you."]
    static let fine = ["Glad to hear it, sir. What can I do for you?", "Good to hear. What's on your mind?", "Excellent. What can I do for you, sir?",
                       "Glad to hear it, sir.", "Very good. What do you need?"]

    // Short openers said before getting on with a request ("Morning, sir." then "Let me check your calendar.").
    static let openHelloMorning = ["Morning, sir.", "Good morning."], openHelloAfternoon = ["Afternoon, sir.", "Good afternoon."]
    static let openHelloEvening = ["Evening, sir.", "Good evening."], openHelloAny = ["Hello, sir.", "Hi, sir."]
    static let openWellbeing = ["Very well, sir.", "Quite well, thank you."], openThanks = ["My pleasure.", "Of course."]
    static let openPraise = ["Thank you, sir.", "Kind of you."], openBack = ["Welcome back, sir.", "Welcome back."], openFine = ["Glad to hear it.", "Good to hear."]

    static var all: [String] {
        helloMorning + helloAfternoon + helloEvening + helloLate + helloAny + wrongMorningAfternoon + wrongMorningEvening + wrongMorningLate
            + wrongEveningMorning + wrongEveningAfternoon + wrongAfternoonMorning + wrongAfternoonEvening + wellbeing + wellbeingLate + yourDay
            + whatsup + thanks + praise + checkin + back + backFromSchool + fine + openHelloMorning + openHelloAfternoon + openHelloEvening
            + openHelloAny + openWellbeing + openThanks + openPraise + openBack + openFine + greetedWellbeing + fineAsk
    }

    private static func helloLines(named: DayPart?, now: Date) -> [String] {
        let part = dayPart(now)
        let h = Calendar.current.component(.hour, from: now)
        if let n = named, n != part {
            switch (n, part) {
            case (.morning, .afternoon): return wrongMorningAfternoon
            case (.morning, .evening): return wrongMorningEvening
            case (.morning, .late): return h < 4 ? wrongMorningLate : wrongMorningEvening
            case (.evening, .morning): return wrongEveningMorning
            case (.evening, .afternoon): return wrongEveningAfternoon
            case (.afternoon, .morning): return wrongAfternoonMorning
            case (.afternoon, .evening), (.afternoon, .late): return wrongAfternoonEvening
            default: break   // "good evening" late at night is fine
            }
        }
        switch part {
        case .morning: return helloMorning + (named == nil ? helloAny : [])
        case .afternoon: return helloAfternoon + (named == nil ? helloAny : [])
        case .evening: return helloEvening + (named == nil ? helloAny : [])
        case .late: return named == nil ? helloLate + helloAny : helloEvening
        }
    }

    /// The whole reply to pure small talk.
    static func line(for r: SocialRead, now: Date = Date()) -> String {
        let part = dayPart(now)
        switch r.kind {
        case .hello: return Acks.pick(helloLines(named: r.named, now: now))
        case .wellbeing:
            // "Good morning, how are you?" answers both at once.
            // "Good morning, how are you?" answers both at once, greeting with the real time of day.
            if r.named != nil {
                let greet = part == .morning ? "Good morning, sir." : part == .afternoon ? "Good afternoon, sir." : "Good evening, sir."
                return greet + " " + Acks.pick(wellbeingAfterGreeting)
            }
            return Acks.pick(part == .late && Calendar.current.component(.hour, from: now) < 4 ? wellbeingLate + wellbeing : wellbeing)
        case .yourDay: return Acks.pick(yourDay)
        case .whatsup: return Acks.pick(whatsup)
        case .thanks: return Acks.pick(thanks)
        case .praise: return Acks.pick(praise)
        case .checkin: return Acks.pick(checkin)
        case .back:
            let cal = Calendar.current
            let h = cal.component(.hour, from: now), wd = cal.component(.weekday, from: now)
            if (2...6).contains(wd) && (15..<18).contains(h) && Double.random(in: 0..<1) < 0.6 { return Acks.pick(backFromSchool) }
            return Acks.pick(back)
        case .fine: return Acks.pick(fine)
        case .fineAsk: return Acks.pick(fineAsk)
        case .askBack: return Acks.pick(wellbeing)
        }
    }

    /// A short opener before a request, or nil when a greeting there would just be noise ("hey", "what's up", "you there").
    static func opener(for r: SocialRead, now: Date = Date()) -> String? {
        if r.weakOnly { return nil }
        switch r.kind {
        case .hello:
            switch dayPart(now) {
            case .morning: return Acks.pick(openHelloMorning)
            case .afternoon: return Acks.pick(openHelloAfternoon)
            case .evening: return Acks.pick(openHelloEvening)
            case .late: return Acks.pick(r.named == .evening ? openHelloEvening : openHelloAny)
            }
        case .wellbeing, .yourDay, .askBack: return Acks.pick(openWellbeing)
        case .thanks: return Acks.pick(openThanks)
        case .praise: return Acks.pick(openPraise)
        case .back: return Acks.pick(openBack)
        case .fine, .fineAsk: return Acks.pick(openFine)
        case .whatsup, .checkin: return nil
        }
    }

    /// True when the reply asked how he is, so his next few words ("good, you?") are read as his answer.
    nonisolated static func asksHowHeIs(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.hasSuffix("?") && ["and you?", "how are you?", "and yourself?", "how about you?", "how was yours?", "how's yours been?",
                                     "and yours?", "how about yours, sir?", "how was school?", "how did today go?", "holding up?"]
            .contains { l.hasSuffix($0) }
    }

    /// Jev's small-talk answer mapped to a kind (nil: not small talk, or not sure enough).
    nonisolated static func kind(fromJev choice: String) -> SocialKind? {
        switch choice {
        case "hello": return .hello
        case "wellbeing": return .wellbeing
        case "whatsup": return .whatsup
        case "thanks": return .thanks
        case "praise": return .praise
        case "checkin": return .checkin
        case "back": return .back
        default: return nil
        }
    }
}
