import UIKit
import SwiftUI

extension Haptics.Reason {
    static let downloads = "downloads"
}

/// Downloads as the app has them: the first time a site sends a file it asks,
/// and the answer stays in Site Settings; the Downloads page in the menu's
/// sheet; a file's own actions.
extension AppModel {
    var downloads: DownloadStore { pages.downloads }

    func attachDownloads() {
        pages.onDownloadAsk = { [weak self] question, answer in
            guard let self else { answer(false); return }
            self.askDownload(question, answer: answer)
        }
        pages.onImageSaved = { [weak self] outcome in
            switch outcome {
            case .saved: self?.say("Saved to Photos", glyph: .checkCircle2)
            case .copied: self?.say("Image copied", glyph: .checkCircle2)
            case .noAccess: self?.say("Yab can’t add to Photos", glyph: .exclamationCircle)
            case .failed: self?.say("Couldn’t get this image", glyph: .exclamationCircle)
            }
        }
    }

    /// An allowed site doesn't ask, one told no doesn't send. A private tab
    /// asks every time: nothing of it is remembered.
    private func askDownload(_ question: DownloadAsk, answer: @escaping @MainActor (Bool) -> Void) {
        if !question.isPrivate {
            switch siteSettings.decision(.downloads, for: question.host, isPrivate: false) {
            case .allowed?: answer(true); return
            case .off?:
                say("Downloads are off for \(question.host)", glyph: .exclamationCircle)
                answer(false)
                return
            default: break
            }
        }
        // The card stands over the plate where it is at full size.
        chrome.fold(false)
        downloads.present(question, answer: answer)
    }

    /// Download remembers the site in Allowed Here; Cancel leaves it to ask again.
    func answerDownload(_ question: DownloadAsk, _ yes: Bool) {
        Haptics.play(.soft, reason: Haptics.Reason.downloads)
        if yes, !question.isPrivate {
            siteSettings.setDecision(.allowed, .downloads, for: question.host, isPrivate: false)
        }
        Motion.downloadAsk.run { downloads.answer(question.id, yes) }
    }

    // MARK: - the page

    /// The menu's row: every file.
    func openDownloadsPage() {
        Haptics.play(.soft, reason: Haptics.Reason.downloads)
        pageMenu.downloadsHost = nil
        bringIn(.downloads)
    }

    /// Site Settings' Downloaded Here: this site's, one step deeper.
    func openSiteDownloads() {
        guard let tab = browser.tab else { return }
        Haptics.play(.soft, reason: Haptics.Reason.downloads)
        pageMenu.downloadsHost = siteHost(of: tab)
        bringIn(.downloads)
    }

    /// The Now line: Open opens the file; otherwise the sheet comes out of
    /// the plate with Downloads already on it.
    func tapDownloadLine() {
        if let flash = downloads.flash, let file = downloads.entry(flash), file.isDone,
           downloads.list(isPrivate: pageIsPrivate).allSatisfy({ !$0.isRunning }) {
            downloads.flashTaken()
            openDownload(file)
            return
        }
        openDownloadsFromPlate()
    }

    func openDownloadsFromPlate() {
        guard browser.tab != nil, surfaces.menu == nil else { return }
        Haptics.play(.medium, reason: Haptics.Reason.pageMenu)
        pageMenu.reset()
        pageMenu.page = .downloads
        chrome.fold(false)
        var quiet = Transaction(animation: nil)
        quiet.disablesAnimations = true
        withTransaction(quiet) { surfaces.openMenu(.plate) }
    }

    // MARK: - a file

    func openDownload(_ file: DownloadEntry) {
        guard let url = downloads.url(of: file) else { return }
        FilePreview.show(url)
    }

    func shareDownload(_ file: DownloadEntry) {
        guard let url = downloads.url(of: file) else { return }
        // A turn later, so the row's menu is gone from under it.
        DispatchQueue.main.async {
            guard let root = Self.topController() else { return }
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = root.view
            sheet.popoverPresentationController?.sourceRect = Self.shareAnchor(in: root.view)
            root.present(sheet, animated: !Motion.disabled)
        }
    }

    func showDownloadInFiles(_ file: DownloadEntry) {
        guard let url = downloads.url(of: file) else { return }
        Self.openInFiles(url.deletingLastPathComponent())
    }

    func showDownloadsInFiles() {
        if let first = downloads.list(isPrivate: false).first(where: \.isDone) { showDownloadInFiles(first) }
    }

    /// The Files app at a folder of Yab's: its scheme takes the folder's path.
    private static func openInFiles(_ folder: URL) {
        guard var parts = URLComponents(url: folder, resolvingAgainstBaseURL: false) else { return }
        parts.scheme = "shareddocuments"
        if let url = parts.url { UIApplication.shared.open(url) }
    }

    func deleteDownload(_ file: DownloadEntry) {
        Haptics.play(.soft, reason: Haptics.Reason.downloads)
        withAnimation(Motion.fade) { downloads.delete(file.id) }
    }

    func retryDownload(_ file: DownloadEntry) {
        Haptics.play(.soft, reason: Haptics.Reason.downloads)
        downloads.retry(file.id)
    }
}
