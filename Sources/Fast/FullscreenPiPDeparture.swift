import AppKit
import QuartzCore
import WebKit

/// Owns delayed automatic PiP for an inline film whose source is hidden or
/// minimized. Fullscreen playback stays in its presentation even off Space.
@MainActor
final class FullscreenPiPDeparture {
    enum Mode: Equatable { case ordinary, window, player, moving }

    @MainActor struct Frame {
        let tab: Tab
        let web: WKWebView
        let source: NSWindow
        let host: NSWindow?
        let mode: Mode
        let hostOnSpace: Bool?
        let sourceOnSpace: Bool
        let usable: Bool
        let sourceHidden: Bool
        let sourceMinimized: Bool

        static func read(_ browser: Browser) -> Frame? {
            guard let tab = browser.active, let web = tab.built,
                  let source = BrowserWindows.shared.window(for: browser) else { return nil }
            let mode: Mode
            let host: NSWindow?
            switch web.fullscreenState {
            case .enteringFullscreen, .exitingFullscreen:
                mode = .moving; host = web.window
            case .inFullscreen:
                mode = .player; host = web.window
            case .notInFullscreen:
                if browser.fullScreen {
                    // A SwiftUI flag can precede/follow the native transition.
                    mode = source.styleMask.contains(.fullScreen) ? .window : .moving
                } else {
                    mode = source.styleMask.contains(.fullScreen) ? .moving : .ordinary
                }
                host = web.window === source ? source : nil
            @unknown default:
                mode = .moving; host = nil
            }
            return Frame(tab: tab, web: web, source: source, host: host, mode: mode,
                         hostOnSpace: host?.isOnActiveSpace, sourceOnSpace: source.isOnActiveSpace,
                         usable: host.map { $0.windowNumber > 0 && $0.isVisible && !$0.isMiniaturized } ?? false,
                         sourceHidden: source.windowNumber > 0 && (NSApp.isHidden || !source.isVisible),
                         sourceMinimized: source.isMiniaturized)
        }

        var appDeparture: Bool {
            mode == .ordinary && host === source && (sourceHidden || sourceMinimized)
        }
        var departed: Bool { appDeparture }
        var sourceAway: Bool { sourceHidden || sourceMinimized || !sourceOnSpace }
    }

    @MainActor final class Context {
        enum Phase: Equatable { case waiting, requested, extracting, installed }
        weak var tab: Tab?
        weak var web: WKWebView?
        weak var source: NSWindow?
        weak var host: NSWindow?
        let navigation: CFTimeInterval?
        let webID: ObjectIdentifier
        let mode: Mode
        let appDeparture: Bool
        var phase = Phase.waiting
        var mayUndoSystemRequest = true

        init(_ frame: Frame) {
            tab = frame.tab; web = frame.web; source = frame.source; host = frame.host
            navigation = frame.tab.askedAt; mode = frame.mode; webID = ObjectIdentifier(frame.web)
            appDeparture = frame.appDeparture
        }

        func owns(_ frame: Frame) -> Bool {
            tab === frame.tab && web === frame.web && source === frame.source && navigation == frame.tab.askedAt
        }

        func original(_ frame: Frame) -> Bool { owns(frame) && frame.departed && mode == frame.mode && host === frame.host }
        /// A successful system-PiP request may itself leave WebKit's
        /// fullscreen window before its promise answers. Keep that owned
        /// native handoff alive, but never use it to authorize fallback
        /// extraction of a page from a visible Desktop window.
        func nativeHandoff(_ frame: Frame) -> Bool {
            guard owns(frame), mode == .player else { return false }
            if frame.mode == .moving { return frame.host == nil || frame.host === host || frame.host === source }
            return (frame.mode == .ordinary || frame.mode == .window) && frame.host === source
        }

    }

    typealias Later = (@escaping @MainActor @Sendable () -> Void) -> Void
    private let capture: (Browser) -> Frame?
    private let later: Later
    private let onSpace: (NSWindow) -> Bool?
    private let sourceFocused: (NSWindow) -> Bool
    private let spaceCenter: NotificationCenter
    private weak var browser: Browser?
    private weak var closedSource: NSWindow?
    private var current: Context?
    private var issued: [ObjectIdentifier: Context] = [:]
    private weak var latest: Context?
    private var spaceToken: NSObjectProtocol?
    private var windowTokens: [NSObjectProtocol] = []

    init(capture: @escaping (Browser) -> Frame? = Frame.read,
         later: @escaping Later = { action in DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: action) },
         onSpace: @escaping (NSWindow) -> Bool? = { window in
             guard window.windowNumber > 0, window.isVisible, !window.isMiniaturized else { return nil }
             return window.isOnActiveSpace
         }, sourceFocused: @escaping (NSWindow) -> Bool = { $0.isKeyWindow }) {
        self.capture = capture; self.later = later; self.onSpace = onSpace; self.sourceFocused = sourceFocused
        self.spaceCenter = NSWorkspace.shared.notificationCenter
    }

    deinit {
        if let spaceToken { spaceCenter.removeObserver(spaceToken) }
        for token in windowTokens { NotificationCenter.default.removeObserver(token) }
    }

    func start(for browser: Browser) {
        stop()
        self.browser = browser
        spaceToken = spaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.changed() } }
        let center = NotificationCenter.default
        windowTokens = [
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let browser = self.browser, let frame = self.capture(browser),
                          let window = note.object as? NSWindow, window === frame.source || window === frame.host else { return }
                    self.changed()
                }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let browser = self.browser, let frame = self.capture(browser),
                          self.current?.phase == .installed, let window = note.object as? NSWindow,
                          window === frame.source else { return }
                    browser.appBack()
                }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let browser = self.browser, let window = note.object as? NSWindow else { return }
                    if window === self.capture(browser)?.source {
                        self.closedSource = window
                        self.cancel()
                        return
                    }
                    // System PiP can close its own fullscreen host before
                    // the script promise returns. Only that owned native
                    // handoff may survive; a source-window close cancels it.
                    // The primary Browser is retained and can reopen.
                    if let current = self.current, window === current.host, current.phase == .waiting { self.cancel() }
                }
            },
        ]
        for name in [NSApplication.didResignActiveNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification] {
            windowTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            })
        }
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            windowTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let browser = self.browser, let frame = self.capture(browser),
                          let window = note.object as? NSWindow, window === frame.source else { return }
                    self.changed()
                }
            })
        }
    }

    func stop() {
        cancel()
        if let spaceToken { spaceCenter.removeObserver(spaceToken) }
        spaceToken = nil
        for token in windowTokens { NotificationCenter.default.removeObserver(token) }
        windowTokens = []
        closedSource = nil
        browser = nil
    }

    func cancel() { current = nil }

    /// A later user/ordinary request on this page owns its presentation.
    /// A rejected old system-PiP answer must not close that newer owner.
    @discardableResult func supersede(with tab: Tab) -> Bool {
        let hadContext = current != nil || !issued.isEmpty
        // A new manual request for the same live page may own the
        // presentation already entering. Another page cannot own it.
        for request in issued.values where request.tab === tab && request.web === tab.built && request.navigation == tab.askedAt {
            request.mayUndoSystemRequest = false
        }
        cancel()
        return hadContext
    }

    enum Receipt { case ordinary, automatic(Context), rejected }

    func receipt(for tab: Tab, in browser: Browser, origin: NSWindow? = nil) -> Receipt {
        guard let web = tab.built, let request = issued[ObjectIdentifier(web)], request.tab === tab,
              request.web === web, request.navigation == tab.askedAt else { return .ordinary }
        if let origin, origin !== request.source && origin !== request.host { return .ordinary }
        if !request.mayUndoSystemRequest { return .ordinary }
        return acceptsSystemAnswer(request, in: browser) ? .automatic(request) : .rejected
    }

    /// A waiting/cancelled timer is not a native request. Register only
    /// after Browser.pictureOut has passed every guard and is about to ask
    /// WebKit; otherwise a later site button would be rejected indefinitely.
    func beginRequest(_ context: Context, in browser: Browser) -> Bool {
        guard permits(context, in: browser) else { return false }
        // Keep distinct pending pages until each native promise answers;
        // another fullscreen departure cannot erase an older stale receipt.
        issued = issued.filter { $0.value.web != nil && $0.value.tab?.gone == false }
        issued[context.webID]?.mayUndoSystemRequest = false
        issued[context.webID] = context
        latest = context
        return true
    }

    @discardableResult func finished(_ context: Context) -> Bool {
        let stopped = current === context && context.phase == .requested
        if stopped { cancel() }
        if issued[context.webID] === context { issued[context.webID] = nil }
        if latest === context { latest = nil }
        return stopped
    }

    func beginFallback(_ context: Context, in browser: Browser) -> Bool {
        // A refused player-fullscreen request needs separately qualified
        // native-exit proof. Keep #1007's whole-page guard in that case.
        guard context.mode == .ordinary || context.mode == .window, permits(context, in: browser) else { return false }
        context.phase = .extracting
        return true
    }

    func mayUndoSystemAnswer(_ context: Context, in browser: Browser) -> Bool {
        guard issued[context.webID] === context, context.mayUndoSystemRequest,
              let tab = context.tab, let web = context.web, !tab.gone, !tab.asleep,
              tab.built === web, tab.askedAt == context.navigation, tab.delegate === browser,
              browser.everyTab.contains(where: { $0 === tab }), web.fullscreenState == .notInFullscreen else { return false }
        return true
    }

    private func policy(_ frame: Frame, in browser: Browser) -> Bool {
        (Browser.benchAway ?? (!Thrift.on && browser.prefs.floatsOnLeave)) && browser.active === frame.tab
            && !frame.tab.gone && !frame.tab.asleep && !frame.tab.onCall
            && frame.tab.built === frame.web && frame.tab.delegate === browser
            && browser.everyTab.contains(where: { $0 === frame.tab })
            && browser.minimizeHold.allowsAuto(frame.tab.id)
            && AutomaticPiPSites.shared.allows(frame.tab.address) && Players.follows(frame.tab)
    }

    private func continues(_ context: Context, in browser: Browser, frame: Frame) -> Bool {
        guard current === context, context.owns(frame), policy(frame, in: browser) else { return false }
        if context.appDeparture, context.phase != .installed, !frame.tab.noisy || frame.tab.muted { return false }
        switch context.phase {
        case .waiting: return context.original(frame)
        case .extracting: return context.original(frame)
        case .requested:
            return context.original(frame) || (context.nativeHandoff(frame) && context.host.flatMap(onSpace) != true)
        case .installed:
            if context.mode == .player {
                return context.original(frame) || (context.nativeHandoff(frame) && context.host.flatMap(onSpace) != true)
            }
            return frame.sourceAway
        }
    }

    func permits(_ context: Context, in browser: Browser) -> Bool {
        guard context.phase == .requested || context.phase == .extracting, let frame = capture(browser) else { return false }
        return current === context && context.original(frame) && policy(frame, in: browser)
            && (!context.appDeparture || (frame.tab.noisy && !frame.tab.muted))
    }

    /// Only the native promise success may finish after its own fullscreen
    /// window disappeared. A failed request still needs original off-Space
    /// evidence before the existing (non-fullscreen) fallback can run.
    func acceptsSystemAnswer(_ context: Context, in browser: Browser) -> Bool {
        guard context.phase == .requested || context.phase == .installed, let frame = capture(browser) else { return false }
        return continues(context, in: browser, frame: frame)
    }

    static func back(quietly: Bool, appActive: Bool, selected: Bool, departure: Bool?) -> Bool {
        quietly && appActive && selected && departure != true
    }

    func installed(_ context: Context) { if current === context { context.phase = .installed } }
    /// Observation of the actual controller state, never an injected result.
    var benchPhase: Context.Phase? { Store.testing ? current?.phase : nil }
    var benchIssued: Context? { Store.testing ? latest : nil }

    /// Becoming active in another Yab window is not returning to this
    /// fullscreen Space. Its ordinary appBack policy resumes on return.
    func staysAway(in browser: Browser) -> Bool {
        guard let current, let frame = capture(browser), continues(current, in: browser, frame: frame) else { return false }
        // Native PiP may return its inline page to the Desktop already
        // being used. Mere Space/occlusion events do not undo it. An app
        // activation for another Yab window does not either: return when
        // this source actually takes the key focus (also observed above).
        if current.phase == .installed, current.mode == .player,
           current.nativeHandoff(frame), frame.sourceOnSpace { return !sourceFocused(frame.source) }
        return true
    }

    func changed() {
        guard let browser else { return }
        guard let frame = capture(browser) else { cancel(); return }
        if closedSource === frame.source {
            guard frame.usable, frame.host === frame.source else { cancel(); return }
            closedSource = nil
        }
        if let current {
            if continues(current, in: browser, frame: frame) { return }
            let returnedToHost = current.mode == .player
                ? frame.host === current.host && frame.hostOnSpace == true && frame.usable
                : !frame.sourceAway
            let returning = current.owns(frame) && returnedToHost && current.phase == .installed
            cancel()
            if returning && NSApp.isActive { browser.appBack() }
        }
        // Visible fullscreen and missing/transitioning hosts never start
        // an away watcher or a delayed extraction attempt.
        guard frame.departed, policy(frame, in: browser),
              !frame.appDeparture || (frame.tab.noisy && !frame.tab.muted),
              !browser.tabs.contains(where: \.pictureInPicture),
              !browser.floater.showing || browser.floater.homing else { return }
        let context = Context(frame)
        current = context
        later { [weak self, weak browser, weak context] in
            guard let self, let browser, let context, let frame = self.capture(browser),
                  self.continues(context, in: browser, frame: frame) else { return }
            context.phase = .requested
            browser.leftFullscreen(context)
        }
    }
}
