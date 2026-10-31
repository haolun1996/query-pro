import Foundation
import Testing
@testable import SQCore

@Suite struct KeychainTests {
    @Test func decodeQuotedPasswords() {
        #expect(Keychain.decode("password: \"secret\"\n") == "secret")
        #expect(Keychain.decode("password: \"c3bc\"\n") == "c3bc")
        #expect(Keychain.decode("password: \"say \"hi\"\"\n") == "say \"hi\"")
    }

    @Test func decodeHexPasswords() {
        #expect(Keychain.decode("password: 0x6162C3BC  \"ab\\303\\274\"\n") == "abü")
    }

    @Test func decodeMissingLine() {
        #expect(Keychain.decode("") == nil)
    }

    /// Writes, reads, overwrites and deletes a throwaway item in the login keychain.
    @Test func roundTrip() async {
        let id = UUID()
        #expect(await Keychain.password(for: id) == nil)
        #expect(await Keychain.setPassword("p@ss \"word\" ü", for: id))
        #expect(await Keychain.password(for: id) == "p@ss \"word\" ü")
        #expect(await Keychain.setPassword("second", for: id))
        #expect(await Keychain.password(for: id) == "second")
        #expect(await Keychain.deletePassword(for: id))
        #expect(await Keychain.password(for: id) == nil)
    }
}
