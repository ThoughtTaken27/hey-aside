import AppKit
import Foundation

/// The wake → listen → endpoint → countdown → deliver state machine.
///
/// Timing design (measured Sep 24 on replayed audio):
/// - The fast recognizer (DictationTranscriber) streams words ~0.5 s behind speech: used for wake + live captions.
/// - The accurate recognizer (SpeechTranscriber) lags ~2 s but has better words + punctuation: used for the sent text.
/// - End of speech is decided from audio silence (stamped on the audio thread), not from text arrival.
/// - The send countdown starts the moment speech ends; the accurate text is finalized and typed *during* the countdown.
@MainActor
final class Controller: RecognizerDelegate {
    enum State: String { case idle, listening, confirming, speaking, paused, failed }

    let recognizer = Recognizer()
    let popup = AsidePopup()
    let hud = HUDController()

    private(set) var state: State = .idle { didSet { if state != oldValue { onStateChange?(state) } } }
    var onStateChange: ((State) -> Void)?
    var lastError: String?

    /// Test mode: never touches the popup or CLI; reports what it would send.
    var dryRun = false
    var onDryRunDeliver: ((String) -> Void)?
    /// Live test mode: fill and verify, then clear instead of sending.
    var noSubmit = false

    // Transcript
    private struct Seg { let source: SegmentUpdate.Source; let session: Int; let start: Double; let end: Double; let text: String; let isFinal: Bool }
    private var segs: [Seg] = []
    private var ignoreUpToSession = 0
    private var wakeSession = 0
    private var wakeStart: Double = 0

    // Timing
    private var wakeAt: TimeInterval = 0
    private var lastVoiced: TimeInterval = 0
    private var lastTextGrowth: TimeInterval = 0
    private var lastWordCount = 0
    private var turnWordsAt: TimeInterval = 0            // when the current turn's first word showed up (Mac-audio check window)
    private var wakeCheckSession = -1                    // the speech burst whose wake phrase is being checked against Mac audio
    private var flushedWhileEmpty = false
    private var timer: Timer?
    private var marks: [String: TimeInterval] = [:]

    // Countdown / cancel
    private var endpointSession = 0
    private var endpointAudioEnd: Double = 0
    private var countdownDeadline: TimeInterval = 0
    private var escPressed = false
    private var returnPressed = false
    private var cancelSpoken = false
    private var runID = 0
    private var popupTask: Task<AsidePopup.OpenResult, Never>?
    private var keyMonitor: Any?

    // Live conversation (Codex-voice style): one Aside session, continuous listening, talk while it works.
    let speaker = Speaker()
    let proactive = Proactive()
    private var lastAnnouncement: (text: String, at: TimeInterval)?
    private var unpromptedOpen = false
    private(set) var live = false             // a conversation is open: no wake phrase needed between turns
    private var convSession: String?          // the one Aside session this conversation lives in
    private var lastConvEndedAt: TimeInterval = -1e9
    private var lastConvActivity: TimeInterval = 0
    private var run: AgentRun?                // Aside currently working
    private var runRetried = false
    private var lastRunPrompt = ""
    private var lastStep: String?
    private var lastSpokenAt: TimeInterval = 0
    private var endedByEsc = false
    private var runWatch: Timer?
    private var idleChecks = 0
    private var statusCheckInFlight = false   // one `aside session list` at a time, ever
    enum SpeechKind { case ack, filler, progress, answer }
    private var speechQueue: [(String, SpeechKind)] = []
    private var speakingKind: SpeechKind?
    private var caption = ""
    private var agentBusy: Bool { run?.isRunning ?? false }
    private var fastBusy = false                          // the fast path is deciding or answering
    private var fastPairs: [(q: String, a: String)] = []  // answered on the fast path, not yet seen by the Aside session
    private var pendingAnswer: String?
    private var turnsAddedDuringRun = 0
    private var captionWork: [DispatchWorkItem] = []
    private var unduckWork: DispatchWorkItem?
    private var sirAsked = false
    private var headsUpSpoken = false
    private var heardDuringSpeech = false
    private var lastSpokenText = ""
    // Sep 27: the conversation as spoken (for natural first replies), this run's steps, and reminders.
    private var recentTurns: [(q: String, a: String)] = []
    private var lastUserCmd = ""
    private var runSteps: [String] = []
    // Sep 28: spoken status while the agent works (see statusBeat).
    private var statusWork: DispatchWorkItem?
    private var statusSaid: [String] = []
    private var statusStep: String?
    private var lastStatusAt: TimeInterval = 0
    private var fillerTurn = -1                           // the turn that already got its "On it." / "Let me think."
    // Sep 28 fast lane: the turn being answered (its later sentences are still arriving) and one started early.
    private var laneTurn: LaneTurn?
    private var speculation: LaneTurn?
    private var specTries = 0
    // Sep 29: when Jarvis last asked how you are, so "good, you?" is read as your answer for the next 30 s.
    private var socialAskedAt: CFTimeInterval = 0
    private var socialAsked: Bool { CACurrentMediaTime() - socialAskedAt < 30 }
    private var turnSeq = 0                               // bumps once per spoken turn (unlike runID, not on every listen)
    let reminders = Reminders()
    // Sep 30 (Coucou pass): files or links dropped on the notch ride with the next request; "this" brings the screen.
    let drops = DropCatcher()
    private var attached: [DropItem] = []
    private var attachedAt: TimeInterval = 0
    // Oct 7: Jarvis Live. A live call owns the mic and speaker through Codex's voice helper; see LiveCall.swift.
    let liveCall = LiveCall()
    private(set) var inLiveCall = false
    private var liveHeard = ""
    private var liveHeardDone = true
    private var liveSaid = ""
    private var liveSaidDone = true
    private var liveStep: String?
    private var liveTasks = 0                      // background Aside tasks running in this call
    private var liveActivity: NSObjectProtocol?    // keeps App Nap and timer coalescing off during a call
    private var liveInitial: String?
    private var liveFallback: String?            // set when the call failed before saying anything: classic pipeline takes the turn
    private var useLive: Bool { !dryRun && !noSubmit && LiveCall.available }
    private var progressLines: Bool { UserDefaults.standard.object(forKey: "progressLines") as? Bool ?? true }

    init() {
        recognizer.delegate = self
        speaker.io = recognizer
        liveCall.onEvent = { [weak self] e in self?.handleLive(e) }
        liveCall.onAnnounce = { [weak self] t in self?.liveTaskResult(t) }
        hud.onMuteToggle = { [weak self] in Task { @MainActor in await self?.setMuted(!Settings.shared.paused) } }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let code = e.keyCode
            Task { @MainActor in
                guard let self else { return }
                if code == 53 && self.inLiveCall { Log.write("LIVE esc"); self.liveCall.stop(); return }
                if code == 53 && self.live { self.clearAttached(); self.endConversation(say: nil, byEsc: true); return }
                guard self.state == .listening || self.state == .confirming else { return }
                if code == 53 { self.escPressed = true; self.clearAttached() }
                if code == 36 || code == 76 { self.returnPressed = true }
            }
        }
    }

    // MARK: lifecycle

    func start() async {
        if !dryRun && !noSubmit { startDrops() }   // idempotent; also while muted, since a drop unmutes
        guard !Settings.shared.paused else { state = .paused; showMuted(); return }
        lastRestart = CACurrentMediaTime()   // ignore the device-change event our own engine start triggers
        do {
            try await recognizer.start()
            lastRestart = CACurrentMediaTime()
            if !dryRun && !noSubmit && SystemAudio.enabled { SystemAudio.shared.stop(); SystemAudio.shared.start() }   // Oct 2: ignore what the Mac plays
            state = .idle
            if !dryRun { speaker.prefetch(Acks.summoned + Acks.summonedMorning + Acks.summonedEvening + Acks.summonedLate + Fillers.all + Social.all) }   // must play instantly
            if !dryRun && !noSubmit {
                proactive.deliver = { [weak self] u in self?.announce(u) }
                proactive.canDeliverNow = { [weak self] in guard let self else { return false }; return !self.live && self.state == .idle && !Settings.shared.paused }
                proactive.start()
                reminders.fire = { [weak self] r in self?.deliverReminder(r) }
                reminders.start()
            }
            lastError = nil
            failures = 0
        } catch {
            lastError = error.localizedDescription
            state = .failed
            failures += 1
            Log.write("start failed (#\(failures)): \(error)")
        }
        startWatchdog()
    }

    // MARK: self-healing
    //
    // One cheap check every 5 s (no audio work): restarts the mic if it went silent (device grabbed, driver hiccup),
    // and retries a failed start with backoff (2, 5, 15, 30, then every 60 s), e.g. when the mic isn't ready at login.
    private var failures = 0
    private var watchdog: Timer?
    private var nextRetryAt: TimeInterval = 0

    private func startWatchdog() {
        if state == .failed { nextRetryAt = CACurrentMediaTime() + [2, 5, 15, 30, 60][min(failures - 1, 4)] }
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        watchdog?.tolerance = 1.5   // lets macOS batch the wakeup with others (energy)
    }

    private func checkHealth() {
        guard !Settings.shared.paused, !restarting else { return }
        let now = CACurrentMediaTime()
        switch state {
        case .failed where now >= nextRetryAt:
            Log.write("self-heal: retrying start")
            Task { await start() }
        case .idle where recognizer.running && recognizer.secondsSinceAudio > 8:
            Log.write("self-heal: no audio for \(Int(recognizer.secondsSinceAudio)) s; restarting mic")
            lastRestart = 0
            Task { await restartAudio() }
        default: break
        }
    }

    // MARK: mute (Sep 25: fully deaf until unmuted; the mic is released, so macOS's mic indicator goes off too)

    var muted: Bool { Settings.shared.paused }

    func setMuted(_ on: Bool) async {
        guard on != Settings.shared.paused else { return }
        if inLiveCall {
            // The call keeps running; only its mic is muted (the helper owns it, not the wake recognizer).
            Log.write(on ? "MUTED (live call)" : "UNMUTED (live call)")
            Settings.shared.paused = on
            hud.model.muted = on
            liveCall.setMuted(on)
            onStateChange?(state)
            return
        }
        if on {
            Log.write("MUTED\(live ? " (conversation kept open)" : "")")

            Settings.shared.paused = true
            if live { resetRun() } else { finish(.cancelled, "", sound: nil, quiet: true) }
            speaker.coolDown()   // no voice warm-ups while he can't hear you
            recognizer.stop()
            SystemAudio.shared.stop()
            state = .paused
            hud.model.muted = true
            showMuted()
        } else {
            Log.write("UNMUTED")

            Settings.shared.paused = false
            hud.model.muted = false
            if !live { recognizer.echoCancelWanted = false }   // idle wake mode never needs echo cancellation
            await start()
            if live {
                lastConvActivity = CACurrentMediaTime()        // a fresh follow-up window from now
                listenNext()
            } else {
                hud.dismiss(after: 0.35)
            }
        }
        onStateChange?(state)
    }

    /// Muted: keep the orb (grey, not rendering) and its button on screen so you can always unmute.
    private func showMuted() {
        guard Settings.shared.paused else { return }
        hud.model.muted = true
        if live { refreshHUD(); return }
        let m = hud.model
        m.phase = .listening; m.transcript = ""; m.status = ""
        hud.present(anchor: nil)
    }

    func pause() {
        Settings.shared.paused = true
        finish(.cancelled, "Paused", sound: nil, quiet: true)
        recognizer.stop()
        SystemAudio.shared.stop()
        state = .paused
    }

    func resume() async {
        Settings.shared.paused = false
        await start()
    }

    private var restarting = false
    private var lastRestart: TimeInterval = 0
    private var suppressRestartUntil: TimeInterval = 0

    func restartAudio() async {
        guard !Settings.shared.paused else { return }
        guard !inLiveCall else { return }   // the call's helper opening devices fires these; the recognizer is off anyway
        // Device-change notifications arrive in bursts (and once at launch): collapse them.
        let now = CACurrentMediaTime()
        guard !restarting, now - lastRestart > 1.5, now > suppressRestartUntil else { return }
        restarting = true; lastRestart = now
        defer { restarting = false }
        finish(.cancelled, "", sound: nil, quiet: true)
        recognizer.stop()
        SystemAudio.shared.stop()
        try? await Task.sleep(nanoseconds: 400_000_000)
        await start()
    }

    // MARK: RecognizerDelegate

    nonisolated func recognizer(didUpdate seg: SegmentUpdate) {
        MainActor.assumeIsolated { self.handle(seg) }
    }

    nonisolated func recognizer(level: Float, lastVoicedAt: TimeInterval) {
        MainActor.assumeIsolated {
            self.lastVoiced = max(self.lastVoiced, lastVoicedAt)
            if self.state == .listening && self.speakingKind == nil { self.hud.model.level = CGFloat(level) }
        }
    }

    nonisolated func recognizer(failed message: String) {
        MainActor.assumeIsolated {
            Log.write("recognizer error: \(message); self-heal restart")
            Task { await self.restartAudio() }
        }
    }

    private func handle(_ seg: SegmentUpdate) {
        guard seg.session > ignoreUpToSession else { return }
        if live && speakingKind != nil {
            if !recognizer.echoCancelActive {
                // No echo cancellation: the mic hears Aside, so only the wake phrase can interrupt (Aside never says it).
                if WakeMatcher.match(seg.text) != nil { Log.write("barge-in (wake phrase)"); stopSpeaking(); restartTurn() }
                return
            }
            // Echo cancellation on: anything you say is you. Duck at once; stop only for a real interruption,
            // not "yeah" / "mm-hmm" (listener feedback keeps him talking).
            heardDuringSpeech = true
            let n = wordCount(seg.text)
            if n >= 1 && !speaker.ducked { speaker.duck(true) }
            if n >= 3 || (n >= 2 && !Router.isBackchannel(seg.text)) {
                Log.write("barge-in: \(seg.text)"); stopSpeaking()
            } else {
                unduckWork?.cancel()
                let w = DispatchWorkItem { [weak self] in if self?.speakingKind != nil { self?.speaker.duck(false) } }
                unduckWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: w)
            }
        }
        if Log.echo { Log.write("  seg \(seg.source == .fast ? "fast" : "acc ") s\(seg.session) \(seg.isFinal ? "F" : "v") [\(String(format: "%.2f", seg.start))-\(String(format: "%.2f", seg.end))] \(seg.text)") }
        upsert(seg)
        switch state {
        case .idle:
            // Also try the whole utterance so far: recognizers sometimes finalize "Hey" on its own and "Aside, ..." next.
            let joined = segs.filter { $0.source == seg.source && $0.session == seg.session }.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            let first = segs.first { $0.source == seg.source && $0.session == seg.session }
            if let m = WakeMatcher.match(seg.text) {
                gatedWake(session: seg.session, start: seg.start, initial: m.command, heard: seg.text)
            } else if joined != seg.text, let m = WakeMatcher.match(joined) {
                gatedWake(session: seg.session, start: first?.start ?? seg.start, initial: m.command, heard: joined)
            } else if seg.isFinal && seg.source == .accurate {
                if WakeMatcher.isNearMiss(seg.text) { Log.write("near-miss: \"\(seg.text)\"") }
                if segs.count > 60 { segs.removeFirst(segs.count - 60) }
            }
        case .listening:
            let cmd = liveCommand()
            let words = wordCount(cmd)
            if words > 0 && lastWordCount == 0 && turnWordsAt == 0 { turnWordsAt = CACurrentMediaTime() }
            if words > lastWordCount { lastWordCount = words; lastTextGrowth = CACurrentMediaTime(); flushedWhileEmpty = false }
            else if words < lastWordCount { lastWordCount = words }   // text was revised down (e.g. an echo got stripped)
            if live { if !cmd.isEmpty { lastConvActivity = CACurrentMediaTime() }; refreshHUD() } else { hud.model.transcript = cmd }
        case .confirming:
            // Only speech *after* the request counts, so "cancel my 3pm meeting" can't cancel itself.
            let after = seg.session > endpointSession || seg.start >= endpointAudioEnd - 0.05
            if after && WakeMatcher.containsCancel(seg.text) { cancelSpoken = true }
        default:
            break
        }
    }

    private func upsert(_ u: SegmentUpdate) {
        segs.removeAll { $0.source == u.source && $0.session == u.session && !$0.isFinal }
        if u.isFinal { segs.removeAll { $0.source == u.source && $0.session == u.session && $0.isFinal && abs($0.start - u.start) < 0.001 } }
        segs.append(Seg(source: u.source, session: u.session, start: u.start, end: u.end, text: u.text, isFinal: u.isFinal))
        segs.sort { ($0.session, $0.start) < ($1.session, $1.start) }
    }

    private func command(_ source: SegmentUpdate.Source) -> String {
        let parts = segs.filter { $0.source == source && ($0.session > wakeSession || ($0.session == wakeSession && $0.end > wakeStart + 0.001)) }
        let c = WakeMatcher.stripWake(parts.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))
        return sirAsked ? Controller.stripSummonEcho(c) : c
    }

    /// The mic may catch Ryan's "Sir?" / "Yes, sir?" (partially too: "Yes" arrives before "sir").
    nonisolated static func stripSummonEcho(_ c: String) -> String {
        // Sep 27: the greeting varies now, so drop any of them if the mic caught it back.
        let words = { (x: String) in x.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init) }
        let heard = words(c)
        let lines = ["Sir?", "Yes, sir?", "At your service.", "Go ahead, sir.", "I'm listening.", "What do you need, sir?", "Morning, sir.", "Good morning, sir.",
                     "Evening, sir.", "Good evening, sir.", "Still up, sir?", "Burning the midnight oil, sir?"].map(words).sorted { $0.count > $1.count }
        for l in lines where l.count <= heard.count && Array(heard.prefix(l.count)) == l {
            var rest = Substring(c)
            for _ in 0..<l.count {   // drop that many words from the original text
                rest = rest.drop(while: { !$0.isLetter && $0 != "'" }).drop(while: { $0.isLetter || $0 == "'" })
            }
            return WakeMatcher.clean(String(rest.drop(while: { !$0.isLetter && !$0.isNumber })))
        }
        return WakeMatcher.clean(c.replacingOccurrences(of: #"^(?i)(yes|yeah)?[\s,.?!]*(sir)?[\s?.!,]*"#, with: "", options: .regularExpression))
    }

    private func wordCount(_ s: String) -> Int { s.split(whereSeparator: { $0 == " " }).count }

    /// Whichever stream currently has more words (the fast one usually leads).
    private func liveCommand() -> String {
        let f = command(.fast), a = command(.accurate)
        return wordCount(a) > wordCount(f) ? a : f
    }

    /// Text to send: accurate stream unless it's clearly incomplete.
    private func bestCommand() -> String {
        let a = command(.accurate), f = command(.fast)
        let aw = wordCount(a), fw = wordCount(f)
        if aw == 0 { return f }
        if Double(aw) < Double(fw) * 0.6 { Log.write("accurate text incomplete (\(aw) vs \(fw) words); using fast"); return f }
        return a
    }

    // MARK: wake + listen

    /// Menu "Talk to Aside Now": same flow without saying the phrase.
    func manualWake() {
        guard state == .idle else { return }
        let sid = recognizer.currentSessionID
        ignoreUpToSession = sid
        wake(session: sid + 1, start: 0, initial: "", heard: "(manual)")
    }

    // MARK: drop on the notch (Sep 30, after Coucou)

    private func startDrops() {
        guard drops.onDrop == nil else { return }
        drops.onPhase = { [weak self] phase in self?.dropPhase(phase) }
        drops.onDrop = { [weak self] items in self?.dropped(items) }
        drops.start()
    }

    /// A file or link on its way to the notch: Jarvis comes out to meet it (island style only); gone again if it isn't dropped.
    private func dropPhase(_ phase: DropCatcher.Phase) {
        guard Settings.shared.hudStyle == .island, Settings.shared.hud else { return }
        let m = hud.model
        m.drop = phase
        if phase != .none {
            if state == .idle && !live && !m.shown { m.phase = .listening; m.transcript = ""; m.status = ""; m.hint = "" }
            hud.present(anchor: nil)
        } else if state == .idle && !live && attached.isEmpty {
            hud.dismiss(after: 0.2)
        } else if Settings.shared.paused && !live {
            showMuted()
        }
    }

    /// Swallowed: the orb gulps, the island hops, and Jarvis listens for what to do with it (a drop is a clear "I want
    /// you", so it also unmutes him). In an open conversation it simply rides with your next turn.
    private func dropped(_ items: [DropItem]) {
        let m = hud.model
        m.drop = .none
        Task { @MainActor in
            let ready = await Task.detached(priority: .userInitiated) { DropItem.readable(items) }.value
            self.attached = ready
            self.attachedAt = CACurrentMediaTime()
            let at = self.attachedAt
            m.attachment = DropItem.summary(ready)
            m.gulps += 1
            self.hud.island.hop()
            Log.write("DROP: \(ready.count) item(s)" + (Settings.shared.logTranscripts ? " \(m.attachment)" : ""))
            // Unused after 3 minutes: let it go.
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
                guard let self, self.attachedAt == at, !self.attached.isEmpty else { return }
                Log.write("drop expired unused"); self.clearAttached()
            }
            if Settings.shared.paused { await self.setMuted(false) }
            if self.live { self.refreshHUD() }
            else if self.state == .idle { self.manualWake() }
        }
    }

    private func clearAttached() {
        attached = []
        if !hud.model.attachment.isEmpty { hud.model.attachment = "" }
    }

    /// Oct 2: a wake phrase heard while the Mac was playing sound is checked against what the Mac played first (~0.5 s);
    /// if the Mac said it (a video, a call, music), Jarvis stays asleep. With the Mac quiet there is no check and no delay.
    private func gatedWake(session: Int, start: Double, initial: String, heard: String) {
        guard !dryRun, SystemAudio.shared.running, SystemAudio.shared.playedRecently(within: 4) else {
            wake(session: session, start: start, initial: initial, heard: heard); return
        }
        guard wakeCheckSession != session else { return }   // already checking this burst
        wakeCheckSession = session
        Task { @MainActor in
            let fromMac = await SystemAudio.shared.wakeCameFromMac()
            guard self.state == .idle, !Settings.shared.paused else { return }
            if fromMac {
                self.ignoreUpToSession = max(self.ignoreUpToSession, session)
                Log.write("WAKE ignored (the Mac said it): \"\(heard)\"")
                return
            }
            self.wake(session: session, start: start, initial: initial, heard: heard)
        }
    }

    private func wake(session: Int, start: Double, initial: String, heard: String) {
        let now = CACurrentMediaTime()
        runID += 1
        state = .listening
        wakeSession = session; wakeStart = start
        wakeAt = now; lastTextGrowth = now
        lastWordCount = wordCount(initial)
        turnWordsAt = initial.isEmpty ? 0 : now
        flushedWhileEmpty = false
        marks = ["wake": now]
        speculation?.cancel(); speculation = nil; specTries = 0
        sirAsked = false
        escPressed = false; returnPressed = false; cancelSpoken = false
        recognizer.setHoldOpen(true)
        Log.write("WAKE heard=\"\(heard)\"")
        // Oct 7: warm the live call while you are still talking; the 2-3 s connect hides inside your sentence.
        if !live && !inLiveCall && useLive { liveCall.prepare() }
        // Sep 30: open the voice sockets while you are still talking, so the first reply doesn't pay the handshake.
        if !dryRun && !live && Settings.shared.voiceReplies { speaker.warmUp() }
        if !dryRun && Lane.enabled { LaneModel.warmUp() }
        if !live { play("Pop") }   // "Pop" = the chosen chime (Siri Listen)
        if live { refreshHUD() } else {
            hud.model.phase = .listening
            hud.model.status = "Listening"
            hud.model.transcript = initial
            hud.model.hint = live ? "" : "Yes, sir?"
            hud.present(anchor: nil)
        }

        if !dryRun && Settings.shared.delivery != .background {
            let rid = runID
            popupTask = Task { @MainActor in
                let r = await self.popup.open()
                self.marks["popup"] = CACurrentMediaTime()
                Log.write("popup open: \(r) in \(Int(((self.marks["popup"] ?? now) - now) * 1000)) ms")
                if case .ready = r, rid == self.runID { self.hud.present(anchor: self.popup.popupWindowFrame()) }
                return r
            }
        } else { popupTask = nil }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard state == .listening else { return }
        let now = CACurrentMediaTime()
        if escPressed { finish(.cancelled, "Cancelled", sound: "Bottle"); return }
        let ep = Endpointer(baseSilence: Settings.shared.silence)
        let cmd = liveCommand()
        let silence = now - max(wakeAt, lastVoiced)

        if live && cmd.isEmpty {
            wakeAt = max(wakeAt, now - 1)   // an open conversation has no "max request length" while silent
            let quietFor = now - max(lastConvActivity, lastVoiced)
            // After an update you didn't ask for, only a quick reply counts (Sep 25 test: room speech 13 s later got sent).
            let idleLimit = unpromptedOpen ? 6 : Settings.shared.conversationIdle
            // Background noise mustn't hold that short window open: only words count, not raw voice activity.
            let quiet = unpromptedOpen ? now - lastConvActivity : quietFor
            if !agentBusy && speakingKind == nil && speechQueue.isEmpty && quiet >= idleLimit {
                // Sep 29: a conversation you started goes to sleep after a couple of quiet minutes: Jarvis mutes (mic off)
                // until you unmute him. The short window after an update he offered on his own just closes.
                if !unpromptedOpen && Settings.shared.idleMutes && (!dryRun || Settings.testOverride) {
                    Log.write("conversation idle \(Int(quiet)) s; muting")
                    Task { await self.setMuted(true); self.endConversation(say: nil, byEsc: false) }
                    timer?.invalidate(); timer = nil
                    return
                }
                Log.write("conversation idle \(Int(quiet)) s; closing")
                endConversation(say: nil, byEsc: false); return
            }
            if silence >= ep.baseSilence && !flushedWhileEmpty {
                flushedWhileEmpty = true
                Task { await Controller.race(timeout: 0.9) { await self.recognizer.finalizeCurrent() } }
            }
            return
        }
        if now - wakeAt > ep.maxDuration { endpoint(); return }
        if cmd.isEmpty && !live && useLive && silence >= 0.8 && now - wakeAt >= 0.8 {
            // Only "Hey Jarvis": open the live call and let Jarvis greet you in his own voice.
            enterLive(text: nil, greet: Acks.summonedNow()); return
        }
        if cmd.isEmpty && !live && !sirAsked && silence >= 0.8 && now - wakeAt >= 0.8 && Settings.shared.voiceReplies {
            // You said only "Hey Jarvis" and paused: he answers "Sir?" (pre-cached, instant). If the mic catches it,
            // command() strips a leading "sir", so nothing you say is thrown away.
            sirAsked = true
            let line = Acks.summonedNow()
            Log.write("summoned: \(line)")
            Task { await self.speaker.speak(line) }
        }
        if cmd.isEmpty {
            // Sep 29: you said only "Hey Jarvis" and paused. Once he has answered "Sir?", he opens the conversation and
            // waits for you the way he does between turns (the island stays up; a couple of quiet minutes mutes him).
            if silence >= ep.initialWait { finish(.cancelled, "", sound: nil, quiet: true); return }
            if (sirAsked || !Settings.shared.voiceReplies) && silence >= 2.5 && Settings.shared.followUp { holdOpen(); return }
            // Recognizers hold the last words until they're sure; nudge them once so we can decide.
            if silence >= ep.baseSilence && !flushedWhileEmpty {
                flushedWhileEmpty = true
                Task { await Controller.race(timeout: 0.9) { await self.recognizer.finalizeCurrent() } }
            }
            return
        }
        // Your words look finished: start Jev and the reply now, so most of the wait hides inside the silence window.
        if Lane.enabled, !useLive, Lane.looksFinished(cmd, silence: silence) { speculate(cmd) }
        if silence >= ep.requiredSilence(for: cmd) { endpoint(); return }
        // Noisy-room backstop: the voice gate never closes, but no new words for a while.
        if silence < 0.3 && now - lastTextGrowth >= ep.requiredSilence(for: cmd) + 1.8 {
            Log.write("endpoint via text stall (noisy audio)"); endpoint()
        }
    }

    // MARK: endpoint → countdown → deliver

    private func endpoint() {
        timer?.invalidate(); timer = nil
        let now = CACurrentMediaTime()
        marks["endpoint"] = now
        Log.write("endpoint: \(Int((now - lastVoiced) * 1000)) ms after last voiced audio")
        recognizer.setHoldOpen(false)
        endpointSession = recognizer.currentSessionID
        endpointAudioEnd = segs.filter { $0.session == endpointSession }.map { $0.end }.max() ?? 0
        escPressed = false; returnPressed = false; cancelSpoken = false

        // Countdown starts now; finalization + typing happen inside it.
        let window = (dryRun || live) ? 0 : Settings.shared.cancelWindow
        countdownDeadline = now + window
        state = .confirming
        hud.model.phase = .confirming
        hud.model.status = window > 0 ? "Sending · say \u{201C}cancel\u{201D} or press esc" : "Sending"
        hud.model.transcript = liveCommand()
        hud.startCountdown(window)

        let rid = runID
        Task { @MainActor in
            let f0 = CACurrentMediaTime()
            await Controller.race(timeout: 0.9) { await self.recognizer.finalizeCurrent() }
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard rid == self.runID, self.state == .confirming else { return }
            let cmd = self.bestCommand()
            Log.write("finalize \(Int((CACurrentMediaTime() - f0) * 1000)) ms; COMMAND: " + (Settings.shared.logTranscripts ? "\"\(cmd)\"" : "[\(cmd.count) chars]"))
            if Lane.enabled, !self.useLive || self.live, !cmd.isEmpty { self.speculate(cmd) }
            if self.live {
                if cmd.isEmpty || self.wordCount(cmd) == 0 { self.listenNext(); return }
                self.hud.model.transcript = cmd
                await self.deliver(cmd, rid: rid)
                return
            }
            if cmd.isEmpty { self.finish(.cancelled, "Didn't catch a request", sound: "Bottle"); return }
            if WakeMatcher.isCancel(cmd) { self.finish(.cancelled, "Cancelled", sound: "Bottle"); return }
            self.hud.model.transcript = cmd
            if self.useLive { self.enterLive(text: cmd, greet: nil); return }
            await self.deliver(cmd, rid: rid)
        }
    }

    /// Polls until the countdown ends. Returns false if cancelled by voice or esc.
    private func awaitCountdown(rid: Int, early: (() -> Bool)? = nil) async -> Bool {
        while CACurrentMediaTime() < countdownDeadline {
            if rid != runID || escPressed || cancelSpoken { return false }
            if returnPressed { return true }
            if early?() == true { Log.write("lane: countdown skipped, the answer is ready"); return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return rid == runID && !escPressed && !cancelSpoken
    }

    private func deliver(_ cmd: String, rid: Int) async {
        if dryRun {
            onDryRunDeliver?(cmd)
            finish(.sent, "Dry run", sound: nil); return
        }
        let mode = Settings.shared.delivery
        if mode != .background {
            var r = await popupTask?.value ?? .failed("not opened")
            guard rid == runID else { return }
            if case .ready = r, popup.focusedPopupTextArea() == nil { r = await popup.open() }
            if case .ready = r {
                if await popup.fill(cmd) {
                    marks["filled"] = CACurrentMediaTime()
                    hud.present(anchor: popup.popupWindowFrame())
                    let go = await awaitCountdown(rid: rid)
                    guard rid == runID else { return }
                    if !go { popup.clearAndClose(); finish(.cancelled, "Cancelled · nothing sent", sound: "Bottle"); return }
                    if noSubmit {
                        popup.clearAndClose()
                        Log.write("TEST fill verified; cleared without sending")
                        finish(.cancelled, "Test passed · cleared, not sent", sound: nil); return
                    }
                    if returnPressed { finish(.sent, "Sent to Aside", sound: "Pop"); return }
                    switch await popup.submit(expected: cmd) {
                    case .sent:
                        Log.write("SENT via popup; speech end → sent \(Int((CACurrentMediaTime() - (marks["endpoint"] ?? 0)) * 1000)) ms")
                        finish(.sent, "Sent to Aside", sound: "Pop")
                    case .alreadyGone:
                        finish(.cancelled, "Popup closed · nothing sent", sound: "Bottle")
                    case .failed:
                        finish(.error, "Couldn\u{2019}t confirm it sent", sound: "Basso")
                    }
                    return
                }
                Log.write("popup fill not verified")
                popup.clearAndClose()
            } else {
                Log.write("popup unavailable: \(r)")
            }
            if mode == .popupOnly { finish(.error, "Couldn\u{2019}t reach the Aside popup", sound: "Basso"); return }
        }
        // Background task through the aside CLI.
        guard BackgroundDelivery.available else { finish(.error, "aside CLI not found", sound: "Basso"); return }
        hud.model.status = "Starting in background · say \u{201C}cancel\u{201D} or press esc"
        let go = await awaitCountdown(rid: rid, early: { [weak self] in self?.laneReady(cmd) ?? false })
        guard rid == runID else { return }
        if !go { finish(.cancelled, "Cancelled · nothing sent", sound: "Bottle"); return }
        if noSubmit { Log.write("TEST background path reached; not started"); finish(.cancelled, "Test passed · background path", sound: nil); return }
        await converse(cmd)
    }

    // MARK: live conversation

    /// Every turn lands here (first turn after its countdown; later turns right away).
    private func converse(_ cmd: String) async {
        // Oct 2: in an open conversation no wake phrase is needed, so a video talking nearby could pass for him. If the
        // Mac was playing sound while these words came in and most of them were in that sound, they weren't his.
        if live, !dryRun, SystemAudio.shared.running {
            let span = turnWordsAt > 0 ? CACurrentMediaTime() - turnWordsAt + 0.8 : 6
            if await SystemAudio.shared.commandCameFromMac(cmd, spokenOver: min(max(span, 2), 13)) {
                Log.write("ignored Mac audio turn: \(cmd)")
                listenNext(); return
            }
        }
        let now = CACurrentMediaTime()
        let starting = !live
        if starting { beginConversation() }
        lastConvActivity = now
        if !starting && Router.isNoise(cmd) {
            Log.write("ignored noise turn: \(cmd)")
            listenNext(); return
        }
        // "Yeah", "mm-hmm" said over Jarvis is listening, not a request, unless he just asked you something.
        if !starting && heardDuringSpeech && Router.isBackchannel(cmd) && !lastSpokenText.hasSuffix("?") {
            Log.write("ignored backchannel: \(cmd)")
            heardDuringSpeech = false
            listenNext(); return
        }
        heardDuringSpeech = false
        unpromptedOpen = false   // you answered: a normal conversation from here
        turnSeq += 1
        laneTurn?.cancel()   // a new turn ends whatever was still being written for the last one
        lastUserCmd = cmd
        let intent = Router.intent(cmd, agentBusy: agentBusy)
        Log.write("TURN (\(intent)\(agentBusy ? ", Aside busy" : "")): \(cmd)")
        let voice = Settings.shared.voiceReplies
        var prompt = voice ? cmd + AsideCLI.voiceSuffix : cmd
        if let a = lastAnnouncement, CACurrentMediaTime() - a.at < 180 {
            prompt = "[You (Jarvis) just told me out loud: \"\(a.text)\"]\n" + prompt
            lastAnnouncement = nil
        }
        // Sep 29: greetings and small talk get an instant, fitting line, never "On it." (Social.swift).
        if voice, await socialTurn(cmd, intent: intent, starting: starting) { return }
        // Sep 30: what you dropped on the notch, and what's in front of you when you say "this". Either makes the turn
        // an agent turn (the prompt is no longer plain), since only the agent can open a file or a page.
        var carried = false
        let dropsHere = !attached.isEmpty && intent != .endConversation && intent != .stop && !Router.isNoise(cmd)
        if dropsHere {
            prompt = DropItem.promptBlock(attached) + prompt
            Log.write("turn carries \(attached.count) dropped item(s)")
            carried = true
            clearAttached()
        }
        if Settings.shared.screenContext && ScreenContext.refersToScreen(cmd) && intent != .endConversation && intent != .stop {
            if let ctx = await ScreenContext.capture() {
                prompt = ctx.promptBlock + prompt
                Log.write("turn carries screen context: \(ctx.logLine)")
                carried = true
            }
        }

        switch intent {
        case .endConversation:
            if agentBusy { say(Acks.pick(Acks.carryOn), .ack); endConversation(say: nil, byEsc: false, afterSpeech: true) }
            else { endConversation(say: cmd.lowercased().contains("night") ? Acks.pick(Acks.goodnight) : Acks.pick(Acks.signOff), byEsc: false) }
            return
        case .stop:
            say(Acks.pick(Acks.stopped), .ack)
            if let sid = convSession { _ = await AgentRun.control(["session", "stop", sid]) }
            run?.terminate()
        case .status:
            say(lastStep.map { "I'm " + Controller.lowerFirst($0) + "." } ?? "Still thinking it through.", .answer)
        case .steer where agentBusy && convSession != nil:
            note("Adjusting course")
            turnsAddedDuringRun += 1
            _ = await AgentRun.control(["session", "steer", convSession!, prompt])
            reflexAck(cmd, busy: true)
        case .queue where agentBusy && convSession != nil, .steer where agentBusy && convSession != nil:
            note("Queued for next")
            turnsAddedDuringRun += 1
            _ = await AgentRun.control(["session", "queue", convSession!, prompt])
            reflexAck(cmd, busy: true)
        default:
            // Sep 27 reflex: one call decides. A safe general question is answered outright in ~2 s; anything else
            // starts the agent and Jarvis says the short, specific thing a person would say before going off to do it.
            let plain = prompt == (voice ? cmd + AsideCLI.voiceSuffix : cmd)
            // Oct 2: follow-ups in an open chat get the quick lane too (Luna sees the last few exchanges and hands off
            // whenever the answer needs the agent's tools); only work already in progress goes straight to Aside.
            let canAnswer = voice && plain && !agentBusy
            if canAnswer && Lane.enabled && FastPath.available {
                await laneAnswer(cmd, prompt: prompt)
                break
            }
            if canAnswer && FastPath.available {
                fastBusy = true
                refreshHUD()
                let r = await FastPath.reply(cmd, history: recentTurns, busy: false)
                fastBusy = false
                if let r, r.mode == "answer", live, !endedByEsc {
                    fastPairs.append((q: cmd, a: r.say))
                    if fastPairs.count > 3 { fastPairs.removeFirst() }
                    remember(cmd, r.say)
                    say(r.say, .answer)
                    break
                }
                startRun(withDigest(withEarlier(prompt)))
                if let r, r.mode == "ack", live, !endedByEsc, agentBusy, pendingAnswer == nil { say(r.say, .ack) }
                break
            }
            startRun(withDigest(withEarlier(prompt)))
            if voice && (plain || carried) { reflexAck(cmd, busy: false, opener: Social.read(cmd).flatMap { $0.rest == nil ? nil : Social.opener(for: $0) }) }
        }
        // First real turn of a conversation (including one held open after a bare "Hey Jarvis"): talk-over on now.
        if !dryRun { await enableEchoCancel(true) }
        listenNext()
    }

    /// Small talk, answered on the spot with a line voiced in advance. True when this turn was handled here.
    /// The table reads the words; mid-conversation, short words it missed get one quick Jev check (the first turn
    /// already asks Jev inside its route call). While Aside works, a greeting gets "Right here" plus what it's doing.
    private func socialTurn(_ cmd: String, intent: Intent, starting: Bool) async -> Bool {
        let read = Social.read(cmd, afterQuestion: socialAsked)
        if intent == .stop { return false }
        if intent == .endConversation && read?.kind != .fine { return false }
        var kind = read.flatMap { $0.isPure ? $0.kind : nil }
        let seq = turnSeq
        if kind == nil, read == nil, convSession != nil, !agentBusy, Lane.enabled, Social.worthAsking(cmd) {
            fastBusy = true
            refreshHUD()
            kind = await LaneJev.social(cmd)
            fastBusy = false
            refreshHUD()
            if seq != turnSeq || !live || endedByEsc { return true }
        }
        guard let kind else { return false }
        speculation?.cancel(); speculation = nil
        let line: String
        if agentBusy && [.hello, .checkin, .wellbeing, .yourDay, .whatsup].contains(kind) {
            line = "Right here, sir. " + (lastStep.map { "I'm " + Controller.lowerFirst($0) + "." } ?? "Still at it.")
        } else {
            line = Social.line(for: (read?.isPure == true ? read : nil) ?? SocialRead(kind: kind, named: nil, rest: nil, weakOnly: false))
        }
        Log.write("social: \(kind.rawValue)\(agentBusy ? " (Aside busy)" : "") -> \(line)")
        socialAskedAt = !agentBusy && Social.asksHowHeIs(line) ? CACurrentMediaTime() : 0
        if !agentBusy { spoke(cmd, [line]) }
        say(line, .answer)
        // First real turn of a conversation (including one held open after a bare "Hey Jarvis"): talk-over on now.
        if !dryRun { await enableEchoCancel(true) }
        listenNext()
        return true
    }

    /// Silent end-to-end test of live turns (`--converse-test "..."`, turns split by " || "; add `--in-session` to act as
    /// if an Aside chat is already open): no mic, no sound, no agent. Logs what would be said and whether the agent starts.
    func testConverse(_ text: String, inSession: Bool = false) async {
        dryRun = true
        if inSession { beginConversation(); convSession = "dry-run-session" }
        for turn in text.components(separatedBy: " || ") {
            let t0 = CACurrentMediaTime()
            Log.write("TEST: turn \"\(turn)\"")
            await converse(turn)
            Log.write("TEST: converse returned after \(Int((CACurrentMediaTime() - t0) * 1000)) ms")
            try? await Task.sleep(nanoseconds: 300_000_000)
            while speakingKind != nil || !speechQueue.isEmpty { try? await Task.sleep(nanoseconds: 50_000_000) }
            try? await Task.sleep(nanoseconds: 1_500_000_000)   // late sentences and the acknowledgement
            while speakingKind != nil || !speechQueue.isEmpty { try? await Task.sleep(nanoseconds: 50_000_000) }
            Log.write("TEST: done after \(Int((CACurrentMediaTime() - t0) * 1000)) ms")
        }
    }

    // MARK: fast lane (Sep 28)

    /// Starts Jev and the reply early for words that look finished. Costs nothing if they change: it is thrown away.
    private func speculate(_ cmd: String) {
        guard Settings.shared.voiceReplies, FastPath.available, convSession == nil, !agentBusy, lastAnnouncement == nil,
              attached.isEmpty, !(Settings.shared.screenContext && ScreenContext.refersToScreen(cmd)) else { return }
        let key = Lane.norm(cmd)
        guard !key.isEmpty, speculation?.key != key, specTries < 3, !Router.isNoise(cmd) else { return }
        if case .queue = Router.intent(cmd, agentBusy: false) {} else { return }
        specTries += 1
        speculation?.cancel()
        speculation = LaneTurn(text: cmd, history: recentTurns, afterQuestion: socialAsked)
    }

    /// The turn for these exact words: the early one if it matches, otherwise a fresh one.
    private func takeTurn(for cmd: String) -> LaneTurn {
        if let s = speculation, !s.cancelled, s.key == Lane.norm(cmd) { speculation = nil; return s }
        speculation?.cancel(); speculation = nil
        return LaneTurn(text: cmd, history: recentTurns, afterQuestion: socialAsked)
    }

    /// The first turn of a conversation. Clock questions answer from the clock; requests that plainly need tools start
    /// the agent at once; plain questions wait only for Jev's yes and the first finished sentence of the reply.
    private func laneAnswer(_ cmd: String, prompt: String) async {
        let turn = takeTurn(for: cmd)
        laneTurn = turn
        let seq = turnSeq
        func stale() -> Bool { laneTurn !== turn || turnSeq != seq || !live || endedByEsc }
        let sinceEndpoint = { Int((CACurrentMediaTime() - (self.marks["endpoint"] ?? turn.startedAt)) * 1000) }
        switch turn.plan {
        case .social(let line):
            Log.write("lane: small talk \(sinceEndpoint()) ms after the endpoint")
            socialAskedAt = Social.asksHowHeIs(line) ? CACurrentMediaTime() : 0
            spoke(cmd, [line])
            say(line, .answer)
        case .instant(let line):
            Log.write("lane: clock answer \(sinceEndpoint()) ms after the endpoint")
            if let o = turn.opener { say(o, .answer) }
            spoke(cmd, [turn.opener, line].compactMap { $0 })
            say(line, .answer)
        case .agent:
            Log.write("lane: straight to the agent")
            startRun(withDigest(withEarlier(prompt)))
            sayOpener(turn, seq: seq)
        case .candidate:
            fastBusy = true
            refreshHUD()
            // Oct 2: no canned "Let me think." while the reply is written (~1 s on Luna); the orb shows it is thinking.
            let v = await turn.decision(timeout: 2.5)
            // Sep 29: small talk Jev recognised ("yo what's good my guy") gets its ready line now, no waiting on a reply.
            if !stale(), turn.opener == nil, let k = v?.social {
                fastBusy = false
                turn.cancel()
                let line = Social.line(for: SocialRead(kind: k, named: nil, rest: nil, weakOnly: false))
                Log.write("lane: small talk (jev \(k.rawValue)) \(sinceEndpoint()) ms after the endpoint")
                socialAskedAt = Social.asksHowHeIs(line) ? CACurrentMediaTime() : 0
                spoke(cmd, [line])
                say(line, .answer)
                return
            }
            var first: String?
            // Oct 2: Luna judges for itself (it says HANDOFF when tools are needed), so the reply is used unless Jev is
            // fairly sure this needs live data, his things, or an action. Jev being down no longer sends everything to
            // the agent. Never wait longer than 6 s from when the turn began.
            let jevSaysTools = v.map { !$0.fast && $0.route != "chat" && $0.p >= 0.7 } ?? false
            if !stale(), !jevSaysTools { first = await turn.sentence(0, timeout: max(1, 6 - (CACurrentMediaTime() - turn.startedAt))) }
            fastBusy = false
            if stale() { turn.cancel(); return }
            if let first {
                Log.write("lane: answering \(sinceEndpoint()) ms after the endpoint")
                if let o = turn.opener { say(o, .answer) }
                spoke(cmd, [turn.opener, first].compactMap { $0 })
                say(first, .answer)
                streamRest(of: turn, after: first, cmd: cmd, seq: seq)
            } else {
                Log.write("lane: agent (jev \(v.map { "\($0.route) \(String(format: "%.2f", $0.p))" } ?? "unavailable"), \(turn.handedOff ? "Luna handed off" : "no quick reply"))")
                startRun(withDigest(withEarlier(prompt)))
                if fillerTurn != seq { sayOpener(turn, seq: seq) }
            }
        }
    }

    /// Sentence two of a quick reply, queued as they finish (the voice pre-loads each while the last one plays).
    private func streamRest(of turn: LaneTurn, after first: String, cmd: String, seq: Int) {
        Task { @MainActor in
            var said = [first]
            for i in 1..<2 {
                guard let s = await turn.sentence(i, timeout: 5) else { break }
                guard !turn.cancelled, self.turnSeq == seq, self.live, !self.endedByEsc, self.laneTurn === turn else { return }
                self.speaker.prefetch([s])
                self.say(s, .answer)
                said.append(s)
            }
            guard self.turnSeq == seq else { return }
            if let i = self.recentTurns.lastIndex(where: { $0.q == cmd }) { self.recentTurns[i].a = said.joined(separator: " ") }
            if let i = self.fastPairs.lastIndex(where: { $0.q == cmd }) { self.fastPairs[i].a = said.joined(separator: " ") }
        }
    }

    /// Keeps the Aside session's context and the next fast reply's history in step with what was said aloud.
    private func spoke(_ cmd: String, _ lines: [String]) {
        let a = lines.joined(separator: " ")
        fastPairs.append((q: cmd, a: a))
        if fastPairs.count > 3 { fastPairs.removeFirst() }
        remember(cmd, a)
    }

    /// The instant "On it." / "Let me look into that." (voiced in advance, so there is no wait): you know it landed.
    private func sayFiller(_ line: String, opener: String? = nil) {
        guard Settings.shared.voiceReplies, live, !endedByEsc else { return }
        fillerTurn = turnSeq
        // Sep 29: "Morning, sir." then "Let me check your calendar." (both voiced in advance; one "sir" at most).
        if let o = opener, speakingKind == nil, speechQueue.isEmpty {
            say(o, .filler)
            speechQueue.append((o.lowercased().contains("sir") ? LaneStatus.dropSir(line) : line, .filler))
            return
        }
        say(line, .filler)
    }

    /// Oct 2: the first line for a job the agent is doing, written for this request by the quick model ("Boone's weekend
    /// forecast, coming up."). A greeting in front is said at once; the line follows when ready. If it isn't ready
    /// within 2.5 s, or the answer got there first, nothing is said: the orb already shows Jarvis is working.
    private func sayOpener(_ turn: LaneTurn, seq: Int) {
        guard Settings.shared.voiceReplies, live, !endedByEsc else { return }
        fillerTurn = seq
        let greeting = turn.opener
        if let g = greeting, speakingKind == nil, speechQueue.isEmpty { say(g, .filler) }
        let rid = runID
        Task { @MainActor in
            let started = CACurrentMediaTime()
            guard let line = await turn.opener(timeout: 2.5) else { Log.write("lane: no opener"); return }
            guard self.turnSeq == seq, rid == self.runID, self.live, !self.endedByEsc, self.agentBusy, self.pendingAnswer == nil else { return }
            Log.write("lane: opener after \(Int((CACurrentMediaTime() - started) * 1000)) ms: \(line)")
            self.say(greeting?.lowercased().contains("sir") == true ? LaneStatus.dropSir(line) : line, .filler)
        }
    }

    /// True when the reply to these words can already be spoken, so the send countdown (nothing is sent) may end early.
    private func laneReady(_ cmd: String) -> Bool {
        if Settings.shared.voiceReplies, Social.read(cmd, afterQuestion: socialAsked)?.isPure == true { return true }   // small talk: nothing is sent
        guard Lane.enabled, let s = speculation, !s.cancelled, s.key == Lane.norm(cmd) else { return false }
        return s.readyToSpeak
    }

    /// Sep 30: a school/task question gets the local digest in front (once per Aside session), so the agent can answer
    /// from what the Mac already knows instead of browsing. Agent only: never the fast lane (by design).
    private var digestSession: String?
    private var lastRunHadDigest = false
    private func withDigest(_ prompt: String) -> String {
        lastRunHadDigest = false
        guard Digest.enabled, Digest.relevant(lastUserCmd), convSession == nil || convSession != digestSession,
              let d = Digest.text() else { return prompt }
        lastRunHadDigest = true
        if convSession != nil { digestSession = convSession }
        Log.write("digest attached (\(d.count) chars)")
        return d + "\n\n" + prompt
    }

    /// The Aside session didn't hear the fast answers: give it that context once.
    private func withEarlier(_ prompt: String) -> String {
        guard !fastPairs.isEmpty else { return prompt }
        let earlier = fastPairs.map { "Me: \($0.q)\nYou: \($0.a)" }.joined(separator: "\n")
        fastPairs.removeAll()
        return "[Earlier in this voice chat, answered quickly without tools:\n\(earlier)]\n" + prompt
    }

    private func remember(_ q: String, _ a: String) {
        recentTurns.append((q: q, a: a))
        if recentTurns.count > 4 { recentTurns.removeFirst() }
    }

    /// Say the natural first line without holding up the agent (it's already running).
    private func reflexAck(_ cmd: String, busy: Bool, opener: String? = nil) {
        guard Settings.shared.voiceReplies else { return }
        if Lane.enabled {
            // Sep 28: a quiet "Noted, sir." for an addition to work in progress. Oct 2: a new request gets a line
            // written for it instead of a canned one; what he's actually doing is then spoken as status beats.
            if busy { sayFiller(Fillers.pick(for: cmd, busy: true), opener: opener); return }
            sayOpener(LaneTurn(text: cmd, history: recentTurns, agentOnly: true), seq: turnSeq)
            return
        }
        guard FastPath.available else { return }
        let rid = runID
        Task { @MainActor in
            guard let r = await FastPath.reply(cmd, history: self.recentTurns, busy: busy, kind: "ack") else { return }
            guard rid == self.runID, self.live, !self.endedByEsc, self.agentBusy, self.pendingAnswer == nil else { return }
            self.say(r.say, .ack)
        }
    }

    /// A reminder you set comes due: spoken even in quiet hours (you asked for it); mute keeps it to the notification.
    private func deliverReminder(_ r: Reminder) {
        guard !Settings.shared.paused, Settings.shared.voiceReplies else { return }
        if live { say(r.text, .answer); return }
        announce(Proactive.Update(text: r.text, key: "remind:\(r.id)", validUntil: Date().addingTimeInterval(3 * 3600)))
    }

    private func beginConversation() {
        live = true
        endedByEsc = false
        // Same chat if you come back within 10 minutes.
        if CACurrentMediaTime() - lastConvEndedAt > 600 { convSession = nil; fastPairs.removeAll() }
        Log.write("CONVERSATION START (session \(convSession ?? "new"))")
        speaker.onLevel = { [weak self] l in if self?.speakingKind != nil { self?.hud.model.level = CGFloat(l) * 0.6 } }
        speaker.onSentence = nil
        speaker.onCaption = { [weak self] text, dur in self?.showCaption(text, duration: dur) }
        speaker.prefetch(Acks.all)
        speaker.warmUp()
    }

    private func endConversation(say line: String?, byEsc: Bool, afterSpeech: Bool = false) {
        guard live else { return }
        unpromptedOpen = false
        Log.write("CONVERSATION END\(byEsc ? " (esc)" : "")")
        endedByEsc = byEsc
        if byEsc { stopSpeaking() }
        speculation?.cancel(); speculation = nil
        live = false
        lastConvEndedAt = CACurrentMediaTime()
        timer?.invalidate(); timer = nil
        resetRun()
        Task { @MainActor in
            if let line { self.say(line, .answer) }
            // Let the goodbye (or pending ack) finish, then drop back to the light wake-word mode.
            while self.speakingKind != nil || !self.speechQueue.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
            if !self.live {
                self.speaker.coolDown()
                if Settings.shared.paused {
                    self.recognizer.echoCancelWanted = false
                    self.showMuted()
                } else {
                    self.hud.dismiss(after: 0.1)
                    await self.enableEchoCancel(false)
                }
            }
        }
    }

    /// "Hey Jarvis" and nothing yet: open the conversation without a turn, so he keeps listening for you.
    private func holdOpen() {
        guard !live, state == .listening else { return }
        Log.write("summoned, no words yet; conversation open and waiting")
        beginConversation()
        lastConvActivity = CACurrentMediaTime()
        listenNext()   // echo cancellation waits for the first real turn: switching it restarts the mic (~0.5 s)
    }

    /// Opens the next turn: keep listening without the wake phrase.
    private func listenNext() {
        guard live else { return }
        resetRun()
        let sid = recognizer.currentSessionID
        ignoreUpToSession = sid
        wake(session: sid + 1, start: 0, initial: "", heard: "(conversation)")
    }

    /// Discards what the mic heard so far in this turn (e.g. Aside's own voice without echo cancellation).
    private func restartTurn() {
        guard live, state == .listening else { return }
        ignoreUpToSession = recognizer.currentSessionID
        recognizer.resetSession()
        segs.removeAll()
        wakeSession = ignoreUpToSession + 1; wakeStart = 0
        lastWordCount = 0
        turnWordsAt = 0
        wakeAt = CACurrentMediaTime()
        refreshHUD()
    }

    private func enableEchoCancel(_ on: Bool) async {
        guard Settings.shared.echoCancel || !on, recognizer.echoCancelWanted != on, !Settings.shared.paused else { return }
        recognizer.echoCancelWanted = on
        suppressRestartUntil = CACurrentMediaTime() + 4
        let t0 = CACurrentMediaTime()
        recognizer.stop()
        do { try await recognizer.start() }
        catch {
            Log.write("echo cancel switch failed (\(error)); staying without it")
            recognizer.echoCancelWanted = false
            try? await recognizer.start()
        }
        suppressRestartUntil = CACurrentMediaTime() + 3
        lastRestart = CACurrentMediaTime()
        Log.write("echo cancellation \(recognizer.echoCancelActive ? "on" : "off") in \(Int((CACurrentMediaTime() - t0) * 1000)) ms")
        if live && state == .listening { restartTurn() }
    }

    // MARK: Aside runs

    private func startRun(_ prompt: String, isRetry: Bool = false) {
        if dryRun { Log.write("TEST: the agent would start now (\(prompt.count) chars)"); return }
        run?.terminate()
        lastRunPrompt = prompt
        runRetried = isRetry
        lastStep = nil
        pendingAnswer = nil
        turnsAddedDuringRun = 0
        headsUpSpoken = false
        runSteps = []
        statusSaid = []
        statusStep = nil
        let r = AgentRun(prompt: prompt, resume: convSession)
        r.onEvent = { [weak self, weak r] e in guard let self, let r, self.run === r else { return }; self.handleRun(e) }
        r.onExit = { [weak self, weak r] code in guard let self, let r, self.run === r else { return }; self.runEnded(code) }
        run = r
        idleChecks = 0
        if !r.start() { run = nil; say("Sorry, I couldn't reach Aside.", .answer); return }
        runWatch?.invalidate()
        runWatch = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkRun() } }
        scheduleStatus(after: 6)
        refreshHUD()
    }

    // MARK: spoken status while Aside works (Sep 28)
    //
    // Like a person working beside you: "Searching the web now." at ~6 s, then an update every ~20 s only when he has
    // moved on to something new (or ~40 s have passed: "Still going through your inbox, sir."). At most four per task,
    // never over you, over an answer, or right after something was said. `progressLines` = false turns them off.

    private func scheduleStatus(after delay: TimeInterval) {
        statusWork?.cancel(); statusWork = nil
        guard progressLines, Settings.shared.voiceReplies else { return }
        let w = DispatchWorkItem { [weak self] in self?.statusBeat() }
        statusWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func statusBeat() {
        guard let r = run, r.isRunning, live, !endedByEsc, statusSaid.count < 4 else { return }
        let now = CACurrentMediaTime()
        let youreTalking = state == .listening && !liveCommand().isEmpty
        if speakingKind != nil || youreTalking || pendingAnswer != nil || now - lastSpokenAt < 4 { scheduleStatus(after: 2.5); return }
        let step = lastStep
        let fresh = step != nil && step != statusStep
        if statusSaid.isEmpty {
            // The first beat waits for a real step (up to ~12 s), so it says something specific.
            if step == nil && now - r.startedAt < 12 { scheduleStatus(after: 1.5); return }
        } else if !fresh && now - lastStatusAt < 40 {
            scheduleStatus(after: 5); return
        }
        statusStep = step
        lastStatusAt = now
        let cmd = lastUserCmd, steps = runSteps, said = statusSaid
        Task { @MainActor in
            // "Sir" at most every third line or so, and never twice running.
            let allowSir = !self.lastSpokenText.lowercased().contains("sir") && Double.random(in: 0..<1) < 0.4
            let written = await LaneStatus.line(request: cmd, steps: steps, said: said, allowSir: allowSir, timeout: 3.5)
            guard self.run === r, r.isRunning, self.live, !self.endedByEsc, self.pendingAnswer == nil,
                  let line = written ?? LaneStatus.fallback(step: step, said: said) else { self.scheduleStatus(after: 20); return }
            Log.write("status: \(line)\(written == nil ? " (from the step)" : "")")
            self.statusSaid.append(line)
            self.lastStatusAt = CACurrentMediaTime()
            self.say(line, .progress)
            self.scheduleStatus(after: 20)
        }
    }

    private func handleRun(_ e: AgentRun.Event) {
        lastConvActivity = CACurrentMediaTime()
        switch e {
        case .session(let id):
            convSession = id
            if lastRunHadDigest { digestSession = id }
            Log.write("session \(id)")
        case .step(let title):
            // Steps are shown on the orb, never spoken (design: show it, then give the output).
            // One exception (Sep 25): a first-line heads-up for a long task ("This will take a few minutes, sir.").
            if let p = pendingAnswer, !headsUpSpoken, SpokenText.isHeadsUp(p) {
                headsUpSpoken = true
                Log.write("heads-up: \(p)")
                say(SpokenText.from(p), .ack)
            }
            pendingAnswer = nil          // text before a tool call was Aside thinking out loud, not the answer
            lastStep = title
            runSteps.append(title)
            Log.write("step: \(title)")
            refreshHUD()
        case .toolWithoutTitle:
            pendingAnswer = nil
        case .text(let t):
            // Hold it: if another step follows, it was an in-between remark. Spoken when the run ends,
            // or (when you added requests mid-task) once no step follows within a few seconds.
            pendingAnswer = t
            if turnsAddedDuringRun > 0 {
                let held = t
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                    guard let self, self.pendingAnswer == held else { return }
                    self.speakAnswer(held)
                }
            }
        case .error(let msg):
            Log.write("run error: \(msg)")
            if msg.lowercased().contains("not found") && !runRetried {
                // Aside lost the session (seen Sep 24). Start fresh once, same request.
                Log.write("session lost; retrying as a new session")
                convSession = nil
                let p = lastRunPrompt
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.startRun(p, isRetry: true) }
            } else if !endedByEsc {
                say("Sorry, that didn't go through.", .answer)
            }
        }
    }

    private func speakAnswer(_ t: String) {
        pendingAnswer = nil
        let speech = SpokenText.from(t)
        if !speech.isEmpty { remember(lastUserCmd, speech) }
        Log.write("ANSWER: " + (Settings.shared.logTranscripts ? "\"\(speech)\"" : "[\(speech.count) chars]"))
        guard !speech.isEmpty, Settings.shared.voiceReplies, !endedByEsc else { return }
        if !live {
            // The conversation closed while Aside worked: it's now an unprompted update, so it follows the proactive rules
            // (quiet during school/sleep, only when you're at the Mac; otherwise held until you're back).
            let u = Proactive.Update(text: speech, key: "task:\(speech.hashValue)", validUntil: Date().addingTimeInterval(8 * 3600))
            if Proactive.quietReason() != nil || !Proactive.present || Settings.shared.paused || state != .idle {
                Log.write("holding finished-task update (\(Proactive.quietReason() ?? (Proactive.present ? "busy" : "you're away")))")
                proactive.enqueue(u)
            } else {
                announce(u)
            }
            return
        }
        hud.island.hop()   // Sep 30: the answer is in (Coucou's finish jump, small and silent)
        say(speech, .answer)
    }

    /// Jarvis speaks up: soft "ready" tone, the orb blooms, he says it, then listens briefly for a follow-up
    /// (which is sent with what he just said as context, so "which one?" works).
    private func announce(_ u: Proactive.Update) {
        guard !live, state == .idle, !Settings.shared.paused else { proactive.enqueue(u); return }
        Log.write("ANNOUNCE: \(u.text)")
        play("Pop")
        lastAnnouncement = (u.text, CACurrentMediaTime())
        unpromptedOpen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.reopenForAnswer()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.hud.island.hop() }
            self.say(u.text, .answer)
        }
    }

    private func runEnded(_ code: Int32) {
        statusWork?.cancel(); statusWork = nil
        Log.write("run ended (exit \(code)) after \(Int(CACurrentMediaTime() - (run?.startedAt ?? 0))) s")
        if let t = pendingAnswer { speakAnswer(t) }
        turnsAddedDuringRun = 0
        runWatch?.invalidate(); runWatch = nil
        run = nil
        lastStep = nil
        lastConvActivity = CACurrentMediaTime()
        refreshHUD()
    }

    /// Every 20 s while Aside works: catch sessions that vanished or finished without the CLI exiting.
    private func checkRun() {
        guard let r = run, r.isRunning, let sid = convSession, !statusCheckInFlight else { return }
        statusCheckInFlight = true
        Task { @MainActor in
            let st = await AgentRun.status(of: sid)
            self.statusCheckInFlight = false
            guard self.run === r, r.isRunning, st != "unknown" else { return }
            if st == nil && CACurrentMediaTime() - r.startedAt > 30 {
                Log.write("watch: session \(sid) vanished; restarting request")
                r.terminate()
                self.run = nil
                if !self.runRetried { self.convSession = nil; self.startRun(self.lastRunPrompt, isRetry: true) }
                else if !self.endedByEsc { self.say("Sorry, Aside lost track of that one.", .answer) }
            } else if st == "idle" || st == "interrupted" {
                self.idleChecks += 1
                if self.idleChecks >= 2 { Log.write("watch: session \(sid) is \(st!) but the CLI is still running; closing it"); r.terminate() }
            } else { self.idleChecks = 0 }
        }
    }

    /// An answer arrived after the conversation closed (not via esc): bring the orb back to deliver it.
    private func reopenForAnswer() {
        guard !live, state == .idle, !Settings.shared.paused else { return }
        live = true
        speaker.onLevel = { [weak self] l in if self?.speakingKind != nil { self?.hud.model.level = CGFloat(l) * 0.6 } }
        speaker.onSentence = nil
        speaker.onCaption = { [weak self] text, dur in self?.showCaption(text, duration: dur) }
        lastConvActivity = CACurrentMediaTime()
        listenNext()
        Task { await self.enableEchoCancel(true) }
    }

    // MARK: speech queue (answers > acks > progress; never talks over itself)

    private func say(_ text: String, _ kind: SpeechKind) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        switch kind {
        case .answer:
            // Real content beats a status line; a filler ("Let me think.") is under a second, so it finishes first.
            if speakingKind == .ack || speakingKind == .progress { speaker.stop() }
            speechQueue.removeAll { $0.1 != .answer }
        case .ack, .filler:
            if speakingKind != nil { return }   // something's already talking; an ack would just be noise
        case .progress:
            if speakingKind != nil || !speechQueue.isEmpty { return }
        }
        speechQueue.append((t, kind))
        if speakingKind == nil { Task { await self.drainSpeech() } }
    }

    private func drainSpeech() async {
        while !speechQueue.isEmpty {
            let (text, kind) = speechQueue.removeFirst()
            speakingKind = kind
            lastSpokenText = text
            caption = ""
            refreshHUD()
            await speaker.speak(text)
            lastSpokenAt = CACurrentMediaTime()
            lastConvActivity = lastSpokenAt
        }
        speakingKind = nil
        caption = ""
        hud.model.level = 0
        // Without echo cancellation the mic heard Aside: throw that away before your next words.
        if live && !recognizer.echoCancelActive { restartTurn() }
        refreshHUD()
    }

    /// Shows a spoken chunk one line at a time, each line timed to when Ryan says it (by character share of the audio).
    private func showCaption(_ text: String, duration: TimeInterval) {
        captionWork.forEach { $0.cancel() }; captionWork.removeAll()
        let lines = HUDController.captionLines(text)
        guard !lines.isEmpty else { return }
        let total = Double(lines.reduce(0) { $0 + $1.count })
        var at = 0.0
        for line in lines {
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.speakingKind != nil else { return }
                self.caption = line; self.refreshHUD()
            }
            captionWork.append(w)
            DispatchQueue.main.asyncAfter(deadline: .now() + at, execute: w)
            at += duration * Double(line.count) / max(1, total)
        }
    }

    /// A silent, visual acknowledgement on the orb (e.g. "Queued for next"), shown for a moment while Aside works.
    private var noteText: String?
    private func note(_ text: String) {
        noteText = text; refreshHUD()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self, self.noteText == text else { return }
            self.noteText = nil; self.refreshHUD()
        }
    }

    private func stopSpeaking() {
        laneTurn?.cancel()
        captionWork.forEach { $0.cancel() }; captionWork.removeAll()
        speechQueue.removeAll()
        speaker.stop()
    }

    // MARK: orb

    /// One place decides what the orb shows during a conversation: your words > Aside talking > Aside working > listening.
    private func refreshHUD() {
        guard live || Settings.shared.paused else { return }
        let yours = state == .listening ? liveCommand() : ""
        let m = hud.model
        if !yours.isEmpty {
            if m.phase != .listening { m.phase = .listening }
            m.transcript = yours
        } else if speakingKind != nil {
            if m.phase != .speaking { m.phase = .speaking }
            m.transcript = caption
        } else if agentBusy || fastBusy {
            if m.phase != .thinking { m.phase = .thinking }
            m.transcript = noteText ?? lastStep ?? "Thinking"
        } else {
            if m.phase != .listening { m.phase = .listening }
            m.transcript = ""
        }
        m.status = ""
        hud.present(anchor: nil)
    }

    static func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }

    /// Kept for tests: short replies that close a conversation.
    nonisolated static func isDismissal(_ s: String) -> Bool { Router.intent(s, agentBusy: false) == .endConversation }

    /// Runs delivery directly with given text (no speech). Used by --simulate for live popup tests.
    func testDeliver(_ text: String) async {
        runID += 1
        let rid = runID
        state = .confirming
        marks = ["endpoint": CACurrentMediaTime()]
        escPressed = false; returnPressed = false; cancelSpoken = false
        endpointSession = Int.max
        countdownDeadline = CACurrentMediaTime() + Settings.shared.cancelWindow
        hud.model.phase = .confirming
        hud.model.status = "Test · filling the popup"
        hud.model.transcript = text
        hud.present(anchor: nil)
        hud.startCountdown(Settings.shared.cancelWindow)
        if Settings.shared.delivery != .background { popupTask = Task { @MainActor in await self.popup.open() } }
        await deliver(text, rid: rid)
    }

    // MARK: Jarvis Live (Oct 7)

    /// Hands the conversation to a live call: your first sentence goes in as text (or Jarvis greets you), and from
    /// then on the call hears you directly, answers in his own voice, and hands real work to Aside.
    private func enterLive(text: String?, greet: String?) {
        resetRun()
        inLiveCall = true
        state = .speaking                         // keeps the watchdog, proactive updates and wake detection out
        liveInitial = text; liveFallback = nil
        liveHeard = ""; liveHeardDone = true; liveSaid = ""; liveSaidDone = true; liveStep = nil; liveTasks = 0
        // Shut our own audio first: the call's helper opens mic and speaker only after this (see jarvis-live.mjs
        // DEFER_DEVICES), so macOS never reconfigures the device while Jarvis is talking.
        recognizer.stop()                         // the call's helper owns the mic (with echo cancellation)
        SystemAudio.shared.stop()
        speaker.coolDown()
        liveActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Jarvis Live call")
        let m = hud.model
        m.hint = ""; m.status = ""
        m.phase = text == nil ? .listening : .thinking
        m.transcript = text ?? ""
        hud.present(anchor: nil)
        Log.write("LIVE CALL begin" + (text == nil ? " (greeting)" : " with your first sentence"))
        liveCall.begin(text: text, greet: greet)
    }

    private func handleLive(_ e: LiveCall.Event) {
        guard inLiveCall else {
            if case .error(let msg) = e { Log.write("LIVE warm-up error: \(msg)") }
            return
        }
        let m = hud.model
        switch e {
        case .ready, .live:
            return
        case .heard(let t, let final):
            // Only your words go in the ticker. Echo cancellation is on, so this is never Jarvis hearing himself.
            if liveHeardDone { liveHeard = ""; liveHeardDone = false }
            liveHeard = final ? t : liveHeard + t
            if final { liveHeardDone = true }
            let words = liveHeard.trimmingCharacters(in: .whitespaces)
            if m.phase != .listening { m.phase = .listening }
            m.transcript = words
        case .said(let t, let final):
            // Jarvis's own words stay off the island unless "Show Jarvis's Words" is on (same rule as the classic voice).
            if liveSaidDone { liveSaid = ""; liveSaidDone = false }
            liveSaid = final ? t : liveSaid + t
            if final { liveSaidDone = true }
            if final { liveSettle() } else {
                if m.phase != .speaking { m.phase = .speaking }
                m.transcript = Settings.shared.islandCaptions ? liveSaid.trimmingCharacters(in: .whitespaces) : ""
            }
        case .working(let on):
            if !on { liveStep = nil }
            if m.phase != .speaking && liveHeardDone { liveSettle(thinking: on) }
            if !on { return }
        case .step(let s):
            liveStep = s
            if m.phase != .speaking && liveHeardDone { m.phase = .thinking; m.transcript = s }
        case .tasks(let n):
            liveTasks = n
            if n == 0 { liveStep = nil }
            if m.phase != .speaking && liveHeardDone { liveSettle() }
        case .error(let msg):
            Log.write("LIVE error: \(msg)")
            if !liveCall.everSpoke { liveFallback = liveInitial ?? "" }
            return
        case .end(let reason):
            exitLive(reason)
            return
        }
        hud.present(anchor: nil)
    }

    /// The resting look between turns: working (with the current step) while Aside has something running, else listening.
    private func liveSettle(thinking: Bool = false) {
        let m = hud.model
        if thinking || liveTasks > 0 {
            if m.phase != .thinking { m.phase = .thinking }
            m.transcript = liveStep ?? (liveTasks > 0 ? "Working in Aside" : "Thinking")
        } else {
            if m.phase != .listening { m.phase = .listening }
            m.transcript = ""
        }
        hud.present(anchor: nil)
    }

    /// A background Aside task from a finished call came back. In a call: Jarvis says it there. Otherwise the classic
    /// voice announces it the way proactive updates are delivered (waits if you're mid-conversation).
    private func liveTaskResult(_ text: String, attempt: Int = 0) {
        if inLiveCall { liveCall.speak(text); return }
        guard !Settings.shared.paused else { Log.write("LIVE task result dropped (muted): \(text.prefix(120))"); return }
        if live || state != .idle {
            guard attempt < 60 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.liveTaskResult(text, attempt: attempt + 1) }
            return
        }
        Log.write("ANNOUNCE (Aside task): \(text.prefix(160))")
        play("Pop")
        lastAnnouncement = (text, CACurrentMediaTime())
        unpromptedOpen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.reopenForAnswer()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.hud.island.hop() }
            self.say(text, .answer)
        }
    }

    private func exitLive(_ reason: String) {
        guard inLiveCall else { return }
        inLiveCall = false
        if let a = liveActivity { ProcessInfo.processInfo.endActivity(a); liveActivity = nil }
        Log.write("LIVE CALL end (\(reason))")
        let fallback = liveFallback
        liveFallback = nil; liveInitial = nil
        state = .idle
        if fallback == nil || fallback == "" { hud.dismiss(after: 0.3) }
        Task { @MainActor in
            await self.start()                    // wake word back on
            guard let fallback, !Settings.shared.paused else { return }
            if fallback.isEmpty {
                await self.speaker.speak("Live voice is unavailable right now, sir. Ask me again and I'll use the usual route.")
                return
            }
            // The call failed before saying anything (e.g. Codex usage limit): the classic Ryan pipeline takes the turn.
            Log.write("LIVE fallback: classic pipeline takes the turn")
            self.hud.model.phase = .thinking; self.hud.model.transcript = fallback; self.hud.present(anchor: nil)
            await self.converse(fallback)
        }
    }

    /// Verification hook (`--live-test "question"`): runs one silent live call (mic muted, speaker suppressed) with the
    /// app's own microphone permission, logs every event, and quits.
    func liveTest(_ text: String) {
        liveCall.silentTest = true
        liveCall.onEvent = { e in
            switch e {
            case .ready: Log.write("LIVETEST ready")
            case .live: Log.write("LIVETEST live")
            case .heard(let t, let f): if f { Log.write("LIVETEST heard: \(t)") }
            case .said(let t, let f): if f { Log.write("LIVETEST said: \(t)") }
            case .working(let on): Log.write("LIVETEST working=\(on)")
            case .step(let s): Log.write("LIVETEST step: \(s)")
            case .tasks(let n): Log.write("LIVETEST tasks=\(n)")
            case .error(let m): Log.write("LIVETEST error: \(m)")
            case .end(let r): Log.write("LIVETEST end: \(r); peak Jarvis audio level \(String(format: "%.3f", self.liveCall.remotePeak))"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            }
        }
        liveCall.prepare()
        liveCall.begin(text: text, greet: nil)
    }

    /// Single exit point for every run.
    private func finish(_ phase: HUDModel.Phase, _ title: String, sound: String?, quiet: Bool = false) {
        if inLiveCall { liveCall.stop(); return }
        if liveCall.running && !liveCall.begun { liveCall.stop() }   // woke, then cancelled: drop the warm call
        if live { endConversation(say: nil, byEsc: true); return }
        let wasActive = state == .listening || state == .confirming
        resetRun()
        speaker.coolDown()   // woke but no conversation started: stop keeping the voice sockets warm
        guard wasActive else { return }
        if quiet { hud.dismiss(after: 0); return }
        hud.model.phase = phase
        hud.model.status = title
        if let sound { play(sound) }
        hud.dismiss(after: phase == .error ? 2.4 : 1.2)
        Log.write("END \(phase): \(title)")
    }

    /// Resets per-turn state without touching the HUD.
    private func resetRun() {
        runID += 1
        speculation?.cancel(); speculation = nil
        timer?.invalidate(); timer = nil
        recognizer.setHoldOpen(false)
        ignoreUpToSession = recognizer.currentSessionID
        recognizer.resetSession()
        segs.removeAll()
        popupTask = nil
        if Settings.shared.paused { state = .paused } else if state != .failed { state = .idle }
    }

    // MARK: utils

    /// Runs `work` but returns after `timeout` even if it hasn't finished.
    static func race(timeout: TimeInterval, _ work: @escaping @Sendable () async -> Void) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let once = OnceFlag()
            Task.detached { await work(); if once.fire() { c.resume() } }
            Task.detached { try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); if once.fire() { c.resume() } }
        }
    }

    /// Stock macOS sounds (preferred over a synthesized set).
    private func play(_ name: String) {
        guard !dryRun, !Speaker.silent else { return }
        Sounds.system(name)
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
