import AppKit

/// How often the clipboard is looked at. Every second while someone is at
/// the Mac; every five once nobody has touched it for a minute, a copy then
/// coming from a script or another device; while the screen is locked, only
/// at the lock itself, every half minute. Back to every second, with a look at once, the moment anyone
/// comes back: Yab or another app brought forward, a key or a click in Yab,
/// the screen unlocked, the Mac awake. A copy made meanwhile is still caught, the pasteboard's count
/// having moved.
@MainActor
final class ClipPace {
    static let quick: TimeInterval = 1
    static let away: TimeInterval = 5
    static let recheck: TimeInterval = 30
    /// Without a key, a click or the mouse moving for this long, nobody is there.
    static let quietAfter: TimeInterval = 60

    static func every(quiet: TimeInterval, locked: Bool) -> TimeInterval? {
        if locked { return nil }
        return quiet >= quietAfter ? away : quick
    }

    private let steady: TimeInterval?
    private let quiet: () -> TimeInterval
    private let lockedNow: () -> Bool
    private let look: () -> Void
    private(set) var timer: Timer?
    private(set) var locked = false
    private var watches: [(NotificationCenter, NSObjectProtocol)] = []
    private var press: Any?

    /// `steady`: a test world's own pace (YAB_CLIPS_EVERY, or every second),
    /// kept whatever the Mac: an eval Mac nobody touches, its screen locked.
    init(steady: TimeInterval? = nil, quiet: @escaping () -> TimeInterval = ClipPace.sinceInput,
         locked: @escaping () -> Bool = ClipPace.screenLocked, look: @escaping () -> Void) {
        self.steady = steady.map { max(0.005, $0) }; self.quiet = quiet; self.lockedNow = locked; self.look = look
    }

    static func screenLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    static func sinceInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func start() {
        guard timer == nil, watches.isEmpty, press == nil else { return }
        locked = lockedNow()
        let workspace = NSWorkspace.shared.notificationCenter, local = NotificationCenter.default
        let distributed = DistributedNotificationCenter.default()
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ act: @escaping @MainActor (ClipPace) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { act(self) } }
            }
            watches.append((center, token))
        }
        on(local, NSApplication.didBecomeActiveNotification) { $0.wake() }
        on(workspace, NSWorkspace.didActivateApplicationNotification) { $0.wake() }
        on(workspace, NSWorkspace.didWakeNotification) { $0.wake() }
        on(distributed, .init("com.apple.screenIsLocked")) { $0.lock() }
        on(distributed, .init("com.apple.screenIsUnlocked")) { $0.unlock() }
        press = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.pressed() }
            return event
        }
        pace()
    }

    /// Clips holds its pace for the run; this is for tests.
    func stop() {
        timer?.invalidate(); timer = nil
        for (center, token) in watches { center.removeObserver(token) }
        watches = []
        if let press { NSEvent.removeMonitor(press) }
        press = nil
    }

    /// Someone is back: a look now, and the quick pace again.
    func wake() {
        // A notice of the unlock may come late to an app behind others.
        guard steady != nil || !lockedNow() else { lock(); return }
        locked = false
        look()
        pace(quiet: 0)
    }

    /// A lock notice can come late to an app behind others, after the
    /// unlock: taken only while the session says it is locked.
    func lock() {
        guard steady == nil, lockedNow() else { return }
        locked = true
        pace()
    }

    /// The unlock notice can come before the session says so: it is taken as it is.
    func unlock() {
        locked = false
        look()
        pace(quiet: 0)
    }

    /// A key or a click in Yab while the look is slow: someone is there,
    /// maybe copying. A look now and the quick pace again, so a copy, a
    /// private window's too, is taken with the window and app it was made in,
    /// not one switched to while the slow look waited.
    func pressed() {
        guard steady == nil, timer?.timeInterval != Self.quick else { return }
        wake()
    }

    /// One tick: a look, then the pace for whoever is there now.
    func tick() {
        guard !locked || steady != nil else {
            // Locked, the tick looks at the lock alone: its end may never be heard.
            if !lockedNow() { unlock() }
            return
        }
        look()
        pace()
    }

    private func pace(quiet seen: TimeInterval? = nil) {
        if let steady {
            if timer?.timeInterval != steady { timer?.invalidate(); timer = Clips.makeTimer(every: steady) { [weak self] in self?.tick() } }
            return
        }
        let idle = seen ?? quiet()
        // Nobody about: a lock nobody told this app of stops the looks too.
        if idle >= Self.quietAfter, !locked, lockedNow() { lock(); return }
        let wanted = Self.every(quiet: idle, locked: locked) ?? Self.recheck
        guard timer?.timeInterval != wanted else { return }
        timer?.invalidate()
        timer = Clips.makeTimer(every: wanted) { [weak self] in self?.tick() }
    }
}
