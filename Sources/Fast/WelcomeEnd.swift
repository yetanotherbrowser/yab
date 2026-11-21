import SwiftUI
import AppKit

// The last of it. Chapter 5, Only what helps: with an agent connected and
// nothing yet remembered, two cards side by side, Get to Know and Google,
// each asking only when its own button is pressed (Continue never presses
// them); otherwise Google alone, as a composed hero: the account the import
// found signed in, what one Allow at Google brings (mail, the next meeting,
// codes), Connect. Google's page is a tab: the welcome steps aside for it
// and comes back to the account connected, the other one found left for
// Settings › Mail. Chapter 6, Links from other apps,
// unless Yab already is where links go: the Mac's own Mail, Messages and
// Slack beside the window-to-be, a link lifts out of the last of them,
// travels on an arc and lands as the tab at the row's end; Make Default asks
// macOS. Then Finish: every held pref written first, the frame leaves, and
// the window-to-be grows into the real window's rect, its corner relaxing
// to the window's own, and the overlay is gone.
//
// As the approved prototype has it (yab-onboarding-new.html): chapter 5 is
// one beat, two cards (`access`) or Google alone (`access-b`).

@MainActor
enum WelcomeEnd: WelcomeChapter {
    static let helpsTitle = "Give your agents context about you"
    static let linksTitle = "Links from other apps."

    // MARK: - the path

    static func beats(_ stage: WelcomeStage) -> [WelcomeStage.Beat] {
        // The facts these chapters ask about, read as the welcome begins.
        if stage.beat == .welcome { look() }
        var beats: [WelcomeStage.Beat] = twoCards(stage) ? [.access]
            : MailExperiment.enabled() || stage.pretend.calendar != nil ? [.accessB] : []
        if !alreadyDefault(stage) { beats.append(.links) }
        beats.append(.finish)
        return beats
    }

    /// Get to Know beside Calendar: an agent connected, nothing yet
    /// remembered, and something for it to read. Until the memory has been
    /// read, taken as empty.
    static func twoCards(_ stage: WelcomeStage) -> Bool {
        WelcomeConnect.connected(stage) != nil && (stage.pretend.memoryFull.map { !$0 } ?? memoryEmpty ?? true)
            && somethingToRead(stage)
    }

    /// Get to Know reads the history and the signed-in sites of a browser
    /// brought in from (OtherHistory: bringing was the yes). Started fresh,
    /// with no browser read before, it would find nothing: no card then.
    static func somethingToRead(_ stage: WelcomeStage) -> Bool {
        if WelcomeYours.broughtFrom(stage) != nil { return true }
        if WelcomeYours.pretending(stage) || stage.pretend.bring != nil { return false }
        return OtherHistory.choices.values.contains(true)
    }

    /// Yab was already where links go when the welcome began: read once,
    /// so saying yes in chapter 6 doesn't take the chapter off the path.
    static func alreadyDefault(_ stage: WelcomeStage) -> Bool {
        if let pretended = stage.pretend.defaultBrowser { return pretended == .already }
        if defaultAtStart == nil { defaultAtStart = Links.isDefault }
        return defaultAtStart ?? false
    }

    /// Slack is on this Mac: named and drawn only then.
    static func slack(_ stage: WelcomeStage) -> Bool {
        if let pretended = stage.pretend.slack { return pretended }
        if slackInstalled == nil { slackInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: slackApp) != nil }
        return slackInstalled ?? false
    }

    static let mailApp = "com.apple.mail"
    static let messagesApp = "com.apple.MobileSMS"
    static let slackApp = "com.tinyspeck.slackmacgap"

    // MARK: - what this Mac says, read once a welcome

    /// Nothing remembered yet: read off the main thread (it reads the
    /// memory's files), nil until it has been.
    private static var memoryEmpty: Bool?
    private static var defaultAtStart: Bool?
    private static var slackInstalled: Bool?
    private static var lookedAt: Date?

    /// Once as a welcome begins (a replay later reads again): the memory
    /// off the main thread, the default browser and Slack in place, each a
    /// moment's question to Launch Services.
    private static func look() {
        if let lookedAt, Date().timeIntervalSince(lookedAt) < 30 { return }
        lookedAt = Date()
        defaultAtStart = Links.isDefault
        slackInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: slackApp) != nil
        Task.detached(priority: .utility) {
            let empty = Memory.empty
            await MainActor.run { WelcomeEnd.learned(memoryEmpty: empty) }
        }
    }

    private static func learned(memoryEmpty empty: Bool) {
        guard empty != memoryEmpty else { return }
        memoryEmpty = empty
        WelcomeStage.shared.needsRefresh()
    }

    // MARK: - the words

    static func words(_ moment: WelcomeMoment, _ stage: WelcomeStage) -> WelcomeWords {
        switch moment.beat {
        case .access, .accessB:
            let path = stage.path
            let last = path.firstIndex(of: moment.beat).map { $0 + 1 < path.count && path[$0 + 1] == .finish } ?? !path.contains(.links)
            return WelcomeWords(title: moment.beat == .access ? helpsTitle : "Only what helps.",
                                sub: moment.beat == .access ? "Each one asks only when you press its button." : "It asks only when you press its button.",
                                primary: last ? "Start Browsing" : "Continue", quiet: "Not Now")
        case .links:
            let sub = slack(stage) ? "Make Yab your default browser, and links from Mail, Messages and Slack open here."
                : "Make Yab your default browser, and links from Mail and Messages open here."
            if stage.askedDefault { return WelcomeWords(title: linksTitle, sub: sub, primary: "Waiting for macOS", busy: true, quiet: "Not Now") }
            return WelcomeWords(title: linksTitle, sub: sub, primary: "Make Default", quiet: "Not Now")
        default:
            return WelcomeWords(frame: .finish, primary: nil)
        }
    }

    // MARK: - arriving and pressing

    static func arrive(_ moment: WelcomeMoment, _ stage: WelcomeStage) {
        switch moment.beat {
        case .access, .accessB:
            // The Google accounts signed in by now: the import has brought
            // its cookies. Each space's, as Settings › Mail finds them.
            if MailExperiment.enabled(), stage.pretend.calendar == nil, let browser = stage.browser {
                Task { await MailFound.shared.look(browser) }
            }
        case .finish:
            // Moved here, not a still frame of the bench: every held pref
            // first, so the real window lays itself out under the overlay
            // before anything moves.
            guard moment.from != nil else { return }
            stage.writeHeld()
            // Reduce Motion: one crossfade, the overlay's own, to the real window.
            if stage.reduceMotion {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard stage.beat == .finish else { return }
                    stage.close()
                }
            }
        default:
            break
        }
    }

    static func press(_ button: WelcomeButton, _ moment: WelcomeMoment, _ stage: WelcomeStage) -> WelcomeTurn {
        switch moment.beat {
        case .access, .accessB:
            // Continue turns the chapter; it never presses a card's button.
            return button == .quiet ? .chapter(6) : .next
        case .links:
            if button == .quiet { return .finish }
            makeDefault(stage)
            return .stay
        default:
            return .stay
        }
    }

    /// The context card's explicit, one-time Allow.
    static func allowContext(_ stage: WelcomeStage) {
        if stage.pretend.agents == nil, let browser = stage.browser {
            guard AgentSetupModel.shared.anyConnected else { return }
            browser.prefs.bench = true
            guard let session = ContextConsent.allow(), session.state.live else { return }
        }
        stage.suggesting = true
        stage.refresh()
    }

    /// Get to Know is on: turned on here, or already at work (a replay).
    private static func knowing(_ stage: WelcomeStage) -> Bool {
        stage.suggesting || (stage.pretend.agents == nil && Agents.shared.knowingRun != nil)
    }

    /// Connect: Google's page in a tab, the account found named to it so
    /// it has only the yes to ask; `another`, a page with Google's own
    /// choice of account. While Google still warns about Yab, the welcome
    /// steps aside first and the question says what to press there. The
    /// bench's Google says yes with a meeting, as the prototype's does.
    private static func connect(_ stage: WelcomeStage, another: Bool) {
        if stage.pretend.calendar != nil {
            stage.pretend.calendar = .connecting
            stage.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 * WelcomeMotion.pace) {
                guard stage.pretend.calendar == .connecting else { return }
                stage.pretend.calendar = .meeting
                stage.refresh()
            }
            return
        }
        guard let browser = stage.browser else { return }
        let pick = another ? nil : MailFound.shared.pick
        asking = Asking(face: pick.map { Face(email: $0.email, photo: $0.photo) }, before: MailCenter.shared.accounts)
        Task {
            if MailClient.underReview {
                stage.stepAside(for: .google, browser)
                guard await MailClient.warnFirst(place: .page) else {
                    asking = nil
                    stage.comeBack(browser)
                    return
                }
            }
            browser.prefs.usesMail = true
            if let pick { MailSettings.remember(pick) }
            MailCenter.shared.connect(in: browser, hint: pick?.email, space: pick?.space)
            // Connect may not have started (no client): back at once.
            if !MailCenter.shared.connecting {
                asking = nil
                stage.comeBack(browser)
            }
        }
    }

    /// Make Default: macOS's own dialog; the button waits on it. Yes goes
    /// on to Finish, no leaves Make Default as it was. The bench's macOS
    /// answers after a moment, as it said it would.
    private static func makeDefault(_ stage: WelcomeStage) {
        stage.askedDefault = true
        stage.defaultRefused = false
        let answered: (Bool) -> Void = { yes in
            guard stage.askedDefault else { return }
            stage.askedDefault = false
            guard stage.beat == .links else { return }
            if yes {
                stage.go(.finish)
            } else {
                stage.defaultRefused = true
                stage.refresh()
            }
        }
        if let pretended = stage.pretend.defaultBrowser {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3 * WelcomeMotion.pace) { answered(pretended != .no) }
        } else {
            Links.becomeDefault(answered)
        }
    }

    // MARK: - playing

    static func play(_ moment: WelcomeMoment, _ player: WelcomePlayer) async {
        switch moment.beat {
        case .links: await playLinks(moment, player)
        case .finish: await playFinish(moment, player)
        default: player.show()
        }
    }

    /// The link leaves the last app: it comes in beside it, lifts (1.04),
    /// travels on an arc to where its tab will be, and becomes the tab as
    /// the page turns to it.
    private static func playLinks(_ moment: WelcomeMoment, _ player: WelcomePlayer) async {
        player.show("arrive")
        guard await player.wait(0.52) else { return }
        if let layer = player.layer(for: "chip"), let from = player.frame(of: "chip"),
           let to = landing(player.stage) {
            let dx = to.minX - from.minX, dy = to.midY - from.midY
            let values = [CATransform3DIdentity, about(layer, scale: 1.04), about(layer, scale: 1.04, dx: dx / 2, dy: dy / 2 - 70),
                          about(layer, scale: 0.96, dx: dx, dy: dy)]
            let travel = WelcomeMotion.keyframes("transform", values: values.map { NSValue(caTransform3D: $0) }, times: [0, 0.15, 0.55, 1],
                                                 duration: 0.56, curve: .linear, on: layer, fill: .forwards)
            travel.timingFunction = WelcomeCurve.travel.function
            layer.add(travel, forKey: "travel")
            guard await player.wait(0.56) else { return }
        }
        player.show()
    }

    /// Where the link's tab will be once it has landed, in stage points.
    private static func landing(_ stage: WelcomeStage) -> CGRect? {
        let landed = windowToBe(stage, page: .launchNotes(landed: true))
        return ["y-launch", "y-plus"].lazy.compactMap { frame(of: $0, in: landed) }.first
    }

    /// Peak 3. On the Start Browsing path the window-to-be comes in first;
    /// then it grows into the real window's rect, the gaps closing and its
    /// corner relaxing to the window's 18, and lands with one firm haptic.
    private static func playFinish(_ moment: WelcomeMoment, _ player: WelcomePlayer) async {
        if player.frame(of: "wtb") == nil {
            player.show("enter")
            guard await player.wait(0.30) else { return }
        }
        player.show()
        relax(player)
        guard await player.wait(0.42) else { return }
        player.haptic(.levelChange)
        player.stage.close()
    }

    /// The window-to-be's corner from its own 18 to the window's 18 on
    /// screen, on the same glide as its bounds, rather than at once.
    private static func relax(_ player: WelcomePlayer) {
        let target = Radius.window / player.moment.scale
        guard abs(target - Radius.window) > 0.5, let part = player.layer(for: "wtb"),
              let plate = part.sublayers?.first(where: { $0.backgroundColor != nil && abs($0.cornerRadius - target) < 0.01 }) else { return }
        plate.add(WelcomeMotion.animation("cornerRadius", from: Radius.window, to: target, curve: .glide, duration: 0.34, on: plate), forKey: "relax")
    }

    /// A scale about a layer's middle and a move, as its transform.
    private static func about(_ layer: CALayer, scale: CGFloat, dx: CGFloat = 0, dy: CGFloat = 0) -> CATransform3D {
        let size = layer.bounds.size
        let middle = CGPoint(x: size.width * (0.5 - layer.anchorPoint.x), y: size.height * (0.5 - layer.anchorPoint.y))
        var transform = CATransform3DMakeTranslation(-middle.x, -middle.y, 0)
        transform = CATransform3DConcat(transform, CATransform3DMakeScale(scale, scale, 1))
        return CATransform3DConcat(transform, CATransform3DMakeTranslation(middle.x + dx, middle.y + dy, 0))
    }

    // MARK: - the boards

    static func board(_ moment: WelcomeMoment, _ stage: WelcomeStage) -> WelcomeBoard {
        switch moment.beat {
        case .access: return cards(moment, stage)
        case .accessB: return alone(stage)
        case .links: return links(moment, stage)
        default: return finish(moment, stage)
        }
    }

    // MARK: chapter 5, two cards

    /// The two cards: 356 wide, 16 apart, centered, their tops at 312,
    /// one height, hugging the taller one's content.
    fileprivate enum Cards {
        static let width: CGFloat = 356
        static let top: CGFloat = 312
        static let know = CGRect(x: 226, y: top, width: width, height: 0)
        static let google = CGRect(x: 598, y: top, width: width, height: 0)
        /// The words' column beside the tile.
        static let words = width - 2 * CardFrame.inset - CardFrame.well - CardFrame.wellGap
        static let titleLine: CGFloat = 20
        static let detailLine: CGFloat = 18
        static let point: CGFloat = 24
        static let lock: CGFloat = 14
        static let foot = ButtonSize.regular.height

        static let knowDetail = "Reads your browsing history and the sites you’re signed in to."
        static let knowFoot = "About ten minutes. Inspect or clear it in AI › Memory."
        static let googleDetail = "One Allow at Google, and Yab has your mail and meetings."
        static let points: [(glyph: String, words: String)] = [
            (glyph: "pencil", words: "Page text goes to your connected AI"),
            (glyph: "quote.bubble", words: "Nothing is sent or posted to those sites"),
            (glyph: "hand.raised", words: "Optional. Choose Allow to start"),
        ]
        static let googlePoints: [(glyph: String, words: String)] = WelcomeEnd.gains.map { ($0.glyph, $0.point) }

        /// What sets lines of 13 18 apart, as the prototype sets a detail.
        static let leading: CGFloat = {
            let font = NSFont.systemFont(ofSize: 13)
            return detailLine - (font.ascender - font.descender + font.leading)
        }()

        /// How many lines the words take at this width.
        static func lines(_ text: String, size: CGFloat, width: CGFloat) -> Int {
            let font = NSFont.systemFont(ofSize: size)
            let height = (text as NSString).boundingRect(with: CGSize(width: width, height: 1000), options: [.usesLineFragmentOrigin],
                                                         attributes: [.font: font]).height
            return max(1, Int((height / NSLayoutManager().defaultLineHeight(for: font)).rounded()))
        }

        /// A detail's height in the words' column.
        static func detail(_ text: String) -> CGFloat { CGFloat(lines(text, size: 13, width: words)) * detailLine }

        /// The foot line's height in Get to Know: its words, beside the lock
        /// and Turn On, in lines 16 apart, or the button's height.
        static let knowFootHeight: CGFloat = {
            let turnOn = 2 * ButtonSize.regular.padding + ("Turn On" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: CardFrame.words)]).width
            let room = width - 2 * CardFrame.inset - lock - 2 * 8 - turnOn
            return max(foot, CGFloat(lines(knowFoot, size: 12, width: room)) * 16)
        }()

        /// Get to Know's content, top to bottom: the title beside the tile,
        /// the detail, the three points; then the foot.
        static let knowHeight: CGFloat = CardFrame.inset + max(CardFrame.well, titleLine + 2 + detail(knowDetail) + 10 + CGFloat(points.count) * point)
            + CardFrame.inset + knowFootHeight + CardFrame.inset

        /// Google's, as Get to Know's: the title, the detail, three points;
        /// then its one-line foot.
        static let googleHeight: CGFloat = CardFrame.inset + max(CardFrame.well, titleLine + 2 + detail(googleDetail) + 10 + CGFloat(googlePoints.count) * point)
            + CardFrame.inset + foot + CardFrame.inset

        static let height = max(knowHeight, googleHeight)
    }

    /// The token of the beat whose cards last dropped the lock's shackle:
    /// once as the card lands, not on every refresh after.
    private static var shackleDropped: Int?

    private static func cards(_ moment: WelcomeMoment, _ stage: WelcomeStage) -> WelcomeBoard {
        let height = Cards.height
        let on = knowing(stage)
        let step = google(stage)

        var know = StagePart.view("card-know", Cards.know.with(height: height), enter: .rise, takesClicks: true) {
            HelpsKnowCard(on: on) { allowContext(stage) }
        }
        // The lock: two opaque shapes of its own, its shackle dropping and
        // closing once as the card lands.
        let drop = !stage.reduceMotion && moment.from != nil && shackleDropped != stage.playing
        if drop { shackleDropped = stage.playing }
        let appearance = stage.view.effectiveAppearance
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var colors = (ink: Palette.NS.ink.cgColor, ground: Palette.NS.ground.cgColor)
        appearance.performAsCurrentDrawingAppearance { colors = (Palette.NS.ink.cgColor, Palette.NS.ground.cgColor) }
        let (ink, ground) = colors
        let pace = WelcomeMotion.pace
        know.children = [
            StagePart(dark ? "know-lock-dark" : "know-lock",
                      CGRect(x: CardFrame.inset, y: height - CardFrame.inset - Cards.knowFootHeight / 2 - Cards.lock / 2, width: Cards.lock, height: Cards.lock),
                      drawing: .layer({ HelpsLockLayer(ink: ink, ground: ground, drop: drop ? 0.30 : nil, pace: pace) })),
        ]

        if !MailExperiment.enabled(), stage.pretend.calendar == nil {
            know.frame.origin.x = (StageSpace.size.width - Cards.width) / 2
            return WelcomeBoard([know])
        }
        let card = StagePart.view("card-google", Cards.google.with(height: height), enter: .rise, delay: 0.06, takesClicks: true) {
            HelpsGoogleCard(step: step) { connect(stage, another: false) }
        }
        return WelcomeBoard([know, card])
    }

    // MARK: chapter 5, Google alone

    /// Google as a hero of its own: the account's face, what it brings in
    /// three tiles, Connect. Once in, the face wears a tick and the meeting
    /// tile says when the next one is.
    private static func alone(_ stage: WelcomeStage) -> WelcomeBoard {
        let step = google(stage)
        let width = StageSpace.size.width
        return WelcomeBoard([
            .view("g-face", CGRect(x: (width - 72) / 2, y: 262, width: 72, height: 72), enter: .drop) {
                GoogleFace(face: step.face, done: step.phase == .connected, side: 72)
            },
            .view("g-t:" + step.title, CGRect(x: 0, y: 354, width: width, height: 46), enter: .up6, delay: 0.06) {
                VStack(spacing: 6) {
                    Text(step.title).font(.system(size: 17, weight: .medium)).frame(height: 22)
                    Text(step.sub(WelcomeYours.broughtFrom(stage)?.name)).font(.system(size: 13)).foregroundStyle(Palette.muted)
                        .frame(height: Cards.detailLine)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            },
            .view("g-gains", CGRect(x: (width - 380) / 2, y: 424, width: 380, height: 64), enter: .up6, delay: 0.1) {
                GoogleGains(meeting: step.meeting, on: step.phase == .connected)
            },
            .view("g-act:" + step.phase.rawValue, CGRect(x: 0, y: 516, width: width, height: ButtonSize.large.height),
                  enter: .fade, delay: 0.14, takesClicks: step.phase != .connected) {
                GoogleActions(step: step, connect: { connect(stage, another: false) }, another: { connect(stage, another: true) })
            },
        ])
    }

    // MARK: Google's answer

    /// An account as the welcome shows it: its address and Google's photo.
    struct Face: Equatable {
        let email: String
        let photo: URL?
    }

    /// Connect pressed: for whom, and the accounts there were, so the
    /// answer is known when a new one comes in (Google's tab closes a moment
    /// before the account is read).
    private struct Asking {
        let face: Face?
        let before: [String]
    }

    private static var asking: Asking?
    /// The account the welcome connected, shown as the one in after.
    private static var justConnected: String?

    /// What the three tiles say, and the points in Google's card.
    nonisolated static let gains: [(glyph: String, tile: String, point: String, tint: NSColor)] = [
        (glyph: "envelope", tile: "Mail, sorted", point: "Mail, sorted before you open it", tint: .systemBlue),
        (glyph: "calendar", tile: "Next meeting", point: "Your next meeting beside your tabs", tint: .systemRed),
        (glyph: "number", tile: "Codes filled", point: "Codes from mail, filled for you", tint: .systemGreen),
    ]

    struct GoogleStep: Equatable {
        enum Phase: String { case ask, asking, failed, connected, unavailable }
        var phase: Phase
        /// The account Connect is for, or the one connected.
        var face: Face?
        /// Another account found signed in, left for Settings › Mail.
        var other: String?
        /// The next meeting, in words: "In 25m", "Tomorrow 8:00".
        var meeting: String?

        var title: String {
            switch phase {
            case .connected: return "\(face?.email ?? "Google") is in."
            case .asking: return "Allow Yab in Google."
            case .ask, .failed, .unavailable:
                return face.map { "Bring \($0.email) into Yab." } ?? "Bring your Google account into Yab."
            }
        }

        func sub(_ browser: String?) -> String {
            switch phase {
            case .connected:
                return other.map { "Add \($0) any time in Settings › Mail." } ?? "Your mail, your meetings and your codes are here."
            case .asking: return "Google’s page is open in a tab."
            case .failed: return "Google didn’t give Yab access. Nothing was read."
            case .unavailable: return "This build of Yab can’t connect to Google."
            case .ask:
                guard face != nil else { return "You sign in once in a tab, then Allow." }
                return browser.map { "The Google account you use in \($0). One Allow at Google." } ?? "Signed in in Yab already. One Allow at Google."
            }
        }
    }

    /// Google as it stands: the bench's, or the accounts found and
    /// connected, and Connect's answer.
    static func google(_ stage: WelcomeStage) -> GoogleStep {
        if let pretended = stage.pretend.calendar {
            let face = Face(email: "jamie.lee@gmail.com", photo: nil)
            switch pretended {
            case .not: return GoogleStep(phase: .ask, face: face)
            case .connecting: return GoogleStep(phase: .asking, face: face)
            case .meeting: return GoogleStep(phase: .connected, face: face, other: "jamie@studio.com", meeting: "In 25m")
            case .empty: return GoogleStep(phase: .connected, face: face)
            case .denied: return GoogleStep(phase: .failed, face: face)
            }
        }
        let center = MailCenter.shared
        let found = MailFound.shared
        if let asking {
            // A new account in: the one just connected.
            if let account = center.accounts.first(where: { !asking.before.contains($0) }) {
                self.asking = nil
                justConnected = account
                return connected(account, stage)
            }
            if center.connectFailed { return GoogleStep(phase: .failed, face: asking.face) }
            return GoogleStep(phase: .asking, face: asking.face)
        }
        // A replay, or connected before the welcome: shown as done.
        if let account = justConnected.flatMap({ center.accounts.contains($0) ? $0 : nil }) ?? center.accounts.first {
            return connected(account, stage)
        }
        guard MailClient.configured != nil else { return GoogleStep(phase: .unavailable) }
        let face = found.pick.map { Face(email: $0.email, photo: $0.photo) }
        return GoogleStep(phase: center.connectFailed ? .failed : .ask, face: face)
    }

    private static func connected(_ account: String, _ stage: WelcomeStage) -> GoogleStep {
        let photo = Store.settings.string(forKey: "mail.photo.\(account)").flatMap(URL.init(string:))
        let other = MailFound.shared.accounts.first { $0.email != account }?.email
        return GoogleStep(phase: .connected, face: Face(email: account, photo: photo), other: other, meeting: nextMeeting())
    }

    /// The next meeting, today's or tomorrow's, in words.
    private static func nextMeeting() -> String? {
        let now = Date()
        guard let meeting = Meetings.shared.list.first(where: { $0.end > now }) else { return nil }
        if meeting.start <= now { return "Now" }
        if Calendar.current.isDateInToday(meeting.start) {
            let words = until(meeting.start, from: now)
            return words.prefix(1).uppercased() + words.dropFirst()
        }
        guard Calendar.current.isDateInTomorrow(meeting.start) else { return nil }
        return "Tomorrow " + meeting.start.englishFormatted(date: .omitted, time: .shortened)
    }

    /// How long until it starts, in words: "in 25m", "in 2h 10m", "now".
    static func until(_ start: Date, from now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "in \(hours)h" : "in \(hours)h \(rest)m"
    }

    private static func width(_ text: String, _ size: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width
    }

    // MARK: chapter 6

    /// Where the window-to-be stands in chapter 6.
    private static let linksFrame = CGRect(x: 278, y: 160, width: 752, height: 526)

    private static func links(_ moment: WelcomeMoment, _ stage: WelcomeStage) -> WelcomeBoard {
        var apps: [(key: String, bundle: String)] = [(key: "mail", bundle: mailApp), (key: "messages", bundle: messagesApp)]
        if slack(stage) { apps.append((key: "slack", bundle: slackApp)) }
        // A column of the Mac's own icons, centered on the window-to-be.
        let top = linksFrame.midY - (CGFloat(apps.count) * 96 - 32) / 2
        var parts: [StagePart] = apps.enumerated().map { index, app in
            WelcomeParts.mark("app-" + app.key, CGRect(x: 150, y: top + CGFloat(index) * 96, width: 64, height: 64), .app(app.bundle),
                              enter: .drop, delay: Double(index) * 0.04)
        }
        let arriving = moment.phase == "arrive"
        parts.append(windowToBe(stage, page: .launchNotes(landed: !arriving)))
        if arriving {
            // The link, out of the last app, level with its middle.
            let y = top + CGFloat(apps.count - 1) * 96 + 18
            let chip = ceil(2 * ButtonSize.regular.padding + 12 + 6 + width(LinksChip.words, CardFrame.words))
            parts.append(.view("chip", CGRect(x: 196, y: y, width: chip, height: ButtonSize.regular.height), enter: .fade, delay: 0.22, exit: .fastFade) {
                LinksChip()
            })
        }
        return WelcomeBoard(parts, exits: ["chip": .fastFade])
    }

    /// The window-to-be in your look, as chapter 6 has it.
    private static func windowToBe(_ stage: WelcomeStage, page: WelcomeWindowPage) -> StagePart {
        WelcomeParts.windowToBe("wtb", linksFrame, look: WelcomeYours.windowLook(stage), yours: WelcomeYours.yours(stage), page: page, enter: .grow94)
    }

    /// A key's rect in stage points, inside a part not yet on the stage.
    private static func frame(of key: String, in part: StagePart, origin: CGPoint = .zero) -> CGRect? {
        let here = part.frame.offsetBy(dx: origin.x, dy: origin.y)
        if part.key == key { return here }
        for child in part.children {
            if let found = frame(of: key, in: child, origin: here.origin) { return found }
        }
        return nil
    }

    // MARK: Finish

    private static func finish(_ moment: WelcomeMoment, _ stage: WelcomeStage) -> WelcomeBoard {
        // Reduce Motion: nothing grows; the overlay's crossfade is the move.
        guard !stage.reduceMotion else { return WelcomeBoard() }
        let look = WelcomeYours.windowLook(stage), yours = WelcomeYours.yours(stage)
        let page: WelcomeWindowPage = stage.path.contains(.links) ? .launchNotes(landed: true) : .newTab
        if moment.phase == "enter" {
            // The Start Browsing path: in first, in the middle, then it grows.
            let rect = CGRect(x: (StageSpace.size.width - linksFrame.width) / 2, y: linksFrame.minY, width: linksFrame.width, height: linksFrame.height)
            return WelcomeBoard([WelcomeParts.windowToBe("wtb", rect, look: look, yours: yours, page: page, enter: .grow94)])
        }
        // The real window's own rect, in stage points, its corner 18 on screen.
        let window = moment.window
        let rect = StageSpace.toStage(CGRect(origin: .zero, size: window), in: window)
        return WelcomeBoard([
            WelcomeParts.windowToBe("wtb", rect, look: look, yours: yours, page: page, corner: Radius.window / moment.scale, flat: true, enter: .grow94),
        ])
    }
}

private extension CGRect {
    func with(height: CGFloat) -> CGRect { CGRect(x: minX, y: minY, width: width, height: height) }
}

// MARK: - the cards' faces

/// Get to Know: its tile, what it does, three points, and the foot line
/// with the lock (a part of its own, over the room left for it) and Turn On,
/// or "On" once it is.
private struct HelpsKnowCard: View {
    typealias Cards = WelcomeEnd.Cards
    let on: Bool
    let turnOn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: CardFrame.wellGap) {
                FeatureTile(icon: "sparkles", tint: .systemPurple, side: CardFrame.well)
                VStack(alignment: .leading, spacing: 0) {
                    Text("A one-time read, about ten minutes.").font(CardFrame.title).lineLimit(1).frame(height: Cards.titleLine)
                    HelpsDetail(text: Cards.knowDetail)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Cards.points.indices, id: \.self) { index in
                            HStack(spacing: 10) {
                                Symbol(Cards.points[index].glyph, size: 14 / Glyphs.scale).foregroundStyle(Palette.muted)
                                Text(Cards.points[index].words).font(.system(size: 13))
                            }
                            .frame(height: Cards.point)
                        }
                    }
                    .padding(.top, 10)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                // The lock's room: the lock is drawn by the stage.
                Color.clear.frame(width: Cards.lock, height: Cards.lock)
                Text(Cards.knowFoot)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineSpacing(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if on {
                    Text("On").font(.system(size: 12.5)).foregroundStyle(Palette.muted).padding(.trailing, 6)
                } else {
                    Button("Allow", action: turnOn).buttonStyle(.yab(.secondary, .regular))
                }
            }
            .frame(height: Cards.knowFootHeight)
        }
        .foregroundStyle(Palette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardFrame()
    }
}

/// Google: the account's face, what it brings in three points, and the
/// foot: the account and Connect, or where it got to.
private struct HelpsGoogleCard: View {
    typealias Cards = WelcomeEnd.Cards
    let step: WelcomeEnd.GoogleStep
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: CardFrame.wellGap) {
                GoogleFace(face: step.face, done: step.phase == .connected, side: CardFrame.well)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Bring in your Google account.").font(CardFrame.title).lineLimit(1).frame(height: Cards.titleLine)
                    HelpsDetail(text: Cards.googleDetail)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Cards.googlePoints.indices, id: \.self) { index in
                            HStack(spacing: 10) {
                                Symbol(Cards.googlePoints[index].glyph, size: 14 / Glyphs.scale).foregroundStyle(Palette.muted)
                                Text(Cards.googlePoints[index].words).font(.system(size: 13))
                            }
                            .frame(height: Cards.point)
                        }
                    }
                    .padding(.top, 10)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Text(foot)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                switch step.phase {
                case .ask: Button(step.face == nil ? "Sign In" : "Connect", action: connect).buttonStyle(.yab(.secondary, .regular))
                case .failed: Button("Try Again", action: connect).buttonStyle(.yab(.secondary, .regular))
                case .connected: Text("Connected").font(.system(size: 12.5)).foregroundStyle(Palette.muted).padding(.trailing, 6)
                case .asking, .unavailable: EmptyView()
                }
            }
            .lineLimit(1)
            .frame(height: Cards.foot)
        }
        .foregroundStyle(Palette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardFrame()
    }

    private var foot: String {
        switch step.phase {
        case .ask: return step.face?.email ?? "You sign in once in a tab."
        case .asking: return "Google’s page is open in a tab."
        case .failed: return "Google didn’t give Yab access."
        case .connected: return step.face?.email ?? ""
        case .unavailable: return "This build can’t connect to Google."
        }
    }
}

/// A card's detail: 13 muted, its lines 18 apart as the prototype sets
/// them, in the height they take.
private struct HelpsDetail: View {
    let text: String

    var body: some View {
        Text(text)
            .font(CardFrame.detail)
            .foregroundStyle(Palette.muted)
            .lineSpacing(WelcomeEnd.Cards.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: WelcomeEnd.Cards.detail(text), alignment: .leading)
    }
}

/// Google's own marks as of 2026, shipped in Resources/Google: Gmail, the
/// G, and Calendar's, one a day of the month, today's shown as Google's own.
enum GoogleMarks {
    static let gmail = load("gmail", in: "Google")
    static let g = load("g", in: "Google")
    static var calendar: NSImage? { load(String(Calendar.current.component(.day, from: Date())), in: "Google/calendar") }

    private static func load(_ name: String, in folder: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "png", subdirectory: folder).flatMap(NSImage.init(contentsOf:))
    }
}

/// An account's face: Google's photo, or its first letter in white on a
/// color of its own; Google's G at its corner on a white plate, or a tick
/// once it is in. A plain one for an account not known yet.
private struct GoogleFace: View {
    let face: WelcomeEnd.Face?
    let done: Bool
    let side: CGFloat

    /// The faces' colors, one an address, as Google's own letter faces.
    private static let hues: [NSColor] = [
        NSColor(srgbRed: 0.31, green: 0.42, blue: 0.93, alpha: 1),
        NSColor(srgbRed: 0.12, green: 0.62, blue: 0.45, alpha: 1),
        NSColor(srgbRed: 0.85, green: 0.34, blue: 0.17, alpha: 1),
        NSColor(srgbRed: 0.54, green: 0.36, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.76, green: 0.25, blue: 0.48, alpha: 1),
    ]

    var body: some View {
        let badge = (side / 3).rounded()
        Group {
            if let face {
                let hue = Self.hues[face.email.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % Self.hues.count]
                ZStack {
                    Circle().fill(Color(nsColor: hue))
                    Text(String(face.email.first.map { $0.uppercased() } ?? "?"))
                        .font(.system(size: (side * 0.39).rounded(), weight: .semibold)) // design: a face's letter, at the face's size
                        .foregroundStyle(.white)
                    if let photo = face.photo {
                        AsyncImage(url: photo) { image in image.resizable().interpolation(.high) } placeholder: { Color.clear }
                    }
                }
                .frame(width: side, height: side)
                .clipShape(Circle())
            } else {
                Symbol("person", size: side * 0.42)
                    .foregroundStyle(Palette.muted)
                    .frame(width: side, height: side)
                    .background(Circle().fill(Palette.ink.opacity(0.06)))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Group {
                if done {
                    Symbol("checkmark", size: badge * 0.5, weight: .bold)
                        .foregroundStyle(.white)
                        .frame(width: badge, height: badge)
                        .background(Circle().fill(Color.green))
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                } else {
                    Group {
                        if let g = GoogleMarks.g {
                            Image(nsImage: g).resizable().interpolation(.high).frame(width: badge * 0.62, height: badge * 0.62)
                        } else {
                            Text("G").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.ink)
                        }
                    }
                    .frame(width: badge, height: badge)
                    .background(Circle().fill(WelcomeParts.chip))
                    .overlay(Circle().strokeBorder(WelcomeParts.ring, lineWidth: 0.5))
                }
            }
            .offset(x: 2, y: 2)
        }
        .animation(.snappy(duration: 0.24, extraBounce: 0), value: done)
        .accessibilityHidden(true)
    }
}

/// What one Allow at Google brings: Gmail's, Calendar's and a code's marks
/// on white plates, their words under them; once in, the meeting's says
/// when the next one is.
private struct GoogleGains: View {
    let meeting: String?
    let on: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ForEach(WelcomeEnd.gains.indices, id: \.self) { index in
                VStack(spacing: 6) {
                    plate(index)
                    Text(index == 1 && on ? meeting ?? "None soon" : WelcomeEnd.gains[index].tile)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(minWidth: 88)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func plate(_ index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.surface, style: .continuous)
        return Group {
            switch (index, index == 0 ? GoogleMarks.gmail : GoogleMarks.calendar) {
            case (0...1, let mark?): Image(nsImage: mark).resizable().interpolation(.high).frame(width: 20, height: 20)
            // A code as a site mails it: four digits on a plate of their own.
            case (2, _):
                Text("4821")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 2)
                    .frame(height: 16)
                    .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Palette.ink.opacity(0.07)))
            default: Symbol(WelcomeEnd.gains[index].glyph, size: 18).foregroundStyle(Palette.muted)
            }
        }
        .frame(width: 40, height: 40)
        .background(shape.fill(WelcomeParts.chip))
        .overlay(shape.strokeBorder(WelcomeParts.ring, lineWidth: 0.5))
    }
}

/// Google alone's end: Connect and Another Account, Try Again, or nothing
/// once it is in (Continue is the frame's).
private struct GoogleActions: View {
    let step: WelcomeEnd.GoogleStep
    let connect: () -> Void
    let another: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch step.phase {
            case .ask:
                if step.face == nil {
                    Button("Sign In to Google", action: another).buttonStyle(.yab(.primary, .large))
                } else {
                    Button("Connect", action: connect).buttonStyle(.yab(.primary, .large))
                    Button("Another Account", action: another).buttonStyle(.yab(.quiet, .large))
                }
            case .failed:
                Button("Try Again", action: step.face == nil ? another : connect).buttonStyle(.yab(.primary, .large))
            case .asking, .connected, .unavailable:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The link on its way from another app: the glass chip, `link` and the
/// page's name. A picture of a link, not a button: nothing presses it.
private struct LinksChip: View {
    static let words = "Launch notes"

    var body: some View {
        Button {} label: {
            HStack(spacing: 6) {
                Symbol("link", size: 12 / Glyphs.scale).foregroundStyle(Palette.muted)
                Text(Self.words)
            }
        }
        .buttonStyle(.yab(.glass, .regular))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - the lock

/// Get to Know's lock, 14: its body and its shackle, two opaque shapes (a
/// see-through stroke shows where the two overlap). Made as its card comes
/// in, the shackle open, it drops and closes once, 0.28 s, as the card lands.
private final class HelpsLockLayer: CALayer {
    private let body = CAShapeLayer()
    private let shackle = CAShapeLayer()
    /// When the shackle drops, in media time, and the welcome's pace then.
    private var drop: (at: CFTimeInterval, pace: Double)?

    init(ink: CGColor, ground: CGColor, drop delay: Double?, pace: Double) {
        super.init()
        for shape in [body, shackle] {
            shape.strokeColor = ink
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.contentsScale = 3
            addSublayer(shape)
        }
        body.fillColor = ground
        shackle.fillColor = nil
        drop = delay.map { (at: CACurrentMediaTime() + $0 * pace, pace: pace) }
        setNeedsLayout()
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    /// Drawn in the icon's 24 grid, which way up the layer's points run.
    override func layoutSublayers() {
        super.layoutSublayers()
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        let k = side / 24
        let down = contentsAreFlipped()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: down ? y * k : side - y * k) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.frame = bounds
        shackle.frame = bounds
        body.lineWidth = 2 * k
        shackle.lineWidth = 2 * k
        let box = CGRect(x: 5 * k, y: down ? 10 * k : side - 20 * k, width: 14 * k, height: 10 * k)
        body.path = CGPath(roundedRect: box, cornerWidth: 2.5 * k, cornerHeight: 2.5 * k, transform: nil)
        let arch = CGMutablePath()
        arch.move(to: point(8, 10))
        arch.addLine(to: point(8, 7.5))
        arch.addCurve(to: point(12, 3.5), control1: point(8, 5.29086), control2: point(9.79086, 3.5))
        arch.addCurve(to: point(16, 7.5), control1: point(14.2091, 3.5), control2: point(16, 5.29086))
        arch.addLine(to: point(16, 10))
        shackle.path = arch
        CATransaction.commit()

        guard let drop else { return }
        self.drop = nil
        // Up 4 of the grid, down past closed, back 1, closed.
        let up = (down ? -4 : 4) * k
        let fall = CAKeyframeAnimation(keyPath: "transform.translation.y")
        fall.values = [up, 0, up / 4, 0]
        fall.keyTimes = [0, 0.6, 0.8, 1]
        fall.duration = 0.28
        fall.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fall.speed = Float(1 / drop.pace)
        fall.beginTime = shackle.convertTime(drop.at, from: nil)
        fall.fillMode = .backwards
        shackle.add(fall, forKey: "drop")
    }
}
