import Foundation

/// Name of the installer XPC service inside Lumio.app (Contents/XPCServices). The app is sandboxed
/// and can't replace itself, so this small unsandboxed helper does it, and only for a signed update.
public let installerServiceName = "com.jackson.iptvstreamer.installer"

/// What the app asks the installer service to do.
@objc public protocol InstallerServiceProtocol {
    /// Installs the signed archive at `archivePath` over the app the service lives in. Replies with
    /// the installed version, or an error message.
    func installUpdate(archivePath: String, signature: String, reply: @escaping @Sendable (String?, String?) -> Void)
}

/// Replaces an installed app with the one in a signed update archive (.zip).
///
/// Every check happens here, in the installer service, whatever the app already checked:
/// 1. The archive is copied somewhere only the installer writes to, so it can't change after checking.
/// 2. Its signature must match the installed app's update key.
/// 3. It must hold exactly one app, with the same bundle identifier and a newer version.
/// 4. The app's code signature must be intact (nothing altered after it was built).
/// Only then is the installed app swapped for the new one, in one rename. The running app keeps
/// running from the old copy until it relaunches.
public struct UpdateInstaller: Sendable {
    public enum Failure: Error, LocalizedError, Equatable {
        case translocated
        case notWritable(String)
        case tooLarge
        case noApp
        case wrongApp(String)
        case notNewer(String)
        case damaged(String)
        case swapFailed(String)

        public var errorDescription: String? {
            switch self {
            case .translocated:
                "Lumio is running from a temporary location macOS uses for downloaded apps. Move Lumio to the Applications folder, open it from there, and try again."
            case .notWritable(let folder):
                "Lumio can't replace itself in “\(folder)” (your account can't change that folder). Download the update and install it by hand."
            case .tooLarge: "The update is unexpectedly large, so it wasn't installed."
            case .noApp: "The update doesn't contain the app."
            case .wrongApp(let id): "The update contains a different app (\(id)), so it wasn't installed."
            case .notNewer(let version): "The update (\(version)) isn't newer than this version, so it wasn't installed."
            case .damaged(let detail): "The update is damaged, so it wasn't installed (\(detail))."
            case .swapFailed(let detail): "The update couldn't be put in place (\(detail)). Lumio wasn't changed."
            }
        }
    }

    /// The installed app to replace.
    public var appURL: URL
    public var bundleIdentifier: String
    public var currentVersion: SemanticVersion
    /// Base64 Ed25519 public key (`LumioUpdatePublicKey`).
    public var publicKey: String
    public var maxArchiveBytes = 1 << 30
    /// Checks the new app's code signature. Replaceable for tests, whose fake apps aren't signed.
    public var verifyCodeSignature: @Sendable (URL) throws -> Void = { app in
        try UpdateInstaller.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    public init(appURL: URL, bundleIdentifier: String, currentVersion: SemanticVersion, publicKey: String) {
        self.appURL = appURL
        self.bundleIdentifier = bundleIdentifier
        self.currentVersion = currentVersion
        self.publicKey = publicKey
    }

    /// Reads the identifier, version and key from an installed app's Info.plist.
    public init(installedApp appURL: URL) throws {
        let info = try Self.info(of: appURL)
        guard let identifier = info["CFBundleIdentifier"] as? String,
              let version = (info["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init)
        else { throw Failure.damaged("the installed app's Info.plist is incomplete") }
        self.init(appURL: appURL, bundleIdentifier: identifier, currentVersion: version,
                  publicKey: info["LumioUpdatePublicKey"] as? String ?? "")
    }

    /// Installs the update and returns its version.
    @discardableResult
    public func install(archive: URL, signature: String) throws -> SemanticVersion {
        let fileManager = FileManager.default
        guard !appURL.path.contains("/AppTranslocation/") else { throw Failure.translocated }
        let folder = appURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: folder.path) else { throw Failure.notWritable(folder.path) }

        // A private working folder on the same disk as the app, so the final swap is one rename.
        let staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
        defer { try? fileManager.removeItem(at: staging) }

        let size = (try? fileManager.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
        guard size <= maxArchiveBytes else { throw Failure.tooLarge }
        let copy = staging.appendingPathComponent("update.zip")
        try fileManager.copyItem(at: archive, to: copy)
        try UpdateSignature.verify(fileAt: copy, signature: signature, publicKey: publicKey)

        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        do {
            try Self.run("/usr/bin/ditto", ["-x", "-k", copy.path, unpacked.path])
        } catch {
            throw Failure.damaged("couldn't unpack it")
        }
        let apps = (try? fileManager.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1, let newApp = apps.first else { throw Failure.noApp }

        let info = try Self.info(of: newApp)
        let identifier = info["CFBundleIdentifier"] as? String ?? "?"
        guard identifier == bundleIdentifier else { throw Failure.wrongApp(identifier) }
        let versionText = info["CFBundleShortVersionString"] as? String ?? "?"
        guard let version = SemanticVersion(versionText), version > currentVersion else { throw Failure.notNewer(versionText) }
        guard let executable = info["CFBundleExecutable"] as? String,
              fileManager.isExecutableFile(atPath: newApp.appendingPathComponent("Contents/MacOS/\(executable)").path)
        else { throw Failure.damaged("the app has no program inside") }
        do {
            try verifyCodeSignature(newApp)
        } catch {
            throw Failure.damaged("its code signature doesn't check out")
        }
        // The archive was downloaded, so macOS marked it as quarantined. Its signature has been
        // checked against the release key above, which is what the quarantine prompt is for.
        try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        // Swap: installed app aside, new app in, old copy deleted with the working folder.
        let previous = staging.appendingPathComponent("previous.app")
        do {
            try fileManager.moveItem(at: appURL, to: previous)
        } catch {
            throw Failure.swapFailed(error.localizedDescription)
        }
        do {
            try fileManager.moveItem(at: newApp, to: appURL)
        } catch {
            try? fileManager.moveItem(at: previous, to: appURL)
            throw Failure.swapFailed(error.localizedDescription)
        }
        return version
    }

    static func info(of app: URL) throws -> [String: Any] {
        let url = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw Failure.damaged("no readable Info.plist") }
        return plist
    }

    /// Runs a system tool and waits; throws when it fails.
    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.damaged("\(URL(fileURLWithPath: tool).lastPathComponent) exited with \(process.terminationStatus)")
        }
    }
}
