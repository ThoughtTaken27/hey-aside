import Foundation

/// Jarvis Live (a full-duplex realtime call) is not part of this release: it depended on an undocumented
/// realtime endpoint. This stub keeps the Controller's interface; `available` is always false, so every
/// conversation uses the regular on-device recognizer -> Aside -> spoken answer path.
final class LiveCall {
    enum Event {
        case ready
        case live
        case heard(String, final: Bool)
        case said(String, final: Bool)
        case working(Bool)
        case step(String)
        case error(String)
        case end(String)
        case tasks(Int)
    }
    var onAnnounce: ((String) -> Void)?
    var onEvent: ((Event) -> Void)?
    var silentTest = false
    private(set) var begun = false
    private(set) var everSpoke = false
    private(set) var remotePeak = 0.0
    var running: Bool { false }
    static var available: Bool { false }
    func prepare() {}
    func begin(text: String?, greet: String?) {}
    func speak(_ text: String) {}
    func setMuted(_ on: Bool) {}
    func stop() {}
}
