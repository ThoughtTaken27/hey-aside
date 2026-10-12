import Foundation

/// School/task background is Aside's job (its own memory, skills and routines), so Hey Aside attaches nothing
/// extra to a request. Kept as a stub so the call sites stay simple.
enum Digest {
    static var enabled: Bool { false }
    nonisolated(unsafe) static var rootOverride: String?
    nonisolated static func relevant(_ s: String) -> Bool { false }
    static func text(now: Date = Date()) -> String? { nil }
}
