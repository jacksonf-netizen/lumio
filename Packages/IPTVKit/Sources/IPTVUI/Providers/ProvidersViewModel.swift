import Foundation
import Observation
import IPTVCore

/// Live status for one provider row.
struct ProviderStatus: Equatable {
    var counts = CatalogCounts()
    var usage: ConnectionUsage?
}

@MainActor
@Observable
final class ProvidersViewModel {
    private(set) var providers: [Provider] = []
    /// False until the first database read completes, so empty-state UI doesn't flash on launch.
    private(set) var loaded = false
    private(set) var status: [ProviderID: ProviderStatus] = [:]
    /// Providers currently refreshing, with their current step.
    private(set) var syncing: [ProviderID: String] = [:]
    var errorMessage: String?

    var isSyncing: Bool { !syncing.isEmpty }
    var syncSummary: String {
        guard let (id, step) = syncing.first else { return "" }
        let name = providers.first { $0.id == id }?.name ?? "provider"
        return syncing.count > 1 ? "Updating \(syncing.count) providers…" : "\(name): \(step)"
    }

    private let environment: AppEnvironment
    private var service: ProviderService { environment.providers }
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Starts following the provider table, sync events and connection usage. Safe to call twice.
    func start() {
        guard tasks.isEmpty else { return }
        let values = service.repository.observeAll()
        tasks.append(Task { [weak self] in
            do {
                for try await providers in values {
                    guard let self else { return }
                    self.providers = providers
                    self.loaded = true
                    self.reloadStatus()
                }
            } catch {
                self?.errorMessage = "Couldn't read providers: \(error)"
            }
        })
        let sync = environment.sync
        tasks.append(Task { [weak self] in
            for await event in await sync.events() {
                self?.handle(event)
            }
        })
        let connections = environment.connections
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await connections.waitForChange()
                await self?.reloadUsage()
            }
        })
    }

    private func handle(_ event: SyncEvent) {
        switch event {
        case .started(let id):
            syncing[id] = "Starting…"
        case .step(let id, let step):
            syncing[id] = Self.label(for: step)
        case .guideProgress(let id, let count):
            syncing[id] = "Guide: \(count.formatted()) programmes"
        case .finished(let id, _):
            syncing[id] = nil
            reloadStatus()
        }
    }

    private static func label(for step: SyncStep) -> String {
        switch step {
        case .account: "Checking account…"
        case .live: "Updating channels…"
        case .movies: "Updating movies…"
        case .series: "Updating series…"
        case .guide: "Downloading guide…"
        case .matching: "Matching channels…"
        }
    }

    private func reloadStatus() {
        for provider in providers {
            let counts = (try? environment.catalog.counts(providerID: provider.id)) ?? CatalogCounts()
            status[provider.id, default: ProviderStatus()].counts = counts
        }
        Task { await reloadUsage() }
    }

    private func reloadUsage() async {
        let snapshot = await environment.connections.snapshot()
        for provider in providers {
            let limit = await environment.connections.limit(for: provider.id)
            status[provider.id, default: ProviderStatus()].usage =
                snapshot[provider.id] ?? ConnectionUsage(limit: limit, inUse: 0, purposes: [])
        }
    }

    // MARK: Actions

    /// Returns nil on success, or a message to show in the editor.
    func add(name: String, serverURL: String, username: String, password: String) async -> String? {
        do {
            let provider = try await service.addProvider(
                name: name, serverURL: serverURL,
                credentials: ProviderCredentials(username: username, password: password))
            refresh(provider)
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    /// Updates name/URL and optionally credentials (empty password keeps the saved one).
    func save(_ provider: Provider, name: String, serverURL: String, username: String, password: String) async -> String? {
        do {
            var updated = provider
            updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? provider.name : name
            var credentials: ProviderCredentials?
            if let existing = try service.credentials(for: provider.id) {
                let newUser = username.isEmpty ? existing.username : username
                let newPass = password.isEmpty ? existing.password : password
                if newUser != existing.username || newPass != existing.password {
                    credentials = ProviderCredentials(username: newUser, password: newPass)
                }
            } else {
                credentials = ProviderCredentials(username: username, password: password)
            }
            try await service.updateProvider(updated, serverURL: serverURL, credentials: credentials)
            refresh(updated, restart: true)
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    func savedUsername(for provider: Provider) -> String {
        (try? service.credentials(for: provider.id))?.username ?? ""
    }

    func remove(_ provider: Provider) async {
        await environment.sync.cancel(provider.id)
        do {
            try await service.removeProvider(id: provider.id)
            await environment.connections.removeProvider(provider.id)
            try environment.logicalChannels.rebuild()
        } catch {
            errorMessage = "Couldn't remove \(provider.name): \(Self.message(for: error))"
        }
    }

    func setEnabled(_ enabled: Bool, for provider: Provider) async {
        var updated = provider
        updated.isEnabled = enabled
        do {
            try await service.updateProvider(updated)
            try environment.logicalChannels.rebuild()
            if enabled { refresh(updated) }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ids = providers.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        do {
            try service.repository.reorder(ids)
            // Priority decides which provider's name/logo a merged channel shows.
            try environment.logicalChannels.rebuild()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func refresh(_ provider: Provider, parts: RefreshParts = .all, restart: Bool = false) {
        let sync = environment.sync
        Task.detached(priority: .utility) { await sync.refresh(provider.id, parts: parts, restart: restart) }
    }

    func refreshAll() {
        let sync = environment.sync
        Task.detached(priority: .utility) { await sync.refreshStale(force: true) }
    }

    private static func message(for error: Error) -> String {
        CredentialRedactor.redact((error as? LocalizedError)?.errorDescription ?? String(describing: error))
    }
}
