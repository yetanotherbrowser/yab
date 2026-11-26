import SwiftUI
import Foundation

/// The atlas's first group, the page and its plate: the page full screen,
/// the plate at the bottom, back on the left, the space on the right, the Now
/// line over them when there is something to say. Each starts from the
/// atlas's own start: Work, Onboarding v3 in Figma, nothing running. Titles
/// and notes are the prototype's own, to find the frame by.
///
/// page.4 (the neighbor tab) and page.5 (past the last tab) are paging on
/// the plate (below); page.6, the plate's menu, the field branch's (M3,
/// States+Field.swift).
extension StateCatalog {
    static let page: [NamedState] = [
        NamedState("page.1", "Plain view", "Nothing running: no Now row.") { _ in },

        NamedState("page.2", "Scrolling", "The plate folds into a capsule, the Now row into a short word beside it.") { app in
            app.tasks.start("lisbon")
            app.tasks.set("lisbon", status: .running, step: 1)
            app.chrome.setFolded(true)
        },

        NamedState("page.folded", "Scrolling without Now", "The plate alone in a capsule: 158 wide, centered.") { app in
            app.chrome.setFolded(true)
        },

        NamedState("page.3", "Dark page", "The status bar turns light, the plate stays glass.") { app in
            // Personal's second tab of today: a dark video page.
            if let tab = app.browser.space("personal")?.today.dropFirst().first { app.browser.select(tab.id) }
        },

        NamedState("page.7", "Message", "Only when nothing on screen answers: “Link copied”.") { app in
            app.surfaces.showToast("Link copied", glyph: .chainLink1)
        },

    ] + paging + pageMenu + downloads + printing

    // MARK: - paging tabs on the plate

    private static let paging: [NamedState] = [
        NamedState("page.4", "Next tab", "A swipe on the plate: the page and caption follow the finger.") { app in
            let pager = Pager.of(app)
            pager.hold(at: -170)
            if let after = app.surfaces.pageSwipe?.after { await app.pages.waitUntilPainted(after.id, timeout: .seconds(8)) }
        },
        NamedState("page.4a", "Swipe started", "≡ and ↻ are gone, the pill shrank to the address and hugs the side it leaves toward.") { app in
            Pager.of(app).hold(at: -60)
        },
        NamedState("page.4c", "Swipe past the middle", "The leaving pill faded out, the incoming one slid in from the other side with its address.") { app in
            let pager = Pager.of(app)
            pager.hold(at: -260)
            if let after = app.surfaces.pageSwipe?.after { await app.pages.waitUntilPainted(after.id, timeout: .seconds(8)) }
        },
        NamedState("page.4e", "First tab", "Nothing further left: the page moves with resistance, the pill only loses ≡ and ↻.") { app in
            if let first = app.browser.pagingOrder.first { app.browser.select(first.id) }
            Pager.of(app).hold(at: 160)
        },
        NamedState("page.last", "Last tab", "No tabs to the right: a swipe left brings a new one.") { app in
            if let last = app.browser.pagingOrder.last { app.browser.select(last.id) }
        },
        NamedState("page.5a", "To a new tab", "Past the last tab the spaces screen slides in; ‹ fades, + becomes ✕.") { app in
            if let last = app.browser.pagingOrder.last { app.browser.select(last.id) }
            Pager.of(app).hold(at: -170)
        },
        NamedState("page.5", "Past the last tab", "The spaces screen almost settled; the pill turned into the New Tab field.") { app in
            if let last = app.browser.pagingOrder.last { app.browser.select(last.id) }
            Pager.of(app).hold(at: -300)
        },
        NamedState("page.5c", "New tab settling", "The pill settles into the field's place, ✕ where + was.") { app in
            if let last = app.browser.pagingOrder.last { app.browser.select(last.id) }
            Pager.of(app).hold(at: -380)
        },
        NamedState("page.5d", "New tab", "Let go: New Tab in place, no second growth, the keyboard rising.") { app in
            if let last = app.browser.pagingOrder.last { app.browser.select(last.id) }
            Pager.of(app).step(1)
            try? await Task.sleep(for: .milliseconds(900))
        },
    ]

    /// The page menu's states (the review page's SCENE 9 gallery), Site
    /// Settings (SCENE 14) and Find on Page (SCENE 12).
    static let pageMenu: [NamedState] = [
        NamedState("menu.copied", "Link copied", "As on the Mac: the link in the menu row turned into a checkmark for a second, the menu stayed.") { app in
            openPageMenu(app)
            app.pageMenu.copies = 1
        },
        NamedState("menu.loading", "Loading", "↻ → ✕, a bar under the address, Find and Reader grayed out.") { app in
            app.pageStateOverride = WebPool.PageState(isLoading: true, progress: 0.42, canGoBack: true)
            openPageMenu(app)
        },
        NamedState("menu.error", "Didn't open", "Under the domain “Can't open this page”, ↻ is the main button.") { app in
            let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
            app.pageStateOverride = WebPool.PageState(canGoBack: true, failure: PageLoadFailure(url: app.browser.tab?.navigationURL, error: error))
            openPageMenu(app)
        },
        NamedState("menu.kept", "Kept", "The tile filled, the caption “Kept”.") { app in
            if let tab = app.browser.tab, tab.place == .today { app.browser.keep(tab.id) }
            openPageMenu(app)
        },
        NamedState("menu.reader", "Reader on", "“Exit Reader”.") { app in
            app.pageStateOverride = WebPool.PageState(canGoBack: true, readerAvailable: true, readerEnabled: true)
            openPageMenu(app)
        },
        NamedState("menu.zoom", "Zoom 110%", "− 110% +, remembered for the site.") { app in
            if let tab = app.browser.tab { app.siteSettings.setZoom(1.1, for: app.siteHost(of: tab), isPrivate: false) }
            openPageMenu(app)
        },
        NamedState("menu.desktop", "Desktop Site", "«Request Mobile Site».") { app in
            if let tab = app.browser.tab { app.siteSettings.setDesktop(true, for: app.siteHost(of: tab), isPrivate: false) }
            openPageMenu(app)
        },
        NamedState("menu.mac", "Opened on Mac", "“Opened on MacBook Pro” with a checkmark.") { app in
            openPageMenu(app)
            app.pageMenu.openedOnMac = true
        },
        NamedState("menu.asleep", "Mac asleep", "The caption “Opens when your Mac wakes”.") { app in
            app.browser.macAsleep = true
            openPageMenu(app)
        },
        NamedState("menu.history", "Has history", "‹ › dark.") { app in
            app.pageStateOverride = WebPool.PageState(canGoBack: true, canGoForward: true, readerAvailable: true)
            openPageMenu(app)
        },
        NamedState("menu.private", "Private tab", "A dark menu without Ask, Give a Task, Open on Mac and Keep.") { app in
            app.openPrivately(PageFixtures.search(FieldSamples.gift))
            // The chrome closes a menu as the tab changes: open it after.
            try? await Task.sleep(for: .milliseconds(300))
            openPageMenu(app)
        },
        NamedState("site.1", "Site Settings", "The same sheet: the header “‹ figma.com”, the body replaced.") { app in
            openPageMenu(app)
            app.pageMenu.page = .site
        },
        NamedState("site.2", "Allowed here", "Camera allowed, the microphone will ask.") { app in
            if let tab = app.browser.tab {
                let host = app.siteHost(of: tab)
                app.siteSettings.setDecision(.allowed, .camera, for: host, isPrivate: false)
                app.siteSettings.setDecision(.ask, .microphone, for: host, isPrivate: false)
                app.siteSettings.setZoom(1.2, for: host, isPrivate: false)
            }
            openPageMenu(app)
            app.pageMenu.page = .site
        },
        NamedState("site.3", "Certificate", "Connection is secure ›: issued to, issued by, valid until.") { app in
            openPageMenu(app)
            app.pageMenu.page = .certificate
        },
        NamedState("site.4", "Long domain", "The header centered on the sheet; a long domain truncates at the end, as on the plate.") { app in
            let url = URL(string: "https://customer-support.eu-west.status.example-platform.com/incidents")!
            app.browser.open(PageFixtures.tab(for: url, in: app.world, fixturesEnabled: app.fixturesEnabled))
            // The chrome closes a menu as the tab changes: open it after.
            try? await Task.sleep(for: .milliseconds(300))
            openPageMenu(app)
            app.pageMenu.page = .site
        },
        NamedState("menu.ask", "Ask from the menu", "The Ask tile: a new chat about the page in front, ideas for it over the field, the keyboard.") { app in
            openPageMenu(app)
            try? await Task.sleep(for: .milliseconds(300))
            app.pageMenuAsk()
        },
        NamedState("menu.ask.sent", "Ask from the menu, question", "The first words in a chat from Ask: the page's plate (Figma) over the field, an answer about it.") { app in
            openPageMenu(app)
            try? await Task.sleep(for: .milliseconds(300))
            app.pageMenuAsk()
            try? await Task.sleep(for: .milliseconds(400))
            app.send("what does anna want?")
        },
        NamedState("menu.nomac", "Menu without a Mac", "No Ask tile: Find on Page, Keep, Share (--world empty).") { app in
            // Not now: the welcome stays away, the browser is empty and Mac-less.
            SettingsUI.shared.welcomeForced = false
            SettingsStore.shared.welcomed = true
            let url = URL(string: "https://example.com/")!
            app.browser.open(PageFixtures.tab(for: url, in: app.world, fixturesEnabled: app.fixturesEnabled))
            // The chrome closes a menu as the tab changes: open it after.
            try? await Task.sleep(for: .milliseconds(300))
            openPageMenu(app)
        },
        NamedState("find.1", "Find on page", "The system find bar; the plate, Back and + are gone.") { app in
            guard let tab = app.browser.tab else { return }
            app.pages.activate(tab)
            await app.pages.waitUntilPainted(tab.id, timeout: .seconds(12))
            app.findOnPage(tab.id, text: "hours")
        },
        NamedState("find.2", "On This Page", "A typed word: the “On This Page · N matches” row.") { app in
            // Counted on the drawn page itself, as typing does.
            guard let tab = app.browser.tab else { return }
            app.pages.activate(tab)
            await app.pages.waitUntilPainted(tab.id, timeout: .seconds(12))
            app.surfaces.openField(.address)
            app.field.typed("hours")
            for _ in 0..<40 where app.field.onThisPage == nil { try? await Task.sleep(for: .milliseconds(100)) }
        },
    ]

    /// The page menu part way into the field, held there.
    @MainActor
    static func menuToField(_ app: AppModel, _ t: CGFloat) {
        app.surfaces.openField(.address, from: CGRect(x: 20, y: 380, width: 362, height: 50), keepingMenu: true)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            var quiet = Transaction(animation: nil)
            quiet.disablesAnimations = true
            withTransaction(quiet) {
                app.pageMenu.toField = t
                app.field.progress = t
            }
        }
    }

    /// The page menu open, as ≡ leaves it.
    @MainActor
    static func openPageMenu(_ app: AppModel) {
        app.pageMenu.reset()
        app.pageMenu.shown = true
        app.surfaces.openMenu(.plate)
    }
}
