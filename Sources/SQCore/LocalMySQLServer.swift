import Foundation

/// The MySQL server that Oracle's macOS installer puts on this Mac. It runs as a system LaunchDaemon
/// that stays off until started, so starting or stopping it needs an administrator: that goes through
/// `osascript … with administrator privileges`, the standard macOS password prompt.
public enum LocalMySQLServer {
    public static let label = "com.oracle.oss.mysql.mysqld"
    static let plist = "/Library/LaunchDaemons/\(label).plist"
    public static let errorLog = "/usr/local/mysql/data/mysqld.local.err"

    public enum Status: Sendable, Equatable {
        case notInstalled
        case stopped
        /// launchd runs mysqld but it doesn't accept connections yet (recovery, first start).
        case starting
        case running
    }

    public enum Failure: LocalizedError, Equatable {
        /// The user closed the password prompt.
        case cancelled
        case command(String)
        case didNotStart
        case didNotStop

        public var errorDescription: String? {
            switch self {
            case .cancelled: "Cancelled."
            case .command(let message): message
            case .didNotStart: "MySQL didn't start accepting connections. Its log is \(LocalMySQLServer.errorLog)."
            case .didNotStop: "MySQL is still running."
            }
        }
    }

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: plist) }

    public static func isLocal(host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", ""].contains(host.trimmingCharacters(in: .whitespaces).lowercased())
    }

    public static func status(port: Int = 3306) async -> Status {
        guard isInstalled else { return .notInstalled }
        // The port is the truth: mysqld may also have been started by hand, outside launchd.
        if acceptsConnections(port: port) { return .running }
        return await launchdRunsIt() ? .starting : .stopped
    }

    /// Asks for an administrator password, starts the daemon, and waits until it accepts connections.
    public static func start(port: Int = 3306) async throws(Failure) {
        // `enable` and `bootstrap` cover a daemon that was disabled or unloaded (e.g. by the MySQL
        // preference pane); bootstrap fails harmlessly when it's already loaded.
        try await runAsAdministrator(
            "/bin/launchctl enable system/\(label); /bin/launchctl bootstrap system \(plist) 2>/dev/null; /bin/launchctl kickstart system/\(label)"
        )
        // InnoDB recovery after an unclean shutdown can take a while.
        for _ in 0..<120 {
            if acceptsConnections(port: port) { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        throw .didNotStart
    }

    /// Asks for an administrator password and shuts mysqld down cleanly (SIGTERM). The daemon's
    /// KeepAlive only restarts it after a crash, so it stays stopped.
    public static func stop(port: Int = 3306) async throws(Failure) {
        try await runAsAdministrator("/bin/launchctl kill TERM system/\(label)")
        for _ in 0..<120 {
            if !acceptsConnections(port: port) { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        throw .didNotStop
    }

    /// `launchctl print` of a system daemon needs no root.
    private static func launchdRunsIt() async -> Bool {
        guard let result = await Shell.run("/bin/launchctl", ["print", "system/\(label)"]), result.exitCode == 0 else { return false }
        return result.stdout.contains("state = running")
    }

    private static func runAsAdministrator(_ command: String) async throws(Failure) {
        let script = "do shell script \"\(command)\" with administrator privileges"
        // Long timeout: the prompt waits for the user.
        guard let result = await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 300) else {
            throw .command("The administrator prompt timed out.")
        }
        guard result.exitCode != 0 else { return }
        // -128 is AppleScript's "User canceled".
        if result.stderr.contains("(-128)") { throw .cancelled }
        throw .command(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A plain TCP connect to 127.0.0.1: instant either way on loopback, and needs no credentials.
    static func acceptsConnections(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(clamping: port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
