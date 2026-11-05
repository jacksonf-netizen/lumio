// The Android app's signing key: every APK Lumio publishes is signed with it, and Android only
// installs an update signed with the same key as the installed app.
//
//   swift AndroidTV/Tools/apk_signing_key.swift generate      Make the key (once). It goes into your
//                                                             login Keychain, never into a file here.
//   swift AndroidTV/Tools/apk_signing_key.swift fingerprint   Print the certificate's SHA-256 (also in
//                                                             AndroidTV/signing-certificate.txt).
//   swift AndroidTV/Tools/apk_signing_key.swift sign IN OUT   Sign an APK (v3 signature scheme).
//   swift AndroidTV/Tools/apk_signing_key.swift backup FOLDER Write the keystore and its password to
//                                                             FOLDER (a USB stick, say) for the
//                                                             offline backup.
//
// IF THIS KEY IS LOST, NO INSTALLED COPY CAN EVER UPDATE AGAIN: everyone would have to uninstall
// Lumio (losing their settings) and install it afresh. Make the backup right after `generate`.
//
// The keystore (PKCS12, RSA 4096, valid 100 years) and a random password are kept together in one
// Keychain item ("Lumio Android signing key"). Signing writes the keystore to a private temporary
// folder for the moment apksigner needs it and deletes it straight after; the password reaches
// keytool and apksigner through an environment variable, never the command line.
// Needs JAVA_HOME and ANDROID_HOME (source AndroidTV/Tools/env.sh).

import Foundation
import Security

let service = "Lumio Android signing key"
let account = "keystore"
let alias = "lumio"

struct Stored: Codable {
    var keystore: String // base64 PKCS12
    var password: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("apk_signing_key: \(message)\n".utf8))
    exit(1)
}

func environment(_ name: String) -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { fail("\(name) isn't set; run `source AndroidTV/Tools/env.sh` first") }
    return value
}

func stored() -> Stored? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data, let item = try? JSONDecoder().decode(Stored.self, from: data)
    else { fail("couldn't read the signing key from the Keychain (status \(status))") }
    return item
}

/// Runs a tool with the keystore password in LUMIO_KS_PASS. Returns its output.
@discardableResult
func run(_ tool: String, _ arguments: [String], password: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    env["LUMIO_KS_PASS"] = password
    process.environment = env
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { fail("couldn't run \(tool): \(error.localizedDescription)") }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("\((tool as NSString).lastPathComponent) failed:\n\(output)") }
    return output
}

/// A folder only this user can read, removed when `body` returns.
func withPrivateFolder<T>(_ body: (URL) -> T) -> T {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lumio-key-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    } catch { fail("couldn't make a private folder: \(error.localizedDescription)") }
    defer { try? FileManager.default.removeItem(at: folder) }
    return body(folder)
}

func writeKeystore(_ item: Stored, in folder: URL) -> URL {
    let file = folder.appendingPathComponent("lumio.p12")
    guard let data = Data(base64Encoded: item.keystore),
          FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    else { fail("couldn't write the keystore to a temporary file") }
    return file
}

var keytool: String { environment("JAVA_HOME") + "/bin/keytool" }

var apksigner: String {
    let tools = URL(fileURLWithPath: environment("ANDROID_HOME")).appendingPathComponent("build-tools")
    let versions = (try? FileManager.default.contentsOfDirectory(atPath: tools.path))?
        .sorted { $0.compare($1, options: .numeric) == .orderedAscending } ?? []
    guard let newest = versions.last else { fail("no Android build-tools found in \(tools.path)") }
    return tools.appendingPathComponent(newest).appendingPathComponent("apksigner").path
}

func fingerprint(_ item: Stored) -> String {
    withPrivateFolder { folder in
        let output = run(keytool, ["-list", "-v", "-keystore", writeKeystore(item, in: folder).path, "-storetype", "PKCS12",
                                   "-storepass:env", "LUMIO_KS_PASS", "-alias", alias], password: item.password)
        guard let line = output.split(separator: "\n").first(where: { $0.contains("SHA256:") }) else { fail("keytool printed no SHA-256 fingerprint") }
        return line.components(separatedBy: "SHA256:").last!.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "").lowercased()
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "generate":
    if stored() != nil { fail("a signing key already exists; `fingerprint` prints it. Replacing it would stop every installed copy from updating.") }
    var bytes = [UInt8](repeating: 0, count: 24)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { fail("no random bytes") }
    let password = Data(bytes).base64EncodedString()
    let item: Stored = withPrivateFolder { folder in
        let file = folder.appendingPathComponent("lumio.p12")
        run(keytool, ["-genkeypair", "-keystore", file.path, "-storetype", "PKCS12", "-alias", alias, "-keyalg", "RSA",
                      "-keysize", "4096", "-validity", "36500", "-dname", "CN=Lumio, O=Lumio",
                      "-storepass:env", "LUMIO_KS_PASS", "-keypass:env", "LUMIO_KS_PASS"], password: password)
        guard let data = FileManager.default.contents(atPath: file.path) else { fail("keytool made no keystore") }
        return Stored(keystore: data.base64EncodedString(), password: password)
    }
    let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                              kSecAttrAccount as String: account, kSecAttrLabel as String: service,
                              kSecValueData as String: try! JSONEncoder().encode(item)]
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { fail("couldn't save the key to the Keychain (status \(status))") }
    print(fingerprint(item))

case "fingerprint":
    guard let item = stored() else { fail("no signing key yet; run `generate` first") }
    print(fingerprint(item))

case "sign":
    guard arguments.count == 3 else { fail("usage: sign IN.apk OUT.apk") }
    guard let item = stored() else { fail("no signing key yet; run `generate` first") }
    _ = withPrivateFolder { folder in
        // minSdk 28: the v3 scheme (it allows rotating the key later). apksigner adds v2 only for
        // older Android versions, so with minSdk 28 it leaves it out; no v1 (JAR) signature.
        run(apksigner, ["sign", "--ks", writeKeystore(item, in: folder).path, "--ks-type", "PKCS12", "--ks-key-alias", alias,
                        "--ks-pass", "env:LUMIO_KS_PASS", "--v1-signing-enabled", "false", "--v2-signing-enabled", "true",
                        "--v3-signing-enabled", "true", "--out", arguments[2], arguments[1]], password: item.password)
    }

case "backup":
    guard arguments.count == 2 else { fail("usage: backup FOLDER") }
    guard let item = stored() else { fail("no signing key yet; run `generate` first") }
    let folder = URL(fileURLWithPath: arguments[1])
    let keystore = folder.appendingPathComponent("lumio-android-signing.p12")
    let note = folder.appendingPathComponent("lumio-android-signing-README.txt")
    guard !FileManager.default.fileExists(atPath: keystore.path) else { fail("\(keystore.path) already exists") }
    guard let data = Data(base64Encoded: item.keystore),
          FileManager.default.createFile(atPath: keystore.path, contents: data, attributes: [.posixPermissions: 0o600]),
          FileManager.default.createFile(atPath: note.path, contents: Data("""
            Lumio for Android TV: the APK signing key. Keep this somewhere safe and offline.
            Without it no installed copy of Lumio can update.

            Keystore: lumio-android-signing.p12 (PKCS12), key alias "\(alias)"
            Password (keystore and key): \(item.password)
            Certificate SHA-256: \(fingerprint(item))

            To put it back into a Mac's Keychain, ask Claude, or see AndroidTV/Tools/apk_signing_key.swift.

            """.utf8), attributes: [.posixPermissions: 0o600])
    else { fail("couldn't write the backup to \(folder.path)") }
    print("Wrote \(keystore.path) and \(note.path)")

default:
    fail("usage: apk_signing_key.swift generate | fingerprint | sign IN OUT | backup FOLDER")
}
