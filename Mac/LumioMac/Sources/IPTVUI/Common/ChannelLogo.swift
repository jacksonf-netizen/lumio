import AppKit
import SwiftUI

/// A channel's logo on a soft rounded tile, or its initials when it has no logo (or the logo fails
/// to load), so every row lines up the same way.
struct ChannelLogo: View {
    let name: String
    let url: URL?
    var maxPixelSize: CGFloat = 128

    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geometry in
            let radius = min(geometry.size.width, geometry.size.height) * 0.18
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.quaternary.opacity(0.6))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(geometry.size.height * 0.1)
                } else {
                    Text(Monogram.initials(name))
                        .font(.system(size: geometry.size.height * 0.38, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 4)
                }
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let hit = ImageCache.shared.cached(url) {
                image = hit
                return
            }
            image = nil
            image = await ImageCache.shared.image(for: url, maxPixelSize: maxPixelSize)
        }
    }
}

/// Short initials for a channel name: "BBC One HD" → "BBC", "Harness News HD" → "HN".
enum Monogram {
    private static let noise: Set<String> = ["HD", "FHD", "UHD", "SD", "4K", "8K", "HEVC", "H265", "H264", "RAW", "50FPS", "60FPS"]

    static func initials(_ name: String) -> String {
        var text = name
        // Drop a short country/group prefix such as "UK:" or "US |".
        if let separator = text.firstIndex(where: { $0 == ":" || $0 == "|" }),
           text.distance(from: text.startIndex, to: separator) <= 4 {
            text = String(text[text.index(after: separator)...])
        }
        let words = text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !noise.contains($0.uppercased()) }
        guard let first = words.first else { return "TV" }
        // Acronyms read best whole (BBC, CNN, ESPN).
        if first.count <= 4, first.count >= 2, first == first.uppercased(), first.contains(where: \.isLetter) {
            return first
        }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.joined()
    }
}

/// AppKit version of `ChannelLogo` for the channel table.
final class ChannelLogoTile: NSView {
    private let imageView = NSImageView()
    private let initials = NSTextField(labelWithString: "")
    private var url: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        imageView.imageScaling = .scaleProportionallyUpOrDown
        initials.alignment = .center
        initials.textColor = .secondaryLabelColor
        initials.lineBreakMode = .byClipping
        for view in [imageView, initials] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            initials.centerXAnchor.constraint(equalTo: centerXAnchor),
            initials.centerYAnchor.constraint(equalTo: centerYAnchor),
            initials.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) * 0.18
        initials.font = .systemFont(ofSize: max(9, bounds.height * 0.36), weight: .bold).rounded
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    func configure(name: String, url: URL?, maxPixelSize: CGFloat = 96) {
        initials.stringValue = Monogram.initials(name)
        guard url != self.url || imageView.image == nil else { return }
        self.url = url
        show(nil)
        guard let url else { return }
        if let cached = ImageCache.shared.cached(url) {
            show(cached)
        } else {
            Task { [weak self] in
                let image = await ImageCache.shared.image(for: url, maxPixelSize: maxPixelSize)
                if self?.url == url { self?.show(image) }
            }
        }
    }

    private func show(_ image: NSImage?) {
        imageView.image = image
        initials.isHidden = image != nil
    }
}

extension NSFont {
    /// The rounded design of this font, when available.
    var rounded: NSFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
