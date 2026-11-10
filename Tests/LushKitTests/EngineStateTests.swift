import Foundation
import Testing
@testable import LushKit

/// A transport that answers nothing: these tests never reach a server.
struct NullTransport: LushTransport {
    func listToys() async throws -> [LushToy] { [] }
    func renameToy(id: UUID, to name: String) async throws {}
    func forgetToy(id: UUID) async throws {}
    func createGrant(granteeID: UUID, label: String, expiresAt: Date?) async throws -> LushGrant {
        LushGrant(id: UUID(), granteeID: granteeID, label: label, expiresAt: expiresAt)
    }
    func revokeGrant(id: UUID) async throws {}
    func listGrants() async throws -> [LushGrant] { [] }
    func listContacts() async throws -> [LushContact] { [] }
    func listEvents(limit: Int) async throws -> [LushEvent] { [] }
}

/// What the kit leaves on the phone, and that the wipe takes all of it.
@MainActor
@Suite struct EngineStateTests {
    func defaults() -> UserDefaults {
        let name = "LushKitTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func engine(_ user: UUID, _ d: UserDefaults) -> LushEngine {
        let config = LushConfig(baseURL: URL(string: "http://localhost:1")!, currentUserID: user,
                                tokenProvider: { nil }, deviceID: LushConfig.installID(defaults: d))
        return LushEngine(config: config, transport: NullTransport(), defaults: d)
    }

    @Test func releaseModeIsRememberedPerUser() {
        let d = defaults()
        let a = UUID(), b = UUID()
        let ea = engine(a, d)
        #expect(ea.releaseMode == .hold, "the default")
        ea.releaseMode = .touch
        #expect(engine(a, d).releaseMode == .touch, "remembered for the same user")
        #expect(engine(b, d).releaseMode == .hold, "someone else on this phone starts fresh")
    }

    @Test func wipeLeavesNothingOfTheKitOnThePhone() {
        let d = defaults()
        d.set("touch", forKey: "LushKit.releaseMode") // the old global key, from before per-user state
        let e = engine(UUID(), d)
        e.releaseMode = .touch
        #expect(d.dictionaryRepresentation().keys.contains { $0.hasPrefix("LushKit.") })

        e.wipeLocalStore()
        let left = d.dictionaryRepresentation().keys.filter { $0.hasPrefix("LushKit.") }
        #expect(left.isEmpty, "left behind: \(left)")
        #expect(e.releaseMode == .hold)
        #expect(e.connection == .offline && e.toys.isEmpty && e.log.isEmpty)
    }

    @Test func aNewInstallIdIsMadeAfterAWipe() {
        let d = defaults()
        let first = LushConfig.installID(defaults: d)
        #expect(LushConfig.installID(defaults: d) == first, "stable until wiped")
        engine(UUID(), d).wipeLocalStore()
        #expect(LushConfig.installID(defaults: d) != first)
    }

    @Test func wipeStopsEveryToyOnThisPhone() {
        let e = engine(UUID(), defaults())
        let toy = RecordingToy()
        e.host(toy)
        toy.apply(.vibrate(level: 9))
        e.wipeLocalStore()
        #expect(toy.current == .stop)
    }

    @Test func stoppingTheEngineStopsEveryToyOnThisPhone() {
        // The host calls stop() when its screen goes or the app leaves the
        // foreground; nothing may keep running after that.
        let e = engine(UUID(), defaults())
        let toy = RecordingToy()
        e.host(toy)
        toy.apply(.vibrate(level: 14))
        e.stop()
        #expect(toy.current == .stop)
    }

    @Test func unhostStopsTheToyFirst() {
        let e = engine(UUID(), defaults())
        let toy = RecordingToy()
        e.host(toy)
        toy.apply(.vibrate(level: 14))
        e.unhost(hwKey: toy.hwKey)
        #expect(toy.applied.last == .stop)
        #expect(e.localToys.isEmpty)
    }

    @Test func takenOverIsAnEndReason() {
        #expect(Wire.ended(.takenOver) == .takenOver)
        #expect(LushEndReason.takenOver.text == "took over")
        // The server's words for these are the server's to say; an unknown
        // reason is ignored, not guessed.
        #expect(Wire.ended(.unspecified) == nil)
    }
}

@Suite struct HistoryLineTests {
    private func event(_ kind: String, _ detail: String = "") -> LushEvent {
        LushEvent(id: UUID(), toyID: nil, kind: kind, actorID: UUID(), at: Date(), detail: detail)
    }

    @Test func aStretchReadsAsAStartAndAnEnd() {
        #expect(event("driving").line(actor: "Sam").title == "Sam started driving")
        let end = event("stopped", "stopped by owner · 1m12s").line(actor: "You")
        #expect(end.title == "You stopped it")
        #expect(end.note == "after 1m12s")
    }

    @Test func everyEndingTheServerSendsHasWords() {
        for why in ["let go", "timed out", "driver offline", "stopped by owner", "stopped by someone else", "taken over",
                    "toy offline", "access ended", "pattern finished", "paused by owner", "toy forgotten"] {
            let title = event("stopped", "\(why) · 5s").line(actor: "Sam").title
            #expect(!title.hasPrefix("Stopped:"), "no wording for \(why)")
        }
    }

    @Test func anUnknownEndingOrKindStillReads() {
        #expect(event("stopped", "something new · 2s").line(actor: "Sam").title == "Stopped: something new")
        #expect(event("stopped").line(actor: "Sam").title == "Stopped")
        #expect(event("brand_new").line(actor: "Sam").title == "brand new")
    }
}
