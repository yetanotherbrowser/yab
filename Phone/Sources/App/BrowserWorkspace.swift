import SwiftUI
import Observation
import UIKit

extension Metrics {
    enum Workspace {
        static let minimumWidth: CGFloat = 600
        static let minimumPane: CGFloat = 320
        static let menuWidth: CGFloat = 402
        static let sidebar: CGFloat = 320
        static let conversation: CGFloat = 360
        static let divider: CGFloat = 1
        static let maximumPlate: CGFloat = 600
    }
}

/// Window geometry, never a device name or a guessed hinge location.
struct BrowserWorkspaceLayout: Equatable {
    let size: CGSize
    let expanded: Bool
    let split: Bool
    let fraction: CGFloat
    let gap: CGFloat
    let horizontal: Bool

    init(size: CGSize, regular: Bool, paired: Bool, fraction: CGFloat = 0.5, gap: CGFloat = Metrics.Workspace.divider,
         horizontal: Bool? = nil) {
        self.size = size
        self.gap = gap
        self.horizontal = horizontal ?? (size.width > size.height)
        let available = max(1, size.width - gap)
        let minimum = min(0.5, Metrics.Workspace.minimumPane / available)
        self.fraction = fraction.isFinite ? min(1 - minimum, max(minimum, fraction)) : 0.5
        expanded = regular && size.width >= Metrics.Workspace.minimumWidth
        split = expanded && paired && self.horizontal
            && size.width >= Metrics.Workspace.minimumPane * 2 + gap
    }

    func pane(_ second: Bool) -> CGRect {
        guard split else { return CGRect(origin: .zero, size: size) }
        let first = (size.width - gap) * fraction
        return CGRect(x: second ? first + gap : 0, y: 0,
                      width: second ? size.width - first - gap : first, height: size.height)
    }
}

/// One selection owns the existing browser controls. Its companion stays alive
/// in the same WebPool, including its history, form values and scroll position.
@MainActor @Observable
final class BrowserWorkspace {
    struct Pair: Equatable {
        var first: Tab.ID
        var second: Tab.ID
        var focused: Tab.ID
        var ids: [Tab.ID] { [first, second] }
    }
    private(set) var savedPair: Pair?
    private(set) var first: Tab.ID?
    private(set) var second: Tab.ID?
    private(set) var secondFocused = false
    private(set) var expanded = false
    var paneFrame = CGRect.zero
    /// Counts Show Downloads: the downloads button on screen opens its list.
    var downloadsShown = 0
    var windowSize = CGSize.zero
    var tabletControls = false
    var regularWidth = false
    var legacyTabletWindow = false
    var verticalBarLeading: Bool? = nil
    var reservations = ChromeGeometry.Reservations.empty
    /// The key window's safe area, kept current by BrowserWorkspaceView's probe.
    var windowInsets = UIEdgeInsets.zero
    /// Test states only: a wide window on a phone's size class, as an unfolded
    /// Duo has; the simulator can't unfold from a script.
    nonisolated(unsafe) static var regularForced = false
    /// The regular-width phone presentation. No header
    /// (the design of 2026-10-10): the page whole, the plate at its foot, the
    /// rail at its side, the spaces as a column, search in the middle.
    var unfolded: Bool {
        guard expanded, !tabletControls else { return false }
        // Preserve the existing narrow iPad presentation without using its
        // legacy capacity threshold to identify an unfolded phone.
        if legacyTabletWindow { return min(windowSize.width, windowSize.height) >= Metrics.Workspace.minimumWidth }
        return Self.regularForced || regularWidth
    }
    /// All Tabs lays three cards whole across an unfolded Duo on its side.
    var galleryAcross: Bool { unfolded && windowSize.width > windowSize.height }
    /// What the system reserves from a surface this wide at the window's left:
    /// the column beside a page reaches only that edge.
    func sides(ofSurface width: CGFloat) -> ChromeGeometry.Sides {
        width < windowSize.width - 0.5 ? .init(left: windowInsets.left, right: 0) : ChromeGeometry.effectiveSides
    }
    var hardwareSides: ChromeGeometry.Sides {
        .init(left: windowInsets.left + ChromeGeometry.extraSides.left, right: windowInsets.right + ChromeGeometry.extraSides.right)
    }
    var statusColumn: Bool {
        let sides = hardwareSides
        return sides.foot == .zero && sides != .zero
    }
    /// The status column stands over the spaces at the whole screen, or over
    /// the column on the left.
    var statusColumnOverField: Bool { statusColumn && (!expanded || hardwareSides.left > 0) }
    /// On the right of a wide window it stands on the page.
    var statusColumnOverPage: Bool { statusColumn && expanded && hardwareSides.left == 0 }
    let preferences: TabletLayoutPreferences
    var sidebarShown: Bool {
        get { preferences.sidebarShown }
        set { preferences.sidebarShown = newValue }
    }
    init(preferences: TabletLayoutPreferences? = nil) { self.preferences = preferences ?? TabletLayoutPreferences() }
    var newPage: Tab.ID?
    var paired: Bool { first != nil && second != nil }
    var canSplit: Bool {
        expanded && windowSize.width > windowSize.height
            && windowSize.width >= Metrics.Workspace.minimumPane * 2 + Metrics.Workspace.divider
    }
    /// All Tabs keeps the phone's row: on a Duo, whichever way it stands.
    var galleryVerticalControls: Bool { verticalControls && !statusColumn }
    var verticalControls: Bool { !tabletControls && (verticalBarLeading != nil || statusColumn || (windowSize.width >= 568 && windowSize.width > windowSize.height)) }
    var leadingRail: Bool {
        // A split pane without the hardware column keeps its outer rail.
        if canSplit && paired { return !secondFocused }
        if let verticalBarLeading { return verticalBarLeading }
        if statusColumn { return hardwareSides.left > 0 }
        return canSplit && paired && !secondFocused
    }
    var companion: Tab.ID? { secondFocused ? first : second }

    func openBeside(current: Tab.ID, other: Tab.ID) {
        guard current != other else { return }
        newPage = nil
        first = current; second = other; secondFocused = true
        savedPair = Pair(first: current, second: other, focused: other)
    }

    func fieldClosed() { newPage = nil }

    func fullSpread() { savedPair = nil; leaveSplit() }

    /// An unrelated card opens by itself; the pair keeps its own card in All Tabs.
    func leaveSplit() { first = nil; second = nil; secondFocused = false; newPage = nil }

    func resize(expanded: Bool) { self.expanded = expanded }

    func selected(_ id: Tab.ID?, valid: Set<Tab.ID>) {
        if let savedPair, !Set(savedPair.ids).isSubset(of: valid) { self.savedPair = nil }
        if !paired, let id, let saved = savedPair, saved.ids.contains(id) {
            first = saved.first; second = saved.second; secondFocused = id == saved.second
        }
        guard paired else { return }
        guard let id, let first, let second, valid.contains(first), valid.contains(second), valid.contains(id) else {
            fullSpread(); return
        }
        if !expanded {
            // A different tab on the cover becomes the new full spread.
            if id != (secondFocused ? second : first) { fullSpread() }
        } else if id == first { secondFocused = false }
        else if id == second { secondFocused = true }
        else if secondFocused { self.second = id }
        else { self.first = id }
        if let first = self.first, let second = self.second {
            savedPair = Pair(first: first, second: second, focused: id)
        }
    }
}

extension AppModel {
    /// Selection can finish New Tab Beside by choosing an existing tab,
    /// including the original one. The field's placeholder is never history.
    func reconcileWorkspace() {
        if let empty = workspace.newPage, let selected = browser.tab?.id, selected != empty {
            workspace.newPage = nil
            if selected == workspace.first {
                workspace.fullSpread()
            } else {
                workspace.selected(selected, valid: Set(browser.space.allTabs.map(\.id)))
            }
            browser.close(empty)
        }
        let valid = Set(browser.space.allTabs.filter { !$0.isPrivate && !$0.isMail }.map(\.id))
        workspace.selected(browser.tab?.id, valid: valid)
        // Keep remembered documents alive while the window is narrow.
        pages.workspaceTabs = Set([workspace.first, workspace.second].compactMap { $0 } + (workspace.savedPair?.ids ?? []))
    }

    func openTabBeside(_ tab: Tab) {
        guard workspace.canSplit, let current = browser.tab, current.id != tab.id,
              browser.space.tab(tab.id) != nil, !current.isPrivate, !tab.isPrivate, !current.isMail, !tab.isMail,
              !browser.space.isPrivate else { return }
        workspace.openBeside(current: current.id, other: tab.id)
        browser.select(tab.id)
        field.close()
    }

    func newTabBeside() {
        guard workspace.canSplit, let current = browser.tab, !pageIsPrivate, !current.isMail else { return }
        let tab = Tab(id: UUID().uuidString, title: "New Tab", site: "New Tab", icon: "globe", url: "about:blank")
        workspace.openBeside(current: current.id, other: tab.id)
        workspace.newPage = tab.id
        browser.open(tab, deduplicate: false)
        openNewTab()
    }

    func closeWorkspacePage() {
        guard let id = browser.tab?.id else { return }
        closeWorkspacePage(id)
    }

    /// Closing the inactive pane must preserve its neighbor, regardless of
    /// whether SwiftUI has reconciled the latest selection yet.
    func closeWorkspacePage(_ id: Tab.ID) {
        guard browser.tab(id) != nil else { return }
        let other = workspace.paired
            ? [workspace.first, workspace.second].compactMap { $0 }.first { $0 != id }
            : nil
        workspace.fullSpread()
        browser.close(id)
        if let other { browser.select(other) }
    }

    /// Keyboard notifications use screen coordinates; browser surfaces live
    /// inside a window and, on a landscape spread, only part of that window.
    func workspaceKeyboardHeight(_ end: CGRect) -> CGFloat {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.keyWindow else { return 0 }
        let keyboard = window.convert(end, from: window.screen.coordinateSpace)
        let frame = workspace.tabletControls || workspace.paneFrame.isEmpty ? window.bounds : workspace.paneFrame
        let overlap = frame.intersection(keyboard)
        return overlap.isNull ? 0 : overlap.height
    }
}
