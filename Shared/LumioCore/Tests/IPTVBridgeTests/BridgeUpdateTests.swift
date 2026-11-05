#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import IPTVBridge
import IPTVCore

/// The Android app's update requests: the check finds the APK, the signature check refuses a
/// changed file.
@Suite("Bridge: updates")
struct BridgeUpdateTests {
    final class Stub: HTTPTransport, @unchecked Sendable {
        let body: String
        init(_ body: String) { self.body = body }
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) { throw URLError(.unsupportedURL) }
    }

    private func call(_ bridge: BridgeCore, _ method: String, _ params: [String: Any]) async throws -> (result: [String: Any], error: String?) {
        let request = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        let reply = await bridge.handle(String(decoding: request, as: UTF8.self))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        return (object["result"] as? [String: Any] ?? [:], object["error"] as? String)
    }

    @Test func checkFindsTheAndroidBuild() async throws {
        let downloads = "https://github.com/owner/repo/releases/download/v0.3.0"
        let release = """
        {"tag_name": "v0.3.0", "name": "Lumio 0.3.0", "html_url": "https://github.com/owner/repo/releases/tag/v0.3.0",
         "body": "The guide scrolls faster.\\n\\nMore detail.\\n\\n---\\n- Android TV: faster guide.\\n\\n<!-- lumio-changed: mac=0.2.0 android=0.3.0 -->",
         "assets": [{"name": "Lumio-0.3.0.zip", "browser_download_url": "\(downloads)/Lumio-0.3.0.zip"},
                    {"name": "Lumio-AndroidTV.apk", "browser_download_url": "\(downloads)/Lumio-AndroidTV.apk"},
                    {"name": "Lumio-AndroidTV.apk.sig", "browser_download_url": "\(downloads)/Lumio-AndroidTV.apk.sig"}]}
        """
        let bridge = BridgeCore(environment: .preview(), updateTransport: Stub(release), events: { _ in })
        let (update, error) = try await call(bridge, "update.check", ["repository": "owner/repo", "version": "0.2.0"])
        #expect(error == nil)
        #expect(update["status"] as? String == "available")
        #expect(update["latest"] as? String == "0.3.0")
        #expect(update["summary"] as? String == "The guide scrolls faster.")
        #expect(update["apkURL"] as? String == "\(downloads)/Lumio-AndroidTV.apk")
        #expect(update["signatureURL"] as? String == "\(downloads)/Lumio-AndroidTV.apk.sig")
        // Already on the last Android change.
        let (same, _) = try await call(bridge, "update.check", ["repository": "owner/repo", "version": "0.3.0"])
        #expect(same["status"] as? String == "upToDate")
        // No feed configured.
        let (_, notConfigured) = try await call(bridge, "update.check", ["repository": "", "version": "0.2.0"])
        #expect(notConfigured != nil)
    }

    @Test func verifyRefusesAChangedFile() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString).apk")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("the real APK".utf8).write(to: file)
        let signature = try UpdateSignature.sign(fileAt: file, with: key)
        let bridge = BridgeCore(environment: .preview(), events: { _ in })

        let (_, ok) = try await call(bridge, "update.verify", ["file": file.path, "signature": signature, "publicKey": publicKey])
        #expect(ok == nil)
        try Data("something else".utf8).write(to: file)
        let (_, changed) = try await call(bridge, "update.verify", ["file": file.path, "signature": signature, "publicKey": publicKey])
        #expect(changed?.contains("doesn't match") == true)
        let (_, noKey) = try await call(bridge, "update.verify", ["file": file.path, "signature": signature, "publicKey": ""])
        #expect(noKey != nil)
    }
}
