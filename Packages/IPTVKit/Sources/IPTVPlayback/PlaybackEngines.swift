import AppKit
import IPTVCore
import Network
import SwiftUI

/// Engines that render into an NSView. (macOS; an iOS port would provide a UIView instead.)
@MainActor
public protocol VideoSurfaceProviding: AnyObject {
    var videoView: NSView { get }
}

/// Engines that support Picture in Picture (AVPlayer; mpv can't hand its frames to the system PiP window).
@MainActor
public protocol PictureInPictureCapable: AnyObject {
    var canPictureInPicture: Bool { get }
    func togglePictureInPicture()
}

public enum PlaybackEngines {
    /// Creates a new engine instance. Each player slot (main, preview, each multiview tile) owns its own.
    @MainActor
    public static func make(_ kind: EngineKind) -> any PlaybackEngine {
        switch kind {
        case .mpv: MPVEngine()
        case .avPlayer: AVPlayerEngine()
        }
    }
}

/// Shows whichever engine a PlaybackController is currently using.
public struct VideoSurface: NSViewRepresentable {
    private let engine: (any PlaybackEngine)?

    public init(engine: (any PlaybackEngine)?) {
        self.engine = engine
    }

    public func makeNSView(context: Context) -> VideoContainerView {
        VideoContainerView()
    }

    public func updateNSView(_ view: VideoContainerView, context: Context) {
        view.show((engine as? VideoSurfaceProviding)?.videoView)
    }
}

/// Black container that swaps the engine view in and out without recreating it.
public final class VideoContainerView: NSView {
    private weak var current: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ view: NSView?) {
        guard view !== current else { return }
        current?.removeFromSuperview()
        current = view
        guard let view else { return }
        // A view can live in one superview at a time; this moves it if it was elsewhere.
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    // Let clicks and keys go to SwiftUI overlays above.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Network reachability (NWPathMonitor) and sleep/wake (NSWorkspace) for PlaybackController.
public final class MacSystemEvents: SystemEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<SystemEvent>.Continuation] = [:]
    private let monitor = NWPathMonitor()
    private var lastAvailable: Bool?
    private var tokens: [NSObjectProtocol] = []

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.pathChanged(path.status == .satisfied)
        }
        monitor.start(queue: DispatchQueue(label: "com.jackson.iptvstreamer.network"))
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            Log.playback.notice("System will sleep")
            self?.send(.willSleep)
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            Log.playback.notice("System did wake")
            self?.send(.didWake)
        })
    }

    deinit {
        monitor.cancel()
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    public func events() -> AsyncStream<SystemEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SystemEvent>.makeStream()
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
        }
        lock.withLock { continuations[id] = continuation }
        return stream
    }

    private func pathChanged(_ available: Bool) {
        let changed = lock.withLock { () -> Bool in
            defer { lastAvailable = available }
            return lastAvailable != available
        }
        guard changed else { return }
        Log.playback.notice("Network \(available ? "available" : "unavailable", privacy: .public)")
        send(.network(available: available))
    }

    private func send(_ event: SystemEvent) {
        lock.withLock { Array(continuations.values) }.forEach { $0.yield(event) }
    }
}
