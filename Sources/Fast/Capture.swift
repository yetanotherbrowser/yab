import AppKit
import SwiftUI
import QuartzCore
import ImageIO
import UniformTypeIdentifiers
import AudioToolbox
import CoreImage
import AVFoundation

// ⇧⌘2: a part of the page, the page as it shows, or all of it, framed and
// on the clipboard (docs/capture.md).
//
// Motion as the prototype set it
// out (work/visualizations/yab-capture-morph.html). What was taken is one
// object from the page to the corner, to the editor and into Downloads:
// the picture lifts off where it was, and the card grows out of it (P3,
// P4). It is never made again on the way, so nothing jumps where one view
// would hand over to another.
//
// All of it is Core Animation in a view of its own over the window, the
// way LinkPeek and the downloads' flights are: a SwiftUI animation would
// be a commit of the whole window every frame. SwiftUI only draws the
// words and buttons, in hosting views that fade.
//
// The picture is WebKit's own (takeSnapshot, painted in the page's
// process), so no permission to record the screen is asked for, and the
// outline and the dim over the page are never in it.

/// How a capture is framed, kept from one to the next: the last look is the
/// next one's (Pika's way), with nothing to name or manage.
struct CaptureStyle: Codable, Equatable {
    enum Backdrop: String, Codable, CaseIterable { case page, hue, wallpaper, none }
    enum Shape: String, Codable, CaseIterable {
        case auto, wide, square, tall
        var ratio: CGFloat? {
            switch self {
            case .auto: return nil
            case .wide: return 16.0 / 9.0
            case .square: return 1
            case .tall: return 4.0 / 5.0
            }
        }
        var title: String {
            switch self {
            case .auto: return "Auto"
            case .wide: return "16:9"
            case .square: return "1:1"
            case .tall: return "4:5"
            }
        }
    }

    var backdrop = Backdrop.page
    /// 0…360, the hue backdrop's.
    var hue: Double = 28
    var shape = Shape.auto
    var hidePrivate = true

    static let key = "capture.style"

    static var saved: CaptureStyle {
        guard let data = Store.settings.data(forKey: key),
              let style = try? JSONDecoder().decode(CaptureStyle.self, from: data) else { return CaptureStyle() }
        return style
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { Store.settings.set(data, forKey: Self.key) }
    }
}

/// Where the picture sits in its frame, in the picture's points. The same
/// numbers draw the file and the preview, so the preview is the file.
struct CaptureLayout: Equatable {
    var canvas: CGSize
    /// The picture, from the canvas' bottom left.
    var picture: CGRect

    /// Whether a shape suits a picture: one that would more than double
    /// the frame, a whole page made 16:9, is left at its own shape.
    static func fits(_ size: CGSize, _ shape: CaptureStyle.Shape) -> Bool {
        guard let ratio = shape.ratio, size.width > 0, size.height > 0 else { return true }
        let own = size.width / size.height
        return max(own / ratio, ratio / own) <= 2
    }

    /// The page's own corner on a backdrop (Radius.surface), for the picture.
    static let corner = Radius.surface

    init(_ size: CGSize, _ style: CaptureStyle) {
        guard style.backdrop != .none else {
            canvas = size
            picture = CGRect(origin: .zero, size: size)
            return
        }
        // Air around it in proportion to the smaller side, as a mat is cut:
        // a long page gets the air of its width, not of its length.
        let pad = min(96, max(24, (min(size.width, size.height) * 0.1).rounded()))
        var width = size.width + pad * 2
        var height = size.height + pad * 2
        if let ratio = style.shape.ratio, CaptureLayout.fits(size, style.shape) {
            if width / height < ratio { width = height * ratio } else { height = width / ratio }
        }
        canvas = CGSize(width: width.rounded(), height: height.rounded())
        picture = CGRect(x: ((canvas.width - size.width) / 2).rounded(), y: ((canvas.height - size.height) / 2).rounded(),
                         width: size.width, height: size.height)
    }
}

/// What was taken, and from where.
struct Shot {
    let image: CGImage
    /// The picture's size in points, the page's own.
    let size: CGSize
    let name: String
    let url: URL?
    let title: String
    /// Where it was on screen, in the overlay's points: where it lifts off.
    let source: CGRect
    /// Boxes of things not to show, in the picture's points from its top left.
    var secrets: [CGRect] = []
    /// The page's color at the picture's edges, for the Page backdrop.
    var tint: NSColor?
    /// The file's own name, for a picture that has one (Capture Image).
    var file: String?

    var host: String { url?.host() ?? "" }
    var pixels: CGSize { CGSize(width: image.width, height: image.height) }
    var scale: CGFloat { size.width > 0 ? CGFloat(image.width) / size.width : 2 }
}

/// The finished picture: drawn away from the main thread, from the same
/// layout the preview uses.
enum CaptureArt {
    /// Colors for a backdrop, top left to bottom right.
    static func colors(_ style: CaptureStyle, tint: NSColor?) -> [CGColor] {
        switch style.backdrop {
        case .hue:
            let h = style.hue / 360
            let a = NSColor(hue: (h + 0.05).truncatingRemainder(dividingBy: 1), saturation: 0.42, brightness: 0.98, alpha: 1)
            let b = NSColor(hue: (h + 0.96).truncatingRemainder(dividingBy: 1), saturation: 0.58, brightness: 0.88, alpha: 1)
            return [a.cgColor, b.cgColor]
        case .page:
            let base = (tint ?? NSColor(white: 0.94, alpha: 1)).usingColorSpace(.sRGB) ?? NSColor(white: 0.94, alpha: 1)
            let light = 0.299 * base.redComponent + 0.587 * base.greenComponent + 0.114 * base.blueComponent
            // Near white, a quiet warm gray, so the picture's own white edge
            // and its shadow still read; near black, lifted a little.
            if light > 0.86 {
                return [NSColor(srgbRed: 0.95, green: 0.945, blue: 0.93, alpha: 1).cgColor,
                        NSColor(srgbRed: 0.87, green: 0.86, blue: 0.84, alpha: 1).cgColor]
            }
            if light < 0.18 {
                return [(base.blended(withFraction: 0.16, of: .white) ?? base).cgColor, base.cgColor]
            }
            return [(base.blended(withFraction: 0.22, of: .white) ?? base).cgColor,
                    (base.blended(withFraction: 0.08, of: .black) ?? base).cgColor]
        case .wallpaper, .none:
            return []
        }
    }

    /// The edge color of a picture: its border, averaged.
    nonisolated static func tint(of image: CGImage) -> NSColor? {
        let side = 12
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var sum = (r: 0.0, g: 0.0, b: 0.0), n = 0.0
        for y in 0..<side { for x in 0..<side where x == 0 || y == 0 || x == side - 1 || y == side - 1 {
            let i = (y * side + x) * 4
            sum.r += Double(bytes[i]); sum.g += Double(bytes[i + 1]); sum.b += Double(bytes[i + 2]); n += 1
        } }
        guard n > 0 else { return nil }
        return NSColor(srgbRed: sum.r / n / 255, green: sum.g / n / 255, blue: sum.b / n / 255, alpha: 1)
    }

    /// The picture on its backdrop, at the picture's own pixels per point.
    nonisolated static func compose(_ shot: Shot, _ style: CaptureStyle, colors: [CGColor], wallpaper: CGImage?) -> CGImage? {
        let layout = CaptureLayout(shot.size, style)
        let scale = shot.scale
        let width = Int((layout.canvas.width * scale).rounded()), height = Int((layout.canvas.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.interpolationQuality = .high
        let whole = CGRect(origin: .zero, size: layout.canvas)
        switch style.backdrop {
        case .none: break
        case .wallpaper:
            if let wallpaper {
                let w = CGFloat(wallpaper.width), h = CGFloat(wallpaper.height)
                let fill = max(whole.width / w, whole.height / h)
                context.draw(wallpaper, in: CGRect(x: (whole.width - w * fill) / 2, y: (whole.height - h * fill) / 2, width: w * fill, height: h * fill))
            } else {
                context.setFillColor(NSColor(white: 0.9, alpha: 1).cgColor)
                context.fill(whole)
            }
        case .page, .hue:
            if colors.count == 2, let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: whole.height), end: CGPoint(x: whole.width, y: 0), options: [])
            }
        }
        let framed = style.backdrop != .none
        let corner = framed ? CaptureLayout.corner : 0
        let path = CGPath.rounded(layout.picture, corner: corner)
        if framed {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -Shadow.lift.y), blur: Shadow.lift.radius, color: NSColor(white: 0, alpha: CGFloat(Shadow.lift.opacity)).cgColor)
            context.addPath(path)
            context.setFillColor(NSColor.white.cgColor)
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(shot.image, in: layout.picture)
        if style.hidePrivate {
            context.setFillColor(CaptureArt.hush)
            for box in shot.secrets {
                let r = CGRect(x: layout.picture.minX + box.minX, y: layout.picture.maxY - box.maxY, width: box.width, height: box.height).insetBy(dx: -1, dy: -1)
                context.addPath(CGPath.rounded(r, corner: 3))
                context.fillPath()
            }
        }
        context.restoreGState()
        return context.makeImage()
    }

    /// What a hidden thing is painted over with: solid, never a blur, which
    /// can be undone.
    static let hush = NSColor(white: 0.16, alpha: 1).cgColor

    /// A PNG that pastes at the page's size: its pixels per inch say how
    /// many pixels to a point, and it says where it came from.
    nonisolated static func png(_ image: CGImage, scale: CGFloat, from url: URL?, title: String) -> Data? {
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        var png: [CFString: Any] = [:]
        if let url { png[kCGImagePropertyPNGDescription] = url.absoluteString }
        if !title.isEmpty { png[kCGImagePropertyPNGTitle] = title }
        png[kCGImagePropertyPNGSoftware] = "yab"
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
            kCGImagePropertyPNGDictionary: png,
        ]
        CGImageDestinationAddImage(target, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(target) else { return nil }
        return data as Data
    }

    /// A page's PDF as a picture `width` pixels wide.
    nonisolated static func raster(pdf data: Data, width: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let k = CGFloat(width) / box.width
        let height = Int((box.height * k).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: k, y: k)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// The page behind the editor: a small picture of it, blurred.
    nonisolated static func blur(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image).clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(4, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    /// A smaller copy for the layers, which can't hold a texture past 16k.
    nonisolated static func fit(_ image: CGImage, longest: Int) -> CGImage {
        let side = max(image.width, image.height)
        guard side > longest, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        let k = CGFloat(longest) / CGFloat(side)
        let w = max(1, Int(CGFloat(image.width) * k)), h = max(1, Int(CGFloat(image.height) * k))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? image
    }
}

/// The Mac's own shutter, the one ⇧⌘4 makes, and only when the Mac makes
/// interface sounds at all (Sound › Play user interface sound effects).
/// A system sound, which plays on the sound server: NSSound's first play
/// held the main thread 70 to 130 ms, just when the picture should fly.
enum CaptureSound {
    private static var sound: SystemSoundID = 0
    private static let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"

    static var on: Bool {
        (UserDefaults(suiteName: "com.apple.systemsound")?.object(forKey: "com.apple.sound.uiaudio.enabled") as? Int ?? 1) != 0
    }

    /// Read ahead of the press, so the click is on time.
    static func warm() {
        guard sound == 0, on else { return }
        AudioServicesCreateSystemSoundID(URL(fileURLWithPath: path) as CFURL, &sound)
    }

    static func play() {
        guard on else { return }
        warm()
        if sound != 0 { AudioServicesPlaySystemSound(sound) }
    }
}

/// What the page is asked, in yab's own world, where the page's scripts
/// can't see it.
enum CaptureScript {
    static let source = #"""
    (() => {
      if (window.__yabCapture) return;
      const tags = {IMG:'Image',PICTURE:'Image',svg:'Drawing',SVG:'Drawing',CANVAS:'Canvas',VIDEO:'Video',NAV:'Navigation',
        HEADER:'Header',FOOTER:'Footer',MAIN:'Main',ASIDE:'Sidebar',SECTION:'Section',ARTICLE:'Article',FORM:'Form',
        TABLE:'Table',PRE:'Code',FIGURE:'Figure',BUTTON:'Button',A:'Link',P:'Paragraph',UL:'List',OL:'List',LI:'Item',
        H1:'Heading',H2:'Heading',H3:'Heading',H4:'Heading',H5:'Heading',H6:'Heading',BLOCKQUOTE:'Quote',
        INPUT:'Field',TEXTAREA:'Field',SELECT:'Menu',IFRAME:'Frame',DIALOG:'Dialog',LABEL:'Label'};
      const roles = {navigation:'Navigation',banner:'Header',contentinfo:'Footer',dialog:'Dialog',button:'Button',img:'Image',
        figure:'Figure',table:'Table',list:'List',listitem:'Item',article:'Article',region:'Section',main:'Main'};
      const name = n => {
        const aria = ((n.getAttribute && n.getAttribute('aria-label')) || '').trim();
        if (aria && aria.length <= 28) return aria;
        const role = n.getAttribute && n.getAttribute('role');
        if (role && roles[role]) return roles[role];
        return tags[n.tagName] || 'Block';
      };
      const same = (a, b) => Math.abs(a.x - b.x) < 1 && Math.abs(a.y - b.y) < 1 && Math.abs(a.w - b.w) < 1 && Math.abs(a.h - b.h) < 1;
      const secretText = /[\w.+-]+@[\w-]+\.[\w.-]{2,}|\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{8,}|\bgh[pousr]_[A-Za-z0-9]{20,}|\bAKIA[0-9A-Z]{16}\b|\beyJ[\w-]{10,}\.[\w-]{10,}\.[\w-]{5,}|\b(?:\d[ -]?){13,19}\b|\b[0-9a-f]{32,}\b/g;
      window.__yabCapture = {
        at(x, y) {
          const out = [];
          for (let n = document.elementFromPoint(x, y); n && n !== document.documentElement && out.length < 16; n = n.parentElement) {
            if (n === document.body) break;
            const r = n.getBoundingClientRect();
            if (r.width < 12 || r.height < 12) continue;
            const d = getComputedStyle(n).display;
            if (d === 'inline' || d === 'contents') continue;
            const box = {x: r.left, y: r.top, w: r.width, h: r.height, name: name(n)};
            const last = out[out.length - 1];
            if (last && same(last, box)) { if (box.name !== 'Block') last.name = box.name; continue; }
            out.push(box);
          }
          return out;
        },
        page() {
          const d = document.documentElement, b = document.body;
          return {x: scrollX, y: scrollY, w: Math.max(d.scrollWidth, b ? b.scrollWidth : 0),
                  h: Math.max(d.scrollHeight, b ? b.scrollHeight : 0), vw: innerWidth, vh: innerHeight};
        },
        secrets(rx, ry, rw, rh) {
          const out = [];
          const add = r => {
            if (r.width > 0 && r.height > 0 && r.right > rx && r.left < rx + rw && r.bottom > ry && r.top < ry + rh && out.length < 200)
              out.push({x: r.left - rx, y: r.top - ry, w: r.width, h: r.height});
          };
          for (const i of document.querySelectorAll('input')) {
            if (getComputedStyle(i).visibility === 'hidden') continue;
            const t = (i.type || '').toLowerCase(), ac = (i.autocomplete || '').toLowerCase();
            let filled = false;
            try { filled = i.matches(':autofill'); } catch (e) {}
            if (!i.value && t !== 'password') continue;
            secretText.lastIndex = 0;
            if (t === 'password' || t === 'email' || t === 'tel' || /cc-|email|tel|one-time-code|password/.test(ac) || filled
                || secretText.test(i.value || '')) add(i.getBoundingClientRect());
          }
          if (!document.body) return out;
          const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          let seen = 0;
          for (let t = walk.nextNode(); t && seen < 6000; t = walk.nextNode()) {
            seen++;
            const s = t.nodeValue;
            if (!s || s.length < 6) continue;
            if (t.parentElement && getComputedStyle(t.parentElement).visibility === 'hidden') continue;
            secretText.lastIndex = 0;
            let m;
            while ((m = secretText.exec(s))) {
              const range = document.createRange();
              range.setStart(t, m.index);
              range.setEnd(t, m.index + m[0].length);
              for (const r of range.getClientRects()) add(r);
            }
          }
          return out;
        }
      };
    })();
    """#
}

/// A box on the page, as the page measured it, in CSS pixels from the
/// viewport's top left.
struct CaptureBox: Equatable {
    var rect: CGRect
    var name: String

    init?(_ any: Any?) {
        guard let d = any as? [String: Any], let x = (d["x"] as? NSNumber)?.doubleValue, let y = (d["y"] as? NSNumber)?.doubleValue,
              let w = (d["w"] as? NSNumber)?.doubleValue, let h = (d["h"] as? NSNumber)?.doubleValue else { return nil }
        rect = CGRect(x: x, y: y, width: w, height: h)
        name = d["name"] as? String ?? "Block"
    }
}

/// The words and state the hosted parts draw. Its own object, watched only
/// by the capture's hosting views, never by the window.
@MainActor
final class CaptureModel: ObservableObject {
    @Published var style = CaptureStyle.saved
    @Published var pixels = CGSize.zero
    @Published var name = ""
    @Published var host = ""
    @Published var secrets = 0
    @Published var tint: NSColor?
    @Published var wallpaper: NSImage?
    /// Said in the pill while a long page is being taken.
    @Published var busy: String?
    /// The picture's size in points, for which shapes suit it.
    @Published var size = CGSize.zero
    /// Its view is up in the window's room (CaptureSkyLayer).
    @Published var up = false
    /// While picking: whether the cookie notice, a chat bubble, anything
    /// fixed over the page is left out.
    var act: (CaptureAction) -> Void = { _ in }

    var dims: String { "\(Int(pixels.width)) × \(Int(pixels.height))" }
}

enum CaptureAction { case visible, whole, cancel, edit, save, done, style(CaptureStyle) }

// MARK: - the capture

@MainActor
final class Capture {
    enum Stage: String { case idle, picking, plate, editing }

    private(set) var stage = Stage.idle
    weak var browser: Browser?
    private weak var tab: Tab?
    private var view: CaptureView?
    private(set) var shot: Shot?
    let model = CaptureModel()
    /// Where its view goes: a room over the window that SwiftUI keeps on
    /// top (CaptureSky). A view added to the window's hosting view by hand
    /// was put under SwiftUI's own layers and never seen.
    weak var room: NSView?
    /// The page's boxes under the pointer, innermost first, and which of
    /// them is picked (↑ goes out, ↓ back in).
    private var chain: [CaptureBox] = []
    private var level = 0
    private var asking = false
    private var pending: CGPoint?
    private var composed: CGImage?
    private var making = 0
    /// The clipboard's count after this capture's last write, so a newer
    /// look replaces it but something copied meanwhile is left alone.
    private var copied = -1
    /// This capture's place in the clipboard's history, replaced by each
    /// new look of it.
    private var clip: UUID?
    /// This capture is one picture's (`image`): its look is its own, not
    /// the next capture's.
    private var plain = false
    /// And from a private tab: nothing of it stays in the clipboard's
    /// history or in Files.
    private var unkept = false
    /// Which Capture Image this is, so a late answer from the last one is
    /// let go.
    private var imageTurn = 0
    private var hush: DispatchWorkItem?
    private var recopy: DispatchWorkItem?
    private var monitor: Any?
    private var wallpaperFor: URL?

    /// Timings of the last capture, for ./bench.
    private(set) var metrics: [String: Double] = [:]
    private var started: CFTimeInterval = 0

    init(_ browser: Browser) {
        self.browser = browser
        model.act = { [weak self] in self?.act($0) }
    }

    var shown: Bool { stage != .idle }

    private func act(_ action: CaptureAction) {
        switch action {
        case .visible: take(.visible)
        case .whole: take(.whole)
        case .cancel: stage == .picking ? cancel() : close()
        case .edit: edit()
        case .save: save()
        case .done: back()
        case .style(let style): restyle(style)
        }
    }

    // MARK: picking

    /// ⇧⌘2: into picking; again while picking, the page as it shows.
    func start() {
        switch stage {
        case .picking: take(.visible); return
        case .plate, .editing: close(quick: true)
        case .idle: break
        }
        guard let tab = browser?.active, !tab.isBlank else { return }
        let t0 = CACurrentMediaTime()
        guard raise(over: tab) else { return }
        CaptureSound.warm()
        metrics = ["pick_ms": (CACurrentMediaTime() - t0) * 1000]
    }

    /// The overlay up over a tab's page, ready to pick from or to land on.
    private func raise(over tab: Tab, quiet: Bool = false) -> Bool {
        guard let web = tab.builtPage, let content = room, content.window != nil, content.window === web.window else { return false }
        self.tab = tab
        web.runInYab(CaptureScript.source)
        let view: CaptureView
        if let kept = self.view, kept.superview === content {
            view = kept
        } else {
            self.view?.removeFromSuperview()
            view = CaptureView(capture: self, frame: content.bounds)
            view.autoresizingMask = [.width, .height]
            content.addSubview(view)
            self.view = view
        }
        stage = .picking
        model.up = true
        chain = []
        level = 0
        model.busy = nil
        if quiet {
            var style = CaptureStyle.saved
            style.backdrop = .none
            style.shape = .auto
            model.style = style
        } else if plain {
            model.style = .saved
        }
        plain = quiet
        unkept = quiet && tab.shy
        view.pick(page: pageRect(web, in: view), model: model, quiet: quiet)
        watchKeys()
        return true
    }

    // MARK: a picture

    /// Capture Image, from a picture's menu: that picture, with nothing to
    /// pick and no frame. Its own pixels, as many as its file has, so what
    /// comes out is the image itself as a PNG; a look given it in the editor
    /// stays with it and is not the next capture's. One with no pixels to
    /// read here, an SVG or one its site won't give again, is taken off the
    /// page where it shows.
    func image(_ url: URL, on tab: Tab) {
        imageTurn += 1
        let asked = imageTurn
        let box = tab.pointedImage?.url == url ? tab.pointedImageBox : nil
        Task { [weak tab] in
            guard let tab else { return }
            let data = await Browser.imageData(url, from: tab) ?? Data()
            let name = data.isEmpty ? nil : Browser.pictureName(url, data, on: tab)
            DispatchQueue.global(qos: .userInitiated).async {
                let image = Capture.pixels(of: data)
                let preview = image.map { CaptureArt.fit($0, longest: Capture.previewSide) }
                let tint = preview.flatMap { CaptureArt.tint(of: $0) }
                DispatchQueue.main.async { [weak self, weak tab] in
                    guard let self, let tab, self.imageTurn == asked, self.browser?.active === tab else { return }
                    self.land(image: image, preview: preview, tint: tint, name: name, box: box, on: tab)
                }
            }
        }
    }

    private func land(image: CGImage?, preview: CGImage?, tint: NSColor?, name: String?, box: CGRect?, on tab: Tab) {
        if stage != .idle { close(quick: true) }
        guard !tab.isBlank, raise(over: tab, quiet: true), let web = tab.builtPage, let view else {
            return couldnt()
        }
        started = CACurrentMediaTime()
        metrics = [:]
        if let image, let preview {
            let page = pageRect(web, in: view)
            let source = box.flatMap(onScreen) ?? page.insetBy(dx: page.width * 0.3, dy: page.height * 0.3)
            turn += 1
            early = []
            var shot = Shot(image: image, size: CGSize(width: image.width, height: image.height), name: "Image",
                            url: tab.address, title: tab.title, source: source)
            shot.tint = tint
            shot.file = name.map { ($0 as NSString).deletingPathExtension + ".png" }
            CaptureSound.play()
            land(shot, preview: preview)
        } else if let box, let source = onScreen(box) {
            snap(css: box, source: source, name: "Image")
        } else {
            close(quick: true)
            couldnt()
        }
    }

    private func couldnt() {
        browser?.toaster.pop("Couldn’t capture the image", mark: "exclamationmark.triangle")
    }

    /// A picture's first frame the way it is meant to stand, whatever its
    /// file's orientation says, and no larger than a capture may be.
    nonisolated static func pixels(of data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, width > 0, height > 0 else { return nil }
        let shrink = min(1, (Double(Capture.most) / (width * height)).squareRoot())
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int((max(width, height) * shrink).rounded()),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: picking, on the page

    private func pageRect(_ web: any PageHandle, in view: NSView) -> CGRect {
        view.convert(web.bounds, from: web)
    }

    private var zoom: CGFloat {
        guard let web = tab?.builtPage else { return 1 }
        return web.pageZoom * web.magnification
    }

    /// A box the page measured, in the overlay's points.
    func onScreen(_ css: CGRect) -> CGRect? {
        guard let web = tab?.builtPage, let view else { return nil }
        let z = zoom
        var r = CGRect(x: css.minX * z, y: css.minY * z, width: css.width * z, height: css.height * z)
        if !web.isFlipped { r.origin.y = web.bounds.height - r.maxY }
        return view.convert(r, from: web)
    }

    /// A point in the overlay, in the page's CSS pixels.
    private func css(_ point: CGPoint) -> CGPoint? {
        guard let web = tab?.builtPage, let view else { return nil }
        let p = web.convert(point, from: view)
        let z = zoom
        return CGPoint(x: p.x / z, y: (web.isFlipped ? p.y : web.bounds.height - p.y) / z)
    }

    /// The pointer moved over the page: what is under it, asked one at a
    /// time, the latest point waiting while an answer is on its way.
    func hover(_ point: CGPoint) {
        guard stage == .picking else { return }
        if asking { pending = point; return }
        guard let web = tab?.builtPage, let at = css(point) else { return }
        asking = true
        let t0 = CACurrentMediaTime()
        web.runInYab("window.__yabCapture ? window.__yabCapture.at(\(at.x), \(at.y)) : []") { [weak self] answer in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.asking = false
                self.metrics["hover_ms"] = (CACurrentMediaTime() - t0) * 1000
                guard self.stage == .picking else { return }
                let found = (answer as? [Any] ?? []).compactMap(CaptureBox.init)
                if found != self.chain { self.chain = found; self.level = 0 }
                self.outline()
                if let next = self.pending { self.pending = nil; self.hover(next) }
            }
        }
    }

    private func outline() {
        guard let view else { return }
        if chain.indices.contains(level), let rect = onScreen(chain[level].rect) {
            view.outline(rect, name: chain[level].name, size: chain[level].rect.size)
        } else {
            view.outline(nil, name: "", size: .zero)
        }
    }

    /// The wheel over the page while picking goes to the page.
    func scroll(_ event: NSEvent) {
        tab?.builtPage?.scrollWheel(with: event)
    }

    /// ↑ to the box around this one, ↓ back in.
    func step(out: Bool) {
        guard stage == .picking, !chain.isEmpty else { return }
        level = out ? min(chain.count - 1, level + 1) : max(0, level - 1)
        outline()
    }

    enum Kind { case box, area(CGRect), visible, whole }

    /// A click, a drag, ↩ or F.
    func take(_ kind: Kind) {
        guard stage == .picking, pageTask == nil, let tab, let web = tab.builtPage, let view else { return }
        started = CACurrentMediaTime()
        let page = pageRect(web, in: view)
        switch kind {
        case .box:
            guard chain.indices.contains(level), let rect = onScreen(chain[level].rect) else { return take(.visible) }
            let box = chain[level]
            snap(css: box.rect, source: rect, name: box.name)
        case .area(let rect):
            let r = rect.intersection(page)
            guard r.width >= 4, r.height >= 4, let a = css(CGPoint(x: r.minX, y: r.maxY)),
                  let b = css(CGPoint(x: r.maxX, y: r.minY)) else { return }
            let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            snap(css: box, source: r, name: "Area")
        case .visible:
            let z = zoom
            snap(css: CGRect(x: 0, y: 0, width: web.bounds.width / z, height: web.bounds.height / z), source: page, name: "Visible part")
        case .whole:
            view.busy("Taking the whole page")
            web.runInYab("window.__yabCapture ? window.__yabCapture.page() : null") { [weak self] answer in
                MainActor.assumeIsolated {
                    guard let self, self.stage == .picking, let d = answer as? [String: Any],
                          let y = (d["y"] as? NSNumber)?.doubleValue, let w = (d["vw"] as? NSNumber)?.doubleValue,
                          let h = (d["h"] as? NSNumber)?.doubleValue else { return self?.take(.visible) ?? () }
                    // The whole length, the top of it `y` above the view's.
                    let css = CGRect(x: 0, y: -y, width: w, height: max(h, 1))
                    let source = self.onScreen(css) ?? page
                    self.snap(css: css, source: source, name: "Whole page")
                }
            }
        }
    }

    /// The pixels past which a picture is taken smaller: 36 million, a page
    /// some 11,000 points long at 2x, some 140 MB in memory.
    nonisolated static let most: CGFloat = 36_000_000

    private func snap(css: CGRect, source: CGRect, name: String) {
        guard pageTask == nil, let tab, let web = tab.builtPage, let window = web.window else { return }
        let z = zoom
        let rect = CGRect(x: css.minX * z, y: css.minY * z, width: css.width * z, height: css.height * z)
        let scale = window.backingScaleFactor
        let pixels = rect.width * rect.height * scale * scale
        let width = pixels > Capture.most ? rect.width * (Capture.most / pixels).squareRoot() : rect.width
        let config = PageShot(rect: rect, width: width, afterUpdates: false)
        let fits = CGRect(origin: .zero, size: web.bounds.size).insetBy(dx: -1, dy: -1).contains(rect)
        let url = tab.address, title = tab.title
        let asked = CACurrentMediaTime()
        turn += 1
        let turn = self.turn
        early = nil
        // What not to show is looked for beside the picture, not before it:
        // the picture lands as soon as it is taken, and the boxes go on it
        // when they come, before anything reaches the clipboard.
        if fits {
            web.runInYab("window.__yabCapture ? window.__yabCapture.secrets(\(css.minX), \(css.minY), \(css.width), \(css.height)) : []") { [weak self] answer in
                MainActor.assumeIsolated {
                    guard let self, turn == self.turn else { return }
                    self.metrics["secrets_ms"] = (CACurrentMediaTime() - asked) * 1000
                    let found = (answer as? [Any] ?? []).compactMap(CaptureBox.init).map { $0.rect.applying(.init(scaleX: z, y: z)) }
                    if self.shot != nil, self.landed == turn { self.hide(found) } else { self.early = found }
                }
            }
        }
        let taken: (CGImage?) -> Void = { [weak self] image in
            MainActor.assumeIsolated {
                guard let self, turn == self.turn, self.stage == .picking else { return }
                guard let image else { self.failed(); return }
                self.metrics["snapshot_ms"] = (CACurrentMediaTime() - asked) * 1000
                // The layers get a picture their size, made away from the
                // main thread: handed the whole one, the commit that starts
                // the flight copied 14 to 45 MB and dropped frames.
                DispatchQueue.global(qos: .userInitiated).async {
                    let p0 = CACurrentMediaTime()
                    let preview = CaptureArt.fit(image, longest: Capture.previewSide)
                    let tint = CaptureArt.tint(of: preview)
                    let p1 = CACurrentMediaTime()
                    DispatchQueue.main.async { [weak self] in
                        guard let self, turn == self.turn, self.stage == .picking else { return }
                        self.metrics["preview_ms"] = (p1 - p0) * 1000
                        var shot = Shot(image: image, size: css.size.applying(.init(scaleX: z, y: z)), name: name, url: url, title: title, source: source)
                        shot.tint = tint
                        self.land(shot, preview: preview)
                    }
                }
            }
        }
        // Use the screen renderer for every part, including long pages.
        // PDF export paints composited content differently from the screen.
        if fits {
            web.snapshot(config) { image, _ in taken(image?.cgImage(forProposedRect: nil, context: nil, hints: nil)) }
        } else {
            let pixelWidth = Int((width * scale).rounded())
            pageTask = Task { [weak self] in
                let result = await CapturePage.take(web, rect: rect, pixelWidth: pixelWidth, zoom: z) { [weak self, weak tab] in
                    self?.turn == turn && self?.stage == .picking && tab?.builtPage === web && tab?.address == url
                }
                guard let self else { return }
                self.pageTask = nil
                guard self.turn == turn else { return }
                self.early = result?.secrets
                taken(result?.image)
            }
        }
        // The shutter as the picture is asked for, after the asking.
        CaptureSound.play()
    }
    /// Which take this is, so a late answer from the last one is let go.
    private var turn = 0
    private var pageTask: Task<Void, Never>?
    private var landed = 0
    /// Boxes to hide that came before the picture did.
    private var early: [CGRect]?
    /// What the clipboard waits for: the edge color and the boxes to hide.
    private var parts = 0

    private func hide(_ found: [CGRect]) {
        guard shot != nil, parts > 0, !hidden else { return }
        hidden = true
        shot?.secrets = found
        model.secrets = found.count
        if let shot { view?.blocks(found, in: shot.size, hidden: !model.style.hidePrivate) }
        part()
    }
    private var hidden = false

    private func part() {
        parts -= 1
        if parts == 0 { copy() }
    }

    private func failed() {
        close(quick: true)
        browser?.toaster.pop("Couldn’t take this page", mark: "exclamationmark.triangle")
    }

    // MARK: the corner

    /// The longest side of the picture the layers show: the editor's
    /// canvas at 2x, no more.
    nonisolated static let previewSide = 1800

    private func land(_ shot: Shot, preview: CGImage) {
        guard let view else { return }
        self.shot = shot
        stage = .plate
        composed = nil
        clip = nil
        model.name = shot.name
        model.host = shot.host
        model.secrets = shot.secrets.count
        model.size = shot.size
        model.tint = shot.tint
        let layout = CaptureLayout(shot.size, model.style)
        model.pixels = CGSize(width: (layout.canvas.width * shot.scale).rounded(), height: (layout.canvas.height * shot.scale).rounded())
        let t0 = CACurrentMediaTime()
        landed = turn
        parts = 1
        hidden = false
        view.land(shot, preview: preview, style: model.style)
        view.backdrop(model.style, tint: shot.tint, wallpaper: wallpaperImage)
        if let early { self.early = nil; hide(early) }
        // A page too busy to answer is not waited on for long.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, turn] in
            guard let self, self.landed == turn else { return }
            self.hide([])
        }
        metrics["flight_start_ms"] = (CACurrentMediaTime() - t0) * 1000
        metrics["ready_ms"] = (CACurrentMediaTime() - started) * 1000
        metrics["pixels_w"] = Double(shot.image.width)
        metrics["pixels_h"] = Double(shot.image.height)
        if model.style.backdrop == .wallpaper { loadWallpaper() }
        linger()
    }

    /// The finished picture onto the clipboard once it is made, away from
    /// the main thread. Not a promise of it: a clipboard history (Raycast's,
    /// Universal Clipboard) reads a new clipboard at once, and a promise
    /// made the main thread wait out the PNG for it, 40 to 300 ms a time.
    /// Something copied meanwhile wins; so does a newer look of this one.
    /// The clipboard's history is handed the same PNG.
    private func copy() {
        guard let shot else { return }
        let style = model.style
        let colors = CaptureArt.colors(style, tint: shot.tint)
        let wallpaper = wallpaperCG
        making += 1
        let turn = making
        let before = NSPasteboard.general.changeCount
        let url = unkept ? nil : shot.url, title = unkept ? "" : shot.title
        let unkept = unkept
        DispatchQueue.global(qos: .userInitiated).async {
            let c0 = CACurrentMediaTime()
            let image = CaptureArt.compose(shot, style, colors: colors, wallpaper: wallpaper)
            let c1 = CACurrentMediaTime()
            let data = image.flatMap { CaptureArt.png($0, scale: shot.scale, from: url, title: title) }
            let c2 = CACurrentMediaTime()
            let digest = data.map(Clips.digest) ?? ""
            let pixels = CGSize(width: image?.width ?? 0, height: image?.height ?? 0)
            DispatchQueue.main.async { [weak self] in
                guard let self, turn == self.making else { return }
                let board = NSPasteboard.general
                if let data, board.changeCount == before || board.changeCount == self.copied {
                    let t0 = CACurrentMediaTime()
                    board.clearContents()
                    board.setData(data, forType: .png)
                    self.copied = board.changeCount
                    Clips.shared.mark(board.changeCount)
                    self.metrics["clipboard_ms"] = (CACurrentMediaTime() - t0) * 1000
                    if !unkept {
                        self.clip = Clips.shared.took(png: data, digest: digest, pixels: pixels, page: url, pageTitle: title.isEmpty ? nil : title, replacing: self.clip)
                    }
                }
                self.composed = image
                self.metrics["compose_ms"] = (c1 - c0) * 1000
                self.metrics["png_ms"] = (c2 - c1) * 1000
                self.metrics["png_kb"] = Double(data?.count ?? 0) / 1024
            }
        }
    }

    /// Up for a while, and gone unless the pointer is on it or it is being
    /// edited.
    private func linger() {
        hush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.stage == .plate, self.view?.hovering != true else { return }
            self.close()
        }
        hush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    /// ./bench: the corner kept up while it is looked at.
    func hold() { hush?.cancel() }

    func pointer(on: Bool) {
        guard stage == .plate else { return }
        if on { hush?.cancel() } else { linger() }
    }

    // MARK: the editor

    func edit() {
        guard stage == .plate, let shot, let view, let web = tab?.builtPage else { return }
        stage = .editing
        hush?.cancel()
        // The wallpaper's swatch shows the wallpaper before it is picked.
        loadWallpaper()
        // The page behind, blurred by being drawn small and shown large.
        let small = PageShot(width: max(40, web.bounds.width / 6), afterUpdates: false)
        web.snapshot(small) { [weak view] image, _ in
            MainActor.assumeIsolated {
                guard let picture = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let blurred = CaptureArt.blur(picture)
                    DispatchQueue.main.async { view?.cover(blurred) }
                }
            }
        }
        view.edit(shot, style: model.style)
    }

    func back() {
        guard stage == .editing, let shot, let view else { return }
        stage = .plate
        view.back(shot, style: model.style)
        linger()
    }

    private func restyle(_ style: CaptureStyle) {
        guard style != model.style, let shot, let view else { return }
        let old = model.style
        model.style = style
        if !plain { style.save() }
        let layout = CaptureLayout(shot.size, style)
        model.pixels = CGSize(width: (layout.canvas.width * shot.scale).rounded(), height: (layout.canvas.height * shot.scale).rounded())
        if style.backdrop == .wallpaper { loadWallpaper() }
        view.restyle(shot, from: old, to: style, tint: shot.tint, wallpaper: wallpaperImage, editing: stage == .editing)
        recopy?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.copy() }
        recopy = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private var wallpaperImage: CGImage?
    private var wallpaperCG: CGImage? { wallpaperImage }

    private func loadWallpaper() {
        // The window's screen first, then the rest: macOS can name a file
        // for a screen that is long gone (an app that set it was renamed
        // since), and the one it really shows is then another screen's.
        let first = view?.window?.screen ?? NSScreen.main
        let screens = (first.map { [$0] } ?? []) + NSScreen.screens.filter { $0 !== first }
        var urls: [URL] = []
        for screen in screens {
            if let url = NSWorkspace.shared.desktopImageURL(for: screen), !urls.contains(url) { urls.append(url) }
        }
        guard let url = urls.first, url != wallpaperFor else { return }
        wallpaperFor = url
        Task.detached(priority: .userInitiated) {
            var found: CGImage?
            for url in urls {
                found = await Capture.wallpaper(at: url)
                if found != nil { break }
            }
            let image = found
            await MainActor.run { [weak self] in
                guard let self, let image else { return }
                self.wallpaperImage = image
                self.model.wallpaper = NSImage(cgImage: image, size: .zero)
                if self.model.style.backdrop == .wallpaper, self.shot != nil {
                    self.view?.backdrop(self.model.style, tint: self.shot?.tint, wallpaper: image)
                    self.copy()
                }
            }
        }
    }

    /// A wallpaper as a picture: a still, or the first frame of one of the
    /// Mac's own that move (Sequoia Sunrise and the like are films).
    nonisolated static func wallpaper(at url: URL) async -> CGImage? {
        if (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .movie) == true {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1600, height: 1600)
            return try? await generator.image(at: .zero).image
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
    }

    // MARK: saving

    /// Into the downloads folder, and into the downloads button on screen:
    /// the picture flies there, the way a download lands.
    func save() {
        guard let shot, let browser, let view else { return }
        let style = model.style
        let colors = CaptureArt.colors(style, tint: shot.tint)
        let wallpaper = wallpaperCG
        let ready = composed
        let folder = browser.prefs.downloads
        let file = Capture.free(Capture.fileName(shot), in: folder)
        hush?.cancel()
        let hoard = browser.hoard
        let loot = browser.loot
        hoard.lifting()
        stage = .idle
        unwatchKeys()
        let flying = view
        view.fly(to: { hoard.landing }) { [weak self] landed in
            hoard.touched(file.lastPathComponent)
            if !landed { self?.browser?.toaster.pop("Saved to Downloads", mark: "arrow.down.circle") }
            self?.teardown(flying)
        }
        let unkept = unkept
        let page = unkept ? nil : shot.url
        DispatchQueue.global(qos: .userInitiated).async {
            let image = ready ?? CaptureArt.compose(shot, style, colors: colors, wallpaper: wallpaper)
            let data = image.flatMap { CaptureArt.png($0, scale: shot.scale, from: page, title: unkept ? "" : shot.title) }
            let wrote = (try? data?.write(to: file, options: .atomic)) != nil
            if wrote, let page { Browser.writeWhereFrom(file, [page]) }
            DispatchQueue.main.async {
                guard wrote else {
                    browser.toaster.pop("Couldn’t save the picture", mark: "exclamationmark.triangle")
                    return
                }
                guard !unkept else { return }
                loot.add(Keep(name: file.lastPathComponent, from: page?.host() ?? "", path: file.path, date: Date(),
                              page: page, pageTitle: shot.title.isEmpty ? nil : shot.title))
            }
        }
    }

    /// "linework.studio 2026-09-27 at 9.29.12.png", as the Mac names its own.
    static func fileName(_ shot: Shot, at date: Date = Date()) -> String {
        if let file = shot.file { return file }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd 'at' H.mm.ss"
        let head = shot.host.isEmpty ? "Capture" : shot.host
        return "\(head) \(stamp.string(from: date)).png"
    }

    private static func free(_ name: String, in folder: URL) -> URL {
        let stem = (name as NSString).deletingPathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) \(n).png")
            n += 1
        }
        return candidate
    }

    /// The finished picture as a file for a drag, written where it is dropped.
    func promise() -> NSFilePromiseProvider? {
        guard let shot else { return nil }
        let style = model.style
        return CapturePromise.provider(name: Capture.fileName(shot), image: composed, shot: shot, style: style,
                                       colors: CaptureArt.colors(style, tint: shot.tint), wallpaper: wallpaperCG)
    }

    // MARK: going

    func cancel() {
        guard stage == .picking else { return }
        pageTask?.cancel()
        turn += 1
        stage = .idle
        unwatchKeys()
        let going = view
        view?.leave { [weak self] in self?.teardown(going) }
    }

    /// The corner or the editor away: quicker than it came (P3).
    func close(quick: Bool = false) {
        guard stage != .idle else { return }
        pageTask?.cancel()
        turn += 1
        stage = .idle
        hush?.cancel()
        unwatchKeys()
        let going = view
        if quick { teardown(going); return }
        view?.leave { [weak self] in self?.teardown(going) }
    }

    /// A view that has finished going. A new capture may already have its
    /// own view up by then, which stays.
    private func teardown(_ gone: CaptureView?) {
        // A new capture may have started on the same view meanwhile.
        guard stage == .idle || view !== gone else { return }
        gone?.rest()
        guard view === gone else { return }
        model.up = false
        chain = []
        asking = false
        pending = nil
    }

    // MARK: keys

    /// While it is up, Escape, Return, F and the arrows are its, and ⌘S
    /// saves once there is a picture; everything else goes on to the page.
    func take(_ event: NSEvent) -> Bool {
        guard stage != .idle, event.window === view?.window else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch stage {
        case .picking:
            switch event.keyCode {
            case 53 where flags.isEmpty: cancel(); return true
            case 36 where flags.isEmpty, 76 where flags.isEmpty: take(.visible); return true
            case _ where Keymap.shared.matches(event, .captureWhole): take(.whole); return true
            case 126 where flags.isEmpty: step(out: true); return true
            case 125 where flags.isEmpty: step(out: false); return true
            default: return false
            }
        case .plate:
            if event.keyCode == 53, flags.isEmpty { close(); return true }
            if Keymap.shared.matches(event, .captureSave) { save(); return true }
            return false
        case .editing:
            if [53, 36, 76].contains(event.keyCode) && flags.isEmpty { back(); return true }
            if Keymap.shared.matches(event, .captureSave) { save(); return true }
            return false
        case .idle:
            return false
        }
    }

    private func watchKeys() {
        guard monitor == nil else { return }
        // A click anywhere else puts the corner away, as a menu goes.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .scrollWheel]) { [weak self] event in
            guard let self, let view = self.view,
                  event.window === view.window || (event.type == .scrollWheel && event.window == nil) else { return event }
            if event.type == .scrollWheel { return view.swipeToClose(event) ? nil : event }
            let at = view.convert(event.locationInWindow, from: nil)
            if self.stage == .plate, !view.holds(at) { self.close() }
            return event
        }
    }

    private func unwatchKeys() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // MARK: bench

    /// The capture as ./bench sees it.
    var report: [String: Any] {
        var out: [String: Any] = ["stage": stage.rawValue, "metrics": metrics.mapValues { ($0 * 10).rounded() / 10 }]
        if let shot {
            out["name"] = shot.name
            out["size"] = [shot.size.width, shot.size.height]
            out["pixels"] = [shot.image.width, shot.image.height]
            out["secrets"] = shot.secrets.count
        }
        out["style"] = ["backdrop": model.style.backdrop.rawValue, "shape": model.style.shape.rawValue, "hidePrivate": model.style.hidePrivate]
        out["chain"] = chain.map { ["name": $0.name, "w": $0.rect.width, "h": $0.rect.height] }
        if let view { out["layers"] = view.state }
        return out
    }

    /// ./bench: what is under a point of the page, then take it.
    func benchHover(css point: CGPoint, _ done: @escaping () -> Void) {
        guard stage == .picking, let web = tab?.builtPage else { return done() }
        let t0 = CACurrentMediaTime()
        web.runInYab("window.__yabCapture ? window.__yabCapture.at(\(point.x), \(point.y)) : []") { [weak self] answer in
            MainActor.assumeIsolated {
                self?.metrics["hover_ms"] = (CACurrentMediaTime() - t0) * 1000
                self?.chain = (answer as? [Any] ?? []).compactMap(CaptureBox.init)
                self?.level = 0
                self?.outline()
                done()
            }
        }
    }

    func benchStyle(_ change: (inout CaptureStyle) -> Void) {
        var style = model.style
        change(&style)
        restyle(style)
    }
}

/// Writes a dragged capture where it is dropped.
final class CapturePromise: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    static let shared = CapturePromise()
    /// The provider keeps its own snapshot until the receiver asks for it.
    /// Another drag must not replace the first one's pixels or provenance.
    private struct Payload {
        let name: String
        let image: CGImage?
        let shot: Shot
        let style: CaptureStyle
        let colors: [CGColor]
        let wallpaper: CGImage?
    }

    @MainActor
    static func provider(name: String, image: CGImage?, shot: Shot, style: CaptureStyle,
                         colors: [CGColor], wallpaper: CGImage?) -> NSFilePromiseProvider {
        let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: shared)
        provider.userInfo = Payload(name: name, image: image, shot: shot, style: style, colors: colors, wallpaper: wallpaper)
        return provider
    }
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider.userInfo as? Payload)?.name ?? "Capture.png"
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let p = provider.userInfo as? Payload,
              let image = p.image ?? CaptureArt.compose(p.shot, p.style, colors: p.colors, wallpaper: p.wallpaper),
              let data = CaptureArt.png(image, scale: p.shot.scale, from: p.shot.url, title: p.shot.title)
        else { completionHandler(CocoaError(.fileWriteUnknown)); return }
        do {
            try data.write(to: url, options: .atomic)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
}
