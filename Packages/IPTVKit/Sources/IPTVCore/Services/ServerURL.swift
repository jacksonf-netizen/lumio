import Foundation

public enum ServerURLError: Error, Equatable, CustomStringConvertible {
    case empty
    case invalid
    case unsupportedScheme(String)
    case containsCredentials

    public var description: String {
        switch self {
        case .empty: "Enter the server URL."
        case .invalid: "That doesn't look like a valid server URL."
        case .unsupportedScheme(let scheme): "Unsupported URL scheme \"\(scheme)\". Use http or https."
        case .containsCredentials: "Don't put the username or password in the URL. Use the fields below."
        }
    }
}

public enum ServerURL {
    /// Turns user input into a canonical base URL like `http://host:8080`.
    ///
    /// Accepts input with or without a scheme (defaults to http, which most Xtream panels use),
    /// strips trailing slashes and a pasted `player_api.php` / `get.php` / `xmltv.php` path with its
    /// query, and rejects URLs that embed credentials.
    public static func normalize(_ input: String) throws -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ServerURLError.empty }
        if !text.contains("://") { text = "http://" + text }

        guard var components = URLComponents(string: text),
              let host = components.host, !host.isEmpty
        else { throw ServerURLError.invalid }

        let scheme = components.scheme?.lowercased() ?? "http"
        guard scheme == "http" || scheme == "https" else { throw ServerURLError.unsupportedScheme(scheme) }
        if components.user != nil || components.password != nil { throw ServerURLError.containsCredentials }
        if let items = components.queryItems,
           items.contains(where: {
               ["username", "password"].contains($0.name.lowercased()) && !($0.value ?? "").isEmpty
           }) {
            throw ServerURLError.containsCredentials
        }

        components.scheme = scheme
        components.host = host.lowercased()
        components.query = nil
        components.fragment = nil

        var path = components.path
        for endpoint in ["player_api.php", "get.php", "xmltv.php", "panel_api.php"]
        where path.lowercased().hasSuffix("/" + endpoint) {
            path = String(path.dropLast(endpoint.count + 1))
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path

        guard let url = components.url else { throw ServerURLError.invalid }
        return url
    }
}
