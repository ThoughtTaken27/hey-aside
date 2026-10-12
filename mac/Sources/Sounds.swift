import AppKit
import AVFoundation
import Foundation

/// Jarvis's own sound set (Sep 25), replacing the stock macOS sounds.
/// Synthesized once at launch (additive sines with a glassy overtone and an exponential tail), a few KB each, no files.
/// Rules: short (under 0.4 s), quiet, pitched in one key (C major) so they feel like one family.
enum JarvisSound: CaseIterable {
    case wake       // you said "Hey Jarvis": a bright two-note rise
    case ready      // he has something for you unprompted (finished task, heads-up): a soft three-note arpeggio
    case mute       // mic off: two notes falling
    case unmute     // mic on: two notes rising
    case end        // conversation over / cancelled: one low, soft note

    /// (frequency Hz, start s, length s, gain)
    fileprivate var notes: [(Double, Double, Double, Double)] {
        switch self {
        case .wake:   return [(1046.5, 0, 0.16, 0.55), (1568.0, 0.07, 0.24, 0.5)]
        case .ready:  return [(784.0, 0, 0.2, 0.45), (1046.5, 0.09, 0.22, 0.45), (1318.5, 0.18, 0.3, 0.42)]
        case .mute:   return [(987.8, 0, 0.12, 0.45), (659.3, 0.08, 0.2, 0.45)]
        case .unmute: return [(659.3, 0, 0.12, 0.45), (987.8, 0.08, 0.2, 0.45)]
        case .end:    return [(523.3, 0, 0.26, 0.4)]
        }
    }
    fileprivate var volume: Float {
        switch self { case .wake: return 0.2; case .ready: return 0.26; case .mute, .unmute: return 0.18; case .end: return 0.16 }
    }
}

@MainActor
enum Sounds {
    private static var players: [JarvisSound: AVAudioPlayer] = [:]

    /// The sounds Hey Aside uses: stock macOS ones (Tink = wake, Pop = conversation/announcement, Bottle = cancelled, Basso = error).
    static func system(_ name: String) {
        guard Settings.shared.sounds else { return }
        if name == "Pop" { chime(Settings.shared.chime); return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    /// Menu label -> sound. Stock macOS sounds only; a .caf you drop into Resources/Chimes/ is picked up by name too.
    static let chimes: [(label: String, name: String)] = [
        ("Pop", "Pop"), ("Glass", "Glass"), ("Tink", "Tink"), ("Ping", "Ping"), ("Purr", "Purr"), ("Hero", "Hero"),
    ]
    private static var current: NSSound?
    static func chime(_ name: String) {
        if let url = Bundle.main.url(forResource: name, withExtension: "caf", subdirectory: "Chimes") {
            current = NSSound(contentsOf: url, byReference: true)
        } else {
            current = NSSound(named: NSSound.Name(name))
        }
        current?.play()
    }

    /// Synthesized set, kept only for auditioning alternatives (not used by the app).
    static func play(_ s: JarvisSound) {
        guard Settings.shared.sounds, !Speaker.silent else { return }
        if players[s] == nil, let p = try? AVAudioPlayer(data: wav(s)) { p.prepareToPlay(); players[s] = p }
        guard let p = players[s] else { return }
        p.volume = s.volume
        p.currentTime = 0
        p.play()
    }

    /// Renders the sound to a 16-bit mono WAV in memory.
    static func wav(_ s: JarvisSound) -> Data {
        let sr = 44_100.0
        let total = (s.notes.map { $0.1 + $0.2 }.max() ?? 0.3) + 0.08
        let n = Int(total * sr)
        var buf = [Double](repeating: 0, count: n)
        for (f, start, len, gain) in s.notes {
            let i0 = Int(start * sr), count = Int((len + 0.06) * sr)
            for i in 0..<count where i0 + i < n {
                let t = Double(i) / sr
                let attack = min(1, t / 0.004)                       // 4 ms: no click
                let decay = exp(-t / (len * 0.38))                   // bell-like tail
                let v = sin(2 * .pi * f * t) + 0.18 * sin(2 * .pi * f * 2 * t) + 0.06 * sin(2 * .pi * f * 3.01 * t)
                buf[i0 + i] += v * attack * decay * gain
            }
        }
        let peak = max(0.001, buf.map(abs).max() ?? 1)
        var pcm = Data(capacity: n * 2)
        for x in buf {
            var v = Int16(max(-1, min(1, x / peak * 0.9)) * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(44_100); u32(88_200); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }
}
