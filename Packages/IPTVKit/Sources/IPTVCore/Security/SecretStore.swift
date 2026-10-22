import Foundation
import Security

/// Storage for provider credentials. The app uses `KeychainSecretStore`; tests and previews use
/// `InMemorySecretStore`.
public protocol SecretStore: Sendable {
    func save(_ credentials: ProviderCredentials, for providerID: ProviderID) throws
    func load(for providerID: ProviderID) throws -> ProviderCredentials?
    func delete(for providerID: ProviderID) throws
}

public enum SecretStoreError: Error, Equatable, CustomStringConvertible {
    case keychain(status: OSStatus)
    case corruptItem

    public var description: String {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain error \(status): \(message)"
        case .corruptItem:
            return "Keychain item could not be decoded"
        }
    }
}

/// Stores each provider's credentials as one generic-password Keychain item.
/// service = `service`, account = provider id, data = JSON `{username, password}`.
public struct KeychainSecretStore: SecretStore {
    public static let defaultService = "com.jackson.iptvstreamer.provider"

    public let service: String
    /// What an erased item holds (the Keychain doesn't store empty values).
    static let erased = Data([0])
    /// `SecItemDelete`, replaceable in tests.
    var deleteItem: @Sendable (CFDictionary) -> OSStatus = { SecItemDelete($0) }

    public init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    public func save(_ credentials: ProviderCredentials, for providerID: ProviderID) throws {
        let data = try JSONEncoder().encode(credentials)
        let query = baseQuery(for: providerID)

        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Lumio provider"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            Log.security.error("Keychain save failed: \(status)")
            throw SecretStoreError.keychain(status: status)
        }
    }

    public func load(for providerID: ProviderID) throws -> ProviderCredentials? {
        var query = baseQuery(for: providerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            // Erased by `delete` (see there): nothing saved.
            if let data = result as? Data, data.isEmpty || data == Self.erased { return nil }
            guard let data = result as? Data,
                  let credentials = try? JSONDecoder().decode(ProviderCredentials.self, from: data)
            else { throw SecretStoreError.corruptItem }
            return credentials
        case errSecItemNotFound:
            return nil
        default:
            Log.security.error("Keychain load failed: \(status)")
            throw SecretStoreError.keychain(status: status)
        }
    }

    public func delete(for providerID: ProviderID) throws {
        var status = deleteItem(baseQuery(for: providerID) as CFDictionary)
        if status == errSecInvalidOwnerEdit {
            // Only the exact build that saved an item may delete it; later versions (signed by the
            // same team) can still read and change it. So the login is erased instead, and nothing
            // usable is left behind.
            status = SecItemUpdate(baseQuery(for: providerID) as CFDictionary, [kSecValueData as String: Self.erased] as CFDictionary)
            if status == errSecSuccess { Log.security.info("Keychain item from an earlier version erased (it can't be deleted)") }
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Log.security.error("Keychain delete failed: \(status)")
            throw SecretStoreError.keychain(status: status)
        }
    }

    private func baseQuery(for providerID: ProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.rawValue,
        ]
    }
}

/// Non-persistent store for tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ProviderID: ProviderCredentials] = [:]

    public init() {}

    public func save(_ credentials: ProviderCredentials, for providerID: ProviderID) throws {
        lock.withLock { items[providerID] = credentials }
    }

    public func load(for providerID: ProviderID) throws -> ProviderCredentials? {
        lock.withLock { items[providerID] }
    }

    public func delete(for providerID: ProviderID) throws {
        _ = lock.withLock { items.removeValue(forKey: providerID) }
    }

    public var count: Int { lock.withLock { items.count } }
}
