@preconcurrency import CoreBluetooth
import Foundation
import Observation

/// A real toy connected to this phone over Bluetooth.
@MainActor
@Observable
public final class BluetoothToy: LocalToy {
    public let hwKey: String
    public let model: String
    public let name: String
    public let caps: Set<LushCapability>
    public let vibrateMotors: Int
    public let firmware: String
    public internal(set) var battery: Int?
    public private(set) var current: ToyAction = .stop

    /// CoreBluetooth's id for it on this phone.
    public let peripheralID: UUID
    @ObservationIgnored private let write: @MainActor (String) -> Void

    init(hwKey: String, kind: Lovense.Kind, name: String, firmware: String, peripheralID: UUID,
         write: @escaping @MainActor (String) -> Void) {
        self.hwKey = hwKey
        self.model = kind.model
        self.caps = kind.caps
        self.vibrateMotors = kind.motors
        self.name = name
        self.firmware = firmware
        self.peripheralID = peripheralID
        self.write = write
    }

    /// Which way it's turning: the toy only has a toggle, so the phone keeps count.
    @ObservationIgnored private var flipped = false

    public func apply(_ action: ToyAction) {
        // A built-in pattern runs until it's told to end.
        if case .pattern = current, action != current { write(Lovense.endPreset) }
        if case .rotate(_, let flip) = action, flip != flipped {
            flipped = flip
            write(Lovense.rotateChange)
        }
        current = action
        for command in Lovense.commands(for: action, caps: caps) { write(command) }
    }
}

/// Finds Lovense toys, connects them, and puts each one in service on the
/// engine (`engine.host`). A dropped link takes it out again.
///
/// Nothing touches Bluetooth until `scan()` is first called, so the
/// permission prompt only appears when the user asks to connect a toy. The
/// host passes its system-dialog guard: iOS makes the app inactive while the
/// prompt is up, and a host that locks on inactive must not treat that as
/// leaving.
@MainActor
@Observable
public final class LushBluetooth: NSObject {
    public enum Availability: Sendable, Equatable {
        /// Bluetooth hasn't been touched yet.
        case idle
        case starting
        case ready
        case poweredOff
        /// The user said no (Settings → the app → Bluetooth).
        case denied
        case unsupported
    }

    /// A toy seen while scanning.
    public struct Found: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let name: String
        public let model: String
        public var rssi: Int
        public var seen: Date
    }

    public private(set) var availability: Availability = .idle
    public private(set) var isScanning = false
    /// Toys in range that aren't connected, strongest signal first.
    public private(set) var found: [Found] = []
    public private(set) var connecting: Set<UUID> = []
    /// Toys connected and in service.
    public private(set) var toys: [BluetoothToy] = []
    /// The last thing that went wrong, in plain words (cleared on the next try).
    public private(set) var lastError: String?

    @ObservationIgnored private let engine: LushEngine
    @ObservationIgnored private let beginSystemDialog: @MainActor () -> Void
    @ObservationIgnored private let endSystemDialog: @MainActor () -> Void
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var promptOpen = false
    @ObservationIgnored private var wantsScan = false
    @ObservationIgnored private var sessions: [UUID: Session] = [:]
    @ObservationIgnored private var seen: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var pruneTask: Task<Void, Never>?
    @ObservationIgnored private var batteryTask: Task<Void, Never>?

    static let connectTimeout: Duration = .seconds(15)
    static let identifyTimeout: Duration = .seconds(3)
    static let batteryInterval: Duration = .seconds(90)
    /// A toy not heard from for this long leaves the scan list.
    static let staleAfter: TimeInterval = 8

    /// One peripheral's connection, from `connect` until it drops.
    private final class Session {
        let peripheral: CBPeripheral
        let advertisedName: String
        var tx: CBCharacteristic?
        var rx: CBCharacteristic?
        var knownTx: CBUUID?
        var knownRx: CBUUID?
        var probing = 0
        var parser = Lovense.Parser()
        var toy: BluetoothToy?
        var timeout: Task<Void, Never>?
        init(peripheral: CBPeripheral, advertisedName: String) {
            self.peripheral = peripheral
            self.advertisedName = advertisedName
        }
    }

    public init(engine: LushEngine,
                beginSystemDialog: @escaping @MainActor () -> Void = {},
                endSystemDialog: @escaping @MainActor () -> Void = {}) {
        self.engine = engine
        self.beginSystemDialog = beginSystemDialog
        self.endSystemDialog = endSystemDialog
        super.init()
    }

    // MARK: scanning

    /// Start looking for toys. The first call ever shows the system's Bluetooth
    /// prompt.
    public func scan() {
        lastError = nil
        wantsScan = true
        if central == nil {
            availability = .starting
            if CBCentralManager.authorization == .notDetermined {
                promptOpen = true
                beginSystemDialog()
            }
            // Main queue: every delegate call lands on the main actor.
            central = CBCentralManager(delegate: self, queue: nil)
            return // centralManagerDidUpdateState starts the scan
        }
        startScanIfReady()
    }

    public func stopScan() {
        wantsScan = false
        central?.stopScan()
        isScanning = false
        pruneTask?.cancel()
        pruneTask = nil
        found = []
    }

    private func startScanIfReady() {
        guard wantsScan, let central, central.state == .poweredOn else { return }
        // By name, not by service: the service families change with firmware.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
        if pruneTask == nil {
            pruneTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    self?.pruneFound()
                }
            }
        }
    }

    private func pruneFound() {
        let cutoff = Date().addingTimeInterval(-Self.staleAfter)
        found.removeAll { $0.seen < cutoff && !connecting.contains($0.id) }
    }

    // MARK: connecting

    /// Connect a toy from `found` and put it in service.
    public func connect(_ id: UUID) {
        guard let central, central.state == .poweredOn, sessions[id] == nil, let peripheral = seen[id] else { return }
        lastError = nil
        let name = found.first { $0.id == id }?.name ?? peripheral.name ?? "Toy"
        let session = Session(peripheral: peripheral, advertisedName: name)
        sessions[id] = session
        connecting.insert(id)
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        session.timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.connectTimeout)
            guard !Task.isCancelled else { return }
            self?.fail(id, "Couldn't connect. Check the toy is on and close by.")
        }
    }

    /// Stop and disconnect one toy.
    public func disconnect(hwKey: String) {
        guard let (id, _) = sessions.first(where: { $0.value.toy?.hwKey == hwKey }) else { return }
        drop(id)
    }

    /// Stop and disconnect every toy, and stop scanning (sign-out, or the host
    /// going away).
    public func shutdown() {
        stopScan()
        for id in Array(sessions.keys) { drop(id) }
    }

    /// Take a toy out of service (the engine stops it first), then cut the link.
    private func drop(_ id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.timeout?.cancel()
        connecting.remove(id)
        if let toy = session.toy {
            engine.unhost(hwKey: toy.hwKey) // applies Stop while the link is still up
            toys.removeAll { $0.hwKey == toy.hwKey }
        }
        central?.cancelPeripheralConnection(session.peripheral)
        updateBatteryPolling()
    }

    private func fail(_ id: UUID, _ message: String) {
        guard sessions[id] != nil else { return }
        lastError = message
        drop(id)
    }

    private func write(_ text: String, to id: UUID) {
        guard let s = sessions[id], let tx = s.tx, s.peripheral.state == .connected else { return }
        let type: CBCharacteristicWriteType = tx.properties.contains(.write) ? .withResponse : .withoutResponse
        s.peripheral.writeValue(Data(text.utf8), for: tx, type: type)
    }

    /// The link is up and notifying: ask what it is, then put it in service.
    private func identify(_ id: UUID) {
        guard let s = sessions[id] else { return }
        s.timeout?.cancel()
        // First thing: have the toy stop itself if this link ever drops.
        write(Lovense.stopOnDisconnect, to: id)
        write(Lovense.deviceType, to: id)
        // A toy that never answers still works: it's keyed by this phone's id for it.
        s.timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.identifyTimeout)
            guard !Task.isCancelled else { return }
            self?.ready(id, letter: nil, firmware: "", address: nil)
        }
    }

    private func ready(_ id: UUID, letter: String?, firmware: String, address: String?) {
        guard let s = sessions[id], s.toy == nil else { return }
        s.timeout?.cancel()
        s.timeout = nil
        let kind = Lovense.kind(advertisedName: s.advertisedName, letter: letter)
        let toy = BluetoothToy(hwKey: Lovense.hwKey(address: address, peripheralID: id), kind: kind,
                               name: Self.displayName(kind), firmware: firmware, peripheralID: id) { [weak self] text in
            self?.write(text, to: id)
        }
        s.toy = toy
        connecting.remove(id)
        found.removeAll { $0.id == id }
        toys.append(toy)
        toy.apply(.stop) // whatever it was doing before we connected, it stops
        engine.host(toy)
        write(Lovense.battery, to: id)
        updateBatteryPolling()
    }

    static func displayName(_ kind: Lovense.Kind) -> String {
        switch kind.model {
        case "lush4": "Lush 4"
        case "toy": "Toy"
        default: kind.model.prefix(1).uppercased() + kind.model.dropFirst()
        }
    }

    private func updateBatteryPolling() {
        if toys.isEmpty {
            batteryTask?.cancel()
            batteryTask = nil
        } else if batteryTask == nil {
            batteryTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.batteryInterval)
                    guard let self, !Task.isCancelled else { return }
                    for id in self.sessions.keys { self.write(Lovense.battery, to: id) }
                }
            }
        }
    }

    private func handle(_ frame: Lovense.Frame, from id: UUID) {
        guard let s = sessions[id] else { return }
        switch frame {
        case .deviceType(let letter, let firmware, let address):
            ready(id, letter: letter, firmware: firmware, address: address)
        case .battery(let percent):
            guard let toy = s.toy, toy.battery != percent else { return }
            toy.battery = percent
            engine.publishLocalToys()
        case .ok, .error, .other:
            break
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension LushBluetooth: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if promptOpen, central.state != .unknown, central.state != .resetting {
            promptOpen = false
            endSystemDialog()
        }
        switch central.state {
        case .poweredOn:
            availability = .ready
            startScanIfReady()
        case .poweredOff:
            availability = .poweredOff
            lost()
        case .unauthorized:
            availability = .denied
            lost()
        case .unsupported:
            availability = .unsupported
        default:
            availability = .starting
        }
    }

    /// Bluetooth went away: every link is gone with it.
    private func lost() {
        isScanning = false
        found = []
        for id in Array(sessions.keys) { drop(id) }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let id = peripheral.identifier
        guard Lovense.isToyName(name), sessions[id]?.toy == nil else { return }
        seen[id] = peripheral
        let now = Date()
        if let i = found.firstIndex(where: { $0.id == id }) {
            // The list would churn at the advertising rate; update at most once a second.
            guard now.timeIntervalSince(found[i].seen) >= 1 else { return }
            found[i].rssi = RSSI.intValue
            found[i].seen = now
        } else {
            found.append(Found(id: id, name: name, model: Self.displayName(Lovense.kind(advertisedName: name)),
                               rssi: RSSI.intValue, seen: now))
        }
        found.sort { $0.rssi > $1.rssi }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard sessions[peripheral.identifier] != nil else { return }
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail(peripheral.identifier, "Couldn't connect. Check the toy is on and close by.")
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        guard let s = sessions[id] else { return }
        if s.toy == nil { lastError = "The toy disconnected before it was ready." }
        drop(id)
    }
}

// MARK: - CBPeripheralDelegate

extension LushBluetooth: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let id = peripheral.identifier
        guard let s = sessions[id] else { return }
        let services = peripheral.services ?? []
        if error != nil || services.isEmpty {
            fail(id, "This toy isn't answering. Turn it off and on, then try again.")
            return
        }
        // A known family: its write / notify characteristics are known too.
        for service in services {
            if let known = Lovense.channel(forService: service.uuid.uuidString) {
                s.knownTx = CBUUID(string: known.tx)
                s.knownRx = CBUUID(string: known.rx)
                s.probing = 1
                peripheral.discoverCharacteristics(nil, for: service)
                return
            }
        }
        // Unknown firmware: look in every non-standard service for a writable
        // characteristic and a notifying one.
        let candidates = services.filter { !Lovense.isStandardService($0.uuid.uuidString) }
        guard !candidates.isEmpty else {
            fail(id, "This doesn't look like a toy this app can drive.")
            return
        }
        s.probing = candidates.count
        candidates.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let id = peripheral.identifier
        guard let s = sessions[id], s.rx == nil || s.tx == nil else { return }
        let chars = service.characteristics ?? []
        if let knownTx = s.knownTx, let knownRx = s.knownRx {
            s.tx = s.tx ?? chars.first { $0.uuid == knownTx }
            s.rx = s.rx ?? chars.first { $0.uuid == knownRx }
        }
        // Fall back to what each characteristic can do.
        s.tx = s.tx ?? chars.first { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }
        s.rx = s.rx ?? chars.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }

        if let rx = s.rx, s.tx != nil {
            s.probing = 0
            peripheral.setNotifyValue(true, for: rx)
            return
        }
        s.probing -= 1
        if s.probing <= 0 { fail(id, "This doesn't look like a toy this app can drive.") }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        guard let s = sessions[id], characteristic.uuid == s.rx?.uuid, s.toy == nil else { return }
        if error != nil {
            fail(id, "This toy isn't answering. Turn it off and on, then try again.")
            return
        }
        identify(id)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        guard let s = sessions[id], characteristic.uuid == s.rx?.uuid, let data = characteristic.value else { return }
        for frame in s.parser.feed(data) { handle(frame, from: id) }
    }
}
