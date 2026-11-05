import Foundation

/// One provider's copy of the thing being played.
public struct PlaybackSource: Sendable, Hashable {
    public var providerID: ProviderID
    /// Stream id for live and movies, episode id for episodes.
    public var itemID: String
    public var providerName: String
    public var providerPriority: Int
    /// From the provider's `allowed_output_formats`; empty means unknown (try both).
    public var allowedFormats: [StreamFormat]
    /// Per-channel override from settings.
    public var preferredFormat: StreamFormat?
    public var engineOverride: EngineKind?
    /// VOD container extension (mkv, mp4…).
    public var containerExtension: String?
    /// What worked last time (from PlaybackHistory).
    public var lastWorkingFormat: StreamFormat?
    public var lastWorkingEngine: EngineKind?
    public var reliability: Double

    public init(providerID: ProviderID, itemID: String, providerName: String = "", providerPriority: Int = 0,
                allowedFormats: [StreamFormat] = [], preferredFormat: StreamFormat? = nil,
                engineOverride: EngineKind? = nil, containerExtension: String? = nil,
                lastWorkingFormat: StreamFormat? = nil, lastWorkingEngine: EngineKind? = nil, reliability: Double = 0.5) {
        self.providerID = providerID
        self.itemID = itemID
        self.providerName = providerName
        self.providerPriority = providerPriority
        self.allowedFormats = allowedFormats
        self.preferredFormat = preferredFormat
        self.engineOverride = engineOverride
        self.containerExtension = containerExtension
        self.lastWorkingFormat = lastWorkingFormat
        self.lastWorkingEngine = lastWorkingEngine
        self.reliability = reliability
    }

    public var streamID: Int? { Int(itemID) }
}

/// Something to play: a logical live channel (with sources on several providers), a movie, or an episode.
public struct PlaybackItem: Sendable, Hashable, Identifiable {
    public enum Content: String, Sendable, Hashable { case live, movie, episode }

    /// Logical channel id for live, "movie:<provider>:<id>" / "episode:<provider>:<id>" for VOD.
    public var id: String
    public var title: String
    public var content: Content
    public var sources: [PlaybackSource]
    public var startPosition: Double?
    public var logoURL: URL?
    /// Optional manual choice: only use this provider (multiview per-tile override).
    public var pinnedProviderID: ProviderID?

    public init(id: String, title: String, content: Content, sources: [PlaybackSource], startPosition: Double? = nil,
                logoURL: URL? = nil, pinnedProviderID: ProviderID? = nil) {
        self.id = id
        self.title = title
        self.content = content
        self.sources = sources
        self.startPosition = startPosition
        self.logoURL = logoURL
        self.pinnedProviderID = pinnedProviderID
    }

    public var isLive: Bool { content == .live }
}

/// One rung of the fallback ladder: a source played with a format on an engine.
public struct PlaybackPlan: Sendable, Hashable, CustomStringConvertible {
    public var source: PlaybackSource
    /// Live only; VOD uses the container extension.
    public var format: StreamFormat?
    public var engine: EngineKind

    public var description: String {
        "\(source.providerName.isEmpty ? source.providerID.rawValue : source.providerName)/\(source.itemID) \(format?.rawValue ?? source.containerExtension ?? "") on \(engine.rawValue)"
    }
}

/// Builds the ordered list of things to try when playing an item.
public enum FallbackLadder {
    /// Containers AVPlayer can open directly.
    static let avPlayerContainers: Set<String> = ["mp4", "m4v", "mov", "m3u8", "mp3", "aac", "m4a"]

    /// For each source (already in preference order):
    /// 1. what worked last time, else preferred format on the default engine
    /// 2. the other format on the same engine (if the provider allows it)
    /// 3. the platform's other engines (AVPlayer only gets HLS for live, or containers it supports
    ///    for VOD). Only engines in `engines` are used; a saved engine the platform doesn't have
    ///    (an mpv override restored on Android, say) is ignored.
    public static func plans(for item: PlaybackItem, defaultEngine: EngineKind = .mpv,
                             defaultFormat: StreamFormat = .ts,
                             engines: [EngineKind] = [.mpv, .avPlayer]) -> [PlaybackPlan] {
        let available = engines.isEmpty ? [defaultEngine] : engines
        func usable(_ engine: EngineKind?) -> EngineKind? { engine.flatMap { available.contains($0) ? $0 : nil } }
        func supports(_ engine: EngineKind, _ format: StreamFormat) -> Bool { engine != .avPlayer || format == .m3u8 }
        func supports(_ engine: EngineKind, container: String) -> Bool {
            engine != .avPlayer || avPlayerContainers.contains(container)
        }

        var result: [PlaybackPlan] = []
        for source in item.sources {
            var plans: [PlaybackPlan] = []
            let primaryEngine = usable(source.engineOverride) ?? usable(source.lastWorkingEngine) ?? usable(defaultEngine) ?? available[0]
            // Locked to one engine by a per-channel override: don't switch engines.
            let locked = usable(source.engineOverride) != nil

            if item.isLive {
                let allowed = source.allowedFormats.isEmpty ? [StreamFormat.ts, .m3u8] : source.allowedFormats
                let wanted = source.lastWorkingFormat ?? source.preferredFormat ?? defaultFormat
                let primaryFormat = allowed.contains(wanted) ? wanted : allowed[0]
                let primary = PlaybackPlan(
                    source: source, format: primaryFormat,
                    engine: supports(primaryEngine, primaryFormat)
                        ? primaryEngine : (available.first { supports($0, primaryFormat) } ?? primaryEngine))
                plans.append(primary)
                for format in allowed where format != primary.format && supports(primary.engine, format) {
                    plans.append(PlaybackPlan(source: source, format: format, engine: primary.engine))
                }
                if !locked {
                    for engine in available where engine != primary.engine {
                        let formats = allowed.filter { supports(engine, $0) }
                        let ordered = formats.filter { $0 == primary.format } + formats.filter { $0 != primary.format }
                        for format in ordered {
                            plans.append(PlaybackPlan(source: source, format: format, engine: engine))
                        }
                    }
                }
            } else {
                plans.append(PlaybackPlan(source: source, format: nil, engine: primaryEngine))
                let container = (source.containerExtension ?? "mp4").lowercased()
                if !locked {
                    for engine in available where engine != primaryEngine && supports(engine, container: container) {
                        plans.append(PlaybackPlan(source: source, format: nil, engine: engine))
                    }
                }
            }
            for plan in plans where !result.contains(plan) { result.append(plan) }
        }
        return result
    }
}
