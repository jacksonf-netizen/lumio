import Foundation
import Testing
@testable import IPTVCore
@testable import IPTVPlayback

/// End-to-end reliability tests: real engines against the local fault-injecting harness.
///
/// Start the harness first, then run:
///   python3 Tools/StreamHarness/harness.py --port 8098 --quiet &
///   swift test --filter HarnessIntegrationTests
/// The suite is skipped when the harness isn't running.
@Suite("Harness integration (real engines)", .serialized, .enabled(if: Harness.isRunning))
@MainActor
struct HarnessIntegrationTests {
    let provider = ProviderID("harness")

    func controller(settings: PlaybackSettings = PlaybackSettings()) -> PlaybackController {
        PlaybackController(purpose: .main, settings: settings, dependencies: PlaybackDependencies(
            connections: ConnectionManager(defaultLimit: 2), resolver: HarnessResolver(),
            makeEngine: { kind in
                kind == .mpv ? MPVEngine(headless: true) as any PlaybackEngine : AVPlayerEngine()
            }))
    }

    func item(_ channel: Int, formats: [StreamFormat] = [.ts, .m3u8]) -> PlaybackItem {
        PlaybackItem(id: "harness:\(channel)", title: "Harness \(channel)", content: .live, sources: [
            PlaybackSource(providerID: provider, itemID: String(channel), providerName: "Harness", allowedFormats: formats),
        ])
    }

    func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    init() async throws {
        // Every test starts from a healthy harness, even if an earlier run was interrupted.
        try await Harness.control("normal")
    }

    @Test(arguments: [1, 2, 3])
    func mpvPlaysEachChannelQuickly(channel: Int) async throws {
        try await Harness.control("normal")
        let player = controller()
        let started = Date()
        player.play(item(channel, formats: [.ts]))
        #expect(await waitFor(10) { player.phase == .playing })
        let elapsed = Date().timeIntervalSince(started)
        print("Harness channel \(channel): first frame after \(String(format: "%.2f", elapsed)) s")
        #expect(elapsed < 4)
        try await Task.sleep(for: .seconds(2))
        let metrics = try #require(player.metrics)
        print("Harness channel \(channel): \(metrics)")
        #expect(metrics.videoCodec == ["1": "h264", "2": "hevc", "3": "h264"]["\(channel)"])
        #expect((metrics.position ?? 0) > 0)
        await player.stop()
        await player.shutdown()
    }

    @Test func stallTriggersReconnectAndRecovers() async throws {
        try await Harness.control("normal")
        var settings = PlaybackSettings()
        settings.stallTimeout = 4
        let player = controller(settings: settings)
        player.play(item(1, formats: [.ts]))
        #expect(await waitFor(10) { player.phase == .playing })

        try await Harness.control("stall")
        // The engine has a few seconds buffered, then the watchdog fires.
        #expect(await waitFor(20) { player.phase.isRecovering })
        try await Harness.control("normal")
        #expect(await waitFor(20) { player.phase == .playing })
        #expect(player.reconnectCount >= 1)
        await player.stop()
        await player.shutdown()
    }

    @Test func droppedConnectionReconnects() async throws {
        try await Harness.control("normal")
        let player = controller()
        player.play(item(1, formats: [.ts]))
        #expect(await waitFor(10) { player.phase == .playing })
        try await Harness.control("drop")
        #expect(await waitFor(20) { player.reconnectCount >= 1 })
        #expect(await waitFor(20) { player.phase == .playing })
        await player.stop()
        await player.shutdown()
    }

    @Test func httpErrorsProduceSpecificMessages() async throws {
        try await Harness.control("status?code=404")
        let player = controller()
        player.play(item(1, formats: [.ts]))
        #expect(await waitFor(30) { if case .failed = player.phase { true } else { false } })
        guard case .failed(let failure) = player.phase else {
            try await Harness.control("normal")
            return
        }
        print("404 message: \(failure.message)")
        #expect(failure.message.contains("404"))
        try await Harness.control("normal")
        await player.shutdown()
    }
}

enum Harness {
    static let base = URL(string: ProcessInfo.processInfo.environment["IPTV_HARNESS_URL"] ?? "http://127.0.0.1:8098")!

    static var isRunning: Bool {
        var request = URLRequest(url: base.appending(path: "control/state"))
        request.timeoutInterval = 1
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 2)
        return ok
    }

    static func control(_ command: String) async throws {
        let url = URL(string: base.absoluteString + "/control/" + command)!
        _ = try await URLSession.shared.data(from: url)
    }
}

struct HarnessResolver: StreamURLResolver {
    func url(for source: PlaybackSource, content: PlaybackItem.Content, format: StreamFormat?) throws -> URL {
        Harness.base.appending(path: "live/test/test/\(source.itemID).\(format?.rawValue ?? "ts")")
    }
    func userAgent(for providerID: ProviderID) -> String { "Lumio-Tests" }
    func redactionCredentials(for providerID: ProviderID) -> [ProviderCredentials] {
        [ProviderCredentials(username: "test", password: "test")]
    }
}
