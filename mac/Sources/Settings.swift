import Foundation

enum DeliveryMode: String, CaseIterable {
    case popupThenBackground = "popup+background"
    case popupOnly = "popup"
    case background = "background"

    var title: String {
        switch self {
        case .popupThenBackground: return "Popup, fall back to background"
        case .popupOnly: return "Popup only"
        case .background: return "New Aside session (no popup)"
        }
    }
}

/// UserDefaults-backed settings. Domain: app.heyaside.mac
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "delivery": DeliveryMode.background.rawValue,
            "silence": 1.2,
            "cancelWindow": 1.5,
            "sounds": true,
            "hud": true,
            "builtInMic": true,
            "paused": false,
            "cliPermission": "ask",
            // Empty = whatever model Aside itself is set to use.
            "agentModel": "",
            "agentEffort": "",
            "agentSpeed": "",
            "logTranscripts": true,
            "vocabulary": "Jarvis, Hey Jarvis, Aside, Hey Aside, Gmail"
        ])
    }

    var delivery: DeliveryMode {
        get { DeliveryMode(rawValue: d.string(forKey: "delivery") ?? "") ?? .background }
        set { d.set(newValue.rawValue, forKey: "delivery") }
    }
    var silence: Double { get { d.double(forKey: "silence") } set { d.set(newValue, forKey: "silence") } }
    var cancelWindow: Double { get { d.double(forKey: "cancelWindow") } set { d.set(newValue, forKey: "cancelWindow") } }
    /// The chime when a conversation opens or Jarvis speaks up: a macOS sound name or a bundled Chimes/<name>.caf.
    var chime: String { get { d.string(forKey: "chime") ?? "Pop" } set { d.set(newValue, forKey: "chime") } }
    var sounds: Bool { get { d.bool(forKey: "sounds") } set { d.set(newValue, forKey: "sounds") } }
    var hud: Bool { get { d.bool(forKey: "hud") } set { d.set(newValue, forKey: "hud") } }
    var builtInMic: Bool { get { d.bool(forKey: "builtInMic") } set { d.set(newValue, forKey: "builtInMic") } }
    /// Silent tests run unmuted in memory only, never touching the real mute setting.
    nonisolated(unsafe) static var testOverride = false
    private var testPaused = false
    var paused: Bool {
        get { Settings.testOverride ? testPaused : d.bool(forKey: "paused") }
        set { if Settings.testOverride { testPaused = newValue } else { d.set(newValue, forKey: "paused") } }
    }
    var voice: AsideVoice {
        get { AsideVoice(rawValue: d.string(forKey: "voice") ?? "") ?? .ryan }
        set { d.set(newValue.rawValue, forKey: "voice") }
    }
    /// Speaking rate in percent relative to the voice's normal speed (slightly faster than +6).
    var voiceRate: Int { get { d.object(forKey: "voiceRate") as? Int ?? 9 } set { d.set(newValue, forKey: "voiceRate") } }
    /// Talk over Aside: the mic cancels Aside's own voice (Apple voice processing).
    var echoCancel: Bool { get { d.object(forKey: "echoCancel") as? Bool ?? true } set { d.set(newValue, forKey: "echoCancel") } }
    /// A conversation stays open (no wake phrase needed) until this many seconds pass with nobody talking and Aside idle.
    /// Sep 29: 2.5 minutes (was 20 s), then Jarvis mutes himself (`idleMutes`).
    var conversationIdle: Double { get { Settings.idleOverride ?? d.object(forKey: "conversationIdle") as? Double ?? 150 } set { d.set(newValue, forKey: "conversationIdle") } }
    /// Tests only: a short quiet window, never written to defaults.
    nonisolated(unsafe) static var idleOverride: Double?
    /// When a conversation goes quiet for `conversationIdle`, mute (mic off, "Hey Jarvis" off until you unmute) instead
    /// of dropping back to listening for the wake phrase.
    var idleMutes: Bool { get { d.object(forKey: "idleMutes") as? Bool ?? true } set { d.set(newValue, forKey: "idleMutes") } }
    /// Speak Aside's replies out loud.
    var voiceReplies: Bool { get { d.object(forKey: "voiceReplies") as? Bool ?? true } set { d.set(newValue, forKey: "voiceReplies") } }
    /// After Aside speaks, keep listening briefly for a follow-up without the wake phrase.
    var followUp: Bool { get { d.object(forKey: "followUp") as? Bool ?? true } set { d.set(newValue, forKey: "followUp") } }
    /// Jarvis may speak up on his own (finished tasks, deadline heads-ups), outside school and sleep hours.
    /// Oct 7: Jarvis Live (Codex realtime voice + Aside MCP). Off returns to the classic Ryan pipeline.
    var liveCall: Bool { get { d.object(forKey: "liveCall") as? Bool ?? true } set { d.set(newValue, forKey: "liveCall") } }
    /// Codex v3 voices: juniper, maple, spruce, ember, vale, breeze, arbor, sol, cove. Arbor measured deepest (84 Hz), Spruce next (88 Hz).
    var liveVoice: String { get { d.string(forKey: "liveVoice") ?? "arbor" } set { d.set(newValue, forKey: "liveVoice") } }
    /// Audio through Codex's own codex-voice-host (default; verified Oct 7 once macOS permissions were granted).
    /// false = the WebKit WebRTC bridge (VoiceBridge.swift), kept as a fallback; its ICE did not connect on Oct 7.
    var liveNative: Bool { get { d.object(forKey: "liveNative") as? Bool ?? true } set { d.set(newValue, forKey: "liveNative") } }
    var liveModel: String { get { d.string(forKey: "liveModel") ?? "gpt-6-luna" } set { d.set(newValue, forKey: "liveModel") } }
    /// Seconds of quiet (nobody talking, nothing running) before a live call hangs up. At least 30 feels natural.
    var liveIdle: Double { get { d.object(forKey: "liveIdle") as? Double ?? 30 } set { d.set(newValue, forKey: "liveIdle") } }
    var proactive: Bool { get { d.object(forKey: "proactive") as? Bool ?? true } set { d.set(newValue, forKey: "proactive") } }
    var wakePhrase: WakeMatcher.Phrase {
        get { WakeMatcher.Phrase(rawValue: d.string(forKey: "wakePhrase") ?? "") ?? .jarvis }
        set { d.set(newValue.rawValue, forKey: "wakePhrase"); WakeMatcher.phrase = newValue }
    }
    var orbPalette: OrbPalette {
        get { OrbPalette(rawValue: d.string(forKey: "orbPalette") ?? "") ?? .jarvis }
        set { d.set(newValue.rawValue, forKey: "orbPalette") }
    }
    /// Where Jarvis shows up: the Dynamic Island (matched to Vorssaint's) or the floating orb (Sep 28).
    nonisolated(unsafe) static var styleOverride: HUDStyle?
    /// Words in the island. Off by default: Jarvis is voice + orb; only the send countdown and errors show text.
    nonisolated(unsafe) static var captionsOverride: Bool?
    /// Sep 30: "this" / "on my screen" sends the front app, window title and browser tab with that turn.
    /// Off: defaults write app.heyaside.mac screenContext -bool false
    var screenContext: Bool { d.object(forKey: "screenContext") as? Bool ?? true }
    var islandCaptions: Bool {
        get { Settings.captionsOverride ?? d.bool(forKey: "islandCaptions") }
        set { d.set(newValue, forKey: "islandCaptions") }
    }
    var hudStyle: HUDStyle {
        get { Settings.styleOverride ?? HUDStyle(rawValue: d.string(forKey: "hudStyle") ?? "") ?? .island }
        set { d.set(newValue.rawValue, forKey: "hudStyle") }
    }
    var cliPermission: String { d.string(forKey: "cliPermission") ?? "ask" }
    /// Optionally pin every new Aside session Jarvis starts to one model. Unset (the default) uses Aside's own default.
    /// Resumed sessions keep the model they started with.
    /// Override: defaults write app.heyaside.mac agentModel -string provider/model (agentEffort, agentSpeed likewise).
    var cliModelArgs: [String] {
        var a: [String] = []
        if let m = d.string(forKey: "agentModel"), !m.isEmpty { a += ["--model", m] }
        if let e = d.string(forKey: "agentEffort"), !e.isEmpty { a += ["--effort", e] }
        if let s = d.string(forKey: "agentSpeed"), !s.isEmpty { a += ["--speed", s] }
        return a
    }
    /// Arguments that start a brand-new Aside session with the pinned model.
    func newSessionArgs(_ prompt: String) -> [String] { cliModelArgs + ["--permission", cliPermission, prompt] }
    var logTranscripts: Bool { d.bool(forKey: "logTranscripts") }
    var vocabulary: [String] {
        (d.string(forKey: "vocabulary") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// The signed-in Aside account folder (~/.aside/u/<currentAccountId>), as Aside's accounts.json says.
enum AsideRoot {
    static var path: String {
        let home = NSHomeDirectory() + "/.aside"
        if let d = try? Data(contentsOf: URL(fileURLWithPath: home + "/accounts.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let id = j["currentAccountId"] as? Int, id >= 0 {
            return home + "/u/\(id)"
        }
        return home + "/u/0"
    }
}

enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/HeyAside", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("heyaside.log")
    }()
    private static let q = DispatchQueue(label: "heyaside.log")
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()
    static var echo = false

    static func write(_ msg: String) {
        let line = "\(fmt.string(from: Date())) \(msg)\n"
        if echo { FileHandle.standardOutput.write(line.data(using: .utf8)!) }
        q.async {
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
            else { try? line.data(using: .utf8)!.write(to: url) }
        }
    }
}
