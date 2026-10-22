import Foundation
import Testing
@testable import IPTVCore

/// Uses the real login Keychain under a throwaway service name, and cleans up after itself.
@Suite("Keychain secret store", .serialized)
struct KeychainSecretStoreTests {
    let store = KeychainSecretStore(service: "com.jackson.iptvstreamer.tests.\(UUID().uuidString)")

    @Test func saveLoadUpdateDelete() throws {
        let id = ProviderID.make()
        defer { try? store.delete(for: id) }

        #expect(try store.load(for: id) == nil)

        try store.save(ProviderCredentials(username: "alice", password: "one"), for: id)
        #expect(try store.load(for: id) == ProviderCredentials(username: "alice", password: "one"))

        try store.save(ProviderCredentials(username: "alice", password: "two"), for: id)
        #expect(try store.load(for: id)?.password == "two")

        try store.delete(for: id)
        #expect(try store.load(for: id) == nil)
        // Deleting a missing item is not an error.
        try store.delete(for: id)
    }

    @Test func itemsAreSeparatedByProvider() throws {
        let a = ProviderID.make()
        let b = ProviderID.make()
        defer {
            try? store.delete(for: a)
            try? store.delete(for: b)
        }
        try store.save(ProviderCredentials(username: "a", password: "pa"), for: a)
        try store.save(ProviderCredentials(username: "b", password: "pb"), for: b)
        try store.delete(for: a)
        #expect(try store.load(for: a) == nil)
        #expect(try store.load(for: b)?.username == "b")
    }
}
