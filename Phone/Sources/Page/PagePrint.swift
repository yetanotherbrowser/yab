import UIKit
import WebKit
import os

private let printLog = Logger(subsystem: "dev.serafim.fast.iphone", category: "print")

/// The Mac's Duplicate Tab, Print… and Save as PDF for a page.
extension AppModel {
    /// The tab's page again, in a new tab of its space, in front.
    func duplicate(_ tab: Tab) {
        guard let url = tab.navigationURL else { return }
        openHeldLink(url, from: tab.id, as: .front)
    }

    /// Print…: the system's print panel with the page as WebKit lays it out for paper.
    func printPage() {
        guard let tab = browser.tab, let view = pages.liveView(tab.id) else { return }
        let info = UIPrintInfo.printInfo()
        info.jobName = tab.title
        info.outputType = .general
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = view.viewPrintFormatter()
        controller.present(animated: !Motion.disabled)
    }

    /// Save as PDF: the whole page as one PDF, handed to the share sheet
    /// (Save to Files and the rest), named for the page.
    func savePageAsPDF() {
        guard let tab = browser.tab, let view = pages.liveView(tab.id) else { return }
        view.createPDF { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(data):
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-pdf-\(UUID())", isDirectory: true)
                let name = PageDownload.filename(tab.title.isEmpty ? "Page" : tab.title)
                let file = folder.appendingPathComponent((name as NSString).pathExtension.lowercased() == "pdf" ? name : name + ".pdf")
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.write(to: file)
                } catch {
                    printLog.error("save as PDF: \(error.localizedDescription, privacy: .public)")
                    self.say("Couldn’t save this page", glyph: .exclamationCircle)
                    return
                }
                guard let root = Self.topController() else { return }
                let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView = root.view
                sheet.popoverPresentationController?.sourceRect = Self.shareAnchor(in: root.view)
                sheet.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: folder) }
                root.present(sheet, animated: !Motion.disabled)
            case let .failure(error):
                printLog.error("save as PDF: \(error.localizedDescription, privacy: .public)")
                self.say("Couldn’t save this page", glyph: .exclamationCircle)
            }
        }
    }
}
