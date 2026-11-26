import Photos
import UIKit
import UniformTypeIdentifiers
import WebKit

/// An image inside a held link. iOS's context menu says nothing of an image
/// (WKContextMenuElementInfo has only `linkURL`), so the page's own touch
/// listener (PageSignals) tells what lies under the finger, in Yab's script
/// world, and the link's menu adds Save to Photos, Copy Image and Share; the
/// bytes come through the page's own store, cookies and all. An image with no
/// link is WebKit's: it shows its own menu and never asks Yab.
@MainActor
enum PageImage {
    /// What the page says of the image under the finger.
    struct Held: Equatable, Sendable {
        let source: String
        let width: Int
        let height: Int
    }

    enum Outcome: Equatable, Sendable { case saved, copied, noAccess, failed }

    static let save = "Save to Photos"
    static let copy = "Copy Image"
    static let share = "Share Image…"

    static func held(in view: WKWebView) async -> Held? {
        let result = try? await view.callAsyncJavaScript("return window.__yabHeld ? window.__yabHeld() : null", in: nil, contentWorld: PageSignals.world)
        guard let values = result as? [String: Any], let source = values["src"] as? String, !source.isEmpty else { return nil }
        return Held(source: source, width: values["width"] as? Int ?? 0, height: values["height"] as? Int ?? 0)
    }

    /// Save to Photos, Copy Image, then Share.
    static func actions(_ held: Held, in view: WKWebView, said: @escaping @MainActor (Outcome) -> Void) -> [UIMenuElement] {
        let save = UIAction(title: Self.save, image: UIImage.menuGlyph(MacGlyph.photo)) { [weak view] _ in
            guard let view else { return }
            Task { @MainActor in
                guard let data = await bytes(of: held, in: view) else { said(.failed); return }
                said(await addToPhotos(data))
            }
        }
        save.accessibilityIdentifier = "image.save"
        let copy = UIAction(title: Self.copy, image: UIImage.menuGlyph(MacGlyph.yabCopy)) { [weak view] _ in
            guard let view else { return }
            Task { @MainActor in
                guard let data = await bytes(of: held, in: view), let image = UIImage(data: data) else { said(.failed); return }
                UIPasteboard.general.image = image
                Haptics.play(.soft, reason: Haptics.Reason.copied)
                said(.copied)
            }
        }
        copy.accessibilityIdentifier = "image.copy"
        let share = UIAction(title: Self.share, image: UIImage.menuGlyph(MacGlyph.yabShare)) { [weak view] _ in
            guard let view else { return }
            Task { @MainActor in
                guard let data = await bytes(of: held, in: view) else { said(.failed); return }
                present(data, held)
            }
        }
        share.accessibilityIdentifier = "image.share"
        return [save, copy, share]
    }

    /// Photos' add-only access, asked the first time and never again by Yab;
    /// the image goes in with the bytes the site sent.
    private static func addToPhotos(_ data: Data) async -> Outcome {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .noAccess }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            return .saved
        } catch { return .failed }
    }

    private static func present(_ data: Data, _ held: Held) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-image-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = PageDownload.filename(URL(string: held.source)?.lastPathComponent ?? "Image")
        let named = (name as NSString).pathExtension.isEmpty ? "\(name).\(ending(of: data))" : name
        let file = folder.appendingPathComponent(named, isDirectory: false)
        guard (try? data.write(to: file)) != nil, let root = AppModel.topController() else { return }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = root.view
        sheet.popoverPresentationController?.sourceRect = AppModel.shareAnchor(in: root.view)
        sheet.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: folder) }
        root.present(sheet, animated: !Motion.disabled)
    }

    private static func ending(of data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) else { return "jpg" }
        return UTType(type as String)?.preferredFilenameExtension ?? "jpg"
    }

    /// The image's bytes: a data: address in place, a blob: from the page,
    /// anything else as a download of the page's store, never a request of
    /// Yab's own that would miss the site's cookies.
    static func bytes(of held: Held, in view: WKWebView) async -> Data? {
        guard let url = URL(string: held.source) else { return nil }
        switch url.scheme?.lowercased() {
        case "data": return try? Data(contentsOf: url)
        case "blob":
            let script = "const r = await fetch(src); const b = new Uint8Array(await r.arrayBuffer()); let s = ''; for (let i = 0; i < b.length; i += 8192) s += String.fromCharCode.apply(null, b.subarray(i, i + 8192)); return btoa(s);"
            let result = try? await view.callAsyncJavaScript(script, arguments: ["src": held.source], in: nil, contentWorld: .page)
            return (result as? String).flatMap { Data(base64Encoded: $0) }
        case "http", "https":
            var request = URLRequest(url: url)
            if let page = view.url?.absoluteString { request.setValue(page, forHTTPHeaderField: "Referer") }
            return await ImageFetch.fetch(request, in: view)
        default: return nil
        }
    }
}

/// One image's bytes through WKDownload, into a temporary file and straight out.
@MainActor
private final class ImageFetch: NSObject, WKDownloadDelegate {
    private static var running: Set<ImageFetch> = []
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-held-\(UUID())", isDirectory: true)
    private var target: URL?
    private var done: ((Data?) -> Void)?

    static func fetch(_ request: URLRequest, in view: WKWebView) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let fetch = ImageFetch()
            fetch.done = { continuation.resume(returning: $0) }
            running.insert(fetch)
            view.startDownload(using: request) { $0.delegate = fetch }
        }
    }

    private func end(_ data: Data?) {
        try? FileManager.default.removeItem(at: folder)
        done?(data)
        done = nil
        Self.running.remove(self)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("image", isDirectory: false)
        target = file
        completionHandler(file)
    }

    func downloadDidFinish(_ download: WKDownload) { end(target.flatMap { try? Data(contentsOf: $0) }) }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { end(nil) }
}
