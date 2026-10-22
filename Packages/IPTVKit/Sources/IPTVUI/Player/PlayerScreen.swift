import AppKit
import SwiftUI
import IPTVCore
import IPTVPlayback

/// The main player: full-window (or full-screen) video with the info banner, controls, guide overlay
/// and keyboard handling.
///
/// Keys: ↑/↓ or Page Up/Down change channel · 0–9 jump to a number · ⌫ or L last channel ·
/// G guide · F full screen · D diagnostics · M multiview · I info · Space pause · Esc close.
public struct PlayerScreen: View {
    let state: AppState
    var standalone = false

    @State private var bannerVisible = false
    @State private var bannerTask: Task<Void, Never>?
    @State private var controlsVisible = true
    @State private var controlsTask: Task<Void, Never>?
    @State private var hoveringControls = false
    @State private var numberEntry = ""
    @State private var numberTask: Task<Void, Never>?
    @State private var nowNext: NowNext?
    @State private var isFullScreen = false
    @FocusState private var focused: Bool
    @Environment(\.openWindow) private var openWindow

    public init(state: AppState, standalone: Bool = false) {
        self.state = state
        self.standalone = standalone
    }

    private var controller: PlaybackController { state.hub.main }
    private var isLive: Bool { controller.item?.isLive ?? true }

    public var body: some View {
        ZStack {
            // Diagnostics are drawn here, under the channel banner, so the two never overlap.
            PlayerView(controller: controller)
                .onTapGesture(count: 2) { toggleFullScreen() }

            // While the guide is open, clicking the video around it closes it.
            if state.showGuideOverlay {
                Color.black.opacity(0.001)
                    .onTapGesture { closeGuide() }
            }

            // Soft shading behind the overlays so white text stays readable on bright video.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 180)
                    .opacity(isLive && (bannerVisible || controlsVisible) && !state.showGuideOverlay ? 1 : 0)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 200)
                    .opacity(controlsVisible || state.showGuideOverlay ? 1 : 0)
            }
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 10) {
                if isLive, let channel = state.currentChannel, !state.showGuideOverlay, bannerVisible || controlsVisible {
                    InfoBanner(channel: channel, nowNext: nowNext, controller: controller)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                if state.showDiagnostics {
                    DiagnosticsOverlay(controller: controller) { state.showDiagnostics = false }
                        .transition(.opacity)
                }
            }
            // Clear of the window buttons in the top-left corner.
            .padding(.top, 36)
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack {
                if !numberEntry.isEmpty {
                    Text(numberEntry + "_")
                        .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1)))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 36)
                        .padding(.trailing, 20)
                }
                Spacer()
                if state.showGuideOverlay {
                    GuideView(state: state, compact: true, onClose: closeGuide)
                        .frame(maxHeight: 420)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
                        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                        .padding(20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if controlsVisible {
                    ControlsBar(state: state, controller: controller, isFullScreen: isFullScreen, close: close,
                                toggleFullScreen: toggleFullScreen, openMultiview: openMultiview, seek: seek(by:))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .onHover { inside in
                        hoveringControls = inside
                        if !inside { showControls() }
                    }
                    .transition(.opacity)
                }
            }
        }
        .background(.black)
        // The player is always dark, whatever the system appearance.
        .environment(\.colorScheme, .dark)
        .background(PlayerWindowChrome(controlsVisible: controlsVisible || state.showGuideOverlay))
        .animation(.easeInOut(duration: 0.2), value: bannerVisible)
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .animation(.easeInOut(duration: 0.25), value: state.showGuideOverlay)
        .animation(.easeInOut(duration: 0.15), value: state.showDiagnostics)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in isFullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in isFullScreen = false }
        .onAppear {
            isFullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false
            focused = true
            showBanner()
            showControls()
            MediaKeys.shared.attach(state)
        }
        .onChange(of: state.channelChangeCount) { showBanner() }
        .onContinuousHover { phase in
            if case .active = phase { showControls() }
        }
        .task(id: state.currentChannel?.id) { await loadNowNext() }
        .onKeyPress(phases: .down) { press in handle(press) }
    }

    // MARK: Keys

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if state.showGuideOverlay {
            if press.key == .escape || press.characters.lowercased() == "g" {
                closeGuide()
                return .handled
            }
            return .ignored // the guide handles its own keys
        }
        switch press.key {
        case .upArrow, .pageUp:
            if isLive { state.zap(by: -1) }
            return .handled
        case .downArrow, .pageDown:
            if isLive { state.zap(by: 1) }
            return .handled
        case .escape:
            // Closes whatever is on top first: number entry, stream info, full screen, the player.
            if !numberEntry.isEmpty { numberEntry = "" } else if state.showDiagnostics {
                state.showDiagnostics = false
            } else if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true {
                toggleFullScreen()
            } else {
                close()
            }
            return .handled
        case .delete, .deleteForward:
            state.lastChannel()
            return .handled
        case .space:
            togglePause()
            return .handled
        case .return:
            commitNumber()
            return .handled
        case .leftArrow where !isLive:
            seek(by: -10)
            return .handled
        case .rightArrow where !isLive:
            seek(by: 30)
            return .handled
        default:
            break
        }
        let key = press.characters.lowercased()
        if let digit = key.first, digit.isNumber, key.count == 1, isLive {
            appendDigit(digit)
            return .handled
        }
        switch key {
        case "l": state.lastChannel()
        case "g": if isLive { state.showGuideOverlay = true }
        case "f": toggleFullScreen()
        case "d": state.showDiagnostics.toggle()
        case "i": showBanner()
        case "m": openMultiview()
        default: return .ignored
        }
        return .handled
    }

    private func appendDigit(_ digit: Character) {
        guard numberEntry.count < 5 else { return }
        numberEntry.append(digit)
        numberTask?.cancel()
        numberTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            commitNumber()
        }
    }

    private func commitNumber() {
        numberTask?.cancel()
        guard let number = Int(numberEntry) else { return }
        numberEntry = ""
        state.jump(toNumber: number)
    }

    // MARK: Actions

    private func closeGuide() {
        state.showGuideOverlay = false
        // The guide grid had keyboard focus; give it back to the player so its keys work again.
        DispatchQueue.main.async { focused = true }
        showControls()
    }

    private func togglePause() {
        if controller.phase == .paused { controller.resume() } else { controller.pause() }
        showControls()
    }

    private func seek(by seconds: Double) {
        guard let position = controller.metrics?.position else { return }
        controller.seek(to: max(0, position + seconds))
        showControls()
    }

    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private func close() {
        if standalone {
            NSApp.keyWindow?.close()
        } else {
            state.closePlayer()
        }
    }

    private func openMultiview() {
        guard isLive else { return }
        let channel = state.currentChannel
        if standalone {
            // Multiview lives in the main window: close this one and bring that forward.
            NSApp.keyWindow?.close()
            openWindow(id: "main")
        }
        state.startMultiview(with: channel)
    }

    private func showBanner() {
        bannerVisible = true
        bannerTask?.cancel()
        bannerTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            bannerVisible = false
        }
    }

    private func showControls() {
        controlsVisible = true
        NSCursor.unhide()
        controlsTask?.cancel()
        controlsTask = Task {
            try? await Task.sleep(for: .seconds(3))
            // Stay up while the pointer is on the controls or playback is paused.
            guard !Task.isCancelled, !hoveringControls, controller.phase != .paused else { return }
            controlsVisible = false
            if controller.phase == .playing { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }

    private func loadNowNext() async {
        guard let ref = state.currentChannel?.epg else {
            nowNext = nil
            return
        }
        while !Task.isCancelled {
            nowNext = (try? await state.guide.nowNext(for: [ref]))?[ref]
            // Refresh when the current programme ends (or every minute).
            let wait = max(5, min(60, (nowNext?.now?.stop.timeIntervalSinceNow ?? 60) + 1))
            try? await Task.sleep(for: .seconds(wait))
        }
    }
}

// MARK: - Banner and controls

/// Channel change banner in the top-left corner: logo, number, name, now/next with progress.
struct InfoBanner: View {
    let channel: ChannelListItem
    let nowNext: NowNext?
    let controller: PlaybackController

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ChannelLogo(name: channel.name, url: channel.logoURL, maxPixelSize: 112)
                .frame(width: 60, height: 42)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let number = channel.number {
                        Text("\(number)").font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(channel.name).font(.headline).lineLimit(1)
                    StreamBadges(metrics: controller.metrics).padding(.leading, 2)
                }
                if let now = nowNext?.now {
                    HStack {
                        Text(now.title).font(.subheadline).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(now.start.formatted(date: .omitted, time: .shortened)) – \(now.stop.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: nowNext?.progress() ?? 0).controlSize(.mini).tint(.white)
                    if let next = nowNext?.next {
                        Text("Next: \(next.title) at \(next.start.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text("No programme information").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 440, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }
}

/// Title and scrubber for movies and episodes, shown above the buttons.
struct VODScrubber: View {
    let controller: PlaybackController
    let title: String

    var body: some View {
        let position = controller.metrics?.position ?? 0
        let duration = controller.metrics?.duration ?? 0
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title).font(.headline).lineLimit(1)
                StreamBadges(metrics: controller.metrics)
            }
            HStack(spacing: 10) {
                Text(Self.format(position)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Slider(value: Binding(get: { position }, set: { controller.seek(to: $0) }), in: 0...max(duration, 1))
                    .controlSize(.small)
                    .tint(.white)
                Text("-" + Self.format(max(0, duration - position))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The floating control bar at the bottom of the player.
struct ControlsBar: View {
    let state: AppState
    let controller: PlaybackController
    let isFullScreen: Bool
    let close: () -> Void
    let toggleFullScreen: () -> Void
    let openMultiview: () -> Void
    let seek: (Double) -> Void

    private var isLive: Bool { controller.item?.isLive ?? true }
    private var isPaused: Bool { controller.phase == .paused }

    var body: some View {
        VStack(spacing: 4) {
            if !isLive, let item = controller.item {
                VODScrubber(controller: controller, title: item.title)
            }
            HStack(spacing: 2) {
                Button(action: close) { Image(systemName: "xmark") }
                    .help("Close Player (Esc)")
                ControlSeparator()
                if isLive {
                    Button { state.zap(by: -1) } label: { Image(systemName: "chevron.up") }
                        .help("Previous Channel (↑)")
                    Button { state.zap(by: 1) } label: { Image(systemName: "chevron.down") }
                        .help("Next Channel (↓)")
                    Button { state.lastChannel() } label: { Image(systemName: "arrow.uturn.backward") }
                        .help("Last Channel (⌫ or L)")
                        .disabled(state.previousChannel == nil)
                } else {
                    Button { seek(-10) } label: { Image(systemName: "gobackward.10") }
                        .help("Back 10 Seconds (←)")
                }
                Button {
                    if isPaused { controller.resume() } else { controller.pause() }
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PlayerControlStyle(size: 40))
                .help(isPaused ? "Play (Space)" : "Pause (Space)")
                if isLive {
                    LiveBadge(isPaused: isPaused).padding(.leading, 6)
                } else {
                    Button { seek(30) } label: { Image(systemName: "goforward.30") }
                        .help("Forward 30 Seconds (→)")
                }
                Spacer(minLength: 16)
                Button { state.showDiagnostics.toggle() } label: {
                    Image(systemName: state.showDiagnostics ? "info.circle.fill" : "info.circle")
                }
                .help(state.showDiagnostics ? "Hide Stream Info (D)" : "Stream Info (D)")
                TracksMenu(controller: controller)
                VolumeControl(controller: controller)
                ControlSeparator()
                if isLive {
                    Button { state.showGuideOverlay = true } label: { Image(systemName: "calendar.day.timeline.left") }
                        .help("Guide (G)")
                    Button(action: openMultiview) { Image(systemName: "square.grid.2x2") }
                        .help("Multiview (M)")
                }
                if let pip = controller.engine as? PictureInPictureCapable, pip.canPictureInPicture {
                    Button { pip.togglePictureInPicture() } label: { Image(systemName: "pip.enter") }
                        .help("Picture in Picture")
                }
                Button(action: toggleFullScreen) {
                    Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(isFullScreen ? "Exit Full Screen (F)" : "Full Screen (F)")
            }
        }
        .buttonStyle(PlayerControlStyle())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 760)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }
}

/// Round, borderless player button with a hover highlight.
struct PlayerControlStyle: ButtonStyle {
    var size: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        PlayerControlBody(configuration: configuration, size: size)
    }

    private struct PlayerControlBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.42, weight: .semibold))
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.24 : (hovering && isEnabled ? 0.13 : 0))))
                .contentShape(Circle())
                .foregroundStyle(.white.opacity(isEnabled ? 0.95 : 0.35))
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

struct ControlSeparator: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 18).padding(.horizontal, 6)
    }
}

/// Red LIVE pill; greys out while paused.
private struct LiveBadge: View {
    let isPaused: Bool

    var body: some View {
        Text("LIVE")
            .font(.system(size: 10, weight: .heavy))
            .tracking(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isPaused ? Color.white.opacity(0.25) : Color.red, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundStyle(.white)
            .help(isPaused ? "Paused" : "Live")
    }
}

/// Mute button whose icon follows the level, plus a small slider.
private struct VolumeControl: View {
    let controller: PlaybackController

    private var icon: String {
        let volume = controller.volume
        if controller.isMuted || volume <= 0.001 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 2) {
            Button { controller.isMuted.toggle() } label: {
                Image(systemName: icon).contentTransition(.symbolEffect(.replace))
            }
            .help(controller.isMuted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { controller.isMuted ? 0 : controller.volume },
                                  set: { controller.volume = $0; if $0 > 0 { controller.isMuted = false } }),
                   in: 0...1)
                .controlSize(.mini)
                .tint(.white)
                .frame(width: 80)
                .padding(.trailing, 4)
        }
    }
}

/// Audio and subtitle track selection.
struct TracksMenu: View {
    let controller: PlaybackController

    var body: some View {
        let _ = controller.tracksVersion
        let tracks = controller.tracks()
        let audio = tracks.filter { $0.kind == .audio }
        let subtitles = tracks.filter { $0.kind == .subtitle }
        Menu {
            Section("Audio") {
                ForEach(audio) { track in
                    Button { controller.select(track, kind: .audio) } label: {
                        if track.isSelected { Label(track.displayName, systemImage: "checkmark") } else { Text(track.displayName) }
                    }
                }
            }
            Section("Subtitles") {
                Button { controller.select(nil, kind: .subtitle) } label: {
                    if !subtitles.contains(where: \.isSelected) { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                }
                ForEach(subtitles) { track in
                    Button { controller.select(track, kind: .subtitle) } label: {
                        if track.isSelected { Label(track.displayName, systemImage: "checkmark") } else { Text(track.displayName) }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(audio.count < 2 && subtitles.isEmpty)
        .help("Audio and subtitles")
    }
}
