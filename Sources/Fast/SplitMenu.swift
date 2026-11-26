import AppKit
import SwiftUI

/// The split is the context, even when the press lands on one of its chips.
/// Page commands belong to each page's submenu. Group commands always carry
/// every pane, including Pin from search and Move to > Pinned Tabs.
struct SplitMenu: View {
    let browser: Browser
    let pair: Pair

    private var halves: [Tab] { pair.ids.compactMap { browser.tab(id: $0) } }
    private var pinned: Bool { browser.pinPair(of: pair.first) != nil }

    var body: some View {
        if pinned {
            Button("Unpin Pair", mark: "pin.slash") { browser.unpinPair(pair) }.shortcut(.pin)
        } else {
            Button("Pin Pair", mark: "pin") { browser.pinPair(pair) }
                .shortcut(.pin)
                .disabled(!browser.canPinPair(pair))
        }
        Button("Separate All Tabs", mark: "yab.split.slash") { separate() }
        // Two side by side or stacked; three and four have one layout each.
        if pair.count == 2 {
            Menu("Arrange", mark: "rectangle.split.2x1") {
                Button("Side by Side", mark: "rectangle.split.2x1") { browser.arrange(pair, .across) }
                    .disabled(!browser.canArrange(pair, .across))
                Button("Stacked", mark: "rectangle.split.1x2") { browser.arrange(pair, .stacked) }
                    .disabled(!browser.canArrange(pair, .stacked))
            }
        }
        Divider()
        Button("Tab Options") {}.disabled(true)
        ForEach(halves, id: \.id) { half in
            Menu { pageActions(half) } label: { Self.line(half) }
        }
        Divider()
        Button("Duplicate", mark: "yab.tabs.plus") { browser.duplicateSplit(pair) }
            .shortcut(.duplicate)
            .disabled(halves.count != 2 || halves.contains(where: \.isBlank))
        Menu("Move to", mark: "arrow.right") {
            if pinned {
                Button("Today", mark: "pin.slash") { browser.unpinPair(pair) }
            } else {
                Button("Pinned Tabs", mark: "pin") { browser.pinPair(pair) }
                    .disabled(!browser.canPinPair(pair))
            }
            SpaceSend(browser: browser, tabs: halves, title: "Space")
            if halves.contains(where: \.keepable) {
                Menu("Folder", mark: "yab.folder.right") {
                    Button("New Folder…", mark: "yab.folder.plus") { browser.newFolder(with: halves) }
                }
            }
        }
        Divider()
        Button("Archive Item", mark: "yab.tabs.x") {
            if pinned { browser.closePinPair(pair) } else { browser.shut(halves) }
        }.shortcut(.closeTab)
        Button("Archive Tabs Below", mark: "yab.tabs.down") { browser.closeAfter(halves) }
            .shortcut(.closeAfter)
            .disabled(browser.sideCloseTargets(halves, before: false).isEmpty)

        // Existing Yab commands stay reachable through menu search. These
        // handlers act on the split, never the half that was right-clicked.
        Menu(ActionMenu.tabSearchActions) {
            Button("Swap Halves", mark: "arrow.left.arrow.right") { browser.swapHalves(pair) }
                .disabled(browser.stagePair?.contains(pair.first) != true || pair.count != 2)
            Button("Copy \(halves.count) URLs", mark: "link") { browser.copyAddresses(halves) }.shortcut(.copyAddress)
            Button("Copy \(halves.count) Markdown Links", mark: "markdown") { browser.copyMarkdownLink(halves) }.shortcut(.copyMarkdownLink)
        }
    }

    @ViewBuilder
    private func pageActions(_ half: Tab) -> some View {
        Button("Separate from Split View", mark: "yab.split.slash") { separate(keeping: half.id) }
        Divider()
        Button(browser.siteMuted(half) ? "Unmute" : "Mute", mark: browser.siteMuted(half) ? "speaker.wave.2" : "speaker.slash") { browser.toggleSiteMute(half) }
            .disabled(!AudioWatch.canMute || half.address?.scheme?.hasPrefix("http") != true)
        Button("Copy Link", mark: "link") { browser.copyAddresses([half]) }.shortcut(.copyAddress).disabled(half.isBlank)
        Button("Copy link as Markdown", mark: "markdown") { browser.copyMarkdownLink([half]) }.shortcut(.copyMarkdownLink).disabled(half.isBlank)
        Divider()
        ChangeIconItem(target: .tab(half.id), mark: "face.smiling")
        Button("Rename…", mark: "pencil") { browser.select(half); browser.beginTabEdit(half) }
            .shortcut(.rename)
            .disabled(half.isBlank || half.pin != nil)
        Divider()
        Button("Archive Item", mark: "yab.tab.x") { browser.shut(half) }.shortcut(.closeTab)
    }

    private func separate(keeping half: Tab.ID? = nil) {
        for tab in halves { tab.pairRest = false }
        browser.separate(pair, keeping: half)
    }

    static func line(_ half: Tab) -> SwiftUI.Label<Text, Image> {
        let words = MenuWidth.cut(half.rowLabel, font: NSFont.menuFont(ofSize: 0)) ?? half.rowLabel
        let mark = half.displayIcon.map(MenuMark.picture) ?? MenuMark.image("globe")
        return SwiftUI.Label { Text(words) } icon: { Image(nsImage: mark) }
    }
}

extension Browser {
    /// Duplicate the two pages using the normal tab duplication, then keep
    /// the copies together with the original divider position and layout.
    func duplicateSplit(_ pair: Pair) {
        let halves = pair.ids.compactMap { tab(id: $0) }
        guard pairs.contains(pair), halves.count == 2, halves.allSatisfy({ !$0.isBlank }) else { return }
        duplicate(halves)
        // The copies alone: `chosen` also counts the tab in front.
        let copies = tabs.filter { gathered.contains($0.id) }
        guard copies.count == 2, copies.allSatisfy({ copy in !halves.contains { $0 === copy } }) else { return }
        pairs.append(Pair(first: copies[0].id, second: copies[1].id, share: pair.share, arrangement: pair.arrangement))
        select(copies[1])
        restage()
        writeSession(now: true)
    }
}
