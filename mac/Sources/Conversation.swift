import Foundation
import QuartzCore

/// Runs an Aside session through the `aside` CLI and returns its final answer.
enum AsideCLI {
    struct Result { var sessionID: String?; var answer: String; var error: String?; var exitCode: Int32 }

    /// Appended to voice requests so the first lines are speakable; long detail stays in the chat after a `---` line.
    /// Appended to voice turns. The spoken part must carry the real answer (Sep 24: Aside once said only
    /// "Here are the five I had saved" and put every item after the divider, so nothing useful was read aloud).
    static let voiceSuffix = "\n\n[Voice mode: your reply is read aloud in a British voice; I call you Jarvis. Be JARVIS: composed, precise, quietly witty. Call me \"sir\" now and then, not every reply. Dry British humor only when it fits, never on serious or school-critical answers. Lead with the actual answer, the specific names, times and numbers, in 2-6 short natural sentences under 90 words; no markdown; fold lists into sentences. Never open with only a lead-in like \"Here are the five\". If I'm just reacting or chatting (\"oh that's cool\", \"thanks\", \"nice\"), reply in one short natural line and don't use tools. Be discreet: this plays out loud and others may hear, so never volunteer sensitive details (immigration status, health, money, grades, private messages, passwords) unless I asked for that exact thing. You have my memory, history and skills, so use them and never claim you can't remember things. My words come from speech recognition, so read through mishearings (a name like \"Clint\" or \"Travis\" at the start means Jarvis; \"a side\" means Aside). Any tool title you write is shown to me on screen: make it 2-5 plain-English words like \"Checking your grades\", no file names or jargon. I have already said a short acknowledgement out loud, so never open with one or with a heads-up; start with the result. To set a reminder or timer, never use Aside routines or `say`: run `\"$HOME/Applications/Hey Aside.app/Contents/MacOS/HeyAside\" --remind \"<local time, e.g. 2026-09-27T18:00>\" \"<what I should hear, spoken naturally>\"` and tell me the time you set. Say numbers the way a person would: exact when I asked for a figure, rounded when it doesn't matter. Fuller detail can go after a line containing only ---.]"

    static func run(_ prompt: String, resume sessionID: String?) async -> Result {
        guard BackgroundDelivery.available else { return Result(sessionID: nil, answer: "", error: "aside CLI not found", exitCode: -1) }
        return await withCheckedContinuation { (c: CheckedContinuation<Result, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: BackgroundDelivery.cli)
            p.arguments = sessionID.map { ["session", "resume", $0, prompt] } ?? Settings.shared.newSessionArgs(prompt)
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:" + (env["PATH"] ?? "")
            p.environment = env
            p.standardInput = FileHandle.nullDevice
            let logURL = Log.url.deletingLastPathComponent().appendingPathComponent("background-tasks.log")
            if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
            let log = try? FileHandle(forWritingTo: logURL)
            log?.seekToEndOfFile()
            log?.write("\n=== \(Date()) \(sessionID.map { "[resume \($0)] " } ?? "")\(prompt)\n".data(using: .utf8)!)
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            let buf = LockedData()
            pipe.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                if d.isEmpty { fh.readabilityHandler = nil; return }
                buf.append(d); log?.write(d)
            }
            p.terminationHandler = { proc in
                // Drain anything left in the pipe before parsing.
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty { buf.append(rest); log?.write(rest) }
                try? log?.close()
                var r = parse(String(decoding: buf.data, as: UTF8.self))
                r.exitCode = proc.terminationStatus
                if r.error == nil && proc.terminationStatus != 0 { r.error = "exit \(proc.terminationStatus)" }
                Log.write("session \(r.sessionID ?? "?") done: exit \(proc.terminationStatus)\(r.error.map { ", error: \($0)" } ?? ""), answer \(r.answer.count) chars")
                c.resume(returning: r)
            }
            do { try p.run(); Log.write("session task started pid=\(p.processIdentifier)\(sessionID.map { " (resume \($0))" } ?? "")") }
            catch { c.resume(returning: Result(sessionID: nil, answer: "", error: error.localizedDescription, exitCode: -1)) }
        }
    }

    /// The CLI styles its output: dim = thinking/tool results/meta, green = tool calls, red = errors, plain = the answer.
    /// The final answer is the plain text after the last styled block.
    static func parse(_ raw: String) -> Result {
        var segs: [(style: String, text: String)] = []
        var style = "0"
        var cur = ""
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i] == "\u{1B}", raw.index(after: i) < raw.endIndex, raw[raw.index(after: i)] == "[",
               let m = raw[i...].firstIndex(of: "m"), raw.distance(from: i, to: m) < 12 {
                if !cur.isEmpty { segs.append((style, cur)); cur = "" }
                let code = String(raw[raw.index(i, offsetBy: 2)..<m])
                style = (code.isEmpty || code == "0") ? "0" : code
                i = raw.index(after: m)
                continue
            }
            cur.append(raw[i]); i = raw.index(after: i)
        }
        if !cur.isEmpty { segs.append((style, cur)) }

        var r = Result(sessionID: nil, answer: "", error: nil, exitCode: 0)
        for s in segs where s.style == "2" {
            for key in ["created new session: ", "continuing existing session: "] {
                if let rg = s.text.range(of: key) {
                    r.sessionID = String(s.text[rg.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
                }
            }
        }
        if let k = segs.firstIndex(where: { $0.style == "31" && $0.text.contains("Error") }) {
            let tail = segs[(k + 1)...].map { $0.text }.joined()
            r.error = String(tail.split(separator: "\n").first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
            if r.error?.isEmpty ?? true { r.error = "Aside error" }
        }
        let lastStyled = segs.lastIndex { $0.style != "0" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? -1
        r.answer = segs[(lastStyled + 1)...].filter { $0.style == "0" }.map { $0.text }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return r
    }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var d = Data()
    func append(_ x: Data) { lock.lock(); d.append(x); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return d }
}

/// Turns a chat answer into something pleasant to hear: the real answer, concise, never just a headline.
enum SpokenText {
    static func from(_ answer: String) -> String {
        var spoken = answer, detail: String? = nil
        if let r = answer.range(of: #"\n\s*---+\s*(\n|$)"#, options: .regularExpression) {
            spoken = String(answer[..<r.lowerBound]); detail = String(answer[r.upperBound...])
        }
        var s = clean(spoken)
        // Safety net: a lead-in ("Here are the five…", "I found three:") with the substance below the divider.
        if let detail, isLeadIn(s) {
            let items = keyItems(detail)
            if !items.isEmpty {
                s = s.trimmingCharacters(in: CharacterSet(charactersIn: ":. ")) + ". " + items.joined(separator: " ")
                return cap(s, maxSentences: 12, maxWords: 120)
            }
        }
        return cap(s, maxSentences: 7, maxWords: 110)
    }

    /// "This will take a few minutes, sir. I'll let you know." A long-task heads-up, the only interim line worth hearing.
    static func isHeadsUp(_ s: String) -> Bool {
        let t = clean(s)
        guard t.split(separator: " ").count <= 25 else { return false }
        return t.range(of: #"(?i)\b(few minutes|a minute|minutes|a while|a moment|let you know|get back to you|tell you when|report back|shortly)\b"#, options: .regularExpression) != nil
    }

    /// Short opener that promises content instead of giving it.
    static func isLeadIn(_ s: String) -> Bool {
        let words = s.split(separator: " ").count
        guard words <= 16 else { return false }
        if s.hasSuffix(":") { return true }
        return s.range(of: #"(?i)\b(here (are|is|'s)|here’s|below|the following|as follows|these are|i found|i've got|i have (the|your)|saved as|listed|breakdown|rundown|summary)\b"#,
                       options: .regularExpression) != nil
    }

    /// The lines worth hearing from a detail block: section headers + items, preferring lines with a time/date/"due".
    static func keyItems(_ detail: String) -> [String] {
        var out: [String] = []
        let lines = detail.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let isHeader: (String) -> Bool = { $0.hasPrefix("**") || $0.hasPrefix("#") || ($0.hasSuffix(":") && $0.count < 60) }
        let isItem: (String) -> Bool = { $0.range(of: #"^([-*+•]|\d+[.)])\s+"#, options: .regularExpression) != nil }
        let timed: (String) -> Bool = { $0.range(of: #"(?i)\b(due|by|at|until)\b.*\d|\d{1,2}(:\d{2})?\s?(am|pm)|\b(mon|tue|wed|thu|fri|sat|sun)\w*\b"#, options: .regularExpression) != nil }
        let items = lines.filter(isItem)
        // If several items say "due …", those are the real items; the rest are sub-notes.
        let hasDue: (String) -> Bool = { $0.range(of: #"(?i)\bdue\b"#, options: .regularExpression) != nil }
        let preferDue = items.filter(hasDue).count >= 2
        let preferTimed = !preferDue && items.filter(timed).count >= 2
        var words = 0
        for l in lines {
            if isHeader(l) {
                let h = clean(l).trimmingCharacters(in: CharacterSet(charactersIn: ":. "))
                if !h.isEmpty && words < 70 { out.append(h + ":"); words += h.split(separator: " ").count }
            } else if isItem(l) && (preferDue ? hasDue(l) : (!preferTimed || timed(l))) {
                var t = clean(l).trimmingCharacters(in: .whitespaces)
                if !t.hasSuffix(".") { t += "." }
                let w = t.split(separator: " ").count
                if words + w > 95 { break }
                out.append(t); words += w
            }
        }
        // Drop a trailing header with nothing after it.
        while let last = out.last, last.hasSuffix(":") { out.removeLast() }
        return out
    }

    static func clean(_ text: String) -> String {
        var s = text
        let rules: [(String, String)] = [
            (#"```[\s\S]*?```"#, " "), (#"`([^`]*)`"#, "$1"), (#"!\[[^\]]*\]\([^)]*\)"#, ""), (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
            (#"https?://\S+"#, "the link"), (#"(?m)^\s{0,3}#{1,6}\s*"#, ""), (#"(?m)^\s*[-*+•]\s+"#, ""), (#"(?m)^\s*\d+[.)]\s+"#, ""),
            (#"\*\*|__|\*|_(?=\S)|(?<=\S)_"#, ""), (#"\|"#, ", "), (#"\s*\n\s*\n\s*"#, ". "), (#"\s*\n\s*"#, " "),
            (#"\.\s*\.(\s|$)"#, ".$1"), (#":\s*\."#, ":"), (#"\s{2,}"#, " "),
        ]
        for (p, t) in rules { s = s.replacingOccurrences(of: p, with: t, options: .regularExpression) }
        return s.replacingOccurrences(of: "\u{2014}", with: ", ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Concise, not clipped mid-thought: whole sentences only, up to the limits.
    static func cap(_ s: String, maxSentences: Int, maxWords: Int) -> String {
        var sentences: [String] = []
        s.enumerateSubstrings(in: s.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let t = sub?.trimmingCharacters(in: .whitespaces), !t.isEmpty { sentences.append(t) }
        }
        var out: [String] = [], words = 0
        for t in sentences {
            let w = t.split(separator: " ").count
            if !out.isEmpty && (out.count >= maxSentences || words + w > maxWords) { break }
            out.append(t); words += w
        }
        let joined = out.joined(separator: " ")
        return out.count < sentences.count ? joined + " The rest is in Aside." : joined
    }
}

// MARK: - Live agent run (streaming)

/// One running `aside` CLI process whose output is parsed live:
/// steps (tool calls with their human titles) and answer blocks are delivered as they happen.
@MainActor
final class AgentRun {
    enum Event { case session(String), step(String), toolWithoutTitle, text(String), error(String) }

    private let process = Process()
    private let buf = LockedData()
    private var emitted = Set<Int>()
    private(set) var isRunning = false
    let startedAt = CACurrentMediaTime()
    var onEvent: ((Event) -> Void)?
    var onExit: ((Int32) -> Void)?

    init(prompt: String, resume sessionID: String?) {
        process.executableURL = URL(fileURLWithPath: BackgroundDelivery.cli)
        process.arguments = sessionID.map { ["session", "resume", $0, prompt] } ?? Settings.shared.newSessionArgs(prompt)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:" + (env["PATH"] ?? "")
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let logURL = Log.url.deletingLastPathComponent().appendingPathComponent("background-tasks.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let log = try? FileHandle(forWritingTo: logURL)
        log?.seekToEndOfFile()
        log?.write("\n=== \(Date()) \(sessionID.map { "[resume \($0)] " } ?? "")\(prompt)\n".data(using: .utf8)!)
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        let buf = self.buf
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; return }
            buf.append(d); log?.write(d)
            DispatchQueue.main.async { self?.scan(final: false) }
        }
        process.terminationHandler = { [weak self] p in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty { buf.append(rest); log?.write(rest) }
            try? log?.close()
            let code = p.terminationStatus
            DispatchQueue.main.async {
                guard let self else { return }
                self.scan(final: true)
                self.isRunning = false
                self.onExit?(code)
            }
        }
    }

    func start() -> Bool {
        do { try process.run(); isRunning = true; Log.write("agent run started pid=\(process.processIdentifier)"); return true }
        catch { Log.write("agent run failed to start: \(error)"); return false }
    }

    func terminate() { if process.isRunning { process.terminate() } }

    /// Re-parses the buffer and emits events not yet emitted (keyed by byte offset, which never changes as output grows).
    ///
    /// The CLI's output, as it really looks (captured Sep 24):
    ///   ESC[2m created new session: X ESC[0m                      dim = meta, thinking, tool results
    ///   ESC[32m read_file ESC[0m ( path: ESC[32m'/…/SKILL.md' ESC[39m ) ESC[2m [call_…]
    ///   ESC[32m repl ESC[0m ( code: ESC[32m'…' ESC[39m, title: ESC[32m'Opening Schoology' ESC[39m )
    ///   plain text = Aside talking to you
    /// Argument values are ALSO green (syntax highlighting), so a tool call is only "green name, ESC[0m, then '('".
    private func scan(final: Bool) {
        let raw = String(decoding: buf.data, as: UTF8.self)
        let calls = AgentRun.toolCalls(in: raw, final: final)
        for c in calls where !emitted.contains(c.start) {
            guard c.complete else { continue }
            emitted.insert(c.start)
            if let title = AgentRun.stepTitle(tool: c.name, args: c.args) { onEvent?(.step(title)) }
            else { onEvent?(.toolWithoutTitle) }
        }
        // Everything outside tool calls: dim = meta/thinking/results; plain = what Aside says; red "Error" = failure.
        let segs = AgentRun.segments(raw).filter { seg in !calls.contains { seg.offset >= $0.start && seg.offset < $0.end } }
        var i = 0
        while i < segs.count {
            let sg = segs[i]
            if sg.style == "2" {
                for key in ["created new session: ", "continuing existing session: "] {
                    if let r = sg.text.range(of: key), !emitted.contains(sg.offset) {
                        emitted.insert(sg.offset)
                        onEvent?(.session(String(sg.text[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })))
                    }
                }
                i += 1
            } else if sg.style == "31" && sg.text.contains("Error") {
                var tail = ""; var j = i + 1
                while j < segs.count, !tail.contains("\n") { tail += segs[j].text; j += 1 }
                if (tail.contains("\n") || final) && !emitted.contains(sg.offset) {
                    emitted.insert(sg.offset)
                    onEvent?(.error(String(tail.split(separator: "\n").first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))))
                }
                i = j
            } else if sg.style == "0" {
                var text = ""; var j = i
                while j < segs.count, segs[j].style == "0" { text += segs[j].text; j += 1 }
                // Closed = something came after it (a tool call, thinking, ...) or the run ended; never emit half an answer.
                let endOffset = j < segs.count ? segs[j].offset : raw.utf8.count
                let closed = j < segs.count || final || calls.contains { $0.start >= endOffset }
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if closed && !t.isEmpty && t != "\u{2022}" && !emitted.contains(sg.offset) {
                    emitted.insert(sg.offset)
                    onEvent?(.text(t))
                }
                i = j
            } else { i += 1 }
        }
    }

    struct ToolCall { let name: String; let args: String; let start: Int; let end: Int; let complete: Bool }

    /// Tool calls with their ANSI-stripped arguments, as UTF-8 byte ranges. A call ends at its dim "[call_...]" tag or a blank line.
    nonisolated static func toolCalls(in raw: String, final: Bool) -> [ToolCall] {
        let ns = raw as NSString
        guard let re = try? NSRegularExpression(pattern: "\\u001B\\[32m([A-Za-z_][A-Za-z0-9_]*)\\u001B\\[0m\\(") else { return [] }
        var out: [ToolCall] = []
        for m in re.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            // Must start a line (argument strings never do).
            if m.range.location > 0 {
                let prev = ns.substring(with: NSRange(location: m.range.location - 1, length: 1))
                if prev != "\n" { continue }
            }
            let afterU16 = m.range.location + m.range.length
            let rest = ns.substring(from: afterU16)
            var endLocal: String.Index? = nil
            if let r = rest.range(of: "\u{1B}[2m") { endLocal = r.lowerBound }
            if let r = rest.range(of: "\n\n") { endLocal = min(endLocal ?? r.lowerBound, r.lowerBound) }
            let argsRaw = endLocal.map { String(rest[..<$0]) } ?? rest
            let args = argsRaw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            let startByte = ns.substring(to: m.range.location).utf8.count
            let endByte = ns.substring(to: afterU16).utf8.count + argsRaw.utf8.count
            out.append(ToolCall(name: ns.substring(with: m.range(at: 1)), args: args, start: startByte, end: endByte,
                                complete: endLocal != nil || final))
        }
        return out
    }

    /// Styled segments with their UTF-8 offsets. Resets (0, 39 default color, 22 normal intensity) all mean plain.
    nonisolated static func segments(_ raw: String) -> [(style: String, text: String, offset: Int)] {
        var segs: [(style: String, text: String, offset: Int)] = []
        var style = "0", cur = "", curStart = 0, pos = 0
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i] == "\u{1B}", raw.index(after: i) < raw.endIndex, raw[raw.index(after: i)] == "[",
               let m = raw[i...].firstIndex(of: "m"), raw.distance(from: i, to: m) < 12 {
                if !cur.isEmpty { segs.append((style, cur, curStart)); cur = "" }
                let code = String(raw[raw.index(i, offsetBy: 2)..<m])
                style = ["", "0", "39", "22", "49"].contains(code) ? "0" : code
                pos += String(raw[i...m]).utf8.count
                i = raw.index(after: m)
                continue
            }
            if cur.isEmpty { curStart = pos }
            cur.append(raw[i]); pos += String(raw[i]).utf8.count; i = raw.index(after: i)
        }
        if !cur.isEmpty { segs.append((style, cur, curStart)) }
        return segs
    }

    /// A short human step for the orb, or nil if there's nothing worth showing (the orb keeps the previous step).
    /// "Open Claude usage settings" -> "Opening Claude usage settings"; "List state.db tables" -> "Listing tables".
    nonisolated static func polishStep(_ raw: String) -> String {
        var words = raw.split(separator: " ").map(String.init)
            .filter { !($0.contains(".") && $0.count > 3 && !$0.hasSuffix(".")) && !$0.contains("/") && !$0.contains("_") }
        guard let first = words.first else { return raw }
        let irregular = ["Get": "Getting", "Set": "Setting", "Run": "Running", "Put": "Putting", "Plan": "Planning", "Scan": "Scanning",
                         "Stop": "Stopping", "Shop": "Shopping", "Map": "Mapping", "Sum": "Summing", "Tap": "Tapping", "Log": "Logging",
                         "Use": "Using", "Save": "Saving", "Close": "Closing", "Write": "Writing", "Compare": "Comparing", "Locate": "Locating",
                         "Aggregate": "Aggregating", "Calculate": "Calculating", "Compute": "Computing", "Update": "Updating", "Create": "Creating",
                         "Retrieve": "Retrieving", "Explore": "Exploring", "Examine": "Examining", "Parse": "Parsing", "Type": "Typing", "Draft": "Drafting",
                         "Review": "Reviewing", "Move": "Moving", "Prepare": "Preparing", "Organize": "Organizing", "Capture": "Capturing", "Dismiss": "Dismissing"]
        let regular = ["Open", "Check", "Inspect", "List", "Find", "Verify", "Search", "Read", "Load", "Look", "Collect", "Pull", "Fetch", "Break", "Click",
                       "Fill", "Confirm", "Extract", "Count", "Scroll", "Navigate", "Sort", "Filter", "Test", "Try", "Search", "Summarize", "Add",
                       "Select", "Download", "Show", "Grab", "Visit", "Switch", "Start", "Build", "Match", "Cross-check", "Double-check", "Refresh",
                       "Attach", "Send", "Post", "Query", "Browse", "Wait", "Watch", "Rescan", "Re-read", "Recheck", "Tally", "Sign", "Log", "Pick", "Go", "Look up"]
        if let g = irregular[first] { words[0] = g }
        else if regular.contains(first) { words[0] = first + "ing" }
        if words.count < 2 { return raw }
        return words.joined(separator: " ")
    }

    nonisolated static func stepTitle(tool: String, args: String) -> String? {
        func clip(_ t: String) -> String {
            let one = polishStep(t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces))
            return one.count > 46 ? String(one.prefix(45)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : one
        }
        if let r = args.range(of: #"title:\s*['"]([^'"]{2,120})['"]"#, options: .regularExpression) {
            let m = String(args[r])
            if let q = m.firstIndex(where: { $0 == "'" || $0 == "\"" }) { return clip(String(m[m.index(after: q)...].dropLast())) }
        }
        // Skills: ".../skills/user/daily-planner/SKILL.md" -> "Using your Daily planner skill"
        if let r = args.range(of: #"skills/(?:user|builtin)/(?:site-specific/)?([a-z0-9-]+)"#, options: .regularExpression) {
            let name = String(args[r]).split(separator: "/").last.map(String.init) ?? ""
            let words = name.split(separator: "-").map(String.init)
            let pretty = words.enumerated().map { $0.offset == 0 ? $0.element.prefix(1).uppercased() + $0.element.dropFirst() : $0.element }.joined(separator: " ")
            return clip("Using your \(pretty) skill")
        }
        let known: [String: String] = [
            "get_time": "Checking the time", "websearch": "Searching the web", "WebSearch": "Searching the web",
            "WebFetch": "Reading a web page", "history_search": "Checking your history", "history_read": "Checking your history",
            "memory_search": "Checking what I remember", "subagent": "Bringing in a helper", "subagent_wait": "Waiting on a helper",
            "Bash": "Running a quick command", "read_file": "Reading notes", "write_file": "Saving notes", "edit_file": "Updating notes",
            "write_todos": "Planning the steps", "notification": "Sending you a notification",
        ]
        if let k = known[tool] {
            if tool == "read_file", args.contains("/memory/") { return "Checking what I remember" }
            return k
        }
        return nil
    }

    // MARK: control commands on a session (short-lived CLI calls)

    nonisolated static func control(_ args: [String], timeout: TimeInterval = 20) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: BackgroundDelivery.cli)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
            let once = OnceFlag()
            p.terminationHandler = { proc in if once.fire() { c.resume(returning: proc.terminationStatus == 0) } }
            do { try p.run() } catch { if once.fire() { c.resume(returning: false) }; return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
                if once.fire() { Log.write("aside \(args.prefix(2).joined(separator: " ")) timed out after \(Int(timeout)) s"); c.resume(returning: false) }
            }
        }
    }

    /// Status from `aside session list`: "running", "idle", ... or nil if the session doesn't exist; "unknown" when the
    /// CLI failed or was slow (never treated as vanished).
    /// Sep 30: the list outgrew the 64 KB pipe buffer (94 KB), and reading it only after exit deadlocked both sides, so a
    /// hung copy piled up every 20 s (23 found after 13 h; ~355 on Sep 26). The pipe is now drained while it runs.
    nonisolated static func status(of sessionID: String, timeout: TimeInterval = 10) async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: BackgroundDelivery.cli)
            p.arguments = ["session", "list"]
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            let buf = LockedData()
            pipe.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                if d.isEmpty { fh.readabilityHandler = nil } else { buf.append(d) }
            }
            let once = OnceFlag()
            p.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty { buf.append(rest) }
                let out = String(decoding: buf.data, as: UTF8.self)
                let line = out.split(separator: "\n").first { $0.contains(sessionID) }
                if once.fire() { c.resume(returning: line.map { String($0.split(separator: " ", omittingEmptySubsequences: true).dropFirst().first ?? "") }) }
            }
            do { try p.run() } catch { if once.fire() { c.resume(returning: "unknown") }; return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
                if once.fire() { Log.write("watch: session list timed out after \(Int(timeout)) s"); c.resume(returning: "unknown") }
            }
        }
    }
}

// MARK: - What you meant when you talked while Aside was working

enum Intent: Equatable { case stop, status, steer, queue, endConversation }

enum Router {
    /// Pure disfluency ("You know.", "Um.", "Hmm") is room noise or a half-start, not a turn (Sep 25: "You know." got a reply).
    nonisolated static func isNoise(_ raw: String) -> Bool {
        let t = raw.lowercased().replacingOccurrences(of: #"[^a-z' ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        if t.isEmpty { return true }
        let filler: Set<String> = ["um", "umm", "uh", "uhh", "hmm", "hm", "mm", "mhm", "ah", "oh", "er", "erm", "like", "so", "you know", "i mean", "well", "the", "a", "and", "but"]
        if filler.contains(t) { return true }
        return t.split(separator: " ").allSatisfy { ["um", "umm", "uh", "uhh", "hmm", "hm", "mm", "ah", "er", "erm", "you", "know", "like", "so", "i", "mean", "well"].contains(String($0)) }
    }

    /// Listener feedback ("yeah", "mm-hmm", "okay, right") said while Jarvis talks: support, not a request.
    nonisolated static func isBackchannel(_ raw: String) -> Bool {
        let t = raw.lowercased().replacingOccurrences(of: #"[^a-z' ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        let words = Set(["yeah", "yes", "yep", "yup", "ok", "okay", "right", "mm", "mhm", "mmhmm", "hmm", "uh", "huh", "uhhuh", "um",
                         "got", "it", "i", "see", "sure", "alright", "true", "nice", "cool", "wow", "oh", "ah", "exactly", "totally", "gotcha", "makes", "sense"])
        let w = t.split(separator: " ").map(String.init)
        return !w.isEmpty && w.count <= 4 && w.allSatisfy { words.contains($0) }
    }

    nonisolated static func intent(_ raw: String, agentBusy: Bool) -> Intent {
        let t = raw.lowercased().replacingOccurrences(of: #"[^a-z' ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        let words = t.split(separator: " ").count
        func has(_ list: [String]) -> Bool { list.contains { t.contains($0) } }
        func starts(_ list: [String]) -> Bool { list.contains { t == $0 || t.hasPrefix($0 + " ") } }
        let ends = ["bye", "goodbye", "that's all", "thats all", "that's it", "thats it", "we're done", "were done", "stop listening",
                    "thanks that's all", "thanks that's it", "i'm good", "im good", "all good", "no thanks", "no thank you", "nothing else",
                    "that'll be all", "thatll be all", "that will be all", "thanks jarvis that's all", "goodnight", "good night"]
        if words <= 5 && (ends.contains(t) || starts(["bye", "goodbye", "that's all", "thats all", "that'll be all", "that will be all", "stop listening", "nothing else", "goodnight", "good night"])) { return .endConversation }
        // Sep 29: "thanks, bye", "okay see you later", "night night, jarvis" end it too.
        if words <= 6 && ["bye", "goodbye", "good night", "goodnight", "see you", "see ya", "see you later", "talk to you later", "catch you later", "bye jarvis", "goodnight jarvis", "good night jarvis", "night night", "bye bye"].contains(where: { t.hasSuffix(" " + $0) }) { return .endConversation }
        if !agentBusy {
            // "thanks", "oh that's cool", "no" get a brief reply from Aside (Sep 25), not a canned goodbye.
            return .queue
        }
        if words <= 5 && starts(["stop", "cancel", "abort", "never mind", "nevermind", "forget it", "hold on stop", "stop that", "cancel that"]) { return .stop }
        if has(["what are you doing", "what's happening", "whats happening", "how's it going", "hows it going", "how is it going", "status",
                "are you done", "almost done", "how long", "what's taking", "whats taking", "where are you at", "what are you up to",
                "any progress", "how far", "still working", "what's going on", "whats going on"]) { return .status }
        if starts(["actually", "instead", "wait", "no", "change", "don't", "dont", "do not", "switch", "rather", "scratch that", "make it", "not",
                   "just", "only", "skip", "forget", "never mind the", "you don't have to", "you dont have to"]) { return .steer }
        // "Can you just ...", "just check your memories", "don't bother ...", "quickly ..." redirect the current work.
        if has(["can you just", "could you just", "just tell me", "just check", "just use", "don't bother", "dont bother", "no need to",
                "you don't have to", "you dont have to", "instead", "quickly", "really quick", "skip that", "don't check", "dont check"]) { return .steer }
        return .queue
    }
}

/// The only canned lines left (Sep 25: no "On it"/"Got it" fillers; the orb shows it heard you, Aside's answer is the reply).
/// These answer a direct command, so a short line is the real output. Rotated so it never sounds like a loop.
enum Acks {
    static let stopped = ["Stopped, sir.", "Done, I've stopped.", "Stopping there."]
    static let summoned = ["Sir?", "Yes, sir?", "At your service.", "Go ahead, sir.", "I'm listening.", "What do you need, sir?"]
    static let summonedMorning = ["Morning, sir.", "Good morning, sir."]
    static let summonedEvening = ["Evening, sir.", "Good evening, sir."]
    static let summonedLate = ["Still up, sir?", "Burning the midnight oil, sir?"]
    /// Sep 27: a bare "Hey Jarvis" gets a varied, time-aware reply, like a person looking up. All pre-cached.
    static func summonedNow(_ d: Date = Date()) -> String {
        let h = Calendar.current.component(.hour, from: d)
        let timed: [String] = (5..<11).contains(h) ? summonedMorning : (17..<22).contains(h) ? summonedEvening : (h >= 23 || h < 4) ? summonedLate : []
        if !timed.isEmpty && Double.random(in: 0..<1) < 0.35 { return pick(timed) }
        return pick(summoned)
    }
    static let signOff = ["Very good, sir.", "Of course, sir.", "Until later, sir."]
    static let goodnight = ["Goodnight, sir.", "Sleep well, sir."]
    static let carryOn = ["I'll carry on and let you know, sir."]
    static var all: [String] { summoned + summonedMorning + summonedEvening + summonedLate + stopped + signOff + goodnight + carryOn }
    private nonisolated(unsafe) static var last: [String: String] = [:]
    /// Random pick that never repeats the previous line from the same set.
    static func pick(_ set: [String]) -> String {
        let key = set.first ?? ""
        let options = set.count > 1 ? set.filter { $0 != last[key] } : set
        let p = options.randomElement() ?? ""
        last[key] = p
        return p
    }
}
