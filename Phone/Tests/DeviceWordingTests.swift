import SyncKit
import UIKit
import XCTest
@testable import YabPhone

/// Words shown on an iPad name an iPad: the Sync identity error, what an
/// extension can't do here, and another device listed without a name.
@MainActor
final class DeviceWordingTests: XCTestCase {
    func testAnIPadIsCalledAnIPad() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "an iPad's words")
        let identity = try XCTUnwrap(SyncKeychain.Failure.deviceIdentity.errorDescription)
        XCTAssertTrue(identity.hasPrefix("This iPad "), identity)

        let worker: [String: Any] = ["manifest_version": 3, "background": ["service_worker": "bg.js"]]
        var reasons = [ExtensionCompatibility.verdict(id: "x", manifest: worker, entitled: false).reason]
        var native = worker; native["permissions"] = ["nativeMessaging"]
        reasons.append(ExtensionCompatibility.verdict(id: "x", manifest: native, entitled: true).reason)
        reasons.append(ExtensionCompatibility.verdict(id: "liecbddmkiiihnedobmlmillhodjkdmb", manifest: worker, entitled: true).reason)
        for reason in reasons {
            XCTAssertTrue(reason.contains("iPad"), reason)
            XCTAssertFalse(reason.contains("iPhone"), reason)
        }

        let devices = SettingsDevice.list([SyncDevice(id: "tablet", name: "", model: "iPad16,3", lastSeen: nil)], own: "me", now: Date())
        XCTAssertEqual(devices.first?.name, "iPad")
    }
}
