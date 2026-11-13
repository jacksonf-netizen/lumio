import Foundation
import Testing
@testable import IPTVCore

/// Channel names are cleaned up by hand-written scans instead of Regex (which took minutes over a
/// big provider on a TV box). They must give what the Regex gave.
@Suite("Cleaning up names without Regex")
struct NameScanTests {
    static let names: [String] = {
        var names = [
            "UK: BBC One HD", "UK | Sky Sports", "US - ESPN", "|UK| ITV", "[UK] Channel 4", "UK► Dave", "USA: FOX",
            "BBC: One", "EXYU: RTS", "ABCDE: Long", "UKa: no", "  UK :  spaced", "(DE) ZDF", "[UK]", "UK:", "UK::|-  X",
            "US| SPORTS NETWORK", "BEE| DAZN CUP FHD EN", "AR| BEIN SPORTS ᵁᴴᴰ 4K", "Sky (Backup) [VIP] {UK} HD",
            "Open (bracket only", "Close) only", "Nested [a (b] c)", "[(x)]", "Mixed (a] b", "ESPN HD", "", " ",
            "ÉCOLE: Ça va", "FR » Canal+", "TR-TRT 1", "PT- RTP", "ESPN 2 HD", "(2026) Film [4K]", "a[b]c(d)e{f}g",
            "US|ESPN", "U: short", "Ü: umlaut", "IND : Star", "XXXX-YYYY", "[ US ] - CNN",
        ]
        let parts = ["UK", "US", "USA", "BEE", "AR", "fr", "", "[", "(", "|", ":", " ", "-", "►", "]", ")", "}", "{",
                     "ESPN", "HD", "ᴴᴰ", "+1", "(Backup)", "é"]
        var random = Seeded()
        for _ in 0..<400 {
            var name = ""
            for _ in 0..<Int.random(in: 1...6, using: &random) { name += parts[Int.random(in: 0..<parts.count, using: &random)] }
            names.append(name)
        }
        return names
    }()

    /// The same names every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64 = 7
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    // The Regex versions these replaced.
    static func oldStrip(_ name: String) -> String {
        let longPrefixes: Set<String> = ["USA", "EXYU", "IND"]
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.prefixMatch(of: /^[\[\(\|]?\s*([A-Z]{2,4})\s*[\]\)\|:\-►»]+\s*/) else { return trimmed }
        let code = String(match.output.1)
        guard code.count == 2 || longPrefixes.contains(code) else { return trimmed }
        let rest = trimmed[match.range.upperBound...]
        return rest.isEmpty ? trimmed : String(rest)
    }

    @Test func bracketsAreRemovedAsBefore() {
        for name in Self.names {
            #expect(ChannelMatcher.removingBracketed(name) == name.replacing(/[\[\(\{][^\]\)\}]*[\]\)\}]/, with: " "), "\(name)")
        }
    }

    @Test func countryPrefixesAreStrippedAsBefore() {
        // The names only use long prefixes that both lists have (USA, EXYU, IND).
        for name in Self.names {
            #expect(ChannelMatcher.stripCountryPrefix(name) == Self.oldStrip(name), "\(name)")
        }
    }
}
