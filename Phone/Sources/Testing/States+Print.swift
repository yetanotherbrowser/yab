import UIKit

/// Keeping a page (Page/PagePrint): the system's print panel over it, and a
/// PDF document in the system's viewer, as a PDF a tab opens lands there.
extension StateCatalog {
    static let printing: [NamedState] = [
        NamedState("print.panel", "Print", "Print… from Site Controls › More: the system's print panel with the page laid out for paper.") { app in
            guard await loaded(app) else { return }
            app.printPage()
        },
        NamedState("print.viewer", "PDF in the viewer", "A PDF the page opened: into Downloads without the site's question, then the system's viewer over the page.") { app in
            guard let tab = app.browser.tab else { return }
            let file = DownloadEntry(id: UUID(), name: "report-2026.pdf", host: app.siteHost(of: tab), size: 48_000,
                                     date: Date(), state: .done, isPrivate: false, file: "report-2026.pdf")
            app.downloads.pretend([file], arrived: file.id)
            guard let url = app.downloads.url(of: file) else { return }
            try? onePagePDF(title: "Report 2026").write(to: url)
            app.openDownload(file)
        },
    ]

    /// Print draws WebKit's page, so the page in front has to be on screen first.
    @MainActor private static func loaded(_ app: AppModel) async -> Bool {
        guard let tab = app.browser.tab else { return false }
        app.pages.activate(tab)
        await app.pages.waitUntilPainted(tab.id, timeout: .seconds(12))
        return app.pageCanBeDrawn
    }

    /// A letter-size page with a title, so the viewer has a real document.
    private static func onePagePDF(title: String) -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            context.beginPage()
            let words = NSAttributedString(string: title, attributes: [.font: UIFont.boldSystemFont(ofSize: 32)])
            words.draw(at: CGPoint(x: 72, y: 72))
        }
    }
}
