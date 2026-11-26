import SwiftUI
import UIKit
import CoreText

/// The first launch, as the agreed prototype draws it
/// (work/design/yab-iphone-onboarding-2026-11-04): full
/// pages on a ground of one system color, ‹, the dots and Skip at the top, a
/// big title with its period, one line of words, at most one real setting and
/// one black button. One glass object goes through every page and becomes
/// the next page's thing: the name's glass letters squeeze into the Mac's
/// spaces, the spaces become the field, the field the private field, a tab,
/// and at the end the real search field.
///
/// Joining needs one yes: Join, or the Mac letting the code in, and the page
/// goes on by itself. Nothing asks for a permission.
@MainActor
@Observable
final class FirstRun {
    static let shared = FirstRun()

    enum Step: Hashable {
        /// "Yab." in glass with sites drifting through it; Get Started.
        case welcome
        /// The same Apple ID as a Mac in sync: its spaces in a deck; Join.
        case found
        /// No key here: Yab for Mac and its address; on without it.
        case noMac
        /// The code in plates, to type on a Mac that syncs.
        case code
        case recovery
        /// Search, ask, hand off: the field and its three ways.
        case field
        /// Close the eyes: the eyes in the field.
        case incognito
        /// Links open in Yab: the default browser.
        case links
        /// The glass becomes the real field and the welcome goes.
        case end
    }

    private(set) var step: Step = .welcome
    /// The flow is on this launch: it stays until its last step, whatever
    /// joining does to the Mac underneath.
    private(set) var started = false
    /// Which sync page this launch shows: the found Mac or no Mac; after a
    /// code or the Recovery Key let it in, that page.
    private(set) var syncPage: Step = .noMac
    /// Join pressed: the deck lies down in a row and counts what came.
    private(set) var joining = false
    /// In: the counts rolled, the plates went into the check.
    private(set) var joined = false
    /// The spaces' counts, 0 to 1.
    private(set) var counted: Double = 0
    /// Without a Mac: nothing asks to join later, on this launch or the next.
    private(set) var withoutMac = false
    /// Wrong Recovery Keys typed, for the field's shake.
    private(set) var wrongs = 0
    /// The private page's eyes are shut: the page is night.
    private(set) var incognito = false
    /// The links page is asked only while Yab isn't the default browser.
    private(set) var asksLinks = true
    /// A finger on the name: the letters' jelly, counted.
    private(set) var pokes = 0
    /// The field page: what the field is typing, what landed in each way.
    private(set) var typed = ""
    private(set) var landed = ["", "", ""]
    private(set) var lit: Int?
    /// The links page: the tab in front and a link on its way in.
    private(set) var linkShown = 0
    private(set) var linkComing: Int?
    private(set) var linkLanding = false
    /// A named state holds the flow where it put it.
    @ObservationIgnored var holds = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var phrase = 0

    /// The pages the dots count: the welcome, sync, the field, private and,
    /// while Yab isn't the default browser, links.
    var pages: Int { asksLinks ? 5 : 4 }

    /// The dot of the page on screen.
    var page: Int {
        switch step {
        case .welcome: 0
        case .found, .noMac, .code, .recovery: 1
        case .field: 2
        case .incognito: 3
        case .links, .end: min(4, pages - 1)
        }
    }

    var isSync: Bool { [.found, .noMac, .code, .recovery].contains(step) }

    // MARK: - the way through

    /// The welcome is on screen.
    func begin(_ app: AppModel) {
        guard !started else { return }
        started = true
        asksLinks = Self.asksAboutLinks && !SettingsUI.shared.assumeDefaultBrowser && DefaultBrowser.refresh() != true
    }

    /// Get Started: the letters squeeze into the sync page's glass.
    func getStarted(_ app: AppModel) {
        Haptics.play(.selection, reason: Self.next)
        syncPage = app.sync.phase == .on ? .found : .noMac
        go(syncPage)
    }

    func go(_ next: Step) {
        loop?.cancel()
        withAnimation(Self.motion(Self.morph)) { step = next }
        switch next {
        case .field: startTyping()
        case .links: startLinks()
        default: break
        }
    }

    /// The black button of the page on screen.
    func forward(_ app: AppModel) {
        switch step {
        case .welcome: getStarted(app)
        case .found: join(app)
        case .noMac:
            Haptics.play(.selection, reason: Self.next)
            useWithoutMac(app)
            go(.field)
        case .code, .recovery: break
        case .field:
            Haptics.play(.selection, reason: Self.next)
            go(.incognito)
        case .incognito:
            Haptics.play(.selection, reason: Self.next)
            if asksLinks { go(.links) } else { finish(app) }
        case .links: makeDefault(app)
        case .end: break
        }
    }

    func back(_ app: AppModel) {
        Haptics.play(.selection, reason: Self.next)
        switch step {
        case .welcome, .end: return
        case .found, .noMac: go(.welcome)
        case .code:
            // The code is let go: nothing polls the server from the page before.
            app.sync.stopAsking()
            syncPage = app.sync.phase == .on ? .found : .noMac
            go(syncPage)
        case .recovery:
            app.sync.showRecovery(false)
            go(.code)
        case .field: go(syncPage)
        case .incognito: go(.field)
        case .links: go(.incognito)
        }
    }

    /// Skip: straight to the field, joined or not.
    func skip(_ app: AppModel) {
        Haptics.play(.selection, reason: Self.next)
        if !joined, app.sync.phase != .on { useWithoutMac(app) }
        finish(app, openField: step != .links && step != .incognito)
    }

    /// The code is on screen, so a new one replaces it when it expires.
    var showsCode: Bool { started && (step == .code || step == .recovery) }

    /// "Yab is on my Mac" from the no-Mac page, "Not your Mac?" from the found one.
    func chooseMac(_ app: AppModel) {
        Haptics.play(.light, reason: Haptics.Reason.confirm)
        if withoutMac {
            withoutMac = false
            SettingsStore.shared.withoutMac = false
            // Unanswered again: a quit before joining brings the welcome back.
            SettingsStore.shared.welcomed = false
            app.sync.asksOnFront = true
        }
        if step == .found {
            // The same Apple ID, but another person's Mac: forget the found
            // key and show a code instead.
            if app.sync.setup != nil {
                app.sync.joinAgain()
            } else {
                app.sync.pretend(.joining(.code(Self.standInCode)), sheet: false)
            }
        } else {
            app.sync.beginJoin()
            if case .joining(.code) = app.sync.phase {} else if app.sync.setup == nil {
                app.sync.pretend(.joining(.code(Self.standInCode)), sheet: false)
            }
        }
        go(.code)
    }

    func useRecoveryKey(_ app: AppModel) {
        Haptics.play(.light, reason: Haptics.Reason.confirm)
        app.sync.showRecovery(true)
        go(.recovery)
    }

    /// Join by the Recovery Key: in, or the field shakes and says why.
    func tryRecovery(_ app: AppModel) {
        guard !joined else { return }
        if !app.sync.useRecovery(app.sync.typed) {
            withAnimation(Self.motion(.linear(duration: 0.3))) { wrongs += 1 }
        }
    }

    /// The found Mac: the deck lies down in a row, each space counts its
    /// tabs, and the page goes on by itself.
    func join(_ app: AppModel) {
        guard !joining, !joined else { return }
        Haptics.play(.light, reason: Haptics.Reason.confirm)
        withAnimation(Self.motion(Self.morph)) { joining = true }
        Task { @MainActor in
            await pause(0.36)
            for i in 1...12 {
                await pause(0.11)
                withAnimation(Self.motion(.linear(duration: 0.11))) { counted = Self.eout(Double(i) / 12) }
            }
            counted = 1
            succeed(app)
        }
    }

    /// Joined, by Join, a Mac letting the code in, or the Recovery Key: the
    /// check, then on to the field without another tap.
    func succeed(_ app: AppModel) {
        guard !joined else { return }
        // The code and the Recovery Key are answered by sync's own success.
        if step == .found { Haptics.play(.success, reason: Haptics.Reason.done) }
        if step == .code || step == .recovery { syncPage = step }
        withAnimation(Self.motion(.easeOut(duration: 0.4))) { joined = true }
        Task { @MainActor in
            await pause(1.3)
            guard !holds, isSync else { return }
            go(.field)
        }
    }

    private func useWithoutMac(_ app: AppModel) {
        guard !withoutMac else { return }
        withoutMac = true
        // Settings › Sync keeps Join Your Mac; nothing else asks, on this
        // launch or the next, and no code waits on the server.
        SettingsStore.shared.withoutMac = true
        // The welcome's question is answered: the pages after it run on
        // this launch (`started` holds them), and a launch after a quit on
        // one of them opens the browser, not the welcome again (1813).
        SettingsStore.shared.welcomed = true
        app.sync.asksOnFront = false
        app.sync.stopAsking()
    }

    /// On since Apple granted Default Web Browser (2026-10-12).
    static let asksAboutLinks = true

    /// Make Yab Default: the iOS setting itself, where the browser is chosen.
    func makeDefault(_ app: AppModel) {
        Haptics.play(.light, reason: Haptics.Reason.confirm)
        if let url = URL(string: UIApplication.openDefaultApplicationsSettingsURLString) {
            UIApplication.shared.open(url)
        }
        finish(app)
    }

    /// Completing the welcome reveals the browser underneath. Opening search
    /// belongs to an explicit early Skip, not to the welcome disappearing.
    func finish(_ app: AppModel, openField: Bool = false) {
        guard started else { return }
        if openField {
            go(.end)
            Task { @MainActor in
                await pause(0.42)
                done()
                Motion.fieldOpen.run { app.surfaces.openField(.newTab) }
            }
        } else {
            app.surfaces.closeField()
            TabStack.of(app).dismissGallery()
            done()
        }
    }

    /// Settings › General › Show Welcome Again: the first run from its first
    /// page, over whatever was open. Nothing it found or set is undone: a Mac
    /// in sync shows as found, and Join only lays its spaces out again.
    func replay(_ app: AppModel) {
        Haptics.play(.light, reason: Haptics.Reason.confirm)
        reset()
        app.surfaces.closeSettings()
        Motion.welcomeOut.run { SettingsUI.shared.welcomeForced = true }
    }

    /// Gone for good.
    func done() {
        loop?.cancel()
        Motion.welcomeOut.run {
            SettingsStore.shared.welcomed = true
            SettingsUI.shared.welcomeForced = nil
        }
        started = false
    }

    // MARK: - the pages' own life

    /// A finger on the name: jelly.
    func poke() {
        Haptics.play(.light, reason: "name press")
        pokes += 1
    }

    func toggleIncognito() {
        Haptics.play(.light, reason: Haptics.Reason.eyes)
        withAnimation(Self.motion(.easeInOut(duration: 0.45))) { incognito.toggle() }
    }

    /// A page's one setting changed.
    func toggled() {
        Haptics.play(.selection, reason: "toggle")
    }

    /// The field types a phrase, and the phrase lands in its way: Search,
    /// Ask or Your Mac. A tap on the field types the next one at once.
    func startTyping(now: Bool = false) {
        loop?.cancel()
        typed = ""
        guard !Motion.disabled else {
            landed = ["lisbon weather", "is this flight refundable?", "book a table for 8 on Saturday"]
            return
        }
        loop = Task { @MainActor in
            if !now { try? await Task.sleep(for: .milliseconds(500)) }
            while !Task.isCancelled, step == .field {
                let (text, way) = Self.phrases[phrase % Self.phrases.count]
                phrase += 1
                for letter in text {
                    guard !Task.isCancelled else { return }
                    typed.append(letter)
                    try? await Task.sleep(for: .milliseconds(42))
                }
                try? await Task.sleep(for: .milliseconds(380))
                guard !Task.isCancelled else { return }
                withAnimation(Self.motion(Self.land)) { landed[way] = text; typed = ""; lit = way }
                try? await Task.sleep(for: .milliseconds(450))
                withAnimation(Self.motion(.easeOut(duration: 0.3))) { lit = nil }
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }

    func tapField() {
        Haptics.play(.light, reason: "field")
        startTyping(now: true)
    }

    /// A link comes in from another app every couple of seconds and becomes
    /// the tab in front.
    private func startLinks() {
        loop?.cancel()
        guard !Motion.disabled else { return }
        loop = Task { @MainActor in
            while !Task.isCancelled, step == .links {
                try? await Task.sleep(for: .milliseconds(1100))
                guard !Task.isCancelled else { return }
                let next = (linkShown + 1) % Self.links.count
                withAnimation(Self.motion(.spring(response: 0.42, dampingFraction: 0.8))) { linkComing = next; linkLanding = false }
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                withAnimation(Self.motion(Self.morph)) { linkLanding = true }
                try? await Task.sleep(for: .milliseconds(380))
                withAnimation(Self.motion(.easeOut(duration: 0.25))) { linkShown = next; linkComing = nil; linkLanding = false }
            }
        }
    }

    // MARK: - named states

    /// A step as a still, for named states (Testing/States+Welcome.swift).
    func pretend(_ step: Step, sync: Step? = nil, joining: Bool = false, joined: Bool = false, counted: Double = 0,
                 wrongs: Int = 0, incognito: Bool = false) {
        holds = true
        started = true
        loop?.cancel()
        self.step = step
        syncPage = sync ?? (step == .found ? .found : .noMac)
        self.joining = joining
        self.joined = joined
        self.counted = counted
        self.wrongs = wrongs
        self.incognito = incognito
        if step == .field { startTyping() }
    }

    /// Back to the first moment, for a named state that starts the flow.
    func reset() {
        loop?.cancel()
        step = .welcome; started = false; syncPage = .noMac; joining = false; joined = false; counted = 0
        withoutMac = false; wrongs = 0; incognito = false; asksLinks = true; pokes = 0; typed = ""
        landed = ["", "", ""]; lit = nil; linkShown = 0; linkComing = nil; linkLanding = false; holds = false; phrase = 0
    }

    // MARK: - motion, the prototype's numbers

    static let standInCode = "K7QM-4TZP"
    /// The glass from one page's shape into the next's (the prototype's morph).
    static let morph = Animation.spring(response: 0.5, dampingFraction: 0.86)
    /// A typed phrase into its way.
    static let land = Animation.spring(response: 0.42, dampingFraction: 0.82)
    /// A label's glyphs, "Copy" to "Copied".
    static let label = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)
    static let next = "first run next"

    static let phrases: [(String, Int)] = [
        ("lisbon weather", 0), ("is this flight refundable?", 1), ("book a table for 8 on Saturday", 2),
        ("flights to porto in june", 0), ("what\u{2019}s in this pdf?", 1), ("cancel my gym membership", 2),
    ]

    struct Link: Sendable {
        let host: String
        let title: String
        let from: GlyphName
        let colors: [UInt32]
    }

    static let links: [Link] = [
        Link(host: "timeout.com", title: "The best things to do in Lisbon", from: .chatBubble7, colors: [0xF7C873, 0xEE7B5B, 0xB5527A]),
        Link(host: "airbnb.com", title: "Alfama flat, 3 nights", from: .email1, colors: [0xFF9A8B, 0xE0565B]),
        Link(host: "flytap.com", title: "Lisbon, round trip", from: .chatBubble7, colors: [0x86D9A4, 0x2E9E6B]),
    ]

    /// The Mac's own name once sync has heard it, else "Your Mac": never a
    /// stand-in name for somebody else's Mac.
    static func macName(_ app: AppModel, lower: Bool = false) -> String {
        app.sync.macs.first?.name ?? (lower ? "your Mac" : "Your Mac")
    }

    /// A view's animation, or none with motion off (named states, tests).
    static func motion(_ animation: Animation) -> Animation? { Motion.disabled ? nil : Motion.reduced ? Motion.fade : animation }

    static func eout(_ p: Double) -> Double { 1 - pow(1 - min(max(p, 0), 1), 3) }
    static func seg(_ p: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat { min(max((p - a) / (b - a), 0), 1) }

    private func pause(_ seconds: Double) async {
        guard !Motion.disabled else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// What the found Mac brings, in its own words.
struct FoundCounts {
    let tabs: Int
    let pins: Int
    let folders: Int

    @MainActor
    init(_ app: AppModel) {
        let spaces = app.browser.spaces.filter { !$0.isPrivate }
        func count(_ items: [KeptItem]) -> (tabs: Int, folders: Int) {
            items.reduce((0, 0)) { sum, item in
                switch item {
                case .tab: return (sum.0 + 1, sum.1)
                case let .folder(folder):
                    let inner = count(folder.items)
                    return (sum.0 + inner.tabs, sum.1 + 1 + inner.folders)
                }
            }
        }
        let kept = spaces.map { count($0.kept) }
        tabs = spaces.reduce(0) { $0 + $1.today.count } + kept.reduce(0) { $0 + $1.tabs }
        pins = spaces.reduce(0) { $0 + $1.pins.count }
        folders = kept.reduce(0) { $0 + $1.folders }
    }
}

// MARK: - the screen

struct FirstRunView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    /// The bottom block's height (words, the setting, the button): the
    /// stage above it scales its drawing down when they would meet.
    @State private var bottom: CGFloat = 300
    /// How much of the screen the keyboard covers.
    @State private var keyboard: CGFloat = 0
    private var run: FirstRun { .shared }
    private typealias M = Metrics.FirstTray

    var body: some View {
        let night = run.step == .incognito && run.incognito
        let dark = night || scheme == .dark
        ZStack {
            FirstRunGround(night: night)
                .opacity(run.step == .end ? 0 : 1)
                .animation(FirstRun.motion(.easeOut(duration: 0.45)), value: run.step == .end)
                .ignoresSafeArea()
            // The welcome stands over the whole screen (its layer ignores
            // the safe area): the window's own insets keep ‹ and Skip under
            // the status bar and the button over the home indicator, and
            // the keyboard, when the Recovery Key is typed, lifts the words.
            GeometryReader { proxy in
                let insets = Self.insets
                let below = max(insets.bottom, keyboard)
                let width = min(proxy.size.width, M.column)
                let height = max(1, proxy.size.height - insets.top - below)
                screen(CGSize(width: width, height: height))
                    .frame(width: width, height: height)
                    .padding(.top, insets.top)
                    .padding(.bottom, below)
                    .frame(maxWidth: .infinity)
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                        let covered = max(0, proxy.frame(in: .global).maxY - frame.minY)
                        withAnimation(FirstRun.motion(.spring(response: 0.36, dampingFraction: 0.86))) { keyboard = min(proxy.size.height, covered) }
                    }
            }
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        .onAppear {
            run.begin(app)
            FirstRunTilt.shared.start()
        }
        .onDisappear { FirstRunTilt.shared.stop() }
        // Joined while the code or the Recovery Key is up: a Mac let it in.
        .onChange(of: app.sync.phase) { _, now in
            if now == .on, run.step == .code || run.step == .recovery { run.succeed(app) }
        }
        .onChange(of: night, initial: true) { _, isNight in
            app.surfaces.statusBarLight = isNight || scheme == .dark
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome")
        .accessibilityAddTraits(.isModal)
    }

    /// The key window's safe area: the layer over it ignores its own.
    private static var insets: UIEdgeInsets {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }?.safeAreaInsets ?? UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
    }

    private func screen(_ size: CGSize) -> some View {
        let available = size.height - bottom - M.stageTop - M.stageGap
        let needs = FirstRunStage.needs(run.step)
        let k = max(0.45, min(size.width / FirstRunStage.width, M.maxScale, available / needs))
        // The drawing a little above the middle of the room it has.
        let air = max(0, (available - needs * k) * 0.4)
        return ZStack(alignment: .top) {
            FirstRunStage()
                .frame(width: FirstRunStage.width, height: FirstRunStage.height, alignment: .topLeading)
                .scaleEffect(k, anchor: .topLeading)
                .frame(width: FirstRunStage.width * k, height: FirstRunStage.height * k, alignment: .topLeading)
                .padding(.top, M.stageTop + air)
                .animation(FirstRun.motion(FirstRun.morph), value: k)
                .animation(FirstRun.motion(FirstRun.morph), value: air)
            VStack(spacing: 0) {
                FirstRunBar()
                Spacer(minLength: 0)
                FirstRunBottom(maxCopy: max(120, size.height * 0.42))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottom = $0 }
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

/// The ground: one iOS system color fading into the grouped gray, its dots
/// barely there; graphite in Dark Mode; night while Private's eyes are shut.
private struct FirstRunGround: View {
    let night: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if scheme == .dark {
                Color(red: 0x0E / 255, green: 0x0E / 255, blue: 0x11 / 255)
            } else {
                LinearGradient(stops: [.init(color: Self.mix(0.14), location: 0), .init(color: Self.mix(0.04), location: 0.42),
                                       .init(color: Self.gray, location: 0.7)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Self.blue.opacity(0.3), Self.blue.opacity(0)], center: UnitPoint(x: 0.5, y: -0.08),
                               startRadius: 0, endRadius: 520)
            }
            Dots(color: scheme == .dark ? Color.white.opacity(0.045) : Color(red: 60 / 255, green: 72 / 255, blue: 110 / 255).opacity(0.05))
                .padding(-12)
                .parallax(-4)
            Color(red: 5 / 255, green: 5 / 255, blue: 7 / 255)
                .opacity(night ? 1 : 0)
                .animation(FirstRun.motion(.easeInOut(duration: 0.45)), value: night)
        }
    }

    static let blue = Color(red: 0, green: 0x7A / 255, blue: 1)
    static let gray = Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF7 / 255)

    /// System blue mixed into #F2F2F7 at `share`.
    static func mix(_ share: Double) -> Color {
        Color(red: 0xF2 / 255 * (1 - share), green: (0xF2 * (1 - share) + 0x7A * share) / 255, blue: (0xF7 * (1 - share) + 0xFF * share) / 255)
    }

    private struct Dots: View {
        let color: Color
        var body: some View {
            Canvas { context, size in
                var dots = Path()
                for x in stride(from: 9.0, to: size.width, by: 18) {
                    for y in stride(from: 9.0, to: size.height, by: 18) {
                        dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    }
                }
                context.fill(dots, with: .color(color))
            }
            .accessibilityHidden(true)
        }
    }
}

// MARK: - the frame: ‹, the dots, Skip

private struct FirstRunBar: View {
    @Environment(AppModel.self) private var app
    private var run: FirstRun { .shared }

    var body: some View {
        let back = run.step != .welcome && run.step != .end && !(run.isSync && (run.joining || run.joined))
        let skip = run.step != .end && !run.joining
        HStack {
            Button { run.back(app) } label: {
                Glyph(.chevronLeft, size: 19)
                    .frame(width: 44, height: 44)
                    .glassCircle()
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .opacity(back ? 1 : 0)
            .allowsHitTesting(back)
            .accessibilityHidden(!back)
            .accessibilityLabel("Back")
            .accessibilityIdentifier("welcome.back")
            Spacer(minLength: 0)
            Button { run.skip(app) } label: {
                Text("Skip")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 40)
                    .glassCapsule()
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .contentShape(Capsule())
            .opacity(skip ? 1 : 0)
            .allowsHitTesting(skip)
            .accessibilityIdentifier("welcome.skip")
        }
        .overlay {
            HStack(spacing: 6) {
                ForEach(0..<run.pages, id: \.self) { i in
                    Capsule()
                        .fill(i == run.page ? Ink.primary : Ink.faint.opacity(0.55))
                        .frame(width: i == run.page ? 22 : 7, height: 7)
                }
            }
            .animation(FirstRun.motion(.spring(response: 0.36, dampingFraction: 0.86)), value: run.page)
            .opacity(run.step == .end ? 0 : 1)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .frame(height: Metrics.FirstTray.barHeight)
        .animation(FirstRun.motion(.easeOut(duration: 0.25)), value: back)
    }
}

// MARK: - the words, the setting, the button

private struct FirstRunBottom: View {
    @Environment(AppModel.self) private var app
    let maxCopy: CGFloat
    /// The words' own height, measured off screen.
    @State private var copyHeight: CGFloat = 0
    private var run: FirstRun { .shared }

    var body: some View {
        let words = Words(run.step, app: app)
        VStack(alignment: .leading, spacing: 0) {
            // As tall as the words; only text too large for the room scrolls.
            Group {
                if copyHeight > maxCopy {
                    ScrollView { copy(words) }
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollIndicators(.hidden)
                        .frame(height: maxCopy)
                } else {
                    copy(words)
                }
            }
            .background {
                copy(words)
                    .hidden()
                    .accessibilityHidden(true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { copyHeight = $0 }
            }
            .id(run.step)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)).animation(FirstRun.motion(.easeOut(duration: 0.3).delay(0.08))),
                                    removal: .opacity.animation(FirstRun.motion(.easeOut(duration: 0.14)))))
            SettingRow(step: run.step)
                .padding(.top, 22)
            CallButton()
                .padding(.top, 16)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
        .opacity(run.step == .end ? 0 : 1)
        .animation(FirstRun.motion(.easeOut(duration: 0.2)), value: run.step == .end)
    }

    private func copy(_ words: Words) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(words.title)
                .font(.largeTitle.bold())
                .tracking(-0.7)
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("welcome.title")
            Text(words.sub)
                .font(.body)
                .lineSpacing(3)
                .foregroundStyle(FirstRunInk.words)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("welcome.words")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Each page's title and words.
    struct Words {
        let title: String
        let sub: String

        @MainActor
        init(_ step: FirstRun.Step, app: AppModel) {
            let mac = FirstRun.macName(app)
            switch step {
            case .welcome:
                title = "Hi, it\u{2019}s Yab"
                sub = "A browser that keeps your Mac\u{2019}s tabs in your pocket."
            case .found:
                title = mac == "Your Mac" ? "Found your Mac" : "Found \(mac)"
                sub = "Same Apple ID. Join it, and its spaces and tabs open here, end-to-end encrypted."
            case .noMac:
                title = "Yab is on Mac too"
                sub = "Yab works fine on its own here. When you get it on your Mac, join from Settings \u{203A} Sync and your spaces come over."
            case .code:
                title = "Join your Mac"
                sub = "In Yab on your Mac, open Settings \u{203A} Sync, choose Add a Device and type this code."
            case .recovery:
                title = "Use your Recovery Key"
                sub = "It\u{2019}s in Yab on your Mac, in Settings \u{203A} Sync, or in Yab Recovery Key.pdf."
            case .field:
                title = "Search, ask, hand off"
                sub = "One place to type. Yab knows a search from a question or a task for your Mac."
            case .incognito:
                title = "Close the eyes"
                sub = "Tap the eyes in the field. The tab stays off your Mac and is gone once you close it."
            case .links:
                title = "Links open in Yab"
                sub = FirstRun.shared.withoutMac
                    ? "From Messages, Mail and every other app: a link becomes a tab here."
                    : "From Messages, Mail and every other app: a link becomes a tab here, and on your Mac too."
            case .end:
                title = " "
                sub = " "
            }
        }
    }
}

/// The page's one setting, or the way to another page: a glass row.
private struct SettingRow: View {
    @Environment(AppModel.self) private var app
    let step: FirstRun.Step
    private var run: FirstRun { .shared }

    var body: some View {
        Group {
            switch step {
            case .found:
                if !run.joining && !run.joined {
                    way("Another Mac?", "Join it with a code", id: "welcome.useCode") { run.chooseMac(app) }
                }
            case .noMac:
                way("Yab is on my Mac", "Show a code to type there", id: "welcome.mac") { run.chooseMac(app) }
            case .code:
                if !run.joined {
                    way("Use Recovery Key", "From Yab Recovery Key.pdf", id: "welcome.recovery") { run.useRecoveryKey(app) }
                }
            case .field:
                toggle("Open Keyboard at Launch", "Start every visit typing", id: "welcome.keyboard",
                       on: Binding(get: { SettingsStore.shared.openKeyboardAtLaunch },
                                   set: { SettingsStore.shared.openKeyboardAtLaunch = $0; run.toggled() }))
            case .incognito:
                toggle("Face ID for Private Tabs", "Needed each time you open them", id: "welcome.privateLock",
                       on: Binding(get: { SettingsStore.shared.privateLock },
                                   set: { SettingsStore.shared.privateLock = $0; run.toggled() }))
            case .welcome, .recovery, .links, .end:
                EmptyView()
            }
        }
        .id(step)
        .transition(.asymmetric(insertion: .opacity.animation(FirstRun.motion(.easeOut(duration: 0.24).delay(0.1))),
                                removal: .opacity.animation(FirstRun.motion(.easeOut(duration: 0.12)))))
    }

    private func toggle(_ title: String, _ words: String, id: String, on: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            label(title, words)
            Toggle(title, isOn: on)
                .labelsHidden()
                .accessibilityIdentifier(id)
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .glassPlate(RoundedRectangle(cornerRadius: 30, style: .continuous), interactive: false)
    }

    private func way(_ title: String, _ words: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                label(title, words)
                Glyph(.chevronRight, size: 13, color: Ink.faint)
                    .padding(.trailing, 4)
            }
            .padding(.leading, 20)
            .padding(.trailing, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 64)
            .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .glassPlate(RoundedRectangle(cornerRadius: 30, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func label(_ title: String, _ words: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(Ink.primary)
            Text(words)
                .font(.footnote)
                .foregroundStyle(FirstRunInk.words)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The page's one black button (white on night and in Dark Mode).
private struct CallButton: View {
    @Environment(AppModel.self) private var app
    @State private var copied = false
    private var run: FirstRun { .shared }

    var body: some View {
        let (title, id, enabled) = what
        Button {
            switch run.step {
            case .code:
                if case let .joining(.code(code)) = app.sync.phase {
                    UIPasteboard.general.string = code
                } else {
                    UIPasteboard.general.string = FirstRun.standInCode
                }
                Haptics.play(.soft, reason: Haptics.Reason.copyLink)
                withAnimation(FirstRun.motion(FirstRun.label)) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation(FirstRun.motion(FirstRun.label)) { copied = false } }
            case .recovery:
                run.tryRecovery(app)
            default:
                run.forward(app)
            }
        } label: {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color(uiColor: .systemBackground))
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Color.primary, in: Capsule(style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 11, y: 8)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(Pressed())
        .disabled(!enabled)
        // Joining and In Sync are words about the Mac, not a dead button.
        .opacity(run.step == .recovery && !enabled && !run.joined ? 0.4 : 1)
        .animation(FirstRun.motion(.easeOut(duration: 0.2)), value: title)
        .accessibilityIdentifier(id)
    }

    private var what: (String, String, Bool) {
        switch run.step {
        case .welcome: ("Get Started", "welcome.start", true)
        case .found:
            if run.joined { ("In Sync", "welcome.join", false) }
            else if run.joining { ("Joining\u{2026}", "welcome.join", false) }
            else { ("Join \(FirstRun.macName(app))", "welcome.join", true) }
        case .noMac: ("Continue", "welcome.withoutMac", true)
        case .code: run.joined ? ("In Sync", "welcome.copy", false) : (copied ? "Copied" : "Copy Code", "welcome.copy", true)
        case .recovery: run.joined ? ("In Sync", "welcome.go", false) : ("Join", "welcome.go", !app.sync.typed.isEmpty)
        case .field, .incognito: ("Continue", "welcome.next", true)
        case .links: ("Make Yab Default", "welcome.makeDefault", true)
        case .end: (" ", "welcome.end", false)
        }
    }
}

// MARK: - the stage: the drawing above the words

/// The prototype's drawing, 402 wide, its top under ‹ and Skip: the glass
/// object and whatever the page has around it. The screen scales it to fit
/// between the bar and the words.
private struct FirstRunStage: View {
    @Environment(AppModel.self) private var app
    private var run: FirstRun { .shared }

    static let width: CGFloat = 402
    static let height: CGFloat = 560
    /// Where the name's letters sit: the next page's glass grows out of them.
    static let letters = CGRect(x: 34, y: 122, width: 334, height: 137)

    /// How tall each page's drawing is.
    static func needs(_ step: FirstRun.Step) -> CGFloat {
        switch step {
        case .welcome: 348
        case .found: 290
        case .noMac: 392
        case .code: 258
        case .recovery: 214
        case .field: 356
        case .incognito: 320
        case .links: 352
        case .end: 220
        }
    }

    /// The glass object's shape on each page.
    static func hero(_ step: FirstRun.Step, joining: Bool) -> (CGRect, CGFloat) {
        switch step {
        case .welcome: (letters, 40)
        case .found: joining ? (CGRect(x: 18, y: 70, width: 120, height: 180), 26) : (CGRect(x: 46, y: 48, width: 310, height: 206), 30)
        case .noMac: (CGRect(x: 36, y: 322, width: 330, height: 68), 34)
        case .code: (CGRect(x: 46, y: 48, width: 310, height: 206), 30)
        case .recovery: (CGRect(x: 20, y: 48, width: 362, height: 162), 30)
        case .field: (CGRect(x: 20, y: 84, width: 362, height: 60), 30)
        case .incognito: (CGRect(x: 20, y: 160, width: 362, height: 56), 28)
        case .links: (CGRect(x: 86, y: 48, width: 230, height: 300), 30)
        case .end: (CGRect(x: 16, y: 120, width: 370, height: 48), 24)
        }
    }

    var body: some View {
        let step = run.step
        let (rect, radius) = Self.hero(step, joining: run.joining)
        ZStack(alignment: .topLeading) {
            if step == .welcome {
                DriftRows()
                    .offset(y: 48)
                    .parallax(-12)
                    .transition(.opacity.animation(FirstRun.motion(.easeOut(duration: 0.3))))
                    .accessibilityHidden(true)
                GlassName(pokes: run.pokes) { run.poke() }
                    .parallax(5)
                    .transition(.asymmetric(insertion: .opacity.animation(FirstRun.motion(.easeOut(duration: 0.4))),
                                            removal: .modifier(active: Melt(into: Self.hero(app.sync.phase == .on ? .found : .noMac, joining: false).0),
                                                               identity: Melt(into: nil))))
            }
            if step == .found {
                DeckBehind()
                    .transition(.opacity.animation(FirstRun.motion(.easeOut(duration: 0.3))))
            }
            if step == .noMac {
                Image("MacYab")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 340, height: 206)
                    .shadow(color: Color(red: 20 / 255, green: 40 / 255, blue: 90 / 255).opacity(0.18), radius: 13, y: 18)
                    .offset(x: 31, y: 90)
                    .parallax(-7)
                    .transition(.opacity.combined(with: .offset(y: 14)).animation(FirstRun.motion(.easeOut(duration: 0.4))))
                    .accessibilityLabel("Yab for Mac")
            }
            if step == .field {
                FieldWays()
                    .offset(x: 20, y: 160)
                    .parallax(3)
                    .transition(.opacity.combined(with: .offset(y: 14)).animation(FirstRun.motion(.easeOut(duration: 0.34).delay(0.12))))
            }
            if step == .incognito {
                PrivateAround()
                    .parallax(-6)
                    .transition(.opacity.animation(FirstRun.motion(.easeOut(duration: 0.3))))
            }
            if step == .links {
                LinksBehind()
                    .parallax(-8)
                    .transition(.opacity.animation(FirstRun.motion(.easeOut(duration: 0.3))))
            }
            HeroGlass(step: step, rect: rect, radius: radius)
            if step == .links, let coming = run.linkComing {
                LinkPill(link: FirstRun.links[coming], landing: run.linkLanding, card: rect)
                    .parallax(10)
                    .transition(.opacity.combined(with: .offset(y: -16)))
            }
        }
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
    }
}

/// The one glass object, in this page's shape, with this page's thing in it.
private struct HeroGlass: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let step: FirstRun.Step
    let rect: CGRect
    let radius: CGFloat
    private var run: FirstRun { .shared }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let night = step == .incognito && run.incognito
        content
            .frame(width: rect.width, height: rect.height)
            .clipShape(shape)
            .glassEffect(glass(night: night), in: shape)
            .offset(x: rect.minX, y: rect.minY)
            .parallax(6)
            // Only the fade waits for the letters to start squeezing; the
            // shape itself moves on the page's spring.
            .animation(FirstRun.motion(step == .welcome ? .easeOut(duration: 0.2) : .easeOut(duration: 0.3).delay(0.12))) {
                $0.opacity(step == .welcome ? 0 : 1)
            }
    }

    private func glass(night: Bool) -> Glass {
        if night { return GlassTone.dark.glass(for: .dark) }
        switch step {
        // The deck's front card hides what lies behind it: nothing shows through.
        case .found: return .regular.tint(scheme == .dark ? Color(red: 0.16, green: 0.16, blue: 0.18).opacity(0.92) : Color.white.opacity(0.84))
        case .end: return .regular.tint(scheme == .dark ? Color(red: 0.16, green: 0.16, blue: 0.18).opacity(0.95) : Color.white.opacity(0.94))
        default: return GlassTone.light.glass(for: scheme)
        }
    }

    @ViewBuilder private var content: some View {
        ZStack {
            switch step {
            case .welcome: Color.clear
            case .found: FoundCard(spread: run.joining)
            case .noMac: MacLink()
            case .code: CodeCard()
            case .recovery: RecoveryCard()
            case .field: TypingField()
            case .incognito: PrivateField()
            case .links: TabCard(link: FirstRun.links[run.linkShown])
            case .end: EndField()
            }
        }
        .id(contentKey)
        .transition(.blurReplace.animation(FirstRun.motion(.easeOut(duration: 0.28))))
    }

    private var contentKey: String {
        switch step {
        case .found: run.joining ? "found.spread" : "found"
        case .links: "links.\(run.linkShown)"
        default: "\(step)"
        }
    }
}

// MARK: - the welcome: the name in glass

/// Sites drifting by in three rows, the middle one the other way; through
/// the glass letters they show refracted.
private struct DriftRows: View {
    static let sites = ["news.ycombinator.com", "linear.app", "airbnb.com", "ledger.app", "paper.so", "daybook.app",
                        "theverge.com", "youtube.com", "tern.app", "drift.com", "flytap.com"]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: Motion.disabled || Motion.reduced)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                row(0, t: t, period: 26, reverse: false).offset(y: 10)
                row(4, t: t, period: 31, reverse: true).offset(y: 108)
                row(8, t: t, period: 22, reverse: false).offset(y: 206)
            }
        }
        .frame(width: FirstRunStage.width, height: 300, alignment: .topLeading)
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.14),
                                     .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .opacity(0.6)
    }

    private func row(_ first: Int, t: Double, period: Double, reverse: Bool) -> some View {
        let span = CGFloat(9) * (76 + 18)
        var p = CGFloat((t / period).truncatingRemainder(dividingBy: 1))
        if Motion.disabled { p = 0.18 }
        if reverse { p = 1 - p }
        return HStack(spacing: 18) {
            ForEach(0..<18, id: \.self) { k in
                let site = Self.sites[(first + k % 9) % Self.sites.count]
                Favicon(icon: site, host: site, size: 40)
                    .frame(width: 76, height: 76)
                    .background(scheme == .dark ? Color.white.opacity(0.14) : Color.white,
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: Color(red: 20 / 255, green: 40 / 255, blue: 90 / 255).opacity(0.1), radius: 9, y: 6)
            }
        }
        .fixedSize()
        .offset(x: -p * span)
    }
}

/// "Yab." in Liquid Glass: the letters refract the sites drifting under them.
/// A finger on them: jelly.
private struct GlassName: View {
    let pokes: Int
    let poke: () -> Void

    var body: some View {
        let r = FirstRunStage.letters
        ZStack(alignment: .topLeading) {
            NameShape()
                .fill(Color(red: 20 / 255, green: 50 / 255, blue: 140 / 255).opacity(0.18))
                .frame(width: r.width, height: r.height)
                .blur(radius: 10)
                .offset(x: r.minX, y: r.minY + 10)
            Color.clear
                .frame(width: r.width, height: r.height)
                .glassEffect(.regular.tint(Color.white.opacity(0.3)).interactive(), in: NameShape())
                .contentShape(NameShape())
                .onTapGesture(perform: poke)
                .keyframeAnimator(initialValue: Squish(), trigger: pokes) { content, value in
                    content.scaleEffect(x: value.x, y: value.y, anchor: .bottom)
                } keyframes: { _ in
                    KeyframeTrack(\.x) {
                        CubicKeyframe(1.1, duration: 0.1)
                        CubicKeyframe(0.93, duration: 0.13)
                        CubicKeyframe(1.04, duration: 0.13)
                        CubicKeyframe(0.985, duration: 0.12)
                        CubicKeyframe(1, duration: 0.22)
                    }
                    KeyframeTrack(\.y) {
                        CubicKeyframe(0.86, duration: 0.1)
                        CubicKeyframe(1.08, duration: 0.13)
                        CubicKeyframe(0.97, duration: 0.13)
                        CubicKeyframe(1.015, duration: 0.12)
                        CubicKeyframe(1, duration: 0.22)
                    }
                }
                .offset(x: r.minX, y: r.minY)
                .accessibilityElement()
                .accessibilityLabel("Yab")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("welcome.name")
        }
        .frame(width: FirstRunStage.width, height: FirstRunStage.height, alignment: .topLeading)
    }

    struct Squish {
        var x: Double = 1
        var y: Double = 1
    }
}

/// Get Started: the letters squeeze into the next page's glass and blur away
/// while that glass grows out of them.
private struct Melt: ViewModifier {
    let into: CGRect?

    func body(content: Content) -> some View {
        let from = FirstRunStage.letters
        let to = into ?? from
        content
            .scaleEffect(x: to.width / from.width, y: to.height / from.height,
                         anchor: UnitPoint(x: from.midX / FirstRunStage.width, y: from.midY / FirstRunStage.height))
            .offset(x: to.midX - from.midX, y: to.midY - from.midY)
            .blur(radius: into == nil ? 0 : 8)
            .opacity(into == nil ? 1 : 0)
    }
}

/// "Yab." as a shape: the system font's heaviest letters, kerned tight as
/// the drawing has them, fitted to the rect.
private struct NameShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = Self.unit
        guard unit.width > 0 else { return Path() }
        let k = min(rect.width / unit.width, rect.height / unit.height)
        let x = rect.midX - unit.midX * k, y = rect.midY - unit.midY * k
        return Path(Self.glyphs).applying(CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: x, ty: y))
    }

    nonisolated(unsafe) private static let glyphs: CGPath = {
        let font = UIFont.systemFont(ofSize: 182, weight: .heavy)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Yab.", attributes: [.font: font, .kern: -7]))
        let path = CGMutablePath()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? (font as CTFont)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var points = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &points)
            for i in 0..<count {
                guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                // CoreText draws up from the baseline: flip it for the screen.
                path.addPath(glyph, transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: points[i].x, ty: -points[i].y))
            }
        }
        return path
    }()

    nonisolated(unsafe) private static let unit: CGRect = glyphs.boundingBoxOfPath
}

// MARK: - sync: the found Mac's spaces

/// The Mac's spaces as SettingsStore keeps them: the first in the glass, two
/// more as plain cards stacked straight under it.
@MainActor
private enum FoundSpaces {
    static func all(_ app: AppModel) -> [Space] { Array(app.browser.spaces.filter { !$0.isPrivate }.prefix(3)) }
    static func tabs(_ space: Space) -> Int { space.today.count + space.keptTabs.count }
}

/// The deck's other two spaces: straight under the front card, peeking out
/// below it, blank while stacked so nothing shows through. Join lays them
/// beside it as minis that count their tabs.
private struct DeckBehind: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    private var run: FirstRun { .shared }

    var body: some View {
        let spaces = FoundSpaces.all(app)
        ZStack(alignment: .topLeading) {
            ForEach(Array(spaces.dropFirst().enumerated()), id: \.element.id) { i, space in
                let spread = run.joining
                let rect = spread ? CGRect(x: i == 0 ? 141 : 264, y: 70, width: 120, height: 180)
                                  : CGRect(x: 46 + 310 * (0.03 + 0.03 * CGFloat(i)), y: 48 + 14 + 12 * CGFloat(i),
                                           width: 310 * (0.94 - 0.06 * CGFloat(i)), height: 206)
                let shape = RoundedRectangle(cornerRadius: spread ? 26 : 30, style: .continuous)
                ZStack {
                    if spread {
                        SpaceMini(space: space, tabs: FoundSpaces.tabs(space))
                            .transition(.opacity.animation(FirstRun.motion(.easeOut(duration: 0.2).delay(0.15))))
                    }
                }
                .frame(width: rect.width, height: rect.height)
                .glassEffect(GlassTone.light.glass(for: scheme).interactive(false), in: shape)
                .opacity(spread ? 1 : 0.9 - 0.2 * Double(i))
                .offset(x: rect.minX, y: rect.minY)
                .parallax(spread ? 4 : -5 - 4 * CGFloat(i))
                .zIndex(Double(-i))
            }
        }
        .accessibilityHidden(!run.joining)
    }
}

/// The front card: the first space, its pins and two tabs; spread, its mini.
private struct FoundCard: View {
    @Environment(AppModel.self) private var app
    let spread: Bool

    var body: some View {
        let spaces = FoundSpaces.all(app)
        if let space = spaces.first {
            if spread {
                SpaceMini(space: space, tabs: FoundSpaces.tabs(space))
            } else {
                SpaceCard(space: space)
            }
        } else {
            VStack(spacing: 12) {
                Glyph(.macbook, size: 30, color: .white)
                    .frame(width: 60, height: 60)
                    .background(Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                Text(FirstRun.macName(app))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Ink.primary)
            }
        }
    }
}

private struct SpaceCard: View {
    let space: Space

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(space.emoji)
                    .font(.system(size: 18))
                    .frame(width: 34, height: 34)
                    .background(Color(rgb: space.tint, opacity: 0.32), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(space.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(FoundSpaces.tabs(space)) tabs")
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Ink.tertiary)
            }
            if !space.visiblePins.isEmpty {
                HStack(spacing: 8) {
                    ForEach(space.visiblePins.prefix(4)) { pin in
                        Favicon(icon: pin.icon, host: pin.addressHost, size: 24, url: pin.navigationURL, mark: pin.customMark)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    ForEach(0..<max(0, 4 - space.visiblePins.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 44) }
                }
            }
            ForEach(space.rows.prefix(2)) { tab in
                HStack(spacing: 10) {
                    Favicon(icon: tab.icon, host: tab.addressHost, size: 18, url: tab.navigationURL, mark: tab.customMark)
                    Text(tab.title)
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 18, leading: 18, bottom: 14, trailing: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(space.name), \(FoundSpaces.tabs(space)) tabs")
    }
}

/// A space lying in the row after Join: its emoji, name, three pins and the
/// count rolling up to a check.
private struct SpaceMini: View {
    let space: Space
    let tabs: Int
    private var run: FirstRun { .shared }

    var body: some View {
        VStack(spacing: 10) {
            Text(space.emoji)
                .font(.system(size: 24))
                .frame(width: 46, height: 46)
                .background(Color(rgb: space.tint, opacity: 0.32), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            Text(space.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .padding(.horizontal, 8)
            HStack(spacing: -5) {
                ForEach(space.visiblePins.prefix(3)) { pin in
                    Favicon(icon: pin.icon, host: pin.addressHost, size: 20, url: pin.navigationURL, mark: pin.customMark)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.9), lineWidth: 2))
                }
            }
            HStack(spacing: 5) {
                Text("\(Int((Double(tabs) * run.counted).rounded())) tabs")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(tabs) * run.counted))
                if run.joined {
                    DrawnCheck(progress: 1, size: 15)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Ink.tertiary)
            .accessibilityIdentifier("welcome.count")
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - sync: no Mac, the code, the Recovery Key

/// Under the Mac: one glass capsule, Yab for Mac, its address and Copy.
private struct MacLink: View {
    var body: some View {
        HStack(spacing: 12) {
            Glyph(.macbook, size: 20, color: .white)
                .frame(width: 40, height: 40)
                .background(Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Yab for Mac")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Text("yetanotherbrowser.com")
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Yab for Mac, at yet another browser dot com")
            Spacer(minLength: 4)
            CopyButton(text: "https://yetanotherbrowser.com", id: "welcome.copyLink")
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
    }
}

/// The code on glass plates: four and four, the way there under them; when
/// the Mac lets it in they turn green and go into the check.
private struct CodeCard: View {
    @Environment(AppModel.self) private var app
    @State private var renewed = false
    private var run: FirstRun { .shared }

    var body: some View {
        let code = currentCode
        let online = NetworkWatch.shared.isOnline
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Glyph(.macbook, size: 22, color: .white)
                    .frame(width: 42, height: 42)
                    .background(Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(run.joined ? "In sync with \(FirstRun.macName(app, lower: true))" : "On your Mac")
                        .font(.headline)
                        .foregroundStyle(Ink.primary)
                        .contentTransition(.opacity)
                        .accessibilityIdentifier("welcome.codeTitle")
                    Text("Settings \u{203A} Sync \u{203A} Add a Device")
                        .font(.subheadline)
                        .foregroundStyle(FirstRunInk.words)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            ZStack {
                Plates(code: code, width: 274, joined: run.joined)
                    .id(code)
                    .environment(\.platesQuiet, !online && !run.joined)
                DrawnCheck(progress: run.joined ? 1 : 0)
                    .animation(FirstRun.motion(.linear(duration: 0.3).delay(0.62)), value: run.joined)
                    .opacity(run.joined ? 1 : 0)
                    .animation(FirstRun.motion(.easeOut(duration: 0.08).delay(0.62)), value: run.joined)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(run.joined ? "In sync" : code.filter { $0 != "-" }.map { String($0) }.joined(separator: " "))
            .accessibilityIdentifier("welcome.code")
            Text(caption(online: online))
                .font(.subheadline)
                .foregroundStyle(FirstRunInk.words)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .opacity(run.joined ? 0 : 1)
                .accessibilityIdentifier("welcome.caption")
        }
        .padding(18)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .onChange(of: code) { _, _ in
            // Ten minutes on: a new code, and the caption says so for a while.
            renewed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { renewed = false }
        }
    }

    private var currentCode: String {
        if case let .joining(.code(code)) = app.sync.phase { return code }
        return FirstRun.standInCode
    }

    private func caption(online: Bool) -> String {
        if !online { return "No connection. Yab keeps trying." }
        if renewed { return "New code. The old one expired." }
        return "Waiting for your Mac\u{2026}"
    }
}

/// The code's eight plates, four and four with a dash: they rise one by
/// one, and joined they turn green and converge into the middle.
private struct Plates: View {
    let code: String
    let width: CGFloat
    let joined: Bool
    /// No line: the plates fade, their letters gray but legible.
    @Environment(\.platesQuiet) private var quiet
    @Environment(\.colorScheme) private var scheme
    @State private var risen = false

    private var letters: [Character] { code.filter { $0 != "-" }.map { $0 } }

    var body: some View {
        let letters = letters
        let gap: CGFloat = 5, dash: CGFloat = 12
        let plate = min(28, (width - dash - gap * CGFloat(letters.count)) / CGFloat(max(1, letters.count)))
        let total = CGFloat(letters.count) * plate + dash + gap * CGFloat(letters.count)
        HStack(spacing: gap) {
            ForEach(Array(letters.enumerated()), id: \.offset) { i, letter in
                if i == letters.count / 2 {
                    Capsule()
                        .fill(Ink.faint)
                        .frame(width: 8, height: 2)
                        .frame(width: dash)
                        .opacity(joined ? 0 : 1)
                        .animation(FirstRun.motion(.easeOut(duration: 0.2)), value: joined)
                }
                let x = Self.center(i, count: letters.count, plate: plate, gap: gap, dash: dash) - total / 2
                Text(String(letter))
                    .accessibilityHidden(true)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(joined ? Color.white : quiet ? Ink.faint : Ink.primary)
                    .frame(width: plate, height: 44)
                    .background(joined ? Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)
                                       : scheme == .dark ? Color.white.opacity(quiet ? 0.08 : 0.14) : Color.white.opacity(quiet ? 0.45 : 0.75),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .animation(FirstRun.motion(.easeOut(duration: 0.16).delay(Double(i) * 0.04)), value: joined)
                    .offset(x: joined ? -x : 0)
                    .scaleEffect(joined ? 0.4 : 1)
                    .opacity(joined ? 0 : 1)
                    .animation(FirstRun.motion(.spring(response: 0.36, dampingFraction: 0.86).delay(0.36)), value: joined)
                    .opacity(risen ? 1 : 0)
                    .offset(y: risen ? 0 : 6)
                    .animation(FirstRun.motion(.easeOut(duration: 0.18).delay(0.2 + Double(i) * 0.04)), value: risen)
            }
        }
        .onAppear { risen = true }
        .accessibilityHidden(true)
    }

    /// A plate's middle from the row's left edge.
    static func center(_ i: Int, count: Int, plate: CGFloat, gap: CGFloat, dash: CGFloat) -> CGFloat {
        let before = CGFloat(i) * (plate + gap) + (i >= count / 2 ? dash + gap : 0)
        return before + plate / 2
    }
}

/// The Recovery Key in one field, three lines and monospaced; a wrong one
/// shakes and says so at once.
private struct RecoveryCard: View {
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool
    private var run: FirstRun { .shared }

    var body: some View {
        @Bindable var sync = app.sync
        let wrong = sync.phase == .joining(.recovery(wrong: true))
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Glyph(run.joined ? .checkCircle2 : .key1, size: 22, color: run.joined ? Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255) : Ink.tertiary)
                    .padding(.top, 2)
                TextField("", text: $sync.typed, prompt: Text("XXXX-XXXX-\u{2026}").foregroundStyle(Ink.faint), axis: .vertical)
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .tracking(0.68)
                    .lineLimit(1...3)
                    .foregroundStyle(Ink.primary)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.join)
                    .focused($focused)
                    .onChange(of: sync.typed) { _, now in
                        guard now.contains("\n") else { return }
                        sync.typed = now.replacingOccurrences(of: "\n", with: "")
                        run.tryRecovery(app)
                    }
                    .onSubmit { run.tryRecovery(app) }
                    .accessibilityIdentifier("welcome.field")
            }
            Spacer(minLength: 0)
            // At once, no motion: what is wrong is said where it is.
            Text("That isn\u{2019}t a Recovery Key. Check each group of four.")
                .font(.footnote)
                .foregroundStyle(Ink.warn)
                .opacity(wrong && !sync.typed.isEmpty ? 1 : 0)
                .transaction { $0.animation = nil }
                .accessibilityHidden(!wrong)
                .accessibilityIdentifier("welcome.wrong")
        }
        .padding(EdgeInsets(top: 20, leading: 20, bottom: 16, trailing: 20))
        .modifier(Shake(travel: CGFloat(run.wrongs)))
        .task {
            try? await Task.sleep(for: .milliseconds(Motion.disabled ? 0 : 450))
            focused = true
        }
    }
}

/// ±8 sideways, fading out, 0.3 s, once a wrong key.
private struct Shake: GeometryEffect {
    var travel: CGFloat
    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let q = travel - travel.rounded(.down)
        return ProjectionTransform(CGAffineTransform(translationX: 8 * sin(q * .pi * 6) * (1 - q), y: 0))
    }
}

// MARK: - the field and its three ways

/// The field types a phrase; the phrase lands whole in its way. Its glyph
/// and words line up with the ways' glyphs and words under it.
private struct TypingField: View {
    private var run: FirstRun { .shared }

    var body: some View {
        HStack(spacing: 12) {
            Glyph(.magnifyingGlass, size: 22, color: Ink.tertiary)
                .frame(width: FieldWays.glyph)
            HStack(spacing: 1) {
                if run.typed.isEmpty {
                    Text("Search, ask or give a task")
                        .foregroundStyle(Ink.faint)
                } else {
                    Text(run.typed)
                        .foregroundStyle(Ink.primary)
                        .transition(.opacity.combined(with: .offset(y: 26)))
                }
                Caret()
            }
            .font(.system(size: 19))
            .lineLimit(1)
            Spacer(minLength: 0)
            Eyes(shut: 0, color: Ink.primary)
        }
        .padding(.leading, FieldWays.inset)
        .padding(.trailing, 18)
        .contentShape(Rectangle())
        .onTapGesture { run.tapField() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Search, ask or give a task")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("welcome.demoField")
    }
}

private struct Caret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.53)) { context in
            let on = Motion.disabled || Int(context.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
            RoundedRectangle(cornerRadius: 1)
                .fill(Color(red: 0x0A / 255, green: 0x7A / 255, blue: 1))
                .frame(width: 2, height: 24)
                .opacity(on ? 1 : 0)
        }
    }
}

/// Search, Ask, Your Mac: one glass card of three rows, each a quiet glyph
/// and its name, with the last phrase it took under the name.
private struct FieldWays: View {
    /// The field's glyph column and its inset: the rows use the same, so
    /// glyphs and words stand in one line from the field down.
    static let glyph: CGFloat = 24
    static let inset: CGFloat = 18
    static let row: CGFloat = 64

    private var run: FirstRun { .shared }

    var body: some View {
        let ways: [(String, GlyphName)] = [("Search", .magnifyingGlass), ("Ask", .bubbleSparkle), ("Your Mac", .macbook)]
        VStack(spacing: 0) {
            ForEach(Array(ways.enumerated()), id: \.offset) { i, way in
                if i > 0 {
                    Rectangle()
                        .fill(Ink.faint.opacity(0.35))
                        .frame(height: 0.5)
                        .padding(.leading, Self.inset + Self.glyph + 12)
                }
                HStack(spacing: 12) {
                    Glyph(way.1, size: 20, color: Ink.rowGlyph)
                        .frame(width: Self.glyph)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(way.0)
                            .font(.system(size: run.landed[i].isEmpty ? 17 : 13, weight: run.landed[i].isEmpty ? .regular : .semibold))
                            .foregroundStyle(run.landed[i].isEmpty ? Ink.primary : Ink.tertiary)
                        if !run.landed[i].isEmpty {
                            Text(run.landed[i])
                                .font(.system(size: 17))
                                .foregroundStyle(Ink.primary)
                                .lineLimit(1)
                                .id(run.landed[i])
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -22)), removal: .opacity))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, Self.inset)
                .padding(.trailing, 18)
                .frame(height: Self.row)
                .background(Color(red: 0x0A / 255, green: 0x7A / 255, blue: 1).opacity(run.lit == i ? 0.1 : 0))
            }
        }
        .frame(width: 362)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .glassPlate(RoundedRectangle(cornerRadius: 28, style: .continuous), interactive: false)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - private

/// The private page's field: tap the eyes and the page goes night.
private struct PrivateField: View {
    private var run: FirstRun { .shared }

    var body: some View {
        let night = run.incognito
        HStack(spacing: 12) {
            Glyph(.magnifyingGlass, size: 20, color: night ? Color.white.opacity(0.7) : Ink.tertiary)
                .frame(width: FieldWays.glyph)
            Text("Search, ask or give a task")
                .font(.system(size: 17))
                .foregroundStyle(night ? Color.white.opacity(0.5) : Ink.faint)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { run.toggleIncognito() } label: {
                HStack(spacing: 8) {
                    Text("Incognito")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .fixedSize()
                        .frame(width: night ? 82 : 0, alignment: .leading)
                        .clipped()
                    Eyes(shut: night ? 1 : 0, color: night ? .white : Ink.primary)
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(night ? "Open the eyes" : "Close the eyes")
            .accessibilityIdentifier("welcome.eyes")
        }
        .padding(.leading, FieldWays.inset)
        .padding(.trailing, 10)
    }
}

/// Around it: "tap the eyes" in the pen, and once they're shut, what Private
/// means, in chips.
private struct PrivateAround: View {
    private var run: FirstRun { .shared }
    static let chips = [["Stays on this \(DeviceWord.name)", "Gone when closed"], ["Hidden from the agent", "Never synced"]]

    var body: some View {
        let night = run.incognito
        ZStack(alignment: .topLeading) {
            VStack(spacing: 10) {
                Glyph(.incognito, size: 46, color: Color.white.opacity(0.88))
                Text("You\u{2019}re browsing Incognito")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.88))
            }
            .frame(width: FirstRunStage.width)
            .offset(y: 48)
            .opacity(night ? 1 : 0)
            .animation(FirstRun.motion(.easeOut(duration: 0.35).delay(night ? 0.1 : 0)), value: night)
            VStack(spacing: 10) {
                ForEach(Array(Self.chips.enumerated()), id: \.offset) { r, row in
                    HStack(spacing: 8) {
                        ForEach(Array(row.enumerated()), id: \.offset) { c, chip in
                            let k = r * 3 + c
                            Text(chip)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .frame(height: 34)
                                .background(Color.white.opacity(0.12), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6))
                                .scaleEffect(night ? 1 : 0.7)
                                .opacity(night ? 1 : 0)
                                .animation(FirstRun.motion(.spring(response: 0.45, dampingFraction: 0.7).delay(night ? 0.12 + Double(k) * 0.07 : 0)), value: night)
                        }
                    }
                }
            }
            .frame(width: FirstRunStage.width)
            .offset(y: 238)
            ZStack(alignment: .topLeading) {
                Text("tap the eyes")
                    .font(PenFont.hand(26))
                    .foregroundStyle(Color(red: 0x62 / 255, green: 0x36 / 255, blue: 0xE0 / 255))
                PenArrow()
                    .stroke(Color(red: 0x62 / 255, green: 0x36 / 255, blue: 0xE0 / 255), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 40, height: 46)
                    .offset(x: 108, y: 22)
            }
            .offset(x: 210, y: 92)
            .opacity(night ? 0 : 1)
            .animation(FirstRun.motion(.easeOut(duration: 0.3)), value: night)
        }
        .frame(width: FirstRunStage.width, height: FirstRunStage.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private struct PenArrow: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 8, y: 2))
            path.addCurve(to: CGPoint(x: 26, y: 36), control1: CGPoint(x: 18, y: 10), control2: CGPoint(x: 24, y: 20))
            path.move(to: CGPoint(x: 18, y: 30))
            path.addLine(to: CGPoint(x: 26, y: 37))
            path.addLine(to: CGPoint(x: 31, y: 28))
            return path
        }
    }
}

// MARK: - links

/// The tabs under the one in front: straight, peeking out above it.
private struct LinksBehind: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<2, id: \.self) { i in
                let w = 230 * (0.92 - 0.06 * CGFloat(i))
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.1 - 0.03 * Double(i)) : Color.white.opacity(0.55 - 0.15 * Double(i)))
                    .frame(width: w, height: 300)
                    .offset(x: 201 - w / 2, y: 48 - 12 - 11 * CGFloat(i))
                    .zIndex(Double(-i))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A tab: the page's picture and title, its lines, its address on glass.
private struct TabCard: View {
    let link: FirstRun.Link

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: link.colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(link.title)
                        .font(.system(size: 24, weight: .heavy))
                        .tracking(-0.5)
                        .foregroundStyle(.white)
                        .padding(16)
                }
                .frame(height: proxy.size.height * 0.62)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule()
                            .fill(Color(red: 0xEC / 255, green: 0xEA / 255, blue: 0xF1 / 255))
                            .frame(width: i == 2 ? proxy.size.width * 0.5 : nil, height: 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
                Spacer(minLength: 0)
            }
            .background(Color.white)
            .overlay(alignment: .bottom) {
                HStack(spacing: 7) {
                    Favicon(icon: link.host, host: link.host, size: 14)
                    Text(link.host)
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.primary)
                }
                .frame(maxWidth: .infinity, minHeight: 34)
                .glassCapsule(interactive: false)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(link.title), \(link.host)")
    }
}

/// A link on its way in from another app: a pill at the top that grows into
/// the tab in front.
private struct LinkPill: View {
    let link: FirstRun.Link
    let landing: Bool
    let card: CGRect

    var body: some View {
        let pill = CGRect(x: 201 - 95, y: -6, width: 190, height: 40)
        let r = landing ? card : pill
        HStack(spacing: 8) {
            Glyph(link.from, size: 16, color: .white)
                .frame(width: 28, height: 28)
                .background(Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(link.host)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .opacity(landing ? 0 : 1)
        .frame(width: r.width, height: r.height, alignment: .leading)
        .glassPlate(RoundedRectangle(cornerRadius: landing ? 30 : 20, style: .continuous), interactive: false)
        .offset(x: r.minX, y: r.minY)
        .accessibilityHidden(true)
    }
}

/// The last page: the glass is the search field, where the real one opens.
private struct EndField: View {
    var body: some View {
        HStack(spacing: 10) {
            Glyph(.magnifyingGlass, size: 19, color: Ink.tertiary)
            Text("Search, ask or give a task")
                .font(.system(size: 17))
                .foregroundStyle(Ink.faint)
                .lineLimit(1)
            Spacer(minLength: 0)
            Eyes(shut: 0, color: Ink.primary)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .accessibilityHidden(true)
    }
}

// MARK: - the parts

/// Copy → Copied: "Cop" stays, "y" goes, "ied" grows, the clipboard turns
/// into a drawn check; back after two seconds.
private struct CopyButton: View {
    let text: String
    let id: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            Haptics.play(.soft, reason: Haptics.Reason.copyLink)
            withAnimation(FirstRun.motion(FirstRun.label)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation(FirstRun.motion(FirstRun.label)) { copied = false } }
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    Glyph(.clipboard, size: 15, color: Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255))
                        .opacity(copied ? 0 : 1)
                    DrawnCheck(progress: copied ? 1 : 0, size: 15, color: Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255))
                        .animation(FirstRun.motion(.linear(duration: 0.34)), value: copied)
                }
                .frame(width: 15, height: 15)
                HStack(spacing: 0) {
                    Text("Cop")
                    Text("y")
                        .fixedSize()
                        .frame(width: copied ? 0 : nil, alignment: .leading)
                        .opacity(copied ? 0 : 1)
                        .clipped()
                    Text("ied")
                        .fixedSize()
                        .frame(width: copied ? nil : 0, alignment: .leading)
                        .opacity(copied ? 1 : 0)
                        .clipped()
                }
                // The button says Copy or Copied itself; its letters are drawing.
                .accessibilityHidden(true)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255))
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(Color.white.opacity(0.9), in: Capsule())
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(Pressed())
        .accessibilityLabel(copied ? "Copied" : "Copy")
        .accessibilityIdentifier(id)
    }
}

/// Caveat, the pen's hand on Yab's site and the Mac's notes
/// (Design/Caveat.ttf, SIL OFL, THIRD_PARTY_NOTICES.md).
enum PenFont {
    private static let registered: Bool = {
        guard let url = Bundle.main.url(forResource: "Caveat", withExtension: "ttf") else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    static func hand(_ size: CGFloat) -> Font {
        _ = registered
        return Font.custom("Caveat", size: size).weight(.semibold)
    }
}

/// The check that draws itself: the circle first, then the tick (~0.4 s).
struct DrawnCheck: View, Animatable {
    var progress: CGFloat
    var size: CGFloat = 52
    var color: Color = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let s = size / 52
        ZStack {
            Circle()
                .trim(from: 0, to: CGFloat(FirstRun.eout(Double(FirstRun.seg(progress, 0, 0.6)))))
                .stroke(color, style: StrokeStyle(lineWidth: 3.5 * s, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(3 * s)
            Tick()
                .trim(from: 0, to: CGFloat(FirstRun.eout(Double(FirstRun.seg(progress, 0.45, 1)))))
                .stroke(color, style: StrokeStyle(lineWidth: 4 * s, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private struct Tick: Shape {
        func path(in rect: CGRect) -> Path {
            let s = rect.width / 52
            var path = Path()
            path.move(to: CGPoint(x: 15 * s, y: 27 * s))
            path.addLine(to: CGPoint(x: 22.5 * s, y: 34.5 * s))
            path.addLine(to: CGPoint(x: 37.5 * s, y: 19 * s))
            return path
        }
    }
}

/// 0.96 under the finger.
private struct Pressed: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(FirstRun.motion(.easeOut(duration: 0.12)), value: configuration.isPressed)
    }
}

private extension EnvironmentValues {
    @Entry var platesQuiet = false
}

/// The first run's own inks.
private enum FirstRunInk {
    /// The words under a title: opaque, so they keep their contrast over the
    /// ground's color (#3C3C43, iOS's secondary label made opaque; dark #D1D1D6).
    static let words = AppearanceColors.color(0x3C3C43, 0xD1D1D6)
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension Metrics {
    /// The first run's page, the drawing's numbers.
    enum FirstTray {
        /// The old tray's corner, kept for the chats' tray that matches it.
        static let radius: CGFloat = 38
        /// ‹, the dots and Skip.
        static let barHeight: CGFloat = 48
        /// The stage's top under the bar, and its air above the words.
        static let stageTop: CGFloat = 48
        static let stageGap: CGFloat = 16
        /// The page's widest column (iPad), and the drawing's largest scale.
        static let column: CGFloat = 440
        static let maxScale: CGFloat = 1.1
    }
}
