import Foundation
import IPTVCore
import Observation

// Multiview over the bridge: `multiview.*` requests and `multiview` events. The tiles are the
// shared MultiviewSession (the Mac's too): each tile is a PlaybackController with its own engine in
// the app ("tile0" to "tile3"), and SourceSelector spreads the tiles across providers so no
// provider is asked for more streams than it allows.
//
// How many tiles a device can decode is the app's business (it reads the decoder's limits); the
// core accepts 2 to 4.

/// One tile, as the app shows it.
public struct TileDTO: Codable, Equatable, Sendable {
    public var index: Int
    public var channel: ChannelDTO?
    /// The Live TV group the channel was picked from, so it can be watched full screen from there.
    public var group: String?
    /// As `PlayerStateDTO.phase`.
    public var phase: String
    public var attempt: Int?
    /// Why it failed, when failed.
    public var message: String?
    public var notice: String?
    /// The provider the tile plays from.
    public var provider: String?
    public var providerID: String?
    /// The provider chosen for this tile; nil for automatic.
    public var pinned: String?
    /// Every provider carrying the channel, for choosing one.
    public var providers: [ProviderChoiceDTO]
}

public struct ProviderChoiceDTO: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
}

/// Sent with every `multiview` event and returned by every `multiview.*` request.
public struct MultiviewStateDTO: Codable, Equatable, Sendable {
    public var active: Bool
    /// 2, 3 or 4.
    public var layout: Int
    /// The tile whose sound plays.
    public var audioTile: Int
    /// Some tile has no free connection on any provider.
    public var warning: String?
    /// The tiles in the layout, in order.
    public var tiles: [TileDTO]
}

@MainActor
final class BridgeMultiview {
    let session: MultiviewSession
    private let emit: @Sendable (BridgeEvent) -> Void
    private let environment: AppEnvironment
    /// The group each channel was picked from, by channel id.
    private var groups: [String: String] = [:]

    init(environment: AppEnvironment, send: @escaping @MainActor (String) -> String?, emit: @escaping @Sendable (BridgeEvent) -> Void) {
        self.environment = environment
        self.emit = emit
        session = MultiviewSession(environment: environment, layout: 2) { index in
            let dependencies = environment.playbackDependencies(makeEngine: { _ in BridgedEngine(player: "tile\(index)", send: send) })
            return PlaybackController(purpose: .tile(index), settings: environment.playbackSettings(engines: [.exoPlayer]),
                                      dependencies: dependencies)
        }
        follow()
    }

    /// Opens multiview with `layout` tiles, `channel` (if any) in the first empty one. The app's
    /// other players stop first.
    func start(layout: Int, channel: ChannelListItem?, group: String?, stopOthers: @escaping @MainActor () async -> Void) throws {
        try check(layout: layout)
        if session.layout != layout { session.layout = layout }
        if let channel, let group { groups[channel.id] = group }
        session.start(with: channel, stopOthers: stopOthers)
        emitState()
    }

    func setLayout(_ layout: Int) throws {
        try check(layout: layout)
        session.layout = layout
    }

    func setChannel(_ channel: ChannelListItem, group: String?, tile: Int) throws {
        try check(tile: tile)
        if let group { groups[channel.id] = group }
        session.setChannel(channel, forTile: tile)
    }

    func clearTile(_ tile: Int) throws {
        try check(tile: tile)
        session.clearTile(tile)
    }

    func pin(_ provider: ProviderID?, tile: Int) throws {
        try check(tile: tile)
        if let provider, !session.providers(forTile: tile).contains(provider) {
            throw BridgeError("That provider doesn't carry this channel.")
        }
        session.pinProvider(provider, forTile: tile)
    }

    func focusAudio(_ tile: Int) throws {
        try check(tile: tile)
        session.focusAudio(tile)
    }

    /// Tries a failed tile again.
    func retry(_ tile: Int) async throws {
        try check(tile: tile)
        await session.tiles[tile].controller.retry()
    }

    /// Returns once every tile's stream is closed, so a full-screen player started next can't push
    /// a provider over its connection limit.
    func stop() async {
        await session.stopAll()
        emitState()
    }

    func reloadSettings() {
        for tile in session.tiles { tile.controller.settings = environment.playbackSettings(engines: [.exoPlayer]) }
    }

    private func check(layout: Int) throws {
        guard (2...4).contains(layout) else { throw BridgeError("Multiview has 2 to 4 tiles.") }
    }

    private func check(tile: Int) throws {
        guard (0..<session.layout).contains(tile) else { throw BridgeError("There's no tile \(tile + 1).") }
    }

    // MARK: State

    var state: MultiviewStateDTO {
        let names = Dictionary(((try? environment.providers.repository.all()) ?? []).map { ($0.id, $0.name) }) { first, _ in first }
        return MultiviewStateDTO(
            active: session.isActive, layout: session.layout, audioTile: session.audioTile, warning: session.warning,
            tiles: session.visibleTiles.map { tile in
                let (phase, attempt, message) = PhaseText.of(tile.controller.phase)
                return TileDTO(
                    index: tile.index, channel: tile.channel.map(ChannelDTO.init), group: tile.channel.flatMap { groups[$0.id] },
                    phase: phase, attempt: attempt, message: message, notice: tile.controller.notice,
                    provider: tile.controller.plan?.source.providerName ?? tile.assignedProvider.flatMap { names[$0] },
                    providerID: tile.assignedProvider?.rawValue, pinned: tile.pinnedProvider?.rawValue,
                    providers: (tile.channel?.sourceProviders ?? []).map { ProviderChoiceDTO(id: $0.rawValue, name: names[$0] ?? $0.rawValue) })
            })
    }

    private func emitState() {
        emit(BridgeEvent(type: "multiview", multiview: state))
    }

    /// Sends the state whenever the tiles, the layout, the audio or any tile's player changes.
    private func follow() {
        withObservationTracking {
            _ = session.isActive
            _ = session.layout
            _ = session.audioTile
            _ = session.warning
            for tile in session.tiles {
                _ = tile.channel
                _ = tile.controller.phase
                _ = tile.controller.notice
                _ = tile.controller.plan
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.emitState()
                self?.follow()
            }
        }
    }
}

/// A player phase as the bridge sends it: name, reconnect attempt, failure message.
enum PhaseText {
    static func of(_ phase: PlaybackPhase) -> (String, Int?, String?) {
        switch phase {
        case .idle: ("idle", nil, nil)
        case .connecting: ("connecting", nil, nil)
        case .buffering: ("buffering", nil, nil)
        case .playing: ("playing", nil, nil)
        case .paused: ("paused", nil, nil)
        case .reconnecting(let n): ("reconnecting", n, nil)
        case .waitingForNetwork: ("waitingForNetwork", nil, nil)
        case .suspended: ("suspended", nil, nil)
        case .preempted: ("preempted", nil, nil)
        case .ended: ("ended", nil, nil)
        case .failed(let failure): ("failed", nil, CredentialRedactor.redact(failure.message))
        }
    }
}

extension BridgeCore {
    func multiviewRequest(_ method: String, _ params: Params) async throws -> any Encodable {
        let multiview = try await players.multiview()
        switch method {
        case "multiview.start":
            struct P: Decodable { var layout: Int; var channel: String?; var group: String? }
            let p = try params.decode(P.self)
            var channel: ChannelListItem?
            if let id = p.channel { channel = try await self.channel(id) }
            let players = self.players
            try await multiview.start(layout: p.layout, channel: channel, group: p.group) {
                for player in players.all { await player.stop() }
            }

        case "multiview.layout":
            struct P: Decodable { var layout: Int }
            try await multiview.setLayout(try params.decode(P.self).layout)

        case "multiview.setChannel":
            struct P: Decodable { var tile: Int; var channel: String; var group: String? }
            let p = try params.decode(P.self)
            let channel = try await self.channel(p.channel)
            try await multiview.setChannel(channel, group: p.group, tile: p.tile)

        case "multiview.clearTile", "multiview.focusAudio", "multiview.retry":
            struct P: Decodable { var tile: Int }
            let tile = try params.decode(P.self).tile
            switch method {
            case "multiview.clearTile": try await multiview.clearTile(tile)
            case "multiview.focusAudio": try await multiview.focusAudio(tile)
            default: try await multiview.retry(tile)
            }

        case "multiview.pinProvider":
            // No provider: automatic.
            struct P: Decodable { var tile: Int; var provider: String? }
            let p = try params.decode(P.self)
            try await multiview.pin(p.provider.map(ProviderID.init), tile: p.tile)

        case "multiview.stop":
            await multiview.stop()

        case "multiview.state":
            break

        default:
            throw BridgeError("Unknown request \(method).")
        }
        return await multiview.state
    }
}
