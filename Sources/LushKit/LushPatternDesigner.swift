import SwiftUI

/// Draw your own pattern: a curve of intensity over time, split into named
/// phases. Drag a point to move it (time sideways, level up and down), tap
/// empty space to add one. Starts from the research template.
public struct LushPatternDesigner: View {
    let engine: LushEngine
    @State private var draft: LushPattern
    @State private var selected: Int?
    @State private var dragging: Int?
    @State private var pxPerSecond: Double = 6
    @State private var saving = false
    @State private var status: String?
    @State private var naming: NamingPhase?
    @Environment(\.dismiss) private var dismiss

    private struct NamingPhase: Identifiable {
        let id = UUID()
        let at: Double
        var label = ""
    }

    public init(engine: LushEngine, pattern: LushPattern) {
        self.engine = engine
        _draft = State(initialValue: pattern)
    }

    private let height: CGFloat = 280
    private var drivable: [LushToy] { engine.toys.filter(\.online) }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TextField("Name", text: $draft.name)
                    .font(.title2.weight(.bold))
                    .padding(14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))

                canvas

                HStack {
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                    Slider(value: $pxPerSecond, in: 2...40)
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                }

                if let i = selected, draft.points.indices.contains(i) {
                    pointCard(i)
                }
                phasesCard
                summary

                if let status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(18)
        }
        .scrollContentBackground(.hidden)
        .background { AuroraBackground(intensity: 0.15) }
        .navigationTitle(draft.isSaved ? "Edit pattern" : "New pattern")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .disabled(!draft.isValid || saving)
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    if drivable.isEmpty { Text("No toy online") }
                    ForEach(drivable) { toy in
                        Button(toy.owned ? toy.name : "\(engine.name(for: toy.ownerID))'s \(toy.name)") {
                            engine.set(.curve(draft), on: toy)
                            status = "Playing on \(toy.name) — Stop from its control screen."
                        }
                    }
                    Divider()
                    Button("Start over from the research template", systemImage: "arrow.counterclockwise") {
                        let (id, name) = (draft.id, draft.name)
                        draft = .researchTemplate(name: name.isEmpty ? "Signature" : name)
                        draft.id = id // a reset edits the same pattern
                        selected = nil
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert("Name this phase", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("e.g. Tease", text: Binding(get: { naming?.label ?? "" }, set: { naming?.label = $0 }))
            Button("Add") { addMark() }
            Button("Cancel", role: .cancel) { naming = nil }
        }
    }

    // MARK: canvas

    private var canvas: some View {
        let width = max(320, draft.duration * pxPerSecond + 40)
        return ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                Canvas { gc, size in draw(gc, size) }
                    .frame(width: width, height: height)
                    .contentShape(.rect)
                    .gesture(drag)
                ForEach(Array(draft.marks.enumerated()), id: \.offset) { _, m in
                    Text(m.label)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .glassEffect(.regular, in: .capsule)
                        .offset(x: x(m.at) + 4, y: 6)
                        .allowsHitTesting(false)
                }
            }
            .padding(.vertical, 4)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func x(_ t: Double) -> CGFloat { 20 + t * pxPerSecond }
    private func y(_ level: Double) -> CGFloat { height - 24 - (height - 48) * level / Double(ToyAction.maxLevel) }
    private func time(atX px: CGFloat) -> Double { max(0, (px - 20) / pxPerSecond) }
    private func level(atY py: CGFloat) -> Int {
        let v = (height - 24 - py) / (height - 48) * Double(ToyAction.maxLevel)
        return min(max(Int(v.rounded()), 0), ToyAction.maxLevel)
    }

    private func draw(_ gc: GraphicsContext, _ size: CGSize) {
        // Level guides.
        for l in [0, 5, 10, 15, 20] {
            var g = Path()
            g.move(to: CGPoint(x: 0, y: y(Double(l))))
            g.addLine(to: CGPoint(x: size.width, y: y(Double(l))))
            gc.stroke(g, with: .color(.primary.opacity(l == 0 ? 0.18 : 0.07)), lineWidth: 1)
        }
        // Phase lines.
        for m in draft.marks {
            var g = Path()
            g.move(to: CGPoint(x: x(m.at), y: 0))
            g.addLine(to: CGPoint(x: x(m.at), y: size.height))
            gc.stroke(g, with: .color(.primary.opacity(0.22)), style: .init(lineWidth: 1, dash: [4, 4]))
        }
        guard !draft.points.isEmpty else { return }
        var line = Path()
        for (i, p) in draft.points.enumerated() {
            let pt = CGPoint(x: x(p.at), y: y(Double(p.level)))
            i == 0 ? line.move(to: pt) : line.addLine(to: pt)
        }
        var fill = line
        fill.addLine(to: CGPoint(x: x(draft.duration), y: y(0)))
        fill.addLine(to: CGPoint(x: x(0), y: y(0)))
        fill.closeSubpath()
        gc.fill(fill, with: .linearGradient(
            Gradient(colors: [LushPalette.accent(1).opacity(0.55), LushPalette.accent(0.5).opacity(0.25), LushPalette.accent(0).opacity(0.08)]),
            startPoint: CGPoint(x: 0, y: y(20)), endPoint: CGPoint(x: 0, y: y(0))))
        gc.stroke(line, with: .color(LushPalette.accent(0.7)), style: .init(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        for (i, p) in draft.points.enumerated() {
            let big = i == selected || i == dragging
            let r: CGFloat = big ? 8 : 4
            let c = CGRect(x: x(p.at) - r, y: y(Double(p.level)) - r, width: r * 2, height: r * 2)
            gc.fill(Path(ellipseIn: c), with: .color(big ? .white : LushPalette.accent(Double(p.level) / 20)))
            if big { gc.stroke(Path(ellipseIn: c), with: .color(LushPalette.accent(0.7)), lineWidth: 3) }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if dragging == nil {
                    // Grab the nearest point within reach, if any.
                    let near = draft.points.indices.min {
                        hypot(x(draft.points[$0].at) - g.startLocation.x, y(Double(draft.points[$0].level)) - g.startLocation.y)
                            < hypot(x(draft.points[$1].at) - g.startLocation.x, y(Double(draft.points[$1].level)) - g.startLocation.y)
                    }
                    if let near, hypot(x(draft.points[near].at) - g.startLocation.x,
                                       y(Double(draft.points[near].level)) - g.startLocation.y) < 28 {
                        dragging = near
                        selected = near
                    } else {
                        return
                    }
                }
                guard let i = dragging else { return }
                var p = draft.points[i]
                p.level = level(atY: g.location.y)
                if i > 0 {
                    // Stay between neighbors; the first point is pinned at 0.
                    let lo = draft.points[i - 1].at + 0.1
                    let hi = i + 1 < draft.points.count ? draft.points[i + 1].at - 0.1 : 3600
                    p.at = (min(max(time(atX: g.location.x), lo), hi) * 10).rounded() / 10
                }
                draft.points[i] = p
            }
            .onEnded { g in
                defer { dragging = nil }
                guard dragging == nil, hypot(g.translation.width, g.translation.height) < 6 else { return }
                addPoint(at: time(atX: g.location.x), level: level(atY: g.location.y))
            }
    }

    private func addPoint(at t: Double, level: Int) {
        let t = (t * 10).rounded() / 10
        guard t > 0, !draft.points.contains(where: { abs($0.at - t) < 0.1 }), draft.points.count < 600 else { return }
        let i = draft.points.firstIndex { $0.at > t } ?? draft.points.count
        draft.points.insert(.init(at: t, level: level), at: i)
        selected = i
    }

    // MARK: cards

    private func pointCard(_ i: Int) -> some View {
        let p = draft.points[i]
        return GlassCard {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Level \(p.level)").font(.headline)
                    Text("at \(clock(p.at))").font(.subheadline).foregroundStyle(.secondary)
                    if let ph = draft.phase(at: p.at) {
                        Text(ph.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Phase here", systemImage: "flag") { naming = NamingPhase(at: p.at) }
                    .buttonStyle(.glass)
                    .disabled(draft.marks.contains { abs($0.at - p.at) < 0.1 })
                if i > 0 && i < draft.points.count - 1 {
                    Button(role: .destructive) {
                        draft.points.remove(at: i)
                        selected = nil
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private var phasesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Phases").font(.headline)
                Text("Her “More” skips to the next phase.").font(.caption).foregroundStyle(.secondary)
                if draft.marks.isEmpty {
                    Text("Select a point and tap “Phase here”.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(Array(draft.marks.enumerated()), id: \.offset) { i, m in
                    HStack {
                        Text(m.label).font(.subheadline.weight(.medium))
                        Spacer()
                        Text(clock(m.at)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            draft.marks.remove(at: i)
                        } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var summary: some View {
        HStack {
            Label(clock(draft.duration), systemImage: "clock")
            Spacer()
            Label("\(draft.points.count) points", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }

    private func clock(_ t: Double) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: actions

    private func addMark() {
        guard let n = naming else { return }
        let label = n.label.trimmingCharacters(in: .whitespaces)
        naming = nil
        guard !label.isEmpty else { return }
        draft.marks.append(.init(at: n.at, label: String(label.prefix(24))))
        draft.marks.sort { $0.at < $1.at }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            draft = try await engine.save(draft)
            status = "Saved."
        } catch {
            status = "Couldn't save — \(error.localizedDescription)"
        }
    }
}
