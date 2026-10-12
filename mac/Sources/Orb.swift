import AppKit
import MetalKit
import SwiftUI

// Fluid Orb, native Metal port of Rare UI's "Fluid Orb" (https://www.rareui.com/components/fluidorb),
// by Swami Malode, MIT + Commons Clause, attribution required: credited in the menu (About) and README.
// Changes from the web version: voice level ("energy") speeds the drift and deepens the shading,
// and rendering is paused whenever the orb is hidden, so the idle cost is zero.

enum OrbPalette: String, CaseIterable {
    case jarvis, aside, blue, red, green
    var title: String {
        switch self { case .jarvis: return "Jarvis Blue"; case .aside: return "Aside Orange"; case .blue: return "Blue"; case .red: return "Red"; case .green: return "Green" }
    }
    var rgb: SIMD3<Float> {
        switch self {
        case .jarvis: return SIMD3(0x0B, 0x86, 0xFF) / 255    // arc-reactor blue
        case .aside: return SIMD3(0xF7, 0x50, 0x01) / 255
        case .blue: return SIMD3(0x1A, 0x73, 0xF2) / 255
        case .red: return SIMD3(0xFF, 0x3B, 0x30) / 255
        case .green: return SIMD3(0x34, 0xC7, 0x59) / 255
        }
    }
    var color: Color { Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z)) }
}

private struct OrbUniforms {
    var color: SIMD4<Float>
    var res: SIMD2<Float>
    var time: Float
    var energy: Float
    var desat: Float
    var scale: Float
    var glow: Float
    var tint: Float = 0
    var pad1: Float = 0
}

private let fluidOrbShader = """
#include <metal_stdlib>
using namespace metal;

struct U { float4 color; float2 res; float time; float energy; float desat; float scale; float glow; float tint; float pad1; };
struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut orb_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = p; return o;   // uv.y = 0 at bottom, like gl_FragCoord
}

static float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123); }

static float noise(float2 p) {
    float2 i = floor(p); float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), u.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
}

static float fbm(float2 p) {
    float v = 0.0, a = 0.6;
    for (int i = 0; i < 2; i++) { v += a * noise(p); p *= 2.0; a *= 0.5; }
    v += 0.15 * 0.5;   // 3rd octave replaced by its mean: at ~60 px it only reads as grain
    return v;
}

fragment float4 orb_fragment(VOut in [[stage_in]], constant U &u [[buffer(0)]]) {
    // The orb fills `scale` of the view; the rest is room for the halo and swell.
    float2 uv = (in.uv - 0.5) / u.scale + 0.5;
    float t = u.time * 0.22;
    float2 drift = float2(sin(t) + 0.6 * sin(t * 1.7 + 1.3), cos(t * 0.8) + 0.6 * cos(t * 1.3 + 2.1));
    float2 p = float2(uv.x * 1.8, uv.y) + drift * 0.7;
    float2 q = float2(fbm(p + drift), fbm(p + float2(3.2, 1.5) - drift));
    float f = fbm(p + (1.2 + 0.15 * u.energy) * q);

    float g = clamp(1.0 - uv.y, 0.0, 1.0);
    float anchor = smoothstep(0.0, 0.3, uv.y);
    float shade = clamp(g + (f - 0.5) * (0.8 + 0.1 * u.energy) * anchor, 0.0, 1.0);
    // Tint (island): pull the white cap down to a soft highlight so, at 18 pt on black, it reads as a lit blue sphere.
    shade = clamp(shade * (1.0 - 0.28 * u.tint) + 0.34 * u.tint, 0.0, 1.0);

    float3 c = u.color.rgb;
    float3 white = float3(0.99, 1.0, 1.0);
    float3 col = mix(white, mix(white, c, 0.5), smoothstep(0.28, 0.52, shade));
    col = mix(col, c, smoothstep(0.58, 0.88, shade));
    col = mix(col, float3(dot(col, float3(0.299, 0.587, 0.114))), u.desat);

    float r = 0.5 * u.scale;
    float d = distance(in.uv, float2(0.5));
    float edge = smoothstep(r, r - 1.2 / u.res.x, d);
    // Soft contact shadow (keeps the white top readable on white pages) and a colored halo that grows with your voice.
    float sh = smoothstep(r + 0.07, r - 0.02, distance(in.uv, float2(0.5, 0.485))) * 0.16;
    float hd = distance(in.uv, float2(0.5, 0.47));
    float h = pow(smoothstep(0.5, r * 0.9, hd), 3.0) * u.glow;
    float3 rgb = c * h;
    float a = h + sh * (1.0 - h);
    rgb = col * edge + rgb * (1.0 - edge);
    a = edge + a * (1.0 - edge);
    return float4(rgb, a);
}
"""

/// Plain reference state shared with the renderer; updating it never re-renders SwiftUI.
final class OrbState {
    var targetLevel: Float = 0
    var palette: OrbPalette = .aside
    var calm = false        // countdown / done: slow, steady drift
    var desaturate = false  // cancelled / error
}

final class OrbRenderer: NSObject, MTKViewDelegate {
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    let state: OrbState
    private var last = CACurrentMediaTime()
    private var energy: Float = 0
    private var desat: Float = 0
    private var t: Float = Float.random(in: 0...40)
    var frames = 0
    var tint: Float = 0

    init?(device: MTLDevice, state: OrbState) {
        guard let q = device.makeCommandQueue(),
              let lib = try? device.makeLibrary(source: fluidOrbShader, options: OrbRenderer.compileOptions()),
              let vf = lib.makeFunction(name: "orb_vertex"), let ff = lib.makeFunction(name: "orb_fragment") else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vf; d.fragmentFunction = ff
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        queue = q; pipeline = p; self.state = state
    }

    /// Precise math: the orb's sin-based hash turns into spiky noise under GPU fast-math.
    static func compileOptions() -> MTLCompileOptions {
        let o = MTLCompileOptions()
        if #available(macOS 15.0, *) { o.mathMode = .safe } else { o.fastMathEnabled = false }
        return o
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.05, now - last)); last = now
        // VU-style smoothing: quick attack, slow release, so the orb swells with words and settles between them.
        let target = state.calm ? 0 : min(1, state.targetLevel * 1.8)
        energy += (target - energy) * min(1, (target > energy ? 12 : 3.5) * dt)
        desat += ((state.desaturate ? 1 : 0) - desat) * min(1, 6 * dt)
        t += dt * (state.calm ? 0.9 : 1.2 + energy * 2.2)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { t = 12 }
        frames += 1

        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let c = state.palette.rgb
        var u = OrbUniforms(color: SIMD4(c, 1), res: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                            time: t, energy: energy, desat: desat,
                            scale: 0.62 + 0.07 * energy, glow: (0.06 + 0.30 * energy) * (1 - desat), tint: tint)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<OrbUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    /// Smoothed energy for SwiftUI-side scale/glow (read by a TimelineView only while visible).
    var smoothedEnergy: Float { energy }
}

/// Keeps the drawable matched to the view. SwiftUI may lay the view out at zero size first and not call
/// updateNSView again once it has its real size; a stale 2x2 drawable then stretches into a flat square (Sep 28).
final class OrbMTKView: MTKView {
    func syncDrawable() {
        let scale = max(2, window?.backingScaleFactor ?? 2)
        let want = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if drawableSize != want { drawableSize = want }
        drawFirstFrameIfPaused()
    }
    /// A view that starts paused (Jarvis summoned while muted) would otherwise show nothing at all: give it one still
    /// frame, the frozen orb, as soon as it has a size.
    func drawFirstFrameIfPaused() {
        guard isPaused, bounds.width > 0, window != nil, (delegate as? OrbRenderer)?.frames == 0 else { return }
        draw()
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); syncDrawable() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); syncDrawable() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); syncDrawable() }
}

struct OrbView: NSViewRepresentable {
    let state: OrbState
    let running: Bool
    /// The island's orb is ~18 pt: its slow drift reads the same at 30 fps for half the GPU and CPU.
    var fps = 60
    /// 0 = the floating orb's white-capped look; 1 = the island's deeper, bluer small-size look.
    var tint: Float = 0

    final class Coordinator { var renderer: OrbRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let v = OrbMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        v.colorPixelFormat = .bgra8Unorm
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        v.framebufferOnly = true
        v.preferredFramesPerSecond = fps
        v.enableSetNeedsDisplay = false
        (v.layer as? CAMetalLayer)?.isOpaque = false
        if let dev = v.device, let r = OrbRenderer(device: dev, state: state) {
            r.tint = tint
            context.coordinator.renderer = r
            v.delegate = r
        } else {
            Log.write("orb: Metal unavailable; orb hidden")
        }
        v.autoResizeDrawable = false
        v.isPaused = !running
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {
        // Always render at >= 2x so edges and gradients stay smooth on 1x external displays (tiny: ~200x200 px).
        (v as? OrbMTKView)?.syncDrawable()
        context.coordinator.renderer?.tint = tint
        v.isPaused = !running
        (v as? OrbMTKView)?.drawFirstFrameIfPaused()
    }
}
