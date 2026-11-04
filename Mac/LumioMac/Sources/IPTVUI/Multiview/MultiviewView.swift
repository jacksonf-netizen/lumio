import AppKit
import SwiftUI
import IPTVCore

/// Multiview: 2–4 live tiles filling the window, opened from the player (M). Like the player, the
/// window chrome and controls fade away until the mouse moves.
///
/// Keys: Esc back to the player (on the tile you're hearing) · 1–4 hear that tile · F full screen.
struct MultiviewScreen: View {
    @Bindable var model: MultiviewModel
    let state: AppState
    @State private var pickingTile: Int?
    @State private var controlsVisible = true
    @State private var controlsTask: Task<Void, Never>?
    @State private var hoveringControls = false
    @State private var isFullScreen = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            grid
                .padding(4)

            VStack(spacing: 10) {
                if let warning = model.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .symbolRenderingMode(.multicolor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.orange.opacity(0.5)))
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                        .frame(maxWidth: 640)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if controlsVisible {
                    controlBar
                        .onHover { inside in
                            hoveringControls = inside
                            if !inside { showControls() }
                        }
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(.black)
        .environment(\.colorScheme, .dark)
        .background(PlayerWindowChrome(controlsVisible: controlsVisible))
        .animation(.easeInOut(duration: 0.25), value: model.warning)
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in handle(press) }
        .onContinuousHover { phase in
            if case .active = phase { showControls() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in isFullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in isFullScreen = false }
        .sheet(item: Binding(get: { pickingTile.map(TileRef.init) }, set: { pickingTile = $0?.index })) { ref in
            ChannelPicker(state: state) { channel in
                model.setChannel(channel, forTile: ref.index)
            }
        }
        .onChange(of: pickingTile) { _, picking in if picking == nil { focused = true } }
        .onAppear {
            isFullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false
            focused = true
            showControls()
            if !model.isActive { model.start(with: nil) }
        }
        .onDisappear {
            controlsTask?.cancel()
            NSCursor.unhide()
            Task { await model.stopAll() }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 2) {
            Button { state.exitMultiview() } label: { Image(systemName: "chevron.backward") }
                .help("Back to the player, on the tile you're hearing (Esc)")
            ControlSeparator()
            Text("Multiview")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8)
            Spacer(minLength: 16)
            Picker("Layout", selection: $model.layout) {
                Image(systemName: "rectangle.split.2x1").tag(2)
                Image(systemName: "rectangle.split.3x1").tag(3)
                Image(systemName: "square.grid.2x2").tag(4)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Number of tiles")
            Spacer(minLength: 16)
            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .help(isFullScreen ? "Exit Full Screen (F)" : "Full Screen (F)")
            Button { state.closeMultiview() } label: { Image(systemName: "xmark") }
                .help("Close Multiview and stop all tiles")
        }
        .buttonStyle(PlayerControlStyle())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard pickingTile == nil else { return .ignored }
        if press.key == .escape {
            state.exitMultiview()
            return .handled
        }
        let key = press.characters.lowercased()
        if let digit = Int(key), (1...model.layout).contains(digit) {
            model.focusAudio(digit - 1)
            showControls()
            return .handled
        }
        if key == "f" {
            NSApp.keyWindow?.toggleFullScreen(nil)
            return .handled
        }
        return .ignored
    }

    private func showControls() {
        controlsVisible = true
        NSCursor.unhide()
        controlsTask?.cancel()
        controlsTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !hoveringControls, pickingTile == nil else { return }
            controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    struct TileRef: Identifiable {
        let index: Int
        var id: Int { index }
    }

    @ViewBuilder
    private var grid: some View {
        let tiles = model.visibleTiles
        GeometryReader { geometry in
            let columns = tiles.count == 2 ? 2 : (tiles.count == 3 ? 3 : 2)
            let rows = tiles.count == 4 ? 2 : 1
            let size = CGSize(width: geometry.size.width / CGFloat(columns), height: geometry.size.height / CGFloat(rows))
            ZStack(alignment: .topLeading) {
                ForEach(Array(tiles.enumerated()), id: \.element.id) { position, tile in
                    TileView(tile: tile, model: model, state: state, isAudio: model.audioTile == tile.index,
                             pick: { pickingTile = tile.index })
                        .frame(width: size.width - 4, height: size.height - 4)
                        .offset(x: CGFloat(position % columns) * size.width + 2, y: CGFloat(position / columns) * size.height + 2)
                }
            }
        }
    }
}

private struct TileView: View {
    let tile: MultiviewModel.Tile
    let model: MultiviewModel
    let state: AppState
    let isAudio: Bool
    let pick: () -> Void
    @State private var hovering = false

    /// The tile's label bar shows on hover, and stays up when the tile needs attention.
    private var showsHeader: Bool {
        hovering || tile.assignedProvider == nil
    }

    var body: some View {
        ZStack {
            if tile.channel != nil {
                PlayerView(controller: tile.controller, compact: true)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if let channel = tile.channel { state.watchFromMultiview(channel) }
                    }
                    .onTapGesture { model.focusAudio(tile.index) }
            } else {
                Button(action: pick) {
                    VStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .medium))
                            .frame(width: 52, height: 52)
                            .background(.white.opacity(hovering ? 0.16 : 0.08), in: Circle())
                        Text("Add Channel").font(.callout.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.6))
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .padding(10)
                }
            }
            if tile.channel != nil {
                VStack {
                    HStack(spacing: 6) {
                        Image(systemName: isAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .foregroundStyle(isAudio ? .white : .white.opacity(0.5))
                            .help(isAudio ? "Playing this tile's sound" : "Click the tile to hear it")
                        Text(tile.channel?.name ?? "").font(.callout.weight(.semibold)).lineLimit(1)
                        providerMenu
                        Spacer()
                        Button(action: pick) { Image(systemName: "arrow.left.arrow.right") }
                            .buttonStyle(PlayerControlStyle(size: 26))
                            .help("Change channel")
                        Button { model.clearTile(tile.index) } label: { Image(systemName: "xmark") }
                            .buttonStyle(PlayerControlStyle(size: 26))
                            .help("Close tile")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 18)
                    .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
                    .opacity(showsHeader ? 1 : 0)
                    Spacer()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isAudio && tile.channel != nil ? Color.accentColor : .clear, lineWidth: 2)
        }
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.18), value: showsHeader)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var providerMenu: some View {
        let name = tile.assignedProvider.map(state.live.providerName) ?? "No connection"
        return Menu {
            Button { model.pinProvider(nil, forTile: tile.index) } label: {
                tile.pinnedProvider == nil ? Label("Automatic", systemImage: "checkmark") : Label("Automatic", systemImage: "")
            }
            Divider()
            ForEach(model.providers(forTile: tile.index), id: \.self) { provider in
                Button { model.pinProvider(provider, forTile: tile.index) } label: {
                    if tile.pinnedProvider == provider {
                        Label(state.live.providerName(provider), systemImage: "checkmark")
                    } else {
                        Text(state.live.providerName(provider))
                    }
                }
            }
        } label: {
            Text(name)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(tile.assignedProvider == nil ? Color.orange.opacity(0.6) : Color.white.opacity(0.2), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Provider for this tile")
    }
}

/// Searchable list of all channels.
struct ChannelPicker: View {
    let state: AppState
    let onPick: (ChannelListItem) -> Void
    @State private var query = ""
    @State private var channels: [ChannelListItem] = []
    @State private var selection: ChannelListItem.ID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a Channel").font(.headline)
            TextField("Search", text: $query).textFieldStyle(.roundedBorder)
            List(filtered, selection: $selection) { channel in
                HStack {
                    ChannelLogo(name: channel.name, url: channel.logoURL, maxPixelSize: 64).frame(width: 38, height: 26)
                    Text(channel.name)
                    Spacer()
                    if channel.sourceProviders.count > 1 {
                        Text("\(channel.sourceProviders.count) sources").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(channel.id)
            }
            .frame(width: 440, height: 360)
            .contextMenu(forSelectionType: ChannelListItem.ID.self) { _ in EmptyView() } primaryAction: { ids in
                choose(ids.first)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose") { choose(selection) }.keyboardShortcut(.defaultAction).disabled(selection == nil)
            }
        }
        .padding(20)
        .task { channels = (try? await state.liveCatalog.allChannels()) ?? [] }
    }

    private var filtered: [ChannelListItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return Array((q.isEmpty ? channels : channels.filter { $0.name.localizedCaseInsensitiveContains(q) }).prefix(300))
    }

    private func choose(_ id: ChannelListItem.ID?) {
        guard let channel = channels.first(where: { $0.id == id }) else { return }
        onPick(channel)
        dismiss()
    }
}
