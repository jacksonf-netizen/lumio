import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ServerURLError: Error, Equatable, CustomStringConvertible {
    case empty
    case invalid
    case unsupportedScheme(String)
    case containsCredentials
    /// A line of a pasted list that isn't a link (1-based line number).
    case notALink(line: Int)
    case differentLogins
    case tooMany(Int)

    public var description: String {
        switch self {
        case .notALink(let line): "Line \(line) isn't a link. Put one server address on each line."
        case .differentLogins: "These links contain different usernames or passwords. Add each login as its own provider."
        case .tooMany(let limit): "That's more than \(limit) links. Keep the ones your seller lists for this account."
        case .empty: "Enter the server URL."
        case .invalid: "That doesn't look like a valid server URL."
        case .unsupportedScheme(let scheme): "Unsupported URL scheme \"\(scheme)\". Use http or https."
        case .containsCredentials: "Don't put the username or password in the URL. Use the fields below."
        }
    }
}

/// Server addresses pasted as a list, plus a login found inside them.
public struct ServerList: Sendable, Equatable {
    public var urls: [URL]
    /// From links like `http://host/get.php?username=…&password=…` (what sellers send as an M3U link).
    public var credentials: ProviderCredentials?
}

public enum ServerURL {
    public static let maxLinks = 20
    static let streamPaths: Set<String> = ["live", "movie", "series", "timeshift"]

    /// Reads what a seller sent: one link per line, top one preferred, or several on a line
    /// (separated by spaces or commas, as a TV's one-line field gets them). Lines may be bare
    /// addresses, full M3U or player_api links (their username and password are returned separately
    /// and stripped from the address), or have a label or bullet before the link. Blank lines and
    /// duplicates are skipped. Stream links (`/live/user/pass/1.ts`) work like M3U links.
    public static func parseList(_ text: String) throws -> ServerList {
        var urls: [URL] = []
        var credentials: ProviderCredentials?
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            for candidate in try candidates(in: line, number: index + 1) {
                let (url, login): (URL, ProviderCredentials?)
                do {
                    (url, login) = try normalize(String(candidate), allowingCredentials: true)
                } catch ServerURLError.invalid {
                    throw ServerURLError.notALink(line: index + 1)
                }
                if let login {
                    if let credentials, credentials != login { throw ServerURLError.differentLogins }
                    credentials = login
                }
                if !urls.contains(url) { urls.append(url) }
            }
        }
        guard !urls.isEmpty else { throw ServerURLError.empty }
        guard urls.count <= maxLinks else { throw ServerURLError.tooMany(maxLinks) }
        return ServerList(urls: urls, credentials: credentials)
    }

    /// The links on one line. With `http://` or `https://`, each runs from there to the next space
    /// or the next link; of the words around them, only ones shaped like an address
    /// (`host.example.com:8080`, `203.0.113.7`) count, so labels like "URL:" or "or" are ignored.
    /// Without, the line is bare addresses: one, or several separated by spaces or commas, each with
    /// a dot or a port (so "Username: jo" isn't taken for two links).
    private static func candidates(in line: String, number: Int) throws -> [Substring] {
        let starts = line.ranges(of: /(?i)https?:\/\//).map(\.lowerBound)
        if !starts.isEmpty {
            var found: [Substring] = []
            var gapStart = line.startIndex
            func addresses(in gap: Substring) {
                found += gap.split { $0.isWhitespace || $0 == "," || $0 == ";" }
                    .filter { $0.wholeMatch(of: /(?i)(([a-z0-9-]+\.)+[a-z]{2,}|\d{1,3}(\.\d{1,3}){3}|[a-z0-9.-]+(?=:))(:\d{1,5})?\/?/) != nil }
            }
            for (index, start) in starts.enumerated() {
                addresses(in: line[gapStart..<start])
                let limit = index + 1 < starts.count ? starts[index + 1] : line.endIndex
                let link = line[start..<limit].prefix { !$0.isWhitespace }
                let kept = link.count - link.reversed().prefix { ",;)]>".contains($0) }.count
                if kept > 0 { found.append(link.prefix(kept)) }
                gapStart = link.endIndex
            }
            addresses(in: line[gapStart...])
            return found
        }
        // "1. host:8080", "- host:8080", "• host:8080"
        let bare = line.replacing(/^(\d+[.)]|[-•*])\s+/, with: "")
        let tokens = bare.split { $0.isWhitespace || $0 == "," || $0 == ";" }
        guard tokens.count > 1 else { return tokens }
        guard tokens.allSatisfy({ $0.contains(".") || $0.contains(/:\d/) }) else { throw ServerURLError.notALink(line: number) }
        return tokens
    }

    /// Turns user input into a canonical base URL like `http://host:8080`.
    ///
    /// Accepts input with or without a scheme (defaults to http, which most Xtream panels use),
    /// strips trailing slashes and a pasted `player_api.php` / `get.php` / `xmltv.php` path with its
    /// query, and rejects URLs that embed credentials.
    public static func normalize(_ input: String) throws -> URL {
        try normalize(input, allowingCredentials: false).0
    }

    /// As `normalize`, but a username and password in the query are returned instead of refused.
    static func normalize(_ input: String, allowingCredentials: Bool) throws -> (URL, ProviderCredentials?) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ServerURLError.empty }
        if !text.contains("://") { text = "http://" + text }

        guard var components = URLComponents(string: text),
              let host = components.host, !host.isEmpty
        else { throw ServerURLError.invalid }

        let scheme = components.scheme?.lowercased() ?? "http"
        guard scheme == "http" || scheme == "https" else { throw ServerURLError.unsupportedScheme(scheme) }
        if components.user != nil || components.password != nil { throw ServerURLError.containsCredentials }
        var login: ProviderCredentials?
        if let items = components.queryItems {
            func value(_ name: String) -> String? {
                items.first { $0.name.lowercased() == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
            }
            let username = value("username"), password = value("password")
            if username != nil || password != nil {
                guard allowingCredentials, let username, let password else { throw ServerURLError.containsCredentials }
                login = ProviderCredentials(username: username, password: password)
            }
        }

        components.scheme = scheme
        components.host = host.lowercased()
        components.query = nil
        components.fragment = nil

        var path = components.path
        // A stream link (`/live/user/pass/123.ts`, also movie, series, timeshift) has the login in
        // its path: the address is what comes before it.
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        if let kind = segments.firstIndex(where: { streamPaths.contains($0.lowercased()) }),
           segments.count > kind + 2, !segments[kind + 1].isEmpty, !segments[kind + 2].isEmpty {
            guard allowingCredentials else { throw ServerURLError.containsCredentials }
            // (`path` is already percent-decoded.)
            let inPath = ProviderCredentials(username: String(segments[kind + 1]), password: String(segments[kind + 2]))
            if let login, login != inPath { throw ServerURLError.differentLogins }
            login = inPath
            path = segments[..<kind].joined(separator: "/")
        }
        for endpoint in ["player_api.php", "get.php", "xmltv.php", "panel_api.php"]
        where path.lowercased().hasSuffix("/" + endpoint) {
            path = String(path.dropLast(endpoint.count + 1))
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path

        guard let url = components.url else { throw ServerURLError.invalid }
        return (url, login)
    }
}
