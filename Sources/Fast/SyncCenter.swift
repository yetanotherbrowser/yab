import AppKit
import Combine
import Foundation
import SyncKit

/// This Mac's id among the account's devices (`sync.device`). The server
/// refuses an id removed from the account for good, so a Mac removed from
/// elsewhere forgets its id as it turns off and joins again under a new one
/// (R7, Phone/Reference/digest/sync-ios.md). An ordinary off and on keeps it.
struct SyncDeviceIdentity {
    let settings: UserDefaults
    private let key = "sync.device"

    init(settings: UserDefaults) { self.settings = settings }

    var id: String {
        if let kept = settings.string(forKey: key) { return kept }
        let id = UUID().uuidString.lowercased()
        settings.set(id, forKey: key)
        return id
    }

    /// Only the refused client's own id goes: a late finish of an older
    /// client can't take away the id a newer join already registered.
    func turnOff(after state: SyncClient.State, device: String?) {
        guard case .refused = state, settings.string(forKey: key) == device else { return }
        settings.removeObject(forKey: key)
    }
}

// Sync on this Mac (docs/sync.md): the key, the journal, the line to the
// server, and the mirrors between them and Yab's own files and windows.
// Going out: a file written (a space's row, the spaces, the bookmarks, a
// setting) is read back and told to the journal, which stamps what changed
// and the client sends it. Coming in: what changed is written into the
// files and, for rows, into the live window, where a page on screen is
// never pulled from under you.

/// Where a flush tells the journal what Yab's files say, one after
/// another, and where a delivery waits its turn to merge (SyncCenter.flush).
/// The main thread never waits on it.
private let syncFlushing = DispatchQueue(label: "yab.sync.flush", qos: .utility)

@MainActor
final class SyncCenter: ObservableObject {
    static let shared = SyncCenter()

    private let sharedKey: () -> Seal?
    private let keepKey: (Seal) -> Void
    private let activateAccount: ((SyncCenter, Seal) -> Void)?
    private let pairingTransport: Transport?
    /// How long Turn On waits for iCloud Keychain before it asks.
    private let lookFor: TimeInterval

    /// Keep account-entry tests off Keychain and the live sync client.
    /// Ordinary instances use the existing key store, pairing and begin path.
    init(sharedKey: @escaping () -> Seal? = { SyncKey.shared },
         keepKey: @escaping (Seal) -> Void = { SyncKey.keep($0) },
         activateAccount: ((SyncCenter, Seal) -> Void)? = nil,
         pairingTransport: Transport? = nil,
         lookFor: TimeInterval = 6) {
        self.sharedKey = sharedKey
        self.keepKey = keepKey
        self.activateAccount = activateAccount
        self.pairingTransport = pairingTransport
        self.lookFor = lookFor
    }

    let capabilityAnswerers = AssistantAnswererNames()
    @Published private(set) var on = false { didSet { refreshAssistantAnswererNames() } }
    @Published private(set) var state: SyncClient.State = .off
    @Published private(set) var devices: [SyncClient.Listed] = [] { didSet { refreshAssistantAnswererNames() } }
    /// The Recovery Key, shown once, right after sync is turned on.
    @Published var recovery: String?
    /// The code this Mac shows while it waits to be let in, or the code of
    /// another Mac's Add a Device typed here (`joiningInvited`).
    @Published private(set) var joining: Joining?
    /// `joining` is under a code another Mac showed: this Mac shows the four
    /// digits that Mac asks about, not a code of its own.
    @Published private(set) var joiningInvited = false
    /// Why the last code didn't get this Mac in, shown under the next one.
    @Published private(set) var joinTrouble: String?
    /// Where Turn On Sync has got to (docs/sync.md, "Turning on").
    enum Arrival: Equatable {
        case ready
        /// Waiting for the account's key from iCloud Keychain.
        case looking
        /// No key came: the person says whether this is the first device.
        case nobody
        /// No line: nobody can say there are no other devices.
        case offline
    }
    @Published private(set) var arrival = Arrival.ready
    private var lookNumber = 0
    /// Another account on this Apple ID, while it stands apart.
    struct Separate: Equatable {
        let account: String
        let name: String
        let seal: Seal
        let devices: Int
        static func == (a: Separate, b: Separate) -> Bool { a.account == b.account && a.name == b.name && a.devices == b.devices }
    }
    @Published private(set) var separate: Separate?
    /// The same, after Keep Separate: only Add a Device still offers it.
    @Published private(set) var keptApart: Separate?
    /// Two accounts are becoming one.
    @Published private(set) var joiningAccounts = false
    /// This Mac said Join to a code it typed while it syncs.
    @Published private(set) var joinAgreed = false
    /// The key that code's Mac sent, held until Join.
    private var heldKey: Seal?
    var awaitingJoinConfirmation: Bool { heldKey != nil && !joinAgreed }
    /// Two accounts became one from a code typed here: Add a Device is done.
    @Published private(set) var joinedByCode = 0
    private var separateLooked = Date.distantPast
    private static let keptKey = "sync.keptSeparate", leftKey = "sync.leftAccounts", toldKey = "sync.toldSeparate"
    private var asking: Pairing.Asking? {
        willSet { asking?.cancel() }
    }
    /// How many things of each kind sync holds, for Settings, counted only
    /// while it shows them (`showCounts`).
    @Published private(set) var counts: [String: Int] = [:]
    private var countsShown = 0
    private var counting = false
    private var countAgain = false
    private let countQueue = DispatchQueue(label: "sync.count", qos: .utility)
    @Published private(set) var disabledCategories = Set((Store.settings.stringArray(forKey: SyncCategory.preferenceKey) ?? [])
        .compactMap(SyncCategory.init(rawValue:)))
    private var categoryRevision = 0

    var excludedCollections: Set<String> { SyncCategory.excluded(by: disabledCategories) }

    func syncs(_ category: SyncCategory) -> Bool { !disabledCategories.contains(category) }

    func setSync(_ category: SyncCategory, enabled: Bool) {
        guard syncs(category) != enabled else { return }
        if enabled { disabledCategories.remove(category) } else { disabledCategories.insert(category) }
        Store.settings.set(disabledCategories.map(\.rawValue).sorted(), forKey: SyncCategory.preferenceKey)
        categoryRevision += 1
        let revision = categoryRevision
        if enabled {
            // Survives quitting before catch-up finishes, including an offline
            // change made while no client is running.
            Store.settings.set(true, forKey: SyncCategory.replayKey)
            if category == .chats { chatsSent = [:] }
        }
        guard let client else { return }
        // Pause before changing the policy. When enabling, read local edits
        // against the old journal before replaying remote changes missed while
        // disabled; otherwise an unchanged local value could undo a remote edit.
        client.stop()
        client.setExcludedCollections(excludedCollections)
        due.formUnion(category.collections)
        flush(after: { [weak self, weak client] succeeded in
            guard let self, let client, self.client === client, self.categoryRevision == revision, succeeded else { return }
            client.start()
        })
    }
    /// The last two weeks of history go with the rest, unless turned off.
    @Published var history = Store.settings.object(forKey: "sync.history") as? Bool ?? true {
        didSet {
            Store.settings.set(history, forKey: "sync.history")
            changed(SyncShapes.visit)
        }
    }

    private(set) var journal: Journal? { didSet { refreshAssistantAnswererNames() } }
    private(set) var client: SyncClient?
    /// When each chat that went up had last moved: one that hasn't moved
    /// since isn't read again (SyncChats).
    var chatsSent: [String: Date] = [:]
    /// Tasks from the iPhone, while sync is on (SyncTasks, SyncTaskRead).
    private(set) var taskReader: SyncTaskRead?
    /// The page in front on each iPhone of the account, as its presence
    /// last said it (SyncPhone): the field's From iPhone row.
    var phoneFronts: [String: PhoneFront.Page] = [:]
    /// When an iPhone not in the device list last had it read again.
    var phonesAskedForDevices = Date.distantPast
    /// When a task from a phone not yet in the device list last asked for
    /// the list again (SyncTasks): a phone that just joined.
    var taskAskedForDevices = Date.distantPast
    private var seal: Seal?

    /// The Memory review only decodes address context. It never reads a
    /// password/card item or performs a network request to show a preview.
    func contextSyncReplay() -> ContextSyncReplay {
        let seal = self.seal
        return ContextSyncReplay(privacy: .shared, journal: journal, root: Store.folder,
            decodeAddress: { record in
                guard let seal, let data = record["secret"]?.string.flatMap({ seal.reveal($0, in: record.key) }) else { return nil }
                return SyncWallet.contextAddress(data, id: record.id)
            }, writeAddress: { address, record in
                guard let data = Wallet.addressData(address) else { return false }
                let facts = record["facts"].flatMap { try? JSONEncoder().encode($0) }
                return Wallet.put(card: false, record.id, secret: data, facts: facts, from: record.latest?.wall)
            })
    }
    private var bag = Set<AnyCancellable>()
    private var due = Set<String>()
    private var dueWork: DispatchWorkItem?
    /// Set while what came from elsewhere is being written in, so the
    /// writes it causes aren't read back as changes made here.
    private var applying = false
    /// Joined just now: once caught up, the same pin or bookmark brought
    /// by both sides is made one (`settleJoin`).
    private var merging = false
    /// The front tab and how far down its page is (0...1), read as the
    /// person leaves this Mac: a phone opening that tab starts there (R9).
    private var leftAt: (tab: UUID, scroll: Double)?
    /// This Mac is going to sleep, or Yab is quitting: said with the
    /// presence, so a phone shows "Mac asleep" at once, not minutes later.
    private var sleeping = false
    /// Yab is quitting: its last presence says `why: quit`, not sleep.
    private var quitting = false
    /// Incoming addon changes held until a join has caught up, including
    /// removals of plugins this Mac still keeps from its previous join.
    private var joiningAddons: [String: Set<String>] = [:]
    /// Passwords and cards (SyncWallet): the keychain is read and written
    /// on a queue of its own. `walletStamps` and `walletSeen` are what the
    /// last read knew, `walletEpoch` moves when records come in, so a read
    /// begun before them is thrown away, and `walletChanges` is the
    /// keychain's change count that read saw.
    private let walletQueue = DispatchQueue(label: "sync.wallet", qos: .utility)
    private var walletStamps: [String: String] = [:]
    private var walletSeen = Set<String>()
    private var walletEpoch = 0
    private var walletChanges = -1
    /// Passwords and cards go with the rest, unless turned off.
    @Published var passwords = SyncWallet.on {
        didSet {
            SyncWallet.on = passwords
            walletChanges = -1
            changed(SyncWallet.login)
        }
    }
    /// Extensions and plugins go with the rest, unless turned off. Off,
    /// this Mac gives up the plugins it ticked for the others and nothing
    /// waits to be put in. What it agreed on with the account stays noted
    /// (SyncAddons.Ledger), so on again it takes what changed elsewhere
    /// meanwhile and sends only what changed here.
    @Published var addons = SyncAddons.on {
        didSet {
            guard addons != oldValue else { return }
            if !addons, let journal, let mirror {
                if !mirror.giveUp(journal, device: Self.deviceID).isEmpty { client?.kick() }
            }
            SyncAddons.on = addons
            if addons {
                changed(SyncAddons.ext)
                changed(SyncAddons.plugin)
                changed(SyncShapes.setting)
            } else {
                SyncInstalls.shared.clear()
            }
            // Ticks and a plugin's routines follow who ticks now.
            BoostServices.shared.reconcile()
            BoostContributions.reconcile()
        }
    }
    /// The extensions and plugins mirror (SyncMirror), while sync is on.
    private(set) var mirror: SyncMirror?
    /// Set while this Mac hands its plugins over and leaves: nothing more
    /// is read, sent or taken in.
    private var leaving = false
    private static var ledgerFile: URL { Store.file("sync-addons.json") }

    /// The server: `YAB_SYNC_URL`, then Info.plist's `YabSync`, then the
    /// address the Worker is deployed at.
    static var base: URL {
        if let env = ProcessInfo.processInfo.environment["YAB_SYNC_URL"], let url = URL(string: env) { return url }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "YabSync") as? String, let url = URL(string: plist) { return url }
        return URL(string: "https://yab-sync.21st.workers.dev")!
    }

    /// This Mac's name among the devices: made once, kept on this Mac only.
    static var device: SyncClient.Device {
        SyncClient.Device(id: deviceID, name: Host.current().localizedName ?? "Mac", model: Self.model)
    }

    nonisolated static var deviceID: String {
        SyncDeviceIdentity(settings: Store.settings).id
    }

    private static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var chars = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &chars, &size, nil, 0)
        return String(cString: chars)
    }

    // MARK: On and off

    /// At launch: back on if this Mac was in.
    func launch() {
        SyncShapes.register()
        guard let seal = SyncKey.local else { return }
        begin(seal)
    }

    /// Not in a test world unless it names a server of its own.
    nonisolated static var mayRun: Bool { !Store.testing || ProcessInfo.processInfo.environment["YAB_SYNC_URL"] != nil }

    /// A Yab woken for agents starts without sync, and starts it once a
    /// person shows it or it is kept to serve (Headless): before, it never
    /// did, so an iPhone's chats and tasks waited on a Mac that was open.
    func launchIfNeeded() {
        guard journal == nil, Self.mayRun else { return }
        launch()
    }

    /// Settings › Sync › Turn On: the account iCloud Keychain already
    /// holds if there is one, a new one otherwise.
    func turnOn() {
        // Choosing this account supersedes a code still waiting elsewhere.
        stopAsking()
        if let shared = sharedKey() { return join(shared) }
        lookNumber += 1
        arrival = .looking
        look(lookNumber, until: Date().addingTimeInterval(lookFor))
    }

    /// iCloud Keychain can be seconds behind: a new account made now is a
    /// second account for the same person, with nothing to say so.
    private func look(_ number: Int, until: Date) {
        guard number == lookNumber, arrival == .looking else { return }
        if let shared = sharedKey() {
            arrival = .ready
            return join(shared)
        }
        guard Date() >= until else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in look(number, until: until) }
            return
        }
        var health = URLRequest(url: Self.base.appendingPathComponent("v1/health"))
        health.timeoutInterval = 8
        (pairingTransport ?? WebTransport()).request(health) { status, _ in
            DispatchQueue.main.async { [self] in
                guard number == lookNumber, arrival == .looking else { return }
                arrival = status == nil ? .offline : .nobody
            }
        }
    }

    /// Back to Turn On Sync, from looking or either answer.
    func stopLooking() {
        lookNumber += 1
        arrival = .ready
    }

    /// Is This Your First Device?'s Start Syncing, and the only way a new
    /// account is made: the account iCloud Keychain holds if one came since.
    func startSyncing() {
        stopAsking()
        stopLooking()
        if let shared = sharedKey() { return join(shared) }
        let seal = Seal.make()
        keepKey(seal)
        recovery = seal.recovery
        begin(seal)
    }

    /// In with a key from elsewhere: a code, the Recovery Key, iCloud.
    /// What this Mac had is pictured first, for Undo Joining.
    func join(_ seal: Seal) {
        stopAsking()
        keepKey(seal)
        Self.snapshot()
        // Pins as the account has them, not as this Mac decided alone: each
        // space's until its value comes, so no pin of another Mac's is
        // taken for a shared one meanwhile.
        if SharedPins.joining(settings: Store.settings) {
            for browser in BrowserWindows.shared.browsers where browser.prefs.pinsEverySpace { browser.prefs.pinsEverySpace = false }
        }
        merging = true
        begin(seal)
    }

    /// Typed in Settings: true if it was a Recovery Key.
    func join(recovery text: String) -> Bool {
        guard let seal = Seal(recovery: text) else { return false }
        join(seal)
        return true
    }

    /// Shows a code and waits for a device in the account to answer it.
    /// With `invite`, the code another Mac shows under Add a Device, typed
    /// here: this Mac posts its key under that code and waits for that
    /// Mac's yes to the four digits both show (JoinInvite), as an iPhone
    /// scanning it does. Before, a Mac had nowhere to put such a code, and
    /// the code a syncing Mac showed worked only for an iPhone (register 1628).
    func askToJoin(invite: String? = nil) {
        let invited = invite.flatMap { JoinInvite.code(scanned: $0) }
        if invite != nil, invited == nil {
            joinTrouble = "That isn’t a code from Yab. On the other Mac, choose Add a Device in Settings › Sync."
            return
        }
        let joining = Joining(code: invited)
        self.joining = joining
        joiningInvited = invited != nil
        if invited != nil { joinTrouble = nil }
        asking = Pairing.wait(joining, base: Self.base, transport: pairingTransport ?? WebTransport()) { result in
            DispatchQueue.main.async { [self] in
                guard self.joining?.code == joining.code else { return }
                self.asking = nil
                switch result {
                case let .success(seal):
                    joinTrouble = nil
                    if self.seal != nil {
                        // Let In can arrive before this Mac's Join. Keep
                        // its code and digits visible until its own yes.
                        heldKey = seal
                        settleHeld()
                    } else {
                        join(seal)
                    }
                case let .failure(failure):
                    self.joining = nil
                    self.joiningInvited = false
                    // Why, said, never the page quietly back to Turn On as
                    // it was; and a code of this Mac's own back on screen
                    // when the other Mac's didn't work or this one's ran out.
                    joinTrouble = Self.trouble(failure, invited: invited != nil)
                    joinAgreed = false
                    // Syncing already: Add a Device has a code of its own.
                    guard self.seal == nil else { return }
                    switch failure {
                    case .taken, .expired: askToJoin()
                    case .unreadable, .refused: if invited != nil { askToJoin() }
                    }
                }
            }
        }
    }

    static func trouble(_ failure: Pairing.Failure, invited: Bool) -> String? {
        switch (failure, invited) {
        case (.taken, _): "That code was used already. On the other Mac, choose Add a Device for a new one."
        case (.expired, true): "That code ran out. On the other Mac, choose Add a Device for a new one."
        // This Mac's own code ran out: a new one, nothing to say.
        case (.expired, false): nil
        case (.unreadable, _), (.refused, _): "The other Mac couldn’t let this Mac in. Check it has the latest Yab, then try again."
        }
    }

    /// Cancel, or the page gone: nothing more is read or sent.
    func stopAsking() {
        asking = nil
        joining = nil
        joiningInvited = false
        joinTrouble = nil
        joinAgreed = false
        heldKey = nil
    }

    // MARK: Two accounts

    /// The Join under the digits, on a Mac that already syncs: waits for
    /// the other Mac's Let In, in whichever order they come.
    func agreeToJoin() {
        guard joining != nil || heldKey != nil else { return }
        joinAgreed = true
        settleHeld()
    }

    private func settleHeld() {
        guard joinAgreed, let held = heldKey else { return }
        heldKey = nil
        joinAgreed = false
        join(accounts: held, keptBy: nil) { [self] in joinedByCode += 1 }
    }

    /// Looks whether iCloud Keychain holds another account's key: another
    /// Mac on this Apple ID turned on by itself. Cheap to ask; what it does
    /// with a new answer at most once a minute.
    func lookForSeparate(now: Bool = false) {
        guard let seal, !joiningAccounts, !merging, !leaving, now || Date().timeIntervalSince(separateLooked) > 60 else { return }
        guard let other = sharedKey(), other.raw != seal.raw else {
            separate = nil
            keptApart = nil
            return
        }
        // An account left once stays left: a stale key from before a move.
        if Self.left.contains(other.account) {
            keepKey(seal)
            return
        }
        separateLooked = Date()
        AccountMove.peek(other, device: Self.device, base: Self.base, transport: pairingTransport ?? WebTransport()) { list in
            DispatchQueue.main.async { [self] in
                guard let mine = self.seal, mine.raw == seal.raw, let list else { return }
                // Nobody there: that account is over, ours goes back in iCloud.
                guard let first = list.max(by: { ($0.lastSeen ?? .distantPast) < ($1.lastSeen ?? .distantPast) }) else {
                    return keepKey(mine)
                }
                let found = Separate(account: other.account, name: first.name, seal: other, devices: list.count)
                if Self.kept.contains(other.account) {
                    separate = nil
                    keptApart = found
                    return
                }
                separate = found
                keptApart = nil
                tellSeparate(found)
            }
        }
    }

    /// Once for each account: nothing else says so unless Settings is open.
    private func tellSeparate(_ found: Separate) {
        var told = Store.settings.stringArray(forKey: Self.toldKey) ?? []
        guard !told.contains(found.account) else { return }
        told.append(found.account)
        Store.settings.set(told, forKey: Self.toldKey)
        primary?.announce("\(found.name) syncs separately", mark: "arrow.triangle.2.circlepath")
    }

    private static var kept: [String] { Store.settings.stringArray(forKey: keptKey) ?? [] }
    private static var left: [String] { Store.settings.stringArray(forKey: leftKey) ?? [] }

    func keepSeparate() {
        guard let found = separate else { return }
        Store.settings.set(Self.kept + [found.account], forKey: Self.keptKey)
        separate = nil
        keptApart = found
    }

    /// Join on the separate account's row.
    func joinSeparate() {
        guard let found = separate ?? keptApart else { return }
        Store.settings.set(Self.kept.filter { $0 != found.account }, forKey: Self.keptKey)
        join(accounts: found.seal, keptBy: found.devices) {}
    }

    /// The account with more devices stays, this Mac's when even: iCloud
    /// holds the newest key, so this one is the older. The other account's
    /// devices are told where to go and follow by themselves.
    private func join(accounts other: Seal, keptBy known: Int?, done: @escaping () -> Void) {
        guard let mine = seal, !joiningAccounts else { return }
        joiningAccounts = true
        func decide(_ there: Int) {
            let here = devices.count
            separate = nil
            keptApart = nil
            if here >= there { stay(mine, leaving: other, done: done) } else { go(to: other, leaving: mine, done: done) }
        }
        if let known { return decide(known) }
        AccountMove.peek(other, device: Self.device, base: Self.base, transport: pairingTransport ?? WebTransport()) { list in
            DispatchQueue.main.async { decide(list?.count ?? 0) }
        }
    }

    /// This account stays: the move goes into the other.
    private func stay(_ mine: Seal, leaving other: Seal, done: @escaping () -> Void) {
        keepKey(mine)
        Store.settings.set(Self.left + [other.account], forKey: Self.leftKey)
        AccountMove.leave(in: other, to: mine, device: Self.device, folder: Store.file("sync.sqlite").deletingLastPathComponent(),
                          base: Self.base, transport: pairingTransport ?? WebTransport()) { _ in
            DispatchQueue.main.async { [self] in
                joiningAccounts = false
                stopAsking()
                done()
            }
        }
    }

    /// The other stays: the move goes into this account, then this Mac.
    private func go(to other: Seal, leaving mine: Seal, done: @escaping () -> Void) {
        guard let journal else { return }
        _ = try? journal.change(Record.Key(collection: SyncCollection.moved, id: AccountMove.id), AccountMove.fields(to: other))
        client?.kick()
        let until = Date().addingTimeInterval(5)
        func wait() {
            let sent = !journal.pending().contains { $0.record.collection == SyncCollection.moved }
            guard sent || Date() > until else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: wait)
                return
            }
            move(to: other, leaving: mine) { [self] in
                joiningAccounts = false
                done()
            }
        }
        wait()
    }

    /// Out of this account and into another, this Mac's files as they are.
    private func move(to other: Seal, leaving mine: Seal, then done: @escaping () -> Void) {
        Store.settings.set(Self.left + [mine.account], forKey: Self.leftKey)
        turnOff(handOver: true) { [self] in
            join(other)
            done()
        }
    }

    /// Another device merged this account into another: this Mac follows.
    private func follow(_ destination: Seal) {
        guard let mine = seal, !joiningAccounts, !leaving, !Self.left.contains(destination.account) else { return }
        joiningAccounts = true
        move(to: destination, leaving: mine) { [self] in joiningAccounts = false }
    }

    /// This account's Recovery Key, for an eval to stand in for iCloud.
    var accountRecovery: String? { seal?.recovery }

    /// The account's address on the server, for evals to tell two Macs are
    /// in one account; nil while sync is off.
    var account: String? { seal?.account }

    /// The four digits this Mac shows while it waits under another Mac's code.
    var joiningCheck: String? {
        guard joiningInvited, let joining else { return nil }
        return JoinInvite.check(code: joining.code, publicKey: joining.publicKey)
    }

    /// On a Mac already in: a code of its own for an iPhone to scan or type
    /// (SyncInvite). Nil while sync is off here.
    func invite() -> SyncInvite? {
        guard seal != nil else { return nil }
        return SyncInvite(host: JoinInviteHost(base: Self.base))
    }

    /// The person said the digits match: the account's key goes to the
    /// device that posted under this Mac's code.
    func letIn(_ invite: SyncInvite, done: @escaping () -> Void) {
        guard let seal else { return }
        invite.letIn(seal, done: done)
    }

    /// On a Mac already in: the code another device shows.
    func approve(code: String, _ done: @escaping (Bool) -> Void) {
        guard let seal else { return done(false) }
        Pairing.answer(code: code, seal: seal, base: Self.base) { ok in
            DispatchQueue.main.async { done(ok) }
        }
    }

    /// Off on this Mac: the key and the journal go, Yab's files stay as
    /// they are. The other devices go on. `handOver`: the plugins this Mac
    /// ticked for the others are given up first, and the line stays open a
    /// moment for the others to hear it.
    func turnOff(everywhere: Bool = false, handOver: Bool = false, then done: (() -> Void)? = nil) {
        // Read before stop turns the client off and before an account's
        // deletion or a hand-over finishes: a Mac removed from the account
        // (refused) gives up its id, so it can join again (R7).
        let previousClient = client
        let previousState = state
        let previousDevice = previousClient?.device.id ?? Store.settings.string(forKey: "sync.device")
        let finish = { [self] in
            previousClient?.stop()
            // A finish that comes late must not forget a newer join's key,
            // token or journal.
            guard client === previousClient else { return }
            taskReader?.stop()
            taskReader = nil
            Bench.shared.remoteTaskReader = nil
            client = nil
            journal = nil
            seal = nil
            SyncKey.forget(everywhere: everywhere)
            SyncDeviceIdentity(settings: Store.settings).turnOff(after: previousState, device: previousDevice)
            for name in ["sync.sqlite", "sync.sqlite-wal", "sync.sqlite-shm"] {
                try? FileManager.default.removeItem(at: Store.file(name))
            }
            bag.removeAll()
            walletStamps = [:]
            walletSeen = []
            walletEpoch += 1
            walletChanges = -1
            mirror?.forget()
            mirror = nil
            leaving = false
            merging = false
            if let every = SharedPins.leftJoining(settings: Store.settings) {
                for browser in BrowserWindows.shared.browsers where browser.prefs.pinsEverySpace != every { browser.prefs.pinsEverySpace = every }
            }
            joiningAddons = [:]
            // Joining again adds this Mac's keys to the account's first.
            Store.settings.removeObject(forKey: SyncShapes.shortcutsSplit)
            SyncInstalls.shared.clear()
            on = false
            state = .off
            devices = []
            phoneFronts = [:]
            counts = [:]
            recovery = nil
        }
        let end = {
            finish()
            BoostServices.shared.reconcile()
            BoostContributions.reconcile()
            done?()
        }
        if everywhere, let client {
            client.deleteAccount { _ in DispatchQueue.main.async(execute: end) }
            return
        }
        // Handing over: the plugins this Mac ticks given up, nothing else
        // read or sent meanwhile, and the line kept until the server has
        // taken them (five seconds at most). One that never gets there is
        // taken over by the others once this Mac is away two days.
        guard handOver, let journal, let mirror, state == .live else { return end() }
        leaving = true
        dueWork?.cancel()
        let keys = Set(mirror.giveUp(journal, device: Self.deviceID))
        guard !keys.isEmpty else { return end() }
        client?.kick()
        let until = Date().addingTimeInterval(5)
        func wait() {
            let sent = !journal.pending().contains { keys.contains($0.record.key) }
            if sent || Date() > until || state != .live { return end() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: wait)
        }
        wait()
    }

    func refreshDevices() {
        guard let client else { return }
        client.devices { [weak client] list in
            DispatchQueue.main.async { [self] in
                guard let client, self.client === client, let list else { return }
                devices = list.filter { !$0.revoked }
                // A task that came before its phone was in the list.
                takeTasks()
                takeAssistantAnswers()
                takeForeignAssistantApprovals()
                mirror?.devices = SyncAddons.present(devices.map { (id: $0.id, seen: $0.lastSeen) })
                if let journal, !leaving, !merging, SyncAddons.on, !(mirror?.takeOver(journal, device: Self.deviceID).isEmpty ?? true) { client.kick() }
            }
        }
    }

    func remove(device id: String) {
        client?.remove(device: id) { _ in DispatchQueue.main.async { [self] in refreshDevices() } }
    }

    var thisDevice: String { Self.device.id }

    // MARK: Running

    private func begin(_ seal: Seal) {
        if let activateAccount {
            // The injected activation omits the client, not membership.
            self.seal = seal
            return activateAccount(self, seal)
        }
        joiningAddons = [:]
        guard let journal = try? Journal(path: Store.file("sync.sqlite").path, device: Self.device.id) else { return }
        ContextPrivacy.shared.attachSync(journal)
        // Steps removed before they went blank still hold their words:
        // cleared once (a full read of every step).
        if !UserDefaults.standard.bool(forKey: "syncBlankedSteps"), (try? journal.blankRemoved(SyncChats.item)) != nil {
            UserDefaults.standard.set(true, forKey: "syncBlankedSteps")
        }
        Vault.beginSync()
        self.seal = seal
        self.journal = journal
        if Store.settings.bool(forKey: SyncCategory.replayKey) { journal.cursor = 0 }
        let ledger = (try? Data(contentsOf: Self.ledgerFile)).flatMap { try? JSONDecoder().decode(SyncAddons.Ledger.self, from: $0) } ?? SyncAddons.Ledger()
        mirror = SyncMirror(extensions: Extensions.shared, plugins: Boosts.shared, ledger: ledger) { ledger in
            if let ledger, let data = try? JSONEncoder().encode(ledger) { try? data.write(to: Self.ledgerFile, options: .atomic) }
            else if ledger == nil { try? FileManager.default.removeItem(at: Self.ledgerFile) }
        }
        let client = SyncClient(base: Self.base, journal: journal, seal: seal, device: Self.device, token: SyncKey.token)
        client.setExcludedCollections(excludedCollections)
        // Merged in one step with no flush between: a save of this Mac's
        // files read back between taking records in and writing them into
        // the files would take records just come for ones removed here. So
        // the whole delivery holds `syncFlushing`, where flushes run: the
        // live rows are read on the main thread, the records taken into the
        // journal here, off it, and the files and windows changed on the
        // main thread again. A change made on the main thread meanwhile
        // only asks for a flush, which waits for this.
        client.deliver = { [weak self, weak client] items in
            let contextEpoch = ContextPrivacy.shared.epoch
            syncFlushing.sync {
                var asked: (journal: Journal, rows: [UUID]?, items: [(record: SyncKit.Record, version: Int64)])?
                DispatchQueue.main.sync {
                    let span = MainBudget.begin("sync.deliver"); defer { span?.end() }
                    guard let self, let client, self.client === client, let journal = self.journal else { return }
                    if let seal = self.seal, let there = AccountMove.destination(items.map(\.record), from: seal) {
                        DispatchQueue.main.async { self.follow(there) }
                    }
                    let items = items.filter { !self.excludedCollections.contains($0.record.collection) && $0.record.collection != SyncCollection.moved }
                    // A fresh journal does not return an already deleted
                    // incoming record as a change. It still removes a plugin
                    // kept locally from before this Mac left the account.
                    if self.merging, SyncAddons.on {
                        for (record, _) in items where SyncAddons.collections.contains(record.collection) {
                            self.joiningAddons[record.collection, default: []].insert(record.id)
                        }
                    }
                    var rows: [UUID]?
                    let rowKinds = [SyncShapes.tab, SyncShapes.folder, SyncShapes.pair]
                    if !self.merging, !self.leaving, items.contains(where: { rowKinds.contains($0.record.collection) }) {
                        // A local close may still await Session.written or its
                        // debounce. Publish the live row before a late title or
                        // position update can put that tab back into the window:
                        // asked to be written, the rows read back as they are now.
                        self.primary?.writeRows()
                        rows = Spaces.read().map(\.id)
                    }
                    asked = (journal, rows, items)
                }
                guard let asked else { return }
                let changed = MainBudget.chunk("sync.receive") {
                    try? Self.receive(asked.items, into: asked.journal, localRows: asked.rows.map { Self.rows($0) })
                }
                var fetched = changed.map { Self.fetch(for: $0, from: asked.journal) } ?? Fetched()
                fetched.contextEpoch = contextEpoch
                DispatchQueue.main.sync {
                    let span = MainBudget.begin("sync.deliver"); defer { span?.end() }
                    guard let self, let client, self.client === client, self.journal === asked.journal else { return }
                    if let changed, !changed.isEmpty, !self.leaving { self.adopt(changed, fetched: fetched) }
                    if asked.rows != nil { client.kick() }
                }
            }
        }
        client.stateChanged = { [weak self, weak client] state in
            DispatchQueue.main.async {
                guard let self, let client, self.client === client else { return }
                self.state = state
                if state == .live {
                    Store.settings.removeObject(forKey: SyncCategory.replayKey)
                    if let token = client.token, token != SyncKey.token { SyncKey.token = token }
                    self.refreshDevices()
                    self.lookForSeparate()
                    // Caught up after joining: the account's Pins, or In
                    // Each Space for an account from before the choice.
                    if let every = SharedPins.joined(settings: Store.settings) {
                        for browser in BrowserWindows.shared.browsers where browser.prefs.pinsEverySpace != every {
                            browser.prefs.pinsEverySpace = every
                        }
                    }
                    if self.merging {
                        self.merging = false
                        self.settleJoin()
                        // Read only now: what the account has came first, so
                        // a login on both sides is settled by when each changed.
                        self.changed(SyncWallet.login)
                        // A rejoining Mac may still have plugins it used
                        // to tick. Read their account owners only after
                        // catch-up, before writing any local addon values.
                        self.changed(SyncAddons.ext)
                        self.changed(SyncAddons.plugin)
                    }
                    // Words that came for this Mac while it was away.
                    self.takeSends()
                    // Tasks too, and what tasks did while the line was down.
                    self.takeTasks()
                    self.takeAssistantAnswers()
                    self.takeForeignAssistantApprovals()
                    self.taskReader?.resume()
                }
            }
        }
        // Which tab is in front here, for a phone's "On your Mac", and the
        // beat that tells the others this Mac is up.
        client.presence = { [weak self] in
            DispatchQueue.main.sync {
                let browser = BrowserWindows.shared.browsers.first { $0.windowID == nil }
                let front = browser?.active.flatMap { $0.shy ? nil : $0 }
                var fields: [String: Value] = ["name": .string(Self.device.name), "at": .number(Date().timeIntervalSince1970)]
                if self?.syncs(.tabs) == true, let front, let url = front.address?.absoluteString {
                    fields["url"] = .string(url)
                    fields["title"] = .string(front.title)
                    fields["tab"] = .string(front.id.uuidString)
                    if let leftAt = self?.leftAt, leftAt.tab == front.id { fields["scroll"] = .number(leftAt.scroll) }
                }
                if self?.sleeping == true {
                    fields["asleep"] = .bool(true)
                    // Which it is, for the phone's words: the Mac asleep, or Yab quit.
                    fields["why"] = .string(self?.quitting == true ? "quit" : "sleep")
                }
                return SyncKit.Record(collection: "presence", id: Self.deviceID, fields: fields)
            }
        }
        // An iPhone's page in front, for the field's From iPhone (SyncPhone).
        client.heardPresence = { [weak self, weak client] device, record in
            DispatchQueue.main.async {
                guard let self, let client, self.client === client else { return }
                self.heardPresence(device, record)
            }
        }
        self.client = client
        let reader = SyncTaskRead(agents: Agents.shared) { [weak self] in
            guard let self, let client = self.client, let browser = self.primary else { return nil }
            return SyncTaskRead.Context(client: client, phones: self.devices, browser: browser)
        }
        taskReader = reader
        Bench.shared.remoteTaskReader = reader
        on = true
        watch()
        // Everything as it stands, told to the journal before the line
        // opens: the first hello then sends this Mac's side and brings the
        // account's, and the two are put together field by field.
        for collection in [SyncShapes.space, SyncShapes.tab, SyncShapes.bookmark, SyncShapes.setting, SyncShapes.file, SyncShapes.icon, SyncShapes.routine, SyncShapes.memory, SyncShapes.visit, SyncShapes.answer, SyncChats.chat, SyncWallet.login, SyncAddons.ext, SyncAddons.plugin, SyncNow.now, SyncShapes.project] { due.insert(collection) }
        flush(after: { [weak self] _ in self?.drawUnshown() })
        client.start()
    }

    /// What the journal holds and the rows never drew (Journal.unshown):
    /// a relaunch between a delivery's merge and its rows, the update's
    /// among them, left those records in the journal only, and the line
    /// brings them again unchanged, so nothing else would draw them.
    private func drawUnshown() {
        guard let journal, syncs(.tabs), !leaving else { return }
        syncFlushing.async { [weak self] in
            let records = [SyncShapes.tab, SyncShapes.folder, SyncShapes.pair].flatMap { journal.unshown($0) }
            guard !records.isEmpty else { return }
            let fetched = Self.fetch(for: records, from: journal)
            DispatchQueue.main.sync {
                guard let self, self.journal === journal, !self.leaving else { return }
                self.adopt(records, fetched: fetched)
            }
        }
    }

    private func watch() {
        bag.removeAll()
        NotificationCenter.default.publisher(for: Spaces.changed)
            .sink { [weak self] _ in self?.changed(SyncShapes.space) }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: Session.written)
            .sink { [weak self] _ in self?.changed(SyncShapes.tab) }
            .store(in: &bag)
        // A chat moves with every step its agent takes: up within a second.
        Chats.shared.$all.dropFirst()
            .sink { [weak self] _ in self?.changed(SyncChats.chat) }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: Routines.changed)
            .sink { [weak self] _ in self?.changed(SyncShapes.routine) }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: Projects.changed)
            .sink { [weak self] _ in self?.changed(SyncShapes.project) }
            .store(in: &bag)
        // Now's mail rows, for the iPhone's Now widget: only when they change.
        Hints.shared.$rows
            .map { SyncNow.rows($0, message: { _, _ in "" }) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.changed(SyncNow.now) }
            .store(in: &bag)
        Bookmarks.shared.$roots
            .dropFirst()
            .sink { [weak self] _ in self?.changed(SyncShapes.bookmark) }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.changed(SyncShapes.setting) }
            .store(in: &bag)
        Extensions.shared.$installed.dropFirst()
            .sink { [weak self] _ in self?.changed(SyncAddons.ext) }
            .store(in: &bag)
        Boosts.shared.$records.dropFirst()
            .sink { [weak self] _ in self?.changed(SyncAddons.plugin) }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: BoostStorage.changed)
            .sink { [weak self] _ in self?.changed(SyncAddons.plugin) }
            .store(in: &bag)
        // The keychain says nothing when it changes; Yab counts its own
        // writes, and a count that moved is read again.
        Timer.publish(every: 2, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self, Vault.changes != self.walletChanges else { return }
                self.changed(SyncWallet.login)
            }
            .store(in: &bag)
        // A live line may stay open for days. Refresh the device list so
        // a Mac that left without a handover can age out and its plugins
        // be taken over without a reconnect or opening Settings.
        Timer.publish(every: 300, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self, self.state == .live, !self.leaving else { return }
                self.refreshDevices()
            }
            .store(in: &bag)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                // Up again: said now, not at the next beat (a line still up
                // after a short sleep says nothing by itself).
                self?.sleeping = false
                self?.client?.start()
                self?.client?.sayPresence()
            }
            .store(in: &bag)
        // The person leaving this Mac: Yab to the back, the screen locked,
        // the Mac to sleep, Yab quitting. Where the front tab stands goes to
        // the others then, with how far down it is, so a phone opens it at
        // the same place (R9); asleep is said as the Mac goes.
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.sayWhereIAm() }
            .store(in: &bag)
        DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .sink { [weak self] _ in self?.sayWhereIAm() }
            .store(in: &bag)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.sayWhereIAm(asleep: true) }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.sleeping = true
                self?.quitting = true
                self?.client?.sayPresence()
            }
            .store(in: &bag)
        // Another tab in front here: "Mac" moves on the phone with it.
        if let main = BrowserWindows.shared.browsers.first(where: { $0.windowID == nil }) {
            main.changes(\.activeID).removeDuplicates().dropFirst()
                .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.client?.sayPresence() }
                .store(in: &bag)
        }
        // The small files have no word of their own when they change: read
        // every half minute, which costs a few kilobytes of reading.
        Timer.publish(every: 30, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                self?.changed(SyncShapes.file)
                self?.changed(SyncShapes.answer)
                self?.changed(SyncShapes.icon)
                self?.changed(SyncShapes.memory)
                self?.changed(SyncShapes.visit)
                self?.changed(SyncChats.chat)
            }
            .store(in: &bag)
    }

    /// The front tab's place on its page, read, then said with the presence;
    /// said at once too, in case the page doesn't answer before the Mac sleeps.
    private func sayWhereIAm(asleep: Bool = false) {
        if asleep { sleeping = true }
        guard let client else { return }
        client.sayPresence()
        let browser = BrowserWindows.shared.browsers.first { $0.windowID == nil }
        guard let front = browser?.active, !front.shy, let page = front.builtPage else { return }
        let id = front.id
        page.runInYab(Self.scrollScript) { [weak self] value in
            MainActor.assumeIsolated {
                guard let self, let fraction = (value as? NSNumber)?.doubleValue else { return }
                self.leftAt = (id, min(1, max(0, fraction)))
                client.sayPresence()
            }
        }
    }

    /// How far down the page, or its scrolling part, is: 0 at the top, 1 at the end.
    private static let scrollScript = """
    (function () {
      var e = document.scrollingElement || document.documentElement, m = e.scrollHeight - innerHeight;
      if (m > 2) return e.scrollTop / m;
      var all = document.querySelectorAll('*');
      for (var i = 0; i < all.length && i < 4000; i++) {
        var n = all[i], s = getComputedStyle(n).overflowY;
        if ((s === 'auto' || s === 'scroll') && n.scrollHeight - n.clientHeight > 2) return n.scrollTop / (n.scrollHeight - n.clientHeight);
      }
      return 0;
    })()
    """

    /// What this Mac takes from the iPhone changed (Open at Login turned on
    /// or off): its `commandcap` record goes up with the next flush.
    func capabilityChanged() { changed(SyncChats.chat) }

    /// Everything read again and sent now, not on the half minute (bench).
    /// `done` once the journal has been told, on the main thread.
    func flushNow(then done: (@MainActor () -> Void)? = nil) {
        for collection in [SyncShapes.file, SyncShapes.answer, SyncShapes.icon, SyncShapes.memory, SyncShapes.visit, SyncChats.chat, SyncShapes.tab, SyncWallet.login, SyncAddons.ext, SyncAddons.plugin, SyncNow.now] { due.insert(collection) }
        flush(then: done)
    }

    private func changed(_ collection: String) {
        guard on, !applying, !leaving else { return }
        due.insert(collection)
        dueWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        dueWork = work
        // A row reaches the other devices in a moment (R8: a phone shows the
        // Mac's new tab well within 300 ms); the rest is gathered for 0.3 s.
        let wait = due == [SyncShapes.tab] ? 0.02 : 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// What Yab's files say now, told to the journal; what differs goes up.
    /// What only the main thread may read (the windows' rows, bookmarks,
    /// routines, history, chats) is read there; the rest, reading the
    /// memory folder and the small files, comparing each collection with
    /// the journal and writing what changed, on `syncFlushing`. A delivery
    /// holds that queue while it merges on the main thread (deliver), so a
    /// merge never falls between what a flush read and what it tells the
    /// journal, as when both were the main thread's in one step.
    private func flush(then done: (@MainActor () -> Void)? = nil, after: (@MainActor (Bool) -> Void)? = nil) {
        let span = MainBudget.begin("sync.flush"); defer { span?.end() }
        guard let journal, !leaving else { done?(); after?(false); return }
        let collections = SyncAddons.due(due)
        due = []
        syncFlushing.async { [weak self] in
            var read: Flush?
            DispatchQueue.main.sync {
                guard let self, self.journal === journal, !self.leaving else { return }
                let span = MainBudget.begin("sync.flush.read"); defer { span?.end() }
                read = self.read(collections)
            }
            guard let read else {
                DispatchQueue.main.async { done?(); after?(false) }
                return
            }
            let failed: Error?
            do {
                try MainBudget.chunk("sync.flush.tell") { try Self.tell(read, into: journal) }
                failed = read.failed
            } catch {
                failed = error
            }
            if let failed { NSLog("sync: %@", String(describing: failed)) }
            DispatchQueue.main.async { [weak self] in
                defer { done?() }
                guard let self, self.journal === journal, !self.leaving else { after?(false); return }
                self.flushed(collections, journal: journal, failed: failed != nil)
                after?(failed == nil)
            }
        }
    }

    /// What a flush took from the main thread, for `tell`.
    struct Flush: @unchecked Sendable {
        var collections: Set<String>
        var spaces: [Space]?
        /// The spaces whose rows go; the rows are read with the journal work.
        var rows: [UUID]?
        var bookmarks: [Bookmark]?
        var settings: [String: Any]?
        var addons = false
        var routines: [Routine]?
        /// The projects of chats (SyncShapes.projects).
        var projects: [Project]?
        var device = ""
        var visits: [Visit]?
        /// Places deleted here by hand since the last flush (History.cuts).
        var cuts: [String: Date] = [:]
        /// Now's mail rows, this Mac's (SyncNow).
        var now: [SyncNow.Row]?
        /// The chats were told to the journal on the main thread; this is
        /// what went wrong there, which stops what comes after them.
        var failed: Error?
    }

    private func read(_ collections: Set<String>) -> Flush {
        let chatsRequested = collections.contains(SyncChats.chat)
        let collections = collections.subtracting(excludedCollections)
        var read = Flush(collections: collections)
        if collections.contains(SyncShapes.space) { read.spaces = Spaces.read() }
        if collections.contains(SyncShapes.tab) { read.rows = Spaces.read().map(\.id) }
        if collections.contains(SyncShapes.bookmark) { read.bookmarks = Bookmarks.shared.roots }
        if collections.contains(SyncShapes.setting) {
            read.settings = Store.settings.dictionaryRepresentation()
            read.addons = SyncAddons.on
        }
        if collections.contains(SyncShapes.routine) {
            read.routines = Routines.shared.all
            read.device = Self.deviceID
        }
        if collections.contains(SyncShapes.project) { read.projects = Projects.shared.all }
        if collections.contains(SyncShapes.visit) {
            read.visits = history ? History.shared.visits(since: Date().addingTimeInterval(-SyncShapes.historyDays)) : []
            let cuts = History.shared.takeCuts()
            if history { read.cuts = cuts }
        }
        if collections.contains(SyncNow.now) {
            read.now = SyncNow.rows(Hints.shared.rows) { MailCenter.shared.lastMessageID(account: $0, thread: $1) }
            read.device = Self.deviceID
        }
        if chatsRequested {
            do { try flushChats() } catch { read.failed = error }
        }
        return read
    }

    /// The collections told to the journal in the order they always were;
    /// the first that fails stops the rest.
    nonisolated static func tell(_ read: Flush, into journal: Journal) throws {
        let collections = read.collections
        if let spaces = read.spaces {
            try journal.reconcile(SyncShapes.space, SyncShapes.spaces(spaces, orders: orders(SyncShapes.space, in: journal)))
        }
        if let spaces = read.rows { try reconcileRows(rows(spaces), into: journal, device: deviceID) }
        if let bookmarks = read.bookmarks {
            try journal.reconcile(SyncShapes.bookmark, SyncShapes.bookmarks(bookmarks, orders: orders(SyncShapes.bookmark, in: journal)))
        }
        if let settings = read.settings, let keys = try SyncShapes.reconcileSettings(journal, settings, addons: read.addons) {
            DispatchQueue.main.async { Self.takeShortcuts(keys, split: true) }
        }
        if let routines = read.routines { try SyncShapes.reconcileRoutines(journal, routines, device: read.device) }
        if let projects = read.projects { try journal.reconcile(SyncShapes.project, SyncShapes.projects(projects)) }
        if let visits = read.visits {
            do {
                try SyncShapes.tellVisits(visits, cuts: read.cuts, into: journal)
            } catch {
                // Deleted by hand and not told: told with the next flush.
                let cuts = read.cuts
                if !cuts.isEmpty { DispatchQueue.main.async { MainActor.assumeIsolated { History.shared.keepCuts(cuts) } } }
                throw error
            }
        }
        if let now = read.now { try SyncNow.reconcile(journal, now, device: read.device) }
        if read.failed != nil { return }
        if collections.contains(SyncShapes.memory) {
            try journal.reconcile(SyncShapes.memory, SyncShapes.memory(in: Memory.folder))
        }
        if collections.contains(SyncShapes.file) {
            try journal.reconcile(SyncShapes.file, SyncShapes.files(in: Store.folder))
        }
        if collections.contains(SyncShapes.icon) {
            try journal.reconcile(SyncShapes.icon, SyncShapes.icons(in: Store.folder))
        }
        if collections.contains(SyncShapes.answer) {
            try journal.reconcile(SyncShapes.answer, SyncShapes.answers(FormAnswers.load().said))
        }
    }

    /// Back on the main thread once the journal is told: the wallet,
    /// extensions and plugins, then the counts and the push.
    /// The keys as the account has them, one an action, kept and taken
    /// at once; `split` marks this Mac as sending them that way from now.
    private static func takeShortcuts(_ keys: [String: String], split: Bool) {
        if keys.isEmpty {
            Store.settings.removeObject(forKey: SyncShapes.shortcutsKey)
        } else {
            Store.settings.set(keys, forKey: SyncShapes.shortcutsKey)
        }
        if split { Store.settings.set(true, forKey: SyncShapes.shortcutsSplit) }
        Keymap.shared.adoptStored()
    }

    private func flushed(_ collections: Set<String>, journal: Journal, failed: Bool) {
        if !failed {
            do {
                if collections.contains(SyncWallet.login) {
                    flushWallet()
                }
                if !merging, collections.contains(SyncAddons.ext) {
                    let changed = joiningAddons.removeValue(forKey: SyncAddons.ext) ?? []
                    try takeExtensions(journal, changed: changed.compactMap { journal.record(.init(collection: SyncAddons.ext, id: $0)) })
                }
                if !merging, collections.contains(SyncAddons.plugin) {
                    let changed = joiningAddons.removeValue(forKey: SyncAddons.plugin) ?? []
                    let parts = joiningAddons.removeValue(forKey: SyncAddons.part) ?? []
                    try takePlugins(journal, changed: changed.compactMap { journal.record(.init(collection: SyncAddons.plugin, id: $0)) },
                                    parts: parts.compactMap { journal.record(.init(collection: SyncAddons.part, id: $0)) })
                }
            } catch {
                NSLog("sync: %@", String(describing: error))
            }
        }
        recount()
        client?.kick()
    }

    /// Each space's row as its file has it, or as last asked to be written
    /// (Session.read), on any thread.
    nonisolated private static func rows(_ spaces: [UUID]) -> [UUID: Session.Shape] {
        // The shared pins go as the first space's (SharedPins.syncRow).
        var rows = Dictionary(spaces.map { ($0, SharedPins.syncRow($0)) }, uniquingKeysWith: { first, _ in first })
        // Personal can be gone while the shared pins still exist. Keep
        // their sync parent, without reviving Personal's old tabs or space.
        if rows[Space.firstID] == nil {
            let pins = Session.read(space: Space.pinsID)
            rows[Space.firstID] = SharedPins.folded(pins.tabs, into: .init(tabs: [], front: nil), pinPairs: pins.pairs)
        }
        return rows
    }

    nonisolated private static func reconcileRows(_ rows: [UUID: Session.Shape], into journal: Journal, device: String) throws {
        let every = journal.all(SyncShapes.tab)
        let living = every.filter { $0.alive() }
        let orders = Self.previousOrders(rows, journal: Dictionary(living.compactMap { record in
            record["order"]?.string.map { (record.id, $0) }
        }, uniquingKeysWith: { first, _ in first }), shown: journal.shown(SyncShapes.tab).compactMapValues { $0["order"]?.string })
        // Today is each device's own: this Mac's tabs of today are written
        // as its own, and another device's are never closed for missing here.
        let marked = SyncShapes.marked
        var out = SyncShapes.rows(rows, orders: orders, device: device, owner: SyncShapes.owners(living, marked: marked))
        // Catch-up pages go by sequence too: a folder opened, renamed or
        // moved since its tabs were written comes pages after them, and a
        // folder can come before the folder it is in. A row draws a folder
        // only from its record, so until that comes it shows its tabs
        // loose. That is no move out of it: a link to a folder this journal
        // has never held stays, and a folder nothing here names yet was
        // never drawn here, so it isn't removed for missing from the rows.
        // A fresh Mac's first sync took every tab whose folder came late
        // out of it, and those folders away, on every device (row 1895).
        let folders = journal.all(SyncShapes.folder)
        let held = Set(folders.map(\.id))
        let livingFolders = folders.filter { $0.alive() }
        out.tabs = SyncShapes.keepingLinks(out.tabs, had: living, held: held)
        out.folders = SyncShapes.keepingLinks(out.folders, had: livingFolders, held: held)
        let named = Set((living + livingFolders).compactMap { $0["folder"]?.string })
        // Nor a pair whose other tab hasn't come yet.
        let heldTabs = Set(every.map(\.id))
        // Nor one whose tabs, as this Mac last took them in, stand in
        // another space than it does: a split view moved a record at a
        // time (PhoneSync.move, or a page between them) can't be drawn
        // until its tabs and it are in one space again, and a removal
        // here would win over the pair's own move when it came.
        let standing = Dictionary(living.compactMap { record in record["parent"]?.string.map { (record.id, $0) } },
                                  uniquingKeysWith: { first, _ in first })
        func apart(_ pair: SyncKit.Record, _ ids: [String]) -> Bool {
            let space = pair["parent"]?.string
            return ids.allSatisfy { standing[$0] != nil } && ids.contains { standing[$0] != space }
        }
        // Catch-up pages are ordered by sequence. A space renamed after its
        // tabs can arrive in a later page: absence from local rows is not a
        // close until this Mac has received that space. Tombstones count as
        // known, so deleting a space still removes its rows.
        let represented = Set(rows.keys.map(\.uuidString))
        let spaceRecords = journal.all(SyncShapes.space)
        let knownSpaces = Set(spaceRecords.map(\.id))
        let goneSpaces = Set(spaceRecords.filter { !$0.alive() }.map(\.id)).subtracting(represented)
        func awaitingSpace(_ record: SyncKit.Record) -> Bool {
            guard let parent = record["parent"]?.string else { return false }
            return !represented.contains(parent) && !knownSpaces.contains(parent)
        }
        // A space removed takes what was in it, drawn here or not.
        func orphaned(_ record: SyncKit.Record) -> Bool {
            record["parent"]?.string.map(goneSpaces.contains) ?? false
        }
        // Three-way (Journal.reconcile's `shown`): only what these files
        // changed since they were last read goes up, so rows that haven't
        // drawn what the journal already holds are no edit (register 2589).
        try journal.reconcile(SyncShapes.tab, out.tabs, within: {
            !awaitingSpace($0) && !SyncShapes.elsewhere($0, device: device, marked: marked)
        }, shown: true, orphaned: orphaned)
        // Nor the folders and pairs of those tabs: another Mac's folder of
        // today's tabs, or two of its tabs side by side, are never in this
        // Mac's rows, and removing them for it broke that Mac's (row 965).
        let away = living.filter { SyncShapes.elsewhere($0, device: device, marked: marked) }
        let awayIDs = Set(away.map(\.id)), awayFolders = Set(away.compactMap { $0["folder"]?.string })
        try journal.reconcile(SyncShapes.folder, out.folders, within: {
            !awaitingSpace($0) && !awayFolders.contains($0.id) && named.contains($0.id)
        }, shown: true, orphaned: orphaned)
        try journal.reconcile(SyncShapes.pair, out.pairs, within: { pair in
            let ids = pair.id.split(separator: "|").map(String.init)
            return !awaitingSpace(pair) && !ids.contains(where: awayIDs.contains) && ids.allSatisfy(heldTabs.contains)
                && (!apart(pair, ids) || orphaned(pair))
        }, shown: true, orphaned: orphaned)
    }

    /// The keys a row's tabs are written from. A row in the journal's order
    /// (drawn from it, or moved here to the same) takes the journal's keys;
    /// one that isn't still stands as its files last said, so it takes the
    /// keys they were written with: a row that didn't move gives the same
    /// keys back, and only a move made here gives new ones. The journal's
    /// keys laid over an old row made every tab the other Mac moved look
    /// moved here, and the old order went up as now's (register 2589).
    nonisolated static func previousOrders(_ rows: [UUID: Session.Shape], journal: [String: String], shown: [String: String]) -> [String: String] {
        var out = journal
        for shape in rows.values {
            let ids = shape.tabs.compactMap(\.id)
            let keyed = ids.filter { journal[$0] != nil }
            let inOrder = keyed == keyed.sorted { (journal[$0]!, $0) < (journal[$1]!, $1) }
            if inOrder { continue }
            for id in ids { if let key = shown[id] { out[id] = key } }
        }
        return out
    }

    /// Local row mutations and incoming records meet in this main-thread
    /// turn. Joining passes nil, so the account arrives before local rows.
    /// `device`: this Mac's id; a test passes another to be a second Mac.
    nonisolated static func receive(_ items: [(record: SyncKit.Record, version: Int64)], into journal: Journal,
                        localRows: [UUID: Session.Shape]?, device: String = deviceID) throws -> [SyncKit.Record] {
        if let localRows { try reconcileRows(localRows, into: journal, device: device) }
        // Tabs another device opens without saying whose (an iPhone from
        // before Today was each device's) are that device's: marked before
        // the journal takes them in, while they are still new to it.
        let marked = SyncShapes.marked
        let now = SyncShapes.mark(items.map(\.record), in: journal, device: device, marked: marked)
        if now != marked { SyncShapes.marked = now }
        return try journal.receive(items)
    }

    /// The keychain read off the main thread, and what it found told to
    /// the journal here, where records from elsewhere are taken in too.
    private func flushWallet() {
        guard SyncWallet.on, !merging, let journal, let seal else { return }
        let epoch = walletEpoch, stamps = walletStamps, seen = walletSeen
        walletChanges = Vault.changes
        walletQueue.async { [weak self] in
            guard let read = SyncWallet.read(journal: journal, seal: seal, stamps: stamps, seen: seen) else { return }
            DispatchQueue.main.async {
                guard let self, self.journal === journal else { return }
                guard self.walletEpoch == epoch else {
                    read.touched.forEach(Vault.again)
                    return self.changed(SyncWallet.login)
                }
                self.walletStamps = read.stamps
                self.walletSeen = read.seen
                do {
                    for collection in SyncWallet.collections where read.differs.contains(collection) {
                        try journal.reconcile(collection, read.now[collection] ?? [:])
                    }
                    Vault.published(read.published)
                } catch {
                    NSLog("sync: %@", String(describing: error))
                }
                self.walletRead?()
                if !read.writes.isEmpty { self.takeWallet(read.writes) }
                self.recount()
                self.client?.kick()
            }
        }
    }

    /// Records into the keychain, then read back once they are in.
    private func takeWallet(_ records: [SyncKit.Record], contextEpoch: String = ContextPrivacy.shared.epoch) {
        guard SyncWallet.on, let seal else { return }
        walletEpoch += 1
        walletQueue.async {
            // Nothing written in and nothing here newer: nothing to read back.
            guard SyncWallet.write(records, seal: seal, contextEpoch: contextEpoch) else { return }
            DispatchQueue.main.async { [weak self] in self?.changed(SyncWallet.login) }
        }
    }

    /// The bench's: told in the main-thread turn a read of the keychain
    /// reached the journal (evals/sync/check.py changes a password in the
    /// very second sync wrote its record).
    var walletRead: (() -> Void)?

    /// The bench's: the keychain's queue held, as on a Mac too busy to
    /// write in what came, until let go or `seconds` passed
    /// (evals/sync/check.py).
    private var walletHold: DispatchSemaphore?
    func holdWallet(seconds: Double) {
        releaseWallet()
        let hold = DispatchSemaphore(value: 0)
        walletHold = hold
        walletQueue.async { _ = hold.wait(timeout: .now() + seconds) }
    }

    func releaseWallet() {
        walletHold?.signal()
        walletHold = nil
    }

    private func orders(_ collection: String) -> [String: String] {
        journal.map { Self.orders(collection, in: $0) } ?? [:]
    }

    nonisolated private static func orders(_ collection: String, in journal: Journal) -> [String: String] {
        var out: [String: String] = [:]
        for record in journal.living(collection) {
            if let order = record["order"]?.string { out[record.id] = order }
        }
        return out
    }

    /// Settings › Sync on screen, saying how many of each there are. The
    /// numbers are counted only then: counting reads and decodes nearly the
    /// whole journal, 130 ms for one of 5,100 records (evals/sync-cost), and
    /// it was done on the main thread after every flush, a tab picked, an
    /// agent's step, a setting; on a Mac under load such reads held the
    /// window for seconds (stalls.log, 2026-10-08).
    func showCounts(_ shown: Bool) {
        countsShown = max(0, countsShown + (shown ? 1 : -1))
        if shown { recount() }
    }

    /// The numbers now, counted here and kept, for the bench.
    func countsNow() -> [String: Int] {
        guard let journal else { return counts }
        counts = Self.count(journal, extensions: mirror?.count ?? 0)
        return counts
    }

    /// Counted on a queue of their own while Settings › Sync shows them;
    /// asked again while counting, counted once more after.
    private func recount() {
        guard let journal, countsShown > 0 else { return }
        if counting {
            countAgain = true
            return
        }
        counting = true
        let extensions = mirror?.count ?? 0
        countQueue.async { [weak self] in
            let counted = Self.count(journal, extensions: extensions)
            DispatchQueue.main.async {
                guard let self else { return }
                self.counting = false
                if self.journal === journal { self.counts = counted }
                if self.countAgain {
                    self.countAgain = false
                    self.recount()
                }
            }
        }
    }

    nonisolated private static func count(_ journal: Journal, extensions: Int) -> [String: Int] {
        [
            SyncShapes.space: journal.living(SyncShapes.space).count,
            SyncShapes.tab: journal.living(SyncShapes.tab).count,
            SyncShapes.bookmark: journal.living(SyncShapes.bookmark).filter { $0["url"] != nil }.count,
            SyncShapes.setting: journal.living(SyncShapes.setting).count,
            SyncShapes.file: journal.living(SyncShapes.file).count + journal.living(SyncShapes.icon).count + journal.living(SyncShapes.answer).count,
            SyncShapes.routine: journal.living(SyncShapes.routine).count,
            SyncShapes.visit: journal.living(SyncShapes.visit).count,
            SyncChats.chat: journal.living(SyncChats.chat).count,
            SyncShapes.memory: Set(journal.living(SyncShapes.memory).map { $0["day"]?.string ?? $0.id }).count,
            SyncWallet.login: journal.living(SyncWallet.login).count,
            SyncWallet.card: journal.living(SyncWallet.card).count + journal.living(SyncWallet.address).count,
            SyncAddons.ext: extensions,
        ]
    }

    // MARK: Extensions and plugins

    /// Extensions: one read of the mirror, from a flush or from records that
    /// came in; what waits to be put in, to SyncInstalls.
    private func takeExtensions(_ journal: Journal, changed: [SyncKit.Record] = []) throws {
        guard let mirror else { return }
        let missing = try mirror.extensions(journal, changed: Set(changed.map(\.id)))
        SyncInstalls.shared.want(SyncAddons.ext, missing)
    }

    /// Plugins and their parts, likewise. Parts are taken back only once
    /// the line is live: a Mac still catching up hasn't every record yet.
    private func takePlugins(_ journal: Journal, changed: [SyncKit.Record] = [], parts: [SyncKit.Record] = []) throws {
        guard let mirror else { return }
        let missing = try mirror.plugins(journal, device: Self.deviceID, live: state == .live,
                                         changed: Set(changed.map(\.id)), parts: Set(parts.map(\.id)))
        SyncInstalls.shared.want(SyncAddons.plugin, missing, parts: !parts.isEmpty)
    }

    /// What keeps one of the small files in memory, told it changed.
    private static func reread(_ paths: Set<String>) {
        let browsers = BrowserWindows.shared.browsers
        if paths.contains("scopes.json") { Scopes.reload() }
        if paths.contains("quick-actions.json") { QuickActions.shared.reload() }
        if paths.contains("short-names.json") { ShortNames.shared.reload() }
        if paths.contains("hidden.json") { Curtain.shared.reload() }
        if paths.contains("commands.json") { for browser in browsers { browser.selectionCommands.load() } }
        if paths.contains("mail/snippets.noindex/snippets.json") { MailSnippets.shared.load() }
    }

    // MARK: Joining

    /// The same page pinned or kept in the same space on both sides, the
    /// same bookmark in the same folder: one of each stays, the one with
    /// the lower id, so both sides keep the same one.
    private func settleJoin() {
        guard let journal else { return }
        var gone: [SyncKit.Record.Key] = []
        let tabs = syncs(.tabs) ? journal.living(SyncShapes.tab).filter { $0["pin"] != nil || $0["kept"]?.bool == true } : []
        for (_, twins) in Dictionary(grouping: tabs, by: { "\($0["parent"]?.string ?? "")|\($0["url"]?.string ?? "")" }) where twins.count > 1 {
            gone += twins.sorted { $0.id < $1.id }.dropFirst().map(\.key)
        }
        let marks = syncs(.bookmarks) ? journal.living(SyncShapes.bookmark) : []
        let titles = Dictionary(marks.map { ($0.id, $0["title"]?.string ?? "") }, uniquingKeysWith: { a, _ in a })
        for (_, twins) in Dictionary(grouping: marks, by: { record -> String in
            // A folder by its name, a page by its address, each under its
            // folder's name, so two bars of the same folders meet.
            let parent = record["parent"]?.string ?? ""
            let under = parent == SyncShapes.root ? parent : titles[parent] ?? parent
            return "\(under)|\(record["url"]?.string ?? "folder:" + (record["title"]?.string ?? ""))"
        }) where twins.count > 1 {
            let keep = twins.min { $0.id < $1.id }!
            for twin in twins where twin.id != keep.id {
                // A folder's children follow the one that stays.
                for child in marks where child["parent"]?.string == twin.id {
                    try? journal.change(child.key, ["parent": .string(keep.id), "order": child["order"] ?? .null])
                }
                gone.append(twin.key)
            }
        }
        guard !gone.isEmpty else { return }
        for key in gone { try? journal.remove(key) }
        adopt(gone.compactMap { journal.record($0) } + journal.living(SyncShapes.bookmark))
        client?.kick()
    }

    /// Spaces, rows and bookmarks as they were before joining.
    private static var snapshots: URL { Store.folder.appendingPathComponent("Sync Snapshot", isDirectory: true) }

    private static func snapshot() {
        Session.settle()
        let manager = FileManager.default
        try? manager.removeItem(at: snapshots)
        try? manager.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let names = ((try? manager.contentsOfDirectory(atPath: Store.folder.path)) ?? [])
            .filter { $0 == "spaces.json" || $0 == "bookmarks.json" || ($0.hasPrefix("session") && $0.hasSuffix(".json") && !$0.hasPrefix("session-window-")) }
        for name in names {
            try? manager.copyItem(at: Store.folder.appendingPathComponent(name), to: snapshots.appendingPathComponent(name))
        }
        Store.settings.set(Date().timeIntervalSince1970, forKey: "sync.snapshot")
    }

    /// Undo Joining is offered for a week after.
    var canUndoJoining: Bool {
        let at = Store.settings.double(forKey: "sync.snapshot")
        return at > 0 && Date().timeIntervalSince1970 - at < 7 * 86_400 && FileManager.default.fileExists(atPath: Self.snapshots.path)
    }

    /// Sync off on this Mac and its spaces, tabs and bookmarks as they were
    /// before it joined. The other devices keep what the account has.
    func undoJoining() {
        guard canUndoJoining else { return }
        // What sync put in since joining goes too, once sync is off here:
        // nothing of the account's left on, running here.
        let installed = mirror?.ledger.installed ?? []
        turnOff(handOver: true) {
            for key in installed {
                let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                if parts[0] == SyncAddons.ext { Extensions.shared.remove(parts[1]) }
                if parts[0] == SyncAddons.plugin { Boosts.shared.removeSynced(parts[1]) }
            }
        }
        let folder = Self.snapshots
        if let data = try? Data(contentsOf: folder.appendingPathComponent("spaces.json")),
           let spaces = try? JSONDecoder().decode([Space].self, from: data) {
            let now = Set(Spaces.read().map(\.id))
            for id in now where !spaces.contains(where: { $0.id == id }) { primary?.deleteSpace(id) }
            Spaces.write(spaces)
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("bookmarks.json")),
           let tree = try? JSONDecoder().decode([Bookmark].self, from: data) {
            Bookmarks.shared.adopt(tree)
        }
        for space in Spaces.read() {
            let name = space.isFirst ? "session.json" : "session-\(space.id.uuidString).json"
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let shape = try? JSONDecoder().decode(Session.Shape.self, from: data) else { continue }
            if let primary { primary.adopt(shape, in: space.id) } else { Session.write(now: true, space: space.id, shape) }
        }
        try? FileManager.default.removeItem(at: folder)
        Store.settings.removeObject(forKey: "sync.snapshot")
    }

    // MARK: Coming in

    private var primary: Browser? { BrowserWindows.shared.browsers.first { $0.windowID == nil } }

    /// The collections a delivery's records touch, read whole from the
    /// journal off the main thread before `adopt` runs on it (deliver).
    /// Nothing else writes those collections in between: flushes wait for
    /// the delivery, and the records came in just before.
    struct Fetched: @unchecked Sendable {
        var contextEpoch = ContextPrivacy.shared.epoch
        var spaces: [SyncKit.Record]?
        var tabs: [SyncKit.Record]?
        var folders: [SyncKit.Record]?
        var pairs: [SyncKit.Record]?
        var bookmarks: [SyncKit.Record]?
        var answers: [SyncKit.Record]?
        var routines: [SyncKit.Record]?
        var projects: [SyncKit.Record]?
    }

    nonisolated static func fetch(for records: [SyncKit.Record], from journal: Journal) -> Fetched {
        MainBudget.chunk("sync.fetch") {
            let kinds = Set(records.map(\.collection))
            var fetched = Fetched()
            if kinds.contains(SyncShapes.space) { fetched.spaces = journal.living(SyncShapes.space) }
            if !kinds.isDisjoint(with: [SyncShapes.space, SyncShapes.tab, SyncShapes.folder, SyncShapes.pair]) {
                fetched.tabs = journal.all(SyncShapes.tab)
                fetched.folders = journal.all(SyncShapes.folder)
                fetched.pairs = journal.all(SyncShapes.pair)
            }
            if kinds.contains(SyncShapes.bookmark) { fetched.bookmarks = journal.all(SyncShapes.bookmark) }
            if kinds.contains(SyncShapes.answer) { fetched.answers = journal.all(SyncShapes.answer) }
            if kinds.contains(SyncShapes.routine) { fetched.routines = journal.all(SyncShapes.routine) }
            if kinds.contains(SyncShapes.project) { fetched.projects = journal.all(SyncShapes.project) }
            return fetched
        }
    }

    /// Whether a space's row here holds any of these tabs: its live row if
    /// the window has it, its file if not.
    private func holds(_ space: UUID, any ids: Set<String>) -> Bool {
        guard !ids.isEmpty else { return false }
        if let primary, space == primary.spaceID || primary.parked[space] != nil {
            let row = space == primary.spaceID ? primary.tabs : primary.parked[space]?.tabs ?? []
            return row.contains { ids.contains(KeptEverywhere.key($0).uuidString) }
        }
        return Session.read(space: space).tabs.contains { $0.id.map(ids.contains) ?? false }
    }

    private func adopt(_ records: [SyncKit.Record], fetched: Fetched = Fetched()) {
        guard let journal else { return }
        adopt(records, from: journal, fetched: fetched)
    }

    /// Apply a delivery using its journal, also usable with isolated journals
    /// without starting a client or opening an account.
    func adopt(_ records: [SyncKit.Record], from journal: Journal, fetched: Fetched = Fetched()) {
        let records = records.filter { !excludedCollections.contains($0.collection) }
        let span = MainBudget.begin("sync.adopt"); defer { span?.end() }
        applying = true
        defer {
            applying = false
            recount()
        }
        let by = Dictionary(grouping: records, by: \.collection)
        var addedSpaces = Set<UUID>()

        if by[SyncShapes.space] != nil {
            let local = Dictionary(Spaces.read().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let records = fetched.spaces ?? journal.living(SyncShapes.space)
            // The choice and value are one operation. An old device can
            // echo an emoji while retaining a stale choice for that emoji;
            // matching text alone does not make it a new deliberate pick.
            let chosen = Set(records.filter { record in
                guard let icon = record["icon"]?.string else { return false }
                return record["iconChoice"]?.string == icon && record.stamps["icon"] != nil && record.stamps["iconChoice"] == record.stamps["icon"]
                    && (record["iconChoiceID"] == nil || record.stamps["iconChoiceID"] == record.stamps["icon"])
            }.compactMap { UUID(uuidString: $0.id) })
            var fresh = SyncShapes.spaces(from: records).map { space -> Space in
                // What was brought in, from whose sign-ins, and the sites muted
                // there are this Mac's.
                var space = space
                if !chosen.contains(space.id) { space.iconChoice = nil; space.iconChoiceID = nil }
                if let had = local[space.id] {
                    space.icon = SpaceSymbols.kept(incoming: space.icon, had: had.icon, choice: space.iconChoice)
                    if space.icon == had.icon, space.iconChoice != space.icon {
                        space.iconChoice = had.iconChoice
                        space.iconChoiceID = had.iconChoiceID
                    }
                }
                space.brought = local[space.id]?.brought
                // Pre-profile devices have no field; preserve imported links then.
                if !records.contains(where: { $0.id == space.id.uuidString && $0.stamps["signInWith"] != nil }) {
                    space.signInWith = local[space.id]?.signInWith
                    space.signedInAs = local[space.id]?.signedInAs
                } else if local[space.id]?.profileID == space.profileID {
                    // An echo of unchanged membership is not a manual detach
                    // from the imported profile; a later Bring In still uses it.
                    space.signedInAs = local[space.id]?.signedInAs
                }
                space.mutedSites = local[space.id]?.mutedSites
                return space
            }
            // Catch-up is paged: absence from the journal is not a deletion.
            // In particular a renamed space may arrive after its pins. Keep
            // its local session until an explicit tombstone says it is gone.
            let known = Set(journal.all(SyncShapes.space).map(\.id))
            fresh += Spaces.read().filter { !known.contains($0.id.uuidString) }
            // A remote deletion may remove Personal too. Keep one local
            // space only when the incoming list has none at all.
            if fresh.isEmpty {
                fresh = [primary.flatMap { local[$0.spaceID] } ?? Spaces.read()[0]]
            }
            let gone = local.keys.filter { id in !fresh.contains { $0.id == id } }
            addedSpaces = Set(fresh.map(\.id)).subtracting(local.keys)
            for id in gone { primary?.deleteSpace(id) }
            Spaces.write(fresh)
        }

        let rowKinds = [SyncShapes.tab, SyncShapes.folder, SyncShapes.pair]
        if syncs(.tabs), !addedSpaces.isEmpty || rowKinds.contains(where: { by[$0] != nil }) {
            // Tabs received before their space were journaled but could not
            // be shown. Materialize them when the space finally arrives,
            // even when this delivery contains no tab records of its own.
            var spaces = Set(addedSpaces.map(\.uuidString))
            for record in rowKinds.flatMap({ by[$0] ?? [] }) {
                if let parent = record.fields["parent"]?.string { spaces.insert(parent) }
            }
            let tabs = fetched.tabs ?? journal.all(SyncShapes.tab), folders = fetched.folders ?? journal.all(SyncShapes.folder)
            let pairs = fetched.pairs ?? journal.all(SyncShapes.pair)
            let held = Set(tabs.map(\.id))
            let localSpaces = Set(Spaces.read().map(\.id))
            let known = SharedPins.on ? localSpaces.union([Space.firstID]) : localSpaces
            // A tab gone to another space, a folder's with it, leaves the
            // one it was in here too: that space's row is read again as well.
            let moved = Set((by[SyncShapes.tab] ?? []).map(\.id))
            for id in known where !spaces.contains(id.uuidString) && holds(id, any: moved) { spaces.insert(id.uuidString) }
            for id in spaces.compactMap(UUID.init(uuidString:)) where known.contains(id) {
                let virtual = id == Space.firstID && !localSpaces.contains(id)
                let pinsRow = Session.read(space: Space.pinsID)
                let here = virtual ? SharedPins.folded(pinsRow.tabs, into: .init(tabs: [], front: nil), pinPairs: pinsRow.pairs)
                    : SharedPins.syncRow(id)
                let shape = SyncShapes.row(id, tabs: tabs, folders: folders, pairs: pairs, here: here, device: Self.deviceID, marked: SyncShapes.marked)
                // The first space's pins are the shared ones while pins are
                // shared here: apart again, each to its own row.
                if id == Space.firstID, SharedPins.on {
                    let (pins, rest) = SharedPins.unfolded(shape)
                    // Pairs pinned as one go to the pins' file with them (PinPairs.swift).
                    let pinPairs = SharedPins.pinPairs(shape)
                    if let primary {
                        if !virtual { primary.adopt(rest, in: id, held: held) }
                        else { Session.write(now: true, space: Space.pinsID, .init(tabs: pins, active: 0, pairs: pinPairs.isEmpty ? nil : pinPairs)) }
                        for window in SharedPins.windows(with: primary) where window.pinsShared {
                            window.followPins(pins, pairs: pinPairs, addresses: true)
                        }
                    } else {
                        if !virtual { Session.write(now: true, space: id, rest) }
                        Session.write(now: true, space: Space.pinsID, .init(tabs: pins, active: 0, pairs: pinPairs.isEmpty ? nil : pinPairs))
                    }
                    continue
                }
                if let primary { primary.adopt(shape, in: id, held: held) } else { Session.write(now: true, space: id, shape) }
            }
            // The rows as drawn now are read back at once, so they are what
            // the next difference is measured from (Journal's `shown`): a tab
            // that just came and is closed right after still goes.
            DispatchQueue.main.async { [weak self] in self?.changed(SyncShapes.tab) }
        }

        if by[SyncShapes.bookmark] != nil {
            Bookmarks.shared.adopt(SyncShapes.bookmarks(from: fetched.bookmarks ?? journal.all(SyncShapes.bookmark)))
        }

        if let settings = by[SyncShapes.setting] {
            let split = Store.settings.bool(forKey: SyncShapes.shortcutsSplit)
            for record in settings where SyncShapes.syncs(record.id) && (SyncAddons.on || !SyncShapes.extensionSetting(record.id)) {
                // Keys come one an action once this Mac has split them, and
                // until then as the whole dictionary (SyncShapes, shortcuts).
                if record.id.hasPrefix(SyncShapes.shortcutPrefix) || (split && record.id == SyncShapes.shortcutsKey) { continue }
                // A Mac in use joining keeps its pins apart (SharedPins.joining).
                if record.id == SharedPins.key, SharedPins.holdsApart(Store.settings) { continue }
                if record.alive(), let value = record["value"].flatMap(SyncShapes.plist) {
                    Store.settings.set(value, forKey: record.id)
                } else {
                    Store.settings.removeObject(forKey: record.id)
                }
            }
            let fresh = Preferences()
            for browser in BrowserWindows.shared.browsers {
                let paint = fresh.usesSpaces ? browser.space.paint : nil
                browser.prefs.adopt(fresh, wearing: paint)
            }
            AppIconStyle.sharedSettingsChanged(Set(settings.map(\.id)))
            if split, settings.contains(where: { $0.id.hasPrefix(SyncShapes.shortcutPrefix) }) {
                Self.takeShortcuts(SyncShapes.shortcuts(from: journal.living(SyncShapes.setting)), split: false)
            } else {
                Keymap.shared.adoptStored()
            }
        }

        if let changed = by[SyncShapes.memory] {
            ContextPrivacy.shared.transaction {
            guard ContextPrivacy.shared.current(fetched.contextEpoch) else { return }
            let eligible = journal.all(SyncShapes.memory).filter { ContextPrivacy.shared.mayTakeSync("memory/" + $0.id, epoch: fetched.contextEpoch, stamp: $0.latest, image: ContextSyncReplay.image($0)) }
            let files = SyncShapes.memoryFiles(from: eligible)
            // Each page a change touched, written whole or removed; a day is
            // written again from all its entries.
            var paths = Set<String>()
            for record in changed where ContextPrivacy.shared.mayTakeSync("memory/" + record.id, epoch: fetched.contextEpoch, stamp: record.latest, image: ContextSyncReplay.image(record)) {
                if let day = record.fields["day"]?.string { paths.insert(day) } else { paths.insert(record.id) }
            }
            for path in paths where !path.contains("..") && path.hasSuffix(".md") {
                let url = Memory.folder.appendingPathComponent(path)
                // A page mail wrote here stays as it is: it never syncs, and
                // another Mac taking back its own copy doesn't take this one.
                if !path.hasPrefix("episodic/"), let here = try? String(contentsOf: url, encoding: .utf8), Memory.fromMail(here) { continue }
                if path.hasPrefix("episodic/"), let text = files[path] {
                    // An entry written here since the last read stays: it
                    // goes up with the next one.
                    let known = Set(eligible.compactMap { $0.fields["day"]?.string == path ? $0.fields["text"]?.string : nil })
                    let local = ((try? String(contentsOf: url, encoding: .utf8)).map(SyncShapes.entries) ?? []).filter { !known.contains($0) }
                    let date = url.deletingPathExtension().lastPathComponent
                    let all = (SyncShapes.entries(text) + local).sorted()
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? ("# \(date)\n\n" + all.joined(separator: "\n\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
                } else if let text = files[path] {
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? text.write(to: url, atomically: true, encoding: .utf8)
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        }

        // A place gone from the two weeks, or from a Mac that stopped
        // syncing history, stays here. One deleted by hand on another device
        // (its cut) goes here too, from the field and History, unless this
        // Mac has been there since: kept, it would come back with the next flush.
        if let visits = by[SyncShapes.visit] {
            History.shared.adoptSynced(SyncShapes.visits(from: visits))
            let gone = History.shared.dropSynced(SyncShapes.cutVisits(from: visits))
            if !gone.isEmpty { Diary.shared.forget(keys: gone.map(Diary.key)) }
        }
        // A chat of this Mac's pinned, read, archived or renamed on another
        // device: taken here, so the next flush doesn't write it back (R4).
        if let heads = by[SyncChats.chat] { adoptChats(heads) }
        let wallet = SyncWallet.collections.flatMap { by[$0] ?? [] }
        if !wallet.isEmpty { takeWallet(wallet, contextEpoch: fetched.contextEpoch) }
        if SyncAddons.on, merging {
            for collection in SyncAddons.collections {
                joiningAddons[collection, default: []].formUnion((by[collection] ?? []).map(\.id))
            }
        } else if SyncAddons.on {
            do {
                if let changed = by[SyncAddons.ext] { try takeExtensions(journal, changed: changed) }
                if by[SyncAddons.plugin] != nil || by[SyncAddons.part] != nil {
                    try takePlugins(journal, changed: by[SyncAddons.plugin] ?? [], parts: by[SyncAddons.part] ?? [])
                }
            } catch {
                NSLog("sync: %@", String(describing: error))
            }
            client?.kick()
        }
        // A file's last part arriving lets words waiting for it be said.
        if by[SyncChats.send] != nil || by[SyncChats.part] != nil {
            DispatchQueue.main.async { [weak self] in self?.takeSends() }
        }
        // An iPhone saying it takes pages: Send to iPhone names it once it
        // is in the device list (SyncPhone).
        if let caps = by[OpenOnMac.capability] { heardCapabilities(caps) }
        if by[TaskRecords.requestCollection] != nil {
            DispatchQueue.main.async { [weak self] in self?.takeTasks() }
        }
        if by[AssistantApprovalRecords.answerCollection] != nil {
            DispatchQueue.main.async { [weak self] in self?.takeAssistantAnswers() }
        }
        if by[AssistantApprovalRecords.requestCollection] != nil || by[AssistantApprovalRecords.answerCollection] != nil {
            DispatchQueue.main.async { [weak self] in self?.takeForeignAssistantApprovals() }
        }

        if by[SyncShapes.answer] != nil {
            let said = SyncShapes.answers(from: fetched.answers ?? journal.all(SyncShapes.answer), local: FormAnswers.load().said)
            if said != FormAnswers.load().said { FormAnswers.save(FormAnswers.Book(said: said)) }
        }

        if by[SyncShapes.routine] != nil {
            Routines.shared.adopt(SyncShapes.routines(from: fetched.routines ?? journal.all(SyncShapes.routine)))
        }

        if by[SyncShapes.project] != nil {
            let records = fetched.projects ?? journal.all(SyncShapes.project)
            Projects.shared.adopt(SyncShapes.projects(from: records), removed: Set(records.filter { !$0.alive() }.map(\.id)))
        }

        // Files are written whole, and whatever holds one in memory reads it
        // again at once; the rest read their file each time they need it.
        let files = (by[SyncShapes.file] ?? []).filter { SyncShapes.files.contains($0.id) }
        defer { if !files.isEmpty { Self.reread(Set(files.map(\.id))) } }
        for record in files {
            if record.id == "know.json", !ContextPrivacy.shared.mayTakeSync("know.json", epoch: fetched.contextEpoch, stamp: record.latest, image: ContextSyncReplay.image(record)) { continue }
            if record.id == "profile.json" {
                guard ContextPrivacy.shared.current(fetched.contextEpoch), record.alive(), let incoming = SyncShapes.profile(from: record) else { continue }
                _ = ContextPrivacy.shared.mergeSyncedProfile(incoming, epoch: fetched.contextEpoch, stamp: record.latest, image: ContextSyncReplay.image(record))
                continue
            }
            ContextPrivacy.shared.transaction {
                if record.id == "know.json", !ContextPrivacy.shared.mayTakeSync("know.json", epoch: fetched.contextEpoch, stamp: record.latest, image: ContextSyncReplay.image(record)) { return }
            let url = Store.folder.appendingPathComponent(record.id)
            if record.alive(), let json = record["json"], let data = try? JSONEncoder().encode(json) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
            }
        }
        for record in by[SyncShapes.icon] ?? [] where !record.id.contains("/") && !record.id.hasPrefix(".") {
            let url = Store.folder.appendingPathComponent("custom-icons").appendingPathComponent(record.id)
            if record.alive(), let data = record["data"]?.string.flatMap({ Data(base64Encoded: $0) }) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

// MARK: - A row from elsewhere, into a live window

extension Browser {
    /// A space's row as sync says it is now: tabs opened elsewhere come in
    /// asleep, tabs closed elsewhere go, the rest take their new names,
    /// pins, folders and places. The page on screen keeps its address; an
    /// agent's tabs, private ones and a call stay where they are.
    /// `held`: every tab record sync's journal has, removed ones too. A tab
    /// here whose record it never had was never anywhere else, so nothing
    /// closed it elsewhere: it stays, where it is. Nil: the shape is the
    /// whole row (a snapshot put back).
    func adopt(_ shape: Session.Shape, in space: UUID, held: Set<String>? = nil) {
        let onScreen = space == spaceID
        var row = onScreen ? tabs : parked[space]?.tabs ?? []
        let active = onScreen ? activeID : parked[space]?.active
        let localPairs = onScreen ? pairs : parked[space]?.pairs ?? []
        // A space never opened since launch has no row yet: its file is it.
        if !onScreen, parked[space] == nil {
            Session.write(now: true, space: space, shape)
            // Another window may have it open: its kept and pins follow.
            KeptEverywhere.wrote(shape.tabs.filter(KeptEverywhere.listed), space: space, by: self)
            return
        }
        let wanted = Set(shape.tabs.compactMap(\.id))
        // A kept tab or a pin is written under its key, which is its id
        // unless the tab was made for an entry another window had first
        // (KeptEverywhere.swift).
        let byID = Dictionary(row.map { (KeptEverywhere.key($0).uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        // The folders the row has, and the folders those are in.
        var nests = Dictionary(row.flatMap { tab in (tab.nest?.chain ?? []).map { ($0.id.uuidString, $0) } }, uniquingKeysWith: { a, _ in a })

        // Gone elsewhere: closed here too, unless it never syncs. The shared
        // pins come as the first space's, and are followed apart from any
        // space's row (SharedPins.swift).
        let syncing = row.filter { !$0.shy && !$0.bench && !travels($0) && $0.everywhere == nil }
        // Not in the shape, and never in the journal: a tab opened here
        // since this delivery read the rows, or one with no page sync writes
        // yet (a link's new tab before its first address, a chrome:// page).
        // Taken for closed elsewhere, it closed the moment it opened, the
        // window landing on another tab (feedback #1877).
        let unheld = held.map { held in
            syncing.filter { tab in
                let key = KeptEverywhere.key(tab).uuidString
                return !wanted.contains(key) && !held.contains(key)
            }
        } ?? []
        let synced = syncing.filter { tab in !unheld.contains { $0 === tab } }
        let closing = synced.filter { !wanted.contains(KeptEverywhere.key($0).uuidString) }
        var nextActive = active
        if let active, closing.contains(where: { $0.id == active }) {
            let left = row.filter { tab in !closing.contains { $0.id == tab.id } }
            nextActive = (left.last { !$0.asleep } ?? left.last)?.id
        }

        var made: [Tab] = []
        // A tab here that doesn't sync (a call, an agent's guest, a private
        // one) stays as it is among `staying`, never taken into `made` as
        // well: the row held it twice and the tab bar trapped on it.
        let syncedIDs = Set(synced.map(\.id))
        var listed = Set<String>()
        for entry in shape.tabs {
            guard let id = entry.id, listed.insert(id).inserted, let url = URL(string: entry.url) else { continue }
            if let have = byID[id], !syncedIDs.contains(have.id) { continue }
            let tab: Tab
            if let have = byID[id] {
                tab = have
                if tab.address != url, tab.id != active, !(pair(of: tab.id).map { _ in onScreen } ?? false) {
                    if !tab.asleep { tab.rest() }
                    tab.restore(url: url, title: entry.title)
                } else if tab.asleep, tab.title != entry.title {
                    tab.restore(url: url, title: entry.title)
                }
                // Read further elsewhere: there when it is next looked at
                // here. The page on screen stays where you are.
                let shown = onScreen && (tab.id == active || pair(of: active).map { $0.first == tab.id || $0.second == tab.id } == true)
                if tab.depth != entry.depth, !shown {
                    tab.arrive(at: entry.depth, now: true)
                }
            } else {
                tab = Tab(id: Tab.returning(id), configuration: Web.configuration(store: Spaces.store(for: space)), engine: entry.engineKind)
                prepare(tab)
                tab.restore(url: url, title: entry.title)
                tab.arrive(at: entry.depth)
            }
            tab.pin = entry.pin
            tab.name = entry.name
            tab.customMark = entry.customMark
            if let seen = entry.seen, Date(timeIntervalSince1970: seen) > tab.touched { tab.touch(at: Date(timeIntervalSince1970: seen)) }
            tab.kept = entry.kept == true && entry.pin == nil
            tab.takeHome(entry)
            tab.live = tab.kept ? entry.live : nil
            if let key = entry.folder, entry.pin == nil {
                let nest = nests[key] ?? Nest(id: UUID(uuidString: key) ?? UUID(), name: entry.folderName ?? "Folder", open: entry.folderOpen ?? true)
                nest.name = entry.folderName ?? nest.name
                if let open = entry.folderOpen { nest.open = open }
                nest.search = entry.folderSearch
                nest.ordinaryToday = entry.folderOrdinaryToday == true
                nest.fleeting = entry.folderToday == true && !nest.ordinaryToday
                nest.linked = entry.folderLinked == true
                if tab.kept { nest.live = entry.folderLive }
                nest.customMark = entry.folderMark
                nest.color = entry.folderColor
                nests[key] = nest
                // The folders it is in, as the other device has them.
                if tab.kept || nest.ordinaryToday {
                    nest.file(in: entry.folderPath, nests: &nests, update: true)
                    for each in nest.chain {
                        each.ordinaryToday = entry.folderOrdinaryToday == true
                        if tab.kept { each.fleeting = false; each.search = nil }
                    }
                } else { nest.parent = nil }
                tab.nest = nest
            } else {
                tab.nest = nil
            }
            made.append(tab)
        }
        // What doesn't sync keeps its place at the end of the row, the
        // shared pins theirs at its head.
        let staying = row.filter { tab in !syncedIDs.contains(tab.id) && !unheld.contains { $0 === tab } }
        for tab in closing {
            AgentPage.forget(tab)
            tab.close()
        }
        var next = staying.filter { $0.everywhere != nil } + made + staying.filter { $0.everywhere == nil }
        // One sync never had keeps its place: after the tab before it.
        for tab in unheld {
            let at = row.firstIndex { $0 === tab } ?? 0
            let prior = row[..<at].last { earlier in next.contains { $0 === earlier } }
            let index = prior.flatMap { prior in next.firstIndex { $0 === prior } }.map { $0 + 1 }
                ?? staying.filter { $0.everywhere != nil }.count
            next.insert(tab, at: index)
        }
        row = next

        // Pairs by the ids in the new row. A pair with a tab that doesn't
        // sync is this window's own, just as that tab is: an unrelated sync
        // update must not separate it. An incoming pair takes precedence
        // when it explicitly puts one of those tabs beside another.
        var paired = Set<Tab.ID>()
        var newPairs = (shape.pairs ?? []).compactMap { pair -> Pair? in
            guard shape.tabs.indices.contains(pair.first), shape.tabs.indices.contains(pair.second),
                  let first = shape.tabs[pair.first].id.flatMap(UUID.init(uuidString:)), let second = shape.tabs[pair.second].id.flatMap(UUID.init(uuidString:)),
                  let a = row.first(where: { KeptEverywhere.key($0) == first })?.id, let b = row.first(where: { KeptEverywhere.key($0) == second })?.id,
                  a != b, pair.share.isFinite, !paired.contains(a), !paired.contains(b)
            else { return nil }
            paired.formUnion([a, b])
            return Pair(first: a, second: b, share: min(Pair.most, max(Pair.least, CGFloat(pair.share))))
        }
        let remaining = Set(row.map(\.id))
        for pair in localPairs {
            guard !syncedIDs.contains(pair.first) || !syncedIDs.contains(pair.second),
                  pair.first != pair.second, remaining.contains(pair.first), remaining.contains(pair.second),
                  !paired.contains(pair.first), !paired.contains(pair.second) else { continue }
            paired.formUnion([pair.first, pair.second])
            newPairs.append(pair)
        }

        if onScreen {
            quietly {
                lay(row)
                pairs = newPairs
                if nextActive != activeID {
                    if let next = nextActive.flatMap({ id in row.first { $0.id == id } }) { select(next) } else { activeID = nil; askNew() }
                }
            }
        } else {
            parked[space] = Parked(tabs: row, active: nextActive, pairs: newPairs)
        }
        writeRow(row, active: onScreen ? activeID : nextActive, space: space, pairs: newPairs, now: true)
    }
}

// MARK: - Settings from elsewhere, into the live preferences

extension Preferences {
    /// Takes the values another Preferences read from the store, each only
    /// where it differs, so nothing is redrawn or rewritten for nothing.
    /// What is this Mac's own (the bench, the downloads folder, Welcome,
    /// the sidebar's width) is left alone.
    func adopt(_ o: Preferences, wearing paint: SpacePaint? = nil) {
        if agentsRemember != o.agentsRemember { agentsRemember = o.agentsRemember }
        if agentsAsking != o.agentsAsking { agentsAsking = o.agentsAsking }
        if askOpens != o.askOpens { askOpens = o.askOpens }
        if agentsMessages != o.agentsMessages { agentsMessages = o.agentsMessages }
        if look != o.look { look = o.look }
        if backdrop != o.backdrop { backdrop = o.backdrop }
        adoptPaint(o, wearing: paint)
        if sidebar != o.sidebar { sidebar = o.sidebar }
        if glyph != o.glyph { glyph = o.glyph }
        if density != o.density { density = o.density }
        if addressBar != o.addressBar { addressBar = o.addressBar }
        if fullURL != o.fullURL { fullURL = o.fullURL }
        if pageZoom != o.pageZoom { pageZoom = o.pageZoom }
        if pageFonts != o.pageFonts { pageFonts = o.pageFonts }
        // Pages read Dark pages from the store, which sync has already
        // written: left out here, every new page went dark while Settings
        // on this Mac still said Off, and picking Off again changed nothing.
        if darkPages != o.darkPages { darkPages = o.darkPages }
        if darkLook != o.darkLook { darkLook = o.darkLook }
        if bookmarkBar != o.bookmarkBar { bookmarkBar = o.bookmarkBar }
        if sleepsTabs != o.sleepsTabs { sleepsTabs = o.sleepsTabs }
        if tidyAfter != o.tidyAfter { tidyAfter = o.tidyAfter }
        if shielded != o.shielded { shielded = o.shielded }
        if extensionsInPrivate != o.extensionsInPrivate { extensionsInPrivate = o.extensionsInPrivate }
        if passkeys != o.passkeys { passkeys = o.passkeys }
        if asksWhereToSave != o.asksWhereToSave { asksWhereToSave = o.asksWhereToSave }
        if uploadsInFinder != o.uploadsInFinder { uploadsInFinder = o.uploadsInFinder }
        if savesPasswords != o.savesPasswords { savesPasswords = o.savesPasswords }
        if fillsPasswords != o.fillsPasswords { fillsPasswords = o.fillsPasswords }
        if codesFromMail != o.codesFromMail { codesFromMail = o.codesFromMail }
        if savesCards != o.savesCards { savesCards = o.savesCards }
        if fillsCards != o.fillsCards { fillsCards = o.fillsCards }
        if fillsForms != o.fillsForms { fillsForms = o.fillsForms }
        if draftsForms != o.draftsForms { draftsForms = o.draftsForms }
        if engine != o.engine { engine = o.engine }
        if engineCustom != o.engineCustom { engineCustom = o.engineCustom }
        if siteLearn != o.siteLearn { siteLearn = o.siteLearn }
        if siteRecent != o.siteRecent { siteRecent = o.siteRecent }
        if warnsOnQuit != o.warnsOnQuit { warnsOnQuit = o.warnsOnQuit }
        if smallLinks != o.smallLinks { smallLinks = o.smallLinks }
        if smallKey != o.smallKey { smallKey = o.smallKey }
        if peeks != o.peeks { peeks = o.peeks }
        if usesSpaces != o.usesSpaces { usesSpaces = o.usesSpaces }
        if pinsEverySpace != o.pinsEverySpace { pinsEverySpace = o.pinsEverySpace }
        if mailAnimations != o.mailAnimations { mailAnimations = o.mailAnimations }
        if showsPlayer != o.showsPlayer { showsPlayer = o.showsPlayer }
        if floatsOnLeave != o.floatsOnLeave { floatsOnLeave = o.floatsOnLeave }
        if floatsAway != o.floatsAway { floatsAway = o.floatsAway }
        if linkFolders != o.linkFolders { linkFolders = o.linkFolders }
        if folderEmoji != o.folderEmoji { folderEmoji = o.folderEmoji }
        if optShiftFolders != o.optShiftFolders { optShiftFolders = o.optShiftFolders }
        if meetingFolders != o.meetingFolders { meetingFolders = o.meetingFolders }
    }
}

// MARK: - Bookmarks from elsewhere

extension Bookmarks {
    /// The whole tree as sync says it is now.
    func adopt(_ tree: [Bookmark]) {
        guard tree != roots else { return }
        replaceAll(with: tree)
    }
}
