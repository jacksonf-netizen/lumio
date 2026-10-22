import CryptoKit
import Foundation
import Testing
@testable import LumioUpdate

@Suite("Installing updates")
struct UpdateInstallerTests {
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LumioUpdateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// A minimal app bundle: Info.plist plus an executable that prints its version.
    func makeApp(at url: URL, version: String, identifier: String = "com.example.lumio") throws {
        let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                                   "CFBundleExecutable": "Lumio", "LumioUpdatePublicKey": publicKey]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        let program = macOS.appendingPathComponent("Lumio")
        try Data("#!/bin/sh\necho \(version)\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
    }

    /// A release archive (as make_release.sh builds it) and its signature.
    func makeRelease(version: String, identifier: String = "com.example.lumio") throws -> (URL, String) {
        let build = root.appendingPathComponent("build-\(UUID().uuidString)/Lumio.app", isDirectory: true)
        try makeApp(at: build, version: version, identifier: identifier)
        let zip = root.appendingPathComponent("Lumio-\(version)-\(UUID().uuidString).zip")
        try UpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", build.path, zip.path])
        return (zip, try UpdateSignature.sign(fileAt: zip, with: key))
    }

    func installed() throws -> (URL, UpdateInstaller) {
        let app = root.appendingPathComponent("Applications/Lumio.app", isDirectory: true)
        try makeApp(at: app, version: "0.1.0")
        var installer = try UpdateInstaller(installedApp: app)
        installer.verifyCodeSignature = { _ in }
        return (app, installer)
    }

    func installedVersion(_ app: URL) throws -> String? {
        try UpdateInstaller.info(of: app)["CFBundleShortVersionString"] as? String
    }

    @Test func signaturesMatchOnlyTheSignedFileAndKey() throws {
        let file = root.appendingPathComponent("file.bin")
        try Data(repeating: 7, count: 3 << 20).write(to: file)
        let signature = try UpdateSignature.sign(fileAt: file, with: key)
        try UpdateSignature.verify(fileAt: file, signature: signature, publicKey: publicKey)

        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(throws: UpdateSignature.Failure.mismatch) { try UpdateSignature.verify(fileAt: file, signature: signature, publicKey: other) }
        #expect(throws: UpdateSignature.Failure.missingPublicKey) { try UpdateSignature.verify(fileAt: file, signature: signature, publicKey: "") }
        #expect(throws: UpdateSignature.Failure.invalidSignature) { try UpdateSignature.verify(fileAt: file, signature: "nope", publicKey: publicKey) }
        // One changed byte.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: 2 << 20)
        handle.write(Data([8]))
        try handle.close()
        #expect(throws: UpdateSignature.Failure.mismatch) { try UpdateSignature.verify(fileAt: file, signature: signature, publicKey: publicKey) }
    }

    @Test func installsASignedNewerVersion() throws {
        let (app, installer) = try installed()
        let (zip, signature) = try makeRelease(version: "0.2.0")
        #expect(try installer.install(archive: zip, signature: signature) == SemanticVersion("0.2.0"))
        #expect(try installedVersion(app) == "0.2.0")
        #expect(FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/Lumio").path))
        // Nothing left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path) == ["Lumio.app"])
    }

    /// The Dock's pinned icon follows the app folder, so the folder itself must stay the same one.
    @Test func keepsTheAppFolderItself() throws {
        let (app, installer) = try installed()
        let folderID = { try FileManager.default.attributesOfItem(atPath: app.path)[.systemFileNumber] as? Int }
        let before = try folderID()
        let (zip, signature) = try makeRelease(version: "0.2.0")
        try installer.install(archive: zip, signature: signature)
        #expect(try installedVersion(app) == "0.2.0")
        #expect(try folderID() == before)
    }

    /// The app hands the installer service an open file rather than a path.
    @Test func installsFromAnOpenFile() throws {
        let (app, installer) = try installed()
        let (zip, signature) = try makeRelease(version: "0.2.0")
        let handle = try FileHandle(forReadingFrom: zip)
        defer { try? handle.close() }
        _ = try handle.read(upToCount: 100) // Read from the start whatever the position.
        #expect(try installer.install(archive: handle, signature: signature) == SemanticVersion("0.2.0"))
        #expect(try installedVersion(app) == "0.2.0")

        var small = try installed().1
        small.maxArchiveBytes = 100
        let (bigger, biggerSignature) = try makeRelease(version: "0.3.0")
        #expect(throws: UpdateInstaller.Failure.tooLarge) {
            try small.install(archive: try FileHandle(forReadingFrom: bigger), signature: biggerSignature)
        }
    }

    @Test func refusesAnythingElseAndLeavesTheAppAlone() throws {
        let (app, installer) = try installed()
        let (zip, signature) = try makeRelease(version: "0.2.0")
        let (otherZip, otherSignature) = try makeRelease(version: "0.3.0")

        // Signature of a different archive.
        #expect(throws: UpdateSignature.Failure.mismatch) { try installer.install(archive: zip, signature: otherSignature) }
        // Signed by someone else.
        let stranger = try UpdateSignature.sign(fileAt: otherZip, with: Curve25519.Signing.PrivateKey())
        #expect(throws: UpdateSignature.Failure.mismatch) { try installer.install(archive: otherZip, signature: stranger) }
        // Same or older version (e.g. an old release served again).
        let (old, oldSignature) = try makeRelease(version: "0.1.0")
        #expect(throws: UpdateInstaller.Failure.notNewer("0.1.0")) { try installer.install(archive: old, signature: oldSignature) }
        // A different app, even when signed.
        let (wrong, wrongSignature) = try makeRelease(version: "0.4.0", identifier: "com.example.other")
        #expect(throws: UpdateInstaller.Failure.wrongApp("com.example.other")) { try installer.install(archive: wrong, signature: wrongSignature) }
        // A broken code signature.
        var strict = installer
        strict.verifyCodeSignature = { _ in throw UpdateInstaller.Failure.damaged("test") }
        #expect(throws: UpdateInstaller.Failure.self) { try strict.install(archive: zip, signature: signature) }
        // Not a zip at all.
        let junk = root.appendingPathComponent("junk.zip")
        try Data("not a zip".utf8).write(to: junk)
        #expect(throws: UpdateInstaller.Failure.self) {
            try installer.install(archive: junk, signature: try UpdateSignature.sign(fileAt: junk, with: key))
        }
        #expect(try installedVersion(app) == "0.1.0")
        #expect(try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path) == ["Lumio.app"])
    }

    @Test func translocatedCopiesAreNotUpdated() throws {
        let (zip, signature) = try makeRelease(version: "0.2.0")
        var installer = UpdateInstaller(appURL: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Lumio.app"),
                                        bundleIdentifier: "com.example.lumio", currentVersion: SemanticVersion("0.1.0")!, publicKey: publicKey)
        installer.verifyCodeSignature = { _ in }
        #expect(throws: UpdateInstaller.Failure.translocated) { try installer.install(archive: zip, signature: signature) }
    }
}
