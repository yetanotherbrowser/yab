import AppKit
import YabCoreClient

/// One lazy page process per application. The socket is private and disposable;
/// the data root is stable within Store's app/test world.
@MainActor
final class ChromiumProcess {
    static let shared = ChromiumProcess()
    private var client: YabCoreClient?
    var originalCallerDiagnostic: ChromiumOriginalCallerDiagnostic?
    var mayBeginOriginalCallerDiagnostic: Bool { originalCallerDiagnostic == nil && client == nil && process == nil && starting == nil }
    private var nativeHooks: [String: JSONValue] = [:]
    private var starting: Task<YabCoreClient, Error>?
    private var process: Process?
    /// That helper's end, from its termination handler.
    private var processExit: ChildExit?
    var processID: pid_t? { process?.isRunning == true ? process?.processIdentifier : nil }
    private var directory: URL?
    private var generation = UUID()
    private var pages: [String: WeakPage] = [:]
    private var early: [YabCoreEvent] = []
    private var adopting: Set<String> = []
    private var downloads: [String: ChromiumDownload] = [:]
    private var endingRenderers: [String: Task<Void, Never>] = [:]
    private var losses: [Date] = []
    private struct WeakPage { weak var value: ChromiumPage? }

    /// Local mirrors only. A census never creates or wakes a remote page.
    var livePages: [ChromiumPage] { pages.values.compactMap(\.value) }
    /// Popup retirement must never start a replacement helper.
    var connectedClient: YabCoreClient? { client }
    /// Stock CEF forwards Cocoa composition but has no external text-state
    /// callback. Only an explicit capability denial selects that legacy path.
    var legacyTextInput: Bool { ChromiumNativeTextInput.usesLegacyHelper(nativeHooks["nativeTextInput"]) }
    /// The helper runs an extension's named command for a page (CEF patch
    /// 0116, `extension.command.run`); the button's command needs no more
    /// than its press.
    var runsExtensionCommands: Bool { nativeHooks["extensionCommands"] == .bool(true) || nativeHooks["extensionCommands"] == .number(1) }
    /// The helper can slow a page's frames and keep it shown (CEF patch 0137,
    /// `tab.frames`). The stock SDK can't.
    var pacesFrames: Bool { nativeHooks["frameInterval"] == .bool(true) || nativeHooks["frameInterval"] == .number(1) }
    /// Identity of this helper lifetime, never a renderer document identity.
    var connectionGeneration: UUID { generation }
    func isCurrent(_ core: YabCoreClient) -> Bool { client === core }
    func isCurrent(_ core: YabCoreClient, generation expected: UUID) -> Bool {
        client === core && generation == expected
    }
    /// CEF patch 0124: the extension's own rows of its button's menu
    /// (contextMenus of context "action"), its omnibox keyword's events, and
    /// chrome.sidePanel.setOptions as it happens. Without it (the 0.46.29
    /// SDK) the menu has Yab's rows only, the keyword isn't the field's, and
    /// a panel follows the tab in front but not a live setOptions.
    var extensionSurfaces: (actionMenu: Bool, omnibox: Bool, panelOptions: Bool) {
        // A bool, or 1: YabCore boxes its macros as numbers (@(1)).
        let on = { (name: String) in self.nativeHooks[name] == .bool(true) || self.nativeHooks[name] == .number(1) }
        return (on("extensionActionMenu"), on("extensionOmnibox"), on("sidePanelOptions"))
    }

    /// The helper as far as its hello, off the main thread from the app's first
    /// moments: a launch holds that thread 100 to 200 ms past the first page's
    /// asking, and the helper's own half second needs nothing from it. Chrome's
    /// browser process is up before its window for the same reason.
    private struct Ahead: @unchecked Sendable {
        let child: Process
        let exit: ChildExit
        let directory: URL
        let core: YabCoreClient
    }
    private nonisolated(unsafe) static var ahead: Task<Ahead, Error>?

    /// A helper that is running is starting, however long CEF takes: the
    /// first run after an update, a loaded Mac. At 20 s it was ended and a
    /// second one started as cold, and the pages waiting failed with
    /// "YabCore did not start" (transport, code 2: R2524). Its exit still ends the wait at once.
    nonisolated static let startAllowance: TimeInterval = 120
    static func startAhead() {
        guard PageEngineFactory.chromiumEnabled, !Store.unitTests, !Headless.on, !LinkGap.cut("chromium.ahead") else { return }
        ahead = Task.detached(priority: .userInitiated) {
            sweepSockets()
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yc-" + UUID().uuidString.prefix(8))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let socket = dir.appendingPathComponent("core.sock").path
            let child = Process()
            child.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/YabCore.app/Contents/MacOS/YabCore")
            let exit = try configure(child, socket: socket)
            let peer = NativePeerIdentity.prepareLaunch(child)
            OpenTrace.mark("chromium.helper.run")
            try child.runValidated()
            exit.launched(pid: child.processIdentifier)
            let witness = peer?.captureLaunched()
            do {
                let until = Date().addingTimeInterval(Self.startAllowance)
                while !FileManager.default.fileExists(atPath: socket) {
                    guard child.isRunning, Date() < until else { throw YabCoreError.transport("YabCore did not start") }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                OpenTrace.mark("chromium.helper.socket")
                let core = try await YabCoreClient.connect(path: socket, originalLaunch: witness)
                OpenTrace.mark("chromium.helper.hello")
                return Ahead(child: child, exit: exit, directory: dir, core: core)
            } catch {
                if child.isRunning { child.terminate() }
                throw error
            }
        }
    }

    /// Shared by eager and lazy startup. Keep audio attributed to the containing
    /// Yab application: SCK app filters omit the separate CEF audio utility.
    /// Audio stays outside Swift UI, but loses its utility-process isolation.
    nonisolated static func launchArguments(socket: String, dataRoot: URL) -> [String] {
        ["--socket=" + socket, "--data-root=" + dataRoot.path,
         "--disable-features=AudioServiceOutOfProcess"]
    }

    /// What the helper is started with, however it is started. Its end is
    /// watched from here, before it runs, so no exit goes unseen.
    private nonisolated static func configure(_ child: Process, socket: String) throws -> ChildExit {
        ChromiumNativeHosts.refreshAppleBeforeLaunch(dataRoot: Store.file("Chromium"))
        // Keep Chrome’s native recovery of visible failed documents enabled.
        child.arguments = launchArguments(socket: socket, dataRoot: Store.file("Chromium"))
        // Read the owning app's language choice, including an isolated probe
        // world's AppleLanguages. The helper has a different defaults domain.
        let languages = languageTags(Store.settings.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages)
        child.arguments?.append("--lang=" + (languages.first ?? "en-US"))
        child.arguments?.append("--accept-lang=" + languages.joined(separator: ","))
        if Store.testing {
            // Chromium switches to try in a test world, joined by spaces.
            if let more = ProcessInfo.processInfo.environment["YAB_HELPER_ARGS"] {
                child.arguments?.append(contentsOf: more.split(separator: " ").map(String.init))
            }
            // YAB_REAL_KEYCHAIN: a folder standing in for the helper's home,
            // whose search list holds a throwaway keychain. The real
            // keychain code runs; the Mac's login keychain is not touched.
            if let home = ProcessInfo.processInfo.environment["YAB_REAL_KEYCHAIN"], !home.isEmpty {
                var environment = ProcessInfo.processInfo.environment
                environment["HOME"] = home
                child.environment = environment
            } else {
                child.arguments?.append("--use-mock-keychain")
            }
            if ProcessInfo.processInfo.environment["YAB_CHROMIUM_FAKE_MEDIA"] == "1" {
                child.arguments?.append("--use-fake-device-for-media-stream")
            }
        }
        // Avoid pipe backpressure; the farm app log owns stderr.
        child.standardOutput = FileHandle.standardError
        child.standardError = FileHandle.standardError
        let broker: ChromiumSafeStorageBroker?
        if child.arguments?.contains("--use-mock-keychain") == true { broker = nil }
        else {
            let path = URL(fileURLWithPath: socket).deletingLastPathComponent().appendingPathComponent("key.sock").path
            guard let helper = child.executableURL else { throw YabCoreError.transport("YabCore executable is missing") }
            broker = try ChromiumSafeStorageBroker(path: path, authorize: { ChromiumSafeStorage.authorizes(pid: $0, helper: helper) })
            child.arguments?.append("--yab-safe-storage-socket=" + path)
        }
        return ChildExit(watching: child, safeStorage: broker)
    }

    nonisolated static func languageTags(_ preferred: [String]) -> [String] {
        var tags: [String] = []
        for language in preferred {
            var tag = language.replacingOccurrences(of: "_", with: "-")
            // Chromium's packaged Simplified/Traditional Chinese locales.
            if tag == "zh-Hans" || tag.hasPrefix("zh-Hans-") { tag = "zh-CN" }
            if tag == "zh-Hant" || tag.hasPrefix("zh-Hant-") { tag = "zh-TW" }
            guard !tag.isEmpty, tag.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  !tags.contains(tag) else { continue }
            tags.append(tag)
        }
        return tags.isEmpty ? ["en-US"] : tags
    }

    /// A connected helper's events, for as long as it is this one.
    private func adopt(_ core: YabCoreClient, token: UUID) async {
        nativeHooks = await core.nativeHooks
        await ChromiumEnergySaver.apply(to: core)
        client = core
        ChromiumGeolocation.connected(hooks: nativeHooks)
        ChromiumTabGroups.shared.start()
        ShieldChromium.tell()
        Task { @MainActor [weak self] in
            for await event in core.events {
                guard let self, self.generation == token else { return }
                self.receive(event, from: core, generation: token)
            }
            guard let self, self.generation == token else { return }
            self.exited(endedBy: await core.endedBy)
        }
    }

    func connection() async throws -> YabCoreClient {
        if let client { return client }
        if let starting { return try await starting.value }
        if let diagnostic = originalCallerDiagnostic {
            guard !diagnostic.launchConsumed else { throw YabCoreError.disconnected }
            diagnostic.launchConsumed = true // Failed/lost original diagnostic never reconnects.
        }
        let token = UUID()
        generation = token
        let early = Self.ahead
        Self.ahead = nil
        ChromiumPersistentProfiles.sweepErased()
        // A helper started ahead swept before it spawned, and may still be binding.
        if early == nil { Self.sweepSockets() }
        let task = Task { @MainActor () throws -> YabCoreClient in
            if let early, let started = try? await early.value {
                if originalCallerDiagnostic == nil {
                    directory = started.directory
                    process = started.child
                    processExit = started.exit
                    await adopt(started.core, token: token)
                    return started.core
                }
                // That diagnostic watches a helper's birth, and two can't share a data root.
                started.child.terminate()
                await Task.detached { started.child.waitUntilExit() }.value
            }
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yc-" + UUID().uuidString.prefix(8))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            directory = dir
            let socket = dir.appendingPathComponent("core.sock").path
            // SwiftPM's synchronous AppKit host is outside an app bundle.
            // Tests point to the exact CEF app assembled in this farm job.
            let testApp = Store.unitTests ? ProcessInfo.processInfo.environment["YAB_TEST_CEF_APP"] : nil
            let app = testApp.map { URL(fileURLWithPath: $0) } ?? Bundle.main.bundleURL
            let helper = app.appendingPathComponent("Contents/Frameworks/YabCore.app/Contents/MacOS/YabCore")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                throw YabCoreError.transport("This dev app has no YabCore helper. Build with YAB_CEF=1.")
            }
            let child = Process()
            child.executableURL = helper
            let exit = try Self.configure(child, socket: socket)
            let preparedPeer: NativePeerIdentity.PreparedLaunch?
            if let diagnostic = originalCallerDiagnostic {
                child.arguments?.append("--observe-original-caller")
                if diagnostic.deadline { child.arguments?.append("--original-caller-deadline-gate") }
                switch NativePeerIdentity.prepareDiagnosticLaunchResult(child) {
                case .prepared(let prepared): preparedPeer = prepared
                case .helperImageRefused:
                    diagnostic.helperImageRefused = true
                    throw YabCoreError.transport("Original diagnostic exact helper image refused")
                case .unavailable: throw YabCoreError.transport("Original diagnostic static helper preparation unavailable")
                }
            } else { preparedPeer = NativePeerIdentity.prepareLaunch(child) }
            OpenTrace.mark("chromium.helper.run")
            try child.runValidated()
            exit.launched(pid: child.processIdentifier)
            let originalPeer = preparedPeer?.captureLaunched() // Actual same child, before the first await.
            process = child
            processExit = exit
            originalCallerDiagnostic?.process = child
            originalCallerDiagnostic?.witness = originalPeer
            do {
                if originalCallerDiagnostic != nil && originalPeer == nil {
                    throw YabCoreError.transport("Original diagnostic child birth witness unavailable")
                }
                let until = Date().addingTimeInterval(Self.startAllowance)
                while !FileManager.default.fileExists(atPath: socket) {
                    guard child.isRunning, Date() < until else { throw YabCoreError.transport("YabCore did not start") }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                OpenTrace.mark("chromium.helper.socket")
                let core = try await YabCoreClient.connect(path: socket, originalLaunch: originalPeer)
                OpenTrace.mark("chromium.helper.hello")
                await adopt(core, token: token)
                originalCallerDiagnostic?.client = core
                return core
            } catch {
                if child.isRunning { child.terminate() }
                throw error
            }
        }
        starting = task
        do { let core = try await task.value; starting = nil; return core }
        catch { starting = nil; exited(endedBy: nil, starting: true); throw error }
    }

    func attach(_ page: ChromiumPage, id: String) {
        pages[id] = WeakPage(value: page)
        let buffered = early.filter { $0.tab == id }
        early.removeAll { $0.tab == id }
        if let client {
            page.refreshNativeMediaState(core: client, remote: id, hooks: nativeHooks)
            page.refreshOriginalPDFPresence(core: client, remote: id, hooks: nativeHooks)
        }
        buffered.forEach(page.receive)
        page.accessibilityAttached()
    }
    func detach(_ id: String) {
        pages.removeValue(forKey: id)
        guard let client else { return }
        let ending = endingRenderers.removeValue(forKey: id)
        Task {
            await ending?.value
            try? await client.closeTab(id)
        }
    }

    /// Ending a hung renderer must survive retirement of its page and must
    /// precede closing its native browser. Never start a helper for cleanup.
    func endRenderer(tab id: String, pid: pid_t) {
        guard let client, endingRenderers[id] == nil else { return }
        endingRenderers[id] = Task {
            _ = try? await client.request("page.killRenderer", params: ["tab": .string(id), "rendererPID": .number(Double(pid))])
            self.endingRenderers[id] = nil
        }
    }
    func keepDownload(_ download: ChromiumDownload) { downloads[download.remoteID] = download }
    private func receive(_ event: YabCoreEvent, from source: YabCoreClient, generation sourceGeneration: UUID) {
        guard isCurrent(source, generation: sourceGeneration) else { return }
        if ChromiumDRMExtensionSession.receive(event, from: client) { return }
        if ChromiumConsent.receive(event, from: client) { return }
        if ChromiumDesktopMedia.receive(event, from: client) { return }
        if ChromiumWebAuthn.receive(event, from: client) { return }
        if ChromiumGeolocation.receive(event) { return }
        if ChromiumColumn.receive(event) { return }
        if ChromiumExtensionTabs.receive(event, core: source) { return }
        if SiteNotices.receive(event) { return }
        if event.name == "download.updated", let id = event.params["download"]?.string, let download = downloads[id] {
            download.receive(event.params)
            if event.params["complete"] == .bool(true) || event.params["canceled"] == .bool(true) || event.params["interrupted"] == .bool(true) {
                downloads[id] = nil
            }
            return
        }
        guard let id = event.tab else { return }
        if event.name == "cookies.touched" {
            if let page = pages[id]?.value, let url = event.params["url"]?.string.flatMap(URL.init(string:)) {
                page.cookiesTouched(url, mainFrame: event.params["main"] == .bool(true))
            }
            return
        }
        if let page = pages[id]?.value {
            if event.name == "tab.closed" { pages.removeValue(forKey: id) }
            if event.name == "page.originalPDF.changed" {
                page.receiveOriginalPDFPresence(event, from: source, generation: sourceGeneration)
            } else { page.receive(event) }
        }
        else if event.name == "tab.created" {
            adoptCreatedTab(event)
        } else {
            early.append(event)
            if early.count > 256 { early.removeFirst() }
        }
    }
    private func exited(endedBy: YabCoreError?, starting: Bool = false) {
        let exit = processExit
        let endedPID = process?.processIdentifier
        LaunchJournal.record("core.lost", child: endedPID)
        ChromiumConsent.disconnected(client)
        ChromiumGeolocation.disconnected()
        ChromiumDesktopMedia.disconnected(client)
        generation = UUID()
        client = nil
        nativeHooks = [:]
        process = nil
        processExit = nil
        let lostDownloads = Array(downloads.values); downloads.removeAll()
        lostDownloads.forEach { $0.fail(YabCoreError.disconnected) }
        let live = pages.values.compactMap(\.value)
        pages.removeAll(); early.removeAll(); adopting.removeAll()
        let recover = mayRecover()
        LaunchJournal.record(recover ? "core.recovery.allowed" : "core.recovery.stopped", child: endedPID)
        live.forEach { $0.helperExited(recover: recover) }
        Self.noteLoss(exit, pid: endedPID, endedBy: endedBy, starting: starting, recovering: recover && !live.isEmpty)
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    /// The helper's end, for feedback: how it went and its status. The
    /// record waits for the helper's own exit (its termination handler), so
    /// a crash says its signal rather than only that the line went; a helper
    /// still running 2 s after its line closed is said as the line's loss.
    /// Quitting is no loss.
    private static func noteLoss(_ exit: ChildExit?, pid: Int32?, endedBy: YabCoreError?, starting: Bool, recovering: Bool) {
        guard !Links.leaving else { return }
        Task { @MainActor in
            let ended = await exit?.end(within: .seconds(2))
            let (end, code) = helperEnd(endedBy: endedBy, exit: ended, starting: starting)
            NSLog("Chromium: helper lost (%@, %@)%@", end.rawValue, code.map(String.init) ?? "-", recovering ? ", pages come back" : "")
            Watchdog.note("chromium helper lost: \(end.rawValue) \(code.map(String.init) ?? "-")")
            FeedbackDiagnostics.shared.helperLost(end, code: code, recovering: recovering)
            CrashSessions.died(kind: "helper", pid: pid, reason: end.rawValue, code: code)
        }
    }
    /// How the helper went and its code (exit status or signal), from what
    /// ended the line and the helper's exit, if it has exited.
    nonisolated static func helperEnd(endedBy: YabCoreError?, exit: ChildExit.End?, starting: Bool) -> (HelperEnd, Int?) {
        let code = exit.map { Int($0.status) }
        // The client's own refusal first: the helper then exits because
        // its line closed, and its status says nothing of why.
        if case .protocolViolation = endedBy { return (.protocolViolation, code) }
        if exit?.reason == .uncaughtSignal { return (.signal, code) }
        if starting { return (.notStarted, code) }
        if exit != nil { return (.exited, code) }
        switch endedBy {
        case .transport, .timeout, .remote: return (.transport, nil)
        default: return (.disconnected, nil)
        }
    }
    /// A folder left by a helper that was killed with its app: nothing
    /// removed it. One whose socket still answers belongs to another Yab.
    private nonisolated static func sweepSockets() {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        for name in names where name.hasPrefix("yc-") && name.utf8.count == 11 {
            let folder = temporary.appendingPathComponent(name)
            if !socketAnswers(folder.appendingPathComponent("core.sock").path) { try? FileManager.default.removeItem(at: folder) }
        }
    }

    private nonisolated static func socketAnswers(_ path: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return true }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: address.sun_path) - 1))
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, length) == 0 }
        }
    }

    /// A helper lost now and then brings its pages back unasked; one that
    /// keeps going leaves them to say so. Never while the app is quitting.
    private func mayRecover() -> Bool {
        guard !Links.leaving, originalCallerDiagnostic == nil else { return false }
        let now = Date()
        losses = losses.filter { now.timeIntervalSince($0) < 120 } + [now]
        return losses.count <= 3
    }
    // Used only by the isolated acceptance probe. Closing the socket also makes
    // CEF close all producer windows when the application exits.
    func crashForTesting() { if Store.testing { process?.terminate() } }

    /// Mark the native tab adopted before any input/binding command is sent.
    /// Replies and events from a replaced helper must never attach to this one.
    private func adoptCreatedTab(_ event: YabCoreEvent) {
        guard let client, let id = event.tab, let profile = event.params["profile"]?.string,
              case .bool(let privateMode) = event.params["private"] else { return }
        guard adopting.insert(id).inserted else { return }
        let token = generation
        Task { @MainActor [weak self] in
            guard let self, self.generation == token else { return }
            defer { if self.generation == token { self.adopting.remove(id) } }
            do {
                let receipt = try await client.request("tab.adopt", params: ["tab": .string(id), "profile": .string(profile), "private": .bool(privateMode)])
                guard self.generation == token else { return }
                var params = event.params
                if case .object(let fields) = receipt { params.merge(fields) { _, new in new } }
                let accepted = YabCoreEvent(name: event.name, params: params)
                let opener = params["opener"]?.string.flatMap { self.pages[$0]?.value?.navigationTab }
                if params["source"]?["documentPiP"] == .bool(true) {
                    // A second request replaces the first: Chromium has
                    // already told that document it is going.
                    if let opener, opener.documentPiP.showing {
                        opener.documentPiP.close()
                        opener.documentPiP = DocumentPiP()
                    }
                    guard let opener, let browser = opener.delegate as? Browser,
                          opener.documentPiP.openChromium(accepted, source: opener, browser: browser) else {
                        try? await client.closeTab(id); return
                    }
                } else {
                    // Chrome's window can be led by a page of its own (a
                    // control tab): the tab goes to the window in front, as
                    // Chrome sends a worker's tab to the last focused one.
                    let extensionTab = params["creationPurpose"]?.string == "extension"
                    let owner: Tab?
                    if let original = params["extensionCreation"]?["ownerTab"].string {
                        // A missing original owner is a refusal, never a chance
                        // to retarget an in-flight identity call to the front tab.
                        // Any other extension tab whose named owner is no row
                        // (its action popup, an offscreen page: Jam recording a
                        // tab, #1874) goes to the window in front, as Chromium
                        // sends it to the last focused one; refused, it was
                        // closed at once and the extension saw it removed.
                        let identity = params["extensionCreation"]?["requestedKind"] == .string("identity")
                        owner = self.pages[original]?.value?.navigationTab
                            ?? (identity ? nil : ChromiumTabAdoption.frontTab(profile: profile))
                    } else {
                        owner = extensionTab ? ChromiumTabAdoption.frontTab(profile: profile) : nil
                    }
                    if ChromiumTabAdoption.install(accepted, opener: opener, owner: owner) == nil {
                        FileHandle.standardError.write(Data("yab: tab \(id) refused: purpose \(params["creationPurpose"]?.string ?? "-") opener \(opener != nil) owner \(owner != nil)\n".utf8))
                        try? await client.closeTab(id); return
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("yab: tab \(id) closed: tab.adopt failed: \(error)\n".utf8))
                try? await client.closeTab(id)
            }
        }
    }
}

/// A child process's end as Foundation reports it: Process's termination
/// handler, fired by NSTask's own exit source (a kqueue/dispatch proc-exit
/// watch), never a poll of `isRunning`. Made before `run`, so an exit that
/// comes at once is not missed; anyone may wait on it, before or after.
final class ChildExit: @unchecked Sendable {
    struct End: Sendable, Equatable {
        let status: Int32
        let reason: Process.TerminationReason
    }
    private let lock = NSLock()
    private var stored: End?
    private var waiting: [UUID: CheckedContinuation<End?, Never>] = [:]

    private let safeStorage: ChromiumSafeStorageBroker?

    func launched(pid: pid_t) { safeStorage?.launched(pid: pid) }

    init(watching child: Process, safeStorage: ChromiumSafeStorageBroker? = nil) {
        self.safeStorage = safeStorage
        child.terminationHandler = { [self] ended in
            safeStorage?.stop()
            finish(End(status: ended.terminationStatus, reason: ended.terminationReason))
        }
    }

    /// The end, if it has come.
    var ended: End? { lock.withLock { stored } }

    /// The end as soon as it comes; nil when it hasn't within `limit`.
    func end(within limit: Duration) async -> End? {
        if let ended { return ended }
        return await withTaskGroup(of: End?.self) { group in
            group.addTask { await self.next() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? ended
        }
    }

    private func finish(_ value: End) {
        let resumed: [CheckedContinuation<End?, Never>] = lock.withLock {
            guard stored == nil else { return [] }
            stored = value
            defer { waiting.removeAll() }
            return Array(waiting.values)
        }
        resumed.forEach { $0.resume(returning: value) }
    }

    private func next() async -> End? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<End?, Never>) in
                lock.lock()
                if let stored {
                    lock.unlock()
                    continuation.resume(returning: stored)
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    waiting[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            let continuation = lock.withLock { waiting.removeValue(forKey: id) }
            continuation?.resume(returning: nil)
        }
    }
}
