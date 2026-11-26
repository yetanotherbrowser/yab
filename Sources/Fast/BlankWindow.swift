import AppKit
import SwiftUI

// File › Blank Window, as Arc 1.170 has it (feedback #312, measured in
// evals/blank-window/arc.py and arc_more.py): a window whose tabs are its
// own. Its column heads them "This Window", with New Tab under it and no
// pins, no kept tabs, no space's name and no spaces at its foot; its tabs
// are in no space's sidebar and in no other window. It signs in as the
// space it was opened from (its cookies, passwords and extensions), and
// stays in that space: the Spaces menu doesn't move it, nor do ⌃1 to ⌃9.
// ⌘T, ⌘L and a page's new-tab links open tabs in it; nothing in it is kept
// or pinned. Arc keeps it across a quit, tabs and all, and so does Yab: it
// is one of the windows, with a file of its own. ⌘W on its last tab shuts
// it, as Arc's, and ⇧⌘T brings it back whole. A tab's Move to Space takes
// the tab out of it into that space, in a window of yours, as Arc's Move to.
// Arc's key, ⌃⌘N, is Yab's New Folder with Tabs (Finder's and Dia's), so
// Blank Window comes with no key unless one is given in Shortcuts.

enum BlankWindow {
    /// Where a window is said to be blank, beside `window.<id>.space`.
    nonisolated static func key(_ id: UUID) -> String { "window.\(id.uuidString).blank" }

    nonisolated static func marked(_ id: UUID) -> Bool { Store.settings.bool(forKey: key(id)) }

    /// What its column heads its tabs with, and its title with none.
    nonisolated static let heading = "This Window"
    nonisolated static let title = "Blank Window"
}

extension BrowserWindows {
    /// A Blank Window over the one it was asked from, in that one's space.
    @discardableResult
    func newBlankWindow(from source: Browser? = nil) -> Browser {
        newWindow(from: source, blank: true)
    }
}

extension Browser {
    /// File › Blank Window, its row in ⌘T and its key if one was given.
    func newBlankWindow() {
        if NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.isARepeat == true { return }
        if fieldShowing, asked != nil, active != nil { dismiss() }
        BrowserWindows.shared.newBlankWindow(from: self)
    }

    /// A window of yours to take a Blank Window's tabs into `space`: one on
    /// that space already, the one used last, or a new one of it.
    private func spaceWindow(for space: UUID) -> Browser {
        let windows = BrowserWindows.shared
        let others = windows.browsers.filter { !$0.blank && $0 !== self }
        if let here = others.last(where: { $0.spaceID == space }) { return here }
        if let used = others.last {
            used.switchSpace(to: space)
            return used
        }
        return windows.newWindow(from: self, space: space)
    }

    /// Move to Space in a Blank Window: the tabs out of it, each the same
    /// page when the space signs in as this window does and opened afresh
    /// there when not, into that space's row in a window of yours, the
    /// last of them in front there. The window goes when nothing is left.
    func moveOutOfBlank(_ picked: [Tab], to target: UUID, say: Bool = true) {
        guard let space = spaces.first(where: { $0.id == target }), target != Space.mailID else { return }
        settleNow()
        cancelTabEdit()
        var ids = Set(picked.map(\.id))
        for tab in picked { ids.formUnion(mates(of: tab.id)) }
        let moving = tabs.filter { ids.contains($0.id) && !travels($0) && !$0.shy }
        guard !moving.isEmpty else { return }
        let destination = spaceWindow(for: target)
        let here = destination.spaceID
        _ = unpick()
        pairs.removeAll { $0.ids.contains(where: ids.contains) }
        for (index, tab) in moving.enumerated() {
            let last = index == moving.count - 1
            moveOut(tab)
            if !tab.shy, tab.store !== Spaces.store(for: here), let url = tab.pending ?? tab.address {
                let fresh = Tab(configuration: Web.configuration(store: Spaces.store(for: here)))
                destination.prepare(fresh)
                fresh.restore(url: url, title: tab.title)
                fresh.name = tab.name
                tab.close()
                destination.moveIn(fresh, selecting: last)
            } else {
                destination.moveIn(tab, selecting: last)
            }
        }
        BrowserWindows.shared.show(destination)
        if say {
            let words = moving.count == 1 ? "Moved to \(space.name)" : "Moved \(moving.count) tabs to \(space.name)"
            destination.toaster.pop(words, mark: space.icon, feedback: .success)
        }
        if !tabs.contains(where: { !$0.bench }) { BrowserWindows.shared.window(for: self)?.performClose(nil) }
    }
}

/// "This Window" over a Blank Window's tabs, where a space's name stands in
/// any other window's column: the same type and color as that name, with
/// no mark, no fold and no menu, as Arc's.
struct BlankHeading: View {
    @Environment(\.tone) private var tone

    var body: some View {
        Text(BlankWindow.heading)
            .lineLimit(1)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Palette.muted(on: tone))
            .padding(.leading, SideBar.inner)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: SideBar.row)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
    }
}
