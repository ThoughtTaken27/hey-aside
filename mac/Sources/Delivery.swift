import AppKit
import ApplicationServices
import Foundation

/// Drives Aside's mini popup (default shortcut Option+Q) safely.
///
/// Safety rules learned from live probing on Sep 24:
/// - The shortcut toggles, and blind HID typing can land in the main chat composer.
///   So we never type unless the focused element is a text area inside Aside's floating popup window.
/// - Keystrokes are posted to Aside's pid only, so a focus change can never leak text into another app.
final class AsidePopup {
    static let bundleID = "at.studio.AsideBrowser"

    struct Shortcut { let key: CGKeyCode; let flags: CGEventFlags; let text: String }

    var app: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first }

    // MARK: shortcut from Aside's Local State

    static func readShortcut() -> (enabled: Bool, shortcut: Shortcut?) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Aside/Local State")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let aside = json["aside"] as? [String: Any],
              let mp = aside["mini_popup"] as? [String: Any] else { return (true, parse("Alt+Q")) }
        let enabled = mp["enabled"] as? Bool ?? true
        let s = mp["shortcut"] as? String ?? "Alt+Q"
        return (enabled, parse(s))
    }

    static func parse(_ s: String) -> Shortcut? {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for raw in s.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            switch raw {
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "command", "cmd", "meta", "super": flags.insert(.maskCommand)
            case "ctrl", "control", "macctrl": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            default: key = keyCodes[raw]
            }
        }
        guard let k = key else { return nil }
        return Shortcut(key: k, flags: flags, text: s)
    }

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "space": 49, "period": 47, "comma": 43, "slash": 44,
        "semicolon": 41, "quote": 39, "return": 36, "enter": 36, "tab": 48, "escape": 53, "esc": 53, "`": 50, "backquote": 50
    ]

    // MARK: AX helpers

    private func attr(_ e: AXUIElement, _ k: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil
    }

    private func frame(_ e: AXUIElement) -> CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv = attr(e, kAXPositionAttribute), let sv = attr(e, kAXSizeAttribute) else { return nil }
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Aside-owned on-screen floating window (the popup). CG coordinates, top-left origin.
    func popupWindowFrame() -> CGRect? {
        guard let pid = app?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard layer > 0, let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.width >= 250 && r.width <= 1400 && r.height >= 50 && r.height <= 1000 { return r }
        }
        return nil
    }

    /// The popup's composer, only when all three hold: Aside is frontmost, the popup is Aside's focused window,
    /// and the text area inside the popup reports AXFocused. (Aside's app-level AXFocusedUIElement can point at the
    /// main window's composer even while the popup has focus, so it is never trusted on its own.)
    func focusedPopupTextArea() -> AXUIElement? {
        guard let app, app.isActive, let pf = popupWindowFrame() else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let fw = attr(ax, kAXFocusedWindowAttribute), let ff = frame(fw as! AXUIElement),
              abs(ff.minX - pf.minX) < 6, abs(ff.width - pf.width) < 6 else { return nil }
        var visited = 0
        func find(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
            visited += 1
            guard depth < 30, visited < 500 else { return nil }
            if (attr(e, kAXRoleAttribute) as? String) == "AXTextArea" || (attr(e, kAXRoleAttribute) as? String) == "AXTextField" {
                return (attr(e, kAXFocusedAttribute) as? Bool) == true ? e : nil
            }
            for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if let hit = find(c, depth + 1) { return hit } }
            return nil
        }
        return find(fw as! AXUIElement, 0)
    }

    /// One-line state dump for debugging popup detection.
    func diag() -> String {
        guard let app else { return "aside not running" }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var out = "active=\(app.isActive) popup=\(popupWindowFrame().map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none")"
        if let fe = attr(ax, kAXFocusedUIElementAttribute) {
            let el = fe as! AXUIElement
            out += " focused=\(attr(el, kAXRoleAttribute) as? String ?? "?")"
            if let w = attr(el, kAXWindowAttribute), let wf = frame(w as! AXUIElement) { out += " win=\(Int(wf.minX)),\(Int(wf.minY)) \(Int(wf.width))x\(Int(wf.height))" }
        } else { out += " focused=nil" }
        if let pid = Optional(app.processIdentifier), let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            let ws = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.map { w -> String in
                let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
                return "L\(w[kCGWindowLayer as String] as? Int ?? -1):\(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))"
            }
            out += " wins=[\(ws.joined(separator: " "))]"
        }
        return out
    }
    func axReport() -> String {
        guard let app else { return "no app" }
        func d(_ e: AXUIElement) -> String { "\(attr(e, kAXRoleAttribute) as? String ?? "?")/\(attr(e, kAXSubroleAttribute) as? String ?? "-") v='\((attr(e, kAXValueAttribute) as? String ?? "").prefix(24))' t='\((attr(e, kAXTitleAttribute) as? String ?? "").prefix(24))'" }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var o = "active=\(app.isActive)\n"
        o += "  app focused: " + ((attr(ax, kAXFocusedUIElementAttribute)).map { d($0 as! AXUIElement) } ?? "nil") + "\n"
        o += "  systemwide focused: " + ((attr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)).map { d($0 as! AXUIElement) } ?? "nil") + "\n"
        if let fw = attr(ax, kAXFocusedWindowAttribute) {
            let w = fw as! AXUIElement
            o += "  focused window: \(d(w)) frame=\(frame(w).map { "\($0)" } ?? "?")\n"
            o += "  window's focused el: " + ((attr(w, kAXFocusedUIElementAttribute)).map { d($0 as! AXUIElement) } ?? "nil") + "\n"
        } else { o += "  focused window: nil\n" }
        if let ws = attr(ax, kAXWindowsAttribute) as? [AXUIElement] { o += "  windows: " + ws.map { d($0) + " " + (frame($0).map { "\(Int($0.width))x\(Int($0.height))" } ?? "") }.joined(separator: " | ") }
        return o
    }
    func popupTree(maxDepth: Int = 18) -> String {
        guard let app, let pf = popupWindowFrame() else { return "no popup" }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let ws = attr(ax, kAXWindowsAttribute) as? [AXUIElement],
              let w = ws.first(where: { frame($0).map { abs($0.width - pf.width) < 4 } ?? false }) else { return "popup window not in AX" }
        var out: [String] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth <= maxDepth, out.count < 60 else { return }
            let role = attr(e, kAXRoleAttribute) as? String ?? "?"
            let v = (attr(e, kAXValueAttribute) as? String ?? "").prefix(30)
            let foc = (attr(e, kAXFocusedAttribute) as? Bool) == true ? " [FOCUSED]" : ""
            let names = (try? { var n: CFArray?; AXUIElementCopyAttributeNames(e, &n); return (n as? [String])?.count ?? 0 }()) ?? 0
            out.append(String(repeating: "  ", count: depth) + "\(role) v='\(v)'\(foc) attrs=\(names)")
            for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, depth + 1) }
        }
        walk(w, 0)
        return out.joined(separator: "\n")
    }
    func setManualAX() -> String {
        guard let app else { return "" }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        return "manual=\(AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue).rawValue) enhanced=\(AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue).rawValue)"
    }
    func pressShortcut() { let (_, sc) = Self.readShortcut(); if let sc { postHID(sc.key, sc.flags) } }

    func value(_ el: AXUIElement) -> String { (attr(el, kAXValueAttribute) as? String) ?? "" }

    /// Text currently in the popup's composer, ignoring the "Ask Aside" placeholder.
    func composerText(_ el: AXUIElement) -> String {
        let v = value(el).trimmingCharacters(in: .whitespacesAndNewlines)
        return v == "Ask Aside" ? "" : v
    }

    // MARK: event posting

    private let src = CGEventSource(stateID: .hidSystemState)

    private func postHID(_ key: CGKeyCode, _ flags: CGEventFlags) {
        let d = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)!; d.flags = flags
        let u = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)!; u.flags = flags
        d.post(tap: .cghidEventTap); usleep(15000); u.post(tap: .cghidEventTap)
    }

    private func postPid(_ key: CGKeyCode, _ flags: CGEventFlags = []) {
        guard let pid = app?.processIdentifier else { return }
        let d = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)!; d.flags = flags
        let u = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)!; u.flags = flags
        d.postToPid(pid); usleep(12000); u.postToPid(pid); usleep(25000)
    }

    private func typePid(_ text: String) {
        guard let pid = app?.processIdentifier else { return }
        let u16 = Array(text.utf16)
        var i = 0
        while i < u16.count {
            let ch = Array(u16[i..<min(i + 16, u16.count)])
            let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)!
            d.keyboardSetUnicodeString(stringLength: ch.count, unicodeString: ch)
            let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)!
            u.keyboardSetUnicodeString(stringLength: ch.count, unicodeString: ch)
            d.postToPid(pid); u.postToPid(pid); usleep(6000)
            i += 16
        }
    }

    private func waitFor(_ timeout: TimeInterval, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return cond()
    }

    // MARK: high-level steps

    enum OpenResult { case ready, notRunning, disabled, failed(String) }

    /// Opens (or refocuses) the popup and waits until its text area has keyboard focus.
    func open() async -> OpenResult {
        guard let app else { return .notRunning }
        if focusedPopupTextArea() != nil { return .ready }
        let (enabled, sc) = Self.readShortcut()
        guard enabled, let sc else { return .disabled }

        if popupWindowFrame() != nil {
            // Popup visible but not focused: bring Aside forward instead of toggling it closed.
            app.activate()
            if await waitFor(0.8, { self.focusedPopupTextArea() != nil }) { return .ready }
            // Still not focused: close it with the toggle, then reopen below.
            postHID(sc.key, sc.flags)
            _ = await waitFor(0.6, { self.popupWindowFrame() == nil })
        }
        postHID(sc.key, sc.flags)
        if await waitFor(1.5, { self.focusedPopupTextArea() != nil }) { return .ready }
        return .failed("popup did not take focus")
    }

    /// Types the text into the verified popup text area. Returns false if focus could not be proven.
    func fill(_ text: String) async -> Bool {
        guard let el = focusedPopupTextArea() else { return false }
        if !composerText(el).isEmpty { postPid(0, .maskCommand); postPid(51) } // replace leftover draft
        guard focusedPopupTextArea() != nil else { return false }
        typePid(text)
        let probe = String(text.prefix(24)).lowercased()
        return await waitFor(1.0, {
            guard let e = self.focusedPopupTextArea() else { return false }
            return self.composerText(e).lowercased().contains(probe)
        })
    }

    enum SubmitResult { case sent, alreadyGone, failed }

    /// Presses Return only if the popup still holds our text.
    func submit(expected text: String) async -> SubmitResult {
        guard let el = focusedPopupTextArea() else { return .alreadyGone }
        let probe = String(text.prefix(24)).lowercased()
        guard composerText(el).lowercased().contains(probe) else { return .alreadyGone }
        postPid(36)
        let ok = await waitFor(1.5, {
            guard let e = self.focusedPopupTextArea() else { return true } // popup changed state/closed
            return !self.composerText(e).lowercased().contains(probe)
        })
        return ok ? .sent : .failed
    }

    /// Clears our text and closes the popup (used on cancel).
    func clearAndClose() {
        guard focusedPopupTextArea() != nil else { return }
        postPid(0, .maskCommand); postPid(51); postPid(53)
    }
}

/// Starts an Aside task without any UI, through the supported `aside` CLI.
enum BackgroundDelivery {
    static let cli = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/aside").path

    static var available: Bool { FileManager.default.isExecutableFile(atPath: cli) }

    static func start(_ text: String) -> Bool {
        guard available else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = Settings.shared.newSessionArgs(text)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let logURL = Log.url.deletingLastPathComponent().appendingPathComponent("background-tasks.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: logURL)
        h?.seekToEndOfFile()
        h?.write("\n=== \(Date()) \(text)\n".data(using: .utf8)!)
        // Stream the CLI's output to the log and note the new session id (no polling; the pipe wakes us).
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        var sawID = false
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty else { fh.readabilityHandler = nil; return }
            h?.write(data)
            if !sawID, let str = String(data: data, encoding: .utf8), let r = str.range(of: "created new session: ") {
                sawID = true
                let id = str[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                Log.write("session created: \(id)")
            }
        }
        p.terminationHandler = { proc in Log.write("session task finished (exit \(proc.terminationStatus))") }
        do { try p.run(); Log.write("background task started pid=\(p.processIdentifier)"); return true }
        catch { Log.write("background task failed: \(error)"); return false }
    }
}
