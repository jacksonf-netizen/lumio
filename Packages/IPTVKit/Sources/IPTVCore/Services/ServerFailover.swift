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
/// one small `player_api.php` request per link, one link at a time: a seller's addresses often
/// lead to the same server, and panels with flood protection answer a burst of requests with
/// "not found". It doesn't use one of the account's stream connections.
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
    /// Pause after each request a server answered, so a check never looks like a flood. "Not
    /// found" is asked again after three of these (flood protection lets go within seconds).
    private let pacing: TimeInterval

    private var running: [ProviderID: Task<Outcome, Never>] = [:]
    /// When the address in use last answered; a stream failing soon after isn't the server's fault.
    private var lastAnswered: [ProviderID: Date] = [:]
    static let trustAnswerFor: TimeInterval = 20

    public init(database: AppDatabase, secrets: any SecretStore, transport: any HTTPTransport = URLSessionTransport(),
                clock: any AppClock = SystemClock(), probeTimeout: TimeInterval = 8, pacing: TimeInterval = 1,
                userAgent: @escaping @Sendable () -> String = { XtreamClient.defaultUserAgent }) {
        providers = ProviderRepository(database: database)
        self.secrets = secrets
        self.transport = transport
        self.clock = clock
        self.probeTimeout = probeTimeout
        self.pacing = pacing
        self.userAgent = userAgent
    }

    // MARK: Checks

    /// Quick check after something failed: asks the address in use first and stops there if it
    /// logs in; otherwise asks the others in order and switches to the first one that logs in.
    @discardableResult
    public func ensureWorking(_ id: ProviderID) async -> Outcome {
        await shared(id) { await self.check(id, preferHigher: false) }
    }

    /// Full check of every link that isn't dead. Also moves back up to a higher link that works
    /// again; streams already playing keep their address, the next one uses the new link.
    /// `includingDead` (Refresh in Settings) tries dead links too.
    @discardableResult
    public func recheck(_ id: ProviderID, includingDead: Bool = false) async -> Outcome {
        await shared(id) { await self.check(id, preferHigher: true, includingDead: includingDead) }
    }

    /// Rechecks every enabled provider (at launch and every few hours).
    public func recheckAll(includingDead: Bool = false) async {
        let ids = ((try? providers.all()) ?? []).filter(\.isEnabled).map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { _ = await self.recheck(id, includingDead: includingDead) } }
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

    private func check(_ id: ProviderID, preferHigher: Bool, includingDead: Bool = false) async -> Outcome {
        guard let provider = try? providers.provider(id: id), provider.isEnabled,
              let credentials = try? secrets.load(for: id),
              let all = try? providers.links(for: id), !all.isEmpty
        else { return .skipped }
        let links = includingDead ? all : Self.linksToCheck(all, now: clock.now())
        // Every link is dead and had its daily try already.
        guard !links.isEmpty else { return .allDown }
        let active = provider.serverURL
        let agent = provider.userAgentOverride ?? userAgent()

        // One link at a time. A quick check starts with the address in use and stops at the first
        // link that logs in; a full check asks every link, in the user's order.
        let order = preferHigher ? links : links.filter { $0.url == active } + links.filter { $0.url != active }
        var results: [URL: Probe] = [:]
        for (index, link) in order.enumerated() {
            if Task.isCancelled { return .skipped }
            let (result, answered) = await probe(link.url, credentials: credentials, userAgent: agent)
            results[link.url] = result
            if !preferHigher, result == .up(loggedIn: true) { break }
            if answered, index < order.count - 1 { try? await Task.sleep(for: .seconds(pacing)) }
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

    /// The links an automatic check tries: not dead ones (down for a day), unless none of the others
    /// work. Then the dead ones get one try a day, so a seller's outage that lasted more than a day
    /// doesn't leave the provider stuck after it ends.
    static func linksToCheck(_ links: [ServerLink], now: Date) -> [ServerLink] {
        let alive = links.filter { !$0.isDead }
        guard alive.allSatisfy(\.isDown) else { return alive }
        let lastTry = links.filter(\.isDead).compactMap(\.lastCheckedAt).max()
        if let lastTry, now.timeIntervalSince(lastTry) < ServerLink.deadAfter { return alive }
        return links
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
    /// the server is up: those are the same on every link, so switching wouldn't help. "Not found"
    /// may be flood protection, so it's asked once more after a pause. `answered` is whether the
    /// request reached a server (then the next one waits a moment).
    private func probe(_ url: URL, credentials: ProviderCredentials, userAgent: String) async -> (Probe, answered: Bool) {
        var configured = XtreamClient(serverURL: url, credentials: credentials, transport: transport, userAgent: userAgent)
        configured.requestTimeout = probeTimeout
        let client = configured
        var error = await ask(client)
        if error == .notFound {
            try? await Task.sleep(for: .seconds(3 * pacing))
            error = await ask(client)
        }
        guard let error else { return (.up(loggedIn: true), true) }
        return (Self.classify(error, credentials: credentials), Self.reachedServer(error))
    }

    /// One account request; nil when it logged in. Gives up after a little more than the request
    /// timeout even if the server keeps trickling bytes.
    private func ask(_ client: XtreamClient) async -> XtreamError? {
        let deadline = probeTimeout + 2
        return await withTaskGroup(of: XtreamError??.self) { group in
            group.addTask {
                do {
                    _ = try await client.authenticate()
                    return .some(nil)
                } catch {
                    return .some(Task.isCancelled ? .cancelled : XtreamError.from(error))
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(deadline))
                return Task.isCancelled ? nil : .some(.timeout)
            }
            var outcome: XtreamError? = .cancelled
            for await result in group {
                guard let result else { continue }
                outcome = result
                break
            }
            group.cancelAll()
            return outcome
        }
    }

    static func reachedServer(_ error: XtreamError) -> Bool {
        switch error {
        case .timeout, .offline, .cannotConnect, .cancelled: false
        default: true
        }
    }

    /// Down means nothing answers there: no such address, no connection, a timeout, "not found"
    /// twice, a page that isn't a panel, or a gateway saying the server behind it is down. Other
    /// refusals are a server answering (panels use odd codes, like 511 or 513 for a bad login).
    static func classify(_ error: XtreamError, credentials: ProviderCredentials) -> Probe {
        switch error {
        case .unauthorized, .accountExpired, .accountNotActive, .maxConnectionsReached, .rateLimited, .forbidden,
             .httpStatus:
            .up(loggedIn: false)
        case .server(let code) where !serverDownCodes.contains(code):
            .up(loggedIn: false)
        case .offline: .offline
        case .cancelled: .cancelled
        default: .down(CredentialRedactor.redact(error.description, credentials: [credentials]))
        }
    }

    /// 5xx codes that mean the server (or the one behind a gateway like Cloudflare) isn't working.
    static let serverDownCodes: Set<Int> = [500, 502, 503, 504, 520, 521, 522, 523, 524, 525, 526, 530]
}
