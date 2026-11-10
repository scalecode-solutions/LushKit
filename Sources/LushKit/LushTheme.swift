import SwiftUI

/// LushKit's look: "Aurora". A slow, living mesh gradient tinted by intensity —
/// cool violet at rest, magenta in the middle, hot pink-coral at full — with
/// glass floating over it. Built like GarageKit's backdrop: it follows the
/// host's color scheme (neutral edges, black-ish in dark, near-white in light),
/// only the middle carries the tint, an opaque base keeps the host from
/// bleeding through, it redraws at 12 fps, and it's static under Reduce Motion.
public enum LushPalette {
    /// The accent that follows intensity (0…1): glows, rings, the trail, the tint.
    public static func accent(_ intensity: Double) -> Color {
        let t = min(max(intensity, 0), 1)
        let cool = Color.hex(0x8B6CFF), mid = Color.hex(0xE0459E), heat = Color.hex(0xFF6F5E)
        return t < 0.5 ? cool.mix(with: mid, by: t * 2) : mid.mix(with: heat, by: (t - 0.5) * 2)
    }
}

/// The living background. Warms and quickens with intensity.
public struct AuroraBackground: View {
    var intensity: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    public init(intensity: Double) {
        self.intensity = intensity
    }

    private var dark: Bool { colorScheme == .dark }
    private var edge: Color { dark ? .black : Color(white: 0.97) }
    private var rim: Color { dark ? Color(white: 0.06) : Color(white: 0.93) }
    private var base: Color { dark ? .black : .white }

    public var body: some View {
        let i = min(max(intensity, 0), 1)
        let tint = LushPalette.accent(i)
        // At rest the glow is a whisper; at full it floods the middle and
        // reaches into the bottom rim.
        let core = (dark ? 0.30 : 0.22) + i * (dark ? 0.50 : 0.45)
        let side = 0.08 + i * 0.30
        let low = rim.mix(with: tint, by: i * (dark ? 0.45 : 0.35))
        TimelineView(.animation(minimumInterval: 1 / 12, paused: reduceMotion)) { ctx in
            let t = reduceMotion ? 0 : Float(ctx.date.timeIntervalSinceReferenceDate) * Float(1 + i * 1.5)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5 + 0.08 * sin(t * 0.35)],
                    [0.5 + 0.14 * sin(t * 0.27), 0.48 + 0.12 * cos(t * 0.31)],
                    [1, 0.5 + 0.08 * cos(t * 0.29)],
                    [0, 1], [0.5 + 0.10 * sin(t * 0.23), 1], [1, 1],
                ],
                colors: [
                    edge, rim, edge,
                    tint.opacity(side), tint.opacity(core), tint.opacity(side),
                    edge, low, edge,
                ]
            )
        }
        .background(base)
        .animation(.smooth(duration: 0.6), value: intensity)
        .ignoresSafeArea()
    }
}

extension Color {
    static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// A frosted card over the aurora.
struct GlassCard<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(tint.map { .regular.tint($0.opacity(0.25)) } ?? .regular, in: .rect(cornerRadius: 24))
    }
}

/// How each built-in pattern moves over time, as 0…1. Our own approximation of
/// the toy's built-ins (Lovense doesn't publish the curves); the chips and the
/// live trail both draw from it, so what you tap is what you see.
enum PatternShape {
    /// Seconds per cycle: the glyph draws two of them.
    static func period(_ name: String) -> Double {
        switch name {
        case "pulse": 1.0
        case "wave": 2.4
        case "fireworks": 2.4
        case "earthquake": 3.0
        default: 1
        }
    }

    static func value(_ name: String, at t: Double) -> Double {
        let p = period(name)
        let phase = t.truncatingRemainder(dividingBy: p) / p // 0…1 within a cycle
        let v: Double
        switch name {
        case "pulse":
            // A beat: quick rise, hold, quick fall, rest.
            let edge = 0.08
            if phase < edge { v = 0.12 + 0.76 * (phase / edge) }
            else if phase < 0.45 { v = 0.88 }
            else if phase < 0.45 + edge { v = 0.88 - 0.76 * ((phase - 0.45) / edge) }
            else { v = 0.12 }
        case "wave":
            v = 0.5 - 0.38 * cos(phase * 2 * .pi)
        case "fireworks":
            // A burst that crackles and fades.
            let env = exp(-phase * 3.2)
            v = 0.12 + 0.82 * env * (0.55 + 0.45 * abs(sin(phase * 2 * .pi * 7)))
        case "earthquake":
            let x = t * 2 * .pi / p
            v = 0.52 + 0.22 * sin(x * 3.1) + 0.14 * sin(x * 7.7 + 1.3) + 0.09 * sin(x * 17.9 + 0.4)
        default:
            v = 0.5
        }
        return min(max(v, 0), 1)
    }
}

/// A tiny drawing of a pattern: two cycles of its shape.
struct PatternGlyph: Shape {
    let name: String

    func path(in r: CGRect) -> Path {
        var p = Path()
        let span = PatternShape.period(name) * 2
        let steps = 64
        for i in 0...steps {
            let x = Double(i) / Double(steps)
            let v = PatternShape.value(name, at: x * span)
            let pt = CGPoint(x: r.minX + x * r.width, y: r.maxY - v * r.height)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }
}

/// A tiny drawing of a custom pattern's whole curve.
struct CurveGlyph: Shape {
    let pattern: LushPattern

    func path(in r: CGRect) -> Path {
        var p = Path()
        let d = max(pattern.duration, 0.001)
        for (i, pt) in pattern.points.enumerated() {
            let x = r.minX + pt.at / d * r.width
            let y = r.maxY - Double(pt.level) / Double(ToyAction.maxLevel) * r.height
            i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
        }
        return p
    }
}

/// A person's face, or their initial on a soft disc.
struct Avatar: View {
    let name: String
    let data: Data?
    var size: CGFloat = 44
    var ring: Color? = nil

    var body: some View {
        Group {
            if let data, let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Text(String(name.first ?? "•").uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.primary.opacity(0.10))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay {
            if let ring {
                Circle().stroke(ring, lineWidth: 2).padding(-4)
                    .shadow(color: ring.opacity(0.8), radius: 6)
            }
        }
    }
}
