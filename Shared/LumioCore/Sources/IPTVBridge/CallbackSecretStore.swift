import Foundation
import IPTVCore

/// Saved logins kept by the app itself, reached through three callbacks. The Android TV app keeps
/// them in a file encrypted with a key held in the Android Keystore. Each value is the login as
/// JSON (`{"username": …, "password": …}`); it goes only to the callbacks, never to a log.
public struct CallbackSecretStore: SecretStore {
    public typealias Save = @Sendable (_ providerID: String, _ value: String) -> Bool
    public typealias Load = @Sendable (_ providerID: String) -> String?
    public typealias Delete = @Sendable (_ providerID: String) -> Bool

    private let saveValue: Save
    private let loadValue: Load
    private let deleteValue: Delete

    public init(save: @escaping Save, load: @escaping Load, delete: @escaping Delete) {
        saveValue = save
        loadValue = load
        deleteValue = delete
    }

    public func save(_ credentials: ProviderCredentials, for providerID: ProviderID) throws {
        let value = String(decoding: try JSONEncoder().encode(credentials), as: UTF8.self)
        guard saveValue(providerID.rawValue, value) else { throw CallbackSecretStoreError.saveFailed }
    }

    public func load(for providerID: ProviderID) throws -> ProviderCredentials? {
        guard let value = loadValue(providerID.rawValue) else { return nil }
        do {
            return try JSONDecoder().decode(ProviderCredentials.self, from: Data(value.utf8))
        } catch {
            throw SecretStoreError.corruptItem
        }
    }

    public func delete(for providerID: ProviderID) throws {
        guard deleteValue(providerID.rawValue) else { throw CallbackSecretStoreError.deleteFailed }
    }
}

public enum CallbackSecretStoreError: Error, LocalizedError {
    case saveFailed, deleteFailed

    public var errorDescription: String? {
        switch self {
        case .saveFailed: "Couldn't save the login on this device."
        case .deleteFailed: "Couldn't remove the saved login from this device."
        }
    }
}
