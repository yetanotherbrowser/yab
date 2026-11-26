import CoreGraphics
import Foundation
import Observation
import UIKit
import os

/// Where a task meets the person on this iPhone: it sends tasks to the Mac
/// (the TaskBackend, today the VirtualMac), turns what the Mac says into the
/// runs the Now line, the column and the chats read (TaskStore), plays the
/// haptics the moments want, keeps the Live Activity in step, and holds the
/// sheets that come for the person: the code, the yes and Face ID, a task's
/// chat growing out of the Now line or the Island.
@MainActor
@Observable
final class TaskDesk {
    /// The app owns its desk. A delayed callback may outlive that owner.
    @ObservationIgnored private(set) weak var app: AppModel?
    @ObservationIgnored let backend: TaskBackend
    @ObservationIgnored let signer: YesSigner
    @ObservationIgnored let activity: TaskActivityController
    @ObservationIgnored private let log = Logger(subsystem: "dev.serafim.fast.iphone", category: "tasks")

    /// The one desk of the running app, for the Live Activity's buttons.
    static weak var current: TaskDesk?

    /// The Mac, awake or asleep since a time.
    private(set) var presence: MacPresence
    /// What the Mac asked for, by task: the code's sender, the yes's facts,
    /// what stopped it.
    private(set) var codes: [TaskRun.ID: CodeRequest] = [:]
    private(set) var yeses: [TaskRun.ID: YesRequest] = [:]
    private(set) var failures: [TaskRun.ID: TaskFailure] = [:]

    /// The app's desk, as launched: the world's virtual Mac with the launch
    /// arguments over it, Face ID (or its stand-in), and a Live Activity
    /// unless this launch is a named state's picture.
    convenience init(app: AppModel, options: LaunchOptions = .current, arguments: [String] = ProcessInfo.processInfo.arguments) {
        let script = MacScript.load(world: app.world).applying(arguments: arguments)
        let signer: YesSigner = app.isFixture ? Self.signer(arguments: arguments) : UnavailableYesSigner()
        self.init(app: app, script: script, signer: signer, still: options.state != nil,
                  activities: options.state == nil, words: options.state == nil ? Self.value("YabTaskWords", in: arguments) : nil)
    }

    /// A desk with its parts given: tests run the virtual Mac fast and sign
    /// with a key of their own.
    init(app: AppModel, script: MacScript, signer: YesSigner, still: Bool, activities: Bool, words: String? = nil) {
        self.app = app
        let mac = app.isFixture ? VirtualMac(script: script, definitions: app.world.taskDefinitions) : nil
        if let mac { backend = mac } else { backend = UnavailableTaskBackend() }
        self.signer = signer
        activity = TaskActivityController(enabled: activities && app.isFixture)
        presence = backend.presence
        mac?.known = { [weak app] id in app?.tasks.run(id) }
        // Named states are pictures: nothing moves on its own in them.
        mac?.still = still
        backend.onEvent = { [weak self] event in self?.apply(event) }
        backend.trust(signer.publicKey)
        Self.current = self
        // The chats and the tasks wait on the same Mac.
        if let mac {
            if app.browser.macAsleep, presence.awake { mac.sleep() }
            else { app.browser.macAsleep = !presence.awake }
        }
        TaskIntentRouter.handler = { [weak self] task, action in self?.act(task: task, action: action) }
        if let since = presence.asleepSince {
            for run in app.tasks.runs where run.status == .waits && run.asleepSince == nil {
                app.tasks.update(run.id) { $0.asleepSince = since }
            }
        }
        if app.isFixture { followMacAsleep() }
        if !still, let mac {
            for run in app.tasks.runs { mac.adopt(run) }
            // Authenticated taps from a background launch are read once.
            for pending in TaskIntentRouter.takePending() { act(task: pending.task, action: pending.action) }
            if let words {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(0.6))
                    self?.send(words: words)
                }
            }
        }
        activity.sync(self)
    }

    isolated deinit {
        for watch in sendingWatch.values { watch.cancel() }
        virtualMac?.halt()
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
    }

    /// Whether Yab is on screen, for the haptics that only make sense there.
    @ObservationIgnored var onScreen: () -> Bool = { UIApplication.shared.applicationState != .background }

    private static func value(_ key: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: "-" + key), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    /// Face ID through the system; `-YabFaceID match|nomatch` stands in for a face.
    private static func signer(arguments: [String]) -> YesSigner {
        switch value("YabFaceID", in: arguments) {
        case "match": return StandInSigner(match: true)
        case "nomatch": return StandInSigner(match: false)
        default:
            do { return try FaceIDSigner(allowsFixtureRequests: true) }
            catch { return UnavailableYesSigner() }
        }
    }

    var virtualMac: VirtualMac? { backend as? VirtualMac }
    /// A single eligible Mac may be used without guessing among multiple Macs.
    /// An explicit selection never falls back to another owner.
    var selectedLiveMac: String?
    private var liveBackend: SyncTaskBackend? {
        guard let app, !app.isFixture, !app.hasPrivateForeground,
              app.sync.currentTaskOrigin() != nil, let engine = app.sync.engine else { return nil }
        let eligible = engine.macs.filter { engine.readOnlyTaskEpoch(on: $0.id) != nil }
        let owner: String
        if let selectedLiveMac {
            guard eligible.contains(where: { $0.id == selectedLiveMac }) else { return nil }
            owner = selectedLiveMac
        } else if let chosen = app.sync.chosenMac, eligible.contains(where: { $0.id == chosen }) {
            // A Mac picked by hand for new work (the + menu, Open on Mac's
            // list) is an explicit owner; nothing is guessed among several.
            owner = chosen
        } else {
            guard eligible.count == 1, let only = eligible.first else { return nil }
            owner = only.id
        }
        return SyncTaskBackend.capture(in: app, mac: owner)
    }
    var canRun: Bool { app?.isFixture == true || liveBackend != nil }

    // MARK: - Claude's answers wait too

    /// Claude answers on the Mac: an answer asked for while it sleeps waits
    /// for it ("Waits for your Mac · asleep since 18:52", chat.8) and comes
    /// when it wakes. The chats call this before they show Claude's answer.
    func whenMacAwake() async {
        guard app != nil else { return }
        await backend.whenAwake()
    }

    /// "18:52" while the Mac sleeps; nil when it's awake.
    var macAsleepSince: String? { presence.awake ? nil : presence.asleepSince }

    /// One Mac for the whole app: whatever learns it fell asleep or woke
    /// (sync, the chats, a named state) says so in `browser.macAsleep`, and
    /// the virtual Mac follows, so tasks and Claude's answers wait on the same
    /// Mac and wake with it.
    private func followMacAsleep() {
        guard let app else { return }
        withObservationTracking { _ = app.browser.macAsleep } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.macAsleepChanged() }
        }
    }

    private func macAsleepChanged() {
        guard let app else { return }
        followMacAsleep()
        guard app.browser.macAsleep == presence.awake, let mac = virtualMac else { return }
        if app.browser.macAsleep { mac.sleep() } else { mac.wake() }
    }

    // MARK: - sending

    /// A task from words in the field ("book the tap 18:35 to lisbon, window
    /// seat"). Until the Mac reads words itself, the stand-in picks which of
    /// the world's tasks they mean: anna or a reply, lumen or a spot,
    /// lisbon or a flight. Other words have no stand-in task.
    @discardableResult
    func send(words: String) -> TaskRun.ID? {
        guard let app else { return nil }
        if !app.isFixture {
            guard let liveBackend else {
                // Yab closed on the Mac it would go to: a task can't wait
                // for a run of Yab still to come, so it says where to open it.
                // A task runs only on a Mac that is up now: why not, by name.
                if let mac = MacPick.pick(app.sync.macs, chosen: app.sync.chosenMac), let words = MacWords.taskRefused(mac.name, mac.state) {
                    app.say(words, glyph: .macbook)
                } else {
                    app.say("No ready Mac is available for this task", glyph: .macbook)
                }
                return nil
            }
            do {
                let snapshot = try liveBackend.send(words)
                app.sync.reconcileLiveTasks()
                return snapshot.id
            } catch {
                app.say("This task could not be queued for your Mac", glyph: .macbook)
                return nil
            }
        }
        guard canRun else { app.say("Tasks on your Mac aren’t available yet", glyph: .macbook); return nil }
        let id = Self.taskFor(words: words, among: Set(app.world.taskDefinitions.map(\.id)))
        guard let id else { return nil }
        send(id, words: words)
        return id
    }

    static func taskFor(words: String, among defined: Set<TaskDefinition.ID>) -> TaskDefinition.ID? {
        let words = words.lowercased()
        let id: TaskDefinition.ID
        if words.contains("anna") || words.contains("repl") { id = "anna" }
        else if words.contains("lumen") || words.contains("spot") || words.contains("design systems") { id = "lumen" }
        else if words.contains("flight") || words.contains("lisbon") { id = "lisbon" }
        else { return nil }
        return defined.contains(id) ? id : nil
    }

    /// Sends a known task: "Sending to your Mac" until the Mac takes it; the
    /// Mac asleep, it waits at once.
    func send(_ id: TaskDefinition.ID, words: String) {
        guard let app, app.isFixture else { return }
        guard canRun else { app.say("Tasks on your Mac aren’t available yet", glyph: .macbook); return }
        if let run = app.tasks.run(id), run.status != .done, run.status != .stopped { return }
        app.tasks.remove(id)
        let asleep = !presence.awake
        TaskMotion.run(.nowArrive) {
            _ = app.tasks.start(id, macAsleep: asleep)
            if asleep { app.tasks.update(id) { $0.asleepSince = presence.asleepSince } }
        }
        failures[id] = nil
        warned[id] = nil
        codes[id] = nil
        yeses[id] = nil
        refused.remove(id)
        later.remove(id)
        backend.send(TaskOrder(id: id, words: words))
        watchSending(id)
        activity.sync(self)
    }

    /// Longer than 20 s without the Mac taking it: the line says it waits.
    @ObservationIgnored private var sendingWatch: [TaskRun.ID: Task<Void, Never>] = [:]

    private func watchSending(_ id: TaskRun.ID) {
        sendingWatch[id]?.cancel()
        sendingWatch[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(TaskDesk.sendingPatience))
            guard !Task.isCancelled, let self, let app = self.app, app.tasks.run(id)?.status == .sending else { return }
            self.apply(.waits(id))
        }
    }

    static let sendingPatience: TimeInterval = 20

    // MARK: - what the Mac says

    func apply(_ event: MacEvent) {
        guard let app else { return }
        let tasks = app.tasks
        switch event {
        case let .step(id, _), let .paying(id), let .done(id), let .failed(id, _), let .stopped(id):
            later.remove(id)
        default:
            break
        }
        switch event {
        case let .presence(presence):
            self.presence = presence
            app.browser.macAsleep = !presence.awake
            log.info("mac \(presence.awake ? "awake" : "asleep", privacy: .public)")
        case let .taken(id):
            sendingWatch[id]?.cancel()
            words {
                tasks.update(id) { $0.asleepSince = nil }
                tasks.set(id, status: .running, step: tasks.run(id)?.step ?? 0)
            }
        case let .step(id, k):
            sendingWatch[id]?.cancel()
            words {
                // Past the step that asked for the code: the site took it.
                if codes[id] != nil, let asked = tasks.definition(id)?.steps.firstIndex(where: { $0.needs == .code }), k > asked {
                    tasks.update(id) { $0.codeGiven = true }
                }
                tasks.set(id, status: .running, step: k)
            }
        case let .needsCode(id, request):
            codes[id] = request
            needsYou(id, .code)
        case let .codeRefused(id, request):
            // The site didn't take it: the boxes are asked again, and since
            // the line says the same words as before, the person is told.
            codes[id] = request
            refused.insert(id)
            tasks.update(id) { $0.codeGiven = false }
            tasks.set(id, status: .code)
            warned[id] = .code
            if onScreen() {
                Haptics.play(.warning, reason: Haptics.Reason.needsYou)
                app.say("\(request.sender) didn’t take that code. Enter the newest one.", glyph: .key1)
            }
        case let .needsYes(id, request):
            yeses[id] = request
            needsYou(id, .yes)
        case let .paying(id):
            words {
                tasks.update(id) { $0.yesGiven = true }
                tasks.set(id, status: .paying)
            }
        case let .done(id):
            let last = max(0, (tasks.definition(id)?.steps.count ?? 1) - 1)
            tasks.update(id) { $0.seen = false }
            words { tasks.set(id, status: .done, step: last) }
            codes[id] = nil
            yeses[id] = nil
        case let .failed(id, failure):
            failures[id] = failure
            // The color at once, with the error the moment wants.
            tasks.update(id) { $0.failure = failure.line }
            tasks.set(id, status: .failed)
            if onScreen() { Haptics.play(.error, reason: Haptics.Reason.failed) }
            if case .code(id)? = sheet { closeSheet() }
            if case .yes(id)? = sheet { closeSheet() }
        case let .stopped(id):
            // The person's own Stop: nothing to alarm about, the line lets it go.
            sendingWatch[id]?.cancel()
            words { tasks.set(id, status: .stopped) }
            codes[id] = nil
            yeses[id] = nil
            if sheet?.task == id { closeSheet() }
        case let .waits(id):
            sendingWatch[id]?.cancel()
            let since = presence.awake ? nil : presence.asleepSince
            words {
                tasks.update(id) { $0.asleepSince = since }
                tasks.set(id, status: .waits)
            }
        }
        log.debug("event \(String(describing: event), privacy: .public)")
        activity.sync(self)
        keepAwakeWhileLive()
    }

    /// New words for the same task change in place (0.15 s fade).
    private func words(_ change: () -> Void) {
        TaskMotion.run(.nowWords, change)
    }

    /// Needs you: orange at once (no fade), the line's nudge (NowLineView),
    /// the warning once per status, only while Yab is on screen; otherwise
    /// the Live Activity says it.
    @ObservationIgnored private var warned: [TaskRun.ID: TaskStatus] = [:]

    private func needsYou(_ id: TaskRun.ID, _ status: TaskStatus) {
        guard let app else { return }
        app.tasks.set(id, status: status)
        guard warned[id] != status else { return }
        warned[id] = status
        if onScreen() {
            Haptics.play(.warning, reason: Haptics.Reason.needsYou)
        }
    }

    // MARK: - the person's answers

    /// The code from Messages, to the Mac. The sheet goes back into the line
    /// once the boxes have shown it full (0.45 s).
    func giveCode(_ id: TaskRun.ID, code: String) {
        guard let app else { return }
        guard app.tasks.run(id)?.status == .code else { return }
        refused.remove(id)
        backend.giveCode(id, code: code)
        // Running again while the Mac signs in; codeGiven once it says the
        // site took it (its next step), or back to the boxes if not.
        words { app.tasks.set(id, status: .running) }
        activity.sync(self)
    }

    /// Codes the site didn't take: the sheet says so when it opens again.
    private(set) var refused: Set<TaskRun.ID> = []

    /// Face ID, then the signature for this exact request; the panel says
    /// Signed and the sheet goes back into the line, which says Paying.
    func approve(_ id: TaskRun.ID) async {
        guard app?.tasks.run(id)?.status == .yes, let request = yeses[id], faceID == nil, !signing else { return }
        // One signature at a time: the system's panel leaves faceID nil while it looks.
        signing = true
        let revision = approvalRevision
        defer { signing = false }
        if !signer.showsSystemPanel { TaskMotion.run(.faceIDIn) { faceID = .looking } }
        do {
            let yes = try await signer.sign(request, task: id)
            guard revision == approvalRevision, app?.tasks.run(id)?.status == .yes, yeses[id] == request, !later.contains(id) else {
                TaskMotion.run(.faceIDOut) { faceID = nil }
                return
            }
            TaskMotion.run(.faceIDIn) { faceID = .signed }
            Haptics.play(.success, reason: Haptics.Reason.done)
            try? await Task.sleep(for: .seconds(Motion.disabled ? 0 : Metrics.FaceIDPanel.signed))
            TaskMotion.run(.faceIDOut) { faceID = nil }
            guard revision == approvalRevision, app?.tasks.run(id)?.status == .yes, yeses[id] == request, !later.contains(id) else { return }
            closeSheet()
            backend.giveYes(id, yes)
        } catch {
            TaskMotion.run(.faceIDOut) { faceID = nil }
            log.info("no yes: \(String(describing: error), privacy: .public)")
            if case let YesSignerError.unavailable(why) = error {
                app?.say("Face ID isn’t available: \(why)", glyph: .faceId)
            }
        }
    }

    /// A yes being signed: Pay does nothing more until it is.
    private(set) var signing = false
    @ObservationIgnored private var approvalRevision = 0

    func notNow(_ id: TaskRun.ID) {
        guard app != nil else { return }
        later.insert(id)
        backend.notNow(id)
        closeSheet()
        activity.sync(self)
    }

    /// Yeses put off with Not Now: the Lock Screen stops asking, Review stays.
    private(set) var later: Set<TaskRun.ID> = []

    func retry(_ id: TaskRun.ID) {
        guard let app else { return }
        failures[id] = nil
        app.tasks.update(id) { $0.failure = nil }
        words { app.tasks.set(id, status: .running) }
        backend.retry(id)
        activity.sync(self)
    }

    func stop(_ id: TaskRun.ID) {
        guard app != nil else { return }
        backend.stop(id)
    }

    /// More words while it works: they go to the Mac; nothing on screen
    /// answers them, so a toast says where they went.
    func tell(_ id: TaskRun.ID, _ words: String) {
        guard let app, app.isFixture else { return }
        backend.tell(id, words)
        app.say("Told it on your Mac", glyph: .macbook)
    }

    /// The Mac's result opened: Done stops being said, the line goes.
    func seen(_ id: TaskRun.ID) {
        guard let app else { return }
        if !app.isFixture {
            guard let snapshot = app.sync.visibleLiveTask(id), snapshot.observation?.status == .done else { return }
            if !app.tasks.markLiveSeen(snapshot) {
                app.say("Couldn’t save read status on this \(DeviceWord.name)", glyph: .macbook)
            }
            return
        }
        guard app.tasks.run(id)?.status == .done else { return }
        app.tasks.markSeen(id)
        activity.sync(self)
    }

    // MARK: - the sheets that come for the person

    enum PersonSheet: Equatable {
        case code(TaskRun.ID)
        case yes(TaskRun.ID)

        var task: TaskRun.ID {
            switch self {
            case let .code(id), let .yes(id): id
            }
        }
    }

    /// Where a sheet grows from and goes back to: the Now line, a Lock
    /// Screen button, the Island; nil rises from the bottom.
    struct Origin: Equatable {
        var rect: CGRect
        var radius: CGFloat
    }

    enum FaceIDState: Equatable {
        case looking, signed
    }

    private(set) var sheet: PersonSheet?
    private(set) var sheetOrigin: Origin?
    /// The origin is in Yab (the Now line) and so still there to go back
    /// into; a Lock Screen button or the Island is gone once Yab is in front.
    private var originInYab = false
    /// 0 at its origin, 1 grown.
    var sheetGrowth: CGFloat = 0
    /// Going away with no origin to go back into: down 60 % with a fade,
    /// where it came up 105 %.
    private(set) var sheetLeaving = false
    private(set) var faceID: FaceIDState?

    // MARK: - pictures (named states)

    /// The code sheet in a picture: on the prototype's drawing of the number
    /// pad with QuickType's code, the boxes holding these digits ("" empty).
    /// Nil live: the sheet stands on the system's keyboard.
    var pictureCode: String?
    /// Yab outside Yab, drawn: the Island over another app, the Lock Screen.
    var outside: OutsideScene?

    func showCode(_ id: TaskRun.ID, from origin: Origin?, inYab: Bool = true) {
        present(.code(id), from: origin, inYab: inYab)
    }

    func showYes(_ id: TaskRun.ID, from origin: Origin?, inYab: Bool = true) {
        guard app != nil else { return }
        later.remove(id)
        present(.yes(id), from: origin, inYab: inYab)
        activity.sync(self)
    }

    /// Which presentation a closing sheet belongs to: one shown again meanwhile stays.
    @ObservationIgnored private var sheetGeneration = 0
    @ObservationIgnored private var chatGeneration = 0
    var liveChatGeneration: Int { chatGeneration }

    /// An external link takes the screen. The task keeps waiting on the Mac,
    /// but its chat, code and consent UI no longer cover the page.
    func dismissForLink() {
        guard app != nil else { return }
        approvalRevision += 1
        sheetGeneration += 1
        chatGeneration += 1
        sheet = nil
        sheetOrigin = nil
        sheetGrowth = 0
        sheetLeaving = false
        faceID = nil
        chatFold = 0
        chatPull = 0
    }

    private func present(_ sheet: PersonSheet, from origin: Origin?, inYab: Bool) {
        guard let app else { return }
        app.surfaces.closeChat()
        app.surfaces.scrim = 0
        app.surfaces.recede = 0
        app.surfaces.chromeOpacity = 1
        sheetGeneration += 1
        let generation = sheetGeneration
        sheetOrigin = origin
        originInYab = inYab
        sheetLeaving = false
        sheetGrowth = 0
        self.sheet = sheet
        if Motion.disabled {
            sheetGrowth = 1
            return
        }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.app != nil, self.sheetGeneration == generation, self.sheet == sheet else { return }
            TaskMotion.run(origin == nil ? .sheetRise : .sheetGrow) { self.sheetGrowth = 1 }
        }
    }

    /// Back into its origin if that is still on screen (the Now line it
    /// grew out of), into the Now line if it came from outside Yab and the
    /// line is there, else down and away.
    func closeSheet() {
        guard let app else { return }
        guard sheet != nil else { return }
        if Motion.disabled {
            sheet = nil
            sheetGrowth = 0
            return
        }
        let line = app.nowItem != nil && app.surfaces.field == nil
        if !line {
            sheetOrigin = nil
        } else if !originInYab, sheetOrigin != nil {
            let rect = ChromeGeometry(size: Self.screen, folded: app.chrome.folded, hasNow: true).now
            sheetOrigin = Origin(rect: rect, radius: rect.height / 2)
        }
        let back = sheetOrigin != nil
        sheetLeaving = !back
        let generation = sheetGeneration
        TaskMotion.run(back ? .sheetBack : .sheetDrop, { self.sheetGrowth = 0 }) { [weak self] in
            guard let self, self.app != nil, self.sheetGeneration == generation else { return }
            self.sheet = nil
        }
    }

    /// For named states: a sheet straight in, grown, nothing moving.
    func showStill(_ sheet: PersonSheet, faceID: FaceIDState? = nil) {
        guard app != nil else { return }
        self.sheet = sheet
        sheetOrigin = nil
        sheetLeaving = false
        sheetGrowth = 1
        self.faceID = faceID
    }

    /// For named states: what the Mac asked, as if it had.
    func setRequests(_ id: TaskRun.ID) {
        guard let app else { return }
        let script = virtualMac?.script.script(id) ?? MacScript.TaskScript()
        codes[id] = script.code
        yeses[id] = script.yes
        if app.tasks.run(id)?.status == .failed, let failure = script.failure {
            failures[id] = failure
            app.tasks.update(id) { $0.failure = failure.line }
        }
    }

    // MARK: - the Now line and the Island

    /// A tap on the Now line about a task (AppActions.tapNow): the code or
    /// the yes grows out of the line; Retry runs it again from where it
    /// stopped; anything else opens its chat out of the line.
    func tapNow(_ item: NowItem, action: String?, from frame: CGRect) {
        guard let app else { return }
        guard let id = item.taskID else { return }
        if !app.isFixture {
            guard app.sync.visibleLiveTask(id) != nil else { return }
            openChat(id, from: .nowLine(frame))
            return
        }
        guard let run = app.tasks.run(id) else { return }
        let line = Origin(rect: frame, radius: frame.height / 2)
        switch run.status {
        case .code: showCode(id, from: line)
        case .yes: showYes(id, from: line)
        case .failed where action == "Retry": retry(id)
        default: openChat(id, from: .nowLine(frame))
        }
    }

    /// Where a task's chat grows from.
    enum ChatOrigin: Equatable {
        case nowLine(CGRect)
        case island(CGRect)
        case other(CGRect?)

        var rect: CGRect? {
            switch self {
            case let .nowLine(r), let .island(r): r
            case let .other(r): r
            }
        }

        var radius: CGFloat {
            switch self {
            case let .nowLine(r): r.height / 2
            case .island: Metrics.Island.radius + 3
            case .other: Metrics.Radius.row + 2
            }
        }

        var motion: Motion {
            switch self {
            case .nowLine: .nowToChat
            case .island: .islandToChat
            case .other: .chatUnfold
            }
        }
    }

    private(set) var chatOrigin: ChatOrigin = .other(nil)
    /// 1 at its origin (the Now line, the Island), 0 at full height.
    var chatFold: CGFloat = 0
    /// How far a finger has pulled it down.
    var chatPull: CGFloat = 0

    /// A task's chat, grown out of `origin`; done and opened, it is seen.
    func openChat(_ id: TaskRun.ID, from origin: ChatOrigin) {
        guard let app else { return }
        if !app.isFixture {
            guard app.sync.visibleLiveTask(id) != nil else { return }
            seen(id)
        }
        // A task opened from Now owns this surface. A retained Chats tray
        // must stop drawing and answering touches behind it.
        if app.chatSheet.shown { app.hideSheet() }
        chatGeneration += 1
        let generation = chatGeneration
        chatOrigin = origin
        chatPull = 0
        // The task draws its own scrim. The column's previous one is finished.
        app.surfaces.scrim = 0
        app.surfaces.chromeOpacity = 1
        if app.tasks.run(id)?.status == .done { seen(id) }
        guard !Motion.disabled, origin.rect != nil else {
            chatFold = 0
            app.surfaces.openChat(.task(id), from: origin.rect)
            app.surfaces.recede = 1
            return
        }
        chatFold = 1
        app.surfaces.openChat(.task(id), from: origin.rect)
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, let app = self.app, self.chatGeneration == generation, app.surfaces.chat == .task(id) else { return }
            guard app.isFixture || app.sync.visibleLiveTask(id) != nil else {
                app.surfaces.closeChat()
                self.restorePageAfterChat()
                return
            }
            // The page steps back as the sheet stands up (.94, radius 30).
            TaskMotion.run(origin.motion) {
                self.chatFold = 0
                app.surfaces.recede = 1
            }
        }
    }

    /// Swiped down: it folds into the Now line (0.3 s) and the line speaks
    /// for the task again.
    func foldChat(velocity: CGFloat = 0) {
        guard let app else { return }
        guard case .task? = app.surfaces.chat else { return }
        let line = ChromeGeometry(size: Self.screen, folded: false, hasNow: true).now
        chatOrigin = .nowLine(line)
        if Motion.disabled {
            app.surfaces.closeChat()
            restorePageAfterChat()
            chatFold = 0
            chatPull = 0
            return
        }
        let generation = chatGeneration
        TaskMotion.run(.chatToNow, {
            self.chatFold = 1
            self.chatPull = 0
            app.surfaces.recede = 0
        }) { [weak self] in
            guard let self, let app = self.app, self.chatGeneration == generation else { return }
            app.surfaces.closeChat()
            self.chatFold = 0
            self.restorePageAfterChat()
        }
    }

    /// The page is clear once the task lets it go. Another surface may have
    /// taken it while the task's view was disappearing.
    func restorePageAfterChat() {
        guard let app else { return }
        guard app.surfaces.chat == nil, app.surfaces.field == nil,
              !app.surfaces.settings,
              !app.surfaces.join else { return }
        app.surfaces.scrim = 0
        app.surfaces.recede = 0
        app.surfaces.chromeOpacity = 1
    }

    /// The Island's rect while another app is in front (out.1).
    static var islandRect: CGRect {
        CGRect(x: (screen.width - Metrics.Island.compactWidth) / 2, y: Metrics.Island.top,
               width: Metrics.Island.compactWidth, height: Metrics.Island.size.height)
    }

    static var screen: CGSize {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.screen.bounds.size ?? Metrics.screen
    }

    /// Yab opened from the Live Activity: the Island grows the task's chat,
    /// or the sheet it needs (a code, a yes) out of the button tapped.
    func openFromActivity(_ id: TaskRun.ID, action: String?) {
        guard let app else { return }
        guard let run = app.tasks.run(id) else { return }
        let button = TaskActivityLayout.buttonRect(action: action, screen: Self.screen)
        let from = Origin(rect: button ?? Self.islandRect, radius: button == nil ? Metrics.Island.radius : Metrics.LiveActivity.button / 2 + 3)
        switch (run.status, action) {
        case (.code, _): showCode(id, from: from, inYab: false)
        case (.yes, _): showYes(id, from: from, inYab: false)
        case (.failed, "retry"): retry(id)
        default: openChat(id, from: .island(Self.islandRect))
        }
    }

    /// Stop and Not Now from the Lock Screen (TaskActivityIntent), in Yab's process.
    func act(task: TaskRun.ID, action: String) {
        guard app != nil else { return }
        switch action {
        case "stop": stop(task)
        case "notNow": notNow(task)
        case "retry": retry(task)
        default: openFromActivity(task, action: action)
        }
    }

    /// yab://task/<id>[/<action>]: the Island or a Lock Screen button opened Yab.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard app != nil else { return false }
        guard url.scheme == "yab", url.host() == "task" else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let id = parts.first else { return false }
        openFromActivity(id, action: parts.dropFirst().first)
        return true
    }

    // MARK: - while Yab is away

    /// The virtual Mac lives in this app: a little time in the background so
    /// a task keeps moving on the Island while another app is in front.
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private func keepAwakeWhileLive() {
        guard let app else { return }
        let live = app.tasks.runs.contains { [.sending, .running, .paying].contains($0.status) }
        if live, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "virtual Mac") { [weak self] in
                guard let self else { return }
                // Yab stops moving it: the Lock Screen says its words are old.
                if self.app != nil { self.activity.goesQuiet() }
                UIApplication.shared.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        } else if !live, backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
