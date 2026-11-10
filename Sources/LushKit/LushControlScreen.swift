import SwiftUI

/// What lifting your finger off the control does.
public enum ReleaseMode: String, CaseIterable, Sendable {
    /// The level stays where you left it (kept alive until you change it or Stop).
    case hold
    /// It falls back to zero, like letting go of a hand.
    case touch

    var title: String { self == .hold ? "Hold" : "Touch" }
    var hint: String { self == .hold ? "Stays when you let go" : "Fades when you let go" }
}

/// Which output the control drives.
enum Channel: String, CaseIterable, Identifiable {
    case vibrate, rotate, air, thrust
    var id: String { rawValue }

    var title: String { rawValue.capitalized }
    var max: Int { self == .air ? ToyAction.maxAir : ToyAction.maxLevel }

    func action(_ level: Int) -> ToyAction {
        switch self {
        case .vibrate: .vibrate(level: level)
        case .rotate: .rotate(level: level)
        case .air: .air(level: level)
        case .thrust: .thrust(level: level)
        }
    }

    static func available(_ caps: Set<LushCapability>) -> [Channel] {
        let all = allCases.filter { caps.contains(LushCapability(rawValue: $0.rawValue)!) }
        return all.isEmpty ? [.vibrate] : all
    }
}

/// The control, pushed onto the host's navigation stack (it hides the bar and
/// brings its own back button). The whole screen is the slider: your finger's
/// height is the level. A trail of the last few seconds drifts behind the
/// number, and the aurora warms with it.
struct LushControlScreen: View {
    @Bindable var engine: LushEngine
    let toyID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var release: ReleaseMode { engine.releaseMode }
    @State private var channel: Channel = .vibrate
    @State private var levels: [Channel: Int] = [:]
    @State private var pattern: String?
    @State private var patternStart = Date()
    /// A custom pattern playing on her phone, and our estimate of where it is:
    /// playhead `anchor.at` seconds at `anchor.date`, re-synced by her feedback.
    @State private var curve: LushPattern?
    @State private var anchor = (at: 0.0, date: Date())
    /// How hard the curve plays, percent of its design (10–200). Dragging
    /// while a curve plays sets it, instead of replacing the curve.
    @State private var strength = 100
    @State private var designing: LushPattern?
    @State private var dragging = false
    @State private var trail = Trail()

    private var toy: LushToy? { engine.toys.first { $0.id == toyID } }
    private var level: Int { levels[channel] ?? 0 }
    private func curvePlayhead(_ now: Date) -> Double {
        guard let curve else { return 0 }
        return curve.position(after: anchor.at + now.timeIntervalSince(anchor.date))
    }

    /// The curve's level at a time, as 0…1, with strength applied.
    private func curveValue(_ c: LushPattern, _ now: Date) -> Double {
        min(c.level(at: curvePlayhead(now)) * Double(strength) / 100, Double(ToyAction.maxLevel)) / Double(ToyAction.maxLevel)
    }

    /// Finger height (0…1) → strength: the middle of the screen is 100%.
    static func strength(at f: Double) -> Int {
        let f = min(max(f, 0), 1)
        let pct = f <= 0.5 ? 10 + f / 0.5 * 90 : 100 + (f - 0.5) / 0.5 * 100
        return Int((pct / 5).rounded()) * 5
    }

    private var intensity: Double {
        if pattern != nil || curve != nil { return 0.6 }
        return Double(level) / Double(channel.max)
    }

    var body: some View {
        ZStack {
            if let pattern, !reduceMotion {
                // The aurora breathes with the pattern's shape while it plays.
                TimelineView(.animation(minimumInterval: 1 / 12)) { ctx in
                    AuroraBackground(intensity: PatternShape.value(pattern, at: ctx.date.timeIntervalSince(patternStart)))
                }
            } else if let curve, !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 12)) { ctx in
                    AuroraBackground(intensity: curveValue(curve, ctx.date))
                }
            } else {
                AuroraBackground(intensity: intensity)
            }
            if let toy {
                surface(toy)
                TrailView(trail: trail, color: LushPalette.accent(intensity), live: dragging || level > 0 || pattern != nil || curve != nil)
                    .allowsHitTesting(false)
                VStack(spacing: 0) {
                    header(toy)
                    Spacer()
                    readout.allowsHitTesting(false)
                    Spacer()
                    controls(toy)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            } else {
                ContentUnavailableView("This toy is gone", systemImage: "wave.3.right",
                                       description: Text("Its owner stopped sharing it."))
                    .onTapGesture { dismiss() }
            }
        }
        .overlay(alignment: .top) { feedbackBanner }
        .overlay(alignment: .top) { endedBanner }
        .sheet(item: $designing) { p in
            NavigationStack { LushPatternDesigner(engine: engine, pattern: p) }
        }
        .onChange(of: engine.curveAnchors[toyID]) { _, a in
            // Her phone reported where the curve really is: re-sync our estimate.
            guard let a, let curve else { return }
            anchor = (a.playhead, a.at)
            trail.add(0, curve: curve, offset: a.playhead, strength: Double(strength) / 100, at: a.at)
        }
        .onChange(of: engine.driving[toyID]) { _, now in sync(now) }
        .sensoryFeedback(.warning, trigger: engine.lastFeedback?.id)
        .sensoryFeedback(.selection, trigger: level)
        .sensoryFeedback(.selection, trigger: strength)
        .sensoryFeedback(.impact(weight: .heavy), trigger: level == channel.max)
        .onAppear(perform: restore)
        .statusBarHidden(dragging)
        // Pushed in the host's stack, but it keeps the whole screen: the
        // screen is the control, and an edge swipe would fight the drag.
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
    }

    // MARK: pieces

    private func header(_ toy: LushToy) -> some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left").font(.headline).frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Back")

            VStack(alignment: .leading, spacing: 2) {
                Text(toy.name.isEmpty ? toy.model : toy.name).font(.headline)
                Text(subtitle(toy)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !toy.owned {
                let c = engine.contacts.first { $0.id == toy.ownerID }
                Avatar(name: c?.name ?? "", data: c?.avatar, size: 36,
                       ring: toy.online ? LushPalette.accent(intensity) : nil)
            }
        }
        .padding(.top, 8)
    }

    private func subtitle(_ toy: LushToy) -> String {
        var parts: [String] = []
        if !toy.owned { parts.append(engine.name(for: toy.ownerID).split(separator: " ").first.map(String.init).map { $0 + "'s" } ?? "") }
        parts.append(toy.online ? "online" : "offline")
        if let b = toy.battery, toy.online { parts.append("\(b)%") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var feedbackBanner: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if let fb = engine.lastFeedback, fb.toyID == toyID, ctx.date.timeIntervalSince(fb.at) < 5 {
                Label("\(firstName(engine.name(for: fb.from))) \(fb.kind.driverText)", systemImage: fb.kind.symbol)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular.tint(LushPalette.accent(0.8).opacity(0.4)), in: .capsule)
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: engine.lastFeedback?.id)
        .allowsHitTesting(false)
    }

    /// "Sam paused it", "Pattern finished": what you were driving stopped.
    @ViewBuilder
    private var endedBanner: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if let e = engine.lastEnded, e.toyID == toyID, ctx.date.timeIntervalSince(e.at) < 5 {
                Label(e.reason == .finished ? "Pattern finished" : "\(firstName(engine.name(for: e.by))) \(e.reason.text)",
                      systemImage: e.reason == .finished ? "checkmark" : "hand.raised.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: engine.lastEnded?.id)
        .allowsHitTesting(false)
    }

    private func firstName(_ s: String) -> String { s.split(separator: " ").first.map(String.init)?.capitalized ?? s }

    private var readout: some View {
        VStack(spacing: 6) {
            Group {
                if let curve {
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        VStack(spacing: 4) {
                            Text(curve.name).font(.system(size: 52, weight: .heavy, design: .rounded))
                            if let phase = curve.phase(at: curvePlayhead(ctx.date)) {
                                Text(phase.label).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            if dragging || strength != 100 {
                                Text("\(strength)%")
                                    .font(.system(size: 34, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .contentTransition(.numericText(value: Double(strength)))
                            }
                        }
                    }
                } else if let pattern {
                    Text(pattern.capitalized)
                        .font(.system(size: 64, weight: .heavy, design: .rounded))
                } else {
                    Text("\(level)")
                        .font(.system(size: 132, weight: .black, design: .rounded))
                        .contentTransition(.numericText(value: Double(level)))
                        .monospacedDigit()
                }
            }
            .shadow(color: LushPalette.accent(intensity).opacity(0.9), radius: 18 + intensity * 24)
            .animation(.snappy(duration: 0.18), value: level)

            Text(toy?.online == false ? "Offline"
                 : toy?.paused == true ? "\(firstName(engine.name(for: toy?.ownerID))) paused it"
                 : engine.connection != .online ? "Reconnecting…"
                 : curve != nil ? (dragging ? "Strength" : "Slide to set the strength")
                 : (dragging ? channel.title : release.hint))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var chipDivider: some View {
        Capsule().fill(.secondary.opacity(0.35)).frame(width: 1.5, height: 22).padding(.horizontal, 2)
    }

    private func controls(_ toy: LushToy) -> some View {
        VStack(spacing: 14) {
            let channels = Channel.available(toy.caps)
            if channels.count > 1 {
                HStack(spacing: 6) {
                    ForEach(channels) { c in
                        Button(c.title) { channel = c }
                            .buttonStyle(.glass)
                            .tint(c == channel ? LushPalette.accent(intensity) : nil)
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(engine.patterns) { c in
                        Button {
                            play(c, on: toy)
                        } label: {
                            HStack(spacing: 6) {
                                CurveGlyph(pattern: c).stroke(style: .init(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                                    .frame(width: 26, height: 14)
                                Text(c.name).font(.subheadline.weight(.semibold))
                            }
                            .padding(.horizontal, 4)
                        }
                        .buttonStyle(.glass)
                        .tint(curve?.id == c.id ? LushPalette.accent(0.6) : nil)
                    }
                    Button {
                        designing = .researchTemplate()
                    } label: {
                        Image(systemName: "plus").font(.subheadline.weight(.semibold)).padding(.horizontal, 2)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Design a pattern")
                    chipDivider
                    ForEach(LushPattern.house) { c in
                        Button {
                            play(c, on: toy)
                        } label: {
                            HStack(spacing: 6) {
                                CurveGlyph(pattern: c).stroke(style: .init(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                                    .frame(width: 26, height: 14)
                                Text(c.name).font(.subheadline.weight(.semibold))
                            }
                            .padding(.horizontal, 4)
                        }
                        .buttonStyle(.glass)
                        .tint(curve?.id == c.id ? LushPalette.accent(0.6) : nil)
                        .contextMenu {
                            Button("Make my own version", systemImage: "square.on.square") { designing = c.duplicate() }
                        }
                    }
                    chipDivider
                    ForEach(ToyAction.patterns, id: \.self) { p in
                        Button {
                            play(p, on: toy)
                        } label: {
                            HStack(spacing: 6) {
                                PatternGlyph(name: p).stroke(style: .init(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                                    .frame(width: 26, height: 14)
                                Text(p.capitalized).font(.subheadline.weight(.medium))
                            }
                            .padding(.horizontal, 4)
                        }
                        .buttonStyle(.glass)
                        .tint(pattern == p ? LushPalette.accent(0.6) : nil)
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollClipDisabled()
            .disabled(toy.paused) // she paused it: only Stop

            HStack {
                Picker("When you let go", selection: $engine.releaseMode) {
                    ForEach(ReleaseMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                Spacer()
                Button {
                    stop(toy)
                } label: {
                    Image(systemName: "stop.fill").font(.title2).frame(width: 64, height: 64)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .accessibilityLabel("Stop")
            }
        }
        .disabled(!toy.online)
    }

    /// The whole screen is the slider.
    private func surface(_ toy: LushToy) -> some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard toy.online, !toy.paused, engine.connection == .online else { return }
                            dragging = true
                            let top = geo.size.height * 0.16, bottom = geo.size.height * 0.80
                            let f = 1 - (g.location.y - top) / (bottom - top)
                            let next = Int((min(max(f, 0), 1) * Double(channel.max)).rounded())
                            if let curve {
                                let s = Self.strength(at: f)
                                if s != strength { setStrength(s, of: curve, on: toy) }
                            } else if pattern != nil || next != level {
                                send(next, on: toy)
                            }
                        }
                        .onEnded { _ in
                            dragging = false
                            if release == .touch, curve == nil, level > 0 { send(0, on: toy) }
                        }
                )
        }
        .ignoresSafeArea()
    }

    // MARK: actions

    private func send(_ value: Int, on toy: LushToy) {
        pattern = nil
        curve = nil
        levels[channel] = value
        trail.add(Double(value) / Double(channel.max))
        engine.set(channel.action(value), on: toy)
    }

    private func play(_ c: LushPattern, on toy: LushToy) {
        pattern = nil
        levels = [:]
        curve = c
        strength = 100
        anchor = (0, Date())
        trail.add(0, curve: c, offset: 0, at: anchor.date)
        engine.set(.curve(c), on: toy)
    }

    /// Same curve, same place, stronger or softer.
    private func setStrength(_ s: Int, of c: LushPattern, on toy: LushToy) {
        strength = s
        let now = Date()
        trail.add(0, curve: c, offset: curvePlayhead(now), strength: Double(s) / 100, at: now)
        // Same run (play), new strength: her phone adjusts it in place.
        guard case .curve(_, _, let play)? = engine.driving[toy.id] else { return }
        engine.set(.curve(c, strength: s, play: play), on: toy)
    }

    private func play(_ p: String, on toy: LushToy) {
        curve = nil
        pattern = p
        patternStart = Date()
        levels = [:]
        trail.add(0.6, pattern: p, at: patternStart)
        engine.set(.pattern(p), on: toy)
    }

    private func stop(_ toy: LushToy) {
        pattern = nil
        curve = nil
        levels = [:]
        trail.add(0)
        engine.stop(toy)
    }

    /// Follow the engine when what it's driving changes underneath us: it
    /// ended (her pause, a finished pattern, someone else's Stop, a lost
    /// connection), or a curve was started elsewhere (the designer's "Try on").
    private func sync(_ now: ToyAction?) {
        switch now {
        case nil:
            guard curve != nil || pattern != nil || level > 0 else { return }
            curve = nil
            pattern = nil
            levels = [:]
            trail.add(0)
        case .curve(let c, let s, _)? where curve != c:
            pattern = nil
            levels = [:]
            curve = c
            strength = s
            let a = engine.curveAnchors[toyID]
            anchor = (a?.playhead ?? 0, a?.at ?? Date())
            trail.add(0, curve: c, offset: curvePlayhead(Date()), strength: Double(s) / 100)
        default:
            break
        }
    }

    /// Pick up where this phone left off, if it's still driving this toy.
    private func restore() {
        guard let toy else { return }
        channel = Channel.available(toy.caps).first ?? .vibrate
        switch engine.driving[toy.id] {
        case .vibrate(let l, _): channel = .vibrate; levels[.vibrate] = l
        case .rotate(let l, _): channel = .rotate; levels[.rotate] = l
        case .air(let l): channel = .air; levels[.air] = l
        case .thrust(let l): channel = .thrust; levels[.thrust] = l
        case .pattern(let p): pattern = p
        case .curve(let c, let s, _):
            curve = c
            strength = s
            if let a = engine.curveAnchors[toy.id] { anchor = (a.playhead, a.at) }
        case .stop, nil: break
        }
        if let curve {
            trail.add(0, curve: curve, offset: curvePlayhead(Date()), strength: Double(strength) / 100)
        } else {
            trail.add(intensity, pattern: pattern)
        }
    }
}

/// The last few seconds of what was sent: levels, and patterns (drawn with
/// their shape, live).
struct Trail {
    static let window: TimeInterval = 8
    struct Point {
        let at: Date
        let value: Double
        let pattern: String?
        var curve: LushPattern? = nil
        /// The curve's playhead at `at`.
        var offset: Double = 0
        /// The curve's strength (1 = as designed).
        var strength: Double = 1
    }
    private(set) var points: [Point] = []

    mutating func add(_ value: Double, pattern: String? = nil, curve: LushPattern? = nil, offset: Double = 0, strength: Double = 1, at now: Date = Date()) {
        points.append(Point(at: now, value: value, pattern: pattern, curve: curve, offset: offset, strength: strength))
        // Keep one point older than the window so the line enters from the edge.
        while points.count > 2, now.timeIntervalSince(points[1].at) > Self.window { points.removeFirst() }
    }

    /// What the line shows at time t: a pattern's shape while it plays, else the
    /// level, eased over ~120 ms from the previous one so changes read as motion.
    func value(at t: Date) -> Double? {
        guard let i = points.lastIndex(where: { $0.at <= t }) else { return nil }
        let p = points[i]
        if let name = p.pattern { return PatternShape.value(name, at: t.timeIntervalSince(p.at)) }
        if let c = p.curve {
            let v = c.level(at: c.position(after: p.offset + t.timeIntervalSince(p.at))) * p.strength
            return min(v, Double(ToyAction.maxLevel)) / Double(ToyAction.maxLevel)
        }
        let since = t.timeIntervalSince(p.at)
        guard i > 0, since < 0.12, let before = value(at: p.at.addingTimeInterval(-0.0001)) else { return p.value }
        let k = since / 0.12
        return before + (p.value - before) * (k * k * (3 - 2 * k)) // smoothstep
    }
}

/// The trail, drifting right-to-left across the middle of the screen.
struct TrailView: View {
    let trail: Trail
    let color: Color
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !live)) { ctx in
            Canvas { gc, size in
                let now = ctx.date
                let band = CGRect(x: 0, y: size.height * 0.30, width: size.width, height: size.height * 0.40)
                let samples = 160
                var path = Path()
                var started = false
                for i in 0...samples {
                    let x = size.width * Double(i) / Double(samples)
                    let t = now.addingTimeInterval(-Trail.window * (1 - Double(i) / Double(samples)))
                    guard let v = trail.value(at: t) else { continue }
                    let pt = CGPoint(x: x, y: band.maxY - band.height * v)
                    if started { path.addLine(to: pt) } else { path.move(to: pt); started = true }
                }
                guard started else { return }
                var glow = gc
                glow.addFilter(.blur(radius: 6))
                glow.stroke(path, with: .color(color.opacity(0.55)), style: .init(lineWidth: 6, lineCap: .round, lineJoin: .round))
                gc.stroke(path, with: .color(color.opacity(0.9)), style: .init(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .ignoresSafeArea()
    }
}
