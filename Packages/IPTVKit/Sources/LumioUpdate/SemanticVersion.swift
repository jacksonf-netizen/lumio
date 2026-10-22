import Foundation

/// A version like "1.2.3", "v1.2" or "1.3.0-beta.2". Missing parts count as 0; a pre-release sorts
/// before the same version without one (1.3.0-beta.2 < 1.3.0).
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// The part after "-", if any (e.g. "beta.2").
    public let prerelease: String?

    public init?(_ text: String) {
        var string = text.trimmingCharacters(in: .whitespaces)
        if string.first == "v" || string.first == "V" { string.removeFirst() }
        // Build metadata ("+build.5") doesn't affect ordering.
        if let plus = string.firstIndex(of: "+") { string = String(string[..<plus]) }
        var prerelease: String?
        if let dash = string.firstIndex(of: "-") {
            prerelease = String(string[string.index(after: dash)...])
            string = String(string[..<dash])
        }
        let parts = string.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        major = parts[0]!
        minor = parts.count > 1 ? parts[1]! : 0
        patch = parts.count > 2 ? parts[2]! : 0
        self.prerelease = (prerelease?.isEmpty ?? true) ? nil : prerelease
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _): return false
        case (_, nil): return true
        case let (l?, r?): return Self.comparePrerelease(l, r)
        }
    }

    /// Dot-separated identifiers; numeric ones compare as numbers ("beta.10" > "beta.2").
    private static func comparePrerelease(_ lhs: String, _ rhs: String) -> Bool {
        let l = lhs.split(separator: "."), r = rhs.split(separator: ".")
        for (a, b) in zip(l, r) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a < b
            }
        }
        return l.count < r.count
    }
}
