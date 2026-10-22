import Foundation

extension URL {
    /// An http or https URL with a host. Links from provider data (logos, posters, guide icons) must
    /// be one, so a provider can't point the app at local files (`file://`) or other schemes.
    public var isWebURL: Bool {
        guard let scheme = scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(host ?? "").isEmpty
    }
}

public enum HTTPHeader {
    /// A header value safe to send: control characters (line breaks could inject extra headers)
    /// removed, trimmed, and kept to a sensible length. Empty input gives `fallback`.
    public static func sanitized(_ value: String, fallback: String) -> String {
        let cleaned = String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(512))
    }
}
