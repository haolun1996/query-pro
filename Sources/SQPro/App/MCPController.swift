import AppKit
import Foundation
import Observation
import SQCore
import SQMCP

/// Runs the MCP server according to Settings and keeps the activity log.
@Observable
final class MCPController {
    enum Status: Equatable {
        case stopped
        case running(port: Int)
        case failed(String)
    }

    static let defaultPort = 7531
    private static let maxActivity = 500

    private(set) var status = Status.stopped
    /// Newest first.
    private(set) var activity: [MCPActivity] = []

    private let connections: ConnectionsModel
    private var server: MCPHTTPServer?
    private let defaults = UserDefaults.standard

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: SettingsKey.mcpEnabled)
            Task { isEnabled ? await start() : await stop() }
        }
    }

    var port: Int {
        didSet {
            guard port != oldValue else { return }
            defaults.set(port, forKey: SettingsKey.mcpPort)
            if isEnabled { Task { await restart() } }
        }
    }

    /// One token per connection id. Anyone with a token can use that connection's tools, so they are never logged.
    private var tokens: [String: String]

    /// The connection the activity window is filtered to; `nil` shows all.
    var activityFilter: UUID?

    init(connections: ConnectionsModel) {
        self.connections = connections
        isEnabled = defaults.bool(forKey: SettingsKey.mcpEnabled)
        port = defaults.object(forKey: SettingsKey.mcpPort) as? Int ?? Self.defaultPort
        tokens = defaults.dictionary(forKey: SettingsKey.mcpTokens) as? [String: String] ?? [:]
        if isEnabled { Task { await start() } }
    }

    // MARK: Per connection

    func url(for profile: ConnectionProfile) -> String {
        "http://127.0.0.1:\(port)\(MCPHTTPServer.path(for: profile.id))"
    }

    /// Created the first time it's needed.
    func token(for profile: ConnectionProfile) -> String {
        if let token = tokens[profile.id.uuidString] { return token }
        let token = Self.makeToken()
        tokens[profile.id.uuidString] = token
        defaults.set(tokens, forKey: SettingsKey.mcpTokens)
        return token
    }

    /// The old token stops working right away; projects using it need the new command.
    func regenerateToken(for profile: ConnectionProfile) {
        tokens[profile.id.uuidString] = Self.makeToken()
        defaults.set(tokens, forKey: SettingsKey.mcpTokens)
    }

    /// The MCP server name in Claude Code, e.g. `querywell-local-pos`.
    func serverName(for profile: ConnectionProfile) -> String {
        let slug = profile.name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return "querywell-" + (slug.isEmpty ? String(profile.id.uuidString.prefix(8)).lowercased() : slug)
    }

    /// Run inside a project folder: Claude Code's default "local" scope adds it to that project only.
    func claudeCodeCommand(for profile: ConnectionProfile) -> String {
        "claude mcp add --transport http \(serverName(for: profile)) \(url(for: profile)) --header \"Authorization: Bearer \(token(for: profile))\""
    }

    func activity(for connection: UUID?) -> [MCPActivity] {
        guard let connection else { return activity }
        return activity.filter { $0.connectionID == connection }
    }

    // MARK: Running

    func start() async {
        guard server == nil else { return }
        let provider = AppMCPProvider(controller: self)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let server = MCPHTTPServer(port: port) { connection in
            await provider.token(for: connection)
        } makeServer: { connection in
            await SQLTools(provider: provider, connection: connection).makeServer(version: version)
        }
        do {
            try await server.start()
            self.server = server
            status = .running(port: port)
        } catch {
            status = .failed("Couldn't listen on port \(port): \(error.localizedDescription). Try another port.")
        }
    }

    func stop() async {
        await server?.stop()
        server = nil
        status = .stopped
    }

    private func restart() async {
        await stop()
        await start()
    }

    func clearActivity() {
        activity.removeAll()
    }

    // MARK: Provider callbacks

    fileprivate func currentProfiles() -> [ConnectionProfile] {
        connections.profiles
    }

    /// Only connections open to AI have a usable token.
    fileprivate func currentToken(for connection: UUID) -> String? {
        guard let profile = connections.profile(id: connection), profile.mcpAccess != .hidden else { return nil }
        return tokens[connection.uuidString]
    }

    fileprivate func record(_ entry: MCPActivity) {
        activity.insert(entry, at: 0)
        if activity.count > Self.maxActivity { activity.removeLast(activity.count - Self.maxActivity) }
    }

    /// Brings Querywell forward and asks. Deny is the default button, so a stray Return can't approve.
    fileprivate func askToApprove(_ sql: String, on profile: ConnectionProfile) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "An AI client wants to change \(profile.name)"
        alert.informativeText = "\(profile.name) is marked as production.\n\n\(sql)"
        alert.addButton(withTitle: "Deny")
        let allow = alert.addButton(withTitle: "Allow")
        allow.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}

/// Bridges the MCP tools (any thread) to the app (main actor).
private nonisolated struct AppMCPProvider: MCPProvider {
    let controller: MCPController

    func profiles() async -> [ConnectionProfile] {
        await controller.currentProfiles()
    }

    func token(for connection: UUID) async -> String? {
        await controller.currentToken(for: connection)
    }

    func password(for profile: ConnectionProfile) async -> String? {
        await Keychain.password(for: profile.id, kind: profile.usesSeparateMCPUser ? .mcp : .connection)
    }

    func approveWrite(_ sql: String, on profile: ConnectionProfile) async -> Bool {
        await controller.askToApprove(sql, on: profile)
    }

    func record(_ activity: MCPActivity) async {
        await controller.record(activity)
    }
}
