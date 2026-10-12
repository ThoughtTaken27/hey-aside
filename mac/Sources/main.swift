import FoundationModels
import AppKit
import AVFoundation
import ServiceManagement

extension Array where Element: Equatable {
    var adjacentPairsDiffer: Bool { zip(self, dropFirst()).allSatisfy { $0 != $1 } }
}

// MARK: - Command-line test modes

let args = CommandLine.arguments

// `HeyAside --announce "text"`: asks the running Hey Aside to say something (for Aside routines).
// It still follows the quiet-hours and presence rules, so a routine can call it any time.
if let i = args.firstIndex(of: "--announce"), i + 1 < args.count {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("app.heyaside.mac.announce"), object: args[i + 1], userInfo: nil, deliverImmediately: true)
    print("sent")
    exit(0)
}

// `HeyAside --remind "2026-09-27T18:00" "text"`: Jarvis says it at that time (Sep 27). `--reminders` lists them.
if let i = args.firstIndex(of: "--remind") {
    guard i + 2 < args.count, let at = ReminderStore.parse(args[i + 1]) else {
        print("usage: HeyAside --remind \"YYYY-MM-DDTHH:MM\" \"what to say\""); exit(64)
    }
    let text = args[(i + 2)...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { print("nothing to say"); exit(64) }
    guard at.timeIntervalSinceNow > -60 else { print("that time has passed: \(at)"); exit(65) }
    let r = ReminderStore.add(at: at, text: text)
    let f = DateFormatter(); f.dateFormat = "EEE h:mm a"
    print("reminder set for \(f.string(from: r.at)): \(r.text)")
    exit(0)
}
if args.contains("--reminders") {
    let f = DateFormatter(); f.dateFormat = "EEE MMM d h:mm a"
    for r in ReminderStore.load().sorted(by: { $0.at < $1.at }) { print("\(r.fired ? "done" : "due ") \(f.string(from: r.at))  \(r.text)") }
    exit(0)
}

func runUnitTests() -> Int32 {
    var fails = 0
    func check(_ name: String, _ ok: Bool) { print(ok ? "PASS" : "FAIL", name); if !ok { fails += 1 } }
    // Hey Jarvis (Sep 25). Recognizer output from the 30-clip accent corpus in tests/jarvis.
    WakeMatcher.phrase = .jarvis
    for (t, want) in [("Hey, Jarvis, what do I have due today?", "What do I have due today?"), ("Hey Jarvis what do I have do today", "What do I have do today"),
                      ("Jarvis, what time is it?", "What time is it?"), ("Hey Jarvis.", ""), ("Um, hey Jarvis, open my email", "Open my email"),
                      ("Okay Jarvis, summarize this page", "Summarize this page"), ("Hey Jervis, what's next", "What's next"), ("Hey jar vis open Gmail", "Open Gmail")] {
        check("jarvis: \(t)", WakeMatcher.match(t)?.command == want)
    }
    for t in ["Jarvis is so cool in Iron Man", "Jarvis was the AI in the movie", "I love how Jarvis talks", "Hey Travis, want to grab lunch?",
              "Hey Aside, open Gmail", "Hey guys, look at this"] {
        check("no-jarvis: \(t)", WakeMatcher.match(t) == nil)
    }
    WakeMatcher.phrase = .both
    check("both: jarvis", WakeMatcher.match("Hey Jarvis, open Gmail")?.command == "Open Gmail")
    check("both: aside", WakeMatcher.match("Hey Aside, open Gmail")?.command == "Open Gmail")
    let pos: [(String, String)] = [
        ("Hey Aside, what's due tomorrow on Schoology?", "What's due tomorrow on Schoology?"),
        ("Pay aside, open my Gmail and summarize unread emails.", "Open my Gmail and summarize unread emails."),
        ("Hey, aside, open my mail.", "Open my mail."),
        ("hey a side check my calendar", "Check my calendar"),
        ("Um, hey Aside, what's the weather", "What's the weather"),
        ("Hey Aside.", ""),
        ("Hi Aside, remind me at 5", "Remind me at 5"),
        ("Okay Aside, summarize this page", "Summarize this page"),
        ("Hey Aside's there a quiz tomorrow", "There a quiz tomorrow"),
    ]
    for (t, want) in pos { let m = WakeMatcher.match(t); check("wake: \(t) -> \(m?.command ?? "nil")", m?.command == want) }
    let neg = [
        "I'm going to put that aside for now and grab some lunch.",
        "Okay, a side note, the meeting moved to Friday.",
        "Hey, a side note: the meeting moved.",
        "Aside from that, we're good.",
        "Hey, aside from that, it works.",
        "Set it aside.",
        "Okay aside from the homework",
        "They set aside time",
        "Hey guys, look at this side",
        "A side of fries please",
        "How do you assign?",
    ]
    for t in neg { check("no-wake: \(t)", WakeMatcher.match(t) == nil) }
    check("cancel: 'Cancel.'", WakeMatcher.isCancel("Cancel."))
    check("cancel: 'never mind'", WakeMatcher.isCancel("never mind"))
    check("not cancel: 'cancel my 3pm meeting'", !WakeMatcher.isCancel("cancel my 3pm meeting"))
    check("stripWake revised", WakeMatcher.stripWake("Hey aside, open Gmail") == "Open Gmail")
    let ep = Endpointer(baseSilence: 1.2)
    check("ep: sentence ends", ep.requiredSilence(for: "Open Gmail.") == 1.2)
    check("ep: dangling 'and'", ep.requiredSilence(for: "Open Gmail and") > 2.0)
    check("ep: no punctuation", abs(ep.requiredSilence(for: "Open Gmail") - 1.2) < 0.01)
    var epSmart = Endpointer(baseSilence: 1.2); epSmart.smart = true
    var epOff = Endpointer(baseSilence: 1.2); epOff.smart = false
    check("ep smart: finished question is quick", abs(epSmart.requiredSilence(for: "What's the capital of Australia?") - 0.6) < 0.01)
    check("ep smart: 4+ word question, no punctuation yet", abs(epSmart.requiredSilence(for: "what's the capital of Australia") - 0.85) < 0.01)
    check("ep smart: dangling still waits", epSmart.requiredSilence(for: "What's the weather in") > 2.0)
    check("ep smart: short fragment waits the full window", abs(epSmart.requiredSilence(for: "So yeah") - 1.2) < 0.01)
    check("ep smart: never longer than base", Endpointer(baseSilence: 0.5, smart: true).requiredSilence(for: "Who wrote Hamlet?") <= 0.5)
    check("ep smart off: base only", abs(epOff.requiredSilence(for: "What's the capital of Australia?") - 1.2) < 0.01)
    check("ep: finish after silence", ep.decide(now: 10, wakeAt: 5, lastActivity: 8.7, command: "Open Gmail.") == .finish)
    check("ep: keep while talking", ep.decide(now: 10, wakeAt: 5, lastActivity: 9.5, command: "Open Gmail.") == .keepListening)
    check("ep: empty waits", ep.decide(now: 10, wakeAt: 6, lastActivity: 6, command: "") == .keepListening)
    check("ep: empty times out", ep.decide(now: 15, wakeAt: 6, lastActivity: 6, command: "") == .timeoutNoCommand)
    check("ep: max length", ep.decide(now: 60, wakeAt: 5, lastActivity: 59.9, command: "x") == .maxLength)
    check("shortcut Alt+Q", AsidePopup.parse("Alt+Q").map { $0.key == 12 && $0.flags == .maskAlternate } ?? false)
    check("shortcut Ctrl+Shift+Space", AsidePopup.parse("Ctrl+Shift+Space").map { $0.key == 49 && $0.flags.contains(.maskControl) && $0.flags.contains(.maskShift) } ?? false)
    // Aside CLI output parsing (real samples captured Sep 24)
    let E = "\u{1B}"
    let simple = "\(E)[2mcreated new session: wkgao53z87HscKGx\(E)[0m\n\(E)[2mThinking: casual greeting.\n\n\(E)[0m\nDoing well, and ready to work.\n\nWhat's on your plate?\(E)[0m\n"
    let p1 = AsideCLI.parse(simple)
    check("cli: session id", p1.sessionID == "wkgao53z87HscKGx")
    check("cli: answer skips thinking", p1.answer == "Doing well, and ready to work.\n\nWhat's on your plate?" && p1.error == nil)
    let tool = "\(E)[2mcreated new session: 11mxoff6KKBrqoU5\(E)[0m\n\(E)[2mThinking: wants time.\(E)[0m\n\n\(E)[32mget_time\(E)[0m()\n\n\(E)[2m > Thursday 10:26 PM\(E)[0m\n\(E)[2mThinking: ok.\(E)[0m\nIt's **10:26 PM**.\(E)[0m\n"
    check("cli: answer after tool call", AsideCLI.parse(tool).answer == "It's **10:26 PM**.")
    let err = "\(E)[2mcreated new session: Kxs21AON9LFHaVgn\(E)[0m\n\n \u{2022} \(E)[31mError\(E)[0m Session not found: Kxs21AON9LFHaVgn\n"
    let pe = AsideCLI.parse(err)
    check("cli: error detected", pe.error == "Session not found: Kxs21AON9LFHaVgn")
    let resume = "\(E)[2mcontinuing existing session: 11mxoff6KKBrqoU5\(E)[0m\n\(E)[2mThinking: Thursday.\(E)[0m\nIt's **Thursday**.\(E)[0m\n"
    check("cli: resume id + answer", AsideCLI.parse(resume).sessionID == "11mxoff6KKBrqoU5" && AsideCLI.parse(resume).answer == "It's **Thursday**.")
    // Spoken text
    check("speech: strips markdown", SpokenText.from("It's **Thursday**.") == "It's Thursday.")
    check("speech: cuts detail after ---", SpokenText.from("You have two things due.\n\n---\n- Chem lab\n- Calc quiz") == "You have two things due.")
    check("speech: bullets become sentences", !SpokenText.from("Due:\n- **Chem** lab\n- [Calc](https://x.com) quiz").contains("*"))
    check("speech: long answers trimmed", SpokenText.from("One. Two. Three. Four. Five. Six. Seven. Eight.").hasSuffix("The rest is in Aside."))
    // Follow-up dismissals
    check("followup: sign-offs end, small talk doesn't", !Controller.isDismissal("Thanks!") && !Controller.isDismissal("Oh, that's cool.") && Controller.isDismissal("that's all") && Controller.isDismissal("No, thank you.") && Controller.isDismissal("That'll be all, Jarvis.") && Controller.isDismissal("Goodnight"))
    check("followup: real request continues", !Controller.isDismissal("thanks, now email it to me") && !Controller.isDismissal("what about Friday"))
    check("voice: first chunk is short", Speaker.chunks("Sure. Your lab is due tomorrow. Want a plan?").first == "Sure.")
    let longFirst = Speaker.chunks("Leonardo da Vinci painted the Mona Lisa, sometime between fifteen oh three and fifteen nineteen in Florence. It hangs in the Louvre.")
    check("voice: long first sentence cut at its first comma", longFirst.first == "Leonardo da Vinci painted the Mona Lisa," && longFirst.count == 2 && longFirst[1].hasPrefix("sometime between"))
    check("voice: short first sentence kept whole", Speaker.chunks("All systems running smoothly, sir. How are you?").first == "All systems running smoothly, sir.")
    check("no self-wake: voice sample", WakeMatcher.match("Hey Alex, it's Aside. This is how I'll sound when I answer you.") == nil)
    check("no self-wake: typical reply", WakeMatcher.match("Hey, it's Aside here. You have a chemistry lab due tomorrow.") == nil)
    // Talking while Aside works
    check("router: stop", Router.intent("stop", agentBusy: true) == .stop && Router.intent("cancel that", agentBusy: true) == .stop)
    check("router: status", Router.intent("what are you doing right now?", agentBusy: true) == .status && Router.intent("how's it going", agentBusy: true) == .status)
    check("router: steer", Router.intent("actually, check Friday instead", agentBusy: true) == .steer && Router.intent("wait, use my school email", agentBusy: true) == .steer)
    check("router: queue", Router.intent("also email me the list", agentBusy: true) == .queue)
    check("router: new question when idle", Router.intent("what's the weather tomorrow", agentBusy: false) == .queue)
    check("router: end", Router.intent("that's all", agentBusy: true) == .endConversation && Router.intent("thanks", agentBusy: false) == .queue && Router.intent("bye", agentBusy: false) == .endConversation)
    check("router: thanks while busy isn't goodbye", Router.intent("thanks", agentBusy: true) != .endConversation)
    let stream = "\u{1B}[2mcreated new session: abc123\u{1B}[0m\n\u{1B}[32mrepl\u{1B}[0m(code: 'x', title: 'Opening Schoology')\n\u{1B}[2m > ok\u{1B}[0m\n"
    check("stream: step title", AgentRun.stepTitle(tool: "repl", args: "(code: 'x', title: 'Opening Schoology')") == "Opening Schoology" && AgentRun.segments(stream).count >= 3)
    check("stream: known tool name", AgentRun.stepTitle(tool: "get_time", args: "()") == "Checking the time")
    // Mishearings observed in the Sep 24 accent test
    for (t, want) in [("Hey side, what's due tomorrow?", "What's due tomorrow?"), ("Hey, side, what time is it", "What time is it"),
                      ("Hey as side, what's due tomorrow", "What's due tomorrow"), ("Hit aside what time is it?", "What time is it?"),
                      ("He aside what time is it?", "What time is it?"), ("Here, aside what time is it?", "What time is it?")] {
        check("wake+: \(t)", WakeMatcher.match(t)?.command == want)
    }
    for t in ["Hey Siri, what time is it?", "He sided with me on that.", "Hey, side note, I'm running late.", "He is on my side.",
              "Hi, side effects are rare.", "Here, side dish is ready.", "His side of the story is different.", "Hey, side walk chalk is fun."] {
        check("no-wake+: \(t)", WakeMatcher.match(t) == nil)
    }
    // Real CLI output (Sep 24): argument strings are green too; only real tool calls may become steps.
    let E2 = "\u{1B}"
    let realSkill = "\n\(E2)[32mread_file\(E2)[0m(path: \(E2)[32m'/Users/alex/.aside/u/0/skills/user/daily-planner/SKILL.md'\(E2)[39m)\(E2)[2m [call_1]\(E2)[0m\n"
    let rc = AgentRun.toolCalls(in: realSkill, final: true)
    check("replay: skill read -> friendly step", rc.count == 1 && AgentRun.stepTitle(tool: rc[0].name, args: rc[0].args) == "Using your Daily planner skill")
    let realRepl = "\n" + E2 + "[32mrepl" + E2 + "[0m(code: " + E2 + "[32m\"await openTab('https://x.com');\\n\"" + E2 + "[39m +\n       "
        + E2 + "[32m'const s1 = 1;\\n'" + E2 + "[39m,\n     title: " + E2 + "[32m'Opening Schoology home'" + E2 + "[39m)" + E2 + "[2m [call_2]" + E2 + "[0m\n"
    let rr = AgentRun.toolCalls(in: realRepl, final: true)
    check("replay: code strings are not steps", rr.count == 1 && AgentRun.stepTitle(tool: rr[0].name, args: rr[0].args) == "Opening Schoology home")
    check("replay: untitled unknown tool hidden", AgentRun.stepTitle(tool: "some_new_tool", args: "(x: 1)") == nil)
    check("router: 'can you just' redirects", Router.intent("Can you just tell me from your memories really quickly?", agentBusy: true) == .steer)
    let lines = HUDController.captionLines("You have four things due today and two are already done and graded. The other two are Progress Check 2 from this afternoon and the Atwood pre-lab due at midnight.")
    check("captions: split into single lines", lines.count >= 3 && lines.joined(separator: " ").hasSuffix("midnight."))
    check("noise: fillers ignored", Router.isNoise("You know.") && Router.isNoise("Um, uh") && Router.isNoise("Hmm."))
    check("noise: real replies kept", !Router.isNoise("Yeah") && !Router.isNoise("No") && !Router.isNoise("Oh that's cool") && !Router.isNoise("Okay thanks"))
    check("backchannel: listener feedback", Router.isBackchannel("Yeah.") && Router.isBackchannel("Mm-hmm, okay") && Router.isBackchannel("Got it, right"))
    check("backchannel: real turns", !Router.isBackchannel("Yeah, open Gmail") && !Router.isBackchannel("Wait, stop") && !Router.isBackchannel("What about tomorrow?"))
    check("steps: -ing form", AgentRun.polishStep("Open Claude usage settings") == "Opening Claude usage settings" && AgentRun.polishStep("Sum Opus costs across sessions") == "Summing Opus costs across sessions")
    check("steps: no file names", AgentRun.polishStep("List state.db tables") == "Listing tables" && AgentRun.polishStep("Checking the time") == "Checking the time")
    do {
        let c = Calendar.current
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date { c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))! }
        check("quiet: school (Fri 10 AM)", Proactive.quietReason(at(2026, 9, 25, 10, 0)) == "school hours")
        check("quiet: after school (Fri 3:20 PM)", Proactive.quietReason(at(2026, 9, 25, 15, 20)) == nil)
        check("quiet: sleep (Sat 1 AM)", Proactive.quietReason(at(2026, 9, 26, 1, 0)) == "sleep hours")
        check("quiet: weekend day (Sat 10 AM)", Proactive.quietReason(at(2026, 9, 26, 10, 0)) == nil)
        check("quiet: 11 PM", Proactive.quietReason(at(2026, 9, 25, 23, 5)) == "sleep hours")
    }
    check("heads-up: long task line", SpokenText.isHeadsUp("This will take a few minutes, sir. I'll let you know.") && !SpokenText.isHeadsUp("Let me check your Schoology."))
    check("summon echo stripped", Controller.stripSummonEcho("Yes, sir? What's due tomorrow?") == "What's due tomorrow?" && Controller.stripSummonEcho("Yes") == "" && Controller.stripSummonEcho("Sir?") == "" && Controller.stripSummonEcho("Open Gmail") == "Open Gmail")
    // Sep 24 11:38 PM: Aside put everything after the divider; the spoken part must still carry the items.
    let realAnswer = "Yeah, here are the five I had saved as due Thursday.\n---\n**The two already done**\n- Group Work Reflection, AP Lit, due 7:47am.\n- Marked graded 5 out of 5, no action left.\n- 2.3/3 HW, Calculus Honors, due 2:59pm.\n**The three still open in memory**\n- Progress Check 2, AP Lit, due 3pm.\n- Page was blank with Submit live.\n- Lit Circle Book in Class, AP Lit, due 11:59pm.\n- Atwood Machine Pre-Lab Questions, Physics, due 11:59pm.\n- 100 points, Labs 30 percent, one attempt only.\nAll from the Sep 24 planner run."
    let spokenReal = SpokenText.from(realAnswer)
    check("speech: lead-in gets the items", spokenReal.contains("Progress Check 2") && spokenReal.contains("Atwood") && spokenReal.contains("Lit Circle"))
    check("speech: noise lines skipped", !spokenReal.contains("Page was blank") && !spokenReal.contains("100 points"))
    check("speech: good answers untouched", SpokenText.from("You have three left: Progress Check 2 by 3, your Lit Circle book by midnight, and the Atwood pre-lab by midnight.\n---\n- details") == "You have three left: Progress Check 2 by 3, your Lit Circle book by midnight, and the Atwood pre-lab by midnight.")
    print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
    // Sep 27: wake-word tail, varied greeting echo, reminder times.
    WakeMatcher.phrase = .jarvis
    check("wake tail: bare 'Hey Jarvis Ja' is empty", WakeMatcher.stripWake("Hey Jarvis Ja") == "")
    check("wake tail: command after 'Ja' kept", WakeMatcher.stripWake("Hey Jarvis Ja what's the weather") == "What's the weather")
    check("wake tail: normal command untouched", WakeMatcher.stripWake("Hey Jarvis, open my email") == "Open my email")
    check("echo: new greeting stripped", Controller.stripSummonEcho("At your service. Open my email") == "Open my email")
    check("echo: old greeting still stripped", Controller.stripSummonEcho("Yes sir, what time is it") == "What time is it")
    check("echo: real command untouched", Controller.stripSummonEcho("Go to the store") == "Go to the store")
    check("remind: parses local time", ReminderStore.parse("2026-09-27T18:00") != nil && ReminderStore.parse("2026-09-27 18:00:30") != nil && ReminderStore.parse("six") == nil)
    check("greeting: always from the pool", (0..<20).allSatisfy { _ in Acks.all.contains(Acks.summonedNow()) })
    // Sep 28 fast lane: the clock, the routing words, sentence cutting, and what may be said aloud.
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Chicago")!
    func at(_ h: Int, _ m: Int, day: Int = 28) -> Date { cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: h, minute: m))! }
    check("clock: ten past two", LocalAnswers.spokenTime(at(14, 10), cal) == "ten past two in the afternoon")
    check("clock: quarter to eight", LocalAnswers.spokenTime(at(7, 45), cal) == "quarter to eight in the morning")
    check("clock: half past nine at night", LocalAnswers.spokenTime(at(21, 30), cal) == "half past nine at night")
    check("clock: exact minutes", LocalAnswers.spokenTime(at(9, 7), cal) == "seven minutes past nine in the morning" && LocalAnswers.spokenTime(at(9, 1), cal) == "one minute past nine in the morning")
    check("clock: minutes to the next hour", LocalAnswers.spokenTime(at(9, 52), cal) == "eight minutes to ten in the morning")
    check("clock: noon, midnight, o'clock", LocalAnswers.spokenTime(at(12, 0), cal) == "noon" && LocalAnswers.spokenTime(at(0, 0), cal) == "midnight" && LocalAnswers.spokenTime(at(15, 0), cal) == "three o'clock in the afternoon")
    check("clock: to noon and to midnight", LocalAnswers.spokenTime(at(11, 50), cal) == "ten to noon" && LocalAnswers.spokenTime(at(23, 45), cal) == "quarter to midnight")
    check("clock: date", LocalAnswers.spokenDate(at(9, 0), cal) == "Monday the twenty-eighth of September")
    for q in ["What time is it?", "hey jarvis what's the time", "Can you tell me the time please", "what time is it right now", "Jarvis, what time is it, sir?", "do you have the time"] {
        check("instant time: \(q)", LocalAnswers.instant(q, now: at(14, 10), calendar: cal) == "It's ten past two in the afternoon.")
    }
    for q in ["What's the date today?", "what day is it", "What's today's date?", "Tell me the date"] {
        check("instant date: \(q)", LocalAnswers.instant(q, now: at(14, 10), calendar: cal) == "It's Monday the twenty-eighth of September.")
    }
    check("instant: sir on request", LocalAnswers.instant("what time is it", now: at(14, 10), calendar: cal, sir: true) == "It's ten past two in the afternoon, sir.")
    for q in ["What time is my meeting?", "what time does the store open", "what day is the dentist appointment", "what's the time complexity of quicksort", "is it time to go", "what time is it in Tokyo"] {
        check("not instant: \(q)", LocalAnswers.instant(q) == nil)
    }
    for q in ["How's it going today?", "What is the capital of Australia", "Who wrote Hamlet", "Tell me a joke", "How are you doing", "who is the president now", "what's seventeen times twenty three"] {
        check("lane candidate: \(q)", !Lane.mustUseAgent(q))
    }
    for q in ["What's on my calendar today", "Open my email", "What's the weather", "Remind me to call mom", "Search for coupons near me", "what's on today's agenda", "Find that file", "what's the latest news", "Can you set a timer"] {
        check("lane agent: \(q)", Lane.mustUseAgent(q))
    }
    check("lane agent: too long", Lane.mustUseAgent(String(repeating: "tell me about rome ", count: 20)))
    check("lane private: code", Lane.looksPrivate("my verification code is 482913") && Lane.looksPrivate("what do I do about my visa") && !Lane.looksPrivate("who wrote Hamlet"))
    check("lane finished: question after a beat", Lane.looksFinished("What time is it?", silence: 0.4) && !Lane.looksFinished("What time is it?", silence: 0.2))
    // Sep 30 (Coucou pass): "this" points at the screen; time words don't.
    for yes in ["Summarize this", "what's this", "reply to this email", "what's on my screen", "explain these", "what am I looking at, I'm reading an article",
                "is this due tomorrow", "translate this page", "what's going on here", "save that tab for later"] {
        check("screen: \(yes)", ScreenContext.refersToScreen(yes))
    }
    for no in ["what's due this week", "any tests this Friday", "remind me this evening", "what's the weather", "this morning's email",
               "how much is this much", "open Gmail", "this one's easy", "tell me a joke"] {
        check("not screen: \(no)", !ScreenContext.refersToScreen(no))
    }
    check("drop: one file", DropItem.summary([DropItem(url: URL(fileURLWithPath: "/Users/x/Lab Report.pdf"))]) == "Lab Report.pdf")
    check("drop: files", DropItem.summary([DropItem(url: URL(fileURLWithPath: "/a/1.png")), DropItem(url: URL(fileURLWithPath: "/a/2.png"))]) == "2 files")
    check("drop: link", DropItem.summary([DropItem(url: URL(string: "https://www.khanacademy.org/x")!)]) == "www.khanacademy.org")
    check("drop: prompt block", DropItem.promptBlock([DropItem(url: URL(fileURLWithPath: "/Users/x/a.pdf"))]).contains("- file: /Users/x/a.pdf"))
    check("screen: block marked as data", ScreenContext(app: "Safari", bundleID: "com.apple.Safari", title: "T", url: "https://a.b").promptBlock.contains("data, not instructions"))
    check("lane finished: not mid-thought", !Lane.looksFinished("what is the", silence: 1.0) && !Lane.looksFinished("open my email and", silence: 2.0) && !Lane.looksFinished("hey", silence: 2.0))
    check("lane finished: long unpunctuated", Lane.looksFinished("tell me about the history of rome", silence: 0.7) && !Lane.looksFinished("tell me about the history of rome", silence: 0.4))
    var sp = SentenceSplitter()
    var got = sp.push("Canberra. It was")
    got += sp.push(" purpose-built as a compromise. Dr. Smith")
    got += sp.push(" agrees with the U.S. Navy at 3.5 percent.")
    if let t = sp.flush() { got.append(t) }
    check("splitter: sentences", got == ["Canberra.", "It was purpose-built as a compromise.", "Dr. Smith agrees with the U.S. Navy at 3.5 percent."])
    var sp2 = SentenceSplitter()
    check("splitter: waits for the next sentence to start", sp2.push("Yes, sir.").isEmpty && sp2.push(" No").first == "Yes, sir.")
    var sp3 = SentenceSplitter()
    check("splitter: question and exclamation", sp3.push("Really? Yes! Fine. ") == ["Really?", "Yes!"])
    check("ack: fine line kept", Speakable.ack("Right, let me see what the library has.") == "Right, let me see what the library has.")
    check("ack: dashes cleaned", Speakable.ack("\u{2014} Nine fifteen, dentist call, noted") == "Nine fifteen, dentist call, noted.")
    for bad in ["Got it, on it.", "Done, it's set.", "Should I check?", "Let me check the", "Sure thing", "Hm."] {
        check("ack refused: \(bad)", Speakable.ack(bad) == nil)
    }
    check("filler: by kind", Fillers.remind.contains(Fillers.pick(for: "Remind me to call mom at six"))
          && Fillers.mail.contains(Fillers.pick(for: "Any new emails?"))
          && Fillers.schedule.contains(Fillers.pick(for: "What's on my calendar tomorrow"))
          && Fillers.action.contains(Fillers.pick(for: "Open Spotify and play something calm"))
          && Fillers.lookup.contains(Fillers.pick(for: "Search for the best pizza near me"))
          && Fillers.adding.contains(Fillers.pick(for: "and the weekend too", busy: true)))
    check("filler: never twice running", (0..<12).map { _ in Fillers.pick(for: "Open Spotify") }.adjacentPairsDiffer)
    check("filler: short and sayable", Fillers.all.allSatisfy { $0.split(separator: " ").count <= 7 && ($0.hasSuffix(".") || $0.hasSuffix("!")) })
    check("status fallback: from the step", LaneStatus.fallback(step: "Searching the web", said: []) == "Searching the web now."
          && LaneStatus.fallback(step: "Checking your grades", said: ["Searching the web now."]) == "Still checking your grades."
          && LaneStatus.fallback(step: "Searching the web", said: ["Searching the web now."]) == "Still searching the web.")
    check("status fallback: nothing specific yet", LaneStatus.fallback(step: nil, said: []) == nil && LaneStatus.fallback(step: "Thinking", said: []) == nil
          && LaneStatus.fallback(step: nil, said: ["Searching the web now."]) == "Still working on it, sir."
          && LaneStatus.fallback(step: nil, said: ["Still working on it, sir."]) == nil)
    check("status: sir dropped cleanly", LaneStatus.dropSir("Still pulling prices, sir, nearly through.") == "Still pulling prices, nearly through."
          && LaneStatus.dropSir("Pulling up your week now, sir.") == "Pulling up your week now." && LaneStatus.dropSir("Sir, one moment.") == "One moment."
          && LaneStatus.dropSir("Stirring the pot now.") == "Stirring the pot now.")
    check("status: repeats caught", LaneStatus.similar("Still combing through your inbox.", "still combing through the results") && !LaneStatus.similar("Searching the web now.", "Reading a web page now."))
    check("answer: ok and refused", Speakable.answerOK("Canberra.") && !Speakable.answerOK("I can't access real-time data.") && !Speakable.answerOK("- Paris") && !Speakable.answerOK("1. Paris"))
    check("clean: markdown and quotes", Speakable.clean("\"**Sixteen** ounces \u{2014} always.\"") == "Sixteen ounces, always.")
    let goodReq = LaneJev.requestJSON("  Who wrote   Hamlet? ")
    let reqObj = goodReq.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check("jev request: shape", (reqObj?["state"] as? String) == "Someone just said this to their voice assistant: \"Who wrote Hamlet?\"" && reqObj?["tier"] as? String == "you" && ((reqObj?["questions"] as? [String: Any])?["route"] as? [String: Any])?["type"] as? String == "choice")
    check("jev request: same key order as the door's own route", String(data: goodReq ?? Data(), encoding: .utf8)?.contains(#""questions":{"route":{"type":"choice","instructions":"What does answering this need?","criteria":{"chat""#) == true)
    let fastJSON = #"{"ok":true,"answers":{"route":{"type":"choice","choice":"chat","confidence":0.97,"probabilities":{"chat":0.99,"personal":0.01,"live":0,"action":0}}},"cached":true,"ms":0}"#
    let slowJSON = #"{"ok":true,"answers":{"route":{"type":"choice","choice":"chat","confidence":0.48,"probabilities":{"chat":0.61,"personal":0.39,"live":0,"action":0}}},"cached":false,"ms":1749}"#
    let liveJSON = #"{"ok":true,"answers":{"route":{"type":"choice","choice":"live","confidence":0.99,"probabilities":{"chat":0,"personal":0,"live":1,"action":0}}},"cached":false,"ms":800}"#
    check("jev verdict: confident chat is fast", LaneJev.parse(Data(fastJSON.utf8))?.fast == true)
    check("jev verdict: unsure chat is not", LaneJev.parse(Data(slowJSON.utf8))?.fast == false)
    check("jev verdict: live is not", LaneJev.parse(Data(liveJSON.utf8))?.fast == false && LaneJev.parse(Data(liveJSON.utf8))?.route == "live")
    check("jev verdict: refusal is nil", LaneJev.parse(Data(#"{"ok":false,"why":"private"}"#.utf8)) == nil)
    // Sep 29: the island takes Vorssaint's own sizes (1920x1080, 30 pt bar, its camera box 180: resting island 268).
    var ig = IslandGeometry(); ig.screen = CGRect(x: 0, y: 0, width: 1920, height: 1080); ig.cameraWidth = 180; ig.height = 30; ig.vorssaintWidth = 268
    check("island: resting strip is Vorssaint's (268 x 30)", ig.compactWidth == 268)
    check("island: notice strip is camera + 160 (340 x 30)", ig.noticeWidth == 340)
    check("island: peek card is 340 x 92", ig.peekWidth == 340 && ig.peekHeight == 92)
    ig.vorssaintWidth = 362
    check("island: never narrower than Vorssaint's live activity", ig.compactWidth == 362 && ig.noticeWidth == 362 && ig.peekWidth == 362)
    check("island: corners match Vorssaint (shoulder min(14, 0.19h), bottom min(28, 0.34h))",
          IslandGeometry.shoulder(30) == min(14, 30 * 0.19) && IslandGeometry.shoulder(92) == 14)
    return fails == 0 ? 0 : 1
}

if args.contains("--unit") { exit(runUnitTests()) }

if let i = args.firstIndex(of: "--login"), i + 1 < args.count {
    do {
        if args[i + 1] == "on" { try LoginAgent.install() } else { LoginAgent.remove() }
        print("launch at login + crash relaunch:", LoginAgent.isInstalled ? "on" : "off")
    } catch { print("login agent error:", error) }
    exit(0)
}
if let i = args.firstIndex(of: "--export-sounds"), i + 1 < args.count {
    MainActor.assumeIsolated {
        for (n, s) in zip(["wake", "ready", "mute", "unmute", "end"], JarvisSound.allCases) { try? Sounds.wav(s).write(to: URL(fileURLWithPath: args[i + 1] + "/\(n).wav")) }
    }
    exit(0)
}
if let i = args.firstIndex(of: "--polish-steps"), i + 1 < args.count {
    for l in ((try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? "").split(separator: "\n") { print(String(l), " ->  ", AgentRun.polishStep(String(l))) }
    exit(0)
}
if let i = args.firstIndex(of: "--spoken-preview"), i + 1 < args.count {
    print(SpokenText.from((try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? "")); exit(0)
}
if let i = args.firstIndex(of: "--lane"), i + 1 < args.count {
    // Offline timeline of one turn through the fast lane: no audio, nothing sent to Aside. Uses the real Jev door and model.
    let text = args[i + 1]
    Task { @MainActor in
        let t0 = CACurrentMediaTime()
        func ms() -> Int { Int((CACurrentMediaTime() - t0) * 1000) }
        let turn = LaneTurn(text: text, history: [])
        print("plan      \(turn.planName)\(turn.opener.map { "  opener \"\($0)\"" } ?? "")\(turn.core != text ? "  core \"\(turn.core)\"" : "")")
        switch turn.plan {
        case .social(let line): print("social    \(ms()) ms  \"\(line)\"")
        case .instant(let line): print("clock     \(ms()) ms  \"\(line)\"")
        case .agent:
            let op = await turn.opener(timeout: 6)
            print("agent     starts at 0 ms, opener at \(ms()) ms  \(op.map { "\"\($0)\"" } ?? "none (silence)")")
            let line = await LaneStatus.line(request: text, steps: [], said: [], timeout: 8)
            print("status    \(ms()) ms  \(line.map { "\"\($0)\"" } ?? "none")  (spoken ~6 s in, once a step shows)")
            // A later beat, with sample steps (as if the agent had searched and then opened a page).
            let steps = ["Searching the web", "Reading a web page"]
            let t1 = CACurrentMediaTime()
            let later = await LaneStatus.line(request: text, steps: steps, said: line.map { [$0] } ?? [], timeout: 8)
            print("status 2  \(Int((CACurrentMediaTime() - t1) * 1000)) ms  \(later.map { "\"\($0)\"" } ?? "none -> \(LaneStatus.fallback(step: steps.last, said: line.map { [$0] } ?? []) ?? "silence")")  (sample steps)")
        case .candidate:
            let v = await turn.decision(timeout: 6)
            print("jev       \(ms()) ms  \(v.map { "\($0.route) p=\(String(format: "%.2f", $0.p)) conf=\(String(format: "%.2f", $0.confidence)) fast=\($0.fast) social=\($0.social?.rawValue ?? "-")" } ?? "unavailable")")
            if turn.opener == nil, let k = v?.social { print("social    \(ms()) ms  \"\(Social.line(for: SocialRead(kind: k, named: nil, rest: nil, weakOnly: false)))\""); exit(0) }
            let jevSaysTools = v.map { !$0.fast && $0.route != "chat" && $0.p >= 0.7 } ?? false
            var said = false
            if !jevSaysTools { for k in 0..<3 { guard let s = await turn.sentence(k, timeout: 8) else { break }; said = true; print("sentence\(k + 1) \(ms()) ms  \"\(s)\"") } }
            if !said {
                let op = await turn.opener(timeout: 6)
                print("agent     starts at \(ms()) ms (\(jevSaysTools ? "jev: tools" : turn.handedOff ? "Luna handed off" : "no reply")), opener \(op.map { "\"\($0)\"" } ?? "none")  at \(ms()) ms")
            }
        }
        exit(0)
    }
    RunLoop.main.run()
}
if let i = args.firstIndex(of: "--macaudio-test"), i + 2 < args.count {
    // Silent: loads a sound file as if the Mac had just played it, then asks whether a heard phrase came from it.
    let file = URL(fileURLWithPath: args[i + 1]), heard = args[i + 2]
    Task {
        guard let f = try? AVAudioFile(forReading: file), let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { print("cannot read file"); exit(1) }
        try? f.read(into: buf)
        let sa = SystemAudio.shared
        sa.prepareForTest(sampleRate: f.processingFormat.sampleRate)
        sa.appendForTest(buf)
        sa.markRunningForTest()
        let t0 = CACurrentMediaTime()
        let wake = WakeMatcher.match(heard) != nil ? await sa.wakeCameFromMac() : false
        let cmd = await sa.commandCameFromMac(heard, spokenOver: 10)
        print("heard \"\(heard)\" -> wake from Mac: \(wake), command from Mac: \(cmd)  (\(Int((CACurrentMediaTime() - t0) * 1000)) ms)")
        exit(0)
    }
    RunLoop.main.run()
}
if args.contains("--lane-bench") {
    // Old path (jev reply through the door: route, then a whole reply) against the lane, on different but similar questions
    // (Jev caches identical text for a week, which would flatter whichever runs second). No audio.
    Task { @MainActor in
        func p50(_ v: [Int]) -> Int { v.sorted()[v.count / 2] }
        let chatOld = ["What is the boiling point of water in Fahrenheit", "Who discovered penicillin", "How many days are in a leap year", "What's the tallest mountain in the world", "Is a tomato a fruit", "How many legs does a spider have"]
        let chatNew = ["What is the freezing point of water in Fahrenheit", "Who invented the telephone", "How many weeks are in a year", "What's the longest river in the world", "Is a cucumber a fruit", "How many legs does an insect have"]
        let tasks = ["Open my email and summarize the unread ones", "Search online for a good pizza dough recipe", "Remind me to water the plants at four", "Find my latest notes on the science project", "Check my calendar for next week"]
        var oldChat: [Int] = [], newChat: [Int] = [], oldAgentStart: [Int] = [], newAck: [Int] = []
        for t in chatOld {
            let t0 = CACurrentMediaTime()
            let r = await FastPath.reply(t, history: [], busy: false, timeout: 15)
            let ms = Int((CACurrentMediaTime() - t0) * 1000)
            print("old chat  \(ms) ms  \(r?.mode ?? "none")")
            oldChat.append(ms)
        }
        for t in chatNew {
            let t0 = CACurrentMediaTime()
            let turn = LaneTurn(text: t, history: [])
            let v = await turn.decision(timeout: 8)
            let s = await turn.sentence(0, timeout: 12)
            let ms = Int((CACurrentMediaTime() - t0) * 1000)
            print("new chat  \(ms) ms  \(v?.fast == true && s != nil ? "answer" : "none")  (jev \(turn.verdictMs ?? -1) ms, first sentence \(turn.firstSentenceMs ?? -1) ms)")
            newChat.append(ms)
        }
        for t in tasks {
            let t0 = CACurrentMediaTime()
            _ = await FastPath.reply(t, history: [], busy: false, timeout: 15)
            let ms = Int((CACurrentMediaTime() - t0) * 1000)
            oldAgentStart.append(ms)
            print("old agent start \(ms) ms | new agent start 0 ms, spoken filler at 0 ms")
            newAck.append(0)
        }
        print("chat, time until Jarvis can start speaking (before voice synthesis): old p50 \(p50(oldChat)) ms, lane p50 \(p50(newChat)) ms")
        print("requests, agent starts after: old p50 \(p50(oldAgentStart)) ms, lane 0 ms; spoken filler: lane p50 \(newAck.isEmpty ? -1 : p50(newAck)) ms")
        exit(0)
    }
    RunLoop.main.run()
}
if let i = args.firstIndex(of: "--parse-replay"), i + 1 < args.count {
    // Offline: shows what the orb/voice would do for a captured CLI transcript. Sends nothing.
    let raw = (try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? ""
    for c in AgentRun.toolCalls(in: raw, final: true) { print("STEP  ", AgentRun.stepTitle(tool: c.name, args: c.args) ?? "(hidden: \(c.name))") }
    let calls = AgentRun.toolCalls(in: raw, final: true)
    let segs = AgentRun.segments(raw).filter { seg in !calls.contains { seg.offset >= $0.start && seg.offset < $0.end } }
    var text = ""
    for sg in segs { if sg.style == "0" { text += sg.text } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { print("TEXT  ", text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)); text = "" } else { text = "" } }
    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { print("FINAL ", text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)) }
    exit(0)
}
if args.contains("--vp-probe") {
    func tryVariant(_ name: String, _ setup: (AVAudioEngine) throws -> Void) {
        let e = AVAudioEngine()
        do {
            try setup(e)
            let f = e.inputNode.outputFormat(forBus: 0)
            e.inputNode.installTap(onBus: 0, bufferSize: 1024, format: f) { _, _ in }
            e.prepare()
            try e.start()
            print("OK  ", name, "in:", f.sampleRate, "x\(f.channelCount)", "out:", e.outputNode.outputFormat(forBus: 0).sampleRate)
            e.stop()
        } catch { print("FAIL", name, error) }
        e.inputNode.removeTap(onBus: 0)
        usleep(300_000)
    }
    let pf = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    tryVariant("A vp-in + player") { e in try e.inputNode.setVoiceProcessingEnabled(true); let p = AVAudioPlayerNode(); e.attach(p); e.connect(p, to: e.mainMixerNode, format: pf) }
    tryVariant("B vp-in, no player") { e in try e.inputNode.setVoiceProcessingEnabled(true) }
    tryVariant("C touch output first, vp-in + player") { e in _ = e.outputNode; _ = e.mainMixerNode; try e.inputNode.setVoiceProcessingEnabled(true); let p = AVAudioPlayerNode(); e.attach(p); e.connect(p, to: e.mainMixerNode, format: pf) }
    tryVariant("D vp-in+out + player") { e in try e.inputNode.setVoiceProcessingEnabled(true); try e.outputNode.setVoiceProcessingEnabled(true); let p = AVAudioPlayerNode(); e.attach(p); e.connect(p, to: e.mainMixerNode, format: pf) }
    tryVariant("E vp-in + player, mixer->out explicit fmt") { e in try e.inputNode.setVoiceProcessingEnabled(true); let p = AVAudioPlayerNode(); e.attach(p); e.connect(p, to: e.mainMixerNode, format: pf); e.connect(e.mainMixerNode, to: e.outputNode, format: e.outputNode.inputFormat(forBus: 0)) }
    tryVariant("F no vp + player (baseline)") { e in let p = AVAudioPlayerNode(); e.attach(p); e.connect(p, to: e.mainMixerNode, format: pf) }
    exit(0)
}
if args.contains("--probe-ax") {
    let p = AsidePopup()
    print(p.setManualAX())
    print("before:", p.axReport())
    p.pressShortcut()
    usleep(900_000)
    print(p.popupTree())
    usleep(1_200_000)
    print("--- after 2.1s:"); print(p.popupTree())
    p.pressShortcut()   // toggle it closed again
    exit(0)
}
if args.contains("--probe-open") {
    let p = AsidePopup()
    print("before:", p.diag())
    p.pressShortcut()
    for i in 1...18 { usleep(100_000); if i % 2 == 0 || i < 5 { print("t+\(i*100)ms:", p.diag()) } }
    exit(0)
}
if let i = args.firstIndex(of: "--probe") {
    _ = i
    let p = AsidePopup()
    let (en, sc) = AsidePopup.readShortcut()
    print("aside running:", p.app != nil, "active:", p.app?.isActive ?? false)
    print("popup enabled:", en, "shortcut:", sc?.text ?? "nil")
    print("popup frame:", p.popupWindowFrame().map { "\($0)" } ?? "none")
    if let el = p.focusedPopupTextArea() { print("popup text area focused; composer:", "\"\(p.composerText(el))\"") } else { print("popup text area: not focused") }
    print("AX trusted:", AXIsProcessTrusted(), "CLI:", BackgroundDelivery.available)
    exit(0)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var controller: Controller!
    var statusItem: NSStatusItem!
    let menu = NSMenu()

    func applicationDidFinishLaunching(_ note: Notification) {
        WakeMatcher.phrase = Settings.shared.wakePhrase
        MainActor.assumeIsolated {
            controller = Controller()
            if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
                runPreview(args[i + 1]); return
            }
            if let i = args.firstIndex(of: "--synth-file"), i + 4 < args.count {
                // --synth-file <voice> <rate> <text> <out.caf>: writes padded audio for offline recognizer tests (never plays).
                Task { @MainActor in
                    let v = AsideVoice(rawValue: args[i + 1]) ?? .ryan
                    guard let d = try? await EdgeTTS().synthesize(args[i + 3], voice: v, rate: Int(args[i + 2]) ?? 0),
                          let b = Speaker.decode(d) else { print("synth failed"); exit(1) }
                    let sr = b.format.sampleRate
                    let pre = AVAudioFrameCount(sr * 0.8), post = AVAudioFrameCount(sr * 3.5)
                    let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: pre + b.frameLength + post)!
                    out.frameLength = pre + b.frameLength + post
                    let dst = out.floatChannelData![0]; dst.initialize(repeating: 0, count: Int(out.frameLength))
                    (dst + Int(pre)).update(from: b.floatChannelData![0], count: Int(b.frameLength))
                    let f = try! AVAudioFile(forWriting: URL(fileURLWithPath: args[i + 4]), settings: b.format.settings)
                    try! f.write(from: out)
                    exit(0)
                }
                return
            }
            if args.contains("--idle-test") {
                Task { @MainActor in await controller.start(); try? await Task.sleep(nanoseconds: 25_000_000_000); exit(0) }
                return
            }
            if args.contains("--test-aec") {
                Log.echo = true
                Task { @MainActor in
                    await controller.start()
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    Log.write("AEC TEST START echoCancel=\(controller.recognizer.echoCancelActive)")
                    await controller.speaker.speak("Your chemistry lab is due tomorrow at eight in the morning. You also have a calculus quiz on Friday, and your English essay draft is due next Monday. I would start with the lab tonight since it is the closest deadline.")
                    Log.write("AEC TEST END")

                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    exit(0)
                }
                return
            }
            if args.contains("--probe-llm") {
                Task { @MainActor in
                    let m = SystemLanguageModel.default
                    print("availability:", m.availability)
                    if case .available = m.availability {
                        let s = LanguageModelSession(instructions: "You are the fast voice layer of an assistant named Aside. Reply with one short spoken sentence, no markdown.")
                        let t0 = CACurrentMediaTime()
                        if let r = try? await s.respond(to: "User just asked the agent: 'check what's due tomorrow on Schoology'. Say a brief natural acknowledgement before the agent starts working.") {
                            print(String(format: "%.2fs", CACurrentMediaTime() - t0), r.content) }
                        let t1 = CACurrentMediaTime()
                        let s2 = LanguageModelSession(instructions: "Classify the user's turn said while an agent is busy. Answer with exactly one word: STOP, STATUS, STEER, or QUEUE.")
                        if let r = try? await s2.respond(to: "actually, check Friday instead") { print(String(format: "%.2fs", CACurrentMediaTime() - t1), r.content) }
                    }
                    exit(0)
                }
                return
            }
            if args.contains("--voice-bench") {
                // Sep 30, silent: the start of a conversation as it really happens (warm-up + stock-line prefetch + the
                // first reply, all at once), timing until the first part's audio is ready. Nothing is played.
                Task { @MainActor in
                    let replies = ["Leonardo da Vinci painted it, sir, some time between fifteen oh three and fifteen nineteen.",
                                   "Canberra is the capital of Australia, not Sydney, as many assume.",
                                   "It's about three hundred and eighty four thousand kilometres away, give or take.",
                                   "Water boils at two hundred and twelve degrees Fahrenheit at sea level."]
                    var firsts: [Int] = []
                    if args.contains("--trace") { EdgeTTS.traceTiming = true; Log.echo = true }
                    for r in replies {
                        let sp = Speaker()
                        sp.warmUp(); sp.prefetch(Acks.all + Fillers.all)
                        let ms = await sp.firstPartReadyMs(r)
                        print("first audio ready \(ms) ms  (\(Speaker.chunks(r).first ?? ""))")
                        firsts.append(ms)
                        sp.coolDown()
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                    }
                    print("p50 \(firsts.sorted()[firsts.count / 2]) ms, max \(firsts.max() ?? -1) ms")
                    exit(0)
                }
                return
            }
            if args.contains("--tts-bench") {
                Task { @MainActor in
                    let e = EdgeTTS()
                    let texts = ["Sure.", "Your chemistry lab is due tomorrow at eight, and you have a calc quiz on Friday.", "Want me to make a plan for tonight?"]
                    EdgeTTS.traceTiming = true; Log.echo = true
                    if args.contains("--gaps") {
                        for gap in [0, 3, 8, 15, 25] {
                            try? await Task.sleep(nanoseconds: UInt64(gap) * 1_000_000_000)
                            let t0 = CACurrentMediaTime()
                            _ = try? await e.synthesize("It's Thursday, September twenty fourth.", voice: .andrew, rate: 9)
                            print("after \(gap)s gap: \(Int((CACurrentMediaTime() - t0) * 1000))ms")
                        }
                        exit(0)
                    }
                    for round in 1...3 {
                        var line = "round \(round):"
                        for t in texts {
                            let t0 = CACurrentMediaTime()
                            do { _ = try await e.synthesize(t, voice: .andrew, rate: 10); line += " \(Int((CACurrentMediaTime() - t0) * 1000))ms" } catch { line += " ERR(\(error))" }
                        }
                        print(line)
                    }
                    // parallel
                    let t0 = CACurrentMediaTime()
                    await withTaskGroup(of: Void.self) { g in for t in texts { g.addTask { _ = try? await e.synthesize(t, voice: .andrew, rate: 10) } } }
                    print("parallel all 3: \(Int((CACurrentMediaTime() - t0) * 1000))ms")
                    exit(0)
                }
                return
            }
            if let i = args.firstIndex(of: "--say"), i + 1 < args.count {
                Log.echo = true
                if let v = args.firstIndex(of: "--voice"), v + 1 < args.count, let av = AsideVoice(rawValue: args[v + 1]) { Settings.shared.voice = av }
                let sp = Speaker()
                var peak: Float = 0
                sp.onLevel = { peak = max(peak, $0) }
                sp.onSentence = { Log.write("speaking: \($0)") }
                Task { @MainActor in
                    let t0 = CACurrentMediaTime()
                    await sp.speak(args[i + 1])
                    Log.write(String(format: "done in %.2f s, peak level %.2f", CACurrentMediaTime() - t0, peak))
                    exit(0)
                }
                return
            }
            if args.contains("--test-heal") {
                Log.echo = true
                Task { @MainActor in
                    await controller.start()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    Log.write("TEST: killing audio silently")
                    controller.recognizer.simulateDeadAudio()
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    Log.write("TEST: audio age now \(String(format: "%.1f", controller.recognizer.secondsSinceAudio)) s")
                    exit(0)
                }
                return
            }
            if let i = args.firstIndex(of: "--test-file"), i + 1 < args.count {
                runFileTest(URL(fileURLWithPath: args[i + 1]))
                return
            }
            if let i = args.firstIndex(of: "--converse-test"), i + 1 < args.count {
                Log.echo = true; Speaker.silent = true; Settings.testOverride = true
                let text = args[i + 1]
                Task { @MainActor in await self.controller.testConverse(text, inSession: args.contains("--in-session")); exit(0) }
                return
            }
            if let i = args.firstIndex(of: "--live-test"), i + 1 < args.count {
                Log.echo = true
                let text = args[i + 1]
                Task { @MainActor in self.controller.liveTest(text) }
                return
            }
            Log.rotateIfNeeded()
            if args.contains("--silent-test") { Speaker.silent = true; Log.echo = true; Settings.testOverride = true }
            if !args.contains("--simulate") && !args.contains("--test-mute") && !args.contains("--silent-test") { SingleInstance.ensure() }
            if args.contains("--test-mute") { Log.echo = true }
            setupStatusItem()
            controller.onStateChange = { [weak self] _ in self?.refreshIcon() }
            observeSystem()
            Task { @MainActor in
                await self.requestPermissions()
                await self.controller.start()
                self.refreshIcon()
                if let i = args.firstIndex(of: "--simulate"), i + 1 < args.count { self.simulate(args[i + 1]) }
                if args.contains("--test-mute") { await self.controller.setMuted(true) }
                if args.contains("--mute-cycle") {
                    // Mid-conversation mute test without touching the pointer: mute at +14 s, unmute at +18 s.
                    try? await Task.sleep(nanoseconds: 14_000_000_000); await self.controller.setMuted(true)
                    try? await Task.sleep(nanoseconds: 4_000_000_000); await self.controller.setMuted(false)
                }
            }
        }
    }

    // Offline pipeline test: feeds an audio file through the real recognizer + controller in dry-run mode.
    @MainActor func runFileTest(_ url: URL) {
        Log.echo = true
        Speaker.silent = true
        controller.dryRun = true
        // --idle <s>: a short conversation quiet window, to see it mute (in memory only; the real mute is untouched).
        if let i = args.firstIndex(of: "--idle"), i + 1 < args.count, let s = Double(args[i + 1]) { Settings.idleOverride = s; Settings.testOverride = true }
        controller.onDryRunDeliver = { cmd in print("DELIVER: \"\(cmd)\"") }
        Task { @MainActor in
            do { try await controller.recognizer.runFile(url) } catch { print("ERROR", error) }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            print("TEST DONE")
            exit(0)
        }
    }

    /// Shows the capsule in a given state with sample content (for screenshot review). Exits after 6 s.
    @MainActor func runPreview(_ phase: String) {
        let hud = controller.hud
        let m = hud.model
        if let i = args.firstIndex(of: "--palette"), i + 1 < args.count, let p = OrbPalette(rawValue: args[i + 1]) { Settings.shared.orbPalette = p }
        if let i = args.firstIndex(of: "--style"), i + 1 < args.count, let st = HUDStyle(rawValue: args[i + 1]) { Settings.styleOverride = st }
        if args.contains("--captions") { Settings.captionsOverride = true } else if args.contains("--no-captions") { Settings.captionsOverride = false }
        if phase == "tour" { runTour(); return }
        switch phase {
        case "empty": m.phase = .listening; m.status = "Listening"; m.transcript = ""
        case "listening": m.phase = .listening; m.status = "Listening"; m.transcript = "What's due tomorrow on Schoology, and make me a plan for tonight"
        case "long": m.phase = .listening; m.status = "Listening"; m.transcript = "Open my Gmail, summarize every unread email from school this week, and flag anything that needs a reply before Friday"
        case "confirming": m.phase = .confirming; m.status = "Sending \u{00B7} say \u{201C}cancel\u{201D} or press esc"; m.transcript = "What's due tomorrow on Schoology? Make me a plan for tonight."
        case "sent": m.phase = .sent; m.status = "Sent to Aside"; m.transcript = "What's due tomorrow on Schoology? Make me a plan for tonight."
        case "thinking": m.phase = .thinking; m.status = ""; m.transcript = "Using your Schoology daily planner skill"
        case "speaking": m.phase = .speaking; m.status = ""; m.transcript = HUDController.captionLines("You have four things due today and two are already done and graded. The other two are Progress Check 2 from this afternoon and the Atwood pre-lab due at midnight.")[0]
        case "summoned": m.phase = .listening; m.status = ""; m.transcript = ""; m.hint = "Yes, sir?"
        case "muted": m.muted = true; m.phase = .listening; m.status = ""; m.transcript = ""
        case "hover": m.phase = .listening; m.status = ""; m.transcript = "What's due tomorrow"; m.revealControls = true; m.muteHover = true
        case "reveal": m.phase = .speaking; m.status = ""; m.transcript = "The Atwood pre-lab is due at 11:59 tonight, sir."; m.revealControls = true
        case "muted-reveal": m.muted = true; m.phase = .listening; m.status = ""; m.transcript = ""; m.revealControls = true
        case "muted-speaking": m.muted = true; m.phase = .speaking; m.status = ""; m.transcript = "The Atwood pre-lab is due at 11:59 tonight, sir."
        case "cancelled": m.phase = .cancelled; m.status = "Cancelled \u{00B7} nothing sent"; m.transcript = ""
        case "error": m.phase = .error; m.status = "Couldn\u{2019}t reach the Aside popup"; m.transcript = ""
        case "drop-near": m.phase = .listening; m.status = ""; m.transcript = ""; m.drop = .near
        case "drop-over": m.phase = .listening; m.status = ""; m.transcript = ""; m.drop = .over
        case "dropped": m.phase = .listening; m.status = ""; m.transcript = ""; m.attachment = "Chem Lab 4 - Titration.pdf"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { m.gulps += 1; hud.island.hop() }
        default: break
        }
        hud.previewPinned = true
        hud.present(anchor: nil)
        if phase == "confirming" { hud.startCountdown(3) }
        // Simulated voice level so the orb moves like it does while you talk.
        var t = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            t += 0.05
            MainActor.assumeIsolated { if phase == "listening" || phase == "long" || phase == "empty" || phase == "speaking" { m.level = CGFloat(0.35 + 0.3 * sin(t * 7) * sin(t * 2.3)) } }
        }
        // --snap <out.png>: render the settled island to a file and quit (no screen recording needed).
        if let i = args.firstIndex(of: "--snap"), i + 1 < args.count {
            let out = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { print(hud.island.snapshot(to: out) ? "snap \(out.path)" : "snap failed"); exit(0) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) }
    }

    /// Plays a whole conversation in the current style with neutral sample content (no audio, nothing sent):
    /// wake, live words, countdown, working steps, spoken lines, a quiet tuck-away, a follow-up, retract. ~22 s.
    @MainActor func runTour() {
        let hud = controller.hud, m = hud.model
        var steps: [(TimeInterval, () -> Void)] = []
        var at: TimeInterval = 0.4
        func add(_ dt: TimeInterval, _ f: @escaping () -> Void) { at += dt; steps.append((at, f)) }
        var talking = false
        add(0) { m.phase = .listening; m.status = ""; m.transcript = ""; m.hint = "Yes, sir?"; hud.present(anchor: nil) }
        add(1.4) { talking = true }
        let words = "What's the weather this afternoon, and do I need an umbrella".split(separator: " ").map(String.init)
        for i in words.indices { add(0.2) { m.hint = ""; m.transcript = words[0...i].joined(separator: " ") } }
        add(0.7) { talking = false; m.phase = .confirming; m.status = "Sending"; m.transcript = "What's the weather this afternoon, and do I need an umbrella?"; hud.startCountdown(1.5) }
        add(1.7) { m.countdownActive = false; m.phase = .thinking; m.transcript = "Checking the forecast" }
        add(1.5) { m.transcript = "Reading hourly rain chances" }
        let lines = HUDController.captionLines("Light rain moves in around four, sir, so yes, take the umbrella. It should clear up by seven.")
        for (i, l) in lines.enumerated() { add(i == 0 ? 1.5 : 2.1) { talking = true; m.phase = .speaking; m.transcript = l } }
        add(2.3) { talking = false; m.phase = .listening; m.transcript = ""; m.hint = "" }
        // Quiet: the island tucks away. A follow-up brings it straight back, then quiet again.
        add(2.0) { talking = true; m.transcript = "Thanks" }
        add(0.6) { talking = true; m.phase = .speaking; m.transcript = "Anytime, sir." }
        add(1.4) { talking = false; m.phase = .listening; m.transcript = "" }
        add(1.6) { hud.dismiss(after: 0) }
        add(1.6) { exit(0) }
        for (t, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { f() } } }
        var t = 0.0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            t += 1.0 / 60
            MainActor.assumeIsolated { m.level = talking ? CGFloat(max(0, 0.32 + 0.3 * sin(t * 7) * sin(t * 2.3) + 0.1 * sin(t * 17))) : 0 }
        }
    }

    /// Live delivery test without speaking: runs the real delivery path with a given text.
    /// With --no-send it fills the popup, verifies, then clears and closes it (nothing is sent).
    @MainActor func simulate(_ text: String) {
        Log.echo = true
        controller.noSubmit = args.contains("--no-send")
        Task { @MainActor in
            await controller.testDeliver(text)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if args.contains("--exit") { exit(0) }
        }
    }

    @MainActor func requestPermissions() async {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        Log.write("permissions: mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) ax=\(AXIsProcessTrusted())")
    }

    @MainActor func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.recognizer.stop() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in try? await Task.sleep(nanoseconds: 1_500_000_000); await self?.controller.restartAudio(); self?.refreshIcon() }
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in Log.write("audio config changed; restarting"); await self?.controller.restartAudio(); self?.refreshIcon() }
        }
    }

    // MARK: status item + menu

    @MainActor func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()
    }

    @MainActor func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let st = controller.state
        let name: String
        var tint: NSColor? = nil
        switch st {
        case .paused: name = "mic.slash"
        case .failed: name = "exclamationmark.triangle"
        case .listening, .confirming, .speaking:
            name = "waveform.circle.fill"; tint = NSColor(red: 0xE8 / 255, green: 0x7D / 255, blue: 0x4F / 255, alpha: 1)
        case .idle: name = "waveform"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Hey Aside")
        img?.isTemplate = true
        button.image = img
        button.contentTintColor = tint
        button.toolTip = "Hey Aside: \(st.rawValue)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) { MainActor.assumeIsolated { buildMenu() } }

    @MainActor func buildMenu() {
        menu.removeAllItems()
        let s = Settings.shared
        let st = controller.state
        let header: String
        switch st {
        case .paused: header = "Muted: not listening"
        case .failed: header = "Not listening: \(controller.lastError ?? "error")"
        default: header = "Listening for \(s.wakePhrase == .both ? "\u{201C}Hey Jarvis\u{201D} or \u{201C}Hey Aside\u{201D}" : s.wakePhrase.title)"
        }
        menu.addItem(disabled(header))
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { menu.addItem(item("Allow Microphone Access…", #selector(openMicSettings))) }
        if !AXIsProcessTrusted() { menu.addItem(item("Allow Accessibility (needed for popup)…", #selector(openAXSettings))) }
        menu.addItem(.separator())
        menu.addItem(item("Talk to Aside Now", #selector(talkNow), key: ""))
        menu.addItem(item(st == .paused ? "Unmute Microphone" : "Mute Microphone", #selector(togglePause)))
        menu.addItem(.separator())

        let wp = NSMenu()
        for p in WakeMatcher.Phrase.allCases { let i = item(p.title, #selector(setWakePhrase(_:))); i.representedObject = p.rawValue; i.state = s.wakePhrase == p ? .on : .off; wp.addItem(i) }
        menu.addItem(submenu("Wake Phrase", wp))

        let dm = NSMenu()
        for m in DeliveryMode.allCases { let i = item(m.title, #selector(setDelivery(_:))); i.representedObject = m.rawValue; i.state = s.delivery == m ? .on : .off; dm.addItem(i) }
        menu.addItem(submenu("Send To", dm))

        let cw = NSMenu()
        for (t, v) in [("Send immediately", 0.0), ("1.5 seconds", 1.5), ("3 seconds", 3.0)] { let i = item(t, #selector(setCancelWindow(_:))); i.representedObject = v; i.state = s.cancelWindow == v ? .on : .off; cw.addItem(i) }
        menu.addItem(submenu("Pause Before Sending", cw))

        let sw = NSMenu()
        for (t, v) in [("Snappy (0.8 s)", 0.8), ("Balanced (1.2 s)", 1.2), ("Relaxed (1.8 s)", 1.8)] { let i = item(t, #selector(setSilence(_:))); i.representedObject = v; i.state = abs(s.silence - v) < 0.01 ? .on : .off; sw.addItem(i) }
        menu.addItem(submenu("Wait After I Stop Talking", sw))

        let om = NSMenu()
        for p in OrbPalette.allCases { let i = item(p.title, #selector(setPalette(_:))); i.representedObject = p.rawValue; i.state = s.orbPalette == p ? .on : .off; om.addItem(i) }
        menu.addItem(submenu("Orb Color", om))
        let dsm = NSMenu()
        for st in HUDStyle.allCases { let i = item(st.title, #selector(setHUDStyle(_:))); i.representedObject = st.rawValue; i.state = s.hudStyle == st ? .on : .off; dsm.addItem(i) }
        dsm.addItem(.separator())
        let cap = toggle("Show Jarvis\u{2019}s Words", s.islandCaptions, #selector(toggleIslandCaptions))
        if s.hudStyle != .island { cap.action = nil }   // the floating orb always shows its words
        dsm.addItem(cap)
        menu.addItem(submenu("Show Jarvis In", dsm))

        menu.addItem(toggle("Speak Replies", s.voiceReplies, #selector(toggleVoiceReplies)))
        menu.addItem(toggle("Talk Over Aside (echo cancellation)", s.echoCancel, #selector(toggleEchoCancel)))
        let vm = NSMenu()
        for v in AsideVoice.allCases where !v.title.contains("test only") { let i = item(v.title, #selector(setVoice(_:))); i.representedObject = v.rawValue; i.state = s.voice == v ? .on : .off; vm.addItem(i) }
        vm.addItem(.separator())
        vm.addItem(item("Play Sample", #selector(playSample)))
        menu.addItem(submenu("Voice", vm))

        menu.addItem(toggle("Speak Up On His Own (not in school or sleep hours)", s.proactive, #selector(toggleProactive)))
        menu.addItem(toggle("Sounds", s.sounds, #selector(toggleSounds)))
        let cm = NSMenu()
        for c in Sounds.chimes { let i = item(c.label, #selector(setChime(_:))); i.representedObject = c.name; i.state = s.chime == c.name ? .on : .off; cm.addItem(i) }
        menu.addItem(submenu("Chime (plays when picked)", cm))
        menu.addItem(toggle("Live Captions", s.hud, #selector(toggleHUD)))
        menu.addItem(toggle("Use Built-in Mic (keeps AirPods in high quality)", s.builtInMic, #selector(toggleMic)))
        menu.addItem(toggle("Launch at Login", LoginAgent.isInstalled, #selector(toggleLogin)))
        menu.addItem(.separator())
        menu.addItem(item("Open Log", #selector(openLog)))
        menu.addItem(item("Orb by Rare UI (rareui.com)", #selector(openCredit)))
        menu.addItem(item("Quit Hey Aside", #selector(quit), key: "q"))
    }

    @MainActor func item(_ t: String, _ a: Selector, key: String = "") -> NSMenuItem { let i = NSMenuItem(title: t, action: a, keyEquivalent: key); i.target = self; return i }
    @MainActor func disabled(_ t: String) -> NSMenuItem { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }
    @MainActor func toggle(_ t: String, _ on: Bool, _ a: Selector) -> NSMenuItem { let i = item(t, a); i.state = on ? .on : .off; return i }
    @MainActor func submenu(_ t: String, _ m: NSMenu) -> NSMenuItem { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.submenu = m; return i }

    @objc func talkNow() { MainActor.assumeIsolated { controller.manualWake() } }
    @objc func togglePause() {
        MainActor.assumeIsolated {
            Task { @MainActor in await controller.setMuted(!Settings.shared.paused); refreshIcon() }
        }
    }
    @objc func setDelivery(_ i: NSMenuItem) { if let r = i.representedObject as? String, let m = DeliveryMode(rawValue: r) { Settings.shared.delivery = m } }
    @objc func setCancelWindow(_ i: NSMenuItem) { if let v = i.representedObject as? Double { Settings.shared.cancelWindow = v } }
    @objc func setSilence(_ i: NSMenuItem) { if let v = i.representedObject as? Double { Settings.shared.silence = v } }
    @objc func setWakePhrase(_ i: NSMenuItem) { if let r = i.representedObject as? String, let p = WakeMatcher.Phrase(rawValue: r) { Settings.shared.wakePhrase = p } }
    @objc func setChime(_ i: NSMenuItem) { if let n = i.representedObject as? String { Settings.shared.chime = n; MainActor.assumeIsolated { Sounds.chime(n) } } }
    @objc func toggleProactive() { Settings.shared.proactive.toggle() }
    @objc func toggleVoiceReplies() { Settings.shared.voiceReplies.toggle() }
    @objc func toggleFollowUp() { Settings.shared.followUp.toggle() }
    @objc func toggleEchoCancel() { Settings.shared.echoCancel.toggle() }
    @objc func setVoice(_ i: NSMenuItem) {
        if let r = i.representedObject as? String, let v = AsideVoice(rawValue: r) { Settings.shared.voice = v; playSample() }
    }
    @objc func playSample() {
        MainActor.assumeIsolated { Task { @MainActor in await controller.speaker.speak("Hello, it's Aside. This is how I'll sound when I answer you.") } }
    }
    @objc func openCredit() { NSWorkspace.shared.open(URL(string: "https://www.rareui.com/components/fluidorb")!) }
    @objc func setPalette(_ i: NSMenuItem) { if let r = i.representedObject as? String, let p = OrbPalette(rawValue: r) { Settings.shared.orbPalette = p } }
    @objc func toggleSounds() { Settings.shared.sounds.toggle() }
    @objc func toggleHUD() { Settings.shared.hud.toggle() }
    @objc func toggleIslandCaptions() { Settings.shared.islandCaptions.toggle() }
    @objc func setHUDStyle(_ i: NSMenuItem) { if let r = i.representedObject as? String, let st = HUDStyle(rawValue: r) { Settings.shared.hudStyle = st } }
    @objc func toggleMic() { Settings.shared.builtInMic.toggle(); MainActor.assumeIsolated { Task { @MainActor in await controller.restartAudio(); refreshIcon() } } }
    @objc func toggleLogin() {
        if LoginAgent.isInstalled { LoginAgent.remove(); return }
        do {
            try LoginAgent.install()
            // launchd just started a managed copy; hand off to it so crash-relaunch covers this session too.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        } catch { Log.write("login agent error: \(error)") }
    }
    @objc func openLog() { NSWorkspace.shared.open(Log.url) }
    @objc func openMicSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
    @objc func openAXSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
