import Foundation
import Testing
@testable import IPTVCore

/// Values that don't fit a 32-bit `Int`. Android TV boxes such as the onn 4K Pro run apps as
/// 32-bit (armv7), where these used to crash or break; on a 64-bit Mac they always passed. Run them
/// on such a box with `AndroidTV/Tools/run_core_tests.sh armv7`.
@Suite("Numbers too big for 32 bits")
struct ThirtyTwoBitTests {
    @Test func theGuideSizeLimitIsPositive() {
        #expect(XtreamClient.maxGuideDownloadBytes == 2 << 30)
        #expect(XtreamClient.maxGuideDownloadBytes > 0)
    }

    @Test func guideDatesFarFromNowParse() throws {
        let late = try #require(XMLTVDate.parse("20991231235959 +0000"))
        #expect(late.timeIntervalSince1970 == 4_102_444_799)
        let early = try #require(XMLTVDate.parse("19000101000000 +0000"))
        #expect(early.timeIntervalSince1970 == -2_208_988_800)
        #expect(XMLTVDate.parse("00010101000000 +0000") != nil)
    }

    @Test func episodeNumbersAtTheLimitDontCrash() {
        _ = XMLTVDate.readableEpisode(fromXMLTVNS: "\(Int.max).\(Int.max).")
    }

    @Test func hugeNumbersInAProviderListDontStopTheRest() async throws {
        let transport = StubTransport()
        transport.set("get_live_streams", body: """
            [{"num": 1, "name": "Normal", "stream_id": 101, "epg_channel_id": "normal.uk"},
             {"num": 3000000000, "name": "Huge number", "stream_id": 102, "added": 99999999999},
             {"num": "202401151830", "name": "Huge text number", "stream_id": "103"},
             {"num": 4, "name": "Huge id", "stream_id": 3000000000}]
            """)
        let source = XtreamSourceProvider(provider: TestData.provider(),
                                          credentials: ProviderCredentials(username: "u", password: "p"),
                                          transport: transport)
        let names = try await source.fetchChannels().map(\.name)
        #expect(names.contains("Normal"))
        #expect(names.contains("Huge number"))
        #expect(names.contains("Huge text number"))
    }

    @Test func aWholeNumberTooBigForIntBecomesText() throws {
        struct Item: Decodable {
            let value: String?
            enum CodingKeys: String, CodingKey { case value }
            init(from decoder: Decoder) throws {
                value = try decoder.container(keyedBy: CodingKeys.self).lossyString(.value)
            }
        }
        let item = try JSONDecoder().decode(Item.self, from: Data(#"{"value": 3000000000}"#.utf8))
        #expect(item.value == "3000000000")
    }
}
