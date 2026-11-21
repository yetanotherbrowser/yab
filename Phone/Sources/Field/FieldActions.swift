import SwiftUI
import UIKit
import os

/// What the field's choices do. From the plate's field a choice loads in
/// this tab (a search, an address), so Back returns to the page before, or
/// switches to a tab found; from New Tab it opens a new tab at the top of
/// today's; with the eyes shut, a private one. An ask grows the answer out
/// of the field; a task goes to the Mac and the Now line takes it. Over a
/// private tab the field offers no history and no agent, and what it opens
/// stays private.
extension AppModel {
    // MARK: - the rows and the key

    /// Every tab the words may find: pinned, kept (in folders too) and
    /// today's, in every space, as the Mac's ⌘T finds them. Private tabs are
    /// no one's history, so words never find them.
    var tabCandidates: [TabCandidate] {
        browser.spaces.flatMap { space -> [TabCandidate] in
            var out: [TabCandidate] = []
            @MainActor func visit(_ items: [KeptItem], folder: String?) {
                for item in items {
                    switch item {
                    case let .tab(tab):
                        if !tab.isPrivate { out.append(candidate(tab, space: space, folder: folder)) }
                    case let .folder(child): visit(child.items, folder: child.name)
                    }
                }
            }
            visit(space.kept, folder: nil)
            out += space.today.filter { !$0.isPrivate }.map { candidate($0, space: space, folder: nil) }
            out += space.visiblePins.filter { !$0.isPrivate }.map { candidate($0, space: space, folder: nil) }
            return out
        }
    }

    private func candidate(_ tab: Tab, space: Space, folder: String?) -> TabCandidate {
        TabCandidate(id: tab.id, title: tab.title, site: tab.site, icon: tab.icon, host: tab.host, folder: folder, space: space.name,
                     url: tab.navigationURL?.absoluteString)
    }

    /// The rows for the words typed, best first.
    var fieldRows: [WordRow] { fieldRows(content: NewTabContent.make(for: self)) }

    /// The rows, with New Tab's content already made. The field works them
    /// out once a draw and hands them to what reads them (its key, the
    /// address written on): each one looking through every place in History
    /// again cost a letter three times the work (#1637).
    func fieldRows(content: NewTabContent) -> [WordRow] {
        #if DEBUG
        fieldRowsMade += 1
        #endif
        // On the Chats page the words search the chats, in the card itself.
        if fieldSearchesChats { return [] }
        let name = fixturesEnabled ? "Google" : field.searchSettings.searchSelection.name
        // History and the Mac's bookmarks; never for words with the eyes shut.
        let places = field.place.isPrivate ? [] : history.places
        let settings = SettingsStore.shared
        var rows = Words.rows(for: field.words, in: field.place, tabs: tabCandidates, sites: content.frequent,
                              places: places, except: field.mode == .address ? field.pageID : nil,
                              replaces: field.pageIsToday, agent: settings.agent.name,
                              guesses: settings.guessesFromWords, asks: settings.offersAsk, tasks: settings.offersTask).map { row in
            guard row.action == .search else { return row }
            var row = row
            row.subtitle = "Search \(name) · " + (field.place.replacesTab && field.pageIsToday ? "in this tab" : "new tab")
            return row
        }
        // Yab's own menu actions, as the Mac's field finds them.
        rows = Words.withCommands(rows, typed: field.words, commands: commandCandidates)
        // The engine's completions, under the search for the words themselves.
        let phrases = SearchSuggest.shared.phrases(for: field.words)
        if !phrases.isEmpty {
            let at = (rows.lastIndex { $0.group == .web } ?? rows.count - 1) + 1
            let made = phrases.map { WordRow(action: .searchFor($0), icon: .magnifier, title: $0, subtitle: "Search \(name)",
                                             key: .search, group: .web) }
            rows.insert(contentsOf: made, at: min(max(at, 0), rows.count))
        }
        // Safari's "On This Page", last: the page in front holds the words.
        if field.mode == .address, let found = field.onThisPage,
           found.words == field.words.trimmingCharacters(in: .whitespacesAndNewlines), !rows.isEmpty {
            rows.append(WordRow(action: .findOnPage, icon: .onPage,
                                title: "On This Page · \(found.count) \(found.count == 1 ? "match" : "matches")",
                                subtitle: "Find “\(found.words)”", key: .go, group: .web))
        }
        return rows
    }

    /// The rest of the best row's address, written on after the words in
    /// the field ("net" + "flix.com"): only when the best row
    /// is a site, a tab or a page and the words are the start of its host.
    /// A search or Ask Claude is never written in the field.
    var fieldCompletion: String? {
        guard !field.showsAddress, !fieldAnswerTakesKey, !fieldSearchesChats else { return nil }
        return fieldCompletion(rows: fieldRows)
    }

    func fieldCompletion(rows: [WordRow]) -> String? {
        guard !field.showsAddress, !fieldAnswerTakesKey, !fieldSearchesChats else { return nil }
        let typed = field.text
        guard !typed.isEmpty, !typed.contains(where: \.isWhitespace), let row = rows.first else { return nil }
        return row.completion(after: typed)
    }

    /// The keyboard's key, named after the top row; go over the address.
    var fieldKey: WordRow.Key { fieldKey(rows: fieldRows) }

    /// The key for rows already made: a view that shows them asks this
    /// rather than making every row again.
    func fieldKey(rows: [WordRow]) -> WordRow.Key {
        fieldAnswerTakesKey || fieldSearchesChats ? .search : rows.first?.key ?? .go
    }

    // MARK: - Return, a row

    /// Return: the top row, or with the address showing, the page again.
    func fieldReturn() {
        // Search on the Chats page: the cards already show what it found, so
        // the keyboard goes and the list stays to look through.
        if fieldSearchesChats { return field.putKeyboardAway() }
        // A question and nothing else: the key copies its answer (FieldAnswer).
        if fieldAnswerTakesKey { return copyFieldAnswer() }
        if let row = fieldRows.first { return choose(row) }
        guard field.showsAddress, let tab = browser.tab else { return }
        closeFieldAfterChoice()
        _ = pages.view(for: tab)
        Task { @MainActor [weak self] in
            _ = await self?.pages.reloadSelected(tab.id)
        }
        say("Reloading", glyph: .arrowRotateClockwise)
    }

    /// A row chosen.
    func choose(_ row: WordRow) {
        let words = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = field.mode ?? .address
        // The eyes shut, or the plate's field over a private tab: what opens stays private.
        let isPrivate = field.place.isPrivate
        let fieldFrame = field.frame(in: screenSize)
        // The address standing as it was: the same page again.
        let samePage = field.showsAddress
        // Private words have no tab, chat or agent to go to (the rows never offer them).
        let searches: Bool = if case .searchFor = row.action { true } else { false }
        if isPrivate, !searches, ![.search, .open, .findOnPage].contains(row.action) { return }
        let place: Bool = if case .place = row.action { true } else { false }
        let site: Bool = if case .site = row.action { true } else { false }
        if searches || place || site || [.search, .open].contains(row.action) { adoptNewTabSpace() }
        field.forget()
        switch row.action {
        case let .tab(id):
            closeFieldAfterChoice()
            browser.select(id)
        case let .site(key):
            let site = NewTabContent.frequent(for: self).first { $0.key == key }
            closeFieldAfterChoice(goesUp: site.map { openTab(of: $0) == nil } ?? false)
            if let site { openFrequent(site) }
        case .search:
            closeFieldAfterChoice(goesUp: !samePage)
            show(PageFixtures.search(words, isPrivate: isPrivate, fixturesEnabled: fixturesEnabled,
                                     selection: field.searchSettings.searchSelection), newTab: mode == .newTab)
        case let .searchFor(phrase):
            closeFieldAfterChoice(goesUp: !samePage)
            show(PageFixtures.search(phrase, isPrivate: isPrivate, fixturesEnabled: fixturesEnabled,
                                     selection: field.searchSettings.searchSelection), newTab: mode == .newTab)
        case .open:
            closeFieldAfterChoice(goesUp: !samePage)
            let url = Words.address(words) ?? URL(string: "https://" + words)!
            show(PageFixtures.tab(for: url, isPrivate: isPrivate, in: world, fixturesEnabled: fixturesEnabled), newTab: mode == .newTab)
        case let .place(address):
            closeFieldAfterChoice(goesUp: !samePage)
            guard let url = URL(string: address) else { return }
            let page = fixturesEnabled ? PageFixtures.tab(for: url, in: world, fixturesEnabled: true)
                : PageFixtures.liveTab(for: url, title: row.title)
            show(page, newTab: mode == .newTab)
        case .ask:
            // The answer grows out of the field itself.
            Motion.answerGrow.run {
                surfaces.openChat(.answer(question: words, aboutPage: mode == .address), from: fieldFrame)
            }
        case .task:
            Haptics.play(.light, reason: Haptics.Reason.taskSent)
            closeFieldAfterChoice()
            startTask(for: words)
        case .settings:
            Motion.sheetGrow.run { surfaces.openSettings() }
        case let .command(token):
            guard let key = BrowserKey(token: token) else { return }
            closeFieldAfterChoice()
            // Once the field is gone: the keys stay the field's while it is up.
            DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.disabled ? 0 : Motion.fieldClose.duration)) { [weak self] in
                self?.use(key)
            }
        case .findOnPage:
            let id = browser.tab?.id
            closeFieldAfterChoice()
            // The field's keyboard goes first; iOS's find bar brings its own.
            DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.disabled ? 0 : Motion.fieldClose.duration)) { [weak self] in
                self?.findOnPage(id, text: words)
            }
        }
    }

    /// A New Tab row of Now or Recent Tabs.
    func choose(_ item: NewTabItem) {
        if case let .search(words) = item.action {
            return choose(WordRow(action: .searchFor(words), icon: .magnifier, title: words, subtitle: "", key: .search, group: .web))
        }
        adoptNewTabSpace()
        field.forget()
        let new: Bool = switch item.action {
        case .paste, .open: true
        case .go, .reopen, .search: false
        }
        closeFieldAfterChoice(goesUp: new)
        switch item.action {
        case .paste:
            guard let link = field.clipboardLink == FieldModel.pasteboardMarker ? UIPasteboard.general.url : field.clipboardLink else { return }
            show(PageFixtures.tab(for: link, in: world, fixturesEnabled: fixturesEnabled), newTab: true)
        case let .open(page):
            var tab = page
            tab.id = PageFixtures.newID()
            show(tab, newTab: true)
        case let .go(id):
            browser.select(id)
        case let .reopen(id):
            backStack.undo(id)
        case .search:
            break
        }
    }

    /// A Frequent site: its tab open in this space, else a new one.
    func openFrequent(_ site: SiteCandidate) {
        if let open = openTab(of: site) {
            browser.select(open.id)
        } else {
            show(PageFixtures.site(site, fixturesEnabled: fixturesEnabled), newTab: true)
        }
    }

    private func openTab(of site: SiteCandidate) -> Tab? {
        let page = PageFixtures.site(site, fixturesEnabled: fixturesEnabled)
        return browser.space.allTabs.first {
            !$0.isPrivate && (fixturesEnabled ? $0.icon == site.key : $0.navigationURL == page.navigationURL)
        }
    }

    /// A Frequent tile tapped in New Tab.
    func chooseFrequent(_ site: SiteCandidate) {
        adoptNewTabSpace()
        field.forget()
        closeFieldAfterChoice()
        openFrequent(site)
    }

    /// Shows a page: a new tab at the top of today's, or in the tab in front,
    /// its own web view, so Back returns. A pin stays the site it pins and a
    /// kept tab, a folder's too, the page it keeps: the page opens as a new
    /// tab first in today's instead, as the prototype's navigate does. Loaded
    /// into a live folder's tab, it rewrote that tab everywhere, so whatever
    /// was opened over it landed in the folder instead of Today. A private
    /// page loads only into a private tab: over an ordinary one (the plate's
    /// field with its eyes shut) it is a private tab of its own, or the
    /// ordinary tab took it and history recorded it (#1603).
    func show(_ tab: Tab, newTab: Bool) {
        guard !newTab, let front = browser.tab, front.place == .today, tab.isPrivate == front.isPrivate else {
            if tab.isPrivate { openPrivately(tab) }
            else {
                // Opening the eyes in Private explicitly returns to ordinary browsing.
                let ordinary = browser.space.isPrivate ? browser.ordinarySpaceID : nil
                browser.open(tab, in: ordinary)
            }
            return
        }
        load(tab, into: front)
    }

    /// The page opens in Private: a dark tab, in a store kept
    /// in memory only, gone with the last private tab (WebPool).
    func openPrivately(_ tab: Tab) {
        var tab = tab
        tab.isPrivate = true
        if !tab.id.hasPrefix("private-") { tab.id = "private-" + UUID().uuidString.prefix(8).lowercased() }
        browser.open(tab)
        field.privateTabsNow(Set(browser.allTabs.filter(\.isPrivate).map(\.id)))
    }

    /// Closes a private tab: gone from today's, its page, its picture, its
    /// draft, and with the last one the store they shared. Closed any other
    /// way (the column, Clear), FieldModel's watch does the same.
    func closePrivate(_ id: Tab.ID) {
        guard browser.tab(id)?.isPrivate == true else { return }
        browser.close(id)
        field.privateTabsNow(Set(browser.allTabs.filter(\.isPrivate).map(\.id)))
    }

    /// The world's task the words read as, if any: until the Mac takes any
    /// words (M8), a task is one of the world's own.
    func worldTask(for words: String) -> TaskDefinition.ID? {
        let lower = words.lowercased()
        let pick: TaskDefinition.ID? = lower.contains("anna") || lower.contains("repl") ? "anna"
            : lower.contains("lumen") || lower.contains("spot") || lower.contains("design systems") ? "lumen"
            : lower.contains("lisbon") || lower.contains("flight") ? "lisbon" : nil
        return pick.flatMap { tasks.definition($0) != nil ? $0 : nil }
    }

    /// A task in words goes to the Mac; the Now line takes it. Words that are
    /// none of the world's tasks are only said sent until the Mac takes any (M8).
    func startTask(for words: String) {
        guard fixturesEnabled else { _ = taskDesk.send(words: words); return }
        guard let id = worldTask(for: words) else { return say("Sent to your Mac", glyph: .macbook) }
        taskDesk.send(id, words: words)
    }

    /// The field goes back where it came from after a choice that opens no
    /// sheet of its own. The eyes open again, as softly as they shut.
    func closeFieldAfterChoice(goesUp: Bool = false) {
        field.sheetGoesUp = goesUp && field.inSheet && !field.isPrivate
        if field.isPrivate { Haptics.play(.soft, reason: Haptics.Reason.eyes) }
        field.endPrivate()
        guard surfaces.field != nil else { return }
        Motion.fieldClose.run { surfaces.closeField() }
    }

    // MARK: - the page's card

    enum PageAction: String, CaseIterable {
        case copy, share, ask, onMac

        var title: String {
            switch self {
            case .copy: "Copy Link"
            case .share: "Share"
            case .ask: "Ask"
            case .onMac: "On Mac"
            }
        }

        var glyph: GlyphName {
            switch self {
            case .copy: .chainLink1
            case .share: .shareOs
            case .ask: .sparkle
            case .onMac: .macbook
            }
        }
    }

    /// The page card's actions: over a private tab only Copy Link and Share,
    /// as the agent doesn't read it and the Mac never has it.
    var pageActions: [PageAction] {
        browser.tab?.isPrivate == true ? [.copy, .share] : PageAction.allCases
    }

    func pageAction(_ action: PageAction) {
        guard let tab = browser.tab, pageActions.contains(action) else { return }
        switch action {
        case .copy:
            closeFieldAfterChoice()
            copyLink(of: tab)
        case .share:
            closeFieldAfterChoice()
            share(tab)
        case .ask:
            field.put(askSample(for: tab))
        case .onMac:
            closeFieldAfterChoice()
            guard !tab.isPrivate else { return }
            if isFixture { say("Open on your Mac", glyph: .macbook) }
            else { sync.openOnMac(tab) }
        }
    }

    /// What Ask on the page's card puts in the field: the world's question
    /// for its page (the onboarding file Anna commented on), else a summary.
    /// By the page shown, not the tab: a tab can show another page now.
    func askSample(for tab: Tab) -> String {
        isFixture && tab.address == "figma.com/design/xK29fLm8/Onboarding-v3" ? "what does anna want?" : "summarize this page"
    }

    func link(of tab: Tab) -> URL? {
        tab.navigationURL ?? Words.address(tab.address)
    }

    func copyLink(of tab: Tab) {
        Haptics.play(.soft, reason: Haptics.Reason.linkCopied)
        say("Link copied", glyph: .chainLink1)
        UIPasteboard.general.url = link(of: tab)
    }

    /// The iOS share sheet for a page.
    func share(_ tab: Tab) {
        guard let url = link(of: tab) else { return }
        // The page itself beside its address: with its web view among the
        // items iOS offers Add to Home Screen, as from Safari (#2034).
        // Never a private page's: the home screen would keep it.
        let page = tab.isPrivate ? nil : pages.liveView(tab.id)
        // A turn later, so the field or the menu is gone from under it.
        DispatchQueue.main.async {
            guard let root = Self.topController() else { return }
            let items: [Any] = page.map { [url, $0] } ?? [url]
            let sheet = UIActivityViewController(activityItems: items, applicationActivities: [OpenInSafariActivity()])
            // On iPad it is a popover, and UIKit throws without an anchor
            // (register 1142), as PageDownload's share does.
            sheet.popoverPresentationController?.sourceView = root.view
            sheet.popoverPresentationController?.sourceRect = Self.shareAnchor(in: root.view)
            root.present(sheet, animated: !Motion.disabled)
        }
    }

    static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        // A popover on its way out (Site Controls closing for Share) can't present.
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    /// Where a share sheet's popover points on iPad: under the toolbar, where
    /// Site Controls and the downloads button are, or over the phone's plate.
    static func shareAnchor(in view: UIView) -> CGRect {
        let traits = view.traitCollection
        if TabletWorkspaceGeometry.usesToolbar(size: view.bounds.size, regular: traits.horizontalSizeClass == .regular,
                                               idiom: traits.userInterfaceIdiom) {
            return CGRect(x: view.bounds.midX, y: view.safeAreaInsets.top + TabletWorkspaceGeometry.toolbar, width: 1, height: 1)
        }
        return CGRect(x: view.bounds.midX, y: view.bounds.maxY - 44, width: 1, height: 1)
    }

    /// The screen the app draws on.
    var screenSize: CGSize {
        if workspace.tabletControls, field.shown { return workspace.windowSize }
        if workspace.paneFrame.width > 0 {
            var size = workspace.paneFrame.size
            if workspace.expanded, field.shown { size.width = min(size.width, Metrics.Workspace.sidebar) }
            else if workspace.expanded, chatSheet.shown { size.width = min(size.width, Metrics.Workspace.conversation) }
            return size
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.keyWindow?.bounds.size ?? Metrics.screen
    }

    // MARK: - the plate's menu

    /// Both plus menus use the same captured page owner and private entry.
    /// Authentication may finish later, after this page has been left.
    /// `then` runs once the field is open (the menu's Voice Search, Scan QR Code).
    func openNewTab(privately: Bool? = nil, from origin: CGRect? = nil, then: (@MainActor () -> Void)? = nil) {
        let owner = browser.spaceID
        let source = browser.tab
        let privateInput = privately == true || browser.space.isPrivate || source?.isPrivate == true
        let open: @MainActor () -> Void = { [weak self] in
            guard let self, self.browser.spaceID == owner,
                  self.browser.tab?.id == source?.id,
                  self.browser.tab?.navigationURL == source?.navigationURL,
                  !self.surfaces.settings, !self.surfaces.join,
                  self.surfaces.chat == nil, self.surfaces.field == nil else { return }
            Haptics.play(.light, reason: Haptics.Reason.confirm)
            self.chrome.unfold()
            Motion.plusToField.run { self.field.openNewTab(privately: privateInput, from: origin) }
            then?()
        }
        if privateInput { privateLock.request(open) }
        else { open() }
    }

    func reloadOrStopPage() {
        guard let tab = browser.tab else { return }
        Haptics.play(.soft, reason: Haptics.Reason.reload)
        if currentPageState.isLoading { pages.stop(tab.id) }
        else {
            Task { @MainActor [weak self] in
                _ = await self?.pages.reloadSelected(tab.id)
            }
        }
    }
}

extension WordRow {
    /// The host's tail after `typed`, when the row opens a site whose host
    /// starts so: "net" and netflix.com give "flix.com".
    func completion(after typed: String) -> String? {
        let host: String?
        switch action {
        case .site, .tab:
            if case let .favicon(_, h) = icon { host = h } else { host = nil }
        case let .place(url):
            host = URL(string: url)?.host
        default:
            host = nil
        }
        guard let host, !host.isEmpty else { return nil }
        let lower = typed.lowercased()
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        for whole in [bare, host] where whole.count > typed.count && whole.lowercased().hasPrefix(lower) {
            return String(whole.dropFirst(typed.count))
        }
        return nil
    }
}
