import Foundation
import IPTVCore

// Settings and content switches over the bridge: `settings.*` and `content.*` requests. Values are
// stored by the core's SettingsRepository and LibraryRepository, as on the Mac; only the keys an
// Android TV app offers are accepted, each checked against the Mac's ranges.

public struct SettingsDTO: Codable, Equatable, Sendable {
    public var epgRefreshHours: Double
    public var catalogRefreshHours: Double
    public var epgFutureDays: Double
    /// ts or m3u8.
    public var preferredFormat: String
    /// lowLatency, normal or large.
    public var bufferPreset: String
    public var stallTimeoutSeconds: Double
    /// Empty: the default.
    public var userAgent: String
    public var defaultUserAgent: String
    /// Sidebar sections switched off.
    public var hiddenSidebarItems: [String]
}

public struct RegionDTO: Codable, Equatable, Sendable {
    public var code: String
    public var name: String
    public var groups: Int
    public var examples: [String]
    public var shown: Bool
    public var categoryCount: Int
    public var shownCategories: Int
    /// Groups without a recognisable region.
    public var other: Bool
}

public struct ContentCategoryDTO: Codable, Equatable, Sendable {
    public var provider: String
    public var providerName: String
    /// live, movie or series.
    public var kind: String
    public var id: String
    public var name: String
    public var shown: Bool
}

public struct RegionsDTO: Codable, Equatable, Sendable {
    public var regions: [RegionDTO]
    /// Each region's live groups, by region code.
    public var categories: [String: [ContentCategoryDTO]]
}

extension BridgeCore {
    func settingsRequest(_ method: String, _ params: Params) async throws -> any Encodable {
        let settings = environment.settings
        let library = LibraryRepository(database: environment.database)
        switch method {
        case "settings.get":
            return SettingsDTO(
                epgRefreshHours: (try? settings.value(Double.self, for: .epgRefreshHours)) ?? 12,
                catalogRefreshHours: (try? settings.value(Double.self, for: .catalogRefreshHours)) ?? 12,
                epgFutureDays: (try? settings.value(Double.self, for: .epgFutureDays)) ?? 7,
                preferredFormat: ((try? settings.value(StreamFormat.self, for: .preferredFormat)) ?? .ts).rawValue,
                bufferPreset: ((try? settings.value(BufferPreset.self, for: .bufferPreset)) ?? .normal).rawValue,
                stallTimeoutSeconds: (try? settings.value(Double.self, for: .stallTimeoutSeconds)) ?? 8,
                userAgent: (try? settings.value(String.self, for: .userAgent)) ?? "",
                defaultUserAgent: XtreamClient.defaultUserAgent,
                hiddenSidebarItems: (try? settings.value([String].self, for: .hiddenSidebarItems)) ?? [])

        case "settings.set":
            // One setting: {"key": …, "value": …}. A missing value goes back to the default.
            struct P: Decodable {
                var key: String
                var number: Double?
                var text: String?
                var list: [String]?
            }
            let p = try params.decode(P.self)
            func number(_ range: ClosedRange<Double>) throws -> Double {
                guard let value = p.number, range.contains(value) else {
                    throw BridgeError("\(p.key) must be between \(Int(range.lowerBound)) and \(Int(range.upperBound)).")
                }
                return value
            }
            switch p.key {
            case "epgRefreshHours": try settings.set(try number(2...48), for: .epgRefreshHours)
            case "catalogRefreshHours": try settings.set(try number(2...72), for: .catalogRefreshHours)
            case "epgFutureDays": try settings.set(try number(1...14), for: .epgFutureDays)
            case "stallTimeoutSeconds": try settings.set(try number(3...30), for: .stallTimeoutSeconds)
            case "preferredFormat":
                guard let format = p.text.flatMap(StreamFormat.init(rawValue:)) else { throw BridgeError("Unknown format.") }
                try settings.set(format, for: .preferredFormat)
            case "bufferPreset":
                guard let preset = p.text.flatMap(BufferPreset.init(rawValue:)) else { throw BridgeError("Unknown buffer size.") }
                try settings.set(preset, for: .bufferPreset)
            case "userAgent":
                let agent = p.text?.trimmingCharacters(in: .whitespaces) ?? ""
                try settings.set(agent.isEmpty ? nil : agent, for: .userAgent)
            case "hiddenSidebarItems":
                try settings.set(p.list ?? [], for: .hiddenSidebarItems)
            default:
                throw BridgeError("Unknown setting \(p.key).")
            }
            // Players pick up playback settings for the next stream.
            if ["stallTimeoutSeconds", "preferredFormat", "bufferPreset"].contains(p.key) { await players.reloadSettings() }
            return Empty()

        case "content.regions":
            let regions = try await library.regions()
            let categories = try await library.regionCategories()
            return RegionsDTO(
                regions: regions.map { region in
                    RegionDTO(code: region.code, name: region.name, groups: region.liveGroups, examples: region.examples,
                              shown: !region.isHidden, categoryCount: region.categoryCount,
                              shownCategories: region.shownCategories, other: region.isOther)
                },
                categories: categories.mapValues { list in
                    list.map { ContentCategoryDTO(provider: $0.providerID.rawValue, providerName: $0.providerName, kind: $0.kind.rawValue,
                                                  id: $0.categoryID, name: $0.name, shown: $0.isShown) }
                })

        case "content.setRegion":
            // Switching a region on or off also resets its single groups (as on the Mac).
            struct P: Decodable { var code: String; var shown: Bool }
            let p = try params.decode(P.self)
            try await library.setRegion(p.code, hidden: !p.shown)
            return Empty()

        case "content.setAllRegions":
            struct P: Decodable { var shown: Bool }
            let shown = try params.decode(P.self).shown
            let codes = Set(try await library.regions().map(\.code))
            try await library.setHiddenRegions(shown ? [] : codes, resettingCategoriesIn: codes)
            return Empty()

        case "content.setRegionCategory":
            struct P: Decodable { var provider: String; var id: String; var shown: Bool }
            let p = try params.decode(P.self)
            let all = try await library.regionCategories().values.joined()
            guard let category = all.first(where: { $0.providerID.rawValue == p.provider && $0.categoryID == p.id }) else {
                throw BridgeError("That group no longer exists.")
            }
            try await library.setCategory(category, shown: p.shown)
            return Empty()

        case "content.hiddenCategories":
            return try await library.hiddenCategories().map {
                ContentCategoryDTO(provider: $0.providerID.rawValue, providerName: $0.providerName, kind: $0.kind.rawValue,
                                   id: $0.categoryID, name: $0.name, shown: false)
            }

        case "content.setCategoryHidden":
            // Any kind: a movie or series category from a Hold OK menu, or one shown again.
            struct P: Decodable { var provider: String; var kind: String; var id: String; var hidden: Bool }
            let p = try params.decode(P.self)
            guard let kind = ContentKind(rawValue: p.kind) else { throw BridgeError("Unknown kind \(p.kind).") }
            try await library.setCategoryHidden(p.hidden, providerID: ProviderID(p.provider), kind: kind, categoryID: p.id)
            emitVODChange()
            return Empty()

        default:
            throw BridgeError("Unknown request \(method).")
        }
    }
}

extension Players {
    /// After a playback setting changes: each player uses it from its next stream.
    func reloadSettings() {
        for player in all { player.controller.settings = environment.playbackSettings(engines: [.exoPlayer]) }
        multiviewIfMade?.reloadSettings()
    }
}
