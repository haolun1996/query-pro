import Foundation
import NIOCore
import NIOPosix
import NIOSSL

public enum RedisError: Error, LocalizedError, Equatable {
    case notConnected
    /// An error reply, e.g. `WRONGTYPE …` or `NOAUTH …`.
    case server(String)
    /// The connection dropped while a command was running; it was not run again.
    case lostDuringCommand
    case connectTimedOut
    /// The server hung up during TLS or login, which is what a TLS mismatch looks like.
    case closedDuringLogin(usesTLS: Bool, detail: String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the server."
        case .server(let message): message
        case .lostDuringCommand:
            "The connection to the server was lost while this command was running. Query Pro has reconnected; check whether it took effect before running it again."
        case .connectTimedOut:
            "The server accepted the connection but didn't finish logging in. Check the port, and whether this server needs TLS."
        case .closedDuringLogin(let usesTLS, let detail):
            usesTLS
                ? "The TLS handshake failed (\(detail)). If this server doesn't use TLS, turn TLS off for this connection."
                : "The server closed the connection while logging in (\(detail)). If it uses TLS, as most cloud Redis services do, turn TLS on for this connection."
        }
    }

    /// Wrong password or user, or a password is needed: the app asks for it again.
    public var isAccessDenied: Bool {
        guard case .server(let message) = self else { return false }
        return message.hasPrefix("WRONGPASS") || message.hasPrefix("NOAUTH")
            || message.contains("invalid password") || message.contains("invalid username-password")
    }
}

/// One live connection to a Redis server. Commands are pipelined in order on one socket.
///
/// Like `MySQLSession`, it reconnects by itself: after a quiet spell it pings first (cloud servers and NAT drop idle
/// connections silently), and a closed connection is reopened before the next command, logging in and selecting the
/// same database again. A command that was on the wire when the connection dropped is reported, never re-sent.
public actor RedisSession {
    public let profile: ConnectionProfile
    private let password: String?
    private var channel: (any Channel)?
    /// The database commands run in; follows `SELECT` sent through `send`.
    public private(set) var database: Int
    private var lastUsed = ContinuousClock.now
    private var reconnected = false
    private let idleCheck: Duration
    private let connectTimeout: Duration

    public init(profile: ConnectionProfile, password: String?, idleCheck: Duration = .seconds(30), connectTimeout: Duration = .seconds(15)) {
        self.profile = profile
        self.password = password?.isEmpty == true ? nil : password
        self.idleCheck = idleCheck
        self.connectTimeout = connectTimeout
        self.database = profile.redisDatabase
    }

    public func connect() async throws {
        if let channel, channel.isActive { return }
        try await open()
    }

    /// A command still waiting fails, and isn't followed by a reconnect: `connect` opens a new connection when wanted.
    public func close() async {
        let closing = channel
        channel = nil
        if let closing { try? await closing.close() }
    }

    /// `true` once after the session had to reconnect, so the app can say so.
    public func takeReconnectNotice() -> Bool {
        defer { reconnected = false }
        return reconnected
    }

    /// Sends one command and returns the reply, error replies included (the console shows them as they are).
    public func send(_ arguments: [Data]) async throws -> RESPValue {
        try await sendAll([arguments])[0]
    }

    public func send(_ arguments: String...) async throws -> RESPValue {
        try await send(arguments.map { Data($0.utf8) })
    }

    /// Like `send`, but an error reply throws `RedisError.server`.
    public func call(_ arguments: [Data]) async throws -> RESPValue {
        let reply = try await send(arguments)
        if case .error(let message) = reply { throw RedisError.server(message) }
        return reply
    }

    public func call(_ arguments: String...) async throws -> RESPValue {
        try await call(arguments.map { Data($0.utf8) })
    }

    /// Sends every command before reading any reply: one round trip for, say, TYPE of 500 keys.
    public func sendAll(_ commands: [[Data]]) async throws -> [RESPValue] {
        guard channel != nil else { throw RedisError.notConnected }
        try await reviveIfNeeded()
        guard let channel else { throw RedisError.notConnected }
        lastUsed = .now
        let replies: [RESPValue]
        do {
            replies = try await Self.write(commands, on: channel)
        } catch let error as RedisError {
            throw error
        } catch {
            guard !channel.isActive else { throw error }
            // Closed on purpose (`close`, a stop button), or another call already reconnected.
            guard self.channel === channel else { throw RedisError.lostDuringCommand }
            try? await reconnect()
            throw RedisError.lostDuringCommand
        }
        for (command, reply) in zip(commands, replies) {
            if !reply.isError, let name = command.first.map({ String(decoding: $0, as: UTF8.self).uppercased() }),
               name == "SELECT", command.count == 2, let number = Int(String(decoding: command[1], as: UTF8.self)) {
                database = number
            }
        }
        return replies
    }

    // MARK: Connection

    private func open() async throws {
        let channel = try await Self.connectChannel(profile: profile, timeout: connectTimeout)
        do {
            try await Self.withDeadline(connectTimeout, closing: channel) { [profile, password, database] in
                var login: [[Data]] = []
                if let password {
                    let user = profile.user.trimmingCharacters(in: .whitespaces)
                    login.append(user.isEmpty ? ["AUTH", password].map(Self.data) : ["AUTH", user, password].map(Self.data))
                }
                if database != 0 { login.append(["SELECT", String(database)].map(Self.data)) }
                login.append(["CLIENT", "SETNAME", "QueryPro"].map(Self.data))
                let replies = try await Self.write(login, on: channel)
                // SETNAME may be denied by ACLs or renamed on managed servers; only AUTH and SELECT matter.
                for reply in replies.dropLast() {
                    if case .error(let message) = reply { throw RedisError.server(message) }
                }
            }
        } catch let error as RedisError {
            try? await channel.close()
            throw error
        } catch {
            try? await channel.close()
            throw RedisError.closedDuringLogin(usesTLS: profile.sslMode == .required, detail: "\(error)")
        }
        self.channel = channel
        lastUsed = .now
    }

    private func reconnect() async throws {
        let closing = channel
        channel = nil
        if let closing { try? await closing.close() }
        try await open()
        reconnected = true
    }

    private func reviveIfNeeded() async throws {
        guard let channel else { return }
        var alive = channel.isActive
        if alive, ContinuousClock.now - lastUsed > idleCheck {
            alive = (try? await Self.withDeadline(.seconds(5), closing: channel) {
                try await Self.write([[Self.data("PING")]], on: channel)
            }) != nil
        }
        if !alive { try await reconnect() }
    }

    private static func data(_ text: String) -> Data { Data(text.utf8) }

    private static func write(_ commands: [[Data]], on channel: any Channel) async throws -> [RESPValue] {
        let promise = channel.eventLoop.makePromise(of: [RESPValue].self)
        var buffer = channel.allocator.buffer(capacity: 64)
        for command in commands { RESP.encode(command, into: &buffer) }
        channel.writeAndFlush(RedisRequest(buffer: buffer, count: commands.count, promise: promise), promise: nil)
        return try await promise.futureResult.get()
    }

    private static func connectChannel(profile: ConnectionProfile, timeout: Duration) async throws -> any Channel {
        let host = profile.host.trimmingCharacters(in: .whitespaces)
        var tls: NIOSSLContext?
        if profile.sslMode == .required {
            // Like MySQL's "use SSL if available": encrypted, but self-signed and private-CA certificates (Redis
            // Cloud, self-hosted) are accepted.
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.certificateVerification = .none
            tls = try NIOSSLContext(configuration: configuration)
        }
        // SNI needs a name; managed services route on it.
        let serverName = host.isEmpty || host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) ? nil : host
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.milliseconds(Int64(timeout / .milliseconds(1))))
            .channelOption(.socketOption(.so_keepalive), value: 1)
            .channelInitializer { [tls] channel in
                channel.eventLoop.makeCompletedFuture {
                    if let tls {
                        try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls, serverHostname: serverName))
                    }
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(RESPDecoder()))
                    try channel.pipeline.syncOperations.addHandler(RedisClientHandler())
                }
            }
        return try await bootstrap.connect(host: host.isEmpty ? "localhost" : host, port: profile.port).get()
    }

    /// Fails with `connectTimedOut` and closes the channel (which fails anything waiting on it) when `work` takes
    /// too long: a TLS port spoken to in plain text, or plain text to a TLS port, never answers.
    private static func withDeadline<T: Sendable>(
        _ timeout: Duration,
        closing channel: any Channel,
        _ work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                guard (try? await Task.sleep(for: timeout)) != nil else { return nil }
                try? await channel.close()
                throw RedisError.connectTimedOut
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let value = result { return value }
            }
            throw RedisError.connectTimedOut
        }
    }
}

// MARK: Channel handlers

struct RedisRequest {
    let buffer: ByteBuffer
    /// How many replies to collect for it.
    let count: Int
    let promise: EventLoopPromise<[RESPValue]>
}

struct RESPDecoder: ByteToMessageDecoder {
    typealias InboundOut = RESPValue

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let value = try RESP.parse(&buffer) else { return .needMoreData }
        context.fireChannelRead(Self.wrapInboundOut(value))
        return .continue
    }

    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }
}

/// Matches replies to requests in order: Redis answers commands in the order they were sent.
final class RedisClientHandler: ChannelDuplexHandler {
    typealias InboundIn = RESPValue
    typealias OutboundIn = RedisRequest
    typealias OutboundOut = ByteBuffer

    private struct Waiting {
        let promise: EventLoopPromise<[RESPValue]>
        var remaining: Int
        var replies: [RESPValue]
    }

    private var queue: [Waiting] = []

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let request = unwrapOutboundIn(data)
        queue.append(Waiting(promise: request.promise, remaining: request.count, replies: []))
        context.write(wrapOutboundOut(request.buffer)).whenFailure { error in
            request.promise.fail(error)
        }
        promise?.succeed()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let value = unwrapInboundIn(data)
        guard !queue.isEmpty else { return }  // Pushed messages we never asked for.
        queue[0].replies.append(value)
        queue[0].remaining -= 1
        if queue[0].remaining == 0 {
            let done = queue.removeFirst()
            done.promise.succeed(done.replies)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failAll(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(ChannelError.ioOnClosedChannel)
        context.fireChannelInactive()
    }

    private func failAll(_ error: any Error) {
        let waiting = queue
        queue.removeAll()
        for item in waiting { item.promise.fail(error) }
    }
}
