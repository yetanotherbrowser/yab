import Foundation
import CryptoKit
import Testing
@testable import Fast

struct ChromiumExtensionPackagesTests {
    private let id = "dbepggeogbaibhgnhhndojpepiihcmeb"
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("evals/extensions/frozen-vimium/dbepggeogbaibhgnhhndojpepiihcmeb-3198c26aa719be462dea585050fbed9b8b80628d57ea88a113babf5334c5517c.crx")
    }

    @Test func signedPackageRetainsStoreIdentity() throws {
        let crx = try Data(contentsOf: fixture)
        let package = try Crx.verifiedPackage(crx, id: id)
        #expect(Crx.letters(Array(SHA256.hash(data: package.publicKey).prefix(16))) == id)
        #expect(package.zip == (try Crx.verifiedZip(crx, id: id)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-package-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try ChromiumExtensionPackages.prepare(crx, id: id, root: root)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as! [String: Any]
        #expect(manifest["key"] as? String == package.publicKey.base64EncodedString())
        #expect(manifest["name"] as? String == "Vimium")
        #expect(try ChromiumExtensionPackages.prepare(crx, id: id, root: root) == folder)
    }

    @Test func tamperingAndWrongIDNeverCreateAnInstallFolder() throws {
        let original = try Data(contentsOf: fixture)
        var tampered = original
        tampered[tampered.count - 1] ^= 1
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-package-refused-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (bytes, requestedID) in [(tampered, id), (original, String(repeating: "a", count: 32))] {
            do {
                _ = try ChromiumExtensionPackages.prepare(bytes, id: requestedID, root: root)
                Issue.record("An unauthenticated package was accepted")
            } catch { #expect(error is Crx.Refused) }
            #expect(!FileManager.default.fileExists(atPath: root.path))
        }
    }

    @Test func theStoreIsAskedAsThePinnedEngine() throws {
        let fetch = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/cef/fetch.sh")
        let script = try String(contentsOf: fetch, encoding: .utf8)
        let pin = try #require(script.firstMatch(of: #/VERSION = '[^']*chromium-([0-9.]+)'/#))
        #expect(ChromiumExtensionPackages.engineVersion == String(pin.1))
    }
}
