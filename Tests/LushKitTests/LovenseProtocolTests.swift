import Foundation
import Testing
@testable import LushKit

/// The Lovense strings, pinned: what goes to a toy and what comes back.
@Suite struct LovenseProtocolTests {
    // MARK: commands

    @Test func levelsBecomeTheDocumentedStrings() {
        let v: Set<LushCapability> = [.vibrate]
        #expect(Lovense.commands(for: .vibrate(level: 12), caps: v) == ["Vibrate:12;"])
        #expect(Lovense.commands(for: .vibrate(level: 7, motor: 2), caps: v) == ["Vibrate2:7;"])
        #expect(Lovense.commands(for: .rotate(level: 9), caps: v) == ["Rotate:9;"])
        #expect(Lovense.commands(for: .air(level: 3), caps: v) == ["Air:Level:3;"])
        #expect(Lovense.commands(for: .thrust(level: 20), caps: v) == ["Thrust:20;"])
    }

    @Test func aToyIsNeverSentANumberOutsideItsRange() {
        let v: Set<LushCapability> = [.vibrate]
        #expect(Lovense.commands(for: .vibrate(level: 99), caps: v) == ["Vibrate:20;"])
        #expect(Lovense.commands(for: .vibrate(level: -5), caps: v) == ["Vibrate:0;"])
        #expect(Lovense.commands(for: .air(level: 9), caps: v) == ["Air:Level:5;"])
        #expect(Lovense.commands(for: .vibrate(level: 3, motor: 99), caps: v) == ["Vibrate4:3;"])
    }

    @Test func builtInPatternsGoByNumberAndUnknownOnesGoNowhere() {
        #expect(Lovense.commands(for: .pattern("pulse"), caps: [.vibrate]) == ["Preset:1;"])
        #expect(Lovense.commands(for: .pattern("earthquake"), caps: [.vibrate]) == ["Preset:4;"])
        // Every name the kit offers has a number.
        for name in ToyAction.patterns { #expect(Lovense.presets[name] != nil, "\(name)") }
        // A name can't smuggle a command through.
        #expect(Lovense.commands(for: .pattern("PowerOff;"), caps: [.vibrate]).isEmpty)
        #expect(Lovense.commands(for: .pattern("1;Vibrate:20"), caps: [.vibrate]).isEmpty)
    }

    @Test func stopIsZeroLevelsForEverythingTheToyHas() {
        // There is no "Stop;" in the protocol: a stop that the toy ignores is
        // the worst bug this file could have.
        #expect(Lovense.stop(caps: [.vibrate]) == ["Vibrate:0;"])
        #expect(Lovense.stop(caps: [.vibrate, .rotate]) == ["Vibrate:0;", "Rotate:0;"])
        #expect(Lovense.stop(caps: [.vibrate, .air]) == ["Vibrate:0;", "Air:Level:0;"])
        #expect(Lovense.stop(caps: [.thrust]) == ["Vibrate:0;", "Thrust:0;"])
        #expect(Lovense.commands(for: .stop, caps: [.vibrate, .rotate]) == Lovense.stop(caps: [.vibrate, .rotate]))
        #expect(!Lovense.stop(caps: []).isEmpty, "a toy with unknown caps still gets a stop")
    }

    @Test func aCurveWritesNothingItself() {
        let p = LushPattern(name: "p", points: [.init(at: 0, level: 1), .init(at: 5, level: 9)])
        #expect(Lovense.commands(for: .curve(p), caps: [.vibrate]).isEmpty)
    }

    @Test func everyCommandIsOneTerminatedAsciiString() {
        let p = LushPattern(name: "p", points: [.init(at: 0, level: 1), .init(at: 5, level: 9)])
        let actions: [ToyAction] = [.vibrate(level: 3), .vibrate(level: 3, motor: 1), .rotate(level: 4, flip: true),
                                    .air(level: 2), .thrust(level: 5), .pattern("wave"), .curve(p), .stop]
        for a in actions {
            for c in Lovense.commands(for: a, caps: [.vibrate, .rotate, .air, .thrust]) {
                #expect(c.hasSuffix(";") && c.components(separatedBy: ";").count == 2, "\(c)")
                let ascii = c.unicodeScalars.filter { !$0.isASCII }.isEmpty
                #expect(ascii, "\(c)")
            }
        }
        for c in [Lovense.deviceType, Lovense.battery, Lovense.rotateChange, Lovense.endPreset, Lovense.stopOnDisconnect] {
            #expect(c.hasSuffix(";") && c.components(separatedBy: ";").count == 2)
        }
    }

    // MARK: replies

    @Test func classifiesReplies() {
        #expect(Lovense.classify("OK") == .ok)
        #expect(Lovense.classify("ERR") == .error)
        #expect(Lovense.classify("85") == .battery(85))
        #expect(Lovense.classify("0") == .battery(0))
        #expect(Lovense.classify("C:11:0082059AD3BD") == .deviceType(letter: "C", firmware: "11", address: "0082059AD3BD"))
        #expect(Lovense.classify("EI:240:a1b2c3d4e5f6") == .deviceType(letter: "EI", firmware: "240", address: "A1B2C3D4E5F6"))
        // Not a battery level, not a device type.
        #expect(Lovense.classify("101") == .other("101"))
        #expect(Lovense.classify("-3") == .other("-3"))
        #expect(Lovense.classify("AutoSwith:1:0") == .other("AutoSwith:1:0"))
        #expect(Lovense.classify("C:11:nothex") == .other("C:11:nothex"))
        #expect(Lovense.classify("c:11:0082059AD3BD") == .other("c:11:0082059AD3BD"))
    }

    @Test func parserBuffersAcrossNotifications() {
        var p = Lovense.Parser()
        #expect(p.feed(Data("C:11:0082".utf8)).isEmpty)
        #expect(p.feed(Data("059AD3BD;8".utf8)) == [.deviceType(letter: "C", firmware: "11", address: "0082059AD3BD")])
        #expect(p.feed(Data("5;OK;\n".utf8)) == [.battery(85), .ok])
        #expect(p.feed(Data(";;  ;".utf8)).isEmpty, "empty pieces are skipped")
    }

    @Test func parserSurvivesNoise() {
        var p = Lovense.Parser()
        // Bytes that aren't text are dropped, not buffered forever.
        #expect(p.feed(Data([0xff, 0xfe, 0xfd])).isEmpty)
        // A stream that never ends a reply doesn't grow without bound.
        for _ in 0..<50 { _ = p.feed(Data(String(repeating: "x", count: 100).utf8)) }
        _ = p.feed(Data(";".utf8)) // ends whatever noise was still buffered
        #expect(p.feed(Data("77;".utf8)) == [.battery(77)], "and the parser works again")
    }

    // MARK: what a toy is

    @Test func kindFromNameAndLetter() {
        #expect(Lovense.kind(advertisedName: "LVS-C18").model == "lush4")
        #expect(Lovense.kind(advertisedName: "LVS-Lush04_abc").model == "lush4")
        #expect(Lovense.kind(advertisedName: "LVS-Edge36").motors == 2)
        #expect(Lovense.kind(advertisedName: "LVS-Nora12").caps == [.vibrate, .rotate])
        #expect(Lovense.kind(advertisedName: "LVS-Max2").caps == [.vibrate, .air])
        #expect(Lovense.kind(advertisedName: "LVS-Whatever").model == "toy")
        #expect(Lovense.kind(letter: "S")?.model == "lush")
        #expect(Lovense.kind(letter: "?") == nil)
        // A specific name beats the letter; a vague name defers to it.
        #expect(Lovense.kind(advertisedName: "LVS-C18", letter: "L").model == "lush4")
        #expect(Lovense.kind(advertisedName: "LVS-X999", letter: "Z").model == "hush")
        #expect(Lovense.kind(advertisedName: "LVS-X999", letter: nil) == Lovense.Kind(model: "toy"))
        // Whatever it is, it can vibrate or thrust: it's never capless.
        #expect(!Lovense.kind(advertisedName: "", letter: "QQ").caps.isEmpty)
    }

    @Test func onlyToyNamesAreListed() {
        for name in ["LVS-C18", "LVS-Lush04", "lvs-z001", "LOVE-A011", "Lush3", "Hush2-xx"] {
            #expect(Lovense.isToyName(name), "\(name)")
        }
        for name in ["", "AirPods Pro", "Someone's Apple Watch", "LE-Bose QC", "TV", "Kitchen speaker"] {
            #expect(!Lovense.isToyName(name), "\(name)")
        }
    }

    @Test func hardwareKeyIsTheAddressOrThisPhonesIdForIt() {
        let id = UUID()
        #expect(Lovense.hwKey(address: "0082059ad3bd", peripheralID: id) == "0082059AD3BD")
        #expect(Lovense.hwKey(address: nil, peripheralID: id) == "BT-" + id.uuidString)
        #expect(Lovense.hwKey(address: "", peripheralID: id) == "BT-" + id.uuidString)
        // Fits the server's 64-character limit either way.
        #expect(Lovense.hwKey(address: nil, peripheralID: id).count <= 64)
    }

    // MARK: GATT

    @Test func knownServicesResolveToTheirChannels() {
        let nus = Lovense.channel(forService: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        #expect(nus?.tx == "6e400002-b5a3-f393-e0a9-e50e24dcca9e" && nus?.rx == "6e400003-b5a3-f393-e0a9-e50e24dcca9e")
        let first = Lovense.channel(forService: "FFF0")
        #expect(first?.tx == "fff2" && first?.rx == "fff1")
        // Third generation, any X/Y/Z.
        for service in ["50300001-0024-4BD4-BBD5-A6920E4C5653", "5a300001-0023-4bd4-bbd5-a6920e4c5653",
                        "4f300001-0023-4bd4-bbd5-a6920e4c5653", "42300001-0024-4bd4-bbd5-a6920e4c5653"] {
            let c = Lovense.channel(forService: service)
            let s = service.lowercased()
            #expect(c?.tx == s.replacingOccurrences(of: "300001", with: "300002"), "\(service)")
            #expect(c?.rx == s.replacingOccurrences(of: "300001", with: "300003"), "\(service)")
        }
        let lush4 = Lovense.channel(forService: "8EC90001-F315-4F60-9FB8-838830DAEA50")
        #expect(lush4?.tx.hasPrefix("8ec90002") == true && lush4?.rx.hasPrefix("8ec90003") == true)
    }

    @Test func unknownServicesAreProbedNotGuessed() {
        #expect(Lovense.channel(forService: "180F") == nil)
        #expect(Lovense.channel(forService: "50300002-0024-4bd4-bbd5-a6920e4c5653") == nil, "a characteristic, not a service")
        #expect(Lovense.channel(forService: "50300001-0024-0000-0000-000000000000") == nil)
        #expect(Lovense.channel(forService: "") == nil)
        for standard in ["1800", "1801", "180A", "180F", "0000180A-0000-1000-8000-00805F9B34FB", "00001530-1212-EFDE-1523-785FEABCD123"] {
            #expect(Lovense.isStandardService(standard), "\(standard)")
        }
        #expect(!Lovense.isStandardService("6e400001-b5a3-f393-e0a9-e50e24dcca9e"))
    }
}

/// A real toy's state, without a radio: what `BluetoothToy` writes.
@MainActor
@Suite struct BluetoothToyTests {
    final class Wire { var sent: [String] = [] }

    func toy(_ kind: Lovense.Kind, _ wire: Wire) -> BluetoothToy {
        BluetoothToy(hwKey: "AA", kind: kind, name: "t", firmware: "1", peripheralID: UUID()) { wire.sent.append($0) }
    }

    @Test func writesWhatItIsTold() {
        let w = Wire()
        let t = toy(Lovense.Kind(model: "lush"), w)
        t.apply(.vibrate(level: 8))
        t.apply(.stop)
        #expect(w.sent == ["Vibrate:8;", "Vibrate:0;"])
        #expect(t.current == .stop)
    }

    @Test func aBuiltInPatternIsEndedBeforeAnythingElse() {
        let w = Wire()
        let t = toy(Lovense.Kind(model: "lush"), w)
        t.apply(.pattern("wave"))
        t.apply(.pattern("wave")) // a keepalive repeat doesn't restart it… (the engine filters these too)
        t.apply(.stop)
        #expect(w.sent == ["Preset:2;", "Preset:2;", "Preset:0;", "Vibrate:0;"])
        w.sent = []
        t.apply(.pattern("pulse"))
        t.apply(.vibrate(level: 5))
        #expect(w.sent == ["Preset:1;", "Preset:0;", "Vibrate:5;"])
    }

    @Test func rotationDirectionIsToggledOnlyWhenItChanges() {
        let w = Wire()
        let t = toy(Lovense.Kind(model: "nora", caps: [.vibrate, .rotate]), w)
        t.apply(.rotate(level: 5))
        t.apply(.rotate(level: 9, flip: true))
        t.apply(.rotate(level: 12, flip: true))
        t.apply(.rotate(level: 3))
        #expect(w.sent == ["Rotate:5;", "RotateChange;", "Rotate:9;", "Rotate:12;", "RotateChange;", "Rotate:3;"])
        w.sent = []
        t.apply(.stop)
        #expect(w.sent == ["Vibrate:0;", "Rotate:0;"])
    }
}
