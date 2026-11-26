import Foundation
import WebKit

/// Whether an extension works on Yab for iPhone, said before it is added:
/// what the probe found for the store's best-known ones (ExtensionsUITests,
/// docs/iphone-extensions.md), and for the rest what its manifest asks for.
/// One that can't work isn't offered; one that partly works says what not.
enum ExtensionCompatibility {
    enum Kind: String { case works, limited, blocked }

    struct Verdict: Equatable {
        let kind: Kind
        /// In the person's words; empty when it simply works.
        let reason: String
    }

    /// Apple's browser entitlement, which WKWebView needs for service
    /// workers, a Manifest V3 extension's background. Set by the build
    /// (Info.plist YabBrowserEntitlement): granted 2026-10-12, on in every
    /// build; a build without it still says why an extension can't run.
    static var hasBrowserEntitlement: Bool {
        let value = Bundle.main.object(forInfoDictionaryKey: "YabBrowserEntitlement")
        return value as? Bool == true || (value as? String)?.uppercased() == "YES"
    }

    static let waitingForApple = "It runs in the background, which Yab for \(DeviceWord.name) can do once Apple grants it the browser permission."

    /// What the probe found on an iPhone, by store id (with the browser
    /// entitlement). Their manifests are read too; this is what they do.
    /// Probed 2026-10-10 (ExtensionsProbeTests, the top 20 of the store).
    static let known: [String: Verdict] = [
        // Work.
        "eimadpbcbfnmbkopoojfekhnkhdbieeh": Verdict(kind: .works, reason: ""),  // Dark Reader
        "nkbihfbeogaeaoehlefnkodbefgpgknn": Verdict(kind: .works, reason: ""),  // MetaMask
        "aapbdbdomjkkjkaonfhkkikfgjllcleb": Verdict(kind: .works, reason: ""),  // Google Translate
        "kbfnbcaeplbcioakkpcpgfkobkghlhen": Verdict(kind: .works, reason: ""),  // Grammarly
        "hdokiejnpimakedhajhdlcegeplioahd": Verdict(kind: .works, reason: ""),  // LastPass
        "gebbhagfogifgggkldgodflihgfeippi": Verdict(kind: .works, reason: ""),  // Return YouTube Dislike
        "mnjggcdmjocbbbhaepdhchncahnbgone": Verdict(kind: .works, reason: ""),  // SponsorBlock
        "ddkjiahejlhfcafbddmgiahcphecmpfh": Verdict(kind: .works, reason: ""),  // uBlock Origin Lite
        // Work in part.
        "nngceckbapebfimnlniiiahkandclblb": Verdict(kind: .limited, reason: "Unlocking with its app on a computer doesn't work on \(DeviceWord.name); sign in with your master password."),  // Bitwarden
        "aeblfdkhhhdcdjpifhhbdiojplfjncoa": Verdict(kind: .limited, reason: "Unlocking with its app on a computer doesn't work on \(DeviceWord.name); sign in to 1Password in the extension."),  // 1Password
        "cfhdojbkjhnklbpkdaibdccddilifddb": Verdict(kind: .limited, reason: "It blocks ads, but its counts of what it blocked stay empty."),  // Adblock Plus
        "bhlhnicpbhignbdhedgjhgdocnmhomnp": Verdict(kind: .limited, reason: "Its tools open, but picking a color from the page may not work."),  // ColorZilla
        // Don't work.
        "gighmmpiobklfepjocnamgkkbiglidom": Verdict(kind: .blocked, reason: "Its background stops on a kind of request \(DeviceWord.name)'s WebKit doesn't know, so it blocks nothing."),  // AdBlock
        "dhdgffkkebhmkfjojejmpbldmpobfkfo": Verdict(kind: .blocked, reason: "User scripts can't run on \(DeviceWord.name) yet."),  // Tampermonkey
        "pkehgijcmpdhfbdbbnkijodmdjhbjlgp": Verdict(kind: .blocked, reason: "Its window stays empty and most of its blocking rules aren't taken on \(DeviceWord.name)."),  // Privacy Badger
        "bmnlcjabgnpnenekpadlanbbkooimhnj": Verdict(kind: .blocked, reason: "Its background stops on something \(DeviceWord.name) doesn't have, so it finds no coupons."),  // Honey
        "fmkadmapgofadopljbjfkapdkoienihi": Verdict(kind: .blocked, reason: "It lives in Developer Tools, which \(DeviceWord.name) doesn't have."),  // React Developer Tools
        "liecbddmkiiihnedobmlmillhodjkdmb": Verdict(kind: .blocked, reason: "It records the screen, which an \(DeviceWord.name) browser can't."),  // Loom
        "laookkfknpbbblfpciffpaejjkokdgca": Verdict(kind: .blocked, reason: "It replaces the new tab page, which Yab for \(DeviceWord.name) doesn't have."),  // Momentum
        "ghbmnnjooekpmoecnnnilnnbdlolhkhi": Verdict(kind: .blocked, reason: "It keeps Google Docs offline in Chrome only."),  // Google Docs Offline
    ]

    /// Permissions for things an iPhone doesn't have.
    static let missing: [String: String] = [
        "debugger": "page debugging", "tabCapture": "recording tabs", "desktopCapture": "recording the screen",
        "pageCapture": "saving pages as files", "proxy": "proxy settings", "vpnProvider": "VPNs", "printerProvider": "printers",
        "printing": "printing", "ttsEngine": "voices", "gcm": "push messages", "platformKeys": "certificates",
        "documentScan": "scanners", "certificateProvider": "certificates", "system.cpu": "system information",
        "system.memory": "system information", "system.storage": "system information", "system.display": "displays",
    ]

    static func verdict(id: String, extension found: WKWebExtension, entitled: Bool = hasBrowserEntitlement) -> Verdict {
        verdict(id: id, manifest: found.manifest, entitled: entitled)
    }

    static func verdict(id: String, manifest: [String: Any], entitled: Bool = hasBrowserEntitlement) -> Verdict {
        let background = manifest["background"] as? [String: Any] ?? [:]
        let worker = background["service_worker"] != nil
        let runsBehind = worker || background["page"] != nil || background["scripts"] != nil
        if runsBehind, !entitled, worker || (manifest["manifest_version"] as? Int ?? 2) >= 3 {
            return Verdict(kind: .blocked, reason: waitingForApple)
        }
        if let found = known[id] { return found }
        if background["persistent"] as? Bool == true {
            return Verdict(kind: .blocked, reason: "It keeps a page running in the background all the time, which \(DeviceWord.name) doesn't allow.")
        }
        let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any] ?? [:]
        let content = (manifest["content_scripts"] as? [Any])?.isEmpty == false
        if manifest["devtools_page"] != nil, action["default_popup"] == nil, !content {
            return Verdict(kind: .blocked, reason: "It lives in Developer Tools, which \(DeviceWord.name) doesn't have.")
        }
        let asked = Set(((manifest["permissions"] as? [Any] ?? []) + (manifest["optional_permissions"] as? [Any] ?? [])).compactMap { $0 as? String })
        let lacks = Set(asked.compactMap { missing[$0] }).sorted()
        if !lacks.isEmpty {
            return Verdict(kind: .limited, reason: "Parts of it need " + lacks.joined(separator: ", ") + ", which \(DeviceWord.name) doesn't have.")
        }
        if asked.contains("nativeMessaging") {
            return Verdict(kind: .limited, reason: "The parts that talk to its app on a computer don't work on \(DeviceWord.name).")
        }
        return Verdict(kind: .works, reason: "")
    }
}
