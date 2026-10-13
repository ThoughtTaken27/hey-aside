import AVFoundation
import CryptoKit
import Foundation

// Aside's spoken voice.
//
// Primary: Microsoft Edge "Read Aloud" neural voices (free, no key, no account). Synthesis happens on Microsoft's
// servers, so the Mac only plays an MP3: near-zero CPU/RAM. Protocol follows rany2/edge-tts (LGPL-3.0; protocol
// constants only, no code copied). It is unofficial and could change: any failure falls back to the Mac's own voice.
// Fallback: AVSpeechSynthesizer with the best installed English voice (offline, zero install).

enum AsideVoice: String, CaseIterable {
    case prabhat = "en-IN-PrabhatNeural"
    case neerja = "en-IN-NeerjaNeural"
    case ava = "en-US-AvaMultilingualNeural"
    case andrew = "en-US-AndrewMultilingualNeural"
    case emma = "en-US-EmmaMultilingualNeural"
    case brian = "en-US-BrianMultilingualNeural"
    case ryan = "en-GB-RyanNeural"
    case thomas = "en-GB-ThomasNeural"
    var title: String {
        switch self {
        case .ava: return "Ava (warm, female)"; case .andrew: return "Andrew (calm, male)"; case .emma: return "Emma (bright, female)"; case .brian: return "Brian (casual, male)"
        case .ryan: return "Ryan (British, Jarvis-style)"; case .thomas: return "Thomas (British, crisp)"
        case .prabhat: return "Prabhat (Indian English, test only)"; case .neerja: return "Neerja (Indian English, test only)"
        }
    }
}

enum EdgeTTSError: Error { case http(Int), noAudio, timeout, closed(String) }

final class EdgeTTS: NSObject, URLSessionWebSocketDelegate {
    private static let token = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"  // public Edge client id (also in rany2/edge-tts), not a secret  gitleaks:allow
    private static let chromium = "143.0.3650.75"
    private static var clockSkew: TimeInterval = 0
    nonisolated(unsafe) static var traceTiming = false
    private lazy var session = URLSession(configuration: .ephemeral)

    private static func secMsGec() -> String {
        var ticks = Date().timeIntervalSince1970 + clockSkew + 11_644_473_600
        ticks -= ticks.truncatingRemainder(dividingBy: 300)
        let s = String(format: "%.0f", ticks * 10_000_000) + token
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    private static func jsDate() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return f.string(from: Date())
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "'", with: "&apos;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Returns MP3 (24 kHz mono 48 kbps) for `text`. One short-lived websocket per call.
    func synthesize(_ text: String, voice: AsideVoice, rate: Int = 6, timeout: TimeInterval = 8) async throws -> Data {
        do { return try await attempt(text, voice: voice, rate: rate, timeout: timeout) }
        catch EdgeTTSError.http(let code) where code == 403 {
            // Token is time-based: fix clock skew from the server's Date header, then retry once.
            if let skew = await Self.serverSkew() { Self.clockSkew = skew }
            return try await attempt(text, voice: voice, rate: rate, timeout: timeout)
        }
    }

    private static func serverSkew() async -> TimeInterval? {
        // The host that checks the token (api.msedgeservices.com) is the one whose clock matters.
        var r = URLRequest(url: URL(string: "https://api.msedgeservices.com/")!); r.httpMethod = "HEAD"
        guard let (_, resp) = try? await URLSession.shared.data(for: r), let h = resp as? HTTPURLResponse,
              let d = h.value(forHTTPHeaderField: "Date") else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: d).map { $0.timeIntervalSinceNow }
    }

    // MARK: persistent connection (reused across sentences; opening a socket is ~90% of the latency)

    private var ws: URLSessionWebSocketTask?
    private var wsOpenedAt: TimeInterval = 0
    private var wsLastUsed: TimeInterval = 0
    private let gate = AsyncGate()

    private func makeSocket() -> URLSessionWebSocketTask {
        let cid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // Since October 2026 the old speech.platform.bing.com host answers 403; Edge now
        // synthesizes through api.msedgeservices.com with the same client id (edge-tts#491).
        var comps = URLComponents(string: "wss://api.msedgeservices.com/tts/cognitiveservices/websocket/v1")!
        comps.queryItems = [
            .init(name: "Ocp-Apim-Subscription-Key", value: Self.token), .init(name: "ConnectionId", value: cid),
            .init(name: "Sec-MS-GEC", value: Self.secMsGec()), .init(name: "Sec-MS-GEC-Version", value: "1-\(Self.chromium)"),
        ]
        var req = URLRequest(url: comps.url!)
        let major = Self.chromium.split(separator: ".").first ?? "143"
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36 Edg/\(major).0.0.0", forHTTPHeaderField: "User-Agent")
        req.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        req.setValue("no-cache", forHTTPHeaderField: "Pragma")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("muid=\((0..<16).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined());", forHTTPHeaderField: "Cookie")
        req.timeoutInterval = 10
        let t = session.webSocketTask(with: req)
        t.resume()
        return t
    }

    /// Opens (or keeps) the shared socket so the next sentence doesn't pay for a TLS handshake.
    func connect() async {
        await gate.run { _ = try? await self.socket() }
    }

    /// Sep 30: keeps the socket alive without ever making a real sentence wait: skipped when the socket is busy or was
    /// used in the last 12 s (the server drops sockets idle for ~25 s).
    func keepAlive(voice: AsideVoice) async -> Int? {
        await gate.tryRun { () async -> Int? in
            guard CACurrentMediaTime() - self.wsLastUsed >= 12 else { return nil }
            let t0 = CACurrentMediaTime()
            _ = try? await self.request("Okay.", voice: voice, rate: 0, timeout: 6, fresh: false)
            return Int((CACurrentMediaTime() - t0) * 1000)
        } ?? nil
    }

    func disconnect() {
        ws?.cancel(with: .normalClosure, reason: nil); ws = nil
    }

    private func socket() async throws -> URLSessionWebSocketTask {
        let now = CACurrentMediaTime()
        // Recycle before the 5-minute token window or after long idle (server drops idle sockets).
        if let w = ws, w.state == .running, now - wsOpenedAt < 240, now - wsLastUsed < 25 { return w }
        ws?.cancel(with: .normalClosure, reason: nil)
        let w = makeSocket()
        let config = "X-Timestamp:\(Self.jsDate())\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n"
            + "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}\r\n"
        do { try await w.send(.string(config)) }
        catch {
            if let code = (w.response as? HTTPURLResponse)?.statusCode, code != 101 { throw EdgeTTSError.http(code) }
            throw error
        }
        ws = w; wsOpenedAt = now; wsLastUsed = now
        return w
    }

    private func attempt(_ text: String, voice: AsideVoice, rate: Int, timeout: TimeInterval) async throws -> Data {
        try await gate.run {
            do { return try await self.request(text, voice: voice, rate: rate, timeout: timeout, fresh: false) }
            catch EdgeTTSError.http(let c) { throw EdgeTTSError.http(c) }
            catch {
                // Reused socket went stale: retry once on a fresh one.
                self.disconnect()
                return try await self.request(text, voice: voice, rate: rate, timeout: timeout, fresh: true)
            }
        }
    }

    private func request(_ text: String, voice: AsideVoice, rate: Int, timeout: TimeInterval, fresh: Bool) async throws -> Data {
        let w = try await socket()
        let rid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='\(voice.rawValue)'>"
            + "<prosody pitch='+0Hz' rate='\(rate >= 0 ? "+" : "")\(rate)%' volume='+0%'>\(Self.escape(text))</prosody></voice></speak>"
        let msg = "X-RequestId:\(rid)\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(Self.jsDate())Z\r\nPath:ssml\r\n\r\n" + ssml
        let sentAt = CACurrentMediaTime()
        try await w.send(.string(msg))
        var audio = Data()
        var firstAudioAt: TimeInterval = 0
        while CACurrentMediaTime() - sentAt < timeout {
            let m: URLSessionWebSocketTask.Message
            do { m = try await w.receive() }
            catch {
                if let code = (w.response as? HTTPURLResponse)?.statusCode, code != 101 { throw EdgeTTSError.http(code) }
                throw EdgeTTSError.closed(error.localizedDescription)
            }
            switch m {
            case .string(let s):
                if s.contains("Path:turn.end") && s.contains(rid) {
                    if audio.isEmpty { throw EdgeTTSError.noAudio }
                    wsLastUsed = CACurrentMediaTime()
                    if EdgeTTS.traceTiming { Log.write("  tts \(fresh ? "fresh" : "reused") socket: first audio \(Int((firstAudioAt - sentAt) * 1000)) ms, complete \(Int((CACurrentMediaTime() - sentAt) * 1000)) ms") }
                    return audio
                }
            case .data(let d):
                guard d.count >= 2 else { continue }
                let hl = Int(d[d.startIndex]) << 8 | Int(d[d.startIndex + 1])
                guard d.count >= 2 + hl else { continue }
                let header = String(decoding: d[(d.startIndex + 2)..<(d.startIndex + 2 + hl)], as: UTF8.self)
                if header.contains("Path:audio") && header.contains(rid) {
                    if firstAudioAt == 0 && d.count > 2 + hl { firstAudioAt = CACurrentMediaTime() }
                    audio.append(d[(d.startIndex + 2 + hl)...])
                }
            @unknown default: break
            }
        }
        throw EdgeTTSError.timeout
    }
}

/// Serializes async work (one Edge request in flight per socket).
actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Runs `work` only if nothing else holds the gate or waits for it; nil otherwise.
    func tryRun<T>(_ work: @Sendable () async -> T) async -> T? {
        guard !busy else { return nil }
        return await run { await work() }
    }
    func run<T>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
        return try await work()
    }
}

/// Speaks text sentence by sentence: sentence N+1 is synthesized while N plays, so speech starts fast and never gaps.
/// Publishes a smoothed output level so the orb can move with Aside's voice.
@MainActor
final class Speaker: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    /// Sep 30: two Edge connections. A socket serves one request at a time, and the warm-up, the prefetch of ~40 stock
    /// lines and the first-sentence hedge all queued on the same socket as the reply, so the first word waited 0.6-2.8 s
    /// for synthesis that takes ~0.15 s. Replies use `edge`; prefetch, keep-alive and the hedge use `spare`, and a
    /// multi-part reply alternates between them so part 2 is made while part 1 is.
    private let edge = EdgeTTS()
    private let spare = EdgeTTS()
    private let apple = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var runID = 0
    private var playDone: CheckedContinuation<Void, Never>?
    private var meterTimer: Timer?
    private(set) var isSpeaking = false
    var onLevel: ((Float) -> Void)?
    var onSentence: ((String) -> Void)?
    /// Text about to be heard and how long it will take to say (drives line-by-line captions).
    var onCaption: ((String, TimeInterval) -> Void)?
    private var edgeFailures = 0

    override init() { super.init(); apple.delegate = self }

    /// Speaks all of `text`; returns when finished or stopped.
    /// Tests: log instead of playing (never make noise while someone works).
    nonisolated(unsafe) static var silent = false

    func speak(_ text: String) async {
        if Speaker.silent {
            Log.write("SPEAK (silent test): \(text)")
            onCaption?(text, Double(text.count) / 15)
            try? await Task.sleep(nanoseconds: UInt64(Double(text.count) / 15 * 1e9))
            return
        }
        stop()
        runID += 1
        let rid = runID
        let parts = Speaker.chunks(text)
        guard !parts.isEmpty else { return }
        isSpeaking = true
        defer { if rid == runID { isSpeaking = false; onLevel?(0) } }
        let voice = Settings.shared.voice
        // All chunks are requested at once (warm: ~0.5 s for a whole reply); playback starts as soon as chunk 1 lands.
        let tasks = parts.enumerated().map { synthTask($0.element, voice, hedge: $0.offset == 0, on: $0.offset % 2 == 0 ? edge : spare) }
        for (i, part) in parts.enumerated() {
            guard rid == runID else { tasks.forEach { $0.cancel() }; return }
            let data = await tasks[i].value
            guard rid == runID else { tasks.forEach { $0.cancel() }; return }
            onSentence?(part)
            if let data {
                let dur = (try? AVAudioPlayer(data: data))?.duration ?? Double(part.count) / 15
                onCaption?(part, dur)
                if await play(data, rid: rid) { continue }
            } else {
                onCaption?(part, Double(part.count) / 14)
            }
            await speakApple(part, rid: rid)   // fallback for this chunk
        }
    }

    /// Benchmark only: ms until the first part of `text` has audio, exactly as `speak` would request it (no playback).
    func firstPartReadyMs(_ text: String) async -> Int {
        let t0 = CACurrentMediaTime()
        guard let first = Speaker.chunks(text).first else { return -1 }
        _ = await synthTask(first, Settings.shared.voice, hedge: true, on: edge).value
        return Int((CACurrentMediaTime() - t0) * 1000)
    }

    /// Keeps the voice connection warm while Aside is thinking (cold requests take 2-5 s, warm ones ~0.4 s).
    /// Tiny request (~4 KB) every ~18 s while a conversation is open (at most ~18 minutes); ending the conversation or
    /// muting stops it.
    private var warmTask: Task<Void, Never>?
    func warmUp() {
        warmTask?.cancel()
        let edge = self.edge, spare = self.spare
        warmTask = Task.detached {
            // Open both sockets now (no sentence); a reply that arrives meanwhile just reuses the handshake.
            async let a: Void = edge.connect()
            async let b: Void = spare.connect()
            _ = await (a, b)
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if Task.isCancelled { return }
                for (name, e) in [("main", edge), ("spare", spare)] {
                    if let ms = await e.keepAlive(voice: Settings.shared.voice) { Log.write("voice keep-alive (\(name)) \(ms) ms") }
                }
            }
        }
    }
    func coolDown() { warmTask?.cancel(); warmTask = nil }

    /// `hedge`: for the first sentence, if Edge hasn't answered in 0.9 s, fire a second identical request and use
    /// whichever returns first. Cuts rare slow responses (2-5 s) without extra cost in the normal case (~0.45 s).
    // Pre-synthesized short phrases (acks), keyed by voice+rate+text, so they play instantly.
    private var cache: [String: Data] = [:]
    private func key(_ s: String) -> String { "\(Settings.shared.voice.rawValue)|\(Settings.shared.voiceRate)|\(s)" }

    /// Voices stock lines ahead of time, one cache entry per spoken part (Sep 30: whole lines were cached but replies
    /// are played part by part, so a two-sentence line never hit the cache). Kept on disk too, so a restart is warm.
    func prefetch(_ texts: [String]) {
        let spare = self.spare
        let v = Settings.shared.voice, rate = Settings.shared.voiceRate
        var todo: [String] = []
        for part in Set(texts.flatMap { Speaker.chunks($0) }) where cache[key(part)] == nil {
            if let d = Speaker.diskCached(key(part)) { cache[key(part)] = d } else { todo.append(part) }
        }
        guard !todo.isEmpty else { return }
        Task.detached {
            for t in todo {
                if let d = try? await spare.synthesize(t, voice: v, rate: rate) {
                    let k = "\(v.rawValue)|\(rate)|\(t)"
                    Speaker.saveToDisk(k, d)
                    await MainActor.run { self.cache[k] = d }
                }
            }
        }
    }

    private nonisolated static let diskDir: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("app.heyaside.mac/tts", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    private nonisolated static func diskURL(_ key: String) -> URL {
        diskDir.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined() + ".mp3")
    }
    nonisolated static func diskCached(_ key: String) -> Data? { try? Data(contentsOf: diskURL(key)) }
    nonisolated static func saveToDisk(_ key: String, _ d: Data) { try? d.write(to: diskURL(key), options: .atomic) }

    private func synthTask(_ s: String, _ v: AsideVoice, hedge: Bool = false, on conn: EdgeTTS? = nil) -> Task<Data?, Never> {
        if let d = cache[key(s)] { return Task { d } }
        if s.count <= 80, let d = Speaker.diskCached(key(s)) { cache[key(s)] = d; return Task { d } }
        let edge = conn ?? self.edge
        let other = edge === self.edge ? self.spare : self.edge
        let rate = Settings.shared.voiceRate
        let skip = edgeFailures >= 3   // after repeated failures, stop waiting on the network this session
        return Task.detached {
            if skip { return nil }
            let t0 = CACurrentMediaTime()
            let one: @Sendable (Double) async -> Data? = { delay in
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)); if Task.isCancelled { return nil } }
                do { return try await (delay > 0 ? other : edge).synthesize(s, voice: v, rate: rate) }
                catch { if !Task.isCancelled { Log.write("edge tts failed: \(error)") }; return nil }
            }
            let data: Data? = await withTaskGroup(of: Data?.self) { g in
                g.addTask { await one(0) }
                if hedge { g.addTask { await one(0.6) } }   // on the other socket, so it never queues behind the first
                for await r in g { if let r { g.cancelAll(); return r } }
                return nil
            }
            if let data { Log.write("edge tts \(Int((CACurrentMediaTime() - t0) * 1000)) ms, \(data.count / 1024) KB: \(s.prefix(30))") }
            else { await MainActor.run { self.edgeFailures += 1 } }
            return data
        }
    }

    /// Drops Ryan to ~20% the instant you start talking over him (smooth 120 ms ramp); back up if it was just "mm-hmm".
    private(set) var ducked = false
    private var duckTimer: Timer?
    func duck(_ on: Bool) {
        guard on != ducked else { return }
        ducked = on
        player?.setVolume(on ? 0.2 : 1, fadeDuration: 0.12)
        duckTimer?.invalidate()
        let from: Float = on ? 1 : 0.2, to: Float = on ? 0.2 : 1
        var i = 0
        duckTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] t in
            i += 1
            let x = Float(min(i, 6)) / 6
            self?.io?.setPlaybackVolume(from + (to - from) * x)
            if i >= 6 { t.invalidate() }
        }
    }

    func stop() {
        runID += 1
        duckTimer?.invalidate(); duckTimer = nil
        if ducked { ducked = false; io?.setPlaybackVolume(1) }
        io?.stopPlayback()
        player?.stop(); player = nil
        if apple.isSpeaking { apple.stopSpeaking(at: .immediate) }
        meterTimer?.invalidate(); meterTimer = nil
        playDone?.resume(); playDone = nil
        isSpeaking = false
        onLevel?(0)
    }

    /// When set (conversation engine running), audio goes through the mic's voice-processing engine for echo cancellation.
    weak var io: Recognizer?

    private func play(_ data: Data, rid: Int) async -> Bool {
        if let io, io.canPlay, let buf = Speaker.decode(data) {
            // Levels are precomputed per 1/30 s so the orb follows the voice without tapping the audio graph.
            let levels = Speaker.levels(buf)
            let start = CACurrentMediaTime()
            startMeter {
                let i = Int((CACurrentMediaTime() - start) * 30)
                return i < levels.count ? levels[i] : -60
            }
            await io.play(buf)
            meterTimer?.invalidate(); meterTimer = nil
            return rid == runID
        }
        return await playStandalone(data, rid: rid)
    }

    static func decode(_ mp3: Data) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heyaside-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? mp3.write(to: url)) != nil, let f = try? AVAudioFile(forReading: url),
              let src = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: src)) != nil else { return nil }
        if src.format == Recognizer.playbackFormat { return src }
        guard let conv = AVAudioConverter(from: src.format, to: Recognizer.playbackFormat),
              let out = AVAudioPCMBuffer(pcmFormat: Recognizer.playbackFormat, frameCapacity: AVAudioFrameCount(Double(src.frameLength) * 24_000 / src.format.sampleRate) + 1024) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .endOfStream; return nil }
            fed = true; st.pointee = .haveData; return src
        }
        return err == nil ? out : nil
    }

    static func levels(_ b: AVAudioPCMBuffer) -> [Float] {
        guard let ch = b.floatChannelData?[0] else { return [] }
        let win = Int(b.format.sampleRate / 30)
        var out: [Float] = []
        var i = 0
        while i < Int(b.frameLength) {
            let n = min(win, Int(b.frameLength) - i)
            var sum: Float = 0
            for k in 0..<n { sum += ch[i + k] * ch[i + k] }
            out.append(10 * log10(max(1e-9, sum / Float(n))))
            i += win
        }
        return out
    }

    private func playStandalone(_ data: Data, rid: Int) async -> Bool {
        guard let p = try? AVAudioPlayer(data: data) else { return false }
        p.delegate = self
        p.isMeteringEnabled = true
        player = p
        guard p.play() else { return false }
        startMeter { [weak p] in
            guard let p else { return 0 }
            p.updateMeters()
            return p.averagePower(forChannel: 0)
        }
        await withCheckedContinuation { c in playDone = c }
        meterTimer?.invalidate(); meterTimer = nil
        return true
    }

    private func speakApple(_ s: String, rid: Int) async {
        guard rid == runID else { return }
        let u = AVSpeechUtterance(string: s)
        u.voice = Speaker.bestAppleVoice
        u.rate = 0.52
        apple.speak(u)
        // Apple's synthesizer has no meter; give the orb a gentle synthetic pulse.
        var t: Float = 0
        startMeter { t += 0.05; return -28 + 10 * sin(t * 9) * sin(t * 2.7) }
        await withCheckedContinuation { c in playDone = c }
        meterTimer?.invalidate(); meterTimer = nil
    }

    private func startMeter(_ read: @escaping () -> Float) {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let db = read()
                self?.onLevel?(max(0, min(1, (db + 45) / 40)))   // -45 dB → 0, -5 dB → 1
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated { playDone?.resume(); playDone = nil }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        MainActor.assumeIsolated { playDone?.resume(); playDone = nil }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        MainActor.assumeIsolated { playDone?.resume(); playDone = nil }
    }

    static let bestAppleVoice: AVSpeechSynthesisVoice? = {
        let en = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        return en.max { ($0.quality.rawValue, $0.language == "en-US" ? 1 : 0) < ($1.quality.rawValue, $1.language == "en-US" ? 1 : 0) }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    /// First chunk is one short sentence (fast first audio); later chunks group sentences up to ~220 chars.
    /// Sep 30: a long first sentence (13+ words) is cut at its first comma when both halves have 4+ words, so the first
    /// sound is a short clause ("Leonardo da Vinci painted it, | sometime between 1503 and 1519.").
    nonisolated static func chunks(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { sentences.append(s) }
        }
        if sentences.isEmpty { let t = text.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? [] : [t] }
        let first = sentences.removeFirst()
        var out: [String] = []
        if let (head, tail) = firstClause(first) { out = [head]; sentences.insert(tail, at: 0) } else { out = [first] }
        var cur = ""
        for s in sentences {
            if cur.isEmpty { cur = s } else if cur.count + s.count < 220 { cur += " " + s } else { out.append(cur); cur = s }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    nonisolated static func firstClause(_ s: String) -> (String, String)? {
        let words = s.split(separator: " ")
        guard words.count >= 13 else { return nil }
        var seen = 0
        for (i, w) in words.enumerated() {
            seen += 1
            if w.hasSuffix(","), seen >= 4, words.count - (i + 1) >= 4 {
                return (words[...i].joined(separator: " "), words[(i + 1)...].joined(separator: " "))
            }
        }
        return nil
    }
}
