import SwiftUI

/// The drop-in home screen: what's connected to this phone, then partners'
/// toys (their face, a presence glow, who's driving), then yours. Tap a toy
/// for its control. The aurora behind it all warms when a toy on THIS phone
/// is being driven: you see what you feel.
///
/// Pure: it reads the engine; the host owns start/stop. Put it inside the
/// host's `NavigationStack` (the control is pushed, never presented over the
/// host). Pass `bluetooth` to offer "Connect a toy"; without it (a simulator)
/// the screen only shows toys the host put in service itself.
public struct LushView: View {
    @Bindable var engine: LushEngine
    var bluetooth: LushBluetooth?
    var appearance: LushAppearance
    @State private var open: OpenToy?
    @State private var connecting = false

    public init(engine: LushEngine, bluetooth: LushBluetooth? = nil, appearance: LushAppearance = .standard) {
        self.engine = engine
        self.bluetooth = bluetooth
        self.appearance = appearance
    }

    private struct OpenToy: Identifiable, Hashable { let id: UUID }

    private var shared: [LushToy] { engine.toys.filter { !$0.owned } }
    private var mine: [LushToy] { engine.toys.filter(\.owned) }
    /// How hard the toys on this phone are going right now.
    private var localIntensity: Double { engine.localToys.map(\.current.intensity).max() ?? 0 }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ConnectionPill(connection: engine.connection)
                    .frame(maxWidth: .infinity)

                if !engine.localToys.isEmpty || bluetooth != nil {
                    section(appearance.localTitle) {
                        ForEach(engine.localToys, id: \.hwKey) { LocalToyCard(engine: engine, toy: $0) }
                        if bluetooth != nil {
                            Button {
                                connecting = true
                            } label: {
                                Label(appearance.connectPrompt, systemImage: "plus.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.glass)
                        }
                    }
                }

                section(appearance.sharedTitle) {
                    if shared.isEmpty {
                        EmptyCard(symbol: "heart.circle", text: appearance.sharedEmpty)
                    }
                    ForEach(shared) { toyCard($0) }
                }

                section(appearance.mineTitle) {
                    if mine.isEmpty {
                        EmptyCard(symbol: "dot.radiowaves.left.and.right", text: appearance.mineEmpty)
                    }
                    ForEach(mine) { toyCard($0) }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 32)
        }
        .scrollContentBackground(.hidden)
        .background { AuroraBackground(intensity: localIntensity) }
        .navigationDestination(item: $open) { o in
            LushControlScreen(engine: engine, toyID: o.id)
        }
        .sheet(isPresented: $connecting) {
            if let bluetooth {
                NavigationStack { LushConnectView(bluetooth: bluetooth) }
                    .presentationDetents([.medium, .large])
            }
        }
        .animation(.snappy, value: engine.toys)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            content()
        }
    }

    private func toyCard(_ toy: LushToy) -> some View {
        let contact = engine.contacts.first { $0.id == toy.ownerID }
        let driving = engine.driving[toy.id]
        let accent = LushPalette.accent(driving?.intensity ?? 0.2)
        return Button {
            open = OpenToy(id: toy.id)
        } label: {
            GlassCard(tint: driving.map { _ in accent }) {
                HStack(spacing: 14) {
                    if toy.owned {
                        Image(systemName: "waveform.path")
                            .font(.title2)
                            .frame(width: 48, height: 48)
                            .foregroundStyle(toy.online ? accent : .secondary)
                            .symbolEffect(.variableColor.iterative, isActive: toy.driverID != nil)
                    } else {
                        Avatar(name: contact?.name ?? engine.name(for: toy.ownerID), data: contact?.avatar,
                               size: 48, ring: toy.online ? accent : nil)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(toy.owned ? (toy.name.isEmpty ? toy.model : toy.name)
                                       : firstName(contact?.name ?? engine.name(for: toy.ownerID)))
                            .font(.headline)
                        Text(detail(toy))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let driving, !driving.isIdle {
                        Text(driving.label)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .glassEffect(.regular.tint(accent.opacity(0.35)), in: .capsule)
                    } else if toy.online, let b = toy.battery {
                        Label("\(b)%", systemImage: batterySymbol(b))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(toy.online ? 1 : 0.6)
        .contextMenu {
            if driving != nil {
                Button("Stop", systemImage: "stop.fill", role: .destructive) { engine.stop(toy) }
            }
        }
    }

    private func detail(_ toy: LushToy) -> String {
        var parts: [String] = []
        if !toy.owned { parts.append(toy.name.isEmpty ? toy.model : toy.name) }
        if !toy.online {
            parts.append("offline")
        } else if let d = toy.driverID {
            parts.append(d == engine.config.currentUserID ? "you're driving" : "\(firstName(engine.name(for: d))) is driving")
        } else {
            parts.append("ready")
        }
        return parts.joined(separator: " · ")
    }

    private func firstName(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }

    private func batterySymbol(_ b: Int) -> String {
        switch b {
        case ..<15: "battery.0percent"
        case ..<40: "battery.25percent"
        case ..<65: "battery.50percent"
        case ..<90: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

struct ConnectionPill: View {
    let connection: LushEngine.Connection

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: color, radius: connection == .online ? 4 : 0)
            Text(text).font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }

    private var color: Color {
        switch connection {
        case .online: .green
        case .connecting: .yellow
        case .retrying: .orange
        case .offline: .gray
        }
    }

    private var text: String {
        switch connection {
        case .online: "Connected"
        case .connecting: "Connecting…"
        case .retrying(let why): "Reconnecting — \(why)"
        case .offline: "Offline"
        }
    }
}

/// A toy connected to this phone: a live meter of what it's doing, and — while
/// someone is driving it — her say in it: Almost / More / Stay.
struct LocalToyCard: View {
    let engine: LushEngine
    let toy: any LocalToy

    var body: some View {
        let i = toy.current.intensity
        let incoming = engine.incoming[toy.hwKey]
        let player = engine.players[toy.hwKey]
        let paused = engine.paused.contains(toy.hwKey)
        GlassCard(tint: i > 0 ? LushPalette.accent(i) : nil) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(toy.name, systemImage: toy is SimulatedToy ? "cpu" : "dot.radiowaves.left.and.right")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(paused ? "Paused" : (toy.current.isStop ? "Resting" : toy.current.label))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if paused {
                        Button("Resume", systemImage: "play.fill") { engine.resume(hwKey: toy.hwKey) }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    } else if incoming != nil || !toy.current.isStop {
                        // Her stop: always here while anything runs, and it sticks.
                        Button("Stop", systemImage: "stop.fill") { engine.pause(hwKey: toy.hwKey) }
                            .buttonStyle(.glassProminent)
                            .tint(.red)
                            .foregroundStyle(.white)
                            .controlSize(.small)
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.08))
                        Capsule().fill(LushPalette.accent(i).gradient)
                            .frame(width: max(8, geo.size.width * i))
                            .shadow(color: LushPalette.accent(i).opacity(0.8), radius: i * 8)
                    }
                }
                .frame(height: 8)
                .animation(.snappy(duration: 0.15), value: i)

                if paused {
                    Text("Stopped by you. Nobody can start it until you resume.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let incoming {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(caption(incoming, player))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let player {
                            ProgressView(value: min(player.playhead, player.pattern.duration), total: max(player.pattern.duration, 1))
                                .tint(LushPalette.accent(0.7))
                        }
                        HStack(spacing: 8) {
                            ForEach(LushFeedback.allCases, id: \.self) { f in
                                Button {
                                    engine.feedback(f, hwKey: toy.hwKey)
                                } label: {
                                    Label(f == .stay && player?.frozen == true ? "Resume" : f.title, systemImage: f == .stay && player?.frozen == true ? "play.fill" : f.symbol)
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 4)
                                }
                                .buttonStyle(.glass)
                                .tint(highlight(f, player))
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.snappy, value: incoming)
        .animation(.snappy, value: paused)
        .sensoryFeedback(.impact(weight: .heavy), trigger: paused) { _, now in now }
    }

    private func caption(_ inc: LushEngine.Incoming, _ player: CurvePlayer?) -> String {
        let who = engine.name(for: inc.from).split(separator: " ").first.map(String.init)?.capitalized ?? "Someone"
        if let player {
            let phase = player.pattern.phase(at: player.playhead)?.label
            let state = player.easingSince != nil ? "easing off" : (player.frozen ? "holding here" : phase)
            return "\(who) is playing “\(player.pattern.name)”" + (state.map { " · \($0)" } ?? "")
        }
        return "\(who) is driving"
    }

    private func highlight(_ f: LushFeedback, _ p: CurvePlayer?) -> Color? {
        switch f {
        case .ease: p?.easingSince != nil ? LushPalette.accent(0.2) : nil
        case .stay: p?.frozen == true ? LushPalette.accent(0.6) : nil
        case .more: nil
        }
    }
}

struct EmptyCard: View {
    let symbol: String
    let text: String

    var body: some View {
        GlassCard {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
