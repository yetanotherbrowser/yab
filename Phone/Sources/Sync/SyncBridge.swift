import Foundation
import Observation
import UIKit
import LocalAuthentication
import UserNotifications
import os
#if canImport(SyncKit)
import SyncKit
#endif

/// The app in sync: what the engine (PhoneSync) hears goes into the app's
/// stores, and what the person does to them goes back as records, in the
/// Mac's own encoding. One bridge per launch, always there; with no key and
/// no server it does nothing (test worlds, named states).
///
/// The stores stay the app's: the column, the field and the chats change
/// BrowserStore and ChatStore as they always do, and the bridge watches
/// them. After every change it compares the spaces with the mirror of what
/// sync holds and writes the difference: a tab opened, closed, kept or
/// unkept, moved, put in another place of its list, Clear. Remote changes
/// rebuild the rows they touched, keeping what is this iPhone's own (the tab
/// it shows, the folders it folded, its private tabs).
@MainActor
@Observable
final class SyncBridge {
    /// Where joining stands.
    enum Phase: Hashable, Sendable {
        /// No sync here: a test world, a named state.
        case off
        /// No key yet: this iPhone joins with a code or the Recovery Key.
        case joining(Join)
        /// In, with a line that comes and goes.
        case on
        /// The account turned this iPhone away: removed, or a key that isn't
        /// the account's any more.
        case refused(String)
    }

    enum Join: Hashable, Sendable {
        /// The code to type on a Mac, and whether one is still being made.
        case code(String)
        /// Typing the Recovery Key; `wrong` after one that isn't.
        case recovery(wrong: Bool)
        /// Scanning the code a Mac shows (Add a Device), or typing it.
        case scan
        /// Joining by the Mac's code: the four digits its question names.
        case invite(code: String, check: String)
    }

    private(set) var phase: Phase = .off
    let folderArtwork = SyncFolderArtwork()
    /// The join sheet is up: Settings' (Surfaces.join), which shows what
    /// joining needs now (Join/JoinContent).
    var showsJoin: Bool {
        get { app?.surfaces.join ?? false }
        set {
            guard let surfaces = app?.surfaces, surfaces.join != newValue else { return }
            if newValue { surfaces.openJoin() } else { surfaces.closeJoin() }
        }
    }
    /// What is typed in the Recovery Key's field.
    var typed = ""
    /// Storage/start failures stay visible; they are not a successful join.
    private(set) var joinError: String?
    private(set) var keySharingUnavailable = false
    /// The sheet comes back each time Yab comes to the front while this
    /// iPhone isn't in sync: put away with its ✕, joining waits, it isn't
    /// gone. Settings' welcome turns it off with Not Now (it has Join Your
    /// Mac in Settings for later); a removed iPhone is asked again whatever.
    var asksOnFront = true
    /// The line: off, connecting, live, waiting, refused.
    private(set) var line: SyncClient.State = .off
    /// The account's Macs, the one up first.
    private(set) var macs: [SyncMac] = []
    /// Every device of the account, this iPhone first (Settings › Sync).
    private(set) var devices: [SyncDevice] = []
    /// Changes made here the server hasn't taken yet.
    private(set) var pending = 0
    /// The line has been down for a few seconds: changes wait here.
    private(set) var offline = false
    /// The current sealed questions from a Mac, shown only after their owner
    /// is in this account's device list.
    private(set) var assistantApprovals: [AssistantApprovalRecords.Request] = []
    var assistantApprovalReceipt: String?
    private var openedAssistantApproval: String?
    var presentedAssistantApproval: AssistantApprovalRecords.Request? {
        guard assistantApprovalReceipt == nil else { return nil }
        if let openedAssistantApproval { return assistantApprovals.first { $0.id == openedAssistantApproval } }
        return assistantApprovals.first
    }

    func openAssistantApproval(_ id: String) {
        openedAssistantApproval = id
        assistantApprovalReceipt = nil
        reconcileAssistantApprovals()
    }
    private(set) var assistantApprovalError: String?
    /// What came of the yeses given here, by question, until their tray
    /// lets them go: paying on the site, paid, declined, done.
    private(set) var assistantApprovalResults: [String: AssistantApprovalRecords.Result] = [:]
    /// The questions answered here, kept to read their results against
    /// (an answered question leaves `assistantApprovals`).
    private var answeredAssistantApprovals: [String: AssistantApprovalRecords.Request] = [:]
    /// A named state put its own questions in: they are answered and read
    /// from the stand-ins below, never the line.
    private var pretending = false
    /// Named states' stand-ins for what a Mac would send.
    private var pretendDetails: [String: AssistantApprovalRecords.Detail] = [:]
    private var pretendPreviews: [String: UIImage] = [:]
    /// How a named state's payment ends after its yes: paid or declined;
    /// nil, the state sets its results itself.
    var pretendPayEnds: AssistantApprovalRecords.Result.Phase? = .paid

    /// A named state's result, as a Mac would write it.
    func pretendResult(_ result: AssistantApprovalRecords.Result) {
        guard app?.isFixture == true else { return }
        assistantApprovalResults[result.id] = result
    }
    /// Notifications not yet allowed or refused: the approval card offers to
    /// ask, and only a tap there asks (Yab never prompts for access by itself).
    private(set) var assistantNotificationsUndecided = false
    @ObservationIgnored private var assistantApprovalExpiry: Task<Void, Never>?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private(set) var engine: PhoneSync?
    @ObservationIgnored private(set) var setup: Setup?
    @ObservationIgnored private var mirror = SyncMirror() {
        // The Macs' tabs of today changed: the spaces' pages read them again.
        didSet {
            if oldValue.elsewhere != mirror.elsewhere { macTodayStamp &+= 1 }
            if oldValue.tabs != mirror.tabs { pinsStamp &+= 1 }
        }
    }
    /// Bumped as the Macs' tabs of today change (the mirror itself isn't watched).
    private(set) var macTodayStamp = 0
    private(set) var pinsStamp = 0
    private(set) var sharesPins = false
    static let sharedPinsKey = "pins.everySpace"

    /// Shared pins stay owned by Personal in the journal. Project them into
    /// each shared-sign-in page without duplicating tabs in the browser store.
    /// The space's own pins follow them, as the Mac's row joins them
    /// (docs/shared-pins.md, "Switching"): one pinned here, or a Mac's that
    /// sync brought into this space, unless a shared pin is at its address.
    /// Shown in their place, they hid every pin of the space's own (row 2602).
    func pins(in space: Space) -> [Tab] {
        _ = pinsStamp
        guard sharesPins, !space.isPrivate, !space.ownSignIns else { return space.visiblePins }
        let source = ids.local(SyncCollection.firstSpace)
        if source == space.id { return space.visiblePins }
        let shared = app?.browser.space(source)?.visiblePins ?? mirror.row(SyncCollection.firstSpace).pins.map {
            SyncMapping.tab($0, id: ids.local($0.id), old: nil, fixturesEnabled: app?.isFixture ?? false)
        }.filter { !$0.isMail }
        let addresses = Set(shared.compactMap { $0.navigationURL?.absoluteString })
        return shared + space.visiblePins.filter { pin in
            pin.navigationURL.map { !addresses.contains($0.absoluteString) } ?? true
        }
    }

    /// Whether the Mac's tab in front belongs on `space`'s page: it is in
    /// that space on the Mac, or it is a shared pin the page shows. The
    /// presence names only the tab; its record says where it is. Nil while
    /// that record hasn't come (row 2603).
    func macFrontShows(in space: Space) -> Bool? {
        _ = macTodayStamp
        guard let id = (awakeMac ?? macs.first)?.front?.tab,
              let tab = mirror.tabs[id] ?? mirror.elsewhere[id] else { return nil }
        if tab.list == .pinned, pins(in: space).contains(where: { $0.id == ids.local(id) }) { return true }
        return ids.local(tab.space) == space.id
    }

    /// Opening an inherited pin stays in the chosen space. Its today's copy
    /// has its own identity; the shared pin keeps its original sync parent.
    func openSharedPin(_ id: Tab.ID, in space: Space.ID) -> Bool {
        guard sharesPins, let app, let target = app.browser.space(space),
              !target.isPrivate, !target.ownSignIns,
              let source = ids.known(id), let pin = mirror.tabs[source],
              pin.space == SyncCollection.firstSpace, pin.list == .pinned else { return false }
        app.openFromMac(pin, in: space)
        return true
    }

    private func detachedSharedPin(_ id: Tab.ID) -> SyncTab? {
        guard sharesPins, app?.browser.tab(id) == nil,
              let source = ids.known(id), let pin = mirror.tabs[source],
              pin.space == SyncCollection.firstSpace, pin.list == .pinned else { return nil }
        return pin
    }

    /// Menu actions on a pin whose source space no longer has a page here.
    @discardableResult
    func changeDetachedSharedPin(_ id: Tab.ID, to space: Space.ID? = nil, close: Bool = false) -> Bool {
        guard let engine, let pin = detachedSharedPin(id) else { return false }
        do {
            if close {
                try engine.closeTab(pin.id)
                mirror.apply([.tabGone(pin.id)])
            } else {
                let destination = space ?? app?.browser.ordinarySpaceID
                guard let destination else { return false }
                let changed = try engine.move(pin.id, to: ids.sync(destination), list: .today, at: .top)
                mirror.apply([.tab(changed)])
            }
            rebuild(nil, motion: Motion.columnRows)
            return true
        } catch {
            log.error("shared pin edit: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// The Mac's tabs closed from here while it is down: shown dimmed until it wakes.
    private(set) var closingOnMac: [String: SyncTab] = [:]
    @ObservationIgnored private var ids = IDs()
    @ObservationIgnored private var chatMirror = ChatMirror()
    @ObservationIgnored private var adopted: [Chat.ID: Chat] = [:]
    /// The iPhone's changes go up once the journal or live account is in.
    @ObservationIgnored private(set) var writing = false
    /// This line's look for the empty Personal spaces earlier installs left.
    @ObservationIgnored private var pruned = false
    @ObservationIgnored private var pairing: PhonePairing?
    @ObservationIgnored private var scrolled: String?
    /// How many times the Mac's place on a page was passed on (tests).
    @ObservationIgnored private(set) var scrollsPassed = 0
    /// The tab in front here when the stores last changed: the Mac's scroll
    /// is passed only when its tab comes in front, never while it stays.
    @ObservationIgnored private var lastFront: Tab.ID?
    @ObservationIgnored private var offered: String?
    /// The journal is read and in the stores: until then the line stays
    /// shut, so nothing from it lands on a half-made mirror.
    @ObservationIgnored private(set) var ready = false
    /// Joined through iCloud Keychain with no step: said once, when the
    /// account's spaces are in (nothing else on screen would say why).
    @ObservationIgnored private var saysJoined = false
    /// This launch joined through iCloud Keychain: the first run shows the
    /// Mac it found (Welcome/FirstRun) instead of a toast.
    private(set) var joinedByICloud = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var counting = false
    @ObservationIgnored private var recount = false
    @ObservationIgnored private var wantsHandoff = false
    /// The page in front here and when it came in front, said with the
    /// presence for a Mac's From iPhone (PhoneFront); and what was said last.
    @ObservationIgnored private var frontSince: (url: String?, at: Date)?
    @ObservationIgnored private var frontSaid: (url: String?, title: String?)?
    @ObservationIgnored private var presenceSoon: Task<Void, Never>?
    /// The keyboard is up: something is being typed, and a page a Mac sent
    /// waits in Today with its card instead of coming in front.
    @ObservationIgnored private var keyboardUp = false
    /// Named states: which of the pretend devices is this iPhone.
    @ObservationIgnored var pretendOwnDevice: String?
    @ObservationIgnored let probe: SyncProbe?
    @ObservationIgnored private let log = Logger(subsystem: "dev.serafim.fast.iphone", category: "sync")

    @ObservationIgnored private let settings: SettingsStore

    init(probe: SyncProbe? = nil, settings: SettingsStore = .shared) {
        self.probe = probe
        self.settings = settings
    }

    // MARK: - setting up

    /// How this launch syncs: where the server is, where the key and the
    /// journal live, whether the world goes up as the iPhone's own.
    struct Setup: Sendable {
        var base: URL
        var keys: SyncKeychain
        /// The journal's folder.
        var folder: URL
        /// The world's spaces and tabs are written into an empty journal as
        /// this iPhone's own changes (the `offline` world's outbox).
        var seed: Bool
        /// A world without a key makes one (it is the first device).
        var makesKey: Bool
        var deviceName: String
        /// A server in memory, for unit tests; nil is the web.
        var transport: (any Transport)? = nil
        /// A Mac counts as up this long after its last word; the devices
        /// list is read again this often (`-YabSyncOnlineFor`, `-YabSyncRefresh`).
        var onlineFor: TimeInterval = PhoneSync.onlineFor
        var refreshEvery: TimeInterval = 60
        /// Whether an explicit fixture world goes into the account. A real
        /// local profile is preserved and imported independently of this flag.
        var ownWorld = true

        /// The launch's: `-YabSync <url>` (a local server), a world's own
        /// `"sync"` section, else for a person's launch the keychain and the
        /// deployed server. Test runs never reach the deployed server, and
        /// never the keychain: their key lives in a folder of the world's.
        @MainActor
        static func resolve(options: LaunchOptions, arguments: [String] = ProcessInfo.processInfo.arguments) -> Setup? {
            func value(_ key: String) -> String? {
                guard let i = arguments.firstIndex(of: "-" + key), i + 1 < arguments.count else { return nil }
                return arguments[i + 1]
            }
            let section = WorldSync.read(options.world)
            let server = value("YabSync") ?? section?.server
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            if let server, let base = URL(string: server) {
                guard options.isTestRun || value("YabSync") != nil else { return nil }
                if base.host == URL(string: "https://yab-sync.21st.workers.dev")!.host {
                    Logger(subsystem: "dev.serafim.fast.iphone", category: "sync").error("test runs never sync with the deployed server")
                    return nil
                }
                var folder = support.appendingPathComponent("Sync/worlds/\(options.world)", isDirectory: true)
#if DEBUG
                // An owned live-profile UI test must not reuse a world's key.
                if value("YabSync") != nil, ProcessInfo.processInfo.environment["YAB_TEST"] == "1",
                   let path = value("YabProfileDirectory"), path.hasPrefix("/"),
                   options.profileDirectory == path, ["127.0.0.1", "localhost", "::1"].contains(base.host ?? "") {
                    let profile = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                    let owned = profile.path.hasPrefix("/tmp/") || profile.path.hasPrefix("/private/tmp/")
                        || profile.path.hasPrefix(FileManager.default.temporaryDirectory.path)
                    guard owned else { return nil }
                    folder = profile.appendingPathComponent("Sync-test", isDirectory: true)
                }
#endif
                return Setup(base: base, keys: .testing(folder: folder.appendingPathComponent("keys")),
                             folder: folder.appendingPathComponent("journal"), seed: section?.seed ?? false,
                             makesKey: section?.seed ?? false, deviceName: section?.device ?? "Test iPhone")
            }
            guard !options.isTestRun else { return nil }
            return Setup(base: PhoneSync.defaultBase, keys: .standard(), folder: PhoneSync.defaultFolder, seed: false,
                         makesKey: false, deviceName: UIDevice.current.name, ownWorld: false)
        }
    }

    /// The `"sync"` part of a world's file: the world syncs with this server.
    struct WorldSync: Decodable, Sendable {
        var server: String?
        var seed: Bool?
        var device: String?

        static func read(_ world: String) -> WorldSync? {
            struct File: Decodable { var sync: WorldSync? }
            guard let url = World.folder?.appendingPathComponent("\(world).json"), let data = try? Data(contentsOf: url) else { return nil }
            return (try? JSONDecoder().decode(File.self, from: data))?.sync
        }
    }

    /// Takes the app in and, when this launch syncs, starts: the key from
    /// this iPhone, from iCloud Keychain (no step at all), else joining.
    func attach(_ app: AppModel, setup given: Setup?) {
        self.app = app
        var adjusted = given
        if let seconds = Self.argument("YabSyncOnlineFor").flatMap(Double.init) { adjusted?.onlineFor = seconds }
        if let seconds = Self.argument("YabSyncRefresh").flatMap(Double.init) { adjusted?.refreshEvery = seconds }
        setup = adjusted
        probe?.attach(self, app: app)
        SyncKeychainProbe.runIfAsked()
        watchStores()
        watchFront()
        watchLiveTaskVisibility()
        guard let setup = adjusted else { return }
        // A test's fresh start: no key, no journal of an earlier run.
        if Self.argument("YabSyncFresh") == "1", case let .files(keys) = setup.keys.storage {
            try? FileManager.default.removeItem(at: keys)
            try? FileManager.default.removeItem(at: setup.folder)
        }
        listenToLifecycle()
        if let seal = setup.keys.local {
            // Joined on an earlier launch: past the first run, whichever way
            // it went (builds before it never wrote it down).
            if !settings.welcomed { settings.welcomed = true }
            start(seal)
        } else if let shared = setup.keys.shared, !settings.syncTurnedOff {
            // The same Apple ID as a Mac in sync: in with its key, no step at
            // all; not after Turn Off Sync on This iPhone, until joined again.
            guard keepForJoining(shared.seal, share: false) else {
                let why = joinError
                askToJoin()
                joinError = why
                return
            }
            if start(shared.seal) {
                probe?.say("joined", "icloud")
                saysJoined = true
                joinedByICloud = true
            }
        } else if setup.makesKey {
            let seal = Seal.make()
            guard keepForJoining(seal, share: false) else {
                let why = joinError
                askToJoin()
                joinError = why
                return
            }
            start(seal)
        } else if !firstRunOwnsJoining, !settings.withoutMac, !settings.syncTurnedOff {
            askToJoin()
        }
        // Otherwise joining waits to be asked: the first run's Yab is on my
        // Mac, or Join Your Mac in Settings › Sync. No code, no polling.
    }

    private static func argument(_ key: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-" + key), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    // MARK: - joining

    /// Shows a code for a Mac to let this iPhone in (Settings › Sync › Add a
    /// Device), and waits for it. The same code works ten minutes; then a new one.
    func askToJoin(sameCode: Bool = false) {
        defer { reconcileLiveTasks() }
        guard let setup else { return }
        joinError = nil
        let code = sameCode ? pairing?.code : nil
        pairing?.cancel()
        let pairing = PhonePairing(base: setup.base, transport: setup.transport, every: 2, code: code)
        self.pairing = pairing
        // Typing the Recovery Key or scanning the Mac's code meanwhile: that stays.
        switch phase {
        case .joining(.recovery), .joining(.scan): break
        default: phase = .joining(.code(pairing.code))
        }
        probe?.say("code", pairing.code)
        // Up when asked; a retry behind it leaves the sheet where the person put it.
        // The first launch shows joining in its own tray (Welcome/FirstRun).
        if !sameCode, !showsJoin, !firstRunOwnsJoining { Motion.sheetRise.run { self.showsJoin = true } }
        pairing.start { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.pairing === pairing else { return }
                switch result {
                case let .success(seal):
                    self.pairing = nil
                    guard self.keepForJoining(seal) else { return }
                    if self.joined(seal) { self.probe?.say("joined", "code") }
                case .failure(.expired):
                    // A new code only while one is in sight; otherwise the
                    // next showing makes one (openJoin, beginJoin).
                    if self.showsJoin || FirstRun.shared.showsCode {
                        self.askToJoin()
                    } else {
                        self.pairing = nil
                    }
                case .failure(.cancelled):
                    break
                case .failure:
                    // The server wouldn't take the box: again in a moment,
                    // the same code on screen.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self, self.pairing === pairing else { return }
                        self.askToJoin(sameCode: true)
                    }
                }
            }
        }
    }

    /// The Recovery Key typed in. False, and the words say so, when it isn't one.
    @discardableResult
    func useRecovery(_ typed: String) -> Bool {
        guard let seal = Seal(recovery: typed) else {
            Motion.joinSwap.run { phase = .joining(.recovery(wrong: true)) }
            Haptics.play(.error, reason: "wrong key")
            return false
        }
        joinError = nil
        guard setup != nil, keepForJoining(seal) else { return false }
        pairing?.cancel()
        pairing = nil
        guard joined(seal) else { return false }
        self.typed = ""
        probe?.say("joined", "recovery")
        return true
    }

    /// From this iPhone's code to scanning the Mac's (Scan QR), and back.
    func showScanner(_ on: Bool) {
        joinError = nil
        if on {
            Motion.joinSwap.run { phase = .joining(.scan) }
        } else if let pairing, !pairing.invited {
            Motion.joinSwap.run { phase = .joining(.code(pairing.code)) }
        } else {
            askToJoin()
        }
    }

    /// From the code to the Recovery Key's field, and back.
    func showRecovery(_ on: Bool) {
        if on {
            Motion.joinSwap.run { phase = .joining(.recovery(wrong: false)) }
        } else if let pairing {
            Motion.joinSwap.run { phase = .joining(.code(pairing.code)) }
        } else {
            askToJoin()
        }
    }

    /// The first run left the code (Cancel, ‹, Use Without a Mac): the code
    /// is let go and nothing asks the server until joining is asked again.
    func stopAsking() {
        pairing?.cancel()
        pairing = nil
        if case .joining = phase { phase = .off }
    }

    /// The sheet put away: joining waits until it is shown again.
    func closeJoin() {
        Motion.sheetDrop.run { showsJoin = false }
    }

    /// The sheet up again: from Settings, the column's quiet line, or Yab
    /// coming to the front. Only while this iPhone isn't in sync.
    func openJoin() {
        guard !showsJoin else { return }
        switch phase {
        case .joining:
            // A code that ran out while the sheet was away: a new one.
            if pairing == nil, case .joining(.code) = phase { askToJoin() } else { Motion.sheetRise.run { showsJoin = true } }
        case .refused:
            Motion.sheetRise.run { showsJoin = true }
        case .on, .off:
            break
        }
    }

    /// Join Your Mac (the welcome) and Settings › Your Mac › Sync: a code
    /// on screen, unless this iPhone is joining already, was turned away, or
    /// is in. A launch without sync (a test world) shows the same flow with
    /// a code no Mac answers, the way named states do.
    func beginJoin() {
        switch phase {
        case .off:
            // The first launch shows the code in its own tray, not Settings' sheet.
            if setup != nil { askToJoin() } else { pretend(.joining(.code(Joining().code)), sheet: !firstRunOwnsJoining) }
        case .joining(.code):
            // A code that ran out while the sheet was away: a new one.
            if pairing == nil, setup != nil { askToJoin() }
        case .joining, .refused, .on:
            break
        }
    }

    /// The first launch is up (or about to be): joining shows in its tray
    /// (Welcome/FirstRun), not in Settings' sheet.
    private var firstRunOwnsJoining: Bool { app.map(FirstLaunch.shows) ?? false }

    private func keepForJoining(_ seal: Seal, share: Bool = true) -> Bool {
        guard let setup else { return false }
        switch setup.keys.keep(seal, share: share) {
        case .localFailure:
            joinError = "This iPhone could not save the Sync key. Unlock it and try again."
            Haptics.play(.error, reason: "sync key not saved")
            return false
        case .localOnly:
            keySharingUnavailable = share
        case .localAndShared:
            keySharingUnavailable = false
        }
        return true
    }

    @discardableResult
    private func joined(_ seal: Seal) -> Bool {
        guard start(seal) else { return false }
        if settings.withoutMac { settings.withoutMac = false }
        // In again on purpose: iCloud Keychain's key may bring it back too.
        if settings.syncTurnedOff { settings.syncTurnedOff = false }
        Haptics.play(.success, reason: "joined")
        Motion.sheetDrop.run { showsJoin = false }
        return true
    }

    /// A failed start retries the saved account without removing the key,
    /// device identity, journal, tabs or chats.
    func retryJoin() {
        joinError = nil
        if let seal = setup?.keys.local {
            if joined(seal) { typed = "" }
        } else if case .joining(.recovery) = phase {
            _ = useRecovery(typed)
        } else {
            askToJoin()
        }
    }

    /// Removed from the account: this iPhone forgets the key, the token and
    /// its id (a removed id is refused for good) and joins again as new.
    func joinAgain() {
        defer { reconcileLiveTasks() }
        forgetAccount()
        askToJoin()
    }

    /// Two accounts became one and this iPhone was in the other: on to the
    /// one that stayed, as a new device there, nothing for the person to do.
    private func follow(_ there: Seal) {
        guard phase == .on, let mine = engine?.seal, mine.raw != there.raw else { return }
        let left = "sync.leftAccounts"
        var accounts = UserDefaults.standard.stringArray(forKey: left) ?? []
        guard !accounts.contains(there.account), keepForJoining(there) else { return }
        // Persist the destination before discarding the old account. A
        // failed save keeps the old engine available to deliver the move again.
        accounts.append(mine.account)
        UserDefaults.standard.set(accounts, forKey: left)
        defer { reconcileLiveTasks() }
        forgetAccount(keepingKey: true)
        joined(there)
    }

    /// The line closed and the engine let go, its journal with it: what an
    /// ended app leaves (tests stand in for a relaunch with this).
    func end() {
        defer { reconcileLiveTasks() }
        folderArtwork.reset()
        settings.importSearchPreferences(engine: nil, customTemplate: nil)
        sharesPins = false
        importShield([:])
        importField([:])
        settings.appIcons.adopt([:])
        settings.appIcons.onKeep = nil
        engine?.stop()
        engine = nil
        line = .off
    }

    /// The Mac's ad blocker, read only: its switch ("shield") and the sites
    /// it is off for ("shield.paused"), both synced settings of the Mac's.
    private func importShield(_ preferences: [String: Value]) {
        let enabled = preferences[Self.shieldKey].flatMap { $0.bool ?? $0.number.map { $0 != 0 } }
        let paused = preferences[Self.shieldPausedKey]?.array?.compactMap(\.string)
        settings.importShieldPreferences(enabled: enabled, paused: paused)
    }

    static let shieldKey = "shield"
    static let shieldPausedKey = "shield.paused"

    /// The Mac's Settings › Field, read only: whether Return guesses from
    /// the words ("field.firstRow") and the rows under them ("field.under").
    private func importField(_ preferences: [String: Value]) {
        let firstRow = preferences[Self.fieldFirstRowKey].flatMap { $0.bool ?? $0.number.map { $0 != 0 } }
        let rows = preferences[Self.fieldUnderKey]?.array?.compactMap(\.string)
        settings.importFieldPreferences(firstRow: firstRow, rows: rows)
    }

    static let fieldFirstRowKey = "field.firstRow"
    static let fieldUnderKey = "field.under"

    private static func iconSetting(_ key: String) -> Bool {
        ["gift.firstEdition.receipt", "invite.charm.left", "invite.charm.right"].contains(key)
            || AppIconCatalog.allCases.contains { $0.grantKey == key }
    }

    /// Wearing a seasonal icon on this iPhone keeps it on the other devices.
    private func keepAppIcon(_ icon: AppIconCatalog) {
        guard let engine, engine.settings()[icon.grantKey]?.bool != true else { return }
        do {
            try engine.journal.change(.init(collection: SyncCollection.setting, id: icon.grantKey), ["value": .bool(true)])
            engine.client.kick()
        } catch {
            log.error("couldn't sync app icon: \(String(describing: error), privacy: .public)")
        }
    }

    /// The exact displayed public source, resolving only already-persisted
    /// local-to-sync identities. This getter never manufactures a mapping.
    func currentTaskOrigin() -> TaskRecords.Origin? {
        guard let app, !app.isFixture, phase == .on, ready, let engine,
              app.privateLock.isActive, !app.hasPrivateForeground, !app.browser.space.isPrivate,
              !app.field.isPrivate, !app.field.pageIsPrivate,
              let space = ids.known(app.browser.spaceID),
              let rawSpace = engine.journal.record(.init(collection: SyncCollection.space, id: space)),
              SyncSpace(rawSpace) != nil else { return nil }
        if app.field.shown && app.field.mode == .newTab {
            return .init(space: space, isPrivate: false)
        }
        let tab = app.field.shown && app.field.mode == .address
            ? app.field.pageID.flatMap(app.browser.tab) : app.browser.tab
        guard let tab, !tab.isPrivate, app.browser.space(holding: tab.id)?.id == app.browser.spaceID,
              let id = ids.known(tab.id), let raw = engine.journal.record(.init(collection: SyncCollection.tab, id: id)),
              let source = SyncTab(raw), source.space == space, source.url == tab.url, source.title == tab.title else { return nil }
        return .init(space: space, tab: id, url: source.url, title: source.title, isPrivate: false)
    }

    /// Current public membership and engine ownership gate every UI read, even
    /// while a queued callback from an old engine is still waiting to run.
    func visibleLiveTasks(in localSpace: Space.ID) -> [LiveTaskSnapshot] {
        guard let app, !app.isFixture, phase == .on, ready, let engine,
              app.privateLock.isActive, !app.hasPrivateForeground,
              app.tasks.liveAccount == engine.seal.account,
              let space = app.browser.space(localSpace), !space.isPrivate,
              let source = ids.known(localSpace) else { return [] }
        // The Now line asks this on every update of the chrome, so a space
        // with no task of its own must answer from memory: each journal read
        // is a synchronous hop to the journal's queue and SQLite, and in an
        // update loop it was where the watchdog found the main thread
        // (crashes 269, 349).
        guard app.tasks.live.contains(where: { $0.request.space == source }) else { return [] }
        #if DEBUG
        journalSpaceReads += 1
        #endif
        guard engine.journal.record(.init(collection: SyncCollection.space, id: source)).flatMap(SyncSpace.init) != nil else { return [] }
        if case .refused = engine.state { return [] }
        return app.tasks.live.compactMap { saved in
            guard saved.request.space == source,
                  let current = engine.checkedTaskRecord(saved.id),
                  current.request == saved.request, current.request.readOnlyEpoch != nil else { return nil }
            return try? LiveTaskSnapshot(request: current.request, observation: current.observation)
        }
    }

    #if DEBUG
    /// Journal reads visibleLiveTasks made for the space check (tests). Not
    /// observed: views read through visibleLiveTasks, and a write here would
    /// redraw them for ever.
    @ObservationIgnored private(set) var journalSpaceReads = 0
    #endif

    func visibleLiveTask(_ id: String) -> LiveTaskSnapshot? {
        guard let app else { return nil }
        return visibleLiveTasks(in: app.browser.spaceID).first { $0.id == id }
    }

    /// This reads the current merged journal, never a callback's supplied body.
    func reconcileLiveTasks() {
        guard let app, !app.isFixture else { return }
        guard let engine, phase == .on, ready else {
            app.tasks.replaceLive(account: nil, snapshots: [])
            retireUnavailableLiveChat()
            return
        }
        if case .refused = engine.state {
            app.tasks.replaceLive(account: nil, snapshots: [])
            retireUnavailableLiveChat()
            return
        }
        let observations = Dictionary(engine.taskRecords().map { ($0.task, $0) },
                                      uniquingKeysWith: { a, b in a.revision >= b.revision ? a : b })
        let macs = self.macs
        let snapshots = engine.taskRequests().filter { $0.readOnlyEpoch != nil }.compactMap { request -> LiveTaskSnapshot? in
            guard var snapshot = try? LiveTaskSnapshot(request: request, observation: observations[request.id]) else { return nil }
            // Its Mac down: by name, and since when (MacWords).
            if let mac = macs.first(where: { $0.id == request.mac }), !mac.state.isUp {
                let since = MacWords.since(mac.state.since, now: Date())
                let why: String
                switch mac.state {
                case .closed: why = "Yab closed"
                case .silent: why = "no word"
                default: why = "asleep"
                }
                snapshot.macWait = "\(MacWords.waitsFor(mac.name)) · \(why)\(since.isEmpty ? "" : " " + since)"
            }
            return snapshot
        }
        app.tasks.replaceLive(account: engine.seal.account, snapshots: snapshots,
                              seenScope: .init(folder: engine.options.folder, account: engine.seal.account,
                                               phone: engine.options.device.id))
        retireUnavailableLiveChat()
    }

    private func watchLiveTaskVisibility() {
        guard let app, !app.isFixture else { return }
        withObservationTracking {
            _ = app.hasPrivateForeground
            _ = app.privateLock.isActive
            _ = app.browser.spaceID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.retireUnavailableLiveChat()
                self?.watchLiveTaskVisibility()
            }
        }
    }

    private func retireUnavailableLiveChat() {
        guard let app, !app.isFixture, case let .task(id)? = app.surfaces.chat,
              visibleLiveTask(id) == nil else { return }
        app.surfaces.closeChat()
        app.taskDesk.dismissForLink()
        app.taskDesk.restorePageAfterChat()
    }

    // MARK: - running

    @discardableResult
    private func start(_ seal: Seal) -> Bool {
        guard let setup else { return false }
        folderArtwork.reset()
        app?.tabClear.markShared()
        do {
            let deviceID = try setup.keys.savedDeviceID()
            let engine = try PhoneSync(seal: seal, options: .init(base: setup.base, folder: setup.folder,
                                                                  device: .init(id: deviceID, name: setup.deviceName, model: PhoneSync.model),
                                                                  transport: setup.transport, onlineFor: setup.onlineFor,
                                                                  refreshEvery: setup.refreshEvery),
                                       keys: setup.keys)
            if app?.isFixture == false { ids = try IDs(folder: setup.folder, account: seal.account, device: deviceID) }
            self.engine = engine
            pruned = false
            publishFront(app?.browser.tab)
            engine.onMoved = { [weak self, weak engine] there in
                Task { @MainActor [weak self, weak engine] in
                    guard let self, let engine, self.engine === engine else { return }
                    self.follow(there)
                }
            }
            engine.onChanges = { [weak self, weak engine] batch in
                MainActor.assumeIsolated {
                    guard let self, let engine, self.engine === engine else { return }
                    self.receive(batch)
                }
            }
            engine.onState = { [weak self, weak engine] state in
                MainActor.assumeIsolated {
                    guard let self, let engine, self.engine === engine else { return }
                    self.changed(state)
                }
            }
            engine.onMacs = { [weak self, weak engine] macs in
                MainActor.assumeIsolated {
                    guard let self, let engine, self.engine === engine else { return }
                    self.heard(macs)
                }
            }
            engine.onDevices = { [weak self, weak engine] devices in
                MainActor.assumeIsolated {
                    guard let self, let engine, self.engine === engine else { return }
                    self.devices = devices
                    self.reconcileAssistantApprovals()
                    // The list read after the line came up: the tidy waited for it.
                    if self.line == .live { self.pruneEmptyPersonals() }
                }
            }
            engine.onAssistantApprovals = { [weak self, weak engine] in
                MainActor.assumeIsolated {
                    guard let self, let engine, self.engine === engine else { return }
                    self.reconcileAssistantApprovals()
                }
            }
            engine.onTaskRecordChanges = { [weak self, weak engine] in
                MainActor.assumeIsolated {
                    guard let self, let engine, self.engine === engine else { return }
                    self.reconcileLiveTasks()
                }
            }
            engine.onCapabilities = { [weak self, weak engine] owners in
                MainActor.assumeIsolated {
                    guard let self, let engine, self.engine === engine else { return }
                    self.adoptChats(Set(self.chatMirror.heads.values.filter { owners.contains($0.device) }.map(\.id)))
                    self.reconcileLiveTasks()
                }
            }
            // Read on the line's queue: what the main thread said last.
            let front = frontPresence
            engine.front = { front.withLock { $0 } }
            phase = .on
            joinError = nil
            ready = false
            // Silent pushes wake this iPhone's line in the back (R2).
            SyncPush.letGo()
            SyncPush.bridge = self
            if let id = SyncPush.takeOpenedApproval() { openAssistantApproval(id) }
            UIApplication.shared.registerForRemoteNotifications()
            if let token = SyncPush.token { pushTokenArrived(token) }
            // Explicit demo worlds never stand beside a person's account.
            if !setup.ownWorld { putWorldAway() }
            // The journal is read off the main thread (a heavy account is
            // thousands of records); the line opens once it is in the stores.
            // Today became each device's own: the page in front stays in front.
            let frontLocal = app?.browser.tab.flatMap { $0.isPrivate ? nil : $0.id }
            let frontSynced = frontLocal.flatMap { ids.known($0) }
            Task.detached(priority: .userInitiated) { [weak self] in
                let copy = try? engine.keepFrontAsOwn(frontSynced)
                let snapshot = engine.snapshot()
                let items = engine.allMessages()
                let places = engine.places().map(SyncBridge.place)
                await MainActor.run {
                    guard let self, self.engine === engine else { return }
                    if let copy = copy ?? nil, let frontLocal, let frontSynced { self.ids.alias(frontLocal, to: copy, leaving: frontSynced) }
                    self.app?.history.adoptSynced(places, own: deviceID)
                    self.begin(engine, snapshot, items)
                    self.reconcileAssistantApprovals()
                    engine.start()
                }
            }
            return true
        } catch {
            log.error("sync didn't start: \(String(describing: error), privacy: .public)")
            joinError = "Sync could not start on this iPhone. Unlock it and try again. Your saved data is unchanged."
            phase = .off
            Motion.sheetRise.run { showsJoin = true }
            return false
        }
    }

    /// The journal as it stands: in the app at once, offline or not.
    private func begin(_ engine: PhoneSync, _ snapshot: SyncSnapshot, _ items: [String: [SyncChatItem]]) {
        folderArtwork.replace(account: engine.seal.account, icons: snapshot.icons)
        mirror = SyncMirror(spaces: snapshot.spaces, rows: snapshot.rows, device: engine.device)
        chatMirror = ChatMirror(chats: snapshot.chats, items: items, sends: snapshot.sends)
        pending = snapshot.pending
        macs = snapshot.macs
        app?.history.adoptBookmarks(snapshot.bookmarks)
        settings.importSearchPreferences(engine: snapshot.settings[SearchEngine.key]?.string,
                                                    customTemplate: snapshot.settings[SearchEngine.customKey]?.string)
        sharesPins = snapshot.settings[Self.sharedPinsKey]?.bool == true
        importShield(snapshot.settings)
        importField(snapshot.settings)
        settings.appIcons.adopt(snapshot.settings)
        settings.appIcons.onKeep = { [weak self] icon in self?.keepAppIcon(icon) }
        for icon in settings.appIcons.kept { keepAppIcon(icon) }
        if let person = snapshot.settings[DailyActivity.personKey]?.string {
            UserDefaults.standard.set(person, forKey: DailyActivity.personKey)
        }
        ready = true
        if !mirror.spaces.isEmpty || setup?.seed == true {
            // The seed: the world is this iPhone's own, it all goes up as changes.
            takeAccount()
        }
        adoptChats(nil)
        reconcileLiveTasks()
        // Pages a Mac sent while Yab was away, kept in the journal.
        takePages()
        probe?.say("pending", "\(pending)")
    }

    /// Sync's spaces are in: import unsynced live spaces and write changes
    /// from here on. Fixture worlds require ownWorld before they can be seeded.
    private func takeAccount() {
        guard !writing else { return }
        // Back in an account it left (Turn Off, Join Again): its rows wait
        // for the whole line, so a tab of the iPhone's not come yet isn't
        // taken for one the account closed (row 385).
        let rejoined = ids.rejoined
        if rejoined, line != .live { return }
        if !mirror.spaces.isEmpty {
            rebuild(nil, motion: nil, carry: rejoined)
        } else if setup?.ownWorld != true, app?.isFixture != false {
            return
        }
        writing = true
        flushLocal()
        if rejoined { closeFormerToday() }
        sendRecentVisits()
        watchHistorySwitch()
        if saysJoined, !mirror.spaces.isEmpty {
            saysJoined = false
            // A first launch says it with the found Mac's own tray.
            if settings.welcomed { app?.say("In sync with your Mac", glyph: .macbook) }
        }
    }

    /// Joined again: tabs of today still under an id this iPhone had
    /// before, closed here while it was out, close everywhere (the carried
    /// ones are its own again by now). Nothing else's.
    private func closeFormerToday() {
        guard let engine, !ids.former.isEmpty else { return }
        let stale = mirror.elsewhere.values.filter { $0.list == .today && $0.device.map(ids.former.contains) == true }
        for tab in stale {
            do {
                try engine.closeTab(tab.id)
                mirror.apply([.tabGone(tab.id)])
            } catch {
                log.error("sync close a former tab: \(String(describing: error), privacy: .public)")
            }
        }
        if !stale.isEmpty { countPending() }
    }

    /// What a person's launch showed before the key: Mira's world (the
    /// skeleton's start) goes, an empty space until the account's arrive,
    /// and only the account's chats.
    private func putWorldAway() {
        guard let app, app.isFixture else { return }
        let waiting = Space(id: Self.waitingSpace, name: "Personal", emoji: "🏠", tint: SyncMapping.plainTint,
                            today: [Tab(id: Self.waitingSpace + ".tab", title: "New Tab", site: "New Tab", icon: "globe", page: "blank")])
        for tab in app.browser.allTabs { app.pages.forget(tab.id) }
        app.browser.adopt([waiting])
        app.chats.adopt([], replacingAll: true)
        app.tasks.handoff = nil
    }

    /// The empty space a person's launch shows until the account's come.
    static let waitingSpace = "sync.waiting"

    private func changed(_ state: SyncClient.State) {
        defer { reconcileLiveTasks() }
        line = state
        probe?.say("state", Self.words(state))
        switch state {
        case .live:
            offline = false
            // Caught up: a joining iPhone takes the account's spaces now,
            // and from here on writes its own.
            takeAccount()
            pruneEmptyPersonals()
            countPending()
            wantsHandoff = true
            offerHandoff()
            prepareAssistantNotifications()
            reconcileAssistantApprovals()
        case let .refused(why):
            let words = why.replacingOccurrences(of: "This Mac", with: "This iPhone")
            folderArtwork.reset()
            phase = .refused(words)
            Motion.sheetRise.run { showsJoin = true }
        case .waiting:
            countPending()
            // A moment's blip says nothing; a line down a few seconds does.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, case .waiting = self.line, !self.offline else { return }
                Motion.rowArrive.run { self.offline = true }
            }
        case .off, .connecting:
            break
        }
    }

    private func prepareAssistantNotifications() {
        guard app?.isFixture == false else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let undecided = settings.authorizationStatus == .notDetermined
            Task { @MainActor [weak self] in self?.assistantNotificationsUndecided = undecided }
        }
    }

    /// Opening a chat, or the approval card's button: the system's question,
    /// once, while it is undecided. Never on launch or on joining Sync.
    func askForAssistantNotifications() {
        // A named state or a test world never asks: its pictures and checks
        // need the screen as the app draws it, and nothing there is anyone's.
        guard app?.isFixture == false, !LaunchOptions.current.isTestRun else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                Task { @MainActor [weak self] in
                    self?.prepareAssistantNotifications()
                    // Allowed now: the server alerts this iPhone of questions.
                    if let token = SyncPush.token { self?.pushTokenArrived(token) }
                }
            }
        }
    }

    /// Moves whenever a question, its detail, a page or a result may have
    /// changed: the tray reads them again.
    private(set) var assistantApprovalsTick = 0

    private func reconcileAssistantApprovals() {
        let latest = engine?.assistantApprovals() ?? []
        assistantApprovals = latest
        assistantApprovalsTick &+= 1
        if let engine {
            for (id, request) in answeredAssistantApprovals {
                if let result = engine.assistantResult(request), result != assistantApprovalResults[id] {
                    assistantApprovalResults[id] = result
                }
            }
        }
        assistantApprovalExpiry?.cancel()
        if let first = latest.map(\.expires).min() {
            assistantApprovalExpiry = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(1, first - Date().timeIntervalSince1970 + 1)))
                if !Task.isCancelled { self?.reconcileAssistantApprovals() }
            }
        }
        if let opened = openedAssistantApproval, !latest.contains(where: { $0.id == opened }), line == .live, engine?.assistantApprovalsReady == true {
            assistantApprovalReceipt = "Answered on your Mac"
            openedAssistantApproval = nil
        }
        // The server's alert said it already, opened by Notify/; or a
        // silent push woke the line: said here, under the question's id.
        guard app?.isFixture == false, line == .live, engine?.assistantApprovalsReady == true else { return }
        ApprovalNotice.reconcile(latest)
    }

    /// A yes is the person's: Face ID, Touch ID or the passcode first,
    /// here. A no needs nobody proven. A test world has nobody to ask.
    /// `done` hears whether it went: sent, the person cancelled the check,
    /// or the question changed under it.
    func answerAssistantApproval(_ id: String, yes: Bool, choice: String? = nil, picks: ApprovalPicks = ApprovalPicks(),
                                 done: @escaping @MainActor (ApprovalOutcome) -> Void = { _ in }) {
        guard yes, app?.isFixture == false, !LaunchOptions.current.isTestRun else {
            // A named state's pretend Mac: its answer goes nowhere real. A
            // test world on a real line (the end-to-end check) answers for real.
            if pretending { return pretendAnswer(id, yes: yes, done: done) }
            return done(sendAssistantAnswer(id, yes: yes, choice: choice, picks: picks, proved: yes))
        }
        let context = LAContext()
        var trouble: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &trouble) else {
            // No passcode on this iPhone: nothing to prove it with.
            return done(sendAssistantAnswer(id, yes: true, choice: choice, picks: picks, proved: false))
        }
        let title = assistantApprovals.first { $0.id == id }?.question ?? "this"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Approve \(title)") { ok, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard ok else { return done(.cancelled) }
                done(self.sendAssistantAnswer(id, yes: true, choice: choice, picks: picks, proved: true))
            }
        }
    }

    private func sendAssistantAnswer(_ id: String, yes: Bool, choice: String?, picks: ApprovalPicks, proved: Bool) -> ApprovalOutcome {
        guard let engine, let request = assistantApprovals.first(where: { $0.id == id }) else {
            assistantApprovalError = "This request changed or expired. Check it again in Yab on your Mac."
            return .failed
        }
        do {
            // A card or address typed here goes up first, so its id is known
            // by the time the answer names it.
            var added: [String] = []
            var card = picks.card, place = picks.place
            if yes, let new = picks.newCard {
                card = try engine.keepCard(number: new.number, csc: new.csc, name: new.name, month: new.month, year: new.year)
                added.append(card ?? "")
            }
            if yes, let new = picks.newPlace {
                place = try engine.keepAddress(name: new.name, street: new.street, city: new.city, postal: new.postal)
                added.append(place ?? "")
            }
            try engine.answerAssistantApproval(id, yes: yes, choice: choice, proved: proved, detail: picks.detail,
                                               card: card, place: place, added: added)
            if yes { answeredAssistantApprovals[id] = request }
            if openedAssistantApproval == id { openedAssistantApproval = nil }
            assistantApprovalError = nil
            reconcileAssistantApprovals()
            return .sent
        } catch {
            assistantApprovalError = "This request changed or expired. Check it again in Yab on your Mac."
            reconcileAssistantApprovals()
            return .failed
        }
    }

    /// The tray is done with a question's result: it stops being followed.
    func forgetAssistantResult(_ id: String) {
        answeredAssistantApprovals[id] = nil
        assistantApprovalResults[id] = nil
    }

    /// What a question is about, whole (the Mac's detail), if it sent one.
    func assistantDetail(_ request: AssistantApprovalRecords.Request) -> AssistantApprovalRecords.Detail? {
        if pretending { return pretendDetails[request.id] }
        return engine?.assistantDetail(request)
    }

    /// A page of a file in a question's detail, when it has come.
    func assistantPreview(_ request: AssistantApprovalRecords.Request, file: String, page: Int) -> UIImage? {
        let key = AssistantApprovalRecords.Preview.id(request: request.id, file: file, page: page)
        if pretending { return pretendPreviews[key] }
        if let cached = previewCache.object(forKey: key as NSString) { return cached }
        guard let data = engine?.assistantPreview(request, file: file, page: page), let image = UIImage(data: data) else { return nil }
        previewCache.setObject(image, forKey: key as NSString)
        return image
    }

    private let previewCache = NSCache<NSString, UIImage>()

    /// A named state's yes: a moment for the check, then what a Mac would
    /// write back, so the tray's every step can be filmed.
    private func pretendAnswer(_ id: String, yes: Bool, done: @escaping @MainActor (ApprovalOutcome) -> Void) {
        guard let request = assistantApprovals.first(where: { $0.id == id }) else { return done(.failed) }
        assistantApprovals.removeAll { $0.id == id }
        guard yes else { return done(.sent) }
        answeredAssistantApprovals[id] = request
        done(.sent)
        let pay = pretendDetails[id]?.pay != nil
        guard let ends = pretendPayEnds else { return }
        Task { @MainActor [weak self] in
            if pay {
                try? await Task.sleep(for: .milliseconds(250))
                self?.assistantApprovalResults[id] = .init(id: id, phase: .paying)
                try? await Task.sleep(for: .milliseconds(1600))
                self?.assistantApprovalResults[id] = ends == .declined
                    ? .init(id: id, phase: .declined, words: "Payment not completed")
                    : .init(id: id, phase: .paid, order: "#112-4836027")
            } else {
                try? await Task.sleep(for: .milliseconds(600))
                self?.assistantApprovalResults[id] = .init(id: id, phase: .done)
            }
        }
    }

    static func words(_ state: SyncClient.State) -> String {
        switch state {
        case .off: "off"
        case .connecting: "connecting"
        case .live: "live"
        case let .waiting(why): "waiting \(why)"
        case let .refused(why): "refused \(why)"
        }
    }

    /// The changes waiting here, counted off the main thread (a count, no
    /// record read); counted again while they go up, until all are taken.
    private func countPending() {
        guard let engine else { return }
        // A count already under way may have started before this change:
        // counted once more when it answers.
        guard !counting else { return recount = true }
        counting = true
        recount = false
        engine.countPending { [weak self] now in
            MainActor.assumeIsolated {
                guard let self else { return }
                // An engine let go meanwhile (Join Again): its count says nothing.
                guard self.engine === engine else { return self.counting = false }
                if now != self.pending { self.pending = now }
                self.probe?.say("pending", "\(now)")
                if self.recount {
                    self.counting = false
                    return self.countPending()
                }
                guard now > 0, self.line == .live else { return self.counting = false }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.counting = false
                    self?.countPending()
                }
            }
        }
    }

    // MARK: - the line in front and in the back

    private func listenToLifecycle() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameToFront() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentToBack() }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardUp = true }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardUp = false }
        })
    }

    /// In front: the line opens and catches up from the cursor; what waited
    /// goes up. A pause still draining is called off. Not in sync: the
    /// join sheet comes back (a removed iPhone's always).
    func cameToFront() {
        switch phase {
        case .joining: if asksOnFront, !firstRunOwnsJoining, !settings.withoutMac { openJoin() }
        case .refused: openJoin()
        case .on, .off: break
        }
        guard let engine, ready else { return }
        engine.start()
        reconcileAssistantApprovals()
        wantsHandoff = true
        offerHandoff()
    }

    /// To the back: what is going up gets five seconds, then the line
    /// closes. What is left waits in the journal for the next launch.
    func wentToBack() {
        flushLocal()
        guard let engine else { return }
        // Left now: a Mac offers this page for a minute from here, and hears
        // it before the line closes (the presence goes ahead of the pause).
        if frontSince != nil {
            frontSince?.at = Date()
            publishFront(app?.browser.tab, sayNow: false)
            engine.sayPresence()
        }
        let application = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        task = application.beginBackgroundTask(withName: "Sync") {
            application.endBackgroundTask(task)
        }
        engine.pause(within: 5) {
            DispatchQueue.main.async { application.endBackgroundTask(task) }
        }
    }

    // MARK: - silent pushes

    /// APNs' token for this iPhone: the server is told where to wake it.
    func pushTokenArrived(_ token: Data) {
        let topic = Bundle.main.bundleIdentifier ?? "dev.serafim.fast.iphone"
        // Questions come as alerts only where notifications are allowed;
        // never asked for from here.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let alerts = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            Task { @MainActor [weak self] in
                self?.engine?.wantPushes(.init(token: token, environment: SyncPush.environment, topic: topic, alerts: alerts))
            }
        }
    }

    /// A silent push: what changed elsewhere comes in now. In the back the
    /// line closes again once caught up; in front it stays.
    func wokenByPush(_ done: @escaping (UIBackgroundFetchResult) -> Void) {
        probe?.say("push", "")
        guard let engine, ready else { return done(.noData) }
        flushLocal()
        let inBack = UIApplication.shared.applicationState != .active || probe?.inFront == false
        engine.catchUp(closeAfter: inBack) { came in
            DispatchQueue.main.async {
                guard engine.assistantApprovalsReady else { done(.noData); return }
                ApprovalNotice.reconcile(engine.assistantApprovals()) { done(came ? .newData : .noData) }
            }
        }
    }

    // MARK: - from sync into the app

    /// A batch from the engine. The iPhone's own (origin local) is already
    /// in the stores; another device's rebuilds the rows it touched.
    func receive(_ batch: SyncBatch) {
        defer { reconcileLiveTasks() }
        if ready, phase == .on, let engine {
            for change in batch.changes {
                let id: String
                switch change {
                case let .icon(value): id = value.id
                case let .iconGone(value): id = value
                default: continue
                }
                // Always read the current merged journal. An old engine's
                // queued callback cannot reintroduce its account's pixels.
                let current = engine.journal.record(.init(collection: SyncCollection.icon, id: id)).flatMap(SyncIcon.init)
                folderArtwork.apply(account: engine.seal.account, id: id, icon: current)
            }
        }
        if batch.changes.contains(where: { change in
            switch change {
            case let .setting(value): return [SearchEngine.key, SearchEngine.customKey].contains(value.id)
            case let .settingGone(id): return [SearchEngine.key, SearchEngine.customKey].contains(id)
            default: return false
            }
        }), let engine {
            // Read the merged journal, including removal and a partial batch.
            let preferences = engine.settings()
            settings.importSearchPreferences(engine: preferences[SearchEngine.key]?.string,
                                             customTemplate: preferences[SearchEngine.customKey]?.string)
        }
        // The person's ID from their Mac, for the day's count (DailyActivity).
        for change in batch.changes {
            switch change {
            case let .setting(value) where value.id == DailyActivity.personKey:
                if let person = value.value.string { UserDefaults.standard.set(person, forKey: DailyActivity.personKey) }
            case let .settingGone(id) where id == DailyActivity.personKey:
                UserDefaults.standard.removeObject(forKey: DailyActivity.personKey)
            default: break
            }
        }
        let shieldKeys = [Self.shieldKey, Self.shieldPausedKey]
        if batch.changes.contains(where: { change in
            switch change {
            case let .setting(value): return Self.iconSetting(value.id)
            case let .settingGone(id): return Self.iconSetting(id)
            default: return false
            }
        }), let engine {
            settings.appIcons.adopt(engine.settings())
        }
        if batch.changes.contains(where: { change in
            switch change {
            case let .setting(value): return shieldKeys.contains(value.id)
            case let .settingGone(id): return shieldKeys.contains(id)
            default: return false
            }
        }), let engine {
            importShield(engine.settings())
        }
        let fieldKeys = [Self.fieldFirstRowKey, Self.fieldUnderKey]
        if batch.changes.contains(where: { change in
            switch change {
            case let .setting(value): return fieldKeys.contains(value.id)
            case let .settingGone(id): return fieldKeys.contains(id)
            default: return false
            }
        }), let engine {
            importField(engine.settings())
        }
        if batch.changes.contains(where: { change in
            switch change {
            case let .setting(value): return value.id == Self.sharedPinsKey
            case let .settingGone(id): return id == Self.sharedPinsKey
            default: return false
            }
        }), let engine {
            sharesPins = engine.settings()[Self.sharedPinsKey]?.bool == true
        }
        heardOpenRequests(batch.changes)
        heardPages(batch)
        heardHistory(batch)
        if batch.origin == .local {
            if batch.changes.contains(where: { if case .send = $0 { return true }; return false }) {
                chatMirror.apply(batch.changes)
                adoptChats(chatMirror.touched(by: batch.changes))
            }
            countPending()
            return
        }
        // What the person did a moment ago goes first, so a rebuild can't undo it.
        let started = CACurrentMediaTime()
        flushLocal()
        let flushed = CACurrentMediaTime()
        let touched = mirror.apply(batch.changes)
        if !writing {
            // The account's first spaces, on a launch that waited for them
            // (a batch of chats alone, early in a catch-up, isn't them).
            if !mirror.spaces.isEmpty { takeAccount() }
        } else if !touched.isEmpty {
            let arrived = batch.changes.contains { if case .tab = $0 { return true }; return false }
            let left = batch.changes.contains { if case .tabGone = $0 { return true }; return false }
            rebuild(touched, motion: arrived ? Motion.rowArrive : left ? Motion.rowLeave : Motion.columnRows)
        }
        let rows = CACurrentMediaTime()
        let chats = chatMirror.apply(batch.changes)
        if !chats.isEmpty || batch.changes.contains(where: { if case .send = $0 { return true }; return false }) { adoptChats(chats) }
        else if batch.changes.contains(where: { change in
            switch change {
            case .project, .projectGone: return true
            default: return false
            }
        }) { adoptProjects() }
        probe?.heard(batch, ids: ids)
        // The main thread's share of a batch, when it is more than a frame or three.
        let took = CACurrentMediaTime() - started
        if took > 0.05 {
            log.notice("""
            sync batch of \(batch.changes.count) took \(Int(took * 1000)) ms on the main thread: \
            flush \(Int((flushed - started) * 1000)), rows \(Int((rows - flushed) * 1000)), \
            chats \(chats.count) \(Int((CACurrentMediaTime() - rows) * 1000))
            """)
        }
    }

    /// The app's spaces from the mirror: all of them, or those touched.
    private func rebuild(_ touched: Set<String>?, motion: Motion?, carry: Bool = false) {
        guard let app else { return }
        let old = app.browser.spaces
        var out: [Space] = []
        for synced in mirror.orderedSpaces {
            let id = ids.local(synced.id)
            let had = old.first { $0.id == id }
            if let had, let touched, !touched.contains(synced.id) {
                out.append(had)
            } else {
                var space = SyncMapping.space(synced, row: mirror.row(synced.id), old: had, local: ids.local, fixturesEnabled: app.isFixture)
                if let had, !app.isFixture {
                    // A tab made here that never reached the journal stays:
                    // a link another app opened at launch, before the journal
                    // was read, was dropped and the page under it shown (row 1176).
                    space = carry ? Self.carried(had, into: space, carries: carries)
                        : Self.carried(had, into: space) { tab, _ in
                            // Presence can allocate an id before this tab is
                            // written. Only a journal record makes it synced.
                            guard let sid = self.ids.known(tab.id) else { return true }
                            return self.engine?.journal.record(.init(collection: SyncCollection.tab, id: sid)) == nil
                        }
                }
                out.append(space)
            }
        }
        // A real profile can predate joining. Import spaces that have never
        // had a journal record; a tombstone means the account removed one.
        var follow: Space.ID?
        if !app.isFixture, let engine {
            let firstAt = out.firstIndex { ids.known($0.id)?.uppercased() == SyncCollection.firstSpace }
            let imported = old.filter { space in
                guard !space.isPrivate, space.id != Self.waitingSpace else { return false }
                // A fresh install's untouched starting space joins an account
                // that has spaces of its own as nothing: each reinstall
                // added another empty Personal to it.
                if !mirror.spaces.isEmpty, Self.untouchedStart(space) { return false }
                // Used before joining, it is the account's Personal: its tabs
                // go into the first space, which every device shares, and
                // nothing makes a second Personal.
                if let firstAt, ids.known(space.id) == nil, Self.mergesIntoFirst(space) {
                    out[firstAt] = Self.merged(space, into: out[firstAt])
                    if app.browser.spaceID == space.id { follow = out[firstAt].id }
                    return false
                }
                guard let synced = ids.known(space.id) else { return true }
                return mirror.spaces[synced] == nil && engine.journal.record(.init(collection: SyncCollection.space, id: synced)) == nil
            }
            out += imported
        }
        // A private place, if the app has one, stays this iPhone's.
        out += old.filter(\.isPrivate)
        guard !out.isEmpty else { return }
        let front = frontTab
        // A tab gone from every space lets go of its page and its picture.
        let kept = Set(out.flatMap(\.allTabs).map(\.id))
        let gone = old.flatMap(\.allTabs).map(\.id).filter { !kept.contains($0) }
        let apply = {
            app.browser.adopt(out)
            app.browser.setOnMac(front)
        }
        if let motion { motion.run(apply) } else { Motion.columnRows.run(apply) }
        if let follow { app.browser.showSpace(follow) }
        for id in gone { app.pages.forget(id) }
    }

    // MARK: - from the app into sync

    /// Watches the stores the surfaces change: after each change, once the
    /// change is whole, its difference goes up.
    private func watchStores() {
        guard let app else { return }
        withObservationTracking {
            _ = app.browser.spaces
            _ = app.chats.chats
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.flushLocal()
                self.watchStores()
            }
        }
    }

    /// Search and Today folders remain Mac-owned; only ordinary kept folders
    /// are destinations or editable containers on this iPhone.
    func mayEditFolder(_ id: Folder.ID, in space: Space.ID) -> Bool {
        guard let sid = ids.known(space), let fid = ids.known(id), let folder = mirror.folders[fid] else { return true }
        return folder.space == sid && folder.search == nil && folder.today != true
    }

    /// An explicit folder move writes one tab field. Rebuilding from the
    /// same journal keeps the original fractional keys, not a second arrange.
    @discardableResult
    func moveToFolder(_ tab: Tab, in spaceID: Space.ID, to folder: Folder.ID?, expectedFolder: Folder?) -> Bool {
        guard let app, app.browser.spaceID == spaceID,
              let space = app.browser.space(spaceID), !space.isPrivate,
              space.tab(tab.id) == tab, !tab.isPrivate, tab.place == .kept,
              folder == nil || expectedFolder?.id == folder && space.folders.first(where: { $0.id == folder }) == expectedFolder,
              space.folder(holding: tab.id)?.id != folder else { return false }
        guard let engine else {
            return app.browser.moveIntoFolder(tab.id, in: spaceID, to: folder)
        }
        guard writing, let tid = ids.known(tab.id), let sid = ids.known(spaceID),
              let actual = engine.tab(tid), actual == mirror.tabs[tid], actual.space == sid, actual.list == .kept,
              actual.folder.map(ids.local) == space.folder(holding: tab.id)?.id else { return false }
        let target = folder.flatMap(ids.known)
        if folder != nil {
            guard let target, let actualFolder = engine.row(sid).folders[target],
                  actualFolder == mirror.folders[target] else { return false }
        }
        do {
            let changed = try engine.putInFolder(tid, folder: target)
            mirror.apply([.tab(changed)])
            rebuild([sid], motion: Motion.columnRows)
            return true
        } catch {
            log.error("move into folder: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// The starting space of a new profile (BrowserProfile.Snapshot.empty),
    /// never synced, holding nothing but blank tabs.
    static func untouchedStart(_ space: Space) -> Bool {
        space.id == BrowserProfile.startSpace && space.folders.isEmpty
            && space.allTabs.allSatisfy(isBlank)
    }

    /// A row with nothing on it: a new tab never taken anywhere.
    static func isBlank(_ tab: Tab) -> Bool {
        let url = tab.url ?? "about:blank"
        return url.isEmpty || url == "about:blank"
    }

    /// The starting space, never synced, used before joining and still
    /// called Personal: no folders of its own, so its tabs fit in another
    /// space as they are. Renamed, it is a space of the person's own.
    static func mergesIntoFirst(_ space: Space) -> Bool {
        space.id == BrowserProfile.startSpace && !space.isPrivate && space.folders.isEmpty && space.name == "Personal"
    }

    /// `first` with the starting space's tabs at the end of their lists:
    /// preserving pins and kept tabs. Blank
    /// new tabs stay behind; the one in front stays in front.
    static func merged(_ start: Space, into first: Space) -> Space {
        var out = first
        let have = Set(first.allTabs.map(\.id))
        for tab in start.keptTabs where !isBlank(tab) && !have.contains(tab.id) { out.kept.append(.tab(tab)) }
        for tab in start.pins where !tab.isPrivate && !isBlank(tab) && !have.contains(tab.id) { out.pins.append(tab) }
        for tab in start.today where !isBlank(tab) && !have.contains(tab.id) { out.today.append(tab) }
        out.placeTabs()
        if let current = start.current, out.tab(current) != nil { out.current = current }
        return out
    }

    /// Joining an account again (row 385): `rebuilt`, the space as the
    /// account has it, with the iPhone's own tabs `carries` names put back
    /// where they stood in `had`: today's among today's, kept ones at the
    /// end of the kept (a folder's stay out of it). The next write sends
    /// them up as this iPhone's. Pure, for the tests.
    static func carried(_ had: Space, into rebuilt: Space, carries: (Tab, SyncTab.List) -> Bool) -> Space {
        var out = rebuilt
        let present = Set(rebuilt.allTabs.map(\.id))
        let today = had.today.filter { !$0.isPrivate && !present.contains($0.id) && !isBlank($0) && carries($0, .today) }
        let pins = had.pins.filter { !$0.isPrivate && !present.contains($0.id) && !isBlank($0) && carries($0, .pinned) }
        let kept = had.kept.compactMap { item -> Tab? in
            guard case let .tab(tab) = item, !tab.isPrivate, !present.contains(tab.id), carries(tab, .kept) else { return nil }
            return tab
        }
        guard !today.isEmpty || !kept.isEmpty || !pins.isEmpty else { return rebuilt }
        let back = Set(today.map(\.id))
        out.today = SyncMapping.keepingPrivates(had.today, in: rebuilt.today) { back.contains($0.id) }
        out.kept += kept.map(KeptItem.tab)
        out.pins += pins
        out.placeTabs()
        out.current = SyncMapping.current(in: out, old: had)
        return out
    }

    /// A tab of the app's that the account's rows lack, when joining again:
    /// one never synced (made while sync was off), or one of today's still
    /// under an id this iPhone had before. One the account closed (its
    /// record is a tombstone) or another device's stays out.
    private func carries(_ tab: Tab, _ list: SyncTab.List) -> Bool {
        guard let sid = ids.known(tab.id) else { return true }
        if mirror.tabs[sid] != nil { return false }
        if let there = mirror.elsewhere[sid] {
            return list == .today && there.list == .today && there.device.map(ids.former.contains) == true
        }
        return engine?.journal.record(.init(collection: SyncCollection.tab, id: sid)) == nil
    }

    /// The spaces earlier installs added to the account, one empty Personal
    /// each (row 361): never the first, never one with a page, a folder,
    /// its own sign-ins or a private tab here, and one Personal always
    /// stays. A tab of today's of a device that is gone (`gone`, below) is
    /// no page: nobody sees it again (row 386). Pure, for the tests: the
    /// mirror and the app's spaces in, the synced ids to delete out.
    static func emptyPersonals(_ mirror: SyncMirror, local: (String) -> String, app spaces: [Space],
                               gone: Set<String> = []) -> [String] {
        func isPersonal(_ space: SyncSpace) -> Bool {
            space.name.trimmingCharacters(in: .whitespaces) == "Personal" && SpaceSymbols.emoji(space.icon) == "🏠"
        }
        guard let first = mirror.spaces.values.first(where: \.isFirst) else { return [] }
        let personals = mirror.orderedSpaces.filter { !$0.isFirst && isPersonal($0) }
        var empty = personals.filter { synced in
            let row = mirror.row(synced.id)
            guard !synced.ownSignIns, row.pins.isEmpty, row.kept.isEmpty, row.folders.isEmpty,
                  row.today.allSatisfy({ blankURL($0.url) }),
                  row.elsewhere.allSatisfy({ blankURL($0.url) || $0.device.map(gone.contains) == true }) else { return false }
            let here = spaces.first { $0.id == local(synced.id) }
            return here?.allTabs.allSatisfy(isBlank) ?? true
        }
        // The first space renamed and no full Personal: the oldest stays.
        if !isPersonal(first), empty.count == personals.count, !empty.isEmpty { empty.removeFirst() }
        return empty.map(\.id)
    }

    /// Which sweep of duplicate spaces this build runs (IDs.swept): once an
    /// account, so a later rule can run again under a new number.
    static let sweep = 1

    /// The copies of a space an iPhone added each time it joined an account
    /// again before row 385's fix (its renamed starting space came back as
    /// a new space, its pages with it): spaces of the same name and icon,
    /// one made by a device that is gone (`creators`: the device of each
    /// space record's earliest stamp; `gone`: goneDevices) beside one that
    /// isn't. Such a copy goes only if nothing in it is its own: not the
    /// first space, no sign-ins or folders of its own, every page of it
    /// (pins, kept, today's, a living device's today's elsewhere) at an
    /// address one of the living copies has, and here no private tab or a
    /// page the living copies lack. A gone device's today's are no page
    /// (row 386). Pure, for the tests: the synced ids to delete.
    static func duplicateSpaces(_ mirror: SyncMirror, creators: [String: String], gone: Set<String>,
                                local: (String) -> String, app spaces: [Space]) -> [String] {
        func key(_ space: SyncSpace) -> String {
            space.name.trimmingCharacters(in: .whitespacesAndNewlines) + "\u{0}" + SpaceSymbols.emoji(space.icon)
        }
        func madeByGone(_ space: SyncSpace) -> Bool { creators[space.id].map(gone.contains) == true }
        func here(_ space: SyncSpace) -> Space? { spaces.first { !$0.isPrivate && $0.id == local(space.id) } }
        var doomed: [String] = []
        let groups = Dictionary(grouping: mirror.orderedSpaces, by: key)
        for space in mirror.orderedSpaces {
            guard let group = groups[key(space)], group.count > 1, !space.isFirst, madeByGone(space) else { continue }
            let living = group.filter { $0.isFirst || !madeByGone($0) }
            guard !living.isEmpty else { continue }
            var have = Set<String>()
            for copy in living {
                let row = mirror.row(copy.id)
                for tab in row.all + row.elsewhere where !blankURL(tab.url) { have.insert(address(tab.url)) }
                for tab in here(copy)?.allTabs ?? [] where !isBlank(tab) { have.insert(address(tab.url ?? "")) }
            }
            func covered(_ url: String) -> Bool { blankURL(url) || have.contains(address(url)) }
            let row = mirror.row(space.id)
            guard !space.ownSignIns, row.folders.isEmpty,
                  row.all.allSatisfy({ covered($0.url) }),
                  row.elsewhere.allSatisfy({ covered($0.url) || $0.device.map(gone.contains) == true }) else { continue }
            if let mine = spaces.first(where: { $0.id == local(space.id) }) {
                guard !mine.isPrivate, mine.folders.isEmpty, !mine.ownSignIns,
                      mine.allTabs.allSatisfy({ !$0.isPrivate && (isBlank($0) || covered($0.url ?? "")) }) else { continue }
            }
            doomed.append(space.id)
        }
        return doomed
    }

    /// The devices whose tabs of today nobody will see again: removed from
    /// the account, ids this iPhone had before (IDs.former), and other
    /// iPhones and iPads not heard from in 30 days (an install deleted
    /// without leaving: a reinstall comes back as a new device). Never this
    /// iPhone, never a Mac still in, never one the list doesn't say when it
    /// last saw.
    static func goneDevices(_ roster: [SyncClient.Listed], me: String, former: Set<String>, now: Date = Date()) -> Set<String> {
        var gone = former
        for device in roster where device.id != me {
            let phone = device.model.hasPrefix("iPhone") || device.model.hasPrefix("iPad")
            if device.revoked {
                gone.insert(device.id)
            } else if phone, let seen = device.lastSeen, now.timeIntervalSince(seen) > 30 * 86_400 {
                gone.insert(device.id)
            }
        }
        gone.remove(me)
        return gone
    }

    /// An address as two copies of a page compare: no trailing slash.
    static func address(_ url: String) -> String {
        var url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    static func blankURL(_ url: String) -> Bool { url.isEmpty || url == "about:blank" }

    /// Once a line is caught up, writing and the device list read: the
    /// account's duplicate empty Personal spaces go, and, once an account,
    /// the copies joining again added (row 385), on every device (Delete
    /// Space's way). Logged, never said: nothing of the person's goes.
    private func pruneEmptyPersonals() {
        guard let app, !app.isFixture, writing, let engine, !pruned, let roster = engine.roster else { return }
        pruned = true
        let gone = Self.goneDevices(roster, me: engine.device, former: ids.former)
        var doomed = Self.emptyPersonals(mirror, local: ids.local, app: app.browser.spaces, gone: gone)
        if !doomed.isEmpty { log.notice("sync: removing \(doomed.count) empty duplicate Personal spaces") }
        if ids.swept < Self.sweep {
            var creators: [String: String] = [:]
            for id in mirror.spaces.keys {
                creators[id] = engine.journal.record(.init(collection: SyncCollection.space, id: id))?.stamps.values.min()?.device
            }
            let copies = Self.duplicateSpaces(mirror, creators: creators, gone: gone, local: ids.local, app: app.browser.spaces)
                .filter { !doomed.contains($0) }
            log.notice("sync: sweep \(Self.sweep): \(copies.count) duplicate spaces from joining again, \(gone.count) devices gone")
            doomed += copies
            ids.markSwept(Self.sweep)
            do { try ids.persist() } catch {
                log.error("sync sweep mark: \(String(describing: error), privacy: .public)")
            }
        }
        for id in doomed { deleteSpace(ids.local(id)) }
    }

    /// The Mac's first space is where everything was before: it stays, as
    /// on the Mac, whose Delete Space never offers it.
    func mayDeleteSpace(_ spaceID: Space.ID) -> Bool {
        guard let app, app.browser.mayDeleteSpace(spaceID) else { return false }
        guard engine != nil, let sid = ids.known(spaceID), mirror.spaces[sid] != nil else { return true }
        return writing && sid.uppercased() != SyncCollection.firstSpace
    }

    /// Delete Space: gone here and, written at once, on every device. A
    /// space sync never had goes only here.
    func deleteSpace(_ spaceID: Space.ID) {
        guard let app, mayDeleteSpace(spaceID) else { return }
        if let engine, let sid = ids.known(spaceID), mirror.spaces[sid] != nil {
            // Before the line is caught up, sync would only bring it back.
            guard writing else { return }
            do {
                mirror.apply(try engine.deleteSpace(sid))
            } catch {
                log.error("delete space: \(String(describing: error), privacy: .public)")
                return
            }
        }
        var gone: [Tab.ID] = []
        Motion.columnRows.run { gone = app.browser.deleteSpace(spaceID) }
        for id in gone { app.pages.forget(id) }
    }

    /// A space's id as sync names it, for the end-to-end probe (SyncProbe).
    func syncSpace(_ local: Space.ID) -> String? { ids.known(local) }

    /// What the iPhone changed since the mirror, written as records: spaces
    /// made or renamed, tabs opened, closed, kept, pinned, moved, or put in
    /// a new place of their list. Private tabs never leave the iPhone.
    func flushLocal() {
        guard writing, let app else { return }
        let started = CACurrentMediaTime()
        flushChats()
        let chatsTook = CACurrentMediaTime() - started
        guard let engine else {
            // No line (a named state's Mac): the mirror is what the app shows,
            // and the stand-in Mac's own tabs of today, which it doesn't.
            var rebuilt = Self.mirror(of: app.browser.spaces, ids: &ids, keeping: mirror, fixturesEnabled: app.isFixture)
            rebuilt.elsewhere = mirror.elsewhere
            mirror = rebuilt
            return
        }
        app.tabClear.markShared()
        let spaces = app.browser.spaces.filter { !$0.isPrivate && $0.id != Self.waitingSpace }
        // Persist the local identity before writing its UUID to the journal.
        // If this fails, keep the profile and retry without writing new ids.
        if !app.isFixture {
            do {
                for space in spaces {
                    _ = ids.sync(space.id)
                    for tab in space.allTabs where !tab.isPrivate { _ = ids.sync(tab.id) }
                    for folder in space.folders { _ = ids.sync(folder.id) }
                }
                try ids.persist()
            } catch {
                log.error("sync browser identities: \(String(describing: error), privacy: .public)")
                return
            }
        }
        // Each write's record goes into the mirror as it is made: nothing is
        // read back from the journal for it.
        final class Wrote { var any = false; var what: [String: Int] = [:] }
        let wrote = Wrote()
        func attempt(_ what: String, _ body: () throws -> [SyncChange]) {
            do {
                let changes = try body()
                mirror.apply(changes)
                wrote.any = true
                wrote.what[what, default: 0] += 1
            } catch {
                log.error("sync \(what, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        // Spaces made or renamed here.
        for space in spaces {
            let id = ids.sync(space.id)
            if let synced = mirror.spaces[id] {
                // A Mac's symbol is shown here as its emoji: written back
                // only once another one was picked (feedback #354).
                let icon = SpaceSymbols.wire(shown: space.emoji, synced: synced.icon)
                let choice = icon != synced.icon ? icon : synced.iconChoice
                let choiceID = icon != synced.icon ? UUID().uuidString : synced.iconChoiceID
                if synced.name != space.name || synced.icon != icon {
                    attempt("rename space") {
                        try engine.renameSpace(id, name: space.name, icon: icon, iconChoice: choice, iconChoiceID: choiceID)
                        var renamed = synced
                        renamed.name = space.name
                        renamed.icon = icon
                        renamed.iconChoice = choice
                        renamed.iconChoiceID = choiceID
                        return [.space(renamed)]
                    }
                }
            } else {
                attempt("make space") { try [.space(engine.makeSpace(id: id, name: space.name, icon: space.emoji, paint: space.look.flatMap { SyncPaint($0.raw) }))] }
            }
        }
        // A look's raw value carries the Mac's newer effects through an edit.
        for space in spaces {
            let id = ids.sync(space.id)
            if let look = space.look, mirror.spaces[id]?.paint?.raw != look.raw,
               let paint = SyncPaint(look.raw) {
                attempt("space look") { try [.space(engine.setSpaceLook(id, paint: paint))] }
            }
        }
        for space in spaces {
            let id = ids.sync(space.id)
            let profile = space.signInWith.map { ids.sync($0) }
            if mirror.spaces[id]?.ownSignIns != space.ownSignIns || mirror.spaces[id]?.signInWith != profile {
                attempt("space sign-ins") { try [.space(engine.setSpaceSignIns(id, own: space.ownSignIns, signInWith: profile))] }
            }
        }
        // Dissolve removed folders before writing their promoted children.
        // Every nested identity is persisted before any journal write above.
        for space in spaces {
            let sid = ids.sync(space.id)
            let retained = Set(space.folders.map { ids.sync($0.id) })
            for folder in Array(mirror.folders.values) where folder.space == sid && folder.search == nil && folder.today != true && !retained.contains(folder.id) {
                attempt("delete folder") { try engine.deleteFolder(folder.id, in: sid) }
            }
            func writeFolders(_ items: [KeptItem], parent: String?) {
                for item in items {
                    guard case let .folder(folder) = item else { continue }
                    let fid = ids.sync(folder.id)
                    if let old = mirror.folders[fid] {
                        if (old.name ?? "Folder") != folder.name {
                            attempt("rename folder") { try [.folder(engine.renameFolder(fid, in: sid, to: folder.name))] }
                        }
                    } else {
                        attempt("make folder") { try [.folder(engine.makeFolder(id: fid, name: folder.name, in: sid, parent: parent))] }
                    }
                    writeFolders(folder.items, parent: fid)
                }
            }
            writeFolders(space.kept, parent: nil)
        }
        // Where each tab is now.
        struct Want { var space: String; var list: SyncTab.List; var url: String; var title: String; var name: String?; var folder: String? }
        var wants: [String: Want] = [:]
        var wanted: [String] = []
        var order: [String: [SyncTab.List: [String]]] = [:]
        for space in spaces {
            let sid = ids.sync(space.id)
            let holders = KeptTree.holders(space.kept)
            func put(_ tab: Tab, _ list: SyncTab.List) {
                guard !tab.isPrivate else { return }
                let id = ids.sync(tab.id)
                wants[id] = Want(space: sid, list: list, url: SyncMapping.wireURL(tab, fixturesEnabled: app.isFixture),
                                 title: tab.pageTitle ?? (tab.name == nil ? tab.title : mirror.tabs[id]?.title ?? tab.title), name: tab.name, folder: holders[tab.id].map { ids.sync($0) })
                wanted.append(id)
                order[sid, default: [:]][list, default: []].append(id)
            }
            space.pins.forEach { put($0, .pinned) }
            space.keptTabs.forEach { put($0, .kept) }
            space.today.forEach { put($0, .today) }
        }
        let shown = Set(spaces.map { ids.sync($0.id) })
        // Closed here: gone everywhere. Only rows of spaces the app has.
        for (id, tab) in mirror.tabs where wants[id] == nil && shown.contains(tab.space) {
            attempt("close") {
                try engine.closeTab(id)
                return [.tabGone(id)]
            }
        }
        for id in wanted {
            guard let want = wants[id] else { continue }
            // Beside the row it stands by in its list here, among those sync has.
            func place(in list: SyncTab.List) -> PhoneSync.Place {
                let neighbors = order[want.space]?[list] ?? []
                let at = neighbors.firstIndex(of: id) ?? 0
                let settled = { (other: String) in other != id && self.mirror.tabs[other]?.space == want.space && self.mirror.tabs[other]?.list == list }
                if let next = neighbors.dropFirst(at + 1).first(where: settled) { return .before(next) }
                if let previous = neighbors.prefix(at).last(where: settled) { return .after(previous) }
                return .bottom
            }
            if mirror.tabs[id] == nil {
                // A tab pinned before its first write reaches sync as a pin.
                let list = want.list
                attempt("open") { try [.tab(engine.openTab(id: id, url: want.url, title: want.title, in: want.space, list: list, at: place(in: list)))] }
            }
            guard let had = mirror.tabs[id] else { continue }
            if had.space != want.space || had.list != want.list {
                attempt("move") { try [.tab(engine.move(id, to: want.space, list: want.list, at: place(in: want.list)))] }
            }
            let now = mirror.tabs[id] ?? had
            if app.isFixture ? SyncMapping.address(now.url) != SyncMapping.address(want.url) : now.url != want.url {
                attempt("navigate") { try [.tab(engine.navigate(id, url: want.url, title: want.title))] }
            } else if now.title != want.title, !want.title.isEmpty, want.title != SyncMapping.address(now.url) {
                attempt("title") { try [.tab(engine.navigate(id, url: now.url, title: want.title))] }
            }
            if mirror.tabs[id]?.name != want.name {
                attempt("rename") {
                    try engine.rename(id, want.name)
                    guard let renamed = engine.tab(id) else { return [] }
                    return [.tab(renamed)]
                }
            }
            if want.list == .kept, mirror.tabs[id]?.folder != want.folder {
                attempt("folder") { try [.tab(engine.putInFolder(id, folder: want.folder))] }
            }
        }
        // Each list in the iPhone's order, with the fewest keys changed.
        for (sid, lists) in order {
            let row = mirror.row(sid)
            for (list, wanted) in lists where list != .pinned {
                // The kept as the iPhone shows them, a folder's tabs together:
                // only an order the person changed here is written.
                let now = list == .kept ? SyncMapping.keptOrder(row) : row.today.map(\.id)
                if now != wanted {
                    attempt("arrange") { try engine.arrange(sid, list: list, ids: wanted).map(SyncChange.tab) }
                }
            }
        }
        if wrote.any {
            countPending()
            probe?.say("wrote", "\(pending)")
        }
        let took = CACurrentMediaTime() - started
        if took > 0.05 {
            let what = wrote.what.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
            log.notice("""
            sync: writing took \(Int(took * 1000)) ms on the main thread, chats \(Int(chatsTook * 1000)) of them \
            (\(what.isEmpty ? "nothing written" : what, privacy: .public))
            """)
        }
    }

    /// The mirror a line-less bridge keeps: the app's own spaces as records.
    static func mirror(of spaces: [Space], ids: inout IDs, keeping old: SyncMirror, fixturesEnabled: Bool = true) -> SyncMirror {
        var out = SyncMirror()
        let shown = spaces.filter { !$0.isPrivate }
        // Spaces keep the app's order, as the Mac keeps its own.
        let places = Order.assign(shown.map { ids.sync($0.id) }, previous: old.spaces.compactMapValues(\.order))
        for space in shown {
            let sid = ids.sync(space.id)
            var synced = old.spaces[sid] ?? SyncSpace(id: sid, name: space.name, icon: space.emoji)
            synced.name = space.name
            let icon = SpaceSymbols.wire(shown: space.emoji, synced: synced.icon)
            if icon != synced.icon { synced.iconChoice = icon; synced.iconChoiceID = UUID().uuidString }
            synced.icon = icon
            synced.ownSignIns = space.ownSignIns
            synced.signInWith = space.signInWith.map { ids.sync($0) }
            if let look = space.look { synced.paint = SyncPaint(look.raw) }
            synced.order = places[sid]
            out.spaces[sid] = synced
            var keys = Order.assign(space.allTabs.filter { !$0.isPrivate }.map { ids.sync($0.id) }, previous: [:])
            func put(_ tab: Tab, _ list: SyncTab.List, folder: String? = nil) {
                guard !tab.isPrivate else { return }
                let id = ids.sync(tab.id)
                out.tabs[id] = SyncTab(id: id, space: sid, order: keys.removeValue(forKey: id), url: SyncMapping.wireURL(tab, fixturesEnabled: fixturesEnabled),
                                       title: tab.pageTitle ?? (tab.name == nil ? tab.title : old.tabs[id]?.title ?? tab.title),
                                       pin: list == .pinned ? "" : nil, name: tab.name, kept: list == .kept, folder: folder,
                                       customMark: tab.customMark)
            }
            space.pins.forEach { put($0, .pinned) }
            func kept(_ items: [KeptItem], parent: String?) {
                for item in items {
                    switch item {
                    case let .tab(tab): put(tab, .kept, folder: parent)
                    case let .folder(folder):
                        let fid = ids.sync(folder.id)
                        out.folders[fid] = SyncFolder(id: fid, space: sid, name: folder.name, open: folder.open,
                                                     customMark: folder.customMark, color: folder.color, folder: parent)
                        kept(folder.items, parent: fid)
                    }
                }
            }
            kept(space.kept, parent: nil)
            space.today.forEach { put($0, .today) }
        }
        return out
    }

    // MARK: - chats

    enum QuestionFailure: LocalizedError {
        case notJoined, noMac, starting, privateConversation, unsupportedAgent, chatNotReady, syncChanged, projectsUnsupported
        var errorDescription: String? {
            switch self {
            case .projectsUnsupported: PhoneSync.projectsUnsupported
            case .notJoined: "Join your Mac in Settings to ask Claude."
            case .noMac: "No Mac is in your sync account yet. Open Yab on your Mac and try again."
            case .starting: "Wait until your Mac starts this chat before sending more."
            case .syncChanged: "Sync changed while this question was being prepared. Ask again."
            case .unsupportedAgent: ChatAgent.unsupported
            case .chatNotReady: "Your Mac hasn't synced this chat yet. Wait for sync before sending more."
            case .privateConversation: "Private conversations stay on this iPhone. Ask about a public page to use your Mac."
            }
        }
    }

    /// A new chat needs the Mac's id before a second turn can be sent.
    func isStartingChat(_ id: Chat.ID) -> Bool {
        guard engine?.chat(id) == nil else { return false }
        return chatMirror.sent.values.contains { send in
            guard send.clientDevice == engine?.options.device.id, send.clientChat == id else { return false }
            if send.state == .waiting { return true }
            if send.state == .taken, let remote = send.chat {
                return chatMirror.heads[remote] == nil
            }
            return false
        }
    }

    /// Its Mac takes Stop and Delete for this chat from here.
    func canControlChat(_ id: Chat.ID) -> Bool {
        guard phase == .on, ready, let engine else { return false }
        return engine.canControlChat(id)
    }

    /// Stop a chat's run, or delete the chat, on its Mac (ChatControl).
    func controlChat(_ id: Chat.ID, _ action: SyncSend.Action) -> Bool {
        guard phase == .on, ready, let engine, (try? engine.control(action, chat: id)) != nil else { return false }
        if action == .delete { app?.chats.remove(id) }
        return true
    }

    /// Delete for a chat its Mac can't delete from here: off this iPhone only.
    func forgetChat(_ id: Chat.ID) {
        engine?.forget(chat: id)
        app?.chats.remove(id)
    }

    /// Delete for one of this iPhone's chats (a question its Mac never
    /// answered, failed or still waiting): what still waits is taken back,
    /// and its sends, or the chat its Mac makes of them later, never bring
    /// it back here.
    func forgetOwnChat(_ id: Chat.ID) {
        if let engine {
            let taken = engine.cancelSends(ofClientChat: id)
            if !taken.isEmpty { chatMirror.apply(taken.map { .send($0) }) }
            engine.forget(chat: id)
        }
        app?.chats.remove(id)
    }

    /// The only path that writes a question. Store observation writes
    /// flags, never guesses that a displayed bubble is a new send.
    @discardableResult
    func sendQuestion(_ context: AskContext, in id: Chat.ID, agent: ChatAgent? = nil,
                      expectedEngine: PhoneSync? = nil, files: [SendUpload] = [], pick: ModelChoice? = nil) throws -> SyncSend {
        if let expectedEngine, engine !== expectedEngine { throw QuestionFailure.syncChanged }
        if let app, app.chats.isPrivate(id) || app.chatSheet.pageSources[id]?.isPrivate == true
            || app.chatSheet.pages[id].flatMap({ app.browser.tab($0) })?.isPrivate == true {
            throw QuestionFailure.privateConversation
        }
        guard phase == .on, ready, let engine else { throw QuestionFailure.notJoined }
        guard !isStartingChat(id) else { throw QuestionFailure.starting }
        let send: SyncSend
        if engine.chat(id) != nil || id.hasPrefix("a:") || id.hasPrefix("c:") {
            guard engine.chat(id) != nil else { throw QuestionFailure.chatNotReady }
            var continuation = context
            continuation.history = []
            send = try engine.say(continuation.macPrompt, in: id, clientChat: id, question: context.question, files: files,
                                  model: pick?.model, effort: pick?.effort)
        } else {
            guard !macs.isEmpty else { throw QuestionFailure.noMac }
            // A model picked for the new chat brings its agent.
            let selected = pick?.cli.flatMap(ChatAgent.init(rawValue:))
                ?? agent ?? (app?.isFixture == false ? app?.chatSheet.answerers.preferredMacAgent : nil)
            guard let mac = newChatMac(engine, agent: selected) else { throw QuestionFailure.unsupportedAgent }
            // Begun in a project: only a Mac that takes projects starts it.
            let project = app?.chats.chat(id)?.project
            if project != nil, !engine.canStartInProject(on: mac.id) { throw QuestionFailure.projectsUnsupported }
            send = try engine.startChat(context.macPrompt, on: mac.id, clientChat: id, question: context.question, agent: selected, files: files,
                                        model: pick?.model, effort: pick?.effort, project: project)
            chosenMacOnce = nil
        }
        // The callback is queued; keep a second tap in this turn from
        // creating another chat before that callback arrives.
        chatMirror.apply([.send(send)])
        adoptChats(send.chat.map { Set([$0]) } ?? [])
        return send
    }

    /// The Mac a new chat's first words go to (MacPick): picked by hand,
    /// else the one used last that is up, else the one used last.
    private func newChatMac(_ engine: PhoneSync, agent: ChatAgent?) -> SyncMac? {
        MacPick.pick(macs, chosen: chosenMacOnce ?? chosenMac) { agent == nil || engine.canStartAgent(on: $0.id) }
    }

    /// The Mac new work goes to, for the + menu's Mac row and the line over
    /// a new chat's field.
    func newWorkMac() -> SyncMac? {
        // A named state's stand-in Macs have no engine: the rules alone.
        guard phase == .on, ready, let engine else { return MacPick.pick(macs, chosen: chosenMacOnce ?? chosenMac) }
        let agent = app?.isFixture == false ? app?.chatSheet.answerers.preferredMacAgent : nil
        return newChatMac(engine, agent: nil) ?? newChatMac(engine, agent: agent)
    }

    /// Whether sync already has this chat on its Mac.
    func engineChat(_ id: Chat.ID) -> Bool { engine?.chat(id) != nil }

    /// The Macs that take pages, and the one Open on Mac sends to now.
    var pageMacs: [SyncMac] {
        guard let engine else { return macs }
        return macs.filter { app?.isFixture == true || engine.canOpen(on: $0.id) }
    }
    var pageMac: SyncMac? { MacPick.pick(pageMacs, chosen: chosenMac) }

    /// The Mac picked by hand for new work, kept until it leaves the account
    /// or another is picked (the + menu's Mac page, Open on Mac's list).
    var chosenMac: String? {
        get { UserDefaults.standard.string(forKey: MacPick.chosenKey).flatMap { id in macs.contains { $0.id == id } ? id : nil } }
        set { UserDefaults.standard.set(newValue, forKey: MacPick.chosenKey) }
    }

    /// The Macs as the wait rows say them (SyncMapping.Macs).
    private var macLook: SyncMapping.Macs {
        let macs = self.macs
        let engine = self.engine
        return SyncMapping.Macs(
            name: { id in macs.first { $0.id == id }?.name },
            state: { id in macs.first { $0.id == id }?.state ?? .up },
            other: { id, cli in
                MacPick.other(than: id, in: macs) { mac in
                    guard let engine else { return false }
                    return cli.flatMap(ChatAgent.init(rawValue:)).map { _ in engine.canStartAgent(on: mac.id) } ?? true
                }
            })
    }

    /// Don't Send: the waiting words taken back, into the field again.
    @discardableResult
    func takeBack(send id: String) -> Bool {
        guard phase == .on, let engine else { return false }
        guard let taken = try? engine.cancel(send: id) else {
            app?.say("\(macs.first { $0.id == chatMirror.sent[id]?.device }?.name ?? "Your Mac") already took it", glyph: .macbook)
            return false
        }
        chatMirror.apply([.send(taken)])
        adoptChats(taken.chat.map { Set([$0]) } ?? [])
        return true
    }

    /// Ask on Mac mini: the waiting words taken back from their sleeping
    /// Mac and asked in a new chat on one that is up, files and all.
    func askOnOther(send id: String, mac other: String) {
        guard let app, let had = chatMirror.sent[id], takeBack(send: id) else { return }
        let words = had.question ?? had.text
        chosenMacOnce = other
        app.newChatAsking(words)
    }

    /// One new chat's Mac, picked from a wait row's offer: used once.
    @ObservationIgnored var chosenMacOnce: String?

    /// Photos and files can go with words in this chat: its Mac, or the Mac
    /// a new chat would start on, takes them (SyncSendFile.capability).
    func canAttach(_ id: Chat.ID) -> Bool {
        guard phase == .on, ready, let engine, let app else { return false }
        if app.chats.isPrivate(id) || app.chatSheet.pageSources[id]?.isPrivate == true
            || app.chatSheet.pages[id].flatMap({ app.browser.tab($0) })?.isPrivate == true { return false }
        if engine.chat(id) != nil { return engine.canAttach(chat: id) }
        if id.hasPrefix("a:") || id.hasPrefix("c:") { return false }
        let agent = app.isFixture ? nil : app.chatSheet.answerers.preferredMacAgent
        return newChatMac(engine, agent: agent).map { engine.canAttach(on: $0.id) } ?? false
    }

    /// The models this chat's Mac (or a new chat's) offers, and the chat's
    /// own agent and model as its Mac says them. A chat keeps its agent:
    /// only that agent's models are offered for it.
    func models(for id: Chat.ID) -> (models: [SyncMacModel], cli: String?, model: String?, effort: String?) {
        guard phase == .on, ready, let engine, let app else { return ([], nil, nil, nil) }
        if let head = engine.chat(id) {
            return (engine.models(on: head.device).filter { $0.cli == head.cli }, head.cli, head.model, head.effort)
        }
        if id.hasPrefix("a:") || id.hasPrefix("c:") { return ([], nil, nil, nil) }
        let agent = app.isFixture ? nil : app.chatSheet.answerers.preferredMacAgent
        guard let mac = newChatMac(engine, agent: nil) ?? newChatMac(engine, agent: agent) else { return ([], nil, nil, nil) }
        return (engine.models(on: mac.id), nil, nil, nil)
    }

    /// The chats sync has, into ChatStore: those touched, or all.
    private func adoptChats(_ touched: Set<String>?) {
        guard let app else { return }
        let asleep = app.browser.macAsleep
        // By id, once: an account brings thousands of chats at a time.
        var had = Dictionary(app.chats.chats.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var targets = touched
        let device = engine?.options.device.id
        let mine = chatMirror.sent.values.filter { $0.clientDevice == device && $0.clientChat != nil }
        let latest = Dictionary(grouping: mine, by: { $0.clientChat! }).compactMapValues { $0.max { ($0.at, $0.id) < ($1.at, $1.id) } }
        var gone = engine?.forgottenChats() ?? []
        let forgotten: (String) -> Bool = { gone.contains($0) }
        for (local, send) in latest where local != send.chat {
            // Deleted here before its Mac answered: the chat its Mac made
            // of it goes from this iPhone too, and stays on the Mac.
            if forgotten(local) {
                if let remote = send.chat, !forgotten(remote) { engine?.forget(chat: remote); gone.insert(remote); app.chats.remove(remote) }
                continue
            }
            if send.state == .taken, let remote = send.chat, let head = chatMirror.heads[remote], head.device == send.device {
                if had[remote] == nil { had[remote] = had[local] }
                let parked = app.chats.parked
                guard app.chats.linkLocalHistory(local, to: remote) else {
                    app.chats.update(local) { chat in
                        chat.messages.removeAll { $0.role == .typing || $0.role == .wait }
                        chat.messages.append(Message(role: .failed, text: "Your Mac returned a chat that couldn’t be opened. Send the question again."))
                    }
                    continue
                }
                app.chats.remove(local)
                if var parked, parked.chat == local { parked.chat = remote; app.chats.parked = parked }
                app.chatSheet.reidentify(local, as: remote)
                targets?.insert(remote)
            } else {
                let invalid = send.state == .taken && (send.chat == nil || send.chat.flatMap { chatMirror.heads[$0] }.map { $0.device != send.device } == true)
                if send.state == .cancelled {
                    // Taken back before its Mac named a chat: the new chat goes.
                    if had[local].map({ $0.messages.allSatisfy { $0.role != .answer } }) == true { app.chats.remove(local) }
                } else if let chat = SyncMapping.pendingChat(send, old: had[local], macAsleep: asleep, invalidReturn: invalid, macs: macLook) {
                    app.chats.adopt([chat], preservingLocalHistory: true)
                }
            }
        }
        let heads = chatMirror.heads.values.filter { (targets?.contains($0.id) ?? true) && !forgotten($0.id) }
        let chats = heads.sorted { ($0.updated, $0.id) > ($1.updated, $1.id) }.map { head in
            SyncMapping.chat(head, items: chatMirror.items(of: head.id), sends: chatMirror.sends(of: head.id), macAsleep: asleep,
                             old: had[head.id],
                             ownPhone: device, macs: macLook)
        }
        for chat in chats { adopted[chat.id] = chat }
        app.chats.adopt(chats)
        adoptProjects()
        app.syncRoute()
    }

    /// The account's projects of chats, as its Macs wrote them. A named
    /// state's projects (no engine) are its own.
    private func adoptProjects() {
        guard let app, let engine, !app.isFixture else { return }
        app.projects.adopt(engine.projects().map(ChatProject.init))
    }

    /// A chat's Mac takes it moved into a project from here.
    func canMoveToProject(_ id: Chat.ID) -> Bool {
        guard phase == .on, ready, let engine else { return false }
        return engine.canMoveToProject(id)
    }

    /// The Mac a new chat goes to starts it in a project.
    func canStartInProject() -> Bool {
        guard phase == .on, ready, let engine, let mac = newWorkMac() else { return false }
        return engine.canStartInProject(on: mac.id)
    }

    /// Pin, Unread and Archive set here. Questions are explicit sends.
    private func flushChats() {
        guard let app, let engine, !adopted.isEmpty else { return }
        let current = Dictionary(app.chats.chats.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, was) in adopted {
            guard let now = current[id], now != was else { continue }
            // Moved into a project, or out of one: the head's `project`.
            if now.project != was.project { try? engine.moveChat(id, to: now.project) }
            if now.pinned != was.pinned || now.archived != was.archived || now.unread != was.unread || now.title != was.title {
                try? engine.setChat(id, pinned: now.pinned != was.pinned ? now.pinned : nil,
                                    archived: now.archived != was.archived ? now.archived : nil,
                                    unread: now.unread != was.unread ? now.unread : nil,
                                    title: now.title != was.title ? now.title : nil)
            }
            adopted[id] = now
        }
    }

    @ObservationIgnored private var opensForMac: Set<String> = []

    /// The tab belongs to this call, so a private tab cannot be exported by a
    /// stale menu or a VoiceOver action even when its menu row is hidden.
    /// `quietly`: the page menu says it in its own row, so only a failure is a toast.
    /// `chosen`: that Mac when it takes pages (the end-to-end check names one).
    func openOnMac(_ tab: Tab, quietly: Bool = false, on chosen: String? = nil) {
        guard let app, !tab.isPrivate else { return }
        guard phase == .on, ready, let engine else {
            app.say(QuestionFailure.notJoined.localizedDescription, glyph: .macbook)
            return
        }
        guard let url = tab.navigationURL, OpenOnMac.url(url.absoluteString) != nil else {
            app.say(OpenOnMac.Failure.invalid.localizedDescription, glyph: .macbook)
            return
        }
        guard let mac = MacPick.pick(macs, chosen: chosen ?? chosenMac, can: { engine.canOpen(on: $0.id) }) else {
            app.say(macs.isEmpty ? QuestionFailure.noMac.localizedDescription : OpenOnMac.Failure.unsupported.localizedDescription,
                    glyph: .macbook)
            return
        }
        do {
            // The space it is in here, as sync names it: the Mac opens it there.
            let space = app.browser.space(holding: tab.id).flatMap { ids.known($0.id) }
            let send = try engine.open(url, on: mac.id, space: space)
            opensForMac.insert(send.id)
            // The one send with nothing on screen to answer it: said, by state.
            if !quietly || !mac.state.isUp { app.say(MacWords.sentToast(mac.name, mac.state), glyph: .macbook) }
        } catch {
            app.say(error.localizedDescription, glyph: .macbook)
        }
    }

    private func heardOpenRequests(_ changes: [SyncChange]) {
        guard let engine, let app else { return }
        for change in changes {
            guard case let .send(send) = change, send.kind == .open, opensForMac.contains(send.id),
                  send.clientDevice == engine.options.device.id else { continue }
            let name = macs.first { $0.id == send.device }?.name ?? "your Mac"
            switch send.state {
            case .waiting: continue
            case .taken: app.say("Opened on \(name)", glyph: .macbook)
            case let .failed(reason): app.say(reason.isEmpty ? OpenOnMac.Failure.unavailable.localizedDescription : reason, glyph: .macbook)
            case .expired: app.say("This link arrived too late. Send it again to open it.", glyph: .macbook)
            case .cancelled: break
            }
            opensForMac.remove(send.id)
        }
    }

    // MARK: - pages from a Mac (Send to iPhone)

    /// A page a Mac sent this iPhone came in: taken now.
    private func heardPages(_ batch: SyncBatch) {
        guard batch.origin == .remote, let engine else { return }
        let mine = engine.options.device.id
        let came = batch.changes.contains { change in
            guard case let .send(send) = change else { return false }
            return send.kind == .open && send.device == mine && send.state == .waiting
        }
        if came { takePages() }
    }

    /// Every page a Mac sent and this iPhone hasn't taken, each once
    /// (OpenOnPhone.take keeps the receipt first).
    func takePages() {
        guard phase == .on, ready, let engine, app != nil else { return }
        for page in engine.arrivals() {
            engine.take(page) { page in try MainActor.assumeIsolated { try arrive(page) } }
        }
    }

    /// A page a Mac sent, into the app: the tab that already shows it in the
    /// space it was in there (this iPhone's own space in front when it hasn't
    /// that one), else a new tab at the top of that space's Today. It comes
    /// in front at once when Yab is in front, nothing is being typed and it
    /// was sent a moment ago, and the corner says from where; otherwise it
    /// waits in Today and the Now line's card says "From <Mac>: <title>"
    /// with Open.
    private func arrive(_ page: OpenOnPhone.Arrival, front decided: Bool? = nil) throws {
        guard let app else { throw OpenOnMac.Failure.unavailable }
        let mac = macs.first { $0.id == page.sender }?.name ?? "your Mac"
        let browser = app.browser
        let named = page.space.map { ids.local($0) }.flatMap { browser.space($0) }
        let ordinary = browser.space.isPrivate ? browser.space(browser.ordinarySpaceID) : browser.space
        guard let space = (named?.isPrivate == false ? named : nil) ?? ordinary, !space.isPrivate else {
            throw OpenOnMac.Failure.unavailable
        }
        let had = space.allTabs.first { !$0.isPrivate && $0.navigationURL.map { ContinuePage.same($0, page.url) } == true }
        let tab: Tab
        if let had {
            tab = had
        } else {
            var made = PageFixtures.tab(for: page.url, isPrivate: false, in: app.world, fixturesEnabled: app.isFixture)
            if !page.title.isEmpty { made.title = page.title }
            browser.openBehind(made, after: "", in: space.id)
            tab = made
        }
        probe?.say("arrived", "\(page.id) \(tab.id) \(page.url.absoluteString)")
        let inFront = UIApplication.shared.applicationState == .active && probe?.inFront != false
        if browser.tab?.id == tab.id {
            // On screen already: only where it came from is news.
            app.say("From \(mac)", glyph: .macbook)
            probe?.say("arrival", "shown \(tab.id)")
        } else if decided ?? (inFront && !busy(app) && page.fresh(at: Date())) {
            browser.select(tab.id)
            app.say("From \(mac)", glyph: .macbook)
            probe?.say("arrival", "front \(tab.id)")
        } else {
            Motion.nowArrive.run { app.tasks.arrived = ArrivedPage(tab: tab.id, title: page.title, icon: tab.icon, mac: mac) }
            probe?.say("arrival", "card \(tab.id)")
        }
    }

    /// Something is being typed or a sheet is up: a page the Mac sent doesn't
    /// take the screen from under it.
    private func busy(_ app: AppModel) -> Bool {
        keyboardUp || app.surfaces.field != nil || app.surfaces.settings || app.surfaces.join || app.chatSheet.shown
    }

    // MARK: - leaving, joining by the Mac's code, the Recovery Key

    /// This iPhone's id among the account's devices.
    var ownDevice: String? { engine?.options.device.id ?? pretendOwnDevice }

    /// The account's Recovery Key, for its page once Face ID said yes.
    var recoveryKey: String? { phase == .on ? engine?.seal.recovery : nil }

    /// Settings › Sync › Turn Off Sync on This iPhone, after its question:
    /// the account forgets this iPhone (it is listed no more), and this
    /// iPhone forgets the key, its token, its id and the journal; its tabs
    /// and chats stay as they are. A Mac's key in iCloud Keychain doesn't
    /// bring it back by itself (SettingsStore.syncTurnedOff); joining again
    /// takes a code or the Recovery Key.
    func turnOff() {
        defer { reconcileLiveTasks() }
        guard phase == .on, let engine else { return }
        settings.syncTurnedOff = true
        engine.leave { _ in }
        forgetAccount()
        pairing?.cancel()
        pairing = nil
        macs = []
        devices = []
        phase = .off
        app?.browser.macAsleep = false
        app?.tasks.handoff = nil
        app?.tasks.arrived = nil
        SettingsUI.shared.recoveryShown = nil
        probe?.say("state", "turned off")
        app?.say("Sync Is Off on This iPhone", glyph: .arrowRotateClockwise)
    }

    /// The journal, key, token and id let go: what Join Again and Turn Off share.
    private func forgetAccount(keepingKey: Bool = false) {
        folderArtwork.reset()
        settings.importSearchPreferences(engine: nil, customTemplate: nil)
        importShield([:])
        importField([:])
        settings.appIcons.adopt([:])
        settings.appIcons.onKeep = nil
        engine?.stop()
        engine = nil
        if let setup {
            setup.keys.forget(keepingLocalKey: keepingKey)
            PhoneSync.leave(folder: setup.folder)
        }
        mirror = SyncMirror()
        chatMirror = ChatMirror()
        adopted = [:]
        writing = false
        ready = false
        line = .off
    }

    /// yab://join/<code>, the Camera on a Mac's Add a Device code: joining by
    /// it while this iPhone isn't in sync. False for any other link.
    func openJoinLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "yab", url.host?.lowercased() == "join" else { return false }
        if phase == .on {
            app?.say("This iPhone Is in Sync Already", glyph: .macbook)
        } else {
            joinWithInvite(url.absoluteString)
        }
        return true
    }

    /// Scan QR, or the Mac's code typed: this iPhone posts its key under the
    /// code its Mac shows (Settings › Sync › Add a Device) and shows the four
    /// digits the Mac asks about (JoinInvite); the Mac lets it in on a yes.
    /// False for something that isn't a Mac's code.
    @discardableResult
    func joinWithInvite(_ scanned: String) -> Bool {
        defer { reconcileLiveTasks() }
        guard let code = JoinInvite.code(scanned: scanned) else {
            joinError = "That isn't a code from Yab on your Mac. In Settings › Sync, choose Add a Device."
            return false
        }
        guard let setup else {
            // Named states and test worlds: the screen as it would be.
            pretend(.joining(.invite(code: code, check: "0000")), sheet: true)
            return true
        }
        joinError = nil
        pairing?.cancel()
        let pairing = PhonePairing(base: setup.base, transport: setup.transport, every: 2, code: code, invited: true)
        self.pairing = pairing
        Motion.joinSwap.run { phase = .joining(.invite(code: code, check: pairing.check)) }
        probe?.say("invite", "\(code) \(pairing.check)")
        if !showsJoin, !firstRunOwnsJoining { Motion.sheetRise.run { self.showsJoin = true } }
        pairing.start { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.pairing === pairing else { return }
                self.pairing = nil
                switch result {
                case let .success(seal):
                    guard self.keepForJoining(seal) else { return }
                    if self.joined(seal) { self.probe?.say("joined", "invite") }
                case .failure(.cancelled):
                    break
                case let .failure(failure):
                    // Back to this iPhone's own code, with why under it.
                    self.askToJoin()
                    switch failure {
                    case .server(409): self.joinError = "That code was used already. On your Mac, choose Add a Device for a new one."
                    case .expired: self.joinError = "That code ran out. On your Mac, choose Add a Device for a new one."
                    default: self.joinError = "Your Mac couldn't let this iPhone in. Try again with a new code."
                    }
                }
            }
        }
        return true
    }

    // MARK: - history

    /// A place in sync as History takes it, keyed by its address rather than
    /// the record's id: a Mac on an older Yab names a server's page without
    /// its port, and the same page from it and from a newer Mac is one place.
    nonisolated static func place(_ item: (visit: SyncVisit, device: String?)) -> SyncedPlace {
        SyncedPlace(key: item.visit.place, url: item.visit.url, title: item.visit.title, last: item.visit.last,
                    typed: item.visit.typed, device: item.device)
    }

    /// Places another device went to, and the Mac's bookmarks, into History
    /// as they come. This iPhone's own visits are in History already.
    private func heardHistory(_ batch: SyncBatch) {
        guard let engine, let history = app?.history else { return }
        var visits: [SyncVisit] = []
        var bookmarks = false
        for change in batch.changes {
            switch change {
            case let .visit(visit) where batch.origin == .remote:
                visits.append(visit)
            case .bookmark, .bookmarkGone:
                bookmarks = true
            default:
                break
            }
        }
        if bookmarks { history.adoptBookmarks(engine.bookmarks()) }
        guard !visits.isEmpty else { return }
        // A few as they come, each with its device; a catch-up's thousands
        // (a newly joined iPhone's two weeks) in one read off the main thread.
        guard visits.count > Self.visitsReadOneByOne else {
            history.syncedChanged(visits.map { Self.place(($0, engine.visitDevice($0.id))) })
            return
        }
        let own = engine.options.device.id
        Task.detached(priority: .utility) { [weak self] in
            let places = engine.places().map(SyncBridge.place)
            await MainActor.run {
                guard let self, self.engine === engine else { return }
                self.app?.history.adoptSynced(places, own: own)
            }
        }
    }

    /// More visits in one batch than this are read from the journal at once.
    static let visitsReadOneByOne = 64

    /// A page opened on this iPhone goes to the Mac's history (the visit
    /// records the Macs share), with History in Sync on: never a private
    /// tab's (the caller's to say), a sign-in step's or one older than the
    /// Mac's two weeks.
    func sendVisit(_ url: URL, title: String, at date: Date) {
        guard phase == .on, writing, settings.syncHistory, let engine, HistoryList.syncs(url, at: date) else { return }
        do { try engine.visited(url, title: title, at: date) }
        catch { log.error("history visit: \(String(describing: error), privacy: .public)") }
    }

    /// This iPhone's last two weeks, once sync writes and each time History
    /// in Sync is turned on: only what the records don't have yet is written,
    /// off the main thread.
    private func sendRecentVisits() {
        guard phase == .on, writing, settings.syncHistory, let engine, let recent = app?.history.recentForSync, !recent.isEmpty else { return }
        let log = log
        Task.detached(priority: .utility) {
            for visit in recent {
                do { try engine.visited(visit.url, title: visit.title, at: visit.at) }
                catch { log.error("history visit: \(String(describing: error), privacy: .public)") }
            }
        }
    }

    @ObservationIgnored private var watchingHistory = false

    /// History in Sync turned on again sends what the Mac missed meanwhile.
    private func watchHistorySwitch(was: Bool? = nil) {
        if was == nil {
            guard !watchingHistory else { return }
            watchingHistory = true
        }
        let now = settings.syncHistory
        if let was, now, !was { sendRecentVisits() }
        withObservationTracking { _ = settings.syncHistory } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchHistorySwitch(was: now) }
        }
    }

    // MARK: - the Mac

    /// The Mac up now, if one is.
    var awakeMac: SyncMac? { macs.first { $0.online } }

    /// Resolve a Mac presence through the shared tab record. Presence from older
    /// Macs has no space, and a URL can exist in several spaces.
    func spaceOfMacTab(_ id: String) -> Space.ID? {
        _ = macTodayStamp
        _ = pinsStamp
        if let record = mirror.elsewhere[id] ?? mirror.tabs[id] { return ids.local(record.space) }
        return app?.browser.space(holding: ids.local(id))?.id
    }

    /// A space's tabs of today open on the Macs, in order: not in this
    /// iPhone's rows (docs/sync.md, "Today is each device's own").
    func macTabs(in space: Space.ID) -> [SyncTab] { mirror.row(ids.known(space) ?? space).elsewhere }

    /// A space's lines of the Macs' Today (Settings › Today › Your Mac's
    /// Tabs): each Mac's tabs of today in it, its tab in front first.
    func macToday(in space: Space.ID) -> [MacTodayLine] {
        _ = macTodayStamp
        let sid = ids.known(space) ?? space
        return MacToday.lines(tabs: macTabs(in: space), macs: macs,
                              closing: closingOnMac.values.filter { $0.space == sid }, fallbackName: app?.world.mac.name ?? "Your Mac")
    }

    /// Close on Mac, from its line here: the record goes, and the Mac
    /// closes it, now or when it wakes (docs/sync.md, "Today is each
    /// device's own"). A Mac down keeps the row, dimmed, until then.
    func closeOnMac(_ tab: SyncTab) {
        let owner = macs.first { $0.id == tab.device } ?? macs.first
        if let owner, !owner.state.isUp { closingOnMac[tab.id] = tab }
        guard let engine else {
            // A world without a line: the stand-in Mac's tab just goes.
            mirror.elsewhere[tab.id] = nil
            return
        }
        do {
            try engine.closeTab(tab.id)
            mirror.apply([.tabGone(tab.id)])
        } catch {
            closingOnMac[tab.id] = nil
            log.error("sync close on mac: \(String(describing: error), privacy: .public)")
        }
    }

    /// The app's id for a tab sync knows by `synced`.
    func localID(_ synced: String) -> Tab.ID { ids.local(synced) }

    /// The tab in front on the Mac, as the app knows it: the one up now,
    /// else the one asleep (its tab is still in front there, as it waits).
    var frontTab: Tab.ID? { macs.first?.front?.tab.map { ids.local($0) } }

    /// What this iPhone says of itself: its tab in front. Kept for the
    /// line's queue, which reads it while saying presence.
    @ObservationIgnored private let frontPresence = OSAllocatedUnfairLock<SyncPresence?>(initialState: nil)

    /// The Macs as the engine hears them, or as a named state's Mac says.
    func heard(_ macs: [SyncMac]) {
        defer { reconcileLiveTasks() }
        let previousOwners = Set(self.macs.map(\.id))
        // A Mac asleep, closed or back: the wait rows say it by name.
        let previousStates = self.macs.map { [$0.id: $0.state] }
        self.macs = macs
        guard let app else { return }
        if previousOwners != Set(macs.map(\.id)) || previousStates != macs.map({ [$0.id: $0.state] }) { adoptChats(nil) }
        // The first word from a Mac since this iPhone came to the front.
        if wantsHandoff, awakeMac?.front?.tab != nil {
            wantsHandoff = false
            offerHandoff()
        }
        let asleep = !macs.isEmpty && awakeMac == nil
        // Awake again: what was closed from here while it slept is closed there now.
        if !closingOnMac.isEmpty {
            let up = Set(macs.filter(\.state.isUp).map(\.id))
            closingOnMac = closingOnMac.filter { _, tab in !up.contains(tab.device ?? macs.first?.id ?? "") }
        }
        if app.browser.macAsleep != asleep {
            // Awake again: it catches up from the server by itself, and the
            // quiet line goes.
            (asleep ? Motion.rowArrive : Motion.rowLeave).run {
                app.browser.macAsleep = asleep
                if !asleep { app.browser.pendingForMac = 0 }
            }
            probe?.say("asleep", asleep ? "1" : "0")
            // Words waiting for it say so, or are being answered.
            adoptChats(Set(chatMirror.sent.values.filter { $0.state == .waiting }.compactMap(\.chat)))
        }
        let front = frontTab
        if app.browser.onMac?.id != front {
            app.browser.setOnMac(front)
            probe?.say("onmac", front.map { ids.sync($0) } ?? "none")
        }
    }

    /// The Mac's tab offered on the Now line ("On your Mac"), once for each
    /// tab it has in front, for a minute.
    func offerHandoff() {
        guard let app, let mac = awakeMac, let synced = mac.front?.tab else { return }
        let id = ids.local(synced)
        guard offered != synced, id != app.browser.tab?.id, let tab = app.browser.tab(id) else { return }
        offered = synced
        Motion.nowArrive.run { app.tasks.handoff = tab }
        Task { @MainActor [weak app] in
            try? await Task.sleep(for: .seconds(60))
            guard let app, app.tasks.handoff?.id == id else { return }
            Motion.nowGone.run { app.tasks.handoff = nil }
        }
    }

    /// Opening the tab the Mac has in front: the page starts where the Mac
    /// left it, once (the Mac says how far down with its presence).
    private func watchFront() {
        guard let app else { return }
        let tab = withObservationTracking {
            app.browser.tab
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchFront() }
        }
        publishFront(tab)
        retireUnavailableLiveChat()
        // The Mac's tab opened here some other way (its row): the offer is taken.
        if let tab, app.tasks.handoff?.id == tab.id { Motion.nowGone.run { app.tasks.handoff = nil } }
        // A page the Mac sent, opened from its row in Today: its chip goes too.
        if let tab, app.tasks.arrived?.tab == tab.id { Motion.nowGone.run { app.tasks.arrived = nil } }
        // Only the moment a tab comes in front here: a change to the rows
        // while it stays open (a new beat from the Mac, a Keep, a rebuild)
        // never scrolls the page back under the person's thumb.
        let cameInFront = tab?.id != lastFront
        lastFront = tab?.id
        guard cameInFront, let tab, let mac = awakeMac, let front = mac.front, let scroll = front.scroll,
              front.tab.map({ ids.local($0) }) == tab.id else { return }
        // And once for what the Mac said: back to it later, the page is
        // where it was left here.
        let once = "\(tab.id)@\(front.at)"
        guard scrolled != once else { return }
        scrolled = once
        scrollsPassed += 1
        Task { @MainActor in
            let view = app.pages.view(for: tab)
            await app.pages.waitUntilPainted(tab.id, timeout: .seconds(8))
            let how = (try? await view.evaluateJavaScript(Self.scrollScript(scroll))) as? Int ?? -1
            probe?.say("scrolled", String(format: "%.2f %d", scroll, how))
        }
    }

    /// What this iPhone says of its tab in front: its page, title, tab and
    /// space as sync names them, and when that page came in front here, for
    /// a Mac's From iPhone (PhoneFront). Said at once when it changed, a
    /// moment after, so a page loading says its title too.
    private func publishFront(_ tab: Tab?, sayNow: Bool = true) {
        guard let app else { return }
        let shown = tab?.isPrivate == true ? nil : tab
        let url = shown.map { SyncMapping.wireURL($0, fixturesEnabled: app.isFixture) }
        if url != frontSince?.url { frontSince = (url, Date()) }
        let space = shown.flatMap { app.browser.space(holding: $0.id) }.flatMap { $0.isPrivate ? nil : ids.known($0.id) }
        let presence = SyncPresence(device: "", name: "", at: 0, url: url, title: shown?.title,
                                    tab: shown.map { ids.sync($0.id) }, space: space,
                                    changed: frontSince?.at.timeIntervalSince1970)
        frontPresence.withLock { $0 = tab?.isPrivate == true ? nil : presence }
        guard sayNow, frontSaid?.url != url || frontSaid?.title != shown?.title else { return }
        frontSaid = (url, shown?.title)
        presenceSoon?.cancel()
        presenceSoon = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.engine?.sayPresence()
        }
    }

    /// Scrolls the page, or its scrolling part, to a fraction of its length.
    static func scrollScript(_ fraction: Double) -> String {
        """
        (function (f) {
          var e = document.scrollingElement || document.documentElement;
          if (e.scrollHeight - innerHeight > 2) { e.scrollTop = f * (e.scrollHeight - innerHeight); return 1; }
          var all = document.querySelectorAll('*');
          for (var i = 0; i < all.length; i++) {
            var n = all[i], s = getComputedStyle(n).overflowY;
            if ((s === 'auto' || s === 'scroll') && n.scrollHeight - n.clientHeight > 2) { n.scrollTop = f * (n.scrollHeight - n.clientHeight); return 2; }
          }
          return 0;
        })(\(fraction))
        """
    }

    // MARK: - the quiet line

    /// What a quiet line under a space's today would say, if anything: the
    /// Mac asleep with changes for it, or this iPhone offline with changes
    /// waiting to go up. Only in the space in front. Nothing draws it since
    /// the column went; sync's tests read the outbox's state through it.
    func note(for space: Space.ID) -> SyncNote? {
        guard let app, space == app.browser.spaceID else { return nil }
        // Turned away: sync is off until this iPhone joins again.
        if case .refused = phase { return .removed }
        if app.browser.macAsleep, app.browser.pendingForMac > 0 { return .macAsleep(app.browser.pendingForMac) }
        if offline, pending > 0 { return .offline(pending) }
        return nil
    }

    // MARK: - named states

    func pretendAssistantApprovals(_ requests: [AssistantApprovalRecords.Request],
                                   details: [AssistantApprovalRecords.Detail] = [], previews: [String: UIImage] = [:]) {
        guard app?.isFixture == true else { return }
        pretending = true
        pretendDetails = Dictionary(details.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        pretendPreviews = previews
        assistantApprovals = requests
    }

    /// A named state's question comes back after a decline, as a Mac asks
    /// again: the same request, answerable once more.
    func pretendAskAgain(_ request: AssistantApprovalRecords.Request, detail: AssistantApprovalRecords.Detail?) {
        guard app?.isFixture == true, !assistantApprovals.contains(where: { $0.id == request.id }) else { return }
        if let detail { pretendDetails[detail.id] = detail }
        assistantApprovals.insert(request, at: 0)
    }

    /// A Mac without a server, for named states: its tabs and presence
    /// arrive as they would from the line (Testing/States+Sync.swift).
    func pretend(_ changes: [SyncChange]) {
        writing = true
        if mirror.isEmpty, let app { mirror = Self.mirror(of: app.browser.spaces, ids: &ids, keeping: mirror) }
        receive(SyncBatch(origin: .remote, changes: changes))
    }

    /// The Mac opens a tab at the top of a space's today, as a Mac does.
    func pretendMacOpens(_ id: String, url: String, title: String, in space: String) {
        if mirror.isEmpty, let app { mirror = Self.mirror(of: app.browser.spaces, ids: &ids, keeping: mirror) }
        let row = mirror.row(ids.sync(space))
        let order = Order.between((row.kept.last ?? row.pins.last)?.order, row.today.first?.order)
        pretend([.tab(SyncTab(id: id, space: ids.sync(space), order: order, url: url, title: title,
                              seen: SyncTab.round(seen: Date().timeIntervalSince1970)))])
    }

    /// The Mac's tabs of today in a space, for named states: kept apart
    /// as a Mac's are (`SyncMirror.elsewhere`), not in this iPhone's rows.
    func pretendMacToday(_ tabs: [(url: String, title: String)], in space: String, mac: String = "mac") {
        if mirror.isEmpty, let app { mirror = Self.mirror(of: app.browser.spaces, ids: &ids, keeping: mirror) }
        let sid = ids.sync(space)
        var order: String?
        for (n, tab) in tabs.enumerated() {
            order = Order.between(order, nil)
            mirror.elsewhere["mac-\(space)-\(n)"] = SyncTab(id: "mac-\(space)-\(n)", space: sid, order: order, url: tab.url, title: tab.title,
                                                         device: mac)
        }
    }

    /// The account's Macs for a named state, each with what it is doing.
    func pretendMacs(_ list: [SyncMac]) { heard(list) }

    /// The account's Mac, up or asleep, with a tab in front.
    func pretendMac(awake: Bool, front: Tab.ID?, scroll: Double? = nil, name: String = "MacBook Pro") {
        let now = Date()
        let tab = front.flatMap { app?.browser.tab($0) }
        let presence = SyncPresence(device: "mac", name: name, at: now.timeIntervalSince1970,
                                    url: tab.map { SyncMapping.wireURL($0, fixturesEnabled: app?.isFixture ?? true) }, title: tab?.title,
                                    tab: front.map { ids.sync($0) }, scroll: scroll, asleep: !awake)
        heard([SyncMac(id: "mac", name: name, model: "Mac16,1", lastSeen: now, online: awake, front: presence,
                       state: awake ? .up : .asleep(since: now), usedAt: now)])
    }

    /// The end-to-end check's keyboard: something typed, or not (SyncProbe).
    func pretendTyping(_ on: Bool) { keyboardUp = on }

    /// The account's devices, for named states: in sync, this iPhone among them.
    func pretendDevices(_ list: [SyncDevice], own: String) {
        pretendOwnDevice = own
        devices = list
        phase = .on
    }

    /// A page the Mac sent, for named states: into Today with its card on
    /// the Now line, or in front with the corner saying from where.
    func pretendArrival(_ page: OpenOnPhone.Arrival, front: Bool) {
        try? arrive(page, front: front)
    }

    /// A joining screen, for named states: no pairing box, a fixed code.
    func pretend(_ phase: Phase, sheet: Bool = true) {
        self.phase = phase
        showsJoin = sheet && phase != .off && phase != .on
    }

    /// Joined through iCloud Keychain a moment ago, for named states: the
    /// world plays the account, and what a person sees is said.
    func pretendJoinedByICloud() {
        phase = .on
        line = .live
        writing = true
        app?.say("In sync with your Mac", glyph: .macbook)
    }
}

/// What the quiet line says.
enum SyncNote: Equatable, Sendable {
    case macAsleep(Int)
    case offline(Int)
    /// This iPhone was removed from the account: nothing syncs until it joins again.
    case removed

    var words: String {
        switch self {
        case let .macAsleep(n): "Mac asleep · \(n) \(n == 1 ? "change waits" : "changes wait") for it"
        case let .offline(n): "Offline · \(n) \(n == 1 ? "change waits" : "changes wait") to sync"
        case .removed: "Removed from Sync · Join Again"
        }
    }
}

/// Synced ids and the app's: a tab or space the app made with an id the
/// Mac wouldn't take (anything but an upper-case UUID) is synced under one
/// of its own. Real profiles keep this association beside the journal, so
/// selection, Back history and scroll still belong to the same tab on restart.
/// The association outlives Turn Off and Join Again (row 385): joining the
/// same account again, the iPhone's own spaces and tabs are the records they
/// were, not new ones beside them. The device ids this iPhone had in the
/// account before are kept with it: its tabs of today carry them.
nonisolated struct IDs: Sendable {
    private var toSync: [String: String] = [:]
    private var toLocal: [String: String] = [:]
    private var file: URL?
    private var account = ""
    private var device: String?
    private var dirty = false
    /// The ids this iPhone had in the account before it left and joined again.
    private(set) var former: Set<String> = []
    /// Back in an account it had left, under another device id: until the
    /// association is written again, the app's rows are the iPhone's own.
    private(set) var rejoined = false
    /// Which sweep of the account's duplicate spaces this iPhone has run
    /// (SyncBridge.duplicateSpaces): each runs once an account.
    private(set) var swept = 0

    private struct Saved: Codable {
        var account: String
        var mapping: [String: String]
        var device: String?
        var former: [String]?
        var swept: Int?
    }

    init() {}

    init(folder: URL, account: String, device: String? = nil) throws {
        let file = folder.appendingPathComponent("browser-ids.json")
        self.file = file
        self.account = account
        self.device = device
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
        // Another account's: nothing of it is this one's.
        guard saved.account == account else { return }
        guard saved.mapping.keys.allSatisfy({ !$0.isEmpty }),
              saved.mapping.values.allSatisfy({ UUID(uuidString: $0)?.uuidString == $0 }),
              Set(saved.mapping.values).count == saved.mapping.count else { throw CocoaError(.fileReadCorruptFile) }
        toSync = saved.mapping
        toLocal = Dictionary(uniqueKeysWithValues: toSync.map { ($0.value, $0.key) })
        former = Set(saved.former ?? [])
        swept = saved.swept ?? 0
        if let before = saved.device, let device, before != device {
            former.insert(before)
            rejoined = true
        }
        if let device {
            former.remove(device)
            if saved.device != device { dirty = true }
        }
    }

    func known(_ local: String) -> String? {
        toSync[local] ?? (UUID(uuidString: local)?.uuidString == local ? local : nil)
    }

    mutating func persist() throws {
        guard dirty, let file else { return }
        let data = try JSONEncoder().encode(Saved(account: account, mapping: toSync, device: device,
                                                  former: former.isEmpty ? nil : former.sorted(),
                                                  swept: swept == 0 ? nil : swept))
        try data.write(to: file, options: .atomic)
        dirty = false
        rejoined = false
    }

    mutating func sync(_ local: String) -> String {
        if let known = toSync[local] { return known }
        if UUID(uuidString: local)?.uuidString == local { return local }
        let made = UUID().uuidString
        toSync[local] = made
        toLocal[made] = local
        dirty = true
        return made
    }

    func local(_ synced: String) -> String { toLocal[synced] ?? synced }

    /// The sweep `version` ran for this account; written with the association.
    mutating func markSwept(_ version: Int) {
        guard version > swept else { return }
        swept = version
        dirty = true
    }

    /// The app's tab `local` is sync's `copy` from now on, its page kept;
    /// `old`, the record it stood for, gets a local id of its own, so the
    /// two never meet in the app's rows.
    mutating func alias(_ local: String, to copy: String, leaving old: String) {
        if self.local(old) == local {
            let apart = UUID().uuidString
            toSync[apart] = old
            toLocal[old] = apart
        }
        toSync[local] = copy
        toLocal[copy] = local
        dirty = true
    }
}

/// Chats as sync holds them: heads, their steps, the words sent from here.
nonisolated struct ChatMirror: Sendable {
    var heads: [String: SyncChat] = [:]
    var steps: [String: [String: SyncChatItem]] = [:]
    var sent: [String: SyncSend] = [:]

    init() {}

    init(chats: [SyncChat], items: [String: [SyncChatItem]], sends: [SyncSend]) {
        for chat in chats { heads[chat.id] = chat }
        for (chat, list) in items { steps[chat] = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
        for send in sends { sent[send.id] = send }
    }

    func items(of chat: String) -> [SyncChatItem] {
        (steps[chat] ?? [:]).values.sorted { ($0.n, $0.id) < ($1.n, $1.id) }
    }

    func sends(of chat: String) -> [SyncSend] {
        sent.values.filter { $0.chat == chat }.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }

    /// The chats a batch touches.
    func touched(by changes: [SyncChange]) -> Set<String> {
        var out = Set<String>()
        for change in changes {
            switch change {
            case let .chat(chat): out.insert(chat.id)
            case let .message(item): out.insert(item.chat)
            case let .send(send): if let chat = send.chat { out.insert(chat) }
            default: break
            }
        }
        return out
    }

    @discardableResult
    mutating func apply(_ changes: [SyncChange]) -> Set<String> {
        var out = Set<String>()
        for change in changes {
            switch change {
            case let .chat(chat):
                heads[chat.id] = chat
                out.insert(chat.id)
            case let .message(item):
                steps[item.chat, default: [:]][item.id] = item
                out.insert(item.chat)
            case let .messageGone(id):
                let chat = String(id.split(separator: "/").first ?? "")
                steps[chat]?[id] = nil
                out.insert(chat)
            case let .send(send):
                sent[send.id] = send
                if let chat = send.chat { out.insert(chat) }
            default:
                break
            }
        }
        // A chat that left sync stays, as it last was (decision 8).
        return out.filter { heads[$0] != nil }
    }
}
