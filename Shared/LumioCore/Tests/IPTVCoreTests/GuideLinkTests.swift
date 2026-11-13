import Foundation
import GRDB
import Testing
@testable import IPTVCore

/// Guide links: extra XMLTV files the user adds to a provider, for the channels its own guide
/// leaves out.
@Suite("Guide links")
struct GuideLinkTests {
    let database: AppDatabase
    let provider: Provider
    let clock = ManualClock(.fixtureNow)

    init() throws {
        database = try AppDatabase.inMemory()
        provider = TestData.provider()
        try database.writer.write { [provider] db in
            try provider.insert(db)
            try Channel(providerID: provider.id, streamID: 1, name: "BBC One", epgChannelID: "bbcone.uk").insert(db)
            try Channel(providerID: provider.id, streamID: 2, name: "US: ESPN HD", epgChannelID: "espn.provider").insert(db)
            try Channel(providerID: provider.id, streamID: 3, name: "Sky Sports", epgChannelID: "SkySports.uk").insert(db)
            try Channel(providerID: provider.id, streamID: 4, name: "FOX", epgChannelID: "fox.a").insert(db)
            try Channel(providerID: provider.id, streamID: 5, name: "ESPN 2", epgChannelID: "espn2.provider").insert(db)
        }
    }

    var importer: EPGImporter { EPGImporter(database: database, clock: clock, batchSize: 2) }

    /// An XMLTV file with `channels` (id, name) and one programme each at fixtureNow (title "<id> show").
    static func guide(_ channels: [(String, String)], title: (String) -> String = { "\($0) show" }) throws -> URL {
        func time(_ offset: TimeInterval) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMddHHmmss"
            return formatter.string(from: Date.fixtureNow.addingTimeInterval(offset)) + " +0000"
        }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tv>\n"
        for (id, name) in channels { xml += "<channel id=\"\(id)\"><display-name>\(name)</display-name></channel>\n" }
        for (id, _) in channels {
            xml += "<programme start=\"\(time(-1800))\" stop=\"\(time(1800))\" channel=\"\(id)\"><title>\(title(id))</title></programme>\n"
        }
        xml += "</tv>\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(UUID().uuidString).xml")
        try Data(xml.utf8).write(to: url)
        return url
    }

    func rows() throws -> [String: (title: String, source: Int)] {
        try database.reader.read { db in
            var result: [String: (String, Int)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT epgID, title, source FROM programme") {
                result[row["epgID"]] = (row["title"], row["source"])
            }
            return result
        }
    }

    /// The provider's own guide: BBC One only.
    func importOwnGuide() async throws {
        _ = try await importer.importGuide(file: Self.guide([("bbcone.uk", "BBC One")], title: { _ in "Own news" }),
                                           providerID: provider.id)
    }

    static let link: [(String, String)] = [
        ("bbcone.uk", "BBC One"),            // the provider's own guide has it: left alone
        ("ESPN.us", "ESPN"),                 // name and region
        ("skysports.uk", "Sky Sports HD"),   // same guide ID
        ("fox.boston", "FOX (Boston)"),      // two "fox": left out
        ("fox.denver", "FOX (Denver)"),
        ("cnn.us", "CNN"),                   // the provider has no CNN
    ]

    @Test func fillsWhatTheOwnGuideLeavesOutAndNothingElse() async throws {
        try await importOwnGuide()
        let summary = try await importer.importGuideLinks(files: [try Self.guide(Self.link)], providerID: provider.id, complete: true)
        #expect(summary.matchedChannels == 2)
        let stored = try rows()
        #expect(stored["bbcone.uk"]?.title == "Own news")
        #expect(stored["bbcone.uk"]?.source == 0)
        #expect(stored["espn.provider"]?.title == "ESPN.us show")
        #expect(stored["espn.provider"]?.source == 1)
        #expect(stored["skysports.uk"]?.title == "skysports.uk show")
        #expect(stored["fox.a"] == nil)
        #expect(stored["espn2.provider"] == nil) // "espn 2" isn't "espn"
    }

    @Test func theOwnGuideImportKeepsTheLinksProgrammes() async throws {
        _ = try await importer.importGuideLinks(files: [try Self.guide(Self.link)], providerID: provider.id, complete: true)
        clock.advance(3600)
        try await importOwnGuide()
        let stored = try rows()
        #expect(stored["espn.provider"]?.source == 1)
        #expect(stored["bbcone.uk"]?.title == "Own news")
    }

    @Test func aChannelTheOwnGuideCoversAgainIsItsOwn() async throws {
        // Before the own guide has anything, the link fills BBC One by ID.
        _ = try await importer.importGuideLinks(files: [try Self.guide(Self.link)], providerID: provider.id, complete: true)
        #expect(try rows()["bbcone.uk"]?.source == 1)
        clock.advance(3600)
        try await importOwnGuide()
        _ = try await importer.importGuideLinks(files: [try Self.guide(Self.link)], providerID: provider.id, complete: true)
        #expect(try rows()["bbcone.uk"]?.title == "Own news")
        #expect(try rows()["bbcone.uk"]?.source == 0)
    }

    @Test func onlyACompleteLinkImportRemovesOldRows() async throws {
        _ = try await importer.importGuideLinks(files: [try Self.guide(Self.link)], providerID: provider.id, complete: true)
        clock.advance(3600)
        let withoutESPN = Self.link.filter { $0.0 != "ESPN.us" }
        // A link failed to download: ESPN stays.
        _ = try await importer.importGuideLinks(files: [try Self.guide(withoutESPN)], providerID: provider.id, complete: false)
        #expect(try rows()["espn.provider"] != nil)
        // Every link read: ESPN is gone from them.
        _ = try await importer.importGuideLinks(files: [try Self.guide(withoutESPN)], providerID: provider.id, complete: true)
        #expect(try rows()["espn.provider"] == nil)
    }

    @Test func theProvidersTimeOffsetDoesntShiftTheLinks() async throws {
        try await importOwnGuide()
        _ = try await importer.importGuideLinks(files: [try Self.guide(Self.link)], providerID: provider.id, complete: true)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE provider SET epgTimeOffsetMinutes = 60 WHERE id = ?", arguments: [provider.id])
        }
        let espn = EPGRef(epgID: "espn.provider", providers: [provider.id])
        let bbc = EPGRef(epgID: "bbcone.uk", providers: [provider.id])
        let window = DateInterval(start: Date.fixtureNow.addingTimeInterval(-6 * 3600), duration: 12 * 3600)
        let found = try await GuideRepository(database: database).programmes(for: [espn, bbc], in: window)
        #expect(found[espn]?.first?.start == Date.fixtureNow.addingTimeInterval(-1800))
        #expect(found[bbc]?.first?.start == Date.fixtureNow.addingTimeInterval(-1800 + 3600))

        let repo = EPGRepository(database: database)
        let link = try repo.programmes(providerID: provider.id, epgIDs: ["espn.provider"], in: window, offsetMinutes: 60)
        #expect(link["espn.provider"]?.first?.start == Date.fixtureNow.addingTimeInterval(-1800))
    }

    @Test func linksAreKeptBesideTheLoginAndShownWithoutTheirQuery() throws {
        let secrets = InMemorySecretStore()
        try secrets.save(ProviderCredentials(username: "u", password: "p"), for: provider.id)
        let store = GuideLinkStore(secrets: secrets)
        #expect(try store.links(for: provider.id).isEmpty)
        let link = try #require(GuideLinkStore.parse("epg.example.com/guide.xml.gz?token=secret123"))
        #expect(link.absoluteString == "http://epg.example.com/guide.xml.gz?token=secret123")
        try store.setLinks([link], for: provider.id)
        #expect(try store.links(for: provider.id) == [link])
        #expect(try secrets.load(for: provider.id) == ProviderCredentials(username: "u", password: "p"))
        #expect(GuideLinkStore.display(link) == "epg.example.com/guide.xml.gz")
        #expect(GuideLinkStore.parse("not a link") == nil)
        try store.setLinks([], for: provider.id)
        #expect(try store.links(for: provider.id).isEmpty)
    }

    @Test func failedLinksAreANoteAndHideTheirToken() throws {
        let link = URL(string: "http://epg.example.com/g.xml?username=me&password=secret123")!
        let text = CatalogSyncService.hideLink(link, in: "Could not connect to \(link.absoluteString) (secret123)")
        #expect(!text.contains("secret123"))
        #expect(text.contains("epg.example.com/g.xml"))
        let problems = RefreshProblems(lastError: "guideLinks: epg.example.com/g.xml: not found")
        #expect(problems.guideLinks == "epg.example.com/g.xml: not found")
        #expect(problems.guide == nil)
        #expect(problems.serious == nil)
    }
}
