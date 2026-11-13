import Foundation

/// Guide links (XMLTV addresses) the user added to a provider, for the channels its own guide
/// leaves out. They often carry a login or token, so they're kept with the provider's login in the
/// Keychain / Android Keystore, never in the database or settings: as their own item beside the
/// login, so editing one never touches the other.
public struct GuideLinkStore: Sendable {
    private let secrets: any SecretStore

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    /// The links for `providerID`, in the order added. Empty when there are none.
    public func links(for providerID: ProviderID) throws -> [URL] {
        guard let item = try secrets.load(for: Self.key(providerID)) else { return [] }
        let strings = (try? JSONDecoder().decode([String].self, from: Data(item.password.utf8))) ?? []
        return strings.compactMap(URL.init(string:))
    }

    /// Replaces the links for `providerID`; an empty list removes the item.
    public func setLinks(_ links: [URL], for providerID: ProviderID) throws {
        guard !links.isEmpty else { return try delete(for: providerID) }
        let json = String(decoding: try JSONEncoder().encode(links.map(\.absoluteString)), as: UTF8.self)
        try secrets.save(ProviderCredentials(username: Self.marker, password: json), for: Self.key(providerID))
    }

    public func delete(for providerID: ProviderID) throws {
        try secrets.delete(for: Self.key(providerID))
    }

    /// Where the links live: an item named after the provider, beside its login.
    static func key(_ providerID: ProviderID) -> ProviderID { ProviderID(providerID.rawValue + ".guide-links") }
    static let marker = "guide-links"

    /// A link as it may be shown or logged: the host and path, without the query (where a login
    /// or token usually is) or any user:password@.
    public static func display(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.query = nil
        parts?.user = nil
        parts?.password = nil
        parts?.fragment = nil
        let text = parts?.string ?? url.host ?? "guide link"
        return text.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }

    /// Reads a typed or pasted link: http(s) only; "http://" is assumed when left off.
    public static func parse(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "http://" + trimmed
        }
        guard let url = URL(string: trimmed), let host = url.host, host.contains(".") || host == "localhost" else { return nil }
        return url
    }
}
