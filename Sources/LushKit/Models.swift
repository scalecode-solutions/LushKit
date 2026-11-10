import Foundation

extension LushToy {
    /// A copy with live state changed.
    func with(online: Bool, driverID: UUID?) -> LushToy {
        LushToy(id: id, ownerID: ownerID, name: name, model: model, caps: caps, vibrateMotors: vibrateMotors,
                owned: owned, online: online, battery: battery, driverID: driverID, lastSeen: lastSeen, paused: paused)
    }
}

/// What a toy can do.
public enum LushCapability: String, Sendable, Hashable, CaseIterable {
    case vibrate, rotate, air, thrust
}

/// A toy the signed-in user may see: their own, or a partner's they were granted.
public struct LushToy: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let ownerID: UUID
    public let name: String
    public let model: String
    public let caps: Set<LushCapability>
    public let vibrateMotors: Int
    /// True if the user owns it (vs. was granted control).
    public let owned: Bool
    /// The owner's phone has it connected right now.
    public let online: Bool
    /// 0–100, nil when unknown.
    public let battery: Int?
    /// Who is driving it right now, if anyone.
    public let driverID: UUID?
    public let lastSeen: Date?
    /// She stopped it on her phone: nothing but Stop runs until she resumes.
    public let paused: Bool

    public init(id: UUID, ownerID: UUID, name: String, model: String, caps: Set<LushCapability>,
                vibrateMotors: Int = 1, owned: Bool, online: Bool, battery: Int? = nil,
                driverID: UUID? = nil, lastSeen: Date? = nil, paused: Bool = false) {
        self.id = id
        self.ownerID = ownerID
        self.name = name
        self.model = model
        self.caps = caps
        self.vibrateMotors = vibrateMotors
        self.owned = owned
        self.online = online
        self.battery = battery
        self.driverID = driverID
        self.lastSeen = lastSeen
        self.paused = paused
    }
}

/// One thing to do to a toy. The kit's own type: the wire (`Lush_V1_ToyCommand`)
/// and the Lovense strings (`Lovense.commands`) both map from it.
public enum ToyAction: Sendable, Equatable, Hashable {
    /// motor 0 = all motors.
    case vibrate(level: Int, motor: Int = 0)
    case rotate(level: Int, flip: Bool = false)
    case air(level: Int)
    case thrust(level: Int)
    /// A built-in pattern; see `ToyAction.patterns`. Plays until stopped.
    case pattern(String)
    /// A custom pattern, played by the phone wearing the toy, at `strength`
    /// percent of its designed levels (10–200). `play` names this run of it:
    /// the same play with a new strength adjusts the playing curve; a new play
    /// starts it over. Leave it empty and the engine starts a new run.
    case curve(LushPattern, strength: Int = 100, play: String = "")
    case stop

    public static let patterns = ["pulse", "wave", "fireworks", "earthquake"]
    public static let maxLevel = 20
    public static let maxAir = 5

    public var isStop: Bool { self == .stop }

    /// A level of zero: the toy is idle, so it needn't be held.
    public var isIdle: Bool {
        switch self {
        case .vibrate(let l, _), .rotate(let l, _), .air(let l), .thrust(let l): l == 0
        case .pattern, .curve: false
        case .stop: true
        }
    }

    /// 0…1: how strong this is, for visuals.
    public var intensity: Double {
        switch self {
        case .vibrate(let l, _), .rotate(let l, _), .thrust(let l): Double(l) / Double(Self.maxLevel)
        case .air(let l): Double(l) / Double(Self.maxAir)
        case .pattern, .curve: 0.6
        case .stop: 0
        }
    }

    /// Short human description ("Vibrate 12", "Pattern wave", "Stop").
    public var label: String {
        switch self {
        case .vibrate(let l, let m): m == 0 ? "Vibrate \(l)" : "Vibrate\(m) \(l)"
        case .rotate(let l, let f): f ? "Rotate \(l) ↺" : "Rotate \(l)"
        case .air(let l): "Air \(l)"
        case .thrust(let l): "Thrust \(l)"
        case .pattern(let p): "Pattern \(p)"
        case .curve(let c, let s, _): s == 100 ? c.name : "\(c.name) \(s)%"
        case .stop: "Stop"
        }
    }
}

/// An owner's grant letting another user drive all the owner's toys.
public struct LushGrant: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let granteeID: UUID
    public let label: String
    public let expiresAt: Date?

    public init(id: UUID, granteeID: UUID, label: String, expiresAt: Date?) {
        self.id = id
        self.granteeID = granteeID
        self.label = label
        self.expiresAt = expiresAt
    }
}

/// Someone the user may grant to (a friend in the social graph).
public struct LushContact: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let name: String
    public let avatar: Data?

    public init(id: UUID, name: String, avatar: Data? = nil) {
        self.id = id
        self.name = name
        self.avatar = avatar
    }
}

/// One row of the owner's audit history.
public struct LushEvent: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let toyID: UUID?
    /// "online" | "offline" (a phone), "toy_added" | "toy_online" | "toy_offline" |
    /// "toy_removed", "grant" | "revoke", "driving" (a stretch of control starts) |
    /// "stopped" (it ends: detail is "<why> · <how long>"), "paused" | "resumed".
    public let kind: String
    public let actorID: UUID?
    public let at: Date
    public let detail: String

    public init(id: UUID, toyID: UUID?, kind: String, actorID: UUID?, at: Date, detail: String) {
        self.id = id
        self.toyID = toyID
        self.kind = kind
        self.actorID = actorID
        self.at = at
        self.detail = detail
    }
}

extension LushEvent {
    /// How a history row reads: what happened, and a smaller note beside it.
    /// `actor` is the name of whoever did it ("You", "Sam"); a kind this build
    /// doesn't know still reads as its own words.
    public func line(actor: String) -> (title: String, note: String) {
        switch kind {
        case "driving": return ("\(actor) started driving", "")
        case "stopped":
            let parts = detail.components(separatedBy: " · ")
            let why = parts.first ?? ""
            let length = parts.count > 1 ? parts[1] : ""
            let title: String
            switch why {
            case "let go": title = "\(actor) let go"
            case "timed out": title = "\(actor) went quiet"
            case "driver offline": title = "\(actor) dropped off"
            case "stopped by owner", "stopped by someone else": title = "\(actor) stopped it"
            case "taken over": title = "\(actor) took over"
            case "toy offline": title = "Toy disconnected mid-drive"
            case "access ended": title = "Access ended mid-drive"
            case "pattern finished": title = "Pattern finished"
            case "paused by owner": title = "\(actor) paused it mid-drive"
            case "toy forgotten": title = "Toy removed mid-drive"
            default: title = why.isEmpty ? "Stopped" : "Stopped: \(why)"
            }
            return (title, length.isEmpty ? "" : "after \(length)")
        case "paused": return ("\(actor) paused it", "")
        case "resumed": return ("\(actor) resumed it", "")
        case "toy_added": return ("Toy added", detail)
        case "toy_online": return ("Toy connected", detail)
        case "toy_offline": return ("Toy disconnected", detail)
        case "toy_removed": return ("Toy removed", detail)
        case "online": return ("Phone online", detail)
        case "offline": return ("Phone offline", detail)
        case "grant": return ("Shared", "")
        case "revoke": return ("Sharing ended", detail == "expired" ? "expired" : "")
        default: return (kind.replacingOccurrences(of: "_", with: " "), "")
        }
    }
}

/// Why something a controller was driving stopped, other than its own Stop.
public enum LushEndReason: Sendable, Equatable {
    /// A pattern without a loop reached its end.
    case finished
    /// She stopped it on her phone; it stays paused until she resumes.
    case paused
    /// Someone else (the owner, another partner) stopped it.
    case stopped
    /// Someone else started driving it, so this run ended.
    case takenOver

    /// "Sam paused it" — prefixed with the person's first name.
    public var text: String {
        switch self {
        case .finished: "pattern finished"
        case .paused: "paused it"
        case .stopped: "stopped it"
        case .takenOver: "took over"
        }
    }
}
