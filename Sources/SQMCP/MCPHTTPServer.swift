import Foundation
import Logging
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

/// One MCP endpoint per saved connection, `http://127.0.0.1:<port>/mcp/<connection id>`, each with its own
/// bearer token, so a client set up for one connection can't reach another.
///
/// One MCP `Server` + `StatefulHTTPServerTransport` per client session, keyed by `Mcp-Session-Id`.
/// Adapted from the swift-sdk's conformance server (`MCPConformance/Server/HTTPApp.swift`).
public actor MCPHTTPServer {
    /// Builds the MCP server for one connection.
    public typealias ServerFactory = @Sendable (UUID) async -> Server
    /// The token for a connection, or `nil` when it isn't available to AI clients.
    public typealias TokenLookup = @Sendable (UUID) async -> String?

    public static let pathPrefix = "/mcp/"

    public static func path(for connection: UUID) -> String {
        pathPrefix + connection.uuidString.lowercased()
    }

    private let port: Int
    private let token: TokenLookup
    private let makeServer: ServerFactory
    private var channel: Channel?
    private var group: MultiThreadedEventLoopGroup?
    private var sessions: [String: Session] = [:]
    private var cleanup: Task<Void, Never>?

    private struct Session {
        let connection: UUID
        let server: Server
        let transport: StatefulHTTPServerTransport
        var lastUsed: Date
    }

    public init(port: Int, token: @escaping TokenLookup, makeServer: @escaping ServerFactory) {
        self.port = port
        self.token = token
        self.makeServer = makeServer
    }

    /// Binds to 127.0.0.1 only, so nothing outside this Mac can reach it. Throws if the port is taken.
    public func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(server: self))
                }
            }
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
        do {
            channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        self.group = group
        cleanup = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.closeIdleSessions()
            }
        }
    }

    public func stop() async {
        cleanup?.cancel()
        for session in sessions.values { await session.transport.disconnect() }
        sessions.removeAll()
        try? await channel?.close()
        try? await group?.shutdownGracefully()
        channel = nil
        group = nil
    }

    // MARK: Routing

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard let path = request.path, path.hasPrefix(Self.pathPrefix),
              let connection = UUID(uuidString: String(path.dropFirst(Self.pathPrefix.count)))
        else {
            return .error(statusCode: 404, .invalidRequest("Not Found: use the URL from Query Pro, /mcp/<connection id>"))
        }
        guard let expected = await token(connection), Self.matches(request.header("Authorization"), "Bearer \(expected)") else {
            return .error(statusCode: 401, .invalidRequest("Unauthorized: missing or wrong bearer token for this connection"))
        }

        // A session only ever serves the connection it was opened for.
        if let id = request.header(HTTPHeaderName.sessionID), var session = sessions[id], session.connection == connection {
            session.lastUsed = Date()
            sessions[id] = session
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE", response.statusCode == 200 {
                sessions.removeValue(forKey: id)
            }
            return response
        }

        if request.method.uppercased() == "POST", let body = request.body, Self.isInitialize(body) {
            return await startSession(with: request, connection: connection)
        }
        if request.header(HTTPHeaderName.sessionID) != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: session expired, reconnect"))
        }
        return .error(statusCode: 400, .invalidRequest("Bad Request: missing \(HTTPHeaderName.sessionID) header"))
    }

    /// Constant-time compare, so a token can't be guessed byte by byte from response timing.
    static func matches(_ header: String?, _ expected: String) -> Bool {
        guard let header else { return false }
        let a = Array(header.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func startSession(with request: HTTPRequest, connection: UUID) async -> HTTPResponse {
        let id = UUID().uuidString
        let transport = StatefulHTTPServerTransport(sessionIDGenerator: FixedSessionID(id: id))
        let server = await makeServer(connection)
        do {
            try await server.start(transport: transport)
        } catch {
            await transport.disconnect()
            return .error(statusCode: 500, .internalError("Couldn't start the MCP session: \(error.localizedDescription)"))
        }
        sessions[id] = Session(connection: connection, server: server, transport: transport, lastUsed: Date())
        let response = await transport.handleRequest(request)
        if case .error = response {
            sessions.removeValue(forKey: id)
            await transport.disconnect()
        }
        return response
    }

    private func closeIdleSessions() async {
        let cutoff = Date().addingTimeInterval(-3600)
        for (id, session) in sessions where session.lastUsed < cutoff {
            sessions.removeValue(forKey: id)
            await session.transport.disconnect()
        }
    }

    /// The SDK's own check for this is package-internal, so look at the JSON-RPC method directly.
    static func isInitialize(_ body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return object["method"] as? String == "initialize"
    }

    private struct FixedSessionID: SessionIDGenerator {
        let id: String
        func generateSessionID() -> String { id }
    }
}

/// Converts between NIO HTTP parts and the SDK's framework-neutral `HTTPRequest` / `HTTPResponse`.
private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let server: MCPHTTPServer
    private var head: HTTPRequestHead?
    private var body: ByteBuffer?

    init(server: MCPHTTPServer) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = context.channel.allocator.buffer(capacity: 0)
        case .body(var chunk):
            body?.writeBuffer(&chunk)
        case .end:
            guard let head else { return }
            let body = self.body
            self.head = nil
            self.body = nil
            nonisolated(unsafe) let context = context
            Task {
                let response = await self.respond(head: head, body: body)
                await self.write(response, version: head.version, context: context)
            }
        }
    }

    private func respond(head: HTTPRequestHead, body: ByteBuffer?) async -> HTTPResponse {
        let path = String(head.uri.split(separator: "?").first ?? Substring(head.uri))
        var headers: [String: String] = [:]
        for (name, value) in head.headers {
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        let data = body.flatMap { $0.readableBytes > 0 ? Data($0.readableBytesView) : nil }
        return await server.handle(HTTPRequest(method: head.method.rawValue, headers: headers, body: data, path: path))
    }

    private func write(_ response: HTTPResponse, version: HTTPVersion, context: ChannelHandlerContext) async {
        nonisolated(unsafe) let context = context
        let eventLoop = context.eventLoop
        var responseHead = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: response.statusCode))
        for (name, value) in response.headers { responseHead.headers.add(name: name, value: value) }
        let head = responseHead

        switch response {
        case .stream(let stream, _):
            eventLoop.execute {
                context.writeAndFlush(self.wrapOutboundOut(.head(head)), promise: nil)
            }
            do {
                for try await chunk in stream {
                    eventLoop.execute {
                        var buffer = context.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            } catch {
                // The stream ended with an error; just close it.
            }
            eventLoop.execute {
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        default:
            let body = response.bodyData
            eventLoop.execute {
                context.write(self.wrapOutboundOut(.head(head)), promise: nil)
                if let body {
                    var buffer = context.channel.allocator.buffer(capacity: body.count)
                    buffer.writeBytes(body)
                    context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}
