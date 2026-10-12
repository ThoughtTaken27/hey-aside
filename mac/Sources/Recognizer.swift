import AVFoundation
import CoreAudio
import Foundation
import Speech

struct SegmentUpdate {
    /// fast = DictationTranscriber (streams word by word, used for wake + live captions)
    /// accurate = SpeechTranscriber (batched, better words + punctuation, used for the sent text)
    enum Source { case fast, accurate }
    let source: Source
    let session: Int
    let start: Double
    let end: Double
    let text: String
    let isFinal: Bool
}

protocol RecognizerDelegate: AnyObject {
    func recognizer(didUpdate seg: SegmentUpdate)
    func recognizer(level: Float, lastVoicedAt: TimeInterval)
    func recognizer(failed message: String)
}

/// One SpeechAnalyzer run. A new one starts for each burst of speech, so the recognizer
/// costs nothing during silence and never accumulates hours of state.
final class AnalyzerSession: @unchecked Sendable {
    var id: Int
    private let analyzer: SpeechAnalyzer
    private let cont: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?
    private var fastTask: Task<Void, Never>?
    private(set) var finishing = false

    private init(id: Int, analyzer: SpeechAnalyzer, cont: AsyncStream<AnalyzerInput>.Continuation) {
        self.id = id; self.analyzer = analyzer; self.cont = cont
    }

    static func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: Locale(identifier: "en-US"),
                          transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [])
    }

    static func makeFast() -> DictationTranscriber {
        DictationTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveShortDictation)
    }

    static func make(id: Int, format: AVAudioFormat?, vocabulary: [String],
                     onResult: @escaping @Sendable (SegmentUpdate) -> Void) async throws -> AnalyzerSession {
        let accurate = makeTranscriber()
        let fast = makeFast()
        let analyzer = SpeechAnalyzer(modules: [fast, accurate], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let ctx = AnalysisContext()
        ctx.contextualStrings[.general] = vocabulary
        try await analyzer.setContext(ctx)
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let s = AnalyzerSession(id: id, analyzer: analyzer, cont: cont)
        s.resultsTask = Task.detached { [weak s] in
            do {
                for try await r in accurate.results {
                    guard let sid = s?.id else { break }
                    onResult(SegmentUpdate(source: .accurate, session: sid, start: r.range.start.seconds, end: r.range.end.seconds,
                                           text: String(r.text.characters), isFinal: r.isFinal))
                }
            } catch { Log.write("session \(id) accurate results error: \(error)") }
        }
        s.fastTask = Task.detached { [weak s] in
            do {
                for try await r in fast.results {
                    guard let sid = s?.id else { break }
                    onResult(SegmentUpdate(source: .fast, session: sid, start: r.range.start.seconds, end: r.range.end.seconds,
                                           text: String(r.text.characters), isFinal: r.isFinal))
                }
            } catch { Log.write("session \(id) fast results error: \(error)") }
        }
        try await analyzer.start(inputSequence: stream)
        return s
    }

    func feed(_ inputs: [AnalyzerInput]) { for i in inputs { cont.yield(i) } }

    /// Forces pending volatile text to become final without ending the session.
    func finalizeNow() async { try? await analyzer.finalize(through: nil) }

    func finish() {
        guard !finishing else { return }
        finishing = true
        cont.finish()
        let a = analyzer
        Task.detached { try? await a.finalizeAndFinishThroughEndOfInput() }
    }

    func cancel() {
        finishing = true
        cont.finish()
        let a = analyzer
        Task.detached { await a.cancelAndFinishNow() }
    }
}

/// Microphone capture + energy voice gate + per-burst SpeechAnalyzer sessions.
final class Recognizer: @unchecked Sendable {
    weak var delegate: RecognizerDelegate?

    private var engine = AVAudioEngine()
    private let proc = DispatchQueue(label: "heyaside.audio", qos: .userInitiated)
    private var converter: AnalyzerInputConverter?
    private var analyzerFormat: AVAudioFormat?
    private var vocabulary: [String] = []

    // proc-queue state
    private var noiseFloor: Float = 0.002
    private var lastVoice: TimeInterval = 0
    private var voicedRun = 0
    private var preroll: [AVAudioPCMBuffer] = []
    private var prerollFrames: AVAudioFrameCount = 0
    private var gateOpen = false
    private var session: AnalyzerSession?
    private var creating = false
    private var pending: [AnalyzerInput] = []
    private var finishWhenReady = false
    private var sessionCounter = 0
    private var spare: AnalyzerSession?
    private var preparingSpare = false
    private var lastLevelReport: TimeInterval = 0
    private var voicedSinceReport = false
    private var holdOpenFlag = false
    private(set) var running = false

    /// While the controller is capturing a command, keep feeding audio even through pauses.
    func setHoldOpen(_ v: Bool) { proc.async { self.holdOpenFlag = v } }

    /// Ends the current burst session and ignores its remaining output (used after delivery or cancel).
    func resetSession() {
        proc.async {
            self.session?.cancel(); self.session = nil
            self.pending.removeAll(); self.finishWhenReady = self.creating
            self.gateOpen = false
        }
    }

    /// Forces the current session to finalize its volatile text.
    func finalizeCurrent() async {
        let s: AnalyzerSession? = proc.sync { self.session }
        await s?.finalizeNow()
    }

    var currentSessionID: Int { proc.sync { sessionCounter } }

    private var startGen = 0

    func start() async throws {
        vocabulary = Settings.shared.vocabulary
        startGen += 1
        let gen = startGen
        let eng = AVAudioEngine()
        engine = eng
        // Echo cancellation (Apple voice processing, same as FaceTime): Aside's voice is played through this engine,
        // so the mic can subtract it and you can talk over it. Other apps' audio is ducked as little as possible.
        var vp = false
        if echoCancelWanted {
            // Order matters (measured): the output side must exist before voice processing is enabled,
            // otherwise the engine fails to start with -10875.
            _ = eng.outputNode; _ = eng.mainMixerNode
            do {
                try eng.inputNode.setVoiceProcessingEnabled(true)
                eng.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: true, duckingLevel: .min)
                vp = true
            } catch { Log.write("voice processing unavailable: \(error)") }
        } else if Settings.shared.builtInMic, let dev = Recognizer.builtInInputDevice(), let au = eng.inputNode.audioUnit {
            // Without voice processing, pick the device before touching the output side (else the tap format mismatches).
            var d = dev
            let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
            Log.write("input device: built-in mic (\(dev)) status=\(st)")
        }
        echoCancelActive = vp
        // Only with voice processing does Aside's voice go through this engine (that's what lets the mic cancel it).
        // Without it, playback uses a standalone player; attaching output here would break the mic-only device setup.
        if vp {
            let player = AVAudioPlayerNode()
            eng.attach(player)
            eng.connect(player, to: eng.mainMixerNode, format: Recognizer.playbackFormat)
            self.player = player
        } else { self.player = nil }
        let fmt = eng.inputNode.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw NSError(domain: "HeyAside", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available"]) }
        let template: [any SpeechModule] = [AnalyzerSession.makeFast(), AnalyzerSession.makeTranscriber()]
        if let req = try await AssetInventory.assetInstallationRequest(supporting: template) {
            Log.write("downloading speech model assets")
            try await req.downloadAndInstall()
        }
        guard let af = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: template, considering: fmt) else {
            throw NSError(domain: "HeyAside", code: 2, userInfo: [NSLocalizedDescriptionKey: "No compatible speech audio format"])
        }
        analyzerFormat = af
        converter = AnalyzerInputConverter(analyzerFormat: af)
        Log.write("mic format \(fmt.sampleRate) Hz x\(fmt.channelCount); analyzer format \(af.sampleRate) Hz; echo cancel \(vp ? "on" : "off")")

        // Warm the model once so the first wake is fast.
        let warm = try await AnalyzerSession.make(id: 0, format: af, vocabulary: vocabulary) { _ in }
        warm.finish()

        // A newer start()/stop() happened while we were awaiting model setup: this attempt is stale.
        guard gen == startGen, engine === eng else { Log.write("stale audio start skipped"); return }
        let input = eng.inputNode
        let liveFmt = input.outputFormat(forBus: 0)
        guard liveFmt.sampleRate > 0, liveFmt.channelCount > 0 else { throw NSError(domain: "HeyAside", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone went away"]) }
        input.installTap(onBus: 0, bufferSize: 1024, format: liveFmt) { [weak self] buf, _ in
            guard let self, let copy = Recognizer.copy(buf) else { return }
            self.proc.async { self.process(copy) }
        }
        eng.prepare()
        try eng.start()
        proc.sync { lastBufferAt = CACurrentMediaTime() }
        running = true
        proc.async { self.prepareSpare() }
        Log.write("recognizer started")
    }

    // MARK: playback through the voice-processing engine (so echo cancellation can "hear" what we play)

    static let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private(set) var echoCancelActive = false
    /// Echo cancellation costs ~16% CPU (measured), so it's only on during live conversations.
    var echoCancelWanted = false
    private var player: AVAudioPlayerNode?
    var canPlay: Bool { running && player != nil }

    /// Plays a buffer and returns when it has actually been heard (or playback was stopped).
    func play(_ buf: AVAudioPCMBuffer) async {
        guard let player, running else { return }
        if !player.isPlaying { player.play() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { _ in c.resume() }
        }
    }

    func stopPlayback() { player?.stop() }
    func setPlaybackVolume(_ v: Float) { player?.volume = v }

    /// Test hook: silently kills audio input without updating state, like a driver hiccup would.
    func simulateDeadAudio() { engine.inputNode.removeTap(onBus: 0); engine.stop() }

    func stop() {
        startGen += 1
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        proc.async {
            self.session?.cancel(); self.session = nil; self.gateOpen = false
            self.spare?.cancel(); self.spare = nil
            self.preroll.removeAll(); self.prerollFrames = 0; self.pending.removeAll()
        }
        Log.write("recognizer stopped")
    }

    /// Feed a file through the same pipeline at real-time pace (offline tests).
    func runFile(_ url: URL) async throws {
        vocabulary = Settings.shared.vocabulary
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let template: [any SpeechModule] = [AnalyzerSession.makeFast(), AnalyzerSession.makeTranscriber()]
        guard let af = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: template, considering: fmt) else { return }
        analyzerFormat = af
        converter = AnalyzerInputConverter(analyzerFormat: af)
        let warm = try await AnalyzerSession.make(id: 0, format: af, vocabulary: vocabulary) { _ in }
        warm.finish()
        running = true
        proc.sync { self.prepareSpare() }
        try await Task.sleep(nanoseconds: 800_000_000)
        Log.write("file feed start")
        let feedStart = CACurrentMediaTime()
        let chunk: AVAudioFrameCount = 1024
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { break }
            try file.read(into: buf, frameCount: chunk)
            proc.async { self.process(buf) }
            // Pace against an absolute clock so scheduling jitter can't make the feed drift behind real time.
            let target = feedStart + Double(file.framePosition) / fmt.sampleRate
            let wait = target - CACurrentMediaTime()
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        Log.write("file feed done: drift \(Int((CACurrentMediaTime() - feedStart - Double(file.length) / fmt.sampleRate) * 1000)) ms")
    }

    // MARK: - audio processing (proc queue)

    private var lastBufferAt: TimeInterval = 0
    /// Seconds since the mic last delivered audio (watchdog input). Read from main; written on `proc`.
    var secondsSinceAudio: TimeInterval { proc.sync { lastBufferAt == 0 ? 0 : CACurrentMediaTime() - lastBufferAt } }

    private func process(_ buf: AVAudioPCMBuffer) {
        let now = CACurrentMediaTime()
        lastBufferAt = now
        let rms = Recognizer.rms(buf)
        if rms < noiseFloor * 1.5 { noiseFloor = noiseFloor * 0.95 + rms * 0.05 } else { noiseFloor = noiseFloor * 0.9995 + rms * 0.0005 }
        noiseFloor = min(max(noiseFloor, 0.0003), 0.05)
        let voiced = rms > max(noiseFloor * 3.2, 0.0035)
        if Log.echo && voiced != (voicedRun > 0) { Log.write(String(format: "  vad %@ rms=%.4f floor=%.4f", voiced ? "ON " : "off", rms, noiseFloor)) }
        voicedRun = voiced ? voicedRun + 1 : 0
        if voiced { lastVoice = now }
        if voiced { voicedSinceReport = true }
        if now - lastLevelReport > 0.05 {
            lastLevelReport = now
            let lvl = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 60) / 50))
            voicedSinceReport = false
            let lv = lastVoice
            DispatchQueue.main.async { self.delegate?.recognizer(level: lvl, lastVoicedAt: lv) }
        }

        if gateOpen || holdOpenFlag {
            if !gateOpen { gateOpen = true; ensureSession() }
            feed(buf)
            if !holdOpenFlag && now - lastVoice > 1.3 {
                gateOpen = false
                if let s = session { s.finish(); session = nil } else if creating { finishWhenReady = true }
            }
        } else {
            preroll.append(buf); prerollFrames += buf.frameLength
            let maxFrames = AVAudioFrameCount(buf.format.sampleRate * 0.7)
            while prerollFrames > maxFrames, let first = preroll.first { prerollFrames -= first.frameLength; preroll.removeFirst() }
            if voicedRun >= 2 {
                gateOpen = true
                ensureSession()
                for b in preroll { feed(b) }
                preroll.removeAll(); prerollFrames = 0
            }
        }
    }

    private func feed(_ buf: AVAudioPCMBuffer) {
        guard let converter else { return }
        guard let inputs = try? converter.convert(buf, at: nil), !inputs.isEmpty else { return }
        if let s = session { s.feed(inputs) } else { pending.append(contentsOf: inputs) }
    }

    private func ensureSession() {
        guard session == nil, !creating else { return }
        finishWhenReady = false
        if let s = spare {
            // Pre-warmed session: zero startup latency.
            spare = nil
            sessionCounter += 1
            s.id = sessionCounter
            session = s
            s.feed(pending); pending.removeAll()
            prepareSpare()
            return
        }
        creating = true
        sessionCounter += 1
        let id = sessionCounter
        let fmt = analyzerFormat
        let vocab = vocabulary
        Task.detached { [weak self] in
            do {
                let s = try await AnalyzerSession.make(id: id, format: fmt, vocabulary: vocab) { seg in
                    DispatchQueue.main.async { self?.delegate?.recognizer(didUpdate: seg) }
                }
                self?.proc.async {
                    guard let self else { return }
                    self.creating = false
                    self.session = s
                    s.feed(self.pending); self.pending.removeAll()
                    if self.finishWhenReady && !self.holdOpenFlag { s.finish(); self.session = nil; self.finishWhenReady = false }
                    self.prepareSpare()
                }
            } catch {
                self?.proc.async { self?.creating = false; self?.pending.removeAll() }
                DispatchQueue.main.async { self?.delegate?.recognizer(failed: "Speech session failed: \(error.localizedDescription)") }
            }
        }
    }

    /// Keeps one started-but-idle analyzer ready so speech onset is transcribed immediately.
    private func prepareSpare() {
        guard spare == nil, !preparingSpare, running else { return }
        preparingSpare = true
        let fmt = analyzerFormat
        let vocab = vocabulary
        Task.detached { [weak self] in
            let s = try? await AnalyzerSession.make(id: -1, format: fmt, vocabulary: vocab) { seg in
                DispatchQueue.main.async { self?.delegate?.recognizer(didUpdate: seg) }
            }
            self?.proc.async {
                guard let self else { return }
                self.preparingSpare = false
                if self.running { self.spare = s } else { s?.cancel() }
            }
        }
    }

    // MARK: - helpers

    private static var monoFormats: [Double: AVAudioFormat] = [:]
    private static let monoLock = NSLock()
    static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if b.format.channelCount > 1, b.format.commonFormat == .pcmFormatFloat32, let s = b.floatChannelData {
            monoLock.lock()
            let mf = monoFormats[b.format.sampleRate] ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: b.format.sampleRate, channels: 1, interleaved: false)!
            monoFormats[b.format.sampleRate] = mf
            monoLock.unlock()
            guard let c = AVAudioPCMBuffer(pcmFormat: mf, frameCapacity: b.frameLength), let d = c.floatChannelData else { return nil }
            c.frameLength = b.frameLength
            d[0].update(from: s[0], count: Int(b.frameLength))
            return c
        }
        guard let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        c.frameLength = b.frameLength
        let n = Int(b.frameLength)
        if let s = b.floatChannelData, let d = c.floatChannelData {
            for ch in 0..<Int(b.format.channelCount) { d[ch].update(from: s[ch], count: n) }
        } else if let s = b.int16ChannelData, let d = c.int16ChannelData {
            for ch in 0..<Int(b.format.channelCount) { d[ch].update(from: s[ch], count: n) }
        } else { return nil }
        return c
    }

    static func rms(_ b: AVAudioPCMBuffer) -> Float {
        let n = Int(b.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        if let d = b.floatChannelData?[0] { for i in 0..<n { sum += d[i] * d[i] } }
        else if let d = b.int16ChannelData?[0] { for i in 0..<n { let f = Float(d[i]) / 32768; sum += f * f } }
        return sqrt(sum / Float(n))
    }

    static func builtInInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var t: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            var ta = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &ta, 0, nil, &s, &t) == noErr, t == kAudioDeviceTransportTypeBuiltIn else { continue }
            var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var ss: UInt32 = 0
            if AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ss) == noErr, ss > 0 { return id }
        }
        return nil
    }
}
