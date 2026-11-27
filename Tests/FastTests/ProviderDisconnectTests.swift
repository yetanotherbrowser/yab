import Foundation
import Testing
@testable import Fast

@MainActor
struct ProviderDisconnectTests {
    private func isolated() -> (ProviderConsent, UserDefaults, String) {
        let domain = "disconnect-policy-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        return (ProviderConsent(settings: settings, history: []), settings, domain)
    }
    private func child(_ args: [String], binary: String = "/usr/bin/true") -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary); process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        return process
    }
    private var remove: [String] { ["mcp", "remove", "--scope", "user", AgentSetup.server] }

    @Test func cancelClearsOnlyItsOwnedWorkingStateAndOldDeferCannotClearARetry() {
        let (consent, settings, domain) = isolated()
        defer { settings.removePersistentDomain(forName: domain) }
        let model = AgentSetupModel(status: AgentSetup.Status(), consent: consent)
        let old = model.beginDisconnectWork("claude")
        #expect(model.working == "claude" && model.busy)
        model.cancel()
        #expect(model.working == nil && !model.busy)
        let retry = model.beginDisconnectWork("claude")
        model.endDisconnectWork(old)
        #expect(model.working == "claude" && model.busy)
        model.endDisconnectWork(retry)
        #expect(model.working == nil && !model.busy)
    }

    @Test func oldDisconnectCannotRemoveAReconnectedConfigOrStartItsQueuedHelper() throws {
        let (consent, settings, domain) = isolated()
        defer { settings.removePersistentDomain(forName: domain) }
        consent.grant("claude"); consent.revoke("claude")
        let old = try #require(consent.disconnectPermit("claude"))
        defer { old.revoke() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("synthetic-config")
        try "new connection".write(to: config, atomically: true, encoding: .utf8)
        consent.beginConnection("claude")
        #expect(consent.connectionPermit("claude")?.valid == true)
        #expect(!old.commit { try? FileManager.default.removeItem(at: config) })
        let queued = child(remove)
        #expect(try !Shell.start(queued, permit: nil, disconnect: old.bound(to: "/usr/bin/true")))
        #expect(!queued.isRunning)
        #expect(try String(contentsOf: config, encoding: .utf8) == "new connection")
        consent.grant("claude")
        #expect(!old.valid && consent.allows("claude"))
    }

    @Test func cleanupIsSingleUseExactLocalArgvAndNeverProviderAuthority() throws {
        let (consent, settings, domain) = isolated()
        defer { settings.removePersistentDomain(forName: domain) }
        consent.revoke("claude")
        let permit = try #require(consent.disconnectPermit("claude"))
        defer { permit.revoke() }
        let bound = permit.bound(to: "/usr/bin/true")
        for args in [["-p", "synthetic AI prompt"], ["auth", "status"], ["logout"],
                     ["mcp", "add", "--scope", "user", AgentSetup.server, "--", "/fixture/app", "mcp"]] {
            #expect(try !Shell.start(child(args), permit: nil, disconnect: bound))
        }
        let removed = child(remove)
        #expect(try Shell.start(removed, permit: nil, disconnect: bound))
        removed.waitUntilExit()
        #expect(try !Shell.start(child(remove), permit: nil, disconnect: bound))
        #expect(!consent.allows("claude") && consent.permit("claude") == nil)
        consent.revoke("codex")
        let codex = try #require(consent.disconnectPermit("codex"))
        defer { codex.revoke() }
        let loggedOut = child(["logout"])
        #expect(try Shell.start(loggedOut, permit: nil, disconnect: codex.bound(to: "/usr/bin/true")))
        loggedOut.waitUntilExit()
        #expect(!consent.allows("codex"))
    }

    @Test func aNewConnectionWaitsForItsOldCleanupChildBeforeWritingConfig() async throws {
        let (consent, settings, domain) = isolated()
        defer { settings.removePersistentDomain(forName: domain) }
        consent.revoke("claude")
        let permit = try #require(consent.disconnectPermit("claude"))
        defer { permit.revoke() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("synthetic-cleanup")
        let marker = root.appendingPathComponent("started")
        let config = root.appendingPathComponent("config")
        try "#!/bin/sh\nprintf running > started\ntrap '' TERM\nsleep 30\nprintf stale > config\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let running = child(remove, binary: script.path)
        running.currentDirectoryURL = root; running.environment = ["PATH": "/usr/bin:/bin"]
        defer { if running.isRunning { Shell.end(running, grace: 0) } }
        #expect(try Shell.start(running, permit: nil, disconnect: permit.bound(to: script.path)))
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(for: .milliseconds(10)) }
        try #require(FileManager.default.fileExists(atPath: marker.path))
        consent.beginConnection("claude")
        let first = Task { @MainActor in await consent.settleDisconnects(); return !running.isRunning }
        await Task.yield()
        consent.cancelConnections()
        consent.beginConnection("claude")
        let retry = Task { @MainActor in await consent.settleDisconnects(); return !running.isRunning }
        #expect(await first.value)
        #expect(await retry.value, "A cancel/retry must share the original cleanup's retirement barrier")
        #expect(!running.isRunning)
        try "new connection".write(to: config, atomically: true, encoding: .utf8)
        #expect(!permit.commit { try? "stale".write(to: config, atomically: true, encoding: .utf8) })
        #expect(try String(contentsOf: config, encoding: .utf8) == "new connection")
    }

    @Test func oldDisconnectCannotClearReconnectedOpenCodeConnectionKey() async throws {
        let (consent, settings, domain) = isolated()
        defer { settings.removePersistentDomain(forName: domain) }
        let prior = Store.settings.object(forKey: OpenCodeRunner.connectionKey)
        defer {
            if let prior { Store.settings.set(prior, forKey: OpenCodeRunner.connectionKey) }
            else { Store.settings.removeObject(forKey: OpenCodeRunner.connectionKey) }
        }
        Store.settings.set(true, forKey: OpenCodeRunner.connectionKey)
        consent.grant("opencode")
        consent.revoke("opencode")
        let staleDisconnect = try #require(consent.disconnectPermit("opencode"))
        defer { staleDisconnect.revoke() }
        consent.beginConnection("opencode")
        let found = Shell.Found(claude: nil, codex: nil, opencode: "/oc", env: [:])
        await AgentSetup.remove(found, only: ["opencode"], disconnects: ["opencode": staleDisconnect])
        #expect(Store.settings.bool(forKey: OpenCodeRunner.connectionKey))

        consent.revoke("opencode")
        let validDisconnect = try #require(consent.disconnectPermit("opencode"))
        defer { validDisconnect.revoke() }
        await AgentSetup.remove(found, only: ["opencode"], disconnects: ["opencode": validDisconnect])
        #expect(Store.settings.object(forKey: OpenCodeRunner.connectionKey) == nil)
    }
}
