import Foundation
import GRDB
import Testing
import zlib
@testable import IPTVCore

@Suite("XMLTV dates")
struct XMLTVDateTests {
    @Test(arguments: [
        ("20261017200000 +0000", "2026-10-17T20:00:00Z"),
        ("20261017200000 +0100", "2026-10-17T19:00:00Z"),
        ("20261017200000 -0530", "2026-10-18T01:30:00Z"),
        ("20261017200000", "2026-10-17T20:00:00Z"),
        ("202610172000 +0000", "2026-10-17T20:00:00Z"),
        ("20240229235959 +0000", "2024-02-29T23:59:59Z"),
        ("19991231230000 +0000", "1999-12-31T23:00:00Z"),
    ])
    func parses(input: String, iso: String) throws {
        let expected = try #require(ISO8601DateFormatter().date(from: iso))
        #expect(XMLTVDate.parse(input) == expected)
    }

    @Test(arguments: ["", "2026", "20261317200000 +0000", "20261017250000 +0000", "garbage"])
    func rejects(input: String) {
        #expect(XMLTVDate.parse(input) == nil)
    }

    @Test func readableEpisodeNumbers() {
        #expect(XMLTVDate.readableEpisode(fromXMLTVNS: "2.4.") == "S3 E5")
        #expect(XMLTVDate.readableEpisode(fromXMLTVNS: ".11.") == "E12")
        #expect(XMLTVDate.readableEpisode(fromXMLTVNS: "0/3.9/10.0/1") == "S1 E10")
    }
}

@Suite("XML sanitizer")
struct XMLSanitizerTests {
    func sanitize(_ text: String, chunk: Int) -> String {
        var sanitizer = XMLSanitizer()
        let bytes = Array(text.utf8)
        var output = Data()
        var index = 0
        while index < bytes.count {
            let end = min(index + chunk, bytes.count)
            output.append(sanitizer.process(bytes[index..<end]))
            index = end
        }
        output.append(sanitizer.finish())
        return String(decoding: output, as: UTF8.self)
    }

    @Test(arguments: [1, 2, 3, 5, 7, 64])
    func fixesBareAmpersandsAcrossAnyChunkBoundary(chunk: Int) {
        let input = "Tom & Jerry &amp; Cats &#233; &#x1F600; &hellip; &&; &bogus; &#1; end &"
        let expected = "Tom &amp; Jerry &amp; Cats &#233; &#x1F600; &#8230; &amp;&amp;; &amp;bogus; &amp;#1; end &amp;"
        #expect(sanitize(input, chunk: chunk) == expected)
    }

    @Test func dropsIllegalControlCharacters() {
        #expect(sanitize("a\u{01}b\u{0B}c\td\ne", chunk: 4) == "abc\td\ne")
    }
}

@Suite("XMLTV parsing and import")
struct EPGImportTests {
    let database: AppDatabase
    let provider: Provider
    let clock = ManualClock(.fixtureNow)

    init() throws {
        database = try AppDatabase.inMemory()
        provider = TestData.provider()
        try database.writer.write { [provider] db in
            try provider.insert(db)
            try Channel(providerID: provider.id, streamID: 1, name: "BBC One", epgChannelID: "bbcone.uk").insert(db)
            try Channel(providerID: provider.id, streamID: 2, name: "Sky Sports", epgChannelID: "skyspmainevhd.uk").insert(db)
            try Channel(providerID: provider.id, streamID: 3, name: "Tom", epgChannelID: "a.b").insert(db)
        }
    }

    var importer: EPGImporter { EPGImporter(database: database, clock: clock, batchSize: 2) }

    func titles() throws -> [String] {
        try database.reader.read { db in try String.fetchAll(db, sql: "SELECT title FROM programme ORDER BY start, title") }
    }

    @Test func parserExtractsChannelsAndProgrammes() throws {
        var channels: [XMLTVChannel] = []
        var programmes: [XMLTVProgramme] = []
        let result = XMLTVParser(onChannel: { channels.append($0) }, onProgramme: { programmes.append($0) })
            .parse(fileAt: Fixture.url("xmltv/guide.xml"))
        #expect(result.error == nil)
        #expect(result.skipped == 1)
        #expect(channels.first == XMLTVChannel(id: "BBCOne.uk", displayName: "BBC One", iconURL: URL(string: "http://logos.test/bbc1.png")))
        #expect(programmes.count == 5)
        let news = try #require(programmes.first)
        #expect(news.title == "News at Six") // first title wins
        #expect(news.summary == "Headlines & weather.")
        #expect(news.category == "News")
        let oneShow = programmes[1]
        #expect(oneShow.start == XMLTVDate.parse("20261017183000 +0000"))
        #expect(oneShow.episodeNumber == "S03E05") // onscreen preferred
        #expect(oneShow.subtitle == "Friday")
        #expect(oneShow.iconURL?.absoluteString == "http://img.test/one.jpg")
        #expect(programmes[2].episodeNumber == "E12")
    }

    @Test func importsReferencedChannelsWithinTheWindow() async throws {
        let summary = try await importer.importGuide(file: Fixture.temporaryCopy("xmltv/guide.xml"), providerID: provider.id)
        #expect(summary.partialError == nil)
        #expect(summary.programmesParsed == 5)
        #expect(summary.programmesStored == 3) // not last week's, not the unreferenced channel
        #expect(try titles() == ["News at Six", "The One Show", "Live Football"])
        // EPG ids are stored normalised.
        let ids = try await database.reader.read { db in try String.fetchAll(db, sql: "SELECT DISTINCT epgID FROM programme ORDER BY epgID") }
        #expect(ids == ["bbcone.uk", "skyspmainevhd.uk"])
        // All guide channels are kept for manual matching, even unreferenced ones.
        #expect(try EPGRepository(database: database).guideChannels(providerID: provider.id).count == 3)
    }

    @Test func gzippedGuidesImportTheSame() async throws {
        let summary = try await importer.importGuide(file: Fixture.gzipped("xmltv/guide.xml"), providerID: provider.id)
        #expect(summary.programmesStored == 3)
    }

    @Test func dirtyXMLIsRepairedOnTheWay() async throws {
        let summary = try await importer.importGuide(file: Fixture.temporaryCopy("xmltv/dirty.xml"), providerID: provider.id)
        #expect(summary.partialError == nil)
        #expect(try titles() == ["Tom & Jerry"])
        let summaryText = try await database.reader.read { db in try String.fetchOne(db, sql: "SELECT summary FROM programme") }
        #expect(summaryText == "Cats & mice é …")
    }

    @Test func truncatedFileKeepsWhatWasReadAndKeepsOldData() async throws {
        // First a good import with a programme that the broken file doesn't list.
        try await database.writer.write { [provider] db in
            var old = Programme(providerID: provider.id, epgID: "a.b", start: Date.fixtureNow.addingTimeInterval(7200),
                                stop: Date.fixtureNow.addingTimeInterval(9000), title: "Older import",
                                importedAt: Date.fixtureNow.addingTimeInterval(-3600))
            try old.insert(db)
        }
        let summary = try await importer.importGuide(file: Fixture.temporaryCopy("xmltv/truncated.xml"), providerID: provider.id)
        #expect(summary.partialError != nil)
        #expect(summary.programmesStored == 2)
        #expect(summary.removedStale == 0) // a partial import must not delete anything
        #expect(try titles().contains("Older import"))
    }

    @Test func reimportRemovesProgrammesNoLongerListed() async throws {
        try await database.writer.write { [provider] db in
            var stale = Programme(providerID: provider.id, epgID: "bbcone.uk", start: Date.fixtureNow.addingTimeInterval(3600),
                                  stop: Date.fixtureNow.addingTimeInterval(5400), title: "Cancelled show",
                                  importedAt: Date.fixtureNow.addingTimeInterval(-86_400))
            try stale.insert(db)
        }
        let summary = try await importer.importGuide(file: Fixture.temporaryCopy("xmltv/guide.xml"), providerID: provider.id)
        #expect(summary.removedStale == 1)
        #expect(!(try titles().contains("Cancelled show")))
    }

    @Test func reimportingAnUnchangedGuideKeepsSearchIndexConsistent() async throws {
        _ = try await importer.importGuide(file: Fixture.temporaryCopy("xmltv/guide.xml"), providerID: provider.id)
        clock.advance(60)
        _ = try await importer.importGuide(file: Fixture.temporaryCopy("xmltv/guide.xml"), providerID: provider.id)
        let hits = try await database.reader.read { db in
            try String.fetchAll(db, sql: """
                SELECT programme.title FROM programme JOIN programmeFTS ON programmeFTS.rowid = programme.id
                WHERE programmeFTS MATCH 'football'
                """)
        }
        #expect(hits == ["Live Football"])
        let integrity = try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO programmeFTS(programmeFTS, rank) VALUES ('integrity-check', 1)")
            return true
        }
        #expect(integrity)
    }

    @Test func providerTimeOffsetIsAppliedOnRead() async throws {
        _ = try await importer.importGuide(file: Fixture.temporaryCopy("xmltv/guide.xml"), providerID: provider.id)
        let repo = EPGRepository(database: database)
        let window = DateInterval(start: Date.fixtureNow.addingTimeInterval(-4 * 3600), duration: 6 * 3600)
        let plain = try repo.programmes(providerID: provider.id, epgIDs: ["BBCOne.uk"], in: window)["bbcone.uk"]!
        let shifted = try repo.programmes(providerID: provider.id, epgIDs: ["BBCOne.uk"], in: window, offsetMinutes: 60)["bbcone.uk"]!
        #expect(shifted.first!.start == plain.first!.start.addingTimeInterval(3600))

        let (now, next) = try repo.nowAndNext(providerID: provider.id, epgID: "skyspmainevhd.uk", at: Date.fixtureNow)
        #expect(now?.title == "Live Football")
        #expect(next == nil)
    }

    @Test func pruneRemovesProgrammesBeforeTheWindow() async throws {
        _ = try await importer.importGuide(file: Fixture.temporaryCopy("xmltv/guide.xml"), providerID: provider.id)
        clock.advance(3 * 86_400)
        #expect(try importer.prune() == 3)
    }

    @Test func importIsCancellable() async throws {
        let file = try SyntheticGuide.write(channels: 50, programmesPerChannel: 2_000)
        defer { try? FileManager.default.removeItem(at: file) }
        let importer = self.importer
        let pid = provider.id
        let task = Task { try await importer.importGuide(file: file, providerID: pid) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite("EPG import at scale", .serialized)
struct EPGScaleTests {
    /// Synthetic guide: default ~60 MB uncompressed. Set IPTV_PERF_PROGRAMMES for bigger runs,
    /// e.g. 700000 for a ~200 MB guide.
    @Test func largeGuideImportsWithFlatMemory() async throws {
        let total = Int(ProcessInfo.processInfo.environment["IPTV_PERF_PROGRAMMES"] ?? "") ?? 200_000
        let channels = 500
        let file = try SyntheticGuide.write(channels: channels, programmesPerChannel: total / channels, gzip: true)
        defer { try? FileManager.default.removeItem(at: file) }

        // On disk, so database pages don't count as importer memory.
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("scale-\(UUID().uuidString)/iptv.sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        let database = try AppDatabase.open(at: dbURL)
        let provider = TestData.provider()
        try await database.writer.write { db in
            try provider.insert(db)
            for n in 0..<channels {
                try Channel(providerID: provider.id, streamID: n, name: "Channel \(n)", epgChannelID: "ch\(n).test").insert(db)
            }
        }

        let before = MemoryUsage.residentBytes()
        let peak = PeakMemorySampler()
        peak.start()
        let started = ContinuousClock.now
        let summary = try await EPGImporter(database: database, clock: ManualClock(SyntheticGuide.start.addingTimeInterval(86_400)))
            .importGuide(file: file, providerID: provider.id, window: EPGWindow(pastDays: 30, futureDays: 30))
        let elapsed = ContinuousClock.now - started
        peak.stop()

        #expect(summary.programmesStored == total)
        // Streaming keeps this roughly constant regardless of guide size (SQLite page cache + one batch).
        let growthMB = Double(Int64(peak.peak) - Int64(before)) / 1_048_576
        print("EPG scale: \(total) programmes in \(elapsed); peak RSS growth \(Int(growthMB)) MB")
        #expect(growthMB < 150)
    }
}

enum SyntheticGuide {
    static let start = XMLTVDate.parse("20261017000000 +0000")!

    static func write(channels: Int, programmesPerChannel: Int, gzip: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic-\(UUID().uuidString).xml\(gzip ? ".gz" : "")")
        let gz = gzip ? gzopen(url.path, "wb1") : nil
        let handle: FileHandle? = gzip ? nil : {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            return try? FileHandle(forWritingTo: url)
        }()
        func write(_ text: String) {
            var data = Data(text.utf8)
            if let gz {
                _ = data.withUnsafeMutableBytes { gzwrite(gz, $0.baseAddress, UInt32($0.count)) }
            } else {
                handle?.write(data)
            }
        }
        write("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tv>\n")
        for c in 0..<channels { write("<channel id=\"ch\(c).test\"><display-name>Channel \(c)</display-name></channel>\n") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        var chunk = ""
        for p in 0..<programmesPerChannel {
            let s = formatter.string(from: start.addingTimeInterval(Double(p) * 1800))
            let e = formatter.string(from: start.addingTimeInterval(Double(p + 1) * 1800))
            for c in 0..<channels {
                chunk += "<programme start=\"\(s) +0000\" stop=\"\(e) +0000\" channel=\"ch\(c).test\"><title>Show \(p) on \(c)</title><desc>Synthetic programme description text for load testing, episode \(p).</desc><category>Test</category></programme>\n"
            }
            if chunk.utf8.count > 1 << 20 {
                write(chunk)
                chunk = ""
            }
        }
        write(chunk)
        write("</tv>\n")
        if let gz { gzclose(gz) }
        try handle?.close()
        return url
    }
}

enum MemoryUsage {
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}

final class PeakMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var peakValue: UInt64 = 0

    var peak: UInt64 { lock.withLock { peakValue } }

    func start() {
        lock.withLock { running = true }
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let now = MemoryUsage.residentBytes()
                lock.withLock { peakValue = max(peakValue, now) }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    func stop() { lock.withLock { running = false } }
}
