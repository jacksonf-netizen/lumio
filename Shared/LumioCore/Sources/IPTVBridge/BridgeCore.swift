import Foundation
import GRDB
import IPTVCore

/// The one door between an app written in another language (the Android TV app, in Kotlin) and the
/// shared core. The app sends a command as JSON and gets JSON back; changes arrive as events.
///
///     request:  {"method": "providers.add", "params": {"name": "…", "servers": "…", …}}
///     reply:    {"result": …}  or  {"error": "a message fit to show"}
///     event:    {"type": "sync", "provider": "…", "label": "Updating channels…"}
///
/// The rules all live in the core (`AppEnvironment` and its repositories); this only translates.
/// Calls are coarse (one per screen update), so JSON costs nothing that matters. Methods are listed
/// in `perform(_:_:)`; the Kotlin side has one function per method (LumioCore.kt).
public actor BridgeCore {
    public nonisolated let environment: AppEnvironment
    private let send: @Sendable (String) -> Void
    private let liveCatalog: LiveCatalog
    private let guide: GuideRepository
    private var syncing: [ProviderID: String] = [:]
    private var observers: [AnyDatabaseCancellable] = []
    private var tasks: [Task<Void, Never>] = []

    /// `events` receives each event as JSON, on any thread.
    public init(environment: AppEnvironment, events: @escaping @Sendable (String) -> Void) {
        self.environment = environment
        send = events
        liveCatalog = LiveCatalog(database: environment.database)
        guide = GuideRepository(database: environment.database)
    }

    /// Opens the database at `databasePath` and wires the core with the app's secret store and the
    /// platform's networking.
    public static func open(databasePath: String, secrets: any SecretStore,
                            events: @escaping @Sendable (String) -> Void) throws -> BridgeCore {
        let database = try AppDatabase.open(at: URL(fileURLWithPath: databasePath))
        return BridgeCore(environment: AppEnvironment(database: database, secrets: secrets, transport: URLSessionTransport()),
                          events: events)
    }

    /// Starts following changes and the background work every app runs (link checks and refreshes
    /// on the same schedule as the Mac). Call once, after the app is ready for events.
    public func start(backgroundWork: Bool = true) {
        guard tasks.isEmpty else { return }
        let send = self.send
        observers.append(liveCatalog.observeListChanges { Self.emit(BridgeEvent(type: "live"), to: send) })
        observers.append(liveCatalog.observeGuideChanges { Self.emit(BridgeEvent(type: "guide"), to: send) })
        let environment = self.environment
        // Database observations here, not the repositories' value streams: those deliver on the main
        // queue, which only runs on Android once the app's UI thread drains it.
        observers.append(environment.providers.repository.observeChanges { [weak self] in
            Task { await self?.providersChanged() }
        })
        providersChanged()
        tasks.append(Task { [weak self] in
            for await event in await environment.sync.events() { await self?.handle(event) }
        })
        tasks.append(Task {
            while !Task.isCancelled {
                await environment.connections.waitForChange()
                Self.emit(BridgeEvent(type: "providers"), to: send)
            }
        })
        if backgroundWork { environment.startBackgroundWork() }
    }

    /// Runs one request and returns the reply. Never throws: failures become `{"error": …}`.
    public func handle(_ request: String) async -> String {
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any],
                  let method = object["method"] as? String else { throw BridgeError("The request isn't valid.") }
            let params = try JSONSerialization.data(withJSONObject: object["params"] ?? [String: Any]())
            let result = try await perform(method, Params(data: params))
            return try Self.reply(result)
        } catch {
            return Self.errorReply(AppEnvironment.userMessage(for: error))
        }
    }

    // MARK: Methods

    private func perform(_ method: String, _ params: Params) async throws -> any Encodable {
        switch method {
        case "providers.list":
            return try await providerList()

        case "providers.add":
            struct P: Decodable { var name: String; var servers: String; var username: String; var password: String }
            let p = try params.decode(P.self)
            let provider = try await environment.addProvider(name: p.name, servers: p.servers, username: p.username, password: p.password)
            return ["id": provider.id.rawValue]

        case "providers.save":
            struct P: Decodable { var id: String; var name: String; var servers: String; var username: String; var password: String }
            let p = try params.decode(P.self)
            try await environment.saveProvider(try provider(p.id), name: p.name, servers: p.servers, username: p.username, password: p.password)
            return Empty()

        case "providers.editor":
            let provider = try provider(try params.decode(ID.self).id)
            return ProviderEditorDTO(servers: environment.serverLinksText(for: provider),
                                     username: environment.savedUsername(for: provider.id))

        case "providers.remove":
            try await environment.removeProvider(ProviderID(try params.decode(ID.self).id))
            return Empty()

        case "providers.setEnabled":
            struct P: Decodable { var id: String; var enabled: Bool }
            let p = try params.decode(P.self)
            try await environment.setProviderEnabled(p.enabled, for: try provider(p.id))
            return Empty()

        case "providers.reorder":
            struct P: Decodable { var ids: [String] }
            try environment.reorderProviders(try params.decode(P.self).ids.map(ProviderID.init))
            return Empty()

        case "providers.refresh":
            // Without an id: every provider.
            struct P: Decodable { var id: String? }
            if let id = try params.decode(P.self).id {
                environment.refreshProvider(ProviderID(id))
            } else {
                environment.refreshAllProviders()
            }
            return Empty()

        case "live.groups":
            struct P: Decodable { var includeHidden: Bool? }
            let p = try params.decode(P.self)
            return try await liveCatalog.groups(includeHidden: p.includeHidden ?? false).map(GroupDTO.init)

        case "live.channels":
            struct P: Decodable { var group: String; var includeHidden: Bool? }
            let p = try params.decode(P.self)
            let includeHidden = p.includeHidden ?? false
            let groups = try await liveCatalog.groups(includeHidden: includeHidden)
            guard let group = groups.first(where: { $0.id == p.group }) else { return [ChannelDTO]() }
            return try await liveCatalog.channels(in: group, includeHidden: includeHidden).map(ChannelDTO.init)

        case "live.nowNext":
            struct P: Decodable { var epg: [EPGRefDTO] }
            let refs = try params.decode(P.self).epg
            let found = try await guide.nowNext(for: refs.map(\.ref))
            return refs.compactMap { ref -> NowNextDTO? in
                guard let value = found[ref.ref] else { return nil }
                return NowNextDTO(epg: ref, now: value.now.map(ProgrammeDTO.init), next: value.next.map(ProgrammeDTO.init))
            }

        default:
            throw BridgeError("Unknown request \(method).")
        }
    }

    private func provider(_ id: String) throws -> Provider {
        guard let provider = try environment.providers.repository.provider(id: ProviderID(id)) else {
            throw BridgeError("That provider no longer exists.")
        }
        return provider
    }

    private func providerList() async throws -> [ProviderDTO] {
        let providers = try environment.providers.repository.all()
        let links = Dictionary(grouping: try environment.providers.repository.allLinks(), by: \.providerID)
        let usage = await environment.connections.snapshot()
        var list: [ProviderDTO] = []
        for provider in providers {
            let counts = (try? environment.catalog.counts(providerID: provider.id)) ?? CatalogCounts()
            let providerLinks = links[provider.id] ?? []
            let limit = await environment.connections.limit(for: provider.id)
            list.append(ProviderDTO(
                id: provider.id.rawValue, name: provider.name, enabled: provider.isEnabled,
                server: provider.serverURL.absoluteString,
                links: providerLinks.map {
                    LinkDTO(url: $0.url.absoluteString, inUse: $0.url == provider.serverURL, down: $0.isDown,
                            lastCheckedAt: $0.lastCheckedAt?.timeIntervalSince1970)
                },
                channels: counts.channels, movies: counts.movies, series: counts.series, programmes: counts.programmes,
                connectionsInUse: usage[provider.id]?.inUse ?? 0, connectionLimit: usage[provider.id]?.limit ?? limit,
                accountStatus: provider.accountStatus, expiresAt: provider.expiresAt?.timeIntervalSince1970,
                lastRefreshAt: provider.lastRefreshAt?.timeIntervalSince1970,
                lastError: provider.lastError.map { CredentialRedactor.redact($0) },
                syncing: syncing[provider.id], unreachable: provider.isEnabled && providerLinks.allDown))
        }
        return list
    }

    // MARK: Events

    private func providersChanged() {
        // Logos and posters on a link that isn't in use load from the one that is (as on the Mac).
        if let providers = try? environment.providers.repository.all(),
           let links = try? environment.providers.repository.allLinks() {
            ServerAliases.shared.update(links, active: Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.serverURL) }))
        }
        Self.emit(BridgeEvent(type: "providers"), to: send)
    }

    private func handle(_ event: SyncEvent) {
        switch event {
        case .started(let id):
            syncing[id] = "Starting…"
            Self.emit(BridgeEvent(type: "sync", provider: id.rawValue, label: syncing[id]), to: send)
        case .step(let id, let step):
            syncing[id] = step.label
            Self.emit(BridgeEvent(type: "sync", provider: id.rawValue, label: step.label), to: send)
        case .guideProgress(let id, let count):
            syncing[id] = "Guide: \(count.formatted()) programmes"
            Self.emit(BridgeEvent(type: "sync", provider: id.rawValue, label: syncing[id]), to: send)
        case .finished(let id, let error):
            syncing[id] = nil
            Self.emit(BridgeEvent(type: "sync", provider: id.rawValue, finished: true,
                                  error: error.map { CredentialRedactor.redact($0) }), to: send)
            Self.emit(BridgeEvent(type: "providers"), to: send)
        }
    }

    private static func emit(_ event: BridgeEvent, to send: @Sendable (String) -> Void) {
        guard let data = try? encoder.encode(event) else { return }
        send(String(decoding: data, as: UTF8.self))
    }

    // MARK: JSON

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func reply(_ result: any Encodable) throws -> String {
        struct Reply<T: Encodable>: Encodable { var result: T }
        func encode<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(Reply(result: value)) }
        return String(decoding: try encode(result), as: UTF8.self)
    }

    private static func errorReply(_ message: String) -> String {
        let data = (try? encoder.encode(["error": message])) ?? Data(#"{"error":"Something went wrong."}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

private struct Params {
    let data: Data
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BridgeError("The request is missing something (\(error)).")
        }
    }
}

private struct ID: Decodable { var id: String }
private struct Empty: Encodable {}

struct BridgeError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
