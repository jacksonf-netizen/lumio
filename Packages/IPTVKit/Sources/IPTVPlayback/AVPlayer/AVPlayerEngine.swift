import AVFoundation
import AVKit
import AppKit
import Foundation
import IPTVCore

/// AVPlayer-based engine. Best for HLS (`.m3u8`) and MP4 VOD; also the fallback when mpv fails.
@MainActor
public final class AVPlayerEngine: PlaybackEngine, VideoSurfaceProviding, PictureInPictureCapable {
    public let kind: EngineKind = .avPlayer
    public let events: AsyncStream<EngineEvent>
    public let videoView: NSView

    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let player = AVPlayer()
    private var loadID = 0
    private var sentFirstFrame = false
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var lastHTTPStatus: Int?
    /// Loaded asynchronously after each load; AVFoundation no longer offers a synchronous getter.
    private var selectionGroups: [MediaTrack.Kind: AVMediaSelectionGroup] = [:]

    public var volume: Double = 1 {
        didSet { player.volume = Float(max(0, min(1, volume))) }
    }

    public var isMuted = false {
        didSet { player.isMuted = isMuted }
    }

    private var pipController: AVPictureInPictureController?

    public init() {
        (events, continuation) = AsyncStream<EngineEvent>.makeStream()
        let view = AVPlayerVideoView()
        view.playerLayer.player = player
        videoView = view
        if AVPictureInPictureController.isPictureInPictureSupported() {
            pipController = AVPictureInPictureController(playerLayer: view.playerLayer)
        }
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false

        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.timeControlChanged(status) } }
        })
    }

    @discardableResult
    public func load(_ request: EngineRequest) -> Int {
        clearItemObservers()
        loadID += 1
        let id = loadID
        sentFirstFrame = false
        lastHTTPStatus = nil

        let asset = AVURLAsset(url: request.url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": request.userAgent],
        ])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = request.buffer.readAheadSeconds
        if request.isLive {
            item.automaticallyPreservesTimeOffsetFromLive = true
        }
        observe(item, loadID: id)
        selectionGroups = [:]
        Task { [weak self] in
            let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self, self.loadID == id else { return }
            self.selectionGroups[.audio] = audio
            self.selectionGroups[.subtitle] = legible
            self.emit(.tracksChanged, id)
        }
        player.replaceCurrentItem(with: item)
        if let start = request.startPosition, start > 1, !request.isLive {
            item.seek(to: CMTime(seconds: start, preferredTimescale: 600), completionHandler: nil)
        }
        player.play()
        return id
    }

    private func observe(_ item: AVPlayerItem, loadID id: Int) {
        observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.loadID == id, status == .failed else { return }
                    self.emit(.failed(self.mapFailure(error)), id)
                }
            }
        })
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit(.endOfStream, id) }
        })
        notificationTokens.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated {
                guard let self else { return }
                self.emit(.failed(self.mapFailure(error)), id)
            }
        })
        notificationTokens.append(center.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main) { [weak self] note in
            let status = (note.object as? AVPlayerItem)?.errorLog()?.events.last?.errorStatusCode
            MainActor.assumeIsolated {
                if let status, status >= 400 { self?.lastHTTPStatus = status }
            }
        })
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        guard player.currentItem != nil else { return }
        switch status {
        case .playing:
            sentFirstFrame = true
            emit(.playing, loadID)
        case .waitingToPlayAtSpecifiedRate:
            if sentFirstFrame { emit(.buffering(true), loadID) }
        case .paused:
            if sentFirstFrame { emit(.paused, loadID) }
        @unknown default:
            break
        }
    }

    private func emit(_ kind: EngineEvent.Kind, _ id: Int) {
        guard id == loadID else { return }
        continuation.yield(EngineEvent(loadID: id, kind))
    }

    private func mapFailure(_ error: Error?) -> EngineFailure {
        let detail = error?.localizedDescription ?? "unknown error"
        if let status = lastHTTPStatus { return EngineFailure(.httpStatus(status), detail) }
        guard let nsError = error as NSError? else { return EngineFailure(.unknown, detail) }
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        for candidate in [nsError, underlying].compactMap({ $0 }) {
            if candidate.domain == NSURLErrorDomain {
                switch candidate.code {
                case NSURLErrorTimedOut: return EngineFailure(.timeout, detail)
                // Foundation reports HTTP 404 / 401 / 403 for media loads with these codes.
                case NSURLErrorFileDoesNotExist: return EngineFailure(.httpStatus(404), detail)
                case NSURLErrorUserAuthenticationRequired: return EngineFailure(.httpStatus(401), detail)
                case NSURLErrorNoPermissionsToReadFile: return EngineFailure(.httpStatus(403), detail)
                default: return EngineFailure(.network, detail)
                }
            }
            if candidate.domain == AVFoundationErrorDomain {
                switch AVError.Code(rawValue: candidate.code) {
                case .fileFormatNotRecognized, .failedToParse, .decoderNotFound, .formatUnsupported, .contentIsUnavailable:
                    return EngineFailure(.unsupported, detail)
                case .decodeFailed:
                    return EngineFailure(.decoder, detail)
                default:
                    break
                }
            }
        }
        // CoreMedia's HTTP errors: -12938 (404), -12660 (403), -12661 (other 4xx/5xx).
        switch underlying?.code ?? nsError.code {
        case -12938: return EngineFailure(.httpStatus(404), detail)
        case -12660: return EngineFailure(.httpStatus(403), detail)
        default: return EngineFailure(.unknown, detail)
        }
    }

    public var canPictureInPicture: Bool { pipController?.isPictureInPicturePossible ?? false }

    public func togglePictureInPicture() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }

    public func play() { player.play() }
    public func pause() { player.pause() }

    public func stop() async {
        clearItemObservers()
        loadID += 1
        player.pause()
        // Removing the item cancels its loads and closes the HTTP connections.
        player.replaceCurrentItem(with: nil)
        await Task.yield()
    }

    private func clearItemObservers() {
        // Keep the player-level observation (index 0).
        if observations.count > 1 {
            observations[1...].forEach { $0.invalidate() }
            observations.removeSubrange(1...)
        }
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
    }

    public func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    public func tracks() -> [MediaTrack] {
        guard let item = player.currentItem else { return [] }
        var result: [MediaTrack] = []
        for kind in [MediaTrack.Kind.audio, .subtitle] {
            guard let group = selectionGroups[kind] else { continue }
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            for (index, option) in group.options.enumerated() {
                result.append(MediaTrack(id: index, kind: kind, title: option.displayName,
                                         language: option.extendedLanguageTag, isSelected: option == selected))
            }
        }
        return result
    }

    public func select(_ track: MediaTrack?, kind: MediaTrack.Kind) {
        guard let item = player.currentItem, let group = selectionGroups[kind] else { return }
        let option = track.flatMap { $0.id < group.options.count ? group.options[$0.id] : nil }
        item.select(option, in: group)
    }

    public func metrics() -> PlaybackMetrics {
        guard let item = player.currentItem else { return PlaybackMetrics(engine: .avPlayer) }
        let now = item.currentTime().seconds
        let buffered = item.loadedTimeRanges.map(\.timeRangeValue).first { $0.containsTime(item.currentTime()) }
            .map { $0.end.seconds - now }
        let log = item.accessLog()?.events.last
        let videoTrack = item.tracks.first { $0.assetTrack?.mediaType == .video }
        let size = item.presentationSize == .zero ? nil : item.presentationSize
        return PlaybackMetrics(
            engine: .avPlayer,
            position: now.isFinite ? now : nil,
            duration: item.duration.seconds.isFinite ? item.duration.seconds : nil,
            bufferSeconds: buffered,
            bytesReceived: log.map { $0.numberOfBytesTransferred },
            width: size.map { Int($0.width) },
            height: size.map { Int($0.height) },
            fps: videoTrack.map { Double($0.currentVideoFrameRate) },
            bitrateKbps: log.map { $0.observedBitrate / 1000 },
            droppedFrames: log.map { $0.numberOfDroppedVideoFrames },
            hardwareDecoder: "VideoToolbox",
            displayRefreshRate: videoView.window?.screen.map { Double($0.maximumFramesPerSecond) })
    }

    public func shutdown() {
        clearItemObservers()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        player.replaceCurrentItem(with: nil)
        continuation.finish()
    }
}

/// Plain view hosting an AVPlayerLayer (no system controls; our overlay draws the UI).
final class AVPlayerVideoView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    convenience init() { self.init(frame: NSRect(x: 0, y: 0, width: 640, height: 360)) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
