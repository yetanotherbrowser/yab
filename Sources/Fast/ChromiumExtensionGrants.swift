import Foundation
import YabCoreClient

/// Compare the original Chrome manifest with the saved WebKit approval.
/// Optional permissions are not granted by importing the installed list.
enum ChromiumExtensionGrants {
    static func required(in manifest: [String: Any]) -> Set<String> {
        var grants = normalized(manifest["permissions"] as? [String] ?? [])
        grants.formUnion((manifest["host_permissions"] as? [String] ?? []).map { "site:" + $0 })
        for script in manifest["content_scripts"] as? [[String: Any]] ?? [] {
            grants.formUnion((script["matches"] as? [String] ?? []).map { "site:" + $0 })
        }
        return grants
    }

    /// What only a yes may give an extension moving engines on its own: the
    /// Chromium package's grants beyond the saved approval that Chrome would
    /// warn of, and sites beyond the manifest the approval was given on.
    /// WebKit saved only what it understands (no `nativeMessaging`, `offscreen`
    /// or a match with a port), so the difference alone says nothing; a native
    /// host answers only the extensions its own app named, and the rest of
    /// what falls away here Chrome adds without a warning.
    static func beyondApproval(required: Set<String>, saved: Set<String>, approvedManifest: Set<String>) -> Set<String> {
        let warned = Set(ChromiumInstallWords.chromeOnly.map { "permission:" + $0.0 })
        return required.subtracting(saved).filter { grant in
            grant.hasPrefix("site:") ? !approvedManifest.contains(grant) : warned.contains(grant)
        }
    }

    static func normalized(_ saved: [String]) -> Set<String> {
        Set(saved.map { value in
            if value.hasPrefix("site:") || value.hasPrefix("permission:") { return value }
            if value.contains("://") || value == "<all_urls>" { return "site:" + value }
            let name = value.hasPrefix("yab:") ? String(value.dropFirst(4)) : value
            return "permission:" + name
        })
    }
}

/// Where an extension may reach, kept in Store.settings for both engines
/// (Extensions.access, allowed), said in Chrome's runtime host permissions.
/// Blocked sites have no per-extension form in Chrome and stay WebKit's.
@available(macOS 15.4, *)
@MainActor
extension ChromiumExtensionGrants {
    static func hostAccess(_ access: Extensions.SiteAccess) -> String {
        switch access {
        case .asked: return "ON_ALL_SITES"
        case .sites: return "ON_SPECIFIC_SITES"
        case .click: return "ON_CLICK"
        }
    }

    /// "a.test" of "*://*.a.test/*".
    nonisolated private static func host(of pattern: String) -> String? {
        guard let range = pattern.range(of: "://") else { return nil }
        let tail = pattern[range.upperBound...].prefix { $0 != "/" }
        return tail.hasPrefix("*.") ? String(tail.dropFirst(2)) : String(tail)
    }

    struct AccessChange: Equatable {
        let hostAccess: String
        let add: [String]
        let remove: [String]
    }

    /// What Chrome's host permissions need to say what the list says. Nil
    /// when they already do, or Chrome holds no choice for this extension.
    static func accessChange(_ row: ChromiumExtensions.Item, access: Extensions.SiteAccess, allowed: [String]) -> AccessChange? {
        guard let held = row.access, let now = held["hostAccess"].string else { return nil }
        let wanted = hostAccess(access)
        var granted: [String] = []
        if case .array(let hosts) = held["hosts"] {
            granted = hosts.filter { $0["granted"] == .bool(true) }.compactMap { $0["host"].string }
        }
        let want = access == .sites ? allowed : []
        let have = Set(granted.compactMap(host(of:)))
        // An address has no subdomains for Chrome to take a pattern of.
        let add = access == .sites ? want.filter { !have.contains($0) }.flatMap { host -> [String] in
            host.allSatisfy { $0.isNumber || $0 == "." } ? ["*://\(host)/*"] : ["*://\(host)/*", "*://*.\(host)/*"]
        } : []
        let remove = access == .sites ? granted.filter { host(of: $0).map { !want.contains($0) } ?? false } : []
        return now == wanted && add.isEmpty && remove.isEmpty ? nil : AccessChange(hostAccess: wanted, add: add, remove: remove.filter(valid))
    }

    /// A pattern the management call takes: Chrome's own words for a host.
    nonisolated private static func valid(_ pattern: String) -> Bool {
        pattern.hasSuffix("/*") && host(of: pattern) != nil
    }

    /// At the join: a choice made only on Chromium becomes the list's.
    static func adoptAccess(_ rows: [ChromiumExtensions.Item], into list: Extensions) {
        for row in rows {
            guard let held = row.access, list.access(row.id) == .asked, list.allowed(row.id).isEmpty else { continue }
            switch held["hostAccess"].string {
            case "ON_CLICK": list.setAccess(row.id, .click)
            case "ON_SPECIFIC_SITES":
                list.setAccess(row.id, .sites)
                if case .array(let hosts) = held["hosts"] {
                    let names = hosts.filter { $0["granted"] == .bool(true) }.compactMap { $0["host"].string.flatMap(Self.host(of:)) }
                    list.adopt(sites: names, for: row.id)
                }
            default: break
            }
        }
    }

    /// Its manifest's sites and whether it can wait to be pressed, as Settings
    /// offers them. Nil for one this profile doesn't hold.
    static func reach(of row: ChromiumExtensions.Item) -> (everywhere: Bool, hosts: [String], clickable: Bool)? {
        guard let path = row.path, let manifest = try? ChromiumExtensionPackages.manifest(in: URL(fileURLWithPath: path)) else { return nil }
        let patterns = required(in: manifest).filter { $0.hasPrefix("site:") }.map { String($0.dropFirst(5)) }
        let hosts = patterns.filter { !allHosts($0) }.compactMap(host(of:)).filter { !$0.isEmpty }
        return (patterns.contains(where: allHosts), Array(Set(hosts)).sorted(),
                (manifest["permissions"] as? [String] ?? []).contains("activeTab"))
    }

    nonisolated private static func allHosts(_ pattern: String) -> Bool {
        ["<all_urls>", "*://*/*", "http://*/*", "https://*/*"].contains(pattern)
    }

    /// What it may ask for later, by the one spelling both engines compare:
    /// each key the manifest's own, for asking Chrome with.
    private static func optional(in manifest: [String: Any]) -> [String: String] {
        let listed = (manifest["optional_permissions"] as? [String] ?? []) + (manifest["optional_host_permissions"] as? [String] ?? [])
        return Dictionary(listed.map { (spelled($0), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func spelled(_ key: String) -> String { allHosts(key) ? "<all_urls>" : key }

    private static func marks(_ keys: Set<String>) -> [String: String] {
        Dictionary(keys.map { ($0, "1") }, uniquingKeysWith: { first, _ in first })
    }

    /// Optional grants, given in either engine, held in both. `page` shows
    /// the extension. A grant goes to Chrome through its own request, whose
    /// question is answered yes: the person gave it already (ChromiumConsent).
    static func cross(_ row: ChromiumExtensions.Item, page: ChromiumExtensionPage, list: Extensions,
                      shadow: inout ChromiumExtensionStorage.Shadow) async throws {
        guard let path = row.path else { return }
        let optional = optional(in: try ChromiumExtensionPackages.manifest(in: URL(fileURLWithPath: path)))
        guard !optional.isEmpty else { return }
        let id = row.id
        let held = try await page.run("return await chrome.permissions.getAll();") as? [String: Any] ?? [:]
        var chromium = Set<String>()
        for name in ["permissions", "origins"] { chromium.formUnion((held[name] as? [String] ?? []).map(spelled)) }
        chromium.formIntersection(optional.keys)
        let given = Store.settings.stringArray(forKey: "extensions.granted.\(id)") ?? []
        let webKit = Set((Extensions.choices(id).filter(\.value).map(\.key) + given).map(spelled)).intersection(optional.keys)
        let crossing = ExtensionOneList.crossing(chromium: marks(chromium), webKit: marks(webKit),
                                                 shadow: shadow.grants.map { marks(Set($0)) }, chromiumNewer: true)
        func request(_ keys: [String]) -> [String: Any] {
            let originals = keys.compactMap { optional[$0] }
            let sites = originals.filter { $0.contains("://") || $0 == "<all_urls>" }
            return ["asked": ["origins": sites, "permissions": originals.filter { !sites.contains($0) }]]
        }
        var together = chromium
        if !crossing.toChromium.isEmpty {
            ChromiumConsent.approve("permissions", id)
            defer { ChromiumConsent.withdrawApproval("permissions", id) }
            let answer = try await page.run("return await chrome.permissions.request(asked);", request(crossing.toChromium), gesture: true)
            if answer as? Bool == true { together.formUnion(crossing.toChromium) }
            else { NSLog("Chromium extensions: %@ was not granted what it has under WebKit", id) }
        }
        if !crossing.removeFromChromium.isEmpty {
            _ = try await page.run("return await chrome.permissions.remove(asked);", request(crossing.removeFromChromium))
            together.subtract(crossing.removeFromChromium)
        }
        var toWebKit = crossing.toWebKit
        let isSite = { (key: String) in optional[key].map { $0.contains("://") || $0 == "<all_urls>" } ?? false }
        let sitePicks = Dictionary(toWebKit.filter(isSite).compactMap { optional[$0] }.map { ($0, true) }, uniquingKeysWith: { first, _ in first })
        if !sitePicks.isEmpty, !list.admits(choices: sitePicks, for: id) {
            NSLog("Chromium extensions: %@ was not given its Chromium sites under WebKit's script budget", id)
            let refused = toWebKit.filter(isSite)
            toWebKit.removeAll(where: isSite)
            // Out of the shadow, so the next pass offers them again instead of reading a removal.
            together.subtract(refused)
        }
        if !toWebKit.isEmpty {
            Extensions.choose(Dictionary(toWebKit.compactMap { optional[$0] }.map { ($0, true) }, uniquingKeysWith: { first, _ in first }), for: id)
        }
        if !crossing.removeFromWebKit.isEmpty {
            let gone = Set(crossing.removeFromWebKit)
            Extensions.setChoices(Extensions.choices(id).filter { !gone.contains(spelled($0.key)) }, for: id)
            Store.settings.set(given.filter { !gone.contains(spelled($0)) }, forKey: "extensions.granted.\(id)")
        }
        if !toWebKit.isEmpty || !crossing.removeFromWebKit.isEmpty { list.choicesChanged(id) }
        shadow.grants = together.sorted()
    }
}

/// The install question's lines when Chrome cannot give its own warnings
/// (prebuilt CEF's management page lacks getPermissionWarningsByManifest):
/// Yab's own words for what WebKit knows, as WebKit Yab asks, then Chrome's
/// words for the permissions only Chrome grants.
enum ChromiumInstallWords {
    static let chromeOnly: [(String, String)] = [
        ("history", "Read and change your browsing history"),
        ("bookmarks", "Read and change your bookmarks"),
        ("readingList", "Read and change entries in the reading list"),
        ("topSites", "Read a list of your most frequently visited websites"),
        ("downloads", "Manage your downloads"),
        ("clipboardRead", "Read data you copy and paste"),
        ("geolocation", "Detect your physical location"),
        ("notifications", "Display notifications"),
        ("desktopCapture", "Capture content of your screen"),
        ("tabCapture", "Capture content of your screen"),
        ("privacy", "Change your privacy-related settings"),
        ("contentSettings", "Change which sites can use cookies, JavaScript, your location, camera and microphone"),
        ("management", "Manage your apps, extensions, and themes"),
        ("debugger", "Access the page debugger backend"),
        ("proxy", "Read and change every site you visit"),
    ]

    /// What a package asks for beyond the approval, in the same words.
    static func lines(_ beyond: Set<String>) -> [String] {
        var out: [String] = []
        for (name, sentence) in chromeOnly where beyond.contains("permission:" + name) && !out.contains(sentence) { out.append(sentence) }
        let sites = beyond.filter { $0.hasPrefix("site:") }.map { String($0.dropFirst(5)) }.sorted()
        if !sites.isEmpty { out.append("Read and change pages on " + sites.prefix(4).joined(separator: ", ")) }
        return out
    }

    static func lines(manifest: [String: Any], yab: [String]) -> [String] {
        let declared = Set(manifest["permissions"] as? [String] ?? [])
        var out = yab
        for (name, sentence) in chromeOnly where declared.contains(name) && !out.contains(sentence) { out.append(sentence) }
        return out
    }
}
