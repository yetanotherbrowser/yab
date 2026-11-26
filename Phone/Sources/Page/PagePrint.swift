import UIKit
import WebKit
import os

private let printLog = Logger(subsystem: "dev.serafim.fast.iphone", category: "print")

/// The Mac's Duplicate Tab, Print… and Save as PDF for a page, and
/// Download for a page that is a file.
extension AppModel {
    /// The tab's page again, in a new tab of its space, in front.
    func duplicate(_ tab: Tab) {
        guard let url = tab.navigationURL else { return }
        openHeldLink(url, from: tab.id, as: .front)
    }

    /// The page in front is a picture, a sound or text WebKit shows: the
    /// menus offer Download for it.
    var pageDownloadable: Bool { browser.tab != nil && currentPageState.downloadable }

    /// Download: the picture, sound or text the page is, into Downloads.
    func downloadPage() {
        guard let tab = browser.tab else { return }
        pages.downloadDocument(of: tab.id)
    }

    /// Print and Save as PDF draw the page WebKit has for the tab in front:
    /// a tab not loaded yet (restored, or a Mac's) has none.
    var pageCanBeDrawn: Bool { browser.tab.map { pages.isLive($0.id) } ?? false }

    /// Print…: the system's print panel with the page as WebKit lays it out for paper.
    func printPage() {
        guard let tab = browser.tab, let view = pages.liveView(tab.id) else { return }
        let info = UIPrintInfo.printInfo()
        info.jobName = tab.title
        info.outputType = .general
        let formatter = view.viewPrintFormatter(), isPrivate = pageIsPrivate
        // A turn later, so Site Controls is on its way out from under it.
        DispatchQueue.main.async { [weak self] in self?.presentPrint(info, formatter, isPrivate: isPrivate) }
    }

    /// The page's title as a PDF's name: the whole name, extension and all,
    /// within the file system's limits (PageDownload.filename).
    static func pdfName(_ title: String) -> String {
        let named = title.isEmpty ? "Page" : title
        return PageDownload.filename((named as NSString).pathExtension.lowercased() == "pdf" ? named : named + ".pdf")
    }

    /// Save as PDF: the whole page as one PDF, handed to the share sheet
    /// (Save to Files and the rest), named for the page.
    func savePageAsPDF() {
        guard let tab = browser.tab, let view = pages.liveView(tab.id) else { return }
        let isPrivate = pageIsPrivate
        view.createPDF { [weak self] result in
            // Made while the person may have left the page, Yab or Private:
            // then nothing of it is shown, or kept.
            guard let self, self.presents(for: tab.id, isPrivate: isPrivate,
                                          appActive: UIApplication.shared.applicationState == .active) else { return }
            switch result {
            case let .success(data):
                let folder = self.downloads.exportFolder(isPrivate: isPrivate)
                let file = folder.appendingPathComponent(Self.pdfName(tab.title))
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.write(to: file)
                } catch {
                    printLog.error("save as PDF: \(error.localizedDescription, privacy: .public)")
                    self.say("Couldn’t save this page", glyph: .exclamationCircle)
                    return
                }
                self.presentShare([file], isPrivate: isPrivate, made: folder)
            case let .failure(error):
                printLog.error("save as PDF: \(error.localizedDescription, privacy: .public)")
                self.say("Couldn’t save this page", glyph: .exclamationCircle)
            }
        }
    }
}
