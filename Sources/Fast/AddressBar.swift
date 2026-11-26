import SwiftUI
import AppKit

/// Only actual controls refuse the native band handle. Anchors follow layout,
/// including split sizes, extension doors and controls appearing on hover.
private struct BandControls: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value += nextValue()
    }
}

private extension View {
    func bandControl() -> some View {
        anchorPreference(key: BandControls.self, value: .bounds) { [$0] }
    }

    func bandHandles(enabled: Bool) -> some View {
        overlayPreferenceValue(BandControls.self) { anchors in
            if enabled {
                GeometryReader { geometry in
                    DragStrip(exclusions: anchors.map { geometry[$0] })
                }
            }
        }
    }
}

/// The address, for whoever wants it in view: a band along the top of the
/// page, inside its card, with the site written in the middle of it.
///
/// Only the site, the part that says whose page this is. The scheme, the
/// www and the path are what ⌘L is for, and a click on the site is ⌘L. A
/// subdomain is kept but let down to the muted gray, so the name that does
/// the owning is the one that reads first: docs.google.com and
/// google.com.example.net don't look alike.
///
/// With the tabs across the top the band takes the doors that stood at the
/// row's far end: back, forward and reload on its left, where Chrome keeps
/// them; on its right reading mode's book on an article, the camera,
/// downloads and the site's sliders, which hold the extensions. The row is
/// left to the tabs, each its mark, its title and its cross. With the tabs down the left the column keeps its doors beside the
/// lights and only reading mode's book and the extensions come over: the
/// pinned ones, and the sliders that hold the rest.
///
/// Nothing in it moves on the frequent path. Another tab is another site in
/// the same frame; under the pointer the link shows on the site's left and
/// the star on its right, and a copy from there turns the link into a tick
/// while the corner says it; the site stays where it is. Split View is the
/// band's last door, as Arc keeps it.
struct AddressBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    /// The column out over the page: its own door is there while it shows.
    @ObservedObject var peek: SidePeek
    /// The tabs run across the top, and the band has their doors.
    let strip: Bool
    let height: CGFloat
    /// The card's corners, which the band's top corners are.
    let corner: CGFloat
    /// One of two halves side by side (Split.swift): its own back, forward
    /// and reload whichever side the tabs are on, acting on this half.
    var half = false
    /// The update's door: in one half only, the right one, so there is
    /// one. The camera and the downloads are each half's, as Arc's are.
    var doors = true
    /// One window door even with two halves, in the band on the column's
    /// side.
    var columnDoor = true
    /// The page's leading inset, so the lights keep their window position.
    var leadingInset: CGFloat = 0
    /// A half's own way out of the pair, a cross at the band's far end:
    /// this half leaves and stays a tab, the other takes the width.
    var leave: (() -> Void)? = nil

    @Environment(\.tone) private var tone
    @State private var hovering = false

    /// A half behind the one in front keeps back, forward, its site and its
    /// cross, as Arc's does; the rest comes up under the pointer, in the
    /// room it kept, so the site never moves.
    private var quiet: Bool { half && tab.id != browser.activeID && !hovering }

    /// The band is the address bar, asked for, or a half's, and has the
    /// doors from the row or the column; Developer Mode's band alone
    /// leaves them there.
    private var takes: Bool { half || browser.prefs.addressBar }

    /// Back, forward and reload at the band's start: the row's across the
    /// top, a half's own, or the column's while the bar is shown.
    private var helmed: Bool { half || (takes && (strip || browser.prefs.helmInBand)) }

    /// The same column door comes over while the column is put away. A
    /// column brought out from the edge already has its own, and the tabs
    /// across the top never get a sidebar door.
    private var hiddenColumn: Bool {
        columnDoor && browser.prefs.sidebarButton && !strip && browser.prefs.sideShut && !peek.out
    }

    /// That door stands at the band's end on the column's side, where the
    /// column's own header has it (ColumnDoor.swift): the start for a
    /// column on the left, the far end for one on the right. At the start
    /// for both, a column on the right was brought out from the window's
    /// other side.
    private var doorLeads: Bool { hiddenColumn && browser.flank == .left }
    private var doorTrails: Bool { hiddenColumn && browser.flank == .right }

    var body: some View {
        // The doors at each end and the site in the middle, laid out by
        // BandLayout in one pass from their sizes: measured into state, as
        // they were, every change of the band's width, a divider under the
        // hand, drew the band again, and each half's twice.
        // A page being made on this Mac reads as a whole address, from the
        // band's start, as Arc writes it (DevMode.swift).
        BandLayout(rim: Self.rim(height), id: tab.id, leads: tab.isDev) {
            Group {
                // Only while the band is the address bar: Developer Mode's
                // band alone leaves them where the layout keeps them. With
                // the sidebar, here only when asked for (Settings ›
                // Appearance › Back and forward), as Arc's toolbar has them.
                if helmed || doorLeads {
                    HStack(spacing: Door.Size.band.gap) {
                        if doorLeads {
                            ColumnDoor(browser: browser, prefs: browser.prefs)
                                .environment(\.doorSize, .header)
                                .bandControl()
                        }
                        if helmed {
                            Helm(browser: browser, tab: half ? tab : nil, reads: false, quiet: quiet, still: true)
                                .bandControl()
                        }
                    }
                } else {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            HStack(spacing: Door.Size.band.gap) {
                // A page on this Mac's own server: its errors when it has
                // any, Measure and the developer tools (DevMode.swift).
                if tab.isDev && !half {
                    DevBandDoors(browser: browser, tab: tab, log: tab.devLog.counts)
                        .bandControl()
                }
                // A dev page's link is a door among its tools, beside the
                // camera, as Arc keeps it, not the site's own end.
                if tab.isDev {
                    Door(icon: "link", help: "Copy URL", shortcut: "Copy URL") { browser.focus(tab); browser.copyAddress(door: true) }
                        .bandControl()
                        .opacity(quiet ? 0 : 1)
                        .allowsHitTesting(!quiet)
                }
                // A document that came as JSON: its door, and the words
                // beside it when something is off (JSONView.swift).
                if tab.json != nil && !quiet {
                    JSONBandDoor(browser: browser, tab: tab)
                        .bandControl()
                }
                // Reading mode's book on an article, at the band's end beside
                // the camera, and Aa beside
                // it while the page is read, as the Oct 21 prototype draws
                // them: whichever side the tabs are on, since the column's
                // head no longer has the book. On a feed it is away and
                // keeps no room: the site stands in the middle of the band
                // whatever the doors (BandLayout).
                if takes, ReadingDoor.offered(tab) {
                    ReadingDoor(browser: browser, tab: tab, own: half)
                        .bandControl()
                        .opacity(quiet ? 0 : 1)
                        .allowsHitTesting(!quiet)
                }
                // Capture part of the page (Capture.swift): a half's own,
                // that half brought to the front first.
                if !tab.isBlank {
                    Door(icon: "camera", help: "Capture", shortcut: "Capture…") { browser.focus(tab); browser.capture.start() }
                        .bandControl()
                        .opacity(quiet ? 0 : 1)
                        .allowsHitTesting(!quiet)
                }
                if takes, strip {
                    if doors { UpdateButton(browser: browser, place: .strip).bandControl() }
                    // Under the pointer in the half behind, as the camera
                    // beside it, unless a download is going on.
                    HoardSlot(hoard: browser.hoard, place: .strip, quiet: quiet)
                        .bandControl()
                }
                // Site Controls for this band's page, each half its own:
                // the extensions are in it, where the puzzle used to be.
                if !browser.inMail && !tab.isBlank {
                    // The pinned extensions, before the sliders, as Arc's
                    // toolbar has them at its right: the plate that has them
                    // is away while the band is up. One pair of halves has
                    // one row, the right half's, as it has one update door.
                    if doors {
                        BandPins(quiet: quiet, tab: tab)
                            .bandControl()
                    }
                    WindowChip(browser: browser, tab: tab)
                        .bandControl()
                    SiteControlsDoor(browser: browser, tab: tab, side: Door.Size.band.side, glyph: Door.Size.band.glyph)
                        .bandControl()
                        .opacity(quiet ? 0 : 1)
                        .allowsHitTesting(!quiet)
                }
                // Split View, last at the band's end, as Arc keeps its own:
                // in a half that place is the half's way out below.
                if leave == nil, !half, !browser.inMail, !tab.isBlank, browser.canHost(tab) {
                    Door(icon: "split.view", help: "Split View", shortcut: "Split View") { browser.focus(tab); browser.splitView() }
                        .bandControl()
                }
                if let leave {
                    Door(icon: "xmark", help: "Leave Split View", act: leave)
                        .bandControl()
                        // Under the pointer: the half dims and its chip is
                        // outlined, the one that goes back to the list, and
                        // its picture is taken for the way there.
                        .onHover { [browser, tab] on in
                            browser.splitHint.leave(tab.id, on)
                            if on { SplitDeck.shared.ready(tab.id, in: browser) }
                        }
                }
                if doorTrails {
                    ColumnDoor(browser: browser, prefs: browser.prefs)
                        .environment(\.doorSize, .header)
                        .bandControl()
                }
            }
            if !tab.isBlank {
                Site(browser: browser, tab: tab, copies: browser.copies, handles: !half)
                    .bandControl()
            }
            // A share going on: its mark before the doors at the band's end,
            // its words out over the band when asked for.
            ShareChip(browser: browser, tab: tab)
                .bandControl()
                .layoutValue(key: BandChip.self, value: true)
        }
        // The header's doors, larger than a row's, with Arc's air between.
        .environment(\.doorSize, .band)
        .animation(Motion.quick, value: quiet)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .onHover { hovering = $0 }
        // A half's band is its handle: carried over the other half, the two
        // change places (SplitDeck, as a pair's chip carried there does).
        .contentShape(Rectangle())
        .gesture(carry, including: half ? .all : .subviews)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: corner, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: corner,
                style: .continuous
            )
            // The card's top corners are this fill's own soft edge, and only
            // its: a clip on the same curve over it cut each soft pixel twice,
            // and the paper's band in the bar's color under it added a third
            // (docs/page-corners.md).
            .fill(tone?.color ?? Palette.ground)
            .overlay {
                // A page on this Mac's own server: faint tape across the
                // band, so a dev tab is never taken for the live site.
                if tab.isDev {
                    Hatch().fill(Palette.ink.opacity(0.035))
                        .clipShape(UnevenRoundedRectangle(
                            topLeadingRadius: corner, bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0, topTrailingRadius: corner,
                            style: .continuous
                        ))
                }
            }
        }
        // Native hit testing fills all the air while refusing the measured
        // controls. Split bands retain their existing deck-carry gesture.
        .bandHandles(enabled: !half)
        // Where the band ends and the page starts, as faint as the line
        // down the column's edge.
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.ink.opacity(0.06)).frame(height: 1)
                .allowsHitTesting(false)
        }
        // The whole band, including the empty room beside the site, owns
        // its menu. SteadyMenu lets ordinary clicks and window drags through.
        .steadyMenu(actions: true) { AddressMenu(browser: browser, tab: tab) }
    }

    /// The band taken by the hand: the deck has the half from the first
    /// move, and every move after is its alone, nothing here changes until
    /// it is let go.
    private var carry: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                if !carryTried {
                    carryTried = true
                    let start = value.startLocation
                    carrying = SplitDeck.shared.begin(tab, in: browser, at: start,
                                                      home: CGRect(x: start.x - 90, y: start.y - 14, width: 180, height: 28))
                }
                if carrying { SplitDeck.shared.move(to: value.location) }
            }
            .onEnded { _ in
                if carrying, let drop = SplitDeck.shared.end() { browser.dropSplit(tab, drop) }
                carrying = false
                carryTried = false
            }
    }

    @State private var carrying = false
    @State private var carryTried = false

    /// The bookmarks' row keeps the doors' old air at its ends.
    static let shelfRim: CGFloat = 6

    /// In from the band's ends to the first door: the air the doors have
    /// above and below them, so a door's plate under the pointer stands as
    /// far from the band's side as from its top. Six at the sides with three
    /// above made the cross's plate look pushed up into the corner.
    static func rim(_ height: CGFloat) -> CGFloat {
        max(3, ((height - Door.Size.band.side) / 2).rounded())
    }

    /// The band's height: on a card, in line with the lights beside the
    /// column, the column's top band less the card's inset above and under
    /// it; edge to edge, the row the tabs across the top have, as the
    /// column's whole top band left the doors 11 of air each way and read
    /// as a title bar (2026-10-20); under the tabs, a row a little lower
    /// than theirs.
    static func height(sidebar: Bool, carded: Bool) -> CGFloat {
        guard sidebar else { return 36 }
        return carded ? Metrics.strip - 2 * Backdrop.inset : Metrics.row
    }
}

/// A peek's own address, along the top of its page, when Settings › Tabs
/// asks for it: the band's site and nothing else, in the page's color, as
/// tall as the band on a card. The buttons beside the panel keep closing,
/// keeping and splitting it. A click on the site is ⌘L for the peek's
/// page, its link copies that page's address, its star keeps it
/// (Browser.fieldPage, copyAddress). Drawn by PeekView inside the page's
/// holder, so it grows, goes home and is kept with the page.
struct PeekBand: View {
    let browser: Browser
    @ObservedObject var tab: Tab

    static let height = AddressBar.height(sidebar: true, carded: true)

    var body: some View {
        Toned(tab: tab) { tone in
            let worn = tone ?? (tab.shy ? Tone(NSColor(white: 0.085, alpha: 1)) : nil)
            ZStack {
                Rectangle().fill(worn?.color ?? Palette.ground)
                if !tab.isBlank {
                    Site(browser: browser, tab: tab, copies: browser.copies, handles: false)
                        .padding(.horizontal, AddressBar.rim(Self.height))
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.ink.opacity(0.06)).frame(height: 1)
            }
            .toned(worn)
        }
        .environment(\.doorSize, .band)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
    }
}

/// The site, and under the pointer the link that copies its address on
/// its left and the star that bookmarks it on its right, the same square
/// each side, so the plate grows evenly and stays on the words.
private struct Site: View {
    let browser: Browser
    @ObservedObject private var prefs: Preferences
    @ObservedObject var tab: Tab
    /// The browser's count of copies, handed in as a value: the browser
    /// is the same object before and after one, and this view would
    /// otherwise have nothing to notice.
    let copies: Int
    /// The band is the window's handle here (not one of two halves): its
    /// empty room drags the window and takes the title bar's double-click,
    /// and the site drags it too.
    let handles: Bool

    @Environment(\.tone) private var tone
    @State private var hovering = false
    @State private var linkHovering = false
    @State private var starHovering = false
    @ObservedObject private var bookmarks = Bookmarks.shared
    /// The tick, for a moment after a copy.
    @State private var ticked = false
    @State private var untick: DispatchWorkItem?

    /// The plate under the pointer: the doors' height and corner, so the
    /// site is lit as the doors beside it are, not hugged by a lower one.
    private static let plate: CGFloat = Door.Size.band.side
    /// The lock's square and the link's, in the plate's corners: as far in
    /// from its ends as from its top and bottom.
    private static let slot: CGFloat = 24
    private static let edge: ClosedRange<CGFloat> = 3...3
    /// Their corners, concentric with the plate's.
    private static var inner: CGFloat { Radius.control - edge.lowerBound }
    /// Their air from the site: roomy while the band has the width, given
    /// up down to the least when it hasn't, before the site gives up a
    /// letter.
    private static let gap: ClosedRange<CGFloat> = 4...8
    /// Round the words alone, a page of the app's own.
    private static let bare: ClosedRange<CGFloat> = 8...12
    @ObservedObject private var card = SiteControlsState.shared
    @State private var lockFrame: CGRect = .zero
    @State private var lockHovering = false

    init(browser: Browser, tab: Tab, copies: Int, handles: Bool) {
        self.browser = browser
        self.tab = tab
        self.copies = copies
        self.handles = handles
        self.prefs = browser.prefs
    }

    /// The lock and the link stay up while the lock's card is out. The
    /// band's sliders open the same card without lighting the site: it
    /// isn't what was pressed, and a lit plate reads as hovered.
    private var shown: Bool { hovering || (card.openFor == tab.id && card.page == .connection) }
    /// A dev page keeps them up at rest too, as Arc keeps its: its band is
    /// a workbench, where copying the address is the frequent path.
    private var doorsUp: Bool { shown || tab.isDev }

    var body: some View {
        let copyable = tab.address.map(Self.copyable) ?? false
        // A dev page's band is a workbench: no star there.
        let starred = copyable && !dev && tab.address.map(Bookmark.keepable) == true

        Squeeze(edge: copyable ? Self.edge : Self.bare, gap: Self.gap) {
            // The link on the left and the star on the right are the same
            // square, kept at rest, so the words, not the words and the
            // doors, are what stand in the middle, and the doors coming and
            // going under the pointer move nothing. Site Controls are the
            // band's sliders. A dev page reads as its whole address from
            // the band's start, its lock before it, its link with its tools,
            // and no star.
            if dev {
                lock.bandControl()
            } else if copyable {
                copy.bandControl()
            }
            name.bandControl()
            if starred {
                star.bandControl()
            } else if copyable && !dev {
                Color.clear.frame(width: Self.slot, height: Self.slot)
            }
        }
        .frame(height: Self.plate)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(hovering ? Palette.hover(on: tone) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .onHover { hovering = $0 }
        .bandHandles(enabled: handles)
        // Only the half whose address it was: two side by side both
        // ticked for one copy.
        .onChange(of: copies) { if tab.id == browser.activeID { tick() } }
        .onChange(of: tab.id) { settle() }
    }

    /// The site, still through a copy, as Arc's is: the corner says it.
    private var name: some View {
        Button(action: open) {
            words
                // A long name gives up its front: the end of a host
                // is the part that says whose it is. A dev address
                // keeps its server and gives up the end of its path.
                .truncationMode(dev || prefs.fullURL ? .tail : .head)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .overlay {
            LinkFieldHandle(enabled: handles, click: open)
        }
        .pointerTip(tab.address?.absoluteString ?? "")
        // It raises the field and puts it away itself (`open`), so the
        // window's click away leaves it be (Browser.fieldAway).
        .background(ClickZone(away: browser.fieldAway))
        // Medium, as Arc sets its site: regular read thin on a colored band.
        .sidebarFont(size: dev ? 12 : 13, weight: dev ? .regular : .medium, design: dev ? .monospaced : .default)
        .lineLimit(1)
    }

    /// Each press toggles the field, as each press on Arc's address does
    /// its command bar: up over this page, a press puts it away; down, or
    /// up over the other half, a press raises it here at once. A second
    /// press is never anything else, however soon it comes, so fast
    /// presses are each answered and none is taken for a double-click.
    private func open() {
        if browser.fieldShowing, browser.fieldGuest == nil, browser.activeID == tab.id {
            browser.dismiss()
            return
        }
        // The site of the half behind: that half comes to the front,
        // and the field is its.
        browser.focus(tab)
        browser.edit()
    }

    /// Shut for https and open for http, under the pointer only: on the
    /// frequent path it is the same lock on every site and says nothing.
    /// Pressed, it opens Site Controls on the connection (SiteLock). A page with no site to
    /// trust keeps the square empty.
    @ViewBuilder private var lock: some View {
        let scheme = tab.address?.scheme?.lowercased()
        let site = scheme == "https" || scheme == "http"
        let open = card.openFor == tab.id && card.page == .connection
        if site {
            Button { SiteLock.toggle(browser, tab, from: lockFrame) } label: {
                Symbol(scheme == "https" ? "lock" : "lock.open", size: 10, weight: .medium)
                    .foregroundStyle(open || lockHovering ? Palette.ink : Palette.muted(on: tone))
                    .frame(width: Self.slot, height: Self.slot)
                    .background(
                        RoundedRectangle(cornerRadius: Self.inner, style: .continuous)
                            .fill(open ? Palette.wash(on: tone) : lockHovering ? Palette.hover(on: tone) : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(Door.Give())
            .focusable(false)
            // No tip: a name with no key to it says nothing the lock
            // doesn't, and a click shows the card itself.
            .accessibilityLabel("Site Information")
            .onHover { lockHovering = $0 }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { lockFrame = $0 }
            .opacity(doorsUp ? 1 : 0)
            .allowsHitTesting(doorsUp)
            .animation(Motion.quick, value: doorsUp)
        } else {
            Color.clear.frame(width: Self.slot, height: Self.slot)
        }
    }

    /// The star, under the pointer only: drawn filled on a page kept
    /// already. Add This Page, and pressed again the bookmark taken out.
    private var star: some View {
        let kept = tab.address.map(bookmarks.contains) ?? false
        return Button { browser.toggleBookmark(tab) } label: {
            Symbol(kept ? "star.fill" : "star", size: 10, weight: .medium)
                .foregroundStyle(starHovering ? Palette.ink : Palette.muted(on: tone))
                .frame(width: Self.slot, height: Self.slot)
                .background(
                    RoundedRectangle(cornerRadius: Self.inner, style: .continuous)
                        .fill(starHovering ? Palette.hover(on: tone) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(Door.Give())
        .focusable(false)
        .keyTip(kept ? "Remove Bookmark" : "Bookmark This Page", shortcut: kept ? nil : "Add This Page")
        .onHover { starHovering = $0 }
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .animation(Motion.quick, value: shown)
    }

    /// The link, under the pointer; the tick, for a moment after a copy.
    private var copy: some View {
        Button {
            // A half's own link: that half comes to the front, so its
            // address is the one copied and its corner the one that says so.
            browser.focus(tab)
            browser.copyAddress(door: true)
        } label: {
            CopyMark(ticked: ticked, side: (10 * Glyphs.scale).rounded())
                .foregroundStyle(ticked || linkHovering ? Palette.ink : Palette.muted(on: tone))
                .frame(width: Self.slot, height: Self.slot)
                .background(
                    RoundedRectangle(cornerRadius: Self.inner, style: .continuous)
                        .fill(linkHovering ? Palette.hover(on: tone) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(Door.Give())
        .focusable(false)
        .keyTip("Copy URL", shortcut: "Copy URL")
        .onHover { linkHovering = $0 }
        .opacity(doorsUp || ticked ? 1 : 0)
        .allowsHitTesting(doorsUp)
        .animation(Motion.quick, value: doorsUp)
        .animation(Motion.settle, value: ticked)
    }

    private func tick() {
        untick?.cancel()
        ticked = true
        let work = DispatchWorkItem { ticked = false }
        untick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Toaster.brief, execute: work)
    }

    /// Another tab: whatever the last one was showing is put away at once.
    private func settle() {
        untick?.cancel()
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { ticked = false }
    }

    /// The site's name (AddressWords), or the whole address when that is
    /// what was asked for.
    private var words: Text {
        if prefs.fullURL, let url = tab.address { return FullAddress.text(url, tone: tone) }
        return AddressWords.text(tab: tab, tone: tone)
    }

    private var dev: Bool { tab.isDev }

    /// Whether the address is one worth copying: a page of the app's own
    /// is not somewhere anyone else can go.
    private static func copyable(_ url: URL) -> Bool {
        url.scheme?.lowercased() != DiaryPage.scheme
    }
}

/// The link that copies an address, and the tick that says it did, turned
/// one into the other as Arc turns its own: the link drawn in to a point,
/// the tick written out stroke by stroke from its short end, and after
/// `held` back the same way, the tick taken back to where it started and
/// the link grown out of the point again. The band's, the column's plate's
/// and a link window's link alike.
struct CopyMark: View {
    let ticked: Bool
    /// The square the glyphs are drawn in, as Symbol's (Glyphs.scale).
    let side: CGFloat
    @Environment(\.accessibilityReduceMotion) private var still

    /// How long the tick stays, from the copy to its going back.
    static let held: TimeInterval = 1.1

    var body: some View {
        ZStack {
            if let art = Glyphs.art("link") {
                Image(nsImage: art)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: side, height: side)
                    .scaleEffect(ticked && !still ? 0.2 : 1)
                    .opacity(ticked ? 0 : 1)
                    .animation(still ? nil : ticked ? .easeIn(duration: 0.09) : .easeOut(duration: 0.16).delay(0.12), value: ticked)
            }
            Tick()
                .trim(from: 0, to: ticked || still ? 1 : 0)
                .stroke(style: StrokeStyle(lineWidth: side / 12, lineCap: .round, lineJoin: .round))
                .frame(width: side, height: side)
                .opacity(still && !ticked ? 0 : 1)
                .animation(still ? nil : ticked ? .easeOut(duration: 0.16).delay(0.1) : .easeIn(duration: 0.13), value: ticked)
        }
        .frame(width: side, height: side)
    }

    /// The checkmark's own line (Glyphs' "checkmark"), on its 24 square.
    private struct Tick: Shape {
        func path(in rect: CGRect) -> Path {
            let unit = rect.width / 24
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + 5 * unit, y: rect.minY + 12.75 * unit))
            path.addLine(to: CGPoint(x: rect.minX + 10 * unit, y: rect.minY + 19 * unit))
            path.addLine(to: CGPoint(x: rect.minX + 19 * unit, y: rect.minY + 5 * unit))
            return path
        }
    }
}

/// The plate's row: the lock, the site and the link, the lock and the site
/// (a dev page, whose link is among its tools), or the site alone, with
/// the air at its ends and between them at the most while the width it is
/// offered holds that, and less, evenly, down to the least as it narrows.
/// Past the least the lock and the link stand aside, and only then does the
/// site itself give up letters: the name is what the band is for, and ⌘L
/// still has the address to copy.
private struct Squeeze: Layout {
    let edge: ClosedRange<CGFloat>
    let gap: ClosedRange<CGFloat>

    /// The air at a width: the ends, the gaps, what is left to the site,
    /// and whether the lock and the link have stood aside for it.
    private func fit(_ width: CGFloat?, _ subviews: Subviews) -> (edge: CGFloat, gap: CGFloat, name: CGFloat, aside: Bool) {
        let named = subviews.count > 1 ? 1 : 0
        let slots = subviews.indices.filter { $0 != named }.reduce(0) { $0 + subviews[$1].sizeThatFits(.unspecified).width }
        let name = subviews[named].sizeThatFits(.unspecified).width
        let gaps = CGFloat(subviews.count - 1)
        let most = 2 * edge.upperBound + gaps * gap.upperBound + slots + name
        let least = 2 * edge.lowerBound + gaps * gap.lowerBound + slots + name
        guard let width, width < most else { return (edge.upperBound, gap.upperBound, name, false) }
        guard width > least else {
            // The words alone, with the air the doors had beside them.
            let air = subviews.count > 1 ? edge.lowerBound + gap.lowerBound : edge.lowerBound
            return (air, gap.lowerBound, min(name, max(0, width - 2 * air)), subviews.count > 1)
        }
        let t = (width - least) / (most - least)
        return (
            edge.lowerBound + t * (edge.upperBound - edge.lowerBound),
            gap.lowerBound + t * (gap.upperBound - gap.lowerBound),
            name,
            false
        )
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let air = fit(proposal.width, subviews)
        let named = subviews.count > 1 ? 1 : 0
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        if air.aside { return CGSize(width: 2 * air.edge + air.name, height: height) }
        let widths = subviews.indices.map { $0 == named ? air.name : subviews[$0].sizeThatFits(.unspecified).width }
        return CGSize(width: 2 * air.edge + CGFloat(subviews.count - 1) * air.gap + widths.reduce(0, +), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let air = fit(bounds.width, subviews)
        let named = subviews.count > 1 ? 1 : 0
        if air.aside {
            // Out of the window altogether, where the pointer can't find
            // them either, and the words in the middle of the plate.
            for index in subviews.indices where index != named {
                subviews[index].place(at: CGPoint(x: -10_000, y: bounds.midY), anchor: .leading, proposal: .unspecified)
            }
            subviews[named].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                                  proposal: ProposedViewSize(width: air.name, height: bounds.height))
            return
        }
        var x = bounds.minX + air.edge
        for index in subviews.indices {
            let width = index == named ? air.name : subviews[index].sizeThatFits(.unspecified).width
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + air.gap
        }
    }
}

/// A share's chip among the band's parts.
struct BandChip: LayoutValueKey {
    static let defaultValue = false
}

/// The band's three parts: the doors on the left at the band's start, those
/// on the right at its end, and the site in the middle of the whole band
/// while it fits there clear of the wider side's doors. Where it doesn't,
/// a narrow half, it steps toward the narrower side only as far as it has
/// to, and past the room between the doors gives up letters. A share's
/// chip stands before the doors at the end and is one of them to the site.
struct BandLayout: Layout {
    let rim: CGFloat
    /// The tab the band is for, whose parts are kept for SplitRule.
    var id: Tab.ID?
    /// The site from the band's start, just after the doors there, not in
    /// its middle: a dev page's whole address.
    var leads = false

    /// How wide a band's parts were last laid out: its ends' air, the
    /// doors on each side, the site. For the divider in the hand, which
    /// lays a band's picture out as this does.
    struct Parts {
        var rim: CGFloat
        var lead: CGFloat
        var trail: CGFloat
        var site: CGFloat
        /// The site from the band's start (`leads`).
        var leads = false
    }
    /// Written in layout, which is on the main thread, read there too. By
    /// the band's width as well as its tab: a tab's band can be laid out
    /// elsewhere at another width, and the divider wants the one in its half.
    nonisolated(unsafe) static var parts: [Tab.ID: [Int: Parts]] = [:]

    static func parts(of id: Tab.ID, width: CGFloat) -> Parts? {
        parts[id]?[Int(width.rounded())]
    }

    private func keep(_ parts: Parts, width: CGFloat) {
        guard let id else { return }
        var kept = BandLayout.parts[id] ?? [:]
        if kept.count > 8 { kept = [:] }
        kept[Int(width.rounded())] = parts
        BandLayout.parts[id] = kept
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews all: Subviews, cache: inout ()) {
        let chip = all.first { $0[BandChip.self] }
        let subviews = all.filter { !$0[BandChip.self] }
        guard subviews.count >= 2 else { return }
        let lead = subviews[0].sizeThatFits(.unspecified)
        let doors = subviews[1].sizeThatFits(.unspecified)
        subviews[0].place(at: CGPoint(x: bounds.minX + rim, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(lead))
        subviews[1].place(at: CGPoint(x: bounds.maxX - rim, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(doors))
        let site = subviews.count > 2 ? subviews[2].sizeThatFits(.unspecified) : .zero
        var trail = doors.width
        if let chip {
            let gap = Door.Size.band.gap
            let width = chip.sizeThatFits(.unspecified).width
            chip.place(at: CGPoint(x: bounds.maxX - rim - doors.width - gap, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
            if width > 0 { trail += gap + width }
        }
        guard subviews.count > 2 else {
            keep(Parts(rim: rim, lead: lead.width, trail: trail, site: 0, leads: leads), width: bounds.width)
            return
        }
        let parts = Parts(rim: rim, lead: lead.width, trail: trail, site: site.width, leads: leads)
        keep(parts, width: bounds.width)
        let (mid, width) = BandLayout.site(parts, in: bounds.minX, bounds.maxX)
        subviews[2].place(at: CGPoint(x: mid, y: bounds.midY), anchor: .center,
                          proposal: ProposedViewSize(width: width, height: site.height))
    }

    /// Where the site stands in a band from `start` to `end`, laid out as
    /// its parts say: from the band's start just after the doors there, or
    /// as below.
    static func site(_ parts: Parts, in start: CGFloat, _ end: CGFloat) -> (mid: CGFloat, width: CGFloat) {
        guard parts.leads else {
            return site(parts.site, lead: parts.lead, trail: parts.trail, rim: parts.rim, in: start, end)
        }
        let from = start + parts.rim + parts.lead + (parts.lead > 0 ? 8 : 0)
        let width = min(parts.site, max(0, end - parts.rim - parts.trail - 8 - from))
        return (from + width / 2, width)
    }

    /// Where the site stands in a band from `start` to `end`, its middle and
    /// its width: in the middle of the whole band while it fits there clear
    /// of the doors, else stepped toward the narrower side, else cut.
    static func site(_ site: CGFloat, lead: CGFloat, trail: CGFloat, rim: CGFloat, in start: CGFloat, _ end: CGFloat) -> (mid: CGFloat, width: CGFloat) {
        let from = start + rim + lead + 8
        let to = end - rim - trail - 8
        let width = min(site, max(0, to - from))
        let mid = min(max((start + end) / 2, from + width / 2), to - width / 2)
        return (mid, width)
    }
}

/// Tape across a dev page's band: stripes leaning right, as wide as the
/// air between them. Laid out once for a size.
private struct Hatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step: CGFloat = 12
        let lean = rect.height
        var x = rect.minX - lean
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + lean, y: rect.minY))
            path.addLine(to: CGPoint(x: x + lean + step / 2, y: rect.minY))
            path.addLine(to: CGPoint(x: x + step / 2, y: rect.maxY))
            path.closeSubpath()
            x += step
        }
        return path
    }
}

/// The pinned extensions in the band, the plate's doors (PlatePin) at the
/// band's size. A pin's popup up keeps them under the pointer in a half
/// behind, as the plate keeps its own: the popup hangs from the pin.
private struct BandPins: View {
    let quiet: Bool
    @ObservedObject var tab: Tab
    /// The window's sign-in's extensions (ExtensionSignIns).
    @ObservedObject private var here = ExtensionsHere.shared
    private var extensions: Extensions { here.current }
    /// A Chromium tab's own extensions (ChromiumColumn).
    @ObservedObject private var column = ChromiumColumn.shared
    @ObservedObject private var nativePopup = ChromiumPopupHost.shared
    /// Pins a window of the extension's own stands under (ExtensionWindowFrame).
    @ObservedObject private var hung = ExtensionWindowFrame.Hung.shared

    /// As many as a narrow band keeps beside its site; the rest are in the
    /// sliders' list.
    static let most = 6

    var body: some View {
        let popup = ExtensionPopup.shared
        let native = tab.engineKind == .chromium ? tab : nil
        let pinned = Array((native.map { column.buttons(for: $0) } ?? extensions.buttons.filter(\.pinned)).prefix(Self.most))
        let nativePopupID = native.flatMap { nativePopup.shownExtension(for: $0) }
        let nativeDoor = native.map { nativePopup.shownFromDoor(for: $0) } ?? false
        let popped = native != nil ? nativePopupID != nil && !nativeDoor : popup.isShown && !popup.fromDoor && pinned.contains { $0.id == popup.extensionID }
        // An extension's own window under one keeps them in, as its popup.
        let hidden = quiet && !popped && !pinned.contains { hung.ids.contains($0.id) }
        ForEach(pinned) { button in
            PlatePin(button: button, lit: popped && (nativePopupID ?? popup.extensionID) == button.id,
                     side: Door.Size.band.side, corner: Door.Size.band.corner, native: native) {
                if let native { column.press(button.id, tab: native) } else { extensions.press(button.id) }
            }
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
        }
    }
}
