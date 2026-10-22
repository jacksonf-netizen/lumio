import AppKit
import SwiftUI
import IPTVCore

/// Settings: providers, playback, guide.
struct SettingsView: View {
    let state: AppState
    /// Remembers the last tab, like the system's own settings windows.
    @AppStorage("settingsTab") private var tab = "providers"

    var body: some View {
        TabView(selection: $tab) {
            ProvidersView(model: state.providers)
                .tabItem { Label("Providers", systemImage: "antenna.radiowaves.left.and.right") }
                .tag("providers")
            PlaybackSettingsView(state: state)
                .tabItem { Label("Playback", systemImage: "play.rectangle") }
                .tag("playback")
            GuideSettingsView(state: state)
                .tabItem { Label("Guide", systemImage: "calendar") }
                .tag("guide")
            RegionsSettingsView(state: state)
                .tabItem { Label("Regions", systemImage: "globe") }
                .tag("regions")
            HiddenSettingsView(state: state)
                .tabItem { Label("Hidden", systemImage: "eye.slash") }
                .tag("hidden")
            BackupSettingsView(state: state)
                .tabItem { Label("Backup", systemImage: "externaldrive") }
                .tag("backup")
            AboutSettingsView(updates: state.updates)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag("about")
        }
        .padding()
        .navigationTitle("Settings")
    }
}

private struct PlaybackSettingsView: View {
    let state: AppState
    @State private var engine: EngineKind = .mpv
    @State private var format: StreamFormat = .ts
    @State private var buffer: BufferPreset = .normal
    @State private var stall: Double = 8
    @State private var userAgent = ""

    var body: some View {
        Form {
            Section {
                Picker("Default engine", selection: $engine) {
                    Text("mpv (recommended: MPEG-TS, HEVC, AC-3)").tag(EngineKind.mpv)
                    Text("AVPlayer (HLS)").tag(EngineKind.avPlayer)
                }
                Picker("Preferred live format", selection: $format) {
                    Text("MPEG-TS (.ts)").tag(StreamFormat.ts)
                    Text("HLS (.m3u8)").tag(StreamFormat.m3u8)
                }
                Text("If a channel fails, the player automatically tries the other format, then the other engine, then another provider. You can lock a channel to an engine from its right-click menu.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Engine") }

            Section {
                Picker("Buffer", selection: $buffer) {
                    ForEach(BufferPreset.allCases) { preset in Text(preset.title).tag(preset) }
                }
                Stepper("Reconnect after \(Int(stall)) s without data", value: $stall, in: 3...30)
            } header: { Text("Network") }

            Section {
                TextField("User-Agent", text: $userAgent, prompt: Text(XtreamClient.defaultUserAgent))
                Text("Some providers only accept certain players. Leave empty for the default. Each provider can also override this.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("HTTP") }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: engine) { save() }
        .onChange(of: format) { save() }
        .onChange(of: buffer) { save() }
        .onChange(of: stall) { save() }
        .onChange(of: userAgent) { save() }
    }

    private func load() {
        let s = state.environment.settings
        engine = (try? s.value(EngineKind.self, for: .engine)) ?? .mpv
        format = (try? s.value(StreamFormat.self, for: .preferredFormat)) ?? .ts
        buffer = (try? s.value(BufferPreset.self, for: .bufferPreset)) ?? .normal
        stall = (try? s.value(Double.self, for: .stallTimeoutSeconds)) ?? 8
        userAgent = (try? s.value(String.self, for: .userAgent)) ?? ""
    }

    private func save() {
        let s = state.environment.settings
        try? s.set(engine, for: .engine)
        try? s.set(format, for: .preferredFormat)
        try? s.set(buffer, for: .bufferPreset)
        try? s.set(stall, for: .stallTimeoutSeconds)
        let ua = userAgent.trimmingCharacters(in: .whitespaces)
        try? s.set(ua.isEmpty ? nil : ua, for: .userAgent)
        state.hub.reloadSettings()
    }
}

private struct GuideSettingsView: View {
    let state: AppState
    @State private var refreshHours: Double = 12
    @State private var catalogHours: Double = 12
    @State private var futureDays: Double = 7

    var body: some View {
        Form {
            Section {
                Stepper("Refresh guide every \(Int(refreshHours)) h", value: $refreshHours, in: 2...48, step: 2)
                Stepper("Refresh channels and VOD every \(Int(catalogHours)) h", value: $catalogHours, in: 2...72, step: 2)
                Stepper("Keep \(Int(futureDays)) days of upcoming programmes", value: $futureDays, in: 1...14)
                Text("Refreshes run in the background; the app always opens with what it has cached. Each provider's guide time offset is in Providers → Edit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let s = state.environment.settings
            refreshHours = (try? s.value(Double.self, for: .epgRefreshHours)) ?? 12
            catalogHours = (try? s.value(Double.self, for: .catalogRefreshHours)) ?? 12
            futureDays = (try? s.value(Double.self, for: .epgFutureDays)) ?? 7
        }
        .onChange(of: refreshHours) { try? state.environment.settings.set(refreshHours, for: .epgRefreshHours) }
        .onChange(of: catalogHours) { try? state.environment.settings.set(catalogHours, for: .catalogRefreshHours) }
        .onChange(of: futureDays) { try? state.environment.settings.set(futureDays, for: .epgFutureDays) }
    }
}

/// Regions found in group names ("UK | Sports"), each with an on/off switch, plus "Other Groups"
/// for the rest. Each row opens to list its groups, which can be switched on or off one by one.
private struct RegionsSettingsView: View {
    let state: AppState
    @State private var regions: [RegionSummary] = []
    @State private var categories: [String: [RegionCategory]] = [:]
    /// Opened regions, remembered between visits.
    @State private var expanded = Set(UserDefaults.standard.stringArray(forKey: "regionsExpanded") ?? [])
    @State private var query = ""
    @State private var loaded = false
    @State private var hasMerges = false

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// Regions to list, with the categories to show when open. A filter matches region names and
    /// codes, and also single groups, which then show on their own under an opened region.
    private var visible: [(region: RegionSummary, categories: [RegionCategory], open: Bool)] {
        let q = trimmedQuery
        return regions.compactMap { region in
            let all = categories[region.code] ?? []
            guard !q.isEmpty else { return (region, all, expanded.contains(region.code)) }
            if region.code.localizedCaseInsensitiveContains(q) || region.name.localizedCaseInsensitiveContains(q) {
                return (region, all, expanded.contains(region.code))
            }
            let matching = all.filter { $0.name.localizedCaseInsensitiveContains(q) }
            return matching.isEmpty ? nil : (region, matching, true)
        }
    }

    private var shownCount: Int { regions.filter { !$0.isHidden }.count }
    private var multipleProviders: Bool { state.providers.providers.filter(\.isEnabled).count > 1 }

    var body: some View {
        Form {
            Section {
                if loaded && regions.isEmpty {
                    Text("Your providers haven't listed any groups yet.")
                        .foregroundStyle(.secondary)
                } else if !loaded {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else if visible.isEmpty {
                    Text("Nothing matches “\(trimmedQuery)”.").foregroundStyle(.secondary)
                }
                ForEach(visible, id: \.region.code) { entry in
                    RegionRow(region: entry.region, isOpen: entry.open,
                              others: regions.filter { $0.code != entry.region.code && !$0.isOther },
                              toggleOpen: { toggleOpen(entry.region.code) },
                              setShown: { shown in set(entry.region, shown: shown) },
                              merge: { target in change { try await $0.mergeRegion(entry.region.code, into: target.code) } },
                              separate: { spelling in change { try await $0.separateSpelling(spelling) } })
                    if entry.open {
                        RegionCategoryList(categories: entry.categories, showProvider: multipleProviders) { category, shown in
                            set(category, shown: shown)
                        }
                    }
                }
            } header: {
                HStack(spacing: 10) {
                    Text("Live TV Regions")
                    if !regions.isEmpty {
                        Text("\(shownCount) of \(regions.count) shown").foregroundStyle(.secondary).font(.caption)
                    }
                    Spacer()
                    TextField("Filter", text: $query, prompt: Text("Filter regions or groups"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 190)
                    Button("Show All") { setAll(hidden: false) }
                        .disabled(regions.allSatisfy { !$0.isHidden && $0.shownCategories == $0.categoryCount })
                    Button("Hide All") { setAll(hidden: true) }
                        .disabled(regions.allSatisfy { $0.isHidden && $0.shownCategories == 0 })
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Turn a region off to hide every live group in it: its channels disappear from Live TV, the Guide and Search. Movies and Series aren't affected; right-click a category there to hide it. Groups the app can't place in a region are under Other Groups. New groups your provider adds follow these switches automatically. Favorites and Recents still show anything you picked.")
                    Text("Click a region to see its groups and switch single ones on or off, for example if a group was put in the wrong region. Switching the whole region on or off again resets them.")
                    Text("Providers spell regions differently (US, USA, NA…). Common spellings are already combined; each row lists the ones it covers. If two rows are really the same region, use its ⋯ menu to merge them, or to split a spelling back out.")
                    if hasMerges {
                        Button("Undo My Merges") { change { try await $0.resetRegionMerges() } }
                            .controlSize(.small)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    private func load() async {
        async let loadedRegions = state.library.regions()
        async let loadedCategories = state.library.regionCategories()
        regions = (try? await loadedRegions) ?? []
        categories = (try? await loadedCategories) ?? [:]
        hasMerges = !state.library.regionAliases().isEmpty
        loaded = true
    }

    private func toggleOpen(_ code: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            if expanded.remove(code) == nil { expanded.insert(code) }
        }
        UserDefaults.standard.set(expanded.sorted(), forKey: "regionsExpanded")
    }

    /// Runs a change, then reloads the list (counts and merged rows change with it).
    private func change(_ action: @escaping @Sendable (LibraryRepository) async throws -> Void) {
        let library = state.library
        Task {
            try? await action(library)
            await load()
        }
    }

    private func set(_ region: RegionSummary, shown: Bool) {
        // Update straight away; the reload fills in the exact counts.
        if let index = regions.firstIndex(where: { $0.code == region.code }) {
            regions[index].isHidden = !shown
            regions[index].shownCategories = shown ? regions[index].categoryCount : 0
        }
        categories[region.code] = categories[region.code]?.map { var category = $0; category.isShown = shown; return category }
        change { try await $0.setRegion(region.code, hidden: !shown) }
    }

    private func set(_ category: RegionCategory, shown: Bool) {
        if let index = categories[category.region]?.firstIndex(where: { $0.id == category.id }) {
            categories[category.region]?[index].isShown = shown
        }
        change { try await $0.setCategory(category, shown: shown) }
    }

    private func setAll(hidden: Bool) {
        let codes = Set(regions.map(\.code))
        for index in regions.indices {
            regions[index].isHidden = hidden
            regions[index].shownCategories = hidden ? 0 : regions[index].categoryCount
        }
        change { try await $0.setHiddenRegions(hidden ? codes : [], resettingCategoriesIn: codes) }
    }
}

private struct RegionRow: View {
    let region: RegionSummary
    let isOpen: Bool
    let others: [RegionSummary]
    let toggleOpen: () -> Void
    let setShown: (Bool) -> Void
    let merge: (RegionSummary) -> Void
    let separate: (String) -> Void

    /// "Seen as US, USA, NA · on Main, Backup"
    private var origin: String {
        var parts: [String] = []
        if !region.isOther, region.spellings.count > 1 || region.spellings.first != region.code {
            parts.append("Seen as " + region.spellings.joined(separator: ", "))
        }
        if !region.providers.isEmpty { parts.append("on " + region.providers.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private var counts: String {
        var parts = ["\(region.liveGroups) group\(region.liveGroups == 1 ? "" : "s")"]
        // When single groups differ from the region's switch.
        if region.isHidden ? region.shownCategories > 0 : region.shownCategories < region.categoryCount {
            parts.append("\(region.shownCategories) of \(region.categoryCount) shown")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggleOpen) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 10)
                    Group {
                        if region.isOther {
                            Image(systemName: "questionmark").font(.caption.weight(.bold))
                        } else {
                            Text(region.code).font(.system(.caption, design: .rounded).weight(.bold))
                        }
                    }
                    .frame(minWidth: 34, minHeight: 15)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(region.name).foregroundStyle(region.isHidden && region.shownCategories == 0 ? .secondary : .primary)
                        Text([counts, region.examples.isEmpty ? nil : "e.g. " + region.examples.joined(separator: ", ")]
                                .compactMap { $0 }.joined(separator: " — "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !origin.isEmpty {
                            Text(origin).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Hide this region's groups" : "Show this region's groups")
            if !region.isOther {
                Menu {
                    Menu("Merge Into") {
                        ForEach(others) { other in
                            Button("\(other.name) (\(other.code))") { merge(other) }
                        }
                    }
                    .disabled(others.isEmpty)
                    if region.spellings.count > 1 {
                        Menu("Split Off") {
                            ForEach(region.spellings.filter { $0 != region.code }, id: \.self) { spelling in
                                Button("“\(spelling)” as its own region") { separate(spelling) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Merge or split this region")
            }
            Toggle("Show \(region.name)", isOn: Binding(get: { !region.isHidden }, set: { setShown($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(region.isOther ? "Show or hide every group without a region, including new ones" : "Show or hide everything in \(region.name)")
        }
        .padding(.vertical, 2)
    }
}

/// The live groups of an opened region, each with its own checkbox.
private struct RegionCategoryList: View {
    let categories: [RegionCategory]
    let showProvider: Bool
    let setShown: (RegionCategory, Bool) -> Void

    var body: some View {
        if !categories.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(categories.filter(\.isShown).count) of \(categories.count) shown")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                ForEach(categories) { category in
                    Toggle(isOn: Binding(get: { category.isShown }, set: { setShown(category, $0) })) {
                        HStack(spacing: 6) {
                            Text(category.name).lineLimit(1)
                            if showProvider {
                                Text(category.providerName).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.leading, 30)
            .padding(.vertical, 2)
        }
    }
}

/// Hidden categories of every kind, with Unhide. (Hidden channels: Live TV → Show Hidden.)
private struct HiddenSettingsView: View {
    let state: AppState
    @State private var hidden: [HiddenCategory] = []

    var body: some View {
        Form {
            Section {
                if hidden.isEmpty {
                    Text("Nothing hidden. Right-click a group in Live TV, or a category in Movies or Series, to hide it.")
                        .foregroundStyle(.secondary)
                }
                ForEach(hidden) { category in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(category.name)
                            Text("\(label(category.kind)) · \(category.providerName)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Unhide") {
                            Task {
                                try? await state.library.setCategoryHidden(false, providerID: category.providerID,
                                                                           kind: category.kind, categoryID: category.categoryID)
                                await load()
                            }
                        }
                    }
                }
            } header: { Text("Hidden Categories") } footer: {
                Text("Hidden channels are shown dimmed in Live TV when Show Hidden is on; right-click one to unhide it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    private func load() async {
        hidden = (try? await state.library.hiddenCategories()) ?? []
    }

    private func label(_ kind: ContentKind) -> String {
        switch kind {
        case .live: "Live TV"
        case .movie: "Movies"
        case .series: "Series"
        }
    }
}

/// The notices (about 170 KB with every licence text) in a native text view, which lays out
/// large text lazily; a SwiftUI Text would measure all of it up front.
private struct NoticesTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = true
            textView.backgroundColor = .textBackgroundColor
            textView.textContainerInset = NSSize(width: 10, height: 10)
            textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            textView.string = text
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
}

/// Version, update checks and acknowledgements.
private struct AboutSettingsView: View {
    @Bindable var updates: UpdateController
    @State private var showingNotices = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Lumio").font(.title2.bold())
                        Text(version).foregroundStyle(.secondary).textSelection(.enabled)
                        if let copyright = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String {
                            Text(copyright).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle("Check for updates when Lumio opens", isOn: $updates.automaticChecks)
                    .disabled(!updates.isConfigured)
                HStack {
                    Button("Check Now") { Task { await updates.check(userInitiated: true) } }
                        .disabled(!updates.isConfigured || updates.isChecking)
                    if updates.isChecking { ProgressView().controlSize(.small) }
                    Spacer()
                    if let lastChecked = updates.lastChecked {
                        Text("Last checked \(lastChecked.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Updates") } footer: {
                Group {
                    if let feed = updates.feedDescription {
                        Text("Looks for new releases on \(feed). When there's one, Lumio asks before downloading it\(updates.canInstall ? ", checks its signature, installs it and reopens" : ""). Nothing about you or your providers is sent.")
                    } else {
                        Text("This build has no release feed, so it never checks for updates. Set UPDATE_REPOSITORY in project.yml to turn this on.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Acknowledgements…") { showingNotices = true }
                Text("Lumio is a player only. It doesn't provide any channels, streams or other content: you need your own subscription and Xtream Codes login from an IPTV provider, and you're responsible for using it only with services you're entitled to.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Legal") }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingNotices) { NoticesSheet() }
    }
}

/// The bundled THIRD-PARTY-NOTICES.md, as plain text.
private struct NoticesSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var text: String {
        Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "The acknowledgements file is missing from this build."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Acknowledgements").font(.title2.bold())
            NoticesTextView(text: text)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }
}
