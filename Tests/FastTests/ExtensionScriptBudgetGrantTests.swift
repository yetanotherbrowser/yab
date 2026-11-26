import AppKit
import Foundation
import Testing
import WebKit
import YabCoreClient
@testable import Fast

/// The script budget held through the grant routes of a real loaded context:
/// a grant that would pass it is refused before any setting or native grant
/// changes, and one under it is given.
@MainActor
@Suite(.serialized)
struct ExtensionScriptBudgetGrantTests {
    /// Three files in one group naming every host, and the shim install adds beside them.
    private static let hosts = (0..<80).map { "h\($0).example" }

    @MainActor
    private final class Fixture {
        let signIn = UUID()
        // Shaped as Chrome's, so a Chromium row can name it.
        let id = String((0..<32).map { _ in "abcdefghijklmnop".randomElement()! })
        let root: URL
        let owner: Extensions
        let savedPrivate: Any?

        init() throws {
            try #require(Store.testing)
            _ = NSApplication.shared
            savedPrivate = Store.settings.object(forKey: "extensions.private")
            root = FileManager.default.temporaryDirectory.appendingPathComponent("script-budget-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: Extensions.folder, withIntermediateDirectories: true)
            Store.settings.set(false, forKey: "extensions.private")
            owner = Extensions(signIn: signIn)
        }

        func load() async throws -> WKWebExtensionContext {
            let staged = root.appendingPathComponent("staged", isDirectory: true)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            for name in ["a.js", "b.js", "c.js"] { try Data("void 0".utf8).write(to: staged.appendingPathComponent(name)) }
            let manifest: [String: Any] = [
                "manifest_version": 3, "name": "Script budget", "version": "1.0",
                "host_permissions": ["https://h0.example/*"],
                "optional_host_permissions": hosts.flatMap { ["*://\($0)/*", "*://*.\($0)/*"] },
                // One pattern, so loading grants it once rather than every host.
                "content_scripts": [["matches": ["https://*.example/*"], "js": ["a.js", "b.js", "c.js"]]],
            ]
            try JSONSerialization.data(withJSONObject: manifest).write(to: staged.appendingPathComponent("manifest.json"))
            let found = try await WKWebExtension(resourceBaseURL: staged)
            let loaded = try await owner.admit(staged, as: id, fromStore: false,
                                               finalFolder: Extensions.folder(for: id), confirm: false, quiet: true,
                                               synced: .init(enabled: true, pinned: false, allowed: Extensions.grants(found, in: staged)))
            try #require(loaded)
            let context = try #require(owner.contexts[id])
            try #require(context.isLoaded)
            return context
        }

        /// How many hosts fit: each host allowed is two patterns, each copying every installed file.
        func fit() throws -> Int {
            let url = Extensions.folder(for: id).appendingPathComponent("manifest.json")
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
            let groups = manifest["content_scripts"] as? [[String: Any]] ?? []
            let one = WebKitIPCBoundary.Grants(patterns: Extensions.patterns(for: "h1.example"), allHosts: false)
            let perHost = WebKitIPCBoundary.injectedScripts(groups, grants: one)
            try #require(perHost >= 6)
            return WebKitIPCBoundary.scriptLimit / perHost
        }

        func cleanUp() {
            owner.remove(id)
            owner.shutDown()
            if let savedPrivate { Store.settings.set(savedPrivate, forKey: "extensions.private") }
            else { Store.settings.removeObject(forKey: "extensions.private") }
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: Extensions.signIns.appendingPathComponent(signIn.uuidString, isDirectory: true))
        }
    }

    private static func granted(_ context: WKWebExtensionContext) -> Set<String> {
        Set(context.grantedPermissionMatchPatterns.keys.map(\.string))
    }

    private static func page(_ host: String) -> URL { URL(string: "https://\(host)/page")! }

    @Test func aTrialMirrorsTheLiveGrants() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let context = try await fixture.load()
        fixture.owner.setAccess(fixture.id, .sites)
        for host in Self.hosts.prefix(3) { try #require(fixture.owner.allow(host, for: fixture.id)) }
        fixture.owner.block("h1.example", for: fixture.id)
        let trial = fixture.owner.trial(of: context)
        #expect(Self.granted(trial) == Self.granted(context))
        #expect(trial.hasAccessToAllHosts == context.hasAccessToAllHosts)

        // A trial must take each kind of change as the loaded context does.
        let steps: [(String, WKWebExtensionContext.PermissionStatus)] = [
            ("<all_urls>", .grantedExplicitly), ("*://h5.example/*", .grantedExplicitly),
            ("<all_urls>", .unknown), ("*://*.h2.example/*", .deniedExplicitly), ("*://*/*", .deniedExplicitly),
            ("*://h5.example/*", .unknown),
        ]
        for (string, status) in steps {
            let pattern = try WKWebExtension.MatchPattern(string: string)
            context.setPermissionStatus(status, for: pattern)
            trial.setPermissionStatus(status, for: pattern)
            #expect(Self.granted(trial) == Self.granted(context), "after \(string) → \(status.rawValue)")
            #expect(trial.hasAccessToAllHosts == context.hasAccessToAllHosts)
        }
    }

    @Test func allowingASitePastTheBudgetLeavesGrantsUnchanged() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let context = try await fixture.load()
        try #require(fixture.owner.setAccess(fixture.id, .sites))
        let count = try fixture.fit()
        let fit = Array(Self.hosts.prefix(count))
        for host in fit { #expect(fixture.owner.allow(host, for: fixture.id)) }
        #expect(context.hasAccess(to: Self.page(fit.last!)))

        let before = Self.granted(context)
        let next = Self.hosts[count]
        #expect(!fixture.owner.allow(next, for: fixture.id))
        #expect(fixture.owner.allowed(fixture.id) == fit)
        #expect(Self.granted(context) == before)
        #expect(!context.hasAccess(to: Self.page(next)))
        // Taking access away is never refused.
        #expect(fixture.owner.setAccess(fixture.id, .click))
    }

    @Test func turningOnChosenSitesPastTheBudgetKeepsTheOldAccess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let context = try await fixture.load()
        try #require(fixture.owner.setAccess(fixture.id, .click))
        // Chosen while it waits to be pressed: kept, given nothing yet.
        let over = Self.hosts.prefix(try fixture.fit() + 1).flatMap(Extensions.patterns(for:))
        #expect(fixture.owner.give(sites: over, to: context))
        let before = Self.granted(context)

        #expect(!fixture.owner.setAccess(fixture.id, .asked))
        #expect(fixture.owner.access(fixture.id) == .click)
        #expect(Self.granted(context) == before)
    }

    @Test func narrowingToChosenSitesPastTheBudgetStillApplies() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let context = try await fixture.load()
        let count = try fixture.fit()
        let chosen = Array(Self.hosts.prefix(count + 3))
        fixture.owner.adopt(sites: chosen, for: fixture.id)

        #expect(fixture.owner.setAccess(fixture.id, .sites))
        #expect(fixture.owner.access(fixture.id) == .sites)
        #expect(fixture.owner.allowed(fixture.id) == chosen)
        #expect(context.hasAccess(to: Self.page(chosen[count - 1])))
        #expect(!context.hasAccess(to: Self.page(chosen[count])))
        #expect(fixture.owner.errors[fixture.id]?.contains { $0.hasPrefix("Not running on \(chosen[count])") } == true)
    }

    @available(macOS 15.4, *)
    @Test func chromiumSitesPastTheBudgetAreKeptForChromium() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let context = try await fixture.load()
        let chosen = Array(Self.hosts.prefix(try fixture.fit() + 3))
        let held = JSONValue.object([
            "hostAccess": .string("ON_SPECIFIC_SITES"),
            "hosts": .array(chosen.map { .object(["host": .string("*://\($0)/*"), "granted": .bool(true)]) }),
        ])
        let row = try ChromiumExtensions.Item(.object([
            "id": .string(fixture.id), "name": .string("Script budget"), "state": .string("ENABLED"), "access": held,
        ]))
        ChromiumExtensionGrants.adoptAccess([row], into: fixture.owner)

        #expect(fixture.owner.access(fixture.id) == .sites)
        #expect(fixture.owner.allowed(fixture.id) == chosen)
        #expect(!context.hasAccess(to: Self.page(chosen.last!)))
        let change = ChromiumExtensionGrants.accessChange(row, access: fixture.owner.access(fixture.id),
                                                          allowed: fixture.owner.allowed(fixture.id))
        #expect(change?.remove.isEmpty ?? true)
    }

    @Test func anOptionalSiteRequestPastTheBudgetIsRefusedUnasked() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let context = try await fixture.load()
        fixture.owner.answerForTests = true
        let over = Set(Self.hosts.prefix(try fixture.fit() + 1).flatMap(Extensions.patterns(for:)))
        let asked = fixture.owner.asked.count
        let before = Self.granted(context)
        let (refused, _) = await fixture.owner.webExtensionController(
            fixture.owner.controller, promptForPermissionMatchPatterns: over, in: nil, for: context)
        #expect(refused.isEmpty)
        #expect(fixture.owner.asked.count == asked)
        #expect(Self.granted(context) == before)
        #expect(Extensions.choices(fixture.id).isEmpty)

        let under = Set(Self.hosts.prefix(2).flatMap(Extensions.patterns(for:)))
        let (given, _) = await fixture.owner.webExtensionController(
            fixture.owner.controller, promptForPermissionMatchPatterns: under, in: nil, for: context)
        #expect(given == under)
    }
}
