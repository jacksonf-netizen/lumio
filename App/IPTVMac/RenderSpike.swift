#if DEBUG
import AppKit
import IPTVCore
import IPTVPlayback

/// Development-only rendering check: opens a window with N mpv players on harness streams, prints
/// their metrics every 2 s, then quits. Launch from Terminal:
///
///   "build/DerivedData.noindex/Build/Products/Debug/Lumio.app/Contents/MacOS/Lumio" \
///       -spikeRender 4 -spikeURL http://127.0.0.1:8098
@MainActor
enum RenderSpike {
    static func runIfRequested() -> Bool {
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: "spikeRender")
        guard count > 0, let base = defaults.string(forKey: "spikeURL") else { return false }
        let seconds = defaults.integer(forKey: "spikeSeconds") > 0 ? defaults.integer(forKey: "spikeSeconds") : 20
        start(count: count, base: base, seconds: seconds)
        return true
    }

    private static var engines: [MPVEngine] = []
    private static var window: NSWindow?

    private static func start(count: Int, base: String, seconds: Int) {
        NSApplication.shared.setActivationPolicy(.regular)
        let columns = count > 1 ? 2 : 1
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        let size = NSSize(width: 1280, height: 720)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Render spike: \(count) × mpv"
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content
        let tileWidth = size.width / CGFloat(columns)
        let tileHeight = size.height / CGFloat(rows)
        for index in 0..<count {
            let engine = MPVEngine()
            engines.append(engine)
            let view = engine.videoView
            let column = index % columns
            let row = index / columns
            view.frame = NSRect(x: CGFloat(column) * tileWidth, y: size.height - CGFloat(row + 1) * tileHeight,
                                width: tileWidth, height: tileHeight)
            view.autoresizingMask = [.width, .height, .minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            content.addSubview(view)
            let channel = [1, 2, 3, 1][index % 4]
            engine.isMuted = index > 0
            engine.load(EngineRequest(url: URL(string: "\(base)/live/test/test/\(channel).ts")!, isLive: true,
                                      userAgent: "Lumio-Spike"))
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        self.window = window

        Task { @MainActor in
            for tick in 1...(seconds / 2) {
                try? await Task.sleep(for: .seconds(2))
                for (index, engine) in engines.enumerated() {
                    let m = engine.metrics()
                    print("SPIKE t=\(tick * 2)s tile=\(index) codec=\(m.videoCodec ?? "-") \(m.width ?? 0)x\(m.height ?? 0) fps=\(String(format: "%.1f", m.fps ?? 0)) hwdec=\(m.hardwareDecoder ?? "-") dropped=\(m.droppedFrames ?? -1) pos=\(String(format: "%.1f", m.position ?? -1)) display=\(String(format: "%.1f", m.displayRefreshRate ?? 0))")
                }
                print("SPIKE t=\(tick * 2)s rss=\(residentMegabytes()) MB")
            }
            for engine in engines {
                await engine.stop()
                engine.shutdown()
            }
            print("SPIKE done")
            exit(0)
        }
    }

    private static func residentMegabytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }
}
#endif
