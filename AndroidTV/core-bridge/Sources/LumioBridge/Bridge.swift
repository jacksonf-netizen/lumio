#if canImport(Android)
import Android
#endif
import CJNI
import Dispatch
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IPTVBridge
import IPTVCore

// The Swift half of liblumiocore.so's bridge. cjni.c receives the Kotlin calls and calls these two
// functions; everything else happens in the shared IPTVBridge (Shared/LumioCore), so the requests
// and their rules are the same ones the Mac tests exercise. Only `debug.*` requests are handled
// here: checks of this Android build itself.

private let state = BridgeState()

private final class BridgeState: @unchecked Sendable {
    private let lock = NSLock()
    private var bridge: BridgeCore?
    var core: BridgeCore? {
        get { lock.withLock { bridge } }
        set { lock.withLock { bridge = newValue } }
    }
}

@_cdecl("lumio_swift_start")
public func lumio_swift_start(_ databasePath: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard state.core == nil else { return nil }
    guard let databasePath else { return strdup("No database path.") }
    let secrets = CallbackSecretStore(
        save: { id, value in lumio_secret_save(id, value) },
        load: { id in
            guard let value = lumio_secret_load(id) else { return nil }
            defer { free(value) }
            return String(cString: value)
        },
        delete: { id in lumio_secret_delete(id) })
    do {
        let core = try BridgeCore.open(
            databasePath: String(cString: databasePath), secrets: secrets,
            playerCommands: { json in
                guard let reply = lumio_player_command(json) else { return nil }
                defer { free(reply) }
                return String(cString: reply)
            },
            events: { json in lumio_emit_event(json) })
        state.core = core
        Task { await core.start() }
        return nil
    } catch {
        return strdup(AppEnvironment.userMessage(for: error))
    }
}

@_cdecl("lumio_swift_call")
public func lumio_swift_call(_ request: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let text = request.map { String(cString: $0) } ?? ""
    let reply = waitFor {
        if let debug = await Diagnostics.handle(text) { return debug }
        guard let core = state.core else { return #"{"error":"The core hasn't started."}"# }
        return await core.handle(text)
    }
    return strdup(reply)
}

@_cdecl("lumio_swift_player_event")
public func lumio_swift_player_event(_ json: UnsafePointer<CChar>?) {
    guard let json else { return }
    EngineEvents.shared.deliver(String(cString: json))
}

/// Runs `work` on Swift's thread pool and blocks the calling (Kotlin background) thread until it's done.
private func waitFor(_ work: @escaping @Sendable () async -> String) -> String {
    let box = ReplyBox()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = await work()
        done.signal()
    }
    done.wait()
    return box.value
}

private final class ReplyBox: @unchecked Sendable {
    var value = ""
}

// MARK: Diagnostics

/// Checks of this Android build: what the trimmed ICU data gives (compare with a LUMIO_FULL_ICU=1
/// build), memory, and HTTPS failures. Not used by the app's screens.
private enum Diagnostics {
    static func handle(_ text: String) async -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let method = object["method"] as? String, method.hasPrefix("debug.") else { return nil }
        let params = object["params"] as? [String: Any] ?? [:]
        let result: Any
        switch method {
        case "debug.icuChecks": result = icuChecks()
        case "debug.memory": result = ["residentBytes": residentBytes()]
        case "debug.fetch": result = await fetch(params["url"] as? String ?? "")
        default: return encode(["error": "Unknown request \(method)."])
        }
        return encode(["result": result])
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return #"{"error":"encoding"}"# }
        return String(decoding: data, as: UTF8.self)
    }

    /// Everything in the core that uses ICU data, on fixed inputs.
    private static func icuChecks() -> [String] {
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
        checks.append("duration = \(Duration.milliseconds(1234).formatted(.units(allowed: [.seconds, .milliseconds])))")
        checks.append("expired = \(XtreamError.accountExpired(Date(timeIntervalSince1970: 1_800_000_000)).description)")
        checks.append("count = \(84123.formatted())")
        let london = TimeZone(identifier: "Europe/London")
        checks.append("london summer/winter = \(london?.secondsFromGMT(for: Date(timeIntervalSince1970: 1_784_000_000)) ?? -1)/\(london?.secondsFromGMT(for: Date(timeIntervalSince1970: 1_800_000_000)) ?? -1)")
        return checks
    }

    /// What the user would see for a request to `url` (bad certificates must be refused).
    private static func fetch(_ url: String) async -> [String: Any] {
        guard let url = URL(string: url) else { return ["failed": "bad URL"] }
        do {
            let (_, response) = try await URLSessionTransport().data(for: URLRequest(url: url))
            return ["status": response.statusCode]
        } catch {
            return ["failed": XtreamError.from(error).description]
        }
    }

    /// Int64: 2 GB and more doesn't fit a 32-bit `Int` (armv7), where the multiplication would trap.
    private static func residentBytes() -> Int64 {
        guard let statm = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8),
              let pages = statm.split(separator: " ").dropFirst().first.flatMap({ Int64($0) }) else { return 0 }
        return pages * Int64(sysconf(Int32(_SC_PAGESIZE)))
    }
}
