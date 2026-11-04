import Foundation

/// What the Providers screen of every Lumio app does, so the Mac and Android TV apps follow the
/// same rules: a new or edited provider refreshes straight away, removing one stops its refresh and
/// frees its connections, and every change that affects merged channels rebuilds them.
extension AppEnvironment {
    /// Adds a provider and starts its first refresh. `servers` is one link per line.
    @discardableResult
    public func addProvider(name: String, servers: String, username: String, password: String) async throws -> Provider {
        let provider = try await providers.addProvider(
            name: name, servers: servers, credentials: ProviderCredentials(username: username, password: password))
        refreshProvider(provider.id)
        return provider
    }

    /// Updates the name, links and login. An empty username or password keeps the saved one; a
    /// blank name keeps the current name. Refreshes afterwards, restarting a refresh in progress.
    public func saveProvider(_ provider: Provider, name: String, servers: String, username: String, password: String) async throws {
        var updated = provider
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { updated.name = trimmed }
        var credentials: ProviderCredentials?
        if let existing = try providers.credentials(for: provider.id) {
            let newUser = username.isEmpty ? existing.username : username
            let newPass = password.isEmpty ? existing.password : password
            if newUser != existing.username || newPass != existing.password {
                credentials = ProviderCredentials(username: newUser, password: newPass)
            }
        } else {
            credentials = ProviderCredentials(username: username, password: password)
        }
        try await providers.updateProvider(updated, servers: servers, credentials: credentials)
        refreshProvider(updated.id, restart: true)
    }

    /// Removes a provider with its catalog, guide, links and saved login.
    public func removeProvider(_ id: ProviderID) async throws {
        await sync.cancel(id)
        try await providers.removeProvider(id: id)
        await connections.removeProvider(id)
        try logicalChannels.rebuild()
    }

    /// Switches a provider on or off. Switching on refreshes it.
    public func setProviderEnabled(_ enabled: Bool, for provider: Provider) async throws {
        var updated = provider
        updated.isEnabled = enabled
        try await providers.updateProvider(updated)
        try logicalChannels.rebuild()
        if enabled { refreshProvider(provider.id) }
    }

    /// Saves the providers' order (first = highest priority). Priority decides which provider's
    /// name and logo a merged channel shows.
    public func reorderProviders(_ ids: [ProviderID]) throws {
        try providers.repository.reorder(ids)
        try logicalChannels.rebuild()
    }

    /// Refreshes one provider in the background. Checks its server links first (dead ones too: the
    /// user asked), so the refresh runs on the best one that works.
    public func refreshProvider(_ id: ProviderID, parts: RefreshParts = .all, restart: Bool = false) {
        let sync = self.sync, servers = self.servers
        Task.detached(priority: .utility) {
            await servers.recheck(id, includingDead: true)
            await sync.refresh(id, parts: parts, restart: restart)
        }
    }

    /// Refreshes every provider in the background, links first.
    public func refreshAllProviders() {
        let sync = self.sync, servers = self.servers
        Task.detached(priority: .utility) {
            await servers.recheckAll(includingDead: true)
            await sync.refreshStale(force: true)
        }
    }

    /// The provider's links as an editor shows them, one per line.
    public func serverLinksText(for provider: Provider) -> String {
        let urls = (try? providers.repository.links(for: provider.id))?.map(\.url) ?? [provider.serverURL]
        return urls.map(\.absoluteString).joined(separator: "\n")
    }

    /// The saved username (never the password), for an editor.
    public func savedUsername(for id: ProviderID) -> String {
        (try? providers.credentials(for: id))?.username ?? ""
    }

    /// A message fit to show for any error, with credentials removed.
    public static func userMessage(for error: Error) -> String {
        CredentialRedactor.redact((error as? LocalizedError)?.errorDescription ?? String(describing: error))
    }
}

extension SyncStep {
    /// What a refresh is doing, as the apps show it.
    public var label: String {
        switch self {
        case .account: "Checking account…"
        case .live: "Updating channels…"
        case .movies: "Updating movies…"
        case .series: "Updating series…"
        case .guide: "Downloading guide…"
        case .matching: "Matching channels…"
        }
    }
}
