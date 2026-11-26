import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share sheet's Yab: what was shared, Keep for Later and Open in Yab
/// (ShareCard). Both leave the link in the App Group's queue
/// (SharedLinkQueue). Keep for Later also uploads its saved sync record;
/// Open in Yab then opens Yab at
/// yab://shared, which takes the link and shows it in Peek, as a link from
/// another app opens today. Until Yab may be the default browser, this is
/// how a link from another app gets in.
final class ShareViewController: UIViewController {
    @Observable
    final class Model {
        var found: SharedItems.Found?
        var phase: ShareCardPhase = .loading
    }

    private let model = Model()
    private let queue = SharedLinkQueue.shared
    private let syncAccess = SharedLinkSyncAccess.standard
    private var upload: SharedLinkUpload?
    private var ended = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let host = UIHostingController(rootView: ShareRoot(model: model, open: { [weak self] in self?.choose(.open) },
                                                           keep: { [weak self] in self?.choose(.keep) },
                                                           close: { [weak self] in self?.cancel() }))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        // As tall as the card where the system lets a share sheet say so.
        if let sheet = sheetPresentationController {
            sheet.detents = [.custom(identifier: .init("yab.share")) { _ in ShareCardMetrics.sheetHeight }]
            sheet.preferredCornerRadius = 38
        }
        Task { await read() }
    }

    // MARK: - what was shared

    private func read() async {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        var urls: [URL] = []
        var texts: [String] = []
        var title: String?
        for item in items {
            if title == nil { title = item.attributedTitle?.string }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), let url = await Self.url(from: provider) {
                    urls.append(url)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let text = await Self.text(from: provider) {
                    texts.append(text)
                }
            }
            // Some apps share words only as the item's own text.
            if let text = item.attributedContentText?.string, !text.isEmpty {
                texts.append(text)
                if title == nil, urls.contains(where: SharedItems.isWeb) { title = text }
            }
        }
        model.found = SharedItems.find(urls: urls, texts: texts, title: title)
        model.phase = model.found == nil ? .nothing : .ready
    }

    private static func url(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func text(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
        }
    }

    // MARK: - the choice

    private func choose(_ action: SharedLink.Action) {
        guard let found = model.found, model.phase == .ready else { return }
        var link = SharedLink(action: action, address: found.address, search: found.search, title: found.title)
        let session = syncAccess.session
        let context = SharedLinkSyncContext.read(for: queue)
        if action == .keep, let context, let session, context.account == session.seal?.account,
           context.device == session.device {
            link = (try? context.prepare(link, pending: queue.links)) ?? link
        }
        let queued = queue.add(link)
        switch action {
        case .keep:
            guard queued else { model.phase = .failed; return }
            // Said where the buttons were, then the sheet goes: nothing else shows it.
            model.phase = .kept
            let earliest = DispatchTime.now() + 0.8
            if let payload = SharedLinkSyncRecord.read(link), let session, let context,
               let upload = SharedLinkUpload(record: payload.record, access: syncAccess, session: session) {
                self.upload = upload
                upload.start(base: context.base) { [weak self] _ in
                    DispatchQueue.main.asyncAfter(deadline: earliest) { self?.finish() }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: earliest) { [weak self] in self?.finish() }
            }
        case .open:
            // Queued, Yab takes it from the queue; else the link rides in the URL itself.
            guard let url = queued ? YabRoute.shared.url : (found.search ? nil : SharedLink.wrapped(found.address)) else {
                model.phase = .failed
                return
            }
            openYab(url) { [weak self] opened in
                guard let self else { return }
                if opened { self.finish() } else { self.model.phase = queued ? .waiting : .failed }
            }
        }
    }

    /// Opens Yab. A share extension has no sanctioned way to open its app
    /// (NSExtensionContext.open is for widgets and says no here), so it asks
    /// its own UIApplication through the responder chain. When neither works the link still
    /// waits in the queue, and the card says Yab opens it next time.
    private func openYab(_ url: URL, completion: @escaping (Bool) -> Void) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, @convention(block) (Bool) -> Void) -> Void
                let open = unsafeBitCast(current.method(for: selector), to: Open.self)
                let done: @convention(block) (Bool) -> Void = { opened in DispatchQueue.main.async { completion(opened) } }
                open(current, selector, url as NSURL, NSDictionary(), done)
                return
            }
            responder = current.next
        }
        extensionContext?.open(url) { opened in DispatchQueue.main.async { completion(opened) } }
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        upload?.cancel()
        upload = nil
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        guard !ended else { return }
        ended = true
        upload?.cancel()
        upload = nil
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}

/// The card, following the model.
private struct ShareRoot: View {
    let model: ShareViewController.Model
    let open: () -> Void
    let keep: () -> Void
    let close: () -> Void

    var body: some View {
        ShareCard(found: model.found, phase: model.phase, open: open, keep: keep, close: close)
            .ignoresSafeArea(edges: .bottom)
    }
}
