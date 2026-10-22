import AppKit
import IPTVCore
import SwiftUI

/// Logo and poster loading with a memory cache and a 300 MB disk cache. Only fetches the URLs
/// providers give us; no third-party services.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    /// A decoded image and the size it was decoded for (smaller when the source itself is smaller).
    private final class Entry {
        let image: NSImage
        let requested: CGFloat
        init(image: NSImage, requested: CGFloat) {
            self.image = image
            self.requested = requested
        }
    }

    private let memory = NSCache<NSURL, Entry>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let session: URLSession

    private init() {
        memory.countLimit = 2_000
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IPTVStreamer/Images", isDirectory: true)
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 300 << 20, directory: caches)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
    }

    func cached(_ url: URL) -> NSImage? {
        memory.object(forKey: url as NSURL)?.image
    }

    func image(for url: URL, maxPixelSize: CGFloat = 256) async -> NSImage? {
        // A copy decoded smaller (a poster in a row, then on its detail page) is decoded again at
        // the larger size, from the disk cache.
        let entry = memory.object(forKey: url as NSURL)
        if let entry, entry.requested >= maxPixelSize * 0.9 { return entry.image }
        let key = "\(Int(maxPixelSize))|\(url.absoluteString)"
        if let running = inFlight[key] { return await running.value }
        let session = self.session
        let task = Task<NSImage?, Never>.detached {
            guard let data = await Self.fetch(url, session: session) else { return nil }
            return Self.downsample(data, maxPixelSize: maxPixelSize)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        // Keep the larger of what's cached and what was just decoded.
        if let image, maxPixelSize >= memory.object(forKey: url as NSURL)?.requested ?? 0 {
            memory.setObject(Entry(image: image, requested: maxPixelSize), forKey: url as NSURL)
        }
        return image ?? cached(url)
    }

    /// Logos and posters are well under a megabyte; anything over this is refused.
    nonisolated static let maxImageBytes = 15 << 20

    /// The image's bytes, from the disk cache or the network. Web URLs only (provider data could
    /// point at local files), and never more than `maxImageBytes`, so a broken or hostile server
    /// can't exhaust memory.
    nonisolated static func fetch(_ url: URL, session: URLSession) async -> Data? {
        guard url.isWebURL else { return nil }
        let request = URLRequest(url: url)
        let cache = session.configuration.urlCache
        if let cached = cache?.cachedResponse(for: request), !cached.data.isEmpty { return cached.data }
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, http.statusCode < 400,
              response.expectedContentLength <= Int64(maxImageBytes)
        else { return nil }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxImageBytes {
                    bytes.task.cancel()
                    return nil
                }
            }
        } catch {
            return nil
        }
        cache?.storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
        return data
    }

    /// Decodes at display size so thousands of logos don't hold full-size bitmaps.
    nonisolated private static func downsample(_ data: Data, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// A channel logo or poster with a placeholder.
struct RemoteImage: View {
    let url: URL?
    var maxPixelSize: CGFloat = 256
    var contentMode: ContentMode = .fit
    /// SF Symbol shown until the image loads; nil shows nothing.
    var placeholder: String? = "tv"

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if let placeholder {
                Image(systemName: placeholder)
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            let loaded = await ImageCache.shared.image(for: url, maxPixelSize: maxPixelSize)
            // Fade in images that came from the network; cached ones appear instantly.
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}
