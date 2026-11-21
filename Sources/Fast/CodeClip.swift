import AppKit
import MailCore

/// Password-style clipboard ownership. Only the write we own may be erased.
@MainActor
final class CodeClip {
    let board: NSPasteboard
    private(set) var id: String?
    private(set) var read: MailCodeRead?
    private(set) var sent: SentCode?
    private(set) var count: Int?
    private(set) var expires: Date?
    private var timer: Timer?
    private let onCopy: (String, Int) -> Void
    private let onUse: (SentCode, String) -> Void
    private let canKeep: (SentCode) -> Bool
    private let onForget: () -> Void

    init(board: NSPasteboard = .general, onCopy: @escaping (String, Int) -> Void = { _, _ in },
         onUse: @escaping (SentCode, String) -> Void = { _, _ in },
         canKeep: @escaping (SentCode) -> Bool = { _ in true }, onForget: @escaping () -> Void = {}) {
        self.board = board; self.onCopy = onCopy; self.onUse = onUse; self.canKeep = canKeep; self.onForget = onForget
    }

    deinit { timer?.invalidate() }

    func put(_ read: MailCodeRead, id: String, expires: Date? = nil, sent: SentCode? = nil, now: Date = Date()) {
        timer?.invalidate()
        // Universal Clipboard stays available, including on iPhone.
        board.prepareForNewContents(with: [])
        board.setString(read.code, forType: .string)
        board.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        board.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        self.id = id; self.read = read; self.sent = sent; self.count = board.changeCount
        let deadline = expires ?? read.expires ?? now.addingTimeInterval(MailCodeRead.defaultLifetime)
        // Deliberately copying an expired code still gives the person time to paste it.
        self.expires = deadline > now ? deadline : now.addingTimeInterval(MailCodeRead.defaultLifetime)
        onCopy(id, board.changeCount)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func tick(now: Date = Date()) {
        guard let count else { return }
        guard board.changeCount == count else { forget(); return }
        if let sent, !canKeep(sent) { clear(); return }
        if let expires, now >= expires { clear() }
    }

    @discardableResult
    func consumed(_ code: String, site: String) -> Bool {
        guard let read, count == board.changeCount, read.code == code else { return false }
        if let sent { onUse(sent, site) }
        clear()
        return true
    }

    private func clear() {
        if let count, board.changeCount == count { board.clearContents() }
        forget()
    }

    private func forget() {
        timer?.invalidate(); timer = nil
        let held = id != nil
        id = nil; read = nil; count = nil; expires = nil; sent = nil
        if held { onForget() }
    }
}
