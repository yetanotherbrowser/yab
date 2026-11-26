import JavaScriptCore
import SwiftUI

// An agent in your own tabs, and the few presses it waits on you for.
//
// An agent may act in a tab of yours as it does in its own: the face comes
// on at the tab's end while it works there, a click or a key of yours takes
// the wheel (AgentFeed.drive), and the tab stays yours: where it was, in
// your history, never tidied away with the agent's. Settings › Agents says
// how far: Yes, Ask first (once per tab and task), or Read only.
//
// Wherever it is, a button that sends, posts, pays or deletes isn't
// pressed by the agent: its face turns into the hand and a card hangs from
// the tab with that button's own word on it. Your yes presses it, once.
// The card is a sign-in's card with other words (Tab.handoff holds them
// meanwhile), so the row lifts, the corner calls and the dock steps aside
// exactly as they do for a sign-in.

/// How much an agent asks you first, the way Claude Code's own modes go.
/// Ask: before working in a tab of yours, using this Mac, and anything that leaves
/// or costs. Auto: only before sending, paying, deleting, uploading a file
/// or reading Messages, and before using this Mac. Bypass: never; it does it all itself.
///
/// Whatever the mode, a password is never shown to it, a file never comes
/// from a hidden folder or the keychain, the tab in front of you is never
/// sent elsewhere, and a click of yours takes over. A captcha, a passkey,
/// a site with no saved password are always yours: no agent can do those.
enum AgentAsking: String, CaseIterable {
    case ask, auto, bypass

    var title: String {
        switch self {
        case .ask: return "Ask"
        case .auto: return "Auto"
        case .bypass: return "Bypass"
        }
    }

    var detail: String {
        switch self {
        case .ask: return "Asks before using your tabs or Mac, signing in, and anything it sends, pays, deletes or uploads."
        case .auto: return "Asks before using your Mac, or sending, paying, deleting or uploading your files."
        case .bypass: return "Never asks, including for Mac access. Captchas and passkeys are still yours."
        }
    }
}

struct AgentPermit: Equatable {
    enum Kind: Equatable {
        /// To give this task files and terminal access on the Mac.
        case computer
        /// To act in this tab of yours at all.
        case use
        /// To press this: its words, as the page has them ("Send").
        case press(label: String, ref: String)
        /// To give these files from your Mac to the page, through what ref
        /// opens.
        case upload(files: [URL], ref: String)
        /// To sign in here with a password yab keeps: one of these names.
        case signIn(host: String, users: [String])
        /// To type a connected password manager's kept unlock password into
        /// its own unlock page (unlock_manager).
        case unlockManager(provider: String)
        /// To read the latest code from Messages.
        case messages
        /// To send this text through Messages to someone: the text is the draft.
        case sendMessage(to: String)
        /// To send this mail from yab's mail page (mail_send): whom, in
        /// words, and what the yes is for (MailAgent.Outgoing.key); its
        /// words are the draft, its addresses and subject the detail.
        case sendMail(to: String, mail: String)
        /// To send these mails together (mail_send's mails): how many, and
        /// what the one yes is for (every mail's key); the draft lists each
        /// one's addresses and words.
        case sendMails(count: Int, mail: String)
        /// To search and read the person's mail beyond what they gave the
        /// chat, once a chat (Bench.mailAsks); the detail says what it looks for.
        case mailRead
        /// To change mail this way for the rest of the chat: its word
        /// ("Archive") and mail_act's act or the label change it is for.
        case mailChange(label: String, act: String)
        /// To go to a site the person has never been to, in a chat that read
        /// their mail (Bench.mailLeaves): prompt injection's way out.
        case mailSite(host: String)
        /// To fill a kept address into this site's form (Autofill).
        case address(host: String)
        /// A native effect bound to one journalled operation, approved in Yab.
        case native(label: String, operation: String)
        /// To keep this SKILL.md for every later task (skill_save): its
        /// name, and the yes bound to its exact words (SkillWriter.key).
        case saveSkill(name: String, key: String)
        /// To open a folder macOS keeps closed, or choose the file instead
        /// (FolderAccess).
        case folder(FolderAsk)
    }

    let kind: Kind
    /// Monotonic arrival order, unaffected by a wall-clock correction.
    let askOrder = DispatchTime.now().uptimeNanoseconds
    let session: String
    /// A line beside the question: what for, or to whom.
    let detail: String
    /// What a Send would send, when it can be read off the page.
    var draft: String = ""
    /// What a payment comes to, as the page says it ("$42.10"), when it does.
    var amount: String = ""
    /// A payment however it is labeled: the press sends a form that takes
    /// a card, Continue or Next included.
    var pays = false
    /// Asked of another app's agent, whose yes to reading mail covers its
    /// whole session, every connection of it (Agents.mailGrants): the yes
    /// says so.
    var forSession = false

    // Arrival is presentation metadata. Cause matching deliberately rebuilds
    // a permit, so its fresh clock value must not create a different question.
    static func == (left: AgentPermit, right: AgentPermit) -> Bool {
        left.kind == right.kind && left.session == right.session && left.detail == right.detail
            && left.draft == right.draft && left.amount == right.amount && left.pays == right.pays
            && left.forSession == right.forSession
    }

    /// The press a rule can be kept for, Always here or Never here: not a
    /// payment, not a sign-in, not Messages.
    var ruleLabel: String? {
        switch kind {
        case .press(let label, _): return pays || AgentRules.paying(label) ? nil : label
        case .upload: return "Upload"
        default: return nil
        }
    }

    var question: String {
        switch kind {
        case .computer: return "Let this task use your Mac?"
        case .use: return "Use this tab?"
        // "Pay $12.00" says its amount already: not twice.
        case .press(let label, _): return amount.isEmpty || label.contains(amount) ? "\(label)?" : "\(label) · \(amount)?"
        case .upload(let files, _):
            let names = files.map(\.lastPathComponent)
            return names.count == 1 ? "Upload \(names[0])?" : "Upload \(names.count) files?"
        case .signIn(let host, _): return "Sign in to \(host)?"
        case .unlockManager(let provider): return "Unlock \(PasswordManagers.name(provider))?"
        case .messages: return "Read the code from Messages?"
        case .sendMessage(let to): return "Send to \(to)?"
        case .sendMail(let to, _): return "Send this mail to \(to)?"
        case .sendMails(let count, _): return "Send these \(count) mails?"
        case .mailRead: return "Search your mail?"
        case .mailChange(_, let act): return Bench.changeWords(act).question
        case .mailSite(let host): return "Go to \(host)?"
        case .address(let host): return "Fill your address on \(host)?"
        case .native(let label, _): return "\(label)?"
        case .saveSkill(let name, _): return "Save the skill \(name)?"
        case .folder(let ask): return ask.question
        }
    }

    /// The yes, or for a sign-in with several names, a yes for each.
    struct Answer: Hashable {
        let title: String
        var user: String? = nil
    }

    /// A yes that can't be taken back, something sent, paid, deleted or
    /// posted, a file given away, Messages read: it takes ⌘↩, never a bare
    /// Return that was meant for the page.
    var weighty: Bool {
        switch kind {
        case .computer, .press, .upload, .messages, .sendMessage, .sendMail, .sendMails, .native, .saveSkill: return true
        case .use, .signIn, .unlockManager, .address, .folder, .mailRead, .mailChange, .mailSite: return false
        }
    }

    var answers: [Answer] {
        switch kind {
        case .computer: return [Answer(title: "Allow Mac access")]
        case .use: return [Answer(title: "Allow")]
        case .press(let label, _): return [Answer(title: label)]
        case .upload: return [Answer(title: "Upload")]
        case .signIn(_, let users):
            if users.count == 1 { return [Answer(title: "Sign in", user: users[0])] }
            return users.prefix(3).map { Answer(title: $0, user: $0) }
        case .unlockManager: return [Answer(title: "Unlock")]
        case .messages: return [Answer(title: "Read")]
        case .sendMessage, .sendMail: return [Answer(title: "Send")]
        case .sendMails: return [Answer(title: "Send All")]
        case .mailRead: return [Answer(title: forSession ? "Allow for This Session" : "Search")]
        case .mailChange(let label, _): return [Answer(title: label)]
        case .mailSite: return [Answer(title: "Go")]
        case .address: return [Answer(title: "Fill")]
        case .native(let label, _): return [Answer(title: label)]
        case .saveSkill: return [Answer(title: "Save")]
        case .folder(let ask):
            // The last is the one Return gives.
            let choose = Answer(title: "Choose File", user: "choose"), settings = Answer(title: "Open Settings", user: "settings")
            if ask.stage == .checking { return [] }
            return ask.choosing ? [settings, choose] : [choose, settings]
        }
    }

    /// What the yes is kept under in Tab.approved, for the call to find
    /// when it comes again.
    var key: String {
        switch kind {
        case .computer: return "computer"
        case .use: return "use"
        case .press(_, let ref): return ref
        case .upload(_, let ref): return "upload:" + ref
        case .signIn(let host, _): return "signin:" + host
        case .unlockManager(let provider): return "unlock:" + provider
        case .messages: return "messages"
        case .sendMessage(let to): return "imessage:" + to
        case .sendMail(_, let mail): return "mail:" + mail
        case .sendMails(_, let mail): return "mails:" + mail
        case .mailRead: return "mail.read"
        case .mailChange(_, let act): return "mail.change:" + act
        case .mailSite(let host): return "mail.site:" + host
        case .address(let host): return "address:" + host
        case .native(_, let operation): return "native:" + operation
        case .saveSkill(_, let key): return key
        case .folder(let ask): return "folder:" + ask.path
        }
    }
}

extension Agents {
    /// The person approves this exact mail once, in every mode: Bypass too,
    /// since a sent mail can't come back (docs/casa.md, Consent). The
    /// caller checks the task and mail access before reaching here.
    func sendMail(_ out: MailAgent.Outgoing, in tab: Tab, session: String, mode: AgentAsking, hold: TimeInterval? = nil) async -> [String: Any] {
        await queueMail([out], session: session, hold: hold)
    }

    /// An explicit batch shares one decision, and each outgoing operation
    /// still has one owner. A one-item batch has the single-mail card.
    func sendMails(_ outs: [MailAgent.Outgoing], in tab: Tab, session: String, hold: TimeInterval? = nil) async -> [String: Any] {
        await queueMail(outs, session: session, hold: hold)
    }

    /// Where a task asks for its yes: its own latest tab; else the tab of
    /// yours its question, its last answer or its send is on, so the call
    /// that comes again finds the answer whatever is in front by then;
    /// else the tab in front, never a private one. With no tab in front
    /// (a space with nothing in it), a tab of yours nothing asks in, this
    /// space's first: a send or a chat's question on it stands in the
    /// window's corner wherever you are (Agents.inCorner), so it is asked
    /// all the same rather than refused.
    func askTab(for session: String, in browser: Browser) -> Tab? {
        if let own = self.session(session).flatMap({ tabs(of: $0).last }) { return own }
        let held = browser.everyTab.first { tab in
            tab.permit?.session == session || tab.asker == session || tab.sending?.permit.session == session
                || tab.declined.contains(session)
                || tab.approved.map { $0.session == session && Date().timeIntervalSince($0.at) < 120 } == true
        }
        if let held { return held }
        if let front = browser.active { return front.shy ? nil : front }
        return (browser.tabs + browser.parkedTabs).first { tab in
            !tab.shy && tab.permit == nil && tab.handoff == nil && tab.sending == nil && (tab.agent == nil || tab.agent == session)
        }
    }

    /// A question put on a tab that isn't in front: a chat of Yab's comes
    /// out in the column with it, where the card stands in its field.
    func showAsk(_ tab: Tab, session: String, in browser: Browser) {
        guard browser.active !== tab, let root = self.session(root(of: session)), root.agent != .external,
              !root.quiet, !root.sealed, !(browser.chatOpen && browser.chatShown == root.id) else { return }
        browser.showChat(root.id)
    }

    /// Puts the question at the foot of the tab's page and holds the agent
    /// until it is answered, as a sign-in does.
    func ask(_ tab: Tab, _ permit: AgentPermit) {
        // Nobody there to say yes (`--no-person`, `yab serve --no-person`,
        // yab's quiet work): no, at once, as if said, rather than a card
        // on no screen and an agent waiting on it.
        if Headless.nobody || session(permit.session)?.unattended == true {
            tab.permit = permit
            answer(tab, yes: false)
            return
        }
        // The hand at the tab's end, where its face will be, not over the
        // site's mark.
        // A Mac permission question does not grant use of this tab.
        // Only a question about this page lets it in here: one for the
        // chat, a send or the Mac leaves the tab as it was, no face on it.
        if permit.place == .page, !tab.bench, tab.guest == nil {
            tab.guest = permit.session
        }
        tab.sending = nil
        tab.permit = permit
        // A payment is said in its own sheet, with Touch ID (PayFlow).
        if permit.isPayment { Payments.shared.begin(tab, permit) }
        handoff(tab, reason: permit.question, detail: permit.kind == .computer ? permit.detail : nil)
        // For an assistant in the cloud, and a local agent unless Settings ›
        // Agents says not to, a yes from the person's other devices too.
        if permit.place != .chat, let asker = asker(permit) { AssistantApprovals.shared.opened(tab, permit, by: asker) }
    }

    /// Who the other devices are told asks, or nil when this question stays
    /// on this Mac.
    func asker(_ permit: AgentPermit) -> AssistantApprovals.Asker? {
        guard browser?.prefs.agentsAskElsewhere != false, AssistantApprovals.travels(permit.kind) else { return nil }
        if let grant = assistant(of: permit.session) { return .init(id: grant.id, name: grant.name, local: false) }
        guard let session = session(permit.session), (session.parent == nil || permit.place == .chat), !session.unattended,
              remoteTaskOrigin(session.id) == nil else { return nil }
        return .init(id: "local." + session.cli, name: session.planName, local: true)
    }

    /// Your answer; for a sign-in, as whom.
    func answer(_ tab: Tab, yes: Bool, as user: String? = nil) {
        guard let permit = tab.permit else { return }
        guard remoteTaskOrigin(permit.session) == nil else { return }
        // The chat's question, put on a tab only because the Mac couldn't
        // say it: answered for the chat (answer(chat:)).
        if permit.place == .chat, let root = session(root(of: permit.session)), root.permit == permit {
            tab.permit = nil
            handBack(tab, asker: permit.session)
            answer(chat: root.id, yes: yes)
            return
        }
        // Its answers aren't a yes: one opens Settings, one the Mac's panel.
        if case .folder = permit.kind {
            if !yes { FolderAccess.shared.decline(tab) }
            else if user == "settings" { FolderAccess.shared.openSettings(tab) }
            else { FolderAccess.shared.choose(tab) }
            return
        }
        var computerDecision: Bool?
        switch permit.kind {
        case .computer:
            computerDecision = yes
        case .folder:
            break
        case .use:
            if yes { tab.allowed.insert(permit.session) } else {
                tab.refused.insert(permit.session)
                if tab.guest == permit.session { tab.guest = nil }
            }
        case .native:
            break // Consumed by the native operation, never by a page click.
        default:
            if yes {
                tab.approved = (permit.session, permit.key, Date())
                if case .signIn = permit.kind { tab.chosen = user }
                if !permit.amount.isEmpty { AgentRules.shared.spend(permit.amount) }
            } else {
                tab.declined.insert(permit.session)
            }
        }
        if yes { going(tab, permit) }
        if permit.isNative {
            // Keep the operation's owner while resolving the waiting task.
            handBack(tab)
            tab.permit = nil
        } else {
            tab.permit = nil
            handBack(tab, asker: permit.session)
        }
        AssistantApprovals.shared.settled(tab, permit, yes: yes)
        if permit.isPayment { Payments.shared.answered(tab, permit, yes: yes) }
        if case .native(_, let operation) = permit.kind {
            NativeControl.shared.decide(operation, session: permit.session, yes: yes)
        }
        if let computerDecision, let session = session(permit.session) {
            if computerDecision { allowMacAccess(session) }
            else { denyMacAccess(session) }
        }
    }

    /// A question for the whole chat (AgentPermit.Place.chat), its mail:
    /// kept on the chat and said by the Mac's notification, with its
    /// buttons, Yab in front or not; in the chat's field too while the
    /// column shows it. No tab of yours wears it, its face, a mark or the
    /// chat's answer. True while it waits or after a no: the call that
    /// comes again after a yes finds the chat allowed and goes on.
    func askChat(_ permit: AgentPermit, root: Session, browser: Browser?, answer: ([String: Any]) -> Void) -> Bool {
        if root.declined.remove(permit.key) != nil {
            answer(["error": Bench.declinedWords(permit.kind)])
            return true
        }
        let waits: [String: Any] = ["error": "this waits for the person's yes; asking them now", "asking": true, "chat": root.id]
        // One question a chat at a time: the next waits for this one.
        if root.permit != nil { answer(waits); return true }
        // Nobody there to say yes (`--no-person`, yab's quiet work): no,
        // at once, as if said, rather than a question on no screen.
        if Headless.nobody || root.unattended || session(permit.session)?.unattended == true {
            answer(["error": Bench.declinedWords(permit.kind)])
            return true
        }
        root.permit = permit
        if let who = self.asker(permit) { AssistantApprovals.shared.opened(chat: root, permit, by: who) }
        let asker = session(permit.session) ?? root
        if asker.state == .running { asker.state = .waiting }
        note(asker, permit.question)
        let browser = browser ?? self.browser
        AgentNotices.shared.browser = browser
        AgentNotices.shared.ask(permit, chat: root) { said in
            // The Mac can't say it: the window's corner holds it all the
            // same (AgentAskCorner). A Yab working out of sight shows its
            // window for it, once a chat, so the corner can be seen.
            guard !said, root.permit?.key == permit.key, Headless.hidden, !root.shownForAsk else { return }
            root.shownForAsk = true
            Headless.show(.request)
            Links.showBrowser()
        }
        objectWillChange.send()
        answer(waits)
        return true
    }

    /// The answer to the chat's question, from its notification's buttons
    /// or its field: a yes kept for the rest of the chat, a no heard once
    /// by the call that asked. Only for the question asked now: `key` names
    /// it, so a late button on one already answered does nothing.
    func answer(chat id: String, yes: Bool, key: String? = nil) {
        guard let root = session(id), let permit = root.permit, key == nil || key == permit.key else { return }
        if yes {
            switch permit.kind {
            case .mailRead: grantMail(root)
            case .mailChange(_, let act): root.mailChanges.insert(act)
            case .mailSite(let host): root.mailSites.insert(host)
            default: break
            }
        } else {
            root.declined.insert(permit.key)
        }
        AssistantApprovals.shared.settled(chat: root.id, permit, yes: yes)
        root.permit = nil
        AgentNotices.shared.clear(chat: root.id)
        for tab in windowTabs where tab.permit == permit {
            tab.permit = nil
            handBack(tab, asker: permit.session)
        }
        let asker = session(permit.session) ?? root
        if asker.state == .waiting {
            asker.state = asker.process != nil ? .running : asker.agent == .external ? .attached : .signingIn
            note(asker, "Back to \(asker.planName)")
        }
        objectWillChange.send()
    }

    /// Yes, and from now on without asking, for this press on this site.
    func always(_ tab: Tab) {
        guard remoteTaskOrigin(tab.permit?.session) == nil else { return }
        guard let label = tab.permit?.ruleLabel else { return }
        AgentRules.shared.set(site: AgentRules.site(tab.address), label: label, .always)
        answer(tab, yes: true)
    }

    /// No, and from now on without asking, for this press on this site.
    func never(_ tab: Tab) {
        guard remoteTaskOrigin(tab.permit?.session) == nil else { return }
        guard let label = tab.permit?.ruleLabel else { return }
        AgentRules.shared.set(site: AgentRules.site(tab.address), label: label, .never)
        answer(tab, yes: false)
    }

    /// A task over: its face leaves your tabs, and what it was allowed there
    /// goes with it.
    func leave(_ session: Session) {
        forgetMailCaller(session.id)
        AssistantApprovals.shared.left(session: session.id)
        Payments.shared.left(session: session.id)
        if let root = self.session(root(of: session.id)), root !== session, root.permit?.session == session.id {
            root.permit = nil
            AgentNotices.shared.clear(chat: root.id)
        }
        // What it asked of the chat goes with it, its notification too.
        if let permit = session.permit {
            AssistantApprovals.shared.left(session: permit.session)
            session.permit = nil
            AgentNotices.shared.clear(chat: session.id)
        }
        for tab in windowTabs {
            if tab.agent == session.id || tab.guest == session.id { Bench.shared.rest(tab) }
            if tab.permit?.session == session.id { tab.permit = nil; tab.handoff = nil }
            if tab.sending?.permit.session == session.id { tab.sending = nil }
            // A question it left on a tab of yours goes with it.
            if tab.asker == session.id {
                tab.handoff = nil
                tab.choices = []
                tab.asker = nil
            }
            if tab.guest == session.id {
                tab.handoff = nil
                tab.guest = nil
            }
            tab.allowed.remove(session.id)
            tab.refused.remove(session.id)
            tab.declined.remove(session.id)
            if tab.approved?.session == session.id { tab.approved = nil }
        }
    }
}

/// A yes to something that sends, while it goes (Tab.sending): the
/// question it answered, and once it didn't go, why, and the way to send it
/// again where there is one.
struct AgentSending {
    let permit: AgentPermit
    /// When the yes was said: the card says Sending for a beat at least.
    let at: Date
    var failure: String?
    var retry: (@MainActor () async -> String?)?

    init(_ permit: AgentPermit, at: Date = Date()) {
        self.permit = permit
        self.at = at
    }
}

extension AgentPermit {
    /// A yes after which something goes: the card in the chat's field says
    /// Sending until it has, not a payment (its own sheet says that).
    var sends: Bool {
        switch kind {
        case .press: return !pays && amount.isEmpty
        case .upload, .sendMessage, .sendMail, .sendMails: return true
        default: return false
        }
    }

    /// The yes while it goes, the same word going on: "Send", "Sending".
    static func going(_ title: String) -> String {
        let word = title.split(separator: " ").first.map(String.init) ?? title
        let rest = title.dropFirst(word.count)
        let lower = word.lowercased()
        let doubled: Set = ["submit", "ship", "drop", "plan"]
        let ing: String
        if doubled.contains(lower) {
            ing = word + String(word.last!) + "ing"
        } else if lower.hasSuffix("e"), !lower.hasSuffix("ee"), lower.count > 2 {
            ing = word.dropLast() + "ing"
        } else {
            ing = word + "ing"
        }
        return ing + rest
    }
}

extension Agents {
    /// The yes said to something that sends: the card stays, saying so,
    /// until the call it was for takes it (consumed, sent).
    func going(_ tab: Tab, _ permit: AgentPermit) {
        guard permit.sends, !Headless.nobody else { return }
        let started = AgentSending(permit)
        tab.sending = started
        // The yes lasts two minutes (Tab.approved): past that, nothing goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 125) { [weak tab] in
            guard let tab, let now = tab.sending, now.at == started.at, now.failure == nil else { return }
            tab.sending = nil
        }
    }

    /// The yes taken by the call it was for. A mail or a message says how
    /// it went itself (sent); anything else has gone with the press.
    func consumed(_ tab: Tab) {
        guard let sending = tab.sending, sending.failure == nil else { return }
        switch sending.permit.kind {
        case .sendMail, .sendMails, .sendMessage: return
        default: sent(tab, trouble: nil)
        }
    }

    /// What was sent has gone, or hasn't: gone, the card shrinks back into
    /// the field after Sending had its beat; not, it says why in red, with
    /// Try Again where there is a way to.
    func sent(_ tab: Tab, trouble: String?, retry: (@MainActor () async -> String?)? = nil) {
        guard var sending = tab.sending else { return }
        // A yes given on another device: what came of it goes back there.
        ApprovalDetails.shared.ran(tab, sending.permit, trouble: trouble)
        if let trouble {
            sending.failure = trouble
            sending.retry = retry
            tab.sending = sending
            return
        }
        let at = sending.at
        let wait = max(0, 0.5 - Date().timeIntervalSince(at))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak tab] in
            guard let tab, tab.sending?.at == at else { return }
            tab.sending = nil
        }
    }

    /// Not Now on a send that failed: the card goes, nothing more is tried.
    func dropSending(_ tab: Tab) {
        tab.sending = nil
    }

    /// Try Again on a send that failed: Sending again, the same way.
    func sendAgain(_ tab: Tab) {
        guard var sending = tab.sending, sending.failure != nil, let retry = sending.retry else { return }
        sending.failure = nil
        tab.sending = sending
        Task { @MainActor in
            let trouble = await retry()
            self.sent(tab, trouble: trouble, retry: retry)
        }
    }
}

extension AgentPermit {
    /// Where a question is asked, by what it gives (docs/chat-asks.md).
    enum Place: Equatable {
        /// For the whole chat, its mail: in the Mac's notification, with
        /// its buttons, and in the chat's field while the column shows it.
        /// No tab of yours is touched.
        case chat
        /// For this page: at the foot of the tab the agent works in.
        case page
        /// Money or words sent as you: in Yab, where the amount, whom
        /// and what can be read.
        case send
        /// This Mac: over Yab.
        case mac
    }

    var place: Place {
        switch kind {
        case .mailRead, .mailChange, .mailSite: return .chat
        case .press: return pays || !amount.isEmpty ? .send : .page
        case .sendMail, .sendMails, .sendMessage, .messages, .saveSkill: return .send
        case .computer, .folder, .native: return .mac
        case .use, .upload, .signIn, .address, .unlockManager: return .page
        }
    }

    var isNative: Bool { if case .native = kind { return true }; return false }
    var isFolder: Bool { if case .folder = kind { return true }; return false }
}

// MARK: - what a press would do

extension AgentPage {
    /// Whether a press lands on a button that sends, posts, pays or
    /// deletes, in words scripts share: `pressed(el, action)` is that button
    /// or null, `about(b)` its words and a line of context. Weighed before a
    /// click or a key (weigh), and in an agent's own script (hold).
    /// Deliberately narrow: a word at the start of the button's own name,
    /// the way people label the last step, so "Send" and "Pay now" ask and
    /// "Sending options" doesn't.
    ///
    /// Everything it reads off an element goes through the DOM's own
    /// getters and methods, taken once when the script starts, never
    /// through the element: in an agent's world the element could carry a
    /// name or a `closest` of the agent's making.
    static let commits = """
    const $un = Function.prototype.bind.bind(Function.prototype.call);
    function $get(P, k) {
      for (let p = P; p; p = Object.getPrototypeOf(p)) {
        const d = Object.getOwnPropertyDescriptor(p, k);
        if (d) return $un(d.get || d.value);
      }
      return () => undefined;
    }
    const $closest = $get(Element.prototype, 'closest'), $attr = $get(Element.prototype, 'getAttribute'),
      $tag = $get(Element.prototype, 'tagName'), $one = $get(Element.prototype, 'querySelector'),
      $allIn = $get(Element.prototype, 'querySelectorAll'), $count = $get(NodeList.prototype, 'length'),
      $item = $get(NodeList.prototype, 'item'), $innerText = $get(HTMLElement.prototype, 'innerText'),
      $textContent = $get(Node.prototype, 'textContent'), $up = $get(Node.prototype, 'parentElement'),
      $doc = $get(Node.prototype, 'ownerDocument'), $control = $get(HTMLLabelElement.prototype, 'control'),
      $shown = $get(HTMLElement.prototype, 'offsetParent'), $body = $get(Document.prototype, 'body'),
      $title = $get(Document.prototype, 'title'), $inputValue = $get(HTMLInputElement.prototype, 'value'),
      $areaValue = $get(HTMLTextAreaElement.prototype, 'value'), $nodeType = $get(Node.prototype, 'nodeType'),
      $connected = $get(Node.prototype, 'isConnected');
    function all(el, q) { const list = $allIn(el, q), out = []; for (let i = 0, n = $count(list); i < n; i++) out.push($item(list, i)); return out; }
    function textOf(el) { if (!el) return ''; try { return $innerText(el) || ''; } catch (e) { return $textContent(el) || ''; } }
    function valueOf(el) { const t = $tag(el); return (t === 'INPUT' ? $inputValue(el) : t === 'TEXTAREA' ? $areaValue(el) : '') || ''; }
    // A link that goes somewhere is reading, not committing: "Delete an
    // API key" in a docs sidebar, "Send feedback" in a footer. Only links
    // that act as buttons (no address, #, javascript:) can commit.
    const kinds = 'button,[role=button],a:not([href]),a[href="#"],a[href^="javascript:" i],input[type=submit],input[type=button],[role=menuitem]';
    // "Purchase orders" names a table or a record (register 1762), not a press that buys.
    const verbs = /^(send|send now|post|publish|tweet|pay|pay now|buy|buy now|place (your )?order|order now|purchase(?! (?:orders?|requisitions?|requests?|histor(?:y|ies)|invoices?|records?)\\b)|complete (purchase|order|payment)|confirm (and pay|payment|purchase|order|transfer)|submit (payment|order)|transfer|withdraw|donate|delete|delete forever|delete permanently|delete account|empty trash|cancel (my |your )?(subscription|plan|membership)|(confirm|finish|complete) cancel(l)?ation|(yes, )?cancel (subscription|plan|membership)|turn off auto-?renew(al)?|don'?t renew|end (subscription|plan|membership))(\\b|$)/i;
    // The same last steps as other languages label them, most of yab's
    // people's: German, French, Spanish, Portuguese, Italian. \\b
    // knows only ASCII letters, so the word ends where no letter follows.
    const foreign = /^(senden|absenden|veröffentlichen|bezahlen|jetzt (kaufen|bezahlen)|kaufen|bestellen|zahlungspflichtig bestellen|überweisen|spenden|löschen|endgültig löschen|envoyer|publier|payer|acheter|commander|valider (la|ma) commande|confirmer (le paiement|la commande)|faire un don|supprimer|enviar|publicar|pagar|comprar|realizar pedido|finalizar (compra|pedido)|confirmar (pago|pagamento|pedido|compra)|donar|doar|eliminar|excluir|borrar|invia|pubblica|paga|acquista|ordina|conferma (pagamento|ordine|acquisto)|dona|elimina)(?![\\p{L}\\p{N}])/iu;
    // A form that takes a card: whatever sends it pays, however it is
    // labeled, Continue or Next included. The fields a card is typed
    // into, or the frame a payment service puts them in.
    const cardFields = 'input[autocomplete~="cc-number" i],input[autocomplete~="cc-csc" i],input[name*="cardnumber" i],input[name*="card_number" i],input[name*="card-number" i],input[id*="cardnumber" i],input[data-elements-stable-field-name="cardNumber"],iframe[src*="js.stripe.com"],iframe[name^="__privateStripeFrame"],iframe[src*="braintreegateway.com"],iframe[src*="adyen.com"],iframe[src*="checkout.com"]';
    function sendsCard(b) {
      const t = $tag(b), type = ($attr(b, 'type') || '').toLowerCase();
      const submits = (t === 'BUTTON' && (type === '' || type === 'submit')) || (t === 'INPUT' && (type === 'submit' || type === 'image'));
      const form = submits && $closest(b, 'form');
      return !!form && !!$one(form, cardFields);
    }
    function nameOf(b) {
      const raw = ($attr(b, 'aria-label') || ($tag(b) === 'INPUT' ? $inputValue(b) : '') || textOf(b) || $attr(b, 'title') || '').replace(/\\s+/g, ' ').trim();
      return raw.replace(/[\\u202A-\\u202E]/g, '').replace(/\\s*\\(.*\\)\\s*$/, '').trim();
    }
    function commits(b) { const n = nameOf(b); return !!n && ((n.length <= 32 && (verbs.test(n) || foreign.test(n))) || sendsCard(b)); }
    function pressed(el, action) {
      // A label's click is its control's.
      if ($tag(el) === 'LABEL' && $control(el)) el = $control(el);
      if (action === 'click') {
        // A link that goes somewhere is reading, whatever it says.
        const c = $closest(el, kinds) || ($closest(el, 'a[href]') ? null : el);
        return c && commits(c) ? c : null;
      }
      // Enter in a field, Space on a button, or a form sent: what its form
      // or dialog would do with it, or, for a composer in neither, the
      // nearest surroundings that have a Send.
      const self = $closest(el, kinds);
      if (self && commits(self)) return self;
      // Enter in a one-line field does what its form's default button does,
      // and nothing else: a filter box beside a key's Delete (GitHub SSH
      // keys, Cloud credentials) or Gmail's toolbar never asks "Delete?".
      // Outside a form only a nearby Send-like button counts (a chat box).
      if ($tag(el) === 'INPUT') {
        const form = $closest(el, 'form');
        if (form) {
          const main = $one(form, 'button:not([type]),button[type=submit],input[type=submit],input[type=image]');
          return main && commits(main) ? main : null;
        }
        const sends = b => commits(b) && !/^(delete|remove|empty|cancel|turn off|don'?t|end|l[öo]sch|supprim|elimin|exclu|borr)/i.test(nameOf(b));
        // The nearest box with any buttons is the field's own: its Send or
        // nothing, never one further up the page.
        for (let up = $up(el), n = 0; up && n < 4; up = $up(up), n++) {
          const near = all(up, kinds);
          if (near.length) return near.find(sends) || null;
        }
        return null;
      }
      let box = $closest(el, 'form,[role=dialog],dialog');
      for (let up = el, n = 0; !box && up && n < 8; up = $up(up), n++) {
        if (all(up, kinds).some(commits)) box = up;
      }
      return box ? all(box, kinds).find(commits) || null : null;
    }
    function about(b) {
      const doc = $doc(b) || document;
      const name = nameOf(b);
      const box = $closest(b, '[role=dialog],dialog,form');
      let detail = '';
      if (box) {
        const to = $one(box, '[name=to],[aria-label^="To"],input[type=email]');
        const subject = $one(box, '[name=subjectbox],[name=subject],input[aria-label^="Subject"]');
        const parts = [];
        const who = to && (valueOf(to) || textOf(to)).trim();
        if (who) parts.push('To ' + who.slice(0, 60));
        const topic = subject && valueOf(subject);
        if (topic) parts.push(topic.trim().slice(0, 60));
        if (!parts.length) {
          const head = $attr(box, 'aria-label') || textOf($one(box, 'h1,h2,h3,[role=heading]'));
          if (head) parts.push(head.trim().slice(0, 80));
        }
        detail = parts.join(' · ');
      }
      // What it would send: the composer's text, in the same box, or the
      // nearest one up from the button.
      let draft = '';
      for (let up = b, n = 0; up && n < 10 && !draft; up = $up(up), n++) {
        const field = all(up, '[contenteditable=true],[contenteditable=""],textarea,[role=textbox]')
          .filter(f => { try { return $shown(f) !== null; } catch (e) { return false; } })
          .filter(f => !/^(to|cc|bcc|subject|search)/i.test($attr(f, 'aria-label') || $attr(f, 'name') || ''))
          .map(f => ($tag(f) === 'TEXTAREA' ? $areaValue(f) : textOf(f)) || '')
          .map(t => t.trim()).filter(Boolean).sort((a, b) => b.length - a.length)[0];
        if (field) draft = field.slice(0, 2000);
      }
      // What it comes to, when it pays: on the button ("Pay $42.10"), or on
      // the total's line of its form or page, or the line under it. Whole,
      // with its digits as written ("€ 1.299,00" was read only to its first
      // point, €1.29) and any letters against its sign (US$, R$, CAD$, AR$,
      // Mex$): only none or US is a US dollar (AgentRules.dollars), so a
      // currency this doesn't know asks. The button's own word and the
      // total's label come off first: a page that draws "Pay" or "Total"
      // against "$10" says "Pay$10", and Pay is no currency.
      const cash = /(\\b[A-Za-z]+)?[$€£]\\s?\\d(?:[\\d.,]*\\d)?/;
      const label = /(order total|grand total|total due|amount due|you pay|estimated total|^\\s*total\\b)/i;
      let amount = (name.replace(verbs, '').replace(foreign, '').match(cash) || [''])[0];
      // The nearest surroundings first, out to the whole page: a checkout's
      // total is seldom inside the button's own form. On the total's line
      // the amount may be on either side of its label ("$150.00 order
      // total"); the next line with words counts only when it is the amount
      // alone, not "Includes $5.00 tax". Two different amounts are no
      // total, and with none the person is asked.
      for (const scope of [$closest(b, '[role=dialog],dialog'), $closest(b, 'form'), $closest(b, 'main,aside'), $body(doc)]) {
        if (amount || !scope) continue;
        const lines = textOf(scope).split('\\n');
        const totals = new Set();
        lines.forEach((line, i) => {
          if (!label.test(line)) return;
          const here = line.replace(label, ' ').match(new RegExp(cash.source, 'g')) || [];
          let below = i + 1;
          while (below < lines.length && !lines[below].trim()) below++;
          const next = (lines[below] || '').trim(), alone = next.match(cash);
          (here.length ? here : alone && alone[0] === next ? [next] : []).forEach(m => totals.add(m.replace(/\\s/g, '')));
        });
        if (totals.size === 1) amount = [...totals][0];
        if (totals.size) break;
      }
      return { commit: name.charAt(0).toUpperCase() + name.slice(1), detail: detail || ($title(doc) || '').slice(0, 80), draft, amount: amount.replace(/\\s/g, ''), pays: sendsCard(b) };
    }
    """

    /// What has the focus, into open shadow roots and frames of the same
    /// site: what a key lands on.
    static let focusedScript = """
    function focused() {
      let el = document.activeElement;
      for (let n = 0; el && n < 16; n++) {
        if (el.shadowRoot && el.shadowRoot.activeElement) { el = el.shadowRoot.activeElement; continue; }
        if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
          let inner = null;
          try { inner = el.contentDocument && el.contentDocument.activeElement; } catch (e) {}
          if (inner) { el = inner; continue; }
        }
        break;
      }
      return el || document.body;
    }
    """

    /// Before a click, or Enter in a form: its words and a line of context
    /// if it sends, posts, pays or deletes, nothing otherwise. A key lands
    /// on what has the focus, into shadow roots and frames, as the keys do.
    static let weigh = """
    if (action === 'none') return {};
    // Kept here too, for a yes to be matched to its button with no
    // snapshot taken first.
    const S = (globalThis.__yab ||= { n: 0, refs: new Map() });
    \(focusedScript)
    // Coordinate presses carry a synthetic approval ref, not a DOM ref.
    // Chromium must hit-test the point before considering that label.
    const pointed = frames && at;
    let el = pointed ? document.elementFromPoint(at.x, at.y) : ref ? (S && S.refs.get(ref)) : at ? document.elementFromPoint(at.x, at.y) : focused();
    // A point over another site's frame names nothing this world can read.
    // Where the engine asks (frames), descend same-site frames and refuse
    // the rest rather than weigh the empty frame element.
    if (pointed) {
      let x = at.x, y = at.y;
      for (let n = 0; el && n < 32; n++) {
        if (el.shadowRoot) {
          const inner = el.shadowRoot.elementFromPoint(x, y);
          if (inner && inner !== el) { el = inner; continue; }
        }
        if (el.tagName !== 'IFRAME' && el.tagName !== 'FRAME') break;
        let inner = null;
        try { inner = el.contentDocument; } catch (e) {}
        if (!inner) return { frame: true };
        const r = el.getBoundingClientRect();
        x -= r.left + el.clientLeft; y -= r.top + el.clientTop;
        el = inner.elementFromPoint(x, y);
      }
      // An unresolved frame or shadow boundary at the bound is not a
      // harmless element. Ask for a ref instead of pressing through it.
      if (el && (el.tagName === 'IFRAME' || el.tagName === 'FRAME' || el.shadowRoot)) return { frame: true };
    }
    if (!el || !el.isConnected) return {};
    \(commits)
    const b = pressed(el, action === 'click' ? 'click' : 'key');
    if (!b) return {};
    // A yes is for this element with the same recipient, draft and amount.
    const facts = about(b);
    if (approved && S && S.asked === b && JSON.stringify(S.askedAbout) === JSON.stringify(facts)) {
      S.asked = null; S.askedAbout = null;
      return { commit: nameOf(b), approved: true };
    }
    if (S) { S.asked = b; S.askedAbout = facts; }
    return facts;
    """

    /// The guard's key on each page, a new one for every script: what yab
    /// reaches the guard's controls with, and the agent's script never sees.
    static var holdKeys: [ObjectIdentifier: String] = [:]

    /// The guard an agent's script runs under, set up the first time a
    /// page has one, as `__yabHold`, a constant of the world's own that no
    /// script after it can take or change. In its world, and in every frame
    /// or window of the same site the page has or gets, a click, a click's
    /// or a key's event, or a form sent that lands on a button weighed as
    /// the agent's click and press are weighed isn't made: it is held, all
    /// of that one button's in order, until yab, with the key, takes it and
    /// makes it or drops it. Every other press goes through. What it wraps
    /// is pinned (not writable, not configurable), what it reads with was
    /// taken before the script could touch anything, and the language's
    /// own objects are frozen in this world, so a script can't turn it off,
    /// empty it, make its press itself, or blind it. A frame is guarded as
    /// it is put in the page, as it loads, and whenever the guard is used;
    /// one it can't guard is taken out of the page.
    static func hold(key: String, on: Bool) -> String {
        """
        const __yabHold = (() => {
          let secret = "\(key)", armed = \(on), held = null, others = 0;
          \(commits)
          const define = Object.defineProperty, describe = Object.getOwnPropertyDescriptor, apply = Reflect.apply;
          const mine = new WeakSet(), $mine = $un(WeakSet.prototype.add), $ours = $un(WeakSet.prototype.has);
          const $type = $get(Event.prototype, 'type'), $key = $get(KeyboardEvent.prototype, 'key'),
            $keyCode = $get(KeyboardEvent.prototype, 'keyCode'), $remove = $get(Element.prototype, 'remove'),
            $host = (() => { const h = $get(ShadowRoot.prototype, 'host'); return n => { try { return h(n); } catch (e) { return null; } }; })();
          const mouse = /^(click|dblclick|auxclick|mousedown|mouseup|pointerdown|pointerup|touchstart|touchend)$/, keys = /^key(down|press|up)$/;
          // Held: this press of that button, kept to make on a yes. A press
          // of another such button meanwhile isn't made at all, nor one the
          // guard couldn't read.
          // What an event on a node lands on for the page: text's element, a
          // shadow root's host.
          function elementOf(node) {
            const t = $nodeType(node);
            return t === 1 ? node : t === 3 || t === 8 ? $up(node) : t === 11 ? $host(node) || null : null;
          }
          function stop(el, action, make) {
            if (!armed) return false;
            let b = null;
            try { el = elementOf(el); if (!el) return false; b = pressed(el, action); } catch (e) { others++; return true; }
            if (!b) return false;
            if (held && held.b !== b) { others++; return true; }
            if (!held) held = { b, about: about(b), acts: [] };
            held.acts.push(make);
            return true;
          }
          function kind(ev) {
            let t = '';
            try { t = $type(ev); } catch (e) { return null; }
            if (mouse.test(t)) return 'click';
            if (t === 'submit') return 'key';
            if (keys.test(t)) {
              let k = '', c = 0;
              try { k = $key(ev); c = $keyCode(ev); } catch (e) {}
              if (k === 'Enter' || k === ' ' || c === 13 || c === 32) return 'key';
            }
            return null;
          }
          function pin(P, k, value) { define(P, k, { value, writable: false, configurable: false, enumerable: false }); $mine(mine, value); }
          function guarded(w) {
            try { const d = describe(w.HTMLElement.prototype, 'click'); return !!d && $ours(mine, d.value); } catch (e) { return true; }
          }
          function guard(w) {
            if (!w || guarded(w)) return;
            try { wrap(w); } catch (e) {
              // A frame the guard can't hold has no place in the page.
              try { const f = w.frameElement; if (f) $remove(f); } catch (e2) {}
            }
          }
          // Every window under this one, by index, whatever holds its frame:
          // a shadow root, an object, an embed.
          function sweep(w) {
            guard(w);
            let n = 0;
            try { n = w.length; } catch (e) {}
            for (let i = 0; i < n; i++) { let c = null; try { c = w[i]; } catch (e) {} if (c && c !== w) sweep(c); }
          }
          function rescan() { sweep(window); }
          function wrap(w) {
            const E = w.HTMLElement.prototype, T = w.EventTarget.prototype, F = w.HTMLFormElement.prototype;
            const click = $un(E.click), dispatch = $un(T.dispatchEvent), listen = $un(T.addEventListener);
            const submit = $un(F.submit), request = F.requestSubmit && $un(F.requestSubmit), open = w.open;
            // Put in the page: a frame put in with it is guarded before the
            // script has it.
            function after(P, k) {
              const d = P && describe(P, k);
              if (!d || !d.configurable) return;
              if (typeof d.value === 'function') {
                const f = d.value;
                pin(P, k, function () { const r = apply(f, this, arguments); rescan(); return r; });
              } else if (d.set) {
                const set = $un(d.set);
                const put = function (v) { set(this, v); rescan(); };
                define(P, k, { get: d.get, set: put, enumerable: d.enumerable, configurable: false });
                $mine(mine, put);
              }
            }
            for (const P of [w.Node && w.Node.prototype]) for (const k of ['appendChild', 'insertBefore', 'replaceChild']) after(P, k);
            for (const P of [w.Element, w.CharacterData, w.Document, w.DocumentFragment, w.DocumentType].map(C => C && C.prototype)) {
              for (const k of ['before', 'after', 'replaceWith', 'append', 'prepend', 'replaceChildren', 'insertAdjacentElement', 'insertAdjacentHTML', 'setHTMLUnsafe', 'write', 'writeln', 'innerHTML', 'outerHTML']) after(P, k);
            }
            after(w.ShadowRoot && w.ShadowRoot.prototype, 'innerHTML');
            after(w.ShadowRoot && w.ShadowRoot.prototype, 'setHTMLUnsafe');
            for (const k of ['insertNode', 'surroundContents']) after(w.Range && w.Range.prototype, k);
            pin(E, 'click', function () { if (!stop(this, 'click', () => click(this))) return click(this); });
            pin(T, 'dispatchEvent', function (ev) {
              const action = kind(ev);
              if (action && stop(this, action, () => dispatch(this, ev))) return false;
              return dispatch(this, ev);
            });
            pin(F, 'submit', function () { if (!stop(this, 'key', () => submit(this))) return submit(this); });
            if (request) pin(F, 'requestSubmit', function (by) {
              let b = this;
              try { if (by && commits(by)) b = by; } catch (e) {}
              if (!stop(b, b === this ? 'key' : 'click', () => request(this, by))) return request(this, by);
            });
            // A frame that loads a page anew is a new window: guarded as it
            // loads, and as the script reaches it.
            for (const [C, k] of [[w.HTMLIFrameElement, 'contentWindow'], [w.HTMLIFrameElement, 'contentDocument'], [w.HTMLFrameElement, 'contentWindow'],
                                  [w.HTMLFrameElement, 'contentDocument'], [w.HTMLObjectElement, 'contentWindow'], [w.HTMLObjectElement, 'contentDocument']]) {
              const d = C && describe(C.prototype, k);
              if (!d || !d.get || !d.configurable) continue;
              const read = $un(d.get);
              const get = function () { const v = read(this); rescan(); return v; };
              define(C.prototype, k, { get, enumerable: d.enumerable, configurable: false });
              $mine(mine, get);
            }
            if (typeof open === 'function') {
              try { define(w, 'open', { value: function () { const v = apply(open, this, arguments); rescan(); return v; }, writable: false, configurable: true }); } catch (e) {}
            }
            try { listen(w.document, 'load', rescan, true); listen(w, 'load', rescan, true); } catch (e) {}
          }
          rescan();
          // The language's own objects, which the guard reads with, as they
          // are now, in this world.
          for (const o of [Object, Object.prototype, Function, Function.prototype, Array, Array.prototype, String, String.prototype,
                           RegExp, RegExp.prototype, Reflect, WeakSet.prototype, WeakMap.prototype, Symbol, Math, JSON, Number.prototype, Boolean.prototype]) {
            Object.freeze(o);
          }
          return function (k, command, value) {
            if (typeof k !== 'string' || k !== secret) return false;
            if (command === 'rekey') { secret = value; return true; }
            if (command === 'arm') { armed = !!value; rescan(); return true; }
            if (command === 'take') return held ? { ...held.about, others } : null;
            if (command === 'perform') {
              const h = held;
              held = null; others = 0;
              if (!h || !$connected(h.b)) return false;
              for (const act of h.acts) act();
              return true;
            }
            if (command === 'drop') { held = null; others = 0; return true; }
            return false;
          };
        })();
        true;
        """
    }

    /// Sets the guard up on the page, or finds it there and gives it a new
    /// key, armed or not (Bypass). False when the guard on the page doesn't
    /// answer to yab's key: then no script is run.
    static func arm(_ web: any PageHandle, on: Bool, _ done: @escaping @MainActor (Bool) -> Void) {
        let id = ObjectIdentifier(web)
        let fresh = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        let before = holdKeys[id] ?? ""
        let check = "typeof __yabHold === 'function' ? (__yabHold('\(before)', 'rekey', '\(fresh)') && __yabHold('\(fresh)', 'arm', \(on))) : 'none'"
        web.run(check, in: .agentEval) { result in
            MainActor.assumeIsolated {
                switch try? result.get() {
                case let yes as Bool:
                    if yes { holdKeys[id] = fresh }
                    done(yes)
                case let said as String where said == "none":
                    web.run(hold(key: fresh, on: on), in: .agentEval) { made in
                        MainActor.assumeIsolated {
                            let yes = (try? made.get()) as? Bool == true
                            if yes { holdKeys[id] = fresh }
                            done(yes)
                        }
                    }
                default:
                    done(false)
                }
            }
        }
    }

    /// One of the guard's controls, with the page's key: take (what is
    /// held), perform (make it) or drop (forget it).
    static func held(_ web: any PageHandle, _ command: String, _ done: @escaping @MainActor (Any?) -> Void = { _ in }) {
        let key = holdKeys[ObjectIdentifier(web)] ?? ""
        web.run("typeof __yabHold === 'function' ? __yabHold('\(key)', '\(command)') : null", in: .agentEval) { result in
            MainActor.assumeIsolated { done(try? result.get()) }
        }
    }

    /// An agent's own script, in its world, and what it gives back. One
    /// expression, an async IIFE's too, is returned from an async function
    /// and its promise waited for: evaluateJavaScript has no promises, and
    /// would say null. A script with `await` or `return` in it that is more
    /// than one expression is an async function's body, its `return` what
    /// comes back. Anything else runs as a script, as it always has, its
    /// last value what comes back.
    static func eval(_ web: any PageHandle, _ js: String, patience: Double = 20, _ done: @escaping @MainActor (Result<Any?, Error>) -> Void) {
        let checked: @MainActor (Result<Any?, Error>) -> Void = { result in
            Task { @MainActor in
                guard await AgentSecrets.check(web) else { done(.failure(AgentSecrets.Refused(web))); return }
                done(result)
            }
        }
        let execute = {
            let guardBody = AgentSecrets.guardBody
            guard let body = awaited(js, patience: patience) else {
                web.run(guardBody + js, in: .agentEval) { result in MainActor.assumeIsolated { checked(result) } }
                return
            }
            web.call(guardBody + body, arguments: [:], in: .agentEval) { result in MainActor.assumeIsolated { checked(result) } }
        }
        Task { @MainActor in
            guard await AgentSecrets.check(web) else { done(.failure(AgentSecrets.Refused(web))); return }
            execute()
        }
    }

    /// The async function body an agent's script runs as, or nil for one
    /// run as a script. Which, JavaScriptCore's own parser says. A promise
    /// is waited for `patience` seconds, inside the socket's 25, then given
    /// up on in words. The script's first line stays the body's first, so
    /// an error's line is the agent's; WebKit gives none for a rejection,
    /// so it goes into the words.
    static func awaited(_ js: String, patience: Double = 20) -> String? {
        var one = js
        while let last = one.last, last == ";" || last.isWhitespace { one.removeLast() }
        // A function or class alone is declared, as a script declares it,
        // for the next script to call; as an expression it would be lost.
        let declares = one.range(of: #"^\s*(async\s+)?(function|class)\b"#, options: .regularExpression) != nil
        let inner: String
        if !one.isEmpty, !declares, parses("(async () => (\(one)\n))") {
            inner = "return (\(one)\n);"
        } else if parses(js) {
            return nil
        } else if parses("(async () => {\(js)\n})") {
            inner = js
        } else {
            return nil
        }
        let ms = Int(patience * 1000)
        return """
        let timer; try { const value = await Promise.race([(async () => { \(inner)
        })(), new Promise((_, no) => { timer = setTimeout(() => no("its promise hadn't settled after \(Int(patience)) s"), \(ms)); })]); return value === undefined ? null : \(WebKitIPCBoundary.plainScript)(value); }
        catch (e) { throw typeof e?.line === 'number' && e.line > 0 ? `${e} (line ${e.line})` : e; } finally { clearTimeout(timer); }
        """
    }

    private static let grammar = JSGlobalContextCreate(nil)

    /// Whether a script would compile, without running it.
    static func parses(_ source: String) -> Bool {
        let script = JSStringCreateWithUTF8CString(source)
        defer { JSStringRelease(script) }
        return JSCheckScriptSyntax(grammar, script, nil, 1, nil)
    }
}
