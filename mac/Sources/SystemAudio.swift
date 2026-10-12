import AVFoundation
import CoreAudio
import Foundation
import QuartzCore
import Speech

/// Oct 2: what the Mac itself is playing (videos, music, calls), heard digitally through a Core Audio process tap, so
/// Jarvis can tell your voice from a speaker that says "Hey Jarvis". Only the last 15 s are kept, in memory, and
/// nothing is transcribed unless the mic just heard the wake phrase or a command while the Mac was making sound.
/// Needs the "System Audio Recording Only" permission (macOS asks once). If it is refused or the tap fails, the
/// guard stays out of the way and Jarvis behaves exactly as before.
/// Turn off with `defaults write app.heyaside.mac ignoreMacAudio -bool false`.
final class SystemAudio: @unchecked Sendable {
    static let shared = SystemAudio()

    static var enabled: Bool { UserDefaults.standard.object(forKey: "ignoreMacAudio") as? Bool ?? true }

    private let q = DispatchQueue(label: "heyaside.sysaudio", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?

    // ring buffer of mono samples (q only)
    private var rate: Double = 48_000
    private var ring: [Float] = []
    private var writeAt = 0
    private var filled = 0
    private var lastLoud: TimeInterval = 0
    private var lastBuffer: TimeInterval = 0
    private(set) var running = false

    /// Loud enough to be speech or music coming out of the speakers (RMS of the digital signal).
    private let loudRMS: Float = 0.004

    // MARK: start / stop

    @discardableResult
    func start() -> Bool {
        guard SystemAudio.enabled, !running else { return running }
        var selfObj = AudioObjectID(kAudioObjectUnknown)
        var pid = getpid()
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &selfObj)
        // Everything the Mac plays except Jarvis's own voice.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: selfObj == kAudioObjectUnknown ? [] : [selfObj])
        desc.uuid = UUID()
        desc.name = "Hey Aside - Mac audio guard"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr, tap != kAudioObjectUnknown else { Log.write("mac audio guard: tap failed (\(err))"); return false }
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
        guard err == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else { Log.write("mac audio guard: no tap format (\(err))"); stop(); return false }
        tapFormat = fmt

        let outUID = SystemAudio.defaultOutputUID() ?? ""
        var agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hey Aside Mac Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        if !outUID.isEmpty {
            agg[kAudioAggregateDeviceMainSubDeviceKey] = outUID
            agg[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outUID]]
        }
        var aggDev = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggDev)
        guard err == noErr else { Log.write("mac audio guard: aggregate failed (\(err))"); stop(); return false }
        aggID = aggDev

        q.sync {
            rate = fmt.sampleRate > 0 ? fmt.sampleRate : 48_000
            ring = [Float](repeating: 0, count: Int(rate * 15))
            writeAt = 0; filled = 0; lastLoud = 0; lastBuffer = 0
        }
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggDev, q) { [weak self] _, inData, _, _, _ in
            self?.ingest(inData)
        }
        guard err == noErr, let procID else { Log.write("mac audio guard: io proc failed (\(err))"); stop(); return false }
        err = AudioDeviceStart(aggDev, procID)
        guard err == noErr else { Log.write("mac audio guard: start failed (\(err))"); stop(); return false }
        running = true
        Log.write("mac audio guard on (\(Int(fmt.sampleRate)) Hz x\(fmt.channelCount), excluding own voice: \(selfObj != kAudioObjectUnknown))")
        return true
    }

    func stop() {
        if aggID != kAudioObjectUnknown, let procID { AudioDeviceStop(aggID, procID); AudioDeviceDestroyIOProcID(aggID, procID) }
        procID = nil
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
        running = false
    }

    private static func defaultOutputUID() -> String? {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr, let u = uid else { return nil }
        return u.takeRetainedValue() as String
    }

    // MARK: audio in (q)

    private func ingest(_ list: UnsafePointer<AudioBufferList>) {
        guard let fmt = tapFormat,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: list, deallocator: nil) else { return }
        append(buf)
    }

    /// Mixes to mono and stores the samples; also used by the silent file test.
    func append(_ buf: AVAudioPCMBuffer) {
        let frames = Int(buf.frameLength)
        guard frames > 0, let data = buf.floatChannelData, !ring.isEmpty else { return }
        let ch = Int(buf.format.channelCount)
        let interleaved = buf.format.isInterleaved
        var sum: Float = 0
        for i in 0..<frames {
            var v: Float = 0
            if interleaved { for c in 0..<ch { v += data[0][i * ch + c] } } else { for c in 0..<ch { v += data[c][i] } }
            v /= Float(max(ch, 1))
            ring[writeAt] = v
            writeAt = (writeAt + 1) % ring.count
            sum += v * v
        }
        filled = min(ring.count, filled + frames)
        let now = CACurrentMediaTime()
        lastBuffer = now
        if (sum / Float(frames)).squareRoot() > loudRMS { lastLoud = now }
    }

    /// Test hook: a ring of `seconds` at `sampleRate`, without any tap.
    func prepareForTest(sampleRate: Double) {
        q.sync { rate = sampleRate; ring = [Float](repeating: 0, count: Int(sampleRate * 15)); writeAt = 0; filled = 0; lastLoud = 0 }
    }
    func appendForTest(_ buf: AVAudioPCMBuffer) { q.sync { append(buf) } }
    func markRunningForTest() { running = true }

    // MARK: questions

    /// Did the Mac play anything audible in the last `seconds`?
    func playedRecently(within seconds: TimeInterval) -> Bool {
        q.sync { lastLoud > 0 && CACurrentMediaTime() - lastLoud < seconds }
    }

    /// The last `seconds` of Mac audio as one mono buffer.
    private func clip(last seconds: TimeInterval) -> AVAudioPCMBuffer? {
        q.sync {
            let n = min(filled, Int(seconds * rate))
            guard n > Int(rate * 0.3), let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                  let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)), let dst = out.floatChannelData?[0] else { return nil }
            var r = (writeAt - n + ring.count) % ring.count
            for i in 0..<n { dst[i] = ring[r]; r = (r + 1) % ring.count }
            out.frameLength = AVAudioFrameCount(n)
            return out
        }
    }

    /// What the Mac said in the last `seconds` (on-device recognizer; "" when nothing usable).
    func transcript(last seconds: TimeInterval) async -> String {
        guard let buf = clip(last: seconds) else { return "" }
        return await SystemAudio.transcribe(buf)
    }

    static func transcribe(_ buf: AVAudioPCMBuffer) async -> String {
        let module = SpeechTranscriber(locale: Locale(identifier: "en-US"), transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        guard let af = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: buf.format) else { return "" }
        let conv = AnalyzerInputConverter(analyzerFormat: af)
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let collect = Task.detached { () -> String in
            var parts: [String] = []
            do { for try await r in module.results where r.isFinal { parts.append(String(r.text.characters)) } } catch {}
            return parts.joined(separator: " ")
        }
        do {
            try await analyzer.start(inputSequence: stream)
            for i in (try? conv.convert(buf, at: nil)) ?? [] { cont.yield(i) }
            cont.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            cont.finish()
            Log.write("mac audio guard: transcribe failed: \(error)")
        }
        return await collect.value
    }

    // MARK: verdicts

    /// True when the wake phrase the mic just heard was also in what the Mac played.
    func wakeCameFromMac() async -> Bool {
        guard running, playedRecently(within: 4) else { return false }
        let t0 = CACurrentMediaTime()
        let heard = await transcript(last: 6)
        let fromMac = WakeMatcher.match(heard) != nil
        Log.write("mac audio guard: wake check \(Int((CACurrentMediaTime() - t0) * 1000)) ms, mac said \"\(heard.suffix(80))\" -> \(fromMac ? "ignored" : "his voice")")
        return fromMac
    }

    /// True when most of a command's words were just played by the Mac (a video talking, not you).
    func commandCameFromMac(_ cmd: String, spokenOver seconds: TimeInterval) async -> Bool {
        let words = SystemAudio.words(cmd)
        guard running, words.count >= 2, playedRecently(within: seconds + 1.5) else { return false }
        let t0 = CACurrentMediaTime()
        let heard = await transcript(last: min(15, seconds + 2))
        let mac = SystemAudio.words(heard)
        let share = SystemAudio.overlap(words, mac)
        let pairs = SystemAudio.overlap(SystemAudio.bigrams(words), SystemAudio.bigrams(mac))
        // Both the words and their order must match, so asking about something the video just said ("what does
        // product hunt first mean") is still him.
        let fromMac = share >= 0.6 && (words.count < 3 ? share >= 0.99 : pairs >= 0.45)
        Log.write("mac audio guard: command check \(Int((CACurrentMediaTime() - t0) * 1000)) ms, \(Int(share * 100))% of words and \(Int(pairs * 100))% of word pairs were Mac audio -> \(fromMac ? "ignored" : "his voice")")
        return fromMac
    }

    nonisolated static func words(_ s: String) -> [String] {
        let fillers: Set<String> = ["uh", "um", "hey", "jarvis", "aside", "the", "a", "an", "and"]
        return Lane.norm(s).split(separator: " ").map(String.init).filter { !fillers.contains($0) }
    }

    nonisolated static func bigrams(_ w: [String]) -> [String] { w.count < 2 ? w : (0..<(w.count - 1)).map { w[$0] + " " + w[$0 + 1] } }

    /// Share of the command's words that also appear in what the Mac played.
    nonisolated static func overlap(_ cmd: [String], _ mac: [String]) -> Double {
        guard !cmd.isEmpty else { return 0 }
        let pool = Set(mac)
        return Double(cmd.filter { pool.contains($0) }.count) / Double(cmd.count)
    }
}
