import AppKit

// Yab with no window and no Dock tile, for someone who uses it only from a
// terminal: `yab "…"` or an agent's `yab mcp` wakes it when it isn't open
// (Mcp.wake, with --headless), agents work in the room off screen
// (Bench.house), and nothing comes forward. Yesterday's tabs are read but
// not loaded, the calendar isn't asked, the welcome waits.
//
// It becomes the browser as anyone would see it only when a person asks
// for it: the Dock or Spotlight opening yab, a link, a click on "needs
// you". A request an agent put up (sign in, a captcha, Pay?) shows its tab
// then, with no welcome over it: the welcome is for the first plain open.
// And left alone, with no task running and no call for half an hour, it
// quits, so a woken yab doesn't stay in memory for good; the sign-ins that
// live only as long as the browser does go into the keychain on the way
// out and come back at the next launch (KeptCookies).
//
// Hidden never means a hidden app: WebKit takes a hidden app's pages for
// hidden pages, the room's too, whatever the room does. Its window is what
// is put away.
//
// Two more ways to be here with no window. `yab serve` starts it the same
// way for good: no quitting when idle, for a Mac used by agents, a
// LaunchAgent's (docs/headless.md); with --no-person, nobody is there to
// sign in or say yes, so what needs someone fails at once. And ⌘Q while
// agents work can close the windows and let them finish (linger): the
// menu bar mark stays, and it quits when the last task ends.
//
// PLAN-headless.md has why.
@MainActor
enum Headless {
    /// Started for agents, hidden. Read once: the flag the launch was given.
    nonisolated static let on: Bool = CommandLine.arguments.contains("--headless")
        || ProcessInfo.processInfo.environment["YAB_HEADLESS"] == "1"

    /// Opened by macOS as the person logged in, with Open at Login on
    /// (OpenAtLogin): hidden as a woken Yab is, but sync runs, and it
    /// stays. Unlike `on`, nothing else about the launch changes.
    static var atLogin = false

    /// Shown since: a person asked for the browser.
    private(set) static var shown = false

    /// Quit with agents at work, the windows put away until they finish.
    private(set) static var lingering = false

    /// Kept for good, however long nothing comes (`yab serve`).
    static var serving = CommandLine.arguments.contains("--serve")

    /// Nobody at this Mac (`yab serve --no-person`): whatever needs a
    /// person fails at once rather than waiting on a notice nobody sees.
    static var nobody = CommandLine.arguments.contains("--no-person")

    /// Hidden now: started hidden and not shown yet, or lingering.
    static var hidden: Bool { ((on || atLogin) && !shown) || lingering }

    /// Woken for agents, or opened at login, and not shown yet: nobody has
    /// opened this Yab. (Lingering, someone has, and quit it.)
    static var woken: Bool { (on || atLogin) && !shown }

    /// Why the browser is being shown, which decides what comes first.
    enum Why {
        /// yab opened as yab is opened: the welcome first, if it's due.
        case person
        /// A tab that needs someone: that tab, the welcome after.
        case request
    }

    /// Before any window: an app with no Dock tile and no menu bar, that
    /// still has windows, the room's, and answers a click on its notices.
    static func launch() {
        guard on || atLogin else { return }
        NSApp.setActivationPolicy(.accessory)
        watch()
    }

    /// The clock that quits it and keeps the mark, and a watch for being
    /// hidden from outside (⌘H with its menu open, a script): shown again,
    /// since a hidden app's pages stop.
    private static func watch() {
        lastCall = Date()
        if hiding == nil {
            hiding = NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard Headless.hidden, !Headless.tucking else { return }
                    NSApp.unhideWithoutActivation()
                }
            }
        }
        idle?.invalidate()
        idle = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { Headless.check() }
        }
    }

    private static var hiding: NSObjectProtocol?

    /// ⌘Q with agents at work, and "Quit When Done": every window put away,
    /// no Dock tile, the mark in the menu bar, your own pages asleep, and
    /// the quit itself once the last task ends, or once all that's left
    /// waits on you. A quit someone chose: the sign-ins go as they always
    /// went. Opening yab again before then is the browser as it was.
    static func linger() {
        guard !lingering else { return }
        lingering = true
        put = NSApp.windows.filter { $0.isVisible && $0.identifier != Bench.roomID && $0.level == .normal }
        put.forEach { $0.orderOut(nil) }
        // A page of yours an agent works in stays in its window, now on no
        // screen: seen, as the room's are, while it finishes.
        for tab in Links.browser?.everyTab ?? [] where tab.guest != nil || tab.agent != nil {
            if let web = tab.webKitOnly("WebKit offscreen visibility", build: false), let window = web.window, put.contains(window) { Bench.shared.see(web) }
        }
        // Every other page goes to sleep now, as quitting would have ended
        // it. Awake, five sites held 3 GB long after ⌘Q, playing and all,
        // while a task finished. Asleep, each keeps its place and Back, and
        // the one in front wakes if yab is opened again before it quits.
        BrowserWindows.shared.flushAll()
        for browser in BrowserWindows.shared.browsers {
            for tab in browser.everyTab where tab.guest == nil && tab.agent == nil && tab.builtPage != nil {
                browser.putDown(quitting: tab)
            }
        }
        NSApp.setActivationPolicy(.accessory)
        mark(true)
        watch()
    }

    /// The windows lingering put away, to bring back as they were.
    private static var put: [NSWindow] = []

    /// Right after launch. WebKit takes a hidden app's pages for hidden
    /// pages, the room's too, whatever the room does for them (seen: one
    /// animation frame in two seconds): so it is the window that is put
    /// away, not the app. Opened hidden (`open -j`, as Mcp.wake does),
    /// SwiftUI makes no window, and the app only needs showing. A plain
    /// start with the flag gets the window it always makes, a moment
    /// later: the app hidden until then, so it never shows, then that
    /// window put away and the app shown without coming forward.
    static func settle(plain: Bool) {
        // A reopen can arrive before didFinishLaunching. Do not hide an
        // app the person has already asked to see while it was starting.
        guard hidden else { return }
        guard plain else {
            NSApp.unhideWithoutActivation()
            // Nothing is expected, but a window a restored session brings
            // back a moment later is put away as well.
            for delay in [0.3, 1.0, 2.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { if hidden, !lingering { sweep() } }
            }
            return
        }
        tucking = true
        NSApp.hide(nil)
        tuck(tries: 0)
    }

    /// Hidden on purpose, for a moment: the window a plain start makes is
    /// on its way.
    private static var tucking = false

    private static func tuck(tries: Int) {
        // Asked for meanwhile (a link, a reopen): the window stays.
        guard hidden else { tucking = false; return }
        guard let window = Links.window else {
            // A login-time start can take a while to make its window.
            if tries < 600 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tuck(tries: tries + 1) }
            } else {
                tucking = false
                NSApp.unhideWithoutActivation()
            }
            return
        }
        window.orderOut(nil)
        // Every other window the last run left, brought back with it, too,
        // and for a moment more, since those come a little after the first.
        sweep()
        tucking = false
        NSApp.unhideWithoutActivation()
        for delay in [0.1, 0.3, 0.6, 1.0, 1.5, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { if hidden, !lingering { sweep() } }
        }
    }

    /// Every window on screen but the room's put away.
    private static func sweep() {
        for window in NSApp.windows where window.isVisible && window.identifier != Bench.roomID && window.level == .normal {
            window.orderOut(nil)
        }
    }

    /// The browser, as anyone would see it: a Dock tile, the window, the
    /// tab you were on loaded. Once; it stays that way until yab quits.
    static func show(_ why: Why) {
        guard hidden else { return }
        shown = true
        idle?.invalidate()
        idle = nil
        mark(false)
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        // Someone is here now.
        nobody = false
        SyncCenter.shared.launchIfNeeded()
        if lingering {
            // Back from a quit that waited: the windows as they were, their
            // pages judged by them again.
            lingering = false
            put.forEach { $0.orderFront(nil) }
            for tab in Links.browser?.everyTab ?? [] {
                if let web = tab.webKitOnly("WebKit offscreen visibility", build: false), let window = web.window, put.contains(window), web.seenOffscreen { Bench.shared.unsee(web) }
            }
            put = []
            // Put to sleep by the quit: the pages in front load again.
            for browser in BrowserWindows.shared.browsers {
                browser.active?.wake()
                if let active = browser.active { for id in browser.mates(of: active.id) { _ = browser.tab(id: id)?.wake() } }
            }
            return
        }
        guard let browser = Links.browser else { return }
        // A task waiting on someone is why most hidden yabs get opened:
        // its tab first, whoever opened yab, and the welcome after.
        let waiting = browser.everyTab.first { $0.handoff != nil && ($0.agent != nil || $0.guest != nil || $0.permit != nil) }
        browser.welcoming = why == .person && waiting == nil && !browser.prefs.welcomed
        if let waiting { browser.select(waiting) }
        browser.active?.wake()
        Meetings.shared.start()
    }

    // MARK: - leaving when nobody needs it

    private static var idle: Timer?
    private static var lastCall = Date()

    /// How long a hidden yab waits with nothing to do; a test world can
    /// make it short.
    private static let patience: TimeInterval = {
        if Store.testing, let given = ProcessInfo.processInfo.environment["YAB_HEADLESS_IDLE"].flatMap(Double.init) { return given }
        return 1800
    }()

    /// A call on the socket: someone is still using it.
    static func called() {
        guard hidden else { return }
        lastCall = Date()
        mark(working || lingering)
    }

    /// Tasks at work or waiting for their person (Session.atWork); a
    /// question left on a tab by a task that ended isn't one, nor an agent
    /// attached through `yab mcp` between its calls.
    private static var working: Bool {
        Agents.shared.sessions.contains(where: \.atWork)
    }

    private static func check() {
        guard hidden else { return }
        mark(working || lingering)
        // The quit someone asked for, now that nothing goes on without
        // them: the tasks done, or what's left waiting on the person who
        // quit, which would hold yab, unseen, for good.
        if lingering, !Agents.shared.sessions.contains(where: \.goingOn) {
            idle?.invalidate()
            idle = nil
            Links.leaving = true
            NSApp.terminate(nil)
            return
        }
        if working { lastCall = Date(); return }
        guard !serving, Date().timeIntervalSince(lastCall) > patience else { return }
        leave()
    }

    private static var leaving = false

    /// Quitting on its own, or asked to from the command line (`yab
    /// quit`): the socket first, so a caller arriving now finds yab gone
    /// and wakes a new one instead of talking to one on its way out; then
    /// the sign-ins that would go with the process, kept for the next.
    static func leave() {
        guard hidden, !leaving else { return }
        leaving = true
        idle?.invalidate()
        idle = nil
        Bench.shared.stop()
        // Lingering after ⌘Q, it quits as ⌘Q does, which keeps them too.
        if lingering {
            Links.leaving = true
            NSApp.terminate(nil)
            return
        }
        KeptCookies.save {
            // Opened while its cookies were being kept: it stays, listening.
            guard hidden else {
                leaving = false
                if let browser = Links.browser, browser.prefs.bench { Bench.shared.start(for: browser) }
                return
            }
            NSApp.terminate(nil)
        }
    }

    /// What `yab status` says.
    static var status: [String: Any] {
        let live = Agents.shared.sessions.filter(\.atWork)
        return [
            "pid": Int(getpid()), "app": Bundle.main.bundlePath, "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            "hidden": hidden, "headless": on, "atLogin": atLogin, "serving": serving, "nobody": nobody, "lingering": lingering,
            "working": live.count, "waiting": live.filter { $0.state == .waiting }.count,
            "idle": hidden ? Int(Date().timeIntervalSince(lastCall)) : 0, "quits_after": hidden && !serving && !lingering ? Int(patience) : 0,
            // The quiet switch WebKit may drop in some update: without it an
            // agent's pages off screen run as hidden pages again.
            "room": PageView.canSee ? "seen" : "hidden: WebKit has no window check to turn off",
        ]
    }

    // MARK: - the mark in the menu bar

    /// A browser at work in the person's accounts is never invisible: while
    /// a task runs, yab's agent mark is in the menu bar, and its menu says
    /// in words what each is doing and opens yab on it.
    private static var item: NSStatusItem?
    private static let menu = HeadlessMenu()

    private static func mark(_ up: Bool) {
        if up, item == nil {
            let made = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            made.button?.image = Glyphs.image("agent.face", size: 14)
            made.button?.toolTip = "Yab is working" // design: the menu bar's, drawn by the system, as the menu bar is
            let list = NSMenu()
            list.delegate = menu
            made.menu = list
            item = made
        } else if !up, let made = item {
            NSStatusBar.system.removeStatusItem(made)
            item = nil
        }
    }
}

/// The mark's menu, made anew each time it opens.
@MainActor
final class HeadlessMenu: NSObject, NSMenuDelegate {
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { fill(menu) }
    }

    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        let agents = Agents.shared
        for session in agents.sessions where session.atWork {
            let asking = agents.tabs(of: session).first { $0.handoff != nil }?.handoff
            let doing = asking.map { "Needs you: \($0)" } ?? (session.now.isEmpty ? "Working" : AgentDock.say(session.now, name: session.name))
            let row = NSMenuItem(title: "\(session.name): \(doing)", action: #selector(open(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = session.id
            menu.addItem(row)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let show = NSMenuItem(title: "Show Yab", action: #selector(open(_:)), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let stop = NSMenuItem(title: "Stop All Tasks", action: #selector(stopAll), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Yab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
    }

    /// Yab as anyone would see it, on the task's tab when one was picked;
    /// for Yab's own work out of sight (Get to Know), on its chat, its tabs
    /// being nobody's to go into.
    @objc private func open(_ sender: NSMenuItem) {
        let agents = Agents.shared
        let session = (sender.representedObject as? String).flatMap { agents.session($0) }
        if let session, agents.sealed(session.id) {
            Headless.show(.person)
            Links.showBrowser()
            NSApp.activate()
            if agents.hasChat(session.id) { Links.browser?.showChat(session.id) }
            return
        }
        let tab = session.flatMap { found in agents.tabs(of: found).first { $0.handoff != nil } ?? agents.tabs(of: found).last }
        Headless.show(tab == nil ? .person : .request)
        Links.showBrowser()
        NSApp.activate()
        if let tab, let browser = Links.browser { browser.select(tab) }
    }

    @objc private func stopAll() {
        for session in Agents.shared.sessions where session.atWork { _ = Agents.shared.stop(session.id) }
    }
}
