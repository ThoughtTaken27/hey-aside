import AppKit
import CoreGraphics
import Foundation

/// When Jarvis may speak up on his own (design brief: "never during school, never during sleep; mostly finished tasks,
/// updates, deadlines, things that need my attention and are slightly urgent. We can test it out and see how it feels.")
///
/// Rules:
/// - Quiet on weekdays 7:00 AM - 3:15 PM (school) and every night 11 PM - 7 AM (sleep).
/// - Only when you're at the Mac: input in the last 2 minutes, screen unlocked, not muted, no conversation open.
///   Otherwise it holds the update and says it when you're back (if it's still relevant).
/// - Sources: finished Aside tasks, deadline heads-ups from the school planner's cache (no AI call, no network),
///   and `HeyAside --announce "text"` (for Aside routines).
/// - Checked once a minute; costs a timer tick and, only when the cache file changed, one 27 KB JSON read.
@MainActor
final class Proactive {
    struct Update { let text: String; let key: String; let validUntil: Date }

    var deliver: ((Update) -> Void)?
    var canDeliverNow: (() -> Bool)?
    private var queue: [Update] = []
    private var timer: Timer?
    private let d = UserDefaults.standard

    /// Optional deadline cache (a JSON file with an "items" map, e.g. written by an Aside routine).
    /// Off unless set: `defaults write app.heyaside.mac deadlineCache -string /path/to/items.json`.
    static var cacheURL: URL { URL(fileURLWithPath: UserDefaults.standard.string(forKey: "deadlineCache") ?? "/nonexistent/heyaside-deadlines.json") }
    private var cacheMTime: Date?
    private var items: [(id: String, title: String, due: Date)] = []
    private var cacheFresh = false

    func start() {
        guard timer == nil else { return }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("app.heyaside.mac.announce"), object: nil, queue: .main) { [weak self] n in
            guard let text = n.object as? String, !text.isEmpty else { return }
            MainActor.assumeIsolated {
                Log.write("announce request: \(text)")
                self?.enqueue(Update(text: text, key: "announce:\(text.hashValue)", validUntil: Date().addingTimeInterval(6 * 3600)))
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        timer?.tolerance = 20
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.tick() }
    }

    func enqueue(_ u: Update) {
        guard !queue.contains(where: { $0.key == u.key }) else { return }
        queue.append(u)
        tick()
    }

    // MARK: rules

    nonisolated static func quietReason(_ date: Date = Date()) -> String? {
        let c = Calendar.current
        let wd = c.component(.weekday, from: date)             // 1 = Sunday
        let mins = c.component(.hour, from: date) * 60 + c.component(.minute, from: date)
        if mins >= 23 * 60 || mins < 7 * 60 { return "sleep hours" }
        if (2...6).contains(wd) && mins >= 7 * 60 && mins < 15 * 60 + 15 { return "school hours" }
        return nil
    }

    static var secondsIdle: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    static var present: Bool { secondsIdle < 120 && !screenLocked }

    private func tick() {
        guard Settings.shared.proactive else { return }
        let now = Date()
        queue.removeAll { $0.validUntil < now }
        checkDeadlines(now)
        guard !queue.isEmpty, Proactive.quietReason(now) == nil, Proactive.present, canDeliverNow?() ?? false else { return }
        let u = queue.removeFirst()
        d.set(true, forKey: "said:" + u.key)
        deliver?(u)
    }

    // MARK: deadlines (from the school planner's cache)

    private func loadCache() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: Proactive.cacheURL.path),
              let m = attrs[.modificationDate] as? Date, m != cacheMTime else { return }
        cacheMTime = m
        items = []
        guard let data = try? Data(contentsOf: Proactive.cacheURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let all = root["items"] as? [String: [String: Any]] else { return }
        // Only trust a cache refreshed in the last 2 days; stale status would make false alarms.
        let lastRun = (root["lastRun"] as? String).flatMap { Proactive.day.date(from: $0) }
        cacheFresh = lastRun.map { now in Date().timeIntervalSince(now) < 2 * 86_400 + 3600 } ?? false
        let iso = ISO8601DateFormatter()
        for (id, v) in all {
            guard (v["submissionRequired"] as? Bool) == true, let dueS = v["dueISO"] as? String,
                  let due = iso.date(from: dueS) ?? Proactive.isoNoZ(dueS) else { continue }
            let state = ((v["attemptState"] as? String) ?? "").lowercased()
            let outcome = ((v["outcome"] as? String) ?? "").lowercased()
            if ["submitted", "graded", "locked", "no attempts left", "done", "complete"].contains(where: { state.contains($0) || outcome.contains($0) }) { continue }
            items.append((id, Proactive.spokenTitle(v["title"] as? String ?? ""), due))
        }
    }

    private func checkDeadlines(_ now: Date) {
        loadCache()
        guard cacheFresh else { return }
        // About an hour before something closes.
        for it in items {
            let left = it.due.timeIntervalSince(now)
            guard left > 5 * 60, left <= 75 * 60 else { continue }
            let key = "soon:\(it.id):\(Int(it.due.timeIntervalSince1970))"
            if d.bool(forKey: "said:" + key) { continue }
            let mins = Int((left / 60 / 5).rounded()) * 5
            let when = mins >= 55 ? "in about an hour" : "in about \(mins) minutes"
            enqueue(Update(text: "Sir, a heads-up: \(it.title) closes \(when), at \(Proactive.time(it.due)). Last I checked, it's still open.",
                           key: key, validUntil: it.due.addingTimeInterval(-5 * 60)))
        }
        // Once a day, the first time you're around after school/sleep: what's still open for tonight.
        let today = Proactive.day.string(from: now)
        let key = "tonight:\(today)"
        let tonight = items.filter { Calendar.current.isDate($0.due, inSameDayAs: now) && $0.due > now.addingTimeInterval(75 * 60) }
        if !tonight.isEmpty, !d.bool(forKey: "said:" + key), !queue.contains(where: { $0.key == key }) {
            let names = tonight.sorted { $0.due < $1.due }.prefix(3).map { "\($0.title) by \(Proactive.time($0.due))" }
            let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
            let count = tonight.count == 1 ? "One thing is" : "\(Proactive.word(tonight.count)) things are"
            enqueue(Update(text: "Welcome back, sir. \(count) still open for tonight: \(list).", key: key,
                           validUntil: Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: now) ?? now))
        }
    }

    // MARK: formatting

    static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    static func isoNoZ(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for p in ["yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] { f.dateFormat = p; if let d = f.date(from: s) { return d } }
        return nil
    }
    static func time(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        let h = (c.hour ?? 0) % 12 == 0 ? 12 : (c.hour ?? 0) % 12
        let ampm = (c.hour ?? 0) < 12 ? "AM" : "PM"
        return (c.minute ?? 0) == 0 ? "\(h) \(ampm)" : String(format: "%d:%02d %@", h, c.minute ?? 0, ampm)
    }
    static func word(_ n: Int) -> String { ["Zero", "One", "Two", "Three", "Four", "Five", "Six"][min(n, 6)] }
    /// "Atwood Machine Pre-Lab Questions" stays; codes and brackets go ("(2.3/3) HW" -> "2.3/3 HW").
    static func spokenTitle(_ t: String) -> String {
        t.replacingOccurrences(of: #"[\[\]()]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}
