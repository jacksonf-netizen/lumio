import SwiftUI
import IPTVCore
import IPTVPlayback

/// Video plus status overlays for one PlaybackController. Used full-size, as the preview pane and
/// as a multiview tile.
public struct PlayerView: View {
    let controller: PlaybackController
    var showsDiagnostics: Bool
    var compact: Bool
    /// Short buffering hiccups are normal; only mention buffering once it lasts.
    @State private var longBuffering = false

    public init(controller: PlaybackController, showsDiagnostics: Bool = false, compact: Bool = false) {
        self.controller = controller
        self.showsDiagnostics = showsDiagnostics
        self.compact = compact
    }

    public var body: some View {
        ZStack {
            Color.black
            VideoSurface(engine: controller.engine)
                .opacity(controller.phase == .playing || controller.phase == .buffering || controller.phase == .paused
                         || controller.phase.isRecovering ? 1 : 0)

            stateOverlay

            VStack {
                HStack(alignment: .top) {
                    if showsDiagnostics {
                        DiagnosticsOverlay(controller: controller)
                    }
                    Spacer()
                    recoveryBadge
                }
                // Clear of the window buttons when the player fills the window.
                .padding(.top, compact ? 0 : 20)
                Spacer()
                if let notice = controller.notice {
                    Text(notice)
                        .font(compact ? .caption : .callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
                        .environment(\.colorScheme, .dark)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(compact ? 6 : 16)
        }
        .task(id: controller.phase == .buffering) {
            longBuffering = false
            guard controller.phase == .buffering else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { longBuffering = true }
        }
        .animation(.easeInOut(duration: 0.2), value: controller.notice)
        .animation(.easeInOut(duration: 0.2), value: controller.phase)
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch controller.phase {
        case .connecting:
            VStack(spacing: 12) {
                ProgressView().controlSize(compact ? .small : .regular)
                if !compact, let title = controller.item?.title {
                    VStack(spacing: 3) {
                        Text(title).font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                        Text("Connecting…").font(.callout).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .environment(\.colorScheme, .dark)
        case .failed(let failure):
            VStack(spacing: compact ? 6 : 12) {
                Image(systemName: failure.noConnection ? "rectangle.connected.to.line.below" : "exclamationmark.triangle")
                    .font(compact ? .title3 : .largeTitle)
                    .foregroundStyle(.orange)
                Text(failure.noConnection ? "No free connection" : "Can't play this channel")
                    .font(compact ? .caption.bold() : .headline)
                Text(failure.message)
                    .font(compact ? .caption2 : .callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(compact ? 3 : 6)
                    .frame(maxWidth: 420)
                Button("Try Again") { controller.retry() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(compact ? .small : .large)
                    .padding(.top, compact ? 0 : 4)
            }
            .padding()
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
        case .preempted:
            Label("Paused while the connection is used elsewhere", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        case .ended:
            Label("Finished", systemImage: "checkmark.circle")
                .foregroundStyle(.white.opacity(0.8))
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var recoveryBadge: some View {
        let text: String? = switch controller.phase {
        case .reconnecting: "Reconnecting…"
        case .waitingForNetwork: "Waiting for network…"
        case .suspended: "Paused for sleep"
        case .buffering: compact || !longBuffering ? nil : "Buffering…"
        default: nil
        }
        if let text {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(text)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .transition(.opacity)
        }
    }
}

/// Resolution, frame rate and codec as small pills ("1080p · 50 fps · HEVC"), for the channel
/// banner and the movie title. Empty until the stream reports them.
struct StreamBadges: View {
    let metrics: PlaybackMetrics?

    static func labels(_ m: PlaybackMetrics?) -> [String] {
        var labels: [String] = []
        if let height = m?.height, height > 0 {
            let width = m?.width ?? 0
            // By the larger of height and 16:9-equivalent width, so 1920×800 films still read 1080p.
            let quality: String = switch max(height, width * 9 / 16) {
            case 2000...: "4K"
            case 1400..<2000: "1440p"
            case 1000..<1400: "1080p"
            case 700..<1000: "720p"
            default: "\(height)p"
            }
            labels.append(quality)
        }
        if let fps = m?.fps, fps > 1 {
            let rounded = fps.rounded()
            labels.append(abs(fps - rounded) < 0.05 ? "\(Int(rounded)) fps" : String(format: "%.2f fps", fps))
        }
        if let codec = m?.videoCodec?.lowercased() {
            let names = ["hevc": "HEVC", "h265": "HEVC", "h264": "H.264", "avc1": "H.264", "av1": "AV1", "vp9": "VP9",
                         "mpeg2video": "MPEG-2", "mpeg4": "MPEG-4"]
            labels.append(names[codec] ?? codec.uppercased())
        }
        return labels
    }

    var body: some View {
        let labels = Self.labels(metrics)
        if !labels.isEmpty {
            HStack(spacing: 4) {
                ForEach(labels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .fixedSize()
            .help("Resolution, frame rate and video format. Press D or the ⓘ button for full stream info.")
        }
    }
}

/// Technical details, toggled with D or the ⓘ button.
struct DiagnosticsOverlay: View {
    let controller: PlaybackController
    var close: (() -> Void)? = nil

    var body: some View {
        let m = controller.metrics
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Stream Info").font(.system(size: 12, weight: .semibold))
                Spacer()
                if let close {
                    Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.7))
                        .help("Close (D or Esc)")
                        .accessibilityLabel("Close Stream Info")
                }
            }
            .padding(.bottom, 4)
            row("Engine", controller.plan.map { "\($0.engine == .mpv ? "mpv" : "AVPlayer") · \($0.format?.rawValue ?? $0.source.containerExtension ?? "")" })
            row("Provider", controller.plan.map { $0.source.providerName })
            row("State", stateText)
            row("Video", [m?.videoCodec, resolution(m), m?.fps.map { String(format: "%.2f fps", $0) }].compactMap { $0 }.joined(separator: " · "))
            row("Audio", m?.audioCodec)
            row("Decoder", m?.hardwareDecoder)
            row("Bitrate", m?.bitrateKbps.map { String(format: "%.0f kb/s", $0) })
            row("Buffer", m?.bufferSeconds.map { String(format: "%.1f s", $0) })
            row("Dropped", m?.droppedFrames.map(String.init))
            row("Display", m?.displayRefreshRate.map { String(format: "%.2f Hz", $0) })
            row("Reconnects", String(controller.reconnectCount))
            row("Last error", controller.lastAttemptError)
            row("URL", controller.redactedURL)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .textSelection(.enabled)
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var stateText: String {
        switch controller.phase {
        case .reconnecting(let attempt): "reconnecting (attempt \(attempt))"
        case .failed(let failure): "failed: \(failure.message)"
        default: String(describing: controller.phase)
        }
    }

    private func resolution(_ m: PlaybackMetrics?) -> String? {
        guard let w = m?.width, let h = m?.height else { return nil }
        return "\(w)×\(h)"
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Text(label).foregroundStyle(.white.opacity(0.6)).frame(width: 78, alignment: .leading)
                Text(value).lineLimit(2)
            }
        }
    }
}
