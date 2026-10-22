import Foundation

/// Normalises EPG channel ids everywhere they are stored or compared (trimmed, lowercased),
/// because providers are inconsistent about case.
public enum EPGKey {
    public static func normalize(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// One parsed `<programme>` before it is tied to a provider.
struct XMLTVProgramme: Equatable {
    var channel: String
    var start: Date
    var stop: Date
    var title: String
    var subtitle: String?
    var summary: String?
    var category: String?
    var episodeNumber: String?
    var iconURL: URL?
}

struct XMLTVChannel: Equatable {
    var id: String
    var displayName: String?
    var iconURL: URL?
}

/// SAX-style XMLTV parser over a file on disk. Holds at most one programme in memory at a time;
/// results are delivered through callbacks.
///
/// XMLParser stops at the first fatal syntax error. Everything delivered before that point is kept,
/// and the error is reported in `Result.error` so the caller can treat the import as partial.
final class XMLTVParser: NSObject, XMLParserDelegate {
    struct Result {
        var channels = 0
        var programmes = 0
        var skipped = 0
        var error: String?
    }

    private let onChannel: (XMLTVChannel) -> Void
    private let onProgramme: (XMLTVProgramme) -> Void
    private let shouldContinue: () -> Bool

    private var result = Result()
    private var text = ""
    private var collectingText = false

    private var channel: XMLTVChannel?
    private var programme: XMLTVProgramme?
    private var episodeSystem: String?
    private var episodeIsOnscreen = false
    private var parser: XMLParser?

    init(onChannel: @escaping (XMLTVChannel) -> Void,
         onProgramme: @escaping (XMLTVProgramme) -> Void,
         shouldContinue: @escaping () -> Bool = { true }) {
        self.onChannel = onChannel
        self.onProgramme = onProgramme
        self.shouldContinue = shouldContinue
    }

    /// Parses synchronously. Call from a background thread.
    func parse(fileAt url: URL) -> Result {
        guard let stream = InputStream(url: url) else {
            return Result(error: "cannot open guide file")
        }
        let parser = XMLParser(stream: stream)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        self.parser = parser
        let ok = parser.parse()
        if !ok, result.error == nil {
            let error = parser.parserError as NSError?
            result.error = "XML error at line \(parser.lineNumber): \(error?.localizedDescription ?? "unknown")"
        }
        self.parser = nil
        return result
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        switch name {
        case "programme":
            guard let channelID = attributes["channel"], !channelID.isEmpty,
                  let start = attributes["start"].flatMap(XMLTVDate.parse),
                  let stop = attributes["stop"].flatMap(XMLTVDate.parse),
                  stop > start
            else {
                result.skipped += 1
                programme = nil
                return
            }
            programme = XMLTVProgramme(channel: channelID, start: start, stop: stop, title: "")
            episodeIsOnscreen = false
        case "channel":
            if let id = attributes["id"], !id.isEmpty {
                channel = XMLTVChannel(id: id)
            }
        case "title", "sub-title", "desc", "category", "display-name":
            beginText()
        case "episode-num":
            episodeSystem = attributes["system"]
            beginText()
        case "icon":
            let src = attributes["src"].flatMap { URL(string: $0) }.flatMap { $0.isWebURL ? $0 : nil }
            if programme != nil {
                if programme?.iconURL == nil { programme?.iconURL = src }
            } else if channel != nil, channel?.iconURL == nil {
                channel?.iconURL = src
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingText { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = endText()
        if programme != nil {
            switch name {
            case "title":
                // Keep the first title (usually the primary language).
                if programme!.title.isEmpty, let value { programme!.title = value }
            case "sub-title":
                if programme!.subtitle == nil { programme!.subtitle = value }
            case "desc":
                if programme!.summary == nil { programme!.summary = value }
            case "category":
                if programme!.category == nil { programme!.category = value }
            case "episode-num":
                if let value {
                    let readable = episodeSystem == "xmltv_ns" ? XMLTVDate.readableEpisode(fromXMLTVNS: value) : value
                    // Prefer the human-readable "onscreen" form when both are present.
                    if programme!.episodeNumber == nil || (episodeSystem == "onscreen" && !episodeIsOnscreen) {
                        programme!.episodeNumber = readable
                        episodeIsOnscreen = episodeSystem == "onscreen"
                    }
                }
            case "programme":
                var finished = programme!
                if finished.title.isEmpty { finished.title = "No title" }
                onProgramme(finished)
                result.programmes += 1
                programme = nil
                if result.programmes % 2000 == 0, !shouldContinue() {
                    result.error = "cancelled"
                    parser.abortParsing()
                }
            default:
                break
            }
        } else if channel != nil {
            switch name {
            case "display-name":
                if channel!.displayName == nil { channel!.displayName = value }
            case "channel":
                onChannel(channel!)
                result.channels += 1
                channel = nil
            default:
                break
            }
        }
    }

    private func beginText() {
        text = ""
        collectingText = true
    }

    private func endText() -> String? {
        guard collectingText else { return nil }
        collectingText = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// XMLTV date parsing without DateFormatter (which is far too slow for millions of rows).
enum XMLTVDate {
    /// Parses `YYYYMMDDhhmmss ±hhmm`, also without seconds, without minutes, or without an offset (UTC).
    static func parse(_ string: String) -> Date? {
        var digits: [Int] = []
        digits.reserveCapacity(14)
        var offsetSign = 0
        var offsetDigits: [Int] = []
        var dateDone = false
        for byte in string.utf8 {
            let isDigit = byte >= 0x30 && byte <= 0x39
            if !dateDone {
                if isDigit {
                    if digits.count < 14 { digits.append(Int(byte - 0x30)) }
                    continue
                }
                dateDone = true
            }
            if offsetSign == 0 {
                if byte == UInt8(ascii: "+") { offsetSign = 1 } else if byte == UInt8(ascii: "-") { offsetSign = -1 }
            } else if isDigit, offsetDigits.count < 4 {
                offsetDigits.append(Int(byte - 0x30))
            }
        }
        guard digits.count >= 8 else { return nil }
        func number(_ range: Range<Int>) -> Int {
            range.reduce(0) { $0 * 10 + (digits.count > $1 ? digits[$1] : 0) }
        }
        let year = number(0..<4), month = number(4..<6), day = number(6..<8)
        let hour = number(8..<10), minute = number(10..<12), second = number(12..<14)
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }

        var offsetSeconds = 0
        if offsetSign != 0, offsetDigits.count >= 4 {
            let h = offsetDigits[0] * 10 + offsetDigits[1]
            let m = offsetDigits[2] * 10 + offsetDigits[3]
            offsetSeconds = offsetSign * (h * 3600 + m * 60)
        }
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// xmltv_ns is zero-based "season.episode.part", e.g. "2.4." → "S3 E5".
    static func readableEpisode(fromXMLTVNS value: String) -> String {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        func first(_ part: Substring?) -> Int? {
            part.flatMap { Int($0.split(separator: "/").first?.trimmingCharacters(in: .whitespaces) ?? "") }
        }
        let season = first(parts.first).map { $0 + 1 }
        let episode = first(parts.count > 1 ? parts[1] : nil).map { $0 + 1 }
        switch (season, episode) {
        case let (s?, e?): return "S\(s) E\(e)"
        case let (nil, e?): return "E\(e)"
        case let (s?, nil): return "S\(s)"
        default: return value
        }
    }
}
