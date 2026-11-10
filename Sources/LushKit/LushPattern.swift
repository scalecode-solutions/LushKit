import Foundation

/// A custom pattern: an intensity envelope over time, with named phases.
/// Lovense toys can't store these, so the phone wearing the toy plays it.
public struct LushPattern: Identifiable, Sendable, Equatable, Hashable {
    public struct Point: Sendable, Equatable, Hashable {
        /// Seconds from the start.
        public var at: Double
        /// 0–20.
        public var level: Int

        public init(at: Double, level: Int) {
            self.at = at
            self.level = level
        }
    }

    public struct Mark: Sendable, Equatable, Hashable {
        public var at: Double
        public var label: String

        public init(at: Double, label: String) {
            self.at = at
            self.label = label
        }
    }

    /// Server id once saved; "" for a draft.
    public var id: String
    public var name: String
    public var points: [Point]
    public var marks: [Mark]
    public var loop: Bool
    public var loopFrom: Double

    public init(id: String = "", name: String, points: [Point], marks: [Mark] = [], loop: Bool = false, loopFrom: Double = 0) {
        self.id = id
        self.name = name
        self.points = points
        self.marks = marks
        self.loop = loop
        self.loopFrom = loopFrom
    }

    public var isSaved: Bool { !id.isEmpty }
    public var duration: Double { points.last?.at ?? 0 }

    /// The level at a time (linear between points), as 0…20.
    public func level(at t: Double) -> Double {
        guard let first = points.first else { return 0 }
        if t <= first.at { return Double(first.level) }
        guard let i = points.firstIndex(where: { $0.at > t }) else { return Double(points.last!.level) }
        let a = points[i - 1], b = points[i]
        let k = (t - a.at) / (b.at - a.at)
        return Double(a.level) + (Double(b.level) - Double(a.level)) * k
    }

    /// Where a playhead lands after running `elapsed` seconds (looping if set).
    public func position(after elapsed: Double) -> Double {
        guard loop, elapsed > duration, duration > loopFrom else { return min(elapsed, duration) }
        let span = duration - loopFrom
        return loopFrom + (elapsed - duration).truncatingRemainder(dividingBy: span)
    }

    /// The next phase after t, if any.
    public func nextMark(after t: Double) -> Mark? {
        marks.first { $0.at > t + 0.5 }
    }

    /// The phase t is in.
    public func phase(at t: Double) -> Mark? {
        marks.last { $0.at <= t }
    }

    /// Whether the curve could be saved/sent (mirrors the server's rules).
    public var isValid: Bool {
        guard (2...600).contains(points.count), points.first?.at == 0, duration <= 3600 else { return false }
        for (a, b) in zip(points, points.dropFirst()) where b.at <= a.at { return false }
        guard points.allSatisfy({ (0...ToyAction.maxLevel).contains($0.level) }) else { return false }
        for (a, b) in zip(marks, marks.dropFirst()) where b.at <= a.at { return false }
        if marks.contains(where: { $0.at > duration }) || marks.count > 20 { return false }
        if loop && loopFrom >= duration { return false }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

public extension LushPattern {
    /// A starting point built from the research (notebook: pattern-research):
    /// warm-up in bursts (bursts raise arousal more consistently than continuous
    /// vibration early on) → a slow build → two edge cycles (approach, back off,
    /// rebuild) → a steady, continuous plateau (continuous works better once
    /// arousal plateaus; consistency matters) → a gentle taper. Gentle on
    /// purpose: most women prefer lighter over firmer. ~6 minutes. Meant to be
    /// reshaped by hand.
    static func researchTemplate(name: String = "Signature") -> LushPattern {
        var p: [Point] = []
        var marks: [Mark] = []
        var t = 0.0
        func add(_ dt: Double, _ level: Int) {
            t = ((t + dt) * 10).rounded() / 10 // tenths, so marks land exactly on points
            p.append(Point(at: t, level: level))
        }
        p.append(Point(at: 0, level: 0))

        // Warm-up: bursts that grow longer and a little stronger.
        marks.append(Mark(at: 0, label: "Warm-up"))
        for i in 0..<12 {
            let on = 1.5 + Double(i) * 0.15, rest = 2.0 - Double(i) * 0.08
            let lvl = 5 + i / 3
            add(0.3, lvl); add(on, lvl); add(0.3, 2); add(rest, 2)
        }
        // Build: rising swells.
        marks.append(Mark(at: t, label: "Build"))
        for i in 0..<8 {
            let base = 7 + i
            add(4, base + 3); add(4, base)
        }
        // Edge ×2: climb, hold at the brink, drop well back, rest, rebuild.
        for n in 1...2 {
            marks.append(Mark(at: t, label: "Edge \(n)"))
            add(14, 17 + n); add(5, 17 + n); add(2.5, 6); add(9, 6); add(18, 14)
        }
        // Plateau: steady and continuous — don't change what works.
        marks.append(Mark(at: t, label: "Plateau"))
        add(6, 17); add(150, 17)
        // Taper: a long, soft landing.
        marks.append(Mark(at: t, label: "Afterglow"))
        add(12, 8); add(18, 3); add(10, 0)

        return LushPattern(name: name, points: p, marks: marks)
    }
}

// MARK: - House presets

/// Builds a curve a segment at a time. Times are kept to tenths so phase marks
/// land exactly on points and survive the wire's milliseconds.
struct CurveBuilder {
    private(set) var points: [LushPattern.Point] = [.init(at: 0, level: 0)]
    private(set) var marks: [LushPattern.Mark] = []
    private(set) var t = 0.0
    var loopFrom: Double?

    mutating func phase(_ label: String) { marks.append(.init(at: t, label: label)) }
    /// Move to `level` over `dt` seconds (a straight line).
    mutating func to(_ level: Int, over dt: Double) {
        t = ((t + dt) * 10).rounded() / 10
        points.append(.init(at: t, level: min(max(level, 0), ToyAction.maxLevel)))
    }
    /// Stay at the current level for `dt` seconds.
    mutating func hold(_ dt: Double) { to(points.last!.level, over: dt) }
    /// A burst: snap up, hold, snap down, rest.
    mutating func burst(_ level: Int, on: Double, rest: Double, floor: Int) {
        to(level, over: 0.3); hold(on); to(floor, over: 0.3); hold(rest)
    }
    mutating func loopHere() { loopFrom = t }

    func pattern(id: String, name: String) -> LushPattern {
        LushPattern(id: id, name: name, points: points, marks: marks, loop: loopFrom != nil, loopFrom: loopFrom ?? 0)
    }
}

public extension LushPattern {
    /// Patterns that ship with LushKit, designed from the research (notebook:
    /// pattern-research): bursts while arousal builds, continuous once it
    /// plateaus; a slow build; edging (approach, back off, rebuild); gentle
    /// overall (most prefer lighter); consistency once something works. They
    /// play on her phone like any custom pattern, so her Almost/More/Stay and
    /// the driver's strength both apply. Read-only: duplicate to change one.
    static let house: [LushPattern] = [slowBurn, tease, swell, steady]

    static let houseIDPrefix = "house:"
    /// One of the presets that ship with the kit (not stored on the server).
    var isHouse: Bool { id.hasPrefix(Self.houseIDPrefix) }

    /// An editable copy: unsaved, so saving it makes a new pattern of your own.
    func duplicate(name: String? = nil) -> LushPattern {
        var p = self
        p.id = ""
        p.name = name ?? (self.name + " (mine)")
        return p
    }

    /// Long and patient: lingering low bursts, a very slow build, a long steady
    /// stretch, a soft landing. ~11 min.
    static let slowBurn: LushPattern = {
        var b = CurveBuilder()
        b.phase("Wake")
        for i in 0..<16 {
            b.burst(3 + i / 4, on: 1.2 + Double(i) * 0.12, rest: 3.0 - Double(i) * 0.12, floor: 1)
        }
        b.phase("Build")
        for i in 0..<12 { // rising swells, each a little higher than the last
            let base = 5 + i * 9 / 11
            b.to(base + 3, over: 8); b.to(base, over: 7)
        }
        b.phase("Steady")
        b.to(15, over: 15); b.hold(240)
        b.phase("Land")
        b.to(9, over: 20); b.to(4, over: 25); b.to(0, over: 15)
        return b.pattern(id: houseIDPrefix + "slow-burn", name: "Slow Burn")
    }()

    /// Edging: a quick warm-up, then three edges (each a little higher and
    /// held a little longer), then a long release. Pairs with her Almost. ~8 min.
    static let tease: LushPattern = {
        var b = CurveBuilder()
        b.phase("Warm-up")
        for i in 0..<8 { b.burst(5 + i / 2, on: 1.5 + Double(i) * 0.2, rest: 1.6, floor: 2) }
        b.to(9, over: 20); b.to(12, over: 30)
        for n in 1...3 {
            b.phase("Edge \(n)")
            b.to(15 + n, over: 35)      // climb
            b.hold(4 + Double(n) * 2)   // linger at the brink
            b.to(5, over: 2)            // back off, fast
            b.hold(10)                  // let it settle
            b.to(12, over: 25)          // rebuild
        }
        b.phase("Release")
        b.to(19, over: 20); b.hold(100)
        b.phase("Afterglow")
        b.to(7, over: 15); b.to(2, over: 20); b.to(0, over: 10)
        return b.pattern(id: houseIDPrefix + "tease", name: "Tease")
    }()

    /// Advance and withdraw: waves that grow longer, higher and fuller, then
    /// keep rolling at the top (loops). ~6 min to the top.
    static let swell: LushPattern = {
        var b = CurveBuilder()
        b.phase("Ripples")
        for i in 0..<6 { b.to(6 + i / 2, over: 2 + Double(i) * 0.3); b.to(1, over: 2) }
        b.phase("Waves")
        for i in 0..<10 {
            let peak = 8 + i, trough = 2 + i * 6 / 9
            b.to(peak, over: 4 + Double(i) * 0.8); b.to(trough, over: 4 + Double(i) * 0.6)
        }
        b.phase("Rolling")
        b.loopHere()
        for _ in 0..<3 { b.to(18, over: 9); b.hold(2); b.to(11, over: 7) }
        return b.pattern(id: houseIDPrefix + "swell", name: "Swell")
    }()

    /// A short warm-up, then one even level that never changes. Plays until
    /// stopped; strength sets how strong. For when one thing just works.
    static let steady: LushPattern = {
        var b = CurveBuilder()
        b.phase("Ease in")
        for i in 0..<5 { b.burst(4 + i, on: 1.5, rest: 1.5, floor: 2) }
        b.to(13, over: 30)
        b.phase("Steady")
        b.loopHere()
        b.hold(60)
        return b.pattern(id: houseIDPrefix + "steady", name: "Steady")
    }()
}
