import Foundation
import IPTVCore

/// Development helper: adds providers listed in a `LocalSecrets.json` file (see
/// LocalSecrets.example.json). The file is git-ignored and never bundled with the app.
public enum LocalSecretsImporter {
    struct File: Decodable {
        struct Entry: Decodable {
            var name: String?
            var serverURL: String
            var username: String
            var password: String
        }
        var providers: [Entry]
    }

    /// Adds providers whose server URL + username aren't configured yet. Returns how many were added.
    @discardableResult
    public static func importFile(at url: URL, into environment: AppEnvironment) async throws -> Int {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        let existing = try environment.providers.repository.all()
        var added = 0
        for entry in file.providers {
            let normalized = try ServerURL.normalize(entry.serverURL)
            let duplicate = existing.contains { provider in
                let username = (try? environment.providers.credentials(for: provider.id))?.username
                return provider.serverURL == normalized && username == entry.username
            }
            if duplicate { continue }
            let provider = try await environment.providers.addProvider(
                name: entry.name ?? "", serverURL: entry.serverURL,
                credentials: ProviderCredentials(username: entry.username, password: entry.password))
            added += 1
            let sync = environment.sync
            Task.detached(priority: .utility) { await sync.refresh(provider.id) }
        }
        return added
    }
}
