import Foundation

/// Conversions between the generated wire types and the kit's own models.
enum Wire {
    static func date(_ ms: Int64) -> Date? {
        ms > 0 ? Date(timeIntervalSince1970: Double(ms) / 1000) : nil
    }

    static func cap(_ c: Lush_V1_Capability) -> LushCapability? {
        switch c {
        case .vibrate: .vibrate
        case .rotate: .rotate
        case .air: .air
        case .thrust: .thrust
        default: nil
        }
    }

    static func cap(_ c: LushCapability) -> Lush_V1_Capability {
        switch c {
        case .vibrate: .vibrate
        case .rotate: .rotate
        case .air: .air
        case .thrust: .thrust
        }
    }

    static func toy(_ t: Lush_V1_Toy) throws -> LushToy {
        guard let id = UUID(uuidString: t.id), let owner = UUID(uuidString: t.ownerID) else {
            throw LushTransportError.badResponse("bad toy id")
        }
        return LushToy(
            id: id, ownerID: owner, name: t.name, model: t.model,
            caps: Set(t.caps.compactMap(cap)), vibrateMotors: Int(max(1, t.vibrateMotors)),
            owned: t.owned, online: t.online, battery: t.battery >= 0 ? Int(t.battery) : nil,
            driverID: UUID(uuidString: t.driverID), lastSeen: date(t.lastSeenAt), paused: t.paused
        )
    }

    static func grant(_ g: Lush_V1_Grant) throws -> LushGrant {
        guard let id = UUID(uuidString: g.id), let grantee = UUID(uuidString: g.granteeID) else {
            throw LushTransportError.badResponse("bad grant id")
        }
        return LushGrant(id: id, granteeID: grantee, label: g.label, expiresAt: date(g.expiresAt))
    }

    static func command(_ a: ToyAction) -> Lush_V1_ToyCommand {
        var c = Lush_V1_ToyCommand()
        switch a {
        case .vibrate(let level, let motor):
            c.vibrate = .with { $0.level = Int32(level); $0.motor = Int32(motor) }
        case .rotate(let level, let flip):
            c.rotate = .with { $0.level = Int32(level); $0.flip = flip }
        case .air(let level):
            c.air = .with { $0.level = Int32(level) }
        case .thrust(let level):
            c.thrust = .with { $0.level = Int32(level) }
        case .pattern(let name):
            c.pattern = .with { $0.name = name }
        case .curve(let p, let strength, let play):
            c.curve = curve(p)
            c.curve.strength = wireStrength(strength)
            c.curve.play = play
        case .stop:
            c.stop = .init()
        }
        return c
    }

    /// 100% goes on the wire as 0 (the default); the rest clamps to 10–200.
    static func wireStrength(_ s: Int) -> UInt32 { s == 100 ? 0 : UInt32(min(max(s, 10), 200)) }

    /// A keepalive / strength change for a curve the receiver already has.
    static func curveRef(play: String, strength: Int) -> Lush_V1_ToyCommand {
        var c = Lush_V1_ToyCommand()
        c.curveRef = .with { $0.play = play; $0.strength = wireStrength(strength) }
        return c
    }

    /// Seconds → wire milliseconds. Never traps: negative or huge values clamp
    /// (the server rejects the curve rather than the phone crashing).
    static func ms(_ seconds: Double) -> UInt32 {
        guard seconds.isFinite else { return 0 }
        return UInt32(clamping: Int64(max(0, min((seconds * 1000).rounded(), Double(UInt32.max)))))
    }

    static func curve(_ p: LushPattern) -> Lush_V1_Curve {
        var c = Lush_V1_Curve()
        c.id = p.id
        c.name = p.name
        c.points = p.points.map { pt in .with { $0.atMs = ms(pt.at); $0.level = Int32(clamping: pt.level) } }
        c.marks = p.marks.map { m in .with { $0.atMs = ms(m.at); $0.label = m.label } }
        c.loop = p.loop
        c.loopFromMs = ms(p.loopFrom)
        return c
    }

    static func pattern(_ c: Lush_V1_Curve) -> LushPattern {
        LushPattern(
            id: c.id, name: c.name,
            points: c.points.map { .init(at: Double($0.atMs) / 1000, level: Int($0.level)) },
            marks: c.marks.map { .init(at: Double($0.atMs) / 1000, label: $0.label) },
            loop: c.loop, loopFrom: Double(c.loopFromMs) / 1000
        )
    }

    static func ended(_ r: Lush_V1_EndReason) -> LushEndReason? {
        switch r {
        case .finished: .finished
        case .paused: .paused
        case .stopped: .stopped
        case .takenOver: .takenOver
        default: nil
        }
    }

    static func feedback(_ f: LushFeedback) -> Lush_V1_FeedbackKind {
        switch f {
        case .ease: .ease
        case .more: .more
        case .stay: .stay
        }
    }

    static func feedback(_ k: Lush_V1_FeedbackKind) -> LushFeedback? {
        switch k {
        case .ease: .ease
        case .more: .more
        case .stay: .stay
        default: nil
        }
    }

    static func action(_ c: Lush_V1_ToyCommand) -> ToyAction? {
        switch c.action {
        case .vibrate(let v): .vibrate(level: Int(v.level), motor: Int(v.motor))
        case .rotate(let r): .rotate(level: Int(r.level), flip: r.flip)
        case .air(let a): .air(level: Int(a.level))
        case .thrust(let t): .thrust(level: Int(t.level))
        case .pattern(let p): .pattern(p.name)
        case .curve(let c): .curve(pattern(c), strength: c.strength == 0 ? 100 : Int(c.strength), play: c.play)
        case .curveRef: nil // resolved against what's playing (see Receiver.decide)
        case .stop: .stop
        case nil: nil
        }
    }
}
