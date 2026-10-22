#if DEBUG
import AppKit
import SwiftUI
import IPTVCore
import IPTVPlayback

/// Development-only end-to-end check of the real app against the stream harness. Launch with:
///
///   "…/Lumio.app/Contents/MacOS/Lumio" -databaseName smoke -smokeTest http://127.0.0.1:8098
///
/// Prints `SMOKE` lines and saves window snapshots, then quits. Uses a separate database.
@MainActor
public enum SmokeTest {
    public static func runIfRequested(state: AppState) {
        if UserDefaults.standard.integer(forKey: "soakMinutes") > 0, let base = UserDefaults.standard.string(forKey: "smokeTest"),
           let url = URL(string: base) {
            Task { @MainActor in
                await soak(state: state, harness: url, minutes: UserDefaults.standard.integer(forKey: "soakMinutes"),
                           tiles: UserDefaults.standard.integer(forKey: "soakTiles"))
                exit(0)
            }
            return
        }
        if let base = UserDefaults.standard.string(forKey: "layoutTest"), let url = URL(string: base) {
            Task { @MainActor in
                await layout(state: state, harness: url)
                exit(0)
            }
            return
        }
        // `-playProbe URL -probeChannel N -probeSeconds S`: play one harness channel full screen and
        // log buffering, frame drops and decoding every two seconds.
        if let base = UserDefaults.standard.string(forKey: "playProbe"), let url = URL(string: base) {
            Task { @MainActor in
                await playProbe(state: state, harness: url)
                exit(0)
            }
            return
        }
        // `-guideClipTest YES` (with IPTV_DEV_SEED=1): scroll the guide and check nothing it draws
        // shows outside its own area.
        if UserDefaults.standard.bool(forKey: "guideClipTest") {
            Task { @MainActor in
                await guideClip(state: state)
                exit(0)
            }
            return
        }
        if UserDefaults.standard.bool(forKey: "perfTest") {
            Task { @MainActor in
                await perf(state: state)
                exit(0)
            }
            return
        }
        // `-openSection settings` (any sidebar section): open on that section.
        if let section = UserDefaults.standard.string(forKey: "openSection").flatMap(SidebarItem.init(rawValue:)) {
            state.section = section
        }
        // `-snapshotAfter SECONDS`: saves the whole window, toolbar included, as smoke-window.png.
        let delay = UserDefaults.standard.double(forKey: "snapshotAfter")
        if delay > 0 {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                snapshot("window", includingToolbar: true)
                // As the window server draws it (materials included); an app may capture its
                // own windows without screen-recording permission.
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }),
                   let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
                    save(NSBitmapImageRep(cgImage: image), to: FileManager.default.temporaryDirectory.appendingPathComponent("smoke-screen.png"))
                }
            }
        }
        // `-harness URL`: add the harness as a provider and sync it, then leave the app for manual use.
        if let base = UserDefaults.standard.string(forKey: "harness"), let url = URL(string: base) {
            Task { @MainActor in
                let service = state.environment.providers
                if let provider = try? await service.addProvider(
                    name: "Harness", serverURL: url.absoluteString, credentials: ProviderCredentials(username: "test", password: "test")) {
                    await state.environment.sync.refresh(provider.id)
                }
            }
            return
        }
        guard let base = UserDefaults.standard.string(forKey: "smokeTest"), let url = URL(string: base) else { return }
        Task { @MainActor in
            await run(state: state, harness: url)
            exit(0)
        }
    }

    private static func playProbe(state: AppState, harness: URL) async {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        let service = state.environment.providers
        var provider = (try? service.repository.all())?.first { $0.serverURL.port == harness.port }
        if provider == nil {
            provider = try? await service.addProvider(name: "Harness", serverURL: harness.absoluteString,
                                                      credentials: ProviderCredentials(username: "test", password: "test"))
        }
        guard let provider else { return log("FAIL could not add provider") }
        await state.environment.sync.refresh(provider.id, parts: [.account, .live])
        _ = try? state.environment.logicalChannels.rebuild()
        let streamID = UserDefaults.standard.integer(forKey: "probeChannel")
        let seconds = max(10, UserDefaults.standard.integer(forKey: "probeSeconds"))
        guard let channel = ((try? await state.liveCatalog.allChannels()) ?? []).first(where: { $0.streamID == streamID })
        else { return log("FAIL no channel \(streamID)") }
        let started = Date()
        state.watch(channel, in: [channel])
        var stalls = 0
        var last = state.hub.main.phase
        for _ in 0..<(seconds * 4) {
            try? await Task.sleep(for: .milliseconds(500))
            let phase = state.hub.main.phase
            if phase != last, phase != .playing, last == .playing { stalls += 1 }
            last = phase
            let elapsed = Date().timeIntervalSince(started)
            guard Int(elapsed * 2) % 4 == 0, let m = state.hub.main.metrics else { continue }
            log(String(format: "%5.1fs %@ phase=%@ buffer=%.1fs drops=%d fps=%.1f %@ %dx%d hw=%@ kbps=%.0f",
                       elapsed, channel.name, "\(phase)", m.bufferSeconds ?? -1, m.droppedFrames ?? -1, m.fps ?? -1,
                       m.videoCodec ?? "-", m.width ?? 0, m.height ?? 0, m.hardwareDecoder ?? "-", m.bitrateKbps ?? -1))
        }
        log("probe done: \(channel.name) stalls=\(stalls) drops=\(state.hub.main.metrics?.droppedFrames ?? -1)")
        state.closePlayer()
        try? await Task.sleep(for: .seconds(1))
    }

    private static func guideClip(state: AppState) async {
        // The guide grid alone, on a plain red background: after scrolling, nothing but red may
        // show above or below it.
        let channels = (try? await state.liveCatalog.allChannels()) ?? []
        guard channels.count > 50 else { return log("FAIL needs IPTV_DEV_SEED=1 (got \(channels.count) channels)") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.red.cgColor
        window.contentView = root
        let container = GuideContainerView(frame: NSRect(x: 0, y: 150, width: 900, height: 400))
        root.addSubview(container)
        container.layoutSubtreeIfNeeded()
        container.grid.channels = channels
        window.orderFront(nil)
        try? await Task.sleep(for: .milliseconds(300))
        func strayPixels() -> Int {
            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return -1 }
            root.cacheDisplay(in: root.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / root.bounds.width
            guard let background = rep.colorAt(x: 2, y: 2) else { return -1 }
            var stray = 0
            for y in Array(stride(from: 100, to: 149, by: 4)) + Array(stride(from: 551, to: 650, by: 4)) {
                for x in stride(from: 10, to: 890, by: 20) {
                    guard let color = rep.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale)) else { continue }
                    if color != background { stray += 1 }
                }
            }
            return stray
        }
        let clip = container.scrollView.contentView
        for y in [0.0, 1003.0, 2021.0, 3517.0] {
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
            container.scrollView.reflectScrolledClipView(clip)
            container.grid.display()
            try? await Task.sleep(for: .milliseconds(300))
            let stray = strayPixels()
            log("\(stray == 0 ? "" : "FAIL ")guide scrolled to \(Int(y)): \(stray) pixels drawn outside the guide")
        }
        if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: rep)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("smoke-12-guide-clip.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            log("snapshot \(url.path)")
        }
        window.close()
    }

    /// Logos load from the provider; oversized images and local files are refused.
    private static func imageSafety(state: AppState, harness: URL, t: () -> String) async {
        let channels = (try? await state.liveCatalog.allChannels()) ?? []
        guard let logo = channels.compactMap(\.logoURL).first else { return log("\(t()) FAIL no channel logos") }
        let loaded = await ImageCache.shared.image(for: logo, maxPixelSize: 128)
        let started = Date()
        let huge = await ImageCache.shared.image(for: harness.appendingPathComponent("huge.png"))
        let hugeTime = Date().timeIntervalSince(started)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("smoke-logo.png")
        if let data = try? Data(contentsOf: logo) { try? data.write(to: file) }
        let local = await ImageCache.shared.image(for: file)
        let ok = loaded != nil && huge == nil && local == nil
        log("\(t()) \(ok ? "" : "FAIL ")images: logo loaded=\(loaded != nil) 40 MB image refused=\(huge == nil) in \(String(format: "%.2f", hugeTime))s local file refused=\(local == nil)")
    }

    /// The guide overlay and stream info close with the keyboard even while the guide has focus.
    private static func overlaysClose(state: AppState, t: () -> String) async {
        func press(_ key: String, code: UInt16) {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: key,
                                               charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)
            else { return }
            window.sendEvent(event)
        }
        for (name, key, code) in [("Esc", "\u{1b}", UInt16(53)), ("G", "g", UInt16(5))] {
            state.showGuideOverlay = true
            try? await Task.sleep(for: .seconds(1.2))
            // As after clicking into it: the guide grid has keyboard focus.
            let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible)
            let grid = window?.contentView.flatMap { find(GuideGridView.self, in: $0) }
            if let grid { window?.makeFirstResponder(grid) }
            press(key, code: code)
            try? await Task.sleep(for: .milliseconds(500))
            log("\(t()) \(state.showGuideOverlay ? "FAIL " : "")guide overlay closes with \(name) while focused (grid found: \(grid != nil))")
            state.showGuideOverlay = false
        }
        try? await Task.sleep(for: .milliseconds(500))
        state.showDiagnostics = true
        try? await Task.sleep(for: .milliseconds(400))
        press("\u{1b}", code: 53)
        try? await Task.sleep(for: .milliseconds(400))
        log("\(t()) \(state.showDiagnostics || !state.isPlayerPresented ? "FAIL " : "")stream info closes with Esc and the player stays open")
        state.showDiagnostics = false
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews { if let match = find(type, in: subview) { return match } }
        return nil
    }

    private static func log(_ text: String) {
        print("SMOKE \(text)")
        fflush(stdout)
    }

    private static var activeState: AppState?

    private static func run(state: AppState, harness: URL) async {
        activeState = state
        let started = Date()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        func t() -> String { String(format: "%5.1fs", Date().timeIntervalSince(started)) }
        try? await Task.sleep(for: .seconds(1))
        log("\(t()) \(state.section == .recents ? "" : "FAIL ")opens on \(state.section.rawValue)")

        // 1. Provider
        let service = state.environment.providers
        var provider = (try? service.repository.all())?.first { $0.serverURL.port == harness.port }
        if provider == nil {
            provider = try? await service.addProvider(name: "Harness", serverURL: harness.absoluteString,
                                                      credentials: ProviderCredentials(username: "test", password: "test"))
        }
        guard let provider else { return log("FAIL could not add provider") }
        let report = await state.environment.sync.refresh(provider.id)
        log("\(t()) sync error=\(report.error ?? "none") live=\(report.live.map { "\($0.inserted + $0.unchanged + $0.updated)" } ?? "-") guide=\(report.guide?.programmesStored ?? -1)")
        await state.environment.connections.setLimit((try? service.repository.provider(id: provider.id))?.maxConnections, for: provider.id)

        // 2. Live TV list and preview
        state.section = .liveTV
        state.live.reloadGroups()
        try? await Task.sleep(for: .seconds(1.5))
        log("\(t()) groups=\(state.live.groups.map(\.name)) channels=\(state.live.channels.map(\.name))")
        guard let first = state.live.channels.first else { return log("FAIL no channels") }
        state.live.selectedChannelID = first.id
        _ = await waitFor(8) { state.hub.preview.phase == .playing }
        log("\(t()) preview phase=\(state.hub.preview.phase) engine=\(state.hub.preview.plan?.description ?? "-")")
        try? await Task.sleep(for: .seconds(1))
        snapshot("1-live-tv")

        // 3. Full screen, first-frame time
        let watchStart = Date()
        state.watch(first, in: state.live.channels)
        _ = await waitFor(10) { state.hub.main.phase == .playing }
        log("\(t()) main phase=\(state.hub.main.phase) firstFrame=\(String(format: "%.2f", Date().timeIntervalSince(watchStart)))s preview=\(state.hub.preview.phase)")
        snapshot("2-player-controls") // the controls are still up from opening the player
        try? await Task.sleep(for: .seconds(2))
        state.showDiagnostics = true
        try? await Task.sleep(for: .seconds(1))
        log("\(t()) metrics=\(state.hub.main.metrics.map { "\($0.videoCodec ?? "-") \($0.width ?? 0)x\($0.height ?? 0) hw=\($0.hardwareDecoder ?? "-") drops=\($0.droppedFrames ?? -1)" } ?? "-")")
        snapshot("2-player")
        state.showDiagnostics = false
        log("\(t()) banner badges: \(StreamBadges.labels(state.hub.main.metrics))")
        await overlaysClose(state: state, t: t)

        // Full screen: the video surface should cover the screen and mpv should draw at its size.
        log("\(t()) windowed \(videoGeometry())")
        let playerWindow = NSApp.windows.first { $0.isVisible && $0.frame.width > 400 }
        playerWindow?.toggleFullScreen(nil)
        _ = await waitFor(6) { playerWindow?.styleMask.contains(.fullScreen) == true }
        try? await Task.sleep(for: .seconds(1.5))
        log("\(t()) fullscreen \(videoGeometry())")
        playerWindow?.toggleFullScreen(nil)
        _ = await waitFor(6) { playerWindow?.styleMask.contains(.fullScreen) == false }
        try? await Task.sleep(for: .seconds(1))
        log("\(t()) restored \(videoGeometry())")
        // The narrowest window allowed: the player must still fit it exactly.
        if let playerWindow {
            var frame = playerWindow.frame
            frame.size = playerWindow.minSize
            playerWindow.setFrame(frame, display: true)
            try? await Task.sleep(for: .seconds(1))
            log("\(t()) resized \(videoGeometry())")
        }

        // 4. Zapping: rapid down-presses should open only the final channel.
        for _ in 0..<5 {
            state.zap(by: 1)
            try? await Task.sleep(for: .milliseconds(80))
        }
        _ = await waitFor(10) { state.hub.main.phase == .playing }
        let harnessState = await control(harness, "state")
        log("\(t()) after zapping: channel=\(state.currentChannel?.name ?? "-") phase=\(state.hub.main.phase) harness=\(harnessState)")
        state.lastChannel()
        _ = await waitFor(10) { state.hub.main.phase == .playing }
        log("\(t()) last channel: \(state.currentChannel?.name ?? "-")")

        // 5. Stall → reconnect → recover
        _ = await control(harness, "stall")
        let recovering = await waitFor(25) { state.hub.main.phase.isRecovering }
        log("\(t()) stall detected=\(recovering) phase=\(state.hub.main.phase)")
        _ = await control(harness, "normal")
        let recovered = await waitFor(20) { state.hub.main.phase == .playing }
        log("\(t()) recovered=\(recovered) reconnects=\(state.hub.main.reconnectCount)")

        // 6. Guide
        state.closePlayer()
        try? await Task.sleep(for: .seconds(1))
        state.section = .guide
        try? await Task.sleep(for: .seconds(2.5))
        snapshot("3-guide")

        // 7. Multiview: opened from the player, over the whole window; four tiles.
        let sectionBefore = state.section
        state.startMultiview(with: first)
        try? await Task.sleep(for: .seconds(1))
        log("\(t()) \(state.isMultiviewPresented && !state.isPlayerPresented && state.section == sectionBefore ? "" : "FAIL ")multiview opened from the player (section stays \(state.section.rawValue))")
        let others = state.live.channels.filter { $0.id != first.id }
        for (index, channel) in others.prefix(3).enumerated() {
            state.multiview.setChannel(channel, forTile: index + 1)
            try? await Task.sleep(for: .milliseconds(300))
        }
        _ = await waitFor(12) { state.multiview.visibleTiles.filter { $0.channel != nil }.allSatisfy { $0.controller.phase == .playing } }
        let tiles = state.multiview.visibleTiles.map { "\($0.channel?.name ?? "empty"):\($0.controller.phase):\($0.assignedProvider?.rawValue.prefix(6) ?? "-")" }
        log("\(t()) after closing player: \(videoGeometry().components(separatedBy: " video=")[0])")
        log("\(t()) multiview tiles=\(tiles) warning=\(state.multiview.warning ?? "none") harness=\(await control(harness, "state"))")
        try? await Task.sleep(for: .seconds(1))
        snapshot("4-multiview")

        // Double-clicking a tile goes back to the full-window player on that channel. Every
        // connection is in use here, so the tiles must close before the player opens its stream.
        let refusedBefore = await refusedCount(harness)
        let switchStart = Date()
        state.watchFromMultiview(first)
        let backToPlayer = await waitFor(10) { state.hub.main.phase == .playing }
        let refused = await refusedCount(harness) - refusedBefore
        let tilesActive = state.multiview.tiles.filter { $0.controller.phase != .idle }.count
        let overlays = !state.isMultiviewPresented && state.isPlayerPresented
        log("\(t()) \(backToPlayer && refused == 0 && tilesActive == 0 && overlays ? "" : "FAIL ")tile → player: multiviewShown=\(state.isMultiviewPresented) playerShown=\(state.isPlayerPresented) main=\(state.hub.main.phase) in \(String(format: "%.2f", Date().timeIntervalSince(switchStart)))s tilesActive=\(tilesActive) refusedByProvider=\(refused) leases=\(await state.environment.connections.totalInUse)")
        state.closePlayer()
        try? await Task.sleep(for: .seconds(1.5))
        let inUse = await state.environment.connections.totalInUse
        log("\(t()) after stopping multiview: leases=\(inUse) harness=\(await control(harness, "state"))")

        await imageSafety(state: state, harness: harness, t: t)
        await vod(state: state, providerID: provider.id, t: t)
        await libraryPages(state: state, t: t)
        await regions(state: state, t: t)

        // Search and backup
        let searchStart = Date()
        let found = (try? await SearchRepository(database: state.environment.database).search("harness")) ?? SearchResults()
        log("\(t()) search 'harness': channels=\(found.channels.count) programmes=\(found.programmes.count) movies=\(found.movies.count) series=\(found.series.count) in \(Int(Date().timeIntervalSince(searchStart) * 1000)) ms")
        state.section = .search
        try? await Task.sleep(for: .seconds(1))
        snapshot("7-search")
        if let backup = try? await BackupService(database: state.environment.database).export() {
            let text = String(decoding: backup, as: UTF8.self)
            log("\(t()) backup \(backup.count) bytes, contains credentials=\(text.contains("\"password\"") || text.contains("test:test"))")
        }

        if let second = UserDefaults.standard.string(forKey: "smokeTestB").flatMap(URL.init(string:)) {
            await twoProviders(state: state, a: harness, b: second, t: t)
        }
        if let moved = UserDefaults.standard.string(forKey: "smokeTestMoved") {
            await panelMove(state: state, providerID: provider.id, to: moved, t: t)
        }
        // Settings → About → Acknowledgements, the short list and the full licence texts.
        snapshot(NoticesSheet(), "12-acknowledgements")
        snapshot(NoticesSheet(showingFullTexts: true), "12-acknowledgements-full")
        log("\(t()) done")
    }

    /// The provider moves to another panel (start a harness with --renumber): favorites, recents
    /// and progress should follow the new IDs.
    private static func panelMove(state: AppState, providerID: ProviderID, to url: String, t: () -> String) async {
        let database = state.environment.database
        func rows(_ sql: String) -> [String] {
            (try? database.reader.read { try String.fetchAll($0, sql: sql, arguments: [providerID.rawValue]) }) ?? []
        }
        let channels = (try? state.environment.catalog.channels(providerID: providerID)) ?? []
        for channel in channels.prefix(2) {
            try? await state.library.setFavorite(true, kind: .channel, providerID: providerID, itemID: String(channel.streamID))
        }
        try? await state.library.setFavorite(true, kind: .movie, providerID: providerID, itemID: "900")
        try? await state.library.setFavorite(true, kind: .series, providerID: providerID, itemID: "950")
        try? await state.library.saveProgress(kind: .episode, providerID: providerID, itemID: "951", position: 30, duration: 120)
        let query = "SELECT itemKind || ':' || itemID FROM %@ WHERE providerID = ? ORDER BY itemKind, itemID"
        let before = (favorites: rows(String(format: query, "favorite")), recents: rows(String(format: query, "recentItem")),
                      progress: rows(String(format: query, "watchProgress")))
        log("\(t()) before panel move: favorites=\(before.favorites) recents=\(before.recents) progress=\(before.progress)")

        guard let provider = try? state.environment.providers.repository.provider(id: providerID) else { return }
        try? await state.environment.providers.updateProvider(provider, serverURL: url)
        let report = await state.environment.sync.refresh(providerID, parts: .catalog)
        let after = (favorites: rows(String(format: query, "favorite")), recents: rows(String(format: query, "recentItem")),
                     progress: rows(String(format: query, "watchProgress")))
        // Every entry moved by the harness's offset (500), none lost.
        func shifted(_ entries: [String]) -> [String] {
            entries.map { entry in
                let parts = entry.split(separator: ":", maxSplits: 1)
                return "\(parts[0]):\((Int(parts[1]) ?? 0) + 500)"
            }.sorted()
        }
        let ok = after.favorites.sorted() == shifted(before.favorites) && after.recents.sorted() == shifted(before.recents)
            && after.progress.sorted() == shifted(before.progress) && !before.favorites.isEmpty
        log("\(t()) \(ok ? "" : "FAIL ")after panel move: favorites=\(after.favorites) recents=\(after.recents) progress=\(after.progress) relinked live=\(report.live?.relinked ?? -1) movies=\(report.movies?.relinked ?? -1) series=\(report.series?.relinked ?? -1)")
        let shown = ((try? await state.liveCatalog.channels(in: ChannelGroup(id: "favorites", name: "Favorites", kind: .favorites))) ?? []).map(\.name)
        let continuing = ((try? await state.vod.recentlyWatched(.series)) ?? []).map(\.itemID)
        let channelFavorites = before.favorites.filter { $0.hasPrefix("channel:") }.count
        log("\(t()) \(shown.count == channelFavorites && !continuing.isEmpty ? "" : "FAIL ")favorites shown after move: \(shown); series recently watched: \(continuing)")
    }

    /// Movies and series: play, progress, Continue Watching, resume, episodes.
    private static func vod(state: AppState, providerID: ProviderID, t: () -> String) async {
        state.section = .movies
        try? await Task.sleep(for: .seconds(1.5))
        let movies = (try? await state.vod.items(.movie)) ?? []
        let series = (try? await state.vod.items(.series)) ?? []
        log("\(t()) VOD: movies=\(movies.map(\.displayName)) series=\(series.map(\.name))")
        snapshot("5-movies")
        guard let movie = movies.first,
              let item = try? state.environment.items.movieItem(providerID: providerID, streamID: movie.itemID) else { return log("FAIL no movie") }
        state.playVOD(item, kind: .movie, providerID: providerID, itemID: String(movie.itemID))
        _ = await waitFor(10) { state.hub.main.phase == .playing }
        state.hub.main.seek(to: 45)
        try? await Task.sleep(for: .seconds(13))
        let position = state.hub.main.metrics?.position ?? -1
        state.closePlayer()
        try? await Task.sleep(for: .seconds(1.5))
        let saved = try? await state.vod.progress(kind: .movie, providerID: providerID, itemID: String(movie.itemID))
        let continuing = (try? await state.vod.continueWatching()) ?? []
        log("\(t()) movie played to \(Int(position))s; saved=\(Int(saved?.positionSeconds ?? -1))s of \(Int(saved?.durationSeconds ?? -1))s; continue=\(continuing.map(\.title))")

        // Resume picks up from the saved position.
        if let resume = try? state.environment.items.movieItem(providerID: providerID, streamID: movie.itemID, startPosition: saved?.positionSeconds) {
            state.playVOD(resume, kind: .movie, providerID: providerID, itemID: String(movie.itemID))
            _ = await waitFor(10) { state.hub.main.phase == .playing }
            try? await Task.sleep(for: .seconds(2))
            log("\(t()) resumed at \(Int(state.hub.main.metrics?.position ?? -1))s")
            state.closePlayer()
            try? await Task.sleep(for: .seconds(1))
        }

        // Series: fetch episodes from the provider, play one.
        if let show = series.first, let provider = try? state.environment.providers.repository.provider(id: providerID),
           let source = try? state.environment.sources.source(for: provider),
           let details = try? await source.fetchSeriesDetails(seriesID: show.itemID) {
            try? state.environment.catalog.replaceSeriesDetails(details, providerID: providerID, seriesID: show.itemID)
            let next = try? await state.vod.nextEpisode(providerID: providerID, seriesID: show.itemID)
            log("\(t()) series \(show.name): \(details.episodes.count) episodes; next=\(next?.0.title ?? "-")")
            if let episode = next?.0, let playable = try? state.environment.items.episodeItem(providerID: providerID, episodeID: episode.episodeID) {
                state.playVOD(playable, kind: .episode, providerID: providerID, itemID: episode.episodeID)
                let ok = await waitFor(10) { state.hub.main.phase == .playing }
                log("\(t()) episode playing=\(ok) title=\(state.hub.main.item?.title ?? "-")")
                state.closePlayer()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        state.section = .series
        try? await Task.sleep(for: .seconds(1.5))
        snapshot("6-series")

        // Recently Watched rows: the movie (resumable) and the series' last episode.
        let recentMovies = (try? await state.vod.recentlyWatched(.movie)) ?? []
        let recentSeries = (try? await state.vod.recentlyWatched(.series)) ?? []
        let ok = recentMovies.first?.canResume == true && !recentSeries.isEmpty
        log("\(t()) \(ok ? "" : "FAIL ")recently watched: movies=\(recentMovies.map { "\($0.title)\($0.canResume ? " (resume)" : "")" }) series=\(recentSeries.map { "\($0.title) \($0.subtitle ?? "")" })")
        state.section = .movies
        try? await Task.sleep(for: .seconds(1.5))
        snapshot("5b-movies-recent")
    }

    /// Region switches (needs the harness started with --region-prefixes).
    private static func regions(state: AppState, t: () -> String) async {
        let found = (try? await state.library.regions()) ?? []
        guard !found.isEmpty else { return log("\(t()) regions: none (start the harness with --region-prefixes)") }
        log("\(t()) regions: \(found.map { "\($0.code) (\($0.name)): \($0.liveGroups) live groups, seen as \($0.spellings) on \($0.providers)" })")
        let before = ((try? await state.liveCatalog.allChannels()) ?? []).map(\.name)
        let moviesBefore = ((try? await state.vod.items(.movie)) ?? []).count
        try? await state.library.setRegion("US", hidden: true)
        let moviesAfter = ((try? await state.vod.items(.movie)) ?? []).count
        log("\(t()) \(moviesAfter == moviesBefore ? "" : "FAIL ")region switches leave Movies alone: \(moviesBefore) → \(moviesAfter)")
        let groups = ((try? await state.liveCatalog.groups()) ?? []).filter { $0.kind == .category }.map(\.name)
        let after = ((try? await state.liveCatalog.allChannels()) ?? []).map(\.name)
        let ok = !groups.contains { $0.hasPrefix("US") } && after.count < before.count && !after.isEmpty
        log("\(t()) \(ok ? "" : "FAIL ")hid US: groups=\(groups) channels \(before.count) → \(after.count)")
        try? await Task.sleep(for: .seconds(1.5))
        let shown = state.live.groups.filter { $0.kind == .category }.map(\.name)
        log("\(t()) \(shown.contains { $0.hasPrefix("US") } ? "FAIL " : "")Live TV list after hiding US: \(shown)")
        // One group switched back on inside the hidden region, as Settings → Regions does.
        if let single = ((try? await state.library.regionCategories()) ?? [:])["US"]?.first(where: { $0.kind == .live }) {
            try? await state.library.setCategory(single, shown: true)
            try? await Task.sleep(for: .seconds(1.5))
            let names = state.live.groups.filter { $0.kind == .category }.map(\.name)
            log("\(t()) \(names.contains(single.name) ? "" : "FAIL ")single group shown in hidden region: \(names)")
        }
        let other = ((try? await state.library.regions()) ?? []).first { $0.isOther }
        log("\(t()) other groups bucket: \(other.map { "\($0.categoryCount) categories, e.g. \($0.examples)" } ?? "none")")
        UserDefaults.standard.set("regions", forKey: "settingsTab")
        UserDefaults.standard.set(["US"], forKey: "regionsExpanded")
        state.section = .settings
        try? await Task.sleep(for: .seconds(1.5))
        snapshot("10-settings-regions")
        UserDefaults.standard.removeObject(forKey: "regionsExpanded")
        try? await state.library.setRegion("US", hidden: false)
        UserDefaults.standard.set("providers", forKey: "settingsTab")
        let restored = ((try? await state.liveCatalog.allChannels()) ?? []).count
        log("\(t()) \(restored == before.count ? "" : "FAIL ")showed US again: \(restored) channels")
    }

    /// Recents and Favorites pages: newest first, removing, and drag-to-reorder.
    private static func libraryPages(state: AppState, t: () -> String) async {
        let all = (try? await state.liveCatalog.channels(in: ChannelGroup(id: "all", name: "All", kind: .all))) ?? []
        guard all.count >= 3 else { return log("FAIL library pages need 3 channels") }
        let three = Array(all.prefix(3))

        // Recents: watched A, B, C → listed C, B, A.
        try? await state.library.clearRecents([.channel])
        for channel in three {
            try? await state.library.recordPlayed(providerID: channel.providerID, kind: .channel, itemID: String(channel.streamID))
            try? await Task.sleep(for: .milliseconds(50))
        }
        let recents = GuideModel(state: state, scope: .recents)
        recents.reloadChannels()
        _ = await waitFor(5) { recents.loaded && recents.channels.count == 3 }
        let expected = three.reversed().map(\.name)
        log("\(t()) \(recents.channels.map(\.name) == expected ? "" : "FAIL ")recents order=\(recents.channels.map(\.name))")
        state.section = .recents
        try? await Task.sleep(for: .seconds(1.5))
        snapshot("8-recents")
        if let top = recents.channels.first {
            recents.removeFromList(top)
            var gone = false
            for _ in 0..<20 where !gone {
                try? await Task.sleep(for: .milliseconds(250))
                recents.reloadChannels()
                try? await Task.sleep(for: .milliseconds(100))
                gone = !recents.channels.contains { $0.id == top.id }
            }
            log("\(t()) \(gone && recents.channels.count == 2 ? "" : "FAIL ")removed \(top.name) from recents → \(recents.channels.map(\.name))")
        }

        // Favorites: start clean, add three, drag the first to the bottom.
        let favoritesGroup = ChannelGroup(id: "favorites", name: "Favorites", kind: .favorites)
        for channel in (try? await state.liveCatalog.channels(in: favoritesGroup)) ?? [] {
            _ = try? await state.library.toggleFavorite(channel)
        }
        for channel in three { _ = try? await state.library.toggleFavorite(channel) }
        let favorites = GuideModel(state: state, scope: .favorites)
        favorites.reloadChannels()
        _ = await waitFor(5) { favorites.loaded && favorites.channels.count == 3 }
        let before = favorites.channels.map(\.name)
        favorites.moveChannel(from: 0, to: 3)
        try? await Task.sleep(for: .milliseconds(600))
        let saved = ((try? await state.liveCatalog.channels(in: favoritesGroup)) ?? []).map(\.name)
        let wanted = Array(before.dropFirst()) + before.prefix(1)
        log("\(t()) \(saved == wanted ? "" : "FAIL ")favorites reordered \(before) → saved \(saved)")
        state.section = .favorites
        try? await Task.sleep(for: .seconds(1.5))
        snapshot("9-favorites")
    }

    /// Multiview capacity across providers and cross-provider failover.
    private static func twoProviders(state: AppState, a: URL, b: URL, t: () -> String) async {
        _ = await control(a, "maxconn?n=2")
        _ = await control(b, "maxconn?n=1")
        let service = state.environment.providers
        guard let providerA = (try? service.repository.all())?.first(where: { $0.serverURL.port == a.port }),
              let providerB = try? await service.addProvider(name: "Harness B", serverURL: b.absoluteString,
                                                             credentials: ProviderCredentials(username: "test", password: "test"))
        else { return log("FAIL could not add provider B") }
        await state.environment.sync.refresh(providerA.id, parts: .catalog)
        await state.environment.sync.refresh(providerB.id)
        log("\(t()) limits A=\(await state.environment.connections.limit(for: providerA.id)) B=\(await state.environment.connections.limit(for: providerB.id))")
        state.live.reloadGroups()
        try? await Task.sleep(for: .seconds(1.5))
        let channels = (try? await state.liveCatalog.allChannels()) ?? []
        log("\(t()) merged channels: \(channels.map { "\($0.name)[\($0.sourceProviders.count)]" })")

        // Three tiles over A (2 connections) + B (1 connection).
        state.startMultiview(with: channels.first)
        try? await Task.sleep(for: .seconds(1))
        for (index, channel) in channels.dropFirst().prefix(2).enumerated() {
            state.multiview.setChannel(channel, forTile: index + 1)
            try? await Task.sleep(for: .milliseconds(300))
        }
        _ = await waitFor(15) { state.multiview.visibleTiles.filter { $0.channel != nil }.allSatisfy { $0.controller.phase == .playing } }
        let name = { (id: ProviderID?) in id == providerA.id ? "A" : id == providerB.id ? "B" : "-" }
        let tiles = state.multiview.visibleTiles.filter { $0.channel != nil }.map { "\($0.channel!.name):\($0.controller.phase):\(name($0.assignedProvider))" }
        log("\(t()) 3 tiles over 2 providers: \(tiles) warning=\(state.multiview.warning ?? "none")")
        log("\(t()) harness A=\(await control(a, "state"))")
        log("\(t()) harness B=\(await control(b, "state"))")

        // A fourth channel can't fit: expect a clear warning.
        state.multiview.layout = 4
        if let extra = channels.first {
            state.multiview.setChannel(extra, forTile: 3)
            try? await Task.sleep(for: .seconds(2))
            log("\(t()) 4th tile warning: \(state.multiview.warning ?? "none")")
        }
        state.closeMultiview()
        try? await Task.sleep(for: .seconds(1))

        // Failover: A breaks while playing; the player should switch to B by itself.
        state.section = .liveTV
        guard let channel = channels.first else { return }
        state.watch(channel, in: channels)
        _ = await waitFor(10) { state.hub.main.phase == .playing }
        log("\(t()) playing \(channel.name) on \(name(state.hub.main.plan?.source.providerID))")
        _ = await control(a, "status?code=404")
        _ = await control(a, "drop")
        let traceStart = Date()
        var trace: [String] = []
        var last = ""
        var failedOver = false
        while Date().timeIntervalSince(traceStart) < 30 {
            let main = state.hub.main
            let now = "\(main.phase) \(main.plan.map { "\(name($0.source.providerID))/\($0.format?.rawValue ?? "")/\($0.engine.rawValue)" } ?? "-") [\(main.lastAttemptError?.prefix(60) ?? "")]"
            if now != last {
                trace.append(String(format: "%.1fs %@", Date().timeIntervalSince(traceStart), now))
                last = now
            }
            if main.phase == .playing && main.plan?.source.providerID == providerB.id { failedOver = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        log("\(t()) failover trace: \(trace.joined(separator: " → "))")
        log("\(t()) failover to B=\(failedOver) notice=\(state.hub.main.notice ?? "-") reconnects=\(state.hub.main.reconnectCount)")
        _ = await control(a, "normal")
        state.closePlayer()
        try? await Task.sleep(for: .seconds(1.5))
        log("\(t()) leases after close=\(await state.environment.connections.totalInUse)")

        // Search groups results by provider, in priority order.
        let found = (try? await SearchRepository(database: state.environment.database).search("harness")) ?? SearchResults()
        let order = state.providers.providers.filter(\.isEnabled).map(\.id)
        let groups = found.grouped(by: order)
        let summary = groups.map { "\(state.live.providerName($0.provider)): \($0.results.channels.count) channels, \($0.results.movies.count) movies" }
        log("\(t()) \(groups.map(\.provider) == order ? "" : "FAIL ")search by provider: \(summary)")

        // Two providers spelling the same regions differently should still give one switch each.
        let regions = (try? await state.library.regions()) ?? []
        if !regions.isEmpty {
            let uk = regions.first { $0.code == "UK" }, us = regions.first { $0.code == "US" }
            let merged = Set(uk?.spellings ?? []) == ["UK", "GB"] && Set(us?.spellings ?? []) == ["US", "NA"]
                && uk?.providers.count == 2 && us?.providers.count == 2
            log("\(t()) \(merged ? "" : "FAIL ")regions across providers: \(regions.map { "\($0.code) seen as \($0.spellings) on \($0.providers)" })")
            UserDefaults.standard.set("regions", forKey: "settingsTab")
            state.section = .settings
            try? await Task.sleep(for: .seconds(1.5))
            snapshot("11-regions-two-providers")
            UserDefaults.standard.set("providers", forKey: "settingsTab")
        }
    }

    // MARK: Layout

    /// Visits every section at several window sizes (including the minimum) and reports anything
    /// laid out beyond the window's right or bottom edge. Scrolling content is ignored.
    private static func layout(state: AppState, harness: URL) async {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        try? await Task.sleep(for: .seconds(1))
        if let provider = try? await state.environment.providers.addProvider(
            name: "Harness", serverURL: harness.absoluteString, credentials: ProviderCredentials(username: "test", password: "test")) {
            await state.environment.sync.refresh(provider.id)
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }) else { return log("FAIL no window") }
        state.section = .liveTV
        state.live.reloadGroups()
        try? await Task.sleep(for: .seconds(1.5))
        state.live.selectedChannelID = state.live.channels.first?.id
        var failures = 0
        for size in [window.minSize, CGSize(width: 1100, height: 700), CGSize(width: 1400, height: 860)] {
            var frame = window.frame
            frame.size = size
            window.setFrame(frame, display: true)
            for section in SidebarItem.allCases {
                state.section = section
                try? await Task.sleep(for: .seconds(1.2))
                let (overflow, culprit) = overflow(in: window)
                if overflow > 1 { failures += 1 }
                if section == .liveTV { snapshot("layout-live-\(Int(window.frame.width))") }
                log("layout \(Int(window.frame.width))x\(Int(window.frame.height)) \(section.rawValue): " +
                    (overflow > 1 ? "OVERFLOW \(Int(overflow))pt (\(culprit))" : "ok"))
            }
            // The player with its controls up.
            if let channel = state.live.channels.first {
                state.watch(channel, in: state.live.channels)
                try? await Task.sleep(for: .seconds(2))
                let (overflow, culprit) = overflow(in: window)
                if overflow > 1 { failures += 1 }
                snapshot("layout-player-\(Int(window.frame.width))")
                log("layout \(Int(window.frame.width))x\(Int(window.frame.height)) player: " +
                    (overflow > 1 ? "OVERFLOW \(Int(overflow))pt (\(culprit))" : "ok"))
                state.closePlayer()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        state.section = .liveTV
        log("layout done, \(failures) overflowing")
    }

    private static func overflow(in window: NSWindow) -> (CGFloat, String) {
        guard let content = window.contentView else { return (0, "") }
        let limit = content.bounds
        var worst: (CGFloat, String) = (0, "")
        func visit(_ view: NSView) {
            guard !view.isHidden, view.alphaValue > 0 else { return }
            let frame = view.convert(view.bounds, to: content)
            let excess = max(frame.maxX - limit.maxX, limit.minX - frame.minX)
            if excess > worst.0 { worst = (excess, "\(type(of: view)) \(Int(frame.minX))…\(Int(frame.maxX))") }
            if view is NSClipView { return } // scrolled content may be larger than its viewport
            view.subviews.forEach(visit)
        }
        content.subviews.forEach(visit)
        return worst
    }

    // MARK: Soak

    /// Plays for a long time and logs memory every minute. `tiles` = 0 plays the main player; 2–4
    /// runs multiview.
    private static func soak(state: AppState, harness: URL, minutes: Int, tiles: Int) async {
        guard let provider = try? await state.environment.providers.addProvider(
            name: "Harness", serverURL: harness.absoluteString, credentials: ProviderCredentials(username: "test", password: "test"))
        else { return log("FAIL provider") }
        await state.environment.sync.refresh(provider.id, parts: [.account, .live])
        await state.environment.connections.setLimit(8, for: provider.id)
        let channels = (try? await state.liveCatalog.allChannels()) ?? []
        guard !channels.isEmpty else { return log("FAIL no channels") }
        let start = Date()
        if tiles == 0 {
            state.watch(channels[0], in: channels)
        } else {
            state.multiview.layout = max(2, min(4, tiles))
            state.startMultiview(with: channels[0])
            try? await Task.sleep(for: .seconds(1))
            for index in 1..<state.multiview.layout {
                state.multiview.setChannel(channels[index % channels.count], forTile: index)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        var first: UInt64?
        for minute in 0...minutes {
            if minute > 0 { try? await Task.sleep(for: .seconds(60)) }
            let rss = residentBytes()
            if minute == 2 { first = rss } // baseline after warm-up
            let controllers = tiles == 0 ? [state.hub.main] : state.multiview.visibleTiles.map(\.controller)
            let phases = controllers.map { "\($0.phase)".prefix(12) }.joined(separator: ",")
            let reconnects = controllers.map(\.reconnectCount).reduce(0, +)
            let drops = controllers.compactMap { $0.metrics?.droppedFrames }.reduce(0, +)
            log(String(format: "soak t=%3d min rss=%4d MB growth=%+d MB reconnects=%d drops=%d phases=%@",
                       minute, Int(rss / 1_048_576), first.map { Int((Int64(rss) - Int64($0)) / 1_048_576) } ?? 0,
                       reconnects, drops, phases))
        }
        log(String(format: "soak finished after %.1f h", Date().timeIntervalSince(start) / 3600))
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    // MARK: Performance

    /// Seeds a large synthetic library and measures list loading and guide drawing.
    private static func perf(state: AppState) async {
        if let appeared = RootView.firstAppearance {
            log("launch to first window content: \(String(format: "%.0f", appeared * 1000)) ms")
        }
        let channelCount = UserDefaults.standard.integer(forKey: "perfChannels") > 0 ? UserDefaults.standard.integer(forKey: "perfChannels") : 1500
        let seedStart = Date()
        let providerID = ProviderID.make()
        let start = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
        do {
            try await state.environment.database.writer.write { db in
                try Provider(id: providerID, name: "Perf", serverURL: URL(string: "http://perf.test")!, maxConnections: 4).insert(db)
                for c in 0..<30 {
                    try Category(providerID: providerID, kind: .live, categoryID: "\(c)", name: "Category \(c)", sortIndex: c).insert(db)
                }
                for n in 0..<channelCount {
                    try Channel(providerID: providerID, streamID: n, number: n + 1, name: "Channel \(n + 1)",
                                epgChannelID: "perf\(n)", categoryID: "\(n % 30)", sortIndex: n).insert(db)
                }
                let statement = try db.makeStatement(sql: "INSERT INTO programme (providerID, epgID, start, stop, title, importedAt) VALUES (?, ?, ?, ?, ?, ?)")
                for n in 0..<channelCount {
                    for slot in 0..<(8 * 48) {
                        let s = start.timeIntervalSince1970 + Double(slot) * 1800
                        try statement.execute(arguments: [providerID.rawValue, "perf\(n)", s, s + 1800, "Programme \(slot) on \(n + 1)", s])
                    }
                }
            }
            try state.environment.logicalChannels.rebuild()
        } catch {
            return log("seed failed: \(error)")
        }
        let programmes = channelCount * 8 * 48
        log("seeded \(channelCount) channels, \(programmes) programmes in \(String(format: "%.1f", Date().timeIntervalSince(seedStart))) s")

        // Live TV: loading the "All Channels" list.
        let listStart = Date()
        let all = (try? await state.liveCatalog.allChannels()) ?? []
        log("All Channels list (\(all.count) rows) loaded in \(String(format: "%.0f", Date().timeIntervalSince(listStart) * 1000)) ms")
        let refs = Array(all.prefix(60).compactMap(\.epg))
        let nnStart = Date()
        _ = try? await state.guide.nowNext(for: refs)
        log("now/next for 60 rows in \(String(format: "%.0f", Date().timeIntervalSince(nnStart) * 1000)) ms")

        // Guide: draw time while scrolling.
        state.section = .guide
        try? await Task.sleep(for: .seconds(3))
        guard let grid = findGrid(in: NSApp.windows) else { return log("guide grid not found") }
        log("guide rows=\(grid.channels.count)")
        var drawTimes: [Double] = []
        let clip = grid.scrollView!.contentView
        let startOrigin = clip.bounds.origin
        for step in 0..<240 {
            // Diagonal scroll: down through channels and forward through days.
            let origin = NSPoint(x: startOrigin.x + CGFloat(step) * 90, y: CGFloat(step) * 220)
            clip.setBoundsOrigin(origin)
            grid.scrollView!.reflectScrolledClipView(clip)
            if step % 20 == 0 { try? await Task.sleep(for: .milliseconds(120)) } // let block loads land
            let t0 = CACurrentMediaTime()
            grid.display()
            drawTimes.append((CACurrentMediaTime() - t0) * 1000)
        }
        let sorted = drawTimes.sorted()
        log(String(format: "guide draw per frame: median %.2f ms, p95 %.2f ms, max %.2f ms (budget 8.3 ms at 120 Hz)",
                   sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)], sorted.last ?? 0))
        log("done")
    }

    private static func findGrid(in windows: [NSWindow]) -> GuideGridView? {
        func search(_ view: NSView) -> GuideGridView? {
            if let grid = view as? GuideGridView { return grid }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        for window in windows { if let view = window.contentView, let grid = search(view) { return grid } }
        return nil
    }

    private static func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    /// Streams the harness has refused for being over its connection limit, so far.
    private static func refusedCount(_ base: URL) async -> Int {
        let json = await control(base, "state")
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        return object?["refused"] as? Int ?? 0
    }

    private static func control(_ base: URL, _ command: String) async -> String {
        guard let url = URL(string: base.absoluteString + "/control/" + command),
              let (data, _) = try? await URLSession.shared.data(from: url)
        else { return "unreachable" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Saves the key window's SwiftUI/AppKit content (video layers render black in snapshots).
    /// Window, video view and Metal drawable sizes for the visible player, in points / pixels.
    private static func videoGeometry() -> String {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }),
              let content = window.contentView else { return "no window" }
        // The largest visible Metal view is the main player (the preview and tiles are smaller).
        func metalViews(in view: NSView) -> [NSView] {
            (view.layer is CAMetalLayer && !view.isHiddenOrHasHiddenAncestor ? [view] : []) + view.subviews.flatMap(metalViews)
        }
        func find(_ view: NSView) -> NSView? {
            metalViews(in: view).max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        }
        let screen = window.screen?.frame.size ?? .zero
        var text = "screen=\(Int(screen.width))x\(Int(screen.height)) window=\(Int(window.frame.width))x\(Int(window.frame.height))"
        text += " fullscreen=\(window.styleMask.contains(.fullScreen)) toolbar=\(window.toolbar?.isVisible ?? false) title=\(window.titleVisibility == .visible) chromeTop=\(Int(window.frame.height - window.contentLayoutRect.height))pt items=\(window.toolbar?.items.count ?? -1)"
        if let video = find(content), let layer = video.layer as? CAMetalLayer {
            let frame = video.convert(video.bounds, to: nil)
            text += " video=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
            text += " layer=\(Int(layer.bounds.width))x\(Int(layer.bounds.height))"
            text += " drawable=\(Int(layer.drawableSize.width))x\(Int(layer.drawableSize.height)) scale=\(layer.contentsScale)"
        } else {
            text += " video=none"
        }
        if let mpv = activeState?.hub.main.engine as? MPVEngine {
            let osd = "\(mpv.debugProperty("osd-width") ?? "?")x\(mpv.debugProperty("osd-height") ?? "?")"
            text += " mpv-output=\(osd)"
            if let video = find(content), let layer = video.layer as? CAMetalLayer {
                text += " matches=\(osd == "\(Int(layer.drawableSize.width))x\(Int(layer.drawableSize.height))")"
            }
        }
        return text
    }

    /// A view drawn on its own, at its ideal size (for sheets, which `snapshot(_:)` can't capture).
    private static func snapshot(_ content: some View, _ name: String) {
        let host = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return log("snapshot \(name) unavailable")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smoke-\(name).png")
        save(rep, to: url)
    }

    /// Writes a snapshot to the container's tmp folder. macOS keeps other apps out of the container
    /// once Lumio is certificate-signed, so `-snapshotStdout YES` also prints it as base64
    /// ("SNAPSHOT-PNG name data") for scripts to decode.
    private static func save(_ rep: NSBitmapImageRep, to url: URL) {
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        log("snapshot \(url.path)")
        if UserDefaults.standard.bool(forKey: "snapshotStdout") {
            print("SNAPSHOT-PNG \(url.deletingPathExtension().lastPathComponent) \(png.base64EncodedString())")
            fflush(stdout)
        }
    }

    private static func snapshot(_ name: String, includingToolbar: Bool = false) {
        let candidates = NSApp.windows.filter { $0.contentView != nil && $0.frame.width > 400 }
        guard let window = candidates.first(where: \.isVisible) ?? candidates.first,
              let content = window.contentView,
              case let view = includingToolbar ? (content.superview ?? content) : content,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else {
            let windows = NSApp.windows.map { "\($0.title)|visible=\($0.isVisible)|\(Int($0.frame.width))x\(Int($0.frame.height))" }
            return log("snapshot \(name) unavailable; windows=\(windows)")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smoke-\(name).png")
        save(rep, to: url)
    }
}
#endif
