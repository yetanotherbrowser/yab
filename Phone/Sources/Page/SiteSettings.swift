import Foundation
import Observation
import UIKit
import WebKit

/// What Yab remembers about a site, as the Mac's Site Controls do: its page
/// zoom, whether it is asked for as a desktop site, and what it was once
/// allowed or refused. Keyed by host (no "www."). Ordinary sites persist in
/// the defaults; private tabs keep their own in memory only, gone with the
/// app, and never read or write the ordinary ones. Test worlds keep everything
/// in memory, so named states start the same every time.
@MainActor
@Observable
final class SiteSettings {
    enum Permission: String, Codable, CaseIterable, Sendable {
        case camera, microphone, downloads

        var title: String {
            switch self {
            case .camera: "Camera"
            case .microphone: "Microphone"
            case .downloads: "Downloads"
            }
        }

        /// Its mark: the prototype's, or the Mac's for what it never drew.
        var glyph: GlyphName? {
            switch self {
            case .camera: .camera1
            case .microphone: .microphone
            case .downloads: nil
            }
        }

        var macGlyph: MacGlyph? { self == .downloads ? .yabDownload : nil }
    }

    /// What a site may do, said in a word.
    enum Decision: String, Codable, CaseIterable, Sendable {
        case ask, allowed, off

        var word: String {
            switch self {
            case .ask: "Ask"
            case .allowed: "Allowed"
            case .off: "Off"
            }
        }
    }

    /// Which version of a site is asked for. `automatic` is the device's
    /// own default: WebKit's recommended on an iPad, mobile on an iPhone.
    enum Version: String, Codable, Sendable {
        case automatic, desktop, mobile
    }

    struct Site: Codable, Equatable, Sendable {
        var zoom: Double = 1
        var version: Version = .automatic
        var permissions: [Permission: Decision] = [:]
        /// Block Ads and Trackers for this site, said here; nil follows
        /// the Mac's sites and the switch in Settings (Shield).
        var blocksAds: Bool?
        /// Always Translate: pages of the site in this language (its code,
        /// "pt") are translated as they load (Page/PageTranslation).
        var translates: String?

        var isEmpty: Bool {
            abs(zoom - 1) < 0.001 && version == .automatic && permissions.isEmpty && blocksAds == nil && translates == nil
        }

        init() {}

        private enum CodingKeys: String, CodingKey {
            case zoom, version, permissions, blocksAds, translates
            /// Before `version`: `desktop` true, or (an iPad's) `mobile` true.
            case desktop, mobile
        }

        init(from decoder: Decoder) throws {
            let saved = try decoder.container(keyedBy: CodingKeys.self)
            zoom = try saved.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
            permissions = try saved.decodeIfPresent([Permission: Decision].self, forKey: .permissions) ?? [:]
            blocksAds = try saved.decodeIfPresent(Bool.self, forKey: .blocksAds)
            translates = try saved.decodeIfPresent(String.self, forKey: .translates)
            if let version = try saved.decodeIfPresent(Version.self, forKey: .version) {
                self.version = version
            } else if try saved.decodeIfPresent(Bool.self, forKey: .mobile) == true {
                version = .mobile
            } else if try saved.decodeIfPresent(Bool.self, forKey: .desktop) == true {
                version = .desktop
            }
        }

        func encode(to encoder: Encoder) throws {
            var out = encoder.container(keyedBy: CodingKeys.self)
            try out.encode(zoom, forKey: .zoom)
            try out.encode(version, forKey: .version)
            try out.encode(permissions, forKey: .permissions)
            try out.encodeIfPresent(blocksAds, forKey: .blocksAds)
            try out.encodeIfPresent(translates, forKey: .translates)
        }
    }

    /// The prototype's steps: 10 % at a time up to 200 %, then larger.
    static let zoomSteps: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.1, 1.2, 1.3, 1.4, 1.5, 1.75, 2, 2.5, 3]

    private var sites: [String: Site]
    private var privateSites: [String: Site] = [:]
    private let defaults: UserDefaults?
    private static let key = "yab.siteSettings"

    /// Safari's default: an iPad asks every site for its desktop version, an
    /// iPhone for its mobile one. A site's own choice turns it the other way.
    var prefersDesktop: Bool

    /// `defaults` nil: nothing outlives the app (test worlds).
    init(defaults: UserDefaults? = .standard, prefersDesktop: Bool? = nil) {
        self.defaults = defaults
        self.prefersDesktop = prefersDesktop ?? Self.devicePrefersDesktop
        if let data = defaults?.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: Site].self, from: data) {
            sites = saved
        } else {
            sites = [:]
        }
    }

    /// The host a setting is kept under: lowercased, without "www.".
    static func key(_ host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }

    func site(_ host: String?, isPrivate: Bool) -> Site {
        guard let key = Self.key(host) else { return Site() }
        return (isPrivate ? privateSites[key] : sites[key]) ?? Site()
    }

    private func edit(_ host: String?, isPrivate: Bool, _ change: (inout Site) -> Void) {
        guard let key = Self.key(host) else { return }
        var site = (isPrivate ? privateSites[key] : sites[key]) ?? Site()
        change(&site)
        let value: Site? = site.isEmpty ? nil : site
        if isPrivate { privateSites[key] = value } else { sites[key] = value; save() }
    }

    private func save() {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(sites) { defaults.set(data, forKey: Self.key) }
    }

    // MARK: - page zoom

    func zoom(_ host: String?, isPrivate: Bool) -> Double { site(host, isPrivate: isPrivate).zoom }

    func setZoom(_ zoom: Double, for host: String?, isPrivate: Bool) {
        let clamped = min(max(zoom, Self.zoomSteps.first!), Self.zoomSteps.last!)
        edit(host, isPrivate: isPrivate) { $0.zoom = clamped }
    }

    /// The next step in or out from `zoom`; nil past the last.
    static func step(_ zoom: Double, by direction: Int) -> Double? {
        if direction > 0 { return zoomSteps.first { $0 > zoom + 0.001 } }
        return zoomSteps.last { $0 < zoom - 0.001 }
    }

    static func percent(_ zoom: Double) -> Int { Int((zoom * 100).rounded()) }

    // MARK: - desktop site

    func version(_ host: String?, isPrivate: Bool) -> Version { site(host, isPrivate: isPrivate).version }

    func setVersion(_ version: Version, for host: String?, isPrivate: Bool) {
        edit(host, isPrivate: isPrivate) { $0.version = version }
    }

    /// The switch in the menus: on unless the site is asked for as a mobile one.
    func desktop(_ host: String?, isPrivate: Bool) -> Bool {
        contentMode(host, isPrivate: isPrivate) != .mobile
    }

    /// An iPhone's switch turned back to mobile forgets the choice. An
    /// iPad's default is WebKit's recommended mode, mobile in a narrow pane,
    /// so a desktop asked for there is kept as desktop.
    func setDesktop(_ desktop: Bool, for host: String?, isPrivate: Bool) {
        let asked: Version = desktop ? .desktop : .mobile
        setVersion(!desktop && !prefersDesktop ? .automatic : asked, for: host, isPrivate: isPrivate)
    }

    /// What WebKit is asked for: the one place the choice is read. An iPad
    /// left alone gets Safari's own choice, `.recommended`: desktop at full
    /// width, mobile in a narrow window.
    func contentMode(_ host: String?, isPrivate: Bool) -> WKWebpagePreferences.ContentMode {
        switch version(host, isPrivate: isPrivate) {
        case .desktop: .desktop
        case .mobile: .mobile
        case .automatic: Self.defaultContentMode(prefersDesktop: prefersDesktop)
        }
    }

    static func defaultContentMode(prefersDesktop: Bool) -> WKWebpagePreferences.ContentMode {
        prefersDesktop ? .recommended : .mobile
    }

    /// Safari's default for this device: an iPad prefers desktop sites.
    static var devicePrefersDesktop: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    // MARK: - the ad blocker

    /// What this iPhone was told for the site, nil for nothing said.
    func blocksAds(_ host: String?, isPrivate: Bool) -> Bool? { site(host, isPrivate: isPrivate).blocksAds }

    func setBlocksAds(_ blocks: Bool?, for host: String?, isPrivate: Bool) {
        edit(host, isPrivate: isPrivate) { $0.blocksAds = blocks }
    }

    // MARK: - translation

    /// The language this site's pages are always translated from, if any.
    func alwaysTranslates(_ host: String?, isPrivate: Bool) -> String? { site(host, isPrivate: isPrivate).translates }

    func setAlwaysTranslates(_ language: String?, for host: String?, isPrivate: Bool) {
        edit(host, isPrivate: isPrivate) { $0.translates = language }
    }

    // MARK: - what the site asked for

    func permissions(_ host: String?, isPrivate: Bool) -> [(Permission, Decision)] {
        let saved = site(host, isPrivate: isPrivate).permissions
        return Permission.allCases.compactMap { kind in saved[kind].map { (kind, $0) } }
    }

    func decision(_ kind: Permission, for host: String?, isPrivate: Bool) -> Decision? {
        site(host, isPrivate: isPrivate).permissions[kind]
    }

    func setDecision(_ decision: Decision, _ kind: Permission, for host: String?, isPrivate: Bool) {
        edit(host, isPrivate: isPrivate) { $0.permissions[kind] = decision }
    }

    /// × beside it: forgotten, the site asks again next time.
    func forget(_ kind: Permission, for host: String?, isPrivate: Bool) {
        edit(host, isPrivate: isPrivate) { $0.permissions[kind] = nil }
    }

    /// The site asked for the camera or microphone: remembered as asked, and
    /// what it was told before decides now (Ask lets iOS ask).
    func asked(_ kinds: [Permission], host: String?, isPrivate: Bool) -> WKPermissionDecision {
        let saved = kinds.map { decision($0, for: host, isPrivate: isPrivate) }
        for (kind, decision) in zip(kinds, saved) where decision == nil {
            setDecision(.ask, kind, for: host, isPrivate: isPrivate)
        }
        if saved.contains(.off) { return .deny }
        if saved.allSatisfy({ $0 == .allowed }) { return .grant }
        return .prompt
    }

    /// Clear Data: the site's remembered settings go with its cookies.
    func clear(_ host: String?, isPrivate: Bool) {
        guard let key = Self.key(host) else { return }
        if isPrivate { privateSites[key] = nil } else { sites[key] = nil; save() }
    }

    /// The last private tab closed: what private browsing remembered goes.
    func forgetPrivate() { privateSites.removeAll() }
}
