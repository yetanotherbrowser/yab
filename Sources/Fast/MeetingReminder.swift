import AppKit
import Combine
import SwiftUI

/// Dismissal belongs to an occurrence, so a rescheduled meeting may remind again.
struct MeetingReminders {
    private var dismissed: Set<String> = []
    private func key(_ meeting: Meeting) -> String { "\(meeting.id)|\(meeting.start.timeIntervalSince1970)" }

    /// How long before a meeting it comes early, when something is open
    /// with its people (docs/mail.md, Promised).
    static let early: TimeInterval = 10 * 60

    mutating func next(in meetings: [Meeting], at now: Date) -> Meeting? { pick(in: meetings, at: now)?.meeting }

    /// The card's meeting: a minute before, its Join; ten minutes before,
    /// only when something is open with its people (`open`), its thread.
    /// Each dismissed on its own.
    mutating func pick(in meetings: [Meeting], at now: Date, open: (Meeting) -> Bool = { _ in false }) -> (meeting: Meeting, early: Bool)? {
        let alive = Set(meetings.filter { $0.end > now }.flatMap { [key($0), key($0) + "|early"] })
        dismissed.formIntersection(alive)
        if let join = meetings.filter({
            $0.link != nil && $0.end > now && $0.start.timeIntervalSince(now) <= 60
                && $0.start.timeIntervalSince(now) >= -120 && !dismissed.contains(key($0))
        }).min(by: { $0.start < $1.start }) {
            return (join, false)
        }
        let soon = meetings.filter {
            let wait = $0.start.timeIntervalSince(now)
            return wait > 60 && wait <= Self.early && !dismissed.contains(key($0) + "|early")
        }.sorted { $0.start < $1.start }
        return soon.first(where: open).map { ($0, true) }
    }

    mutating func dismiss(_ meeting: Meeting, early: Bool = false) { dismissed.insert(key(meeting) + (early ? "|early" : "")) }
}

/// A meeting about to start, said as Cron said it: a card in the window's
/// top corner, the title over "in 1m · 2 – 3 PM", Join on the call's own
/// mark with ⌃⌘J. ✕ on its corner, or flung up, and that occurrence stays
/// quiet. In the window you are in, with Yab in front; with another app in
/// front, or no window of Yab's, it floats over the screen you are on
/// (MeetingFloat), once either way. What is open with its people
/// (what you promised them, what they owe you) under a line, a click to its
/// thread; with something open it comes ten minutes early too, Open Thread
/// with ⌃⌘O in Join's place, still time to send what you promised.
///
/// Against the page: light over a dark one, dark otherwise. The dark HUD
/// over X or YouTube was black on black, and a card that says "in 1m"
/// has to be seen. It comes in from the window's side, a little small,
/// and goes back out that way, quicker.
struct MeetingNotice: View {
    let browser: Browser
    /// The tab in front, whose light the card stands against.
    var tab: Tab?
    var top: CGFloat
    /// In MeetingFloat's panel over the screen, not in the window's corner.
    var floating = false
    @ObservedObject private var meetings = Meetings.shared
    @ObservedObject private var place = MeetingFloat.shared
    @State private var over = false
    @Environment(\.accessibilityReduceMotion) private var still

    /// From the card's top to the next notice's, for what stands under it:
    /// more with the lines of what is open.
    static let room: CGFloat = 68
    static func room(lines: Int) -> CGFloat { room + (lines > 0 ? 13 + CGFloat(lines) * 22 : 0) }

    static func showing(_ browser: Browser) -> Bool {
        Meetings.shared.reminder != nil && MeetingFloat.shared.holder === browser && !browser.welcoming
    }

    private var meeting: Meeting? {
        (floating ? place.floating : Self.showing(browser)) ? meetings.reminder : nil
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let meeting {
                Group {
                    if let tab {
                        Under(tab: tab) { card(meeting, light: HUD.surface(over: $0) == .light) }
                    } else {
                        card(meeting, light: false)
                    }
                }
                .noticeFling(.top, token: meeting.id) { meetings.dismissReminder() }
                .transition(still ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)).combined(with: .offset(x: 28)),
                    removal: .opacity.combined(with: .offset(x: 36)).animation(Motion.depart)
                ))
            }
        }
        .animation(still ? Motion.quick : Motion.arrive, value: meeting?.id)
        .padding(.top, top)
    }

    private func card(_ meeting: Meeting, light: Bool) -> some View {
        let size = SidebarTypography.current
        let surface: HUD.Surface = light ? .light : .dark
        let ink = HUD.ink(on: surface)
        let muted = HUD.muted(on: surface)
        let early = meetings.reminderEarly
        let keys = Keymap.shared.text(early ? .openMeetingThread : .joinMeeting)
        let host = meeting.link?.host()?.lowercased() ?? ""
        let open = meetings.reminderOpen
        return VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title.isEmpty ? "Meeting" : meeting.title)
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(Self.when(meeting, at: meetings.now))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                    Text("·")
                    Text(Self.span(meeting))
                }
                .font(.system(size: size - 1).monospacedDigit())
                .foregroundStyle(muted)
                .lineLimit(1)
            }
            .frame(maxWidth: 240, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            // The button at the card's end, as wide as its lines make it.
            Spacer(minLength: 16)
            Button {
                if floating { MeetingFloat.front(browser) }
                if early {
                    browser.openMeetingThread()
                } else {
                    browser.joinMeeting(meeting)
                    meetings.dismissReminder()
                }
            } label: {
                HStack(spacing: 6) {
                    if !early {
                        Mark(icon: Favicons.shared.cached(host), letter: Self.service(host).prefix(1).uppercased(), size: 14)
                    }
                    Text(early ? "Open Thread" : "Join \(Self.service(host))")
                    if !keys.isEmpty {
                        KeyGlyphs(keys: keys, size: 12.5, tint: nil, rest: 0.6)
                            .transaction { $0.animation = nil }
                    }
                }
            }
            .buttonStyle(.yab(.secondary, .regular))
            .environment(\.colorScheme, light ? .light : .dark)
            .keyTip(early ? "Open its thread in mail" : "Join the call")
          }
          if !open.isEmpty {
            Rectangle().fill(ink.opacity(0.12)).frame(height: 0.5)
                .padding(.top, 12) // design: the card's own inset over the line
                .padding(.bottom, 4) // design: the line's rows sit close under it
            ForEach(open, id: \.thread) { line in
                Button {
                    if floating { MeetingFloat.front(browser) }
                    browser.openMeetingThread(line)
                } label: {
                    HStack(spacing: 12) {
                        Text(line.words).foregroundStyle(ink).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 12)
                        Text(line.when).foregroundStyle(muted).lineLimit(1)
                    }
                    .font(.system(size: size - 1))
                    .frame(height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyTip("Open its thread in mail")
            }
            .frame(maxWidth: 400)
          }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(CardFrame.inset)
        .background { HUD.plate(Radius.surface, surface: surface) }
        .overlay(alignment: .topLeading) {
            Button { meetings.dismissReminder() } label: {
                Symbol("xmark", size: 8, weight: .semibold)
                    .foregroundStyle(ink)
                    .frame(width: 20, height: 20)
                    .background { HUD.plate(in: Circle(), surface: surface) }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .keyTip("Dismiss")
            .offset(x: -6, y: -6)
            .opacity(over ? 1 : 0)
            .animation(Motion.quick, value: over)
        }
        .onHover { over = $0 }
        .onAppear { if !host.isEmpty, Favicons.shared.cached(host) == nil { Favicons.shared.fetch(host: host) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(meeting.title), \(Self.when(meeting, at: meetings.now))")
    }

    /// "in 3m", or "now" once it has begun.
    static func when(_ meeting: Meeting, at now: Date) -> String {
        let wait = meeting.start.timeIntervalSince(now)
        return wait > 0 ? "in \(max(1, Int((wait / 60).rounded(.up))))m" : "now"
    }

    /// "2 – 3 PM", as the calendar writes it.
    static func span(_ meeting: Meeting) -> String {
        let format = DateIntervalFormatter()
        format.locale = AppDates.locale
        format.dateStyle = .none
        format.timeStyle = .short
        return format.string(from: meeting.start, to: meeting.end)
    }

    /// What the call is on, by name: Join Meet, Join Zoom.
    static func service(_ host: String) -> String {
        if host == "meet.google.com" { return "Meet" }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") { return "Zoom" }
        if host.hasPrefix("teams.") { return "Teams" }
        if host == "app.slack.com" { return "Huddle" }
        if host.hasSuffix(".webex.com") { return "Webex" }
        return "Call"
    }
}

/// The corner's notices, under a meeting's card while one is up: what the
/// window watches for them, apart from the window, so the minute turning
/// redraws only the corner.
struct CornerNotices: View {
    let browser: Browser
    var tab: Tab?
    var top: CGFloat
    @ObservedObject private var meetings = Meetings.shared
    @ObservedObject private var place = MeetingFloat.shared
    @ObservedObject private var room: AskRoom
    /// The corner's own place, in the window's SwiftUI space.
    @State private var frame: CGRect = .zero
    @Environment(\.accessibilityReduceMotion) private var still

    init(browser: Browser, tab: Tab? = nil, top: CGFloat) {
        self.browser = browser
        self.tab = tab
        self.top = top
        _room = ObservedObject(wrappedValue: browser.askRoom)
    }

    /// The width a notice takes at most, from the corner in.
    private static let reach: CGFloat = 360

    /// A page's card hanging from its tab over the corner: the notice
    /// comes out under it, both read whole, rather than slid behind it.
    private var under: CGFloat {
        guard let card = room.card, frame.width > 0, card.maxX > frame.maxX - Self.reach, card.minX < frame.maxX,
              card.minY < frame.minY + top + Notice.side + 8 else { return 0 }
        return max(0, card.maxY + 8 - (frame.minY + top))
    }

    var body: some View {
        let meeting = MeetingNotice.showing(browser) ? MeetingNotice.room(lines: meetings.reminderOpen.count) : 0
        ZStack(alignment: .topTrailing) {
            Notice(
                browser: browser,
                toaster: browser.toaster,
                tidier: browser.tidier,
                agents: Agents.shared,
                top: top + under + meeting
            )
            MeetingNotice(browser: browser, tab: tab, top: top)
            AssistantBotNotice(browser: browser, tab: tab, top: top + 70)
        }
        // A card come or gone while a notice is up: it moves, not jumps.
        .animation(still ? nil : Motion.quick, value: under)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}

/// Where the meeting's card is: the corner of the window you are in while
/// Yab is in front, else a panel of its own in the top corner of the
/// screen the pointer is on, over every app and space, as Dia's floats
/// (1.7) on the screen you are at (1.17). It follows the pointer to
/// another screen while up. Never both, so one card a meeting.
@MainActor
final class MeetingFloat: ObservableObject {
    static let shared = MeetingFloat()

    /// The window whose corner has the card; nil while it floats or is down.
    @Published private(set) var holder: Browser?
    /// The card is in the panel.
    @Published private(set) var floating = false
    private var panel: NSPanel?
    private var host: MeetingFloatHost?
    private weak var hosted: Browser?
    private var screen: NSScreen?
    /// The pointer's screen, looked at twice a second while the card floats.
    private var follow: Timer?
    private var watches: [NSObjectProtocol] = []
    private var up: AnyCancellable?
    /// Each show and hide, so a hide's end finds out whether it is still the last word.
    private var turn = 0
    /// Room for the plate's shadow and the ✕ over its corner.
    private static let inset: CGFloat = 24
    /// From the screen's top and side to the card, as a notification sits.
    private static let margin: CGFloat = 4

    private init() {
        up = Meetings.shared.$reminder.map { $0 != nil }.removeDuplicates().sink { _ in
            DispatchQueue.main.async { MeetingFloat.shared.place() }
        }
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification, NSApplication.didChangeScreenParametersNotification] {
            watches.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // After the change has settled: a closing window is still key.
                DispatchQueue.main.async { MainActor.assumeIsolated { MeetingFloat.shared.place() } }
            })
        }
    }

    /// The window Yab's keys go to, while Yab is in front.
    private var inFront: Browser? {
        guard NSApp.isActive, let browser = BrowserWindows.shared.activeBrowser,
              let window = BrowserWindows.shared.window(for: browser),
              window.isVisible, !window.isMiniaturized else { return nil }
        return browser
    }

    /// Any window of Yab's, for the card's Join: the one last in front.
    private var someone: Browser? { BrowserWindows.shared.activeBrowser }

    func place() {
        let up = Meetings.shared.reminder != nil
        let here = up ? inFront : nil
        if holder !== here { holder = here }
        let float = up && here == nil && someone != nil
        if floating != float { floating = float }
        if float { show() } else { hide() }
    }

    private static func pointerScreen() -> NSScreen? {
        let at = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(at, $0.frame, false) } ?? NSScreen.main
    }

    /// Yab in front, in the window the card spoke for, before it acts.
    static func front(_ browser: Browser) {
        NSApp.activate()
        BrowserWindows.shared.window(for: browser)?.makeKeyAndOrderFront(nil)
    }

    private func show() {
        guard let browser = someone, let screen = Self.pointerScreen() else { return }
        let panel = self.panel ?? make()
        if hosted !== browser || host == nil {
            let host = MeetingFloatHost(rootView: AnyView(
                MeetingNotice(browser: browser, top: 0, floating: true).padding(Self.inset)
            ))
            host.sizingOptions = [.intrinsicContentSize]
            host.resized = { MeetingFloat.shared.fit(animated: false) }
            panel.contentView = WindowHosting.measured(host)
            self.host = host
            hosted = browser
        }
        let moved = screen != self.screen
        self.screen = screen
        if follow == nil {
            follow = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let shared = MeetingFloat.shared
                    if shared.floating, Self.pointerScreen() != shared.screen { shared.show() }
                }
            }
        }
        turn += 1
        guard !panel.isVisible || moved else { return fit(animated: false) }
        // The card's first frame is drawn on the next pass, after `floating`
        // has reached it: measured before then, the panel is only its inset.
        let mine = turn
        DispatchQueue.main.async { MeetingFloat.shared.enter(panel, mine) }
    }

    private func enter(_ panel: NSPanel, _ mine: Int) {
        guard mine == turn, floating, let screen else { return }
        host?.layoutSubtreeIfNeeded()
        let rest = frame(in: screen)
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // In from the screen's side, as the card comes into a window's corner.
        panel.setFrame(still ? rest : rest.offsetBy(dx: 28, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = still ? 0.12 : 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(rest, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        follow?.invalidate()
        follow = nil
        screen = nil
        guard let panel, panel.isVisible else { return }
        turn += 1
        let mine = turn
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = still ? 0.1 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if !still { panel.animator().setFrame(panel.frame.offsetBy(dx: 36, dy: 0), display: true) }
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { MeetingFloat.shared.gone(mine) }
        })
        // Put away even when the fade never ends.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MeetingFloat.shared.gone(mine) }
    }

    private func gone(_ mine: Int) {
        guard mine == turn, let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// The card's size, its top corner kept where it is.
    private func fit(animated: Bool) {
        guard let panel, let screen, panel.isVisible else { return }
        panel.setFrame(frame(in: screen), display: true, animate: animated)
    }

    private func frame(in screen: NSScreen) -> NSRect {
        let size = host?.fittingSize ?? .zero
        let room = screen.visibleFrame
        return NSRect(x: room.maxX - Self.margin - size.width + Self.inset,
                      y: room.maxY - Self.margin - size.height + Self.inset,
                      width: size.width, height: size.height)
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        // Over macOS's own banners, which sit in the same corner: a meeting
        // starting in a minute matters more than they do.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.panel = panel
        return panel
    }

    /// For the bench: where the card is, and the panel's window and screen.
    var state: [String: Any] {
        [
            "place": floating ? "panel" : holder != nil ? "window" : "none",
            "panel_window": panel.map { $0.isVisible ? $0.windowNumber : 0 } ?? 0,
            "panel_frame": panel.map { NSStringFromRect($0.frame) } ?? "",
            "panel_screen": panel?.screen?.localizedName ?? "",
            "screens": NSScreen.screens.map { ["name": $0.localizedName, "frame": NSStringFromRect($0.frame)] },
            "pointer_screen": Self.pointerScreen()?.localizedName ?? "",
        ]
    }
}

/// Clicks go through on the first press, with another app in front.
private final class MeetingFloatHost: NSHostingView<AnyView> {
    var resized: (() -> Void)?
    private var asked = false

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard !asked else { return }
        asked = true
        DispatchQueue.main.async { [weak self] in
            self?.asked = false
            self?.resized?()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
