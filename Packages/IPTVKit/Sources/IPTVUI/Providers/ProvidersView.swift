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
                            links: model.links[provider.id] ?? [],
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
    let links: [ServerLink]
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
                ServerLinkList(links: links, active: provider.serverURL)
                details
                if provider.isEnabled, links.allDown {
                    Label(links.count == 1
                          ? "The server doesn't answer. Lumio checks again every 5 minutes. If your seller sent a new link, add it with Edit."
                          : "None of the \(links.count) server links answer. Lumio checks again every 5 minutes. If your seller sent new links, add them with Edit.",
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let syncStep {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(syncStep)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if let error = provider.lastError, !links.allDown {
                    // (With every link down, the message above already says why.)
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

struct ProviderEditorSheet: View {
    let model: ProvidersViewModel
    let provider: Provider?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var servers = ""
    /// Set when a pasted link carried the login and it filled the fields.
    @State private var foundLogin = false
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
                .font(.title2.weight(.semibold))

            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Main"))
                LabeledContent {
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: $servers)
                            .font(.callout.monospaced())
                            .multilineTextAlignment(.leading)
                            .frame(height: 76)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(alignment: .topLeading) {
                                if servers.isEmpty {
                                    Text("http://example.com:8080")
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .allowsHitTesting(false)
                                }
                            }
                            .accessibilityLabel("Server links")
                        Text(foundLogin
                             ? "Username and password filled in from the links."
                             : "One per line, preferred first. Paste every link your seller sent: when one stops working, Lumio moves to the next.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Server links")
                }
                .onChange(of: servers) { fillLogin() }
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

            if isNew {
                Text("Enter the Xtream Codes details your IPTV provider gave you. Lumio doesn't provide any content or logins itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                    .disabled(saving || servers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                               || username.isEmpty || (isNew && password.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            guard let provider else { return }
            name = provider.name
            servers = model.serversText(for: provider)
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
            message = await model.save(provider, name: name, servers: servers, username: username, password: password)
        } else {
            message = await model.add(name: name, servers: servers, username: username, password: password)
        }
        if let message { error = message } else { dismiss() }
    }

    /// M3U links carry the login: use it when the fields are still empty.
    private func fillLogin() {
        guard let login = (try? ServerURL.parseList(servers))?.credentials else { return }
        guard username.isEmpty || username == login.username, password.isEmpty || password == login.password else { return }
        if username.isEmpty { username = login.username }
        if password.isEmpty { password = login.password }
        foundLogin = true
    }
}

/// A provider's server links with what the last check found. One healthy link shows as before:
/// just its address.
private struct ServerLinkList: View {
    let links: [ServerLink]
    let active: URL

    var body: some View {
        if links.count <= 1, links.first?.isDown != true {
            Text((links.first?.url ?? active).absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                ForEach(links, id: \.url) { link in
                    GridRow {
                        Text("\(link.position + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .gridColumnAlignment(.trailing)
                        Text(link.url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(link.url == active ? .primary : .secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        state(of: link)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func state(of link: ServerLink) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(link.isDown ? Color.red : (link.url == active ? Color.green : Color.secondary.opacity(0.5)))
                .frame(width: 6, height: 6)
            if let since = link.downSince {
                Text("Down since \(Self.format(since))")
            } else if link.url == active {
                Text("In use")
            } else {
                Text("Standby")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(link.lastFailure ?? link.lastCheckedAt.map { "Answered at \(Self.format($0))" } ?? "Not checked yet")
    }

    private static func format(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

#Preview {
    ProvidersView(model: ProvidersViewModel(environment: .preview()))
        .frame(width: 700, height: 400)
}
