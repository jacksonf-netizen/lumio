import Foundation

/// What playback asks when a stream fails.
public protocol ServerHealth: Sendable {
    /// Checks the provider's server in use and, when it's down, switches to the next working link.
    /// True when it switched, so the stream can be retried on the new address straight away.
    func streamFailed(providerID: ProviderID) async -> Bool
}

public struct NoServerHealth: ServerHealth {
    public init() {}
    public func streamFailed(providerID: ProviderID) async -> Bool { false }
}

/// Keeps each provider on a server link that works.
///
/// Sellers give one login and several addresses because addresses die. The address in use is the
/// provider's `serverURL`, so streams always start on it at once; this actor only checks in the
/// background (at launch, every few hours, after a refresh couldn't connect, and when a stream
/// fails) and moves the provider to the highest link in the user's order that answers. A check is
/// one small `player_api.php` request per link, all links at the same time, so it takes a few
/// seconds at most. It doesn't use one of the account's stream connections.
public actor ServerFailover: ServerHealth {
    public enum Outcome: Sendable, Equatable {
        /// The address in use answers (or is the best one that does).
        case working
        case switched(to: URL)
        /// No link answered.
        case allDown
        /// This Mac is offline: nothing was marked down.
        case offline
        /// Disabled, removed or no saved login.
        case skipped
    }

    private let providers: ProviderRepository
    private let secrets: any SecretStore
    private let transport: any HTTPTransport
    private let clock: any AppClock
    private let userAgent: @Sendable () -> String
    private let probeTimeout: TimeInterval

    private var running: [ProviderID: Task<Outcome, Never>] = [:]
    /// When the address in use last answered; a stream failing soon after isn't the server's fault.
    private var lastAnswered: [ProviderID: Date] = [:]
    static let trustAnswerFor: TimeInterval = 20

    public init(database: AppDatabase, secrets: any SecretStore, transport: any HTTPTransport = URLSessionTransport(),
                clock: any AppClock = SystemClock(), probeTimeout: TimeInterval = 8,
                userAgent: @escaping @Sendable () -> String = { XtreamClient.defaultUserAgent }) {
        providers = ProviderRepository(database: database)
        self.secrets = secrets
        self.transport = transport
        self.clock = clock
        self.probeTimeout = probeTimeout
        self.userAgent = userAgent
    }

    // MARK: Checks

    /// Quick check after something failed: returns as soon as the address in use answers;
    /// otherwise waits for the other links and switches to the first one (in order) that answers.
    @discardableResult
    public func ensureWorking(_ id: ProviderID) async -> Outcome {
        await shared(id) { await self.check(id, preferHigher: false) }
    }

    /// Full check of every link. Also moves back up to a higher link that works again; streams
    /// already playing keep their address, the next one uses the new link.
    @discardableResult
    public func recheck(_ id: ProviderID) async -> Outcome {
        await shared(id) { await self.check(id, preferHigher: true) }
    }

    /// Rechecks every enabled provider (at launch and every few hours).
    public func recheckAll() async {
        let ids = ((try? providers.all()) ?? []).filter(\.isEnabled).map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { _ = await self.recheck(id) } }
        }
    }

    /// Rechecks only providers whose links are all down, so they recover soon after a link returns.
    public func recheckAllDown() async {
        let ids = ((try? providers.all()) ?? []).filter(\.isEnabled).map(\.id)
            .filter { ((try? providers.links(for: $0)) ?? []).allDown }
        for id in ids { _ = await recheck(id) }
    }

    public func streamFailed(providerID id: ProviderID) async -> Bool {
        if let answered = lastAnswered[id], clock.now().timeIntervalSince(answered) < Self.trustAnswerFor { return false }
        if case .switched = await ensureWorking(id) { return true }
        return false
    }

    /// One check per provider at a time; callers arriving meanwhile get its result.
    private func shared(_ id: ProviderID, _ work: @escaping @Sendable () async -> Outcome) async -> Outcome {
        if let running = running[id] { return await running.value }
        let task = Task { await work() }
        running[id] = task
        let outcome = await task.value
        running[id] = nil
        return outcome
    }

    private func check(_ id: ProviderID, preferHigher: Bool) async -> Outcome {
        guard let provider = try? providers.provider(id: id), provider.isEnabled,
              let credentials = try? secrets.load(for: id),
              let links = try? providers.links(for: id), !links.isEmpty
        else { return .skipped }
        let active = provider.serverURL
        let agent = provider.userAgentOverride ?? userAgent()

        // Every link at once. Unless looking for a higher link, stop as soon as the answer is
        // known: the link in use logs in, or it doesn't and every link above the first one that
        // logs in has failed.
        var results: [URL: Probe] = [:]
        await withTaskGroup(of: (URL, Probe).self) { group in
            for link in links {
                group.addTask { (link.url, await self.probe(link.url, credentials: credentials, userAgent: agent)) }
            }
            for await (url, result) in group {
                results[url] = result
                if !preferHigher, let current = results[active],
                   current == .up(loggedIn: true) || Self.decided(links, results) {
                    group.cancelAll()
                    break
                }
            }
        }
        if results.values.contains(.offline) && !results.values.contains(where: \.isUp) {
            Log.app.notice("Server check for \(id, privacy: .public) skipped: offline")
            return .offline
        }

        let now = clock.now()
        for (url, result) in results {
            switch result {
            case .up: try? providers.recordCheck(id, url: url, at: now, failure: nil)
            case .down(let reason): try? providers.recordCheck(id, url: url, at: now, failure: reason)
            case .offline, .cancelled: break
            }
        }
        if results[active]?.isUp == true { lastAnswered[id] = now }

        // A link that accepts the login beats one that only answers: "wrong password" from one link
        // while another logs in means that address now belongs to someone else's panel. When none
        // logs in (wrong password, expired) it's the account, so stay on the address in use.
        let loggedIn = links.first { results[$0.url] == .up(loggedIn: true) }?.url
        let answered = links.first { results[$0.url]?.isUp == true }?.url
        let best = loggedIn ?? (results[active]?.isUp == true ? active : answered)
        if results[active] == .up(loggedIn: true), !preferHigher || best == active { return .working }
        guard let best else {
            Log.app.error("No server link answers for \(id, privacy: .public) (\(links.count) links)")
            return .allDown
        }
        guard best != active else { return .working }
        try? providers.setActive(best, for: id)
        lastAnswered[id] = now
        Log.app.notice("Provider \(id, privacy: .public) switched to server link \(links.firstIndex { $0.url == best }.map { $0 + 1 } ?? 0)")
        return .switched(to: best)
    }

    /// True once a link logs in and every link above it has failed: nothing better can turn up.
    static func decided(_ links: [ServerLink], _ results: [URL: Probe]) -> Bool {
        for link in links {
            switch results[link.url] {
            case .up(loggedIn: true): return true
            case .down?: continue
            default: return false
            }
        }
        return false
    }

    // MARK: Probe

    enum Probe: Equatable, Sendable {
        /// The server answered; `loggedIn` is false for answers like "wrong password" or "expired".
        case up(loggedIn: Bool)
        case down(String)
        case offline
        case cancelled

        var isUp: Bool { if case .up = self { true } else { false } }
    }

    /// Asks the server for the account. Any real answer, even "wrong password" or "expired", means
    /// the server is up: those are the same on every link, so switching wouldn't help. Gives up
    /// after a little more than the request timeout even if the server keeps trickling bytes.
    private func probe(_ url: URL, credentials: ProviderCredentials, userAgent: String) async -> Probe {
        var configured = XtreamClient(serverURL: url, credentials: credentials, transport: transport, userAgent: userAgent)
        configured.requestTimeout = probeTimeout
        let client = configured
        let deadline = probeTimeout + 2
        return await withTaskGroup(of: Probe?.self) { group in
            group.addTask {
                do {
                    _ = try await client.authenticate()
                    return .up(loggedIn: true)
                } catch let error as XtreamError {
                    return Self.classify(error, credentials: credentials)
                } catch {
                    return Task.isCancelled ? .cancelled
                        : .down(CredentialRedactor.redact(error.localizedDescription, credentials: [credentials]))
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(deadline))
                return Task.isCancelled ? nil : .down("No answer within \(Int(deadline)) seconds")
            }
            var outcome = Probe.cancelled
            for await result in group {
                guard let result else { continue }
                outcome = result
                break
            }
            group.cancelAll()
            return outcome
        }
    }

    static func classify(_ error: XtreamError, credentials: ProviderCredentials) -> Probe {
        switch error {
        case .unauthorized, .accountExpired, .accountNotActive, .maxConnectionsReached, .rateLimited: .up(loggedIn: false)
        case .offline: .offline
        case .cancelled: .cancelled
        default: .down(CredentialRedactor.redact(error.description, credentials: [credentials]))
        }
    }
}
