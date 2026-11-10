import Foundation
import Testing
@testable import LushKit

/// End to end against a running mvLush (local Docker). Skipped unless the test
/// runner gets a token and URL:
///
///     TOKEN=$(cd ../mvLush && go run ./cmd/minttoken "$KEY" "$(uuidgen)")
///     TEST_RUNNER_LUSH_TOKEN=$TOKEN TEST_RUNNER_LUSH_URL=http://localhost:6094 \
///       xcodebuild test -scheme LushKit -destination …
///
/// One user, two "phones": A hosts a simulated toy; B drives it through the
/// server. Owners may always drive their own toys, so no grant is needed.
@MainActor
// Serialized: every test signs in as the same user, and the server keeps at
// most 5 sockets per user (each test opens two).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LUSH_TOKEN"] != nil))
struct LiveIntegrationTests {
    let token = ProcessInfo.processInfo.environment["LUSH_TOKEN"] ?? ""
    let url = URL(string: ProcessInfo.processInfo.environment["LUSH_URL"] ?? "http://localhost:6094")!

    func engine(_ device: String) -> LushEngine {
        let token = token
        return LushEngine(config: LushConfig(baseURL: url, currentUserID: UUID(), tokenProvider: { token },
                                             deviceID: device, deviceName: device))
    }

    func until(_ timeout: Duration = .seconds(5), _ ok: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if ok() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return ok()
    }

    @Test func driveThroughServerThenHangUpStopsToy() async throws {
        let a = engine("it-a-\(UUID().uuidString.prefix(6))")
        let b = engine("it-b-\(UUID().uuidString.prefix(6))")
        let sim = SimulatedToy(hwKey: "IT:\(UUID().uuidString.prefix(8))", name: "IT toy")
        a.start()
        a.host(sim)
        b.start()
        defer { a.stop() }

        #expect(await until { a.connection == .online && b.connection == .online })
        // B sees A's toy online (same owner, so it's "owned" for B too).
        #expect(await until { b.toys.contains { $0.online && $0.name == "IT toy" } })
        let toy = try #require(b.toys.first { $0.name == "IT toy" })

        // Live: a burst of slider moves coalesces; the latest lands.
        for level in [3, 5, 8, 11] { b.set(.vibrate(level: level), on: toy) }
        #expect(await until { sim.current == .vibrate(level: 11) })

        // Held: B keeps it alive past the 3 s hold window.
        try await Task.sleep(for: .seconds(4))
        #expect(sim.current == .vibrate(level: 11), "keepalive should hold the level")

        // B hangs up mid-drive → the server tells A to stop.
        b.stop()
        #expect(await until { sim.current == .stop }, "server should stop the toy when its driver leaves")
        #expect(a.log.contains { $0.text.contains("Stop") })
    }

    /// The keepalive re-sends a held pattern every second; the receiver must not
    /// re-apply it (that would restart the pattern on a real toy each second).
    @Test func heldPatternIsAppliedOnce() async throws {
        let a = engine("it-d-\(UUID().uuidString.prefix(6))")
        let b = engine("it-e-\(UUID().uuidString.prefix(6))")
        let sim = SimulatedToy(hwKey: "IT:\(UUID().uuidString.prefix(8))", name: "IT pattern toy")
        a.start()
        a.host(sim)
        b.start()
        defer { a.stop(); b.stop() }
        #expect(await until { b.toys.contains { $0.online && $0.name == "IT pattern toy" } })
        let toy = try #require(b.toys.first { $0.name == "IT pattern toy" })

        b.set(.pattern("wave"), on: toy)
        #expect(await until { sim.current == .pattern("wave") })
        try await Task.sleep(for: .seconds(3.5)) // ≥ 3 keepalive re-sends
        #expect(sim.current == .pattern("wave"))
        #expect(sim.history.filter { $0.action == .pattern("wave") }.count == 1, "re-sent pattern was re-applied")
    }

    /// A custom pattern plays on the receiving phone; keepalive repeats don't
    /// restart it; her "Almost" eases it locally and reaches the driver.
    @Test func curvePlaysOnReceiverAndFeedbackReachesDriver() async throws {
        let a = engine("it-f-\(UUID().uuidString.prefix(6))")
        let b = engine("it-g-\(UUID().uuidString.prefix(6))")
        let sim = SimulatedToy(hwKey: "IT:\(UUID().uuidString.prefix(8))", name: "IT curve toy")
        a.start()
        a.host(sim)
        b.start()
        defer { a.stop(); b.stop() }
        #expect(await until { b.toys.contains { $0.online && $0.name == "IT curve toy" } })
        let toy = try #require(b.toys.first { $0.name == "IT curve toy" })

        let ramp = LushPattern(name: "Ramp", points: [.init(at: 0, level: 4), .init(at: 30, level: 20)],
                               marks: [.init(at: 0, label: "Rise")])
        b.set(.curve(ramp), on: toy)
        #expect(await until { a.players[sim.hwKey] != nil })
        try await Task.sleep(for: .seconds(2.5)) // two+ keepalive repeats
        let player = try #require(a.players[sim.hwKey])
        #expect(player.playhead > 2, "keepalive restarted the curve")
        #expect(sim.current != .stop)

        a.feedback(.ease, hwKey: sim.hwKey)
        #expect(player.easingSince != nil)
        #expect(await until { b.lastFeedback?.kind == .ease })
        #expect((b.lastFeedback?.playhead ?? 0) > 2)
    }

    /// The driver turns a playing house preset up: her phone keeps its place
    /// and plays it harder, instead of starting over.
    @Test func strengthAdjustsAPlayingCurveInPlace() async throws {
        let a = engine("it-h-\(UUID().uuidString.prefix(6))")
        let b = engine("it-i-\(UUID().uuidString.prefix(6))")
        let sim = SimulatedToy(hwKey: "IT:\(UUID().uuidString.prefix(8))", name: "IT strength toy")
        a.start()
        a.host(sim)
        b.start()
        defer { a.stop(); b.stop() }
        #expect(await until { b.toys.contains { $0.online && $0.name == "IT strength toy" } })
        let toy = try #require(b.toys.first { $0.name == "IT strength toy" })

        b.set(.curve(.steady), on: toy)
        #expect(await until { a.players[sim.hwKey] != nil })
        try await Task.sleep(for: .seconds(1.5))
        let player = try #require(a.players[sim.hwKey])
        let before = player.playhead
        guard case .curve(_, _, let play)? = b.driving[toy.id] else { Issue.record("not driving a curve"); return }
        b.set(.curve(.steady, strength: 60, play: play), on: toy)
        #expect(await until { player.strength == 0.6 })
        #expect(a.players[sim.hwKey] === player, "a strength change restarted the curve")
        #expect(player.playhead >= before)
    }

    @Test func localStopOnEngineStop() async throws {
        let a = engine("it-c-\(UUID().uuidString.prefix(6))")
        let sim = SimulatedToy(hwKey: "IT:\(UUID().uuidString.prefix(8))")
        a.start()
        a.host(sim)
        #expect(await until { a.toys.contains { $0.online } })
        let toy = try #require(a.toys.first { $0.online && $0.name == sim.name })
        a.set(.vibrate(level: 6), on: toy)
        #expect(await until { sim.current == .vibrate(level: 6) })
        a.stop()
        #expect(sim.current == .stop, "stopping the engine must stop local toys at once")
    }

    /// Two phones (one user): A hosts a fresh simulated toy, B drives it.
    func pair(_ tag: String) async throws -> (a: LushEngine, b: LushEngine, sim: SimulatedToy, toy: LushToy) {
        let a = engine("it-\(tag)a-\(UUID().uuidString.prefix(6))")
        let b = engine("it-\(tag)b-\(UUID().uuidString.prefix(6))")
        let name = "IT \(tag) \(UUID().uuidString.prefix(4))"
        let sim = SimulatedToy(hwKey: "IT:\(UUID().uuidString.prefix(8))", name: name)
        a.start()
        a.host(sim)
        b.start()
        #expect(await until { b.toys.contains { $0.online && $0.name == name } })
        let toy = try #require(b.toys.first { $0.name == name })
        return (a, b, sim, toy)
    }

    /// A finished pattern releases the toy: the driver is told, its keepalive
    /// ends, her taps can't restart it, and playing it again starts it over.
    @Test func finishedCurveReleasesTheToy() async throws {
        let (a, b, sim, toy) = try await pair("fin")
        defer { a.stop(); b.stop() }
        let short = LushPattern(name: "Short", points: [.init(at: 0, level: 8), .init(at: 1.5, level: 12)])
        b.set(.curve(short), on: toy)
        #expect(await until { a.players[sim.hwKey] != nil })
        #expect(await until { b.lastEnded?.reason == .finished })
        #expect(b.driving[toy.id] == nil, "driver still holding a finished curve")
        #expect(a.players[sim.hwKey] == nil && a.incoming[sim.hwKey] == nil)
        #expect(sim.current == .stop)
        for f in LushFeedback.allCases { a.feedback(f, hwKey: sim.hwKey) }
        try await Task.sleep(for: .seconds(1.5)) // past any keepalive
        #expect(sim.current == .stop, "something restarted a finished curve")

        b.set(.curve(short), on: toy) // a new run
        #expect(await until { a.players[sim.hwKey] != nil && sim.current != .stop }, "replay didn't start")
    }

    /// Her stop sticks: the driver's keepalive can't undo it, the driver is
    /// told, and nothing runs until she resumes.
    @Test func herPauseSticksUntilSheResumes() async throws {
        let (a, b, sim, toy) = try await pair("pause")
        defer { a.stop(); b.stop() }
        b.set(.vibrate(level: 9), on: toy)
        #expect(await until { sim.current == .vibrate(level: 9) })
        a.pause(hwKey: sim.hwKey)
        #expect(sim.current == .stop)
        #expect(await until { b.lastEnded?.reason == .paused && b.driving[toy.id] == nil })
        #expect(await until { b.toys.first { $0.id == toy.id }?.paused == true })
        try await Task.sleep(for: .seconds(1.5))
        #expect(sim.current == .stop, "a keepalive undid her stop")

        b.set(.vibrate(level: 5), on: toy) // refused: she paused it
        try await Task.sleep(for: .milliseconds(500))
        #expect(sim.current == .stop)

        a.resume(hwKey: sim.hwKey)
        #expect(await until { b.toys.first { $0.id == toy.id }?.paused == false })
        b.set(.vibrate(level: 5), on: toy)
        #expect(await until { sim.current == .vibrate(level: 5) })
    }

    /// Someone other than the driver stops the toy: the driver is told and its
    /// keepalive ends, so the Stop sticks.
    @Test func anotherStopEndsTheDriver() async throws {
        let (a, b, sim, toy) = try await pair("other")
        defer { a.stop(); b.stop() }
        b.set(.vibrate(level: 9), on: toy)
        #expect(await until { sim.current == .vibrate(level: 9) })
        a.stop(toy) // the owner's other phone
        #expect(await until { b.lastEnded?.reason == .stopped && b.driving[toy.id] == nil })
        try await Task.sleep(for: .seconds(1.5))
        #expect(sim.current == .stop, "the old driver's keepalive restarted it")
    }
}
