import Foundation
import Testing
@testable import LushKit

/// The generated live frames round-trip — the contract with mvLush's hub.
@Test func liveFrameRoundTrips() throws {
    var drive = Lush_V1_Drive()
    drive.toyID = "t"
    drive.seq = 7
    drive.command.vibrate.level = 12
    var frame = Lush_V1_ClientFrame()
    frame.drive = drive
    let decoded = try Lush_V1_ClientFrame(serializedBytes: try frame.serializedData())
    #expect(decoded.drive.command.vibrate.level == 12)
    #expect(decoded.drive.seq == 7)
}

@Test(arguments: [
    ToyAction.vibrate(level: 12), .vibrate(level: 3, motor: 2), .rotate(level: 5, flip: true),
    .air(level: 4), .thrust(level: 20), .pattern("wave"), .stop,
])
func actionWireRoundTrips(_ a: ToyAction) {
    #expect(Wire.action(Wire.command(a)) == a)
}

@Test func idleAndStop() {
    #expect(ToyAction.vibrate(level: 0).isIdle)
    #expect(!ToyAction.vibrate(level: 1).isIdle)
    #expect(!ToyAction.pattern("pulse").isIdle)
    #expect(ToyAction.stop.isStop && ToyAction.stop.isIdle)
}

@Test func liveURLFollowsBaseURL() {
    func live(_ s: String) -> String {
        LushConfig(baseURL: URL(string: s)!, currentUserID: UUID(), tokenProvider: { nil }, deviceID: "d").liveURL.absoluteString
    }
    #expect(live("http://localhost:6094") == "ws://localhost:6094/live/v1")
    #expect(live("https://lush.example.app") == "wss://lush.example.app/live/v1")
    #expect(live("https://lush.example.app/") == "wss://lush.example.app/live/v1")
}

// MARK: receiver rules

private func command(_ a: ToyAction, deliverBy: Int64, holdUntil: Int64) -> Lush_V1_Command {
    var c = Lush_V1_Command()
    c.command = Wire.command(a)
    c.deliverBy = deliverBy
    c.holdUntil = holdUntil
    return c
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let ms0 = Int64(1_800_000_000_000)

private let cap: Duration = .seconds(3)

private func decide(_ c: Lush_V1_Command, paused: Bool = false,
                    resolve: (Lush_V1_CurveRef) -> ToyAction? = { _ in nil }) -> Receiver.Decision {
    Receiver.decide(c, serverNow: t0, holdCap: cap, paused: paused, resolve: resolve)
}

@Test func appliesWithRemainingHold() {
    #expect(decide(command(.vibrate(level: 9), deliverBy: ms0 + 1500, holdUntil: ms0 + 2000))
        == .apply(.vibrate(level: 9), hold: .milliseconds(2000)))
}

@Test func lateCommandIsDropped() {
    #expect(decide(command(.vibrate(level: 9), deliverBy: ms0 - 1, holdUntil: ms0 + 3000)) == .drop(.late))
}

@Test func stopIsNeverHeldOrDroppedForHold() {
    #expect(decide(command(.stop, deliverBy: ms0 + 1500, holdUntil: 0)) == .apply(.stop, hold: nil))
}

@Test func lateStopIsStillApplied() {
    #expect(decide(command(.stop, deliverBy: ms0 - 60_000, holdUntil: 0)) == .apply(.stop, hold: nil))
    #expect(decide(command(.stop, deliverBy: 0, holdUntil: 0), paused: true) == .apply(.stop, hold: nil))
}

@Test func lapsedHoldIsDropped() {
    #expect(decide(command(.vibrate(level: 9), deliverBy: ms0 + 1500, holdUntil: ms0 - 5)) == .drop(.expired))
}

@Test func missingDeadlinesFailClosed() {
    #expect(decide(command(.vibrate(level: 9), deliverBy: ms0 + 1500, holdUntil: 0)) == .drop(.invalid), "no hold → never runs forever")
    #expect(decide(command(.vibrate(level: 9), deliverBy: 0, holdUntil: ms0 + 3000)) == .drop(.invalid), "no deliver_by → never 'never late'")
    #expect(decide(command(.pattern("wave"), deliverBy: 0, holdUntil: 0)) == .drop(.invalid))
}

@Test func holdIsCappedWhateverTheServerSays() {
    // A clock fault or a bad server says "hold for an hour": the phone holds 3 s.
    #expect(decide(command(.vibrate(level: 9), deliverBy: ms0 + 1500, holdUntil: ms0 + 3_600_000))
        == .apply(.vibrate(level: 9), hold: cap))
}

@Test func pausedRefusesEverythingButStop() {
    #expect(decide(command(.vibrate(level: 9), deliverBy: ms0 + 1500, holdUntil: ms0 + 3000), paused: true) == .drop(.paused))
}

@Test func curveRefResolvesOnlyAgainstWhatsPlaying() {
    let ramp = LushPattern(name: "R", points: [.init(at: 0, level: 0), .init(at: 10, level: 20)])
    var c = command(.stop, deliverBy: ms0 + 1500, holdUntil: ms0 + 3000)
    c.command = Wire.curveRef(play: "run-1", strength: 150)
    #expect(decide(c) == .drop(.unknownCurve))
    let d = decide(c) { ref in ref.play == "run-1" ? .curve(ramp, strength: Int(ref.strength), play: ref.play) : nil }
    #expect(d == .apply(.curve(ramp, strength: 150, play: "run-1"), hold: .milliseconds(3000)))
    #expect(Wire.curveRef(play: "x", strength: 100).curveRef.strength == 0, "100% travels as the default")
}

@Test func emptyCommandIsDropped() {
    #expect(decide(Lush_V1_Command()) == .drop(.unknownCommand))
}

@Test func badCurveTimesNeverTrap() {
    let bad = LushPattern(name: "x", points: [.init(at: -5, level: 3), .init(at: .infinity, level: 99)], loopFrom: -1)
    let c = Wire.curve(bad)
    #expect(c.points.map(\.atMs) == [0, 0])
    #expect(c.loopFromMs == 0)
}

@Test(arguments: ToyAction.patterns)
func patternShapesStayInRange(_ name: String) {
    for i in 0..<500 {
        let v = PatternShape.value(name, at: Double(i) * 0.037)
        #expect(v >= 0 && v <= 1)
    }
}
