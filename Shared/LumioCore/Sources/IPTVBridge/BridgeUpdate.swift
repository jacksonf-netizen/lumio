import Foundation
import IPTVCore

// Updates over the bridge: `update.check` asks GitHub for the latest release, as the Mac does, but
// for the Android build (Lumio-AndroidTV.apk and its .sig); `update.verify` checks a downloaded APK
// against its signature with the same Ed25519 key as the Mac (LumioUpdate). The app downloads the
// files itself (with progress) and hands a verified APK to Android's PackageInstaller.

public struct UpdateDTO: Codable, Equatable, Sendable {
    /// upToDate or available.
    public var status: String
    /// The newest published version.
    public var latest: String
    public var title: String?
    /// The first paragraph of the release notes: all the update prompt shows.
    public var summary: String?
    public var pageURL: String?
    public var apkURL: String?
    public var signatureURL: String?
}

extension BridgeCore {
    func updateRequest(_ method: String, _ params: Params) async throws -> any Encodable {
        switch method {
        case "update.check":
            // The app passes its own build's settings: the repository ("owner/repo") and its version.
            struct P: Decodable { var repository: String; var version: String }
            let p = try params.decode(P.self)
            guard let feed = UpdateFeed(gitHubRepository: p.repository) else { throw BridgeError(UpdateError.notConfigured.localizedDescription) }
            guard let current = SemanticVersion(p.version) else { throw BridgeError("This build's version (\(p.version)) isn't a version number.") }
            let result: UpdateCheckResult
            do {
                result = try await UpdateChecker(feed: feed, currentVersion: current, platform: .android,
                                                 transport: updateTransport).check()
            } catch {
                throw BridgeError(error.localizedDescription)
            }
            switch result {
            case .upToDate(let latest):
                return UpdateDTO(status: "upToDate", latest: latest.description)
            case .available(let update):
                return UpdateDTO(status: "available", latest: update.version.description, title: update.title,
                                 summary: Self.summary(of: update.notes), pageURL: update.pageURL.absoluteString,
                                 apkURL: update.archiveURL?.absoluteString, signatureURL: update.signatureURL?.absoluteString)
            }

        case "update.verify":
            // `file`: the downloaded APK; `signature`: the .sig file's text; `publicKey`: the build's key.
            struct P: Decodable { var file: String; var signature: String; var publicKey: String }
            let p = try params.decode(P.self)
            do {
                try UpdateSignature.verify(fileAt: URL(fileURLWithPath: p.file), signature: p.signature, publicKey: p.publicKey)
            } catch {
                throw BridgeError(error.localizedDescription)
            }
            return Empty()

        default:
            throw BridgeError("Unknown request \(method).")
        }
    }

    /// The release notes' first paragraph, above the "---" that starts the details.
    static func summary(of notes: String) -> String {
        let top = notes.components(separatedBy: "\n---").first ?? ""
        return top.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n").first ?? ""
    }
}
