// macOS-only: AppKit drawing for the EPG grid. A single view draws only the visible rectangle, so
// scrolling stays smooth with thousands of channels and a week of programmes.
import AppKit
import IPTVCore

@MainActor
protocol GuideGridDataSource: AnyObject {
    /// Programmes for `ref` overlapping `window`, or nil if not loaded yet (the grid asks via `request`).
    func programmes(for ref: EPGRef, day: Int) -> [Programme]?
    /// Load these (ref, day) blocks; call `GuideGridView.dataDidChange()` when done.
    func request(_ blocks: [(EPGRef, Int)])
}

@MainActor
final class GuideGridView: NSView {
    struct Metrics {
        var rowHeight: CGFloat = 56
        var channelWidth: CGFloat = 230
        var headerHeight: CGFloat = 30
        var pointsPerMinute: CGFloat = 4.5
    }

    // MARK: Inputs

    var metrics = Metrics() { didSet { relayout() } }
    var channels: [ChannelListItem] = [] { didSet { relayout(); needsDisplay = true } }
    /// Guide timeline start (left edge of the programme area).
    var origin = Date() { didSet { relayout() } }
    var days = 8 { didSet { relayout() } }
    weak var dataSource: GuideGridDataSource?
    var currentChannelID: String?

    var onSelect: ((ChannelListItem, Programme?) -> Void)?
    var onActivate: ((ChannelListItem, Programme?) -> Void)?
    /// Right-click menu for a channel row (nil = no menu).
    var menuForChannel: ((ChannelListItem) -> NSMenu?)?
    /// When set, channels can be dragged up and down in the channel column. Called with the
    /// row moved and the index it's inserted before (as in `Array.move(fromOffsets:toOffset:)`).
    var onMoveChannel: ((Int, Int) -> Void)?
    /// Keys the grid doesn't use itself, offered to the host first (the player closes its guide
    /// overlay on Esc or G). Return true when handled.
    var onOtherKey: ((NSEvent) -> Bool)?

    /// Row being dragged and the insertion index under the pointer.
    private var dragRow: Int?
    private var dropIndex: Int?
    private var dragStart: NSPoint?

    private(set) var selectedRow: Int?
    private(set) var selectedProgramme: Programme?

    // MARK: Layout

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    /// The scroll view whose (invisible) document view sets the scrollable size. This view sits on
    /// top of it at viewport size and draws whatever the scroll offset says is visible.
    weak var scrollView: NSScrollView? {
        didSet { attachToScrollView() }
    }

    private var totalMinutes: CGFloat { CGFloat(days * 24 * 60) }

    /// Scroll offset in document coordinates.
    private var offset: NSPoint { scrollView?.contentView.bounds.origin ?? .zero }

    /// The visible part of the document.
    var viewport: NSRect { NSRect(origin: offset, size: bounds.size) }

    private func relayout() {
        let width = metrics.channelWidth + totalMinutes * metrics.pointsPerMinute
        let height = metrics.headerHeight + CGFloat(channels.count) * metrics.rowHeight
        if let document = scrollView?.documentView {
            let size = NSSize(width: width, height: max(height, bounds.height))
            if document.frame.size != size { document.setFrameSize(size) }
        }
        needsDisplay = true
    }

    func x(for date: Date) -> CGFloat {
        metrics.channelWidth + CGFloat(date.timeIntervalSince(origin) / 60) * metrics.pointsPerMinute
    }

    func date(forX x: CGFloat) -> Date {
        origin.addingTimeInterval(Double((x - metrics.channelWidth) / metrics.pointsPerMinute) * 60)
    }

    func dayIndex(for date: Date) -> Int {
        Int(floor(date.timeIntervalSince(origin) / 86_400))
    }

    // MARK: Scrolling

    private func attachToScrollView() {
        guard let clip = scrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: clip)
        relayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
        requestVisibleData()
    }

    @objc private func boundsChanged() {
        needsDisplay = true
        requestVisibleData()
    }

    override func scrollWheel(with event: NSEvent) {
        scrollView?.scrollWheel(with: event)
    }

    private func setOffset(_ point: NSPoint, animated: Bool) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let maxX = max(0, document.frame.width - bounds.width)
        let maxY = max(0, document.frame.height - bounds.height)
        let clamped = NSPoint(x: min(max(0, point.x), maxX), y: min(max(0, point.y), maxY))
        let clip = scrollView.contentView
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                clip.animator().setBoundsOrigin(clamped)
            }
        } else {
            clip.setBoundsOrigin(clamped)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    /// Scrolls the minimum amount so `rect` (document coordinates) is visible below the header and
    /// right of the channel column.
    private func reveal(_ rect: NSRect) {
        var origin = offset
        let usable = NSRect(x: offset.x + metrics.channelWidth, y: offset.y + metrics.headerHeight,
                            width: bounds.width - metrics.channelWidth, height: bounds.height - metrics.headerHeight)
        if rect.minY < usable.minY { origin.y -= usable.minY - rect.minY }
        if rect.maxY > usable.maxY { origin.y += rect.maxY - usable.maxY }
        if rect.width < usable.width {
            if rect.minX < usable.minX { origin.x -= usable.minX - rect.minX }
            if rect.maxX > usable.maxX { origin.x += rect.maxX - usable.maxX }
        }
        if origin != offset { setOffset(origin, animated: false) }
    }

    /// Scrolls so `date` is near the left edge of the programme area (a little history visible).
    func scroll(to date: Date, animated: Bool = false) {
        // Leave half an hour of history visible to the left.
        let target = x(for: date) - metrics.channelWidth - 30 * metrics.pointsPerMinute
        setOffset(NSPoint(x: target, y: offset.y), animated: animated)
    }

    func scrollToRow(_ row: Int) {
        let y = metrics.headerHeight + CGFloat(row) * metrics.rowHeight
        reveal(NSRect(x: offset.x + metrics.channelWidth, y: y, width: 1, height: metrics.rowHeight))
    }

    private func visibleRows() -> Range<Int> {
        let visible = viewport
        let first = max(0, Int((visible.minY) / metrics.rowHeight) - 1)
        let last = min(channels.count, Int((visible.maxY - metrics.headerHeight) / metrics.rowHeight) + 2)
        return first < last ? first..<last : 0..<0
    }

    func requestVisibleData() {
        guard let dataSource, !channels.isEmpty else { return }
        let rows = visibleRows()
        // Prefetch a few rows beyond the edges and the neighbouring day.
        let prefetch = max(0, rows.lowerBound - 8)..<min(channels.count, rows.upperBound + 8)
        let firstDay = max(0, dayIndex(for: date(forX: viewport.minX + metrics.channelWidth)))
        let lastDay = min(days - 1, dayIndex(for: date(forX: viewport.maxX)))
        var blocks: [(EPGRef, Int)] = []
        for row in prefetch {
            guard let ref = channels[row].epg else { continue }
            for day in firstDay...max(firstDay, lastDay) where dataSource.programmes(for: ref, day: day) == nil {
                blocks.append((ref, day))
            }
        }
        if !blocks.isEmpty { dataSource.request(blocks) }
    }

    func dataDidChange() {
        needsDisplay = true
    }

    // MARK: Drawing

    private let cellFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    private let cellSubFont = NSFont.systemFont(ofSize: 11)
    private let channelFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let headerFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
    private var logoRequests: Set<URL> = []

    override func draw(_ dirtyRect: NSRect) {
        // Rows just outside the viewport are drawn too (so scrolling never shows a gap); keep them
        // from painting over the views around the guide.
        NSBezierPath(rect: bounds).addClip()
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let visible = viewport
        // Draw in document coordinates.
        let transform = NSAffineTransform()
        transform.translateX(by: -visible.minX, yBy: -visible.minY)
        transform.concat()
        let now = Date()
        let rows = visibleRows()
        let windowStart = date(forX: visible.minX + metrics.channelWidth)
        let windowEnd = date(forX: visible.maxX)

        // Programme cells.
        for row in rows {
            let channel = channels[row]
            let y = metrics.headerHeight + CGFloat(row) * metrics.rowHeight
            let rowRect = NSRect(x: visible.minX, y: y, width: visible.width, height: metrics.rowHeight)
            if row == selectedRow {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.08).setFill()
                rowRect.fill()
            }
            guard let ref = channel.epg else {
                drawEmptyRow(y: y, from: windowStart, to: windowEnd, text: "No guide data")
                continue
            }
            var seen = Set<Int64>()
            var any = false
            for day in max(0, dayIndex(for: windowStart))...max(0, min(days - 1, dayIndex(for: windowEnd))) {
                for programme in dataSource?.programmes(for: ref, day: day) ?? [] where programme.stop > windowStart && programme.start < windowEnd {
                    if let id = programme.id, !seen.insert(id).inserted { continue }
                    any = true
                    drawProgramme(programme, y: y, now: now, selected: row == selectedRow && programme.id == selectedProgramme?.id)
                }
            }
            if !any, dataSource?.programmes(for: ref, day: max(0, dayIndex(for: windowStart))) != nil {
                drawEmptyRow(y: y, from: windowStart, to: windowEnd, text: "No information")
            }
            NSColor.separatorColor.setFill()
            NSRect(x: visible.minX, y: y + metrics.rowHeight - 0.5, width: visible.width, height: 0.5).fill()
        }

        drawNowLine(now: now, visible: visible)
        drawChannelColumn(rows: rows, visible: visible)
        drawDropIndicator(visible: visible)
        drawHeader(visible: visible, from: windowStart, to: windowEnd)
        drawCorner(visible: visible)
    }

    private func drawProgramme(_ programme: Programme, y: CGFloat, now: Date, selected: Bool) {
        let x0 = max(x(for: programme.start), viewport.minX + metrics.channelWidth)
        let x1 = x(for: programme.stop)
        guard x1 - x0 > 1 else { return }
        let rect = NSRect(x: x0 + 1, y: y + 2, width: x1 - x0 - 2, height: metrics.rowHeight - 4)
        let isNow = programme.start <= now && programme.stop > now
        let isPast = programme.stop <= now
        let fill: NSColor
        if selected {
            fill = .controlAccentColor
        } else if isNow {
            fill = NSColor.controlAccentColor.withAlphaComponent(0.22)
        } else {
            fill = NSColor.labelColor.withAlphaComponent(isPast ? 0.04 : 0.08)
        }
        fill.setFill()
        let shape = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        shape.fill()
        // Shade the part of a current programme that has already aired.
        if isNow, !selected {
            let elapsed = min(x(for: now), rect.maxX) - rect.minX
            if elapsed > 0 {
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
                NSRect(x: rect.minX, y: rect.minY, width: elapsed, height: rect.height).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        let textColor: NSColor = selected ? .white : (isPast ? .secondaryLabelColor : .labelColor)
        let inner = rect.insetBy(dx: 8, dy: 6)
        guard inner.width > 12 else { return }
        let title = NSAttributedString(string: programme.title, attributes: [.font: cellFont, .foregroundColor: textColor])
        title.draw(with: NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: 17),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let time = "\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.stop.formatted(date: .omitted, time: .shortened))"
        let sub = NSAttributedString(string: time, attributes: [
            .font: cellSubFont, .foregroundColor: selected ? NSColor.white.withAlphaComponent(0.85) : NSColor.secondaryLabelColor,
        ])
        sub.draw(with: NSRect(x: inner.minX, y: inner.minY + 19, width: inner.width, height: 15),
                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawEmptyRow(y: CGFloat, from: Date, to: Date, text: String) {
        let rect = NSRect(x: viewport.minX + metrics.channelWidth + 1, y: y + 2,
                          width: viewport.width - metrics.channelWidth - 2, height: metrics.rowHeight - 4)
        NSColor.labelColor.withAlphaComponent(0.03).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        NSAttributedString(string: text, attributes: [.font: cellSubFont, .foregroundColor: NSColor.tertiaryLabelColor])
            .draw(at: NSPoint(x: rect.minX + 10, y: rect.midY - 7))
    }

    private func drawNowLine(now: Date, visible: NSRect) {
        let nx = x(for: now)
        guard nx > visible.minX + metrics.channelWidth, nx < visible.maxX else { return }
        NSColor.systemRed.setFill()
        NSRect(x: nx - 1, y: visible.minY + metrics.headerHeight, width: 2, height: visible.height - metrics.headerHeight).fill()
        NSBezierPath(ovalIn: NSRect(x: nx - 4, y: visible.minY + metrics.headerHeight - 4, width: 8, height: 8)).fill()
    }

    private func drawChannelColumn(rows: Range<Int>, visible: NSRect) {
        let column = NSRect(x: visible.minX, y: visible.minY, width: metrics.channelWidth, height: visible.height)
        NSColor.controlBackgroundColor.setFill()
        column.fill()
        for row in rows {
            let channel = channels[row]
            let y = metrics.headerHeight + CGFloat(row) * metrics.rowHeight
            let rect = NSRect(x: visible.minX, y: y, width: metrics.channelWidth, height: metrics.rowHeight)
            if row == selectedRow {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).setFill()
                rect.fill()
            } else if channel.id == currentChannelID {
                NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
                rect.fill()
            }
            var x = rect.minX + 8
            if let number = channel.number {
                NSAttributedString(string: "\(number)", attributes: [.font: numberFont, .foregroundColor: NSColor.secondaryLabelColor])
                    .draw(with: NSRect(x: x, y: rect.midY - 7, width: 34, height: 14), options: .usesLineFragmentOrigin)
            }
            x += 36
            let logoRect = NSRect(x: x, y: rect.minY + 10, width: 54, height: rect.height - 20)
            let tile = NSBezierPath(roundedRect: logoRect, xRadius: 7, yRadius: 7)
            NSColor.quaternaryLabelColor.setFill()
            tile.fill()
            let cachedLogo = channel.logoURL.flatMap { ImageCache.shared.cached($0) }
            if let image = cachedLogo {
                image.draw(in: aspectFit(image.size, in: logoRect.insetBy(dx: 4, dy: 4)))
            } else {
                let initials = NSAttributedString(string: Monogram.initials(channel.name), attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .bold).rounded, .foregroundColor: NSColor.secondaryLabelColor,
                ])
                let size = initials.size()
                initials.draw(at: NSPoint(x: logoRect.midX - min(size.width, logoRect.width - 6) / 2, y: logoRect.midY - size.height / 2))
            }
            if let url = channel.logoURL, cachedLogo == nil {
                if !logoRequests.contains(url) {
                    logoRequests.insert(url)
                    Task { [weak self] in
                        _ = await ImageCache.shared.image(for: url, maxPixelSize: 128)
                        self?.needsDisplay = true
                    }
                }
            }
            x += 62
            NSAttributedString(string: channel.name, attributes: [.font: channelFont, .foregroundColor: NSColor.labelColor])
                .draw(with: NSRect(x: x, y: rect.midY - 9, width: rect.maxX - x - 8, height: 18),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            NSColor.separatorColor.setFill()
            NSRect(x: rect.minX, y: rect.maxY - 0.5, width: rect.width, height: 0.5).fill()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: column.maxX - 0.5, y: column.minY, width: 0.5, height: column.height).fill()
    }

    /// While reordering: the dragged row is tinted and a line shows where it will land.
    private func drawDropIndicator(visible: NSRect) {
        guard let dragRow, let dropIndex else { return }
        let rowRect = NSRect(x: visible.minX, y: metrics.headerHeight + CGFloat(dragRow) * metrics.rowHeight,
                             width: metrics.channelWidth, height: metrics.rowHeight)
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        rowRect.fill()
        let y = metrics.headerHeight + CGFloat(dropIndex) * metrics.rowHeight
        NSColor.controlAccentColor.setFill()
        NSRect(x: visible.minX + 6, y: y - 1.5, width: visible.width - 12, height: 3).fill()
        NSBezierPath(ovalIn: NSRect(x: visible.minX + 2, y: y - 4, width: 8, height: 8)).fill()
    }

    private func drawHeader(visible: NSRect, from: Date, to: Date) {
        let header = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: metrics.headerHeight)
        NSColor.controlBackgroundColor.setFill()
        header.fill()
        let calendar = Calendar.current
        let step: TimeInterval = 30 * 60
        var tick = Date(timeIntervalSinceReferenceDate: floor(from.timeIntervalSinceReferenceDate / step) * step)
        while tick < to {
            let tx = x(for: tick)
            if tx >= visible.minX + metrics.channelWidth {
                NSColor.separatorColor.setFill()
                NSRect(x: tx, y: header.maxY - 6, width: 0.5, height: 6).fill()
                let isHour = calendar.component(.minute, from: tick) == 0
                let isMidnight = isHour && calendar.component(.hour, from: tick) == 0
                let label = isMidnight ? tick.formatted(.dateTime.weekday(.abbreviated).day()) : tick.formatted(date: .omitted, time: .shortened)
                NSAttributedString(string: label, attributes: [
                    .font: headerFont, .foregroundColor: isHour ? NSColor.labelColor : NSColor.secondaryLabelColor,
                ]).draw(at: NSPoint(x: tx + 4, y: header.minY + 8))
            }
            tick.addTimeInterval(step)
        }
        NSColor.separatorColor.setFill()
        NSRect(x: header.minX, y: header.maxY - 0.5, width: header.width, height: 0.5).fill()
    }

    private func drawCorner(visible: NSRect) {
        let corner = NSRect(x: visible.minX, y: visible.minY, width: metrics.channelWidth, height: metrics.headerHeight)
        NSColor.controlBackgroundColor.setFill()
        corner.fill()
        let day = date(forX: visible.minX + metrics.channelWidth)
        NSAttributedString(string: day.formatted(.dateTime.weekday(.wide).day().month()), attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ]).draw(at: NSPoint(x: corner.minX + 10, y: corner.minY + 8))
    }

    private func aspectFit(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    // MARK: Interaction

    private func hit(_ point: NSPoint) -> (row: Int, programme: Programme?)? {
        guard point.y > viewport.minY + metrics.headerHeight else { return nil }
        let row = Int((point.y - metrics.headerHeight) / metrics.rowHeight)
        guard channels.indices.contains(row) else { return nil }
        guard point.x > viewport.minX + metrics.channelWidth, let ref = channels[row].epg else { return (row, nil) }
        let time = date(forX: point.x)
        let programme = dataSource?.programmes(for: ref, day: dayIndex(for: time))?.first { $0.start <= time && $0.stop > time }
        return (row, programme)
    }

    private func documentPoint(_ event: NSEvent) -> NSPoint {
        let local = convert(event.locationInWindow, from: nil)
        return NSPoint(x: local.x + offset.x, y: local.y + offset.y)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = documentPoint(event)
        guard let (row, programme) = hit(point) else { return }
        select(row: row, programme: programme)
        if event.clickCount == 2 {
            onActivate?(channels[row], programme)
        } else if onMoveChannel != nil, point.x < viewport.minX + metrics.channelWidth {
            dragRow = row
            dragStart = point
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragRow != nil, let dragStart else { return }
        let point = documentPoint(event)
        // Start reordering only after a deliberate move, so clicks still just select.
        guard dropIndex != nil || abs(point.y - dragStart.y) > 4 else { return }
        // Scroll when dragging past the top or bottom edge.
        let local = convert(event.locationInWindow, from: nil)
        if local.y < metrics.headerHeight + 10 {
            setOffset(NSPoint(x: offset.x, y: offset.y - 12), animated: false)
        } else if local.y > bounds.height - 10 {
            setOffset(NSPoint(x: offset.x, y: offset.y + 12), animated: false)
        }
        let index = Int(((point.y - metrics.headerHeight) / metrics.rowHeight).rounded())
        dropIndex = min(max(0, index), channels.count)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragRow = nil
            dropIndex = nil
            dragStart = nil
            needsDisplay = true
        }
        guard let dragRow, let dropIndex, dropIndex != dragRow, dropIndex != dragRow + 1 else { return }
        let landed = dropIndex > dragRow ? dropIndex - 1 : dropIndex
        onMoveChannel?(dragRow, dropIndex)
        selectedRow = landed
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menuForChannel, let (row, programme) = hit(documentPoint(event)) else { return nil }
        select(row: row, programme: programme)
        return menuForChannel(channels[row])
    }

    override func resetCursorRects() {
        // An open-hand cursor over the channel column hints that rows can be dragged.
        guard onMoveChannel != nil else { return }
        addCursorRect(NSRect(x: 0, y: metrics.headerHeight, width: metrics.channelWidth, height: bounds.height), cursor: .openHand)
    }

    /// Moves the highlight without notifying `onSelect` (after the channel list is reloaded).
    func restoreSelection(row: Int?, programme: Programme?) {
        selectedRow = row
        selectedProgramme = programme
        needsDisplay = true
    }

    func select(row: Int, programme: Programme?) {
        selectedRow = row
        selectedProgramme = programme
        needsDisplay = true
        onSelect?(channels[row], programme)
    }

    override func keyDown(with event: NSEvent) {
        guard !channels.isEmpty else {
            if onOtherKey?(event) != true { super.keyDown(with: event) }
            return
        }
        let row = selectedRow ?? visibleRows().lowerBound
        switch event.keyCode {
        case 125: // down
            moveSelection(toRow: min(channels.count - 1, row + 1))
        case 126: // up
            moveSelection(toRow: max(0, row - 1))
        case 124: // right
            stepProgramme(forward: true)
        case 123: // left
            stepProgramme(forward: false)
        case 36, 76: // return
            if let selectedRow { onActivate?(channels[selectedRow], selectedProgramme) }
        default:
            if onOtherKey?(event) != true { super.keyDown(with: event) }
        }
    }

    private func moveSelection(toRow row: Int) {
        let time = selectedProgramme.map { max($0.start, Date()) } ?? max(Date(), date(forX: viewport.minX + metrics.channelWidth + 40))
        let programme = channels[row].epg.flatMap { dataSource?.programmes(for: $0, day: dayIndex(for: time))?.first { $0.start <= time && $0.stop > time } }
        select(row: row, programme: programme)
        scrollToRow(row)
    }

    private func stepProgramme(forward: Bool) {
        guard let row = selectedRow, let ref = channels[row].epg else { return }
        let reference = selectedProgramme ?? Programme(providerID: ProviderID(""), epgID: "", start: Date(), stop: Date(), title: "")
        let day = dayIndex(for: reference.start)
        let candidates = ((dataSource?.programmes(for: ref, day: day - 1) ?? []) + (dataSource?.programmes(for: ref, day: day) ?? [])
                          + (dataSource?.programmes(for: ref, day: day + 1) ?? [])).sorted { $0.start < $1.start }
        let next = forward ? candidates.first { $0.start >= reference.stop } : candidates.last { $0.stop <= reference.start }
        guard let next else { return }
        select(row: row, programme: next)
        reveal(NSRect(x: x(for: next.start) - 20, y: metrics.headerHeight + CGFloat(row) * metrics.rowHeight,
                      width: x(for: next.stop) - x(for: next.start) + 40, height: metrics.rowHeight))
    }
}

/// Hosts the invisible scroll view (for gestures and scrollbars) with the grid drawn on top.
@MainActor
final class GuideContainerView: NSView {
    let scrollView = NSScrollView()
    let grid = GuideGridView()
    private let spacer = FlippedView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = spacer
        // Since macOS 14 views don't clip their drawing to their bounds unless asked, and the grid
        // draws a row beyond each edge of the viewport.
        clipsToBounds = true
        grid.clipsToBounds = true
        addSubview(scrollView)
        addSubview(grid)
        grid.scrollView = scrollView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        // The grid covers the content area; scrollers (if visible) stay usable beside it.
        grid.frame = scrollView.contentView.frame
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
