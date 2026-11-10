import Foundation
import Testing
@testable import LushKit

@MainActor
final class RecordingToy: LocalToy {
    let hwKey = "REC"
    let model = "test"
    let name = "rec"
    let caps: Set<LushCapability> = [.vibrate]
    let vibrateMotors = 1
    let battery: Int? = 100
    let firmware = ""
    private(set) var current: ToyAction = .stop
    private(set) var applied: [ToyAction] = []
    func apply(_ action: ToyAction) {
        current = action
        applied.append(action)
    }
}

private let ramp = LushPattern(
    name: "Ramp",
    points: [.init(at: 0, level: 0), .init(at: 10, level: 20), .init(at: 20, level: 20)],
    marks: [.init(at: 0, label: "Rise"), .init(at: 10, label: "Top")]
)

@Test func templateIsValidAndShaped() {
    let t = LushPattern.researchTemplate()
    #expect(t.isValid)
    #expect(t.marks.map(\.label) == ["Warm-up", "Build", "Edge 1", "Edge 2", "Plateau", "Afterglow"])
    #expect(t.duration > 240 && t.duration < 600)
    #expect(t.points.last?.level == 0, "ends at rest")
    // Gentle: nothing above 19 — the plateau is strong but not the max.
    #expect(t.points.map(\.level).max()! <= 19)
    // It survives the wire unchanged.
    #expect(Wire.pattern(Wire.curve(t)) == t)
}

@Test func levelInterpolatesAndLoops() {
    #expect(ramp.level(at: 5) == 10)
    #expect(ramp.level(at: 99) == 20)
    var l = ramp
    l.loop = true
    l.loopFrom = 10
    #expect(l.position(after: 25) == 15)
    #expect(ramp.position(after: 25) == 20, "no loop: parks at the end")
    #expect(ramp.nextMark(after: 2)?.label == "Top")
    #expect(ramp.phase(at: 12)?.label == "Top")
}

@MainActor
@Test func playerFollowsTheCurve() {
    let toy = RecordingToy()
    let p = CurvePlayer(pattern: ramp, toy: toy)
    let t0 = ContinuousClock.now
    p.tick(t0)
    p.tick(t0.advanced(by: .seconds(5)))
    #expect(p.output == 10)
    #expect(toy.current == .vibrate(level: 10))
}

@MainActor
@Test func easeBacksOffPausesThenRebuilds() {
    let toy = RecordingToy()
    let p = CurvePlayer(pattern: ramp, toy: toy)
    let t0 = ContinuousClock.now
    p.tick(t0)
    p.tick(t0.advanced(by: .seconds(5))) // level 10
    p.apply(.ease, now: t0.advanced(by: .seconds(5)))
    p.tick(t0.advanced(by: .seconds(6))) // dropped to 30%, paused
    #expect(p.output == 3)
    #expect(abs(p.playhead - 5) < 0.01, "the curve waits while she cools down")
    // Tick like the real player does: every 100 ms.
    var t = 6.0
    while t < 5 + CurvePlayer.easeHold + CurvePlayer.easeRebuild + 0.1 {
        t += 0.1
        p.tick(t0.advanced(by: .seconds(t)))
    }
    #expect(p.easingSince == nil)
    #expect(p.playhead > 5 && p.playhead < 10, "resumes after the rebuild")
}

@MainActor
@Test func moreSkipsToTheNextPhase() {
    let toy = RecordingToy()
    let p = CurvePlayer(pattern: ramp, toy: toy)
    let t0 = ContinuousClock.now
    p.tick(t0)
    p.apply(.more, now: t0)
    #expect(p.playhead == 10)
    #expect(p.output == 20)
}

@MainActor
@Test func stayFreezesUntilTappedAgain() {
    let toy = RecordingToy()
    let p = CurvePlayer(pattern: ramp, toy: toy)
    let t0 = ContinuousClock.now
    p.tick(t0)
    p.tick(t0.advanced(by: .seconds(4)))
    p.apply(.stay, now: t0.advanced(by: .seconds(4)))
    p.tick(t0.advanced(by: .seconds(9)))
    #expect(abs(p.playhead - 4) < 0.01)
    p.apply(.stay, now: t0.advanced(by: .seconds(9)))
    p.tick(t0.advanced(by: .seconds(10)))
    #expect(abs(p.playhead - 5) < 0.01)
}

@MainActor
@Test func finishedCurveStopsTheToy() {
    let toy = RecordingToy()
    let p = CurvePlayer(pattern: ramp, toy: toy)
    let t0 = ContinuousClock.now
    p.tick(t0)
    p.tick(t0.advanced(by: .seconds(25)))
    #expect(p.finished)
    #expect(toy.current == .stop)
}

@Test func housePresetsAreValidAndDistinct() {
    let house = LushPattern.house
    #expect(house.map(\.name) == ["Slow Burn", "Tease", "Swell", "Steady"])
    #expect(Set(house.map(\.id)).count == house.count)
    for p in house {
        #expect(p.isValid, "\(p.name) is invalid")
        #expect(p.isHouse)
        #expect(!p.marks.isEmpty && p.marks.first?.at == 0, "\(p.name) needs phases from the start")
        #expect(p.points.map(\.level).max()! <= 19, "\(p.name): gentle — never the max")
        #expect(p.points.count <= 600)
        #expect(Wire.pattern(Wire.curve(p)) == p, "\(p.name) changes on the wire")
        let copy = p.duplicate()
        #expect(!copy.isSaved && !copy.isHouse && copy.points == p.points)
    }
    #expect(LushPattern.tease.marks.filter { $0.label.hasPrefix("Edge") }.count == 3)
    #expect(LushPattern.steady.loop && LushPattern.swell.loop)
    #expect(!LushPattern.slowBurn.loop && !LushPattern.tease.loop)
    // Bursts early, continuous later: Slow Burn's wake-up dips to the floor
    // between bursts; its steady phase doesn't change.
    let steady = LushPattern.slowBurn.marks.first { $0.label == "Steady" }!.at
    #expect(LushPattern.slowBurn.level(at: steady + 60) == LushPattern.slowBurn.level(at: steady + 200))
}

@Test func strengthCrossesTheWire() {
    let full = Wire.command(.curve(ramp))
    #expect(full.curve.strength == 0, "100% is the default, sent as 0")
    #expect(Wire.action(Wire.command(.curve(ramp, strength: 150, play: "p"))) == .curve(ramp, strength: 150, play: "p"))
    #expect(Wire.action(full) == .curve(ramp, strength: 100))
    #expect(Wire.command(.curve(ramp, strength: 900)).curve.strength == 200, "clamped")
}

@MainActor
@Test func strengthScalesWithoutMovingThePlayhead() {
    let toy = RecordingToy()
    let p = CurvePlayer(pattern: ramp, toy: toy, strength: 50)
    let t0 = ContinuousClock.now
    p.tick(t0)
    p.tick(t0.advanced(by: .seconds(5))) // design level 10
    #expect(p.output == 5)
    p.setStrength(200, now: t0.advanced(by: .seconds(5)))
    #expect(p.output == 20)
    #expect(abs(p.playhead - 5) < 0.01)
    p.tick(t0.advanced(by: .seconds(8))) // design 16 → 32, clamped
    #expect(p.output == 20)
}

@Test func fingerHeightMapsToStrength() {
    #expect(LushControlScreen.strength(at: 0) == 10)
    #expect(LushControlScreen.strength(at: 0.5) == 100)
    #expect(LushControlScreen.strength(at: 1) == 200)
    #expect(LushControlScreen.strength(at: 0.75) == 150)
    #expect(LushControlScreen.strength(at: 2) == 200)
}

@MainActor
@Test func finishedPlayerIsInert() {
    let toy = RecordingToy()
    let p = CurvePlayer(pattern: ramp, toy: toy)
    var finishes = 0
    p.onFinish = { finishes += 1 }
    let t0 = ContinuousClock.now
    p.tick(t0)
    p.tick(t0.advanced(by: .seconds(25))) // past the end
    #expect(p.finished && toy.current == .stop && finishes == 1)
    let writes = toy.applied.count
    // Her taps, a strength change, stray ticks: none may turn the toy back on.
    for f in LushFeedback.allCases { p.apply(f, now: t0.advanced(by: .seconds(26))) }
    p.setStrength(200, now: t0.advanced(by: .seconds(27)))
    p.tick(t0.advanced(by: .seconds(30)))
    #expect(toy.applied.count == writes, "a finished curve touched the toy again")
    #expect(toy.current == .stop && finishes == 1)
}
