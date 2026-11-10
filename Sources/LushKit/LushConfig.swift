import Foundation

/// Everything LushKit needs from the host. The token provider is `@Sendable` +
/// `async` so the host can hand over its current mvServer access token
/// (auto-refreshed) from its own actor. LushKit never logs anyone in.
public struct LushConfig: Sendable {
    /// mvLush base URL (Connect), e.g. `https://lush.example.app`. The live socket
    /// is derived from it: same host, `ws(s)://…/live/v1`.
    public let baseURL: URL
    /// The signed-in user (mvServer UUID).
    public let currentUserID: UUID
    public let tokenProvider: @Sendable () async -> String?
    /// Stable per install: one live socket per (user, device); a newer one
    /// replaces the older. Defaults to an id kept in UserDefaults.
    public let deviceID: String
    /// Shown in the owner's history ("online — Sam's iPhone").
    public let deviceName: String
    public let appVersion: String

    public init(baseURL: URL,
                currentUserID: UUID,
                tokenProvider: @escaping @Sendable () async -> String?,
                deviceID: String = LushConfig.installID(),
                deviceName: String = "iPhone",
                appVersion: String = "0") {
        self.baseURL = baseURL
        self.currentUserID = currentUserID
        self.tokenProvider = tokenProvider
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.appVersion = appVersion
    }

    /// `/live/v1` on the same host: http → ws, https → wss.
    public var liveURL: URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.scheme = (c.scheme == "https") ? "wss" : "ws"
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + "/live/v1"
        return c.url ?? baseURL
    }

    /// The live transport — Connect/protobuf against mvLush.
    public var transport: any LushTransport {
        ConnectLushTransport(baseURL: baseURL, tokenProvider: tokenProvider)
    }

    static let installIDKey = "LushKit.installID"

    /// A UUID made once per install and kept in UserDefaults. The engine's
    /// `wipeLocalStore()` removes it (the next sign-in makes a new one).
    public static func installID(defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: installIDKey) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: installIDKey)
        return id
    }
}
