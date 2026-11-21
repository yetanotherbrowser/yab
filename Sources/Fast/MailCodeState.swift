import AppKit
import Combine

extension MailCodes {
    enum State: String { case fresh, copied, expired, used }
}

/// The same message identity in Mail, notifications, agents and the field's list.
struct MailCodeItem: Identifiable, Equatable {
    let account: String
    let message: String
    let thread: String
    let address: String
    let at: Date
    let read: MailCodeRead
    var id: String { "mail:\(account):\(message)" }
    var expires: Date { read.expires ?? at.addingTimeInterval(MailCodes.fresh) }

    var sent: SentCode {
        SentCode(id: id, code: read.code, from: address, at: at, source: .mail, mine: true,
                 thread: thread, account: account, message: message, read: read)
    }
}

@MainActor
final class MailCodeState: ObservableObject {
    static let shared: MailCodeState = {
        let state = MailCodeState()
        // A newer code, or one entered elsewhere, comes with the mail: what
        // the old one reads changes then, not at a time this side can know.
        state.mail = MailCenter.shared.$changed.dropFirst().sink { [weak state] _ in state?.revision &+= 1 }
        return state
    }()
    private var mail: AnyCancellable?
    @Published private(set) var revision = 0
    /// Set for the moment a code read here next reads differently, and only
    /// then: a clock every second redrew every code on screen all day.
    private(set) var timer: Timer?
    private var due: Date?
    private var uses = Set<String>()
    private var copiedID: String?
    private var copiedCount: Int?
    private var cachedRevision = -1
    private var items: [String: MailCodeItem] = [:]
    private var absent = Set<String>()
    private(set) var copyTimes: [String: Date] = [:]

    /// A page started or stopped waiting for a code (Tab.waitingCode): a
    /// card's "Fill on" button follows it.
    static let codeBoxMoved = PassthroughSubject<Void, Never>()

    /// Told on the next turn of the main loop: a page can be built while a view is drawn.
    static func boxMoved() {
        DispatchQueue.main.async { codeBoxMoved.send() }
    }
    private var boxes: AnyCancellable?

    init() {
        boxes = Self.codeBoxMoved.sink { [weak self] in self?.revision &+= 1 }
    }

    /// The sender's next newer code's date per account and message, as of the mail center's last change.
    private var replaced: [String: Date?] = [:]
    private var replacedRevision = -1

    private func replacedAt(_ item: MailCodeItem) -> Date? {
        if replacedRevision != MailCenter.shared.changed {
            replacedRevision = MailCenter.shared.changed
            replaced.removeAll()
        }
        let key = item.account + "|" + item.message
        if let known = replaced[key] { return known }
        let at = MailCenter.shared.engines[item.account]?.store.codeReplacedAt(message: item.message)
        replaced[key] = .some(at)
        return at
    }

    /// When a code reads differently next: its minutes left going down by
    /// one, its end, or one dated ahead coming due. Nil once used or expired.
    /// `replacedAt`: the date of the sender's next newer code, which replaces
    /// this one half a minute before it (MailStore.codeReplaced).
    nonisolated static func nextChange(_ item: MailCodeItem, state: MailCodes.State, now: Date, replacedAt: Date? = nil) -> Date? {
        if item.at > now.addingTimeInterval(30) { return item.at.addingTimeInterval(-30) }
        guard state == .fresh || state == .copied else { return nil }
        let left = item.expires.timeIntervalSince(now)
        guard left > 0 else { return nil }
        let minute = item.expires.addingTimeInterval(-60 * (ceil(left / 60) - 1))
        guard let replaced = replacedAt?.addingTimeInterval(-30), replaced > now else { return minute }
        return min(minute, replaced)
    }

    private func wake(at date: Date) {
        if let due, due <= date, timer != nil { return }
        due = date
        timer?.invalidate()
        let timer = Timer(fire: date.addingTimeInterval(0.05), interval: 0, repeats: false) { [weak self] _ in
            // Crash #1010 faults in executor lookup, before the tick runs.
            // Foundation calls this timer on the main run loop.
            AppKitMainThread.sync { self?.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Every code drawn reads itself again, and asks for the next wake.
    private func tick() {
        timer = nil; due = nil
        revision &+= 1
    }

    /// The clipboard no longer holds the code copied: it reads fresh again.
    func clipboardMoved() { revision &+= 1 }

    func item(account: String, thread: String, message: String? = nil) -> MailCodeItem? {
        if cachedRevision != MailCenter.shared.changed {
            cachedRevision = MailCenter.shared.changed
            items.removeAll(); absent.removeAll()
        }
        let key = account + "|" + thread + "|" + (message ?? "")
        if let item = items[key] { return item }
        if absent.contains(key) { return nil }
        guard let store = MailCenter.shared.engines[account]?.store else { return nil }
        let id = message ?? store.codeMessage(thread: thread)
        if let id, let read = store.code(message: id), let mail = store.message(id) {
            let item = MailCodeItem(account: account, message: id, thread: mail.thread, address: mail.from.address, at: mail.date, read: read)
            items[key] = item
            return item
        }
        // Already sorted ordinary mail never needs its HTML parsed on the UI thread.
        if let sensed = store.sensed(thread), sensed.kind != .code { absent.insert(key); return nil }
        // A header-only sync or an old archived thread may not have reached Sense.
        let mail = message.flatMap { store.message($0) } ?? store.messages(thread: thread).last
        guard let mail, MailSense.kind(mail, bulk: false) == .code,
              let read = MailCodeWords.read(subject: mail.subject, text: mail.text ?? mail.snippet,
                                            html: mail.html, received: mail.date) else { absent.insert(key); return nil }
        store.keepCode(read, message: mail)
        let item = MailCodeItem(account: account, message: mail.id, thread: thread, address: mail.from.address, at: mail.date, read: read)
        items[key] = item
        return item
    }

    func state(_ item: MailCodeItem, now: Date = Date()) -> MailCodes.State {
        let state = reading(item, now: now)
        let replacedAt = state == .fresh || state == .copied ? replacedAt(item) : nil
        if let next = Self.nextChange(item, state: state, now: now, replacedAt: replacedAt) { wake(at: next) }
        return state
    }

    private func reading(_ item: MailCodeItem, now: Date) -> MailCodes.State {
        let store = MailCenter.shared.engines[item.account]?.store
        if uses.contains(item.id) || store?.codeUse(message: item.message) != nil { return .used }
        if item.at > now.addingTimeInterval(30) || now >= item.expires || store?.codeReplaced(message: item.message, now: now) == true { return .expired }
        if copiedID == item.id, copiedCount == NSPasteboard.general.changeCount { return .copied }
        return .fresh
    }

    func available(_ code: SentCode) -> Bool {
        if code.made { return true }
        guard !uses.contains(code.id) else { return false }
        guard let account = code.account, let thread = code.thread,
              let item = item(account: account, thread: thread, message: code.message) else { return true }
        return code.code == item.read.code && [.fresh, .copied].contains(state(item))
    }

    func copy(_ item: MailCodeItem) {
        CodeClip.shared.put(item.read, id: item.id, expires: item.expires, sent: item.sent)
    }

    func copied(_ id: String, count: Int) {
        let since = Date()
        copyTimes[id] = since
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.copyTimes[id] == since else { return }
            self.copyTimes[id] = nil
            self.revision &+= 1
        }
        copiedID = id; copiedCount = count; revision &+= 1
    }

    func used(_ code: SentCode, site: String) {
        guard !code.made else { return }
        guard uses.insert(code.id).inserted else { return }
        if let account = code.account, let message = code.message {
            MailCenter.shared.engines[account]?.store.useCode(message: message, site: site)
        }
        revision &+= 1
        if MailCodes.archivesUsed, let account = code.account, let thread = code.thread {
            MailCenter.shared.act(.archive, thread: thread, account: account)
        }
    }
}

@MainActor
extension CodeClip {
    static let shared = CodeClip(onCopy: { MailCodeState.shared.copied($0, count: $1) },
                                 onUse: { MailCodeState.shared.used($0, site: $1) },
                                 canKeep: { MailCodeState.shared.available($0) },
                                 onForget: { MailCodeState.shared.clipboardMoved() })
}
