// Signs Lumio update archives, so the app only installs updates that came from you.
//
//   swift Tools/Release/sign_update.swift generate      Make the key pair (once). The private key
//                                                       goes into your login Keychain; the public
//                                                       key is printed for UPDATE_PUBLIC_KEY in
//                                                       project.yml.
//   swift Tools/Release/sign_update.swift public-key    Print the public key again.
//   swift Tools/Release/sign_update.swift sign FILE     Print FILE's signature (base64).
//
// The private key never leaves the Keychain (item "Lumio update signing key"), and is never
// written to the repository. Back it up (Keychain Access → File → Export Items…, or copy the
// password into your password manager): without it you can't sign updates, and friends would have
// to download the next version by hand.
//
// Must match LumioUpdate/UpdateSignature.swift: Ed25519 over "lumio-update-v1" + SHA-256(file).

import CryptoKit
import Foundation
import Security

let service = "Lumio update signing key"
let account = "release"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sign_update: \(message)\n".utf8))
    exit(1)
}

func storedKey() -> Curve25519.Signing.PrivateKey? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data,
          let raw = Data(base64Encoded: data), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("couldn't read the signing key from the Keychain (status \(status))") }
    return key
}

func publicKey(_ key: Curve25519.Signing.PrivateKey) -> String {
    key.publicKey.rawRepresentation.base64EncodedString()
}

func digest(of url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return Data(hasher.finalize())
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "generate":
    if storedKey() != nil { fail("a signing key already exists; `public-key` prints it. Delete it in Keychain Access first to replace it.") }
    let key = Curve25519.Signing.PrivateKey()
    let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                               kSecAttrAccount as String: account, kSecAttrLabel as String: service,
                               kSecValueData as String: Data(key.rawRepresentation.base64EncodedString().utf8)]
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { fail("couldn't save the key to the Keychain (status \(status))") }
    print(publicKey(key))
case "public-key":
    guard let key = storedKey() else { fail("no signing key yet; run `generate` first") }
    print(publicKey(key))
case "sign":
    guard arguments.count == 2, let path = arguments.last else { fail("usage: sign FILE") }
    guard let key = storedKey() else { fail("no signing key yet; run `generate` first") }
    do {
        let message = Data("lumio-update-v1".utf8) + (try digest(of: URL(fileURLWithPath: path)))
        print(try key.signature(for: message).base64EncodedString())
    } catch {
        fail("couldn't sign \(path): \(error.localizedDescription)")
    }
default:
    fail("usage: sign_update.swift generate | public-key | sign FILE")
}
