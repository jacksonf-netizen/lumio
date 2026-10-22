import SwiftUI
import IPTVCore

/// Provider management: add, edit, remove, enable/disable, reorder priority, refresh, and status.
struct ProvidersView: View {
    let model: ProvidersViewModel
    @State private var editor: EditorTarget?
    @State private var pendingRemoval: Provider?

    enum EditorTarget: Identifiable {
        case add
        case edit(Provider)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let provider): provider.id.rawValue
            }
        }
    }

    var body: some View {
        Form {
            Section {
                if model.providers.isEmpty {
                    Text("No providers yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.providers) { provider in
                        ProviderRow(
                            provider: provider,
                            status: model.status[provider.id],
                            syncStep: model.syncing[provider.id],
                            setEnabled: { enabled in Task { await model.setEnabled(enabled, for: provider) } },
                            refresh: { model.refresh(provider) },
                            edit: { editor = .edit(provider) },
                            remove: { pendingRemoval = provider })
                    }
                    .onMove { source, destination in
                        model.move(fromOffsets: source, toOffset: destination)
                    }
                }
            } header: {
                HStack {
                    Text("Providers")
                    Spacer()
                    if !model.providers.isEmpty {
                        Button("Refresh All", systemImage: "arrow.clockwise") { model.refreshAll() }
                            .labelStyle(.titleAndIcon)
                            .disabled(model.isSyncing)
                    }
                    Button("Add Provider…", systemImage: "plus") { editor = .add }
                        .labelStyle(.titleAndIcon)
                }
            } footer: {
                Text("Drag to set priority. Higher providers are preferred when a channel is available from more than one. Passwords are stored in your Keychain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editor) { target in
            switch target {
            case .add: ProviderEditorSheet(model: model, provider: nil)
            case .edit(let provider): ProviderEditorSheet(model: model, provider: provider)
            }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "provider")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { provider in
            Button("Remove", role: .destructive) {
                Task { await model.remove(provider) }
            }
        } message: { _ in
            Text("Its channels, guide data, favorites and watch history will be deleted from this Mac. The saved password is removed from your Keychain.")
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct ProviderRow: View {
    let provider: Provider
    let status: ProviderStatus?
    let syncStep: String?
    let setEnabled: @MainActor @Sendable (Bool) -> Void
    let refresh: () -> Void
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
                .help("Drag to reorder")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(provider.name)
                        .font(.headline)
                        .foregroundStyle(provider.isEnabled ? .primary : .secondary)
                    accountBadge
                }
                Text(provider.serverURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                details
                if let syncStep {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(syncStep)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if let error = provider.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(get: { provider.isEnabled }, set: { setEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(provider.isEnabled ? "Disable this provider" : "Enable this provider")
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(syncStep != nil || !provider.isEnabled)
                .help("Refresh now")
            Button(action: edit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Edit")
            Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove provider")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Refresh Now", action: refresh)
            Button("Edit…", action: edit)
            Divider()
            Button("Remove…", role: .destructive, action: remove)
        }
    }

    @ViewBuilder
    private var accountBadge: some View {
        if let expiry = provider.expiresAt, expiry < Date() {
            badge("Expired", color: .red)
        } else if let status = provider.accountStatus, status.lowercased() != "active" {
            badge(status, color: .orange)
        } else if provider.accountStatus != nil {
            badge("Active", color: .green)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var details: some View {
        let parts: [String] = [
            provider.expiresAt.map { "Expires \($0.formatted(date: .abbreviated, time: .omitted))" },
            connectionsText,
            status.map { "\($0.counts.channels.formatted()) channels · \($0.counts.movies.formatted()) movies · \($0.counts.series.formatted()) series · \($0.counts.programmes.formatted()) guide entries" },
            provider.lastRefreshAt.map { "Updated \($0.formatted(.relative(presentation: .named)))" },
        ].compactMap { $0 }
        return Text(parts.joined(separator: "  ·  "))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var connectionsText: String? {
        let limit = provider.maxConnections ?? status?.usage?.limit
        guard let limit else { return nil }
        let inUse = status?.usage?.inUse ?? 0
        var text = "Connections \(inUse)/\(limit) in this app"
        if let active = provider.activeConnections { text += " (provider reported \(active) active)" }
        return text
    }
}

private struct ProviderEditorSheet: View {
    let model: ProvidersViewModel
    let provider: Provider?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var offsetMinutes = 0
    @State private var userAgent = ""
    @State private var error: String?
    @State private var saving = false

    private var isNew: Bool { provider == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Add Xtream Codes Provider" : "Edit \(provider!.name)")
                .font(.title2.bold())

            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Main"))
                TextField("Server URL", text: $serverURL, prompt: Text("http://example.com:8080"))
                    .textContentType(.URL)
                TextField("Username", text: $username)
                    .textContentType(.username)
                SecureField("Password", text: $password, prompt: isNew ? nil : Text("Unchanged"))
                    .textContentType(.password)
                if !isNew {
                    Stepper("Guide time offset: \(offsetMinutes >= 0 ? "+" : "")\(offsetMinutes) min",
                            value: $offsetMinutes, in: -720...720, step: 15)
                    TextField("User-Agent override", text: $userAgent, prompt: Text("Use the global setting"))
                }
            }
            .formStyle(.grouped)
            .autocorrectionDisabled()

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || serverURL.isEmpty || username.isEmpty || (isNew && password.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            guard let provider else { return }
            name = provider.name
            serverURL = provider.serverURL.absoluteString
            username = model.savedUsername(for: provider)
            offsetMinutes = provider.epgTimeOffsetMinutes
            userAgent = provider.userAgentOverride ?? ""
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let message: String?
        if var provider {
            provider.epgTimeOffsetMinutes = offsetMinutes
            let ua = userAgent.trimmingCharacters(in: .whitespaces)
            provider.userAgentOverride = ua.isEmpty ? nil : ua
            message = await model.save(provider, name: name, serverURL: serverURL, username: username, password: password)
        } else {
            message = await model.add(name: name, serverURL: serverURL, username: username, password: password)
        }
        if let message { error = message } else { dismiss() }
    }
}

#Preview {
    ProvidersView(model: ProvidersViewModel(environment: .preview()))
        .frame(width: 700, height: 400)
}
