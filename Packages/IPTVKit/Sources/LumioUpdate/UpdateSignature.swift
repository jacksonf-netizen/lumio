import CryptoKit
import Foundation

/// Signatures on update archives.
///
/// Each release's .zip is signed with the developer's private Ed25519 key (kept in their Keychain,
/// never in the repository; see Tools/Release/sign_update.swift). The app carries the matching
/// public key (`LumioUpdatePublicKey` in Info.plist) and installs only archives whose signature
/// checks out, so an update can't be swapped for something else on the way, or on GitHub.
///
/// What's signed is "lumio-update-v1" followed by the archive's SHA-256, so large archives are
/// hashed in pieces rather than read into memory.
public enum UpdateSignature {
    public enum Failure: Error, LocalizedError, Equatable {
        case missingPublicKey
        case invalidPublicKey
        case invalidSignature
        case mismatch

        public var errorDescription: String? {
            switch self {
            case .missingPublicKey: "This build has no update key, so it can't check that an update is genuine."
            case .invalidPublicKey: "This build's update key is unreadable."
            case .invalidSignature: "The update's signature is unreadable."
            case .mismatch: "The update's signature doesn't match. It wasn't installed."
            }
        }
    }

    static let context = Data("lumio-update-v1".utf8)

    /// SHA-256 of a file, read 1 MB at a time.
    public static func digest(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    /// Throws unless `signature` (base64) is a valid signature of the file by `publicKey` (base64).
    public static func verify(fileAt url: URL, signature: String, publicKey: String) throws {
        let keyText = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyText.isEmpty else { throw Failure.missingPublicKey }
        guard let keyData = Data(base64Encoded: keyText),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { throw Failure.invalidPublicKey }
        guard let signatureData = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              signatureData.count == 64
        else { throw Failure.invalidSignature }
        guard key.isValidSignature(signatureData, for: context + (try digest(of: url))) else { throw Failure.mismatch }
    }

    /// Signs a file (base64), as the release tool does. Used by tests.
    public static func sign(fileAt url: URL, with key: Curve25519.Signing.PrivateKey) throws -> String {
        try key.signature(for: context + digest(of: url)).base64EncodedString()
    }
}
