import Foundation
import Observation

/// What the person wearing the toy says while being driven.
public enum LushFeedback: String, Sendable, CaseIterable {
    /// "Almost": back off now, then rebuild — the edge cycle.
    case ease
    /// Go on: skip to the next phase.
    case more
    /// Exactly this: freeze here (again to resume).
    case stay

    public var title: String {
        switch self {
        case .ease: "Almost"
        case .more: "More"
        case .stay: "Stay"
        }
    }

    public var symbol: String {
        switch self {
        case .ease: "wind"
        case .more: "forward.fill"
        case .stay: "pause.fill"
        }
    }

    /// How the driver hears it.
    public var driverText: String {
        switch self {
        case .ease: "is close — easing off"
        case .more: "wants more"
        case .stay: "wants exactly this"
        }
    }
}

/// Plays a custom pattern on a toy connected to this phone, ~10 times a second,
/// and lets her feedback move it: Almost eases down and pauses, then rebuilds;
/// More jumps to the next phase; Stay freezes. Runs entirely on her phone — no
/// round trip between her tap and the toy. Time is monotonic (ContinuousClock):
/// changing the phone's clock can't jump or rewind it. Once finished it is
/// inert: nothing it is told can turn the toy back on.
@MainActor
@Observable
public final class CurvePlayer {
    public typealias Instant = ContinuousClock.Instant

    public let pattern: LushPattern
    public private(set) var playhead: Double = 0
    public private(set) var frozen = false
    /// When an "Almost" started (nil when not easing).
    public private(set) var easingSince: Instant?
    public private(set) var finished = false
    /// The level last sent to the toy.
    public private(set) var output = 0
    /// How hard the curve plays: 1 = as designed (0.1–2; levels clamp to 0–20).
    public private(set) var strength: Double = 1

    /// Called once, when a curve without a loop reaches its end (the toy has
    /// just been stopped).
    @ObservationIgnored var onFinish: (() -> Void)?

    @ObservationIgnored private weak var toy: (any LocalToy)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var last: Instant
    @ObservationIgnored private var elapsed: Double = 0

    /// Ease: fall to this share of the curve quickly, hold (paused), then rebuild.
    static let easeFloor = 0.3
    static let easeDrop: Double = 0.6
    static let easeHold: Double = 8
    static let easeRebuild: Double = 4

    init(pattern: LushPattern, toy: any LocalToy, strength: Int = 100, now: Instant = .now) {
        self.pattern = pattern
        self.toy = toy
        self.strength = Self.clamp(strength)
        self.last = now
    }

    static func clamp(_ percent: Int) -> Double { Double(min(max(percent, 10), 200)) / 100 }

    /// The driver moved the strength: keep the playhead, change the levels.
    func setStrength(_ percent: Int, now: Instant = .now) {
        guard !finished else { return }
        strength = Self.clamp(percent)
        tick(now)
    }

    func start() {
        last = .now
        tick(.now)
        guard !finished else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.tick(.now)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func apply(_ f: LushFeedback, now: Instant = .now) {
        guard !finished else { return }
        switch f {
        case .ease:
            easingSince = now
            frozen = false
        case .more:
            easingSince = nil
            frozen = false
            if let next = pattern.nextMark(after: playhead) {
                elapsed = next.at
            } else {
                elapsed = min(pattern.duration, playhead + 15)
            }
            playhead = pattern.position(after: elapsed)
        case .stay:
            frozen.toggle()
            easingSince = nil
        }
        tick(now)
    }

    /// The share of the curve played right now (1 = as designed).
    func modifier(at now: Instant) -> (scale: Double, advancing: Bool) {
        guard let since = easingSince else { return (1, !frozen) }
        let s = Self.seconds(now - since)
        if s < Self.easeHold {
            let k = min(s / Self.easeDrop, 1)
            return (1 - (1 - Self.easeFloor) * k, false)
        }
        if s < Self.easeHold + Self.easeRebuild {
            let k = (s - Self.easeHold) / Self.easeRebuild
            return (Self.easeFloor + (1 - Self.easeFloor) * k, true)
        }
        return (1, true)
    }

    func tick(_ now: Instant) {
        guard !finished else { return }
        let dt = max(0, Self.seconds(now - last))
        last = now
        let (scale, advancing) = modifier(at: now)
        if let since = easingSince, Self.seconds(now - since) >= Self.easeHold + Self.easeRebuild { easingSince = nil }
        if advancing { elapsed += dt }
        playhead = pattern.position(after: elapsed)
        if !pattern.loop, elapsed >= pattern.duration {
            finished = true
            toy?.apply(.stop)
            output = 0
            stop()
            onFinish?()
            onFinish = nil
            return
        }
        let level = min(ToyAction.maxLevel, Int((pattern.level(at: playhead) * scale * strength).rounded()))
        if level != output || toy?.current.isStop == true {
            output = level
            toy?.apply(.vibrate(level: level))
        }
    }

    static func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
