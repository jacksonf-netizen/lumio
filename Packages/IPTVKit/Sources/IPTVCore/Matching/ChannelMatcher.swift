import Foundation

/// Groups channels from different providers that are "the same channel" into logical channels.
///
/// Rules, in order:
/// 1. Channels with the same EPG id belong together (`epg:<id>`).
/// 2. Channels without an EPG id join a group whose normalised name matches, or form a name group
///    (`name:<normalised>`).
/// 3. A logical channel never holds two channels from the same provider. When a provider has
///    several channels sharing a key (e.g. "BBC One HD" and "BBC One SD" with one EPG id), they are
///    split by quality (`…|hd`, `…|sd`) and then by position.
/// 4. Manual overrides win: `unlink` makes a channel stand alone; `link` forces it into a target.
///
/// The function is pure and deterministic: same input, same output, regardless of input order.
public enum ChannelMatcher {
    public struct Input: Sendable {
        public var channel: Channel
        /// Provider priority (lower = preferred); decides whose name and logo a group shows.
        public var providerPriority: Int

        public init(channel: Channel, providerPriority: Int) {
            self.channel = channel
            self.providerPriority = providerPriority
        }
    }

    public struct Output: Sendable, Equatable {
        public var logicalChannels: [LogicalChannel]
        public var members: [LogicalChannelMember]
    }

    public static func match(_ inputs: [Input], overrides: [ChannelLinkOverride] = []) -> Output {
        // Stable order: preferred providers first, then provider order, then stream id.
        let sorted = inputs.sorted {
            ($0.providerPriority, $0.channel.providerID.rawValue, $0.channel.sortIndex, $0.channel.streamID)
                < ($1.providerPriority, $1.channel.providerID.rawValue, $1.channel.sortIndex, $1.channel.streamID)
        }
        let overrideByChannel = Dictionary(
            overrides.map { (SourceKey($0.providerID, $0.streamID), $0) }, uniquingKeysWith: { _, last in last })

        var groups: [String: Group] = [:]
        var order: [String] = []
        func group(_ id: String) -> Group? { groups[id] }
        func add(_ input: Input, to id: String) {
            if groups[id] == nil {
                groups[id] = Group(id: id)
                order.append(id)
            }
            groups[id]!.members.append(input)
        }

        // Name key → group ids created from EPG ids, so EPG-less channels can join them.
        var nameIndex: [String: [String]] = [:]
        // Base key → the base group and its variants, in creation order.
        var families: [String: [String]] = [:]
        var deferredByName: [Input] = []

        // Pass 1: overrides and EPG-keyed channels.
        for input in sorted {
            let source = SourceKey(input.channel.providerID, input.channel.streamID)
            if let override = overrideByChannel[source] {
                switch override.action {
                case .unlink:
                    add(input, to: "solo:\(input.channel.providerID.rawValue):\(input.channel.streamID)")
                case .link:
                    if let target = override.targetLogicalChannelID, !target.isEmpty {
                        add(input, to: target)
                    } else {
                        add(input, to: "solo:\(input.channel.providerID.rawValue):\(input.channel.streamID)")
                    }
                }
                continue
            }
            guard let epg = input.channel.epgChannelID.map(EPGKey.normalize), !epg.isEmpty else {
                deferredByName.append(input)
                continue
            }
            let base = "epg:\(epg)"
            let id = slot(for: input, base: base, groups: groups, families: &families)
            add(input, to: id)
            let name = normalizedName(input.channel.name)
            if !name.isEmpty, !(nameIndex[name]?.contains(id) ?? false) {
                nameIndex[name, default: []].append(id)
            }
        }

        // Pass 2: channels without an EPG id.
        for input in deferredByName {
            let name = normalizedName(input.channel.name)
            guard !name.isEmpty else {
                add(input, to: "solo:\(input.channel.providerID.rawValue):\(input.channel.streamID)")
                continue
            }
            let quality = qualityTag(input.channel.name)
            // Prefer an existing group with the same name that this provider isn't in yet,
            // matching quality when there is a choice.
            let candidates = (nameIndex[name] ?? []) + (families["name:\(name)"] ?? [])
            let joinable = candidates.filter { id in
                guard let g = group(id) else { return false }
                return !g.contains(provider: input.channel.providerID)
            }
            if let id = joinable.first(where: { groups[$0]?.quality == quality }) ?? joinable.first {
                add(input, to: id)
            } else {
                let id = slot(for: input, base: "name:\(name)", groups: groups, families: &families)
                add(input, to: id)
                nameIndex[name, default: []].append(id)
            }
        }

        var logical: [LogicalChannel] = []
        var members: [LogicalChannelMember] = []
        for id in order {
            guard let g = groups[id], let lead = g.members.first else { continue }
            logical.append(LogicalChannel(
                id: id,
                name: displayName(lead.channel.name),
                logoURL: g.members.lazy.compactMap(\.channel.logoURL).first))
            for member in g.members {
                members.append(LogicalChannelMember(logicalChannelID: id, providerID: member.channel.providerID,
                                                    streamID: member.channel.streamID))
            }
        }
        return Output(logicalChannels: logical, members: members)
    }

    /// Picks the group for `input` among `base` and its variants ("base|hd", "base#2"…):
    /// a group this provider isn't in yet, preferring one with the same quality tag.
    private static func slot(for input: Input, base: String, groups: [String: Group],
                             families: inout [String: [String]]) -> String {
        let provider = input.channel.providerID
        let quality = qualityTag(input.channel.name)
        let family = families[base] ?? []
        let free = family.filter { !(groups[$0]?.contains(provider: provider) ?? false) }

        func compatible(_ id: String) -> Bool {
            let other = groups[id]?.quality ?? ""
            return other == quality || other.isEmpty || quality.isEmpty
        }
        if let exact = free.first(where: { groups[$0]?.quality == quality }) { return exact }
        if let loose = free.first(where: compatible) { return loose }

        var id = family.isEmpty ? base : (quality.isEmpty ? base : "\(base)|\(quality)")
        var n = 2
        while family.contains(id) {
            id = "\(base)#\(n)"
            n += 1
        }
        families[base, default: []].append(id)
        return id
    }

    struct Group {
        let id: String
        var members: [Input] = []

        func contains(provider: ProviderID) -> Bool {
            members.contains { $0.channel.providerID == provider }
        }

        var quality: String { members.first.map { qualityTag($0.channel.name) } ?? "" }
    }

    struct SourceKey: Hashable {
        let providerID: ProviderID
        let streamID: Int
        init(_ providerID: ProviderID, _ streamID: Int) {
            self.providerID = providerID
            self.streamID = streamID
        }
    }

    // MARK: Name normalisation

    private static let qualityTokens: [String: String] = [
        "4k": "uhd", "uhd": "uhd", "2160p": "uhd", "ᵁᴴᴰ": "uhd",
        "fhd": "fhd", "1080p": "fhd", "1080i": "fhd", "ᶠᴴᴰ": "fhd",
        "hd": "hd", "720p": "hd", "ᴴᴰ": "hd", "ʰᵈ": "hd",
        "sd": "sd", "576p": "sd", "480p": "sd",
    ]
    private static let noiseTokens: Set<String> = [
        "hevc", "h265", "h264", "x265", "x264", "50fps", "60fps", "25fps", "fps", "raw", "vip", "backup",
        "multi", "multisub", "live", "tv", "channel", "hdr", "dolby", "ac3", "eac3",
    ]

    /// Lowercased, quality/noise tags and country prefixes removed, punctuation stripped.
    /// Keeps "+1" style timeshift markers so "ITV +1" never merges with "ITV".
    public static func normalizedName(_ name: String) -> String {
        var text = stripCountryPrefix(name)
        // Bracketed tags: "[VIP]", "(Backup)", "{UK}".
        text = text.replacing(/[\[\(\{][^\]\)\}]*[\]\)\}]/, with: " ")
        text = text.replacingOccurrences(of: "+", with: " plus")
        text = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        text = text.lowercased()
        let tokens = text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { qualityTokens[$0] == nil && !noiseTokens.contains($0) }
        // Glue "plus" to the following number: "plus 1" → "plus1".
        var result: [String] = []
        for token in tokens {
            if let last = result.last, last == "plus", token.allSatisfy(\.isNumber) {
                result[result.count - 1] = "plus\(token)"
            } else {
                result.append(token)
            }
        }
        return result.joined(separator: " ")
    }

    /// "uhd", "fhd", "hd", "sd" or "" (unknown).
    public static func qualityTag(_ name: String) -> String {
        let lowered = name.lowercased()
        let tokens = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for preferred in ["uhd", "fhd", "hd", "sd"] {
            if tokens.contains(where: { qualityTokens[$0] == preferred }) { return preferred }
        }
        for (token, quality) in qualityTokens where token.unicodeScalars.contains(where: { !$0.isASCII }) {
            if name.contains(token) { return quality }
        }
        return ""
    }

    /// A tidy display name: country prefix removed, original casing kept.
    static func displayName(_ name: String) -> String {
        let stripped = stripCountryPrefix(name).trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? name : stripped
    }

    /// 3–4 letter region prefixes seen in IPTV channel names. Any 2-letter code is also accepted.
    private static let longRegionPrefixes: Set<String> = [
        "USA", "CAN", "GER", "DEU", "FRA", "ITA", "ESP", "NED", "NLD", "POR", "POL", "TUR", "IND", "PAK",
        "AUS", "IRL", "SWE", "NOR", "DEN", "FIN", "GRE", "ROM", "BUL", "HUN", "CZE", "SRB", "CRO", "SUI",
        "AUT", "RUS", "UKR", "BRA", "MEX", "LAT", "ARA", "ARB", "AFR", "EXYU", "ASIA", "CARI",
    ]

    /// Removes "UK:", "UK |", "US - ", "|UK|", "[UK] ", "UK► ", "USA: " style region prefixes.
    /// Broadcaster names such as "BBC: One" are left alone.
    static func stripCountryPrefix(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.prefixMatch(of: /^[\[\(\|]?\s*([A-Z]{2,4})\s*[\]\)\|:\-►»]+\s*/) else { return trimmed }
        let code = String(match.output.1)
        guard code.count == 2 || longRegionPrefixes.contains(code) else { return trimmed }
        let rest = trimmed[match.range.upperBound...]
        return rest.isEmpty ? trimmed : String(rest)
    }
}
