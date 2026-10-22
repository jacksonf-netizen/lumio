import Foundation

// The playback engine abstraction. The UI and PlaybackController only ever talk to
// `PlaybackEngine`; mpv and AVPlayer implementations live in IPTVPlayback.

/// Network buffering behaviour, mapped by each engine to its own options.
public enum BufferPreset: String, Sendable, Codable, CaseIterable, Identifiable {
    case lowLatency
    case normal
    case large

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lowLatency: "Low latency"
        case .normal: "Normal"
        case .large: "Large (unstable network)"
        }
    }

    /// Seconds of media to buffer ahead.
    public var readAheadSeconds: Double {
        switch self {
        case .lowLatency: 2
        case .normal: 8
        case .large: 30
        }
    }

    /// Upper bound on demuxer memory.
    public var maxBytes: Int {
        switch self {
        case .lowLatency: 16 << 20
        case .normal: 64 << 20
        case .large: 192 << 20
        }
    }

    /// Socket timeout before the engine reports a network error.
    public var networkTimeoutSeconds: Double {
        switch self {
        case .lowLatency: 8
        case .normal: 12
        case .large: 20
        }
    }
}

/// Everything an engine needs to open a stream.
public struct EngineRequest: Sendable, Equatable {
    public var url: URL
    public var isLive: Bool
    public var startPosition: Double?
    public var userAgent: String
    public var buffer: BufferPreset

    public init(url: URL, isLive: Bool, startPosition: Double? = nil, userAgent: String, buffer: BufferPreset = .normal) {
        self.url = url
        self.isLive = isLive
        self.startPosition = startPosition
        self.userAgent = HTTPHeader.sanitized(userAgent, fallback: XtreamClient.defaultUserAgent)
        self.buffer = buffer
    }
}

/// Why an engine couldn't play.
public struct EngineFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// Connection refused, reset, DNS, TLS…
        case network
        case timeout
        case httpStatus(Int)
        /// The engine can't handle this format/codec.
        case unsupported
        case decoder
        /// Watchdog: no progress for too long.
        case stalled
        /// A live stream ended (the server closed it).
        case endOfStream
        case unknown
    }

    public var kind: Kind
    public var detail: String

    public init(_ kind: Kind, _ detail: String = "") {
        self.kind = kind
        self.detail = detail
    }

    /// Retrying the same URL won't help; move on to the next format / engine / provider.
    public var skipsToNextRung: Bool {
        switch kind {
        case .unsupported, .decoder: true
        case .httpStatus(let code): code == 404 || code == 401 || code == 403 || code == 458 || code == 456 || code == 509
        default: false
        }
    }

    /// The provider refused this stream outright (missing, forbidden, or at its connection limit).
    /// Other formats from the same provider almost always fail the same way, so if another provider
    /// carries the channel it's faster to go straight there.
    public var providerRefused: Bool {
        if case .httpStatus(let code) = kind { return [401, 403, 404, 456, 458, 509].contains(code) }
        return false
    }

    public var description: String {
        let base: String
        switch kind {
        case .network: base = "Network error"
        case .timeout: base = "The stream didn't start in time"
        case .httpStatus(401): base = "The provider rejected the login (HTTP 401)"
        case .httpStatus(403): base = "The provider refused the stream (HTTP 403). It may be at its connection limit, or blocking this app's user-agent"
        case .httpStatus(404): base = "The provider says this stream doesn't exist (HTTP 404)"
        case .httpStatus(let code) where [456, 458, 509].contains(code): base = "The provider says all connections are in use (HTTP \(code))"
        case .httpStatus(let code) where code >= 500: base = "The provider's server had an error (HTTP \(code))"
        case .httpStatus(let code): base = "Unexpected response from the provider (HTTP \(code))"
        case .unsupported: base = "This stream's format isn't supported by the current player engine"
        case .decoder: base = "The video couldn't be decoded"
        case .stalled: base = "The stream stopped sending data"
        case .endOfStream: base = "The provider closed the stream"
        case .unknown: base = "Playback failed"
        }
        return detail.isEmpty ? base : "\(base) (\(detail))"
    }
}

/// Something an engine reports. `loadID` ties it to one `load` call so late events from a stream
/// that was already replaced are ignored.
public struct EngineEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case buffering(Bool)
        /// The first frame is on screen (or playback resumed).
        case playing
        case paused
        case endOfStream
        case failed(EngineFailure)
        case tracksChanged
    }

    public var loadID: Int
    public var kind: Kind

    public init(loadID: Int, _ kind: Kind) {
        self.loadID = loadID
        self.kind = kind
    }
}

public struct MediaTrack: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case audio, subtitle }

    public var id: Int
    public var kind: Kind
    public var title: String?
    public var language: String?
    public var codec: String?
    public var isSelected: Bool

    public init(id: Int, kind: Kind, title: String? = nil, language: String? = nil, codec: String? = nil, isSelected: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.language = language
        self.codec = codec
        self.isSelected = isSelected
    }

    public var displayName: String {
        let parts = [title, language.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }, codec?.uppercased()]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Track \(id)" : parts.joined(separator: " · ")
    }
}

/// A snapshot for the watchdog and the diagnostics overlay.
public struct PlaybackMetrics: Sendable, Equatable {
    public var engine: EngineKind
    /// Media position in seconds (advances while frames are presented).
    public var position: Double?
    public var duration: Double?
    /// Seconds of media buffered ahead of the position.
    public var bufferSeconds: Double?
    /// Monotonic count of bytes or packets received, if the engine knows; growth means data is flowing.
    public var bytesReceived: Int64?
    public var videoCodec: String?
    public var audioCodec: String?
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    public var bitrateKbps: Double?
    public var droppedFrames: Int?
    public var hardwareDecoder: String?
    public var displayRefreshRate: Double?

    public init(engine: EngineKind, position: Double? = nil, duration: Double? = nil, bufferSeconds: Double? = nil,
                bytesReceived: Int64? = nil, videoCodec: String? = nil, audioCodec: String? = nil, width: Int? = nil,
                height: Int? = nil, fps: Double? = nil, bitrateKbps: Double? = nil, droppedFrames: Int? = nil,
                hardwareDecoder: String? = nil, displayRefreshRate: Double? = nil) {
        self.engine = engine
        self.position = position
        self.duration = duration
        self.bufferSeconds = bufferSeconds
        self.bytesReceived = bytesReceived
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateKbps = bitrateKbps
        self.droppedFrames = droppedFrames
        self.hardwareDecoder = hardwareDecoder
        self.displayRefreshRate = displayRefreshRate
    }
}

/// A video player backend. Implementations are main-actor bound because they own views.
///
/// Contract:
/// - `load` replaces whatever was playing and returns a new load id; every later event for that
///   stream carries it.
/// - `stop` closes the network stream before returning, so a single-connection account can open
///   the next stream immediately.
/// - A user-initiated `stop` never produces a `.failed` event.
@MainActor
public protocol PlaybackEngine: AnyObject {
    var kind: EngineKind { get }
    /// One long-lived stream of events; consumed by exactly one PlaybackController.
    var events: AsyncStream<EngineEvent> { get }

    @discardableResult
    func load(_ request: EngineRequest) -> Int
    func play()
    func pause()
    func stop() async
    func seek(to seconds: Double)
    var volume: Double { get set }
    var isMuted: Bool { get set }
    func tracks() -> [MediaTrack]
    func select(_ track: MediaTrack?, kind: MediaTrack.Kind)
    func metrics() -> PlaybackMetrics
    /// Releases all resources. The engine can't be used afterwards.
    func shutdown()
}
