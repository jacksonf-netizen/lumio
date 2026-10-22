import Foundation

/// Masks credentials in URLs and free text before they are logged or shown on screen
/// (diagnostics overlay, error messages).
///
/// Handles:
/// - Xtream stream paths: `/live/<user>/<pass>/123.ts` (also `movie`, `series`, `timeshift`)
/// - Query parameters: `username=...`, `password=...`
/// - URL user-info: `http://user:pass@host`
/// - Any literal occurrence of known credentials passed in explicitly.
public enum CredentialRedactor {
    public static let mask = "***"

    private static let streamPath = try! NSRegularExpression(
        pattern: #"/(live|movie|series|timeshift)/[^/?#\s]+/[^/?#\s]+/"#, options: [.caseInsensitive])
    private static let queryCredential = try! NSRegularExpression(
        pattern: #"\b(username|password)=[^&#\s]*"#, options: [.caseInsensitive])
    private static let userInfo = try! NSRegularExpression(
        pattern: #"://[^/@\s]+@"#, options: [])

    public static func redact(_ url: URL, credentials: [ProviderCredentials] = []) -> String {
        redact(url.absoluteString, credentials: credentials)
    }

    public static func redact(_ text: String, credentials: [ProviderCredentials] = []) -> String {
        var result = text
        result = replace(streamPath, in: result, template: "/$1/\(mask)/\(mask)/")
        result = replace(queryCredential, in: result, template: "$1=\(mask)")
        result = replace(userInfo, in: result, template: "://\(mask)@")

        // Literal values last, longest first, so a password that contains the username is fully masked.
        let secrets = credentials
            .flatMap { [$0.password, $0.username] }
            .filter { $0.count >= 3 }
            .sorted { $0.count > $1.count }
        for secret in secrets {
            var forms = [secret]
            // Also the percent-encoded forms a URL may carry (strict and path-style encoding).
            for allowed in [Self.unreserved, CharacterSet.urlPathAllowed] {
                if let encoded = secret.addingPercentEncoding(withAllowedCharacters: allowed), encoded != secret {
                    forms.append(encoded)
                }
            }
            for form in forms {
                result = replaceWholeToken(form, in: result)
            }
        }
        return result
    }

    /// RFC 3986 unreserved characters.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Replaces `token` only where it isn't part of a longer word, so a password like "user" doesn't
    /// turn "username" into "***name".
    private static func replaceWholeToken(_ token: String, in text: String) -> String {
        let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: token) + "(?![A-Za-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: mask))
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, template: String) -> String {
        regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
