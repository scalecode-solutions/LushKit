import Foundation
import SwiftProtobuf

/// What the live socket reports to its owner (the engine).
enum LiveEvent: Sendable {
    case connecting
    /// The server said Welcome: the socket is usable.
    case connected(Lush_V1_Welcome)
    case frame(Lush_V1_ServerFrame)
    /// The socket is gone. Every local toy must be stopped (silence stops the toy).
    case disconnected(reason: String)
}

/// One phone's `/live/v1` WebSocket: connect, Hello, read frames, reconnect with
/// backoff, Reauth before the token expires, and give up on a socket that has
/// gone quiet (the server sends Clock every 15 s).
actor LiveSocket {
    nonisolated let events: AsyncStream<LiveEvent>
    private let continuation: AsyncStream<LiveEvent>.Continuation

    private let url: URL
    private let tokenProvider: @Sendable () async -> String?
    private let hello: Lush_V1_Hello
    private let session: URLSession

    private var runTask: Task<Void, Never>?
    private var task: URLSessionWebSocketTask?
    private var reauthTask: Task<Void, Never>?
    private var lastFrameAt = Date()

    /// No frame for this long → the socket is dead (3 missed Clocks).
    static let quietLimit: TimeInterval = 45

    init(url: URL, hello: Lush_V1_Hello, tokenProvider: @escaping @Sendable () async -> String?,
         session: URLSession = URLSession(configuration: .ephemeral)) {
        self.url = url
        self.hello = hello
        self.tokenProvider = tokenProvider
        self.session = session
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    /// Start connecting (and keep reconnecting). Idempotent.
    func start() {
        guard runTask == nil else { return }
        runTask = Task { await self.run() }
    }

    /// Close and stop reconnecting.
    func stop() {
        runTask?.cancel()
        runTask = nil
        reauthTask?.cancel()
        reauthTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Send a frame if connected. Returns false when there's no socket.
    @discardableResult
    func send(_ frame: Lush_V1_ClientFrame) async -> Bool {
        guard let task, let data = try? frame.serializedData() else { return false }
        do {
            try await task.send(.data(data))
            return true
        } catch {
            return false
        }
    }

    // MARK: loop

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            continuation.yield(.connecting)
            let reason = await connectOnce(&attempt)
            reauthTask?.cancel()
            reauthTask = nil
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            continuation.yield(.disconnected(reason: reason))
            if Task.isCancelled { break }
            attempt += 1
            // 1, 2, 4, 8, 16, 30 s — with a little jitter so two phones don't sync up.
            let base = min(30, pow(2, Double(min(attempt, 5) - 1)))
            try? await Task.sleep(for: .seconds(base * Double.random(in: 0.8...1.2)))
        }
    }

    /// One connection's life. Returns why it ended.
    private func connectOnce(_ attempt: inout Int) async -> String {
        guard let token = await tokenProvider() else { return "Not signed in" }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let ws = session.webSocketTask(with: req)
        task = ws
        ws.resume()

        var helloFrame = Lush_V1_ClientFrame()
        helloFrame.hello = hello
        guard await send(helloFrame) else { return "Can't reach the server" }

        lastFrameAt = Date()
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.checkQuiet(ws)
            }
        }
        defer { watchdog.cancel() }

        var bye: Lush_V1_Bye?
        do {
            while !Task.isCancelled {
                let msg = try await ws.receive()
                guard case .data(let data) = msg,
                      let frame = try? Lush_V1_ServerFrame(serializedBytes: data) else { continue }
                lastFrameAt = Date()
                switch frame.body {
                case .welcome(let w):
                    attempt = 0
                    continuation.yield(.connected(w))
                    scheduleReauth(expiresAtMs: w.tokenExpiresAt)
                case .bye(let b):
                    bye = b
                default:
                    break
                }
                continuation.yield(.frame(frame))
            }
            return "Stopped"
        } catch {
            if let bye { return Self.describe(bye) }
            return "Connection lost"
        }
    }

    private func checkQuiet(_ ws: URLSessionWebSocketTask) {
        guard ws === task, Date().timeIntervalSince(lastFrameAt) > Self.quietLimit else { return }
        ws.cancel(with: .goingAway, reason: nil) // receive() throws; run() reconnects
    }

    /// Send a fresh token ~90 s before the current one expires. The server answers
    /// with a new Welcome, which schedules the next one.
    private func scheduleReauth(expiresAtMs: Int64) {
        reauthTask?.cancel()
        guard expiresAtMs > 0 else { return }
        let fireIn = max(15, Double(expiresAtMs) / 1000 - Date().timeIntervalSince1970 - 90)
        reauthTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(fireIn))
            guard !Task.isCancelled, let self else { return }
            await self.reauth()
        }
    }

    private func reauth() async {
        guard let token = await tokenProvider() else { return }
        var f = Lush_V1_ClientFrame()
        f.reauth = .with { $0.accessToken = token }
        await send(f)
    }

    static func describe(_ bye: Lush_V1_Bye) -> String {
        switch bye.code {
        case "replaced": "Connected on another device"
        case "token_expired": "Session expired"
        case "slow_consumer": "Connection too slow"
        default: bye.message.isEmpty ? bye.code : bye.message
        }
    }
}
