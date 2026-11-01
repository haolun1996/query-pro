import Foundation

/// Passwords per connection profile, keyed by the profile's id: the connection's own password, and
/// optionally the separate MySQL login used by AI clients (`kind: .mcp`).
///
/// Goes through `/usr/bin/security`, never Security.framework: the app is ad-hoc signed, so its
/// signature changes every build and framework access would prompt again after each one.
/// Items created by the `security` tool trust that tool, which never changes, so there are no prompts.
/// Passwords go in on stdin as hex (`security -i`, `-X`), never in argv where `ps` would show them.
public enum Keychain {
    static let tool = "/usr/bin/security"
    static let service = "app.sqpro.password"
    /// `security` exit status for "item not found".
    static let notFound: Int32 = 44

    public enum Kind: Sendable {
        /// The connection's own login.
        case connection
        /// The separate login AI clients use over MCP.
        case mcp
    }

    static func account(_ id: UUID, _ kind: Kind) -> String {
        switch kind {
        case .connection: id.uuidString
        case .mcp: id.uuidString + ".mcp"
        }
    }

    /// `nil` when there is no saved password, or the Keychain couldn't be read.
    public static func password(for id: UUID, kind: Kind = .connection) async -> String? {
        let args = ["find-generic-password", "-s", service, "-a", account(id, kind), "-g"]
        guard let result = await Shell.run(tool, args, timeout: 30), result.exitCode == 0 else { return nil }
        return decode(result.stderr)
    }

    /// Saves the password, or removes it when empty. Returns `false` if the Keychain refused.
    @discardableResult
    public static func setPassword(_ password: String?, for id: UUID, kind: Kind = .connection) async -> Bool {
        guard let password, !password.isEmpty else { return await deletePassword(for: id, kind: kind) }
        let hex = Data(password.utf8).map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -s \"\(service)\" -a \"\(account(id, kind))\" -X \(hex)\n"
        let result = await Shell.run(tool, ["-i"], stdin: Data(command.utf8), timeout: 30)
        return result?.exitCode == 0
    }

    /// Returns `true` when the password is gone afterwards, including "was never saved".
    @discardableResult
    public static func deletePassword(for id: UUID, kind: Kind = .connection) async -> Bool {
        let args = ["delete-generic-password", "-s", service, "-a", account(id, kind)]
        guard let result = await Shell.run(tool, args, timeout: 30) else { return false }
        return result.exitCode == 0 || result.exitCode == notFound
    }

    /// Reads the `password:` line that `-g` prints to stderr. It is either quoted text,
    /// `password: "secret"`, or hex when the password has non-ASCII bytes, `password: 0x6162C3BC  "ab\303\274"`.
    static func decode(_ output: String) -> String? {
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("password: ") }) else { return nil }
        let value = line.dropFirst("password: ".count)
        if value.hasPrefix("0x") {
            let hex = value.dropFirst(2).prefix { $0.isHexDigit }
            var bytes: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
                guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return "" }
        return String(value.dropFirst().dropLast())
    }
}
