import SwiftUI

/// The owner screen: who may drive your toys, your toys' names, history, and the
/// receiver's log. The host appends its own rows (account, sign-out) via `extra`.
public struct LushOwnerView<Extra: View>: View {
    @Bindable var engine: LushEngine
    let extra: Extra
    @State private var sharing = false
    @State private var error: String?

    public init(engine: LushEngine, @ViewBuilder extra: () -> Extra) {
        self.engine = engine
        self.extra = extra()
    }

    public var body: some View {
        List {
            Section {
                ForEach(engine.grants) { grant in
                    HStack {
                        Image(systemName: "person.crop.circle")
                        Text(displayName(grant))
                        Spacer()
                        if let exp = grant.expiresAt {
                            Text(exp, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Revoke", role: .destructive) { Task { await revoke(grant) } }
                    }
                }
                Button {
                    sharing = true
                } label: {
                    Label("Share with someone", systemImage: "person.badge.plus")
                }
            } header: {
                Text("Who can drive your toys")
            } footer: {
                Text("A share covers all your toys. Revoking stops anything they're driving at once.")
            }

            Section {
                ForEach(engine.patterns) { p in
                    NavigationLink {
                        LushPatternDesigner(engine: engine, pattern: p)
                    } label: {
                        HStack(spacing: 12) {
                            CurveGlyph(pattern: p)
                                .stroke(LushPalette.accent(0.7), style: .init(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                                .frame(width: 44, height: 22)
                            Text(p.name)
                            Spacer()
                            Text("\(Int(p.duration) / 60):\(String(format: "%02d", Int(p.duration) % 60))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { Task { try? await engine.delete(p) } }
                    }
                }
                NavigationLink {
                    LushPatternDesigner(engine: engine, pattern: .researchTemplate())
                } label: {
                    Label("Design a pattern", systemImage: "scribble.variable")
                }
            } header: {
                Text("Your patterns")
            } footer: {
                Text("New patterns start from a research-based shape: warm-up bursts, a slow build, two edges, a steady plateau, a soft landing.")
            }

            Section {
                ForEach(LushPattern.house) { p in
                    NavigationLink {
                        LushPatternDesigner(engine: engine, pattern: p.duplicate())
                    } label: {
                        HStack(spacing: 12) {
                            CurveGlyph(pattern: p)
                                .stroke(LushPalette.accent(0.7), style: .init(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                                .frame(width: 44, height: 22)
                            Text(p.name)
                            Spacer()
                            Text(p.loop ? "loops" : "\(Int(p.duration) / 60):\(String(format: "%02d", Int(p.duration) % 60))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("House presets")
            } footer: {
                Text("Built from the research. Open one to make your own version of it.")
            }

            let mine = engine.toys.filter(\.owned)
            if !mine.isEmpty {
                Section("Your toys") {
                    ForEach(mine) { toy in
                        ToyNameRow(engine: engine, toy: toy)
                            .swipeActions {
                                Button("Forget", role: .destructive) {
                                    Task { try? await engine.forget(toy) }
                                }
                            }
                    }
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            Section("History") {
                if engine.events.isEmpty {
                    Text("Nothing yet.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(engine.events.prefix(50)) { e in
                    let line = e.line(actor: actorName(e))
                    HStack(alignment: .firstTextBaseline) {
                        Text(line.title).font(.subheadline)
                        if !line.note.isEmpty {
                            Text(line.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(e.at, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("This phone's log") {
                if engine.log.isEmpty {
                    Text("Quiet.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(engine.log.prefix(30)) { line in
                    VStack(alignment: .leading) {
                        Text(line.text).font(.caption.monospaced())
                        Text(line.at, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            extra
        }
        .scrollContentBackground(.hidden)
        .background { AuroraBackground(intensity: 0) }
        .navigationTitle("Manage")
        .refreshable { await engine.refreshLists() }
        .task { await engine.refreshLists() }
        .sheet(isPresented: $sharing) {
            LushShareSheet(engine: engine)
        }
    }

    /// "You", or a contact's first name, for whoever a history row is about.
    private func actorName(_ e: LushEvent) -> String {
        guard e.actorID != nil else { return "Someone" }
        let name = engine.name(for: e.actorID)
        return name.split(separator: " ").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? name
    }

    private func displayName(_ g: LushGrant) -> String {
        if let c = engine.contacts.first(where: { $0.id == g.granteeID }), !c.name.isEmpty { return c.name }
        return g.label.isEmpty ? "Someone" : g.label
    }

    private func revoke(_ g: LushGrant) async {
        do {
            try await engine.revoke(g)
            error = nil
        } catch {
            self.error = "Couldn't revoke — try again"
        }
    }
}

struct ToyNameRow: View {
    let engine: LushEngine
    let toy: LushToy
    @State private var name = ""

    var body: some View {
        TextField("Name", text: $name)
            .onAppear { name = toy.name }
            .onSubmit {
                let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !n.isEmpty, n != toy.name else { return }
                Task { try? await engine.rename(toy, to: n) }
            }
            .submitLabel(.done)
    }
}

/// Pick a friend to share your toys with.
struct LushShareSheet: View {
    let engine: LushEngine
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?
    @State private var query = ""

    private var candidates: [LushContact] {
        let granted = Set(engine.grants.map(\.granteeID))
        return engine.contacts
            .filter { $0.id != engine.config.currentUserID && !granted.contains($0.id) }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                ForEach(candidates) { c in
                    Button {
                        Task { await share(c) }
                    } label: {
                        HStack {
                            avatar(c)
                            Text(c.name.isEmpty ? "Unnamed" : c.name)
                        }
                    }
                    .disabled(busy)
                }
            }
            .searchable(text: $query)
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView("No one to add", systemImage: "person.2.slash",
                                           description: Text("Only friends can be shared with."))
                }
            }
            .navigationTitle("Share your toys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func avatar(_ c: LushContact) -> some View {
        if let data = c.avatar, let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFill().frame(width: 32, height: 32).clipShape(.circle)
        } else {
            Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary)
        }
    }

    private func share(_ c: LushContact) async {
        busy = true
        defer { busy = false }
        do {
            try await engine.grant(to: c)
            dismiss()
        } catch {
            self.error = "Couldn't share — try again"
        }
    }
}
