import AppKit
import Foundation
import ServiceManagement

/// Starts Hey Aside at login and relaunches it if it ever crashes.
///
/// A per-user LaunchAgent (not SMAppService) because launchd can restart the app after a crash:
/// KeepAlive.SuccessfulExit = false means "relaunch on any non-zero exit or signal", while Quit from the menu
/// (exit 0) stays quit until the next login. ThrottleInterval stops a crash loop from burning CPU.
enum LoginAgent {
    static let label = "app.heyaside.mac.agent"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }
    private static var domain: String { "gui/\(getuid())" }

    static func install() throws {
        let exe = Bundle.main.executableURL?.path ?? "\(NSHomeDirectory())/Applications/Hey Aside.app/Contents/MacOS/HeyAside"
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)
        // Files written by a process started from a quarantine-aware app get com.apple.quarantine,
        // and launchd refuses quarantined plists ("error 155"). Strip it from the plist and the app.
        removexattr(plistURL.path, "com.apple.quarantine", 0)
        removexattr(exe, "com.apple.quarantine", 0)
        // Retire the older SMAppService login item so the app never starts twice.
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        let st = launchctl(["bootstrap", domain, plistURL.path])
        Log.write("login agent installed (bootstrap status \(st))")
    }

    static func remove() {
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        Log.write("login agent removed")
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
}

enum SingleInstance {
    /// If another Hey Aside is already running, give it up to `wait` seconds to exit (hand-off), else quit quietly.
    static func ensure(wait: TimeInterval = 3) {
        let me = ProcessInfo.processInfo.processIdentifier
        func others() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "app.heyaside.mac")
                .filter { $0.processIdentifier != me && !$0.isTerminated }
        }
        let end = Date().addingTimeInterval(wait)
        while !others().isEmpty && Date() < end { usleep(200_000) }
        if !others().isEmpty { Log.write("another instance is running; exiting"); exit(0) }
    }
}

extension Log {
    /// Keeps logs small on an always-on app: rotate at 2 MB, keep one old copy.
    static func rotateIfNeeded() {
        let fm = FileManager.default
        for u in [url, url.deletingLastPathComponent().appendingPathComponent("background-tasks.log")] {
            guard let size = (try? fm.attributesOfItem(atPath: u.path)[.size]) as? Int, size > 2_000_000 else { continue }
            let old = u.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: u, to: old)
        }
    }
}
