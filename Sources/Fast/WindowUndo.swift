import AppKit

// ⌘Z for the window. Outside anything typed into, the last thing done by
// hand comes back as it was: a tab closed, a pin, a name, a folder, a
// drag, tabs sent to another space, a space deleted. One stack for all of
// them, newest last, so ⌘Z takes back what was done last, not the last
// tab closed whatever came after it. A notice's Undo is the same step,
// and a notice with Undo up answers ⌘Z first. A page that keeps ⌘Z for
// itself (a canvas, Get to Know) has it first (ContentView.take).

/// One thing ⌘Z takes back.
enum UndoStep {
    /// Tabs closed together, by their ghosts. Gone from Recently Closed
    /// another way (⌘⇧T, the History menu), and the step is passed over.
    case closed(Set<UUID>)
    /// Anything else, and how to take it back; `until`, when it no longer
    /// can (a deleted space's sign-ins erased by then).
    case done(id: UUID, until: Date?, back: () -> Void)

    var id: UUID? {
        guard case .done(let id, _, _) = self else { return nil }
        return id
    }
}

/// The row as it stood: its order, what is pinned, kept and named, its
/// folders and its pairs. Put back whole, which is all an arrangement
/// needs: no page is opened or closed by it.
@MainActor
struct RowShape {
    struct Mark {
        let tab: Tab
        let pin: String?
        let kept: Bool
        let nest: Nest?
        let name: String?
        let everywhere: UUID?

        func same(as other: Mark) -> Bool {
            tab === other.tab && pin == other.pin && kept == other.kept && nest === other.nest
                && name == other.name && everywhere == other.everywhere
        }
    }

    struct Fold {
        let nest: Nest
        let name: String
        let parent: Nest?
        let mark: String?
        let color: String?
        /// Where an empty one stood among the kept (Nest.stand).
        var stand: Nest.Stand? = nil
        var ordinaryToday = false
        var fleeting = false
        var search: String? = nil

        func same(as other: Fold) -> Bool {
            nest === other.nest && name == other.name && parent === other.parent && mark == other.mark && color == other.color && stand == other.stand && ordinaryToday == other.ordinaryToday && fleeting == other.fleeting && search == other.search
        }
    }

    let space: UUID
    let marks: [Mark]
    let folds: [Fold]
    let empties: [Nest]
    let pairs: [Pair]

    init(_ browser: Browser) {
        space = browser.spaceID
        marks = browser.tabs.map { Mark(tab: $0, pin: $0.pin, kept: $0.kept, nest: $0.nest, name: $0.name, everywhere: $0.everywhere) }
        folds = browser.nests.map { Fold(nest: $0, name: $0.name, parent: $0.parent, mark: $0.customMark, color: $0.color, stand: $0.stand, ordinaryToday: $0.ordinaryToday, fleeting: $0.fleeting, search: $0.search) }
        empties = Folders.shared.empties
        pairs = browser.pairs
    }

    func same(as other: RowShape) -> Bool {
        space == other.space && pairs == other.pairs
            && marks.count == other.marks.count && zip(marks, other.marks).allSatisfy { $0.same(as: $1) }
            && folds.count == other.folds.count && zip(folds, other.folds).allSatisfy { $0.same(as: $1) }
            && empties.count == other.empties.count && zip(empties, other.empties).allSatisfy { $0 === $1 }
    }
}

extension Browser {
    /// Whether what is happening now is the person's doing: a press, a key
    /// or a menu a moment ago, not an agent's or a timer's.
    static var handMade: Bool {
        if pretendHand { return true }
        guard !PageView.agentActing, let event = NSApp?.currentEvent else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .otherMouseUp, .keyDown, .keyUp:
            return ProcessInfo.processInfo.systemUptime - event.timestamp < 1.5
        default:
            return false
        }
    }

    /// Whether a change to the row starts a step of its own now: by hand,
    /// and not inside another, a drag held or an undo.
    var startsArranging: Bool {
        arrangeDepth == 0 && !undoing && heldShape.map { CACurrentMediaTime() - $0.at > 120 } != false && Browser.handMade
    }

    /// Tests: every change counts as made by hand.
    static var pretendHand = false

    /// A change to the row made by hand, one step for ⌘Z however many
    /// changes it took. Inside another, or a drag held, it is that one's.
    @discardableResult
    func arranging<T>(_ change: () -> T) -> T {
        guard startsArranging else { return change() }
        let before = RowShape(self)
        let made = steps.count
        arrangeDepth += 1
        let out = change()
        arrangeDepth -= 1
        // A step of its own made inside (a tab closed, the mail pin gone)
        // is this change's.
        if steps.count == made, !RowShape(self).same(as: before) { did { [weak self] in self?.put(before) } }
        return out
    }

    /// A drag or a letter being typed: what the row was when it started,
    /// for one step when it is let go (`letGoArranging`).
    func holdArranging() {
        guard !undoing else { return }
        if let held = heldShape, CACurrentMediaTime() - held.at < 120 { return }
        heldShape = (RowShape(self), CACurrentMediaTime())
    }

    /// A tab gone meanwhile, to another space or window, or closed, is
    /// that act's own step, and the drag leaves none.
    func letGoArranging() {
        guard let held = heldShape else { return }
        heldShape = nil
        let now = RowShape(self)
        guard Set(now.marks.map(\.tab.id)) == Set(held.shape.marks.map(\.tab.id)), !now.same(as: held.shape) else { return }
        did { [weak self] in self?.put(held.shape) }
    }

    /// The row as it was. Tabs opened since stay, among today's; tabs
    /// closed since are Recently Closed's.
    func put(_ shape: RowShape, replacing: [Tab.ID: Tab] = [:]) {
        if spaceID != shape.space {
            guard spaces.contains(where: { $0.id == shape.space }) else { return }
            switchSpace(to: shape.space)
        }
        for fold in shape.folds {
            if fold.nest.name != fold.name { fold.nest.name = fold.name }
            fold.nest.parent = fold.parent
            fold.nest.ordinaryToday = fold.ordinaryToday
            fold.nest.fleeting = fold.fleeting
            fold.nest.search = fold.search
            if fold.nest.stand != fold.stand { fold.nest.stand = fold.stand }
            if fold.nest.customMark != fold.mark { fold.nest.customMark = fold.mark }
            if fold.nest.color != fold.color { fold.nest.color = fold.color }
        }
        let here = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var row: [Tab] = []
        for mark in shape.marks {
            guard let tab = here[mark.tab.id] ?? replacing[mark.tab.id] else { continue }
            if tab.pin != mark.pin { tab.pin = mark.pin }
            if tab.kept != mark.kept { tab.kept = mark.kept }
            if tab.nest !== mark.nest { tab.nest = mark.nest }
            if tab.name != mark.name { tab.name = mark.name }
            if tab.everywhere != mark.everywhere { tab.everywhere = mark.everywhere }
            row.append(tab)
        }
        let known = Set(row.map(\.id))
        row += tabs.filter { !known.contains($0.id) }
        if let editing = editingPin, here[editing]?.pin == nil { editingPin = nil }
        lay(row.filter { $0.pin != nil } + row.filter { $0.pin == nil && $0.kept } + row.filter { $0.pin == nil && !$0.kept })
        let ids = Set(tabs.map(\.id))
        let pairsBack = shape.pairs.compactMap { pair in pair.mapped { replacing[$0]?.id ?? $0 } }.filter { $0.ids.allSatisfy(ids.contains) }
        if pairs != pairsBack { pairs = pairsBack }
        folderBook.putEmpties(shape.empties)
        folderBook.refresh()
        writeSession(now: true)
    }

    /// Something done that ⌘Z can take back; its id, for a notice's Undo
    /// to take the same step (`undo(step:)`).
    @discardableResult
    func did(until: Date? = nil, _ back: @escaping () -> Void) -> UUID {
        let id = UUID()
        guard !undoing else { return id }
        // Made while a drag was held: this is the drag's step.
        heldShape = nil
        steps.append(.done(id: id, until: until, back: back))
        if steps.count > 50 { steps.removeFirst(steps.count - 50) }
        return id
    }

    /// Tabs just closed, as Recently Closed has them.
    func didClose(_ ghosts: Set<UUID>) {
        guard !undoing, !ghosts.isEmpty else { return }
        steps.append(.closed(ghosts))
        if steps.count > 50 { steps.removeFirst(steps.count - 50) }
    }

    /// A notice's Undo: its step, wherever it is in the stack.
    func undo(step id: UUID) {
        guard let at = steps.firstIndex(where: { $0.id == id }),
              case .done(_, let until, let back) = steps.remove(at: at) else { return }
        if let until, until < Date() { return }
        undoing = true
        back()
        undoing = false
    }

    /// Whether ⌘Z has anything in the window to take back.
    var canUndoWindow: Bool {
        if toaster.shown, toaster.undo != nil, toaster.act == nil { return true }
        if active?.offer?.stage == .never { return true }
        return !ghosts.isEmpty || steps.contains { step in
            switch step {
            case .closed(let ids): ghosts.contains { ids.contains($0.id) }
            case .done(_, let until, _): until.map { $0 > Date() } ?? true
            }
        }
    }

    /// ⌘Z outside text: the notice's Undo if one is up, else the last
    /// thing done, else the last tab closed (from before this launch).
    @discardableResult
    func undoWindow() -> Bool {
        if toaster.shown, toaster.undo != nil, toaster.act == nil {
            toaster.undone()
            return true
        }
        if let tab = active, tab.offer?.stage == .never {
            undoNever(tab)
            return true
        }
        while let step = steps.popLast() {
            switch step {
            case .closed(let ids):
                guard let ghost = ghosts.last(where: { ids.contains($0.id) }) else { continue }
                undoing = true
                reopen(from: ghost)
                undoing = false
                return true
            case .done(_, let until, let back):
                if let until, until < Date() { continue }
                undoing = true
                back()
                undoing = false
                return true
            }
        }
        guard !ghosts.isEmpty else { return false }
        undoing = true
        reopen()
        undoing = false
        return true
    }
}

extension Browser {
    /// Remove Folder and its tabs: one step back, the tabs kept in it again
    /// and the empty folders that were in it with them.
    func removeFolder(_ nest: Nest, with group: [Tab]) {
        let empties = folderBook.empties
        let before = steps.count
        // The empty folders in it go with it, rather than keep it.
        folderBook.removeEmpty(nest)
        discard(group, rekept: true)
        guard steps.count > before, case .closed(let ids) = steps.removeLast() else { return }
        did { [weak self] in
            guard let self else { return }
            folderBook.putEmpties(empties)
            if let ghost = ghosts.last(where: { ids.contains($0.id) }) { reopen(from: ghost) }
        }
    }
}

/// Whether a step's other way out came first: its Undo, or its time.
final class Undone {
    var done = false
}

extension SettingsWindow {
    /// Done in Settings: ⌘Z there takes it back, as the Edit menu's Undo
    /// does in any window, and the corner offers Undo. Once, either way.
    func did(_ words: String, mark: String, _ back: @escaping () -> Void) {
        let once = Undone()
        let undo = {
            guard !once.done else { return }
            once.done = true
            back()
        }
        window?.undoManager?.registerUndo(withTarget: once) { _ in MainActor.assumeIsolated { undo() } }
        window?.undoManager?.setActionName(words)
        toaster.pop(words, mark: mark, undo: undo)
    }
}
