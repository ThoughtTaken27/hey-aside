import AppKit
import CoreText
import SwiftUI

// The orb is the interface (after ChatGPT voice mode; orb from rareui.com).
// - Orb blooms in at the top center, swells and drifts faster while you talk (Metal, one pass incl. halo).
// - One line of text under it, only once there are words. Dark glass, hairline border, soft shadow.
// - Countdown = a thin ring drawn around the orb in the orb's color; "esc" keycap shows it can be stopped.
// - Sent: check inside the orb, then the whole thing lifts and fades. Cancelled: orb greys out and shrinks.
// Motion values: bloom spring 0.42/0.78, exits 220 ms ease-out, text swaps 4 px rise + 2 px blur (transitions.dev).

final class HUDModel: ObservableObject {
    enum Phase: Equatable { case listening, confirming, thinking, speaking, sent, cancelled, error }
    @Published var phase: Phase = .listening { didSet { syncOrb() } }
    @Published var status: String = "Listening"
    @Published var transcript: String = "" { didSet { if transcript.isEmpty != oldValue.isEmpty { syncOrb() } } }
    /// Mic fully off (Sep 25). The orb greys and stops rendering while nothing else is happening.
    @Published var muted = false { didSet { syncOrb() } }
    @Published var muteHover = false
    /// Dim prompt shown right after the wake phrase until your words arrive ("Yes, sir?").
    @Published var hint = ""
    /// Pointer is over the orb (or the revealed button): the button slides out. Hidden the rest of the time (Sep 25).
    @Published var revealControls = false
    /// Bumped on every mute toggle: drives the ripple.
    @Published var muteToggles = 0
    @Published var rippleP: CGFloat = 1
    @Published var mutePressed = false
    @Published var orbFrozen = false
    /// Sep 30 (Coucou pass): a file or link being dragged toward the notch, and what was dropped (shown until you speak).
    @Published var drop: DropCatcher.Phase = .none
    @Published var attachment = ""
    /// Bumped to play the orb's one-shot moves: swallowing a drop, a poke, three quick pokes.
    @Published var gulps = 0
    @Published var pokes = 0
    @Published var dizzies = 0
    private var freezeWork: DispatchWorkItem?
    var mutedIdle: Bool { muted && phase == .listening && transcript.isEmpty }
    var showControls: Bool { !(phase == .sent || phase == .cancelled || phase == .error) && drop == .none }

    func syncOrb() {
        orb.desaturate = mutedIdle || phase == .cancelled || phase == .error
        orb.calm = mutedIdle || !(phase == .listening || phase == .speaking)
        freezeWork?.cancel()
        if mutedIdle {
            // Let the grey fade finish, then stop drawing: a muted orb costs no GPU.
            let w = DispatchWorkItem { [weak self] in if self?.mutedIdle == true { self?.orbFrozen = true } }
            freezeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: w)
        } else if orbFrozen { orbFrozen = false }
    }
    @Published var shown = false
    @Published var countdown: CGFloat = 0
    @Published var countdownActive = false
    /// Mic level goes straight to the Metal renderer; it never triggers a SwiftUI re-render.
    var level: CGFloat = 0 { didSet { orb.targetLevel = Float(level) } }
    let orb = OrbState()
}

enum Typeface {
    /// Aside's own UI font (Geist, SIL OFL), registered process-locally from the installed Aside app so text matches Aside.
    static let registered: Bool = {
        let dir = "/Applications/Aside.app/Contents/Frameworks/Aside Framework.framework/Resources/"
        for f in ["Geist-Regular.ttf", "Geist-Medium.ttf"] {
            CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: dir + f) as CFURL, .process, nil)
        }
        return NSFont(name: "Geist-Regular", size: 12) != nil
    }()
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard registered else { return .system(size: size, weight: weight) }
        return .custom(weight == .regular ? "Geist-Regular" : "Geist-Medium", size: size)
    }
}

private struct BlurRise: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View { content.blur(radius: active ? 2 : 0).offset(y: active ? 4 : 0).opacity(active ? 0 : 1) }
}
private extension AnyTransition {
    static var blurRise: AnyTransition { .modifier(active: BlurRise(active: true), identity: BlurRise(active: false)) }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .vibrantDark)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct OrbHUDView: View {
    @ObservedObject var m: HUDModel
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private let orbBox: CGFloat = 100     // view size; the orb itself is ~62 pt, the rest is halo
    private let ringSize: CGFloat = 74

    var body: some View {
        VStack(spacing: 0) {
            orb
            if showPill {
                pill
                    .padding(.top, 2)
                    .transition(.blurRise.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
        .opacity(m.shown ? 1 : 0)
        .offset(y: m.shown ? 0 : (m.phase == .sent ? -10 : 0))
        .scaleEffect(m.shown ? 1 : (m.phase == .sent ? 1 : 0.9), anchor: .top)
        .animation(m.shown ? .spring(response: 0.42, dampingFraction: 0.82) : .easeOut(duration: 0.22), value: m.shown)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: showPill)
        .animation(.easeOut(duration: 0.16), value: pillText)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: m.phase)
    }

    private var showPill: Bool { !pillText.isEmpty }
    private var showingHint: Bool { m.phase == .listening && m.transcript.isEmpty && !m.hint.isEmpty && !m.mutedIdle }
    /// Mute button: to the right of the orb, centered on it (HUDController.muteCenter must match).
    static let muteOffset: CGFloat = 58
    private var live: Bool { m.phase == .listening }
    private let maxText: CGFloat = 500
    private var caption: Text {
        Text(pillText)
            .font(Typeface.font(14.5))
            .foregroundColor(Color.white.opacity(m.phase == .cancelled || m.mutedIdle ? 0.6 : (m.phase == .thinking || showingHint ? 0.55 : 0.93)))
    }

    private var pillText: String {
        switch m.phase {
        case .cancelled, .error: return m.status
        default:
            if m.mutedIdle { return "Muted" }
            if m.phase == .listening && m.transcript.isEmpty { return m.hint }
            return m.transcript
        }
    }

    private var orb: some View {
        ZStack {
            if m.showControls {
                // Tucked behind the orb until you hover it, then springs out to the right.
                let out = m.revealControls
                MuteButton(m: m)
                    .scaleEffect(out ? 1 : 0.45)
                    .blur(radius: out || reduceMotion ? 0 : 3)
                    .opacity(out ? 1 : 0)
                    .offset(x: out ? OrbHUDView.muteOffset : (reduceMotion ? OrbHUDView.muteOffset : 16))
                    .rotationEffect(.degrees(out || reduceMotion ? 0 : -25))
                    .animation(out ? .spring(response: 0.38, dampingFraction: 0.66) : .spring(response: 0.26, dampingFraction: 0.9), value: out)
                    .allowsHitTesting(false)
            }
            OrbView(state: m.orb, running: m.shown && !m.orbFrozen)
                .frame(width: orbBox, height: orbBox)
                .scaleEffect(m.revealControls && !m.muteHover ? 1.035 : 1)
                .animation(.spring(response: 0.34, dampingFraction: 0.7), value: m.revealControls)
                .animation(.spring(response: 0.34, dampingFraction: 0.7), value: m.muteHover)
                .allowsHitTesting(false)
            if m.muted && m.showControls {
                // Muted state lives on the orb itself, so it's clear even with the button tucked away.
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(m.mutedIdle ? 0.58 : 0.45))
                    .shadow(color: .white.opacity(0.35), radius: 0.5, y: 0.5)
                    .transition(.asymmetric(insertion: .scale(scale: 0.3).combined(with: .opacity), removal: .scale(scale: 1.4).combined(with: .opacity)))
            }
            if m.phase == .confirming && m.countdownActive {
                let c = m.orb.palette.color
                ZStack {
                    Circle().stroke(c.opacity(0.18), lineWidth: 2)
                    Circle().trim(from: 0, to: m.countdown)
                        .stroke(c, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: ringSize, height: ringSize)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
            if m.phase == .sent {
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.28), radius: 4, y: 1)
                    .offset(y: 3)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: orbBox, height: orbBox)
        // Bloom in from small; shrink a little on cancel.
        .scaleEffect(m.shown ? (m.phase == .cancelled || m.phase == .error ? 0.86 : 1) : (reduceMotion ? 1 : 0.45))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: m.showControls)
        .animation(.spring(response: 0.34, dampingFraction: 0.62), value: m.muted)
    }

    private var pill: some View {
        HStack(spacing: 10) {
            if live {
                // Live captions: one line. If it's too long, newest words stay visible and older ones fade out left.
                ViewThatFits(in: .horizontal) {
                    caption.lineLimit(1).fixedSize()
                    caption.lineLimit(1).fixedSize()
                        .frame(width: maxText, alignment: .trailing)
                        .clipped()
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1)], startPoint: .leading, endPoint: .trailing))
                }
                .frame(maxWidth: maxText)
                .fixedSize()
            } else if m.phase == .speaking || m.phase == .thinking {
                // Always one line: captions arrive pre-split to fit; steps are short. Each new line rises in.
                caption.lineLimit(1).truncationMode(.tail).fixedSize()
                    .id(pillText)
                    .transition(.blurRise)
                    .modifier(ShimmerIf(on: m.phase == .thinking))
            } else {
                // Short: hug the words. Long: wrap to two centered lines.
                ViewThatFits(in: .horizontal) {
                    caption.lineLimit(1).fixedSize()
                    caption
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .lineSpacing(2)
                        .frame(width: maxText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: maxText)
                .fixedSize()
                .modifier(ShimmerIf(on: m.phase == .thinking))
            }
            if m.phase == .thinking {
                ThinkingDots().transition(.opacity)
            }
            if m.phase == .confirming && m.countdownActive {
                Text("esc")
                    .font(Typeface.font(10.5, .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                    .transition(.opacity)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, m.phase == .confirming && m.countdownActive ? 10 : 16)
        .padding(.vertical, 9)
        .frame(minHeight: 36)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            ZStack { VisualEffect(); Color(white: 0.06).opacity(0.78) }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).inset(by: 1).strokeBorder(LinearGradient(colors: [Color.white.opacity(0.06), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                .shadow(color: .black.opacity(0.10), radius: 1.5, y: 1)
        )
    }
}

extension HUDController {
    /// Splits text into lines that fit the pill (measured with the pill's font), breaking between words.
    static func captionLines(_ text: String, maxWidth: CGFloat = 440) -> [String] {
        let font = (Typeface.registered ? NSFont(name: "Geist-Regular", size: 14.5) : nil) ?? .systemFont(ofSize: 14.5)
        func w(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        var lines: [String] = [], cur = ""
        for word in text.split(separator: " ").map(String.init) {
            let next = cur.isEmpty ? word : cur + " " + word
            if w(next) <= maxWidth || cur.isEmpty { cur = next; continue }
            // Break at a sentence end rather than leave the next sentence's first word or two dangling ("...umbrella. It").
            var parts = cur.split(separator: " ").map(String.init)
            if let end = parts.lastIndex(where: { $0.last.map { ".?!".contains($0) } ?? false }),
               end < parts.count - 1, parts.count - 1 - end <= 3, end >= 3 {
                let tail = parts[(end + 1)...].joined(separator: " ")
                parts.removeSubrange((end + 1)...)
                lines.append(parts.joined(separator: " "))
                cur = tail + " " + word
            } else { lines.append(cur); cur = word }
        }
        if !cur.isEmpty { lines.append(cur) }
        // Avoid a lonely last word: pull one word down from the previous line when it fits.
        if lines.count >= 2, !lines[lines.count - 1].contains(" ") {
            var prev = lines[lines.count - 2].split(separator: " ").map(String.init)
            if prev.count > 2, let moved = prev.popLast() {
                let merged = moved + " " + lines[lines.count - 1]
                if w(merged) <= maxWidth { lines[lines.count - 2] = prev.joined(separator: " "); lines[lines.count - 1] = merged }
            }
        }
        return lines
    }
}

/// Floating, non-activating, click-through panel. Never steals focus from the Aside popup.
final class HUDController {
    let model = HUDModel()
    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?
    private let panelSize = NSSize(width: 600, height: 190)
    var onMuteToggle: (() -> Void)? { didSet { island.onMuteToggle = onMuteToggle } }
    /// Jarvis in the Dynamic Island (default) or the original floating orb; both read the same model.
    lazy var island = IslandController(model: model)
    private var activeStyle: HUDStyle = .island
    private var monitors: [Any] = []
    /// Button center in view coordinates (top-left origin): orb center (top padding 4 + half the 100 pt box) + offset.
    private var muteCenter: CGPoint { CGPoint(x: panelSize.width / 2 + OrbHUDView.muteOffset, y: 4 + 50) }
    private var muteScreenRect: NSRect {
        guard let f = panel?.frame else { return .zero }
        return NSRect(x: f.minX + muteCenter.x - 19, y: f.maxY - muteCenter.y - 19, width: 38, height: 38)
    }

    /// Only the button takes clicks: the panel stays click-through until the pointer is over it.
    private func startTracking() {
        guard monitors.isEmpty else { return }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in self?.updateHover() }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged], handler: { [weak self] e in
            guard let self else { return e }
            self.updateHover()
            guard e.window === self.panel else { return e }
            switch e.type {
            case .leftMouseDown where self.model.muteHover:
                self.model.mutePressed = true
                return nil
            case .leftMouseUp where self.model.mutePressed:
                self.model.mutePressed = false
                if self.model.muteHover {
                    self.model.muteToggles += 1
                    self.model.rippleP = 0
                    DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.55)) { self.model.rippleP = 1 } }
                    self.onMuteToggle?()
                }
                return nil
            default: return e
            }
        }) { monitors.append(l) }
        updateHover()
    }

    private func stopTracking() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        panel?.ignoresMouseEvents = true
        hideWork?.cancel(); hideWork = nil
        model.muteHover = false; model.mutePressed = false; model.revealControls = false
    }

    private var hideWork: DispatchWorkItem?

    /// Orb circle (plus the button and the gap to it once revealed) = hover zone.
    private func inRevealZone(_ pt: NSPoint) -> Bool {
        guard let f = panel?.frame else { return false }
        let c = NSPoint(x: f.minX + panelSize.width / 2, y: f.maxY - 54)
        if hypot(pt.x - c.x, pt.y - c.y) <= 40 { return true }
        return model.revealControls && NSRect(x: c.x, y: c.y - 24, width: OrbHUDView.muteOffset + 24, height: 48).contains(pt)
    }

    /// Screenshot previews: keep the preview's hover state instead of tracking the real pointer.
    var previewPinned = false { didSet { island.previewPinned = previewPinned } }

    private func updateHover() {
        guard let p = panel, !previewPinned else { return }
        let pt = NSEvent.mouseLocation
        let active = p.isVisible && model.shown && model.showControls
        let zone = active && inRevealZone(pt)
        if zone {
            hideWork?.cancel(); hideWork = nil
            if !model.revealControls { model.revealControls = true }
        } else if model.revealControls && hideWork == nil {
            // Short grace so it doesn't flicker when the pointer grazes the edge.
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hideWork = nil
                if !self.inRevealZone(NSEvent.mouseLocation) { self.model.revealControls = false; self.updateHover() }
            }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
        }
        let onButton = active && model.revealControls && muteScreenRect.contains(pt)
        if p.ignoresMouseEvents == onButton { p.ignoresMouseEvents = !onButton }
        if model.muteHover != onButton { model.muteHover = onButton }
        if !onButton && model.mutePressed { model.mutePressed = false }
    }

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }
        let host = NSHostingView(rootView: OrbHUDView(m: model))
        host.frame = NSRect(origin: .zero, size: panelSize)
        let p = NSPanel(contentRect: host.frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = host
        panel = p
        return p
    }

    /// `anchor`: the Aside popup frame in CG (top-left origin) coordinates; the orb sits just below it.
    func present(anchor: CGRect?) {
        guard Settings.shared.hud else { return }
        dismissWork?.cancel()
        model.orb.palette = Settings.shared.orbPalette
        model.syncOrb()
        let style = Settings.shared.hudStyle
        if style != activeStyle {
            // Switched in the menu while something was showing: take the other surface down first.
            if style == .island { panel?.orderOut(nil); stopTracking() } else { island.hide() }
            activeStyle = style
        }
        if style == .island {
            island.present()
            if !model.shown { DispatchQueue.main.async { self.model.shown = true } }
            return
        }
        let p = ensurePanel()
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let origin: NSPoint
        if let a = anchor {
            origin = NSPoint(x: a.midX - panelSize.width / 2, y: primaryH - a.maxY - panelSize.height + 2)
        } else {
            let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            origin = NSPoint(x: vf.midX - panelSize.width / 2, y: vf.maxY - panelSize.height)
        }
        p.setFrameOrigin(origin)
        if !p.isVisible { p.orderFrontRegardless() }
        if !model.shown { DispatchQueue.main.async { self.model.shown = true } }
        startTracking()
    }

    func startCountdown(_ seconds: TimeInterval) {
        model.orb.calm = true
        guard seconds > 0 else { model.countdownActive = false; return }
        model.countdown = 0
        model.countdownActive = true
        DispatchQueue.main.async { withAnimation(.linear(duration: seconds)) { self.model.countdown = 1 } }
    }

    func dismiss(after delay: TimeInterval) {
        dismissWork?.cancel()
        model.orb.calm = true
        model.countdownActive = false
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.model.shown = false
            // The island retracts into the camera box on a spring (~0.35 s); the orb just fades.
            DispatchQueue.main.asyncAfter(deadline: .now() + (self.activeStyle == .island ? 0.5 : 0.26)) {
                guard !self.model.shown else { return }
                self.panel?.orderOut(nil)   // also pauses the orb: zero GPU while hidden
                self.island.hide()
                self.stopTracking()
                self.model.transcript = ""
                self.model.hint = ""
                self.model.phase = .listening
                self.model.status = "Listening"
            }
        }
        dismissWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}


/// Round mic toggle beside the orb. Dark glass like the pill; muted = soft red with a slashed mic.
/// Hover and press come from HUDController's mouse tracking (the panel is click-through everywhere else).
struct MuteButton: View {
    @ObservedObject var m: HUDModel
    private let size: CGFloat = 30
    private let red = Color(red: 0.93, green: 0.27, blue: 0.29)

    var body: some View {
        ZStack {
            if m.muted {
                Circle().fill(LinearGradient(colors: [red.opacity(0.98), Color(red: 0.80, green: 0.18, blue: 0.21)], startPoint: .top, endPoint: .bottom))
            } else {
                ZStack { VisualEffect(); Color(white: 0.06).opacity(m.muteHover ? 0.62 : 0.78) }.clipShape(Circle())
            }
            Circle().strokeBorder(Color.white.opacity(m.muted ? 0.22 : (m.muteHover ? 0.22 : 0.10)), lineWidth: 1)
            Circle().inset(by: 1).strokeBorder(LinearGradient(colors: [Color.white.opacity(m.muted ? 0.25 : 0.07), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            Image(systemName: m.muted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(m.muted ? 1 : (m.muteHover ? 0.95 : 0.72)))
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(.bounce, value: m.muteToggles)
        }
        .frame(width: size, height: size)
        .background(Ripple(p: m.rippleP, color: m.muted ? red : .white))
        .shadow(color: (m.muted ? red : .black).opacity(m.muted ? 0.35 : 0.2), radius: m.muted ? 8 : 10, y: 4)
        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
        .scaleEffect(m.mutePressed ? 0.88 : (m.muteHover ? 1.07 : 1))
        .animation(.spring(response: 0.22, dampingFraction: 0.62), value: m.mutePressed)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: m.muteHover)
        .animation(.easeOut(duration: 0.18), value: m.muted)
    }
}

/// One soft ring that expands and fades from the button when you toggle mute (red when muting, white when unmuting).
struct Ripple: View {
    let p: CGFloat
    let color: Color
    var body: some View {
        Circle()
            .stroke(color.opacity(0.7 * (1 - p)), lineWidth: 2 * (1 - p) + 0.5)
            .scaleEffect(1 + 0.9 * p)
            .allowsHitTesting(false)
    }
}

/// Three soft dots that breathe in sequence while Aside works. Only drawn in the thinking state.
struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    let p = (sin((t * 2 * .pi / 1.2) - Double(i) * 0.9) + 1) / 2
                    Circle()
                        .fill(Color.white.opacity(0.28 + 0.5 * p))
                        .frame(width: 4.5, height: 4.5)
                        .offset(y: -1.5 * p)
                }
            }
        }
        .frame(width: 22, height: 10)
    }
}


/// A soft highlight that sweeps across text while Aside works (the "thinking" state). Drawn only in that state.
struct Shimmer: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                GeometryReader { g in
                    LinearGradient(colors: [.clear, Color.white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.45)
                        .offset(x: (g.size.width * 1.45) * t - g.size.width * 0.45)
                }
            }
            .mask(content)
            .allowsHitTesting(false)
        )
    }
}

struct ShimmerIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View { if on { content.modifier(Shimmer()) } else { content } }
}
