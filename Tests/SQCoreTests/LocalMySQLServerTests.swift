import Foundation
import Testing
@testable import SQCore

@Suite struct LocalMySQLServerTests {
    @Test func localHosts() {
        #expect(LocalMySQLServer.isLocal(host: "localhost"))
        #expect(LocalMySQLServer.isLocal(host: " 127.0.0.1 "))
        #expect(LocalMySQLServer.isLocal(host: "LocalHost"))
        #expect(!LocalMySQLServer.isLocal(host: "db.example.com"))
        #expect(!LocalMySQLServer.isLocal(host: "10.0.0.5"))
    }

    @Test func remoteProfiles() {
        #expect(!ConnectionProfile(host: "localhost").isRemote)
        #expect(!ConnectionProfile(host: "127.0.0.1").isRemote)
        #expect(ConnectionProfile(host: "db.example.com").isRemote)
        #expect(ConnectionProfile(host: "192.168.1.20").isRemote)
    }

    /// Nothing listens on port 1.
    @Test func closedPort() {
        #expect(!LocalMySQLServer.acceptsConnections(port: 1))
    }

    /// Only checks what's there: starting or stopping would need an administrator.
    @Test func statusMatchesThePort() async {
        let status = await LocalMySQLServer.status()
        if !LocalMySQLServer.isInstalled {
            #expect(status == .notInstalled)
        } else if LocalMySQLServer.acceptsConnections(port: 3306) {
            #expect(status == .running)
        } else {
            #expect(status == .stopped || status == .starting)
        }
    }
}
