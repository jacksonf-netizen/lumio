import Foundation
import IPTVCore

// What crosses the bridge, as JSON. These are the bridge's own types, not the core's models, so the
// core can change without the Android app noticing. Kotlin has a matching class for each one
// (AndroidTV/app/.../core/BridgeModels.kt); a change here needs the same change there, and the
// fixtures in Tests/IPTVBridgeTests/Fixtures are read by both sides' tests to keep them in step.
//
// Dates are seconds since 1970. Optional values are left out when missing.

public struct ProviderDTO: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    /// The server link in use.
    public var server: String
    public var links: [LinkDTO]
    public var channels: Int
    public var movies: Int
    public var series: Int
    public var programmes: Int
    public var connectionsInUse: Int
    public var connectionLimit: Int
    public var accountStatus: String?
    public var expiresAt: Double?
    public var lastRefreshAt: Double?
    public var lastError: String?
    /// What a refresh in progress is doing ("Updating channels…"), or nil.
    public var syncing: String?
    /// Every link failed its last check.
    public var unreachable: Bool
}

public struct LinkDTO: Codable, Equatable, Sendable {
    public var url: String
    public var inUse: Bool
    public var down: Bool
    public var lastCheckedAt: Double?
}

public struct GroupDTO: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// favorites, recents, all, custom or category.
    public var kind: String
    public var hidden: Bool
}

public struct ChannelDTO: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var number: Int?
    public var logo: String?
    public var providerID: String
    public var streamID: Int
    public var favorite: Bool
    public var hidden: Bool
    public var catchup: Bool
    /// The guide reference for now/next (`live.nowNext`), when the channel has one.
    public var epg: EPGRefDTO?
}

public struct EPGRefDTO: Codable, Hashable, Sendable {
    public var id: String
    public var providers: [String]
}

public struct NowNextDTO: Codable, Equatable, Sendable {
    public var epg: EPGRefDTO
    public var now: ProgrammeDTO?
    public var next: ProgrammeDTO?
}

public struct ProgrammeDTO: Codable, Equatable, Sendable {
    public var title: String
    public var start: Double
    public var stop: Double
    public var subtitle: String?
    public var summary: String?
}

public struct TrackDTO: Codable, Equatable, Sendable {
    public var id: Int
    /// audio or subtitle.
    public var kind: String
    /// What to show: title, language and codec where known.
    public var name: String
    public var selected: Bool

    init(_ track: MediaTrack) {
        id = track.id
        kind = track.kind.rawValue
        name = track.displayName
        selected = track.isSelected
    }
}

public struct ProviderEditorDTO: Codable, Equatable, Sendable {
    /// One link per line.
    public var servers: String
    /// The saved username; the password never crosses the bridge.
    public var username: String
}

/// Something that changed, pushed to the app as it happens. The app re-reads what it shows.
public struct BridgeEvent: Codable, Equatable, Sendable {
    /// providers: the provider list or a provider's status changed.
    /// live: the Live TV groups or channels changed. guide: now/next may have changed.
    /// sync: a refresh started, moved on a step or finished (`provider`, `label`, `error`).
    /// player: a player's state changed (`state`).
    public var type: String
    public var provider: String?
    public var label: String?
    public var finished: Bool?
    public var error: String?
    public var state: PlayerStateDTO?

    public init(type: String, provider: String? = nil, label: String? = nil, finished: Bool? = nil, error: String? = nil,
                state: PlayerStateDTO? = nil) {
        self.type = type
        self.provider = provider
        self.label = label
        self.finished = finished
        self.error = error
        self.state = state
    }
}

// MARK: Conversions

extension EPGRefDTO {
    init(_ ref: EPGRef) {
        id = ref.epgID
        providers = ref.providers.map(\.rawValue)
    }

    var ref: EPGRef { EPGRef(epgID: id, providers: providers.map(ProviderID.init)) }
}

extension ProgrammeDTO {
    init(_ programme: Programme) {
        title = programme.title
        start = programme.start.timeIntervalSince1970
        stop = programme.stop.timeIntervalSince1970
        subtitle = programme.subtitle
        summary = programme.summary
    }
}

extension GroupDTO {
    init(_ group: ChannelGroup) {
        id = group.id
        name = group.name
        kind = group.kind.rawValue
        hidden = group.isHidden
    }
}

extension ChannelDTO {
    init(_ channel: ChannelListItem) {
        id = channel.id
        name = channel.name
        number = channel.number
        logo = channel.logoURL.map { ServerAliases.shared.rewrite($0).absoluteString }
        providerID = channel.providerID.rawValue
        streamID = channel.streamID
        favorite = channel.isFavorite
        hidden = channel.isHidden
        catchup = channel.hasCatchup
        epg = channel.epg.map(EPGRefDTO.init)
    }
}
