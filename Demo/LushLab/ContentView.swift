import SwiftUI
import LushKit
import MvAuth

struct ContentView: View {
    @State private var auth = AuthModel()

    var body: some View {
        #if DEBUG
        // Automation: `LUSHLAB_USER` + `LUSHLAB_TOKEN` (a minted dev token) skip
        // the login screen, so a script can drive two simulators without
        // anyone's password. Debug builds only.
        if let dev = DevSession.fromEnvironment {
            LushLabHost(userID: dev.userID, baseURL: dev.baseURL, serverName: "Local (dev token)",
                        tokenProvider: { dev.token }, signOut: {})
        } else {
            signedIn
        }
        #else
        signedIn
        #endif
    }

    @ViewBuilder private var signedIn: some View {
        switch auth.state {
        case .loggedIn(let profile):
            LushLabHost(userID: profile.userID, baseURL: auth.server.lushBaseURL, serverName: auth.server.rawValue,
                        tokenProvider: { [auth] in await auth.accessToken() }, signOut: { [auth] in auth.logOut() })
                .id(profile.userID) // a fresh engine per identity
        default:
            LoginView(auth: auth)
        }
    }
}

#if DEBUG
struct DevSession: Sendable {
    let userID: String
    let token: String
    let baseURL: URL

    static var fromEnvironment: DevSession? {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["LUSHLAB_USER"], UUID(uuidString: user) != nil,
              let token = env["LUSHLAB_TOKEN"], !token.isEmpty else { return nil }
        let base = env["LUSHLAB_URL"].flatMap(URL.init(string:)) ?? LabServer.local.lushBaseURL
        return DevSession(userID: user, token: token, baseURL: base)
    }
}
#endif

/// The dev host, shaped like a production one: the engine is built inert with
/// the Lab's token provider, runs only while this screen is up and the app is
/// in front, and is wiped on sign-out. Bluetooth is the kit's; the Lab only
/// hands it the engine (a production host also passes its system-dialog guard).
struct LushLabHost: View {
    let userID: String
    let serverName: String
    let signOut: @MainActor () -> Void
    @State private var engine: LushEngine
    @State private var bluetooth: LushBluetooth
    @Environment(\.scenePhase) private var scenePhase
    #if targetEnvironment(simulator)
    @AppStorage("LushLab.simulatedToy") private var simulatedOn = true
    #else
    @AppStorage("LushLab.simulatedToy") private var simulatedOn = false
    #endif

    init(userID: String, baseURL: URL, serverName: String,
         tokenProvider: @escaping @Sendable () async -> String?, signOut: @escaping @MainActor () -> Void) {
        self.userID = userID
        self.serverName = serverName
        self.signOut = signOut
        let config = LushConfig(
            baseURL: baseURL,
            currentUserID: UUID(uuidString: userID) ?? UUID(),
            tokenProvider: tokenProvider,
            deviceName: UIDevice.current.name,
            appVersion: "lab"
        )
        let engine = LushEngine(config: config)
        _engine = State(initialValue: engine)
        _bluetooth = State(initialValue: LushBluetooth(engine: engine))
    }

    var body: some View {
        NavigationStack {
            LushView(engine: engine, bluetooth: bluetooth)
                .navigationTitle("Lush")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            LushOwnerView(engine: engine) { labSection; accountSection }
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Manage")
                    }
                }
        }
        .task {
            engine.start()
            applySimulatedToy()
        }
        .onDisappear { engine.stop() }
        // Silent unless it's on screen: leaving the foreground stops every toy
        // on this phone and drops the socket; coming back reconnects.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: engine.start()
            case .background: engine.stop()
            default: break
            }
        }
        .onChange(of: simulatedOn) { applySimulatedToy() }
    }

    /// The simulator has no Bluetooth, so the Lab can host a pretend toy. Its
    /// hardware key is stable per install, so it keeps its toy id on the server.
    private var simulatedKey: String {
        "SIM:" + String(LushConfig.installID().prefix(8)).uppercased()
    }

    private func applySimulatedToy() {
        if simulatedOn {
            engine.host(SimulatedToy(hwKey: simulatedKey, name: "Sim (\(UIDevice.current.name))"))
        } else {
            engine.unhost(hwKey: simulatedKey)
        }
    }

    private var labSection: some View {
        Section {
            Toggle("Host a simulated toy", isOn: $simulatedOn)
        } header: {
            Text("Lab")
        } footer: {
            Text("A pretend toy on this phone, so the full loop runs without Bluetooth.")
        }
    }

    /// LushLab's own rows, appended to the kit's owner screen.
    private var accountSection: some View {
        Section {
            LabeledContent("User ID") {
                Text(userID).font(.caption.monospaced()).textSelection(.enabled)
            }
            LabeledContent("Server", value: serverName)
            Button("Sign out", role: .destructive) {
                bluetooth.shutdown()
                engine.wipeLocalStore()
                signOut()
            }
        } header: {
            Text("Account")
        }
    }
}
