import Foundation
import IPTVCore
import Observation

/// The app's main player as the bridge drives it: the core's PlaybackController (reconnects,
/// format and provider fallback, server-link failover, network and sleep handling) with a
/// BridgedEngine, plus the zap list (channel up/down, numbers, previous channel). Watching a
/// channel records it in Recents, as on the Mac.
@MainActor
final class BridgePlayer {
    let id: String
    let controller: PlaybackController
    private let environment: AppEnvironment
    private let library: LibraryRepository
    private let catalog: LiveCatalog
    private let emit: @Sendable (BridgeEvent) -> Void
    private var zap = ZapList<ChannelListItem>()

    init(id: String, environment: AppEnvironment, send: @escaping @MainActor (String) -> String?,
         emit: @escaping @Sendable (BridgeEvent) -> Void) {
        self.id = id
        self.environment = environment
        self.emit = emit
        library = LibraryRepository(database: environment.database)
        catalog = LiveCatalog(database: environment.database)
        let dependencies = environment.playbackDependencies(makeEngine: { _ in BridgedEngine(player: id, send: send) })
        controller = PlaybackController(purpose: .main, settings: environment.playbackSettings(engines: [.exoPlayer]),
                                        dependencies: dependencies)
        follow()
    }

    // MARK: Watching

    /// Plays `channelID` from `group`, zapping through that group from now on.
    func watch(channelID: String, group: String) async throws {
        let groups = try await catalog.groups()
        guard let found = groups.first(where: { $0.id == group }) else { throw BridgeError("That group no longer exists.") }
        let channels = try await catalog.channels(in: found)
        guard let channel = channels.first(where: { $0.id == channelID }) else { throw BridgeError("That channel no longer exists.") }
        try play(channel, in: channels)
    }

    func zap(by offset: Int) throws {
        if let next = zap.channel(by: offset) { try play(next, debounce: true) }
    }

    func jump(toNumber number: Int) throws {
        if let match = zap.channel(number: number, numberOf: \.number) { try play(match) }
    }

    func previous() throws {
        if let previous = zap.previous { try play(previous) }
    }

    func stop() async {
        await controller.stop()
        emitState()
    }

    private func play(_ channel: ChannelListItem, in list: [ChannelListItem]? = nil, debounce: Bool = false) throws {
        guard let item = try environment.items.liveItem(providerID: channel.providerID, streamID: channel.streamID) else {
            throw BridgeError("This channel can't be played.")
        }
        zap.watch(channel, in: list)
        controller.play(item, debounce: debounce)
        emitState()
        let library = self.library
        Task { try? await library.recordPlayed(providerID: channel.providerID, kind: .channel, itemID: String(channel.streamID)) }
    }

    // MARK: State

    var state: PlayerStateDTO {
        let phase: String, attempt: Int?, message: String?
        switch controller.phase {
        case .idle: (phase, attempt, message) = ("idle", nil, nil)
        case .connecting: (phase, attempt, message) = ("connecting", nil, nil)
        case .buffering: (phase, attempt, message) = ("buffering", nil, nil)
        case .playing: (phase, attempt, message) = ("playing", nil, nil)
        case .paused: (phase, attempt, message) = ("paused", nil, nil)
        case .reconnecting(let n): (phase, attempt, message) = ("reconnecting", n, nil)
        case .waitingForNetwork: (phase, attempt, message) = ("waitingForNetwork", nil, nil)
        case .suspended: (phase, attempt, message) = ("suspended", nil, nil)
        case .preempted: (phase, attempt, message) = ("preempted", nil, nil)
        case .ended: (phase, attempt, message) = ("ended", nil, nil)
        case .failed(let failure): (phase, attempt, message) = ("failed", nil, CredentialRedactor.redact(failure.message))
        }
        return PlayerStateDTO(player: id, phase: phase, attempt: attempt, message: message, notice: controller.notice,
                              channel: zap.current.map(ChannelDTO.init), provider: controller.plan?.source.providerName,
                              hasPrevious: zap.previous != nil)
    }

    private func emitState() {
        emit(BridgeEvent(type: "player", state: state))
    }

    /// Sends the state whenever the phase, the notice or the source changes.
    private func follow() {
        withObservationTracking {
            _ = controller.phase
            _ = controller.notice
            _ = controller.plan
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.emitState()
                self?.follow()
            }
        }
    }
}

/// The player's state, sent with every `player` event and returned by `player.state`.
public struct PlayerStateDTO: Codable, Equatable, Sendable {
    public var player: String
    /// idle, connecting, buffering, playing, paused, reconnecting, waitingForNetwork, suspended,
    /// preempted, ended or failed.
    public var phase: String
    /// Reconnect attempt, while reconnecting.
    public var attempt: Int?
    /// Why it failed, when failed.
    public var message: String?
    /// A brief notice such as "Now playing from Provider B".
    public var notice: String?
    public var channel: ChannelDTO?
    /// The provider the stream comes from.
    public var provider: String?
    public var hasPrevious: Bool
}
