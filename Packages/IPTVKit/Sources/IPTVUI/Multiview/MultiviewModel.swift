import Foundation
import Observation
import IPTVCore

/// 2–4 live channels at once. Tiles are spread across providers so the total capacity is the sum of
/// every provider's free connections; one tile has audio focus.
@MainActor
@Observable
final class MultiviewModel {
    struct Tile: Identifiable {
        let index: Int
        let controller: PlaybackController
        var channel: ChannelListItem?
        /// User override: always use this provider for the tile.
        var pinnedProvider: ProviderID?
        /// Provider chosen by automatic assignment.
        var assignedProvider: ProviderID?

        var id: Int { index }
    }

    private(set) var tiles: [Tile] = []
    var layout = 4 {
        didSet { applyLayout() }
    }
    private(set) var audioTile = 0
    /// Shown when some tile can't get a connection on any provider.
    private(set) var warning: String?
    private(set) var isActive = false

    @ObservationIgnored private let hub: PlayerHub
    /// Reassignments run one after another so rapid changes can't interleave.
    @ObservationIgnored private var reassignChain: Task<Void, Never>?
    @ObservationIgnored private let environment: AppEnvironment

    init(hub: PlayerHub, environment: AppEnvironment) {
        self.hub = hub
        self.environment = environment
        tiles = (0..<4).map { Tile(index: $0, controller: hub.makeTileController($0)) }
        updateAudio()
    }

    var visibleTiles: [Tile] { Array(tiles.prefix(layout)) }

    /// Enters multiview. The main player and preview stop first so their connections are free.
    func start(with channel: ChannelListItem?) {
        isActive = true
        let main = hub.main
        let preview = hub.preview
        Task {
            await main.stop()
            await preview.stop()
            if let channel, !tiles.contains(where: { $0.channel?.id == channel.id }) {
                let target = tiles.prefix(layout).firstIndex { $0.channel == nil } ?? 0
                tiles[target].channel = channel
                audioTile = target
                updateAudio()
            }
            await reassign()
        }
    }

    /// Leaves multiview and frees every tile's connection. Returns once every tile's stream is
    /// closed, so whatever plays next can't push the provider over its connection limit.
    func stopAll() async {
        isActive = false
        // Let a reassignment that's under way finish first; it won't start tiles once inactive.
        await reassignChain?.value
        for tile in tiles { await tile.controller.stop() }
    }

    func setChannel(_ channel: ChannelListItem, forTile index: Int) {
        tiles[index].channel = channel
        tiles[index].pinnedProvider = nil
        Task { await reassign() }
    }

    func clearTile(_ index: Int) {
        tiles[index].channel = nil
        tiles[index].assignedProvider = nil
        let controller = tiles[index].controller
        Task {
            await controller.stop()
            await reassign()
        }
    }

    /// nil = automatic.
    func pinProvider(_ provider: ProviderID?, forTile index: Int) {
        tiles[index].pinnedProvider = provider
        Task { await reassign() }
    }

    func focusAudio(_ index: Int) {
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
    func reassign() async {
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
        for (position, index) in order.enumerated() {
            if let pin = tiles[index].pinnedProvider { pins[position] = pin }
        }
        let assignment = SourceSelector.assignTiles(candidates, capacity: capacity, pinned: pins)

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
    func providers(forTile index: Int) -> [ProviderID] {
        tiles[index].channel?.sourceProviders ?? []
    }
}
