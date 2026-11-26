import Foundation
import CryptoKit
#if canImport(SyncKit)
import SyncKit
#endif

// The iPhone in sync (Phone/Reference/digest/sync-ios.md): the same account,
// server and records as the Macs, through SyncKit's journal and client. What
// came from elsewhere reaches the app as typed changes; what the app does
// (a tab opened, closed, kept, moved; words for a chat on a Mac) is written
// to the journal at once and goes up the moment the line is up, so nothing
// waits on the network and nothing is lost offline: the journal's changed
// records are the outbox, kept in `sync.sqlite` across launches.
//
// Built on Foundation, CryptoKit, Security and SyncKit only: the app tells
// it when it comes to the front and goes to the back (scenePhase), and
// wraps `pause` in a background task of its own.

/// What changed, as the app's model takes it.
public nonisolated enum SyncChange: Equatable, Sendable {
    case space(SyncSpace), spaceGone(String)
    case tab(SyncTab), tabGone(String)
    case folder(SyncFolder), folderGone(String)
    case icon(SyncIcon), iconGone(String)
    case pair(SyncPair), pairGone(String)
    case bookmark(SyncBookmark), bookmarkGone(String)
    case setting(SyncSetting), settingGone(String)
    /// History only ever adds: a place that left the two weeks stays.
    case visit(SyncVisit)
    /// A chat that left sync comes as itself with `synced` false: shown
    /// from what it last said, never removed by sync.
    case chat(SyncChat), chatGone(String)
    case message(SyncChatItem), messageGone(String)
    /// Words from here, as the Mac took them (or not).
    case send(SyncSend)
    /// A project of chats, from a Mac (ChatProjects).
    case project(SyncProject), projectGone(String)
}

public nonisolated struct SyncBatch: Sendable {
    public enum Origin: Sendable {
        /// From another device.
        case remote
        /// Written here, by the app: the model already shows it.
        case local
    }
    public var origin: Origin
    public var changes: [SyncChange]
}

/// A Mac of the account, and whether words for it are said now.
public nonisolated struct SyncMac: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var model: String
    public var lastSeen: Date?
    /// Its line was up in the last couple of minutes.
    public var online: Bool
    /// The tab in front on it, from its last presence.
    public var front: SyncPresence?
    /// What it is doing, for the words (MacWords): up, asleep, Yab closed, silent.
    public var state: MacState = .silent(since: nil)
    /// When its tab in front last changed as this iPhone heard it: the Mac
    /// used last is the one new work goes to (MacPick).
    public var usedAt: Date?
}

/// A device of the account, for Settings › Sync on the iPhone: a Mac, an
/// iPhone, this iPhone.
public nonisolated struct SyncDevice: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var model: String
    /// When the server last heard from it, or it last said its presence.
    public var lastSeen: Date?
    public var isPhone: Bool { model.hasPrefix("iPhone") || model.hasPrefix("iPad") }
}

/// Everything sync holds, read at once: what the app starts from.
public nonisolated struct SyncSnapshot: Sendable {
    public var spaces: [SyncSpace]
    public var rows: [String: SyncRow]
    /// Newest first, those that left sync included.
    public var chats: [SyncChat]
    public var sends: [SyncSend]
    public var bookmarks: [SyncBookmark]
    public var settings: [String: Value]
    public var macs: [SyncMac]
    public var cursor: Int64
    /// Changes made here the server hasn't taken yet.
    public var pending: Int
    /// Account-owned custom folder images, read before the line starts.
    public var icons: [SyncIcon] = []
}

public nonisolated final class PhoneSync: @unchecked Sendable {
    public struct Options: Sendable {
        public var base: URL
        /// Where the journal lives: Application Support/Sync.
        public var folder: URL
        public var device: SyncClient.Device
        /// The web for real; a server in memory for tests.
        public var transport: (any Transport)?
        /// Where the app hears changes, state and Macs.
        public var callbacks: DispatchQueue
        /// Chat choices may go up only to their known Mac owner after it
        /// advertises the adopter. False keeps them local even on a new Mac.
        public var chatFlagsGoUp: Bool
        /// How long a Mac counts as up after it was last heard from
        /// (`PhoneSync.onlineFor`), and how often the devices list is read
        /// again while live; shorter in end-to-end checks.
        public var onlineFor: TimeInterval
        public var refreshEvery: TimeInterval

        public init(base: URL = PhoneSync.defaultBase, folder: URL = PhoneSync.defaultFolder, device: SyncClient.Device,
                    transport: (any Transport)? = nil, callbacks: DispatchQueue = .main, chatFlagsGoUp: Bool = true,
                    onlineFor: TimeInterval = PhoneSync.onlineFor, refreshEvery: TimeInterval = 60) {
            self.base = base; self.folder = folder; self.device = device
            self.transport = transport; self.callbacks = callbacks; self.chatFlagsGoUp = chatFlagsGoUp
            self.onlineFor = onlineFor; self.refreshEvery = refreshEvery
        }
    }

    /// Where a tab goes in its list.
    public enum Place: Sendable, Equatable {
        case top, bottom
        case before(String), after(String)
    }

    public enum Failure: Error, Equatable {
        case noSuchTab(String), noSuchSpace(String), noSuchChat(String), notAPlace(String)
    }

    /// A project asked of a Mac whose Yab doesn’t take projects from here.
    public static let projectsUnsupported = "Your Mac can’t take chats in projects yet. Update Yab there."

    /// `YAB_SYNC_URL`, then Info.plist's `YabSync`, then the deployed Worker:
    /// the Mac's order (SyncCenter.base).
    public static var defaultBase: URL {
        if let env = ProcessInfo.processInfo.environment["YAB_SYNC_URL"], let url = URL(string: env) { return url }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "YabSync") as? String, let url = URL(string: plist) { return url }
        return URL(string: "https://yab-sync.21st.workers.dev")!
    }

    public static var defaultFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Sync", isDirectory: true)
    }

    /// The hardware model as the server lists it: "iPhone18,1", or in the
    /// simulator the model it plays.
    public static var model: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var chars = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &chars, &size, nil, 0)
        return String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// How long a device counts as online after it was last heard from.
    /// Docs say two minutes; the server notes `lastSeen` at most once a
    /// minute and a Mac speaks every 55 s, so a little more, or a Mac that
    /// is up would blink off between two of its beats.
    public static let onlineFor: TimeInterval = 150

    public let seal: Seal
    public let journal: Journal
    /// The line. Stopped, it stays stopped until `start` (SyncKit numbers
    /// its lines, so an old socket's goodbye dials nothing).
    public let client: SyncClient
    public let options: Options
    public let keys: SyncKeychain?
    private let taskInbox: TaskRecordInbox

    private let queue = DispatchQueue(label: "phone.sync")
    private let lock = NSLock()
    private var _onChanges: (@Sendable (SyncBatch) -> Void)?
    private var _onMoved: (@Sendable (Seal) -> Void)?
    private var _onTasks: (@Sendable ([TaskRecords.Observation]) -> Void)?
    private var _onTaskRecordChanges: (@Sendable () -> Void)?
    private var _onAssistantApprovals: (@Sendable () -> Void)?
    private var _onCapabilities: (@Sendable (Set<String>) -> Void)?
    private var _taskDelivered: [String: UInt64] = [:]
    private var _taskCallbacksPending: Set<String> = []
#if DEBUG
    private var _taskRecordSnapshotRead: (@Sendable () -> Void)?
    private var _taskRecordReadWork: (@Sendable (String) -> Void)?
    /// Counts actual request decoding for a bounded heavy-journal native check.
    /// This hook has no Release path and cannot alter a record or its authority.
    var taskRecordReadWork: (@Sendable (String) -> Void)? {
        get { locked { _taskRecordReadWork } }
        set { locked { _taskRecordReadWork = newValue } }
    }
    /// Native tests can order two real transport revisions across the snapshot
    /// boundary. No Release hook or alternate execution path exists.
    var taskRecordSnapshotRead: (@Sendable () -> Void)? {
        get { locked { _taskRecordSnapshotRead } }
        set { locked { _taskRecordSnapshotRead = newValue } }
    }
#endif
    private var _onState: (@Sendable (SyncClient.State) -> Void)?
    private var _onMacs: (@Sendable ([SyncMac]) -> Void)?
    private var _onDevices: (@Sendable ([SyncDevice]) -> Void)?
    private var _devices: [SyncDevice] = []
    private var _front: (@Sendable () -> SyncPresence?)?
    private var _state: SyncClient.State = .off
    private var listed: [SyncClient.Listed] = []
    private var approvalDevicesLoaded = false
    private var approvalJournalCaughtUp = false
    public var assistantApprovalsReady: Bool { locked { approvalDevicesLoaded && approvalJournalCaughtUp } }
    private var presences: [String: SyncPresence] = [:]
    /// When each Mac's tab in front last changed, as heard (SyncMac.usedAt).
    private var usedAt: [String: Date] = [:]
    private var _macs: [SyncMac] = []
    private var flags: [String: ChatFlags] = [:]
    /// Sends whose parts are being written, their record not yet: the sweep leaves them.
    private var writingSends: Set<String> = []
    private var timer: DispatchSourceTimer?
    /// Moves on with every start and pause: a pause still draining when Yab
    /// came back to the front sees it, and leaves the line up.
    private var turn = 0
    /// Where this iPhone's silent pushes go (R2), and the server token it
    /// was last told with: told again when either changes.
    private var push: Push?
    private var pushTold: String?
    private let transport: any Transport

    /// An APNs device token, its environment and the app's bundle id.
    public struct Push: Equatable, Sendable {
        public var token: String
        public var environment: String
        public var topic: String
        /// Questions from a Mac's agents come as alerts: this iPhone may
        /// show notifications (ApprovalNotice).
        public var alerts: Bool
        public init(token: Data, environment: String, topic: String, alerts: Bool = false) {
            self.token = token.map { String(format: "%02x", $0) }.joined()
            self.environment = environment
            self.topic = topic
            self.alerts = alerts
        }
    }

    /// Every batch of changes, on `options.callbacks`.
    /// The account this one was merged into (AccountMove), on any queue.
    public var onMoved: (@Sendable (Seal) -> Void)? {
        get { locked { _onMoved } } set { locked { _onMoved = newValue } }
    }
    public var onChanges: (@Sendable (SyncBatch) -> Void)? {
        get { locked { _onChanges } } set { locked { _onChanges = newValue } }
    }
    /// Only accepted observations from the captured known Mac owner.
    public var onTaskRecords: (@Sendable ([TaskRecords.Observation]) -> Void)? {
        get { locked { _onTasks } }
        set {
            locked { _onTasks = newValue }
            if newValue != nil { observeTaskRecords(journal.all(TaskRecords.observationCollection)) }
        }
    }

    /// A current-journal invalidation, including request/observation tombstones.
    /// No synthetic observation or ordinary browser change is supplied.
    public var onTaskRecordChanges: (@Sendable () -> Void)? {
        get { locked { _onTaskRecordChanges } }
        set { locked { _onTaskRecordChanges = newValue } }
    }

    /// A sealed approval was opened, settled or removed by its Mac.
    public var onAssistantApprovals: (@Sendable () -> Void)? {
        get { locked { _onAssistantApprovals } }
        set { locked { _onAssistantApprovals = newValue } }
    }

    private func notifyAssistantApprovals() {
        options.callbacks.async { [weak self] in self?.onAssistantApprovals?() }
    }

    private func notifyTaskRecordChanges() {
        options.callbacks.async { [weak self] in self?.onTaskRecordChanges?() }
    }

    /// Only the owners whose encrypted command capability changed. These
    /// records are not chat data and never become artificial SyncChanges.
    public var onCapabilities: (@Sendable (Set<String>) -> Void)? {
        get { locked { _onCapabilities } }
        set { locked { _onCapabilities = newValue } }
    }
    public var onState: (@Sendable (SyncClient.State) -> Void)? {
        get { locked { _onState } } set { locked { _onState = newValue } }
    }
    public var onMacs: (@Sendable ([SyncMac]) -> Void)? {
        get { locked { _onMacs } } set { locked { _onMacs = newValue } }
    }
    /// Every device of the account, this iPhone too, as the list says.
    public var onDevices: (@Sendable ([SyncDevice]) -> Void)? {
        get { locked { _onDevices } } set { locked { _onDevices = newValue } }
    }
    public var devices: [SyncDevice] { locked { _devices } }
    /// The account's whole device list as last read, removed devices too;
    /// nil until it has been read once (SyncBridge.goneDevices).
    public var roster: [SyncClient.Listed]? { locked { approvalDevicesLoaded ? listed : nil } }
    /// The tab this iPhone has in front, told to the others with its
    /// presence (fields `url`, `title`, `tab`); nil says only that it is up.
    public var front: (@Sendable () -> SyncPresence?)? {
        get { locked { _front } } set { locked { _front = newValue } }
    }

    public var state: SyncClient.State { locked { _state } }
    public var macs: [SyncMac] { locked { _macs } }

    /// Opens the journal in `options.folder` (made, and left out of
    /// backups: a restored iPhone has no key, so its journal would be a
    /// stranger's) and readies the line. Nothing is sent until `start`.
    /// A journal of another account is put away first.
    public init(seal: Seal, options: Options, keys: SyncKeychain? = nil) throws {
        SyncCollection.register()
        let manager = FileManager.default
        try manager.createDirectory(at: options.folder, withIntermediateDirectories: true)
        var folder = options.folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        let marker = options.folder.appendingPathComponent("account")
        if let had = try? String(contentsOf: marker, encoding: .utf8), had != seal.account {
            PhoneSync.leave(folder: options.folder)
            try manager.createDirectory(at: options.folder, withIntermediateDirectories: true)
        }
        try seal.account.write(to: marker, atomically: true, encoding: .utf8)

        self.seal = seal
        self.options = options
        self.keys = keys
        journal = try Journal(path: options.folder.appendingPathComponent("sync.sqlite").path, device: options.device.id)
        transport = options.transport ?? WebTransport()
        client = SyncClient(base: options.base, journal: journal, seal: seal, device: options.device, token: keys?.token,
                            transport: transport)
        taskInbox = try TaskRecordInbox(file: options.folder.appendingPathComponent("task-records.json"),
                                       account: seal.account, phone: options.device.id)
        flags = PhoneSync.readFlags(options.folder)
        wire()
        // A widget placed since the last rows came finds them at once.
        shelveNow()
    }

    /// Sync off on this iPhone: the journal and what it kept go. The key is
    /// the keychain's business (`SyncKeychain.forget`). The app's id
    /// association (browser-ids.json) stays: joining the same account again
    /// finds the iPhone's own spaces and tabs as they were (row 385).
    public static func leave(folder: URL = PhoneSync.defaultFolder) {
        // Off sync, no Mac's rows: the Now widget goes back to Search.
        NowShelf.shared.write([])
        for name in ["sync.sqlite", "sync.sqlite-wal", "sync.sqlite-shm", "chat-flags.json", "task-records.json", "account"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private func wire() {
        // Merged into the journal and handed on in one step on the client's
        // queue, so a write of the app's can't fall between the two.
        client.deliver = { [weak self] items in
            guard let self else { return }
            // Two accounts became one and this isn't the one that stayed.
            if let there = AccountMove.destination(items.map(\.record), from: self.seal) { self.onMoved?(there) }
            guard let changed = try? self.journal.receive(items) else { return }
            self.emit(.remote, changed.flatMap(self.changes(for:)))
            // A newer owner stamp can leave the visible body unchanged.
            // Reconcile the merged records even when the UI has no changes.
            let received = Set(items.map { $0.record.key })
            let taskChanges = received.contains { $0.collection == OpenOnMac.capability || $0.collection == TaskRecords.requestCollection }
                ? self.journal.all(TaskRecords.observationCollection)
                : received.filter { $0.collection == TaskRecords.observationCollection }.sorted().compactMap { self.journal.record($0) }
            self.observeTaskRecords(taskChanges)
            if received.contains(where: { $0.collection == AssistantApprovalRecords.requestCollection
                || $0.collection == AssistantApprovalRecords.answerCollection
                || $0.collection == AssistantApprovalRecords.detailCollection
                || $0.collection == AssistantApprovalRecords.previewCollection
                || $0.collection == AssistantApprovalRecords.resultCollection }) {
                self.notifyAssistantApprovals()
            }
            if received.contains(where: { $0.collection == OpenOnMac.capability
                || $0.collection == TaskRecords.requestCollection
                || $0.collection == TaskRecords.observationCollection }) {
                self.notifyTaskRecordChanges()
            }
            if received.contains(where: { $0.collection == SyncCollection.send || $0.collection == SyncCollection.sendPart }) {
                self.sweepSendParts()
            }
            // The Macs' Now rows, for the Now widget: kept in the App Group
            // here, so a push with no scene draws the widget too.
            if received.contains(where: { $0.collection == SyncCollection.now }) { self.shelveNow() }
            let owners = Set(received.filter { $0.collection == OpenOnMac.capability }.map(\.id))
            if !owners.isEmpty, let callback = self.onCapabilities {
                self.options.callbacks.async { callback(owners) }
            }
        }
        client.stateChanged = { [weak self] state in self?.changed(state) }
        client.heardPresence = { [weak self] device, record in self?.heard(device, record) }
        client.presence = { [weak self] in self?.presence() }
    }

    // MARK: Running

    /// In front: the line opens, catches up from the cursor, and sends what
    /// waited. Also after `pause` or `stop`, and harmless while up.
    public func start() {
        // Under the lock, so a pause deciding to close the line comes
        // either wholly before this (and the line opens again) or after.
        locked {
            turn += 1
            if _state != .live { approvalJournalCaughtUp = false }
            client.start()
        }
        sweepSendParts()
    }

    /// To the back: what is still going up gets up to `within` seconds,
    /// then the line closes. `done` comes when it has, on any queue; the app
    /// ends its background task there. Changes left wait in the journal.
    /// A `start` meanwhile (back in front) calls the pause off.
    public func pause(within: TimeInterval = 5, _ done: (@Sendable () -> Void)? = nil) {
        let deadline = Date().addingTimeInterval(within)
        let mine: Int = locked {
            turn += 1
            return turn
        }
        queue.async { [self] in drain(until: deadline, turn: mine, done) }
    }

    private func drain(until deadline: Date, turn mine: Int, _ done: (@Sendable () -> Void)?) {
        let (current, live) = locked { (turn == mine, _state == .live) }
        guard current else { done?(); return }
        if !live || pending == 0 || Date() >= deadline {
            let stopped: Bool = locked {
                guard turn == mine else { return false }
                _state = .off
                client.stop()
                return true
            }
            if stopped { stopTimer() }
            done?()
            return
        }
        queue.asyncAfter(deadline: .now() + 0.1) { [self] in drain(until: deadline, turn: mine, done) }
    }

    /// The line closes and stays closed until `start`. Changes made
    /// meanwhile wait in the journal.
    public func stop() {
        stopTimer()
        locked {
            turn += 1
            _state = .off
            client.stop()
        }
    }

    private func stopTimer() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    /// Changes made here the server hasn't taken yet: counted, nothing read.
    public var pending: Int { journal.pendingCount }

    /// The same, counted on the engine's queue, the answer on `callbacks`:
    /// the app's main thread never waits on the journal for it.
    public func countPending(_ done: @escaping @Sendable (Int) -> Void) {
        queue.async { [self] in
            let count = pending
            options.callbacks.async { done(count) }
        }
    }

    private func changed(_ state: SyncClient.State) {
        locked { _state = state }
        if state == .live {
            locked { approvalJournalCaughtUp = true }
            // The token the server gave, for the next launch.
            if let token = client.token, let keys, keys.token != token { keys.token = token }
            sayWhatITake()
            refreshMacs()
            queue.async { [self] in startTimer() }
            tellPush()
            notifyAssistantApprovals()
        }
        if case .refused = state { queue.async { [self] in timer?.cancel(); timer = nil } }
        if let callback = onState { options.callbacks.async { callback(state) } }
    }

    // MARK: Silent pushes (R2)

    /// Where to wake this iPhone while its line is closed: the server sends
    /// a silent push there when another device changes something. Told
    /// once the line is up (it needs this device's token), and again
    /// whenever APNs gives a new one.
    public func wantPushes(_ push: Push) {
        let changed: Bool = locked {
            defer { self.push = push }
            return self.push != push
        }
        if changed { tellPush() }
    }

    private func tellPush() {
        let (push, told, token): (Push?, String?, String?) = locked { (self.push, pushTold, client.token) }
        guard let push, let token, told != token + push.token + "\(push.alerts)" else { return }
        var request = URLRequest(url: options.base.appendingPathComponent("v1/accounts/\(seal.account)/devices/\(options.device.id)/push"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": push.token, "env": push.environment, "topic": push.topic,
                                                                        "alerts": push.alerts])
        transport.request(request) { [weak self] status, _ in
            guard let self, status == 204 else { return }
            self.locked { self.pushTold = token + push.token + "\(push.alerts)" }
        }
    }

    /// Woken by a silent push in the back: the line opens, catches up, sends
    /// what waited, and closes again (`pause`), all within `within` seconds;
    /// `done` says whether anything came. In front already, it only opens.
    public func catchUp(within: TimeInterval = 20, closeAfter: Bool, _ done: @escaping @Sendable (Bool) -> Void) {
        let before = journal.cursor
        let budget = within.isFinite ? min(max(0, within), 30) : 20
        let deadline = Date().addingTimeInterval(budget)
        start()
        let expected = locked { turn }
        @Sendable func check() {
            let (state, current) = locked { (_state, turn) }
            // A foreground start or a stop supersedes this background wake.
            // Never let its delayed callback close the newer line.
            guard current == expected else { done(false); return }
            if case .refused = state { done(false); return }
            if (state == .live && assistantApprovalsReady) || Date() >= deadline {
                let came = journal.cursor != before
                if closeAfter { pause(within: max(1, deadline.timeIntervalSinceNow)) { done(came) } } else { done(came) }
                return
            }
            queue.asyncAfter(deadline: .now() + 0.05) { check() }
        }
        queue.async { check() }
    }

    // MARK: Macs

    /// The devices list, read again: who is in the account and when each
    /// was last up.
    public func refreshMacs() {
        client.devices { [weak self] list in
            guard let self, let list else { return }
            self.locked { self.listed = list; self.approvalDevicesLoaded = true }
            self.recomputeMacs()
        }
    }

    private func startTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + options.refreshEvery, repeating: options.refreshEvery)
        timer.setEventHandler { [weak self] in
            self?.refreshMacs()
            self?.recomputeMacs()
        }
        timer.resume()
        self.timer = timer
    }

    private func heard(_ device: String, _ record: Record) {
        let known: Bool = locked {
            let presence = SyncPresence(device: device, record: record)
            if presence.tab != nil, presence.tab != presences[device]?.tab || usedAt[device] == nil {
                usedAt[device] = Date(timeIntervalSince1970: presence.at)
            }
            presences[device] = presence
            return listed.contains { $0.id == device }
        }
        // A device that joined since the list was read: read it again.
        if known { recomputeMacs() } else { refreshMacs() }
    }

    private func recomputeMacs() {
        let now = Date()
        let me = options.device.id
        let macs: [SyncMac] = locked {
            listed.filter { !$0.revoked && $0.id != me && !$0.model.hasPrefix("iPhone") && !$0.model.hasPrefix("iPad") }.map { device in
                let front = presences[device.id]
                let heard = front.map { Date(timeIntervalSince1970: $0.at) }
                let last = [device.lastSeen, heard].compactMap { $0 }.max()
                // A Mac that said it is going to sleep is asleep however
                // fresh its last word.
                let recent = last.map { now.timeIntervalSince($0) < options.onlineFor } ?? false
                return SyncMac(id: device.id, name: device.name, model: device.model, lastSeen: last,
                               online: recent && front?.asleep != true, front: front,
                               state: MacState.of(presence: front, lastSeen: last, now: now, onlineFor: options.onlineFor),
                               usedAt: usedAt[device.id])
            }.sorted { ($0.online ? 0 : 1, $0.name, $0.id) < ($1.online ? 0 : 1, $1.name, $1.id) }
        }
        // Every device, this iPhone and other iPhones too, for Settings.
        let devices: [SyncDevice] = locked {
            listed.filter { !$0.revoked }.map { device in
                let heard = presences[device.id].map { Date(timeIntervalSince1970: $0.at) }
                return SyncDevice(id: device.id, name: device.name, model: device.model,
                                  lastSeen: [device.lastSeen, heard].compactMap { $0 }.max())
            }.sorted { ($0.id == me ? 0 : 1, $0.name, $0.id) < ($1.id == me ? 0 : 1, $1.name, $1.id) }
        }
        let devicesChanged: Bool = locked {
            defer { _devices = devices }
            return _devices != devices
        }
        if devicesChanged, let callback = onDevices { options.callbacks.async { callback(devices) } }
        if devicesChanged { notifyAssistantApprovals() }
        let changed: Bool = locked {
            defer { _macs = macs }
            return _macs != macs
        }
        if changed, let callback = onMacs { options.callbacks.async { callback(macs) } }
        // Records can arrive before the refreshed known-device list.
        if changed { observeTaskRecords(journal.all(TaskRecords.observationCollection)) }
    }

    private func presence() -> Record? {
        let own = front?()
        return SyncPresence(device: options.device.id, name: options.device.name, at: Date().timeIntervalSince1970,
                            url: own?.url, title: own?.title, tab: own?.tab, scroll: own?.scroll,
                            space: own?.space, changed: own?.changed).record
    }

    /// Said now, not at the next beat: the page in front changed, or Yab is
    /// going to the back (a Mac's From iPhone hears it at once).
    public func sayPresence() { client.sayPresence() }

    // MARK: Pages from a Mac (Send to iPhone)

    /// What this iPhone takes from a Mac, said in its own commandcap record:
    /// pages (OpenOnPhone). Written once; unchanged, nothing goes up.
    private func sayWhatITake() {
        let key = Record.Key(collection: OpenOnMac.capability, id: options.device.id)
        let want = OpenOnPhone.capability(device: options.device.id)
        if let had = journal.record(key), OpenOnPhone.supports(had, device: options.device.id),
           want.allSatisfy({ had[$0.key] == $0.value }) { return }
        _ = try? write(OpenOnMac.capability, options.device.id, want)
    }

    /// Pages a Mac sent this iPhone and it hasn't taken yet, oldest first.
    public func arrivals() -> [OpenOnPhone.Arrival] {
        OpenOnPhone.waiting(journal.all(SyncCollection.send), device: options.device.id).compactMap(OpenOnPhone.arrival)
    }

    /// Takes one, once (OpenOnPhone.take): `open` puts it in the app, then
    /// the record says taken and goes up. False for one already taken here,
    /// or one too late or not for this iPhone (said so on the record).
    @discardableResult
    public func take(_ arrival: OpenOnPhone.Arrival, open: (OpenOnPhone.Arrival) throws -> Void) -> Bool {
        guard let record = journal.record(.init(collection: SyncCollection.send, id: arrival.id)) else { return false }
        var opened = false
        let consumed = (try? OpenOnPhone.take(record, in: journal, device: options.device.id) { page in
            try open(page)
            opened = true
        }) ?? false
        if consumed { client.kick() }
        return opened
    }

    // MARK: Leaving

    /// Turn Off on this iPhone: the line closes and the account forgets this
    /// device (it is listed no more); `done` says whether the server took
    /// that. The key and the journal are the caller's to forget after.
    public func leave(_ done: @escaping @Sendable (Bool) -> Void) {
        stop()
        client.remove(device: options.device.id) { ok in done(ok) }
    }

    // MARK: Reading

    public func spaces() -> [SyncSpace] {
        RecordShapes.spaces(from: journal.living(SyncCollection.space))
    }

    /// A space's row as this iPhone shows it: its own tabs of today, every
    /// device's pins and kept; the Macs' tabs of today in `elsewhere`.
    public func row(_ space: String) -> SyncRow {
        SyncRow(space: space, tabs: journal.living(SyncCollection.tab), folders: journal.living(SyncCollection.folder),
                pairs: journal.living(SyncCollection.pair), device: options.device.id, mac: false)
    }

    public func rows() -> [String: SyncRow] {
        let tabs = journal.living(SyncCollection.tab), folders = journal.living(SyncCollection.folder), pairs = journal.living(SyncCollection.pair)
        var out: [String: SyncRow] = [:]
        for space in Set(spaces().map(\.id)).union(tabs.compactMap { $0["parent"]?.string }) {
            out[space] = SyncRow(space: space, tabs: tabs, folders: folders, pairs: pairs, device: options.device.id, mac: false)
        }
        return out
    }

    /// This iPhone's id, the `device` its tabs of today carry.
    public var device: String { options.device.id }

    /// Once, on the first launch where Today is each device's own: the tab
    /// that was in front here, if it was a shared tab of today's (now the
    /// Macs'), gets a copy of this iPhone's own at the top of its Today, so
    /// the page in front stays. The Mac keeps its tab. Returns the copy's id.
    public func keepFrontAsOwn(_ id: String?) throws -> String? {
        let mark = options.folder.appendingPathComponent("today-own")
        guard !FileManager.default.fileExists(atPath: mark.path) else { return nil }
        defer { FileManager.default.createFile(atPath: mark.path, contents: Data()) }
        guard let id, let tab = tab(id), tab.list == .today, !tab.shown(to: device, mac: false) else { return nil }
        return try openTab(url: tab.url, title: tab.title, in: tab.space).id
    }

    public func tab(_ id: String) -> SyncTab? {
        journal.record(.init(collection: SyncCollection.tab, id: id)).flatMap(SyncTab.init)
    }

    /// The tab of this space at this address among what this iPhone shows,
    /// if one is open: one page, one row.
    public func tab(at url: String, in space: String) -> SyncTab? {
        row(space).all.first { $0.url == url }
    }

    /// Every chat, newest first, those that left sync included.
    public func chats() -> [SyncChat] {
        journal.all(SyncCollection.chat).compactMap(chat(from:)).sorted { ($0.updated, $0.id) > ($1.updated, $1.id) }
    }

    public func chat(_ id: String) -> SyncChat? {
        journal.record(.init(collection: SyncCollection.chat, id: id)).flatMap(chat(from:))
    }

    /// The account's projects of chats, the pinned in their order first.
    public func projects() -> [SyncProject] {
        SyncProject.all(journal.all(SyncCollection.project))
    }

    /// A chat's steps in order. Those that left sync with it stay readable.
    public func messages(in chat: String) -> [SyncChatItem] {
        journal.all(SyncCollection.chatItem).filter { $0.id.hasPrefix(chat + "/") }.compactMap(SyncChatItem.init)
            .filter { $0.chat == chat }.sorted { ($0.n, $0.id) < ($1.n, $1.id) }
    }

    /// Every chat's steps at once, by chat: one read of the journal for a
    /// launch, instead of one per chat.
    public func allMessages() -> [String: [SyncChatItem]] {
        var out: [String: [SyncChatItem]] = [:]
        for item in journal.all(SyncCollection.chatItem).compactMap(SyncChatItem.init) { out[item.chat, default: []].append(item) }
        for key in out.keys { out[key]!.sort { ($0.n, $0.id) < ($1.n, $1.id) } }
        return out
    }

    /// Words from here, oldest first; for one chat, or all.
    public func sends(in chat: String? = nil) -> [SyncSend] {
        journal.living(SyncCollection.send).compactMap(SyncSend.init).filter { chat == nil || $0.chat == chat }.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }

    public func bookmarks() -> [SyncBookmark] {
        RecordShapes.bookmarks(from: journal.all(SyncCollection.bookmark))
    }

    public func settings() -> [String: Value] {
        Dictionary(journal.living(SyncCollection.setting).compactMap(SyncSetting.init).map { ($0.id, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    /// Places been to, newest first.
    public func visits(since: Double? = nil) -> [SyncVisit] {
        journal.living(SyncCollection.visit).compactMap(SyncVisit.init).filter { $0.last >= (since ?? 0) }.sorted { $0.last > $1.last }
    }

    /// Places been to, newest first, each with the device whose visit it
    /// last was: the device stamped on `last` (a Mac's id, or this iPhone's).
    public func places(since: Double? = nil) -> [(visit: SyncVisit, device: String?)] {
        journal.living(SyncCollection.visit).compactMap { record in SyncVisit(record).map { ($0, record.stamps["last"]?.device) } }
            .filter { $0.visit.last >= (since ?? 0) }.sorted { $0.visit.last > $1.visit.last }
    }

    /// The device whose visit a place last was, as the journal has it now.
    public func visitDevice(_ id: String) -> String? {
        journal.record(.init(collection: SyncCollection.visit, id: id))?.stamps["last"]?.device
    }

    public func icons() -> [SyncIcon] {
        journal.living(SyncCollection.icon).compactMap(SyncIcon.init).sorted { $0.id < $1.id }
    }

    public func snapshot() -> SyncSnapshot {
        SyncSnapshot(spaces: spaces(), rows: rows(), chats: chats(), sends: sends(), bookmarks: bookmarks(), settings: settings(),
                     macs: macs, cursor: journal.cursor, pending: pending, icons: icons())
    }

    // MARK: Tabs

    /// A new tab in a space's row, seen now. Its id is an
    /// upper-case UUID, as the Mac's are (the Mac takes no other).
    @discardableResult
    public func openTab(id: String = UUID().uuidString, url: String, title: String, in space: String, list: SyncTab.List = .today,
                        at place: Place = .top, seen: Date = Date()) throws -> SyncTab {
        let row = row(space)
        var tab = SyncTab(id: id, space: space, url: url, title: title,
                          pin: list == .pinned ? SyncTab.monogram(url) : nil,
                          seen: SyncTab.round(seen: seen.timeIntervalSince1970), kept: list == .kept,
                          device: list == .today ? options.device.id : nil)
        tab.order = order(in: row, list: list, place: place, moving: nil)
        try write(SyncCollection.tab, tab.id, tab.fields)
        emit(.local, [.tab(tab)])
        return tab
    }

    /// Closed here, closed everywhere: a closed tab never comes back. A
    /// Mac's tab of today closed from here (`elsewhere`) closes on that Mac.
    public func closeTab(_ id: String) throws {
        try journal.remove(.init(collection: SyncCollection.tab, id: id))
        client.kick()
        emit(.local, [.tabGone(id)])
    }

    /// Clear on the line: this iPhone's tabs of today in a space. Pins, the
    /// kept and the Macs' tabs of today stay.
    public func clearToday(in space: String) throws {
        let gone = row(space).today.map(\.id)
        for id in gone { try journal.remove(.init(collection: SyncCollection.tab, id: id)) }
        client.kick()
        emit(.local, gone.map(SyncChange.tabGone))
    }

    /// Keep (swipe right) or Unkeep: the tab changes list. A tab leaving its
    /// list leaves its folder too, a folder being one list's.
    @discardableResult
    public func keep(_ id: String, _ kept: Bool, at place: Place? = nil) throws -> SyncTab {
        try move(id, to: nil, list: kept ? .kept : .today, at: place ?? (kept ? .bottom : .top))
    }

    /// Moved within its list, into another list (pinned too), or to another
    /// space (where it leaves its folder). Only `parent` and `order` change,
    /// and `pin`, `kept` and `folder` when the list does.
    @discardableResult
    public func move(_ id: String, to space: String? = nil, list: SyncTab.List? = nil, at place: Place) throws -> SyncTab {
        guard var tab = tab(id) else { throw Failure.noSuchTab(id) }
        let target = space ?? tab.space
        let list = list ?? tab.list
        var fields: SyncFields = [:]
        if target != tab.space || list != tab.list, tab.folder != nil {
            tab.folder = nil
            fields["folder"] = .null
        }
        if list != tab.list {
            // Pinned here, a tab wears its site's letter, as the Mac's Pin
            // gives it; unpinned, it has none.
            tab.pin = list == .pinned ? SyncTab.monogram(tab.url) : nil
            fields["pin"] = Value(tab.pin)
            tab.kept = list == .kept
            fields["kept"] = tab.kept ? .bool(true) : .null
            // Kept or pinned, a tab is every device's; put back among today's, this iPhone's.
            tab.device = list == .today ? options.device.id : nil
            fields["device"] = Value(tab.device)
        }
        let from = tab.space
        tab.space = target
        tab.order = order(in: row(target), list: list, place: place, moving: id)
        fields["parent"] = .string(target)
        fields["order"] = Value(tab.order)
        try write(SyncCollection.tab, id, fields)
        let pairs = target == from ? [] : try carryPairs(of: id, to: target)
        emit(.local, [.tab(tab)] + pairs)
        return tab
    }

    /// A Mac's split view is a pair under its tabs' space. Once both of its
    /// tabs are in the new space it goes there too, whichever spaces they
    /// came through: left under another, no row shows it and that space's
    /// delete takes it with it.
    private func carryPairs(of id: String, to target: String) throws -> [SyncChange] {
        var changes: [SyncChange] = []
        for record in journal.living(SyncCollection.pair) {
            guard var pair = SyncPair(record), pair.space != target, pair.first == id || pair.second == id,
                  tab(pair.first == id ? pair.second : pair.first)?.space == target else { continue }
            try write(SyncCollection.pair, record.id, ["parent": .string(target)])
            pair.space = target
            changes.append(.pair(pair))
        }
        return changes
    }

    /// A kept tab goes into a Mac folder at any depth, or out at the root.
    /// Folder records and all other tab fields keep their exact stamps.
    @discardableResult
    public func putInFolder(_ id: String, folder: String?) throws -> SyncTab {
        guard var tab = tab(id), tab.list == .kept else { throw Failure.noSuchTab(id) }
        if let folder {
            guard let destination = row(tab.space).folders[folder], destination.space == tab.space,
                  destination.search == nil, destination.today != true else { throw Failure.notAPlace(folder) }
        }
        guard tab.folder != folder else { return tab }
        try write(SyncCollection.tab, id, ["folder": Value(folder)])
        tab.folder = folder
        emit(.local, [.tab(tab)])
        return tab
    }

    /// Folder edits only touch the chosen fields; newer Mac metadata survives.
    @discardableResult
    public func makeFolder(id: String, name: String, in space: String, parent: String? = nil) throws -> SyncFolder {
        guard rows()[space] != nil, row(space).folders[id] == nil else { throw Failure.notAPlace(id) }
        if let parent { guard let folder = row(space).folders[parent], folder.search == nil, folder.today != true else { throw Failure.notAPlace(parent) } }
        let row = row(space)
        let last = (row.kept.compactMap(\.order) + row.folders.values.compactMap(\.order)).max()
        let folder = SyncFolder(id: id, space: space, order: Order.between(last, nil), name: name, open: true, folder: parent)
        try write(SyncCollection.folder, id, folder.fields)
        emit(.local, [.folder(folder)])
        return folder
    }

    @discardableResult
    public func renameFolder(_ id: String, in space: String, to name: String) throws -> SyncFolder {
        guard var folder = row(space).folders[id] else { throw Failure.notAPlace(id) }
        folder.name = name
        try write(SyncCollection.folder, id, ["name": .string(name)])
        emit(.local, [.folder(folder)])
        return folder
    }

    /// Deleting a folder promotes its immediate children, never closes pages.
    @discardableResult
    public func deleteFolder(_ id: String, in space: String) throws -> [SyncChange] {
        let row = row(space)
        guard let folder = row.folders[id] else { throw Failure.notAPlace(id) }
        var changes: [SyncChange] = []
        for var tab in row.kept where tab.folder == id {
            tab.folder = folder.folder
            try write(SyncCollection.tab, tab.id, ["folder": Value(folder.folder)])
            changes.append(.tab(tab))
        }
        for var child in row.folders.values where child.folder == id {
            child.folder = folder.folder
            try write(SyncCollection.folder, child.id, ["parent": .string(space), "order": Value(child.order), "folder": Value(folder.folder)])
            changes.append(.folder(child))
        }
        try journal.remove(.init(collection: SyncCollection.folder, id: id))
        changes.append(.folderGone(id))
        client.kick()
        emit(.local, changes)
        return changes
    }

    /// A list put in a new order at once (a drag let go): the fewest keys
    /// change, those of the tabs that moved, which it returns.
    @discardableResult
    public func arrange(_ space: String, list: SyncTab.List, ids: [String]) throws -> [SyncTab] {
        let row = row(space)
        let lists: [SyncTab.List: [SyncTab]] = [.pinned: row.pins, .kept: row.kept, .today: row.today]
        let known = Set((lists[list] ?? []).map(\.id))
        let wanted = ids.filter(known.contains) + (lists[list] ?? []).map(\.id).filter { !ids.contains($0) }
        var sequence: [String] = []
        for each in [SyncTab.List.pinned, .kept, .today] {
            sequence += each == list ? wanted : (lists[each] ?? []).map(\.id)
        }
        let previous = Dictionary(row.all.compactMap { tab in tab.order.map { (tab.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let orders = Order.assign(sequence, previous: previous)
        var moved: [SyncTab] = []
        for tab in row.all where orders[tab.id] != tab.order {
            var tab = tab
            tab.order = orders[tab.id]
            try write(SyncCollection.tab, tab.id, ["parent": .string(space), "order": Value(tab.order)])
            moved.append(tab)
        }
        emit(.local, moved.map(SyncChange.tab))
        return moved
    }

    /// The page went somewhere else in the tab: a new address and title.
    @discardableResult
    public func navigate(_ id: String, url: String, title: String) throws -> SyncTab {
        guard var tab = tab(id) else { throw Failure.noSuchTab(id) }
        tab.url = url
        tab.title = title
        try write(SyncCollection.tab, id, ["url": .string(url), "title": .string(title)])
        emit(.local, [.tab(tab)])
        return tab
    }

    /// Looked at now: `seen` only ever grows, to five minutes.
    public func saw(_ id: String, at date: Date = Date()) throws {
        guard var tab = tab(id) else { throw Failure.noSuchTab(id) }
        let seen = SyncTab.round(seen: date.timeIntervalSince1970)
        guard seen > (tab.seen ?? 0) else { return }
        tab.seen = seen
        try write(SyncCollection.tab, id, ["seen": .number(seen)])
        emit(.local, [.tab(tab)])
    }

    /// What you call the tab; nil goes back to its page's title.
    public func rename(_ id: String, _ name: String?) throws {
        guard var tab = tab(id) else { throw Failure.noSuchTab(id) }
        tab.name = name
        try write(SyncCollection.tab, id, ["name": Value(name)])
        emit(.local, [.tab(tab)])
    }

    /// A key for a tab at `place` in `list` of `row`: between its neighbors
    /// in that list, and where it can be, between the lists around it too,
    /// so a Mac numbering its whole row keeps the key as it is.
    func order(in row: SyncRow, list: SyncTab.List, place: Place, moving: String?) -> String {
        let sequence: [SyncTab.List] = [.pinned, .kept, .today]
        let members = row.all.filter { $0.id != moving && $0.list == list }
        let at = sequence.firstIndex(of: list) ?? 2
        let before = row.all.filter { $0.id != moving && (sequence.firstIndex(of: $0.list) ?? 2) < at }.last
        let after = row.all.filter { $0.id != moving && (sequence.firstIndex(of: $0.list) ?? 2) > at }.first
        var low: SyncTab?, high: SyncTab?
        switch place {
        case .top: high = members.first
        case .bottom: low = members.last
        case .before(let id):
            if let i = members.firstIndex(where: { $0.id == id }) {
                high = members[i]
                low = i > 0 ? members[i - 1] : nil
            } else { low = members.last }
        case .after(let id):
            if let i = members.firstIndex(where: { $0.id == id }) {
                low = members[i]
                high = i + 1 < members.count ? members[i + 1] : nil
            } else { low = members.last }
        }
        var lo = low?.order, hi = high?.order
        // At an end of the list, the neighbor list's edge bounds it too,
        // when the keys allow.
        if low == nil, let edge = before?.order, hi.map({ edge < $0 }) ?? true { lo = edge }
        if high == nil, let edge = after?.order, lo.map({ $0 < edge }) ?? true { hi = edge }
        return Order.between(lo, hi)
    }

    // MARK: Spaces

    /// A space made here, at the end.
    @discardableResult
    public func makeSpace(id: String = UUID().uuidString, name: String, icon: String, paint: SyncPaint? = nil) throws -> SyncSpace {
        let last = spaces().last?.order
        let space = SyncSpace(id: id, name: name, icon: icon, paint: paint, order: Order.between(last, nil))
        try write(SyncCollection.space, space.id, space.fields)
        emit(.local, [.space(space)])
        return space
    }

    public func renameSpace(_ id: String, name: String, icon: String? = nil, iconChoice: String? = nil, iconChoiceID: String? = nil) throws {
        guard var space = journal.record(.init(collection: SyncCollection.space, id: id)).flatMap(SyncSpace.init) else { throw Failure.noSuchSpace(id) }
        space.name = name
        var fields: SyncFields = ["name": .string(name)]
        if let icon { space.icon = icon; fields["icon"] = .string(icon) }
        if let iconChoice { space.iconChoice = iconChoice; fields["iconChoice"] = .string(iconChoice) }
        if let iconChoiceID { space.iconChoiceID = iconChoiceID; fields["iconChoiceID"] = .string(iconChoiceID) }
        try write(SyncCollection.space, id, fields)
        emit(.local, [.space(space)])
    }

    /// A space and everything in it gone on every device, as a Mac's Delete
    /// Space: its tabs, folders and pairs, then the space's own record.
    @discardableResult
    public func deleteSpace(_ id: String) throws -> [SyncChange] {
        guard journal.record(.init(collection: SyncCollection.space, id: id)).flatMap(SyncSpace.init) != nil else { throw Failure.noSuchSpace(id) }
        var changes: [SyncChange] = []
        for record in journal.living(SyncCollection.pair) where SyncPair(record)?.space == id {
            try journal.remove(record.key)
            changes.append(.pairGone(record.id))
        }
        for record in journal.living(SyncCollection.tab) where SyncTab(record)?.space == id {
            try journal.remove(record.key)
            changes.append(.tabGone(record.id))
        }
        for record in journal.living(SyncCollection.folder) where SyncFolder(record)?.space == id {
            try journal.remove(record.key)
            changes.append(.folderGone(record.id))
        }
        try journal.remove(.init(collection: SyncCollection.space, id: id))
        changes.append(.spaceGone(id))
        client.kick()
        emit(.local, changes)
        return changes
    }

    /// Only paint changes; sign-ins, origin and placement stay with the record.
    @discardableResult
    public func setSpaceLook(_ id: String, paint: SyncPaint) throws -> SyncSpace {
        guard var space = journal.record(.init(collection: SyncCollection.space, id: id)).flatMap(SyncSpace.init) else { throw Failure.noSuchSpace(id) }
        space.paint = paint
        try write(SyncCollection.space, id, ["paint": paint.raw])
        emit(.local, [.space(space)])
        return space
    }

    /// Only this metadata field changes, never paint or website data.
    @discardableResult
    public func setSpaceSignIns(_ id: String, own: Bool, signInWith: String? = nil) throws -> SyncSpace {
        guard var space = journal.record(.init(collection: SyncCollection.space, id: id)).flatMap(SyncSpace.init) else { throw Failure.noSuchSpace(id) }
        space.ownSignIns = own
        space.signInWith = signInWith
        try write(SyncCollection.space, id, ["ownSignIns": .bool(own), "signInWith": Value(signInWith)])
        emit(.local, [.space(space)])
        return space
    }

    // MARK: Chats

    public enum ChatSendFailure: LocalizedError, Equatable {
        case ownerUnavailable, accessRefused
        public var errorDescription: String? {
            switch self {
            case .ownerUnavailable: "This chat's Mac isn't available in your Sync account. Wait for Sync or start a new chat."
            case .accessRefused: "This iPhone no longer has access to this Sync account. Rejoin Sync before sending more."
            }
        }
    }


    /// Words for a chat, said on the Mac that runs it: into the turn going
    /// on there, or a turn of their own. Waiting until that Mac takes them.
    @discardableResult
    public func say(_ text: String, in chat: String, clientChat: String? = nil, question: String? = nil,
                    files: [SendUpload] = [], model: String? = nil, effort: String? = nil) throws -> SyncSend {
        guard let head = self.chat(chat) else { throw Failure.noSuchChat(chat) }
        if case .refused = state { throw ChatSendFailure.accessRefused }
        // Retained heads are readable after removal. Only a known owner in
        // this engine's account can receive new words; sleeping is allowed.
        guard macs.contains(where: { $0.id == head.device }) else { throw ChatSendFailure.ownerUnavailable }
        if !files.isEmpty, !canAttach(on: head.device) { throw SendUpload.Failure.unsupported }
        let pick = canPickModel(on: head.device)
        return try send(SyncSend.fields(device: head.device, chat: chat, text: text, choice: nil, kind: nil, project: nil, at: Date().timeIntervalSince1970,
                                        model: pick ? model : nil, effort: pick ? effort : nil),
                        clientChat: clientChat, question: question, files: files)
    }

    /// Stop a chat's run, or delete the chat, on the Mac that runs it, as
    /// its own menu does. Only for a Mac that says it takes them
    /// (`canControlChat`).
    @discardableResult
    public func control(_ action: SyncSend.Action, chat: String) throws -> SyncSend {
        guard canControlChat(chat), let head = self.chat(chat) else { throw Failure.noSuchChat(chat) }
        let sent = try send(SyncSend.fields(device: head.device, chat: chat, text: nil, choice: nil, kind: nil, project: nil,
                                            at: Date().timeIntervalSince1970, action: action))
        if action == .delete {
            let all: [String: ChatFlags] = locked {
                var mine = flags[chat] ?? ChatFlags()
                mine.deleted = true
                flags[chat] = mine
                return flags
            }
            PhoneSync.writeFlags(all, options.folder)
        }
        return sent
    }

    /// Delete for a chat whose Mac doesn't take it from here: gone from
    /// this iPhone, kept on the Mac.
    public func forget(chat: String) {
        let all: [String: ChatFlags] = locked {
            var mine = flags[chat] ?? ChatFlags()
            mine.deleted = true
            flags[chat] = mine
            return flags
        }
        PhoneSync.writeFlags(all, options.folder)
    }

    /// Deleted from here: by `forget` (a Mac's chat, or a chat of this
    /// iPhone's whose question never got an answer) or by Delete sent to
    /// its Mac. Its sends and head never bring it back.
    public func forgottenChats() -> Set<String> { locked { Set(flags.filter { $0.value.deleted == true }.keys) } }

    /// The waiting sends of one of this iPhone's chats, taken back (Delete).
    public func cancelSends(ofClientChat chat: String) -> [SyncSend] {
        let waiting = journal.living(SyncCollection.send).compactMap(SyncSend.init)
            .filter { $0.clientChat == chat && $0.clientDevice == options.device.id && $0.state == .waiting }
        return waiting.compactMap { try? cancel(send: $0.id) }
    }

    /// The chat's Mac takes Stop and Delete from here (ChatControl).
    public func canControlChat(_ id: String) -> Bool {
        guard let head = chat(id), id.hasPrefix("a:"), macs.contains(where: { $0.id == head.device }) else { return false }
        return ChatControl.supports(journal.record(.init(collection: OpenOnMac.capability, id: head.device)), device: head.device)
    }

    /// A new browser chat on a Mac, with the selected agent.
    /// The Mac names the chat it started in the send (`chat`).
    @discardableResult
    public func startChat(_ text: String, on mac: String, clientChat: String? = nil, question: String? = nil, agent: ChatAgent? = nil,
                          files: [SendUpload] = [], model: String? = nil, effort: String? = nil, project: String? = nil) throws -> SyncSend {
        if agent != nil {
            guard canStartAgent(on: mac) else { throw Failure.notAPlace(ChatAgent.unsupported) }
        }
        if let project {
            guard ChatProjects.valid(project), canStartInProject(on: mac) else { throw Failure.notAPlace(PhoneSync.projectsUnsupported) }
        }
        if !files.isEmpty, !canAttach(on: mac) { throw SendUpload.Failure.unsupported }
        let pick = canPickModel(on: mac)
        return try send(SyncSend.fields(device: mac, chat: nil, text: text, choice: nil, kind: .agent, project: project, at: Date().timeIntervalSince1970, agent: agent,
                                        model: pick ? model : nil, effort: pick ? effort : nil),
                 clientChat: clientChat, question: question, files: files)
    }

    /// The Mac takes a model and effort with words (ModelPick).
    public func canPickModel(on mac: String) -> Bool {
        guard macs.contains(where: { $0.id == mac }) else { return false }
        return ModelPick.supports(journal.record(.init(collection: OpenOnMac.capability, id: mac)), device: mac)
    }

    /// The models the Mac offers its chats; none from one that takes no pick.
    public func models(on mac: String) -> [SyncMacModel] {
        guard macs.contains(where: { $0.id == mac }) else { return [] }
        return ModelPick.models(journal.record(.init(collection: OpenOnMac.capability, id: mac)), device: mac)
    }

    /// The Mac takes photos and files with words (SyncSendFile.capability).
    public func canAttach(on mac: String) -> Bool {
        guard macs.contains(where: { $0.id == mac }) else { return false }
        return SyncSendFile.supports(journal.record(.init(collection: OpenOnMac.capability, id: mac)), device: mac)
    }

    /// The Mac a chat runs on takes photos and files.
    public func canAttach(chat id: String) -> Bool {
        guard let head = chat(id) else { return false }
        return canAttach(on: head.device)
    }

    /// The Mac starts a chat in a project from here (`send.project`).
    public func canStartInProject(on mac: String) -> Bool {
        guard macs.contains(where: { $0.id == mac }) else { return false }
        return ChatProjects.supports(journal.record(.init(collection: OpenOnMac.capability, id: mac)), device: mac)
    }

    /// The chat's Mac takes it moved into a project, or out of one, from here.
    public func canMoveToProject(_ id: String) -> Bool {
        guard canSetChat(id), let head = chat(id) else { return false }
        return ChatProjects.supports(journal.record(.init(collection: OpenOnMac.capability, id: head.device)), device: head.device)
    }

    /// Moves a chat into `project`, or out of its project with nil: its
    /// head's `project`, stamped here as Pin is; the Mac takes it only into
    /// a project it has. Nothing for a Mac that doesn't take it.
    public func moveChat(_ id: String, to project: String?) throws {
        guard journal.record(.init(collection: SyncCollection.chat, id: id)) != nil else { throw Failure.noSuchChat(id) }
        guard project == nil || ChatProjects.valid(project), canMoveToProject(id) else { throw Failure.notAPlace(PhoneSync.projectsUnsupported) }
        try write(SyncCollection.chat, id, ["project": project.map { .string($0) } ?? .null])
        if let chat = chat(id) { emit(.local, [.chat(chat)]) }
    }

    public func canStartAgent(on mac: String) -> Bool {
        guard macs.contains(where: { $0.id == mac }) else { return false }
        return ChatAgent.supports(journal.record(.init(collection: OpenOnMac.capability, id: mac)), device: mac)
    }

    /// The Mac says Yab opens there as its person logs in (Open at Login).
    public func opensAtLogin(_ mac: String) -> Bool {
        guard macs.contains(where: { $0.id == mac }) else { return false }
        return OpensAtLogin.reads(journal.record(.init(collection: OpenOnMac.capability, id: mac)), device: mac)
    }

    /// Offered only after this Mac advertised support in an encrypted record.
    /// A rolled-back Mac ignores the URL-only request instead of running an agent.
    public func canOpen(on mac: String) -> Bool {
        guard macs.contains(where: { $0.id == mac }) else { return false }
        return OpenOnMac.supports(journal.record(.init(collection: OpenOnMac.capability, id: mac)), device: mac)
    }

    /// Takes back words still waiting for their Mac (Don't Send, Ask on
    /// another Mac): `cancelled`, which a Mac's consume passes over. A Mac
    /// that took them first keeps them; the phone hears `taken` and says so.
    @discardableResult
    public func cancel(send id: String) throws -> SyncSend? {
        guard let had = journal.record(.init(collection: SyncCollection.send, id: id)).flatMap(SyncSend.init),
              had.state == .waiting, had.clientDevice == options.device.id || had.clientDevice == nil else { return nil }
        let record = try write(SyncCollection.send, id, ["state": "cancelled"])
        guard let sent = SyncSend(record) else { return nil }
        emit(.local, [.send(sent)])
        return sent
    }

    /// `space`: the synced space the page is in here; the Mac opens it
    /// there when it has that space.
    @discardableResult
    public func open(_ url: URL, on mac: String, space: String? = nil) throws -> SyncSend {
        guard canOpen(on: mac) else { throw OpenOnMac.Failure.unsupported }
        return try send(OpenOnMac.fields(device: mac, sender: options.device.id, url: url, at: Date(), space: space))
    }

    private func send(_ fields: SyncFields, clientChat: String? = nil, question: String? = nil, files: [SendUpload] = []) throws -> SyncSend {
        var fields = fields
        if let clientChat {
            fields["clientChat"] = .string(clientChat)
            fields["clientDevice"] = .string(options.device.id)
            if let question { fields["question"] = .string(question) }
        }
        let id = UUID().uuidString.lowercased()
        if !files.isEmpty { locked { _ = writingSends.insert(id) } }
        defer { if !files.isEmpty { locked { _ = writingSends.remove(id) } } }
        if !files.isEmpty {
            if let failure = SendUpload.check(files.map(\.data.count)) { throw failure }
            // Every part first: a Mac that sees the send finds its bytes there.
            var described: [SyncSendFile] = []
            for (index, file) in files.enumerated() {
                let parts = SyncSendFile.parts(of: file.data, send: id, index: index)
                for part in parts { try journal.change(.init(collection: SyncCollection.sendPart, id: part.id), part.fields) }
                described.append(SyncSendFile(name: file.name, type: file.type, size: file.data.count,
                                              digest: SyncSendFile.hex(file.data), parts: parts.map(\.id)))
            }
            fields["files"] = .array(described.map(\.value))
            // A new chat with its agent chosen and only files still says so.
            if fields["cli"] != nil, fields["agentText"] == nil, fields["text"] == nil { fields["agentText"] = .string("") }
        }
        let record = try write(SyncCollection.send, id, fields)
        guard let sent = SyncSend(record) else { throw Failure.noSuchChat(fields["chat"]?.string ?? "") }
        emit(.local, [.send(sent)])
        return sent
    }

    /// Parts of sends the Mac has answered (taken, failed, expired) or that
    /// are gone: their bytes have done their work, or never will.
    public func sweepSendParts() {
        var settled: [String: Bool] = [:]
        var gone: [Record.Key] = []
        let writing = locked { writingSends }
        for part in journal.living(SyncCollection.sendPart) {
            guard let send = part["send"]?.string else { gone.append(part.key); continue }
            if writing.contains(send) { continue }
            let done = settled[send] ?? {
                let record = journal.record(.init(collection: SyncCollection.send, id: send))
                let state = record.flatMap(SyncSend.init)?.state
                return state == nil || state != .waiting
            }()
            settled[send] = done
            if done { gone.append(part.key) }
        }
        guard !gone.isEmpty else { return }
        for key in gone { try? journal.remove(key) }
        client.kick()
    }

    /// A live chat owned by a known, nonrevoked Mac with the adopter.
    public func canSetChat(_ id: String) -> Bool {
        guard options.chatFlagsGoUp,
              let record = journal.record(.init(collection: SyncCollection.chat, id: id)), record.alive(),
              let head = SyncChat(record),
              (head.kind == "agent" && id.hasPrefix("a:")),
              macs.contains(where: { $0.id == head.device }) else { return false }
        return ChatMetadata.supports(journal.record(.init(collection: OpenOnMac.capability, id: head.device)), device: head.device)
    }

    /// Older Macs keep these choices on this iPhone. Fresh choices on a
    /// supported Mac replace only their matching local pending overrides.
    public func setChat(_ id: String, pinned: Bool? = nil, archived: Bool? = nil, unread: Bool? = nil, title: String? = nil) throws {
        guard let record = journal.record(.init(collection: SyncCollection.chat, id: id)) else { throw Failure.noSuchChat(id) }
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
        var fields: SyncFields = [:]
        if let pinned { fields["pinned"] = pinned ? .bool(true) : .null }
        if let archived { fields["archived"] = archived ? .bool(true) : .null }
        if let unread { fields["unread"] = unread ? .bool(true) : .null }
        if let name { fields["title"] = .string(name) }
        guard !fields.isEmpty else { return }
        let supported = canSetChat(id)
        if supported { try write(SyncCollection.chat, id, fields) }
        let generation = unread == false && !supported ? readGeneration(record) : nil
        let all: [String: ChatFlags] = locked {
            var mine = flags[id] ?? ChatFlags()
            if let pinned { mine.pinned = supported ? nil : pinned }
            if let archived { mine.archived = supported ? nil : archived }
            if let unread {
                mine.unread = supported ? nil : unread
                mine.unreadGeneration = generation
            }
            if let name { mine.title = supported ? nil : name }
            flags[id] = mine.isEmpty ? nil : mine
            return flags
        }
        PhoneSync.writeFlags(all, options.folder)
        if let chat = chat(id) { emit(.local, [.chat(chat)]) }
    }

    private func readGeneration(_ record: Record) -> String {
        let steps = messages(in: record.id)
        let parts = [record["answer"]?.string ?? "", steps.last { $0.kind == "asked" && !$0.isInternal }?.id ?? "",
                     steps.last { $0.kind == "message" }?.id ?? ""]
        return SHA256.hash(data: (try? JSONEncoder().encode(parts)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    private func chat(from record: Record) -> SyncChat? {
        guard var chat = SyncChat(record) else { return nil }
        var mine = locked { flags[record.id] }
        if mine?.deleted == true { return nil }
        if mine?.unread == false {
            let generation = readGeneration(record)
            if let read = mine?.unreadGeneration, read != generation {
                mine?.unread = nil
                mine?.unreadGeneration = nil
            } else {
                // Older flags have no turn marker. Bind their read to the
                // current answer once; subsequent answers can be new again.
                mine?.unreadGeneration = generation
            }
            let all: [String: ChatFlags]? = locked {
                guard flags[record.id] != mine else { return nil }
                flags[record.id] = mine?.isEmpty == true ? nil : mine
                return flags
            }
            if let all { PhoneSync.writeFlags(all, options.folder) }
        }
        if let mine {
            if let pinned = mine.pinned { chat.pinned = pinned }
            if let archived = mine.archived { chat.archived = archived }
            if let unread = mine.unread { chat.unread = unread }
            if let title = mine.title { chat.title = title }
        }
        return chat
    }

    struct ChatFlags: Codable, Equatable {
        var pinned: Bool?
        var archived: Bool?
        var unread: Bool?
        var unreadGeneration: String?
        var title: String?
        /// Deleted from here: its head, kept readable as one that left
        /// sync, isn't shown again.
        var deleted: Bool?
        var isEmpty: Bool { pinned == nil && archived == nil && unread == nil && title == nil && deleted == nil }
    }

    private static func readFlags(_ folder: URL) -> [String: ChatFlags] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("chat-flags.json")) else { return [:] }
        return (try? JSONDecoder().decode([String: ChatFlags].self, from: data)) ?? [:]
    }

    private static func writeFlags(_ flags: [String: ChatFlags], _ folder: URL) {
        guard let data = try? JSONEncoder().encode(flags) else { return }
        try? data.write(to: folder.appendingPathComponent("chat-flags.json"), options: .atomic)
    }

    // MARK: History

    /// A place been to on this iPhone. `last` and `typed` only ever grow.
    public func visited(_ url: URL, title: String, typed: Bool = false, at date: Date = Date()) throws {
        guard SyncVisit.keeps(url) else { throw Failure.notAPlace(url.absoluteString) }
        let fresh = SyncVisit(url: url.absoluteString, title: title, last: date.timeIntervalSince1970.rounded(.down), typed: typed)
        let had = journal.record(.init(collection: SyncCollection.visit, id: fresh.id)).flatMap(SyncVisit.init)
        var fields: SyncFields = [:]
        if fresh.last > (had?.last ?? 0) { fields["last"] = .number(fresh.last); fields["url"] = .string(fresh.url) }
        if !title.isEmpty, title != had?.title { fields["title"] = .string(String(title.prefix(300))) }
        if typed, had?.typed != true { fields["typed"] = .bool(true) }
        if had == nil { fields = fresh.fields }
        guard !fields.isEmpty else { return }
        let record = try write(SyncCollection.visit, fresh.id, fields)
        if let visit = SyncVisit(record) { emit(.local, [.visit(visit)]) }
    }

    // MARK: Task record transport (execution remains unavailable)

    public func canTransportTaskRecords(on mac: String) -> Bool {
        guard journal.clock.device == options.device.id,
              macs.contains(where: { $0.id == mac }) else { return false }
        if case .refused = state { return false }
        return TaskRecords.supports(journal.record(.init(collection: OpenOnMac.capability, id: mac)), mac: mac)
    }

    /// A new live send requires a currently awake known Mac and its distinct
    /// read-only producer authority. Cached transport alone is insufficient.
    public func readOnlyTaskEpoch(on mac: String) -> String? {
        let now = Date().timeIntervalSince1970
        guard state == .live, canTransportTaskRecords(on: mac),
              let owner = macs.first(where: { $0.id == mac && $0.online }), let front = owner.front,
              !front.asleep, front.at.isFinite, front.at > 0,
              now - front.at >= -5, now - front.at < options.onlineFor else { return nil }
        return TaskRecords.readOnlyEpoch(journal.record(.init(collection: OpenOnMac.capability, id: mac)), mac: mac)
    }

    @discardableResult
    public func sendReadOnlyTaskRecord(_ words: String, on mac: String, origin: TaskRecords.Origin,
                                       epoch: String) throws -> TaskRecords.Request {
        guard !origin.isPrivate else { throw TaskRecords.Failure.privateOrigin }
        guard readOnlyTaskEpoch(on: mac) == epoch else { throw TaskRecords.Failure.unsupported }
        return try storeTaskRecord(words, on: mac, origin: origin, readOnlyEpoch: epoch)
    }

    /// Captured public source only. No task UI, provider, key, or permission
    /// is enabled by persisting this request. There is no chat-send fallback.
    @discardableResult
    public func sendTaskRecord(_ words: String, on mac: String, origin: TaskRecords.Origin) throws -> TaskRecords.Request {
        try storeTaskRecord(words, on: mac, origin: origin, readOnlyEpoch: nil)
    }

    private func storeTaskRecord(_ words: String, on mac: String, origin: TaskRecords.Origin,
                                 readOnlyEpoch: String?) throws -> TaskRecords.Request {
        guard !origin.isPrivate else { throw TaskRecords.Failure.privateOrigin }
        guard canTransportTaskRecords(on: mac) else { throw TaskRecords.Failure.unsupported }
        guard let spaceRecord = journal.record(.init(collection: SyncCollection.space, id: origin.space)),
              let _ = SyncSpace(spaceRecord) else { throw Failure.noSuchSpace(origin.space) }
        var sourceURL: String?, sourceTitle: String?
        if let id = origin.tab {
            guard let raw = journal.record(.init(collection: SyncCollection.tab, id: id)),
                  let source = SyncTab(raw), source.space == origin.space,
                  OpenOnMac.url(source.url) != nil else { throw Failure.noSuchTab(id) }
            guard origin.url == source.url, origin.title == source.title else { throw TaskRecords.Failure.stale }
            sourceURL = origin.url; sourceTitle = origin.title
        } else if origin.url != nil || origin.title != nil { throw TaskRecords.Failure.invalid }
        let request = try TaskRecords.Request(account: seal.account, phone: options.device.id, mac: mac,
                                              space: origin.space, tab: origin.tab, url: sourceURL, title: sourceTitle,
                                              words: words, readOnlyEpoch: readOnlyEpoch)
        let fields = try request.fields()
        if let readOnlyEpoch, readOnlyTaskEpoch(on: mac) != readOnlyEpoch { throw TaskRecords.Failure.unsupported }
        let record = try journal.change(.init(collection: TaskRecords.requestCollection, id: request.id), fields)
        guard journal.record(record.key) == record,
              (try TaskRecords.Request.read(record, account: seal.account, phone: options.device.id, mac: mac)) == request else {
            throw TaskRecords.Failure.storage
        }
        client.kick()
        notifyTaskRecordChanges()
        return request
    }

    /// Pure retained authored requests. No callback delivery is consumed and
    /// no local sending/running/result record is synthesized by this read.
    public func taskRequests() -> [TaskRecords.Request] {
        journal.all(TaskRecords.requestCollection).compactMap { record in
#if DEBUG
            taskRecordReadWork?(record.id)
#endif
            guard let request = try? TaskRecords.Request.read(record, account: seal.account, phone: options.device.id),
                  canTransportTaskRecords(on: request.mac) else { return nil }
            return request
        }.sorted { ($0.created, $0.id) < ($1.created, $1.id) }
    }

    /// Open questions from a known Mac, still bound to its current sealed
    /// request. A response already in Sync hides the card on every device.
    public func assistantApprovals() -> [AssistantApprovalRecords.Request] {
        let known = Set(locked { listed.filter { !$0.revoked && $0.id != options.device.id
            && !$0.model.hasPrefix("iPhone") && !$0.model.hasPrefix("iPad") }.map(\.id) })
        return journal.all(AssistantApprovalRecords.requestCollection).compactMap { record in
            guard let writer = record.stamps["body"]?.device, known.contains(writer),
                  let request = try? AssistantApprovalRecords.Request.read(record, account: seal.account, mac: writer),
                  (try? request.validate(at: Date())) != nil,
                  journal.record(.init(collection: AssistantApprovalRecords.answerCollection, id: request.id))?.alive() != true
            else { return nil }
            return request
        }.sorted { ($0.issued, $0.id) < ($1.issued, $1.id) }
    }

    /// What a question is about, whole, when its Mac sent it (version 3).
    public func assistantDetail(_ request: AssistantApprovalRecords.Request) -> AssistantApprovalRecords.Detail? {
        journal.record(.init(collection: AssistantApprovalRecords.detailCollection, id: request.id))
            .flatMap { try? AssistantApprovalRecords.Detail.read($0, request: request) }
    }

    /// One page of a file in a question's detail, as a JPEG, if it came yet.
    public func assistantPreview(_ request: AssistantApprovalRecords.Request, file: String, page: Int) -> Data? {
        let id = AssistantApprovalRecords.Preview.id(request: request.id, file: file, page: page)
        return journal.record(.init(collection: AssistantApprovalRecords.previewCollection, id: id))
            .flatMap { try? AssistantApprovalRecords.Preview.read($0, request: request, file: file, page: page).data }
    }

    /// What came of a yes: paying, paid, declined, done. Read against the
    /// request as it was answered, since an answered request leaves the list.
    public func assistantResult(_ request: AssistantApprovalRecords.Request) -> AssistantApprovalRecords.Result? {
        journal.record(.init(collection: AssistantApprovalRecords.resultCollection, id: request.id))
            .flatMap { try? AssistantApprovalRecords.Result.read($0, request: request) }
    }

    /// A card or an address kept here for a payment's answer: its record
    /// goes up first, so the Mac has it by the time the answer names it.
    public func keepCard(number: String, csc: String, name: String, month: Int, year: Int) throws -> String {
        let id = UUID().uuidString
        _ = try write(SyncCollection.card, id, try AssistantWallet.card(id: id, number: number, csc: csc, name: name,
                                                                         month: month, year: year, seal: seal))
        return id
    }

    public func keepAddress(name: String, street: String, city: String, postal: String) throws -> String {
        let id = UUID().uuidString
        _ = try write(SyncCollection.address, id, try AssistantWallet.address(id: id, name: name, street: street, city: city,
                                                                               postal: postal, seal: seal))
        return id
    }

    /// Explicit answer on this iPhone. Re-read the live request and its Mac
    /// owner before writing; an assistant never gets a method to call here.
    /// A sign-in's yes names the account; `proved`, Face ID or the passcode
    /// passed on this iPhone just before.
    public func answerAssistantApproval(_ id: String, yes: Bool, choice: String? = nil, proved: Bool = false,
                                        detail: AssistantApprovalRecords.Detail? = nil, card: String? = nil,
                                        place: String? = nil, added: [String] = []) throws {
        guard let request = assistantApprovals().first(where: { $0.id == id }),
              let original = journal.record(.init(collection: AssistantApprovalRecords.requestCollection, id: id)),
              // The detail read is the one in the journal now: changed since, the yes is refused.
              detail == nil || detail == assistantDetail(request),
              let answer = try? AssistantApprovalRecords.Answer(request: request, device: options.device.id, yes: yes,
                                                                 choice: yes ? choice : nil, proved: proved, detail: detail,
                                                                 card: card, place: place, added: added),
              let fields = try? answer.fields(),
              journal.record(original.key) == original else { throw AssistantApprovalRecords.Failure.changed }
        let saved = try journal.change(.init(collection: AssistantApprovalRecords.answerCollection, id: id), fields)
        guard saved.fields == fields else { throw AssistantApprovalRecords.Failure.changed }
        client.kick()
        notifyAssistantApprovals()
    }

    /// A retained request and a currently known nonrevoked Mac are required
    /// even for a result read from the durable local inbox after relaunch.
    public func taskRecords() -> [TaskRecords.Observation] {
        journal.all(TaskRecords.requestCollection).compactMap { record in
            guard let request = try? TaskRecords.Request.read(record, account: seal.account, phone: options.device.id),
                  canTransportTaskRecords(on: request.mac),
                  let current = journal.record(.init(collection: TaskRecords.observationCollection, id: request.id)),
                  (try? TaskRecords.Observation.read(current, request: request)) != nil else { return nil }
            return try? taskInbox.current(request: request)
        }.sorted { $0.task < $1.task }
    }

    /// Current authority for one cached ID. This is still a journal read on
    /// every UI access; cached ownership never releases a removed request.
    func checkedTaskRecord(_ id: String) -> (request: TaskRecords.Request, observation: TaskRecords.Observation?)? {
        guard let record = journal.record(.init(collection: TaskRecords.requestCollection, id: id)) else { return nil }
#if DEBUG
        taskRecordReadWork?(record.id)
#endif
        guard let request = try? TaskRecords.Request.read(record, account: seal.account, phone: options.device.id),
              canTransportTaskRecords(on: request.mac) else { return nil }
        var observation: TaskRecords.Observation?
        if let current = journal.record(.init(collection: TaskRecords.observationCollection, id: request.id)),
           (try? TaskRecords.Observation.read(current, request: request)) != nil {
            observation = try? taskInbox.current(request: request)
        }
        return (request, observation)
    }

    private func observeTaskRecords(_ records: [Record]) {
        var accepted: [TaskRecords.Observation] = []
        for record in records where record.collection == TaskRecords.observationCollection {
            guard let original = journal.record(.init(collection: TaskRecords.requestCollection, id: record.id)),
                  let request = try? TaskRecords.Request.read(original, account: seal.account, phone: options.device.id),
                  canTransportTaskRecords(on: request.mac),
                  let observed = try? TaskRecords.Observation.read(record, request: request),
                  (try? taskInbox.accept(observed, request: request)) != nil else { continue }
            accepted.append(observed)
        }
        // A new engine reports its real retained snapshot once after known-Mac
        // reconciliation. The getter never consumes this delivery.
        let ids: Set<String> = locked {
            guard _onTasks != nil else { return [] }
            var fresh: Set<String> = []
            for value in accepted where value.revision > (_taskDelivered[value.task] ?? 0) {
                if _taskCallbacksPending.insert(value.task).inserted { fresh.insert(value.task) }
            }
            return fresh
        }
        guard !ids.isEmpty else { return }
        options.callbacks.async { [weak self] in
            guard let self else { return }
            // The owner may have been revoked, or a newer revision accepted,
            // while this callback waited for the app's queue.
            let latest = self.taskRecords().filter { ids.contains($0.task) }
#if DEBUG
            self.taskRecordSnapshotRead?()
#endif
            let callback = self.onTaskRecords
            let deliver: [TaskRecords.Observation] = self.locked {
                self._taskCallbacksPending.subtract(ids)
                guard callback != nil else { return [] }
                return latest.filter { value in
                    guard value.revision > (self._taskDelivered[value.task] ?? 0) else { return false }
                    self._taskDelivered[value.task] = value.revision
                    return true
                }
            }
            if !deliver.isEmpty { callback?(deliver) }
            // A newer record can arrive after the snapshot read while this
            // ID still belongs to the pending callback. Reconcile once after
            // releasing it; the delivered map ends unchanged replays.
            self.observeTaskRecords(self.journal.all(TaskRecords.observationCollection).filter { ids.contains($0.id) })
        }
    }

    // MARK: Changes

    @discardableResult
    private func write(_ collection: String, _ id: String, _ fields: SyncFields) throws -> Record {
        let record = try journal.change(.init(collection: collection, id: id), fields)
        client.kick()
        return record
    }

    /// Every Mac's Now rows about mail, as the widget draws them (NowShelf).
    func nowRows() -> [NowShelfRow] {
        journal.all(SyncCollection.now).filter { $0.alive() }.compactMap { record in
            guard let title = record["title"]?.string, !title.isEmpty else { return nil }
            return NowShelfRow(id: record.id, title: title, detail: record["detail"]?.string ?? "", who: record["who"]?.string ?? "",
                               host: record["host"]?.string ?? "", web: record["web"]?.string, message: record["message"]?.string,
                               order: Int(record["order"]?.number ?? 0))
        }
    }

    func shelveNow(_ shelf: NowShelf = .shared) { shelf.write(nowRows()) }

    func changes(for record: Record) -> [SyncChange] {
        switch record.collection {
        case SyncCollection.space: return [SyncSpace(record).map(SyncChange.space) ?? .spaceGone(record.id)]
        case SyncCollection.tab: return [SyncTab(record).map(SyncChange.tab) ?? .tabGone(record.id)]
        case SyncCollection.folder: return [SyncFolder(record).map(SyncChange.folder) ?? .folderGone(record.id)]
        case SyncCollection.icon: return [SyncIcon(record).map(SyncChange.icon) ?? .iconGone(record.id)]
        case SyncCollection.pair: return [SyncPair(record).map(SyncChange.pair) ?? .pairGone(record.id)]
        case SyncCollection.bookmark: return [SyncBookmark(record).map(SyncChange.bookmark) ?? .bookmarkGone(record.id)]
        case SyncCollection.setting: return [SyncSetting(record).map(SyncChange.setting) ?? .settingGone(record.id)]
        case SyncCollection.visit: return SyncVisit(record).map { [.visit($0)] } ?? []
        case SyncCollection.chat: return [chat(from: record).map(SyncChange.chat) ?? .chatGone(record.id)]
        case SyncCollection.chatItem:
            guard record.alive() else { return [.messageGone(record.id)] }
            guard let item = SyncChatItem(record) else { return [] }
            var changes: [SyncChange] = [.message(item)]
            // An old Mac may publish only the new steps before its head.
            // Let a local read release the next answer in either order.
            if locked({ flags[item.chat]?.unread == false }), let head = chat(item.chat) { changes.append(.chat(head)) }
            return changes
        case SyncCollection.send: return SyncSend(record).map { [.send($0)] } ?? []
        case SyncCollection.project: return [SyncProject(record).map(SyncChange.project) ?? .projectGone(record.id)]
        default: return []
        }
    }

    private func emit(_ origin: SyncBatch.Origin, _ changes: [SyncChange]) {
        guard !changes.isEmpty, let callback = onChanges else { return }
        let batch = SyncBatch(origin: origin, changes: changes)
        options.callbacks.async { callback(batch) }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}
