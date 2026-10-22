// macOS-only: a virtualised channel list. SwiftUI's List measures every row up front, which costs
// seconds for providers with tens of thousands of channels; NSTableView with a fixed row height only
// ever creates and measures the rows on screen.
import AppKit
import SwiftUI
import IPTVCore

struct ChannelTableView: NSViewRepresentable {
    let channels: [ChannelListItem]
    let nowNext: [EPGRef: NowNext]
    @Binding var selection: ChannelListItem.ID?
    let allowsReordering: Bool
    var onActivate: (ChannelListItem) -> Void
    var onRowVisible: (ChannelListItem) -> Void
    var onMove: (IndexSet, Int) -> Void
    var makeMenu: (ChannelListItem) -> NSMenu

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ChannelNSTableView()
        table.headerView = nil
        table.rowHeight = 56
        table.usesAutomaticRowHeights = false
        table.style = .inset
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.intercellSpacing = NSSize(width: 0, height: 0)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("channel"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.registerForDraggedTypes([.channelRow])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        table.onReturn = { [weak coordinator = context.coordinator] in coordinator?.activateSelected() }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let oldIDs = coordinator.parent?.channels.map(\.id)
        let channelsChanged = oldIDs != channels.map(\.id) || coordinator.parent?.channels != channels
        let nowNextChanged = coordinator.parent?.nowNext != nowNext
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        if channelsChanged {
            table.reloadData()
        } else if nowNextChanged {
            let visible = table.rows(in: table.visibleRect)
            if visible.length > 0 {
                table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                                 columnIndexes: [0])
            }
        }
        // Keep the table's selection in step with the binding.
        let wanted = selection.flatMap { id in channels.firstIndex { $0.id == id } }
        if table.selectedRow != (wanted ?? -1) {
            coordinator.updatingSelection = true
            if let wanted {
                table.selectRowIndexes([wanted], byExtendingSelection: false)
                table.scrollRowToVisible(wanted)
            } else {
                table.deselectAll(nil)
            }
            coordinator.updatingSelection = false
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: ChannelTableView?
        weak var table: NSTableView?
        var updatingSelection = false

        private var channels: [ChannelListItem] { parent?.channels ?? [] }

        func numberOfRows(in tableView: NSTableView) -> Int { channels.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("ChannelCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ChannelCellView ?? {
                let cell = ChannelCellView()
                cell.identifier = identifier
                return cell
            }()
            guard channels.indices.contains(row), let parent else { return cell }
            let channel = channels[row]
            cell.configure(channel, nowNext: channel.epg.flatMap { parent.nowNext[$0] })
            parent.onRowVisible(channel)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updatingSelection, let table, let parent else { return }
            let row = table.selectedRow
            let id = channels.indices.contains(row) ? channels[row].id : nil
            if parent.selection != id { parent.selection = id }
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard channels.indices.contains(row) else { return }
            parent?.onActivate(channels[row])
        }

        func activateSelected() {
            guard let table, channels.indices.contains(table.selectedRow) else { return }
            parent?.onActivate(channels[table.selectedRow])
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, let parent else { return }
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            guard channels.indices.contains(row) else { return }
            for item in parent.makeMenu(channels[row]).items {
                item.menu?.removeItem(item)
                menu.addItem(item)
            }
        }

        // MARK: Drag to reorder

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent?.allowsReordering == true else { return nil }
            let item = NSPasteboardItem()
            item.setString(String(row), forType: .channelRow)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard parent?.allowsReordering == true, info.draggingSource as? NSTableView === tableView else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard let string = info.draggingPasteboard.pasteboardItems?.first?.string(forType: .channelRow),
                  let source = Int(string) else { return false }
            parent?.onMove(IndexSet(integer: source), row)
            return true
        }
    }
}

extension NSPasteboard.PasteboardType {
    static let channelRow = NSPasteboard.PasteboardType("com.jackson.iptvstreamer.channel-row")
}

/// Table that plays the selected channel on Return.
final class ChannelNSTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Native row: number, logo, name with badges, now playing and progress.
final class ChannelCellView: NSTableCellView {
    private let number = NSTextField(labelWithString: "")
    private let logo = ChannelLogoTile()
    private let name = NSTextField(labelWithString: "")
    private let now = NSTextField(labelWithString: "")
    private let badges = NSTextField(labelWithString: "")
    private let progress = ProgressBarView()
    private lazy var nameAtTop = name.topAnchor.constraint(equalTo: topAnchor, constant: 8)
    private lazy var nameCentered = name.centerYAnchor.constraint(equalTo: centerYAnchor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        number.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        number.textColor = .secondaryLabelColor
        number.alignment = .right
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        now.font = .systemFont(ofSize: 11)
        now.textColor = .secondaryLabelColor
        now.lineBreakMode = .byTruncatingTail
        badges.font = .systemFont(ofSize: 10, weight: .semibold)
        badges.textColor = .secondaryLabelColor
        for view in [number, logo, name, now, badges, progress] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        now.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badges.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            number.widthAnchor.constraint(equalToConstant: 34),
            number.centerYAnchor.constraint(equalTo: centerYAnchor),
            logo.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 8),
            logo.widthAnchor.constraint(equalToConstant: 50),
            logo.heightAnchor.constraint(equalToConstant: 34),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 10),
            nameAtTop,
            badges.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            badges.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            badges.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            now.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            now.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            now.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            progress.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            progress.topAnchor.constraint(equalTo: now.bottomAnchor, constant: 4),
            progress.widthAnchor.constraint(equalToConstant: 150),
            progress.heightAnchor.constraint(equalToConstant: 3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { progress.emphasized = backgroundStyle == .emphasized }
    }

    @MainActor
    func configure(_ channel: ChannelListItem, nowNext: NowNext?) {
        number.stringValue = channel.number.map(String.init) ?? ""
        name.stringValue = channel.name
        name.textColor = channel.isHidden ? .secondaryLabelColor : .labelColor
        let marks = NSMutableAttributedString()
        func add(_ text: String, color: NSColor = .secondaryLabelColor) {
            if marks.length > 0 { marks.append(NSAttributedString(string: "  ")) }
            marks.append(NSAttributedString(string: text, attributes: [.foregroundColor: color, .font: badges.font as Any]))
        }
        if channel.isFavorite { add("★", color: .systemYellow) }
        if channel.sourceProviders.count > 1 { add("\(channel.sourceProviders.count) sources") }
        if channel.isHidden { add("hidden") }
        badges.attributedStringValue = marks
        if let programme = nowNext?.now {
            now.stringValue = programme.title
            progress.fraction = nowNext?.progress() ?? 0
            progress.isHidden = false
        } else {
            now.stringValue = ""
            progress.isHidden = true
        }
        // Without a programme line the name sits in the middle of the row.
        let hasProgramme = nowNext?.now != nil
        nameCentered.isActive = !hasProgramme
        nameAtTop.isActive = hasProgramme
        logo.configure(name: channel.name, url: channel.logoURL)
    }
}

/// Thin progress bar (cheaper than NSProgressIndicator for many rows).
final class ProgressBarView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    /// On a highlighted (accent-coloured) row.
    var emphasized = false { didSet { if emphasized != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (emphasized ? NSColor.white.withAlphaComponent(0.3) : .quaternaryLabelColor).setFill()
        track.fill()
        var filled = bounds
        filled.size.width = bounds.width * CGFloat(min(1, max(0, fraction)))
        (emphasized ? NSColor.white : NSColor.controlAccentColor).setFill()
        NSBezierPath(roundedRect: filled, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}
