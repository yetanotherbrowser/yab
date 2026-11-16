import Foundation
import AppKit
import os
import WebKit

// The code a site just sent, offered under the box that asks for it, the
// way the accounts kept for a site hang from its sign-in (docs/mail.md).
//
// Three places a code can be: the site's own two-factor key kept here
// (OneTime), a mail it sent, and a text. Mail is read from Gmail's own
// feed of unread mail with the space's cookies, one request, when Settings ›
// Autofill says so, or from Mail's own store once it is connected; texts
// from Messages where Yab may read them. Each is read when a
// code box has the caret, and again every few seconds for a minute, since
// the code is usually on its way while the box waits. Nothing goes into the
// page until you pick it.

/// A person opened Passwords for this account, then entered a code in its
/// box. This records only the site and account, never a code or a secret.
/// Apple doesn't let another app inspect whether Passwords has a code.
enum AppleCodeHints {
    private static let setting = "codes.applePasswords.accounts"

    nonisolated static func id(host: String, user: String) -> String? {
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let site = Vault.registrable(host.lowercased())
        guard !site.isEmpty, !user.isEmpty else { return nil }
        return site + "\u{1}" + user
    }

    static func has(host: String, user: String) -> Bool {
        guard let id = id(host: host, user: user) else { return false }
        return Store.settings.stringArray(forKey: setting)?.contains(id) == true
    }

    static func remember(host: String, user: String) {
        guard let id = id(host: host, user: user) else { return }
        var accounts = Set(Store.settings.stringArray(forKey: setting) ?? [])
        accounts.insert(id)
        Store.settings.set(accounts.sorted(), forKey: setting)
    }

    static func open() -> Bool {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Passwords.app"))
    }
}

enum MailCodes {
    /// How far back a code still counts.
    nonisolated static let fresh: TimeInterval = MailCodeRead.defaultLifetime

    /// Whether Messages could be read the last time Yab looked: Full Disk
    /// Access given, never asked for. Texted codes are on by themselves
    /// only then (Preferences.textCodes).
    @MainActor static var textsReadable = false {
        didSet { textsLooked = true }
    }
    /// Whether Yab has looked yet this launch: until it has, nobody can say
    /// texts can't be read, and the row offering them stays away.
    @MainActor static var textsLooked = false

    /// The row under a code box offering texted codes, while Messages can't
    /// be read (docs/mail.md, "Codes from texts, offered"): on the first
    /// three code boxes, unless you turned From Messages off yourself.
    /// Taken once, or let pass three times, it never comes back; Settings ›
    /// Autofill keeps the switch.
    enum TextsRow {
        static let key = "codes.texts.offered"
        static let times = 3

        /// How many code boxes it has hung under, and `times` once taken.
        static var shown: Int {
            get { Store.settings.integer(forKey: key) }
            set { Store.settings.set(newValue, forKey: key) }
        }

        /// Whether it goes under the box now. `here`: it is already under
        /// this box, and stays for as long as the box does.
        @MainActor static func offers(_ prefs: Preferences, here: Bool) -> Bool {
            guard textsLooked, !textsReadable, (here || shown < times) else { return false }
            // Turned off by you is off: unset, or turned on without the access.
            return Store.settings.object(forKey: "codes.texts") == nil || prefs.codesFromTexts
        }

        /// Where Full Disk Access is given, in System Settings.
        static let place = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    /// Messages opened once, to know whether it can be. Off the main thread.
    nonisolated static func canReadTexts() -> Bool {
        if case .success = AgentFiles.texts(minutes: 1) { return true }
        return false
    }

    /// Settings › Autofill's Archive code mails after use, off until asked.
    static var archivesUsed: Bool {
        get { Store.settings.bool(forKey: "mail.codes.archive") }
        set { Store.settings.set(newValue, forKey: "mail.codes.archive") }
    }

    /// The code in a mail or a text, or nil when there is none (MailCodeWords).
    nonisolated static func code(in text: String) -> String? { MailCodeWords.code(in: text) }

    /// A sender's domain must be the site asking for the code. Display names
    /// and subjects are sender-controlled and can mention any other site.
    nonisolated static func belongs(address: String, from name: String, subject: String, to host: String) -> Bool {
        let site = Vault.registrable(host)
        let parts = address.split(separator: "@")
        guard parts.count == 2 else { return false }
        let domain = String(parts[1])
        return Vault.registrable(domain) == site
    }

    /// A code as it reads best: in threes, 481 902.
    nonisolated static func spaced(_ code: String) -> String {
        guard code.count == 6 || code.count == 8 else { return code }
        let half = code.index(code.startIndex, offsetBy: code.count / 2)
        return code[..<half] + " " + code[half...]
    }

    // MARK: - Gmail's feed

    /// The unread mail in Gmail's Atom feed, newest first.
    nonisolated static func feed(_ xml: String) -> [Mailed] {
        func field(_ name: String, in entry: String) -> String {
            guard let range = entry.range(of: "<\(name)>([\\s\\S]*?)</\(name)>", options: .regularExpression) else { return "" }
            let inner = entry[range].dropFirst(name.count + 2).dropLast(name.count + 3)
            return AgentRead.plain(String(inner))
        }
        let parse = ISO8601DateFormatter()
        var out: [Mailed] = []
        var rest = xml[...]
        while let open = rest.range(of: "<entry>"), let close = rest.range(of: "</entry>", range: open.upperBound..<rest.endIndex) {
            let entry = String(rest[open.upperBound..<close.lowerBound])
            rest = rest[close.upperBound...]
            let when = field("issued", in: entry)
            let at = parse.date(from: when) ?? parse.date(from: field("modified", in: entry)) ?? .distantPast
            out.append(Mailed(from: field("name", in: entry), address: field("email", in: entry),
                              subject: field("title", in: entry), text: field("summary", in: entry), at: at))
        }
        return out.sorted { $0.at > $1.at }
    }

    /// Only mail from this site, received for the current code request.
    nonisolated static func codes(in mail: [Mailed], for host: String, now: Date = Date(), since: Date? = nil) -> [SentCode] {
        MailCodeMatching.codes(in: mail, now: now, since: since) {
            belongs(address: $0.address, from: $0.from, subject: $0.subject, to: host)
        }
    }

    /// A test world's mailbox, in place of Gmail's feed; nil everywhere else.
    nonisolated static let fakeMail = OSAllocatedUnfairLock<[Mailed]?>(initialState: nil)

    /// The existing synthetic inbox is independent of the page engine.
    /// A real browser-cookie feed still needs its authenticated backend.
    @MainActor static func unread(on tab: Tab, done: @escaping ([Mailed]) -> Void) {
        if let fake = fakeMail.withLock({ $0 }) { done(fake); return }
        // A Chromium tab's sign-ins reach this jar through the cookie bridge.
        unread(store: tab.pageStore, done: done)
    }

    /// Gmail's unread mail with the cookies of the store the tab signs in
    /// with. Nothing when it isn't signed in there.
    @MainActor static func unread(store: WKWebsiteDataStore, done: @escaping ([Mailed]) -> Void) {
        if let fake = fakeMail.withLock({ $0 }) { done(fake); return }
        guard let url = URL(string: "https://mail.google.com/mail/u/0/feed/atom") else { return }
        AgentRead.run(url, method: "GET", body: nil, type: nil, keepHTML: true, store: store) { got in
            let text = got["text"] as? String ?? ""
            let mail = (got["status"] as? Int) == 200 && text.contains("<feed") ? feed(text) : []
            DispatchQueue.main.async { done(mail) }
        }
    }

    // MARK: - texts

    /// The codes in texts from the last few minutes; none without Full Disk
    /// Access.
    nonisolated static func texted(for host: String, since: Date? = nil) -> [SentCode] {
        guard case .success(let texts) = AgentFiles.texts(minutes: fresh / 60) else { return [] }
        let site = Vault.registrable(host).split(separator: ".").first.map { String($0).lowercased() } ?? ""
        let siteWord = #"\b"# + NSRegularExpression.escapedPattern(for: site) + #"\b"#
        return texts.compactMap { text in
            guard text.at >= (since ?? .distantPast), site.count >= 3,
                  text.text.range(of: siteWord, options: [.caseInsensitive, .regularExpression]) != nil,
                  let code = code(in: text.text) else { return nil }
            return SentCode(id: "text:\(text.at.timeIntervalSince1970):\(code)", code: code, from: text.from, at: text.at,
                            source: .text, mine: true)
        }
    }

    // MARK: - keys kept here

    /// The site's own two-factor keys, a code each for now.
    @MainActor static func kept(for host: String) -> [SentCode] {
        let site = Vault.registrable(host)
        return OneTime.ids().compactMap { id -> SentCode? in
            let parts = id.split(separator: "\u{1}", maxSplits: 1).map(String.init)
            guard parts.count == 2, Vault.registrable(parts[0]) == site,
                  let setup = OneTime.setup(host: parts[0], user: parts[1]) else { return nil }
            return SentCode(id: "key:\(id)", code: OneTime.code(setup).code, from: parts[1], at: nil, source: .key, mine: true)
        }
    }

    /// The site's own saved code first, then its recent mail and texts.
    nonisolated static func ordered(_ codes: [SentCode], without used: Set<String>) -> [SentCode] {
        var seen = Set<String>()
        // Pick the newest message before deduplicating: mail is read first,
        // but must not hide a newer text containing the same code.
        let sorted = codes.sorted { (a, b) in
            if a.made != b.made { return a.made }
            return (a.at ?? .distantPast) > (b.at ?? .distantPast)
        }
        let kept = sorted.filter {
            $0.mine && ($0.made || !used.contains($0.id))
                && seen.insert($0.made ? $0.id : $0.code).inserted
        }
        return Array(kept.prefix(4))
    }

    // MARK: - into the page

    /// The code into the box the caret is in, the way a keyboard would: a
    /// row of one-digit boxes a digit each, anything else as typed text.
    static let fill = """
    var el = document.activeElement;
    if (!el || el.tagName !== 'INPUT' || el.disabled || el.readOnly || !/^[A-Za-z0-9]{4,10}$/.test(code)) return false;
    function row(el) {
      if (!el || el.maxLength !== 1) return [el];
      var up = el.parentElement;
      for (var i = 0; i < 3 && up; i++, up = up.parentElement) {
        var all = [].filter.call(up.querySelectorAll('input'), function (b) {
          var r = b.getBoundingClientRect(); return b.maxLength === 1 && r.width > 0 && r.height > 0;
        });
        if (all.length >= 4 && all.length <= 8) return all;
      }
      return [el];
    }
    var boxes = row(el);
    if (boxes.length === 1 && (el.getAttribute('autocomplete') || '').split(/\\s+/).indexOf('one-time-code') < 0) return false;
    // Typing can reach the page before its relay reaches the browser. Never
    // overwrite that input with a suggestion which was already on its way.
    if (boxes.some(function (b) { return b.value; })) return false;
    if (boxes.length === 1 && el.maxLength > 0 && code.length > el.maxLength) return false;
    if (boxes.length > 1 && boxes.length !== code.length) return false;
    if (boxes.length > 1 && boxes.length === code.length) {
      var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      boxes.forEach(function (b, i) {
        b.focus();
        setter.call(b, code[i]);
        b.dispatchEvent(new InputEvent('input', { bubbles: true, data: code[i], inputType: 'insertText' }));
        b.dispatchEvent(new Event('change', { bubbles: true }));
      });
      return boxes.map(function (b) { return b.value; }).join('') === code;
    }
    if (boxes.length > 1) boxes[0].focus();
    return document.execCommand('insertText', false, code);
    """
}

/// What the list under a code box is watching: which tab, until when, and
/// the codes already used, so a code goes in once.
final class CodeWatch {
    var tab: Tab.ID?
    var host = ""
    var request = CodeRequest()
    var document: String?
    var field: String?
    var generation = UUID()
    var started = Date.distantPast
    var until = Date.distantPast
    var timer: Timer?
    var mail: [SentCode] = []
    var texts: [SentCode] = []
    /// Codes Apple Passwords keeps for the site, and when it was last asked.
    var apple: [SentCode] = []
    var appleAsked = Date.distantPast
    var used = Set<String>()
    /// A code went into this tab's box; the list stays down until the box
    /// is emptied or the caret leaves.
    var pickedInto: Tab.ID?
    var lowering: DispatchWorkItem?
    /// A read is on its way: the next tick doesn't start another.
    var reading = 0
    /// The texts row has hung under this box (MailCodes.TextsRow).
    var offered = false

    func stop() {
        timer?.invalidate()
        timer = nil
        tab = nil
        generation = UUID()
        mail = []
        texts = []
        apple = []
        appleAsked = .distantPast
        offered = false
    }
}

extension Browser {
    struct CodeChoices: Equatable {
        let tab: Tab.ID
        var spot: CGRect
        var codes: [SentCode]
        let site: String
        let appleAccount: String?
        var dark: Bool?
        /// "Fill Codes from Texts" as the last row (MailCodes.TextsRow).
        var texts = false
        /// Every row: the codes, Open Apple Passwords, the texts row.
        var count: Int { codes.count + (appleAccount == nil ? 0 : 1) + (texts ? 1 : 0) }
    }

    /// How long the list keeps reading after the caret came to the box,
    /// and how often.
    static let codeWatchFor: TimeInterval = 90
    static let codeEvery: TimeInterval = 3

    /// The caret in a box that asks for a code, or gone from it (nil).
    func codeField(_ tab: Tab, spot: CGRect?) {
        let watch = codeWatch
        guard let spot else {
            if watch.pickedInto == tab.id { watch.pickedInto = nil }
            guard watch.tab == tab.id || codeList?.tab == tab.id else { return }
            watch.lowering?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if codeList?.tab == tab.id { codeList = nil }
                if watch.tab == tab.id { watch.stop() }
            }
            watch.lowering = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            return
        }
        watch.lowering?.cancel()
        if !tab.fieldEmpty {
            if codeList?.tab == tab.id { codeList = nil }
            if watch.tab == tab.id { watch.stop() }
            return
        }
        if watch.pickedInto == tab.id, tab.fieldEmpty { watch.pickedInto = nil }
        guard offersAutofill(tab), watch.pickedInto != tab.id, let host = curtain.host(of: tab.address) else { return }
        // Scrolling says where the box is every frame: only the spot moves.
        if watch.tab == tab.id, watch.host == host, watch.request == tab.fieldCodeRequest,
           watch.document == tab.fieldDocument, watch.field == tab.fieldIdentity {
            if var list = codeList, list.tab == tab.id, list.spot != spot {
                list.spot = spot
                codeList = list
            }
            return
        }
        watch.stop()
        watch.tab = tab.id
        watch.host = host
        watch.request = tab.fieldCodeRequest
        watch.document = tab.fieldDocument
        watch.field = tab.fieldIdentity
        watch.started = Date()
        watch.until = Date().addingTimeInterval(Self.codeWatchFor)
        showCodes(tab, spot: spot)
        readCodes(tab)
        keepReading(tab)
    }

    /// Mail and texts read again every few seconds until the watch is over.
    private func keepReading(_ tab: Tab) {
        codeWatch.timer?.invalidate()
        codeWatch.timer = Timer.scheduledTimer(withTimeInterval: Self.codeEvery, repeats: true) { [weak self, weak tab] _ in
            MainActor.assumeIsolated {
                guard let self, let tab, self.codeWatch.tab == tab.id else { return }
                if Date() > self.codeWatch.until { self.codeWatch.timer?.invalidate(); return }
                self.readCodes(tab)
            }
        }
    }

    /// Mail and texts, read again; the list follows what they say.
    private func readCodes(_ tab: Tab) {
        let watch = codeWatch
        let host = watch.host
        let since = watch.started.addingTimeInterval(-120)
        let generation = watch.generation
        guard watch.reading == 0, tab.fieldCode, tab.fieldEmpty, watch.tab == tab.id else { return }
        // Mail connected in yab: its own store, synced every 2 seconds
        // while the box waits, no feed to read.
        let center = MailCenter.shared
        if watch.request.source != .text, watch.request.source != .key, center.connected, prefs.mailCodes {
            center.quick(for: 20)
            watch.mail = MailCodes.codes(in: center.recent(minutes: MailCodes.fresh / 60), for: host, since: since)
            showCodes(tab, spot: nil)
        } else if watch.request.source != .text, watch.request.source != .key,
                  prefs.mailCodes {
            watch.reading += 1
            MailCodes.unread(on: tab) { [weak self, weak tab] mail in
                guard let self else { return }
                watch.reading -= 1
                guard watch.generation == generation, watch.tab == tab?.id, let tab else { return }
                watch.mail = MailCodes.codes(in: mail, for: host, since: since)
                self.showCodes(tab, spot: nil)
            }
        }
        // Apple Passwords' authenticator codes, asked again now and then so
        // the one shown is about current; the pick asks once more.
        if watch.request.source == nil || watch.request.source == .key,
           Date().timeIntervalSince(watch.appleAsked) > 20, let page = Self.codePage(tab.address) {
            watch.appleAsked = Date()
            let user = tab.account(on: host)
            Task { [weak self, weak tab] in
                guard await ApplePasswords.shared.canFillCodes else { return }
                let found = (try? await ApplePasswords.shared.codes(page: page, user: user)) ?? []
                guard let self, watch.generation == generation, let tab, watch.tab == tab.id else { return }
                watch.apple = found.map {
                    SentCode(id: "apple:\($0.site)\u{1}\($0.user)", code: $0.code, from: $0.user, at: nil, source: .apple, mine: true)
                }
                self.showCodes(tab, spot: nil)
            }
        }
        // Unset, texts are read where they can be: a Mac without Full Disk
        // Access gives nothing, and nothing is asked.
        if watch.request.source != .mail, watch.request.source != .key,
           prefs.codesFromTexts || Store.settings.object(forKey: "codes.texts") == nil {
            watch.reading += 1
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak tab] in
                let readable = MailCodes.canReadTexts()
                let texts = readable ? MailCodes.texted(for: host, since: since) : []
                DispatchQueue.main.async {
                    MailCodes.textsReadable = readable
                    guard let self else { return }
                    watch.reading -= 1
                    guard watch.generation == generation, watch.tab == tab?.id, let tab else { return }
                    watch.texts = texts
                    self.showCodes(tab, spot: nil)
                }
            }
        }
    }

    /// The list as the codes found so far make it; a spot for a new box.
    private func showCodes(_ tab: Tab, spot: CGRect?) {
        let watch = codeWatch
        guard offersAutofill(tab), watch.tab == tab.id, tab.fieldCode, tab.fieldEmpty,
              watch.request == tab.fieldCodeRequest,
              watch.document == tab.fieldDocument, watch.field == tab.fieldIdentity else { return }
        let keys = MailCodes.kept(for: watch.host) + watch.apple
        let codes = MailCodes.ordered((keys + watch.mail + watch.texts).filter(watch.request.accepts).filter { MailCodeState.shared.available($0) }, without: watch.used)
        let account = tab.address?.scheme?.lowercased() == "https" ? tab.account(on: watch.host) : nil
        // The code itself replaces the row that only opens Passwords.
        let appleAccount = (watch.request.source == nil || watch.request.source == .key) && watch.apple.isEmpty
            ? account.flatMap { AppleCodeHints.has(host: watch.host, user: $0) ? $0 : nil } : nil
        guard let spot = spot ?? (codeList?.tab == tab.id ? codeList?.spot : nil) ?? tab.fieldSpot else { return }
        let texts = (watch.request.source == nil || watch.request.source == .text)
            && MailCodes.TextsRow.offers(prefs, here: watch.offered)
        if texts, !watch.offered {
            watch.offered = true
            MailCodes.TextsRow.shown += 1
        }
        if codes.isEmpty && appleAccount == nil && !texts {
            if codeList?.tab == tab.id { codeList = nil }
            return
        }
        let was = codeList
        codeList = CodeChoices(tab: tab.id, spot: spot, codes: codes, site: watch.host,
                               appleAccount: appleAccount, dark: tab.fieldDark, texts: texts)
        // The lit row stays on the code it was on when a new one comes.
        if let was, was.tab == tab.id, let lit = codeLit, was.codes.indices.contains(lit),
           let same = codes.firstIndex(where: { $0.id == was.codes[lit].id }) {
            codeLit = same
        } else if let was, was.tab == tab.id, was.appleAccount != nil,
                  codeLit == was.codes.count, appleAccount != nil {
            codeLit = codes.count
        } else if let was, was.tab == tab.id, was.texts, texts, codeLit == was.count - 1,
                  was.codes.map(\.id) == codes.map(\.id), let list = codeList {
            // Still on the texts row, nothing new over it. A code that
            // comes takes the light: it is what Return should put in.
            codeLit = list.count - 1
        } else {
            codeLit = 0
        }
    }

    func openAppleCode() {
        guard let list = codeList, let user = list.appleAccount,
              let tab = autofillTab(list.tab),
              tab.fieldCode, tab.fieldEmpty,
              tab.fieldCodeRequest.source == nil || tab.fieldCodeRequest.source == .key,
              tab.address?.scheme?.lowercased() == "https",
              curtain.host(of: tab.address) == list.site,
              tab.account(on: list.site)?.lowercased() == user.lowercased(),
              AppleCodeHints.has(host: list.site, user: user), tab.openAppleCode()
        else { return }
        codeList = nil
        codeWatch.pickedInto = tab.id
        codeWatch.stop()
    }

    func pickCode(_ code: SentCode) {
        pickCode(code, appleCode: { page, user in
            // A pick is an authenticated search, not another 10-second
            // ghost search. Only cmd 17 waits for the system auth sheet.
            return try? await ApplePasswords.shared.code(page: page, user: user)
        })
    }

    @discardableResult
    func pickCode(_ code: SentCode, appleCode: @escaping @MainActor (String, String) async -> String?) -> Task<Void, Never>? {
        guard let list = codeList, let tab = autofillTab(list.tab), let web = tab.builtPage else { return nil }
        // What was offered for one site is never put into another's page.
        guard curtain.host(of: tab.address) == list.site else { codeList = nil; return nil }
        guard tab.fieldCode, tab.fieldEmpty, tab.fieldCodeRequest.accepts(code), list.codes.contains(code),
              MailCodeState.shared.available(code), codeWatch.document == tab.fieldDocument,
              codeWatch.field == tab.fieldIdentity, codeWatch.request == tab.fieldCodeRequest else {
            codeList = nil
            return nil
        }
        let document = tab.fieldDocument, field = tab.fieldIdentity, request = tab.fieldCodeRequest
        codeList = nil
        codeWatch.pickedInto = tab.id
        codeWatch.stop()
        web.window?.makeFirstResponder(web)
        guard code.source == .apple else { putCode(code, into: web, site: list.site); return nil }
        // Touch ID may finish after a navigation or a different challenge.
        // Only the same document, field, request and HTTPS page may take it.
        guard let page = Self.codePage(tab.address), document != nil, field != nil else { return nil }
        return Task { [weak self, weak tab, weak web] in
            guard let made = await appleCode(page, code.from), !made.isEmpty,
                  let self, let tab, let web, tab.builtPage === web, !tab.gone, !tab.asleep,
                  Self.codePage(tab.address) == page, self.curtain.host(of: tab.address) == list.site,
                  tab.fieldDocument == document, tab.fieldIdentity == field,
                  tab.waitingCode?.document == document, tab.waitingCode?.field == field,
                  tab.waitingCode?.request == request,
                  (!tab.typing || (tab.fieldCode && tab.fieldCodeRequest == request && tab.fieldEmpty)) else {
                ApplePasswords.log.notice("code pick discarded: challenge changed or helper returned no code")
                return
            }
            let fresh = SentCode(id: code.id, code: made, from: code.from, at: nil, source: .apple, mine: true)
            // The field was bound when the row was picked (document, field,
            // request, above); the Touch ID sheet may hold key still.
            guard request.accepts(fresh) else {
                ApplePasswords.log.notice("code pick discarded: field request doesn't accept the code")
                return
            }
            guard self.offersAutofill(tab, key: false) else {
                ApplePasswords.log.notice("code pick discarded: tab no longer takes autofill")
                return
            }
            web.window?.makeFirstResponder(web)
            self.putCode(fresh, into: web, site: list.site, document: document, field: field)
        }
    }

    /// The page a code is asked for, as Passwords matches it: https, no
    /// query or fragment.
    nonisolated static func codePage(_ address: URL?) -> String? {
        guard let address, address.scheme?.lowercased() == "https",
              var parts = URLComponents(url: address, resolvingAgainstBaseURL: false) else { return nil }
        parts.query = nil
        parts.fragment = nil
        return parts.url?.absoluteString
    }

    private func putCode(_ code: SentCode, into web: any PageHandle, site: String, document: String? = nil, field: String? = nil) {
        let bound = document != nil && field != nil
        let script = bound ? "return !!window.__yabForms && window.__yabForms.codeFill(document, field, code, true, 'key')" : MailCodes.fill
        var arguments: [String: Any] = ["code": code.code]
        if let document, let field { arguments["document"] = document; arguments["field"] = field }
        web.call(script, arguments: arguments, in: bound ? .yab : .page) { result in
            // Archive only after the page accepted the fill, never after a
            // stale suggestion lost a race with manual input.
            if bound {
                let accepted = (try? result.get()) as? Bool == true
                ApplePasswords.log.notice("code field accepted fill: \(accepted)")
            }
            if case .success(let filled) = result, filled as? Bool == true {
                MainActor.assumeIsolated {
                    self.codeWatch.used.insert(code.id)
                    MailCodeState.shared.used(code, site: site)
                    CodeClip.shared.consumed(code.code, site: site)
                }
            }
        }
    }

    /// A remembered field belongs to its document and sender's registrable domain.
    func codeBox(for item: MailCodeItem) -> Tab? {
        guard [.fresh, .copied].contains(MailCodeState.shared.state(item)) else { return nil }
        return tabs.first { tab in
            guard let field = tab.waitingCode, let host = tab.address?.host(), tab.builtPage != nil,
                  field.address == tab.address, field.request.accepts(item.sent),
                  tab.address?.scheme == "https" || Store.testing && ["127.0.0.1", "localhost"].contains(host),
                  !Agents.shared.sealed(tab),
                  MailCodes.belongs(address: item.address, from: "", subject: "", to: host) else { return false }
            return true
        }
    }

    func fillCode(_ item: MailCodeItem, into tab: Tab) {
        guard codeBox(for: item)?.id == tab.id, let field = tab.waitingCode, let web = tab.builtPage,
              let site = tab.address?.host() else { return }
        let arguments: [String: Any] = ["document": field.document, "field": field.field, "code": item.read.code]
        // Ask in the isolated forms world before bringing a stale destination forward.
        web.call("return !!window.__yabForms && window.__yabForms.codeFill(document, field, code, false)",
                                arguments: arguments, in: .yab) { [weak self, weak tab] result in
            MainActor.assumeIsolated {
                guard let self, let tab, case .success(let ready) = result, ready as? Bool == true,
                      self.codeBox(for: item)?.id == tab.id else { return }
                if self.inMail { self.leaveMail() }
                self.select(tab)
                web.window?.makeFirstResponder(web)
                web.call("return !!window.__yabForms && window.__yabForms.codeFill(document, field, code, true)",
                                        arguments: arguments, in: .yab) { result in
                    MainActor.assumeIsolated {
                        if case .success(let filled) = result, filled as? Bool == true {
                            tab.waitingCode = nil
                            MailCodeState.shared.used(item.sent, site: site)
                            CodeClip.shared.consumed(item.read.code, site: site)
                        }
                    }
                }
            }
        }
    }

    /// The texts row, taken: From Messages on, and System Settings at the
    /// place Full Disk Access is given. Nothing is asked by Yab itself, and
    /// the row is done with. The box keeps reading, so a code that lands
    /// once you're back shows under it.
    func allowTextCodes() {
        guard let list = codeList, let tab = autofillTab(list.tab), tab.fieldCode, tab.fieldEmpty,
              tab.fieldCodeRequest.source == nil || tab.fieldCodeRequest.source == .text else { return }
        prefs.textCodes = true
        MailCodes.TextsRow.shown = MailCodes.TextsRow.times
        let watch = codeWatch
        // A trip to System Settings takes a while: the box reads on for as
        // long again from now.
        if watch.tab == tab.id {
            watch.until = Date().addingTimeInterval(Self.codeWatchFor)
            if watch.timer?.isValid != true { keepReading(tab) }
        }
        watch.offered = false
        showCodes(tab, spot: nil)
        if let place = MailCodes.TextsRow.place { NSWorkspace.shared.open(place) }
    }

    func moveCode(_ by: Int) {
        guard let list = codeList else { return }
        let count = list.count
        guard count > 0 else { return }
        codeLit = codeLit.map { ($0 + by + count) % count } ?? (by > 0 ? 0 : count - 1)
    }

    func pointCode(_ at: Int) {
        if codeList != nil { codeLit = at }
    }

    /// Return on a lit code. False when nothing is lit, so the key goes on.
    func pickLitCode() -> Bool {
        guard let lit = codeLit, let list = codeList else { return false }
        if list.codes.indices.contains(lit) { pickCode(list.codes[lit]) }
        else if lit == list.codes.count, list.appleAccount != nil { openAppleCode() }
        else if list.texts, lit == list.count - 1 { allowTextCodes() }
        else { return false }
        return true
    }
}
