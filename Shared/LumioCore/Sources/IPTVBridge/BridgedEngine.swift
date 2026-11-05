import Foundation
import IPTVCore

/// A playback engine that lives in the app (ExoPlayer on Android), driven by the core's
/// PlaybackController through two channels:
///
/// - Commands, sent to the app as JSON and answered at once: load, play, pause, stop, seek,
///   volume, tracks, metrics, release. They're sent on the main actor, which on Android is the UI
///   thread (the bridge drains Swift's main queue there), the thread ExoPlayer wants.
/// - Events, pushed back by the app (`EngineEvents.deliver`) from its player listener: buffering,
///   playing, paused, ended, failed, tracks changed. They carry the load id from `load`, so the
///   controller ignores events from a stream it has already replaced.
@MainActor
public final class BridgedEngine: PlaybackEngine {
    public let kind: EngineKind = .exoPlayer
    public let events: AsyncStream<EngineEvent>
    nonisolated let continuation: AsyncStream<EngineEvent>.Continuation
    let player: String
    private let send: @MainActor (String) -> String?
    private var loadID = 0

    /// `send` delivers one command (JSON) to the app and returns its answer (JSON), or nil.
    public init(player: String, send: @escaping @MainActor (String) -> String?) {
        self.player = player
        self.send = send
        (events, continuation) = AsyncStream<EngineEvent>.makeStream()
        EngineEvents.shared.register(self)
    }

    @discardableResult
    public func load(_ request: EngineRequest) -> Int {
        loadID += 1
        var command: [String: Any] = [
            "loadID": loadID, "url": request.url.absoluteString, "live": request.isLive, "userAgent": request.userAgent,
            "readAheadSeconds": request.buffer.readAheadSeconds, "maxBytes": request.buffer.maxBytes,
            "timeoutSeconds": request.buffer.networkTimeoutSeconds,
        ]
        if let start = request.startPosition { command["startPosition"] = start }
        _ = run("load", command)
        return loadID
    }

    public func play() { _ = run("play") }
    public func pause() { _ = run("pause") }
    /// The app stops the player (and closes its connection) before answering.
    public func stop() async { _ = run("stop") }
    public func seek(to seconds: Double) { _ = run("seek", ["position": seconds]) }

    public var volume: Double = 1 {
        didSet { _ = run("volume", ["volume": volume, "muted": isMuted]) }
    }

    public var isMuted = false {
        didSet { _ = run("volume", ["volume": volume, "muted": isMuted]) }
    }

    public func tracks() -> [MediaTrack] {
        guard let list = run("tracks") as? [[String: Any]] else { return [] }
        return list.compactMap { track in
            guard let id = track["id"] as? Int, let kind = (track["kind"] as? String).flatMap(MediaTrack.Kind.init(rawValue:))
            else { return nil }
            return MediaTrack(id: id, kind: kind, title: track["title"] as? String, language: track["language"] as? String,
                              codec: track["codec"] as? String, isSelected: track["selected"] as? Bool ?? false)
        }
    }

    public func select(_ track: MediaTrack?, kind: MediaTrack.Kind) {
        var command: [String: Any] = ["kind": kind.rawValue]
        if let track { command["id"] = track.id }
        _ = run("select", command)
    }

    public func metrics() -> PlaybackMetrics {
        guard let m = run("metrics") as? [String: Any] else { return PlaybackMetrics(engine: .exoPlayer) }
        func double(_ key: String) -> Double? { (m[key] as? NSNumber)?.doubleValue }
        func int(_ key: String) -> Int? { (m[key] as? NSNumber)?.intValue }
        return PlaybackMetrics(
            engine: .exoPlayer, position: double("position"), duration: double("duration"), bufferSeconds: double("bufferSeconds"),
            bytesReceived: (m["bytesReceived"] as? NSNumber)?.int64Value, videoCodec: m["videoCodec"] as? String,
            audioCodec: m["audioCodec"] as? String, width: int("width"), height: int("height"), fps: double("fps"),
            bitrateKbps: double("bitrateKbps"), droppedFrames: int("droppedFrames"), hardwareDecoder: m["decoder"] as? String)
    }

    public func shutdown() {
        _ = run("release")
        continuation.finish()
        EngineEvents.shared.unregister(player)
    }

    /// Sends one command and returns the answer's `result`.
    private func run(_ command: String, _ fields: [String: Any] = [:]) -> Any? {
        var object = fields
        object["command"] = command
        object["player"] = player
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let reply = send(String(decoding: data, as: UTF8.self)),
              let parsed = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] else { return nil }
        return parsed["result"]
    }

    /// Turns an event from the app into the engine event the controller understands.
    nonisolated static func event(from object: [String: Any]) -> EngineEvent? {
        guard let loadID = object["loadID"] as? Int, let type = object["type"] as? String else { return nil }
        let kind: EngineEvent.Kind
        switch type {
        case "buffering": kind = .buffering(object["value"] as? Bool ?? true)
        case "playing": kind = .playing
        case "paused": kind = .paused
        case "ended": kind = .endOfStream
        case "tracks": kind = .tracksChanged
        case "failed":
            let detail = object["detail"] as? String ?? ""
            let failure: EngineFailure.Kind = switch object["kind"] as? String {
            case "network": .network
            case "timeout": .timeout
            case "http": .httpStatus(object["status"] as? Int ?? 0)
            case "unsupported": .unsupported
            case "decoder": .decoder
            case "noFreeDecoder": .noFreeDecoder
            case "stalled": .stalled
            case "endOfStream": .endOfStream
            default: .unknown
            }
            kind = .failed(EngineFailure(failure, detail))
        default: return nil
        }
        return EngineEvent(loadID: loadID, kind)
    }
}

/// Routes events from the app to the engine of the player they name. Thread-safe: the app calls
/// `deliver` from its own threads.
public final class EngineEvents: @unchecked Sendable {
    public static let shared = EngineEvents()
    private let lock = NSLock()
    private var continuations: [String: AsyncStream<EngineEvent>.Continuation] = [:]

    @MainActor func register(_ engine: BridgedEngine) {
        lock.withLock { continuations[engine.player] = engine.continuation }
    }

    func unregister(_ player: String) {
        lock.withLock { _ = continuations.removeValue(forKey: player) }
    }

    /// One event (JSON) from the app: `{"player", "loadID", "type", …}`.
    public func deliver(_ json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let player = object["player"] as? String, let event = BridgedEngine.event(from: object),
              let continuation = lock.withLock({ continuations[player] }) else { return }
        continuation.yield(event)
    }
}
