import AppKit
import SwiftUI
import IPTVCore

/// Standalone guide window.
public struct GuideWindow: View {
    let state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        GuideView(state: state)
            .onDisappear {
                // The guide window's preview shouldn't keep a connection after closing.
                if !SidebarItem.withPreview.contains(state.section) {
                    Task { await state.hub.stopPreview() }
                }
            }
    }
}

/// Standalone player window.
public struct PlayerWindow: View {
    let state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        PlayerScreen(state: state, standalone: true)
            .ignoresSafeArea()
            .onAppear {
                state.playerWindowOpen = true
                state.isPlayerPresented = false
            }
            .onDisappear {
                state.playerWindowOpen = false
                let main = state.hub.main
                Task { await main.stop() }
            }
    }
}

/// App menu: Check for Updates…
public struct UpdateCommands: Commands {
    let state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                let updates = state.updates
                Task { await updates.check(userInitiated: true) }
            }
            .disabled(state.updates.isChecking)
        }
    }
}

/// Menu bar: Playback.
public struct PlaybackCommands: Commands {
    let state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some Commands {
        CommandMenu("Playback") {
            Button("Channel Up") { state.zap(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Channel Down") { state.zap(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Last Channel") { state.lastChannel() }
                .keyboardShortcut(.delete, modifiers: .command)
            Divider()
            Button("Play / Pause") {
                if state.hub.main.phase == .paused { state.hub.main.resume() } else { state.hub.main.pause() }
            }
            .keyboardShortcut("p", modifiers: .command)
            Button("Mute") { state.hub.main.isMuted.toggle() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Divider()
            Button(state.showDiagnostics ? "Hide Diagnostics" : "Show Diagnostics") { state.showDiagnostics.toggle() }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Button(state.isMultiviewPresented ? "Exit Multiview" : "Multiview") {
                if state.isMultiviewPresented { state.exitMultiview() } else { state.startMultiview(with: state.currentChannel) }
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
            // Multiview starts from a playing channel.
            .disabled(!state.isMultiviewPresented && (state.currentChannel == nil || !(state.isPlayerPresented || state.playerWindowOpen)))
            Button("Close Player") { state.closePlayer() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!state.isPlayerPresented)
        }
    }
}
