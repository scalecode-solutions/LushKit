import Foundation

/// Which backend LushLab talks to. Auth goes to mvServer (WebSocket via MvAuth);
/// lush calls go to mvLush (Connect + the /live/v1 socket via LushKit). Same
/// credentials, two services. Develop against **Local** (mvServer + mvLush in
/// local Docker).
enum LabServer: String, CaseIterable, Identifiable, Sendable {
    case production = "Production"
    case local = "Local"

    var id: String { rawValue }

    /// Where the local stack lives. "localhost" on a simulator; on a real phone,
    /// the Mac's name on the network (e.g. "My-Mac.local"), set on the login
    /// screen. The Mac must publish both ports on the network for that.
    static var localHost: String {
        get {
            let h = UserDefaults.standard.string(forKey: "LushLab.localHost")?.trimmingCharacters(in: .whitespaces) ?? ""
            return h.isEmpty ? "localhost" : h
        }
        set { UserDefaults.standard.set(newValue, forKey: "LushLab.localHost") }
    }

    /// mvServer WebSocket endpoint MvAuth logs in against.
    var authWS: URL {
        switch self {
        case .production: URL(string: "wss://api.mvchat.app/v0/ws")!
        case .local:      URL(string: "ws://\(Self.localHost):6170/v0/ws") ?? URL(string: "ws://localhost:6170/v0/ws")!
        }
    }

    /// mvLush base URL LushKit talks to (the live socket is derived from it).
    var lushBaseURL: URL {
        switch self {
        case .production: URL(string: "https://lush.mvchat.app")!
        case .local:      URL(string: "http://\(Self.localHost):6094") ?? URL(string: "http://localhost:6094")!
        }
    }
}
