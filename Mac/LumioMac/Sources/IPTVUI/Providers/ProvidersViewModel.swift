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
    /// Each provider's server links in order, with what the last check found.
    private(set) var links: [ProviderID: [ServerLink]] = [:]
    /// Providers currently refreshing, with their current step.
    private(set) var syncing: [ProviderID: String] = [:]
    var errorMessage: String?

    var isSyncing: Bool { !syncing.isEmpty }

    /// Enabled providers none of whose server links answered the last check.
    var unreachable: [Provider] {
        providers.filter { $0.isEnabled && (links[$0.id] ?? []).allDown }
    }
    /// "Updating Provider A", or "Updating 2 providers".
    var syncTitle: String {
        guard let (id, _) = syncing.first else { return "" }
        if syncing.count > 1 { return "Updating \(syncing.count) providers" }
        return "Updating \(providers.first { $0.id == id }?.name ?? "provider")"
    }

    /// What a single refresh is doing ("Checking account…").
    var syncDetail: String? {
        guard syncing.count == 1, let (_, step) = syncing.first else { return nil }
        return step
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
                    self.updateAliases()
                }
            } catch {
                self?.errorMessage = "Couldn't read providers: \(error)"
            }
        })
        let linkValues = service.repository.observeLinks()
        tasks.append(Task { [weak self] in
            do {
                for try await links in linkValues {
                    guard let self else { return }
                    self.links = Dictionary(grouping: links, by: \.providerID)
                    self.updateAliases()
                }
            } catch {
                self?.errorMessage = "Couldn't read server links: \(error)"
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
            syncing[id] = step.label
        case .guideProgress(let id, let count):
            syncing[id] = "Guide: \(count.formatted()) programmes"
        case .finished(let id, _):
            syncing[id] = nil
            reloadStatus()
        }
    }

    /// Logos and posters on a link that isn't in use load from the one that is.
    private func updateAliases() {
        ServerAliases.shared.update(links.values.flatMap { $0 },
                                    active: Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.serverURL) }))
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

    // MARK: Actions (the rules are in the shared core: AppEnvironment+ProviderActions)

    /// Returns nil on success, or a message to show in the editor. `servers` is one link per line.
    func add(name: String, servers: String, username: String, password: String) async -> String? {
        do {
            try await environment.addProvider(name: name, servers: servers, username: username, password: password)
            return nil
        } catch {
            return AppEnvironment.userMessage(for: error)
        }
    }

    /// Updates name, links and optionally credentials (empty password keeps the saved one).
    func save(_ provider: Provider, name: String, servers: String, username: String, password: String) async -> String? {
        do {
            try await environment.saveProvider(provider, name: name, servers: servers, username: username, password: password)
            return nil
        } catch {
            return AppEnvironment.userMessage(for: error)
        }
    }

    /// The provider's links as the editor shows them, one per line. Read from the database, so
    /// saving can't drop links that haven't reached `links` yet.
    func serversText(for provider: Provider) -> String {
        environment.serverLinksText(for: provider)
    }

    func savedUsername(for provider: Provider) -> String {
        environment.savedUsername(for: provider.id)
    }

    func remove(_ provider: Provider) async {
        do {
            try await environment.removeProvider(provider.id)
        } catch {
            errorMessage = "Couldn't remove \(provider.name): \(AppEnvironment.userMessage(for: error))"
        }
    }

    func setEnabled(_ enabled: Bool, for provider: Provider) async {
        do {
            try await environment.setProviderEnabled(enabled, for: provider)
        } catch {
            errorMessage = AppEnvironment.userMessage(for: error)
        }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ids = providers.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        do {
            try environment.reorderProviders(ids)
        } catch {
            errorMessage = AppEnvironment.userMessage(for: error)
        }
    }

    func refresh(_ provider: Provider, parts: RefreshParts = .all, restart: Bool = false) {
        environment.refreshProvider(provider.id, parts: parts, restart: restart)
    }

    func refreshAll() {
        environment.refreshAllProviders()
    }
}
