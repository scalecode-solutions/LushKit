import Foundation
import Observation

/// The kit coordinator. Hosts build it inert, `start()` it when the kit's screen
/// comes on and `stop()` it when the screen goes or the app leaves the
/// foreground, and call `wipeLocalStore()` on sign-out. Stopped, it holds no
/// socket and makes no requests: on a day nobody opens the screen, the server
/// never hears from this phone. One engine plays both roles over one live socket:
///
/// - **Receiver** for toys connected to this phone (`host(_:)`): publishes them,
///   applies incoming commands, and enforces the safety rules — drop a command
///   past `deliver_by`, stop a toy when its `hold_until` passes with nothing
///   newer, stop every toy when the socket drops or the engine stops.
/// - **Controller** for toys it may drive (`set(_:on:)`): streams the latest
///   action at ≤ 10 Hz and re-sends a held level every second so it doesn't lapse.
@MainActor
@Observable
public final class LushEngine {
    public enum Connection: Sendable, Equatable {
        case offline
        case connecting
        case online
        /// Lost; reconnecting on its own. The reason is human-readable.
        case retrying(String)
    }

    public struct LogLine: Identifiable, Sendable, Equatable {
        public let id = UUID()
        public let at: Date
        public let text: String
    }

    // MARK: observable state

    public private(set) var connection: Connection = .offline
    /// Every toy the user may see (own + granted), live state included.
    public private(set) var toys: [LushToy] = []
    /// Toys connected to this phone.
    public private(set) var localToys: [any LocalToy] = []
    public private(set) var grants: [LushGrant] = []
    public private(set) var contacts: [LushContact] = []
    public private(set) var events: [LushEvent] = []
    /// What this phone last asked each remote toy to do (for UI echo).
    public private(set) var driving: [UUID: ToyAction] = [:]
    /// Recent receiver/controller happenings, newest first (debug surface).
    public private(set) var log: [LogLine] = []
    /// Server hold window (from Welcome); a level lapses this long after its last send.
    public private(set) var holdWindow: Duration = .seconds(3)
    /// The user's own custom patterns (newest first).
    public private(set) var patterns: [LushPattern] = []

    /// What someone is doing to a toy on THIS phone right now, by hardware key.
    public struct Incoming: Sendable, Equatable {
        public let toyID: String
        public let from: UUID?
        public let action: ToyAction
    }
    public private(set) var incoming: [String: Incoming] = [:]
    /// Custom patterns playing on toys on this phone, by hardware key.
    public private(set) var players: [String: CurvePlayer] = [:]

    /// The latest reaction from someone whose toy this phone is driving.
    public struct FeedbackNote: Identifiable, Sendable, Equatable {
        public let id = UUID()
        public let toyID: UUID
        public let kind: LushFeedback
        public let from: UUID?
        /// Where her phone's curve was (seconds), if one was playing.
        public let playhead: Double
        public let at: Date
    }
    public private(set) var lastFeedback: FeedbackNote?

    /// Toys on this phone she has paused, by hardware key: stopped, and nothing
    /// but Stop runs on them until she resumes.
    public private(set) var paused: Set<String> = []

    /// Where a curve this phone is driving is believed to be: the playhead
    /// (seconds) at a moment. Set when the curve is sent, corrected by her
    /// feedback.
    public struct CurveAnchor: Sendable, Equatable {
        public let playhead: Double
        public let at: Date
    }
    public private(set) var curveAnchors: [UUID: CurveAnchor] = [:]

    /// The latest "what you were driving stopped, and why".
    public struct EndedNote: Identifiable, Sendable, Equatable {
        public let id = UUID()
        public let toyID: UUID
        public let reason: LushEndReason
        public let by: UUID?
        public let at: Date
    }
    public private(set) var lastEnded: EndedNote?

    /// What lifting a finger off the control does. Remembered per user; cleared
    /// by `wipeLocalStore()`.
    public var releaseMode: ReleaseMode {
        didSet {
            guard releaseMode != oldValue else { return }
            defaults.set(releaseMode.rawValue, forKey: releaseKey)
        }
    }

    public let config: LushConfig
    private let transport: any LushTransport
    private let defaults: UserDefaults
    private var releaseKey: String { "LushKit.releaseMode.\(config.currentUserID.uuidString)" }
    private var socket: LiveSocket?
    private var listenTask: Task<Void, Never>?
    /// Bumped by stop(): work started before it must not write after it.
    private var generation = 0

    // receiver
    private var clockOffset: TimeInterval = 0 // server − local
    private var watchdogs: [String: Task<Void, Never>] = [:] // hwKey → hold timer
    /// The command each local toy is under (what keepalive repeats are compared to).
    private var active: [String: ToyAction] = [:]

    // controller
    private var seq: UInt64 = 0
    private var lastSent: [UUID: Date] = [:]
    private var pendingSend: [UUID: Task<Void, Never>] = [:]
    private var keepalive: Task<Void, Never>?
    /// The curve run (play) each remote toy's phone already has in full; after
    /// the first send, keepalives and strength changes send only a CurveRef.
    private var curveSent: [UUID: String] = [:]
    /// Outgoing frames, in order.
    private var sendChain: Task<Void, Never>?

    /// Live levels are capped at this rate per toy.
    static let minSendInterval: TimeInterval = 0.1
    /// A held level is re-sent this often (must be well inside the hold window).
    static let refreshInterval: TimeInterval = 1
    /// No hold on this phone ever runs longer than this, whatever the server says.
    static let maxHold: Duration = .seconds(5)
    /// The hold this phone enforces: the server's window, capped.
    var holdCap: Duration { min(holdWindow, Self.maxHold) }

    public init(config: LushConfig, transport: (any LushTransport)? = nil, defaults: UserDefaults = .standard) {
        self.config = config
        self.transport = transport ?? config.transport
        self.defaults = defaults
        let key = "LushKit.releaseMode.\(config.currentUserID.uuidString)"
        self.releaseMode = defaults.string(forKey: key).flatMap(ReleaseMode.init(rawValue:)) ?? .hold
    }

    /// Going away without stop(): still stop every toy on this phone.
    isolated deinit {
        localToys.forEach { $0.apply(.stop) }
        watchdogs.values.forEach { $0.cancel() }
        players.values.forEach { $0.stop() }
        pendingSend.values.forEach { $0.cancel() }
        keepalive?.cancel()
        listenTask?.cancel()
        if let s = socket { Task { await s.stop() } }
    }

    // MARK: lifecycle

    /// Connect the live socket and load the control-plane lists. Idempotent.
    public func start() {
        guard socket == nil else { return }
        var hello = Lush_V1_Hello()
        hello.deviceID = config.deviceID
        hello.deviceName = config.deviceName
        hello.appVersion = config.appVersion
        hello.platform = "ios"
        let s = LiveSocket(url: config.liveURL, hello: hello, tokenProvider: config.tokenProvider)
        socket = s
        let gen = generation
        listenTask = Task { [weak self] in
            for await event in s.events {
                guard let self, gen == self.generation else { return }
                self.handle(event)
            }
        }
        Task { await s.start() }
        Task { await refreshLists() }
    }

    /// Stop all work and stop every local toy. Safe to call repeatedly.
    public func stop() {
        generation += 1
        stopAllLocal(reason: "engine stopped")
        let s = socket
        socket = nil
        Task { await s?.stop() }
        listenTask?.cancel()
        listenTask = nil
        pendingSend.values.forEach { $0.cancel() }
        pendingSend = [:]
        keepalive?.cancel()
        keepalive = nil
        driving = [:]
        curveSent = [:]
        curveAnchors = [:]
        connection = .offline
    }

    /// Sign-out: stop, then forget everything this account loaded and
    /// everything the kit wrote on this phone (its two defaults keys, and the
    /// pre-0.2 global release-mode key).
    public func wipeLocalStore() {
        stop()
        defaults.removeObject(forKey: releaseKey)
        defaults.removeObject(forKey: LushConfig.installIDKey)
        defaults.removeObject(forKey: "LushKit.releaseMode")
        releaseMode = .hold
        defaults.removeObject(forKey: releaseKey) // the reset above wrote it back
        toys = []
        grants = []
        contacts = []
        events = []
        patterns = []
        lastFeedback = nil
        lastEnded = nil
        paused = []
        log = []
    }

    // MARK: receiver — toys on this phone

    /// Put a toy on this phone in service: published to the server, commands applied.
    public func host(_ toy: any LocalToy) {
        guard !localToys.contains(where: { $0.hwKey == toy.hwKey }) else { return }
        localToys.append(toy)
        publishLocalToys()
    }

    /// Take a toy out of service (stops it first).
    public func unhost(hwKey: String) {
        guard let toy = localToys.first(where: { $0.hwKey == hwKey }) else { return }
        release(hwKey)
        toy.apply(.stop)
        paused.remove(hwKey)
        localToys.removeAll { $0.hwKey == hwKey }
        publishLocalToys()
    }

    /// Her stop. Stops the toy now and keeps it stopped: nothing but Stop runs
    /// on it until she resumes. Whoever was driving is told, and the server
    /// refuses their drives meanwhile. Works with or without a connection.
    public func pause(hwKey: String) {
        guard let toy = localToys.first(where: { $0.hwKey == hwKey }) else { return }
        let toyID = incoming[hwKey]?.toyID
        release(hwKey)
        toy.apply(.stop)
        paused.insert(hwKey)
        if let toyID { sendEnded(toyID, .paused) }
        publishLocalToys()
        note("\(toy.name): paused by you")
    }

    /// Let a paused toy be driven again.
    public func resume(hwKey: String) {
        guard paused.remove(hwKey) != nil else { return }
        publishLocalToys()
        note("resumed")
    }

    /// Re-announce the local toys (call after a battery change, say).
    public func publishLocalToys() {
        var update = Lush_V1_ToysUpdate()
        update.toys = localToys.map { t in
            var l = Lush_V1_LocalToy()
            l.hwKey = t.hwKey
            l.model = t.model
            l.name = t.name
            l.caps = t.caps.map(Wire.cap)
            l.vibrateMotors = Int32(t.vibrateMotors)
            l.battery = Int32(t.battery ?? -1)
            l.firmware = t.firmware
            l.paused = paused.contains(t.hwKey)
            return l
        }
        var f = Lush_V1_ClientFrame()
        f.toys = update
        send(f)
    }

    private func onCommand(_ cmd: Lush_V1_Command) {
        let serverNow = Date().addingTimeInterval(clockOffset)
        let who = name(for: UUID(uuidString: cmd.fromUserID))
        let key = cmd.hwKey
        let decision = Receiver.decide(cmd, serverNow: serverNow, holdCap: holdCap, paused: paused.contains(key)) { ref in
            // A CurveRef only means something against the run playing here.
            guard case .curve(let p, _, let play)? = active[key], play == ref.play, players[key] != nil else { return nil }
            return .curve(p, strength: ref.strength == 0 ? 100 : Int(ref.strength), play: play)
        }
        switch decision {
        case .drop(let why):
            note("dropped \(why) command from \(who)")
            reply(cmd, ok: false, reason: why)
            if why == .unknownCurve { sendEnded(cmd.toyID, .unknownCurve) }
        case .apply(let action, let hold):
            guard let toy = localToys.first(where: { $0.hwKey == key }) else {
                reply(cmd, ok: false, reason: .noToy)
                return
            }
            // A repeat of the command the toy is already under (the controller's
            // keepalive) only extends the hold. Re-applying would restart a
            // pattern every second, and costs a BLE write for nothing.
            var fresh = false
            if case .curve(_, let strength, let play) = action, case .curve(_, _, let playing)? = active[key],
               play == playing, let player = players[key] {
                // Same run, new strength (or a keepalive): adjust it in place.
                player.setStrength(strength)
                active[key] = action
            } else if active[key] != action {
                fresh = true
                players.removeValue(forKey: key)?.stop()
                active[key] = action
                if case .curve(let pattern, let strength, _) = action {
                    let player = CurvePlayer(pattern: pattern, toy: toy, strength: strength)
                    player.onFinish = { [weak self] in self?.curveFinished(key) }
                    players[key] = player
                    player.start()
                } else {
                    toy.apply(action)
                }
            }
            if action.isStop {
                release(key)
            } else if active[key] != nil {
                incoming[key] = Incoming(toyID: cmd.toyID, from: UUID(uuidString: cmd.fromUserID), action: action)
            }
            watchdogs.removeValue(forKey: key)?.cancel()
            if let hold, active[key] != nil {
                watchdogs[key] = Task { [weak self, toy] in
                    try? await Task.sleep(for: hold)
                    guard !Task.isCancelled else { return }
                    // Stop first, and even if the engine is gone: silence stops the toy.
                    toy.apply(.stop)
                    guard let self else { return }
                    self.release(key)
                    self.note("\(toy.name): hold expired → Stop")
                }
            }
            if fresh { note("\(toy.name) ← \(action.label) from \(who)") }
            reply(cmd, ok: true, reason: .unspecified)
        }
    }

    /// A curve on this phone reached its end (the player stopped the toy).
    /// Release it so nothing can restart it, and tell whoever was driving.
    private func curveFinished(_ key: String) {
        let toyID = incoming[key]?.toyID
        let name = localToys.first { $0.hwKey == key }?.name ?? "toy"
        release(key)
        if let toyID { sendEnded(toyID, .finished) }
        note("\(name): pattern finished")
    }

    private func sendEnded(_ toyID: String, _ reason: Lush_V1_EndReason) {
        var f = Lush_V1_ClientFrame()
        f.ended = .with { $0.toyID = toyID; $0.reason = reason }
        send(f)
    }

    private func reply(_ cmd: Lush_V1_Command, ok: Bool, reason: Lush_V1_ResultReason) {
        guard cmd.wantResult else { return }
        var f = Lush_V1_ClientFrame()
        f.result = .with { $0.id = cmd.id; $0.ok = ok; $0.reason = reason }
        send(f)
    }

    /// Forget what a local toy was under (its player, hold timer, who's driving).
    private func release(_ hwKey: String) {
        watchdogs.removeValue(forKey: hwKey)?.cancel()
        players.removeValue(forKey: hwKey)?.stop()
        active[hwKey] = nil
        incoming[hwKey] = nil
    }

    /// Silence stops the toy: on socket loss and on stop().
    private func stopAllLocal(reason: String) {
        for key in Array(Set(watchdogs.keys).union(players.keys).union(active.keys)) { release(key) }
        guard !localToys.isEmpty else { return }
        localToys.forEach { $0.apply(.stop) }
        note("all local toys stopped (\(reason))")
    }

    /// Her reaction while a toy on this phone is being driven: applied to a
    /// playing pattern at once, and passed on to whoever is driving.
    public func feedback(_ kind: LushFeedback, hwKey: String) {
        let player = players[hwKey]
        player?.apply(kind)
        guard let toyID = incoming[hwKey]?.toyID else { return }
        var f = Lush_V1_ClientFrame()
        f.feedback = .with {
            $0.toyID = toyID
            $0.kind = Wire.feedback(kind)
            $0.playheadMs = UInt32(max(0, (player?.playhead ?? 0) * 1000))
        }
        send(f)
        note("you: \(kind.title)")
    }

    // MARK: controller — driving toys

    /// Drive a toy. Live: call it on every slider change; the engine caps the rate
    /// and keeps a held level alive. `.stop` goes out immediately.
    public func set(_ action: ToyAction, on toy: LushToy) {
        let id = toy.id
        var action = action
        if !action.isStop, toys.first(where: { $0.id == id })?.paused ?? toy.paused {
            note("\(toy.name) is paused")
            return
        }
        // An empty play is a new run of the curve.
        if case .curve(let p, let s, let play) = action, play.isEmpty {
            action = .curve(p, strength: s, play: UUID().uuidString)
        }
        driving[id] = action
        if action.isStop || action.isIdle {
            pendingSend.removeValue(forKey: id)?.cancel()
            sendDrive(id, action, wantResult: action.isStop)
            if action.isStop { endDriving(id) }
            return
        }
        ensureKeepalive()
        let since = lastSent[id].map { Date().timeIntervalSince($0) } ?? .infinity
        if since >= Self.minSendInterval {
            pendingSend.removeValue(forKey: id)?.cancel()
            sendDrive(id, action, wantResult: false)
        } else if pendingSend[id] == nil {
            // Coalesce: one send at the end of the interval, with whatever is latest then.
            pendingSend[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.minSendInterval - since))
                guard !Task.isCancelled, let self else { return }
                self.pendingSend[id] = nil
                if let latest = self.driving[id] { self.sendDrive(id, latest, wantResult: false) }
            }
        }
    }

    /// Stop a toy now.
    public func stop(_ toy: LushToy) { set(.stop, on: toy) }

    private func sendDrive(_ toyID: UUID, _ action: ToyAction, wantResult: Bool) {
        seq += 1
        lastSent[toyID] = Date()
        let command: Lush_V1_ToyCommand
        if case .curve(_, let strength, let play) = action {
            if curveSent[toyID] == play {
                command = Wire.curveRef(play: play, strength: strength)
            } else {
                command = Wire.command(action)
                curveSent[toyID] = play
                curveAnchors[toyID] = CurveAnchor(playhead: 0, at: Date())
            }
        } else {
            command = Wire.command(action)
            curveSent[toyID] = nil
            curveAnchors[toyID] = nil
        }
        var f = Lush_V1_ClientFrame()
        f.drive = .with {
            $0.toyID = toyID.uuidString
            $0.command = command
            $0.seq = seq
            $0.wantResult = wantResult
        }
        send(f)
    }

    /// While anything is held, re-send it every second so it doesn't lapse.
    private func ensureKeepalive() {
        guard keepalive == nil else { return }
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.refreshInterval / 2))
                guard let self else { return }
                let held = self.driving.filter { !$0.value.isIdle }
                if held.isEmpty {
                    self.keepalive = nil
                    return
                }
                for (id, action) in held {
                    let since = self.lastSent[id].map { Date().timeIntervalSince($0) } ?? .infinity
                    if since >= Self.refreshInterval { self.sendDrive(id, action, wantResult: false) }
                }
            }
        }
    }

    /// Forget what this phone was driving on a toy (its keepalive ends).
    private func endDriving(_ id: UUID) {
        driving[id] = nil
        pendingSend.removeValue(forKey: id)?.cancel()
        curveSent[id] = nil
        curveAnchors[id] = nil
    }

    // MARK: socket events

    private func handle(_ event: LiveEvent) {
        switch event {
        case .connecting:
            if connection == .offline { connection = .connecting }
        case .connected(let w):
            connection = .online
            clockOffset = Double(w.now) / 1000 - Date().timeIntervalSince1970
            holdWindow = .milliseconds(Int(w.holdMs))
            publishLocalToys() // the server forgets toys when a socket drops
        case .disconnected(let reason):
            connection = .retrying(reason)
            stopAllLocal(reason: "connection lost")
            // Remote toys can't be driven without a socket; let the held levels lapse.
            for id in Array(driving.keys) { endDriving(id) }
            curveSent = [:]
            // Nothing is known to be online until the next snapshot.
            toys = toys.map { $0.with(online: false, driverID: nil) }
        case .frame(let f):
            switch f.body {
            case .clock(let c):
                clockOffset = Double(c.now) / 1000 - Date().timeIntervalSince1970
            case .toys(let snap):
                let fresh = snap.toys.compactMap { try? Wire.toy($0) }
                if fresh != toys { toys = fresh }
                // Forget what we were driving on toys that are gone, offline or paused.
                for id in Array(driving.keys) where !fresh.contains(where: { $0.id == id && $0.online && !$0.paused }) {
                    endDriving(id)
                }
            case .command(let c):
                onCommand(c)
            case .feedback(let fb):
                if let kind = Wire.feedback(fb.kind), let toyID = UUID(uuidString: fb.toyID) {
                    let playhead = Double(fb.playheadMs) / 1000
                    lastFeedback = FeedbackNote(toyID: toyID, kind: kind, from: UUID(uuidString: fb.fromUserID),
                                                playhead: playhead, at: Date())
                    if curveAnchors[toyID] != nil { curveAnchors[toyID] = CurveAnchor(playhead: playhead, at: Date()) }
                }
            case .ended(let e):
                guard let id = UUID(uuidString: e.toyID) else { break }
                if e.reason == .unknownCurve {
                    // Her phone lost the curve (say it reconnected): send it whole again.
                    if case .curve? = driving[id], let action = driving[id] {
                        curveSent[id] = nil
                        sendDrive(id, action, wantResult: false)
                    }
                } else if let reason = Wire.ended(e.reason) {
                    let wasDriving = driving[id] != nil
                    endDriving(id)
                    if wasDriving {
                        let by = UUID(uuidString: e.byUserID)
                        lastEnded = EndedNote(toyID: id, reason: reason, by: by, at: Date())
                        note("\(name(for: by)) \(reason.text)")
                    }
                }
            case .result(let r) where !r.ok:
                note("drive refused: \(r.reason)")
                if [.paused, .stopped, .unavailable].contains(r.reason), let id = UUID(uuidString: r.toyID) { endDriving(id) }
            default:
                break
            }
        }
    }

    /// Frames go out in the order they were made (a ToyEnded before the
    /// ToysUpdate that follows it, a Stop after the level it replaces).
    private func send(_ frame: Lush_V1_ClientFrame) {
        guard let s = socket else { return }
        let previous = sendChain
        sendChain = Task {
            await previous?.value
            await s.send(frame)
        }
    }

    // MARK: control plane

    /// Reload grants, contacts and history. Failures keep the last good lists.
    public func refreshLists() async {
        let gen = generation
        async let g = try? transport.listGrants()
        async let c = try? transport.listContacts()
        async let e = try? transport.listEvents(limit: 50)
        async let p = try? transport.listPatterns()
        let (grants, contacts, events, patterns) = await (g, c, e, p)
        guard gen == generation else { return }
        if let patterns { self.patterns = patterns }
        if let grants { self.grants = grants }
        if let contacts { self.contacts = contacts }
        if let events { self.events = events }
    }

    /// Let `contact` drive all of this user's toys.
    public func grant(to contact: LushContact) async throws {
        _ = try await transport.createGrant(granteeID: contact.id, label: contact.name, expiresAt: nil)
        await refreshLists()
    }

    public func revoke(_ grant: LushGrant) async throws {
        try await transport.revokeGrant(id: grant.id)
        await refreshLists()
    }

    /// Save a pattern (create or replace); returns it as stored.
    @discardableResult
    public func save(_ pattern: LushPattern) async throws -> LushPattern {
        let saved = try await transport.savePattern(pattern)
        patterns.removeAll { $0.id == saved.id }
        patterns.insert(saved, at: 0)
        return saved
    }

    public func delete(_ pattern: LushPattern) async throws {
        try await transport.deletePattern(id: pattern.id)
        patterns.removeAll { $0.id == pattern.id }
    }

    public func rename(_ toy: LushToy, to name: String) async throws {
        try await transport.renameToy(id: toy.id, to: name)
    }

    public func forget(_ toy: LushToy) async throws {
        try await transport.forgetToy(id: toy.id)
    }

    // MARK: helpers

    /// A person's display name: "You", a contact's name, or a neutral word.
    public func name(for user: UUID?) -> String {
        guard let user else { return "someone" }
        if user == config.currentUserID { return "you" }
        return contacts.first(where: { $0.id == user })?.name ?? "partner"
    }

    private func note(_ text: String) {
        log.insert(LogLine(at: Date(), text: text), at: 0)
        if log.count > 60 { log.removeLast() }
    }
}

/// The receiver's rules, free of I/O so tests can pin them. Fail closed: a
/// Stop always applies; anything else needs a deliver_by and a hold, arrives in
/// time, and runs at most `holdCap`, whatever hold_until says.
enum Receiver {
    enum Decision: Equatable {
        case drop(Lush_V1_ResultReason)
        /// Apply now; stop again after `hold` unless something newer arrives
        /// (nil only for Stop).
        case apply(ToyAction, hold: Duration?)
    }

    static func decide(_ cmd: Lush_V1_Command, serverNow: Date, holdCap: Duration, paused: Bool,
                       resolve: (Lush_V1_CurveRef) -> ToyAction? = { _ in nil }) -> Decision {
        // 1. Stop: never late, never paused, never refused.
        if case .stop? = cmd.command.action { return .apply(.stop, hold: nil) }
        // 2. She paused it: only Stop runs.
        if paused { return .drop(.paused) }
        // 3. Know what it is.
        let action: ToyAction
        if case .curveRef(let ref)? = cmd.command.action {
            guard let a = resolve(ref) else { return .drop(.unknownCurve) }
            action = a
        } else {
            guard let a = Wire.action(cmd.command) else { return .drop(.unknownCommand) }
            action = a
        }
        // 4. Anything that runs a toy must say when it goes stale and when it ends.
        guard cmd.deliverBy > 0, cmd.holdUntil > 0 else { return .drop(.invalid) }
        let nowMs = Int64(serverNow.timeIntervalSince1970 * 1000)
        if nowMs > cmd.deliverBy { return .drop(.late) }
        let remaining = cmd.holdUntil - nowMs
        if remaining <= 0 { return .drop(.expired) }
        return .apply(action, hold: min(.milliseconds(remaining), holdCap))
    }
}
