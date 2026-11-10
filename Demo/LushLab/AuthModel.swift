import Foundation
import Observation
import UIKit
import MvAuth

/// Real mvServer auth for LushLab. Logs in via MvAuth (WebSocket), holds the
/// token set, and hands LushKit a token provider that auto-refreshes. Replaces
/// the old dev-minted JWT — the access token here is a genuine mvServer JWT,
/// exactly what mvLush validates.
@MainActor
@Observable
final class AuthModel {
    enum State: Equatable {
        case loggedOut
        case loggingIn
        case loggedIn(UserProfile)
        case failed(String)
    }

    private(set) var state: State = .loggedOut
    private(set) var profile: UserProfile?
    private(set) var server: LabServer = .production

    private var tokens: TokenSet?
    private var client: MvAuthClient?
    /// One refresh at a time, shared by every caller: refresh tokens rotate, so
    /// two concurrent refreshes with the same token would revoke each other.
    private var refreshTask: Task<TokenSet, Error>?

    var isLoggingIn: Bool { state == .loggingIn }

    func login(server: LabServer, username: String, password: String) async {
        self.server = server
        state = .loggingIn

        let info = ClientInfo(
            protocolVersion: "0.1.0",
            userAgent: "LushLab/1.0 iOS",
            appBuild: "1",
            language: "en",
            platform: "ios",
            timeZone: TimeZone.current.identifier,
            deviceID: UIDevice.current.identifierForVendor?.uuidString
        )
        let client = MvAuthClient(serverURL: server.authWS, clientInfo: info)
        self.client = client

        do {
            let result = try await client.login(username: username, password: password)
            tokens = result.tokens
            profile = result.profile
            state = .loggedIn(result.profile)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    func logOut() {
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        profile = nil
        client = nil
        state = .loggedOut
    }

    /// The current access token for LushKit, refreshed when near expiry.
    /// Concurrent callers share one refresh. Only a dead session (expired refresh
    /// token, or the server rejecting it) logs out; a network blip keeps the
    /// session and returns the current token while it's still valid.
    func accessToken() async -> String? {
        guard let tokens, let client else { return nil }
        guard tokens.shouldRefreshAccessToken else { return tokens.accessToken }
        let task: Task<TokenSet, Error>
        if let running = refreshTask {
            task = running
        } else {
            let refreshToken = tokens.refreshToken
            task = Task { try await client.refresh(refreshToken: refreshToken) }
            refreshTask = task
        }
        do {
            let fresh = try await task.value
            // Signed out, or into another account, while this was running.
            guard self.client === client else { return nil }
            if refreshTask == task { refreshTask = nil }
            self.tokens = fresh
            return fresh.accessToken
        } catch {
            guard self.client === client else { return nil }
            if refreshTask == task { refreshTask = nil }
            if Self.sessionIsDead(error) {
                logOut()
                return nil
            }
            return tokens.isAccessTokenExpired ? nil : tokens.accessToken
        }
    }

    private static func sessionIsDead(_ error: Error) -> Bool {
        guard let e = error as? MvAuthError else { return false }
        switch e {
        case .refreshTokenExpired: return true
        case .serverError(let code, _): return code == 401 || code == 403
        default: return false
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let e = error as? MvAuthError else { return error.localizedDescription }
        switch e {
        case .serverError(let code, let text):
            return text ?? "Login failed (\(code))"
        case .connectionFailed, .connectionClosed, .timeout:
            return "Can't reach the server. Check the network and try again."
        case .refreshTokenExpired:
            return "Session expired. Please log in again."
        case .handshakeFailed(let reason):
            return "Handshake failed: \(reason)"
        case .malformedResponse, .underlying:
            return "Unexpected server response."
        }
    }
}
