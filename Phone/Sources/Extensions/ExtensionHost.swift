import Observation
import SwiftUI
import UIKit
import WebKit

/// Chrome extensions on Yab for iPhone, on Apple's engine (WKWebExtension,
/// iOS 18.4+), as Yab for Mac runs them (Sources/Fast/Extensions.swift):
/// installed from the Chrome Web Store (ExtensionPackage), loaded into one
/// controller every page view is born with (WebPool), told which tabs there
/// are and which is in front. A popup is a sheet from the bottom, as the
/// page menu is. What an extension asks for is granted at install, after
/// the person said yes to what it can do.
@MainActor
@Observable
final class ExtensionHost: NSObject {
    static let shared = ExtensionHost()

    struct Installed: Codable, Identifiable, Equatable {
        let id: String
        var name: String
        var version: String
        var enabled: Bool
    }

    /// One action on the page menu: what an extension shows for the tab in front.
    struct Button: Identifiable {
        let id: String
        let name: String
        let label: String
        let badge: String
        let icon: UIImage?
    }

    private(set) var installed: [Installed] = []
    /// Ids being fetched and unpacked now.
    private(set) var installing: Set<String> = []
    /// Bumped when an action or a context changes, so the menu redraws.
    private(set) var revision = 0
    /// What WebKit asked and when, for a test run's list (YAB_TEST).
    private(set) var events: [String] = []
    /// What each extension did and asked for, for the compatibility probe.
    @ObservationIgnored private(set) var logs: [String: [String]] = [:]
    func log(_ id: String, _ line: String) {
        var lines = logs[id, default: []]
        if lines.count < 200 { lines.append(line) }
        logs[id] = lines
    }
    func note(_ event: String) {
        events.append(event)
        if events.count > 40 { events.removeFirst(events.count - 40) }
    }

    /// Made with the pages' own store and name (attach), before any page.
    @ObservationIgnored private(set) var controller: WKWebExtensionController!
    @ObservationIgnored private var contexts: [String: WKWebExtensionContext] = [:]
    @ObservationIgnored private var tabs: [Tab.ID: ExtensionTab] = [:]
    @ObservationIgnored private lazy var window = ExtensionWindow(host: self)
    @ObservationIgnored private var active: Tab.ID?
    @ObservationIgnored private var titles: [Tab.ID: String] = [:]
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var started = false

    static let scheme = "chrome-extension"

    /// Extensions are shown at all only with Apple's browser entitlement:
    /// without it no worker runs, so the page menu's rows, Settings ›
    /// Extensions and the store's Add to Yab stay hidden (docs/TODO-launch.md).
    nonisolated static var isAvailable: Bool { ExtensionCompatibility.hasBrowserEntitlement }

    /// An extension's own page (its welcome, options, a page it opens).
    nonisolated static func isExtensionPage(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "chrome-extension" || scheme == "webkit-extension"
    }

    /// Beside the profile a test run names, so each run starts with none.
    static var folder: URL {
        if let path = LaunchOptions.current.profileDirectory, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("Extensions", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Extensions", isDirectory: true)
    }
    private static var list: URL { folder.appendingPathComponent("installed.json") }

    private override init() {
        super.init()
        installed = (try? JSONDecoder().decode([Installed].self, from: Data(contentsOf: Self.list))) ?? []
        launchLoaded = Set(installed.map(\.id))
    }

    /// Every page view is handed the controller at birth (it can't be given
    /// one later). The controller is made with the pages' store, where an
    /// extension's pages keep what they store, and with their name to the
    /// letter: WebKit gives workers the user agent of the last page that
    /// loaded and, when it differs, stops the running extension workers and
    /// never starts them again (as Yab for Mac found, Extensions.swift).
    func attach(_ configuration: WKWebViewConfiguration, store: WKWebsiteDataStore) {
        if controller == nil {
            // Its pages at chrome-extension://<id>/, as in Chrome and on the Mac.
            WKWebExtension.MatchPattern.registerCustomURLScheme(Self.scheme)
            // What extensions store is kept between launches; a test run's goes with it.
            let testRun = !(LaunchOptions.current.profileDirectory ?? "").isEmpty
            let made: WKWebExtensionController.Configuration = testRun ? .nonPersistent() : .default()
            made.defaultWebsiteDataStore = store
            let views = made.webViewConfiguration ?? WKWebViewConfiguration()
            views.websiteDataStore = store
            views.applicationNameForUserAgent = WebPool.userAgentName
            // An extension's background is never on screen on a phone; WebKit
            // slows unseen views until messages to and from it stop arriving.
            views.preferences.inactiveSchedulingPolicy = .none
            made.webViewConfiguration = views
            controller = WKWebExtensionController(configuration: made)
            controller.delegate = self
        }
        configuration.webExtensionController = controller
    }

    /// Once, with the app: the installed ones loaded, the tabs followed.
    func start(_ app: AppModel) {
        self.app = app
        guard !started, controller != nil else { return }
        started = true
        Task { for item in installed where item.enabled { await load(item.id) } }
        follow()
        ExtensionProbe.runIfAsked(self)
    }

    /// Its action's popup view, made now (the probe draws it out of sight).
    func popupView(_ id: String) -> WKWebView? {
        guard let action = contexts[id]?.action(for: activeTab()), action.presentsPopup else { return nil }
        return action.popupWebView
    }

    func closePopup(_ id: String) { contexts[id]?.action(for: activeTab())?.closePopup() }

    /// The page in front, for the probe's blocking check.
    func frontPage() -> WKWebView? { activeTab().flatMap { liveView($0.id) } }

    /// What Yab can say of an installed one (ExtensionCompatibility).
    func compatibility(_ id: String) -> ExtensionCompatibility.Verdict? {
        guard let context = contexts[id] else { return nil }
        // Without what Yab added to its manifest (ExtensionShim.prepare).
        var manifest = context.webExtension.manifest
        let file = Self.folder.appendingPathComponent(id).appendingPathComponent(".yab-added")
        let added = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String] ?? []
        manifest["permissions"] = (manifest["permissions"] as? [Any] ?? []).filter { !added.contains(($0 as? String) ?? "") }
        return ExtensionCompatibility.verdict(id: id, manifest: manifest)
    }

    // MARK: - the tabs, as WebKit is told them

    private func follow() {
        withObservationTracking { sync() } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    /// The space in front's tabs: opened, closed, the one in front, a new address or title.
    private func sync() {
        guard let app else { return }
        let space = app.browser.space
        let now = space.allTabs
        let ids = Set(now.map(\.id))
        for (id, tab) in tabs where !ids.contains(id) {
            controller.didCloseTab(tab, windowIsClosing: false)
            tabs[id] = nil
            titles[id] = nil
        }
        for item in now where tabs[item.id] == nil {
            let tab = ExtensionTab(host: self, id: item.id)
            tabs[item.id] = tab
            titles[item.id] = item.title + (item.url ?? "")
            controller.didOpenTab(tab)
            note("tab open \(item.id.prefix(6))")
        }
        for item in now {
            let key = item.title + (item.url ?? "")
            if titles[item.id] != key, let tab = tabs[item.id] {
                titles[item.id] = key
                controller.didChangeTabProperties([.title, .URL, .loading], for: tab)
            }
        }
        let front = space.current
        if front != active, let id = front, let tab = tabs[id] {
            let previous = active.flatMap { tabs[$0] }
            active = id
            controller.didActivateTab(tab, previousActiveTab: previous)
            controller.didSelectTabs([tab])
        }
        revision += 1
    }

    /// A page committed or finished: its address and title as WebKit reads them now.
    func pageChanged(_ id: Tab.ID) {
        guard let tab = tabs[id] else { return }
        controller.didChangeTabProperties([.URL, .title, .loading], for: tab)
        revision += 1
    }

    fileprivate func tabsInFront() -> [ExtensionTab] {
        guard let app else { return [] }
        return app.browser.space.allTabs.compactMap { tabs[$0.id] }
    }
    fileprivate func activeTab() -> ExtensionTab? { app?.browser.space.current.flatMap { tabs[$0] } }
    fileprivate func model(_ id: Tab.ID) -> Tab? { app?.browser.tab(id) }
    fileprivate func liveView(_ id: Tab.ID) -> WKWebView? { app?.pages.liveView(id) }
    fileprivate func isFront(_ id: Tab.ID) -> Bool { app?.browser.space.current == id }
    fileprivate func activate(_ id: Tab.ID) { app?.browser.select(id) }
    fileprivate func close(_ id: Tab.ID) { app?.browser.close(id) }
    fileprivate func load(_ url: URL, in id: Tab.ID) { app?.pages.load(id, url) }

    /// A tab for an extension: opened in the space in front.
    fileprivate func openTab(_ url: URL?, front: Bool) -> ExtensionTab? {
        guard let app else { return nil }
        let target = url ?? URL(string: "about:blank")!
        let tab = PageFixtures.tab(for: target, isPrivate: app.browser.space.isPrivate, in: app.world, fixturesEnabled: app.fixturesEnabled)
        if front { app.browser.open(tab, deduplicate: false) }
        else if let source = app.browser.tab?.id { app.browser.openBehind(tab, after: source, in: app.browser.spaceID) }
        else { app.browser.open(tab, deduplicate: false) }
        sync()
        return tabs[tab.id]
    }

    // MARK: - installing

    /// From the store: fetched, checked, unpacked, loaded, kept. Throws in
    /// the person's words.
    func install(_ id: String) async throws -> Installed {
        guard !installing.contains(id) else { throw ExtensionPackage.Refused.empty }
        installing.insert(id)
        defer { installing.remove(id) }
        var stage = "download"
        do {
            let crx = try await ExtensionPackage.fetch(id)
            stage = "verify"
            let zip = try ExtensionPackage.verifiedZip(crx, id: id)
            let target = Self.folder.appendingPathComponent(id, isDirectory: true)
            stage = "unpack"
            try await Task.detached {
                try ExtensionPackage.unpack(zip, into: target)
                try ExtensionShim.prepare(target)
            }.value
            if let old = contexts.removeValue(forKey: id) { try? controller.unload(old) }
            stage = "manifest"
            let found = try await WKWebExtension(resourceBaseURL: target)
            let item = Installed(id: id, name: found.displayName ?? id, version: found.version ?? "", enabled: true)
            installed.removeAll { $0.id == id }
            installed.append(item)
            save()
            stage = "register"
            try loadContext(found, id: id)
            return item
        } catch {
            log(id, Self.packageFailure("install", stage: stage, error: error))
            throw error
        }
    }

    /// What an extension in the store would get, for the yes before it is added.
    func preview(_ id: String) async throws -> (name: String, reach: String, verdict: ExtensionCompatibility.Verdict) {
        var stage = "download"
        do {
            let crx = try await ExtensionPackage.fetch(id)
            stage = "verify"
            let zip = try ExtensionPackage.verifiedZip(crx, id: id)
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("yab-preview-\(id)", isDirectory: true)
            stage = "unpack"
            try await Task.detached { try ExtensionPackage.unpack(zip, into: scratch) }.value
            defer { try? FileManager.default.removeItem(at: scratch) }
            stage = "manifest"
            let found = try await WKWebExtension(resourceBaseURL: scratch)
            return (found.displayName ?? id, Self.reach(found), ExtensionCompatibility.verdict(id: id, extension: found))
        } catch {
            log(id, Self.packageFailure("preview", stage: stage, error: error))
            throw error
        }
    }

    /// Keep package diagnostics free of URLs, paths and error payloads.
    nonisolated static func packageFailure(_ operation: String, stage: String, error: Error) -> String {
        let failure = error as NSError
        let domain: String
        if error is ExtensionPackage.Refused {
            domain = "ExtensionPackage.Refused"
        } else {
            switch failure.domain {
            case NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain,
                 "WKErrorDomain", "WKWebExtensionErrorDomain", "WKWebExtensionContextErrorDomain":
                domain = failure.domain
            default:
                domain = "other"
            }
        }
        return "package.\(operation) stage=\(stage) domain=\(domain) code=\(failure.code)"
    }

    /// What it can do, in a line: every site, some sites, or none.
    static func reach(_ found: WKWebExtension) -> String {
        let patterns = found.allRequestedMatchPatterns
        if patterns.contains(where: { $0.matchesAllURLs || $0.matchesAllHosts }) { return "It can read and change what you see on every website." }
        let hosts = Set(patterns.compactMap(\.host)).sorted()
        if hosts.isEmpty { return "It doesn't read any website." }
        return "It can read and change what you see on " + hosts.prefix(3).joined(separator: ", ") + (hosts.count > 3 ? " and \(hosts.count - 3) more." : ".")
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].enabled = on
        save()
        if on { Task { await load(id) } }
        else if let context = contexts.removeValue(forKey: id) { try? controller.unload(context); revision += 1 }
    }

    func remove(_ id: String) {
        if let context = contexts.removeValue(forKey: id) { try? controller.unload(context) }
        installed.removeAll { $0.id == id }
        save()
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(id, isDirectory: true))
        revision += 1
    }

    private func load(_ id: String) async {
        guard contexts[id] == nil else { return }
        do {
            let found = try await WKWebExtension(resourceBaseURL: Self.folder.appendingPathComponent(id, isDirectory: true))
            try loadContext(found, id: id)
        } catch {
            app?.say("Couldn't load \(installed.first { $0.id == id }?.name ?? "an extension")", glyph: .exclamationCircle)
        }
    }

    private func loadContext(_ found: WKWebExtension, id: String) throws {
        let context = WKWebExtensionContext(for: found)
        // Its id as Chrome's, so its pages are chrome-extension://<id>/ and
        // what it stored is found again after an update.
        context.uniqueIdentifier = id
        if let stable = URL(string: "\(Self.scheme)://\(id)/") { context.baseURL = stable }
        for permission in found.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        for pattern in found.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        // How the shim reaches Yab (ExtensionShim), added at install.
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
        context.isInspectable = true
        try controller.load(context)
        contexts[id] = context
        revision += 1
        // Its background started now, so what keeps it from running is said
        // in its row (Extensions) rather than found out on a page.
        context.loadBackgroundContent { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.trouble[id] = error.localizedDescription }
                self.note("background \(id.prefix(6)): " + (error?.localizedDescription ?? "started"))
                self.log(id, error.map { "background failed " + $0.localizedDescription } ?? "background started")
                self.revision += 1
            }
        }
    }

    /// What WebKit said went wrong with one, in its words: its background
    /// not starting, a manifest key it doesn't take.
    @ObservationIgnored private var trouble: [String: String] = [:]

    func problems(_ id: String) -> [String] {
        _ = revision
        var out = trouble[id].map { [$0] } ?? []
        out += (contexts[id]?.errors ?? []).map(\.localizedDescription)
        out += (contexts[id]?.webExtension.errors ?? []).map(\.localizedDescription)
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// The same errors whole, with what lies under each, for the probe.
    func problemDetails(_ id: String) -> [String] {
        let errors = (contexts[id]?.errors ?? []) + (contexts[id]?.webExtension.errors ?? [])
        return errors.map { error in
            let ns = error as NSError
            var line = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
            if let reason = ns.localizedFailureReason { line += " (\(reason))" }
            if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                line += " <- \(under.domain) \(under.code): \(under.localizedDescription) \(under.userInfo)"
            }
            return line
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(installed).write(to: Self.list, options: .atomic)
    }

    // MARK: - actions on the page menu

    /// The enabled ones' buttons for the tab in front.
    func buttons() -> [Button] {
        _ = revision
        let tab = activeTab()
        return installed.filter(\.enabled).compactMap { item in
            guard let context = contexts[item.id] else { return nil }
            let action = context.action(for: tab)
            return Button(id: item.id, name: item.name, label: action?.label.isEmpty == false ? action!.label : item.name,
                          badge: action?.badgeText ?? "", icon: action?.icon(for: CGSize(width: 24, height: 24)) ?? context.webExtension.icon(for: CGSize(width: 24, height: 24)))
        }
    }

    /// Its button pressed on the page menu: its popup, or what it does.
    func press(_ id: String) {
        guard let context = contexts[id] else { return }
        // A popup it set itself (action.setPopup, ExtensionShim) when WebKit has none.
        if context.action(for: activeTab())?.presentsPopup != true, let path = ExtensionShim.popups[id],
           let url = URL(string: path, relativeTo: context.baseURL)?.absoluteURL, let configuration = context.webViewConfiguration {
            let page = UIViewController()
            let web = WKWebView(frame: .zero, configuration: configuration)
            web.load(URLRequest(url: url))
            page.view = web
            page.view.accessibilityIdentifier = "extensions.popup"
            present(page)
            return
        }
        context.performAction(for: activeTab())
    }

    /// The space in front's tabs as an extension reads them by index (tabs.describe).
    func visibleTabs() -> [(url: String, title: String)] {
        tabsInFront().map { tab in
            let model = model(tab.id)
            return ((liveView(tab.id)?.url ?? model?.navigationURL)?.absoluteString ?? "", liveView(tab.id)?.title ?? model?.title ?? "")
        }
    }

    func openOptions(_ id: String) {
        guard let url = contexts[id]?.optionsPageURL else { return }
        _ = openTab(url, front: true)
    }

    func hasOptions(_ id: String) -> Bool { contexts[id]?.optionsPageURL != nil }

    /// Loaded in an earlier launch (not installed just now): its worker
    /// restores rather than starts fresh.
    func loadedBefore(_ id: String) -> Bool { launchLoaded.contains(id) }
    @ObservationIgnored private var launchLoaded: Set<String> = []

    /// The configuration a view showing one of an extension's pages is made with.
    func configuration(for url: URL) -> WKWebViewConfiguration? {
        guard Self.isExtensionPage(url), let controller else { return nil }
        return controller.extensionContext(for: url)?.webViewConfiguration
    }

    // MARK: - sheets

    fileprivate static func top() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    fileprivate func present(_ controller: UIViewController, large: Bool = false) {
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = large ? [.large()] : [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 38
        }
        Self.top()?.present(controller, animated: !Motion.disabled)
    }

    /// The list: every extension, on or off, its options, Remove; the store.
    func showList() {
        let view = ExtensionsList().environment(self)
        let host = UIHostingController(rootView: view)
        host.view.accessibilityIdentifier = "extensions.list"
        present(host, large: true)
    }

    /// The store's page for an extension: added after a yes.
    func offer(_ id: String) {
        guard let app else { return }
        if installed.contains(where: { $0.id == id }) { app.say("Already in Yab", glyph: .checkmark1); return }
        Task {
            do {
                let (name, reach, verdict) = try await preview(id)
                // One that can't work on an iPhone isn't offered: why, and OK.
                if verdict.kind == .blocked {
                    let sheet = UIAlertController(title: "“\(name)” doesn't work on \(DeviceWord.name) yet", message: verdict.reason, preferredStyle: .alert)
                    sheet.view.accessibilityIdentifier = "extensions.blocked"
                    sheet.addAction(UIAlertAction(title: "OK", style: .cancel))
                    Self.top()?.present(sheet, animated: !Motion.disabled)
                    return
                }
                let message = verdict.kind == .limited ? reach + "\n\n" + verdict.reason : reach
                let sheet = UIAlertController(title: "Add “\(name)”?", message: message, preferredStyle: .alert)
                sheet.view.accessibilityIdentifier = "extensions.offer"
                sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                sheet.addAction(UIAlertAction(title: "Add", style: .default) { _ in
                    Task { @MainActor in
                        do {
                            let item = try await self.install(id)
                            app.say("Added \(item.name)", glyph: .checkmark1)
                        } catch {
                            app.say(error.localizedDescription, glyph: .exclamationCircle)
                        }
                    }
                })
                Self.top()?.present(sheet, animated: !Motion.disabled)
            } catch {
                app.say(error.localizedDescription, glyph: .exclamationCircle)
            }
        }
    }
}

// MARK: - WebKit's questions

extension ExtensionHost: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        note("new tab \(configuration.url?.absoluteString.prefix(60) ?? "")")
        return openTab(configuration.url, front: configuration.shouldBeActive)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        // One window on a phone: its first address as a tab in front.
        _ = openTab(configuration.tabURLs.first, front: configuration.shouldBeFocused)
        return window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        if let url = extensionContext.optionsPageURL { _ = openTab(url, front: true) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        note("asks \(permissions.map(\.rawValue).sorted().joined(separator: ","))")
        // What it asked for at install was granted with the yes then.
        return (permissions.intersection(extensionContext.webExtension.requestedPermissions.union(extensionContext.webExtension.optionalPermissions)), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        (urls, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        (matchPatterns, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for extensionContext: WKWebExtensionContext) async throws {
        note("popup \(extensionContext.uniqueIdentifier.prefix(6))")
        guard let popup = action.popupViewController else { return }
        popup.view.accessibilityIdentifier = "extensions.popup"
        // The page menu goes first, as a tap on one of its rows does.
        if let app, app.surfaces.menu == .plate { app.surfaces.closeMenu(); app.pageMenu.reset() }
        present(popup)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        revision += 1
    }

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext) async throws -> Any? {
        if applicationIdentifier == nil || applicationIdentifier == ExtensionShim.application {
            return await ExtensionShim.answer(message, from: extensionContext)
        }
        note("native message \(applicationIdentifier ?? "")")
        // No other app on an iPhone answers a browser extension.
        throw NSError(domain: "Yab", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native messaging is not available on \(DeviceWord.name)"])
    }
}

// MARK: - tabs and the window, as WebKit sees them

@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    weak var host: ExtensionHost?
    let id: Tab.ID
    init(host: ExtensionHost, id: Tab.ID) { self.host = host; self.id = id }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        host.flatMap { $0.focused() }
    }
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        host?.tabsInFront().firstIndex { $0 === self } ?? NSNotFound
    }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { host?.liveView(id) }
    func title(for context: WKWebExtensionContext) -> String? { host?.liveView(id)?.title ?? host?.model(id)?.title }
    func url(for context: WKWebExtensionContext) -> URL? { host?.liveView(id)?.url ?? host?.model(id)?.navigationURL }
    func isSelected(for context: WKWebExtensionContext) -> Bool { host?.isFront(id) ?? false }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(host?.liveView(id)?.isLoading ?? false) }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { host?.model(id)?.isPrivate ?? false }
    func activate(for context: WKWebExtensionContext) async throws { host?.activate(id) }
    func close(for context: WKWebExtensionContext) async throws { host?.close(id) }
    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws { host?.load(url, in: id) }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws { _ = host?.liveView(id)?.reload() }
    func goBack(for context: WKWebExtensionContext) async throws { _ = host?.liveView(id)?.goBack() }
    func goForward(for context: WKWebExtensionContext) async throws { _ = host?.liveView(id)?.goForward() }
}

@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var host: ExtensionHost?
    init(host: ExtensionHost) { self.host = host }
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { host?.tabsInFront() ?? [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { host?.activeTab() }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .fullscreen }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { host?.app?.browser.space.isPrivate ?? false }
    func frame(for context: WKWebExtensionContext) -> CGRect { CGRect(origin: .zero, size: Metrics.screen) }
}

extension ExtensionHost {
    fileprivate func focused() -> ExtensionWindow { window }
}
