#if canImport(Android)
import Android
#endif
import CJNI
import Dispatch
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IPTVCore

// Phase 0 (test build) bridge: Kotlin calls `LumioCore.nativeCall(json)` and gets JSON back. It's
// written by hand to measure Swift on Android before committing to it; phase 2 replaces it with
// swift-java and real types. Logins are held in memory only here (the Keystore store comes later).

@_cdecl("Java_com_jackson_lumio_LumioCore_nativeCall")
public func Java_com_jackson_lumio_LumioCore_nativeCall(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?,
                                                         _ request: jstring?) -> jstring? {
    let functions = env.pointee!.pointee
    var text = ""
    if let request, let chars = functions.GetStringUTFChars(env, request, nil) {
        text = String(cString: chars)
        functions.ReleaseStringUTFChars(env, request, chars)
    }
    let response = Bridge.shared.handle(text)
    return response.withCString { functions.NewStringUTF(env, $0) }
}

final class Bridge: @unchecked Sendable {
    static let shared = Bridge()

    private var database: AppDatabase?
    private var providers: ProviderService?
    private var sync: CatalogSyncService?
    private var sources: XtreamSourceFactory?
    private let secrets = InMemorySecretStore()
    private let transport = URLSessionTransport()

    /// Runs one request to completion. Kotlin calls it from a background thread.
    func handle(_ json: String) -> String {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await self.run(json)
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    private func run(_ json: String) async -> String {
        let started = Date()
        do {
            guard let request = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let command = request["command"] as? String else { throw BridgeError("bad request") }
            var result = try await perform(command, request)
            result["ms"] = Int(Date().timeIntervalSince(started) * 1000)
            return Self.encode(result)
        } catch {
            return Self.encode(["error": String(describing: error), "ms": Int(Date().timeIntervalSince(started) * 1000)])
        }
    }

    private func perform(_ command: String, _ request: [String: Any]) async throws -> [String: Any] {
        switch command {
        case "start":
            guard let path = request["database"] as? String, let cache = request["cache"] as? String
            else { throw BridgeError("no database or cache path") }
            // Android apps get no TMPDIR, so Foundation's temporary folder would be /data/local/tmp,
            // which apps can't write (downloads crash). Use the app's own cache folder.
            setenv("TMPDIR", cache, 1)
            let database = try AppDatabase.open(at: URL(fileURLWithPath: path))
            let sources = XtreamSourceFactory(secrets: secrets, transport: transport)
            self.database = database
            self.sources = sources
            providers = ProviderService(database: database, secrets: secrets)
            sync = CatalogSyncService(database: database, sources: sources, connections: ConnectionManager())
            let existing = try ProviderRepository(database: database).all()
            return ["providers": existing.count]

        case "addProvider":
            guard let providers, let sync, let server = request["server"] as? String,
                  let username = request["username"] as? String, let password = request["password"] as? String
            else { throw BridgeError("not started or missing fields") }
            // A fresh library each run: the test build keeps logins in memory only.
            for old in try providers.repository.all() { try await providers.removeProvider(id: old.id) }
            let provider = try await providers.addProvider(
                name: request["name"] as? String ?? "Provider", serverURL: server,
                credentials: ProviderCredentials(username: username, password: password))
            let report = await sync.refresh(provider.id)
            let counts = try CatalogRepository(database: database!).counts(providerID: provider.id)
            return ["channels": counts.channels, "movies": counts.movies, "series": counts.series,
                    "programmes": counts.programmes, "error": report.error ?? "",
                    "partErrors": report.partErrors.map { "\($0.key.rawValue): \($0.value)" }]

        case "refreshGuide":
            guard let database, let sync, let provider = try ProviderRepository(database: database).all().first
            else { throw BridgeError("no provider") }
            let report = await sync.refresh(provider.id, parts: .guide)
            return ["programmes": report.guide?.programmesStored ?? 0,
                    "error": report.partErrors[.guide] ?? ""]

        case "channels":
            guard let database, let sources else { throw BridgeError("not started") }
            let channels = try await LiveCatalog(database: database).allChannels()
            let repository = ProviderRepository(database: database)
            var openSources: [ProviderID: any SourceProvider] = [:]
            var list: [[String: Any]] = []
            for channel in channels {
                if openSources[channel.providerID] == nil, let provider = try repository.provider(id: channel.providerID) {
                    openSources[channel.providerID] = try sources.source(for: provider)
                }
                guard let source = openSources[channel.providerID] else { continue }
                list.append(["name": channel.name, "number": channel.number ?? 0,
                             "url": source.liveStreamURL(streamID: channel.streamID, format: .ts).absoluteString])
            }
            return ["channels": list]

        case "search":
            guard let database else { throw BridgeError("not started") }
            let results = try await SearchRepository(database: database).search(request["text"] as? String ?? "")
            return ["channels": results.channels.count, "programmes": results.programmes.count,
                    "movies": results.movies.count, "series": results.series.count]

        case "checkUpdates":
            // HTTPS through Swift's networking on Android (GitHub, the same check the app makes).
            guard let feed = UpdateFeed(gitHubRepository: "jacksonf-netizen/lumio"),
                  let current = SemanticVersion("0.0.1") else { throw BridgeError("bad feed") }
            switch try await UpdateChecker(feed: feed, currentVersion: current, transport: transport).check() {
            case .upToDate(let latest): return ["latest": latest.description]
            case .available(let update): return ["latest": update.version.description]
            }

        case "fetch":
            // Test build only: checks HTTPS certificate checking (bad certificates must fail).
            guard let url = (request["url"] as? String).flatMap(URL.init(string:)) else { throw BridgeError("no url") }
            do {
                let (_, response) = try await transport.data(for: URLRequest(url: url))
                return ["status": response.statusCode]
            } catch {
                // What the user would see: curl's failures mapped like the Mac's (XtreamError).
                return ["failed": XtreamError.from(error).description]
            }

        case "icuChecks":
            // Test build only: everything in the core that uses ICU data, on fixed inputs, so a
            // build with Lumio's trimmed ICU data can be compared with one carrying Swift's full set.
            var checks: [String] = []
            for code in ["UK", "US", "FR", "DE", "ES", "AR", "BEE", "LONGNAMEX"] {
                checks.append("displayName \(code) = \(RegionPrefix.displayName(code))")
            }
            for name in ["UK | Sports", "SWEDEN HD", "[US] News", "FR: Info", "IS| ISRAEL", "NORWAY SPORT"] {
                checks.append("detect \(name) = \(RegionPrefix.detect(name) ?? "nil")")
            }
            for name in ["BBC One HD", "Télé Québec FHD", "ＣＮＮ Ｉｎｔｅｒｎａｔｉｏｎａｌ", "UK: Sky Sports 1 UHD"] {
                checks.append("normalizedName \(name) = \(ChannelMatcher.normalizedName(name))")
            }
            let sorted = ["b", "A", "ä", "Z", "a"].sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            checks.append("sorted = \(sorted)")
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            checks.append("parseUTC = \(formatter.date(from: "2026-10-17 20:00:00")?.timeIntervalSince1970 ?? -1)")
            checks.append("redact = \(CredentialRedactor.redact("http://h.tv/live/user1/pass1/1.ts?username=user1&password=pass1", credentials: [ProviderCredentials(username: "user1", password: "pass1")]))")
            checks.append("duration = \(Duration.milliseconds(1234).formatted(.units(allowed: [.seconds, .milliseconds])))")
            checks.append("expired = \(XtreamError.accountExpired(Date(timeIntervalSince1970: 1_800_000_000)).description)")
            let london = TimeZone(identifier: "Europe/London")
            checks.append("london summer/winter = \(london?.secondsFromGMT(for: Date(timeIntervalSince1970: 1_784_000_000)) ?? -1)/\(london?.secondsFromGMT(for: Date(timeIntervalSince1970: 1_800_000_000)) ?? -1)")
            return ["checks": checks]

        case "memory":
            return ["residentBytes": Self.residentBytes()]

        default:
            throw BridgeError("unknown command \(command)")
        }
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return #"{"error":"encoding"}"# }
        return String(decoding: data, as: UTF8.self)
    }

    private static func residentBytes() -> Int {
        guard let statm = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8),
              let pages = statm.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { return 0 }
        return pages * Int(sysconf(Int32(_SC_PAGESIZE)))
    }
}

private final class ResultBox: @unchecked Sendable {
    var value = ""
}

private struct BridgeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
