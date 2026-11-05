import Foundation
import Observation

/// Multiview: 2–4 live channels at once, shared by the Mac and Android TV. Tiles are spread across
/// providers so the total capacity is the sum of every provider's free connections (see
/// `SourceSelector.assignTiles`); one tile has audio focus. Each tile is its own PlaybackController,
/// so reconnects and fallbacks work as in the full-screen player.
@MainActor
@Observable
public final class MultiviewSession {
    public struct Tile: Identifiable {
        public let index: Int
        public let controller: PlaybackController
        public var channel: ChannelListItem?
        /// User override: always use this provider for the tile.
        public var pinnedProvider: ProviderID?
        /// Provider chosen by automatic assignment.
        public var assignedProvider: ProviderID?

        public var id: Int { index }
    }

    public private(set) var tiles: [Tile] = []
    public var layout = 4 {
        didSet { applyLayout() }
    }
    public private(set) var audioTile = 0
    /// Shown when some tile can't get a connection on any provider.
    public private(set) var warning: String?
    public private(set) var isActive = false

    /// Reassignments run one after another so rapid changes can't interleave.
    @ObservationIgnored private var reassignChain: Task<Void, Never>?
    @ObservationIgnored private let environment: AppEnvironment

    /// `makeController` makes tile `index`'s player (purpose `.tile(index)`).
    public init(environment: AppEnvironment, layout: Int = 4, makeController: (Int) -> PlaybackController) {
        self.environment = environment
        self.layout = layout
        tiles = (0..<4).map { Tile(index: $0, controller: makeController($0)) }
        updateAudio()
    }

    public var visibleTiles: [Tile] { Array(tiles.prefix(layout)) }

    /// Enters multiview with `channel` (if any) in the first empty tile. `stopOthers` stops the
    /// app's other players first (the full-screen player, the preview) so their connections are free.
    public func start(with channel: ChannelListItem?, stopOthers: @escaping @MainActor () async -> Void) {
        isActive = true
        // The tile shows its channel at once; its stream opens once the others have stopped.
        if let channel {
            if let existing = tiles.prefix(layout).firstIndex(where: { $0.channel?.id == channel.id }) {
                audioTile = existing
            } else {
                let target = tiles.prefix(layout).firstIndex { $0.channel == nil } ?? 0
                tiles[target].channel = channel
                tiles[target].pinnedProvider = nil
                audioTile = target
            }
            updateAudio()
        }
        Task {
            await stopOthers()
            await reassign()
        }
    }

    /// Leaves multiview and frees every tile's connection. Returns once every tile's stream is
    /// closed, so whatever plays next can't push the provider over its connection limit.
    public func stopAll() async {
        isActive = false
        // Let a reassignment that's under way finish first; it won't start tiles once inactive.
        await reassignChain?.value
        for tile in tiles { await tile.controller.stop() }
    }

    public func setChannel(_ channel: ChannelListItem, forTile index: Int) {
        tiles[index].channel = channel
        tiles[index].pinnedProvider = nil
        Task { await reassign() }
    }

    public func clearTile(_ index: Int) {
        tiles[index].channel = nil
        tiles[index].assignedProvider = nil
        let controller = tiles[index].controller
        Task {
            await controller.stop()
            await reassign()
        }
    }

    /// nil = automatic.
    public func pinProvider(_ provider: ProviderID?, forTile index: Int) {
        tiles[index].pinnedProvider = provider
        Task { await reassign() }
    }

    public func focusAudio(_ index: Int) {
        audioTile = index
        updateAudio()
    }

    private func updateAudio() {
        for tile in tiles { tile.controller.isMuted = tile.index != audioTile }
    }

    private func applyLayout() {
        // Tiles beyond the layout are closed so they don't hold connections.
        for tile in tiles where tile.index >= layout && tile.channel != nil {
            clearTile(tile.index)
        }
        if audioTile >= layout { focusAudio(0) }
        Task { await reassign() }
    }

    /// Works out which provider each tile uses (see SourceSelector.assignTiles) and (re)starts tiles
    /// whose provider changed. Tiles are stopped before others start, so capacity is never exceeded.
    public func reassign() async {
        let previous = reassignChain
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.performReassign()
        }
        reassignChain = task
        await task.value
    }

    private func performReassign() async {
        let active = tiles.prefix(layout).filter { $0.channel != nil }
        var items: [Int: PlaybackItem] = [:]
        for tile in active {
            guard let channel = tile.channel,
                  let item = try? environment.items.liveItem(providerID: channel.providerID, streamID: channel.streamID)
            else { continue }
            items[tile.index] = item
        }

        // Capacity for tiles = each provider's limit minus connections held by anything that isn't a tile.
        var capacity: [ProviderID: Int] = [:]
        let providerIDs = Set(items.values.flatMap { $0.sources.map(\.providerID) })
        for id in providerIDs {
            let usage = await environment.connections.usage(for: id)
            let nonTile = usage.purposes.filter { if case .tile = $0 { false } else { true } }.count
            capacity[id] = max(0, usage.limit - nonTile)
        }

        let order = active.map(\.index).filter { items[$0] != nil }
        let candidates = order.map { index in
            items[index]!.sources.map {
                SourceCandidate(providerID: $0.providerID, streamID: $0.streamID ?? 0,
                                providerPriority: $0.providerPriority, reliability: $0.reliability)
            }
        }
        var pins: [Int: ProviderID] = [:]
        // Tiles playing the same channel as before stay where they are if they can: when there
        // aren't enough connections, a newly filled tile waits rather than stopping one that plays.
        var playing: [Int: ProviderID] = [:]
        for (position, index) in order.enumerated() {
            if let pin = tiles[index].pinnedProvider { pins[position] = pin }
            if let provider = tiles[index].assignedProvider, tiles[index].controller.phase.isActive,
               tiles[index].controller.item?.id == items[index]?.id {
                playing[position] = provider
            }
        }
        let assignment = SourceSelector.assignTiles(candidates, capacity: capacity, pinned: pins, playing: playing)

        // Stop tiles whose provider changes before starting anything.
        var toStart: [(Int, PlaybackItem)] = []
        var unserved: [String] = []
        for (position, index) in order.enumerated() {
            let provider = assignment[position].source?.providerID
            let changed = provider != tiles[index].assignedProvider || tiles[index].controller.item?.id != items[index]?.id
                || !(tiles[index].controller.phase.isActive)
            tiles[index].assignedProvider = provider
            guard var item = items[index] else { continue }
            guard let provider else {
                unserved.append(tiles[index].channel?.name ?? "tile \(index + 1)")
                await tiles[index].controller.stop()
                continue
            }
            if changed {
                await tiles[index].controller.stop()
                item.pinnedProviderID = provider
                toStart.append((index, item))
            }
        }
        // Multiview may have been left while this was working out the assignment.
        guard isActive else { return }
        for (index, item) in toStart {
            tiles[index].controller.play(item)
        }

        if unserved.isEmpty {
            warning = nil
        } else {
            let names = unserved.joined(separator: ", ")
            warning = "No provider has a free connection for \(names). Close a tile, stop other playback, or add another provider."
        }
        Log.playback.info("Multiview assignment: \(assignment.map { $0.source?.providerID.rawValue ?? "none" }.joined(separator: ", "), privacy: .public)")
    }

    /// Providers that carry the tile's channel, for the per-tile override menu.
    public func providers(forTile index: Int) -> [ProviderID] {
        tiles[index].channel?.sourceProviders ?? []
    }
}
