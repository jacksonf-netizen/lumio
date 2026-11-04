import Foundation

/// How every Lumio app sets up its players, so the Mac and Android TV players share their rules:
/// the same stream addresses, history, server-link failover and settings. Each app brings only
/// its engines.
extension AppEnvironment {
    /// What a player needs, with `makeEngine` building this platform's engines.
    public func playbackDependencies(makeEngine: @escaping @MainActor @Sendable (EngineKind) -> any PlaybackEngine) -> PlaybackDependencies {
        let settings = self.settings
        let resolver = ProviderStreamResolver(database: database, secrets: secrets, userAgent: {
            (try? settings.value(String.self, for: .userAgent)) ?? XtreamClient.defaultUserAgent
        })
        return PlaybackDependencies(
            connections: connections, resolver: resolver, history: DatabasePlaybackHistory(database: database),
            servers: servers, systemEvents: systemEvents, makeEngine: makeEngine)
    }

    /// The user's playback settings, for a platform with `engines` (first is the default).
    public func playbackSettings(engines: [EngineKind]) -> PlaybackSettings {
        var result = PlaybackSettings()
        result.engines = engines
        result.defaultEngine = engines.first ?? .mpv
        if let engine = try? settings.value(EngineKind.self, for: .engine), engines.contains(engine) { result.defaultEngine = engine }
        if let format = try? settings.value(StreamFormat.self, for: .preferredFormat) { result.defaultFormat = format }
        if let buffer = try? settings.value(BufferPreset.self, for: .bufferPreset) { result.buffer = buffer }
        if let stall = try? settings.value(Double.self, for: .stallTimeoutSeconds) { result.stallTimeout = stall }
        return result
    }
}

/// The channels a player zaps through (the list playback started from), with the current and
/// previous channel: channel up/down wraps around, a number picks the channel with that number
/// (or that position), and "previous" swaps back.
public struct ZapList<Channel: Identifiable & Sendable>: Sendable {
    public private(set) var channels: [Channel] = []
    public private(set) var current: Channel?
    public private(set) var previous: Channel?

    public init() {}

    /// Starts watching `channel`, zapping through `list` from now on (when given and not empty).
    public mutating func watch(_ channel: Channel, in list: [Channel]? = nil) {
        if let list, !list.isEmpty { channels = list }
        if channels.isEmpty { channels = [channel] }
        if current?.id != channel.id { previous = current }
        current = channel
    }

    /// The channel `offset` places along the list from the current one, wrapping around.
    public func channel(by offset: Int) -> Channel? {
        guard !channels.isEmpty else { return nil }
        let index = channels.firstIndex { $0.id == current?.id } ?? 0
        return channels[((index + offset) % channels.count + channels.count) % channels.count]
    }

    /// The channel numbered `number`, else the one at that position (1-based), else nil.
    public func channel(number: Int, numberOf: (Channel) -> Int?) -> Channel? {
        if let match = channels.first(where: { numberOf($0) == number }) { return match }
        return number >= 1 && number <= channels.count ? channels[number - 1] : nil
    }
}
