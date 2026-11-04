import SwiftUI
import IPTVCore
import IPTVUI

/// Closing the last window quits the app (and stops playback) instead of leaving it running.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct LumioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Built once at launch from the local database only, so the first frame isn't delayed by the
    /// network. Refreshes then run in the background.
    private let state: AppState?
    private let startupError: Error?

    init() {
        LaunchTrace.mark("App.init start")
        defer { LaunchTrace.mark("App.init end") }
        // Always open with a fresh main window. macOS window restoration can otherwise bring back
        // "no windows" after a crash or force quit, leaving the app with nothing on screen.
        // (Window sizes are remembered separately and still restore.)
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        // Just updated: let the old copy finish quitting before opening the library.
        UpdateController.waitForPreviousCopy()
        do {
            let environment = try AppEnvironment.live()
            state = AppState(environment: environment)
            startupError = nil
            #if DEBUG
            if UserDefaults.standard.integer(forKey: "spikeRender") > 0 {
                DispatchQueue.main.async { _ = RenderSpike.runIfRequested() }
                return
            }
            #endif
            environment.startBackgroundWork()
            // Only with a release feed, and unless the user turned automatic checks off.
            if let state { DispatchQueue.main.async { state.updates.checkAtLaunch() } }
            #if DEBUG
            if let state { DispatchQueue.main.async { SmokeTest.runIfRequested(state: state) } }
            #endif
        } catch {
            state = nil
            startupError = error
            Log.app.fault("Startup failed: \(String(describing: error), privacy: .public)")
        }
    }

    var body: some Scene {
        WindowGroup("Lumio", id: "main") {
            Group {
                if let state {
                    RootView(state: state)
                } else {
                    StartupErrorView(error: startupError)
                }
            }
            .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            SidebarCommands()
            if let state {
                UpdateCommands(state: state)
                PlaybackCommands(state: state)
                ProviderCommands(environment: state.environment)
                #if DEBUG
                DebugCommands(environment: state.environment)
                #endif
            }
        }

        // The guide in its own window (e.g. on a second display), sharing playback with the main window.
        Window("Guide", id: "guide") {
            if let state {
                GuideWindow(state: state)
                    .frame(minWidth: 800, minHeight: 500)
            }
        }
        .defaultSize(width: 1200, height: 720)
        .keyboardShortcut("g", modifiers: [.command, .option])

        // A separate player window. While it's open, playing a channel shows here instead of as an overlay.
        Window("Player", id: "player") {
            if let state {
                PlayerWindow(state: state)
                    .frame(minWidth: 480, minHeight: 270)
            }
        }
        .defaultSize(width: 1280, height: 720)
        .keyboardShortcut("p", modifiers: [.command, .option])
    }
}

/// Shown only if the local database can't be opened (e.g. disk full or a corrupt file).
private struct StartupErrorView: View {
    let error: Error?

    var body: some View {
        EmptyState("Couldn't open the library", systemImage: "exclamationmark.triangle",
                   message: "If macOS asked whether Lumio may access its data, quit Lumio (⌘Q), open it again and click Allow. Your providers and favorites are still there.\n\n"
                       + (error.map { String(describing: $0) } ?? "Unknown error"))
    }
}

/// Set IPTV_TRACE_LAUNCH=1 to print launch milestones (milliseconds since process start).
enum LaunchTrace {
    static let enabled = ProcessInfo.processInfo.environment["IPTV_TRACE_LAUNCH"] != nil
    static func mark(_ label: String) {
        guard enabled else { return }
        print(String(format: "LAUNCH %6.0f ms  %@", (RootView.secondsSinceLaunch) * 1000, label))
        fflush(stdout)
    }
}
