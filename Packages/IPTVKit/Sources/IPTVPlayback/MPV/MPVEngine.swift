// macOS-only: renders through MoltenVK into a CAMetalLayer hosted by an NSView.
import AppKit
import Foundation
import IPTVCore
import Libmpv

/// libmpv-based engine: plays raw MPEG-TS, HEVC, AC-3/E-AC-3 and HLS with VideoToolbox decoding.
@MainActor
public final class MPVEngine: PlaybackEngine, VideoSurfaceProviding {
    public let kind: EngineKind = .mpv
    public let events: AsyncStream<EngineEvent>
    public let videoView: NSView

    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let handle: MPVHandle
    private let pump: MPVEventPump
    private let layer: MPVMetalLayer

    private var nextLoadID = 0
    /// Load ids issued by `load` that haven't seen their START_FILE yet (FIFO).
    private var pendingLoads: [Int] = []
    private var loadForEntry: [Int64: Int] = [:]
    private var currentEntry: Int64?
    private var currentLoadID: Int?
    private var sentFirstFrame = false
    private var isPaused = false
    /// The request for the current load, for probing the HTTP status after a failure.
    private var currentRequest: EngineRequest?
    private var lastErrorLine: String?
    private var redaction: [ProviderCredentials] = []
    private var stopWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var bytesReceived: Int64 = 0
    private var lastMetricsAt: Date?
    private var isShutDown = false

    public var volume: Double = 1 {
        didSet { setDouble("volume", max(0, min(1, volume)) * 100) }
    }

    public var isMuted = false {
        didSet { setFlag("mute", isMuted) }
    }

    private let headless: Bool

    /// - Parameter headless: decode without video or audio output (integration tests).
    public init(headless: Bool = false) {
        self.headless = headless
        (events, continuation) = AsyncStream<EngineEvent>.makeStream()
        layer = MPVMetalLayer()
        let view = MPVVideoView(metalLayer: layer)
        videoView = view

        guard let raw = mpv_create() else { fatalError("mpv_create failed") }
        handle = MPVHandle(raw)
        pump = MPVEventPump(handle: handle)

        configure()
        if !headless {
            view.onDrawableSizeSettled = { [weak self] in self?.matchOutputToDrawable() }
        }
        let status = mpv_initialize(raw)
        if status < 0 { Log.playback.fault("mpv_initialize failed: \(String(cString: mpv_error_string(status)), privacy: .public)") }

        for (name, format) in MPVEngine.observed {
            mpv_observe_property(raw, 0, name, format)
        }
        mpv_request_log_messages(raw, "warn")
        pump.engine = self
        pump.start()
    }

    /// Set IPTV_TRACE_MPV=1 to print mpv's log lines (credentials masked) to stdout.
    static let traceLogs = ProcessInfo.processInfo.environment["IPTV_TRACE_MPV"] != nil

    private static let observed: [(String, mpv_format)] = [
        ("pause", MPV_FORMAT_FLAG),
        ("paused-for-cache", MPV_FORMAT_FLAG),
        ("track-list/count", MPV_FORMAT_INT64),
    ]

    private func configure() {
        let raw = handle.raw
        func option(_ name: String, _ value: String) {
            let status = mpv_set_option_string(raw, name, value)
            if status < 0 { Log.playback.error("mpv option \(name, privacy: .public)=\(value, privacy: .public): \(String(cString: mpv_error_string(status)), privacy: .public)") }
        }
        if headless {
            option("vo", "null")
            option("ao", "null")
        } else {
            // Video output: libplacebo via Vulkan (MoltenVK) into our CAMetalLayer.
            var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
            mpv_set_option(raw, "wid", MPV_FORMAT_INT64, &wid)
            option("vo", "gpu-next")
            option("gpu-api", "vulkan")
            option("gpu-context", "moltenvk")
        }
        option("hwdec", "videotoolbox")
        // Embedded use: no config files, scripts, key bindings or terminal output.
        option("config", "no")
        option("load-scripts", "no")
        // mpv's built-in Lua scripts (OSC, stats, console…) run LuaJIT, which writes executable code at
        // run time. The hardened runtime (Release builds) kills the app for that. We have our own UI,
        // so none of them are needed.
        option("osc", "no")
        for script in ["load-stats-overlay", "load-console", "load-auto-profiles", "load-select",
                       "load-positioning", "load-commands", "load-context-menu"] {
            option(script, "no")
        }
        option("input-default-bindings", "no")
        option("input-vo-keyboard", "no")
        option("terminal", "no")
        option("ytdl", "no")
        option("idle", "yes")
        option("keep-open", "no")
        option("audio-client-name", "Lumio")
        // Network and cache defaults; per-load values are applied in `load`.
        option("cache", "yes")
        option("demuxer-max-back-bytes", "16MiB")
        option("network-timeout", "12")
        option("hr-seek", "yes")
        option("subs-fallback", "yes")
    }

    // MARK: PlaybackEngine

    @discardableResult
    public func load(_ request: EngineRequest) -> Int {
        nextLoadID += 1
        let id = nextLoadID
        pendingLoads.append(id)
        currentLoadID = id
        sentFirstFrame = false
        currentRequest = request
        lastErrorLine = nil
        bytesReceived = 0
        lastMetricsAt = nil

        let buffer = request.buffer
        setString("user-agent", request.userAgent)
        setString("network-timeout", String(Int(buffer.networkTimeoutSeconds)))
        setString("demuxer-readahead-secs", String(Int(buffer.readAheadSeconds)))
        setString("demuxer-max-bytes", String(buffer.maxBytes))
        setString("cache-secs", String(Int(buffer.readAheadSeconds)))
        if request.isLive {
            // Probe less so channel changes are fast; IPTV TS streams start with PAT/PMT anyway.
            setString("demuxer-lavf-probesize", buffer == .large ? "2000000" : "500000")
            setString("demuxer-lavf-analyzeduration", buffer == .large ? "3" : "1")
            setString("cache-pause-initial", buffer == .lowLatency ? "no" : "yes")
            setString("cache-pause-wait", buffer == .lowLatency ? "0.5" : "1")
        } else {
            setString("demuxer-lavf-probesize", "5000000")
            setString("demuxer-lavf-analyzeduration", "5")
            setString("cache-pause-initial", "no")
        }

        var args = [request.url.absoluteString, "replace"]
        if let start = request.startPosition, start > 1 {
            args += ["-1", "start=\(Int(start))"]
        }
        command("loadfile", args)
        return id
    }

    public func play() {
        setFlag("pause", false)
    }

    public func pause() {
        setFlag("pause", true)
    }

    public func stop() async {
        pendingLoads.removeAll()
        currentLoadID = nil
        guard currentEntry != nil, !isShutDown else { return }
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stopWaiters[id] = continuation
            command("stop", [])
            // Don't hang forever if mpv never reports END_FILE.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated {
                    self?.stopWaiters.removeValue(forKey: id)?.resume()
                }
            }
        }
    }

    public func seek(to seconds: Double) {
        command("seek", [String(seconds), "absolute"])
    }

    public func tracks() -> [MediaTrack] {
        let count = getInt("track-list/count") ?? 0
        var result: [MediaTrack] = []
        for index in 0..<count {
            let prefix = "track-list/\(index)/"
            guard let type = getString(prefix + "type"), let id = getInt(prefix + "id") else { continue }
            let kind: MediaTrack.Kind
            switch type {
            case "audio": kind = .audio
            case "sub": kind = .subtitle
            default: continue
            }
            result.append(MediaTrack(id: id, kind: kind, title: getString(prefix + "title"),
                                     language: getString(prefix + "lang"), codec: getString(prefix + "codec"),
                                     isSelected: getFlag(prefix + "selected") ?? false))
        }
        return result
    }

    public func select(_ track: MediaTrack?, kind: MediaTrack.Kind) {
        setString(kind == .audio ? "aid" : "sid", track.map { String($0.id) } ?? "no")
    }

    public func metrics() -> PlaybackMetrics {
        let now = Date()
        // mpv doesn't expose a cumulative byte counter; integrate the input rate.
        if let speed = getInt("cache-speed"), let last = lastMetricsAt {
            bytesReceived += Int64(Double(speed) * now.timeIntervalSince(last))
        }
        lastMetricsAt = now
        let drops = (getInt("frame-drop-count") ?? 0) + (getInt("decoder-frame-drop-count") ?? 0)
        let hwdec = getString("hwdec-current")
        return PlaybackMetrics(
            engine: .mpv,
            position: getDouble("time-pos"),
            duration: getDouble("duration"),
            bufferSeconds: bufferAhead(),
            bytesReceived: bytesReceived,
            videoCodec: getString("video-format"),
            audioCodec: getString("audio-codec-name"),
            width: getInt("video-params/w"),
            height: getInt("video-params/h"),
            fps: getDouble("estimated-vf-fps") ?? getDouble("container-fps"),
            bitrateKbps: getDouble("video-bitrate").map { $0 / 1000 },
            droppedFrames: drops,
            hardwareDecoder: hwdec == "no" ? "software" : hwdec,
            // mpv's display-fps isn't available with the MoltenVK context; ask the screen instead.
            displayRefreshRate: getDouble("display-fps") ?? videoView.window?.screen.map { Double($0.maximumFramesPerSecond) })
    }

    /// Seconds buffered ahead of what's playing. mpv's `demuxer-cache-duration` stays at 0 for many
    /// live MPEG-TS streams (it needs seekable ranges), so fall back to how far the cache reaches
    /// past the playback position.
    private func bufferAhead() -> Double? {
        if let duration = getDouble("demuxer-cache-duration"), duration > 0 { return duration }
        guard let cached = getDouble("demuxer-cache-time"), let position = getDouble("time-pos") else {
            return getDouble("demuxer-cache-duration")
        }
        return max(0, cached - position)
    }

    /// Credentials to mask in mpv log lines (mpv logs URLs).
    public func setRedaction(_ credentials: [ProviderCredentials]) {
        redaction = credentials
    }

    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        stopWaiters.values.forEach { $0.resume() }
        stopWaiters.removeAll()
        pump.shutdown()
        continuation.finish()
    }

    // MARK: Events (delivered on the main thread by MPVEventPump)

    fileprivate func handle(_ events: [MPVRawEvent]) {
        for event in events { handle(event) }
    }

    private func emit(_ kind: EngineEvent.Kind, for loadID: Int?) {
        guard let loadID else { return }
        continuation.yield(EngineEvent(loadID: loadID, kind))
    }

    private func handle(_ event: MPVRawEvent) {
        switch event {
        case .startFile(let entry):
            let loadID = pendingLoads.isEmpty ? nil : pendingLoads.removeFirst()
            if let loadID { loadForEntry[entry] = loadID }
            currentEntry = entry
            sentFirstFrame = false

        case .playbackRestart:
            guard let entry = currentEntry, let loadID = loadForEntry[entry] else { return }
            matchOutputToDrawable()
            if !isPaused {
                sentFirstFrame = true
                emit(.playing, for: loadID)
            }

        case .endFile(let entry, let reason, let error):
            let loadID = loadForEntry.removeValue(forKey: entry)
            if entry == currentEntry { currentEntry = nil }
            switch reason {
            case MPV_END_FILE_REASON_EOF:
                emit(.endOfStream, for: loadID)
            case MPV_END_FILE_REASON_ERROR:
                // FFmpeg's log output (where "HTTP error 404" appears) is process-wide, and with several
                // mpv players mpv routes it to just one of them, so it can't tell us which stream failed
                // how. Ask the server directly instead: one short request that reads only the headers.
                let detail = lastErrorLine ?? String(cString: mpv_error_string(error))
                let request = currentRequest
                Task { @MainActor [weak self] in
                    var status: Int?
                    if let request { status = await MPVEngine.probeStatus(url: request.url, userAgent: request.userAgent) }
                    guard let self else { return }
                    let failure = self.mapFailure(error, detail: detail, probedStatus: status)
                    Log.playback.error("mpv end-file error: \(failure.description, privacy: .public)")
                    self.emit(.failed(failure), for: loadID)
                }
            default:
                break // stop / quit / redirect: user-initiated
            }
            if currentEntry == nil { resumeStopWaiters() }

        case .idle:
            resumeStopWaiters()

        case .flag(let name, let value):
            guard let entry = currentEntry, let loadID = loadForEntry[entry] else {
                if name == "pause" { isPaused = value }
                return
            }
            switch name {
            case "pause":
                isPaused = value
                if value { emit(.paused, for: loadID) } else if sentFirstFrame { emit(.playing, for: loadID) }
            case "paused-for-cache":
                if sentFirstFrame { emit(.buffering(value), for: loadID) }
            default:
                break
            }

        case .int(let name, _):
            if name == "track-list/count", let entry = currentEntry, let loadID = loadForEntry[entry] {
                emit(.tracksChanged, for: loadID)
            }

        case .log(let level, let prefix, let text):
            let line = CredentialRedactor.redact(text.trimmingCharacters(in: .whitespacesAndNewlines), credentials: redaction)
            // FFmpeg lines may belong to another player (see END_FILE above); only mpv's own count.
            if (level == "error" || level == "fatal") && !prefix.hasPrefix("ffmpeg") { lastErrorLine = line }
            if MPVEngine.traceLogs { print("MPVLOG [\(prefix)] \(level): \(line)") }
            Log.playback.debug("mpv[\(prefix, privacy: .public)] \(level, privacy: .public): \(line, privacy: .public)")

        case .shutdown:
            resumeStopWaiters()
        }
    }

    private func resumeStopWaiters() {
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.values.forEach { $0.resume() }
    }

    private func mapFailure(_ code: Int32, detail: String, probedStatus: Int?) -> EngineFailure {
        if let status = probedStatus, status >= 400 { return EngineFailure(.httpStatus(status), detail) }
        let lowered = detail.lowercased()
        if lowered.contains("timed out") || lowered.contains("timeout") { return EngineFailure(.timeout, detail) }
        switch code {
        case MPV_ERROR_UNKNOWN_FORMAT.rawValue, MPV_ERROR_NOTHING_TO_PLAY.rawValue:
            return EngineFailure(.unsupported, detail)
        case MPV_ERROR_VO_INIT_FAILED.rawValue, MPV_ERROR_AO_INIT_FAILED.rawValue:
            return EngineFailure(.decoder, detail)
        case MPV_ERROR_LOADING_FAILED.rawValue:
            // Reachable (2xx) but mpv couldn't make sense of it.
            if let status = probedStatus, (200..<300).contains(status), lowered.contains("recognize") || lowered.contains("format") {
                return EngineFailure(.unsupported, detail)
            }
            return EngineFailure(.network, detail)
        default:
            return EngineFailure(.unknown, detail)
        }
    }

    /// HTTP status of `url`, reading only the response headers (nil if unreachable).
    nonisolated static func probeStatus(url: URL, userAgent: String) async -> Int? {
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        guard let (bytes, response) = try? await session.bytes(for: request) else { return nil }
        bytes.task.cancel()
        return (response as? HTTPURLResponse)?.statusCode
    }

    // MARK: Resizing

    /// Which of two equivalent `vo` spellings is set; switching between them recreates the output.
    private var voSpellingAlternate = false

    /// mpv's MoltenVK output only reads the layer's size when the video output is (re)configured,
    /// not when the layer is resized. Without this, after a window resize or entering full screen mpv
    /// keeps drawing the picture at the old size inside the bigger surface. When the sizes disagree,
    /// recreate the output (by setting an equivalent `vo` value) so it adopts the current size.
    /// Playback continues; at most one frame is skipped.
    private func matchOutputToDrawable() {
        guard !headless, !isShutDown, currentEntry != nil else { return }
        let drawable = layer.drawableSize
        guard drawable.width > 1, drawable.height > 1,
              let width = getInt("osd-width"), let height = getInt("osd-height"), width > 0, height > 0 else { return }
        guard abs(width - Int(drawable.width)) > 1 || abs(height - Int(drawable.height)) > 1 else { return }
        voSpellingAlternate.toggle()
        setString("vo", voSpellingAlternate ? "gpu-next," : "gpu-next")
        Log.playback.debug("mpv output \(width)x\(height) → \(Int(drawable.width))x\(Int(drawable.height))")
    }

    // MARK: Property helpers

    private func command(_ name: String, _ args: [String]) {
        guard !isShutDown else { return }
        let all = [name] + args
        var cStrings: [UnsafeMutablePointer<CChar>?] = all.map { strdup($0) } + [nil]
        defer { cStrings.forEach { free($0) } }
        cStrings.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { pointer in
                let status = mpv_command(handle.raw, pointer)
                if status < 0 {
                    Log.playback.error("mpv \(name, privacy: .public) failed: \(String(cString: mpv_error_string(status)), privacy: .public)")
                }
            }
        }
    }

    private func setString(_ name: String, _ value: String) {
        guard !isShutDown else { return }
        mpv_set_property_string(handle.raw, name, value)
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard !isShutDown else { return }
        var flag: Int32 = value ? 1 : 0
        mpv_set_property(handle.raw, name, MPV_FORMAT_FLAG, &flag)
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard !isShutDown else { return }
        var number = value
        mpv_set_property(handle.raw, name, MPV_FORMAT_DOUBLE, &number)
    }

    private func getDouble(_ name: String) -> Double? {
        guard !isShutDown else { return nil }
        var value = 0.0
        return mpv_get_property(handle.raw, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    private func getInt(_ name: String) -> Int? {
        guard !isShutDown else { return nil }
        var value: Int64 = 0
        return mpv_get_property(handle.raw, name, MPV_FORMAT_INT64, &value) >= 0 ? Int(value) : nil
    }

    private func getFlag(_ name: String) -> Bool? {
        guard !isShutDown else { return nil }
        var value: Int32 = 0
        return mpv_get_property(handle.raw, name, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : nil
    }

    /// Reads any mpv property as a string (debugging and tests).
    public func debugProperty(_ name: String) -> String? { getString(name) }

    private func getString(_ name: String) -> String? {
        guard !isShutDown, let raw = mpv_get_property_string(handle.raw, name) else { return nil }
        defer { mpv_free(raw) }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }
}

// MARK: - Event pump

/// The raw mpv handle, shared between the main thread and the event queue (libmpv's API is thread-safe).
final class MPVHandle: @unchecked Sendable {
    let raw: OpaquePointer
    init(_ raw: OpaquePointer) { self.raw = raw }
}

enum MPVRawEvent: Sendable {
    case startFile(entry: Int64)
    case playbackRestart
    case endFile(entry: Int64, reason: mpv_end_file_reason, error: Int32)
    case idle
    case flag(String, Bool)
    case int(String, Int64)
    case log(level: String, prefix: String, text: String)
    case shutdown
}

/// Drains mpv's event queue on a background queue and hands batches to the engine on the main thread.
final class MPVEventPump: @unchecked Sendable {
    private let handle: MPVHandle
    private let queue = DispatchQueue(label: "com.jackson.iptvstreamer.mpv-events", qos: .userInitiated)
    private let lock = NSLock()
    private var destroyed = false
    @MainActor weak var engine: MPVEngine?

    init(handle: MPVHandle) {
        self.handle = handle
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        mpv_set_wakeup_callback(handle.raw, { context in
            guard let context else { return }
            Unmanaged<MPVEventPump>.fromOpaque(context).takeUnretainedValue().wake()
        }, context)
    }

    private func wake() {
        queue.async { [self] in drain() }
    }

    private func drain() {
        guard !lock.withLock({ destroyed }) else { return }
        var batch: [MPVRawEvent] = []
        while true {
            guard let event = mpv_wait_event(handle.raw, 0)?.pointee else { break }
            if event.event_id == MPV_EVENT_NONE { break }
            if let converted = Self.convert(event) { batch.append(converted) }
            if event.event_id == MPV_EVENT_SHUTDOWN { break }
        }
        guard !batch.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.engine?.handle(batch)
            }
        }
    }

    private static func convert(_ event: mpv_event) -> MPVRawEvent? {
        switch event.event_id {
        case MPV_EVENT_START_FILE:
            let data = event.data?.assumingMemoryBound(to: mpv_event_start_file.self).pointee
            return .startFile(entry: data?.playlist_entry_id ?? -1)
        case MPV_EVENT_PLAYBACK_RESTART:
            return .playbackRestart
        case MPV_EVENT_END_FILE:
            guard let data = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee else { return nil }
            return .endFile(entry: data.playlist_entry_id, reason: data.reason, error: data.error)
        case MPV_EVENT_IDLE:
            return .idle
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                  let namePointer = property.name else { return nil }
            let name = String(cString: namePointer)
            switch property.format {
            case MPV_FORMAT_FLAG:
                guard let value = property.data?.assumingMemoryBound(to: Int32.self).pointee else { return nil }
                return .flag(name, value != 0)
            case MPV_FORMAT_INT64:
                guard let value = property.data?.assumingMemoryBound(to: Int64.self).pointee else { return nil }
                return .int(name, value)
            default:
                return nil
            }
        case MPV_EVENT_LOG_MESSAGE:
            guard let message = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee else { return nil }
            return .log(level: message.level.map { String(cString: $0) } ?? "",
                        prefix: message.prefix.map { String(cString: $0) } ?? "",
                        text: message.text.map { String(cString: $0) } ?? "")
        case MPV_EVENT_SHUTDOWN:
            return .shutdown
        default:
            return nil
        }
    }

    /// Detaches the callback and destroys the mpv core on the event queue.
    func shutdown() {
        mpv_set_wakeup_callback(handle.raw, nil, nil)
        queue.async { [self] in
            lock.withLock { destroyed = true }
            mpv_terminate_destroy(handle.raw)
        }
    }
}

// MARK: - Video view

/// CAMetalLayer with the MoltenVK workarounds from MPVKit's demo (mpv-player/mpv#13651).

final class MPVMetalLayer: CAMetalLayer {
    // MoltenVK may set drawableSize to 1x1 to force-complete a presentation, which flickers.
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 { super.drawableSize = newValue }
        }
    }
}

/// Layer-hosting view for mpv's output.
final class MPVVideoView: NSView {
    private let metalLayer: MPVMetalLayer
    private var settleWork: DispatchWorkItem?
    /// Called once the drawable size stops changing (after a resize or the full-screen animation).
    var onDrawableSizeSettled: (() -> Void)?

    init(metalLayer: MPVMetalLayer) {
        self.metalLayer = metalLayer
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.framebufferOnly = true
        metalLayer.pixelFormat = .bgra8Unorm
        // While a resize is in progress the last frame is scaled to fit, never stretched.
        metalLayer.contentsGravity = .resizeAspect
        layer = metalLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        updateDrawable()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawable()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawable()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateDrawable()
    }

    private func updateDrawable() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let drawable = metalLayer.drawableSize
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        if drawable.width <= 1 || drawable.height <= 1 {
            // First layout: size the drawable right away so mpv starts at the right size.
            metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        } else if metalLayer.drawableSize != drawable {
            metalLayer.drawableSize = drawable // keep the old size until the new one settles
        }
        // Resizing the drawable on every step of a drag or animation would make mpv rebuild its
        // output repeatedly; wait until the size has settled.
        settleWork?.cancel()
        guard !inLiveResize else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let scale = self.window?.backingScaleFactor ?? scale
            let size = CGSize(width: (self.bounds.width * scale).rounded(), height: (self.bounds.height * scale).rounded())
            guard size.width > 1, size.height > 1 else { return }
            if self.metalLayer.drawableSize != size { self.metalLayer.drawableSize = size }
            self.onDrawableSizeSettled?()
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
