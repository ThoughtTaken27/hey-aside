import AppKit
import Combine
import QuartzCore
import SwiftUI

// Jarvis in the Dynamic Island (Sep 28). Hey Aside draws its own island, matched to Vorssaint's so the two read as
// one surface: same flat-top silhouette with concave shoulders, same pure black, same camera/menu-bar box, and the same
// per-axis spring tuning. It blooms out of Vorssaint's resting island and retracts back into it. Nothing of Vorssaint
// is modified, so Vorssaint keeps updating normally; we only read two of its preferences.
//
// v2 (Sep 28, "all about the little details"), after DynamicNotch, DynamicNotchKit, Atoll and boring.notch:
// - The window server does the motion. Springs are simulated once per change and handed to Core Animation as keyframes
//   (the silhouette, its shadow, the content mask, the rim, the glow), so no SwiftUI view re-renders per frame.
//   Voice bars, glow and rim take the voice level at 30 Hz and the render server interpolates between samples.
// - Content unfolds out of the camera instead of fading: blur + squash toward the notch (DynamicNotch's insertion),
//   wings squeeze in toward the camera on the way out (DynamicNotchKit).
// - SF Pro, the system face Vorssaint and the real Dynamic Island use.
// - Hovering the island swells it slightly with a trackpad tick, and turns the right wing into the mic toggle.
// - While Jarvis is up he owns the notch: hovering near it brings out his mic button, and Vorssaint's island (which opens
//   from a tracking area on its own window) stays closed underneath until he retracts.
//
// v3 (Sep 28, spacing/type/placement pass):
// - One alignment line. The orb's left edge, the words' left edge and (mirrored) the right indicator's edge all sit
//   `inset` in from the visible body, so the island reads as one composed object instead of three floating parts.
// - Icons at boring.notch's closed-notch size (bar height - 12 = 18 pt), centered in the menu-bar strip.
// - Words left-aligned under the orb at 13 pt (DynamicNotchKit's expanded inset: ~15 pt sides and bottom). Jarvis's
//   words in medium, yours in regular, hints and working steps dimmed: who is talking reads from the type alone.
// - Widths snap to three sizes instead of growing word by word; the countdown and its esc key live in the right wing.

enum HUDStyle: String, CaseIterable {
    case island, orb
    var title: String { self == .island ? "Dynamic Island" : "Floating Orb" }
}

/// Read-only look at Vorssaint (never written): is its island up, and does it open on hover.
enum Vorssaint {
    static let bundleID = "com.vorssaint.utils"
    private static var prefs: UserDefaults? { UserDefaults(suiteName: bundleID) }
    static var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    static var islandOn: Bool { running && (prefs?.object(forKey: "notchEnabled") as? Bool ?? true) }
    static var opensOnHover: Bool { islandOn && (prefs?.object(forKey: "notchOpenOnHover") as? Bool ?? true) }

    /// Width of Vorssaint's island while it rests in the menu-bar strip (at rest its panel is exactly the island; its
    /// activities widen it, e.g. 257 for a timer, up to 329 for agents). Window bounds only: no screen recording.
    static func restingWidth(near midX: CGFloat, stripHeight: CGFloat) -> CGFloat? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        var widest: CGFloat?
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid {
            guard let d = w[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: d),
                  b.minY <= 1, b.height <= stripHeight + 4, abs(b.midX - midX) < 3 else { continue }
            widest = max(widest ?? 0, b.width)
        }
        return widest
    }

    /// Vorssaint's camera box on this screen, from the narrowest island it has shown here (its resting one, 88 pt of
    /// wings around the camera). Remembered per screen size, so a restart during a Vorssaint activity keeps it. Only a
    /// width close to its formula counts (`estimate`: 180/32 of the bar; measured 180 on a 30 pt bar), so an activity
    /// that is up the whole time (288 wide with music) is never taken for the resting island.
    static func restingCamera(screen: CGSize, seen width: CGFloat, estimate: CGFloat) -> CGFloat? {
        let key = "vorssaintRest.\(Int(screen.width))x\(Int(screen.height))"
        let d = UserDefaults.standard
        var rest = d.double(forKey: key)
        if rest > 0, !(estimate - 4...estimate + 16).contains(CGFloat(rest) - 88) { rest = 0; d.removeObject(forKey: key) }
        let cam = width - 88
        if (estimate - 4...estimate + 16).contains(cam), rest == 0 || width < rest - 0.5 { rest = Double(width); d.set(rest, forKey: key) }
        return rest > 0 ? CGFloat(rest) - 88 : nil
    }
}

/// The camera box Vorssaint's island rests in, measured the way it measures it: a real notch where there is one,
/// otherwise a simulated cutout 180/32 of the menu bar's height wide, as tall as the bar.
struct IslandGeometry: Equatable {
    var screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    var cameraWidth: CGFloat = 169
    var height: CGFloat = 30
    var notched = false
    /// Vorssaint's resting island right now, if it is up: Jarvis is never narrower, so none of it shows around him.
    var vorssaintWidth: CGFloat = 0

    static func current() -> IslandGeometry {
        let screens = NSScreen.screens
        func builtIn(_ s: NSScreen) -> Bool {
            let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return CGDisplayIsBuiltin(id) != 0
        }
        guard let s = screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? screens.first(where: builtIn) ?? screens.first else { return IslandGeometry() }
        var g = IslandGeometry()
        g.screen = s.frame
        let measured = s.frame.maxY - s.visibleFrame.maxY
        let bar = min(64, max(16, measured >= 16 ? measured : NSStatusBar.system.thickness))
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            g.notched = true
            g.cameraWidth = max(0, r.minX - l.maxX)
            g.height = min(s.safeAreaInsets.top, 64)
        } else {
            g.cameraWidth = 180 * bar / 32
            g.height = bar
        }
        g.cameraWidth = min(g.cameraWidth, s.frame.width * 0.7)
        g.vorssaintWidth = Vorssaint.restingWidth(near: s.frame.midX, stripHeight: g.height) ?? 0
        // Sep 29: Vorssaint's camera box on a plain display is not quite 180/32 of the bar here (its resting island is
        // 268 = camera 180 + two 44 pt wings on a 30 pt bar). Its narrowest width is its resting one (activities and
        // notices only widen it), so read the camera back from that and remember it per screen.
        if !g.notched, let cam = Vorssaint.restingCamera(screen: s.frame.size, seen: g.vorssaintWidth, estimate: g.cameraWidth) { g.cameraWidth = cam }
        return g
    }

    var resting: CGSize { CGSize(width: cameraWidth, height: height) }
    // Sep 29: Jarvis only ever takes one of Vorssaint's own three sizes (read from its NotchGeometry), never a width
    // of his own, so the two islands are one object: same length, same width, same corners.
    /// Resting strip: camera + two 44 pt wings (Vorssaint's `restingSize`), or Vorssaint's live width if it is wider.
    var compactWidth: CGFloat { min(screen.width - 24, max(cameraWidth + 2 * 44, vorssaintWidth)) }
    /// Notice strip, for a line of words beside the orb: camera + 160 (Vorssaint's `notice`), same height as the strip.
    var noticeWidth: CGFloat { min(screen.width - 24, max(cameraWidth + 160, vorssaintWidth)) }
    /// Peek card, for words that need a row below: max(camera + 110, 340) wide, strip + 62 tall (Vorssaint's `peek`).
    var peekWidth: CGFloat { min(screen.width - 24, max(cameraWidth + 110, 340, vorssaintWidth)) }
    var peekHeight: CGFloat { height + 10 + 52 }
    static func shoulder(_ h: CGFloat) -> CGFloat { min(14, h * 0.19) }
    /// The island's one alignment line, from its outer edge. In the strip it is Vorssaint's compact edge gap (5 pt
    /// past the shoulder); with words below it eases out to 10 pt so text sits clear of the rounder corners.
    static func inset(_ h: CGFloat) -> CGFloat { shoulder(h) + 5 + 5 * min(1, max(0, (h - 32) / 20)) }
    /// Icon size in the strip (Vorssaint: strip height less a 5 pt gap above and below, at most 20).
    static func icon(_ h: CGFloat) -> CGFloat { max(14, min(20, h - 10)) }
    /// Right-wing icon center, from the island's center.
    static func wingOffset(width: CGFloat, height: CGFloat, strip: CGFloat) -> CGFloat { width / 2 - inset(height) - icon(strip) / 2 }

    /// Flat top flush with the screen edge, concave shoulders, soft bottom corners: the camera-housing silhouette
    /// Vorssaint uses, so where the two surfaces meet there is no seam. Top-left origin. Always the same element
    /// count, so Core Animation can interpolate between any two sizes.
    static func path(_ size: CGSize, x: CGFloat = 0) -> CGPath {
        let w = max(0, size.width), h = max(0, size.height)
        let s = shoulder(h)
        let b = max(0, min(min(28, h * 0.34), h / 2, (w - s * 2) / 2))
        let k: CGFloat = 0.55228475
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x, y: 0))
        p.addLine(to: CGPoint(x: x + w, y: 0))
        p.addCurve(to: CGPoint(x: x + w - s, y: s), control1: CGPoint(x: x + w - s * k, y: 0), control2: CGPoint(x: x + w - s, y: s * (1 - k)))
        p.addLine(to: CGPoint(x: x + w - s, y: h - b))
        p.addCurve(to: CGPoint(x: x + w - s - b, y: h), control1: CGPoint(x: x + w - s, y: h - b * (1 - k)), control2: CGPoint(x: x + w - s - b * (1 - k), y: h))
        p.addLine(to: CGPoint(x: x + s + b, y: h))
        p.addCurve(to: CGPoint(x: x + s, y: h - b), control1: CGPoint(x: x + s + b * (1 - k), y: h), control2: CGPoint(x: x + s, y: h - b * (1 - k)))
        p.addLine(to: CGPoint(x: x + s, y: s))
        p.addCurve(to: CGPoint(x: x, y: 0), control1: CGPoint(x: x + s, y: s * (1 - k)), control2: CGPoint(x: x + s * k, y: 0))
        p.closeSubpath()
        return p
    }
}

// MARK: - Motion

/// Width and height on separate springs with Vorssaint's tuning: sides grow with a little bounce (width 0.44 s / 0.25,
/// height 0.38 s / 0.22), shrink with none (0.30 s, 0.26 s), and never overshoot by more than 12 pt. The trajectory is
/// simulated once per change and played by Core Animation; a change mid-flight starts from the current size and speed.
final class IslandMotion {
    static let fps = 60.0
    private(set) var target: CGSize = .zero
    private var track: [CGSize] = [.zero]
    private var start = CACurrentMediaTime()
    /// Hands a trajectory (sampled at `fps`) to the layers.
    var play: (([CGSize]) -> Void)?

    static func spring(_ duration: Double, _ bounce: Double, travel: CGFloat) -> (k: Double, c: Double) {
        var b = bounce
        if b > 0, travel > 0 {
            let z = 1 - b
            if Double(travel) * exp(-Double.pi * z / (1 - z * z).squareRoot()) > 12 {
                let share = log(12 / Double(travel))
                b = 1 + share / (Double.pi * Double.pi + share * share).squareRoot()
            }
        }
        return (pow(2 * Double.pi / duration, 2), 4 * Double.pi * (1 - b) / duration)
    }

    static func simulate(from s0: CGSize, velocity v0: CGSize, to t: CGSize) -> [CGSize] {
        let dw = t.width - s0.width, dh = t.height - s0.height
        let sw = dw > 0 ? spring(0.44, 0.25, travel: dw) : spring(0.30, 0, travel: -dw)
        let sh = dh > 0 ? spring(0.38, 0.22, travel: dh) : spring(0.26, 0, travel: -dh)
        var x = s0, v = v0
        var out = [s0]
        let h = 1.0 / 240
        func step(_ x: inout CGFloat, _ v: inout CGFloat, _ t: CGFloat, _ p: (k: Double, c: Double)) {
            let a = -p.k * Double(x - t) - p.c * Double(v)
            v += CGFloat(a * h); x += v * CGFloat(h)
        }
        while out.count < 150 {
            for _ in 0..<4 { step(&x.width, &v.width, t.width, sw); step(&x.height, &v.height, t.height, sh) }
            out.append(x)
            if abs(x.width - t.width) < 0.3, abs(x.height - t.height) < 0.3, abs(v.width) < 4, abs(v.height) < 4 { break }
        }
        out[out.count - 1] = t
        return out
    }

    /// Size and velocity right now, read off the playing trajectory.
    func now() -> (size: CGSize, velocity: CGSize) {
        let f = (CACurrentMediaTime() - start) * Self.fps
        let i = Int(f)
        guard i < track.count - 1 else { return (track[track.count - 1], .zero) }
        let a = track[i], b = track[i + 1], u = CGFloat(f - Double(i))
        let s = CGSize(width: a.width + (b.width - a.width) * u, height: a.height + (b.height - a.height) * u)
        return (s, CGSize(width: (b.width - a.width) * Self.fps, height: (b.height - a.height) * Self.fps))
    }
    var moving: Bool { (CACurrentMediaTime() - start) * Self.fps < Double(track.count - 1) }

    func jump(to s: CGSize) {
        target = s; track = [s]; start = CACurrentMediaTime()
        play?(track)
    }

    /// `replay`: the content box moved; hand the rest of the current flight to the layers again.
    func animate(to s: CGSize, replay: Bool = false) {
        guard s != target || replay else { return }
        let (cur, vel) = now()
        target = s
        track = IslandMotion.simulate(from: cur, velocity: vel, to: s)
        start = CACurrentMediaTime()
        play?(track)
    }
}

/// Voice level, smoothed like a VU meter (quick attack, slow release).
final class EnergyMeter {
    private(set) var value: CGFloat = 0
    func sample(_ target: Float, dt: CGFloat) -> CGFloat {
        let goal = CGFloat(min(1, target * 1.8))
        value += (goal - value) * min(1, (goal > value ? 14 : 4) * dt)
        return value
    }
    func reset() { value = 0 }
}

struct IslandLayout: Equatable {
    var size: CGSize = .zero
    var text = ""
    var lines = 0
    /// Words sit in the strip beside the orb (a working step, a note) instead of on a row below it.
    var inline = false
    /// Your live words: a fixed window the text flows through, so the island never resizes with what you say.
    var ticker = false
}

final class IslandUI: ObservableObject {
    @Published var geometry = IslandGeometry()
    @Published var layout = IslandLayout()
    @Published var contentVisible = false
    /// Layer views register here so the level clock can drive them without touching SwiftUI.
    weak var bars: VoiceBarsLayerView?
}

// MARK: - Layers

/// Layer-hosting view with a top-left origin; everything in it is plain Core Animation.
class FlippedLayerView: NSView {
    let root = CALayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        root.isGeometryFlipped = true
        layer = root
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The island's chrome: the black body with its shadow, the glow pooled under it, and the rim of light along its
/// sides and bottom (a slowly turning conic gradient seen through a stroke of the silhouette).
final class IslandChrome {
    let below = FlippedLayerView(frame: .zero)
    let above = FlippedLayerView(frame: .zero)
    private let body = CAShapeLayer()
    private let aura = CAShapeLayer()
    private let rim = CALayer()
    private let rimFade = CALayer()
    private let rimGradient = CAGradientLayer()
    private let rimStrokes = CALayer()
    private let hairline = CAShapeLayer()
    private let halo = CAShapeLayer()
    private let fadeMask = CAGradientLayer()
    /// The rim lives inside the silhouette, so the island's outline is exactly Vorssaint's size.
    private let rimHolder = CALayer()
    private let rimClip = CAShapeLayer()
    private(set) var width: CGFloat = 0

    init() {
        body.fillColor = NSColor.black.cgColor
        body.shadowColor = NSColor.black.cgColor
        body.shadowOpacity = 0
        body.shadowRadius = 16
        body.shadowOffset = CGSize(width: 0, height: 7)
        aura.fillColor = nil
        aura.shadowOpacity = 0
        aura.shadowRadius = 20
        aura.shadowOffset = .zero
        below.root.addSublayer(aura)
        below.root.addSublayer(body)

        for s in [hairline, halo] { s.fillColor = nil; s.strokeColor = NSColor.white.cgColor }
        hairline.lineWidth = 1.8   // clipped to its inner half: a 0.9 pt line
        halo.lineWidth = 6
        halo.opacity = 0.22
        rimStrokes.addSublayer(halo)
        rimStrokes.addSublayer(hairline)
        rim.mask = rimStrokes
        // Light the sides and bottom only: the top edge is the screen edge.
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.black.cgColor]
        rimFade.mask = fadeMask
        rimGradient.type = .conic
        rimGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        rimGradient.endPoint = CGPoint(x: 1, y: 0.5)
        rimFade.addSublayer(rimGradient)
        rim.addSublayer(rimFade)
        rim.opacity = 0
        rimClip.fillColor = NSColor.black.cgColor
        rimHolder.mask = rimClip
        rimHolder.addSublayer(rim)
        above.root.addSublayer(rimHolder)
    }

    func layout(bounds: CGRect, stripHeight: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        width = bounds.width
        for l in [below.root, above.root, rimHolder, rimClip, rim, rimFade, rimStrokes, fadeMask, body, aura, hairline, halo] { l.frame = bounds }
        let top = Double(stripHeight * 0.3 / max(1, bounds.height)), full = Double((stripHeight + 4) / max(1, bounds.height))
        fadeMask.locations = [0, NSNumber(value: top), NSNumber(value: full)]
        let side = max(bounds.width, 700)
        rimGradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        rimGradient.position = CGPoint(x: bounds.midX, y: stripHeight)
        CATransaction.commit()
    }

    func setPalette(_ p: OrbPalette) {
        let c = NSColor(p.color)
        let cols: [NSColor]
        switch p {
        case .jarvis, .blue:
            // Blues only (no purple). Arc-reactor blue, ice cyan, and a pale sky highlight.
            let cyan = NSColor(red: 0.36, green: 0.84, blue: 1, alpha: 1), sky = NSColor(red: 0.62, green: 0.86, blue: 1, alpha: 1)
            cols = [c, cyan, c, sky, c]
        default:
            cols = [c, NSColor(white: 1, alpha: 0.9), c, c.withAlphaComponent(0.6), c]
        }
        rimGradient.colors = cols.map(\.cgColor)
        aura.shadowColor = c.cgColor
    }

    /// Plays a size trajectory on every silhouette-shaped layer at once.
    func play(_ sizes: [CGSize]) {
        let w = width
        func x(_ s: CGSize) -> CGFloat { ((w - s.width) / 2).rounded() }
        let shapes = sizes.map { IslandGeometry.path($0, x: x($0)) }
        let glows = sizes.map { s -> CGPath in
            let gw = max(0, s.width * 0.56)
            return CGPath(ellipseIn: CGRect(x: (w - gw) / 2, y: s.height - 16, width: gw, height: 22), transform: nil)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        body.path = shapes.last; body.shadowPath = shapes.last
        hairline.path = shapes.last; halo.path = shapes.last; rimClip.path = shapes.last
        aura.shadowPath = glows.last
        if sizes.count > 1 {
            let d = Double(sizes.count - 1) / IslandMotion.fps
            for (l, key, values) in [(body, "path", shapes), (body, "shadowPath", shapes), (hairline, "path", shapes), (halo, "path", shapes), (rimClip, "path", shapes), (aura, "shadowPath", glows)] {
                let a = CAKeyframeAnimation(keyPath: key)
                a.values = values
                a.duration = d
                a.calculationMode = .linear
                l.add(a, forKey: key)
            }
        } else {
            for l in [body, hairline, halo, rimClip, aura] { l.removeAllAnimations() }
        }
        CATransaction.commit()
    }

    /// Shadow depth follows how far the island is open.
    func setOpen(_ open: CGFloat) {
        CATransaction.begin(); CATransaction.setAnimationDuration(0.3)
        body.shadowOpacity = Float(0.34 * open)
        CATransaction.commit()
    }

    /// Rim and glow while Jarvis is live. `spin`: seconds per turn (faster while he works).
    func setLive(_ on: Bool, spin: Double) {
        if on {
            let key = "spin\(spin)"
            if rimGradient.animation(forKey: key) == nil {
                rimGradient.removeAllAnimations()
                let a = CABasicAnimation(keyPath: "transform.rotation.z")
                a.fromValue = 0; a.toValue = Double.pi * 2
                a.duration = spin; a.repeatCount = .infinity
                a.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 30)
                rimGradient.add(a, forKey: key)
            }
        } else {
            CATransaction.begin(); CATransaction.setAnimationDuration(0.35)
            rim.opacity = 0; aura.shadowOpacity = 0
            CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.rim.opacity == 0 else { return }
                self.rimGradient.removeAllAnimations()
            }
        }
    }

    /// One level sample (30 Hz); the render server tweens to it.
    func setEnergy(_ e: CGFloat) {
        CATransaction.begin(); CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        rim.opacity = Float(0.3 + 0.62 * e)
        aura.shadowOpacity = Float(0.08 + 0.26 * e)
        CATransaction.commit()
    }
}

/// Five bars in the right wing: the mic while you talk, Ryan's voice while he speaks, resting dots otherwise.
/// Plain layers under a gradient (DynamicNotch's lightweight equalizer approach); the level clock sets their heights.
final class VoiceBarsLayerView: FlippedLayerView {
    private let gradient = CAGradientLayer()
    private let holder = CALayer()
    private var bars: [CALayer] = []
    private static let envelope: [CGFloat] = [0.5, 0.82, 1, 0.82, 0.5]
    private let barW: CGFloat = 2, gap: CGFloat = 2.1, maxH: CGFloat = 14, minH: CGFloat = 3.5

    override init(frame: NSRect) {
        super.init(frame: frame)
        gradient.startPoint = CGPoint(x: 0.5, y: 0); gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.mask = holder
        root.addSublayer(gradient)
        for _ in 0..<5 {
            let b = CALayer()
            b.backgroundColor = NSColor.white.cgColor
            b.cornerRadius = barW / 2
            holder.addSublayer(b)
            bars.append(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func setColor(_ c: NSColor) { gradient.colors = [NSColor(white: 1, alpha: 0.95).cgColor, c.cgColor] }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.frame = bounds; holder.frame = bounds
        CATransaction.commit()
        set(level: 0, t: 0, animated: false)
    }

    func set(level e: CGFloat, t: Double, animated: Bool = true) {
        let total = 5 * barW + 4 * gap
        let x0 = (bounds.width - total).rounded() / 2
        CATransaction.begin()
        if animated { CATransaction.setAnimationDuration(0.1); CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut)) }
        else { CATransaction.setDisableActions(true) }
        for (i, b) in bars.enumerated() {
            let wobble = 0.55 + 0.45 * sin(t * (8.5 + Double(i) * 1.7) + Double(i) * 1.3)
            let idle = 0.5 + 0.5 * sin(t * 2.2 + Double(i) * 0.8)
            let h = minH + 1.2 * CGFloat(idle) * (1 - e) + (maxH - minH) * e * Self.envelope[i] * CGFloat(wobble)
            b.frame = CGRect(x: x0 + CGFloat(i) * (barW + gap), y: (bounds.height - h) / 2, width: barW, height: h)
        }
        holder.opacity = Float(0.62 + 0.38 * min(1, e * 2))
        CATransaction.commit()
    }
}

struct VoiceBars: NSViewRepresentable {
    let ui: IslandUI
    let color: Color
    func makeNSView(context: Context) -> VoiceBarsLayerView {
        let v = VoiceBarsLayerView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        v.setColor(NSColor(color))
        ui.bars = v
        return v
    }
    func updateNSView(_ v: VoiceBarsLayerView, context: Context) { v.setColor(NSColor(color)); ui.bars = v }
}

/// Three dots that pulse in turn while Jarvis works. A replicator animated by the render server: zero CPU.
final class WorkingDotsLayerView: FlippedLayerView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let rep = CAReplicatorLayer()
        rep.frame = bounds
        rep.instanceCount = 3
        rep.instanceTransform = CATransform3DMakeTranslation(6.5, 0, 0)
        rep.instanceDelay = 0.16
        let d = CALayer()
        d.frame = CGRect(x: (bounds.width - 17) / 2, y: bounds.height / 2 - 2, width: 4, height: 4)
        d.cornerRadius = 2
        d.backgroundColor = NSColor.white.cgColor
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.28; fade.toValue = 1
        let lift = CABasicAnimation(keyPath: "transform.translation.y")
        lift.fromValue = 0; lift.toValue = -1.5
        let g = CAAnimationGroup()
        g.animations = [fade, lift]
        g.duration = 0.42; g.autoreverses = true; g.repeatCount = .infinity
        g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        d.add(g, forKey: "pulse")
        d.opacity = 0.28
        rep.addSublayer(d)
        root.addSublayer(rep)
    }
    required init?(coder: NSCoder) { fatalError() }
}

struct WorkingDots: NSViewRepresentable {
    func makeNSView(context: Context) -> WorkingDotsLayerView { WorkingDotsLayerView(frame: NSRect(x: 0, y: 0, width: 18, height: 18)) }
    func updateNSView(_ v: WorkingDotsLayerView, context: Context) {}
}

// MARK: - Content (SwiftUI; re-renders only when the words or the state change)

/// Content unfolding out of the camera (DynamicNotch): squashed toward the notch, blurred, lifted.
private struct Unfold: ViewModifier {
    let p: CGFloat   // 0 folded, 1 open
    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 0.8 + 0.2 * p, y: 0.4 + 0.6 * p, anchor: .top)
            .offset(y: -5 * (1 - p))
            .blur(radius: 10 * (1 - p))
            .opacity(Double(p))
            .compositingGroup()
    }
}

/// Words coming out of the orb beside it: from a little closer to it, blurred, then settling.
private struct Emerge: ViewModifier {
    let p: CGFloat
    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 0.92 + 0.08 * p, y: 1, anchor: .leading)
            .offset(x: -8 * (1 - p))
            .blur(radius: 6 * (1 - p))
            .opacity(Double(p))
    }
}

/// One word arriving at the right edge of the live-words window: a little closer to where it came from, then settling.
private struct WordIn: ViewModifier {
    let p: CGFloat
    func body(content: Content) -> some View {
        content.offset(x: 9 * (1 - p)).blur(radius: 4 * (1 - p)).opacity(Double(p))
    }
}

/// The oldest words dissolving into the orb: a soft edge on the window's left, only once words are running through it.
private struct TickerFade: ViewModifier, Animatable {
    var fade: CGFloat   // width of the soft edge in points; 0 = none
    let room: CGFloat
    var animatableData: CGFloat { get { fade } set { fade = newValue } }
    func body(content: Content) -> some View {
        content.mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                            .init(color: .black, location: min(1, max(0.001, fade / max(room, 1))))],
                                    startPoint: .leading, endPoint: .trailing))
    }
}

/// A wing squeezing toward the camera (DynamicNotchKit's compact leading/trailing transition).
private struct Squeeze: ViewModifier {
    let p: CGFloat
    let anchor: UnitPoint
    func body(content: Content) -> some View {
        content.scaleEffect(x: max(0.001, p), y: 0.6 + 0.4 * p, anchor: anchor).blur(radius: 8 * (1 - p)).opacity(Double(p))
    }
}

private struct Rise: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View { content.blur(radius: active ? 4 : 0).offset(y: active ? 5 : 0).opacity(active ? 0 : 1) }
}

/// Reveals a new line left to right behind a soft edge, the way Jarvis "says" it.
private struct SweepReveal: ViewModifier, Animatable {
    var p: CGFloat
    var animatableData: CGFloat { get { p } set { p = newValue } }
    func body(content: Content) -> some View {
        content
            .mask(LinearGradient(colors: [.black, .clear], startPoint: UnitPoint(x: p * 1.35 - 0.35, y: 0.5), endPoint: UnitPoint(x: p * 1.35, y: 0.5)))
            .blur(radius: (1 - p) * 2.5)
    }
}

private extension AnyTransition {
    /// Old words leave fast; new ones rise in just after, so two captions never overlap.
    static var rise: AnyTransition {
        .asymmetric(insertion: AnyTransition.modifier(active: Rise(active: true), identity: Rise(active: false)).animation(.easeOut(duration: 0.26).delay(0.06)),
                    removal: AnyTransition.opacity.animation(.easeOut(duration: 0.08)))
    }
    static var sweep: AnyTransition {
        .asymmetric(insertion: AnyTransition.modifier(active: SweepReveal(p: 0), identity: SweepReveal(p: 1)).animation(.easeOut(duration: 0.5).delay(0.05)),
                    removal: AnyTransition.opacity.animation(.easeOut(duration: 0.08)))
    }
    static func squeeze(toward anchor: UnitPoint) -> AnyTransition {
        .modifier(active: Squeeze(p: 0, anchor: anchor), identity: Squeeze(p: 1, anchor: anchor))
    }
}

/// Soft highlight sweeping across the step Jarvis is on. Keyframe-driven: no view re-renders.
private struct IslandShimmer: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { g in
                LinearGradient(colors: [.clear, Color.white.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: g.size.width * 0.4)
                    .keyframeAnimator(initialValue: CGFloat(-0.4), repeating: true) { v, x in
                        v.offset(x: x * g.size.width)
                    } keyframes: { _ in
                        LinearKeyframe(CGFloat(1.4), duration: 1.7)
                    }
            }
            .mask(content)
            .allowsHitTesting(false)
        )
    }
}

/// Sep 30 (Coucou's Mochi, in Jarvis's register): the orb's one-shot moves. Swallowing a drop: it opens wide, gulps and
/// settles. A poke (click the island): a squash and a spring back. Three quick pokes: a dizzy wobble. No sounds.
private struct OrbMoves: ViewModifier {
    @ObservedObject var m: HUDModel
    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: CGFloat(1), trigger: m.gulps) { v, s in v.scaleEffect(s) } keyframes: { _ in
                SpringKeyframe(CGFloat(1.32), duration: 0.14, spring: .snappy)
                SpringKeyframe(CGFloat(0.8), duration: 0.12, spring: .snappy)
                SpringKeyframe(CGFloat(1), duration: 0.5, spring: .bouncy)
            }
            .keyframeAnimator(initialValue: CGSize(width: 1, height: 1), trigger: m.pokes) { v, s in v.scaleEffect(x: s.width, y: s.height) } keyframes: { _ in
                SpringKeyframe(CGSize(width: 1.2, height: 0.78), duration: 0.08, spring: .snappy)
                SpringKeyframe(CGSize(width: 1, height: 1), duration: 0.5, spring: .bouncy)
            }
            .keyframeAnimator(initialValue: CGFloat(0), trigger: m.dizzies) { v, x in
                v.offset(x: x).rotationEffect(.degrees(Double(x) * 6))
            } keyframes: { _ in
                CubicKeyframe(CGFloat(3.5), duration: 0.08)
                CubicKeyframe(CGFloat(-3.5), duration: 0.12)
                CubicKeyframe(CGFloat(3), duration: 0.12)
                CubicKeyframe(CGFloat(-3), duration: 0.12)
                CubicKeyframe(CGFloat(2), duration: 0.12)
                CubicKeyframe(CGFloat(-2), duration: 0.12)
                CubicKeyframe(CGFloat(0), duration: 0.14)
            }
    }
}

/// Two columns, each hosted on its own so Core Animation can carry it with its edge of the island: the left one
/// (orb and words, sharing the alignment line) and the right wing. Neither ever jumps ahead of the spring.
struct IslandContent: View {
    enum Part { case leading, trailing }
    @ObservedObject var m: HUDModel
    @ObservedObject var ui: IslandUI
    let part: Part

    private var g: IslandGeometry { ui.geometry }
    private var accent: Color { m.orb.palette.color }
    private var open: Bool { ui.contentVisible }
    private var inset: CGFloat { IslandGeometry.inset(ui.layout.size.height) }
    private var icon: CGFloat { IslandGeometry.icon(g.height) }
    /// The words' column: inside the alignment line on both sides, or (inline) between the orb and the right wing.
    private var room: CGFloat {
        let l = ui.layout
        guard l.inline else { return max(0, l.size.width - 2 * inset) }
        return max(0, l.size.width - 2 * inset - icon - IslandController.inlineGap - IslandController.inlineTrail
                   - IslandController.trailingWidth(m, strip: g.height, button: showButton))
    }
    /// Card: the words sit centered in the room under the strip (Vorssaint's peek keeps 10 pt under the strip and 52
    /// below that), so one line and two lines both look placed rather than hung from the top.
    private var captionTop: CGFloat {
        let l = ui.layout, n = CGFloat(max(1, l.lines))
        let text = n * IslandController.lineHeight + (n - 1) * IslandController.lineGap
        return max(6, ((l.size.height - g.height - text) / 2).rounded())
    }

    var body: some View {
        Group {
            if part == .leading { leadingColumn } else { trailingColumn }
        }
        .frame(width: ui.layout.size.width, height: ui.layout.size.height, alignment: part == .leading ? .topLeading : .topTrailing)
        // Pinned to its own edge of the host, so even a frame drawn before SwiftUI catches up with a new size sits where
        // Core Animation is carrying that edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: part == .leading ? .topLeading : .topTrailing)
        .environment(\.colorScheme, .dark)
        .animation(open ? .spring(response: 0.42, dampingFraction: 0.84).delay(0.05) : .easeIn(duration: 0.14), value: open)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: m.phase)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: m.muted)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: m.revealControls)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: ui.layout.lines)
    }

    @ViewBuilder private var leadingColumn: some View {
        if ui.layout.inline { inlineColumn } else { stackedColumn }
    }

    /// Orb, then the words beside it, both centered in the strip.
    private var inlineColumn: some View {
        HStack(spacing: IslandController.inlineGap) {
            ZStack {
                if open { leading.transition(.squeeze(toward: .trailing)) }
            }
            .frame(width: icon, height: g.height)
            ZStack(alignment: .leading) {
                if open && ui.layout.lines > 0 {
                    caption
                        .transition(.modifier(active: Emerge(p: 0), identity: Emerge(p: 1)))
                }
            }
            .frame(width: room, height: g.height, alignment: .leading)
        }
        .padding(.leading, inset)
        .animation(nil, value: inset)
    }

    private var stackedColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if open {
                    leading.transition(.squeeze(toward: .trailing))
                }
            }
            .frame(width: icon, height: g.height)
            ZStack(alignment: .topLeading) {
                if open && ui.layout.lines > 0 {
                    caption
                        .frame(width: room, alignment: .leading)
                        .padding(.top, captionTop)
                        .transition(.modifier(active: Unfold(p: 0), identity: Unfold(p: 1)))
                }
            }
        }
        .padding(.leading, inset)
        .animation(nil, value: inset)   // Core Animation carries the edge; a SwiftUI spring here would count it twice
    }

    private var trailingColumn: some View {
        ZStack {
            if open {
                trailing.frame(height: icon)
                    .transition(.squeeze(toward: .leading))
            }
        }
        .frame(height: g.height)
        .padding(.trailing, inset)
        .animation(nil, value: inset)
    }

    // MARK: Wings

    private var leading: some View {
        ZStack {
            // The shader draws the sphere at 62% of its view (the rest is halo). The sphere is 2 pt under the icon size:
            // it swells ~10% with the voice and carries a glow, so at full size it read heavier than the glyphs opposite.
            OrbView(state: m.orb, running: m.shown && !m.orbFrozen && open, fps: 30, tint: 1)
                .frame(width: ((icon - 2) / 0.62).rounded(), height: ((icon - 2) / 0.62).rounded())
                .allowsHitTesting(false)
            if m.muted && m.showControls {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.6))
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .frame(width: icon, height: icon)
        .scaleEffect(m.phase == .cancelled || m.phase == .error ? 0.86 : (m.drop == .over ? 1.14 : 1))
        .modifier(OrbMoves(m: m))
    }

    /// Each right-wing state sits in the same `icon` box, trailing edge on the alignment line.
    private func slot<V: View>(_ v: V) -> some View { v.frame(width: icon, height: icon) }

    /// Near the notch the mic button slides out at the wing's edge and the state glyph steps inward to make room.
    private var showButton: Bool { m.revealControls && m.showControls && !(m.phase == .confirming && m.countdownActive) }

    private var trailing: some View {
        HStack(spacing: 8) {
            if !(showButton && m.muted) {   // muted: the red button already says so
                indicator
            }
            if showButton {
                IslandMuteChip(m: m)
                    .transition(.asymmetric(insertion: .scale(scale: 0.4).combined(with: .opacity),
                                            removal: .scale(scale: 0.6).combined(with: .opacity).animation(.easeIn(duration: 0.12))))
            }
        }
    }

    @ViewBuilder private var indicator: some View {
        ZStack(alignment: .trailing) {
            if m.drop != .none {
                slot(Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(m.drop == .over ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.55)))
                    .symbolEffect(.bounce, value: m.drop == .over))
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else if m.phase == .sent {
                slot(Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, accent))
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            } else if m.phase == .cancelled {
                slot(Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.36)))
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else if m.phase == .error {
                slot(Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(red: 1, green: 0.36, blue: 0.3)))
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else if m.phase == .confirming && m.countdownActive {
                HStack(spacing: 8) {
                    Text("esc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.13)))
                    slot(ZStack {
                        Circle().stroke(Color.white.opacity(0.16), lineWidth: 1.8)
                        Circle().trim(from: 0, to: m.countdown)
                            .stroke(accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 13, height: 13))
                }
                .transition(.opacity.combined(with: .scale(scale: 0.7, anchor: .trailing)))
            } else if m.muted {
                slot(Image(systemName: "mic.slash.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.36, blue: 0.36)))
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else if m.phase == .thinking {
                slot(WorkingDots())
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            } else {
                slot(VoiceBars(ui: ui, color: accent))
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
    }

    // MARK: Caption

    private func line(_ s: String) -> Text {
        let v = IslandController.voice(m)
        return Text(s)
            .font(.system(size: IslandController.fontSize, weight: v == .jarvis ? .medium : .regular))
            .foregroundColor(Color.white.opacity(v == .quiet ? 0.5 : (v == .jarvis ? 0.96 : 0.9)))
    }

    /// The last dozen words of what you are saying, each with a stable identity (its place in the sentence), so a new word
    /// arrives on its own and the older ones glide left; dropping one off the far left moves nothing that is visible.
    private var tickerWords: [(id: Int, text: String)] {
        let all = m.transcript.split(whereSeparator: { $0.isWhitespace })
        let base = max(0, all.count - 12)
        return all[base...].enumerated().map { (base + $0.offset, String($0.element)) }
    }

    /// Your words flow through a fixed window beside the orb. They start next to it; once they outgrow the window the
    /// newest stay at the right edge and the oldest slide left and dissolve into the orb. The island does not grow.
    private var ticker: some View {
        let words = tickerWords
        let font = IslandController.font(.yours)
        let width = ceil((words.map(\.text).joined(separator: " ") as NSString).size(withAttributes: [.font: font]).width)
        let over = width > room
        return HStack(spacing: IslandController.spaceWidth) {
            ForEach(words, id: \.id) { w in
                Text(w.text)
                    .font(.system(size: IslandController.fontSize, weight: .regular))
                    .foregroundColor(Color.white.opacity(0.9))
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.modifier(active: WordIn(p: 0), identity: WordIn(p: 1)))
            }
        }
        .fixedSize()
        .frame(width: room, alignment: over ? .trailing : .leading)
        .modifier(TickerFade(fade: over ? 26 : 0, room: room))
        .clipped()
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: words.last?.id ?? -1)
    }

    @ViewBuilder private var caption: some View {
        let text = ui.layout.text
        if ui.layout.ticker {
            ticker
        } else if m.phase == .speaking {
            line(text).lineLimit(1).truncationMode(.tail)
                .frame(width: room, alignment: .leading)
                .id(text)
                .transition(.sweep)
        } else if m.phase == .thinking {
            line(text).lineLimit(ui.layout.inline ? 1 : 2).truncationMode(.tail)
                .lineSpacing(IslandController.lineGap)
                .frame(width: room, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(IslandShimmer())
                .id(text)
                .transition(.rise)
        } else if !m.attachment.isEmpty && text == m.attachment {
            // What you dropped, waiting for you to say what to do with it.
            (Text(Image(systemName: "paperclip")).foregroundColor(accent) + Text(" ") + line(text))
                .font(.system(size: IslandController.fontSize))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: room, alignment: .leading)
                .id(text)
                .transition(.rise)
        } else {
            line(text)
                .lineLimit(ui.layout.inline ? 1 : 2)
                .truncationMode(.tail)
                .lineSpacing(IslandController.lineGap)
                .frame(width: room, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .id(text)
                .transition(.rise)
        }
    }
}

/// Jarvis's mic button, out at the right wing's edge while the pointer is near the notch. Same red as the orb's
/// button when muted.
struct IslandMuteChip: View {
    static let size: CGFloat = 22
    @ObservedObject var m: HUDModel
    private let red = Color(red: 0.93, green: 0.27, blue: 0.29)

    var body: some View {
        ZStack {
            Circle().fill(m.muted ? AnyShapeStyle(LinearGradient(colors: [red, Color(red: 0.8, green: 0.18, blue: 0.21)], startPoint: .top, endPoint: .bottom))
                                  : AnyShapeStyle(Color.white.opacity(m.muteHover ? 0.2 : 0.12)))
            Circle().strokeBorder(Color.white.opacity(m.muted ? 0.25 : 0.1), lineWidth: 0.8)
            Image(systemName: m.muted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(m.muted || m.muteHover ? 1 : 0.85))
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(.bounce, value: m.muteToggles)
        }
        .frame(width: Self.size, height: Self.size)
        .background(Ripple(p: m.rippleP, color: m.muted ? red : .white))
        .scaleEffect(m.mutePressed ? 0.86 : (m.muteHover ? 1.08 : 1))
        .animation(.spring(response: 0.22, dampingFraction: 0.62), value: m.mutePressed)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: m.muteHover)
    }
}

// MARK: - Controller

/// Owns the island panel. Driven entirely by the shared HUDModel, so the controller never has to know which style
/// is showing. The panel sits one level above Vorssaint's and is click-through except for the mic chip.
final class IslandController {
    static let fontSize: CGFloat = 13
    /// Inline words: 8 pt after the orb, 14 pt clear of the right wing.
    static let inlineGap: CGFloat = 8
    static let inlineTrail: CGFloat = 14
    /// The right wing's width for the current state: the glyph, or the esc key and ring during the countdown, plus
    /// the mic button while it is out (`button`).
    static func trailingWidth(_ m: HUDModel, strip: CGFloat, button: Bool = false) -> CGFloat {
        IslandGeometry.icon(strip) + (m.phase == .confirming && m.countdownActive ? 28 + 8 : 0) + (button ? 8 + IslandMuteChip.size : 0)
    }
    /// Card rhythm: one 16 pt line (2 pt apart when there are two), centered in the room under the strip.
    static let lineHeight: CGFloat = 16
    static let lineGap: CGFloat = 2

    /// Who the words belong to, which sets their weight and tone.
    enum Voice { case jarvis, yours, quiet }
    static func voice(_ m: HUDModel) -> Voice {
        if m.drop == .near { return .quiet }
        if m.drop == .over { return .jarvis }
        if !m.attachment.isEmpty && m.phase == .listening && m.transcript.isEmpty { return .yours }
        switch m.phase {
        case .speaking: return .jarvis
        case .thinking, .cancelled, .error: return .quiet
        case .confirming where !Settings.shared.islandCaptions, .sent where !Settings.shared.islandCaptions: return .quiet
        case .listening where m.transcript.isEmpty: return .jarvis   // his "Yes, sir?"
        default: return .yours
        }
    }
    static func font(_ v: Voice) -> NSFont { .systemFont(ofSize: fontSize, weight: v == .jarvis ? .medium : .regular) }
    /// The gap between words in the live-words window: one space of the caption font.
    static let spaceWidth: CGFloat = (" " as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width

    let model: HUDModel
    let ui = IslandUI()
    let motion = IslandMotion()
    var onMuteToggle: (() -> Void)?
    var previewPinned = false
    private var panel: NSPanel?
    private let rootView = NSView(frame: .zero)
    private let chrome = IslandChrome()
    private var contentBox: NSView?
    private var columns: [NSView] = []   // leading, trailing
    private let contentMask = CAShapeLayer()
    private var sub: AnyCancellable?
    private var monitors: [Any] = []
    private let panelSize = NSSize(width: 820, height: 200)
    private var hideWork: DispatchWorkItem?
    private var catcher: NSPanel?
    private var resting = false
    private var quietWork: DispatchWorkItem?
    private var geometryCheckedAt: CFTimeInterval = 0
    private var relayoutQueued = false
    private var clock: Timer?
    private let meter = EnergyMeter()
    private var clockT = 0.0
    private var palette: OrbPalette?
    private var hopUntil: CFTimeInterval = 0
    private var pokeTimes: [CFTimeInterval] = []

    /// Coucou's finish jump, kept small and silent: the island rises a few points and springs back to its size.
    func hop() {
        guard visible, model.shown, !resting else { return }
        hopUntil = CACurrentMediaTime() + 0.13
        relayout()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in self?.relayout() }
    }

    init(model: HUDModel) {
        self.model = model
        sub = model.objectWillChange.sink { [weak self] _ in self?.queueRelayout() }
        motion.play = { [weak self] sizes in self?.play(sizes) }
    }

    var visible: Bool { panel?.isVisible == true }

    /// Gone: a sliver of the strip's width, no height, up in the screen's top edge. Jarvis drops out of it and
    /// retracts back into it (Vorssaint's own island, if up, is simply uncovered underneath).
    private var collapsed: CGSize {
        let g = ui.geometry
        return CGSize(width: max(g.cameraWidth * 0.75, g.compactWidth * 0.6).rounded(), height: 0)
    }

    /// Your live words run through the ticker (see `layout()`), so they are not here. Jarvis's own speech is not shown
    /// (the voice carries it, and captions trail it). What stays is what he is doing: working steps, "Sending to Aside"
    /// over the esc countdown, sent, cancelled, errors. "Show Jarvis's Words" in the menu brings his speech back as text.
    static func captionText(_ m: HUDModel) -> String {
        let captions = Settings.shared.islandCaptions
        // Sep 30: a drag on its way in, then what was dropped until you say what to do with it.
        switch m.drop {
        case .near: return "Drop it here for Jarvis"
        case .over: return "Let go"
        case .none: break
        }
        if !m.attachment.isEmpty && m.phase == .listening && m.transcript.isEmpty && !m.mutedIdle { return m.attachment }
        switch m.phase {
        case .cancelled, .error: return m.status
        case .thinking: return m.transcript
        case .confirming where !captions: return m.countdownActive ? "Sending to Aside" : ""
        case .sent where !captions: return m.status
        case _ where !captions: return ""
        default:
            if m.mutedIdle { return "" }
            if m.phase == .listening && m.transcript.isEmpty { return m.hint }
            return m.transcript
        }
    }

    /// Width left for words beside the orb in a strip of width `w` (without the hover mic button).
    private func inlineRoom(_ w: CGFloat) -> CGFloat {
        let h = ui.geometry.height
        return w - 2 * IslandGeometry.inset(h) - IslandGeometry.icon(h) - Self.inlineGap - Self.inlineTrail - Self.trailingWidth(model, strip: h)
    }

    /// Sep 29: always one of Vorssaint's three sizes (see IslandGeometry), picked by what there is to show:
    /// - nothing to read (listening, working, talking): the resting strip, exactly over Vorssaint's own island;
    /// - one line (your words as you say them, a working step, a note, the countdown): the notice strip, words beside the orb;
    /// - more than a line fits (Jarvis's words with captions on, a long error): the peek card, two lines under the strip.
    /// Under a physical notch the camera would split a strip's words, so there they always take the card.
    private func layout() -> IslandLayout {
        let g = ui.geometry
        let strip = CGSize(width: g.compactWidth, height: g.height)
        let notice = CGSize(width: g.noticeWidth, height: g.height)
        let peek = CGSize(width: g.peekWidth, height: g.peekHeight)
        // Your words run through a fixed window beside the orb; the island never resizes with what you say.
        if model.phase == .listening, !model.transcript.isEmpty, !model.mutedIdle {
            return g.notched ? IslandLayout(size: peek, lines: 1, ticker: true)
                             : IslandLayout(size: notice, lines: 1, inline: true, ticker: true)
        }
        let text = Self.captionText(model)
        guard !text.isEmpty else { return IslandLayout(size: strip, text: "", lines: 0) }
        // A drop on its way in, or what was dropped: one short line beside the orb, like a Vorssaint notice.
        if model.drop != .none || (!model.attachment.isEmpty && text == model.attachment) {
            return g.notched ? IslandLayout(size: peek, text: text, lines: 1) : IslandLayout(size: notice, text: text, lines: 1, inline: true)
        }
        let tw = ceil((text as NSString).size(withAttributes: [.font: Self.font(Self.voice(model))]).width) + 2
        let captions = Settings.shared.islandCaptions
        let transcript = captions && [.listening, .speaking, .confirming, .sent].contains(model.phase)
        // Steps and notes sit beside the orb like Vorssaint's notices. A working step that runs long is cut with an
        // ellipsis (the next one replaces it in a moment); anything else that does not fit takes the card.
        if !transcript && !g.notched && (tw <= inlineRoom(notice.width) || model.phase == .thinking) {
            return IslandLayout(size: notice, text: text, lines: 1, inline: true)
        }
        let oneLine = model.phase == .listening || model.phase == .speaking
        let lines = !oneLine && tw > peek.width - 2 * IslandGeometry.inset(peek.height) ? 2 : 1
        return IslandLayout(size: peek, text: text, lines: lines)
    }

    /// Near the notch the island swells the way Vorssaint's does under the pointer (measured: 288 x 30 -> 310 x 36, so
    /// 22 pt wider and 6 pt taller) and the mic button slides out in the right wing, widened a little more only if the
    /// wing would not otherwise fit the state glyph, a gap and the button.
    private func hovered(_ s: CGSize) -> CGSize {
        // A drop right over the island swells it the same way the pointer does (Coucou lights its box; Jarvis leans in).
        if model.drop == .over { return CGSize(width: s.width + 22, height: s.height + 6) }
        // The happy hop when an answer lands or a drop is swallowed: a quick rise and a spring back (see hop()).
        if CACurrentMediaTime() < hopUntil { return CGSize(width: s.width + 14, height: s.height + 5) }
        guard model.revealControls, buttonAvailable else { return s }
        let g = ui.geometry
        var w = s.width + 22
        let wing = IslandGeometry.inset(g.height) + IslandGeometry.icon(g.height) + 8 + IslandMuteChip.size
        if s.height <= g.height + 0.5 { w = max(w, g.cameraWidth + 2 * wing) }
        return CGSize(width: min(g.screen.width - 24, (w / 2).rounded(.up) * 2), height: s.height + 6)
    }

    private func queueRelayout() {
        guard !relayoutQueued else { return }
        relayoutQueued = true
        DispatchQueue.main.async { [weak self] in self?.relayoutQueued = false; self?.relayout() }
    }

    func relayout() {
        guard visible else { return }
        // Vorssaint's activity can widen or narrow while Jarvis is up; keep matching it (a cheap bounds read, <= 1/s).
        if CACurrentMediaTime() - geometryCheckedAt > 1 {
            geometryCheckedAt = CACurrentMediaTime()
            let g = IslandGeometry.current()
            if g != ui.geometry { ui.geometry = g; chrome.layout(bounds: rootView.bounds, stripHeight: g.height) }
        }
        if palette != model.orb.palette {
            palette = model.orb.palette
            chrome.setPalette(model.orb.palette)
        }
        let l = layout()
        var boxMoved = false
        if l != ui.layout {
            ui.layout = l
            boxMoved = placeContentBox(l.size)
        }
        updateResting()
        let open = model.shown && !resting
        let target = open ? hovered(l.size) : collapsed
        motion.animate(to: target, replay: boxMoved)
        if ui.contentVisible != open { ui.contentVisible = open }
        chrome.setOpen(open && l.lines > 0 && !l.inline ? 1 : (open ? 0.35 : 0))
        updateLive()
        syncCatcher()
        updateHover()
    }

    // MARK: Panel and layers

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }
        rootView.frame = NSRect(origin: .zero, size: panelSize)
        chrome.below.frame = rootView.bounds
        chrome.above.frame = rootView.bounds
        chrome.layout(bounds: rootView.bounds, stripHeight: ui.geometry.height)
        let box = NSView(frame: rootView.bounds)
        box.wantsLayer = true
        box.layer?.masksToBounds = false
        for part in [IslandContent.Part.leading, .trailing] {
            let host = NSHostingView(rootView: IslandContent(m: model, ui: ui, part: part))
            host.sizingOptions = []
            host.wantsLayer = true
            box.addSubview(host)
            columns.append(host)
        }
        contentMask.frame = box.bounds
        box.layer?.mask = contentMask
        contentBox = box
        rootView.addSubview(chrome.below)
        rootView.addSubview(box)
        rootView.addSubview(chrome.above)
        let p = NSPanel(contentRect: rootView.frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)   // Vorssaint's island is at +1
        p.ignoresMouseEvents = true
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = rootView
        panel = p
        return p
    }

    /// Sizes the SwiftUI columns to the layout they will settle at (they never re-lay out per frame); returns true if
    /// they moved, so the running flight is handed to them again from where they now sit.
    @discardableResult private func placeContentBox(_ size: CGSize) -> Bool {
        // Room below for the unfold overshoot; the mask trims it.
        let f = NSRect(x: ((rootView.bounds.width - size.width) / 2).rounded(), y: rootView.bounds.height - size.height - 20,
                       width: size.width, height: size.height + 20)
        guard let first = columns.first, first.frame != f else { return false }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        columns.forEach { $0.frame = f; $0.layoutSubtreeIfNeeded() }   // new size and new content in the same commit
        CATransaction.commit()
        return true
    }

    /// Plays one trajectory on the chrome and on the content mask (same path, in the content box's coordinates).
    private func play(_ sizes: [CGSize]) {
        chrome.play(sizes)
        guard let box = contentBox else { return }
        let w = rootView.bounds.width, bh = box.bounds.height
        // The box's layer is not flipped: build the silhouette top-down, then flip it into place.
        var flip = CGAffineTransform(translationX: 0, y: bh).scaledBy(x: 1, y: -1)
        let paths: [CGPath] = sizes.map { s in
            let x = ((w - s.width) / 2).rounded()
            return IslandGeometry.path(s, x: x).copy(using: &flip) ?? IslandGeometry.path(s, x: x)
        }
        // Each column rides its edge: its offset from where it is laid out, frame by frame, on the same spring.
        let l = ui.layout.size
        func leftEdge(_ s: CGSize) -> CGFloat { ((w - s.width) / 2).rounded() + IslandGeometry.inset(s.height) }
        func rightEdge(_ s: CGSize) -> CGFloat { ((w - s.width) / 2).rounded() + s.width - IslandGeometry.inset(s.height) }
        let offsets = [sizes.map { leftEdge($0) - leftEdge(l) }, sizes.map { rightEdge($0) - rightEdge(l) }]
        let d = Double(sizes.count - 1) / IslandMotion.fps
        CATransaction.begin(); CATransaction.setDisableActions(true)
        contentMask.path = paths.last
        if paths.count > 1 {
            let a = CAKeyframeAnimation(keyPath: "path")
            a.values = paths
            a.duration = d
            a.calculationMode = .linear
            contentMask.add(a, forKey: "path")
        } else { contentMask.removeAllAnimations() }
        for (col, xs) in zip(columns, offsets) {
            let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
            a.values = xs.count > 1 ? xs : [xs[0], xs[0]]
            a.duration = max(d, 0.001)
            a.calculationMode = .linear
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false   // holds the hover swell's small offset once it settles
            col.layer?.add(a, forKey: "ride")
        }
        CATransaction.commit()
    }

    func present() {
        let g = IslandGeometry.current()
        geometryCheckedAt = CACurrentMediaTime()
        let p = ensurePanel()
        if g != ui.geometry {
            ui.geometry = g
            chrome.layout(bounds: rootView.bounds, stripHeight: g.height)
        }
        p.setFrameOrigin(NSPoint(x: g.screen.midX - panelSize.width / 2, y: g.screen.maxY - panelSize.height))
        if !p.isVisible {
            // Muted from the menu: stays tucked away (the menu bar says muted).
            resting = model.mutedIdle && !previewPinned && model.drop == .none
            quietWork?.cancel(); quietWork = nil
            ui.contentVisible = false
            palette = nil
            let l = layout()
            ui.layout = l
            placeContentBox(l.size)
            motion.jump(to: collapsed)
            p.orderFrontRegardless()
            startTracking()
        }
        queueRelayout()
    }

    /// Tests: the island as it settles (model values, no animation) over a grey backdrop, cropped to the top 150 x
    /// 520 pt, with Vorssaint's resting island outlined in orange so the two can be compared. Needs no screen recording.
    func snapshot(to url: URL) -> Bool {
        guard let layer = rootView.layer else { return false }
        let b = rootView.bounds, scale: CGFloat = 2, crop = CGSize(width: 520, height: 150)
        guard let ctx = CGContext(data: nil, width: Int(crop.width * scale), height: Int(crop.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(NSColor(white: 0.42, alpha: 1).cgColor); ctx.fill(CGRect(origin: .zero, size: crop))
        // Top-left crop of the panel's top edge, centered.
        ctx.translateBy(x: -(b.width - crop.width) / 2, y: 0)
        ctx.translateBy(x: 0, y: -(b.height - crop.height))
        layer.render(in: ctx)
        let g = ui.geometry
        let rest = CGSize(width: g.cameraWidth + 88, height: g.height)
        ctx.setStrokeColor(NSColor.orange.cgColor); ctx.setLineWidth(0.75)
        ctx.addRect(CGRect(x: (b.width - rest.width) / 2, y: b.height - rest.height, width: rest.width, height: rest.height).insetBy(dx: 0.4, dy: 0.4))
        ctx.strokePath()
        guard let img = ctx.makeImage(), let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    func hide() {
        panel?.orderOut(nil)
        stopTracking()
        stopClock()
        chrome.setLive(false, spin: 9)
        motion.jump(to: collapsed)
        ui.contentVisible = false
        quietWork?.cancel(); quietWork = nil
        resting = false
    }

    // MARK: Resting (nothing going on)

    /// Sep 29: Jarvis stays out the whole time he is listening, working or talking. Between your sentences (and after
    /// "Hey Jarvis" before you start) he rests in Vorssaint's own strip, orb and bars, so you can see he is waiting for
    /// you; nothing resizes until there is something to read. Only muted with nothing going on does he tuck back into
    /// the top edge, which is also how an idle conversation ends (it mutes after a couple of quiet minutes).
    private func updateResting() {
        let quiet = model.shown && !previewPinned && model.mutedIdle && model.drop == .none
        guard quiet else {
            quietWork?.cancel(); quietWork = nil
            resting = false
            return
        }
        guard !resting, quietWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.quietWork = nil
            self.resting = true
            self.relayout()
        }
        quietWork = w
        // A beat of grace so a pause between two sentences, or the red mute you just clicked, is not snatched away.
        DispatchQueue.main.asyncAfter(deadline: .now() + (model.mutedIdle ? 1.2 : 0.8), execute: w)
    }

    // MARK: Level clock (30 Hz, only while Jarvis is live)

    private var live: Bool {
        visible && ui.contentVisible && (model.drop == .over || (!model.mutedIdle && !model.muted
            && (model.phase == .listening || model.phase == .speaking || model.phase == .thinking)))
    }

    private func updateLive() {
        let on = live
        chrome.setLive(on, spin: model.phase == .thinking || model.drop == .over ? 3.2 : 9)
        if on && clock == nil {
            meter.reset()
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            clock = t
        } else if !on { stopClock() }
    }

    private func stopClock() {
        clock?.invalidate(); clock = nil
        ui.bars?.set(level: 0, t: clockT)
    }

    private func tick() {
        clockT += 1.0 / 30
        let thinking = model.phase == .thinking && model.drop == .none
        let e = model.drop == .over ? 0.72 + 0.12 * CGFloat(sin(clockT * 5))
              : thinking ? 0.3 + 0.08 * CGFloat(sin(clockT * 2.4)) : meter.sample(model.orb.targetLevel, dt: 1.0 / 30)
        chrome.setEnergy(e)
        if !thinking { ui.bars?.set(level: e, t: clockT) }
    }

    // MARK: Pointer
    //
    // While Jarvis is up he owns the notch. An invisible, clickable panel sits exactly over his island: Vorssaint's
    // island underneath opens from a tracking area on its own window, so with the pointer on Jarvis's panel it stays
    // closed, and it opens as usual once Jarvis retracts. Coming near the notch (the island plus a band around it)
    // brings out the mic button in the right wing; it tucks away again shortly after the pointer leaves.

    /// Island rect on screen at the size it is heading to.
    private var islandRect: NSRect {
        let g = ui.geometry, s = motion.target
        return NSRect(x: g.screen.midX - s.width / 2, y: g.screen.maxY - s.height, width: s.width, height: s.height)
    }

    /// The mic button's hit area: the right wing's last slot, a little larger than the 22 pt button.
    private var buttonRect: NSRect {
        let g = ui.geometry, s = motion.target
        let cx = g.screen.midX + s.width / 2 - IslandGeometry.inset(s.height) - IslandMuteChip.size / 2
        return NSRect(x: cx - 17, y: g.screen.maxY - g.height, width: 34, height: g.height)
    }

    private func ensureCatcher() -> NSPanel {
        if let c = catcher { return c }
        let v = IslandHitView(frame: .zero)
        v.onMove = { [weak self] in self?.updateHover() }
        v.onDown = { [weak self] in self?.pointerDown() }
        v.onUp = { [weak self] in self?.pointerUp() }
        let c = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        c.isOpaque = false
        c.backgroundColor = .clear
        c.hasShadow = false
        c.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        c.ignoresMouseEvents = false
        c.acceptsMouseMovedEvents = true
        c.becomesKeyOnlyIfNeeded = true
        c.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        c.contentView = v
        catcher = c
        return c
    }

    /// Keeps the catcher on the island while Jarvis is out; gone the moment he retracts.
    private func syncCatcher() {
        guard visible, model.shown, !resting else { catcher?.orderOut(nil); return }
        let c = ensureCatcher()
        let r = islandRect.integral
        if c.frame != r { c.setFrame(r, display: false) }
        if !c.isVisible { c.orderFrontRegardless() }
    }

    private func startTracking() {
        guard monitors.isEmpty else { return }
        // Movement over other apps (the band around the island); over the catcher its own tracking area reports.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in self?.updateHover() }) { monitors.append(g) }
    }

    private func stopTracking() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        catcher?.orderOut(nil)
        hideWork?.cancel(); hideWork = nil
        model.muteHover = false; model.mutePressed = false; model.revealControls = false
    }

    private func pointerDown() {
        updateHover()
        if model.muteHover { model.mutePressed = true }
    }

    private func pointerUp() {
        guard model.mutePressed else { poke(); return }
        model.mutePressed = false
        updateHover()
        guard model.muteHover else { return }
        model.muteToggles += 1
        model.rippleP = 0
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.55)) { self.model.rippleP = 1 } }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        onMuteToggle?()
    }

    /// A click anywhere on the island but the mic button: the orb squashes and springs back. Three within 1.7 s (Coucou's
    /// rule): a dizzy wobble. Visual only, no sound, nothing else changes.
    private func poke() {
        guard islandRect.contains(NSEvent.mouseLocation) else { return }
        let now = CACurrentMediaTime()
        pokeTimes = pokeTimes.filter { now - $0 < 1.7 } + [now]
        if pokeTimes.count >= 3 {
            pokeTimes.removeAll()
            model.dizzies += 1
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        } else {
            model.pokes += 1
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
    }

    /// The mic button has a job whenever Jarvis is listening, working or talking (not during the send countdown,
    /// where esc is the control, nor on the brief sent/cancelled/error notes).
    private var buttonAvailable: Bool {
        model.shown && model.showControls && ui.contentVisible && !(model.phase == .confirming && model.countdownActive)
    }

    private func updateHover() {
        guard let p = panel, p.isVisible, !previewPinned else { return }
        let pt = NSEvent.mouseLocation
        let island = islandRect
        // "Near the notch": the island, 28 pt either side and 40 pt below it.
        let near = NSRect(x: island.minX - 28, y: island.minY - 40, width: island.width + 56, height: island.height + 40)
        if buttonAvailable && near.contains(pt) {
            hideWork?.cancel(); hideWork = nil
            if !model.revealControls {
                model.revealControls = true
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        } else if model.revealControls && hideWork == nil {
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hideWork = nil
                self.model.revealControls = false
                self.updateHover()
            }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + (buttonAvailable ? 0.6 : 0), execute: w)
        }
        let onButton = buttonAvailable && model.revealControls && buttonRect.contains(pt)
        if model.muteHover != onButton { model.muteHover = onButton }
        if !onButton && model.mutePressed { model.mutePressed = false }
    }
}

/// The catcher's content: reports the pointer (tracking areas work while Hey Aside is in the background) and clicks.
final class IslandHitView: NSView {
    var onMove: (() -> Void)?
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onMove?() }
    override func mouseMoved(with event: NSEvent) { onMove?() }
    override func mouseExited(with event: NSEvent) { onMove?() }
    override func mouseDragged(with event: NSEvent) { onMove?() }
    override func mouseDown(with event: NSEvent) { onDown?() }
    override func mouseUp(with event: NSEvent) { onUp?() }
}
