import Foundation

/// Fast path for plain questions (Sep 26). Jev, through Aside Mobile's local `jev` command, decides in
/// about half a second whether a question needs nothing but general knowledge ("what's 17 times 23",
/// "who wrote Hamlet"). If so, the free text model answers in one or two sentences, about 1.5-2.5 s
/// end to end instead of a 20 s new Aside session. Anything about now, the user's own things, or doing
/// something is refused by rules before Jev is asked. Any doubt, error, or timeout returns nil and
/// the normal Aside path runs exactly as before.
enum FastPath {
    /// Homebrew node on Apple silicon or Intel (launch services do not inherit the shell PATH).
    static let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/node"
    /// Aside Phone's `tools/jev`. Default ~/.local/bin/jev (a symlink); override with `defaults write app.heyaside.mac jevPath -string <path>`.
    static var script: String { UserDefaults.standard.string(forKey: "jevPath") ?? NSHomeDirectory() + "/.local/bin/jev" }

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "fastPath") as? Bool ?? true
    }

    static var available: Bool {
        enabled && FileManager.default.isExecutableFile(atPath: node) && FileManager.default.fileExists(atPath: script)
    }

    static func answer(_ text: String, history: [(q: String, a: String)], timeout: TimeInterval = 7) async -> String? {
        guard available else { return nil }
        var args = [script, "quick", text]
        var histURL: URL?
        if !history.isEmpty {
            let arr = history.suffix(3).map { ["q": $0.q, "a": $0.a] }
            if let data = try? JSONSerialization.data(withJSONObject: arr) {
                let u = FileManager.default.temporaryDirectory.appendingPathComponent("heyaside-fast-\(UUID().uuidString).json")
                if (try? data.write(to: u, options: .atomic)) != nil { histURL = u; args += ["--history", u.path] }
            }
        }
        defer { if let u = histURL { try? FileManager.default.removeItem(at: u) } }
        let started = Date()
        let result: (Int32, Data) = await withCheckedContinuation { (c: CheckedContinuation<(Int32, Data), Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: node)
            p.arguments = args
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            let once = OnceFlag()
            p.terminationHandler = { proc in
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                if once.fire() { c.resume(returning: (proc.terminationStatus, d)) }
            }
            do { try p.run() } catch { if once.fire() { c.resume(returning: (-1, Data())) }; return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
                if once.fire() { c.resume(returning: (-2, Data())) }
            }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        guard result.0 == 0,
              let obj = try? JSONSerialization.jsonObject(with: result.1) as? [String: Any],
              obj["fast"] as? Bool == true,
              let a = (obj["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty
        else {
            Log.write("fast path: no (exit \(result.0), \(ms) ms)")
            return nil
        }
        Log.write("fast path: answered in \(ms) ms")
        return a
    }

    /// Sep 27: what Jarvis says the instant he hears you. `jev reply` either answers outright (mode "answer",
    /// same safety rules as `answer`), or writes the short specific line a person says before going off to do it
    /// (mode "ack"), or mid-task one honest progress line from the real steps (mode "progress").
    struct Reply { let mode: String; let say: String }
    static func reply(_ text: String, history: [(q: String, a: String)], busy: Bool, steps: [String] = [],
                      kind: String = "auto", timeout: TimeInterval = 4.5) async -> Reply? {
        guard available else { return nil }
        let body: [String: Any] = ["text": text, "history": history.suffix(3).map { ["q": $0.q, "a": $0.a] },
                                   "busy": busy, "steps": steps, "kind": kind]
        guard let input = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        let started = Date()
        let result: (Int32, Data) = await withCheckedContinuation { (c: CheckedContinuation<(Int32, Data), Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: node)
            p.arguments = [script, "reply"]
            let inPipe = Pipe(), outPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = FileHandle.nullDevice
            let once = OnceFlag()
            p.terminationHandler = { proc in
                let d = outPipe.fileHandleForReading.readDataToEndOfFile()
                if once.fire() { c.resume(returning: (proc.terminationStatus, d)) }
            }
            do { try p.run() } catch { if once.fire() { c.resume(returning: (-1, Data())) }; return }
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
                if once.fire() { c.resume(returning: (-2, Data())) }
            }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        guard result.0 == 0,
              let obj = try? JSONSerialization.jsonObject(with: result.1) as? [String: Any],
              let mode = obj["mode"] as? String,
              let say = (obj["say"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !say.isEmpty
        else {
            Log.write("reflex (\(kind)): nothing (exit \(result.0), \(ms) ms)")
            return nil
        }
        Log.write("reflex (\(kind)): \(mode) in \(ms) ms")
        return Reply(mode: mode, say: say)
    }
}
