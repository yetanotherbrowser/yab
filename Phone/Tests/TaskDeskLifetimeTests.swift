import CryptoKit
import WebKit
import XCTest
@testable import YabPhone

/// No account, external page, system authentication or Live Activity is used.
/// Weak references prove that a released app lets go of its real model and store.
@MainActor
final class TaskDeskLifetimeTests: XCTestCase {
    private var previousDisabled = false

    override func setUp() async throws {
        previousDisabled = Motion.disabled
        Motion.disabled = true
    }

    override func tearDown() async throws { Motion.disabled = previousDisabled }

    func testAReleasedAppReleasesItsDeskPoolAndTransientWebsiteStore() async throws {
        let lease = makeAppLease()
        await released { lease.app == nil && lease.desk == nil && lease.pool == nil && lease.store == nil }
        XCTAssertNil(lease.app, "the desk cannot own the app that owns it")
        XCTAssertNil(lease.desk)
        XCTAssertNil(lease.pool)
        XCTAssertNil(lease.store)
    }

    func testARetainedDeskRefusesLateEventsActionsAndActivityContentAfterItsAppIsGone() async throws {
        let retained = try retainedFixtureDesk()
        await released { retained.app == nil }
        XCTAssertNil(retained.app)
        let retiredDesk = retained.desk
        let retiredTasks = retained.tasks
        let retiredBefore = retiredTasks.runs
        let retiredDiary = retiredDesk.virtualMac?.diary
        let retiredSigner = retained.signer
        retiredDesk.apply(.stopped("lisbon"))
        retiredDesk.apply(.presence(.asleep(since: "18:52")))
        retiredDesk.apply(.needsCode("lisbon", .init(sender: "Owned", icon: "", site: "owned.test")))
        XCTAssertNil(retiredDesk.send(words: "book a flight to lisbon"))
        retiredDesk.send("lisbon", words: "book")
        retiredDesk.giveCode("lisbon", code: "owned-test-code")
        retiredDesk.retry("lisbon")
        retiredDesk.stop("lisbon")
        retiredDesk.notNow("lisbon")
        retiredDesk.tell("lisbon", "late words")
        retiredDesk.seen("lisbon")
        retiredDesk.showCode("lisbon", from: nil)
        retiredDesk.showYes("lisbon", from: nil)
        retiredDesk.openChat("lisbon", from: .other(nil))
        retiredDesk.tapNow(retained.item, action: "Review", from: .zero)
        retiredDesk.openFromActivity("lisbon", action: "review")
        retiredDesk.act(task: "lisbon", action: "retry")
        XCTAssertFalse(retiredDesk.open(URL(string: "yab://task/lisbon/review")!))
        await retiredDesk.approve("lisbon")
        await retiredDesk.whenMacAwake()
        retiredDesk.activity.sync(retiredDesk)
        XCTAssertFalse(retiredDesk.canRun)
        XCTAssertNil(retiredDesk.app)
        XCTAssertNil(retiredDesk.sheet)
        XCTAssertNil(retiredDesk.faceID)
        XCTAssertNil(TaskActivityContent.state(desk: retiredDesk))
        XCTAssertNil(retiredDesk.activity.shown)
        XCTAssertEqual(retiredTasks.runs, retiredBefore)
        XCTAssertEqual(retiredDesk.virtualMac?.diary, retiredDiary)
        XCTAssertEqual(retiredSigner.signs, 0)

    }

    func testASuspendedSignatureDoesNotRetainItsAppOrDeliverApprovalAfterOwnerRelease() async throws {
        let pending = try approvalLease()
        let desk = pending.desk
        let signature = Task { @MainActor in await desk.approve("lisbon") }
        await released { pending.signer.signs == 1 }
        XCTAssertTrue(desk.signing)
        pending.dropOwner()
        await released { pending.app == nil }
        XCTAssertNil(pending.app, "an in-flight system signer must not retain the whole app")
        let before = desk.virtualMac?.diary
        pending.signer.complete()
        await signature.value
        XCTAssertFalse(desk.signing)
        XCTAssertNil(desk.faceID)
        XCTAssertEqual(desk.virtualMac?.diary, before)
        XCTAssertFalse(desk.virtualMac?.diary.contains("Checked the Face ID signature from the \(DeviceWord.name)") ?? true)
        XCTAssertEqual(pending.tasks.run("lisbon")?.status, .yes)
    }

    func testQueuedTaskPresentationDoesNotRecedeThePageAfterItsOwnerIsReleased() async throws {
        Motion.disabled = false
        let pending = try approvalLease()
        let desk = pending.desk
        let surfaces = try XCTUnwrap(pending.app).surfaces
        desk.openChat("lisbon", from: .nowLine(CGRect(x: 12, y: 730, width: 378, height: 52)))
        XCTAssertEqual(surfaces.recede, 0)
        XCTAssertEqual(desk.chatFold, 1)
        pending.dropOwner()
        await released { pending.app == nil }
        for _ in 0..<3 { await Task.yield() }
        XCTAssertNil(desk.app)
        XCTAssertEqual(surfaces.recede, 0)
        XCTAssertEqual(desk.chatFold, 1, "a retired desk cannot finish a queued presentation")
    }

    @MainActor private final class AppLease {
        weak var app: AppModel?
        weak var desk: TaskDesk?
        weak var pool: WebPool?
        weak var store: WKWebsiteDataStore?
        init(_ app: AppModel) {
            self.app = app
            desk = app.taskDesk
            pool = app.pages
            store = app.websiteDataStore
        }
    }

    private func makeAppLease() -> AppLease {
        let space = Space(id: "public", name: "Owned", emoji: "", tint: RGB(238, 233, 226))
        let app = AppModel(world: World(name: "desk lifetime", space: space.id, spaces: [space], mac: .init(joined: false)),
                           fixturesEnabled: false, privateLockEnabled: { false })
        XCTAssertFalse(app.websiteDataStore.isPersistent)
        return AppLease(app)
    }

    @MainActor private final class ApprovalLease {
        private var owner: AppModel?
        weak var app: AppModel?
        let desk: TaskDesk
        let tasks: TaskStore
        let signer: SuspendedLifetimeSigner
        let item: NowItem

        init(_ app: AppModel, desk: TaskDesk, signer: SuspendedLifetimeSigner, item: NowItem) {
            owner = app
            self.app = app
            self.desk = desk
            tasks = app.tasks
            self.signer = signer
            self.item = item
        }
        func dropOwner() { owner = nil }
    }

    private func approvalLease() throws -> ApprovalLease {
        let app = AppModel(world: try World.load(named: "mira"))
        let signer = SuspendedLifetimeSigner()
        let desk = TaskDesk(app: app, script: MacScript(), signer: signer, still: true, activities: false)
        app.taskDesk = desk
        app.tasks.start("lisbon")
        app.tasks.set("lisbon", status: .yes, step: 3)
        desk.setRequests("lisbon")
        return ApprovalLease(app, desk: desk, signer: signer, item: try XCTUnwrap(app.nowItem))
    }

    private func retainedFixtureDesk() throws -> ApprovalLease {
        let lease = try approvalLease()
        lease.dropOwner()
        return lease
    }

    private func released(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(4)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "owned model/callback did not reach its expected lifecycle boundary")
    }
}

@MainActor
private final class SuspendedLifetimeSigner: YesSigner {
    private let key = P256.Signing.PrivateKey()
    let showsSystemPanel = true
    private(set) var signs = 0
    private var continuation: CheckedContinuation<SignedYes, Error>?
    private var request: YesRequest?
    private var task: TaskRun.ID?
    var publicKey: P256.Signing.PublicKey { key.publicKey }

    func sign(_ request: YesRequest, task: TaskRun.ID) async throws -> SignedYes {
        signs += 1
        self.request = request
        self.task = task
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func complete() {
        guard let continuation, let request, let task else { return }
        self.continuation = nil
        let digest = request.digest(task: task)
        do { continuation.resume(returning: SignedYes(digest: digest, signature: try key.signature(for: digest).rawRepresentation)) }
        catch { continuation.resume(throwing: error) }
    }
}
