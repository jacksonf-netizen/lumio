import Foundation
import Observation

/// What the player is doing, for the UI. See Docs/reconnect-state-machine.md.
public enum PlaybackPhase: Sendable, Equatable {
    case idle
    /// Getting a connection slot and opening the stream.
    case connecting
    case buffering
    case playing
    case paused
    /// Recovering automatically: show a small, non-blocking indicator.
    case reconnecting(attempt: Int)
    case waitingForNetwork
    /// Mac went to sleep; resumes on wake.
    case suspended
    /// Gave its connection to another player (e.g. the preview pane when full-screen starts).
    case preempted
    /// A movie or episode reached its end.
    case ended
    case failed(PlaybackFailure)

    public var isActive: Bool {
        switch self {
        case .idle, .preempted, .ended, .failed: false
        default: true
        }
    }

    public var isRecovering: Bool {
        switch self {
        case .reconnecting, .waitingForNetwork, .suspended: true
        default: false
        }
    }
}

public struct PlaybackFailure: Sendable, Equatable {
    public var message: String
    /// True when the failure was "no free connection anywhere" rather than a broken stream.
    public var noConnection: Bool

    public init(message: String, noConnection: Bool = false) {
        self.message = message
        self.noConnection = noConnection
    }
}

/// Everything the controller depends on, injected so tests can control time, engines and slots.
public struct PlaybackDependencies: Sendable {
    public var connections: ConnectionManager
    public var resolver: any StreamURLResolver
    public var history: any PlaybackHistoryStore
    public var systemEvents: any SystemEventSource
    public var clock: any AppClock
    public var makeEngine: @MainActor @Sendable (EngineKind) -> any PlaybackEngine
    /// Jitter source in [0, 1).
    public var random: @Sendable () -> Double

    public init(connections: ConnectionManager, resolver: any StreamURLResolver,
                history: any PlaybackHistoryStore = NoPlaybackHistory(),
                systemEvents: any SystemEventSource = NoSystemEvents(), clock: any AppClock = SystemClock(),
                makeEngine: @escaping @MainActor @Sendable (EngineKind) -> any PlaybackEngine,
                random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.connections = connections
        self.resolver = resolver
        self.history = history
        self.systemEvents = systemEvents
        self.clock = clock
        self.makeEngine = makeEngine
        self.random = random
    }
}

/// Owns one playback "slot" in the UI (main player, preview pane, or a multiview tile) and keeps
/// it playing: connection-slot leasing, stall watchdog, reconnect with backoff, fallback across
/// formats, engines and providers, network loss and sleep/wake.
@MainActor
@Observable
public final class PlaybackController {
    // MARK: Observable state

    public private(set) var phase: PlaybackPhase = .idle
    public private(set) var item: PlaybackItem?
    /// The rung currently being played or tried.
    public private(set) var plan: PlaybackPlan?
    /// Engine whose view should be on screen.
    public private(set) var engine: (any PlaybackEngine)?
    /// Automatic reconnects and fallbacks in this session (diagnostics).
    public private(set) var reconnectCount = 0
    /// Brief message such as "Switched to Provider B". Cleared automatically.
    public private(set) var notice: String?
    public private(set) var metrics: PlaybackMetrics?
    /// Current stream URL with credentials masked (diagnostics).
    public private(set) var redactedURL: String?
    public private(set) var lastError: String?
    /// Why the most recent attempt failed (shown in diagnostics even while recovering).
    public private(set) var lastAttemptError: String?
    /// Bumped when the engine reports new audio/subtitle tracks.
    public private(set) var tracksVersion = 0

    public var settings: PlaybackSettings
    public let purpose: ConnectionPurpose

    public var volume: Double = 1 {
        didSet { engine?.volume = volume }
    }

    public var isMuted = false {
        didSet { engine?.isMuted = isMuted }
    }

    // MARK: Internals

    @ObservationIgnored private let deps: PlaybackDependencies
    @ObservationIgnored private var engines: [EngineKind: any PlaybackEngine] = [:]
    @ObservationIgnored private var engineConsumers: [Task<Void, Never>] = []
    @ObservationIgnored private var systemConsumer: Task<Void, Never>?
    @ObservationIgnored private var session: Task<Void, Never>?
    @ObservationIgnored private var inbox: Mailbox<Input>?
    @ObservationIgnored private var currentLoad: (kind: EngineKind, id: Int)?
    @ObservationIgnored private var lease: ConnectionLease?
    @ObservationIgnored private var networkAvailable = true
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    private enum Input: Sendable {
        case engine(EngineEvent.Kind)
        case tick
        case network(Bool)
        case sleep
        case wake
    }

    private enum AttemptOutcome {
        case cancelled
        case failed(EngineFailure, playedFor: Double)
        case networkLost
        case suspended
        case ended
    }

    public init(purpose: ConnectionPurpose, settings: PlaybackSettings = PlaybackSettings(), dependencies: PlaybackDependencies) {
        self.purpose = purpose
        self.settings = settings
        deps = dependencies
        let events = dependencies.systemEvents.events()
        systemConsumer = Task { [weak self] in
            for await event in events {
                self?.handleSystemEvent(event)
            }
        }
    }

    /// Stops playback and releases engines. Call when the owning view goes away for good.
    public func shutdown() async {
        await stop()
        systemConsumer?.cancel()
        engineConsumers.forEach { $0.cancel() }
        engines.values.forEach { $0.shutdown() }
        engines.removeAll()
        engine = nil
    }

    // MARK: Commands

    /// Plays `item`, replacing whatever is playing. The previous stream is fully closed (and its
    /// connection slot released) before the new one opens. With `debounce`, opening waits briefly so
    /// zapping through channels doesn't open a stream for every channel passed.
    public func play(_ item: PlaybackItem, debounce: Bool = false) {
        let previous = session
        previous?.cancel()
        self.item = item
        reconnectCount = 0
        lastError = nil
        setNotice(nil)
        transition(to: .connecting, reason: "play \(item.title)")
        session = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            if debounce {
                do { try await self.deps.clock.sleep(for: .seconds(self.settings.zapDebounce)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await self.runSession(item)
        }
    }

    /// Stops playback and releases the connection. Returns once the stream is closed.
    public func stop() async {
        let previous = session
        session = nil
        previous?.cancel()
        await previous?.value
        await closeStream()
        item = nil
        plan = nil
        redactedURL = nil
        metrics = nil
        transition(to: .idle, reason: "stop")
    }

    /// Starts over after a failure, with a fresh attempt budget.
    public func retry() {
        guard let item else { return }
        play(item)
    }

    public func pause() {
        engine?.pause()
    }

    public func resume() {
        engine?.play()
    }

    public func seek(to seconds: Double) {
        engine?.seek(to: seconds)
    }

    public func tracks() -> [MediaTrack] {
        engine?.tracks() ?? []
    }

    public func select(_ track: MediaTrack?, kind: MediaTrack.Kind) {
        engine?.select(track, kind: kind)
        tracksVersion += 1
    }

    /// Whether this controller currently holds a connection slot.
    public var holdsConnection: Bool { lease != nil }

    // MARK: Session

    private func runSession(_ item: PlaybackItem) async {
        let mailbox = Mailbox<Input>()
        inbox = mailbox
        let clock = deps.clock
        let interval = settings.watchdogInterval
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                do { try await clock.sleep(for: .seconds(interval)) } catch { return }
                mailbox.post(.tick)
            }
        }

        await drive(item, mailbox)

        ticker.cancel()
        mailbox.close()
        // The next session only starts after this one returns, so this inbox is still ours.
        inbox = nil
        await closeStream()
    }

    private func drive(_ item: PlaybackItem, _ mailbox: Mailbox<Input>) async {
        let plans = await rankedPlans(for: item)
        guard !plans.isEmpty else {
            fail(PlaybackFailure(message: "This item has no playable source. Its provider may be disabled."))
            return
        }

        var index = 0
        var lastFailure: EngineFailure?
        var noSlot = false

        rungs: while index < plans.count {
            if Task.isCancelled { return }
            let plan = plans[index]
            self.plan = plan

            if lease?.providerID != plan.source.providerID {
                await closeStream()
                if Task.isCancelled { return }
                if index > 0 {
                    reconnectCount += 1
                    let name = plan.source.providerName.isEmpty ? "another provider" : plan.source.providerName
                    setNotice("Switching to \(name)…")
                    Log.playback.notice("Failover to \(plan.description, privacy: .public)")
                }
                do {
                    lease = try await deps.connections.acquire(
                        plan.source.providerID, purpose: purpose,
                        onPreempt: { [weak self] in await self?.handlePreemption() })
                } catch {
                    if Task.isCancelled { return }
                    noSlot = true
                    Log.playback.notice("No slot on \(plan.source.providerID, privacy: .public) for \(self.purpose.description, privacy: .public)")
                    index = plans[(index + 1)...].firstIndex { $0.source.providerID != plan.source.providerID } ?? plans.count
                    continue rungs
                }
                if Task.isCancelled { return }
            }

            var attempt = 0
            attempts: while attempt < settings.attemptsPerRung {
                if Task.isCancelled { return }
                if !networkAvailable {
                    transition(to: .waitingForNetwork, reason: "network down")
                    guard await waitForNetwork(mailbox) else { return }
                }
                let outcome = await runAttempt(plan, item: item, isRetry: attempt > 0 || index > 0, mailbox)
                if Task.isCancelled { return }

                switch outcome {
                case .cancelled:
                    return
                case .ended:
                    transition(to: .ended, reason: "end of media")
                    return
                case .suspended:
                    await closeStream()
                    transition(to: .suspended, reason: "system sleep")
                    guard await waitForWake(mailbox) else { return }
                    // Re-acquire the slot and restart this rung with a fresh budget.
                    continue rungs
                case .networkLost:
                    await stopEngine()
                    transition(to: .waitingForNetwork, reason: "network lost")
                    guard await waitForNetwork(mailbox) else { return }
                    reconnectCount += 1
                    transition(to: .reconnecting(attempt: 1), reason: "network back")
                case .failed(var failure, let playedFor):
                    // Engine messages are shown and logged; make sure no credentials ride along.
                    failure.detail = CredentialRedactor.redact(failure.detail,
                                                               credentials: deps.resolver.redactionCredentials(for: plan.source.providerID))
                    lastFailure = failure
                    lastAttemptError = failure.description
                    await stopEngine()
                    if Task.isCancelled { return }
                    let wasWorking = playedFor >= settings.stableAfter
                    if wasWorking { attempt = 0 }
                    Log.playback.error("""
                        Attempt \(attempt + 1) of \(plan.description, privacy: .public) failed after \
                        \(Int(playedFor))s: \(failure.description, privacy: .public)
                        """)
                    if failure.skipsToNextRung {
                        await deps.history.recordFailure(plan, error: failure)
                        if failure.providerRefused,
                           let otherProvider = plans[(index + 1)...].firstIndex(where: { $0.source.providerID != plan.source.providerID }) {
                            Log.playback.notice("Provider refused \(plan.description, privacy: .public); skipping its other fallbacks")
                            index = otherProvider
                            transition(to: .reconnecting(attempt: 0), reason: "provider refused stream")
                            continue rungs
                        }
                        break attempts
                    }
                    attempt += 1
                    if attempt >= settings.attemptsPerRung {
                        await deps.history.recordFailure(plan, error: failure)
                        break attempts
                    }
                    reconnectCount += 1
                    transition(to: .reconnecting(attempt: attempt), reason: failure.description)
                    let delay = wasWorking ? 0.5 : settings.backoff(attempt: attempt, jitter: deps.random())
                    do { try await deps.clock.sleep(for: .seconds(delay)) } catch { return }
                }
            }
            index += 1
            if index < plans.count, !Task.isCancelled {
                transition(to: .reconnecting(attempt: 0), reason: "next fallback: \(plans[index].description)")
            }
        }

        if noSlot && lastFailure == nil {
            fail(PlaybackFailure(message: ConnectionError.noProviderAvailable.description, noConnection: true))
        } else {
            fail(PlaybackFailure(message: lastFailure?.description ?? "Playback failed."))
        }
    }

    /// One try of one rung: open the stream and supervise it until it fails, ends, or is cancelled.
    private func runAttempt(_ plan: PlaybackPlan, item: PlaybackItem, isRetry: Bool,
                            _ mailbox: Mailbox<Input>) async -> AttemptOutcome {
        let engine = await attachEngine(plan.engine)
        if Task.isCancelled { return .cancelled }

        let url: URL
        do {
            url = try deps.resolver.url(for: plan.source, content: item.content, format: plan.format)
        } catch {
            return .failed(EngineFailure(.unsupported, "can't build the stream URL: \(error)"), playedFor: 0)
        }
        let credentials = deps.resolver.redactionCredentials(for: plan.source.providerID)
        redactedURL = CredentialRedactor.redact(url, credentials: credentials)

        let request = EngineRequest(url: url, isLive: item.isLive, startPosition: item.startPosition,
                                    userAgent: deps.resolver.userAgent(for: plan.source.providerID),
                                    buffer: settings.buffer)
        let loadID = engine.load(request)
        currentLoad = (plan.engine, loadID)
        if !isRetry { transition(to: .connecting, reason: "open \(plan.description)") }
        Log.playback.info("Load #\(loadID) \(plan.description, privacy: .public) \(self.redactedURL ?? "", privacy: .public)")

        let clock = deps.clock
        let openedAt = clock.now()
        var playingSince: Date?
        var lastProgressAt = openedAt
        var lastPosition: Double?
        var lastBuffer: Double?
        var lastBytes: Int64?

        func playedFor() -> Double { playingSince.map { clock.now().timeIntervalSince($0) } ?? 0 }

        while let input = await mailbox.next() {
            if Task.isCancelled { return .cancelled }
            switch input {
            case .engine(let event):
                switch event {
                case .playing:
                    lastProgressAt = clock.now()
                    if playingSince == nil {
                        playingSince = clock.now()
                        let elapsed = clock.now().timeIntervalSince(openedAt)
                        Log.playback.info("First frame after \(elapsed, format: .fixed(precision: 2))s on \(plan.description, privacy: .public)")
                        let history = deps.history
                        Task { await history.recordSuccess(plan) }
                        if notice?.hasPrefix("Switching") == true {
                            setNotice("Now playing from \(plan.source.providerName.isEmpty ? "backup provider" : plan.source.providerName)")
                        }
                    }
                    transition(to: .playing, reason: "engine playing")
                case .buffering(let buffering):
                    if playingSince != nil, phase != .paused {
                        transition(to: buffering ? .buffering : .playing, reason: buffering ? "buffering" : "buffered")
                    }
                case .paused:
                    transition(to: .paused, reason: "paused")
                case .endOfStream:
                    if item.isLive {
                        return networkAvailable ? .failed(EngineFailure(.endOfStream), playedFor: playedFor()) : .networkLost
                    }
                    return .ended
                case .failed(let failure):
                    return networkAvailable ? .failed(failure, playedFor: playedFor()) : .networkLost
                case .tracksChanged:
                    tracksVersion += 1
                }

            case .tick:
                let now = clock.now()
                let sample = engine.metrics()
                metrics = sample
                if playingSince == nil {
                    if now.timeIntervalSince(openedAt) >= settings.openTimeout {
                        return networkAvailable ? .failed(EngineFailure(.timeout), playedFor: 0) : .networkLost
                    }
                } else if phase != .paused {
                    let positionMoved = (sample.position ?? -1) > (lastPosition ?? -1) + 0.01
                    let bufferGrew = (sample.bufferSeconds ?? 0) > (lastBuffer ?? 0) + 0.01
                    let bytesGrew = (sample.bytesReceived ?? 0) > (lastBytes ?? 0)
                    lastPosition = sample.position ?? lastPosition
                    lastBuffer = sample.bufferSeconds ?? lastBuffer
                    lastBytes = sample.bytesReceived ?? lastBytes
                    if positionMoved || bufferGrew || bytesGrew {
                        lastProgressAt = now
                    } else if now.timeIntervalSince(lastProgressAt) >= settings.stallTimeout {
                        return networkAvailable
                            ? .failed(EngineFailure(.stalled, "no data for \(Int(settings.stallTimeout))s"), playedFor: playedFor())
                            : .networkLost
                    }
                }

            case .network(let available):
                if !available { Log.playback.notice("Network down while playing") }
            case .sleep:
                return .suspended
            case .wake:
                break
            }
        }
        return .cancelled
    }

    // MARK: Waiting

    /// Returns false if the session was cancelled while waiting.
    private func waitForNetwork(_ mailbox: Mailbox<Input>) async -> Bool {
        if networkAvailable { return true }
        while let input = await mailbox.next() {
            if Task.isCancelled { return false }
            if case .network(true) = input { return true }
            if case .wake = input, networkAvailable { return true }
        }
        return false
    }

    private func waitForWake(_ mailbox: Mailbox<Input>) async -> Bool {
        while let input = await mailbox.next() {
            if Task.isCancelled { return false }
            if case .wake = input { return true }
        }
        return false
    }

    // MARK: Engines and connections

    private func attachEngine(_ kind: EngineKind) async -> any PlaybackEngine {
        if let current = engine, current.kind != kind {
            await current.stop()
        }
        let target: any PlaybackEngine
        if let existing = engines[kind] {
            target = existing
        } else {
            let created = deps.makeEngine(kind)
            engines[kind] = created
            let events = created.events
            engineConsumers.append(Task { [weak self] in
                for await event in events {
                    self?.receive(event, from: kind)
                }
            })
            target = created
        }
        target.volume = volume
        target.isMuted = isMuted
        engine = target
        return target
    }

    private func receive(_ event: EngineEvent, from kind: EngineKind) {
        guard let currentLoad, currentLoad.kind == kind, currentLoad.id == event.loadID else { return }
        inbox?.post(.engine(event.kind))
    }

    private func stopEngine() async {
        currentLoad = nil
        await engine?.stop()
    }

    /// Stops the stream and gives the connection slot back.
    private func closeStream() async {
        await stopEngine()
        if let lease {
            self.lease = nil
            await deps.connections.release(lease)
        }
    }

    /// Another player needs our slot: stop now and wait for the stream to close.
    private func handlePreemption() async {
        Log.playback.notice("\(self.purpose.description, privacy: .public) preempted")
        let current = session
        session = nil
        lease = nil // already reassigned by the ConnectionManager
        current?.cancel()
        await current?.value
        await stopEngine()
        transition(to: .preempted, reason: "connection needed elsewhere")
    }

    private func handleSystemEvent(_ event: SystemEvent) {
        switch event {
        case .network(let available):
            networkAvailable = available
            inbox?.post(.network(available))
        case .willSleep:
            inbox?.post(.sleep)
        case .didWake:
            inbox?.post(.wake)
        }
    }

    /// Orders sources by free capacity, priority and reliability, then expands them into the ladder.
    private func rankedPlans(for item: PlaybackItem) async -> [PlaybackPlan] {
        var sources = item.sources
        if let pinned = item.pinnedProviderID { sources = sources.filter { $0.providerID == pinned } }
        var capacity: [ProviderID: Int] = [:]
        for source in sources where capacity[source.providerID] == nil {
            var available = await deps.connections.available(on: source.providerID)
            // A slot we already hold counts as available for us.
            if lease?.providerID == source.providerID { available += 1 }
            capacity[source.providerID] = available
        }
        let candidates = sources.map {
            SourceCandidate(providerID: $0.providerID, streamID: $0.streamID ?? 0,
                            providerPriority: $0.providerPriority, reliability: $0.reliability)
        }
        let order = SourceSelector.rank(candidates, capacity: capacity)
        let ranked = order.compactMap { candidate in
            sources.first { $0.providerID == candidate.providerID && ($0.streamID ?? 0) == candidate.streamID }
        }
        var ordered = item
        ordered.sources = ranked
        return FallbackLadder.plans(for: ordered, defaultEngine: settings.defaultEngine, defaultFormat: settings.defaultFormat)
    }

    // MARK: State

    private func transition(to newPhase: PlaybackPhase, reason: String) {
        guard newPhase != phase else { return }
        Log.playback.info("[\(self.purpose.description, privacy: .public)] \(String(describing: self.phase), privacy: .public) → \(String(describing: newPhase), privacy: .public) (\(CredentialRedactor.redact(reason), privacy: .public))")
        phase = newPhase
    }

    private func fail(_ failure: PlaybackFailure) {
        guard !Task.isCancelled else { return }
        lastError = failure.message
        transition(to: .failed(failure), reason: failure.message)
    }

    private func setNotice(_ text: String?) {
        noticeTask?.cancel()
        notice = text
        guard text != nil else { return }
        let clock = deps.clock
        noticeTask = Task { [weak self] in
            do { try await clock.sleep(for: .seconds(5)) } catch { return }
            self?.notice = nil
        }
    }
}

/// Single-consumer queue on the main actor. `next()` returns nil when closed or when the waiting
/// task is cancelled.
@MainActor
final class Mailbox<Element: Sendable> {
    private var buffer: [Element] = []
    private var waiter: CheckedContinuation<Element?, Never>?
    private var closed = false

    func post(_ element: Element) {
        guard !closed else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: element)
        } else {
            buffer.append(element)
        }
    }

    func close() {
        closed = true
        buffer.removeAll()
        resumeWaiter(with: nil)
    }

    func next() async -> Element? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if closed || Task.isCancelled { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeWaiter(with: nil) }
        }
    }

    private func resumeWaiter(with element: Element?) {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(returning: element)
    }
}
