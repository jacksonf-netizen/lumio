import SwiftUI
import UniformTypeIdentifiers
import IPTVCore

/// Settings → Backup: export and import favorites, channel layout, watch history and settings.
struct BackupSettingsView: View {
    let state: AppState
    @State private var exporting = false
    @State private var importing = false
    @State private var document: BackupDocument?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Text("Saves favorites, hidden / renamed / reordered channels and groups, custom groups, guide matches, watch history and settings to a JSON file. Usernames and passwords are never included.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Export…") {
                        Task {
                            do {
                                document = BackupDocument(data: try await BackupService(database: state.environment.database).export())
                                exporting = true
                            } catch {
                                message = "Export failed: \(error)"
                            }
                        }
                    }
                    Button("Import…") { importing = true }
                }
                Text("To restore on a new Mac, add the same providers first (same server URLs), then import.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message {
                    Text(message).font(.callout).textSelection(.enabled)
                }
            } header: { Text("Backup") }
        }
        .formStyle(.grouped)
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "Lumio Backup \(Date().formatted(.iso8601.year().month().day()))") { result in
            if case .failure(let error) = result { message = "Export failed: \(error.localizedDescription)" } else { message = "Backup saved." }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let summary = try await BackupService(database: state.environment.database).importBackup(Data(contentsOf: url))
                    _ = try? state.environment.logicalChannels.rebuild()
                    state.hub.reloadSettings()
                    var text = "Imported \(summary.imported) items for \(summary.matchedProviders.joined(separator: ", "))."
                    if !summary.unmatchedProviders.isEmpty {
                        text += " Skipped providers not set up here: \(summary.unmatchedProviders.joined(separator: ", "))."
                    }
                    message = text
                } catch {
                    message = "Import failed: \(error)"
                }
            }
        }
    }
}

struct BackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
