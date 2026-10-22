import Foundation
import zlib

/// Prepares a downloaded guide for parsing: inflates gzip (or passes plain XML through), and
/// repairs the two most common faults in real-world XMLTV files on the fly:
/// - bare `&` that isn't an entity (e.g. "Tom & Jerry") → `&amp;`
/// - control characters that are illegal in XML 1.0 → removed
///
/// Works in fixed-size chunks so memory stays flat for guides of any size.
enum XMLTVStaging {
    enum StagingError: Error, CustomStringConvertible {
        case cannotOpen(String)
        case readFailed(String)

        var description: String {
            switch self {
            case .cannotOpen(let detail): "Couldn't open the guide file (\(detail))."
            case .readFailed(let detail): "Couldn't read the guide file (\(detail))."
            }
        }
    }

    /// Uncompressed guides beyond this are cut off (and imported up to there), so a malformed or
    /// hostile file can't fill the disk.
    static let maxStagedBytes: Int64 = 6 << 30

    /// Writes a clean, uncompressed copy of `source` to a new temp file and returns its URL.
    static func stage(_ source: URL, chunkSize: Int = 1 << 20, limit: Int64 = maxStagedBytes) throws -> URL {
        // gzopen reads gzip transparently and plain files as-is.
        guard let gz = gzopen(source.path, "rb") else { throw StagingError.cannotOpen(source.lastPathComponent) }
        defer { gzclose(gz) }
        gzbuffer(gz, 1 << 18)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmltv-\(UUID().uuidString).xml")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output)
        else { throw StagingError.cannotOpen("temp file") }
        defer { try? handle.close() }

        var sanitizer = XMLSanitizer()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var written: Int64 = 0
        while true {
            try Task.checkCancellation()
            if written >= limit {
                Log.epg.error("Guide is larger than \(limit >> 20) MB uncompressed; importing the first part only")
                break
            }
            let count = buffer.withUnsafeMutableBytes { gzread(gz, $0.baseAddress, UInt32(chunkSize)) }
            if count < 0 {
                var errnum: Int32 = 0
                let message = gzerror(gz, &errnum).map { String(cString: $0) } ?? "unknown"
                // A truncated gzip stream still gives us everything before the damage.
                if errnum == Z_BUF_ERROR || errnum == Z_DATA_ERROR {
                    Log.epg.error("Guide archive is damaged (\(message, privacy: .public)); importing what was readable")
                    break
                }
                throw StagingError.readFailed(message)
            }
            if count == 0 { break }
            let cleaned = sanitizer.process(buffer[0..<Int(count)])
            try handle.write(contentsOf: cleaned)
            written += Int64(cleaned.count)
        }
        try handle.write(contentsOf: sanitizer.finish())
        return output
    }
}

/// Streaming byte filter. Carries a few bytes across chunk boundaries so an entity split between
/// chunks is judged correctly.
///
/// XML only defines five named entities. Common HTML ones (`&nbsp;`, `&hellip;`, `&eacute;`…) are
/// rewritten as numeric references; any other `&` is escaped.
struct XMLSanitizer {
    /// Longest entity we recognise: `&#x10FFFF;` or a named one like `&hellip;`.
    private static let maxEntityLength = 12
    private static let xmlEntities: Set<String> = ["amp", "lt", "gt", "quot", "apos"]
    private static let htmlEntities: [String: Int] = [
        "nbsp": 160, "iexcl": 161, "pound": 163, "euro": 8364, "yen": 165, "sect": 167, "copy": 169,
        "laquo": 171, "raquo": 187, "reg": 174, "deg": 176, "plusmn": 177, "middot": 183, "frac12": 189,
        "iquest": 191, "times": 215, "divide": 247, "ndash": 8211, "mdash": 8212, "lsquo": 8216,
        "rsquo": 8217, "sbquo": 8218, "ldquo": 8220, "rdquo": 8221, "bdquo": 8222, "bull": 8226,
        "hellip": 8230, "trade": 8482, "prime": 8242,
        "Agrave": 192, "Aacute": 193, "Acirc": 194, "Atilde": 195, "Auml": 196, "Aring": 197, "AElig": 198,
        "Ccedil": 199, "Egrave": 200, "Eacute": 201, "Ecirc": 202, "Euml": 203, "Igrave": 204, "Iacute": 205,
        "Icirc": 206, "Iuml": 207, "Ntilde": 209, "Ograve": 210, "Oacute": 211, "Ocirc": 212, "Otilde": 213,
        "Ouml": 214, "Oslash": 216, "Ugrave": 217, "Uacute": 218, "Ucirc": 219, "Uuml": 220, "szlig": 223,
        "agrave": 224, "aacute": 225, "acirc": 226, "atilde": 227, "auml": 228, "aring": 229, "aelig": 230,
        "ccedil": 231, "egrave": 232, "eacute": 233, "ecirc": 234, "euml": 235, "igrave": 236, "iacute": 237,
        "icirc": 238, "iuml": 239, "ntilde": 241, "ograve": 242, "oacute": 243, "ocirc": 244, "otilde": 245,
        "ouml": 246, "oslash": 248, "ugrave": 249, "uacute": 250, "ucirc": 251, "uuml": 252, "yuml": 255,
    ]
    private static let escapedAmpersand = Array("&amp;".utf8)

    private var pending: [UInt8] = []

    mutating func process(_ chunk: ArraySlice<UInt8>) -> Data {
        var input = pending
        input.append(contentsOf: chunk)
        pending.removeAll(keepingCapacity: true)
        return filter(input, final: false)
    }

    mutating func finish() -> Data {
        let rest = pending
        pending = []
        return filter(rest, final: true)
    }

    private mutating func filter(_ input: [UInt8], final: Bool) -> Data {
        var output = Data()
        output.reserveCapacity(input.count + 64)
        var index = 0
        while index < input.count {
            let byte = input[index]
            if byte == UInt8(ascii: "&") {
                // Not enough bytes left to decide: wait for the next chunk.
                if !final, input.count - index <= Self.maxEntityLength + 1, !Self.hasTerminator(input, from: index) {
                    pending = Array(input[index...])
                    return output
                }
                switch Self.entity(in: input, at: index) {
                case .keep(let length):
                    output.append(contentsOf: input[index..<(index + length)])
                    index += length
                case .replace(let bytes, let length):
                    output.append(contentsOf: bytes)
                    index += length
                case .escape:
                    output.append(contentsOf: Self.escapedAmpersand)
                    index += 1
                }
                continue
            }
            if byte >= 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                output.append(byte)
            }
            // Other control characters are illegal in XML 1.0 and dropped.
            index += 1
        }
        return output
    }

    private enum EntityAction {
        case keep(length: Int)
        case replace([UInt8], length: Int)
        case escape
    }

    private static func hasTerminator(_ bytes: [UInt8], from index: Int) -> Bool {
        bytes[(index + 1)...].contains { !isEntityByte($0) }
    }

    /// Looks at `&...;` starting at `index`.
    private static func entity(in bytes: [UInt8], at index: Int) -> EntityAction {
        var i = index + 1
        while i < bytes.count, i - index <= maxEntityLength + 1 {
            let b = bytes[i]
            if b == UInt8(ascii: ";") {
                let name = String(decoding: bytes[(index + 1)..<i], as: UTF8.self)
                let length = i - index + 1
                if name.isEmpty { return .escape }
                if name.hasPrefix("#") {
                    return isValidCharacterReference(name) ? .keep(length: length) : .escape
                }
                if xmlEntities.contains(name) { return .keep(length: length) }
                if let code = htmlEntities[name] { return .replace(Array("&#\(code);".utf8), length: length) }
                return .escape
            }
            guard isEntityByte(b) else { return .escape }
            i += 1
        }
        return .escape
    }

    /// `#123` or `#x1F` naming a character that's legal in XML.
    private static func isValidCharacterReference(_ name: String) -> Bool {
        let body = name.dropFirst()
        let value: UInt32?
        if body.first == "x" || body.first == "X" {
            value = UInt32(body.dropFirst(), radix: 16)
        } else {
            value = UInt32(body)
        }
        guard let value else { return false }
        return value == 0x9 || value == 0xA || value == 0xD || (0x20...0xD7FF).contains(value)
            || (0xE000...0xFFFD).contains(value) || (0x10000...0x10FFFF).contains(value)
    }

    private static func isEntityByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == UInt8(ascii: "#")
    }
}
