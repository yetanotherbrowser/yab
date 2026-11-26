import SwiftUI
import SyncKit
import UIKit
import os
import UserNotifications

/// Yab for iPhone. A UIKit app around one SwiftUI tree: the window's root is
/// a UIKit container around the hosting controller so the status bar follows the page
/// (light over a dark page), which a SwiftUI App can't say.
@main
final class YabPhoneApp: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Dates in English, as the rest of Yab (EnglishDates).
        EnglishDates.apply()
        MainStalls.shared?.start()
        UNUserNotificationCenter.current().delegate = self
        let options = LaunchOptions.current
        // Named states land in their final frame: nothing moves on the way there.
        if options.noAnimation {
            Motion.disabled = true
            UIView.setAnimationsEnabled(false)
        }
        // The day's count and crash reports, for a build that has a site;
        // MetricKit is listened to from the start (Reports/).
        Reports.start(options)
        return true
    }

    /// The browser's keys in the main menu, the list holding ⌘ shows (BrowserKeys).
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        BrowserKey.build(builder)
    }

    /// A key whose responder chain started outside the browser's window (no
    /// first responder yet) still reaches the browser in front.
    @objc func browserKey(_ command: UIKeyCommand) {
        keysLog.info("key reached the app delegate: \(String(describing: command.propertyList), privacy: .public)")
        Self.frontRoot?.browserKey(command)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(browserKey(_:)) {
            return Self.frontRoot?.canPerformAction(action, withSender: sender) ?? false
        }
        return super.canPerformAction(action, withSender: sender)
    }

    private static var frontRoot: RootController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.keyWindow?.rootViewController as? RootController
    }

    // The completion-handler form, answered on the main thread: the async
    // form's bridged handler returns off main, and UIKit stops the app on
    // a tapped notification.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        let content = response.notification.request.content
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier, content.threadIdentifier == ApprovalNotice.thread else { return }
        SyncPush.openApproval(content.userInfo["approval"] as? String ?? response.notification.request.identifier)
    }

    // Sync's silent pushes (Sync/SyncPush).
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        SyncPush.registered(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        SyncPush.failed(error)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        SyncPush.woke(completionHandler)
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var keyboardWarmed = false
    private var app: AppModel?
    private var continuity: PageContinuity?
    /// The scene was just made: its first trip to the foreground is the
    /// launch, already decided (Field/LaunchKeyboard), not a return.
    private var launching = false

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let options = LaunchOptions.current
        // The ad blocker's compiled lists looked up while the app is made;
        // a page that opens before they are found loads unblocked.
        Shield.shared.start()
        let app = AppModel.launch(options)
        app.sync.attach(app, setup: SyncBridge.Setup.resolve(options: options))
        if let response = connectionOptions.notificationResponse {
            let content = response.notification.request.content
            if content.threadIdentifier == ApprovalNotice.thread {
                app.sync.openAssistantApproval(content.userInfo["approval"] as? String ?? response.notification.request.identifier)
            }
        }
        Reports.attach(app)
        if let tab = options.tab { app.browser.select(tab) }
        // Tasks start with the app, not with the first drawing of their layer.
        _ = app.taskDesk
        self.app = app
        // Links and requests from outside Yab: the share sheet's and others (Entrances).
        Entrances.attach(app, options: options)
        // Launched for something (a link, a page from the Mac, a notification,
        // a Home Screen action, a named state): that is what shows. Test
        // runs keep the page unless they ask for the field. Otherwise New
        // Tab's field stands before the window is drawn, so the first frame
        // has it and the keyboard rises with the launch, not after the page.
        let asked = options.state != nil || options.tab != nil || options.initialURL != nil
            || (options.isTestRun && !options.launchKeyboard)
            || !connectionOptions.urlContexts.isEmpty || !connectionOptions.userActivities.isEmpty
            || connectionOptions.notificationResponse != nil || connectionOptions.shortcutItem != nil
        launching = true
        openFieldArriving(.launch, asked: asked)
        let window = UIWindow(windowScene: scene)
        // Yab's type is drawn at its own sizes (17 in a chat, as Messages'),
        // never scaled by the system's Larger Text: the whole window, SwiftUI
        // and UIKit alike, reads the default category.
        window.traitOverrides.preferredContentSizeCategory = .large
        window.rootViewController = RootController(app: app)
        window.makeKeyAndVisible()
        self.window = window
        if let state = options.state {
            Task { await StateRunner.run(state, in: app, options: options) }
        }
        // A link that launched Yab: the Live Activity's yab://task/... opens
        // its task; one from another app is a new tab.
        // yab://join/<code>, the Camera on a Mac's Add a Device code, joins.
        for context in connectionOptions.urlContexts where !app.taskDesk.open(context.url) {
            let url = context.url
            DispatchQueue.main.async { if !app.sync.openJoinLink(url) { app.openLink(url) } }
        }
        // The page in front is offered to the Mac (Handoff); one picked up
        // from the Mac launched Yab here, and opens as a tab of its own.
        continuity = PageContinuity(app: app, scene: scene)
        continuity?.start()
        for activity in connectionOptions.userActivities where activity.activityType == ContinuePage.type {
            DispatchQueue.main.async { app.pickUp(activity) }
        }
    }

    /// A page picked up from the Mac by Handoff while Yab runs.
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        Links.trace("continue type=\(userActivity.activityType) url=\(String(describing: userActivity.webpageURL))")
        app?.pickUp(userActivity)
    }

    /// A link while Yab runs: a task's from the Live Activity, else a new tab (Entrances/Links).
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        Links.trace("openURLContexts state=\(scene.activationState.rawValue) selected=\(app?.browser.tab?.id ?? "nil") field=\(app?.field.shown == true) away=\(String(describing: LaunchKeyboard.away()))")
        guard let app else { return }
        for context in contexts where !app.taskDesk.open(context.url) && !app.sync.openJoinLink(context.url) { app.openLink(context.url) }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        Links.trace("willResignActive state=\(scene.activationState.rawValue) selected=\(app?.browser.tab?.id ?? "nil") field=\(app?.field.shown == true) away=\(String(describing: LaunchKeyboard.away()))")
        // Dialogs go; a download goes on and says where it is on return.
        app?.pages.appWillResignActive()
        if app?.hasPrivateForeground == true || app?.privateLock.presentsPrompt == true {
            (window?.rootViewController as? RootController)?.setInactivePrivacyCover(true)
        }
        app?.tabClear.resigned()
        // With Open with Face ID the lock closes as Yab goes: private media
        // stops and leaves Picture in Picture with it. Ordinary pages play on.
        if let lock = app?.privateLock, lock.requiresAuthentication, lock.phase != .authenticating {
            app?.pages.pausePrivateMedia()
        }
        app?.privateLock.willResignActive()
        app?.checkpointProfile()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        Links.trace("willEnterForeground state=\(scene.activationState.rawValue) selected=\(app?.browser.tab?.id ?? "nil") field=\(app?.field.shown == true) away=\(String(describing: LaunchKeyboard.away()))")
        // The launch already said what it is for; this is a return. Decided
        // before the snapshot gives way, so the first live frame has the field.
        if launching { launching = false; return }
        let options = LaunchOptions.current
        openFieldArriving(.back, asked: options.isTestRun && !options.launchKeyboard)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        Links.trace("didBecomeActive state=\(scene.activationState.rawValue) selected=\(app?.browser.tab?.id ?? "nil") field=\(app?.field.shown == true) away=\(String(describing: LaunchKeyboard.away()))")
        app?.privateLock.didBecomeActive()
        app?.tabClear.becameActive()
        (window?.rootViewController as? RootController)?.setInactivePrivacyCover(false)
        app?.pages.appDidBecomeActive()
        warmKeyboardOnce()
    }

    /// iOS loads the keyboard the first time a field asks for it, and that stops
    /// the first tap's frame. Asked for here, while nothing moves, and let go in the
    /// same turn, so nothing shows.
    private func warmKeyboardOnce() {
        guard !keyboardWarmed else { return }
        keyboardWarmed = true
        let options = LaunchOptions.current
        guard !options.isTestRun || ProcessInfo.processInfo.environment["YAB_FRAMEMETER"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let window = self.window, self.app?.surfaces.field == nil, !Self.holdsFocus(window) else { return }
            let field = UITextField(frame: .zero)
            window.addSubview(field)
            field.becomeFirstResponder()
            field.resignFirstResponder()
            field.removeFromSuperview()
        }
    }

    private static func holdsFocus(_ view: UIView) -> Bool {
        view.isFirstResponder || view.subviews.contains(where: holdsFocus)
    }

    /// New Tab's field as Yab comes to the front, at once, in place. A link,
    /// a page from the Mac or the share sheet's queue arriving after it
    /// puts it away as it opens its tab (Entrances/Links).
    private func openFieldArriving(_ moment: LaunchKeyboard.Moment, asked: Bool) {
        guard let app else { return }
        let situation = app.launchKeyboardSituation(moment, asked: asked, away: LaunchKeyboard.away())
        if LaunchKeyboard.opens(situation) { app.openLaunchField() }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        Links.trace("didEnterBackground state=\(scene.activationState.rawValue) selected=\(app?.browser.tab?.id ?? "nil") field=\(app?.field.shown == true) away=\(String(describing: LaunchKeyboard.away()))")
        guard let app else { return }
        app.tabClear.resigned()
        app.privateLock.didEnterBackground()
        let options = LaunchOptions.current
        if !options.isTestRun || options.launchKeyboard { LaunchKeyboard.left() }
        #if DEBUG
        if options.isTestRun {
            let offset = UserDefaults.standard.double(forKey: "YabTestAwaySeconds")
            if offset > 0 {
                LaunchKeyboard.left(at: Date().addingTimeInterval(-offset))
                app.tabClear.clock = {
                    let now = TabClearPolicy.Clock.now
                    return .init(date: now.date.addingTimeInterval(offset), uptime: now.uptime + offset)
                }
                Links.trace("fakeAway seconds=\(offset)")
            }
        }
        // #350's world: iOS ends the pages' processes while Yab is away.
        if UserDefaults.standard.bool(forKey: "YabTestEndPagesAway") { app.pages.endPageProcessesForTests() }
        #endif
        let application = UIApplication.shared
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = application.beginBackgroundTask(withName: "Save browser") {
            if backgroundTask != .invalid {
                application.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        Task { @MainActor in
            await app.flushProfile()
            if backgroundTask != .invalid {
                application.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
    }
}

/// UIKit owns the cover beside the hosted SwiftUI view. Both fill the window.
final class RootController: UIViewController {
    private let content: UIHostingController<AnyView>
    private let app: AppModel
    private let privacyCover = UIView()

    init(app: AppModel) {
        self.app = app
        content = UIHostingController(rootView: AnyView(RootView().environment(app)
            .environment(\.syncedArtwork, app.sync.folderArtwork)))
        super.init(nibName: nil, bundle: nil)
    }

    override var undoManager: UndoManager? { app.actionUndo }
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Never take focus from an editor: its native text undo has priority.
        if !Self.hasFirstResponder(view) { becomeFirstResponder() }
    }

    private static func hasFirstResponder(_ view: UIView) -> Bool {
        view.isFirstResponder || view.subviews.contains(where: hasFirstResponder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(content)
        content.view.frame = view.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.view.backgroundColor = .clear
        view.addSubview(content.view)
        content.didMove(toParent: self)
        view.backgroundColor = AppearanceColors.ui(0xFFFFFF, 0x121214)
        privacyCover.backgroundColor = .black
        privacyCover.frame = view.bounds
        privacyCover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        privacyCover.isHidden = true
        privacyCover.isAccessibilityElement = true
        privacyCover.accessibilityLabel = "Private content hidden"
        privacyCover.accessibilityIdentifier = "private.curtain"
        privacyCover.accessibilityViewIsModal = true
        view.addSubview(privacyCover)
        watchStatusBar()
    }

    @MainActor required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    /// UIKit covers synchronously before the system captures this window.
    /// SwiftUI also removes private descendants, rather than just fading them.
    /// The cover stands on the window: what UIKit presents over the page
    /// (the share sheet, the print panel, the viewer) is above this view,
    /// and a full-screen one (the viewer on iPhone) takes it out of the window.
    func setInactivePrivacyCover(_ hiddenContent: Bool) {
        if hiddenContent {
            let host: UIView = view.window ?? presentedViewController?.viewIfLoaded?.window ?? view
            host.endEditing(true)
            privacyCover.frame = host.bounds
            if privacyCover.superview !== host { host.addSubview(privacyCover) }
            host.bringSubviewToFront(privacyCover)
            view.accessibilityElementsHidden = true
            privacyCover.isHidden = false
        } else {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            privacyCover.isHidden = true
            view.accessibilityElementsHidden = false
        }
    }

    /// The browser's keys (BrowserKeys), from the main menu or ⌘'s list.
    @objc func browserKey(_ command: UIKeyCommand) {
        guard let key = BrowserKey(token: command.propertyList), acceptsKeys else { return }
        keysLog.info("key: \(key.title, privacy: .public)")
        app.use(key)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(browserKey(_:)) {
            guard let key = BrowserKey(token: (sender as? UIKeyCommand)?.propertyList) else { return false }
            let may = acceptsKeys && app.mayUse(key)
            keysLog.info("may \(key.title, privacy: .public): \(may)")
            return may
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// iPhone has no main menu to hold them: the browser's own responder does.
    override var keyCommands: [UIKeyCommand]? {
        let own = super.keyCommands ?? []
        guard traitCollection.userInterfaceIdiom == .phone else { return own }
        return own + BrowserKey.all.map(\.command)
    }

    /// Only the window in front takes keys.
    private var acceptsKeys: Bool { viewIfLoaded?.window?.isKeyWindow == true }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        if app.privateContentBlocked || app.privateLock.presentsPrompt { return .lightContent }
        if let light = app.surfaces.statusBarLight { return light ? .lightContent : .darkContent }
        // The spaces or the toolbar beside it: the status column stands on the page.
        if app.field.shown || app.workspace.tabletControls, app.workspace.statusColumnOverPage, app.browser.tab != nil {
            return app.pageIsPrivate || app.pageIsDark ? .lightContent : .darkContent
        }
        if app.workspace.tabletControls {
            return app.pageIsPrivate || AppAppearance.current == .dark ? .lightContent : .darkContent
        }
        // A conversation over the whole screen stands on the chats' own ground.
        if app.chatSheet.shown, app.chatSheet.mode == .chat {
            return AppAppearance.current == .dark ? .lightContent : .darkContent
        }
        if AppAppearance.current == .dark, app.field.shown || app.browser.tab == nil { return .lightContent }
        // The field over Private (its own page or a private tab's) stands on Private's dark ground.
        if app.field.shown, app.field.isPrivate || app.browser.tab?.isPrivate == true { return .lightContent }
        return app.pageIsDark ? .lightContent : .darkContent
    }

    /// Over the spaces a status column covers the head and the pins. Gone, only
    /// the camera stands there, and the head keeps clear of that.
    override var prefersStatusBarHidden: Bool { app.field.shown && app.workspace.statusColumnOverField }

    override var prefersHomeIndicatorAutoHidden: Bool { false }

    /// The style again whenever the page in front turns dark or light.
    private func watchStatusBar() {
        withObservationTracking {
            _ = app.privateLock.isActive
            _ = app.privateContentBlocked
            _ = app.pageIsDark
            _ = app.workspace.tabletControls
            _ = app.workspace.expanded
            _ = app.workspace.windowInsets
            _ = app.surfaces.statusBarLight
            _ = app.chatSheet.shown
            _ = app.chatSheet.mode
            _ = app.field.shown
            _ = app.field.isPrivate
            _ = app.browser.tab?.id
            _ = AppAppearance.current
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.setNeedsStatusBarAppearanceUpdate()
                self?.watchStatusBar()
            }
        }
    }
}
