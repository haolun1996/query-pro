// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SQPro",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "SQPro", targets: ["SQPro"]),
        .executable(name: "sqcheck", targets: ["sqcheck"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.9.2"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    ],
    targets: [
        // Profiles, Keychain, MySQL sessions and query results. No UI.
        .target(name: "SQCore", dependencies: [
            .product(name: "MySQLNIO", package: "mysql-nio"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
        // MCP server for AI clients (Claude Code etc.), on 127.0.0.1 over HTTP. No UI.
        .target(name: "SQMCP", dependencies: [
            "SQCore",
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
        ]),
        // The app. Built into dist/SQ Pro.app by scripts/bundle.sh.
        .executableTarget(
            name: "SQPro",
            dependencies: ["SQCore", "SQMCP"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        // Connection check from the terminal: sqcheck <host> <port> <user> [schema] [sql]
        .executableTarget(name: "sqcheck", dependencies: ["SQCore"]),
        .testTarget(name: "SQCoreTests", dependencies: ["SQCore"]),
        .testTarget(name: "SQMCPTests", dependencies: ["SQMCP"]),
    ]
)
