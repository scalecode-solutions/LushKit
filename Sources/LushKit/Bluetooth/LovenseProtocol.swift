import Foundation

/// The Lovense string protocol, free of CoreBluetooth so tests can pin it.
/// Commands and replies are short ASCII strings ending in `;`.
///
/// Sources: the buttplug.io protocol notes (STPIHKAL,
/// docs.buttplug.io/docs/stpihkal/protocols/lovense) and what the May 2026
/// LovenseBLE prototype saw from a real Lush 4. There is no `Stop;` command in
/// the protocol: stopping is zero levels.
enum Lovense {
    // MARK: commands (phone → toy)

    /// Built-in patterns by number: over Bluetooth the toy takes `Preset:<n>;`
    /// (the names are the cloud API's), and `Preset:0;` ends one.
    static let presets: [String: Int] = ["pulse": 1, "wave": 2, "fireworks": 3, "earthquake": 4]

    /// The strings to write for an action, in order. Levels are clamped: a toy
    /// is never sent a number outside its range. A curve returns nothing: its
    /// player sends levels itself.
    static func commands(for action: ToyAction, caps: Set<LushCapability>) -> [String] {
        switch action {
        case .vibrate(let level, let motor):
            let l = clamp(level, ToyAction.maxLevel)
            return motor <= 0 ? ["Vibrate:\(l);"] : ["Vibrate\(min(motor, 4)):\(l);"]
        case .rotate(let level, _):
            // Direction is a toggle on the toy (`rotateChange`); whoever holds
            // the toy's state decides whether to send it first.
            return ["Rotate:\(clamp(level, ToyAction.maxLevel));"]
        case .air(let level):
            return ["Air:Level:\(clamp(level, ToyAction.maxAir));"]
        case .thrust(let level):
            return ["Thrust:\(clamp(level, ToyAction.maxLevel));"]
        case .pattern(let name):
            guard let n = presets[name] else { return [] }
            return ["Preset:\(n);"]
        case .curve:
            return []
        case .stop:
            return stop(caps: caps)
        }
    }

    /// Stop is the one write that must work, so it's spelled as zero levels
    /// (commands every toy is known to take) rather than a single word.
    /// `Vibrate:0;` also ends a built-in pattern.
    static func stop(caps: Set<LushCapability>) -> [String] {
        var out = ["Vibrate:0;"]
        if caps.contains(.rotate) { out.append("Rotate:0;") }
        if caps.contains(.air) { out.append("Air:Level:0;") }
        if caps.contains(.thrust) { out.append("Thrust:0;") }
        return out
    }

    static let deviceType = "DeviceType;"
    static let battery = "Battery;"
    static let rotateChange = "RotateChange;"
    static let endPreset = "Preset:0;"
    /// The toy's own dead-man switch: stop when the Bluetooth link drops, and
    /// don't resume the last level when it comes back. (The setting really is
    /// spelled "AutoSwith".) Covers a phone that's suspended or out of range,
    /// where no app code is running to send a Stop.
    static let stopOnDisconnect = "AutoSwith:On:Off;"

    private static func clamp(_ v: Int, _ max: Int) -> Int { Swift.min(Swift.max(v, 0), max) }

    // MARK: replies (toy → phone)

    enum Frame: Equatable {
        case ok
        /// The toy refused the last command.
        case error
        /// A bare number 0–100: the answer to `Battery;` (toys also push it).
        case battery(Int)
        /// `<letter>:<firmware>:<address>`, the answer to `DeviceType;`.
        case deviceType(letter: String, firmware: String, address: String)
        case other(String)
    }

    /// Splits a notification stream on `;`. One notification can carry part of
    /// a reply, a whole one, or several, so it buffers across calls.
    struct Parser {
        private var buffer = ""
        /// A toy never sends anything long; a stream with no `;` is noise.
        static let maxBuffer = 512

        mutating func feed(_ data: Data) -> [Frame] {
            guard let chunk = String(data: data, encoding: .utf8) else { return [] }
            buffer += chunk
            var out: [Frame] = []
            while let semi = buffer.firstIndex(of: ";") {
                let piece = buffer[..<semi].trimmingCharacters(in: .whitespacesAndNewlines)
                buffer.removeSubrange(...semi)
                if !piece.isEmpty { out.append(Lovense.classify(piece)) }
            }
            if buffer.count > Self.maxBuffer { buffer = "" }
            return out
        }
    }

    /// Classify one reply (no trailing `;`).
    static func classify(_ frame: String) -> Frame {
        if frame == "OK" { return .ok }
        if frame == "ERR" { return .error }
        if let n = Int(frame), (0...100).contains(n) { return .battery(n) }
        let parts = frame.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        // DeviceType: one or two capital letters, a firmware number, then the
        // address as 12 hex digits ("C:11:0082059AD3BD").
        if parts.count == 3, (1...2).contains(parts[0].count), parts[0].allSatisfy({ $0.isLetter && $0.isUppercase }),
           parts[2].count == 12, parts[2].allSatisfy(\.isHexDigit) {
            return .deviceType(letter: parts[0], firmware: parts[1], address: parts[2].uppercased())
        }
        return .other(frame)
    }

    // MARK: what a toy is

    struct Kind: Equatable {
        var model: String
        var caps: Set<LushCapability> = [.vibrate]
        var motors = 1
    }

    /// From the `DeviceType;` letter (authoritative once connected).
    static func kind(letter: String) -> Kind? {
        switch letter.uppercased() {
        case "S": Kind(model: "lush")
        // "L" is Ambi in the published notes, but a Lush 4 reported it in the
        // field: the advertised name wins when it's specific (see `kind(…)`).
        case "L": Kind(model: "lush4")
        case "H": Kind(model: "solace", caps: [.thrust])
        case "Z": Kind(model: "hush")
        case "A", "C": Kind(model: "nora", caps: [.vibrate, .rotate])
        case "B": Kind(model: "max", caps: [.vibrate, .air])
        case "P": Kind(model: "edge", motors: 2)
        case "W": Kind(model: "domi")
        case "O": Kind(model: "osci")
        case "F": Kind(model: "ferri")
        default: nil
        }
    }

    /// A guess from the advertised name ("LVS-C18", "LVS-Lush04_…"), for the
    /// scan list and as a fallback when a toy doesn't answer `DeviceType;`.
    static func kind(advertisedName: String) -> Kind {
        var body = advertisedName.uppercased()
        if body.hasPrefix("LVS-") { body.removeFirst(4) }
        let table: [(String, Kind)] = [
            ("C18", Kind(model: "lush4")), ("LUSH04", Kind(model: "lush4")), ("LUSH40", Kind(model: "lush4")),
            ("LUSH-04", Kind(model: "lush4")), ("S001", Kind(model: "lush")), ("LUSH", Kind(model: "lush")),
            ("Z001", Kind(model: "hush")), ("HUSH", Kind(model: "hush")),
            ("EDGE", Kind(model: "edge", motors: 2)), ("DOMI", Kind(model: "domi")),
            ("B011", Kind(model: "max", caps: [.vibrate, .air])), ("MAX", Kind(model: "max", caps: [.vibrate, .air])),
            ("NORA", Kind(model: "nora", caps: [.vibrate, .rotate])),
            ("AMBI", Kind(model: "ambi")), ("OSCI", Kind(model: "osci")), ("FERRI", Kind(model: "ferri")),
            ("GRAVITY", Kind(model: "gravity", caps: [.vibrate, .thrust])),
            ("SOLACE", Kind(model: "solace", caps: [.thrust])),
        ]
        return table.first { body.hasPrefix($0.0) }?.1 ?? Kind(model: "toy")
    }

    /// What a connected toy is: its advertised name when that names a model,
    /// else its `DeviceType;` letter, else a plain vibrating toy.
    static func kind(advertisedName: String, letter: String?) -> Kind {
        let byName = kind(advertisedName: advertisedName)
        if byName.model != "toy" { return byName }
        return letter.flatMap(kind(letter:)) ?? byName
    }

    /// Whether an advertised name looks like a Lovense toy. Scanning can't
    /// filter by service (the families keep changing), so it filters by name.
    static func isToyName(_ name: String) -> Bool {
        let upper = name.uppercased()
        if upper.hasPrefix("LVS-") || upper.hasPrefix("LOVE-") || upper.contains("LOVENSE") { return true }
        return ["LUSH", "HUSH", "EDGE", "DOMI", "MAX", "NORA", "OSCI", "FERRI", "MISSION", "DOLCE", "AMBI", "DIAMO",
                "CALOR", "EXOMOON", "GRAVITY", "GEMINI", "VULSE", "SOLACE", "TENERA", "FLEXER", "HYPHY", "GUSH", "RIDGE"]
            .contains { upper.hasPrefix($0) }
    }

    /// The server's stable key for a toy: its address from `DeviceType;`, or,
    /// if it never answered, this phone's own id for it (stable per phone).
    static func hwKey(address: String?, peripheralID: UUID) -> String {
        if let address, !address.isEmpty { return address.uppercased() }
        return "BT-" + peripheralID.uuidString
    }

    // MARK: GATT

    /// The write (tx) and notify (rx) characteristics for a service, if it's a
    /// known Lovense family. A toy with none of them is probed by
    /// characteristic properties instead. UUIDs are compared lowercase.
    static func channel(forService uuid: String) -> (tx: String, rx: String)? {
        let s = uuid.lowercased()
        if let fixed = fixedServices[s] { return fixed }
        // Third generation: XY300001-002Z-4bd4-bbd5-a6920e4c5653, where X, Y
        // and Z vary by model and firmware.
        let tail = "-4bd4-bbd5-a6920e4c5653"
        if s.count == 36, s.hasSuffix(tail), s.dropFirst(2).hasPrefix("300001-002"),
           s.prefix(2).allSatisfy(\.isHexDigit) {
            let head = s.prefix(4), mid = s.dropFirst(8).prefix(5) // "xy30", "-002z"
            return ("\(head)0002\(mid)\(tail)", "\(head)0003\(mid)\(tail)")
        }
        return nil
    }

    private static let fixedServices: [String: (tx: String, rx: String)] = [
        // First generation (Max, Nora).
        "0000fff0-0000-1000-8000-00805f9b34fb": ("0000fff2-0000-1000-8000-00805f9b34fb", "0000fff1-0000-1000-8000-00805f9b34fb"),
        "fff0": ("fff2", "fff1"),
        // Second generation: the Nordic UART service (Lush, Hush).
        "6e400001-b5a3-f393-e0a9-e50e24dcca9e": ("6e400002-b5a3-f393-e0a9-e50e24dcca9e", "6e400003-b5a3-f393-e0a9-e50e24dcca9e"),
        // 2024+ toys (the Lush 4 advertises as LVS-C18), from the May 2026 prototype.
        "8ec90001-f315-4f60-9fb8-838830daea50": ("8ec90002-f315-4f60-9fb8-838830daea50", "8ec90003-f315-4f60-9fb8-838830daea50"),
        "8e400001-f315-4f60-9fb8-838830daea50": ("8ec90002-f315-4f60-9fb8-838830daea50", "8ec90003-f315-4f60-9fb8-838830daea50"),
        "a6ed0401-d344-460a-8075-b9e8ec90d71b": ("a6ed0402-d344-460a-8075-b9e8ec90d71b", "a6ed0403-d344-460a-8075-b9e8ec90d71b"),
    ]

    /// Services that are never the toy's command channel (generic access,
    /// attribute, device info, battery, Nordic DFU).
    static func isStandardService(_ uuid: String) -> Bool {
        let s = uuid.lowercased()
        return ["1800", "1801", "180a", "180f"].contains(s)
            || ["00001800", "00001801", "0000180a", "0000180f", "00001530"].contains { s.hasPrefix($0) }
    }
}
