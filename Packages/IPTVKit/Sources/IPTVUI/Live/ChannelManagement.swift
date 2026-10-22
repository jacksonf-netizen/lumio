import AppKit
import SwiftUI
import IPTVCore

/// Sheets used by channel and group management.
enum ManagementSheet: Identifiable {
    case renameChannel(ChannelListItem)
    case renameGroup(ChannelGroup)
    case newGroup(adding: ChannelListItem?)
    case matchEPG(ChannelListItem)
    case linkChannel(ChannelListItem, sourceProvider: ProviderID, streamID: Int)

    var id: String {
        switch self {
        case .renameChannel(let c): "rename-\(c.id)"
        case .renameGroup(let g): "rename-group-\(g.id)"
        case .newGroup: "new-group"
        case .matchEPG(let c): "epg-\(c.id)"
        case .linkChannel(let c, let p, let s): "link-\(c.id)-\(p.rawValue)-\(s)"
        }
    }
}

/// Right-click menu for a channel.
struct ChannelMenu: View {
    let channel: ChannelListItem
    let model: LiveTVModel
    @Binding var sheet: ManagementSheet?

    var body: some View {
        Button("Watch") { model.watch(channel) }
        Button(channel.isFavorite ? "Remove from Favorites" : "Add to Favorites") { model.toggleFavorite(channel) }
        Divider()
        Button("Rename…") { sheet = .renameChannel(channel) }
        Button(channel.isHidden ? "Unhide" : "Hide") { model.setHidden(!channel.isHidden, channel) }
        Menu("Add to Group") {
            CustomGroupsMenu(channel: channel, model: model, sheet: $sheet)
        }
        if let group = model.selectedGroup, group.kind == .custom {
            Button("Remove from “\(group.name)”") { model.remove(channel, fromGroup: group) }
        }
        Divider()
        Button("Match Guide…") { sheet = .matchEPG(channel) }
        Menu("Sources") {
            ForEach(model.sources(of: channel), id: \.streamID) { source in
                Menu("\(model.providerName(source.providerID)): \(source.name)") {
                    Button("Unlink from This Channel") {
                        model.setLink(.unlink, providerID: source.providerID, streamID: source.streamID)
                    }
                    Button("Restore Automatic Matching") {
                        model.setLink(nil, providerID: source.providerID, streamID: source.streamID)
                    }
                }
            }
            Divider()
            Button("Merge Another Channel Into This…") {
                sheet = .linkChannel(channel, sourceProvider: channel.providerID, streamID: channel.streamID)
            }
        }
        Menu("Player Engine") {
            Button("Automatic") { model.setEngine(nil, format: nil, for: channel) }
            Button("mpv (MPEG-TS)") { model.setEngine(.mpv, format: .ts, for: channel) }
            Button("mpv (HLS)") { model.setEngine(.mpv, format: .m3u8, for: channel) }
            Button("AVPlayer (HLS)") { model.setEngine(.avPlayer, format: .m3u8, for: channel) }
        }
    }
}

private struct CustomGroupsMenu: View {
    let channel: ChannelListItem
    let model: LiveTVModel
    @Binding var sheet: ManagementSheet?

    var body: some View {
        ForEach(model.groups.filter { $0.kind == .custom }) { group in
            Button(group.name) { model.add(channel, toGroup: String(group.id.dropFirst("custom:".count))) }
        }
        Divider()
        Button("New Group…") { sheet = .newGroup(adding: channel) }
    }
}

struct ManagementSheetView: View {
    let sheet: ManagementSheet
    let model: LiveTVModel

    var body: some View {
        switch sheet {
        case .renameChannel(let channel):
            NameSheet(title: "Rename Channel", initial: channel.name, allowReset: true) { name in
                model.rename(channel, to: name)
            }
        case .renameGroup(let group):
            NameSheet(title: "Rename Group", initial: group.name, allowReset: group.kind == .category) { name in
                model.rename(group, to: name)
            }
        case .newGroup(let channel):
            NameSheet(title: "New Group", initial: "", allowReset: false) { name in
                if let name { model.createGroup(named: name, adding: channel) }
            }
        case .matchEPG(let channel):
            EPGMatchSheet(channel: channel, model: model)
        case .linkChannel(let channel, _, _):
            LinkChannelSheet(target: channel, model: model)
        }
    }
}

/// Text prompt. `onDone(nil)` means "reset to the provider's name".
private struct NameSheet: View {
    let title: String
    let initial: String
    let allowReset: Bool
    let onDone: (String?) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Name", text: $text).textFieldStyle(.roundedBorder).frame(width: 320)
            HStack {
                if allowReset {
                    Button("Use Original Name") { onDone(nil); dismiss() }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onDone(text); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { text = initial }
    }
}

/// Manual EPG matching: pick a guide channel from any provider.
private struct EPGMatchSheet: View {
    let channel: ChannelListItem
    let model: LiveTVModel
    @State private var query = ""
    @State private var results: [EPGChannel] = []
    @State private var selection: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Match Guide for “\(channel.name)”").font(.headline)
            Text(channel.epg.map { "Currently using guide id \($0.epgID)." } ?? "This channel has no guide yet.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Search guide channels", text: $query)
                .textFieldStyle(.roundedBorder)
            List(results, id: \.self, selection: $selection) { guide in
                VStack(alignment: .leading) {
                    Text(guide.displayName ?? guide.epgID)
                    Text("\(guide.epgID) · \(model.providerName(guide.providerID))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(key(guide))
            }
            .frame(width: 460, height: 280)
            HStack {
                Button("Use Automatic Matching") {
                    model.setEPG(nil, for: channel)
                    dismiss()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use This Guide") {
                    if let guide = results.first(where: { key($0) == selection }) { model.setEPG(guide, for: channel) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(200))
            let search = query.isEmpty ? channel.name : query
            results = (try? await model.library.searchGuideChannels(search)) ?? []
        }
    }

    private func key(_ guide: EPGChannel) -> String { "\(guide.providerID.rawValue)|\(guide.epgID)" }
}

/// Merge: pick another provider's channel to link into this logical channel.
private struct LinkChannelSheet: View {
    let target: ChannelListItem
    let model: LiveTVModel
    @State private var query = ""
    @State private var all: [ChannelListItem] = []
    @State private var selection: ChannelListItem.ID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge into “\(target.name)”").font(.headline)
            Text("Pick the same channel from another provider. It will play as a backup source.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Search channels", text: $query).textFieldStyle(.roundedBorder)
            List(filtered, selection: $selection) { channel in
                VStack(alignment: .leading) {
                    Text(channel.name)
                    Text(channel.sourceProviders.map(model.providerName).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(channel.id)
            }
            .frame(width: 460, height: 280)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Merge") {
                    if let picked = all.first(where: { $0.id == selection }) {
                        model.setLink(.link, providerID: picked.providerID, streamID: picked.streamID, target: target.id)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .task {
            all = ((try? await model.catalog.allChannels()) ?? []).filter { $0.id != target.id }
            query = target.name
        }
    }

    private var filtered: [ChannelListItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
        return Array(list.prefix(200))
    }
}

// MARK: - AppKit menu (used by the virtualised channel table)

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

@MainActor
enum ChannelMenuBuilder {
    /// The same actions as `ChannelMenu`, as an NSMenu.
    static func menu(for channel: ChannelListItem, model: LiveTVModel, present: @escaping (ManagementSheet) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Watch") { model.watch(channel) })
        menu.addItem(ClosureMenuItem(channel.isFavorite ? "Remove from Favorites" : "Add to Favorites") { model.toggleFavorite(channel) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Rename…") { present(.renameChannel(channel)) })
        menu.addItem(ClosureMenuItem(channel.isHidden ? "Unhide" : "Hide") { model.setHidden(!channel.isHidden, channel) })

        let groups = NSMenu()
        for group in model.groups where group.kind == .custom {
            groups.addItem(ClosureMenuItem(group.name) { model.add(channel, toGroup: String(group.id.dropFirst("custom:".count))) })
        }
        if !groups.items.isEmpty { groups.addItem(.separator()) }
        groups.addItem(ClosureMenuItem("New Group…") { present(.newGroup(adding: channel)) })
        menu.addItem(submenu("Add to Group", groups))
        if let group = model.selectedGroup, group.kind == .custom {
            menu.addItem(ClosureMenuItem("Remove from “\(group.name)”") { model.remove(channel, fromGroup: group) })
        }
        if model.selectedGroup?.kind == .recents {
            menu.addItem(ClosureMenuItem("Remove from Recently Watched") { model.removeRecent(channel) })
        }

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Match Guide…") { present(.matchEPG(channel)) })
        let sources = NSMenu()
        for source in model.sources(of: channel) {
            let sub = NSMenu()
            sub.addItem(ClosureMenuItem("Unlink from This Channel") { model.setLink(.unlink, providerID: source.providerID, streamID: source.streamID) })
            sub.addItem(ClosureMenuItem("Restore Automatic Matching") { model.setLink(nil, providerID: source.providerID, streamID: source.streamID) })
            sources.addItem(submenu("\(model.providerName(source.providerID)): \(source.name)", sub))
        }
        sources.addItem(.separator())
        sources.addItem(ClosureMenuItem("Merge Another Channel Into This…") {
            present(.linkChannel(channel, sourceProvider: channel.providerID, streamID: channel.streamID))
        })
        menu.addItem(submenu("Sources", sources))

        let engine = NSMenu()
        engine.addItem(ClosureMenuItem("Automatic") { model.setEngine(nil, format: nil, for: channel) })
        engine.addItem(ClosureMenuItem("mpv (MPEG-TS)") { model.setEngine(.mpv, format: .ts, for: channel) })
        engine.addItem(ClosureMenuItem("mpv (HLS)") { model.setEngine(.mpv, format: .m3u8, for: channel) })
        engine.addItem(ClosureMenuItem("AVPlayer (HLS)") { model.setEngine(.avPlayer, format: .m3u8, for: channel) })
        menu.addItem(submenu("Player Engine", engine))
        return menu
    }

    private static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
