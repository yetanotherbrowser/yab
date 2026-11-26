import Foundation

/// Downloads (Page/DownloadStore): the page of the menu's sheet from each way
/// in, the menu's row, Site Settings' row, the Now line at each step, the
/// first file's card, and a private tab's own list.
extension StateCatalog {
    static let downloads: [NamedState] = [
        NamedState("downloads.menu", "Menu: file going", "Beside Site Settings: Downloads, “report-2026.pdf 42%” at its end.") { app in
            seed(app)
            openPageMenu(app)
        },
        NamedState("downloads.menu.count", "Menu: files kept", "Downloads with their count: 3.") { app in
            seed(app, running: false)
            openPageMenu(app)
        },
        NamedState("downloads.page", "Downloads", "The same sheet, “‹ Downloads”: one going with Stop, one that failed with Retry, kept ones, Show in Files.") { app in
            seed(app, failed: true)
            openPageMenu(app)
            app.pageMenu.page = .downloads
        },
        NamedState("downloads.site", "Site Settings: files here", "Downloads allowed in Allowed Here, Downloaded Here with a count and an arrow.") { app in
            seed(app, running: false)
            allow(app)
            openPageMenu(app)
            app.pageMenu.page = .site
        },
        NamedState("downloads.site.page", "This site's files", "One step deeper: only this site's, no Show in Files, ‹ back to Site Settings.") { app in
            seed(app)
            allow(app)
            openPageMenu(app)
            app.pageMenu.downloadsHost = host(app)
            app.pageMenu.page = .downloads
        },
        NamedState("downloads.now", "Now: file going", "Over the plate: report-2026.pdf, 42%.") { app in
            seed(app)
        },
        NamedState("downloads.now.several", "Now: three files", "“3 files · 42%”.") { app in
            seed(app, several: true)
        },
        NamedState("downloads.now.open", "Now: done", "report-2026.pdf, Open: for about two seconds.") { app in
            let first = seed(app, running: false)
            app.downloads.pretend(app.downloads.entries, arrived: first)
        },
        NamedState("downloads.now.failed", "Now: failed", "report-2026.pdf, Failed; the row has Retry.") { app in
            let first = seed(app, running: false, failed: true)
            app.downloads.pretend(app.downloads.entries, arrived: first)
        },
        // On iPad, downloads.now and downloads.now.open are the sidebar's
        // button with its ring and with the file's icon; these are the band's.
        NamedState("downloads.tablet.ring", "iPad: file going, sidebar away", "The band's downloads button, beside + and All Tabs: the ring round its mark at 42%.") { app in
            app.workspace.preferences.sidebarShown = false
            seed(app)
        },
        NamedState("downloads.tablet.waiting", "iPad: file in, sidebar away", "The band's downloads button holds report-2026.pdf's icon, with no timer, until the list or the file opens.") { app in
            app.workspace.preferences.sidebarShown = false
            let first = seed(app, running: false)
            app.downloads.pretend(app.downloads.entries, arrived: first)
        },
        NamedState("downloads.tablet.flight", "iPad: file thrown", "Download Linked File from mid-page: the dark disc with its white arrow halfway along its arc to the sidebar's downloads button, already shrinking.") { app in
            app.workspace.preferences.sidebarShown = true
            seed(app)
            let size = app.workspace.windowSize
            app.downloads.pretend(flight: "report-2026.pdf", from: CGPoint(x: size.width * 0.6, y: size.height * 0.45), held: 0.6)
        },
        NamedState("downloads.ask", "First file from a site", "A glass card over the plate: the file, “host · 2.9 MB”, Cancel and Download; the page live.") { app in
            app.downloads.pretend(ask: DownloadAsk(id: UUID(), name: "report-2026.pdf", host: host(app), size: 2_900_000, isPrivate: false))
        },
        NamedState("downloads.private", "Private tab's files", "A private tab sees only its own file; no Show in Files.") { app in
            app.openPrivately(PageFixtures.search(FieldSamples.gift))
            try? await Task.sleep(for: .milliseconds(300))
            seed(app)
            app.downloads.pretend([entry("private-notes.pdf", host: "example.com", ago: 120, isPrivate: true, file: true)] + app.downloads.entries)
            openPageMenu(app)
            app.pageMenu.page = .downloads
        },
        NamedState("downloads.empty", "No files", "The last one deleted: the page stays, “No Downloads”.") { app in
            openPageMenu(app)
            app.pageMenu.page = .downloads
        },
    ]

    @MainActor private static func host(_ app: AppModel) -> String { app.browser.tab.map { app.siteHost(of: $0) } ?? "figma.com" }

    @MainActor private static func allow(_ app: AppModel) {
        app.siteSettings.setDecision(.allowed, .downloads, for: host(app), isPrivate: false)
    }

    private static func entry(_ name: String, host: String, state: DownloadEntry.State = .done, size: Int64 = 480_000,
                              ago: TimeInterval, isPrivate: Bool = false, file: Bool = false) -> DownloadEntry {
        DownloadEntry(id: UUID(), name: name, host: host, size: size, date: Date().addingTimeInterval(-ago), state: state,
                      isPrivate: isPrivate, file: file ? name : nil)
    }

    /// One going or just ended, then two kept, one from another site.
    @discardableResult
    @MainActor private static func seed(_ app: AppModel, running: Bool = true, failed: Bool = false, several: Bool = false) -> UUID {
        let site = host(app)
        let going = DownloadEntry.State.running(received: 1_218_000, total: 2_900_000)
        var list = [entry("report-2026.pdf", host: site, state: running ? going : failed ? .failed : .done, size: 2_900_000, ago: 0, file: !running && !failed)]
        if several {
            list.append(entry("slides.zip", host: site, state: going, size: 2_900_000, ago: 0))
            list.append(entry("hero.png", host: site, state: going, size: 2_900_000, ago: 0))
        } else {
            if running, failed { list.append(entry("archive-2025.zip", host: site, state: .failed, size: 41_000_000, ago: 60)) }
            list.append(entry("invoice-1184.pdf", host: site, ago: 120, file: true))
            list.append(entry("hero.png", host: "figma.com" == site ? "dribbble.com" : "figma.com", size: 1_300_000, ago: 26 * 3600, file: true))
        }
        app.downloads.pretend(list)
        return list[0].id
    }
}
