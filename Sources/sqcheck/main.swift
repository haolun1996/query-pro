import Foundation
import SQCore

// Usage: sqcheck <host> <port> <user> [schema] [sql]
// The password is read from SQ_PASSWORD, or asked for interactively.
let args = CommandLine.arguments
guard args.count >= 4, let port = Int(args[2]) else {
    print("usage: sqcheck <host> <port> <user> [schema] [sql]")
    exit(2)
}
let password = ProcessInfo.processInfo.environment["SQ_PASSWORD"] ?? String(cString: getpass("Password: "))
let profile = ConnectionProfile(name: "check", host: args[1], port: port, user: args[3], defaultSchema: args.count > 4 ? args[4] : "")
let session = MySQLSession(profile: profile, password: password)

func show(_ result: QueryResult) {
    print("> \(result.sql)")
    if result.hasResultSet {
        print(result.columns.map { "\($0.name)\($0.isPrimaryKey ? "*" : "") [\($0.typeName)]" }.joined(separator: " | "))
        for row in result.rows.prefix(20) {
            print(row.map { $0 ?? "NULL" }.joined(separator: " | "))
        }
    }
    print("  \(result.summary) in \(result.duration)\n")
}

do {
    try await session.connect()
    print("Connected. Connection id \(await session.connectionID.map(String.init) ?? "?")\n")
    show(try await session.execute("SELECT VERSION() AS version, CURRENT_USER() AS user"))
    show(try await session.execute("SHOW SESSION STATUS LIKE 'Ssl_cipher'"))
    show(try await session.execute("SHOW DATABASES"))
    if args.count > 5 { show(try await session.execute(args[5])) }
    await session.close()
} catch {
    print("FAILED: \(String(reflecting: error))")
    exit(1)
}
