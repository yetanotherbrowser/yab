import AppKit

// The seam between a tab and the engine that draws its page.
//
// Tab.page and Tab.builtPage expose this interface. Capture, PageWords,
// LinkCard and ordinary Bench operations use it; remaining callers still
// migrate from Tab.web and Tab.built in waves.
// Today WebKitPage.swift makes PageView a PageHandle. Another engine must
// supply the same operations without exposing its view type to consumers.
// Tab owns the handle and chooses its factory. Message relays and the
// remaining concrete view consumers still need migration. docs/page-engine.md records the boundary.
//
// Nothing here imports an engine.

/// Which engine draws a page.
enum PageEngineKind: String, Codable, Sendable {
    case webKit
    /// Reserved for the out-of-process engine. The shipping factory does
    /// not advertise it until its implementation is installed.
    case chromium
}

/// A capture state mirrored locally by the engine, including muted tracks.
enum PageMediaState: Int, Codable, Sendable {
    case none = 0, active = 1, muted = 2
}

struct PageCaptureStatus: Equatable, Codable, Sendable {
    let camera: PageMediaState
    let microphone: PageMediaState
    let screen: PageMediaState
}

/// The engine owns its lifecycle activity gate. A missing implementation is
/// unknown, never idle. This seam also lets explicit unit adapters exercise
/// asynchronous draft ownership without waiving the production activity veto.
@MainActor
protocol PageSleepActivity: AnyObject {
    var sleepActivityUnavailable: Bool { get }
}

/// The world a script runs in. Scripts in different worlds see the same
/// document but none of each other's variables; the page's own scripts see
/// only `.page`.
enum PageWorld: Hashable, Sendable {
    /// The page's own world, where its scripts run.
    case page
    /// The engine's one world for its embedder that the page can't see.
    case client
    /// A world of Yab's own by name: the same name is the same world.
    case named(String)

    /// Yab's page scripts and their messages (Web.world).
    static let yab = PageWorld.named("yab")
    static let agent = PageWorld.named("yab-agent")
    static let agentEval = PageWorld.named("yab-agent-eval")
}

/// A frame of the page, as the engine names it to us: where a message came
/// from, what a navigation is for, where to run a script.
struct PageFrame {
    let isMain: Bool
    let url: URL?
    /// The engine's own handle on the frame, to hand back to the same engine.
    let token: AnyObject
    let origin: PageOrigin

    init(isMain: Bool, url: URL?, token: AnyObject, origin: PageOrigin = PageOrigin(scheme: "", host: "", port: 0)) {
        self.isMain = isMain
        self.url = url
        self.token = token
        self.origin = origin
    }
}

/// Stable across the callbacks of one navigation, including a failure
/// delivered after another navigation has begun. It carries no engine object.
struct PageNavigation: Hashable, Codable, Sendable {
    let id: UUID
    init(id: UUID = UUID()) { self.id = id }
}

/// The browser's answer to a document response. Engines translate it only
/// when the browser answers, which may be after this callback returns.
enum PagePolicy: String, Codable, Sendable {
    case allow, cancel, download
}

struct PageDocumentResponse {
    let response: URLResponse
    let isMainFrame: Bool
    let canShowMIMEType: Bool
}

/// Navigation metadata copied from the engine. No frame or action object
/// crosses the policy boundary; nil target means a new window, not false.
struct PageAction {
    struct Kind: RawRepresentable, Equatable, Codable, Sendable {
        let rawValue: Int
        static let other = Kind(rawValue: -1)
        static let linkActivated = Kind(rawValue: 0)
        static let formSubmitted = Kind(rawValue: 1)
        static let backForward = Kind(rawValue: 2)
        static let reload = Kind(rawValue: 3)
        static let formResubmitted = Kind(rawValue: 4)
    }

    struct Source: Equatable, Codable, Sendable {
        let isMainFrame: Bool
        let scheme: String
        let host: String
        let port: Int
    }

    let request: URLRequest
    let kind: Kind
    let targetIsMainFrame: Bool?
    let source: Source?
    let modifierFlags: NSEvent.ModifierFlags
    let buttonNumber: Int
    let shouldPerformDownload: Bool
    let userInitiated: Bool
}

/// A pending child window. The engine keeps its construction context under
/// this id; only copied window features and navigation metadata leave it.
struct PagePopup {
    let id: UUID
    let action: PageAction
    let width: Double?
    let height: Double?
    let toolbarsVisible: Bool?
    let menuForeground: Bool?

    var isPopup: Bool { width != nil || height != nil || toolbarsVisible == false }
    var size: NSSize? {
        guard let width, let height else { return nil }
        return NSSize(width: width, height: height)
    }
}

struct PageDialog: Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case alert, confirm, prompt
        case beforeUnload = "beforeunload"
    }
    let kind: Kind
    let message: String
    let defaultText: String?
    let origin: PageOrigin
}

enum PageDialogReply: Equatable, Codable, Sendable {
    case accept(String?)
    case cancel
}

struct PageFilePicker {
    /// A native save request, rather than an upload chooser.
    var saveName: String? = nil
    let allowsDirectories: Bool
    let allowsMultiple: Bool
    var frame: PageFrame? = nil
    var lifetime: PageFileRequest? = nil
}

/// An origin copied by the engine, never a live frame or security object.
struct PageOrigin: Equatable, Codable, Sendable {
    let scheme: String
    let host: String
    let port: Int
}

enum PageCapture: Int, Codable, Sendable {
    case camera = 0, microphone = 1, cameraAndMicrophone = 2
}

enum PagePermission: String, Codable, Sendable {
    case grant, deny, prompt
}

/// Only password authentication crosses this boundary. TLS evaluation and
/// credentials backed by SecTrust stay in the engine adapter.
struct PageAuthentication: Codable, Sendable {
    let host: String
    let realm: String?
    let scheme: String?
    let method: String
    let previousFailureCount: Int
    let proposedUser: String?
    let proposedPasswordIsEmpty: Bool
}

enum PageAuthenticationReply: Equatable, Codable, Sendable {
    case performDefaultHandling
    case cancel
    case credential(user: String, password: String)
}

/// A rejected TLS chain, already evaluated by the engine. Only certificate
/// bytes and display words reach the browser, never the live trust object.
struct PageCertificate: Codable {
    let host: String
    let port: Int
    let exception: CertificateException?
    let why: String
    let names: String
    /// Native final request URL, when the engine certifies a main-frame
    /// failure before its redirected address has committed.
    var failingURL: URL? = nil
}

/// Navigation notifications arrive on MainActor in the engine's order.
/// No event asks for a synchronous return from the page.
enum PageNavigationEvent {
    case started(PageNavigation?)
    case redirected(PageNavigation?)
    case committed(PageNavigation?)
    case finished(PageNavigation?)
    case failed(PageNavigation?, Error, provisional: Bool)
}

@MainActor
protocol PageEvents: AnyObject {
    /// Answer with the id of a tab made for this request, or nil to refuse.
    /// The reply may arrive after the event returns. Configuration and live
    /// child views stay in the engine's construction adapter.
    func page(_ page: any PageHandle, open popup: PagePopup,
              reply: @escaping @MainActor (UUID?) -> Void)
    func page(_ page: any PageHandle, dialog: PageDialog,
              reply: @escaping @MainActor (PageDialogReply) -> Void)
    func page(_ page: any PageHandle, chooseFiles picker: PageFilePicker,
              reply: @escaping @MainActor ([URL]?) -> Void)
    func page(_ page: any PageHandle, became download: any PageDownload, isMainFrame: Bool)
    func page(_ page: any PageHandle, responsive: Bool)
    func pageClosed(_ page: any PageHandle)
    func page(_ page: any PageHandle, ended reason: PageEnd?)
    func page(_ page: any PageHandle, authenticate challenge: PageAuthentication,
              reply: @escaping @MainActor (PageAuthenticationReply) -> Void)
    func page(_ page: any PageHandle, rejected certificate: PageCertificate)
    func page(_ page: any PageHandle, capture type: PageCapture, origin: PageOrigin,
              reply: @escaping @MainActor (PagePermission) -> Void)
    func page(_ page: any PageHandle, locate origin: PageOrigin,
              reply: @escaping @MainActor (PagePermission) -> Void)
    func page(_ page: any PageHandle, notify origin: PageOrigin,
              reply: @escaping @MainActor (Bool) -> Void)
    func page(_ page: any PageHandle, permission kind: SitePermission, origin: PageOrigin,
              reply: @escaping @MainActor (Bool) -> Void)
    func page(_ page: any PageHandle, localNetwork kind: LocalNetwork.Kind, origin: PageOrigin,
              reply: @escaping @MainActor (Bool) -> Void)
    func page(_ page: any PageHandle, navigation event: PageNavigationEvent)
    func page(_ page: any PageHandle, decide action: PageAction,
              reply: @escaping @MainActor (PagePolicy) -> Void)
    func page(_ page: any PageHandle, decide response: PageDocumentResponse,
              reply: @escaping @MainActor (PagePolicy) -> Void)
}

extension PageEvents {
    func page(_ page: any PageHandle, responsive: Bool) { }
    func page(_ page: any PageHandle, became download: any PageDownload, isMainFrame: Bool) { }
    func page(_ page: any PageHandle, open popup: PagePopup,
              reply: @escaping @MainActor (UUID?) -> Void) { reply(nil) }
    func page(_ page: any PageHandle, dialog: PageDialog,
              reply: @escaping @MainActor (PageDialogReply) -> Void) { reply(.cancel) }
    func page(_ page: any PageHandle, chooseFiles picker: PageFilePicker,
              reply: @escaping @MainActor ([URL]?) -> Void) { reply(nil) }
    func pageClosed(_ page: any PageHandle) { }
    func page(_ page: any PageHandle, ended reason: PageEnd?) { }
    func page(_ page: any PageHandle, authenticate challenge: PageAuthentication,
              reply: @escaping @MainActor (PageAuthenticationReply) -> Void) { reply(.performDefaultHandling) }
    func page(_ page: any PageHandle, rejected certificate: PageCertificate) { }
    func page(_ page: any PageHandle, capture type: PageCapture, origin: PageOrigin,
              reply: @escaping @MainActor (PagePermission) -> Void) { reply(.deny) }
    func page(_ page: any PageHandle, locate origin: PageOrigin,
              reply: @escaping @MainActor (PagePermission) -> Void) { reply(.deny) }
    func page(_ page: any PageHandle, notify origin: PageOrigin,
              reply: @escaping @MainActor (Bool) -> Void) { reply(false) }
    func page(_ page: any PageHandle, permission kind: SitePermission, origin: PageOrigin,
              reply: @escaping @MainActor (Bool) -> Void) { reply(false) }
    func page(_ page: any PageHandle, localNetwork kind: LocalNetwork.Kind, origin: PageOrigin,
              reply: @escaping @MainActor (Bool) -> Void) { reply(false) }
    /// Listeners interested only in lifecycle events keep the engine's
    /// ordinary navigation behavior.
    func page(_ page: any PageHandle, decide action: PageAction,
              reply: @escaping @MainActor (PagePolicy) -> Void) { reply(.allow) }
}

/// A local proxy for a download. A remote engine mirrors the request,
/// origin and Progress here and routes control/events by id. No native
/// engine download or delegate type is part of the consumer contract.
@MainActor
protocol PageDownload: AnyObject {
    var downloadID: UUID { get }
    var originalRequest: URLRequest? { get }
    var isUserInitiated: Bool { get }
    var isExtensionDownload: Bool { get }
    var progress: Progress { get }
    var page: (any PageHandle)? { get }
    /// Native origin surface, including a separate extension surface that
    /// is not a browser-tab PageHandle. Its type is never engine-specific.
    var sourceView: NSView? { get }
    var pageURL: URL? { get }
    var pageTitle: String? { get }
    var downloadEvents: (any PageDownloadEvents)? { get set }
    func cancelDownload(_ done: @escaping @MainActor (Data?) -> Void)
    func restartDownload(from resumeData: Data?, fallback: (any PageHandle)?,
                         done: @escaping @MainActor ((any PageDownload)?) -> Void)
    /// Yab has atomically published the complete file. An engine with its own
    /// download journal must acknowledge the final path before it is recorded.
    func didPublish(to file: URL) async throws
}

extension PageDownload {
    var isExtensionDownload: Bool { false }
    func didPublish(to file: URL) async throws {}
}

@MainActor
protocol PageDownloadEvents: AnyObject {
    func download(_ download: any PageDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void)
    func downloadDidFinish(_ download: any PageDownload)
    func download(_ download: any PageDownload, didFailWithError error: Error, resumeData: Data?)
}

/// Script to run in a page.
enum PageCode {
    /// Evaluated as the last expression of a script: what it ends on.
    case expression(String)
    /// The body of an async function, its arguments named: what it returns,
    /// a promise awaited.
    case function(String, arguments: [String: Any])
}

/// What a picture of the page takes.
struct PageShot {
    /// The part of the page's view, in its coordinates; nil for all of it.
    var rect: CGRect? = nil
    /// The picture's width in points, scaled to; nil for the rect's own.
    var width: CGFloat? = nil
    /// Waits for what is about to be drawn, as WebKit's snapshot does by
    /// default; false takes what is on screen now.
    var afterUpdates = true
    /// Shown for a moment, never kept or handed on: Chromium needn't encode a
    /// whole window losslessly for it (ten times the bytes and the time).
    var brief = false
    /// An agent's look at the whole view, drawn for it after any scroll: a
    /// scroll the page reports while it is drawn is in the picture, not a
    /// reason to refuse it. A part of the page (rect) still is.
    var scrollMayMove = false

    /// Whether a picture taken while the page's reported scroll went from
    /// `before` to `after` still answers this shot.
    func keeps(scroll before: Double?, _ after: Double?) -> Bool {
        before == after || (scrollMayMove && rect == nil)
    }
}

/// One key as both ways need it: the event's key code and characters
/// for a window, and the DOM's key, code and keyCode, and the text it
/// puts in, for script.
struct PageKey: Equatable {
    var command = false
    var shift = false
    var option = false
    var control = false
    /// The Mac key code and the characters, for an NSEvent.
    let code: UInt16
    let characters: String
    /// KeyboardEvent.key, .code and .keyCode.
    let key: String
    let domCode: String
    let keyCode: Int
    /// What it types into a field, nothing for a key that doesn't.
    let text: String

    var flags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }

    /// Enter or Space: presses what has the focus, a Send among them.
    var presses: Bool { key == "Enter" || key == " " }

    /// For the script.
    var json: [String: Any] {
        ["key": key, "code": domCode, "keyCode": keyCode, "text": text,
         "meta": command, "shift": shift, "alt": option, "ctrl": control]
    }
}

/// A script endpoint, including a separate extension document that is not
/// a browser tab. Engines keep their own frame tokens behind this interface.
@MainActor
protocol PageScriptTarget: NSView {
    /// Script run in `world` (and `frame`, nil for the main one): its value,
    /// or the error. `gesture` makes it count as the person's own action, as
    /// a click does, for what only a click may do (play with sound, open a
    /// window); Yab's own reads run without one (QuietScript.swift).
    func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool,
                  done: (@MainActor (Result<Any?, Error>) -> Void)?)
    func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool) async throws -> Any?
}

/// A page, drawn by some engine. It is the view on the stage itself, so the
/// stage moves and sizes it like any other view.
@MainActor
protocol PageHandle: PageScriptTarget {
    var engine: PageEngineKind { get }
    /// Weakly held. Replacing the listener transfers future notifications;
    /// already-issued policy replies still belong to the engine request.
    var events: (any PageEvents)? { get set }
    /// Independent of the window's navigation delegate, weakly held. Engine
    /// adapters copy changed values here on the main actor, in order.
    var stateEvents: (any PageStateEvents)? { get set }
    /// End observation, input, scripts and media, then release the view.
    func retire(call: Bool, pictureInPicture: Bool)

    // MARK: what it shows

    var url: URL? { get }
    /// The history entry that committed, before a provisional navigation.
    var committedURL: URL? { get }
    var historyEntry: PageHistoryEntry? { get }
    var title: String? { get }
    var isLoading: Bool { get }
    var estimatedProgress: Double { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    /// ⌘+ and ⌘−: the page laid out again larger or smaller.
    var pageZoom: CGFloat { get set }
    /// The pinch: what is on screen magnified.
    var magnification: CGFloat { get set }
    var themeColor: NSColor? { get }
    /// The last trusted native input, in system uptime, consumed by popup
    /// policy. An out-of-process engine mirrors this local input stamp.
    var lastInput: TimeInterval? { get set }

    // MARK: going places

    func navigate(to request: URLRequest)
    func navigate(html: String, base: URL?)
    /// `fromOrigin` skips every cache, as ⇧⌘R.
    func reload(fromOrigin: Bool)
    func stopLoading()
    func navigateBack()
    func navigateForward()

    // MARK: the three primitives

    /// Child frames the engine can currently address, excluding the main
    /// frame, in tree order, at most 40 and less than eight levels deep.
    /// An engine without frame discovery answers with an empty list.
    func childFrames(_ done: @escaping @MainActor ([PageFrame]) -> Void)

    /// A picture of the page as it is drawn.
    func snapshot(_ shot: PageShot, done: @escaping @MainActor (NSImage?, Error?) -> Void)

    /// The document drawn as PDF. `rect` is in document coordinates;
    /// nil lets the engine choose the whole document.
    func pdf(rect: CGRect?, done: @escaping @MainActor (Result<Data, Error>) -> Void)

    // Message registration is not yet abstracted: Tab.relays still installs
    // WebKit handlers. It is the remaining third primitive.

    // MARK: agent input

    /// Native input in CSS pixels, accounting for page zoom and pinch.
    /// A pointer action without a window fails without dispatching events.
    func agentClick(x: Double, y: Double, flags: NSEvent.ModifierFlags) -> Bool
    func agentHover(x: Double, y: Double) -> Bool
    func agentDrag(from: CGPoint, to: CGPoint, done: @escaping @MainActor (Bool) -> Void)
    /// Native text and keys for a page in a window. AgentPage supplies the
    /// existing script fallback when a background page has no window.
    func insertAgentText(_ text: String)
    func sendAgentKeys(_ strokes: [PageKey])

    // MARK: the engine's processes

    /// The process drawing this page's content, if it has one of its own yet.
    var contentProcess: pid_t? { get }
    /// The shared GPU process, when the engine exposes one. A remote engine
    /// mirrors local process ids; reads never wait on its page process.
    var gpuProcess: pid_t? { get }
    var captureStatus: PageCaptureStatus { get }
    func setCameraCapture(_ state: PageMediaState)
    func setMicrophoneCapture(_ state: PageMediaState)
    func stopDisplayCapture()
    /// The content process ended, as Activity Monitor's Force Quit would.
    func killContent()
}

extension PageScriptTarget {
    /// An expression, its value (`evaluateJavaScript`).
    func run(_ script: String, in world: PageWorld = .page, frame: PageFrame? = nil, gesture: Bool = true,
             done: (@MainActor (Result<Any?, Error>) -> Void)? = nil) {
        evaluate(.expression(script), in: world, frame: frame, gesture: gesture, done: done)
    }

    func run(_ script: String, in world: PageWorld = .page, frame: PageFrame? = nil, gesture: Bool = true) async throws -> Any? {
        try await evaluate(.expression(script), in: world, frame: frame, gesture: gesture)
    }

    /// An async function's body with its arguments, what it returns
    /// (`callAsyncJavaScript`).
    func call(_ body: String, arguments: [String: Any] = [:], in world: PageWorld = .page, frame: PageFrame? = nil,
              gesture: Bool = true, done: (@MainActor (Result<Any?, Error>) -> Void)? = nil) {
        evaluate(.function(body, arguments: arguments), in: world, frame: frame, gesture: gesture, done: done)
    }

    func call(_ body: String, arguments: [String: Any] = [:], in world: PageWorld = .page, frame: PageFrame? = nil,
              gesture: Bool = true) async throws -> Any? {
        try await evaluate(.function(body, arguments: arguments), in: world, frame: frame, gesture: gesture)
    }

    /// In Yab's own world, answered with the value or nil for none or an
    /// error, as `evaluateInYab` answers.
    func runInYab(_ script: String, then: (@MainActor (Any?) -> Void)? = nil) {
        run(script, in: .yab) { then?(try? $0.get()) }
    }

}

extension PageHandle {
    func snapshot(_ shot: PageShot = PageShot()) async throws -> NSImage {
        try await withCheckedThrowingContinuation { done in
            snapshot(shot) { image, error in
                if let image { done.resume(returning: image) } else { done.resume(throwing: error ?? PageShotFailed()) }
            }
        }
    }
}

/// No picture and no word from the engine why.
struct PageShotFailed: Error {}

/// An engine must never interpret another engine's frame as the main frame.
enum PageEngineError: Error {
    case foreignFrame
}
