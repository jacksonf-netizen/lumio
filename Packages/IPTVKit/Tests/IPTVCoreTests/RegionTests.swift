import Foundation
import GRDB
import Testing
@testable import IPTVCore

@Suite("Regions")
struct RegionTests {
    @Test(arguments: [
        ("UK | Sports", "UK"), ("UK: Entertainment", "UK"), ("US - News", "US"), ("[FR] Cinéma", "FR"), ("|DE| Filme", "DE"),
        ("(IT) Sport", "IT"), ("EX-YU ▎ Sport", "EX-YU"), ("Canada | News", "CA"), ("USA Entertainment", "US"),
        ("GB| Kids", "UK"), ("AR | MBC", "AR"), ("ARABIC: Movies", "AR"), ("LATINO | Deportes", "LATAM"), ("FR VIP: Sport", "FR"),
        ("★ UK ★ Sports", "UK"), ("NL Films", "NL"), ("EN - Action", "EN"), ("PT| Desporto", "PT"), ("United Kingdom | Docs", "UK"),
        // The same country spelled the ways different providers spell it.
        ("NA | Sports", "US"), ("North America: News", "US"), ("U.S. | Kids", "US"), ("U.S.A - Movies", "US"), ("AMERICAN | Docs", "US"),
        ("USA/CA | Locals", "US"), ("FRENCH | Films", "FR"), ("DEUTSCHLAND: Sport", "DE"), ("GER | Bundesliga", "DE"),
        ("ESPAÑA | Deportes", "ES"), ("TÜRKIYE | Haber", "TR"), ("HOLLAND: Sport", "NL"), ("KSA | Sports", "SA"),
        ("ARGENTINA | Fútbol", "ARGENTINA"), ("ARG | Noticias", "ARGENTINA"),
        // Country names with no separator, and codes the table only knows from real provider lists.
        ("SWEDEN HD & HEVC", "SE"), ("DENMARK TV2 PLAY PPV", "DK"), ("SOUTH AFRICA SPORTS", "ZA"),
        ("EST| ESTONIA", "EE"), ("CRB| HAITI", "CARIBBEAN"), ("|SCA| NORDIC FILMS 4K", "NORDIC"), ("|QC| FILMS", "QC"),
        ("|MULTI| NETFLIX SERIES", "MULTI"), ("ES|ES|ES| MUSICA", "ES"),
        // Short codes the table doesn't know still become a region when used as a prefix.
        ("BEE| BEIN SPORTS", "BEE"), ("WC| WORLD CRICKET", "WC"),
    ])
    func detectsRegionPrefixes(name: String, code: String) {
        #expect(RegionPrefix.detect(name) == code)
    }

    @Test(arguments: [
        "Sports", "Sci-Fi Movies", "VIP | Movies", "4K | Movies", "TV Shows", "NBA League Pass", "BBC Channels",
        "IN Cinemas", "24/7 | Cartoons", "Movies (2024)", "HD Channels", "UK", "PPV: Events",
        "KIDS | Cartoons", "NBA | Games", "Kids | Cartoons", "4K UHD 3840P", "24/7 DISNEY+ ᴿᴬᵂ", "FORMULA 1 ONBOARDS",
        "NETFLIX MOVIES", "TOP IMDB/OSCAR MOVIES", "WORLDCUP 2022", "GEORGIA LOCALS", "Sweden Rocks", "NEW - Movies",
    ])
    func ignoresNamesWithoutARegion(name: String) {
        #expect(RegionPrefix.detect(name) == nil)
    }

    @Test func namesAndStripping() {
        #expect(RegionPrefix.displayName("UK") == "United Kingdom")
        #expect(RegionPrefix.displayName("FR") == "France")
        #expect(RegionPrefix.displayName("EX-YU") == "Ex-Yugoslavia")
        #expect(RegionPrefix.strip("UK | Sports") == "Sports")
        #expect(RegionPrefix.strip("[FR] Cinéma") == "Cinéma")
        #expect(RegionPrefix.strip("Kids") == "Kids")
        #expect(RegionPrefix.strip("SWEDEN HD & HEVC") == "HD & HEVC")
        #expect(RegionPrefix.strip("BEE| BEIN SPORTS") == "BEIN SPORTS")
        #expect(RegionPrefix.displayName("BEE") == "BEE")
    }

    /// Codes are read the way each provider uses them, judged from its own group names.
    @Test func readsCodesTheWayEachProviderUsesThem() {
        func regions(_ names: [String], aliases: [String: String] = [:]) -> [String?] {
            RegionPrefix.resolve(names, aliases: aliases).map(\.region)
        }
        // This provider's IS is Israel, not Iceland; its BH is Bosnia, CG Montenegro, SL Slovenia.
        let israel = ["IS| ISRAEL VIP", "IS| ISRAEL HD", "IS| YES BOXES", "IS| HEBREW SDAROT 24/7"]
        #expect(regions(israel) == ["IL", "IL", "IL", "IL"])
        #expect(regions(["BH| BOSNIA", "CG| MONTENEGRO VIP", "SL| SLOVENIA", "LA| LATVIA"]) == ["BA", "ME", "SI", "LV"])
        // Codes the table doesn't know, explained by the names after them.
        #expect(regions(["KU| KURDISTAN", "TAI| TAIWAN", "VT| VIETNAM", "KA| KAZACHSTAN", "KO| KOSOVO"])
                == ["KURDISH", "TW", "VN", "KZ", "XK"])
        #expect(regions(["LA| LATINO SERIES"]) == ["LATAM"])
        #expect(regions(["AF| AFRICAN MOVIES", "AF| SOUTH AFRICA"]) == ["AFRICA", "AFRICA"])
        // A provider mixing two countries under one code keeps the code's usual meaning.
        #expect(regions(["IR| IRELAND", "IR| SETANTA PPV", "IR| IRAN"]).allSatisfy { $0 == "IR" })
        // A provider whose IS really is Iceland keeps it.
        #expect(regions(["IS| ICELAND HD", "IS| RUV", "IS| SPORT"]) == ["IS", "IS", "IS"])
        // Well-known spellings never move, even when one group names another country.
        #expect(regions(["UK| KIDS", "UK| IRELAND", "PT| PORTUGAL", "PT| CABO VERDE", "EU| NETHERLANDS SD", "AR| MOROCCO"])
                == ["UK", "UK", "PT", "PT", "EU", "AR"])
        // Only when the code abbreviates the region named: content-language words don't count.
        #expect(regions(["IR| PERSIAN SERIES", "IR| TURKISH SERIES", "IR| TURKISH DUBBED"]).allSatisfy { $0 == "IR" })
        #expect(regions(["MX| GUATEMALA", "MX| NEWS", "MX| SPORTS", "MX| MOVIES"]).allSatisfy { $0 == "MX" })
        #expect(regions(["IR| IRELAND", "IR| SETANTA PPV", "IR| CLUBBER PPV"]) == ["IE", "IE", "IE"])
        #expect(regions(["SK| SOUTH KOREA", "SK| COUPANG PPV"]) == ["KR", "KR"])
        // The user's split wins over the provider reading.
        #expect(regions(israel, aliases: ["IS": "IS"]) == ["IS", "IS", "IS", "IS"])
    }

    @Test func keepsTheProvidersSpelling() {
        #expect(RegionPrefix.detectPrefix("NA | Sports") == "NA")
        #expect(RegionPrefix.detectPrefix("U.S. | Kids") == "US")
        #expect(RegionPrefix.detectPrefix("USA/CA | Locals") == "USA")
        #expect(RegionPrefix.key(forPrefix: "NA") == "US")
        #expect(RegionPrefix.key(forPrefix: "NA", aliases: ["NA": "NA"]) == "NA")
        #expect(RegionPrefix.displayName("NA") == "North America")
    }

    @Test func migrationFillsInExistingCategories() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v3-guide-index")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO provider (id, name, kind, serverURL, createdAt) VALUES ('p', 'P', 'xtream', 'http://p.test', 0);
                INSERT INTO category (providerID, kind, categoryID, name) VALUES ('p', 'live', '1', 'UK | Sports'), ('p', 'live', '2', 'Kids');
                """)
        }
        try AppDatabase.migrator.migrate(queue)
        let regions = try queue.read { db in try String?.fetchAll(db, sql: "SELECT region FROM category ORDER BY categoryID") }
        #expect(regions == ["UK", nil])
        let prefixes = try queue.read { db in try String?.fetchAll(db, sql: "SELECT regionPrefix FROM category ORDER BY categoryID") }
        #expect(prefixes == ["UK", nil])
    }

    @Test func betterRulesKeepWhatTheUserHid() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v5-category-region-prefix")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO provider (id, name, kind, serverURL, createdAt) VALUES ('p', 'P', 'xtream', 'http://p.test', 0);
                INSERT INTO category (providerID, kind, categoryID, name, region, regionPrefix) VALUES
                    ('p', 'live', '1', 'SK| SOUTH KOREA', 'SK', 'SK'), ('p', 'live', '2', 'SK| COUPANG PPV', 'SK', 'SK'),
                    ('p', 'live', '3', 'SWEDEN HD & HEVC', NULL, NULL), ('p', 'live', '4', 'SE| SPORT', 'SE', 'SE'),
                    ('p', 'live', '5', 'BEE| BEIN SPORTS', NULL, NULL), ('p', 'live', '6', 'CG| MONTENEGRO', 'CG', 'CG');
                INSERT INTO setting (scopeKey, key, value) VALUES ('global', 'hiddenRegions', '["SK","SE"]');
                """)
        }
        try AppDatabase.migrator.migrate(queue)
        let regions = try queue.read { db in try String?.fetchAll(db, sql: "SELECT region FROM category ORDER BY categoryID") }
        #expect(regions == ["KR", "KR", "SE", "SE", "BEE", "ME"])
        let hidden = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = 'hiddenRegions'")
        }
        // South Korea was hidden as "SK"; BEE groups had no region before, and CG wasn't hidden.
        #expect(hidden == #"["SK","SE","KR"]"#)
    }

    @Test func hiddenRegionsLeaveLiveTVButNotMoviesOrFavorites() async throws {
        let database = try AppDatabase.inMemory()
        let provider = try ProviderRepository(database: database).insert(TestData.provider())
        let catalog = CatalogRepository(database: database)
        try catalog.replaceCategories([
            Category(providerID: provider.id, kind: .live, categoryID: "1", name: "UK | Sports"),
            Category(providerID: provider.id, kind: .live, categoryID: "2", name: "US | News"),
            Category(providerID: provider.id, kind: .live, categoryID: "3", name: "Kids"),
        ], providerID: provider.id, kind: .live)
        try catalog.replaceCategories([Category(providerID: provider.id, kind: .movie, categoryID: "m1", name: "UK | Action"),
                                       Category(providerID: provider.id, kind: .movie, categoryID: "m2", name: "US | Drama")],
                                      providerID: provider.id, kind: .movie)
        try catalog.replaceChannels([
            Channel(providerID: provider.id, streamID: 1, name: "Sky Sports", categoryID: "1"),
            Channel(providerID: provider.id, streamID: 2, name: "Sky News US", categoryID: "2"),
            Channel(providerID: provider.id, streamID: 3, name: "Sky Kids", categoryID: "3"),
        ], providerID: provider.id)
        try catalog.replaceMovies([Movie(providerID: provider.id, streamID: 10, name: "Sky Heist", categoryID: "m1"),
                                   Movie(providerID: provider.id, streamID: 11, name: "Sky Story", categoryID: "m2")],
                                  providerID: provider.id)
        try LogicalChannelStore(database: database).rebuild()
        let library = LibraryRepository(database: database)
        let live = LiveCatalog(database: database)
        let vod = VODCatalog(database: database)
        let search = SearchRepository(database: database)

        let regions = try await library.regions()
        #expect(regions.map(\.code) == ["UK", "US", RegionPrefix.other])
        #expect(regions.first?.liveGroups == 1)
        // Only live groups are listed: region switches don't apply to Movies and Series.
        #expect(regions.first?.examples == ["Sports"])
        #expect(regions.first?.categoryCount == 1)

        let sports = try #require(try await live.allChannels().first { $0.name == "Sky Sports" })
        _ = try await library.toggleFavorite(sports)
        try await library.setRegion("UK", hidden: true)

        #expect(try await library.regions().first { $0.code == "UK" }?.isHidden == true)
        #expect(try await live.groups().filter { $0.kind == .category }.map(\.name) == ["US | News", "Kids"])
        // Hidden even with "Show Hidden", since regions are managed in Settings.
        #expect(try await live.groups(includeHidden: true).filter { $0.kind == .category }.map(\.name) == ["US | News", "Kids"])
        #expect(try await live.allChannels().map(\.name) == ["Sky News US", "Sky Kids"])
        #expect(try await vod.categories(.movie).map(\.name) == ["UK | Action", "US | Drama"])
        #expect(try await vod.items(.movie).map(\.itemID).sorted() == [10, 11])
        let found = try await search.search("sky")
        #expect(found.channels.map(\.name).sorted() == ["Sky Kids", "Sky News US"])
        #expect(found.movies.map(\.itemID).sorted() == [10, 11])
        // Favorites keep what the user picked.
        let favorites = ChannelGroup(id: "favorites", name: "Favorites", kind: .favorites)
        #expect(try await live.channels(in: favorites).map(\.name) == ["Sky Sports"])

        try await library.setRegion("UK", hidden: false)
        #expect(try await live.allChannels().count == 3)
        #expect(try await vod.items(.movie).count == 2)
        #expect(library.hiddenRegions().isEmpty)
    }

    @Test func everyCategoryHasASwitchAndSingleOnesCanDiffer() async throws {
        let database = try AppDatabase.inMemory()
        let provider = try ProviderRepository(database: database).insert(TestData.provider())
        let catalog = CatalogRepository(database: database)
        try catalog.replaceCategories([
            Category(providerID: provider.id, kind: .live, categoryID: "1", name: "UK | Sports"),
            Category(providerID: provider.id, kind: .live, categoryID: "2", name: "UK | Wrongly Filed"),
            Category(providerID: provider.id, kind: .live, categoryID: "3", name: "24/7 Cartoons"),
            Category(providerID: provider.id, kind: .live, categoryID: "4", name: "Formula 1"),
        ], providerID: provider.id, kind: .live)
        try catalog.replaceMovies([Movie(providerID: provider.id, streamID: 10, name: "Heist", categoryID: "m1")], providerID: provider.id)
        try catalog.replaceCategories([Category(providerID: provider.id, kind: .movie, categoryID: "m1", name: "NETFLIX MOVIES")],
                                      providerID: provider.id, kind: .movie)
        let library = LibraryRepository(database: database)
        let live = LiveCatalog(database: database)
        func groupNames() async throws -> [String] { try await live.groups().filter { $0.kind == .category }.map(\.name) }

        // Unrecognised categories are listed too, last, under "Other Groups".
        let regions = try await library.regions()
        #expect(regions.map(\.code) == ["UK", RegionPrefix.other])
        #expect(regions.last?.name == "Other Groups")
        #expect(regions.last?.categoryCount == 2)
        let categories = try await library.regionCategories()
        #expect(categories[RegionPrefix.other]?.map(\.name) == ["24/7 Cartoons", "Formula 1"])

        // The Other switch hides its live groups; movies aren't affected.
        try await library.setRegion(RegionPrefix.other, hidden: true)
        #expect(try await groupNames() == ["UK | Sports", "UK | Wrongly Filed"])
        #expect(try await VODCatalog(database: database).items(.movie).count == 1)
        // Nor is a movie category hidden by hand when a region switch resets its groups.
        try await library.setCategoryHidden(true, providerID: provider.id, kind: .movie, categoryID: "m1")
        try await library.setRegion(RegionPrefix.other, hidden: false)
        #expect(try await VODCatalog(database: database).categories(.movie).isEmpty)
        try await library.setCategoryHidden(false, providerID: provider.id, kind: .movie, categoryID: "m1")
        try await library.setRegion(RegionPrefix.other, hidden: true)

        // Hide the UK, then switch one of its groups back on, and one Other group too.
        try await library.setRegion("UK", hidden: true)
        let wrong = try #require(categories["UK"]?.first { $0.categoryID == "2" })
        let formula = try #require(categories[RegionPrefix.other]?.first { $0.categoryID == "4" })
        try await library.setCategory(wrong, shown: true)
        try await library.setCategory(formula, shown: true)
        #expect(try await groupNames() == ["UK | Wrongly Filed", "Formula 1"])
        #expect(try await library.regions().first { $0.code == "UK" }.map { ($0.shownCategories, $0.categoryCount) } ?? (0, 0) == (1, 2))

        // In a region that's on, switching one off hides just that one.
        try await library.setRegion("UK", hidden: false)
        #expect(try await groupNames() == ["UK | Sports", "UK | Wrongly Filed", "Formula 1"])
        try await library.setCategory(wrong, shown: false)
        #expect(try await groupNames() == ["UK | Sports", "Formula 1"])

        // Flipping a region's switch resets the single switches inside it, like a parent checkbox.
        try await library.setRegion("UK", hidden: true)
        try await library.setRegion("UK", hidden: false)
        #expect(try await groupNames() == ["UK | Sports", "UK | Wrongly Filed", "Formula 1"])
        try await library.setHiddenRegions([], resettingCategoriesIn: ["UK", RegionPrefix.other])
        #expect(try await groupNames().count == 4)
    }

    @Test func providersSpellingsMergeAndCanBeSplitOrMergedByHand() async throws {
        let database = try AppDatabase.inMemory()
        let repo = ProviderRepository(database: database)
        let a = try repo.insert(TestData.provider("A"))
        let b = try repo.insert(TestData.provider("B"))
        let catalog = CatalogRepository(database: database)
        try catalog.replaceCategories([Category(providerID: a.id, kind: .live, categoryID: "1", name: "US | News"),
                                       Category(providerID: a.id, kind: .live, categoryID: "2", name: "CA | Sports")],
                                      providerID: a.id, kind: .live)
        try catalog.replaceCategories([Category(providerID: b.id, kind: .live, categoryID: "1", name: "NA | Sports"),
                                       Category(providerID: b.id, kind: .live, categoryID: "2", name: "USA: Movies")],
                                      providerID: b.id, kind: .live)
        let library = LibraryRepository(database: database)

        // Built in: US, NA and USA are one region, listed with every spelling and both providers.
        var regions = try await library.regions()
        let us = try #require(regions.first { $0.code == "US" })
        #expect(Set(us.spellings) == ["US", "NA", "USA"])
        #expect(us.providers == ["A", "B"])
        #expect(us.liveGroups == 3)

        // Split NA off while US is hidden: it stays hidden as a region of its own.
        try await library.setRegion("US", hidden: true)
        try await library.separateSpelling("NA")
        regions = try await library.regions()
        #expect(regions.first { $0.code == "NA" }?.name == "North America")
        #expect(regions.first { $0.code == "NA" }?.isHidden == true)
        #expect(regions.first { $0.code == "US" }?.spellings.contains("NA") == false)

        // Merge Canada into the US by hand; later syncs keep the merge.
        try await library.mergeRegion("CA", into: "US")
        #expect(try await library.regions().contains { $0.code == "CA" } == false)
        try catalog.replaceCategories([Category(providerID: a.id, kind: .live, categoryID: "2", name: "CA | Sports"),
                                       Category(providerID: a.id, kind: .live, categoryID: "3", name: "CAN | News")],
                                      providerID: a.id, kind: .live)
        let regionsAfterSync = try await database.reader.read { db in
            try String.fetchAll(db, sql: "SELECT region FROM category WHERE providerID = ? ORDER BY categoryID", arguments: [a.id.rawValue])
        }
        #expect(regionsAfterSync == ["US", "US"])

        // Reset goes back to the built-in table.
        try await library.resetRegionMerges()
        #expect(library.regionAliases().isEmpty)
        regions = try await library.regions()
        #expect(regions.contains { $0.code == "CA" })
        #expect(regions.first { $0.code == "US" }?.spellings.contains("NA") == true)
    }
}
