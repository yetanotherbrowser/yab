import AppKit
import ImageIO
import QuartzCore
import Combine
import YabCoreClient
import NativeTextInput

/// Remote pixels and native input only. StageView owns clipping and corners.
@MainActor
final class ChromiumPage: YabTextCheckingView, PageHandle, PageAudioControl {
    let engine = PageEngineKind.chromium
    weak var events: (any PageEvents)?
    weak var stateEvents: (any PageStateEvents)?
    private(set) var url: URL?
    private(set) var committedURL: URL?
    var historyEntry: PageHistoryEntry? { committedURL.map { PageHistoryEntry(url: $0, title: title ?? "") } }
    private(set) var title: String?
    private(set) var isLoading = false
    var estimatedProgress: Double { isLoading ? 0.5 : 1 }
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    var themeColor: NSColor?
    var lastInput: TimeInterval?
    var pageZoom: CGFloat = 1 { didSet { applyZoom() } }
    var magnification: CGFloat = 1 { didSet { applyZoom() } }
    private(set) var contentProcess: pid_t?
    private(set) var audioMuted = false
    var gpuProcess: pid_t? { nil }
    var captureStatus: PageCaptureStatus { media.captureStatus }
    /// Sound, Now Playing, capture and full screen (ChromiumPage+Media.swift).
    let media = ChromiumMedia()
    let sleepState = ChromiumSleep()
    var videoPiP: ChromiumVideoPiP?
    var nativeVideoPiPKnown = false
    var nativeVideoPiPRevision: UInt64 = 0
    private(set) var remoteID: String? {
        didSet {
            if remoteID != oldValue { ChromiumTabGroups.shared.changed() }
        }
    }
    private(set) var contextID: UInt32 = 0
    let scripts = ChromiumScripts()
    lazy var swipe = ChromiumSwipe(self)
    let fileRequests = PageFileRequests()
    let questionRequests = ChromiumQuestionRequests()
    let dragState = ChromiumDragState()
    var topGrab = false {
        didSet { if !topGrab { topGrabPoint = nil } }
    }
    /// The page point that actually passed the header hit test, in CSS pixels.
    var topGrabPoint: CGPoint?
    private var topPress: TopPress?
    var pageCursor = NSCursor.arrow
    var menuKey: NSEvent?
    var resentKey: NSEvent?
    var tipText = ""
    let remoteAccessibility = ChromiumRemoteAccessibility()
    /// A native document child has a panel owner, never a tab-strip row.
    var onDocumentClosed: (@MainActor () -> Void)?
    /// The size a page's own floating window asked for (DocumentPiP).
    var onDocumentSize: (@MainActor (NSSize) -> Void)?
    /// This page is Chrome's DevTools for another (ChromiumDevTools.swift).
    var isDevToolsFrontend = false
    /// The page the last time it was in front (`pictureSoon`).
    private(set) var lastPicture: NSImage?
    private var pictureTask: Task<Void, Never>?
    weak var navigationTab: Tab?
    private var tab: Tab? { get { navigationTab } set { navigationTab = newValue } }
    private(set) var diagnosticFailure: String?
    private var navigationTarget: URL?
    var nativeFindTask: Task<Void, Never>?
    var nativeFindEpoch = 0
    var nativePrintTask: Task<Void, Never>?
    var nativePrintRequestID: String?
    var nativePrintEpoch = 0
    var originalPDFPresence = ChromiumOriginalPDFPresenceState()
    var originalPDFObservationTask: Task<Void, Never>?
    var originalPDFPeer: YabCoreClient?
    var originalPDFHooks: [String: JSONValue] = [:]
    /// Local navigation blocks re-observation until native commit/adoption.
    var originalPDFAdmissionAllowed = true
    /// Actual PDF handed to the native sheet, exposed only in disposable probes.
    var printPreviewForTesting: [String: Any] = [:]
    let profile: String
    let privateMode: Bool
    var profileSpaceID: UUID? {
        guard !privateMode, let tab = navigationTab else { return nil }
        return ChromiumPersistentProfiles.plan(for: tab.pageStore).logical
    }
    private weak var extensionTab: Tab?
    private var extensionWatch: AnyCancellable?
    private(set) lazy var extensions = ChromiumExtensions.shared(profile: profile, privateMode: privateMode, store: navigationTab?.pageStore)
    /// A close batch committed this page (Leaving): its row is the batch's to keep or drop.
    var closeCommitted = false
    private(set) var retired = false
    private var helperWasLost = false
    /// Where a page went on being when its helper was lost, until it is shown.
    private var recovering: URL?
    private var operationEpoch = 0
    private(set) var documentTurn = 0
    /// The last whole picture of the page as shown, still encoded, for a
    /// moment (`recentWholePicture`).
    private var recentWhole: RecentWhole?
    private var scriptTarget: URL?
    private var lastReadiness: [String: Any] = [:]
    private var lastLoadError: [String: Any] = [:]
    private var scriptAttachmentFailure: String?
    private var drmTurn = 0
    /// The page's certificate, as Site Controls reads it (ChromiumPage+Tools).
    var serverTrust: SecTrust?
    /// What device mode last asked of the helper.
    var emulated: [Double]?
    var emulatedAgent: String?
    var minimumFontAsked = 0
    var familiesAsked: PageFamilies.Names?
    /// The last press on the page, for the link it may be about to follow.
    weak var popupBackSource: Tab?
    /// Selection waits for the first native action to choose Peek or a tab.
    var popupForegroundFrom: Tab.ID?
    var popupRequestedForeground: Bool?
    var lastPress: (flags: NSEvent.ModifierFlags, button: Int, at: TimeInterval)?
    /// Click trackers skipped in a row (receiveAction).
    var skips = 0
    /// ⇧ or ⌥ pressed on a link: Yab's click, never the page's or Chrome's.
    var modifiedLink: URL?
    var modifiedDown: NSEvent?
    var modifiedLinkDown: NSEvent?
    var modifiedUp: NSEvent?
    var forceInput = ChromiumForceClickInput()
    private var creating: Task<(YabCoreClient, String), Error>?
    private var navigationBinding: Task<Void, Never>?
    private(set) var tail: Task<Void, Never>?
    private var inputSubmission: Task<Void, Never>?
    private var inputReplies: [UUID: Task<Void, Never>] = [:]
    @MainActor private final class InputReply { var task: Task<Void, Never>? }
    private let remoteParent = CALayer()
    private var remoteLayer: CALayer?
    private var extensionPageOffset: CGPoint = .zero
    private var resizeState = ChromiumResize()
    /// The document and renderer the helper last said this surface shows
    /// (layer.changed `generation`, `renderer`).
    private var surfaceOwner: (generation: Double, renderer: Double)?
    private var viewportPaint: (size: CGSize, done: () -> Void)?

    /// The stage registers after setting the viewport. Do not acknowledge an
    /// RPC reply: only the native compositor receipt has the new canvas.
    func afterViewportPaint(_ done: @escaping () -> Void) {
        viewportPaint = (currentGeometry.size, done)
    }
    func cancelViewportPaint() { viewportPaint = nil }

    private var desiredGeometry: ChromiumResize.Geometry?
    private var sentGeometry: ChromiumResize.Geometry?
    /// The page's bottom left in screen points, its size (a resize moves the
    /// window's bottom) and its screen.
    struct ProducerPlace: Equatable { let x: CGFloat, y: CGFloat, size: CGSize, screen: CGDirectDisplayID }
    /// Where the hidden window was last put (placeProducer); nil for a new one.
    private var placedProducer: ProducerPlace?
    private var geometryQueued = false
    /// Which queued geometry operation owns geometryQueued.
    private var geometryTurn = 0
    /// A tab.visible threw: the helper may or may not have applied it (a hide
    /// can answer an error from its focus cleanup on an iframe's session that
    /// has just gone, #883). The next sync sends visibility whatever
    /// sentGeometry says; trusting it left the page hidden in the helper
    /// while Yab counted it shown, and no show was sent again.
    private var visibilityUnknown = false
    private var navigation: PageNavigation?
    private var awaitingInitialDocument = false
    var reachingFirstDocument: Bool { awaitingInitialDocument && !warmed }
    /// Ahead of a first navigation (`warmUp`): its bootstrap blank says nothing about the tab.
    private var warming = false, warmed = false
    /// Read by the isolated spare-replenishment probe after endpoint setup.
    var isWarmSpare: Bool { warmed && !warming && creating == nil && remoteID != nil && !retired && !helperWasLost }
    private var shownWaiters: [() -> Void] = []
    private var initialNativeLoading: Bool?
    private var initialRequestedURL: URL?
    private var tracking: NSTrackingArea?
    /// Owns `tracking`, so each move reaches the page once (MoveTracker).
    private lazy var moveTracker = MoveTracker(page: self)
    private weak var lastPointerMove: NSEvent?
    /// The pointer moved inside since it last came in (ChromiumPage+Hover).
    var hoverAdmitted = false {
        didSet {
            if hoverAdmitted { Self.pointerPage = self } else if Self.pointerPage === self { Self.pointerPage = nil }
        }
    }
    /// The page whose last move admitted the pointer (answerCursorUpdate).
    static weak var pointerPage: ChromiumPage?
    var hoverMovePending = false
    var hoverMovedAt: TimeInterval = 0
    /// For the acceptance eval: pointer moves seen, helper status messages
    /// heard, and the window's own copies of moves left alone (`echoes`).
    var hoverCounts = (moved: 0, status: 0, last: "", heard: [String](), echoes: 0)
    var editingKeyCodes = Set<UInt16>()
    var pageCopyTurn = 0
    private var marked = NSAttributedString(string: "")
    private var markedStart = NSNotFound
    /// Local invalidation only, never a native document lease.
    private(set) var inputMethodGeneration = 0
    private(set) var inputMethodDispatched = 0
    private(set) var inputMethodTicket: ChromiumInputMethodTicket?
    var inputMethodTurn: Int { documentTurn }
    var inputMethodLive: Bool { !retired && !helperWasLost && remoteID != nil }
    func afterInputMethodDispatch(_ done: @escaping @MainActor () -> Void) {
        let accepted = tail
        Task { @MainActor in await accepted?.value; done() }
    }
    func discardNativeComposition() {
        inputMethodGeneration &+= 1
        marked = NSAttributedString(string: "")
        markedStart = NSNotFound
        keyInterpretation = nil
        imeHandled = false
        imeKeys.removeAll()
    }
    // Own CEF text input (ChromiumPage+TextInput.swift).
    var nativeText: [String: JSONValue]? {
        didSet { syncNativeInputContext() }
    }
    private lazy var nativeInputContext = NSTextInputContext(client: self)
    private var nativeInputContextActive = false
    var nativeTextChecking: NSTextCheckingController?
    var nativeTextCheckingSnapshot: ChromiumTextCheckingSnapshot?
    override var inputContext: NSTextInputContext? {
        nativeInputEligible ? nativeInputContext : nil
    }
    /// Keep the context we activated: the getter intentionally becomes nil on blur.
    func syncNativeInputContext(resigning: Bool = false) {
        let active = !resigning && nativeInputEligible
        syncNativeTextChecking(active: active)
        if active {
            nativeInputContext.invalidateCharacterCoordinates()
            if !nativeInputContextActive { nativeInputContext.activate() }
        } else if nativeInputContextActive {
            nativeInputContext.invalidateCharacterCoordinates()
            nativeInputContext.deactivate()
        }
        nativeInputContextActive = active
    }
    // AppKit reads this Objective-C getter from its actual input client.
    // Until an authenticated field report arrives, offer no guessed OTP hint.
    @objc var contentType: NSTextContentType? = .URL {
        didSet {
            if contentType != oldValue { inputContext?.invalidateCharacterCoordinates() }
        }
    }
    var remoteFocused: Bool?
    /// The page holds the pointer (ChromiumPointerLock).
    var pointerLocked = false
    var keyWatch: [NSObjectProtocol] = []
    var imeHandled = false
    var imeKeys: Set<UInt16> = []
    var keyInterpretation: ChromiumKeyInterpretation?
    /// Routing receipts in disposable test worlds only.
    var keyRoutes: [String] = []
    var pressureStage = 0
    private var stepButton: Int?
    var selectMenu: NSMenu?
    var selectToken: Int?
    // Own CEF extension hooks (ChromiumPage+Popup.swift).
    var extensionPopup: ChromiumExtensionPopup?
    var onExtensionPopup: (@MainActor (ChromiumExtensionPopup?) -> Void)?
    var onExtensionTabCreated: (@MainActor (ExtensionTabRequest) -> Void)?
    private var desiredAudioMuted: Bool

    init(tab: Tab, profile: String? = nil) {
        navigationTab = tab
        self.profile = profile ?? tab.chromiumProfile
        privateMode = tab.shy || !tab.pageStore.isPersistent
        extensionTab = tab
        desiredAudioMuted = tab.muted
        super.init(frame: .zero)
        // Ask for the second pressure stage before the first mouse-down,
        // as a WebKit link view does. A generic one-stage press cannot Peek.
        pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
        registerForDraggedTypes(Self.draggedTypes)
        scripts.page = self
        scripts.tab = tab
        wantsLayer = true
        // Match Chromium's CALayerHost geometry. Its bounds MUST stay zero.
        remoteParent.isGeometryFlipped = true
        layer?.addSublayer(remoteParent)
        extensionWatch = extensions.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.tellNativeStore() }
        }
    }
    required init?(coder: NSCoder) { nil }
    func adoptRemote(_ id: String) {
        precondition(remoteID == nil && creating == nil && !retired)
        remoteID = id
        ChromiumProcess.shared.attach(self, id: id)
        // Native popups bypass endpoint()'s creation path. They still need
        // the same feature scripts and authenticated relays in their first
        // document, including the swipe ownership answer.
        refreshFeatureScripts(to: navigationTab?.address, currentDocument: true)
        if desiredAudioMuted { command("media.mute", ["muted": .bool(true)]) }
        command("script.bind", ["world": .string("yab-world-yab"), "name": .string("yabFindChanged")])
        syncGeometry()
    }
    // Match the separate-process reference host: an ordinary AppKit view
    // with one flipped child layer, not two nested flipped coordinate spaces.
    override var isFlipped: Bool { false }
    /// AppKit can replace this view's backing layer (a popup taking and
    /// returning the stage, another window) without a size change, a layout
    /// or any helper event. The remote page hangs from that layer: host it
    /// on the new backing at the moment it arrives, not when a resize or a
    /// key window happens to repair it.
    override var layer: CALayer? {
        get { super.layer }
        set { super.layer = newValue; restoreSurfaceAttachment() }
    }
    override var acceptsFirstResponder: Bool { true }
    /// A floating window's buttons take the press that also brings it forward:
    /// someone working in the browser mutes a call with one click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { window is DocumentPiPPanel }

    func endpoint() async throws -> (YabCoreClient, String) {
        guard let owner = navigationTab, owner.chromiumProfile == profile else { throw SiteEngineError.profileChanged }
        try ChromiumPrivateProfiles.authorize(profile, store: owner.pageStore, privateMode: privateMode)
        // Geometry, snapshots and script refreshes cannot replace a lost
        // document with an empty bootstrap tab. Navigation owns recovery.
        guard !retired, !helperWasLost else { throw YabCoreError.disconnected }
        if let creating { return try await creating.value }
        if let remoteID { return (try await ChromiumProcess.shared.connection(), remoteID) }
        // DevTools' frontend only ever adopts Chrome's own tab: an empty one
        // made here would race devtools.open.
        guard !isDevToolsFrontend else { throw YabCoreError.disconnected }
        let epoch = operationEpoch
        let task = Task { @MainActor () throws -> (YabCoreClient, String) in
            OpenTrace.mark("chromium.endpoint")
            let core = try await ChromiumProcess.shared.connection()
            try await ChromiumPrivateProfiles.open(profile, privateMode: privateMode, core: core)
            if !privateMode {
                await ChromiumPermissions.opened(profile, core: core)
                // A clearing that failed is paid before any page of the profile.
                await ChromiumClearingDebt.settle(profile, core: core)
            }
            OpenTrace.mark("chromium.profile")
            // The jar's own tab beside this one, not after it: the first
            // navigation waits for its host's cookies.
            (try? ChromiumDRMCookies.of(owner))?.startImport()
            // CEF's empty URL creates an initial, unnavigated document. An
            // explicit about:blank would become a spurious first Back entry.
            // Chrome WebUI must be the browser's initial URL: navigating a
            // normal renderer there is rejected with ERR_ABORTED in this CEF.
            let destination = self.scriptTarget ?? owner.address
            let initial = ChromePages.needsChromium(destination) ? destination?.absoluteString ?? "" : ""
            let id = try await core.createTab(profile: profile, url: initial)
            guard !Task.isCancelled, !retired, operationEpoch == epoch, ChromiumProcess.shared.isCurrent(core) else {
                try? await core.closeTab(id); throw CancellationError()
            }
            remoteID = id
            OpenTrace.mark("chromium.tab")
            ChromiumProcess.shared.attach(self, id: id)
            // Native APIs must see its real logical window before this new
            // endpoint can navigate or execute an extension's first script.
            try await ChromiumTabGroups.shared.syncNow()
            self.syncRemoteFocus()
            do { try await scripts.install(core: core, tab: id) }
            catch {
                if operationEpoch == epoch, ChromiumProcess.shared.isCurrent(core), remoteID == id {
                    ChromiumProcess.shared.detach(id); remoteID = nil
                }
                throw error
            }
            // createTab replies only once the native endpoint accepts LoadURL. The
            // unnavigated document has no renderer yet, so the helper brings up
            // the agent that scripts need with a blank document of its own
            // (scripts.inc ScriptWithAgent): nothing here waits on a document.
            OpenTrace.mark("chromium.scripts")
            if desiredAudioMuted { _ = try await core.request("media.mute", params: ["tab": .string(id), "muted": .bool(true)]) }
            try await self.sendGeometry(core, id, self.currentGeometry)
            placeProducer()
            OpenTrace.mark("chromium.geometry")
            guard !Task.isCancelled, !retired, operationEpoch == epoch,
                  ChromiumProcess.shared.isCurrent(core), remoteID == id else { throw CancellationError() }
            // Runtime binding may await the first document. It must not hold
            // LoadURL or the native auth/certificate continuation behind it.
            navigationBinding = Task { @MainActor [weak self] in
                guard let self, self.remoteID == id else { return }
                do {
                    _ = try await core.request("script.bind", params: ["tab": .string(id), "world": .string("yab-world-yab"), "name": .string("yabFindChanged")])
                } catch {
                    if !Task.isCancelled { DebugLog.note("chromium-binding", ["error": String(describing: error)]) }
                }
            }
            return (core, id)
        }
        creating = task
        do { let result = try await task.value; if operationEpoch == epoch { creating = nil }; return result }
        catch { if operationEpoch == epoch { creating = nil }; throw error }
    }
    /// A spare tab's page gets its helper, profile, native tab, scripts and
    /// cookies now, so the first page it is given only has to load, with a
    /// renderer already running, as a page in Chrome's spare does.
    func warmUp() {
        guard remoteID == nil, creating == nil, !retired, let owner = navigationTab, !warmed, !LinkGap.cut("chromium.warm") else { return }
        warming = true; warmed = true
        awaitingInitialDocument = true
        enqueue { [weak self] _, _ in
            defer { self?.warming = false }
            (try? ChromiumDRMCookies.of(owner))?.startImport()
        }
    }
    /// Picked: the window's redraw for a switch holds the main thread 20-30 ms
    /// before this page reaches the stage, and its renderer needs none of it.
    /// The queue's own geometry says the same when the page gets there, and
    /// says hidden if it never does.
    func willShow() {
        guard let id = remoteID, !retired, sentGeometry?.visible == false, !LinkGap.cut("chromium.show"),
              let core = ChromiumProcess.shared.connectedClient else { return }
        Task.detached(priority: .userInitiated) { _ = try? await core.request("tab.visible", params: ["tab": .string(id), "visible": .bool(true)]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.remoteID == id, self.sentGeometry?.visible == false, !self.currentGeometry.visible else { return }
            self.command("tab.visible", ["visible": .bool(false)])
        }
    }
    /// Waiting for the document asked for to be on screen (afterFirstPaint).
    private var paintWaiters: [@MainActor (Bool) -> Void] = []
    /// `done(true)` once the document this page was sent to has drawn and
    /// its surface is hosted here: committed (never the helper's bootstrap
    /// blank), the native surface acknowledged at this view's size so the
    /// host shows (ChromiumResize.canPresent), and two of the document's
    /// animation frames past (afterNextFrame), the first one handed to the
    /// compositor. What WebKit's next presentation update says of a WebKit
    /// view. Before that the view shows nothing of the page, and a holder
    /// shown meanwhile is an empty card. `done(false)` when the page goes.
    func afterFirstPaint(_ done: @escaping @MainActor (Bool) -> Void) {
        guard !retired else { return done(false) }
        paintWaiters.append(done)
        firstPaintMayHaveCome()
    }
    private func firstPaintMayHaveCome() {
        guard !paintWaiters.isEmpty, !awaitingInitialDocument, committedURL != nil,
              resizeState.canPresent, remoteLayer?.superlayer === remoteParent else { return }
        let waiters = paintWaiters
        paintWaiters = []
        afterNextFrame { drawn in waiters.forEach { $0(drawn) } }
    }
    /// Once the helper has this page in front, for the switch's redraw to come after it.
    func afterShown(_ done: @escaping () -> Void) {
        if sentGeometry?.visible == true, !geometryQueued { done() } else { shownWaiters.append(done) }
    }
    /// Serialize accepted user operations, especially down/text/up and resize.
    private func enqueue(navigation: Bool = false, request: String = "page.feature",
                         _ operation: @escaping @MainActor (YabCoreClient, String) async throws -> Void) {
        let previous = tail
        // Non-streaming operations remain completion barriers, including resize,
        // navigation and keys. Later pointer/wheel input must wait for them.
        inputSubmission = nil
        let epoch = operationEpoch
        tail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !self.retired, !Task.isCancelled, self.operationEpoch == epoch else { return }
            do {
                let (core, id) = try await self.endpoint()
                guard !Task.isCancelled, self.operationEpoch == epoch, ChromiumProcess.shared.isCurrent(core) else { return }
                try await operation(core, id)
            }
            catch {
                if !self.retired, self.operationEpoch == epoch {
                    self.queuedOperationFailed(error, navigation: navigation, request: request)
                }
            }
        }
    }
    func command(_ method: String, _ params: [String: JSONValue] = [:]) {
        enqueue(navigation: ["tab.reload", "tab.back", "tab.forward", "history.go", "tab.restore"].contains(method), request: method) { core, id in
            var p = params; p["tab"] = .string(id)
            _ = try await core.request(method, params: p)
        }
    }
    private func enqueueStreamingInput(_ fields: [String: JSONValue]) {
        let previousSubmission = inputSubmission ?? tail
        let previousCompletion = tail
        let epoch = operationEpoch
        let reply = InputReply()
        let submission = Task { @MainActor [weak self] in
            await previousSubmission?.value
            guard let self, !retired, !Task.isCancelled, operationEpoch == epoch else { return }
            do {
                let (core, id) = try await endpoint()
                guard operationEpoch == epoch, !retired, ChromiumProcess.shared.isCurrent(core) else { return }
                var params = fields; params["tab"] = .string(id)
                let inputParams = params
                await withCheckedContinuation { (sent: CheckedContinuation<Void, Never>) in
                    let token = UUID()
                    reply.task = Task { @MainActor [weak self] in
                        defer { self?.inputReplies[token] = nil }
                        guard let self, !retired, operationEpoch == epoch, ChromiumProcess.shared.isCurrent(core) else {
                            sent.resume(); return
                        }
                        do { _ = try await core.sendInput(inputParams, submitted: { sent.resume() }) }
                        catch {
                            if !retired, operationEpoch == epoch { queuedOperationFailed(error, navigation: false, request: "input.send") }
                        }
                    }
                    inputReplies[token] = reply.task
                }
            } catch {
                if !retired, operationEpoch == epoch { queuedOperationFailed(error, navigation: false, request: "input.send") }
            }
        }
        inputSubmission = submission
        // Existing queueTail readers (snapshots, scripts and teardown) still
        // wait for every reply, even though consecutive pointer/wheel events stream.
        tail = Task { @MainActor in
            await previousCompletion?.value
            await submission.value
            await reply.task?.value
        }
    }
    private func cancelStreamingInput() {
        inputSubmission?.cancel(); inputSubmission = nil
        let replies = Array(inputReplies.values)
        inputReplies.removeAll()
        replies.forEach { $0.cancel() }
    }
    /// A rejected input/appearance/script command is not a failed document.
    /// Keep navigation submission and endpoint creation errors visible; CEF
    /// independently reports real network failures and renderer termination.
    func queuedOperationFailed(_ error: Error, navigation: Bool, request: String) {
        guard !(error is CancellationError) else { return }
        if navigation || remoteID == nil {
            NSLog("Chromium navigation %@ failed: %@", request, String(describing: error))
            failed(error)
        }
        else {
            scriptAttachmentFailure = "\(request): \(error)"
            NSLog("Chromium feature %@ failed: %@", request, String(describing: error))
        }
    }
    /// A live site setting changed. Replace document-start registrations
    /// before a subsequent reload, in the same queue as navigation and input.
    func refreshFeatureScripts(to target: URL? = nil, currentDocument: Bool = false) {
        enqueue(request: "scripts.prepare") { [weak self] core, id in
            guard let self else { return }
            try await self.scripts.prepare(core: core, tab: id, url: target ?? self.url, currentDocument: currentDocument)
        }
    }
    /// The last command queued, to tell whether something was queued since.
    var queueTail: Task<Void, Never>? { tail }
    /// Complete native selection before a page feature reads that selection.
    func afterAcceptedInput(_ done: @escaping @MainActor () -> Void) {
        let accepted = tail
        Task { @MainActor [weak self] in
            await accepted?.value
            guard let self, !self.retired else { return }
            done()
        }
    }
    /// Navigation capabilities use the same endpoint and accepted-operation order.
    func navigationRequest(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        await tail?.value
        let (core, id) = try await endpoint()
        var p = params; p["tab"] = .string(id)
        return try await core.request(method, params: p)
    }
    /// The current PDF URL, read by the helper's network stack in this tab's
    /// cookie context. This remains available on the pinned shipping SDK.
    func sourcePDFBytes() async throws -> Data {
        await tail?.value
        let (core, id) = try await endpoint()
        let epoch = operationEpoch, turn = documentTurn, address = url
        func current() -> Bool {
            !Task.isCancelled && !retired && operationEpoch == epoch && documentTurn == turn &&
                remoteID == id && url == address && ChromiumProcess.shared.isCurrent(core)
        }
        guard current() else { throw CancellationError() }
        let stream = UUID().uuidString
        do {
            let opened = try await core.request("page.pdf.source", params: ["tab": .string(id), "stream": .string(stream)])
            guard opened["stream"].string == stream, current(), opened["url"].string == address?.absoluteString else { throw CancellationError() }
            var data = Data()
            var eof = false
            while !eof {
                guard current() else { throw CancellationError() }
                let reply = try await core.request("page.pdf.read", params: ["tab": .string(id), "stream": .string(stream)])
                guard current(), let encoded = reply["data"].string,
                      case .bool(let end) = reply["eof"] else { throw CancellationError() }
                let chunk: Data
                if reply["base64Encoded"] == .bool(true) {
                    guard let decoded = Data(base64Encoded: encoded) else { throw AgentPDF.Failure() }
                    chunk = decoded
                } else { chunk = Data(encoded.utf8) }
                data.append(chunk)
                eof = end
            }
            return data
        } catch {
            _ = try? await core.request("page.pdf.close", params: ["tab": .string(id), "stream": .string(stream)])
            throw error
        }
    }

    func captureOriginalPDFEndpoint() async throws -> OriginalPDFEndpoint {
        guard !Task.isCancelled, !retired, !helperWasLost, !isLoading,
              let remote = remoteID, let core = originalPDFPeer,
              let scope = originalPDFPresence.owner, let presence = originalPDFPresence.ready,
              originalPDFPresenceOwnerIsCurrent(scope, core: core),
              let tab = navigationTab, tab.builtPage === self else {
            throw CancellationError()
        }
        let endpoint = OriginalPDFEndpoint(core: core,
            binding: OriginalPDFBinding(tab: remote, profile: profile, call: UUID().uuidString),
            epoch: operationEpoch, turn: documentTurn, printEpoch: nativePrintEpoch,
            generation: scope.process, observation: scope.observation, owner: ObjectIdentifier(tab), presence: presence)
        let accepted = tail
        let hooks = await core.nativeHooks
        guard ChromiumOriginalPDFPresenceState.supported(hooks) else {
            throw YabCoreError.remote("Original native PDF bytes are unavailable on this endpoint")
        }
        await accepted?.value
        guard !Task.isCancelled, originalPDFEndpointIsCurrent(endpoint) else { throw CancellationError() }
        return endpoint
    }
    func originalPDFEndpointIsCurrent(_ endpoint: OriginalPDFEndpoint) -> Bool {
        !retired && !helperWasLost && !isLoading && remoteID == endpoint.binding.tab &&
            profile == endpoint.binding.profile && operationEpoch == endpoint.epoch &&
            documentTurn == endpoint.turn && nativePrintEpoch == endpoint.printEpoch &&
            originalPDFPeer === endpoint.core && originalPDFPresence.owner?.observation == endpoint.observation &&
            originalPDFPresence.ready == endpoint.presence && originalPDFPresence.admission != nil &&
            originalPDFPresence.owner.map { originalPDFPresenceOwnerIsCurrent($0, core: endpoint.core) } == true &&
            ChromiumProcess.shared.isCurrent(endpoint.core, generation: endpoint.generation) &&
            navigationTab.map { ObjectIdentifier($0) == endpoint.owner && $0.builtPage === self } == true
    }
    func captureOriginalPDFPresenceOwner(core: YabCoreClient) -> ChromiumOriginalPDFPresenceState.Owner? {
        guard !retired, !helperWasLost, originalPDFAdmissionAllowed, let remoteID, let tab = navigationTab,
              tab.builtPage === self, originalPDFPeer === core, ChromiumProcess.shared.isCurrent(core),
              originalPDFProfileIsCurrent(tab) else { return nil }
        return .init(peer: ObjectIdentifier(core), process: ChromiumProcess.shared.connectionGeneration,
                     tab: remoteID, profile: profile, pageOwner: ObjectIdentifier(tab), store: ObjectIdentifier(tab.pageStore),
                     epoch: operationEpoch, turn: documentTurn, observation: UUID())
    }
    func originalPDFPresenceOwnerIsCurrent(_ owner: ChromiumOriginalPDFPresenceState.Owner, core: YabCoreClient) -> Bool {
        !retired && !helperWasLost && originalPDFPeer === core && owner.peer == ObjectIdentifier(core) &&
            originalPDFPresence.owner == owner && remoteID == owner.tab && profile == owner.profile &&
            operationEpoch == owner.epoch && documentTurn == owner.turn &&
            ChromiumProcess.shared.isCurrent(core, generation: owner.process) &&
            navigationTab.map { ObjectIdentifier($0) == owner.pageOwner && $0.builtPage === self &&
                ObjectIdentifier($0.pageStore) == owner.store && originalPDFProfileIsCurrent($0) } == true
    }
    private func originalPDFProfileIsCurrent(_ tab: Tab) -> Bool {
        guard tab.chromiumProfile == profile else { return false }
        do {
            try ChromiumPrivateProfiles.authorize(profile, store: tab.pageStore, privateMode: privateMode)
            return true
        } catch { return false }
    }
    func originalPDFPresenceBecameUnavailable() {
        guard let tab = navigationTab, tab.builtPage === self else { return }
        tab.paper.nativePresenceUnavailable()
    }
    func presentOriginalPDFPresence() {
        guard !isLoading, let core = originalPDFPeer, let scope = originalPDFPresence.owner,
              originalPDFPresenceOwnerIsCurrent(scope, core: core), let identity = originalPDFPresence.ready,
              let tab = navigationTab else { return }
        tab.paper.nativePresenceReady(identity, tab: tab, page: self,
                                      visible: window != nil && !isHiddenOrHasHiddenAncestor)
    }
    /// A native continuation must not wait behind the script that requested it.
    /// In particular, window.print() can be suspended in the operation queue.
    func finishNativePrint(_ request: String, remote: String) async throws -> Bool {
        guard !retired, remoteID == remote else { throw CancellationError() }
        let core = try await ChromiumProcess.shared.connection()
        guard !retired, remoteID == remote, ChromiumProcess.shared.isCurrent(core) else { throw CancellationError() }
        let reply = try await core.request("print.finish", params: ["tab": .string(remote), "request": .string(request)])
        return reply["finished"] == .bool(true)
    }
    func navigate(to request: URLRequest) {
        navigationTarget = request.url
        diagnosticFailure = nil
        guard let target = request.url else { return }
        topGrab = false
        topPress = nil
        swipe.invalidate()
        documentTurn &+= 1
        invalidateOriginalPDFPresence()
        scriptTarget = target
        drmTurn &+= 1
        if let tab, tab.builtPage === self, tab.wantsWebKit(for: target) {
            // A page that never showed a document (a new tab opened straight
            // to Netflix) has nothing to ask before it goes: the switch's
            // native approval waited on a document that never came, and
            // the tab stayed blank on Chromium.
            if url == nil || url?.absoluteString == "about:blank" {
                DispatchQueue.main.async { [weak self, weak tab] in
                    guard let self, let tab, tab.builtPage === self, !self.retired else { return }
                    tab.replaceEngine(with: .webKit, at: request)
                }
                return
            }
            switchToWebKit(request)
            return
        }
        let navigation: ChromiumDRMNavigation
        do { navigation = try ChromiumDRMNavigation(request) }
        catch { failed(error); return }
        helperWasLost = false
        recovering = nil
        awaitingInitialDocument = (remoteID == nil || warming) && target.absoluteString != "about:blank"
        warmed = false
        markLoading()
        enqueue(navigation: true, request: "tab.navigate") { [weak self] core, id in
            if let self, let tab = self.tab {
                guard tab.chromiumProfile == self.profile else { throw SiteEngineError.profileChanged }
                // Cookies that didn't carry over cost a sign-in, never the page.
                OpenTrace.mark("chromium.cookies.begin")
                do { if !LinkGap.cut("chromium.cookies") { try await ChromiumDRMCookies.of(tab).prepare(for: target, in: .chromium, page: tab.id) } }
                catch is CancellationError { throw CancellationError() }
                catch { NSLog("DRM cookies: not carried over: %@", String(describing: error)) }
                OpenTrace.mark("chromium.cookies.end")
                guard !self.retired, tab.builtPage === self else { throw CancellationError() }
                self.adoptExtensions(for: tab)
            }
            try await self?.scripts.prepare(core: core, tab: id, url: target)
            OpenTrace.mark("chromium.prepared")
            try await core.navigate(tab: id, parameters: navigation.parameters)
            OpenTrace.mark("chromium.navigate")
        }
    }
    /// A page that reached a site with a rule for WebKit by itself. A window
    /// another page opened and still talks to stays with it: the switch would
    /// cut window.opener, and a sign-in in that window would never end. Only
    /// the page can say, as a link with noopener gets a tab with no opener.
    private func switchUnlessOpened(_ request: URLRequest) {
        guard tab?.opener != nil else { switchToWebKit(request); return }
        let turn = drmTurn
        Task { @MainActor [weak self] in
            guard let self, self.drmTurn == turn, !self.retired else { return }
            let answer = try? await self.call("return window.opener !== null", in: .client, gesture: false)
            guard self.drmTurn == turn, !self.retired, answer as? Bool == false else { return }
            self.switchToWebKit(request)
        }
    }

    /// A first page in this profile joins it to the sign-in's one list.
    private func adoptExtensions(for tab: Tab) {
        guard #available(macOS 15.4, *), !tab.shy, !extensions.adopting, let browser = tab.delegate as? Browser else { return }
        extensions.joinList(signIn: Extensions.signIn(of: browser.spaceHolding(tab) ?? browser.spaceID))
    }
    private func switchToWebKit(_ request: URLRequest, emeFailure: Bool = false) {
        let turn = drmTurn
        Task { @MainActor [weak self] in
            guard let self, let tab = self.tab, let target = request.url else { return }
            guard tab.chromiumProfile == profile else {
                failed(YabCoreError.remote("DRM fallback requires migration of the moved tab's Chromium profile"))
                return
            }
            do {
                guard !retired, drmTurn == turn, tab.builtPage === self,
                      tab.chromiumProfile == profile, tab.address?.documentAddress == target.documentAddress,
                      tab.wantsWebKit(for: target, emeFailure: emeFailure) else { return }
                // Service routing and an EME failure identify a destination;
                // neither supplies native approval to retire this document.
                try await EngineSwitchTransaction.execute([
                    .init(tab: tab, engine: .webKit, request: request, isCurrent: { [weak self, weak tab] in
                        guard let self, let tab else { return false }
                        return !self.retired && self.drmTurn == turn && tab.builtPage === self &&
                            tab.chromiumProfile == self.profile && tab.address?.documentAddress == target.documentAddress &&
                            tab.wantsWebKit(for: target, emeFailure: emeFailure)
                    }, installing: { [weak tab] in
                        // Before WebKit's first navigation reads it: that site
                        // stays on WebKit in this tab, and only that site.
                        if emeFailure { tab?.engineProtectedSite = Tab.protectedSite(target) }
                    })
                ])
            } catch {
                // Stay, or a switch that failed: the document shown is still
                // here, so the tab says it again rather than where it was going.
                guard !retired, drmTurn == turn else { return }
                scriptTarget = url
                tab.keepShowing(self)
                tab.engineSwitchFailed(error, to: .webKit)
            }
        }
    }
    func navigate(html: String, base: URL?) {
        navigationTarget = nil
        swipe.invalidate()
        drmTurn &+= 1
        if let base, ["http", "https"].contains(base.scheme?.lowercased() ?? "") {
            // The page keeps the base URL and origin: the helper serves this body to the one navigation to it.
            documentTurn &+= 1
            invalidateOriginalPDFPresence()
            helperWasLost = false
            scriptTarget = base
            awaitingInitialDocument = remoteID == nil || warming
            warmed = false
            markLoading()
            enqueue(navigation: true, request: "tab.loadHTML") { [weak self] core, id in
                try await self?.scripts.prepare(core: core, tab: id, url: base)
                _ = try await core.request("tab.loadHTML", params: ["tab": .string(id), "url": .string(base.absoluteString), "html": .string(html)])
            }
            return
        }
        let value = Data(html.utf8).base64EncodedString()
        navigate(to: URLRequest(url: URL(string: "data:text/html;base64," + value)!))
    }
    func reload(fromOrigin: Bool) {
        navigationTarget = nil
        topGrab = false
        topPress = nil
        swipe.invalidate()
        documentTurn &+= 1
        invalidateOriginalPDFPresence()
        if remoteID == nil, let url { navigate(to: URLRequest(url: url)) }
        else { command("tab.reload", ["fromOrigin": .bool(fromOrigin)]) }
    }
    func refreshEngineSwitchScripts() {
        enqueue { [weak self] core, id in
            guard let self else { return }
            try await self.scripts.prepare(core: core, tab: id, url: self.url)
        }
    }
    func acceptNavigation(_ request: URLRequest) {
        diagnosticFailure = nil
        navigationTarget = request.url
    }
    func stopLoading() {
        navigationTarget = nil
        awaitingInitialDocument = false
        command("tab.stop")
    }
    func navigateBack() { navigationTarget = nil; swipe.invalidate(); documentTurn &+= 1; invalidateOriginalPDFPresence(); scriptTarget = nil; command("tab.back") }
    func navigateForward() { navigationTarget = nil; swipe.invalidate(); documentTurn &+= 1; invalidateOriginalPDFPresence(); scriptTarget = nil; command("tab.forward") }
    func childFrames(_ done: @escaping @MainActor ([PageFrame]) -> Void) {
        Task { @MainActor in
            do {
                await tail?.value
                let (core, id) = try await endpoint()
                let result = try await core.request("scripts.frames", params: ["tab": .string(id)])
                done(scripts.frames(result, tab: id))
            } catch { done([]) }
        }
    }
    func retire(call: Bool, pictureInPicture: Bool) {
        invalidateOriginalPDFPresence(releasePeer: true)
        questionRequests.cancel()
        resetNativeTextInput()
        swipe.invalidate()
        fileRequests.cancel()
        cancelNativePrint()
        ChromiumPopupHost.shared.retire(self)
        extensionPopup?.close(); extensionPopup = nil
        nativeFindEpoch += 1; nativeFindTask?.cancel()
        retired = true; cancelStreamingInput(); tail?.cancel(); creating?.cancel(); hoverAdmitted = false
        let painting = paintWaiters; paintWaiters = []; painting.forEach { $0(false) }
        ChromiumPointerLock.release(self); pointerLocked = false
        scripts.clearFrames()
        navigationBinding?.cancel(); navigationBinding = nil
        events = nil; stateEvents = nil
        if let remoteID { ChromiumProcess.shared.detach(remoteID) }
        remoteID = nil; contentProcess = nil; contextID = 0
        resetGeometry()
        remoteLayer?.removeFromSuperlayer(); remoteLayer = nil
        mediaEnded()
    }
    /// Heard from the helper: `url` is being navigated to in this page.
    func cookiesTouched(_ url: URL, mainFrame: Bool) {
        guard !retired else { return }
        ChromiumDRMCookies.session(of: tab)?.touched(url, mainFrame: mainFrame, by: .chromium, in: tab?.id)
    }
    /// `recover`: the page comes back by itself, now if it is on screen,
    /// else when it next is. Out of retries, it says what happened.
    func helperExited(recover: Bool = false) {
        guard !retired else { return }
        invalidateOriginalPDFPresence(releasePeer: true)
        questionRequests.cancel()
        resetNativeTextInput()
        swipe.invalidate()
        remoteAccessibility.reset()
        navigationTarget = nil
        helperWasLost = true
        operationEpoch &+= 1
        cancelStreamingInput()
        tail?.cancel(); tail = nil
        creating?.cancel()
        remoteFocused = nil
        fileRequests.cancel()
        if let ended = onDocumentClosed { onDocumentClosed = nil; ended(); return }
        scripts.clearFrames()
        cancelNativePrint()
        ChromiumPopupHost.shared.retire(self)
        extensionPopup = nil
        nativeFindEpoch += 1; nativeFindTask?.cancel()
        navigationBinding?.cancel(); navigationBinding = nil
        remoteID = nil; creating = nil; contextID = 0
        resetGeometry()
        contentProcess = nil
        mediaEnded()
        remoteLayer?.removeFromSuperlayer(); remoteLayer = nil
        isLoading = false; stateEvents?.page(self, changed: .loading(false))
        Leaving.chromiumClosed(self)
        if recover, !isDevToolsFrontend, let target = scriptTarget ?? url, ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
           navigationTab?.builtPage === self {
            recovering = target
            NSLog("Chromium: helper lost, the page comes back")
            if window != nil { recoverPage() }
            return
        }
        // Keep the crash visible until the next explicit navigation/reload.
        failed(YabCoreError.disconnected)
    }
    private func recoverPage() {
        guard let target = recovering, !retired else { return }
        recovering = nil
        // After the helper's old connection has gone, in its own turn.
        Task { @MainActor [weak self] in self?.navigate(to: URLRequest(url: target)) }
    }
    func clearDiscardedRenderer() {
        questionRequests.cancel()
        resetNativeTextInput()
        topGrab = false
        topPress = nil
        swipe.invalidate()
        documentTurn &+= 1
        invalidateOriginalPDFPresence()
        contentProcess = nil
        contextID = 0
        remoteLayer?.removeFromSuperlayer(); remoteLayer = nil
        isLoading = false
        stateEvents?.page(self, changed: .loading(false))
    }
    private func markLoading() {
        topGrab = false
        topPress = nil
        initialNativeLoading = nil
        initialRequestedURL = awaitingInitialDocument ? scriptTarget : nil
        isLoading = true
        stateEvents?.page(self, changed: .loading(true))
    }
    private func finishOAuthRedirect(_ callback: URL) {
        navigationTarget = nil
        diagnosticFailure = nil
        lastLoadError = [:]
        awaitingInitialDocument = false
        isLoading = false
        url = callback
        stateEvents?.page(self, changed: .url(callback))
        stateEvents?.page(self, changed: .loading(false))
    }
    /// `code` and `failing` come with a load error: Chromium's net error and the address it failed at.
    func failed(_ error: Error, code: Int? = nil, failing: String? = nil, name: String? = nil) {
        // Cookie carry and queued preparation also cancel when navigation is
        // replaced. Swift cancellation is not a CEF net error (-3), but must
        // have the same non-failure semantics.
        guard !(error is CancellationError) else { return }
        diagnosticFailure = String(describing: error)
        awaitingInitialDocument = false
        isLoading = false
        stateEvents?.page(self, changed: .loading(false))
        var info: [String: Any] = [:]
        if let name { info["netErrorName"] = name }
        if let target = failing.flatMap(URL.init(string:)) ?? url { info[NSURLErrorFailingURLErrorKey] = target }
        let reported = code.map { NSError(domain: "net", code: $0, userInfo: info) as Error } ?? error
        events?.page(self, navigation: .failed(navigation, reported, provisional: false))
    }
    func receive(_ event: YabCoreEvent) {
        guard !retired, event.tab == remoteID else { return }
        let p = event.params
        switch event.name {
        case "tab.closePreflight": _ = receiveLifecycle(event)
        case "script.relay": scripts.receive(event)
        case "page.hover": hoverStatus(p["url"]?.string ?? "")
        case "page.action": receiveAction(p)
        case "page.openLink": receiveOpenLink(p)
        case "page.dragStart": if let data = p["data"]?.object { receiveDragStart(data) }
        case "page.external": receiveExternal(p)
        case "page.cursor": receiveCursor(p)
        case "page.pointerLock": ChromiumPointerLock.page(self, locked: p["locked"] == .bool(true))
        case "page.keyUnhandled": receiveKeyUnhandled(p)
        case "page.devToolsCommand":
            guard let tab = navigationTab, let browser = tab.delegate as? Browser,
                  browser.toolsFront === tab else { return }
            switch p["action"]?.string {
            case "toggle": browser.developerTools()
            case "console": browser.openDevTools(.console)
            case "inspect":
                browser.openDevTools(.elements)
                tab.chromiumDev?.action("elements.toggle-element-search")
            default: break
            }
        case "script.error":
            // Script attachment belongs to an execution context (including
            // transient OAuth iframes), not to the top-level document load.
            // A redirect can destroy that context while attachment is pending.
            // Preserve the diagnostic without covering the live page.
            scriptAttachmentFailure = p["message"]?.string ?? "Page scripts failed"
        case "tab.closed":
            // Drop the native identity first so retirement cannot close a new
            // helper's tab that happens to reuse the same wire identifier.
            remoteID = nil
            if let ended = onDocumentClosed { onDocumentClosed = nil; ended(); return }
            // The native page is terminal even while a Leaving batch keeps
            // its row. Late scripts/input must not create a replacement tab.
            retire(call: false, pictureInPicture: false)
            // An asked batch owns row removal after the remaining pages
            // answer. Removing it here can select/retire the next page.
            if receiveLifecycle(event) { return }
            // A Small Window owns an outside page, not a row in a space.
            // Its native shell must follow the confirmed document close. A kept
            // page can already belong to a row while its old shell hands off.
            if let link = LinkWindow.owning(page: self) { link.close() }
            guard let tab = navigationTab, !tab.gone, let browser = tab.delegate as? Browser else { return }
            if browser.tabs.contains(where: { $0 === tab }) { browser.close(tab) }
            else { browser.closeElsewhere(tab) }
        case "page.externalLink":
            // Browser's own question about an app, the same as a WebKit page's link.
            guard let target = p["url"]?.string.flatMap(URL.init(string:)) else { return }
            let source = url.map { PageAction.Source(isMainFrame: true, scheme: $0.scheme ?? "", host: $0.host() ?? "", port: $0.port ?? 0) }
            let action = PageAction(request: URLRequest(url: target), kind: .linkActivated, targetIsMainFrame: true, source: source,
                                    modifierFlags: [], buttonNumber: 0, shouldPerformDownload: false,
                                    userInitiated: p["gesture"] == .bool(true))
            events?.page(self, decide: action) { _ in }
        case "drm.unavailable":
            // Use the helper's native main-frame URL, never a page-supplied target.
            // A player's page rewrites its fragment as it goes, as Shaka's demo does, and
            // the helper's address can be a step ahead of this one: the same document.
            func document(_ address: URL?) -> String? {
                address?.absoluteString.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
            }
            guard p["keySystem"]?.string == "com.widevine.alpha",
                  let target = p["url"]?.string.flatMap(URL.init(string:)),
                  ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
                  target.documentAddress == url?.documentAddress, let tab, tab.builtPage === self else { return }
            if tab.wantsWebKit(for: target, emeFailure: true) { switchToWebKit(URLRequest(url: target), emeFailure: true) }
        case "page.state":
            var settledBlankLoading: Bool?
            if awaitingInitialDocument, case .bool(let loading) = p["loading"] {
                initialNativeLoading = loading
            }
            // A fragment navigation in CEF's bootstrap blank document has no
            // new OnLoadStart/commit. Accept only the requested native URL,
            // and retain the real loading receipt if it preceded that URL.
            if awaitingInitialDocument, let target = initialRequestedURL,
               target.absoluteString.hasPrefix("about:blank#"),
               p["url"]?.string == target.absoluteString {
                awaitingInitialDocument = false
                if p["loading"] == nil { settledBlankLoading = initialNativeLoading }
            }
            receiveSleep(p)
            if let value = p["rendererPID"]?.number { contentProcess = !sleepState.discarded && value > 0 && value <= Double(Int32.max) ? pid_t(value) : nil }
            if case .bool(let value) = p["audioMuted"] { audioMuted = value }
            if let value = p["url"]?.string, !warmed {
                if !value.isEmpty, value != "about:blank" || scriptTarget == nil { scriptTarget = URL(string: value) }
                url = URL(string: value); stateEvents?.page(self, changed: .url(url))
                if let url, let tab, tab.wantsWebKit(for: url) { switchUnlessOpened(URLRequest(url: url)) }
            }
            if let value = p["title"]?.string, !warmed { title = value; stateEvents?.page(self, changed: .title(value)) }
            if case .bool(let v) = p["loading"], v || !awaitingInitialDocument {
                isLoading = v; stateEvents?.page(self, changed: .loading(v))
            } else if let loading = settledBlankLoading {
                isLoading = loading; stateEvents?.page(self, changed: .loading(loading))
            }
            if case .bool(let v) = p["canGoBack"] { canGoBack = v; stateEvents?.page(self, changed: .back(v)) }
            if case .bool(let v) = p["canGoForward"] { canGoForward = v; stateEvents?.page(self, changed: .forward(v)) }
            if let value = p["backgroundColor"] {
                // Own CEF reports the page's CSS background. Fill area the page
                // has not drawn yet while resizing with it, as Chromium does.
                let hex = value.string?.replacingOccurrences(of: "#", with: "") ?? ""
                CATransaction.begin(); CATransaction.setDisableActions(true)
                if hex.count == 6, let rgb = UInt32(hex, radix: 16) {
                    layer?.backgroundColor = CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                                                     blue: CGFloat(rgb & 255) / 255, alpha: 1)
                } else { layer?.backgroundColor = nil }
                CATransaction.commit()
            }
            if let value = p["themeColor"] {
                let hex = value.string?.replacingOccurrences(of: "#", with: "") ?? ""
                if hex.count == 6, let rgb = UInt32(hex, radix: 16) {
                    let c = PageColor(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1)
                    themeColor = NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
                    stateEvents?.page(self, changed: .theme(c))
                } else { themeColor = nil; stateEvents?.page(self, changed: .theme(nil)) }
            }
            if p["loading"] == .bool(false) { presentOriginalPDFPresence() }
        case "page.started":
            invalidateOriginalPDFPresence()
            resetNativeTextInput()
            questionRequests.cancel()
            swipe.invalidate()
            fileRequests.cancel()
            scripts.clearFrames()
            cancelNativePrint()
            navigation = PageNavigation(); events?.page(self, navigation: .started(navigation))
        case "page.committed":
            OpenTrace.mark("chromium.committed")
            // The helper's startup about:blank is not the accepted request.
            let committed = p["url"]?.string.flatMap(URL.init(string:)) ?? url
            if awaitingInitialDocument {
                guard let committed, !committed.absoluteString.isEmpty,
                      committed.absoluteString != "about:blank" else { return }
                awaitingInitialDocument = false
            }
            invalidateOriginalPDFPresence()
            originalPDFAdmissionAllowed = true
            serverTrust = nil
            restartOriginalPDFPresence()
            resetNativeTextInput()
            endNativeVideoPiP()
            if let committed, url != committed {
                url = committed; stateEvents?.page(self, changed: .url(committed))
            }
            // OnTitleChange need not accompany a commit until the new document
            // supplies a title. The cached value belonged to the old document.
            title = ""
            stateEvents?.page(self, changed: .title(""))
            committedURL = committed; events?.page(self, navigation: .committed(navigation))
            ChromiumDRMCookies.session(of: tab)?.pageCommitted(committed, by: .chromium, in: tab?.id)
            firstPaintMayHaveCome()
        case "page.finished":
            readCertificate()
            OpenTrace.mark("chromium.finished")
            pictureSoon()
            guard !awaitingInitialDocument else { return }
            originalPDFAdmissionAllowed = true
            restartOriginalPDFPresence(force: originalPDFPresence.ready == nil)
            committedURL = url; events?.page(self, navigation: .finished(navigation))
            configureNativeStore()
            ChromiumDRMCookies.session(of: tab)?.pageFinished(url)
        case "script.message":
            if p["world"]?.string == ChromiumStoreBridge.world, p["name"]?.string == ChromiumStoreBridge.binding,
               let tab = extensionTab, let browser = tab.delegate as? Browser,
               ChromiumStoreBridge.accepts(url), ChromiumStoreBridge.accepts(tab.address) {
                let value = p["value"] ?? .null
                if value["add"] == .bool(true) { browser.addFromStore(tab) }
                if let placed = value["placed"].string { tab.storePlaced = placed }
            } else {
                // The find bar's live count (yabFindChanged) shares this event.
                receiveNavigation(event)
            }
        case "page.oauthRedirect":
            guard let callback = p["url"]?.string.flatMap(URL.init(string:)), ChromiumOAuthRedirect.matches(callback) else { return }
            finishOAuthRedirect(callback)
        case "page.loadError":
            if p["code"]?.number != -3,
               let failed = p["url"]?.string.flatMap(URL.init(string:)), ChromiumOAuthRedirect.matches(failed) {
                // Chromium has already reported the attempted URL to the
                // extension. Do not race its callback handler with an error
                // card, URL rewriting or an automatic reload.
                finishOAuthRedirect(failed)
                return
            }
            lastLoadError = ["code": p["code"]?.number ?? 0, "message": p["message"]?.string ?? "", "url": p["url"]?.string ?? ""]
            // Stop/replacement is not a document failure. Do not cancel a
            // newer navigation on a late abort from the old one.
            guard let code = p["code"]?.number.map({ Int($0) }), code != -3 else { break }
            if let failedURL = p["url"]?.string.flatMap(URL.init(string:)),
               let current = navigationTarget, WWWRetry.key(failedURL) != WWWRetry.key(current) { break }
            // Chrome owns recovery, including visibility, connectivity, backoff,
            // certificate exclusions and POST safety. Do not race it with reloads.
            failed(YabCoreError.remote(p["message"]?.string ?? "Chromium load failed"), code: code,
                   failing: p["url"]?.string, name: p["message"]?.string)
        case "page.responsive":
            if let report = ChromiumResponsiveness(p, rendererPID: contentProcess) {
                events?.page(self, responsive: report.responsive)
            }
        case "page.crash":
            CrashSessions.died(kind: "renderer", pid: contentProcess, reason: "terminated",
                               code: p["status"]?.number.map { Int($0) })
            navigationTarget = nil
            questionRequests.cancel()
            resetNativeTextInput()
            swipe.invalidate()
            fileRequests.cancel()
            if let ended = onDocumentClosed { onDocumentClosed = nil; ended(); return }
            cancelNativePrint()
            nativeFindEpoch += 1; nativeFindTask?.cancel()
            contentProcess = nil
            mediaEnded()
            // This is the Chrome window compositor, not the renderer's layer.
            // SadTabHelper installs Chrome's native crash view in that same
            // compositor. Detaching it hides both the message and Reload.
            isLoading = false; stateEvents?.page(self, changed: .loading(false))
            events?.page(self, ended: p["status"]?.number == 3 ? .memory : .crash)
        case "layer.changed":
            if resizeState.surface(p), let paint = viewportPaint, paint.size == resizeState.committed {
                viewportPaint = nil
                paint.done()
            }
            extensionPageOffset = CGPoint(x: -(p["pageX"]?.number ?? 0), y: -(p["pageY"]?.number ?? 0))
            restoreSurfaceAttachment()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            remoteParent.frame = resizeState.frame(in: bounds)
            remoteParent.isHidden = !resizeState.canPresent
            remoteLayer?.position = extensionPageOffset
            CATransaction.commit()
            acceptSurfaceOwner(p)
            let id = UInt32(p["contextId"]?.number ?? 0)
            guard id != contextID || (id != 0 && remoteLayer?.superlayer !== remoteParent) else { return firstPaintMayHaveCome() }
            contextID = id
            CATransaction.begin(); CATransaction.setDisableActions(true)
            remoteLayer?.removeFromSuperlayer(); remoteLayer = nil
            if id != 0, let type = NSClassFromString("CALayerHost") as? CALayer.Type {
                let hosted = type.init()
                hosted.setValue(NSNumber(value: id), forKey: "contextId")
                hosted.anchorPoint = .zero; hosted.position = extensionPageOffset; hosted.bounds = .zero
                remoteParent.addSublayer(hosted); remoteLayer = hosted
            }
            CATransaction.commit()
            acknowledgeSurfaceContext()
            firstPaintMayHaveCome()
        case "tab.resized":
            if resizeState.receive(p) {
                if Store.testing { StageView.mark("fullscreen.resizeCommit", ["tab": remoteID ?? "",
                    "size": resizeState.committed.map { [Double($0.width), Double($0.height)] } ?? []]) }
                restoreSurfaceAttachment()
                CATransaction.begin(); CATransaction.setDisableActions(true)
                remoteParent.frame = resizeState.frame(in: bounds)
                if let paint = viewportPaint, paint.size == resizeState.committed {
                    viewportPaint = nil
                    paint.done()
                }
                remoteParent.isHidden = !resizeState.canPresent
                CATransaction.commit()
                // Chrome may apply a size after the place that followed it
                // (a new page's renderer not ready yet), keeping the window's
                // top: placed again on the size it has now.
                placedProducer = nil
                placeProducer()
                firstPaintMayHaveCome()
            }
        case "media.pip.changed": receiveNativeVideoPiP(p)
        case "documentPiP.size":
            if let width = p["width"]?.number, let height = p["height"]?.number {
                onDocumentSize?(NSSize(width: width, height: height))
            }
        case "page.textInput":
            receiveNativeTextInput(p)
        case "select.open":
            receiveSelect(p)
        case "select.closed":
            closeSelect(p)
        case "popup.layer":
            receivePopup(p)
        case "popup.textInput":
            receivePopupTextInput(p)
        case "popup.cursor":
            extensionPopup?.receiveCursor(p)
        case "tab.extensionCreated":
            receiveExtensionTab(p)
        case "tab.extensionActivate":
            if let tab, let browser = tab.delegate as? Browser { browser.select(tab) }
        case "tab.extensionFocus":
            // chrome.windows.update({focused: true}) (CEF patch 0119): the
            // window this page is in comes to the front, as Chromium's does; a
            // wallet focuses its notification window again so for a new
            // request. Its tab stays as it is: tabs.update selects.
            if let tab {
                NSApp.activate()
                if let made = ChromiumExtensionWindow.showing(tab) {
                    made.window.makeKeyAndOrderFront(nil)
                } else if let browser = tab.delegate as? Browser,
                          let window = BrowserWindows.shared.window(for: browser) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        case "extension.sidePanelOpen":
            // chrome.sidePanel.open() for this page (CEF patch 0095).
            if #available(macOS 15.4, *), let tab, let panel = ChromiumSidePanel.requested(p) {
                ChromiumSidePanel.shared.show(panel.extensionID, url: panel.url, from: tab)
            }
        case "extension.omniboxSuggestions":
            // omnibox.suggest's rows for the words the field last sent (0124).
            if #available(macOS 15.4, *), let rows = ExtensionOmnibox.chromiumSuggestions(p) {
                ExtensionOmnibox.shared.chromiumSuggested(rows.extensionID, request: rows.request, rows: rows.list)
            }
        case "extension.sidePanelOptions":
            // chrome.sidePanel.setOptions, as Chromium's panel hears it (CEF
            // patch 0124): the panel it names follows, wherever it is.
            if let change = ChromiumSidePanel.changed(p) {
                ChromiumSidePanel.shared.optionsChanged(change.extensionID, tab: change.tab, path: change.path, enabled: change.enabled)
            }
        case "download.open":
            receiveDownload(p)
        case "question.open":
            receiveQuestion(event.params)
        case "question.closed":
            receiveQuestionClosed(event.params)
        case "menu.open":
            receiveMenu(p)
        case "print.request":
            receiveNativePrint(p)
        case "print.withdrawn":
            if p["request"]?.string == nativePrintRequestID { cancelNativePrint() }
        case "dialog.open", "file.open", "file.closed":
            receiveNavigation(event)
        case "files.taken":
            receiveFilesTaken(p)
        default: receiveMedia(event)
        }
    }
    /// A popup can take and return the stage without changing this view's
    /// size. AppKit may replace its backing meanwhile: waiting for layout
    /// leaves the live compositor under the old layer until a manual resize.
    /// Reattach only; never manufacture a helper or change native geometry.
    func restoreSurfaceAttachment() {
        guard let backing = layer, remoteParent.superlayer !== backing else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backing.addSublayer(remoteParent)
        remoteParent.frame = resizeState.frame(in: bounds)
        remoteParent.isHidden = !resizeState.canPresent
        CATransaction.commit()
    }
    private func updateSurface() {
        restoreSurfaceAttachment()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        remoteParent.frame = resizeState.frame(in: bounds)
        remoteParent.isHidden = !resizeState.canPresent
        CATransaction.commit()
        syncGeometry()
        if originalPDFPresence.owner == nil { restartOriginalPDFPresence() }
        presentOriginalPDFPresence()
    }
    func extensionHostState() async throws -> JSONValue {
        await tail?.value
        let (core, id) = try await endpoint()
        return try await core.request("tab.state", params: ["tab": .string(id)])
    }
    /// Isolate a blocked store bridge from a blocked renderer in farm probes.
    func extensionDocumentProbe(_ expression: String) async throws -> JSONValue {
        guard Store.testing else { throw YabCoreError.remote("Extension diagnostics require a test world") }
        let (core, id) = try await endpoint()
        return try await core.request("script.document", params: ["tab": .string(id), "expression": .string(expression)])
    }
    /// The extension's button pressed on this page, through Chrome's
    /// original action runner (patches 0018/0030): false when this helper
    /// has no such hook or Chrome refused, so the caller can fall back.
    func openExtensionAction(_ extensionID: String) async -> Bool {
        // An extension action belongs to Chrome's browser UI. A slow page
        // click handler can hold the renderer input ACK (and tail) while the
        // extension's independent renderer is ready to show its popup.
        let epoch = operationEpoch
        guard let (core, id) = try? await endpoint() else { return false }
        let anchor: JSONValue = .object(["x": .number(max(0, Double(bounds.width) - 40)), "y": .number(0),
                                         "width": .number(32), "height": .number(32)])
        do {
            // A button press hands focus back from Yab's chrome to this exact
            // native owner. The local cache records the desired focus, not an
            // acknowledgement: its first request can fail while the producer
            // is starting, or Chrome can clear focus when its widget hides.
            // Reassert it and await acceptance for every action, including the
            // first one, before asking Chrome's runner to dispatch the press.
            let focus = try await core.request("tab.focus", params: ["tab": .string(id), "focused": .bool(true)])
            guard focus["focused"] == .bool(true), !retired, operationEpoch == epoch,
                  remoteID == id, ChromiumProcess.shared.isCurrent(core) else { return false }
            remoteFocused = true
            let reply = try await core.request("extension.action.open",
                                               params: ["tab": .string(id), "extension": .string(extensionID), "anchor": anchor])
            guard !retired, operationEpoch == epoch, remoteID == id,
                  ChromiumProcess.shared.isCurrent(core) else { return false }
            if Store.testing { FileHandle.standardError.write(Data("yab: extension.action.open \(extensionID) -> \(reply)\n".utf8)) }
            return reply["opened"] == .bool(true)
        } catch {
            if Store.testing { FileHandle.standardError.write(Data("yab: extension.action.open \(extensionID) failed: \(error)\n".utf8)) }
            extensions.failure = "action: \(error.localizedDescription)"
            return false
        }
    }
    /// An extension's named command for this page, as Chromium runs one whose
    /// key was pressed (ChromiumExtensionCommands): activeTab for this tab,
    /// and commands.onCommand with it. Focus stays where it is, as in Chromium.
    func runExtensionCommand(_ extensionID: String, command: String) async -> Bool {
        let epoch = operationEpoch
        guard let (core, id) = try? await endpoint() else { return false }
        do {
            let reply = try await core.request("extension.command.run",
                                               params: ["tab": .string(id), "extension": .string(extensionID), "command": .string(command)])
            guard !retired, operationEpoch == epoch, remoteID == id, ChromiumProcess.shared.isCurrent(core) else { return false }
            if Store.testing { FileHandle.standardError.write(Data("yab: extension.command.run \(extensionID) \(command) -> \(reply)\n".utf8)) }
            return reply["ran"] == .bool(true)
        } catch {
            if Store.testing { FileHandle.standardError.write(Data("yab: extension.command.run \(extensionID) \(command) failed: \(error)\n".utf8)) }
            extensions.failure = "command: \(error.localizedDescription)"
            return false
        }
    }

    /// One of CEF patch 0124's requests for this page: the extension's own
    /// rows of its button's menu (`extension.actionMenu`), one of them run
    /// (`extension.actionMenu.run`), or its omnibox keyword's input
    /// (`extension.omnibox`). Chrome's answer, or nil when this helper has
    /// no 0124 or the page went meanwhile.
    func extensionSurface(_ method: String, _ params: [String: JSONValue]) async -> JSONValue? {
        let epoch = operationEpoch
        guard let (core, id) = try? await endpoint() else { return nil }
        do {
            var fields = params
            fields["tab"] = .string(id)
            let reply = try await core.request(method, params: fields)
            guard !retired, operationEpoch == epoch, remoteID == id, ChromiumProcess.shared.isCurrent(core) else { return nil }
            return reply
        } catch {
            if Store.testing { FileHandle.standardError.write(Data("yab: \(method) failed: \(error)\n".utf8)) }
            return nil
        }
    }
    func extensionActionState(press name: String? = nil) async throws -> JSONValue {
        await tail?.value
        let (core, id) = try await endpoint()
        var params: [String: JSONValue] = ["tab": .string(id)]
        if let name { params["name"] = .string(name) }
        return try await core.request(name == nil ? "extension.actions" : "extension.pressAction", params: params)
    }
    private func configureNativeStore() {
        guard ChromiumStoreBridge.accepts(url), !privateMode else { return }
        if Store.testing, ProcessInfo.processInfo.environment["YAB_TEST_NO_STORE_BRIDGE"] == "1" { return }
        enqueue { core, id in
            _ = try await core.request("script.bind", params: ["tab": .string(id), "world": .string(ChromiumStoreBridge.world), "name": .string(ChromiumStoreBridge.binding)])
            _ = try await core.evaluate(tab: id, world: ChromiumStoreBridge.world,
                                       function: "function(){\(ChromiumStoreBridge.script)}", arguments: .null)
        }
        extensions.perform { [weak self] in
            guard let self else { return }
            _ = try await self.extensions.list()
            self.tellNativeStore()
        }
    }
    private func tellNativeStore() {
        guard ChromiumStoreBridge.accepts(url) else { return }
        let state: JSONValue = .object(["installed": .array(extensions.items.map { .string($0.id) }),
                                        "busy": extensions.busy ? Crx.id(in: url?.absoluteString ?? "").map(JSONValue.string) ?? .null : .null])
        enqueue { core, id in
            _ = try await core.evaluate(tab: id, world: ChromiumStoreBridge.world,
                                       function: "function(state){window.__yabStore?.state(state)}", arguments: state)
        }
    }
    override func layout() { super.layout(); updateSurface() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateSurface() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { recoverPage(); ChromiumDRMCookies.session(of: tab)?.pageChanged() }
        if window == nil { hoverLeft(); receiveTooltip("") }
        updateSurface()
        watchKeyWindow()
        scripts.appearanceChanged()
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.focusChanged() } }
        return accepted
    }
    override func viewDidHide() { super.viewDidHide(); hoverLeft(); syncGeometry(); focusChanged() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); scripts.appearanceChanged() }
    override func viewDidUnhide() {
        super.viewDidUnhide(); OpenTrace.mark("chromium.unhide"); restoreSurfaceAttachment(); syncGeometry(); focusChanged(); pictureSoon()
        ChromiumDRMCookies.session(of: tab)?.pageChanged()
    }

    /// Chrome draws only what is on screen, so ⌃Tab's picture of a page in the
    /// back is the one taken here while it was in front.
    private func pictureSoon() {
        pictureTask?.cancel()
        pictureTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled, window != nil, !isHiddenOrHasHiddenAncestor else { return }
            // Of the page shown now: a hide queued after it waits for it.
            snapshotInOrder(PageShot(width: 312, afterUpdates: false)) { [weak self] image, _ in
                if let image { self?.lastPicture = image }
            }
        }
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateSurface() }
    /// The hidden window stands where the page shows, on the screen it shows
    /// on. Chrome tells the page window.screen, screen.orientation, screenX
    /// and the device-width media queries from the screen its own window is
    /// on (RenderWidgetHostViewCocoa updateScreenProperties, display::ScreenMac
    /// GetDisplayNearestWindow), and an assistive client's tree takes its
    /// screen points from that window's frame. Left where it was made, at
    /// (80, 120) of the main screen, a page on a 1080 x 1920 portrait monitor
    /// was told it was on the 1920-wide landscape one (feedback #2019).
    /// Followed on every window move and screen change (watchKeyWindow) and
    /// every geometry sync, after its resize; the same place is not sent twice.
    func placeProducer() {
        guard remoteID != nil, !retired, let window, let screen = window.screen else { return }
        let rect = window.convertToScreen(convert(bounds, to: nil))
        let place = ProducerPlace(x: rect.minX.rounded(), y: rect.minY.rounded(), size: CGSize(width: ceil(rect.width), height: ceil(rect.height)),
                                  screen: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0)
        guard place != placedProducer else { return }
        placedProducer = place
        command("tab.place", ["x": .number(place.x), "y": .number(place.y)])
    }
    var surfaceState: [String: Any] {
        ["rootFlipped": layer?.isGeometryFlipped ?? false,
         "rootClass": layer.map { String(describing: type(of: $0)) } ?? "",
         "parentAttached": remoteParent.superlayer === layer,
         "parentBounds": [remoteParent.bounds.minX, remoteParent.bounds.minY, remoteParent.bounds.width, remoteParent.bounds.height],
         "parentFlipped": remoteParent.isGeometryFlipped,
         "resizeNative": resizeState.native,
         "hostReady": resizeState.canPresent,
         "hostContext": (remoteLayer?.value(forKey: "contextId") as? NSNumber)?.uint32Value ?? 0,
         "hostAttached": remoteLayer?.superlayer === remoteParent,
         "ownerGeneration": surfaceOwner?.generation ?? -1,
         "ownerRenderer": surfaceOwner?.renderer ?? 0,
         "sentShown": sentGeometry.map { $0.visible && !$0.covered } ?? false,
         "resizePending": resizeState.serial ?? "",
         "resizeAcknowledged": resizeState.acknowledged ?? "",
         "resizeCommitted": resizeState.committed.map { [$0.width, $0.height] } ?? [],
         "hostClass": remoteLayer.map { String(describing: type(of: $0)) } ?? "",
         "hostBounds": remoteLayer.map { [$0.bounds.minX, $0.bounds.minY, $0.bounds.width, $0.bounds.height] } ?? [],
         "opacity": layer?.opacity ?? 0, "hidden": isHiddenOrHasHiddenAncestor,
         "lastReadiness": lastReadiness, "lastLoadError": lastLoadError,
         "scriptAttachmentFailure": scriptAttachmentFailure ?? "",
         "diagnosticFailure": diagnosticFailure ?? ""]
    }
    /// The size and scale a page last had on a stage. A page opened behind the
    /// one on screen has no view size yet; given this it loads at the width it
    /// will be shown at, as a background tab does in Chrome. At one point wide
    /// every word is a line: 10 to 20 MB more per tab, and sites pick a phone
    /// layout that the first look has to undo.
    private static var lastStage: (size: CGSize, scale: Double)?
    private var currentGeometry: ChromiumResize.Geometry {
        let placed = window != nil && bounds.width > 1 && bounds.height > 1
        if placed { Self.lastStage = (bounds.size, Double(window?.backingScaleFactor ?? 1)) }
        let screen = NSScreen.main
        let stage = Self.lastStage ?? (screen?.visibleFrame.size ?? bounds.size, Double(screen?.backingScaleFactor ?? 1))
        return ChromiumResize.Geometry(size: placed ? bounds.size : stage.size, scale: window.map { Double($0.backingScaleFactor) } ?? stage.scale,
                                       visible: window != nil && !isHiddenOrHasHiddenAncestor, covered: windowCovered)
    }
    /// Minimized, on another Space, or all under other windows: Chrome tells
    /// such a page it is hidden (WebContentsViewCocoa updateWebContentsVisibility),
    /// and rAF and rendering stop until someone can see it. The stage's own
    /// shown and hidden stay as they are: a tab switch never reads this.
    /// A test world counts it only when asked: probes share a screen and a
    /// window under another's has to keep drawing, as automation turns this
    /// off in Chrome (--disable-backgrounding-occluded-windows). Headless Yab
    /// has no window anyone could see, and its pages work on.
    /// The bench's room is off every screen on purpose: an agent's page is
    /// there to be drawn while it works (WebKit's seenOffscreen), and the
    /// bench takes it out again two minutes after its last call (Bench.rest).
    /// Counted as covered (since 0.46.0), its page was hidden in people's Yab;
    /// up to 0.46.27 a picture held open on it kept it drawing by accident,
    /// and once 0.46.28 refused pictures of hidden pages (#1909) it drew no
    /// animation frames, so lazy dialogs never showed, and every screenshot
    /// said "Page is hidden" (feedback #1963). Test worlds never counted
    /// occlusion, so no eval saw it.
    var windowCovered: Bool {
        guard let window, window.identifier != Bench.roomID, window.isVisible || window.isMiniaturized || NSApp.isHidden,
              !window.occlusionState.contains(.visible), !Headless.hidden else { return false }
        return !Store.testing || ProcessInfo.processInfo.environment["YAB_PAGE_OCCLUSION"] == "1"
    }
    /// The window came into view or went out of it.
    func sightChanged() {
        restoreSurfaceAttachment()
        syncGeometry()
        focusChanged()
        ChromiumDRMCookies.session(of: tab)?.pageChanged()
    }
    /// Surface ownership acknowledgement. Every layer.changed says which
    /// document and renderer the compositor shows and whether the helper
    /// holds the page shown. A new owner (cross-process navigation, renderer
    /// swap, reload) keeps the window compositor's context, so the host is
    /// checked here, on the helper's word, never by re-sending visibility on
    /// key, unhide, occlusion or window moves (85f58b25b) or by a resize.
    /// When the helper's shown state is not what was last sent and nothing
    /// is in flight, what the helper has is what counts as sent: the next
    /// sync brings it back to what the page wants.
    private func acceptSurfaceOwner(_ p: [String: JSONValue]) {
        if let generation = p["generation"]?.number {
            surfaceOwner = (generation, p["renderer"]?.number ?? 0)
        }
        guard case .bool(let shown)? = p["visible"], let sent = sentGeometry, !geometryQueued,
              shown != (sent.visible && !sent.covered) else { return }
        sentGeometry = ChromiumResize.Geometry(size: sent.size, scale: sent.scale, visible: shown, covered: false)
        syncGeometry()
    }
    private func resetGeometry() {
        viewportPaint = nil
        resizeState = ChromiumResize()
        desiredGeometry = nil; sentGeometry = nil
        placedProducer = nil
        geometryQueued = false
        geometryTurn &+= 1
        visibilityUnknown = false
        layer?.backgroundColor = nil
    }
    /// A replacement compositor owns a new geometry handshake even when the
    /// window's size is unchanged. Do not wait for a window resize or enqueue
    /// this behind a script running in the renderer that is being replaced.
    private func acknowledgeSurfaceContext() {
        guard resizeState.needsContextAcknowledgement,
              let remote = remoteID, let core = ChromiumProcess.shared.connectedClient else { return }
        let context = contextID, geometry = currentGeometry, epoch = operationEpoch
        let token = resizeState.request(geometry)
        Task { @MainActor [weak self] in
            guard let self, !self.retired, self.remoteID == remote, self.contextID == context,
                  self.operationEpoch == epoch, self.resizeState.serial == token,
                  ChromiumProcess.shared.isCurrent(core) else { return }
            do {
                let result = try await core.request("tab.resize", params: ["tab": .string(remote), "serial": .string(token),
                    "width": .number(geometry.size.width), "height": .number(geometry.size.height), "scale": .number(geometry.scale)])
                guard !self.retired, self.remoteID == remote, self.contextID == context,
                      ChromiumProcess.shared.isCurrent(core) else { return }
                if result["resizeAck"] != .bool(true) {
                    self.resizeState.unsupported(token)
                    self.remoteParent.isHidden = !self.resizeState.canPresent
                    self.firstPaintMayHaveCome()
                }
            } catch { DebugLog.note("chromium.surface", ["error": error.localizedDescription]) }
        }
    }
    private func sendGeometry(_ core: YabCoreClient, _ id: String, _ geometry: ChromiumResize.Geometry) async throws {
        // A page only shown or hidden keeps its size: showing it is one trip.
        if geometry.size != sentGeometry?.size || geometry.scale != sentGeometry?.scale {
            let token = resizeState.request(geometry)
            if Store.testing { StageView.mark("fullscreen.resizeSend", ["tab": id, "serial": token,
                "size": [Double(geometry.size.width), Double(geometry.size.height)]]) }
            let result = try await core.request("tab.resize", params: ["tab": .string(id), "serial": .string(token),
                "width": .number(geometry.size.width), "height": .number(geometry.size.height), "scale": .number(geometry.scale)])
            if Store.testing { StageView.mark("fullscreen.resizeReply", ["tab": id, "serial": token]) }
            if result["resizeAck"] != .bool(true) {
                resizeState.unsupported(token)
                CATransaction.begin(); CATransaction.setDisableActions(true)
                remoteParent.frame = resizeState.frame(in: bounds)
                remoteParent.isHidden = !resizeState.canPresent
                CATransaction.commit()
                firstPaintMayHaveCome()
            }
        }
        if visibilityUnknown || geometry.changesVisibility(from: sentGeometry) {
            OpenTrace.mark("chromium.visible.send")
            // `keep`: a covered page stays drawn and comes back at once, as Chromium's
            // occluded page does. Only a page the stage took away gives up its layers.
            do {
                _ = try await core.request("tab.visible", params: ["tab": .string(id), "visible": .bool(geometry.visible && !geometry.covered),
                                                                   "keep": .bool(geometry.visible)])
                visibilityUnknown = false
            } catch {
                visibilityUnknown = true
                throw error
            }
            OpenTrace.mark("chromium.visible.done")
        }
        sentGeometry = geometry
        if geometry.visible { let waiters = shownWaiters; shownWaiters = []; waiters.forEach { $0() } }
    }
    private func syncGeometry() {
        guard remoteID != nil, !retired else { return }
        desiredGeometry = currentGeometry
        // Queued after the resize: the helper sets the window's bottom left
        // and a resize keeps its top, so a place sent first left a page that
        // grew taller standing its growth too low (a new tab, 900 points).
        defer { placeProducer() }
        guard let desired = desiredGeometry, !geometryQueued, geometryNeedsSend(desired) else { return }
        geometryQueued = true
        geometryTurn &+= 1
        let turn = geometryTurn
        let ran = GeometryRun()
        enqueue { [weak self] core, id in
            ran.started = true
            guard let self else { return }
            defer { self.geometryFinished(turn) }
            // A throw ends the loop; with visibilityUnknown set, the next sync sends again.
            while self.remoteID == id, let geometry = self.desiredGeometry, self.geometryNeedsSend(geometry) {
                try await self.sendGeometry(core, id, geometry)
            }
        }
        // enqueue can return without running the operation (endpoint failed,
        // helper not current, cancelled): then nothing else would clear
        // geometryQueued, and every later sync of this page would be skipped.
        if let queued = tail {
            Task { @MainActor [weak self] in
                await queued.value
                guard let self, !ran.started else { return }
                self.geometryFinished(turn)
            }
        }
    }
    @MainActor private final class GeometryRun { var started = false }
    private func geometryNeedsSend(_ geometry: ChromiumResize.Geometry) -> Bool {
        visibilityUnknown || geometry != sentGeometry
    }
    /// The queued geometry operation `turn` ended: ran, failed, or never ran.
    private func geometryFinished(_ turn: Int) {
        if turn == geometryTurn { geometryQueued = false }
    }
    private func applyZoom() {
        command("page.zoom", ["factor": .number(Double(pageZoom * magnification))])
    }

    func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool,
                  done: (@MainActor (Result<Any?, Error>) -> Void)?) {
        Task { @MainActor in
            do { let value = try await evaluate(script, in: world, frame: frame, gesture: gesture); done?(.success(value)) }
            catch { done?(.failure(error)) }
        }
    }
    func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool) async throws -> Any? {
        let frameToken = try scripts.token(frame, tab: remoteID)
        await tail?.value
        let (core, id) = try await endpoint()
        let turn = documentTurn
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        var proof: JSONValue
        while true {
            try Task.checkCancellation()
            guard !retired, remoteID == id, documentTurn == turn, tab?.chromiumProfile == profile else { throw CancellationError() }
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            guard seconds > 0 else {
                throw YabCoreError.remote("Document is at \(lastReadiness["url"] as? String ?? "?"), script target is \(scriptTarget?.absoluteString ?? "none")")
            }
            proof = try await core.waitForDocument(tab: id, profile: profile, timeout: seconds)
            lastReadiness = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(proof))) as? [String: Any] ?? [:]
            guard !retired, remoteID == id, documentTurn == turn, tab?.chromiumProfile == profile else { throw CancellationError() }
            if scriptTarget == nil || proof["url"].string == scriptTarget?.absoluteString { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        lastReadiness = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(proof))) as? [String: Any] ?? [:]
        let body: String, args: JSONValue
        // An expression is evaluated by the engine, not by the page's eval: a
        // page's CSP or a boost's locked world has no eval to give.
        var direct: String?
        switch script {
        case .expression(let source):
            direct = source; body = ""; args = .object([:])
        case .function(let source, let arguments):
            guard arguments.keys.allSatisfy({ $0.range(of: "^[A-Za-z_$][A-Za-z0-9_$]*$", options: .regularExpression) != nil }) else {
                throw YabCoreError.remote("Invalid JavaScript argument name")
            }
            body = "const {\(arguments.keys.sorted().joined(separator: ","))}=args;\n" + source
            args = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: arguments))
        }
        // Preserve undefined versus JSON null across wire v1.
        let function = "async function(args){const value=await(async()=>{\(body)})();return value===undefined?{absent:true}:{value};}"
        let result: JSONValue
        if let frameToken {
            var params: [String: JSONValue] = ["tab": .string(id), "frame": .string(frameToken),
                "world": .string(ChromiumScripts.world(world)), "function": .string(function), "arguments": args, "userGesture": .bool(gesture)]
            if let direct { params["expression"] = .string(direct) }
            result = try await core.request("scripts.evaluate", params: params)
        } else { switch world {
        case .page:
            let data = try JSONEncoder().encode(args)
            result = try await core.request("script.document", params: ["tab": .string(id), "userGesture": .bool(gesture),
                "document": proof, "whole": .bool(direct != nil),
                "expression": .string(direct ?? "(\(function))(\(String(decoding: data, as: UTF8.self)))")])
        case .client, .named:
            let name: String
            if case .named(let value) = world { name = "yab-world-" + value } else { name = "yab-client" }
            var params: [String: JSONValue] = ["tab": .string(id), "world": .string(name),
                "function": .string(function), "arguments": args, "userGesture": .bool(gesture), "document": proof]
            if let direct { params["expression"] = .string(direct) }
            result = try await core.request("script.evaluate", params: params)
        }
        }
        guard !retired, remoteID == id, documentTurn == turn else { throw CancellationError() }
        if result["absent"] == .bool(true) { return nil }
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(result["value"]), options: [.fragmentsAllowed])
    }
    func snapshot(_ shot: PageShot, done: @escaping @MainActor (NSImage?, Error?) -> Void) {
        Task { @MainActor in
            do {
                await tail?.value
                let (core, id) = try await endpoint()
                let turn = documentTurn, size = bounds.size, zoom = pageZoom, magnify = magnification
                let location = url, scroll = tab?.lastY
                let rect = shot.rect ?? CGRect(origin: .zero, size: size)
                guard rect.width > 0, rect.height > 0, size.width > 0, size.height > 0 else { throw PageShotFailed() }
                let proof = try await core.waitForDocument(tab: id, profile: profile, timeout: 10)
                // A small or a passing picture needn't be a lossless one of a whole window.
                let format = shot.brief || (shot.width ?? rect.width) <= 640 ? "jpeg" : "png"
                var parameters: [String: JSONValue] = ["tab": .string(id), "document": proof, "format": .string(format)]
                // Past the view: the renderer draws that part of the document
                // for this picture, as Chromium's full-page capture does.
                let beyond = !CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1).contains(rect)
                // What is on screen now: copied from the page's surface, not
                // drawn again for it (YabCore page_snapshot.inc, CEF 0118).
                if !shot.afterUpdates, !beyond, format == "jpeg" { parameters["surface"] = .bool(true) }
                if beyond {
                    let at = (try await run("[window.scrollX, window.scrollY]", in: .yab, gesture: false)) as? [Double] ?? [0, 0]
                    let z = max(zoom * magnify, 0.01), height = rect.height / z
                    parameters["clip"] = .object(["x": .number(at[0] + rect.minX / z), "y": .number(at[1] + rect.minY / z),
                                                  "width": .number(rect.width / z), "height": .number(height),
                                                  "scale": .number(min(1, 16_000 / max(height * (window?.backingScaleFactor ?? 2), 1)))])
                }
                let value = try await core.request("page.snapshot", params: parameters)
                guard !retired, remoteID == id, documentTurn == turn, bounds.size == size,
                      pageZoom == zoom, magnification == magnify, url == location, tab?.lastY == scroll else { throw PageShotFailed() }
                guard let encoded = value["data"].string else { throw PageShotFailed() }
                if !beyond, format == "jpeg", rect == CGRect(origin: .zero, size: size) {
                    keepRecentWhole(encoded, turn: turn, size: size, zoom: zoom, magnification: magnify, url: location, y: scroll)
                }
                let width = shot.width ?? rect.width
                guard width > 0, width.isFinite else { throw PageShotFailed() }
                // A window's picture takes 100 to 200 ms to decode and draw, and
                // pages ask for several as they arrive: never on the main thread,
                // which has the page being opened to get on with.
                let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
                let whole = beyond ? rect.size : size, part = beyond ? CGRect(origin: .zero, size: rect.size) : rect
                let decoded = await Task.detached(priority: .userInitiated) {
                    Self.picture(encoded, page: whole, rect: part, width: width, backing: backing).map(SendablePicture.init)
                }.value
                guard let output = decoded?.image else { throw PageShotFailed() }
                done(output, nil)
            } catch { done(nil, error) }
        }
    }
    private struct SendablePicture: @unchecked Sendable { let image: NSImage }

    /// A helper without CEF patch 0118 has no page.tone: asked once, then
    /// the tone looks at a picture as before.
    static var surfaceTone = true

    /// How light the page is as it is shown, 0 black to 1 white, as
    /// Tab.lightness reads a small picture of it; nil for a page mostly not
    /// drawn. The helper has the GPU scale the page's surface to a few
    /// pixels and sends back only their sums: no picture is encoded, sent or
    /// decoded (R1436). Fails with `ChromiumPage.ToneUnavailable` where the
    /// helper can't.
    func lightness(done: @escaping @MainActor (Result<CGFloat?, Error>) -> Void) {
        let size = bounds.size, turn = documentTurn
        guard Self.surfaceTone else { done(.failure(ToneUnavailable())); return }
        guard !retired, size.width > 0, size.height > 0 else { done(.failure(PageShotFailed())); return }
        Task { @MainActor in
            do {
                let (core, id) = try await endpoint()
                // Tab.lightness reads at most 32 pixels each way.
                let width = 32, height = max(1, min(32, Int((32 * size.height / size.width).rounded())))
                let value = try await core.request("page.tone", params: ["tab": .string(id),
                                                                        "width": .number(Double(width)), "height": .number(Double(height))])
                guard !retired, remoteID == id, documentTurn == turn,
                      let sum = value["sum"].number, let cover = value["cover"].number, let pixels = value["pixels"].number, pixels > 0
                else { throw PageShotFailed() }
                // Premultiplied: the colors over the cover they have (Tab.lightness).
                done(.success(cover * 2 >= pixels * 255 ? CGFloat(sum / (cover * 1000)) : nil))
            } catch YabCoreError.remote(let message) where message == "Unknown method" {
                Self.surfaceTone = false
                done(.failure(ToneUnavailable()))
            } catch { done(.failure(error)) }
        }
    }
    struct ToneUnavailable: Error {}

    /// Each picture of a Chromium page is the whole window read back from
    /// the GPU, encoded, sent over the wire and decoded here. A tone's look
    /// that needs one (a fresh look at an arrival, or a helper without
    /// page.tone) is kept, encoded, for a moment, and the stage's still that
    /// follows is made from it (PageStills.take) instead of a second picture
    /// of the same frame. R1436, evals/energy/chromium_idle.py.
    struct RecentWhole {
        let encoded: String
        let turn: Int
        let size: CGSize
        let zoom: CGFloat
        let magnification: CGFloat
        let url: URL?
        let y: Double?
        let at: CFTimeInterval
    }
    static let recentWholeLife: CFTimeInterval = 2

    private func keepRecentWhole(_ encoded: String, turn: Int, size: CGSize, zoom: CGFloat, magnification: CGFloat, url: URL?, y: Double?) {
        let at = CACurrentMediaTime()
        recentWhole = RecentWhole(encoded: encoded, turn: turn, size: size, zoom: zoom, magnification: magnification, url: url, y: y, at: at)
        // A megabyte or so: let go of once it can no longer be used.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recentWholeLife) { [weak self] in
            if self?.recentWhole?.at == at { self?.recentWhole = nil }
        }
    }

    /// The whole page's last picture when it is of the page as it is shown
    /// now (the same document, size, zoom, address and scroll) and was taken
    /// within `recentWholeLife`; used once.
    func recentWholePicture() -> String? {
        guard let kept = recentWhole else { return nil }
        recentWhole = nil
        guard !retired, CACurrentMediaTime() - kept.at <= Self.recentWholeLife, kept.turn == documentTurn,
              kept.size == bounds.size, kept.zoom == pageZoom, kept.magnification == magnification,
              kept.url == url, kept.y == tab?.lastY else { return nil }
        return kept.encoded
    }
    @MainActor private final class OrderedPicture {
        var reply: Task<(JSONValue, String), Error>?
        var failure: Error?
    }

    /// The whole page as it is shown now, asked of the helper before anything
    /// queued after this call: the hide of a page leaving the stage reaches the
    /// helper after this picture, and the helper holds that hide until the
    /// picture is taken (YabCore page_snapshot.inc). `snapshot` first waits for
    /// the queue and a document round trip, and the stage's leaving picture
    /// reached the helper after the hide: Chromium then pictured a page whose
    /// view was down, its screenshot waited for a frame never presented, and
    /// the hidden page went on painting (4-6% CPU a hidden heavy tab). Only
    /// this page's own queue is waited for; the document is the helper's
    /// current one, held to what the page still says once the picture is back.
    func snapshotInOrder(_ shot: PageShot, done: @escaping @MainActor (NSImage?, Error?) -> Void) {
        let size = bounds.size, zoom = pageZoom, magnify = magnification, location = url, scroll = tab?.lastY
        let turn = documentTurn, epoch = operationEpoch, width = shot.width ?? size.width
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard !retired, !helperWasLost, shot.rect == nil, size.width > 0, size.height > 0, width > 0, width.isFinite else {
            done(nil, PageShotFailed()); return
        }
        let format = shot.brief || width <= 640 ? "jpeg" : "png"
        let picture = OrderedPicture()
        let previous = tail
        inputSubmission = nil
        tail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !self.retired, !Task.isCancelled, self.operationEpoch == epoch else { return }
            do {
                let (core, id) = try await self.endpoint()
                guard self.operationEpoch == epoch, !self.retired, ChromiumProcess.shared.isCurrent(core) else { return }
                // As it is shown: copied from its surface where the helper can.
                // A still's pixels as they are, through shared memory, not a JPEG.
                let params: [String: JSONValue] = ["tab": .string(id), "format": .string(format), "surface": .bool(!shot.afterUpdates),
                                                   "raw": .bool(!shot.afterUpdates && shot.brief)]
                // The queue goes on once the request is on the wire, not at its reply.
                await withCheckedContinuation { (sent: CheckedContinuation<Void, Never>) in
                    picture.reply = Task { @MainActor in
                        let value = try await core.request("page.snapshot", params: params, timeout: 20, submitted: { sent.resume() })
                        return (value, id)
                    }
                }
            } catch { picture.failure = error }
        }
        let asked = tail
        Task { @MainActor [weak self] in
            await asked?.value
            do {
                guard let reply = picture.reply else { throw picture.failure ?? PageShotFailed() }
                let (value, id) = try await reply.value
                let shared = value["shm"].string.flatMap { name in
                    value["width"].number.flatMap { w in value["height"].number.map { h in (name, Int(w), Int(h)) } }
                }
                guard let self, !self.retired, self.remoteID == id, self.documentTurn == turn, self.bounds.size == size,
                      self.pageZoom == zoom, self.magnification == magnify, self.url == location, self.tab?.lastY == scroll else {
                    if let shared { Self.dropShared(shared.0) }
                    throw PageShotFailed()
                }
                let encoded = value["data"].string
                guard shared != nil || encoded != nil else { throw PageShotFailed() }
                let decoded = await Task.detached(priority: .userInitiated) {
                    if let shared {
                        return Self.sharedPicture(shared.0, pixels: (shared.1, shared.2), width: width).map(SendablePicture.init)
                    }
                    return Self.picture(encoded ?? "", page: size, rect: CGRect(origin: .zero, size: size), width: width, backing: backing)
                        .map(SendablePicture.init)
                }.value
                guard let output = decoded?.image else { throw PageShotFailed() }
                done(output, nil)
            } catch { done(nil, error) }
        }
    }

    /// POSIX shared memory by name. shm_open is variadic, which Swift does not
    /// call; opened read-only it takes no third argument, and on arm64 the two
    /// fixed ones go in registers either way.
    private typealias ShmOpen = @convention(c) (UnsafePointer<CChar>, Int32) -> Int32
    private nonisolated static let shmOpen: ShmOpen? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open")
        .map { unsafeBitCast($0, to: ShmOpen.self) }

    nonisolated static func dropShared(_ name: String) { _ = shm_unlink(name) }

    /// A still the helper left in shared memory (YabCore SharedPixels): BGRA,
    /// premultiplied, `pixels` across and down, its rows packed. Copied out
    /// and unlinked at once, so it lives no longer than this read.
    nonisolated static func sharedPicture(_ name: String, pixels: (Int, Int), width: CGFloat) -> NSImage? {
        defer { dropShared(name) }
        let (w, h) = pixels, size = w * h * 4
        guard w > 0, h > 0, w <= 16_384, h <= 16_384, let open = shmOpen else { return nil }
        let fd = name.withCString { open($0, O_RDONLY) }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, Int(info.st_size) >= size,
              let map = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), map != UnsafeMutableRawPointer(bitPattern: -1) else { return nil }
        let bytes = Data(bytes: map, count: size)
        munmap(map, size)
        guard let provider = CGDataProvider(data: bytes as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: width * CGFloat(h) / CGFloat(w)))
    }

    /// `rect` of a page `size` points across, out of the helper's encoded picture,
    /// `width` points wide at `backing` pixels a point.
    nonisolated static func picture(_ encoded: String, page size: CGSize, rect: CGRect, width: CGFloat, backing: CGFloat) -> NSImage? {
        guard let data = Data(base64Encoded: encoded), let source = CGImageSourceCreateWithData(data as CFData, nil),
              size.width > 0, size.height > 0, rect.width > 0 else { return nil }
        // All of a page for a few pixels of it (the tone's 16 points across):
        // a JPEG decoded at a fraction of its size, not a window's 5 million
        // pixels decoded to be thrown away.
        let wanted = width * backing, small = rect == CGRect(origin: .zero, size: size) && wanted * 4 <= size.width * backing
        let options: [CFString: Any] = small
            ? [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true,
               kCGImageSourceThumbnailMaxPixelSize: Int((wanted * 2 * max(1, size.height / size.width)).rounded(.up))]
            : [kCGImageSourceShouldCacheImmediately: true]
        guard let whole = small ? CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                                : CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else { return nil }
        let across = CGFloat(whole.width) / size.width, down = CGFloat(whole.height) / size.height
        // CGImage counts from its top, as PageShot does.
        let part = CGRect(x: rect.minX * across, y: rect.minY * down, width: rect.width * across, height: rect.height * down).integral
        guard let image = part == CGRect(x: 0, y: 0, width: whole.width, height: whole.height) ? whole : whole.cropping(to: part) else { return nil }
        let height = width * rect.height / rect.width
        let pixels = (width: max(1, Int((width * backing).rounded())), height: max(1, Int((height * backing).rounded())))
        let output = NSSize(width: width, height: height)
        if pixels.width == image.width, pixels.height == image.height { return NSImage(cgImage: image, size: output) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        return context.makeImage().map { NSImage(cgImage: $0, size: output) }
    }

    /// The page's next frame out: what a full picture was asked for when only
    /// the moment mattered, a drawing barrier on every show.
    func afterNextFrame(_ done: @escaping @MainActor (Bool) -> Void) {
        Task { @MainActor in
            do {
                await tail?.value
                let (core, id) = try await endpoint()
                _ = try await core.request("page.frame", params: ["tab": .string(id)])
                done(true)
            } catch { done(false) }
        }
    }
    func pdf(rect: CGRect?, done: @escaping @MainActor (Result<Data, Error>) -> Void) {
        Task { @MainActor in
            do { done(.success(try await printedPDF())) } catch { done(.failure(error)) }
        }
    }
    // TODO(chromium): process/media control, permissions, downloads, find,
    // print, PiP and authenticated child-frame/message relays.
    func setCameraCapture(_ state: PageMediaState) { WebKitOnly.note("Camera capture control", engine: .chromium) }
    func setMicrophoneCapture(_ state: PageMediaState) { WebKitOnly.note("Microphone capture control", engine: .chromium) }
    func stopDisplayCapture() {
        guard media.nativeCaptureKnown else { WebKitOnly.note("Display capture control", engine: .chromium); return }
        stopNativeCapture(kind: "screen")
    }
    func setAudioMuted(_ muted: Bool) {
        desiredAudioMuted = muted
        command("media.mute", ["muted": .bool(muted)])
    }
    func killContent() {
        guard let remoteID, let pid = contentProcess else { return }
        ChromiumProcess.shared.endRenderer(tab: remoteID, pid: pid)
    }

    func input(_ kind: String, _ fields: [String: JSONValue] = [:]) {
        // A press that reached this route belongs to the page. Finish the
        // composition on the same queue before the renderer handles it.
        if hasMarkedText(), ["keyDown", "mouseDown", "rightDown", "middleDown"].contains(kind) {
            finishComposition()
        }
        // A press or a key, as a WebKit page counts it. A pointer passing over
        // the page is nobody asking for a download or a window.
        if ["mouseDown", "rightDown", "middleDown", "keyDown", "text"].contains(kind) { lastInput = ProcessInfo.processInfo.systemUptime }
        if let tab = navigationTab, tab.builtPage === self, tab.deaf != nil,
           let browser = tab.delegate as? Browser { browser.reachedDeaf(tab) }
        if ["mouseDown", "rightDown", "middleDown", "mouseDrag", "rightDrag", "wheel", "magnify", "smartMagnify", "keyDown", "text"].contains(kind) { pageCopyTurn &+= 1 }
        if ["mouseDown", "rightDown", "middleDown", "keyDown", "text"].contains(kind) {
            RelayGuard.felt(self)
            AgentFeed.shared.person(self)
        }
        var p = fields; p["kind"] = .string(kind)
        if ["text", "compose", "unmark", "textSelection"].contains(kind) {
            // A queued IME operation cannot cross a known local document,
            // focus or helper transition. This is not the native focused-
            // document lease, which the current helper does not expose.
            let ticket = ChromiumInputMethodTicket()
            inputMethodTicket = ticket
            guard inputMethodLive, let remote = remoteID,
                  let core = ChromiumProcess.shared.connectedClient,
                  ChromiumNativeTextInput.canForward(nativeText, legacy: ChromiumProcess.shared.legacyTextInput),
                  inputMethodFocused else { ticket.result = .refused; return }
            let focus = ChromiumNativeTextInput.focusToken(nativeText)
            let generation = inputMethodGeneration, turn = documentTurn, epoch = operationEpoch
            inputSubmission = nil
            let previous = tail
            // Unlike ordinary navigation, IME must never construct an endpoint.
            tail = Task { @MainActor [weak self] in
                await previous?.value
                guard let self, !Task.isCancelled, self.inputMethodLive,
                      ChromiumProcess.shared.isCurrent(core), self.remoteID == remote,
                      self.operationEpoch == epoch, self.inputMethodGeneration == generation,
                      self.documentTurn == turn, self.inputMethodFocused,
                      ChromiumNativeTextInput.canForward(self.nativeText, legacy: ChromiumProcess.shared.legacyTextInput),
                      ChromiumNativeTextInput.focusToken(self.nativeText) == focus else { ticket.result = .refused; return }
                var params = p; params["tab"] = .string(remote)
                do {
                    _ = try await core.request("input.send", params: params)
                    self.inputMethodDispatched &+= 1
                    ticket.result = .dispatched
                } catch {
                    ticket.result = .unknown
                    if self.inputMethodLive, self.operationEpoch == epoch {
                        self.queuedOperationFailed(error, navigation: false, request: "input.send")
                    }
                }
            }
        } else if kind == "wheel" || ["mouseDown", "mouseUp", "mouseMove", "mouseDrag", "mouseLeave",
                                     "rightDown", "rightUp", "rightDrag", "middleDown", "middleUp", "middleDrag"].contains(kind) {
            // Preserve wire order, including the original press, without a
            // renderer acknowledgement between every movement. CDP replies
            // after handling input; waiting for each one makes a fast drag
            // accumulate stale points and leaves selection behind the hand.
            enqueueStreamingInput(p)
        }
        else { command("input.send", p) }
    }
    private func pagePoint(_ event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow, from: nil)
        return NSPoint(x: p.x, y: bounds.height - p.y)
    }
    func pointer(_ kind: String, _ event: NSEvent) {
        let p = pagePoint(event)
        var fields: [String: JSONValue] = ["x": .number(p.x), "y": .number(p.y), "clickCount": .number(Double(Self.pointerClickCount(event))), "modifiers": .number(Double(event.modifierFlags.rawValue))]
        if pointerLocked { fields.merge(ChromiumPointerLock.fields(event)) { $1 } }
        input(kind, fields)
    }
    /// AppKit raises an Objective-C exception for clickCount on tracking
    /// events (crash #957), even though those also carry pointer positions.
    static func pointerClickCount(_ event: NSEvent) -> Int {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp: return event.clickCount
        default: return 0
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: moveTracker)
        addTrackingArea(area); tracking = area
    }
    /// The owner of the page's tracking area. Both this route and the
    /// window's first-responder delivery use pointerMoved's event gate.
    ///
    /// AppKit hands a move to a tracking area's owner, and also to the
    /// window's first responder when the window accepts mouse-moved events.
    /// Yab's browser window accepts moves (LinkCard turns it on, the bench
    /// too), so an event can arrive twice. Separate extension panels can
    /// deliver only the first-responder event. Deduplicate actual delivery
    /// rather than dropping that event merely because AppKit is dispatching it.
    private final class MoveTracker: NSResponder {
        weak var page: ChromiumPage?
        init(page: ChromiumPage) { self.page = page; super.init() }
        required init?(coder: NSCoder) { nil }
        override func mouseMoved(with event: NSEvent) { page?.pointerMoved(event) }
        override func mouseEntered(with event: NSEvent) { page?.mouseEntered(with: event) }
        override func mouseExited(with event: NSEvent) { page?.mouseExited(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        // A new native down ends a prior capture, including one whose up
        // arrived before its DOM answer. Flush that sequence before this one.
        topPress?.resolve(false)
        topPress = nil
        // A page holding the pointer has every press, as in Chromium.
        if pointerLocked { window?.makeFirstResponder(self); pointer("mouseDown", event); return }
        if forceInput.interceptDown() { topPress = nil; return }
        window?.makeFirstResponder(self)
        lastPress = (event.modifierFlags.intersection([.command, .shift, .option, .control]), event.buttonNumber, event.timestamp)
        if TopPress.holds(event, in: self, grab: topGrab, zoom: pageZoom, at: topGrabPoint) {
            let press = TopPress(down: event,
                forward: { [weak self] in self?.forwardTopPress($0) },
                drag: { [weak self] in self?.window?.performDrag(with: $0) },
                finished: { [weak self] in self?.topPress = nil })
            topPress = press
            press.check(in: self, zoom: pageZoom)
            return
        }
        pageMouseDown(event)
    }
    private func pageMouseDown(_ event: NSEvent) {
        if takesModifiedLink(event) { return }
        dragState.pressed = event
        pointer("mouseDown", event)
    }
    override func mouseUp(with event: NSEvent) {
        if pointerLocked { pointer("mouseUp", event); return }
        if forceInput.interceptUp(event) { topPress = nil; return }
        if let press = topPress { press.receive(event); return }
        if finishModifiedLink(event) { return }
        forwardMouseUp(event)
    }
    private func forwardTopPress(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: pageMouseDown(event)
        case .leftMouseDragged: mouseDragged(with: event)
        case .leftMouseUp: mouseUp(with: event)
        default: break
        }
    }
    func forwardMouseUp(_ event: NSEvent) {
        pointer("mouseUp", event)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if let self, let tab = self.tab, tab.builtPage === self { tab.onSelectionPause?(tab) }
        }
    }
    override func pressureChange(with event: NSEvent) {
        super.pressureChange(with: event)
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        receivePressure(stage: event.stage, amount: CGFloat(event.pressure),
                        point: CGPoint(x: point.x, y: bounds.height - point.y))
    }
    /// Look Up, on a Force Click and on a three-finger tap alike: both come
    /// as quickLookWithEvent:, which this view must answer itself (#1871,
    /// ChromiumLookUp.swift).
    override func quickLook(with event: NSEvent) {
        guard bounds.width > 0, let tab = navigationTab, !tab.bench else { return super.quickLook(with: event) }
        lookUp(at: convert(event.locationInWindow, from: nil))
    }
    /// Tracking areas also hear moves beneath sibling overlays. Only the
    /// window's actual hit target may feed the remote page or set its cursor.
    func ownsHover(at point: NSPoint) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, let content = window?.contentView,
              let frame = content.superview,
              let hit = content.hitTest(frame.convert(point, from: nil)) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }
    private func leavePointer(with event: NSEvent) {
        topGrab = false
        if hoverAdmitted { pointer("mouseLeave", event) }
        hoverLeft()
        receiveTooltip("")
    }
    /// The window may deliver a move to its first responder without the
    /// tracking owner receiving it (an extension's separate panel does).
    /// Both routes enter the same event gate; neither assumes the other ran.
    override func mouseMoved(with event: NSEvent) {
        pointerMoved(event)
    }
    func pointerMoved(_ event: NSEvent) {
        if lastPointerMove === event { hoverCounts.echoes += 1; return }
        lastPointerMove = event
        if pointerLocked {
            // Every move is the page's while it holds the pointer.
            if !ChromiumPointerLock.dropsMove() { pointer("mouseMove", event) }
            return
        }
        guard ownsHover(at: event.locationInWindow) else { leavePointer(with: event); return }
        hoverMoved()
        if NSCursor.current !== pageCursor { pageCursor.set() }
        pointer("mouseMove", event)
    }
    override func mouseDragged(with event: NSEvent) {
        if pointerLocked { pointer("mouseDrag", event); return }
        if forceInput.holdsInput { return }
        if let press = topPress { press.receive(event); return }
        // A modified press waiting for a link lookup is still a native drag
        // when the hand moves. Restore its down before forwarding the drag.
        if let down = takeModifiedDown() { pointer("mouseDown", down) }
        hoverMoved()
        dragState.pressed = event
        if dragState.source == nil { pointer("mouseDrag", event) }
    }
    override func mouseExited(with event: NSEvent) { leavePointer(with: event) }
    override func rightMouseDown(with event: NSEvent) { pointer("rightDown", event) }
    override func rightMouseDragged(with event: NSEvent) { hoverMoved(); pointer("rightDrag", event) }
    override func rightMouseUp(with event: NSEvent) { pointer("rightUp", event) }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 3 {
            stepButton = 3
            if canGoBack || navigationTab?.backSourceAvailable == true { swipe.step(forward: false, swipe: false, at: event.timestamp) }
        } else if event.buttonNumber == 4, canGoForward {
            stepButton = 4
            swipe.step(forward: true, swipe: false, at: event.timestamp)
        } else if event.buttonNumber == 2 {
            // The page hears it first, as in Chromium: auxclick, or a link it
            // leaves alone opens in the back (receiveOpenLink, middleClick).
            // 4 is the middle button as a page action says it, WebKit's mask,
            // not NSEvent's 2 (Browser.middleClick, feedback #79).
            lastPress = (event.modifierFlags.intersection([.command, .shift, .option, .control]), 4, event.timestamp)
            pointer("middleDown", event)
        } else { super.otherMouseDown(with: event) }
    }
    override func otherMouseUp(with event: NSEvent) {
        if stepButton == event.buttonNumber { stepButton = nil }
        else if event.buttonNumber == 2 { pointer("middleUp", event) }
        else { super.otherMouseUp(with: event) }
    }
    override func otherMouseDragged(with event: NSEvent) {
        if event.buttonNumber == 2 { hoverMoved(); pointer("middleDrag", event) }
        else { super.otherMouseDragged(with: event) }
    }
    override func swipe(with event: NSEvent) {
        if event.deltaX > 0 {
            if canGoBack || navigationTab?.backSourceAvailable == true { swipe.step(forward: false, swipe: true, at: event.timestamp) }
            else if let tab = navigationTab, tab.fromTitle?(tab) != nil { tab.onFrom?(tab) }
            else { super.swipe(with: event) }
        } else if event.deltaX < 0, canGoForward { swipe.step(forward: true, swipe: true, at: event.timestamp) }
        else { super.swipe(with: event) }
    }
    override func scrollWheel(with event: NSEvent) {
        hoverScrolled()
        if event.phase == .began || event.phase == .mayBegin { ScrollLatch.hold(self) }
        WheelLatch.hold(self, event)
        navigationTab?.uncover()
        if let tab = navigationTab { tab.onSelectionTouch?(tab) }
        swipe.receive(event)
    }
    func sendWheel(_ event: NSEvent) {
        input("wheel", ChromiumWheelInput.fields(event, at: pagePoint(event)))
    }
    // Both gestures of two fingers together are Chromium's own,
    // not a change of `magnification`, which is ⌘+'s and lays the page out
    // again. A pinch scales the visual viewport about the fingers and two
    // fingers then pan inside it; a double tap zooms to the block under them.
    override func magnify(with event: NSEvent) {
        guard event.phase != [], event.phase != .mayBegin else { return }
        pageGesture("magnify", event)
    }
    override func smartMagnify(with event: NSEvent) { pageGesture("smartMagnify", event) }
    private func pageGesture(_ kind: String, _ event: NSEvent) {
        hoverScrolled()
        navigationTab?.uncover()
        if let tab = navigationTab { tab.onSelectionTouch?(tab) }
        let p = pagePoint(event)
        var fields: [String: JSONValue] = ["x": .number(p.x), "y": .number(p.y), "timestamp": .number(event.timestamp),
            "modifiers": .number(Double(event.modifierFlags.rawValue))]
        if kind == "magnify" {
            fields["phase"] = .number(Double(event.phase.rawValue))
            fields["magnification"] = .number(Double(event.magnification))
        }
        input(kind, fields)
    }
    override func keyDown(with event: NSEvent) {
        // Escape gives a page's full screen back, as in Chromium and Safari.
        if event.keyCode == 53, media.fullscreen { exitPageFullscreen(); return }
        if !composeKey(event) && !takeEditingKey(event) { key("keyDown", event) }
    }
    override func keyUp(with event: NSEvent) {
        let composed = imeKeys.remove(event.keyCode) != nil
        let edited = editingKeyCodes.remove(event.keyCode) != nil
        if !composed && !edited { key("keyUp", event) }
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            editingKeyCodes.removeAll()
            discardNativeComposition()
            syncRemoteFocus(resigning: true)
            DispatchQueue.main.async { [weak self] in self?.scripts.appearanceChanged() }
        }
        return resigned
    }
    /// A modifier alone: the page hears keydown and keyup, as in Chromium. Not
    /// through key(_:_:): a flagsChanged event has no characters to read.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard !hasMarkedText() else { return }
        input("flagsChanged", ChromiumKeyboardInput.fields(event))
    }
    func sendKey(_ kind: String, _ event: NSEvent) { key(kind, event) }
    private func key(_ kind: String, _ event: NSEvent) {
        input(kind, ChromiumKeyboardInput.fields(event))
    }
    /// AppKit text services can use NSResponder's entrypoint rather than
    /// the input-method protocol's replacement-range variant (AutoFill).
    override func insertText(_ string: Any) {
        insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        imeHandled = true
        marked = NSAttributedString(string: "")
        textEdit(.insert(text, replacing: replacementRange))
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let starting = marked.length == 0
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        imeHandled = true
        // A replaced range is where the words go (a held letter marked in
        // place); a new composition starts at the selection.
        if replacementRange.location != NSNotFound { markedStart = replacementRange.location }
        else if starting { markedStart = nativeRange("selection")?.location ?? NSNotFound }
        let selected = selectedRange.location == NSNotFound ? NSRange(location: marked.length, length: 0) : selectedRange
        textEdit(.mark(marked.string, selected: selected, replacing: replacementRange))
    }
    override func unmarkText() {
        guard marked.length > 0 else { return }
        marked = NSAttributedString(string: ""); textEdit(.unmark)
    }
    /// While a key is being read the edit waits for the key's route; any
    /// other time (a candidate clicked, the accent menu's pick, the
    /// Character Viewer, dictation) it goes to the page at once.
    private func textEdit(_ edit: ChromiumKeyInterpretation.Edit) {
        if keyInterpretation != nil { keyInterpretation?.edits.append(edit) } else { sendTextEdit(edit) }
    }
    /// An edit reaches the page's own text input client as AppKit gave it,
    /// with the range it replaces: a held letter's accent replaces the
    /// letter already typed.
    func sendTextEdit(_ edit: ChromiumKeyInterpretation.Edit) {
        switch edit {
        case .insert(let text, let range):
            var fields: [String: JSONValue] = ["text": .string(text)]
            fields.merge(ChromiumNativeTextInput.replacementFields(range)) { $1 }
            input("text", fields)
        case .mark(let text, let selected, let range):
            var fields: [String: JSONValue] = ["text": .string(text), "selectionStart": .number(Double(selected.location)),
                                               "selectionLength": .number(Double(selected.length))]
            fields.merge(ChromiumNativeTextInput.replacementFields(range)) { $1 }
            input("compose", fields)
        case .unmark:
            input("unmark")
        }
    }
    override func selectedRange() -> NSRange { nativeRange("selection") ?? NSRange(location: NSNotFound, length: 0) }
    override func markedRange() -> NSRange {
        guard marked.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return nativeRange("composition") ?? NSRange(location: markedStart == NSNotFound ? 0 : markedStart, length: marked.length)
    }
    override func hasMarkedText() -> Bool { marked.length > 0 }
    override func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nativeSubstring(range, actualRange: actualRange) }
    override func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { nativeFirstRect(range) }
    override func characterIndex(for point: NSPoint) -> UInt { UInt(NSNotFound) }
    override func doCommand(by selector: Selector) { keyInterpretation?.commands += 1 }
    private func agentInput(_ kind: String, _ fields: [String: JSONValue] = [:]) {
        var fields = fields; fields["kind"] = .string(kind)
        command("scripts.input", fields)
    }
    private func cdpModifiers(_ flags: NSEvent.ModifierFlags) -> Double {
        Double((flags.contains(.option) ? 1 : 0) | (flags.contains(.control) ? 2 : 0) |
               (flags.contains(.command) ? 4 : 0) | (flags.contains(.shift) ? 8 : 0))
    }
    func agentClick(x: Double, y: Double, flags: NSEvent.ModifierFlags) -> Bool {
        guard !retired, x.isFinite, y.isFinite else { return false }
        let fields: [String: JSONValue] = ["x": .number(x), "y": .number(y), "modifiers": .number(cdpModifiers(flags)), "clickCount": .number(1), "button": .string("left")]
        window?.makeFirstResponder(self)
        agentInput("mouseMoved", ["x": .number(x), "y": .number(y)])
        agentInput("mousePressed", fields); agentInput("mouseReleased", fields); return true
    }
    func agentHover(x: Double, y: Double) -> Bool {
        guard !retired, x.isFinite, y.isFinite else { return false }
        agentInput("mouseMoved", ["x": .number(x), "y": .number(y)]); return true
    }
    func agentDrag(from: CGPoint, to: CGPoint, done: @escaping @MainActor (Bool) -> Void) {
        guard !retired, [from.x, from.y, to.x, to.y].allSatisfy(\.isFinite) else { done(false); return }
        // No hand on the mouse, so no session for AppKit to hold: Chromium walks this drag itself.
        command("input.send", ["kind": .string("dragIntercept"), "enabled": .bool(false)])
        agentInput("mouseMoved", ["x": .number(from.x), "y": .number(from.y)])
        agentInput("mousePressed", ["x": .number(from.x), "y": .number(from.y), "button": .string("left"), "clickCount": .number(1)])
        agentInput("mouseMoved", ["x": .number(to.x), "y": .number(to.y), "button": .string("left"), "buttons": .number(1)])
        agentInput("mouseReleased", ["x": .number(to.x), "y": .number(to.y), "button": .string("left"), "clickCount": .number(1)])
        command("input.send", ["kind": .string("dragIntercept"), "enabled": .bool(true)])
        Task { @MainActor in await tail?.value; done(true) }
    }
    func insertAgentText(_ text: String) { agentInput("text", ["text": .string(text)]) }
    func sendAgentKeys(_ strokes: [PageKey]) {
        for stroke in strokes {
            agentInput("key", ["keyCode": .number(Double(stroke.keyCode)), "nativeCode": .number(Double(stroke.code)),
                               "key": .string(stroke.key), "code": .string(stroke.domCode), "text": .string(stroke.text),
                               "modifiers": .number(cdpModifiers(stroke.flags))])
        }
    }
}
