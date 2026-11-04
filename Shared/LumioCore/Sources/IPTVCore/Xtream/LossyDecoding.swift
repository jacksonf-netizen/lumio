import Foundation

// Xtream panels are inconsistent: the same field can arrive as a number, a numeric string, an
// empty string, `null`, or be missing entirely; objects are sometimes `[]`. These helpers never
// throw for a type mismatch: they return nil (or a default) instead, so one odd field can't drop
// a whole catalog.

/// Decodes any JSON value and discards it. Used to skip elements we can't decode.
struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        if (try? container.decode(Bool.self)) != nil { return }
        if (try? container.decode(Double.self)) != nil { return }
        if (try? container.decode(String.self)) != nil { return }
        if (try? container.decode([AnyDecodable].self)) != nil { return }
        if (try? container.decode([String: AnyDecodable].self)) != nil { return }
    }
}

/// Decodes `T`, or nil if this element is malformed. Lets arrays skip bad elements.
struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension KeyedDecodingContainer {
    func lossyString(_ key: Key) -> String? {
        guard contains(key), (try? decodeNil(forKey: key)) == false else { return nil }
        if let string = try? decode(String.self, forKey: key) { return string }
        if let int = try? decode(Int.self, forKey: key) { return String(int) }
        if let double = try? decode(Double.self, forKey: key) {
            return double.rounded() == double && abs(double) < 1e15 ? String(Int(double)) : String(double)
        }
        if let bool = try? decode(Bool.self, forKey: key) { return bool ? "1" : "0" }
        return nil
    }

    /// Like `lossyString` but treats empty / whitespace-only / "null" as missing.
    func lossyNonEmptyString(_ key: Key) -> String? {
        guard let string = lossyString(key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty, string.lowercased() != "null"
        else { return nil }
        return string
    }

    func lossyInt(_ key: Key) -> Int? {
        guard contains(key), (try? decodeNil(forKey: key)) == false else { return nil }
        if let int = try? decode(Int.self, forKey: key) { return int }
        if let double = try? decode(Double.self, forKey: key), double.isFinite, abs(double) < 1e15 {
            return Int(double)
        }
        if let string = try? decode(String.self, forKey: key) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let int = Int(trimmed) { return int }
            if let double = Double(trimmed), double.isFinite, abs(double) < 1e15 { return Int(double) }
        }
        if let bool = try? decode(Bool.self, forKey: key) { return bool ? 1 : 0 }
        return nil
    }

    func lossyDouble(_ key: Key) -> Double? {
        guard contains(key), (try? decodeNil(forKey: key)) == false else { return nil }
        if let double = try? decode(Double.self, forKey: key) { return double.isFinite ? double : nil }
        if let string = try? decode(String.self, forKey: key),
           let double = Double(string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")),
           double.isFinite {
            return double
        }
        return nil
    }

    /// Accepts true/false, 1/0, "1"/"0", "true"/"false", "yes"/"no".
    func lossyBool(_ key: Key) -> Bool? {
        guard contains(key), (try? decodeNil(forKey: key)) == false else { return nil }
        if let bool = try? decode(Bool.self, forKey: key) { return bool }
        if let int = try? decode(Int.self, forKey: key) { return int != 0 }
        if let string = try? decode(String.self, forKey: key) {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off", "": return false
            default: return Int(string).map { $0 != 0 }
            }
        }
        return nil
    }

    /// Unix timestamp as number or string. Zero and negative values mean "unknown".
    func lossyUnixDate(_ key: Key) -> Date? {
        guard let seconds = lossyDouble(key), seconds > 0 else { return nil }
        // Some panels send milliseconds.
        let normalized = seconds > 100_000_000_000 ? seconds / 1000 : seconds
        return Date(timeIntervalSince1970: normalized)
    }

    func lossyURL(_ key: Key) -> URL? {
        guard let string = lossyNonEmptyString(key) else { return nil }
        if let url = URL(string: string), url.isWebURL { return url }
        // Spaces and other unescaped characters are common in logo URLs.
        if let escaped = string.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let url = URL(string: escaped), url.isWebURL {
            return url
        }
        return nil
    }

    /// Array of `T`, skipping malformed elements. Returns [] when the key is missing, null, or not an array.
    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        guard let items = try? decode([FailableDecodable<T>].self, forKey: key) else { return [] }
        return items.compactMap(\.value)
    }

    /// An object that panels sometimes send as `[]` or `""` when empty. Returns nil in those cases.
    func lossyObject<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        guard contains(key), (try? decodeNil(forKey: key)) == false else { return nil }
        return try? decode(T.self, forKey: key)
    }

    /// String array that may also arrive as a comma-separated string.
    func lossyStringArray(_ key: Key) -> [String] {
        if let array = try? decode([FailableDecodable<LossyScalar>].self, forKey: key) {
            return array.compactMap { $0.value?.string }.filter { !$0.isEmpty }
        }
        if let string = lossyNonEmptyString(key) {
            return string.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }
}

/// A scalar that may be a string, number or bool, normalised to a string.
struct LossyScalar: Decodable {
    let string: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self.string = string
        } else if let int = try? container.decode(Int.self) {
            string = String(int)
        } else if let double = try? container.decode(Double.self) {
            string = String(double)
        } else if let bool = try? container.decode(Bool.self) {
            string = bool ? "1" : "0"
        } else {
            throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath, debugDescription: "not a scalar"))
        }
    }
}

/// Coding key for arbitrary strings (dictionary-shaped JSON).
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = Int(string)
    }

    init?(stringValue: String) { self.init(stringValue) }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
