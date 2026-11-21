import CryptoKit
import WebKit

// Shield's scriptlets (shield-scriptlets.js): one page-world script in every
// frame, at document start, holding the lists' table of calls by site. Each
// frame picks its own by its own host, so Swift only decides whether the
// script is on the page at all, as `Shield.fit` decides for the rule lists.
//
// The table is written beside the lists when they are built and read at
// launch. While it stays the same, every tab is given the very same
// WKUserScript object, so arming a tab sends nothing new (PageScripts.fit).

@MainActor
enum ShieldScriptlets {
    /// YAB_SHIELD_SCRIPTLETS=0 at launch: on no page, to measure what they cost.
    static var on = ProcessInfo.processInfo.environment["YAB_SHIELD_SCRIPTLETS"] != "0"

    struct Table: Equatable, Sendable {
        /// Filters.Scriptlets.table(), the JSON the page reads.
        let text: String
        let digest: String
        /// The whole script as WebKit runs it, made off the main thread.
        let webKitSource: String

        nonisolated init?(_ text: String) {
            guard !text.isEmpty else { return nil }
            self.text = text
            digest = SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            webKitSource = ShieldScriptlets.source(text, off: "null")
        }
    }

    private(set) static var table: Table?
    /// Read or built once this launch: a build's table is never replaced by
    /// an older one read from disk after it.
    private static var loaded = false
    private static var webKitScript: (digest: String, script: WKUserScript)?
    private static var chromiumSources: [ChromiumPolicy: String] = [:]

    nonisolated private static let template = Filters.Scriptlets.library(PageScript.load("shield-scriptlets"), clickGuard: PageScript.load("shield-guard"))

    nonisolated static func source(_ table: String, off: String) -> String {
        assert(template.contains("__YAB_TABLE__") && template.contains("__YAB_OFF__") && template.contains("function guardClicks("),
               "shield-scriptlets.js lost its markers")
        return Filters.Scriptlets.page(template, table: table, off: off)
    }

    nonisolated private static var file: URL {
        Store.folder.appendingPathComponent("Shield/scriptlets.txt")
    }

    // MARK: - building and launch

    /// Off the main thread, from the build that made the rules.
    nonisolated static func write(_ rules: Filters.Rules) {
        // No ##+js names no site: no page gets the script, nor the click guard in it.
        let text = rules.scriptlets.isEmpty ? "" : rules.scriptlets.table()
        NSLog("yab: shield scriptlets: %d calls, %d bytes; %@", rules.scriptlets.calls.count, text.utf8.count, droppedSummary(rules.dropped))
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: file, options: .atomic)
        let table = Table(text)
        Task { @MainActor in install(table) }
    }

    /// The reasons most rules were left out for, as one line for the log.
    nonisolated static func droppedSummary(_ dropped: [String: Int], top: Int = 6) -> String {
        let total = dropped.values.reduce(0, +)
        let most = dropped.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(top)
        return "dropped \(total)" + (most.isEmpty ? "" : ": " + most.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    }

    /// At launch, the table the last build wrote.
    static func read() {
        guard on else { return }
        Task.detached(priority: .userInitiated) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            let table = Table(text)
            await MainActor.run { if !loaded { install(table) } }
        }
    }

    /// A new table for every page from here on.
    static func install(_ fresh: Table?) {
        loaded = true
        guard fresh != table else { return }
        table = fresh
        webKitScript = nil
        chromiumSources = [:]
        refreshChromium()
    }

    // MARK: - WebKit

    /// Whether a tab's next document gets the script: what `Shield.fit`
    /// asks before it puts the lists on a page.
    static func runs(on host: String?, persistent: Bool) -> Bool {
        let shield = Shield.shared
        return on && !LinkGap.cut("shield") && !PageScripts.omits("scriptlets")
            && shield.enabled && !shield.isOff(on: host) && shield.blocker(persistent: persistent) == nil
    }

    /// The one script every WebKit tab shares while the table stays the same.
    static func webKit(for tab: Tab, host: String?) -> WKUserScript? {
        guard let table else { return nil }
        let persistent = tab.built?.configuration.websiteDataStore.isPersistent ?? !tab.shy
        guard runs(on: host, persistent: persistent) else { return nil }
        if let made = webKitScript, made.digest == table.digest { return made.script }
        let script = WKUserScript(source: table.webKitSource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        webKitScript = (table.digest, script)
        return script
    }

    // MARK: - Chromium

    /// A Chromium registration outlives the navigations after it, so it is
    /// there on every site and carries where Shield is off itself.
    struct ChromiumPolicy: Hashable {
        let digest: String
        let off: [String]
    }

    /// What a Chromium tab going to `host` registers, nil for nothing.
    static func chromiumPolicy(for tab: Tab, host: String?) -> ChromiumPolicy? {
        guard let table, runs(on: nil, persistent: !tab.shy) else { return nil }
        var off = Shield.shared.paused
        // A local page's own name: isOff knows it, the page can't.
        if let host, !Shield.shared.isPaused(on: host), Shield.shared.isOff(on: host) { off.insert(host) }
        return ChromiumPolicy(digest: table.digest, off: off.sorted())
    }

    static func chromium(_ policy: ChromiumPolicy) -> PageScriptRegistration? {
        guard let table, table.digest == policy.digest else { return nil }
        if let known = chromiumSources[policy] {
            return PageScriptRegistration(source: known, world: .page, atEnd: false, mainOnly: false)
        }
        let off = String(decoding: (try? offEncoder.encode(Off(enabled: true, off: policy.off))) ?? Data("null".utf8), as: UTF8.self)
        let source = source(table.text, off: off)
        if chromiumSources.count >= 8 { chromiumSources = [:] }
        chromiumSources[policy] = source
        return PageScriptRegistration(source: source, world: .page, atEnd: false, mainOnly: false)
    }

    private struct Off: Encodable {
        let enabled: Bool
        let off: [String]
    }

    private static let offEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Open Chromium tabs registered with another table or other off sites
    /// register again now, before a reload asked for with the switch.
    static func refreshChromium() {
        for browser in BrowserWindows.shared.browsers {
            let open = browser.everyTab + browser.outside + [browser.peeking].compactMap { $0 }
            for tab in open {
                guard let page = tab.builtPage as? ChromiumPage, page.scripts.scriptletsChanged else { continue }
                page.refreshFeatureScripts()
            }
        }
    }
}
