import Foundation
import Observation

/// A toy connected to THIS phone — the receiver side. The engine publishes these
/// to the server and applies incoming commands to them. `SimulatedToy` is one
/// (for the simulator, which has no Bluetooth); `BluetoothToy` is the real one.
@MainActor
public protocol LocalToy: AnyObject {
    /// Stable hardware identity (the Lovense device address). Unique per owner.
    var hwKey: String { get }
    var model: String { get }
    var name: String { get }
    var caps: Set<LushCapability> { get }
    var vibrateMotors: Int { get }
    /// 0–100, nil when unknown.
    var battery: Int? { get }
    var firmware: String { get }
    /// What it's doing right now (the last action applied).
    var current: ToyAction { get }
    /// Do it to the hardware now.
    func apply(_ action: ToyAction)
}

/// A pretend toy: remembers what it was told so a UI can show it. Lets the whole
/// loop (partner → server → this phone → "toy") run on a simulator.
@MainActor
@Observable
public final class SimulatedToy: LocalToy {
    public let hwKey: String
    public let model = "simulated"
    public let name: String
    public let caps: Set<LushCapability> = [.vibrate, .rotate]
    public let vibrateMotors = 1
    public var battery: Int? = 100
    public let firmware = "sim"

    /// What the toy is doing right now.
    public private(set) var current: ToyAction = .stop
    public private(set) var changedAt = Date()
    /// Every action, newest first (for the lab's log).
    public private(set) var history: [(at: Date, action: ToyAction)] = []

    public init(hwKey: String, name: String = "Simulated toy") {
        self.hwKey = hwKey
        self.name = name
    }

    public func apply(_ action: ToyAction) {
        current = action
        changedAt = Date()
        history.insert((changedAt, action), at: 0)
        if history.count > 40 { history.removeLast() }
    }

    /// 0…1 for a meter.
    public var intensity: Double { current.intensity }
}
