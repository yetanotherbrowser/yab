import CoreGraphics
import Foundation

/// What the chrome's controls do. The surfaces they open are drawn by their
/// own layers; these only decide where a touch leads.
extension AppModel {
    /// Keep the latest reversible browser action, like the existing close receipt.
    /// Explicit grouping makes an action available before the next run-loop turn.
    func registerActionUndo(_ name: String, perform: @escaping (AppModel) -> Void) {
        actionUndo.removeAllActions()
        actionUndo.beginUndoGrouping()
        actionUndo.registerUndo(withTarget: browser) { [weak self] _ in
            guard let self else { return }
            perform(self)
        }
        actionUndo.setActionName(name)
        actionUndo.endUndoGrouping()
    }

    /// Back in the page's own history; at the first page of a tab a link
    /// opened, back to that tab, this one closing (with Undo); else nothing.
    func goBack() {
        guard let tab = browser.tab else { return }
        switch backStack.route(for: tab) {
        case .history:
            Haptics.play(.soft, reason: Haptics.Reason.reload)
            Task { @MainActor in _ = await pages.back(tab.id) }
        case .opener:
            backStack.backToOpener()
        case .nowhere:
            break
        }
    }

    /// The Mac hint crossed or swept away: it stays away for this Mac tab, which
    /// the sync's `offered` will not offer again.
    func dismissNow() {
        switch nowItem?.kind {
        case .handoff?: Motion.nowGone.run { tasks.handoff = nil }
        // A page from the Mac stays in Today; only its card goes.
        case .arrived?: Motion.nowGone.run { tasks.arrived = nil }
        default: break
        }
    }

    /// A dismissal belongs to the exact rendered observation. A later failure,
    /// result or a different account must never borrow an old swipe.
    func nowDismissal(for item: NowItem) -> (() -> Bool)? {
        if item.chip != nil {
            return { [weak self] in
                guard let self, self.nowItem == item else { return false }
                self.dismissNow()
                return true
            }
        }
        guard !isFixture, let snapshot = sync.visibleLiveTask(item.id), snapshot.dismissibleNotice else { return nil }
        return { [weak self] in
            guard let self, self.nowItem?.id == item.id,
                  self.sync.visibleLiveTask(item.id) == snapshot else { return false }
            var saved = false
            Motion.nowGone.run {
                saved = self.tasks.markLiveSeen(snapshot)
                if !saved {
                    self.say("Couldn’t save read status on this \(DeviceWord.name)", glyph: .macbook)
                }
            }
            return saved
        }
    }

    /// A tap on the Now line, or on its action capsule (Review, Enter Code,
    /// Retry). Every surface it opens grows out of the line.
    func tapNow(action: String?, from frame: CGRect) {
        guard let item = nowItem else { return }
        switch item.kind {
        case .handoff:
            // The Mac's tab, here, at the same place of the page.
            if let tab = tasks.handoff { browser.select(tab.id) }
            tasks.handoff = nil
        case .arrived:
            // Open: the page the Mac sent, in front, from its place in Today.
            if let page = tasks.arrived { browser.select(page.tab) }
            Motion.nowGone.run { tasks.arrived = nil }
        case .parked:
            chats.parked = nil
            Motion.nowToChat.run { surfaces.openChat(.chat(item.id), from: frame) }
        case .download:
            tapDownloadLine()
        default:
            // A task's: the code, the yes, Retry or its chat, out of the line (Tasks/TaskDesk).
            taskDesk.tapNow(item, action: action, from: frame)
        }
    }

    /// Join Your Mac from the welcome, or Sync from Settings › Your Mac:
    /// sync's join (Join/JoinContent) in Settings' sheet, grown out of the
    /// button or the row.
    func openJoin(from origin: CGRect? = nil) {
        surfaces.openJoin(from: origin)
        sync.beginJoin()
    }

    /// Says a toast with the haptic its moment wants, if any.
    func say(_ text: String, glyph: GlyphName) {
        Motion.toastIn.run { surfaces.showToast(text, glyph: glyph) }
    }
}
