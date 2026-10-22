import Foundation
import Testing
@testable import IPTVCore

@Suite("Channel matching across providers")
struct ChannelMatcherTests {
    let a = ProviderID("a")
    let b = ProviderID("b")
    let c = ProviderID("c")

    func input(_ provider: ProviderID, _ id: Int, _ name: String, epg: String? = nil, priority: Int? = nil) -> ChannelMatcher.Input {
        let p = priority ?? (provider == a ? 0 : provider == b ? 1 : 2)
        return ChannelMatcher.Input(channel: Channel(providerID: provider, streamID: id, name: name, epgChannelID: epg,
                                                     sortIndex: id), providerPriority: p)
    }

    func groups(_ output: ChannelMatcher.Output) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for m in output.members { result[m.logicalChannelID, default: []].insert("\(m.providerID.rawValue):\(m.streamID)") }
        return result
    }

    @Test(arguments: [
        ("UK: BBC One HD", "bbc one"),
        ("UK | BBC One FHD", "bbc one"),
        ("[UK] BBC ONE ᴴᴰ", "bbc one"),
        ("US - ESPN 2 (Backup)", "espn 2"),
        ("Télé Café 1080p HEVC", "tele cafe"),
        ("ITV +1", "itv plus1"),
        ("ITV+1 HD", "itv plus1"),
        ("Sky Sports Main Event 4K", "sky sports main event"),
        ("BBC: One", "bbc one"),
        ("USA: CNN", "cnn"),
    ])
    func normalisesNames(name: String, expected: String) {
        #expect(ChannelMatcher.normalizedName(name) == expected)
    }

    @Test func timeshiftChannelsStaySeparate() {
        #expect(ChannelMatcher.normalizedName("ITV") != ChannelMatcher.normalizedName("ITV +1"))
    }

    @Test(arguments: [("BBC One HD", "hd"), ("BBC One FHD", "fhd"), ("BBC 4K", "uhd"), ("BBC One", ""), ("BBC ᴴᴰ", "hd")])
    func detectsQuality(name: String, expected: String) {
        #expect(ChannelMatcher.qualityTag(name) == expected)
    }

    @Test func groupsByEPGIDAcrossProviders() {
        let output = ChannelMatcher.match([
            input(a, 1, "UK: BBC One HD", epg: "BBCOne.uk"),
            input(b, 9, "BBC 1", epg: "bbcone.uk"),
        ])
        #expect(groups(output) == ["epg:bbcone.uk": ["a:1", "b:9"]])
        #expect(output.logicalChannels.first?.name == "BBC One HD") // from the preferred provider, prefix stripped
    }

    @Test func fallsBackToNameWhenEPGIDIsMissing() {
        let output = ChannelMatcher.match([
            input(a, 1, "UK: Sky News HD", epg: "skynews.uk"),
            input(b, 2, "Sky News"),
            input(c, 3, "SKY NEWS FHD"),
        ])
        #expect(groups(output) == ["epg:skynews.uk": ["a:1", "b:2", "c:3"]])
    }

    @Test func nameOnlyChannelsGroupTogether() {
        let output = ChannelMatcher.match([input(a, 1, "Local TV"), input(b, 2, "LOCAL TV HD")])
        #expect(groups(output) == ["name:local": ["a:1", "b:2"]])
    }

    @Test func oneProviderNeverAppearsTwiceInAGroupAndQualitiesLineUp() {
        let output = ChannelMatcher.match([
            input(a, 1, "BBC One HD", epg: "bbcone.uk"),
            input(a, 2, "BBC One SD", epg: "bbcone.uk"),
            input(b, 3, "BBC One SD", epg: "bbcone.uk"),
            input(b, 4, "BBC One HD", epg: "bbcone.uk"),
        ])
        let g = groups(output)
        #expect(g.count == 2)
        #expect(g.values.contains(["a:1", "b:4"])) // HD with HD
        #expect(g.values.contains(["a:2", "b:3"])) // SD with SD
        for members in g.values {
            let providers = members.map { $0.split(separator: ":")[0] }
            #expect(Set(providers).count == providers.count)
        }
    }

    @Test func unlinkAndLinkOverridesWin() {
        let output = ChannelMatcher.match([
            input(a, 1, "BBC One", epg: "bbcone.uk"),
            input(b, 2, "BBC One", epg: "bbcone.uk"),
            input(c, 3, "Some Other Name"),
        ], overrides: [
            ChannelLinkOverride(providerID: b, streamID: 2, action: .unlink),
            ChannelLinkOverride(providerID: c, streamID: 3, action: .link, targetLogicalChannelID: "epg:bbcone.uk"),
        ])
        let g = groups(output)
        #expect(g["epg:bbcone.uk"] == ["a:1", "c:3"])
        #expect(g["solo:b:2"] == ["b:2"])
    }

    @Test func resultIsIndependentOfInputOrder() {
        let inputs = [
            input(a, 1, "BBC One HD", epg: "bbcone.uk"), input(a, 2, "BBC One SD", epg: "bbcone.uk"),
            input(b, 3, "BBC One"), input(b, 4, "ITV"), input(c, 5, "ITV HD"), input(c, 6, "ITV +1"),
            input(a, 7, "Channel 4", epg: "c4.uk"), input(b, 8, "Channel 4 HD", epg: "C4.uk"),
        ]
        let expected = ChannelMatcher.match(inputs)
        for _ in 0..<20 {
            #expect(ChannelMatcher.match(inputs.shuffled()) == expected)
        }
    }

    @Test func everyChannelIsInExactlyOneGroup() {
        let inputs = (0..<300).map { i in
            input([a, b, c][i % 3], i, "Channel \(i % 40) \(["HD", "SD", "", "FHD"][i % 4])", epg: i % 2 == 0 ? "ch\(i % 40)" : nil)
        }
        let output = ChannelMatcher.match(inputs)
        #expect(output.members.count == inputs.count)
        #expect(Set(output.members.map { "\($0.providerID.rawValue):\($0.streamID)" }).count == inputs.count)
        #expect(Set(output.logicalChannels.map(\.id)).count == output.logicalChannels.count)
    }
}
