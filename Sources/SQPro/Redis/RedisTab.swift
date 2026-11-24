import AppKit
import Foundation
import Observation
import SQCore

/// One open Redis connection: the key browser and the console.
///
/// Like `ConnectionTab` it keeps two sessions: the browser's (SCAN, values, edits) and the console's, so a slow or
/// blocking console command never freezes the key list, and the console's `SELECT` doesn't move the browser.
@Observable
final class RedisTab: @MainActor WorkspaceTab {
    enum State {
        case connecting
        case connected
        case failed(String)
    }

    let id = UUID()
    let profile: ConnectionProfile
    private(set) var state = State.connecting
    private(set) var serverVersion = ""
    /// Set when the server rejected the password, so the view can ask for it.
    var needsPassword = false

    // MARK: Browser state

    /// The database the key list shows.
    private(set) var database: Int
    /// Key counts per database from `INFO keyspace`.
    private(set) var keyCounts: [Int: Int] = [:]
    /// From `CONFIG GET databases`; managed services often hide CONFIG, so 16 (Redis's default) until known.
    private(set) var databaseCount = 16
    /// Text in the filter box. Plain text matches anywhere in the name; `*`, `?` or `[` make it a glob.
    var filter = ""
    /// `nil` = all types.
    var typeFilter: String?
    private(set) var keys: [RedisKey] = []
    private(set) var tree: [RedisKeyNode] = []
    /// "0" once the scan has walked the whole keyspace.
    private(set) var cursor = "0"
    private(set) var isScanning = false
    private(set) var scanError: String?
    var selectedNodeID: String?

    /// The selected key's value.
    private(set) var detail: KeyDetail?
    var showsNewKey = false

    struct KeyDetail {
        var key: RedisKey
        var loaded: RedisLoadedValue?
        var isLoading = false
        var error: String?
        /// Set after a write failed, shown above the value.
        var writeError: String?
    }

    // MARK: Console state

    struct ConsoleEntry: Identifiable {
        let id = UUID()
        let prompt: String
        let command: String
        var reply: String
        var isError: Bool
        var duration: Duration?
    }

    private(set) var console: [ConsoleEntry] = []
    var consoleInput = ""
    private(set) var isRunningCommand = false
    private(set) var consoleDatabase: Int
    /// Newest last; ↑ in the input walks back through it.
    @ObservationIgnored private(set) var commandHistory: [String] = []
    var showsConsole = true

    enum BottomPanel {
        case console, aiActivity
    }

    var bottomPanel = BottomPanel.console

    @ObservationIgnored private var browserSession: RedisSession?
    @ObservationIgnored private var consoleSession: RedisSession?
    @ObservationIgnored private var password: String?
    @ObservationIgnored private var stoppedCommand = false
    @ObservationIgnored private var majorVersion = 0

    /// Keys loaded per scan step before waiting for "Load More".
    static let pageSize = 1000

    init(profile: ConnectionProfile) {
        self.profile = profile
        database = profile.redisDatabase
        consoleDatabase = profile.redisDatabase
    }

    var title: String { groupedTitle }

    var selectedKey: RedisKey? {
        guard let id = selectedNodeID, id.hasPrefix("k:") else { return nil }
        return keys.first { "k:" + $0.displayName == id }
    }

    /// `host:port[db]>`, like redis-cli.
    var prompt: String {
        consoleDatabase == 0 ? "\(profile.address)>" : "\(profile.address)[\(consoleDatabase)]>"
    }

    // MARK: Connecting

    func connect() async {
        await connect(password: await Keychain.password(for: profile.id))
    }

    func connect(password: String?) async {
        state = .connecting
        needsPassword = false
        self.password = password
        await disconnect()
        let browser = RedisSession(profile: profile, password: password)
        let console = RedisSession(profile: profile, password: password)
        browserSession = browser
        consoleSession = console
        do {
            try await browser.connect()
            try await console.connect()
            let info = try await browser.call("INFO", "server").string ?? ""
            serverVersion = RedisBrowser.infoField("redis_version", in: info)
                ?? RedisBrowser.infoField("valkey_version", in: info) ?? ""
            majorVersion = Int(serverVersion.split(separator: ".").first ?? "") ?? 0
            if let count = try? await browser.call("CONFIG", "GET", "databases").array?.last?.int, count > 0 {
                databaseCount = Int(count)
            }
            state = .connected
            await refreshKeyCounts()
            await reload()
        } catch {
            state = .failed(ErrorText.message(for: error))
            needsPassword = (error as? RedisError)?.isAccessDenied == true
        }
    }

    func disconnect() async {
        await browserSession?.close()
        await consoleSession?.close()
        browserSession = nil
        consoleSession = nil
    }

    // MARK: Keys

    /// The SCAN pattern for the filter box.
    var pattern: String {
        let text = filter.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return "*" }
        if text.contains(where: { "*?[".contains($0) }) { return text }
        let escaped = text.reduce(into: "") { result, character in
            if "\\*?[]".contains(character) { result.append("\\") }
            result.append(character)
        }
        return "*\(escaped)*"
    }

    /// Starts the key list again from the beginning, keeping the selection if that key is still there.
    func reload() async {
        keys = []
        tree = []
        cursor = "0"
        await loadMore(fromStart: true)
        if let key = detail?.key, keys.contains(where: { $0.name == key.name }) {
            await loadValue(of: key)
        } else if detail != nil, selectedKey == nil {
            detail = nil
        }
    }

    /// Scans until another page of keys has arrived or the keyspace is done.
    func loadMore(fromStart: Bool = false) async {
        guard let session = browserSession, !isScanning, fromStart || cursor != "0" else { return }
        isScanning = true
        scanError = nil
        defer { isScanning = false }
        var seen = Set(keys.map(\.name))
        var next = cursor
        var found: [Data] = []
        do {
            repeat {
                let step = try await RedisBrowser.scan(session, cursor: next, pattern: pattern, type: typeFilter)
                next = step.cursor
                for name in step.keys where seen.insert(name).inserted { found.append(name) }
            } while next != "0" && found.count < Self.pageSize
            keys += try await RedisBrowser.describe(session, found)
            cursor = next
            tree = RedisKeyNode.tree(keys)
        } catch {
            scanError = ErrorText.message(for: error)
        }
    }

    var hasMore: Bool { cursor != "0" }

    func select(database number: Int) async {
        guard number != database, let session = browserSession else { return }
        do {
            _ = try await session.call("SELECT", String(number))
            database = number
            detail = nil
            selectedNodeID = nil
            await reload()
        } catch {
            scanError = ErrorText.message(for: error)
        }
    }

    func refreshKeyCounts() async {
        guard let info = try? await browserSession?.call("INFO", "keyspace").string else { return }
        keyCounts = RedisBrowser.keyspace(info)
    }

    // MARK: Values

    func selectionChanged() async {
        guard let key = selectedKey else { return }
        if detail?.key.name == key.name, detail?.loaded != nil { return }
        await loadValue(of: key)
    }

    func loadValue(of key: RedisKey) async {
        guard let session = browserSession else { return }
        detail = KeyDetail(key: key, loaded: detail?.key.name == key.name ? detail?.loaded : nil, isLoading: true)
        do {
            // Type and TTL may have changed since the scan.
            guard let fresh = try await RedisBrowser.describe(session, [key.name]).first else {
                detail = KeyDetail(key: key, error: "This key no longer exists.")
                return
            }
            let loaded = try await RedisBrowser.load(session, key: fresh.name, type: fresh.type)
            guard detail?.key.name == key.name else { return }
            detail = KeyDetail(key: fresh, loaded: loaded)
            replaceKey(fresh)
        } catch {
            detail = KeyDetail(key: key, error: ErrorText.message(for: error))
        }
    }

    private func replaceKey(_ key: RedisKey) {
        guard let index = keys.firstIndex(where: { $0.name == key.name }), keys[index] != key else { return }
        keys[index] = key
        tree = RedisKeyNode.tree(keys)
    }

    // MARK: Writes

    /// Runs commands from the browser against the selected key, then reloads it. Production connections ask first.
    /// Returns `false` when cancelled or failed.
    @discardableResult
    func write(_ commands: [[Data]], describing summary: String? = nil) async -> Bool {
        guard let session = browserSession, !commands.isEmpty else { return false }
        if profile.color.isProduction {
            let text = summary ?? commands.map { $0.map(RedisCommand.quote).joined(separator: " ") }.joined(separator: "\n")
            guard Self.confirm("Change \(profile.name)?", detail: "\(profile.name) is marked as production.\n\n\(text)", action: "Run") else {
                return false
            }
        }
        do {
            let replies = try await session.sendAll(commands)
            if let error = replies.first(where: \.isError), case .error(let message) = error {
                detail?.writeError = message
                return false
            }
            detail?.writeError = nil
            return true
        } catch {
            detail?.writeError = ErrorText.message(for: error)
            return false
        }
    }

    /// Writes, then reloads the key that was changed.
    func edit(_ key: RedisKey, _ commands: [[Data]]) async {
        if await write(commands) { await loadValue(of: key) }
    }

    func setString(_ key: RedisKey, to value: Data) async {
        // KEEPTTL arrived in Redis 6; before it, SET would drop the expiry.
        var command = [Self.word("SET"), key.name, value]
        if majorVersion >= 6 {
            command.append(Self.word("KEEPTTL"))
        } else if let ttl = key.ttl {
            command += [Self.word("PX"), Self.word(String(ttl))]
        }
        await edit(key, [command])
    }

    /// Removes one list element by index: LSET marks it with a value nobody uses, LREM removes that mark.
    func removeListItem(_ key: RedisKey, at index: Int) async {
        let mark = Self.word("__query_pro_deleted_\(UUID().uuidString)__")
        await edit(key, [[Self.word("LSET"), key.name, Self.word(String(index)), mark], [Self.word("LREM"), key.name, Self.word("1"), mark]])
    }

    /// `seconds` nil removes the expiry.
    func setTTL(_ key: RedisKey, seconds: Int?) async {
        let command = seconds.map { [Self.word("EXPIRE"), key.name, Self.word(String($0))] } ?? [Self.word("PERSIST"), key.name]
        await edit(key, [command])
    }

    func delete(_ key: RedisKey) async {
        guard Self.confirm("Delete \(key.displayName)?", detail: "The key and its value are removed from db\(database).", action: "Delete") else { return }
        // UNLINK frees memory in the background; the confirmation above covers production too.
        guard let session = browserSession else { return }
        do {
            var reply = try await session.send([Self.word("UNLINK"), key.name])
            if case .error = reply { reply = try await session.send([Self.word("DEL"), key.name]) }
            if case .error(let message) = reply {
                detail?.writeError = message
                return
            }
            keys.removeAll { $0.name == key.name }
            tree = RedisKeyNode.tree(keys)
            detail = nil
            selectedNodeID = nil
            await refreshKeyCounts()
        } catch {
            detail?.writeError = ErrorText.message(for: error)
        }
    }

    /// RENAMENX, so an existing key is never overwritten.
    func rename(_ key: RedisKey, to newName: String) async -> String? {
        let target = Data(newName.utf8)
        guard !newName.isEmpty, target != key.name, let session = browserSession else { return nil }
        if profile.color.isProduction,
           !Self.confirm("Rename \(key.displayName)?", detail: "\(profile.name) is marked as production.\n\nRENAMENX → \(newName)", action: "Rename") {
            return nil
        }
        do {
            let reply = try await session.send([Self.word("RENAMENX"), key.name, target])
            if case .error(let message) = reply { return message }
            if reply.int == 0 { return "A key named \(newName) already exists." }
            let renamed = RedisKey(name: target, type: key.type, ttl: key.ttl)
            keys.removeAll { $0.name == key.name }
            keys.append(renamed)
            tree = RedisKeyNode.tree(keys)
            selectedNodeID = "k:" + renamed.displayName
            await loadValue(of: renamed)
            return nil
        } catch {
            return ErrorText.message(for: error)
        }
    }

    /// Creates a key of the given type with its first element. Fails if the name is taken.
    func createKey(name: String, type: String, first: Data, second: Data, ttl: Int?) async -> String? {
        let key = Data(name.utf8)
        guard let session = browserSession else { return "Not connected." }
        do {
            if try await session.call([Self.word("EXISTS"), key]).int != 0 { return "A key named \(name) already exists." }
        } catch {
            return ErrorText.message(for: error)
        }
        let command: [Data] = switch type {
        case "hash": [Self.word("HSET"), key, first, second]
        case "list": [Self.word("RPUSH"), key, first]
        case "set": [Self.word("SADD"), key, first]
        case "zset": [Self.word("ZADD"), key, second.isEmpty ? Self.word("0") : second, first]
        case "stream": [Self.word("XADD"), key, Self.word("*"), first, second]
        default: [Self.word("SET"), key, first, Self.word("NX")]
        }
        var commands = [command]
        if let ttl, ttl > 0 { commands.append([Self.word("EXPIRE"), key, Self.word(String(ttl))]) }
        guard await write(commands) else { return detail?.writeError ?? "Cancelled." }
        let created = RedisKey(name: key, type: type, ttl: ttl.map { Int64($0) * 1000 })
        keys.append(created)
        tree = RedisKeyNode.tree(keys)
        selectedNodeID = "k:" + created.displayName
        await loadValue(of: created)
        await refreshKeyCounts()
        return nil
    }

    static func word(_ text: String) -> Data { Data(text.utf8) }

    /// Cancel is the default button, so a stray Return can't run it.
    static func confirm(_ message: String, detail: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Cancel")
        let run = alert.addButton(withTitle: action)
        run.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: Console

    /// Runs the input line in the console session.
    func runConsole() async {
        let line = consoleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !isRunningCommand, let session = consoleSession else { return }
        consoleInput = ""
        if commandHistory.last != line { commandHistory.append(line) }
        let prompt = self.prompt
        if ["clear", "cls"].contains(line.lowercased()) {
            console.removeAll()
            return
        }
        let arguments: [Data]
        do {
            arguments = try RedisCommand.parse(line)
        } catch {
            console.append(ConsoleEntry(prompt: prompt, command: line, reply: "(error) \(error.localizedDescription)", isError: true))
            return
        }
        let words = arguments.map { String(decoding: $0, as: UTF8.self) }
        let name = words.first?.uppercased() ?? ""
        if ["SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "MONITOR"].contains(name) {
            console.append(ConsoleEntry(
                prompt: prompt, command: line,
                reply: "(error) \(name) streams messages forever; use redis-cli for it. The console runs one command at a time.",
                isError: true
            ))
            return
        }
        if profile.color.isProduction, RedisCommand.needsConfirmation(words),
           !Self.confirm("Run \(name) on \(profile.name)?", detail: "\(profile.name) is marked as production.\n\n\(line)", action: "Run") {
            return
        }
        var entry = ConsoleEntry(prompt: prompt, command: line, reply: "", isError: false)
        console.append(entry)
        isRunningCommand = true
        stoppedCommand = false
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let reply = try await session.send(arguments)
            entry.reply = RedisCommand.format(reply)
            entry.isError = reply.isError
            if await session.takeReconnectNotice() { entry.reply = "(reconnected)\n" + entry.reply }
        } catch {
            entry.reply = stoppedCommand ? "(stopped)" : "(error) \(ErrorText.message(for: error))"
            entry.isError = !stoppedCommand
        }
        entry.duration = clock.now - start
        isRunningCommand = false
        consoleDatabase = await session.database
        if let index = console.firstIndex(where: { $0.id == entry.id }) { console[index] = entry }
        // Writes typed in the console show up in the browser.
        if ["SELECT"].contains(name) == false, RedisCommand.access(words) != .read {
            await refreshKeyCounts()
            if let key = detail?.key, words.dropFirst().contains(key.displayName) { await loadValue(of: key) }
        }
    }

    /// Stops a command that's waiting (BLPOP, a slow script): closes the console connection; the next command opens
    /// a new one in the same database.
    func stopConsoleCommand() async {
        guard isRunningCommand, let session = consoleSession else { return }
        stoppedCommand = true
        await session.close()
        // The session remembers its database, so the new connection SELECTs it again.
        try? await session.connect()
    }

    func clearConsole() {
        console.removeAll()
    }
}
