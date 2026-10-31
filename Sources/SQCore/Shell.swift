import Foundation

struct ShellResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

/// Runs a command-line tool off the main thread with a hard deadline, so a tool waiting
/// on a prompt (e.g. `security` on a Keychain "allow access" dialog) can't hang the app.
enum Shell {
    /// Writing to a child that already exited raises SIGPIPE, which would kill the app.
    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// `nil` when the tool can't be launched or runs past `timeout`.
    static func run(_ executable: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval = 10) async -> ShellResult? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, args, stdin: stdin, timeout: timeout))
            }
        }
    }

    private static func runBlocking(_ executable: String, _ args: [String], stdin: Data?, timeout: TimeInterval) -> ShellResult? {
        _ = ignoreSigpipe
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let input = stdin.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let pid = process.processIdentifier
        let timedOut = TimeoutFlag()
        let killer = DispatchWorkItem {
            timedOut.set()
            kill(pid, SIGKILL)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        if let input, let stdin {
            try? input.fileHandleForWriting.write(contentsOf: stdin)
            try? input.fileHandleForWriting.close()
        }
        // Drain stderr on another thread so neither pipe can fill up and block the tool.
        let errorData = DataBox()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            errorData.value = errors.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        drained.wait()
        killer.cancel()
        if timedOut.isSet { return nil }
        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: data, as: UTF8.self),
            stderr: String(decoding: errorData.value, as: UTF8.self)
        )
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var value: Data {
        get { lock.withLock { data } }
        set { lock.withLock { data = newValue } }
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
