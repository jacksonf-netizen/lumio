import Foundation
import GRDB

/// Finds the region prefix providers put on category names ("UK | Sports", "US: News", "[FR] Cinéma",
/// "|DE| Filme", "EX-YU ▎ Sport", "Canada - News") so whole regions can be hidden at once.
///
/// Two steps, because every provider spells regions differently:
/// 1. `detectPrefix` finds the provider's spelling ("NA", "USA", "UNITED STATES", "U.S.").
/// 2. `key(forPrefix:aliases:)` says which region that spelling belongs to ("US"), from a built-in
///    table of provider conventions, overridden by the user's own merges in Settings.
///
/// Codes are also read the way each provider uses them (`resolve`): if a provider's "IS" groups are
/// "IS| ISRAEL VIP" and "IS| HEBREW", its IS means Israel, not Iceland. A short code the table doesn't
/// know ("BEE| BEIN SPORTS") still becomes a region of its own when it's clearly used as a prefix,
/// so it can be hidden; tags like "VIP | Movies" or "4K | Movies" never count.
public enum RegionPrefix {
    /// The region a category name belongs to, or nil if it has no recognisable region prefix.
    public static func detect(_ name: String, aliases: [String: String] = [:]) -> String? {
        detectPrefix(name).map { key(forPrefix: $0, aliases: aliases) }
    }

    /// The provider's spelling of the region at the start of `name`, normalised (upper case, no
    /// dots, single spaces): "U.S. | News" → "US", "North America: Sports" → "NORTH AMERICA".
    public static func detectPrefix(_ name: String) -> String? {
        split(name)?.prefix
    }

    /// The provider's spelling and the rest of the name: "UK | Sports" → ("UK", "Sports").
    static func split(_ name: String) -> (prefix: String, rest: String)? {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines.union(decorations))
        guard !text.isEmpty else { return nil }
        let trim = CharacterSet.whitespaces.union(strongSeparators).union(dashSeparators).union(decorations)

        // Bracketed at the start: "[UK] Sports", "(US) News", "|FR| Films".
        if let first = text.first, let close = closing[first],
           let end = text.dropFirst().firstIndex(of: close),
           text.distance(from: text.startIndex, to: end) <= 20 {
            let inside = String(text[text.index(after: text.startIndex)..<end])
            let rest = text[text.index(after: end)...].trimmingCharacters(in: trim)
            if !rest.isEmpty, let spelling = knownSpelling(inside) ?? unknownCode(inside) { return (spelling, rest) }
        }

        // Before a separator: "UK | Sports", "US: News", "EX-YU ▎ Sport". Strong separators win over
        // dashes, so "EX-YU | Sport" reads as EX-YU rather than EX. Unknown codes only count before a
        // strong separator ("BEE| BEIN SPORTS"), not a dash.
        for separators in [strongSeparators, dashSeparators] {
            if let index = text.firstIndex(where: { $0.unicodeScalars.allSatisfy(separators.contains) }),
               text.distance(from: text.startIndex, to: index) <= 24 {
                let prefix = String(text[..<index])
                let rest = text[text.index(after: index)...].trimmingCharacters(in: trim)
                guard !rest.isEmpty else { continue }
                if let spelling = knownSpelling(prefix) { return (spelling, rest) }
                if separators == strongSeparators, let code = unknownCode(prefix) { return (code, rest) }
            }
        }

        // No separator: an upper-case code ("UK Sports", "USA Entertainment") or country name
        // ("SWEDEN HD & HEVC", "SOUTH AFRICA SPORTS") as the first words. Stricter, because short
        // words like "TV" or "IN" are also country codes.
        let words = text.split(separator: " ")
        for count in stride(from: min(3, words.count - 1), through: 1, by: -1) {
            let candidate = words.prefix(count).joined(separator: " ")
            guard candidate == candidate.uppercased(), candidate.contains(where: \.isLetter) else { continue }
            let normalized = normalize(candidate)
            let isName = normalized.count >= 4 && !ambiguousNames.contains(normalized)
            let isCode = count == 1 && normalized.count <= 5 && !ambiguousWithoutSeparator.contains(normalized)
            guard isName || isCode, !notRegions.contains(normalized), builtInKey(normalized) != nil else { continue }
            return (normalized, words.dropFirst(count).joined(separator: " "))
        }
        return nil
    }

    /// Region keys for one provider's categories of one kind, read the way that provider uses its
    /// codes. A code that isn't one of the well-known provider spellings is reread when the
    /// provider's own group names say what it means: "IS| ISRAEL VIP", "IS| HEBREW SDAROT" → IL;
    /// "KU| KURDISTAN" → Kurdish. Only when the names never mention the code's usual country, and the
    /// code abbreviates the region they mostly name (so "IR| TURKISH SERIES"
    /// stays Iran). The user's merges win.
    public static func resolve(_ names: [String], aliases: [String: String] = [:]) -> [(prefix: String?, region: String?)] {
        let parts = names.map(split)
        var votes: [String: [String]] = [:]   // spelling → regions named after it, in order
        for part in parts.compactMap({ $0 }) {
            if let named = leadingRegion(part.rest) { votes[part.prefix, default: []].append(named) }
        }
        var readings: [String: String] = [:]
        for (spelling, named) in votes where conventions[spelling] == nil && aliases[spelling] == nil {
            let usual = builtInKey(spelling)
            // Only plain ISO codes and unknown codes; never a spelling the table names on purpose.
            guard usual == nil || (spelling.count == 2 && isoCodes.contains(spelling)), !named.contains(where: { $0 == usual })
            else { continue }
            let fitting = named.filter { abbreviates(spelling, $0) }
            var counts: [String: Int] = [:]
            for region in fitting { counts[region, default: 0] += 1 }
            guard let best = fitting.max(by: { counts[$0]! < counts[$1]! }), counts[best]! * 2 > fitting.count else { continue }
            readings[spelling] = best
        }
        return parts.map { part in
            guard let spelling = part?.prefix else { return (nil, nil) }
            if let reading = readings[spelling] { return (spelling, aliases[reading] ?? reading) }
            return (spelling, key(forPrefix: spelling, aliases: aliases))
        }
    }

    /// Whether `code` reads as an abbreviation of one of the region's names: its letters in order,
    /// starting with the first ("IS" → ISRAEL, "CG" → CRNA GORA, "TAI" → TAIWAN).
    private static func abbreviates(_ code: String, _ region: String) -> Bool {
        let letters = Array(code.filter(\.isLetter))
        guard let first = letters.first else { return false }
        return spellings(of: region).contains { name in
            let name = Array(name.filter(\.isLetter))
            guard name.first == first else { return false }
            var index = 0
            for character in name where index < letters.count && character == letters[index] { index += 1 }
            return index == letters.count
        }
    }

    /// Every full name the tables give a region, upper case: IL → ISRAEL, ISRAELI, HEBREW, …
    private static func spellings(of region: String) -> [String] {
        var result = [displayName(region).uppercased()]
        result += conventions.filter { $0.value == region && $0.key.count >= 4 }.map(\.key)
        result += countryNames.filter { $0.value == region }.map(\.key)
        return result
    }

    /// The region named at the start of the rest of a name: "ISRAEL VIP" → IL, "LATINO SERIES" →
    /// LATAM. Full names only (four letters or more), so "NA ŚWIĄTECZNIE" doesn't count as NA.
    private static func leadingRegion(_ rest: String) -> String? {
        let words = normalize(rest).split(whereSeparator: { $0 == " " || $0 == "/" })
        for count in stride(from: min(3, words.count), through: 1, by: -1) {
            let candidate = words.prefix(count).joined(separator: " ")
            if candidate.count >= 4, let region = builtInKey(candidate) { return region }
        }
        return nil
    }

    /// The region a spelling belongs to: the user's choice for that spelling, else the built-in
    /// table (else the spelling itself). A merge of a whole region ("CA" → "US") then applies on
    /// top, so spellings that turn up later ("CAN") follow it too.
    public static func key(forPrefix spelling: String, aliases: [String: String] = [:]) -> String {
        if let chosen = aliases[spelling] { return chosen }
        let base = builtInKey(spelling) ?? spelling
        return aliases[base] ?? base
    }

    /// A readable name for a region: "UK" → "United Kingdom", "AR" → "Arabic".
    public static func displayName(_ code: String) -> String {
        if let name = names[code] { return name }
        if code.count == 2, isoCodes.contains(code), let name = Locale(identifier: "en_US").localizedString(forRegionCode: code) {
            return name
        }
        // Codes the table doesn't know ("BEE") stay as the provider wrote them.
        return code.count <= 5 ? code : code.capitalized
    }

    /// The category name without its region prefix ("UK | Sports" → "Sports"), for compact display.
    public static func strip(_ name: String) -> String {
        split(name)?.rest ?? name
    }

    // MARK: Matching

    private static let decorations = CharacterSet(charactersIn: "★☆✦✧●○◆◇▶►▸•#*~")
    private static let strongSeparators = CharacterSet(charactersIn: "|:▎▍▌┃│¦»·•⎪")
    private static let dashSeparators = CharacterSet(charactersIn: "-–—")
    private static let closing: [Character: Character] = ["[": "]", "(": ")", "|": "|", "{": "}", "<": ">"]

    /// Two-letter codes that are also everyday words or abbreviations: only accepted with a separator.
    private static let ambiguousWithoutSeparator: Set<String> = [
        "TV", "IN", "IS", "IT", "TO", "NO", "DO", "BE", "GO", "SO", "AS", "AM", "PM", "MY", "ME", "OR", "ON", "AT",
        "ID", "AN", "AI", "SD", "HD", "UHD", "FHD", "VIP", "NEW", "ALL", "TOP", "BEST", "NA",
    ]

    /// Country names that are also everyday words or US states: only accepted with a separator.
    private static let ambiguousNames: Set<String> = ["GEORGIA", "JORDAN", "JERSEY", "CHAD", "NIGER", "GUINEA", "WALES"]

    /// Labels that are never regions even with a separator (quality and format tags).
    private static let notRegions: Set<String> = ["TV", "SD", "HD", "FHD", "UHD", "4K", "8K", "VIP", "PPV", "VOD", "HEVC", "24/7", "NEW", "ALL"]

    /// Short upper-case labels that are sections, tags, brands or leagues rather than regions, so
    /// "KIDS | Cartoons" or "NBA | Games" never become a region switch.
    private static let notUnknownRegions: Set<String> = [
        "VIP", "PPV", "HD", "FHD", "UHD", "SD", "TV", "VOD", "HEVC", "NEW", "ALL", "TOP", "HOT", "BEST", "RAW", "LIVE",
        "KIDS", "NEWS", "MUSIC", "SPORT", "ADULT", "XXX", "FILM", "FILMS", "MOVIE", "SERIE", "SHOW", "SHOWS", "DOCS", "DOC",
        "RADIO", "LOCAL", "EVENT", "EXTRA", "PLUS", "PRIME", "GOLD", "BONUS", "TEST", "CINE", "REPLAY", "CAM", "BOX",
        "OTHER", "MISC", "HBO", "ESPN", "SKY", "BBC", "ITV", "CNN", "FOX", "NBC", "CBS", "ABC", "AMC", "TNT", "NBA", "NFL",
        "NHL", "MLB", "MLS", "UFC", "WWE", "NCAA", "EPL", "DAZN", "BEIN", "OSN", "MBC", "ART", "TOD", "F", "PG", "PM", "AM",
    ]

    /// A short upper-case code the table doesn't know ("BEE", "KU"), used as a prefix by a provider.
    private static func unknownCode(_ candidate: String) -> String? {
        let text = candidate.trimmingCharacters(in: .whitespaces)
        guard (2...5).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isUppercase }),
              !notUnknownRegions.contains(text) else { return nil }
        return text
    }

    /// Provider spellings → region. Covers ISO 3-letter and sports codes, native and English names,
    /// and language names, since panels label groups all of these ways.
    private static let conventions: [String: String] = {
        var map: [String: String] = [:]
        func add(_ key: String, _ spellings: String...) { for s in spellings { map[s] = key } }
        // North America: providers use NA for the US lineup.
        add("US", "US", "USA", "UNITED STATES", "UNITED STATES OF AMERICA", "AMERICA", "AMERICAN", "NA", "NORTH AMERICA", "N AMERICA")
        add("UK", "UK", "GB", "GBR", "UNITED KINGDOM", "BRITAIN", "GREAT BRITAIN", "BRITISH", "ENGLAND", "SCOTLAND", "WALES")
        add("CA", "CAN", "CANADA", "CANADIAN")
        add("IE", "IRL", "IRELAND", "IRISH")
        add("AU", "AUS", "AUSTRALIA", "AUSTRALIAN")
        add("NZ", "NZL", "NEW ZEALAND")
        add("FR", "FRA", "FRANCE", "FRENCH", "FRANCAIS", "FRANÇAIS")
        add("DE", "DEU", "GER", "GERMANY", "GERMAN", "DEUTSCH", "DEUTSCHLAND", "ALLEMAGNE")
        add("AT", "AUT", "AUSTRIA", "ÖSTERREICH", "OSTERREICH")
        add("CH", "CHE", "SUI", "SWITZERLAND", "SWISS", "SCHWEIZ", "SUISSE")
        add("ES", "ESP", "SPAIN", "SPANISH", "ESPAÑA", "ESPANA", "ESPAÑOL", "ESPANOL")
        add("PT", "POR", "PRT", "PORTUGAL", "PORTUGUESE", "PORTUGUÊS")
        add("BR", "BRA", "BRAZIL", "BRASIL", "BRAZILIAN")
        add("IT", "ITA", "ITALY", "ITALIA", "ITALIAN")
        add("NL", "NLD", "NED", "HOL", "HOLLAND", "NETHERLANDS", "NEDERLAND", "DUTCH")
        add("BE", "BEL", "BELGIUM", "BELGIQUE", "BELGIE")
        add("SE", "SWE", "SWEDEN", "SVERIGE", "SWEDISH")
        add("NO", "NOR", "NORWAY", "NORGE", "NORWEGIAN")
        add("DK", "DNK", "DEN", "DENMARK", "DANMARK", "DANISH")
        add("FI", "FIN", "FINLAND", "SUOMI", "FINNISH")
        add("PL", "POL", "POLAND", "POLSKA", "POLISH")
        add("CZ", "CZE", "CZECH", "CZECHIA", "CESKO", "ČESKO")
        add("SK", "SVK", "SLOVAKIA")
        add("HU", "HUN", "HUNGARY", "HUNGARIAN", "MAGYAR")
        add("RO", "ROU", "ROM", "ROMANIA", "ROMANIAN")
        add("BG", "BGR", "BUL", "BULGARIA", "BULGARIAN")
        add("GR", "GRC", "GRE", "GREECE", "GREEK", "HELLAS")
        add("AL", "ALB", "ALBANIA", "ALBANIAN", "SHQIP", "SHQIPERI")
        add("TR", "TUR", "TURKEY", "TURKIYE", "TÜRKIYE", "TURKISH", "TÜRK")
        add("RU", "RUS", "RUSSIA", "RUSSIAN")
        add("UA", "UKR", "UKRAINE", "UKRAINIAN")
        add("RS", "SRB", "SERBIA", "SRBIJA")
        add("HR", "HRV", "CRO", "CROATIA", "HRVATSKA")
        add("BA", "BIH", "BOSNIA")
        add("SI", "SVN", "SLO", "SLOVENIA")
        add("MK", "MKD", "MACEDONIA")
        add("EX-YU", "EX-YU", "EXYU", "EX YU", "YU", "BALKAN", "BALKANS")
        add("IL", "ISR", "ISRAEL", "ISRAELI", "HEBREW")
        add("IN", "IND", "INDIA", "INDIAN", "HINDI")
        add("PK", "PAK", "PAKISTAN", "PAKISTANI", "URDU")
        add("BD", "BGD", "BAN", "BANGLADESH", "BANGLA", "BENGALI")
        add("AF", "AFG", "AFGHANISTAN", "AFGHAN")
        add("IR", "IRN", "IRAN")
        add("CN", "CHN", "CHINA", "CHINESE")
        add("JP", "JPN", "JAPAN", "JAPANESE")
        add("KR", "KOR", "KOREA", "SOUTH KOREA", "KOREAN")
        add("PH", "PHL", "PHI", "PHILIPPINES", "FILIPINO", "PINOY")
        add("VN", "VNM", "VIE", "VIETNAM", "VIETNAMESE")
        add("TH", "THA", "THAILAND", "THAI")
        add("MX", "MEX", "MEXICO", "MEXICAN", "MÉXICO")
        add("CO", "COL", "COLOMBIA")
        add("CL", "CHL", "CHI", "CHILE")
        add("SA", "SAU", "KSA", "SAUDI", "SAUDI ARABIA")
        add("AE", "ARE", "UAE", "EMIRATES")
        add("EG", "EGY", "EGYPT")
        add("MA", "MAR", "MOROCCO", "MAROC")
        add("DZ", "DZA", "ALG", "ALGERIA")
        add("TN", "TUN", "TUNISIA")
        add("ZA", "ZAF", "RSA", "SOUTH AFRICA")
        add("NG", "NGA", "NIGERIA")
        // Language and area groupings providers use as prefixes.
        add("AR", "AR", "ARB", "ARAB", "ARABIC", "ARABIA", "عربي")
        add("EN", "EN", "ENG", "ENGLISH")
        add("LATAM", "LAT", "LATAM", "LATIN", "LATINO", "LATINA", "LATIN AMERICA", "LATINOAMERICA")
        add("AFRICA", "AFR", "AFRICA", "AFRICAN")
        add("EU", "EU", "EUR", "EUROPE", "EUROPEAN")
        add("ASIA", "ASIA", "ASIAN")
        add("CARIBBEAN", "CARIB", "CARIBBEAN", "CARIBE")
        add("KURDISH", "KURD", "KURDISH", "KURDISTAN")
        add("PERSIAN", "PERSIAN", "FARSI")
        add("INT", "INT", "INTL", "INTERNATIONAL", "WORLD")
        add("MENA", "MENA", "MIDDLE EAST")
        add("NORDIC", "NORDIC", "SCANDINAVIA", "SCANDINAVIAN", "SCA", "SCAND")
        add("EE", "EST", "ESTONIA", "EESTI")
        add("LV", "LVA", "LATVIA")
        add("LT", "LTU", "LITHUANIA")
        add("KZ", "KAZ", "KAZAKHSTAN", "KAZACHSTAN", "KAZAKSTAN")
        add("XK", "KOS", "KOSOVO", "KOSOVA")
        add("ME", "MNE", "MONTENEGRO", "CRNA GORA")
        add("TW", "TWN", "TAIWAN")
        add("QC", "QC", "QUEBEC", "QUÉBEC")
        add("MULTI", "MULTI", "MULTILANG", "MULTI LANG", "MULTI-LANG", "MULTILANGUAGE")
        add("CARIBBEAN", "CRB")
        // Codes that clash with a provider convention above get their own entries.
        add("ARGENTINA", "ARG", "ARGENTINA")
        add("NAMIBIA", "NAMIBIA")
        return map
    }()

    private static let names: [String: String] = [
        "UK": "United Kingdom", "US": "United States", "EN": "English", "AR": "Arabic", "LATAM": "Latin America",
        "EX-YU": "Ex-Yugoslavia", "AFRICA": "Africa", "EU": "Europe", "ASIA": "Asia", "CARIBBEAN": "Caribbean",
        "KURDISH": "Kurdish", "PERSIAN": "Persian", "INT": "International", "MENA": "Middle East & North Africa",
        "NORDIC": "Nordic", "ARGENTINA": "Argentina", "NAMIBIA": "Namibia", "XK": "Kosovo", "QC": "Québec",
        "MULTI": "Multi-language",
        // Shown when the user splits a spelling into its own region.
        "NA": "North America", "NORTH AMERICA": "North America", "USA": "USA",
    ]

    /// ISO country codes and English country names ("FRANCE" → "FR").
    private static let isoCodes: Set<String> = Set(Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 })
    private static let countryNames: [String: String] = {
        let english = Locale(identifier: "en_US")
        var map: [String: String] = [:]
        for code in isoCodes {
            if let name = english.localizedString(forRegionCode: code) { map[normalize(name)] = code }
        }
        return map
    }()

    /// Upper case, no dots, single spaces: "U.S." → "US", " north  america " → "NORTH AMERICA".
    static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(decorations))
            .uppercased()
            .replacingOccurrences(of: ".", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The normalised spelling if it's a known region ("UK VIP" and "USA/CA" count as UK and USA).
    static func knownSpelling(_ candidate: String) -> String? {
        let text = normalize(candidate)
        guard !text.isEmpty, text.count <= 24, !notRegions.contains(text) else { return nil }
        if builtInKey(text) != nil { return text }
        if let first = text.split(whereSeparator: { $0 == " " || $0 == "/" }).first.map(String.init),
           first != text, builtInKey(first) != nil {
            return first
        }
        return nil
    }

    /// Which region a normalised spelling belongs to, from the built-in table and ISO data.
    static func builtInKey(_ spelling: String) -> String? {
        if notRegions.contains(spelling) { return nil }
        if let key = conventions[spelling] { return key }
        if spelling.count == 2, isoCodes.contains(spelling) { return spelling }
        if let code = countryNames[spelling] { return conventions[code] ?? code }
        return nil
    }
}

extension RegionPrefix {
    /// The bucket for categories with no recognisable region, so every category has a switch.
    public static let other = "OTHER"

    /// SQL that is true when the category row `alias` is hidden by its region switch: it's a live
    /// group (region switches leave Movies and Series alone), its region (or the Other bucket, for
    /// groups without one) is in the global `hiddenRegions` setting, a JSON array of codes, and the
    /// user hasn't switched this one group back on.
    static func hiddenSQL(_ alias: String) -> String {
        let hidden = "(SELECT value FROM json_each(COALESCE((SELECT value FROM setting WHERE scopeKey = 'global' AND key = 'hiddenRegions'), '[]')))"
        return """
            (\(alias).kind = '\(ContentKind.live.rawValue)' AND COALESCE(\(alias).region, '\(other)') IN \(hidden)
             AND NOT EXISTS (SELECT 1 FROM categoryOverride so WHERE so.providerID = \(alias).providerID
                             AND so.kind = \(alias).kind AND so.categoryID = \(alias).categoryID AND so.isShown))
            """
    }

    /// SQL that is true when the channel row `alias` (with providerID and categoryID columns) sits
    /// in a live group hidden by its region switch.
    static func channelHiddenSQL(_ alias: String) -> String {
        """
        EXISTS (SELECT 1 FROM category rc WHERE rc.providerID = \(alias).providerID AND rc.kind = '\(ContentKind.live.rawValue)'
                AND rc.categoryID = \(alias).categoryID AND \(hiddenSQL("rc")))
        """
    }
}

extension RegionPrefix {
    /// The user's merges, read inside a database transaction.
    static func userAliases(_ db: Database) throws -> [String: String] {
        guard let record = try SettingRecord.fetchOne(db, key: ["scopeKey": SettingScope.global.key, "key": SettingKey.regionAliases.rawValue])
        else { return [:] }
        return (try? JSONDecoder.settings.decode([String: String].self, from: Data(record.value.utf8))) ?? [:]
    }

    /// Recomputes every category's region (after the merges change, or when the built-in rules
    /// improve), one provider and kind at a time so codes are read the way each provider uses them.
    /// With `keepHidden`, a region whose groups all come from regions the user had hidden starts
    /// hidden too, so better rules don't bring back what the user turned off.
    static func recompute(in db: Database, aliases: [String: String]? = nil, keepHidden: Bool = false) throws {
        let aliases = try aliases ?? userAliases(db)
        let rows = try Row.fetchAll(db, sql: "SELECT rowid, providerID, kind, name, regionPrefix, region FROM category ORDER BY providerID, kind")
        let batches = Dictionary(grouping: rows) { "\($0["providerID"] as String)/\($0["kind"] as String)" }
        var previous: [String: Set<String?>] = [:]   // new region → the regions its groups had
        for batch in batches.values {
            let resolved = resolve(batch.map { $0["name"] }, aliases: aliases)
            for (row, result) in zip(batch, resolved) {
                let old: String? = row["region"]
                if let region = result.region { previous[region, default: []].insert(old) }
                guard result.prefix != (row["regionPrefix"] as String?) || result.region != old else { continue }
                try db.execute(sql: "UPDATE category SET regionPrefix = ?, region = ? WHERE rowid = ?",
                               arguments: [result.prefix, result.region, row["rowid"] as Int64])
            }
        }
        guard keepHidden, let json = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE scopeKey = ? AND key = ?",
                                                         arguments: [SettingScope.global.key, SettingKey.hiddenRegions.rawValue]),
              var hidden = try? JSONDecoder.settings.decode([String].self, from: Data(json.utf8)) else { return }
        let before = Set(hidden)
        for (region, olds) in previous.sorted(by: { $0.key < $1.key }) where !before.contains(region) {
            if olds.allSatisfy({ $0.map(before.contains) ?? false }) { hidden.append(region) }
        }
        guard hidden.count != before.count else { return }
        let value = String(decoding: try JSONEncoder.settings.encode(hidden), as: UTF8.self)
        try db.execute(sql: "UPDATE setting SET value = ? WHERE scopeKey = ? AND key = ?",
                       arguments: [value, SettingScope.global.key, SettingKey.hiddenRegions.rawValue])
    }
}
