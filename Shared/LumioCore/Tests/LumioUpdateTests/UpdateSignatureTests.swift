#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Testing
@testable import LumioUpdate

/// Update signatures, checked by every Lumio app before it installs anything.
@Suite("Update signatures")
struct UpdateSignatureTests {
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    @Test func signaturesMatchOnlyTheSignedFileAndKey() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("LumioUpdateTests-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: file) }
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
}
