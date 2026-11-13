import Foundation

/// Adds, edits and removes providers, keeping the database row and the Keychain item consistent.
public struct ProviderService: Sendable {
    public let repository: ProviderRepository
    private let secrets: any SecretStore
    private let sync: any SyncProvider

    public init(database: AppDatabase, secrets: any SecretStore, sync: any SyncProvider = LocalOnlySyncProvider()) {
        self.repository = ProviderRepository(database: database)
        self.secrets = secrets
        self.sync = sync
    }

    /// Validates input, stores the credentials in the secret store and inserts the provider.
    /// `servers` is one address or a pasted list, one per line (see `ServerURL.parseList`); a login
    /// inside the links is ignored here (the editor offers it). If the database insert fails the
    /// credentials are removed again.
    @discardableResult
    public func addProvider(name: String, servers: String, credentials: ProviderCredentials) async throws -> Provider {
        let urls = try ServerURL.parseList(servers).urls
        let credentials = try Self.validated(credentials)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = Provider(name: trimmedName.isEmpty ? (urls[0].host ?? "Provider") : trimmedName, serverURL: urls[0])

        try secrets.save(credentials, for: provider.id)
        do {
            let inserted = try repository.insert(provider, links: urls)
            Log.app.info("Added provider \(inserted.id, privacy: .public) with \(urls.count) server links")
            await sync.localDataDidChange(.providers)
            return inserted
        } catch {
            try? secrets.delete(for: provider.id)
            throw error
        }
    }

    @discardableResult
    public func addProvider(name: String, serverURL: String, credentials: ProviderCredentials) async throws -> Provider {
        try await addProvider(name: name, servers: serverURL, credentials: credentials)
    }

    /// Updates the settings and, when given, the server links (one per line) and credentials.
    public func updateProvider(_ provider: Provider, servers: String? = nil,
                               credentials: ProviderCredentials? = nil) async throws {
        let urls = try servers.map { try ServerURL.parseList($0).urls }
        if let credentials { try secrets.save(try Self.validated(credentials), for: provider.id) }
        try repository.updateSettings(provider)
        if let urls { try repository.setLinks(urls, for: provider.id) }
        await sync.localDataDidChange(.providers)
    }

    /// Removes the provider, all data it owns (cascade) and its Keychain item.
    public func removeProvider(id: ProviderID) async throws {
        try repository.delete(id: id)
        try secrets.delete(for: id)
        try? GuideLinkStore(secrets: secrets).delete(for: id)
        Log.app.info("Removed provider \(id, privacy: .public)")
        await sync.localDataDidChange(.providers)
    }

    public func credentials(for id: ProviderID) throws -> ProviderCredentials? {
        try secrets.load(for: id)
    }

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case missingUsername
        case missingPassword

        public var description: String {
            switch self {
            case .missingUsername: "Enter the username."
            case .missingPassword: "Enter the password."
            }
        }
    }

    private static func validated(_ credentials: ProviderCredentials) throws -> ProviderCredentials {
        let username = credentials.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { throw ValidationError.missingUsername }
        // Passwords are kept verbatim; only reject empty.
        guard !credentials.password.isEmpty else { throw ValidationError.missingPassword }
        return ProviderCredentials(username: username, password: credentials.password)
    }
}
