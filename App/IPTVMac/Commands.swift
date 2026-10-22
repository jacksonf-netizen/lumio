import AppKit
import SwiftUI
import IPTVCore
import IPTVUI

/// "Providers" menu: background refresh on demand.
struct ProviderCommands: Commands {
    let environment: AppEnvironment

    var body: some Commands {
        CommandMenu("Providers") {
            Button("Refresh All Providers") {
                let sync = environment.sync
                Task.detached(priority: .utility) { await sync.refreshStale(force: true) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}

#if DEBUG
/// Development-only menu. Not present in Release builds.
struct DebugCommands: Commands {
    let environment: AppEnvironment

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Import Providers from LocalSecrets.json…") {
                importLocalSecrets()
            }
            Button("Reveal Database in Finder") {
                if let url = try? AppDatabase.defaultURL() {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

    /// The app is sandboxed, so the file is picked with an open panel (which grants read access).
    @MainActor
    private func importLocalSecrets() {
        let panel = NSOpenPanel()
        panel.title = "Choose LocalSecrets.json"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let added = try await LocalSecretsImporter.importFile(at: url, into: environment)
                Log.app.info("Imported \(added) providers from LocalSecrets.json")
                showAlert("Added \(added) provider\(added == 1 ? "" : "s"). They are refreshing in the background.")
            } catch {
                showAlert("Couldn't import: \(CredentialRedactor.redact(String(describing: error)))")
            }
        }
    }

    @MainActor
    private func showAlert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }
}
#endif
