import Foundation
import AppKit

/// Sep 27: Jarvis's own reminders. The agent used to burn one of Aside's three routine slots per reminder, or
/// improvise a `sleep` script that spoke in the macOS "Daniel" voice. Now `HeyAside --remind <time> <text>`
/// writes ~/.heyaside/reminders.json and the running app fires it: a notification plus Ryan's voice.
/// A reminder you asked for is spoken even in quiet hours; mute still silences it (notification only).
struct Reminder: Codable, Equatable {
    var id: String
    var at: Date
    var text: String
    var fired: Bool
}

enum ReminderStore {
    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/.heyaside/reminders.json")
    static let changed = Notification.Name("app.heyaside.mac.remindersChanged")

    static func load() -> [Reminder] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Reminder].self, from: d)) ?? []
    }

    static func save(_ all: [Reminder]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        // Keep a day of history, drop the rest.
        let keep = all.filter { !$0.fired || Date().timeIntervalSince($0.at) < 86_400 }
        if let d = try? enc.encode(keep) { try? d.write(to: url, options: .atomic) }
    }

    /// "2026-09-27T18:00", "2026-09-27 18:00", with or without seconds or an offset; local time when none.
    static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "T")
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: t) { return d }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] { f.dateFormat = fmt; if let d = f.date(from: t) { return d } }
        return nil
    }

    static func add(at: Date, text: String) -> Reminder {
        var all = load()
        let r = Reminder(id: UUID().uuidString, at: at, text: text, fired: false)
        all.append(r)
        save(all)
        DistributedNotificationCenter.default().postNotificationName(changed, object: nil, userInfo: nil, deliverImmediately: true)
        return r
    }
}

@MainActor final class Reminders {
    var fire: ((Reminder) -> Void)?
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        DistributedNotificationCenter.default().addObserver(forName: ReminderStore.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        timer?.tolerance = 1
        tick()
    }

    private func tick() {
        let now = Date()
        var all = ReminderStore.load()
        var due: [Reminder] = []
        for i in all.indices where !all[i].fired && all[i].at <= now {
            all[i].fired = true
            // A reminder more than 6 hours stale (Mac was off) is only shown, not spoken.
            if now.timeIntervalSince(all[i].at) < 6 * 3600 { due.append(all[i]) } else { Reminders.notify(all[i].text, stale: true) }
        }
        guard all != ReminderStore.load() || !due.isEmpty else { return }
        ReminderStore.save(all)
        for r in due {
            Log.write("REMINDER: \(r.text)")
            Reminders.notify(r.text, stale: false)
            fire?(r)
        }
    }

    nonisolated static func notify(_ text: String, stale: Bool) {
        let esc = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc)\" with title \"\(stale ? "Missed reminder" : "Jarvis")\""]
        try? p.run()
    }
}
