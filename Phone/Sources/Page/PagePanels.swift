import QuickLook
import UIKit

/// The system's panels over a page: the share sheet, the print panel, the
/// document viewer. UIKit stands them above RootController's curtain and
/// the lock, so a private page's belong to Private: they go, with the file
/// made for them, as soon as Private locks or leaves the front.
@MainActor
final class PrivatePanels {
    private var open: [UUID: @MainActor () -> Void] = [:]
    fileprivate var watching = false

    var isEmpty: Bool { open.isEmpty }

    /// `close` takes the panel away at once and removes what was made for it.
    func opened(_ close: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        open[id] = close
        return id
    }

    /// The person closed it.
    func ended(_ id: UUID) { open[id] = nil }

    func closeAll() {
        let all = open.values
        open = [:]
        all.forEach { $0() }
    }
}

extension AppModel {
    /// A private panel may stay over its page while that page is in front
    /// and Private is not locked. Yab inactive or away keeps it under the
    /// curtain, as it keeps the page; Open with Face ID locks Private then.
    var privatePanelsMayStay: Bool {
        hasPrivateForeground && (!privateLock.requiresAuthentication || privateLock.phase == .unlocked)
    }

    /// The share sheet with `items`; `made` is a folder of files made for
    /// it, removed when the sheet goes.
    func presentShare(_ items: [Any], activities: [UIActivity]? = nil, isPrivate: Bool, made: URL? = nil) {
        let remove = { if let made { try? FileManager.default.removeItem(at: made) } }
        guard mayPresent(isPrivate: isPrivate), let root = Self.topController() else { remove(); return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: activities)
        // On iPad it is a popover, and UIKit throws without an anchor (register 1142).
        sheet.popoverPresentationController?.sourceView = root.view
        sheet.popoverPresentationController?.sourceRect = Self.shareAnchor(in: root.view)
        let panel = isPrivate ? openPrivatePanel { [weak sheet] in sheet?.presentingViewController?.dismiss(animated: false); remove() } : nil
        sheet.completionWithItemsHandler = { [weak self] _, _, _, _ in
            remove()
            if let panel { self?.privatePanels.ended(panel) }
        }
        root.present(sheet, animated: !Motion.disabled)
    }

    /// The system's viewer (QuickLook) with a file.
    func presentPreview(_ url: URL, isPrivate: Bool) {
        guard mayPresent(isPrivate: isPrivate), let root = Self.topController() else { return }
        let preview = FilePreview(url: url)
        let controller = QLPreviewController()
        controller.dataSource = preview
        controller.delegate = preview
        if isPrivate {
            let panel = openPrivatePanel { [weak controller] in controller?.presentingViewController?.dismiss(animated: false) }
            preview.dismissed = { [weak self] in self?.privatePanels.ended(panel) }
        }
        FilePreview.current = preview
        root.present(controller, animated: !Motion.disabled)
    }

    /// The print panel with `formatter`. PrintKit presents it on the
    /// window's top presented controller even while that one is on its way
    /// out (Site Controls closing for Print…), and UIKit drops it there: it
    /// waits until that controller is gone.
    func presentPrint(_ info: UIPrintInfo, _ formatter: UIPrintFormatter, isPrivate: Bool) {
        if let closing = Self.topController()?.presentedViewController, closing.isBeingDismissed,
           let transition = closing.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { [weak self] _ in self?.presentPrint(info, formatter, isPrivate: isPrivate) }
            return
        }
        guard mayPresent(isPrivate: isPrivate) else { return }
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = formatter
        let panel = isPrivate ? openPrivatePanel { controller.dismiss(animated: false) } : nil
        controller.present(animated: !Motion.disabled) { [weak self] _, _, _ in
            if let panel { self?.privatePanels.ended(panel) }
        }
    }

    /// Asked a moment ago, a private panel still shows only while it may stay.
    private func mayPresent(isPrivate: Bool) -> Bool { !isPrivate || privatePanelsMayStay }

    private func openPrivatePanel(_ close: @escaping @MainActor () -> Void) -> UUID {
        let id = privatePanels.opened(close)
        watchPrivatePanels()
        return id
    }

    /// While a private panel is open, the moment Private may no longer be
    /// seen it closes. As TabStack's pictures, it follows the lock itself:
    /// a background, a return, a lock from Settings, Private left.
    private func watchPrivatePanels() {
        guard !privatePanels.isEmpty else { privatePanels.watching = false; return }
        guard !privatePanels.watching else { return }
        privatePanels.watching = true
        let mayStay = withObservationTracking { privatePanelsMayStay } onChange: { [weak self] in
            Task { @MainActor in
                self?.privatePanels.watching = false
                self?.watchPrivatePanels()
            }
        }
        if !mayStay { privatePanels.closeAll() }
    }
}

/// A file in QuickLook, over everything.
@MainActor
final class FilePreview: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    fileprivate static var current: FilePreview?
    private let url: URL
    fileprivate var dismissed: (@MainActor () -> Void)?

    fileprivate init(url: URL) { self.url = url }

    nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        MainActor.assumeIsolated { url as NSURL }
    }

    nonisolated func previewControllerDidDismiss(_ controller: QLPreviewController) {
        MainActor.assumeIsolated {
            dismissed?()
            if Self.current === self { Self.current = nil }
        }
    }
}
