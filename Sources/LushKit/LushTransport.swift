import Foundation
import Connect
import SwiftProtobuf

/// Transport-level failures.
public enum LushTransportError: Error, Sendable, Equatable {
    case notAuthenticated
    case rpc(code: String, message: String)
    case badResponse(String)
}

/// The kit's view of the control plane. A protocol so tests and previews can fake it.
public protocol LushTransport: Sendable {
    func listToys() async throws -> [LushToy]
    func renameToy(id: UUID, to name: String) async throws
    func forgetToy(id: UUID) async throws
    func createGrant(granteeID: UUID, label: String, expiresAt: Date?) async throws -> LushGrant
    func revokeGrant(id: UUID) async throws
    func listGrants() async throws -> [LushGrant]
    func listContacts() async throws -> [LushContact]
    func listEvents(limit: Int) async throws -> [LushEvent]
    func listPatterns() async throws -> [LushPattern]
    /// Create (no id) or replace a pattern; returns it as saved.
    func savePattern(_ p: LushPattern) async throws -> LushPattern
    func deletePattern(id: String) async throws
}

public extension LushTransport {
    func listPatterns() async throws -> [LushPattern] { [] }
    func savePattern(_ p: LushPattern) async throws -> LushPattern { p }
    func deletePattern(id: String) async throws {}
}

/// `LushTransport` over Connect/protobuf. Wraps the generated client and injects
/// the bearer token per call.
public struct ConnectLushTransport: LushTransport {
    private let client: Lush_V1_LushServiceClient
    private let tokenProvider: @Sendable () async -> String?

    public init(baseURL: URL, tokenProvider: @escaping @Sendable () async -> String?) {
        let config = ProtocolClientConfig(host: baseURL.absoluteString, networkProtocol: .connect, codec: ProtoCodec())
        self.client = Lush_V1_LushServiceClient(client: ProtocolClient(httpClient: URLSessionHTTPClient(), config: config))
        self.tokenProvider = tokenProvider
    }

    // MARK: plumbing

    private func headers() async throws -> Headers {
        guard let tok = await tokenProvider() else { throw LushTransportError.notAuthenticated }
        return ["Authorization": ["Bearer \(tok)"]]
    }

    private func value<T>(_ r: ResponseMessage<T>) throws -> T {
        if let m = r.message { return m }
        if let e = r.error {
            if e.code == .unauthenticated { throw LushTransportError.notAuthenticated }
            throw LushTransportError.rpc(code: "\(e.code)", message: e.message ?? "rpc failed")
        }
        throw LushTransportError.badResponse("empty rpc response")
    }

    // MARK: toys

    public func listToys() async throws -> [LushToy] {
        try value(await client.listToys(request: .init(), headers: try await headers())).toys.map(Wire.toy)
    }

    public func renameToy(id: UUID, to name: String) async throws {
        var req = Lush_V1_RenameToyRequest()
        req.toyID = id.uuidString
        req.name = name
        _ = try value(await client.renameToy(request: req, headers: try await headers()))
    }

    public func forgetToy(id: UUID) async throws {
        var req = Lush_V1_ForgetToyRequest()
        req.toyID = id.uuidString
        _ = try value(await client.forgetToy(request: req, headers: try await headers()))
    }

    // MARK: grants

    public func createGrant(granteeID: UUID, label: String, expiresAt: Date?) async throws -> LushGrant {
        var req = Lush_V1_CreateGrantRequest()
        req.granteeID = granteeID.uuidString
        req.label = label
        if let expiresAt { req.expiresAt = Int64(expiresAt.timeIntervalSince1970 * 1000) }
        return try Wire.grant(value(await client.createGrant(request: req, headers: try await headers())).grant)
    }

    public func revokeGrant(id: UUID) async throws {
        var req = Lush_V1_RevokeGrantRequest()
        req.grantID = id.uuidString
        _ = try value(await client.revokeGrant(request: req, headers: try await headers()))
    }

    public func listGrants() async throws -> [LushGrant] {
        try value(await client.listGrants(request: .init(), headers: try await headers())).grants.map(Wire.grant)
    }

    public func listContacts() async throws -> [LushContact] {
        try value(await client.listContacts(request: .init(), headers: try await headers())).contacts.compactMap { c in
            guard let id = UUID(uuidString: c.id) else { return nil }
            return LushContact(id: id, name: c.name, avatar: c.avatar.isEmpty ? nil : Data(base64Encoded: c.avatar))
        }
    }

    public func listPatterns() async throws -> [LushPattern] {
        try value(await client.listPatterns(request: .init(), headers: try await headers())).patterns.map(Wire.pattern)
    }

    public func savePattern(_ p: LushPattern) async throws -> LushPattern {
        var req = Lush_V1_SavePatternRequest()
        req.pattern = Wire.curve(p)
        return Wire.pattern(try value(await client.savePattern(request: req, headers: try await headers())).pattern)
    }

    public func deletePattern(id: String) async throws {
        var req = Lush_V1_DeletePatternRequest()
        req.id = id
        _ = try value(await client.deletePattern(request: req, headers: try await headers()))
    }

    public func listEvents(limit: Int) async throws -> [LushEvent] {
        var req = Lush_V1_ListEventsRequest()
        req.limit = Int32(limit)
        return try value(await client.listEvents(request: req, headers: try await headers())).events.compactMap { e in
            guard let id = UUID(uuidString: e.id) else { return nil }
            return LushEvent(id: id, toyID: UUID(uuidString: e.toyID), kind: e.kind, actorID: UUID(uuidString: e.actorID),
                             at: Wire.date(e.at) ?? .distantPast, detail: e.detail)
        }
    }
}
