import SwiftUI
import UIKit

/// One of the prototype's icons, drawn on its 24-point grid at `size`, its
/// strokes growing with it as the SVG's do. Template images: the color is
/// the view's foreground style.
struct Glyph: View {
    let name: GlyphName?
    /// The Mac's drawing instead of the prototype's (MacGlyph): menus wear
    /// the same mark as the same action on the Mac.
    var mac: MacGlyph? = nil
    var size: CGFloat = 20
    var color: Color? = nil

    init(_ name: GlyphName, size: CGFloat = 20, color: Color? = nil) {
        self.name = name
        self.size = size
        self.color = color
    }

    init(mac: MacGlyph, size: CGFloat = 20, color: Color? = nil) {
        self.name = nil
        self.mac = mac
        self.size = size
        self.color = color
    }

    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .medium))
            } else {
                Image(mac?.rawValue ?? name?.asset ?? "")
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(color ?? Ink.primary)
        .accessibilityHidden(true)
    }

    private var symbol: String? {
        switch name {
        case .none: nil
        case .crossSmall, .crossMedium, .crossLarge: "xmark"
        default: nil
        }
    }
}

extension GlyphName {
    /// The drawing it takes: the prototype's, except Settings, whose wheel
    /// is the one picked for it (MacGlyphs' SettingsWheel).
    var asset: String { self == .settingsGear1 ? "SettingsWheel" : rawValue }
}

/// The prototype's colors, by what they are for.
enum Ink {
    /// Words and glyphs on light glass: #1c1c1e.
    static let primary = AppearanceColors.color(0x1C1C1E, 0xF2F2F7)
    /// rgba(60, 60, 67, .72): a line's second line.
    static let secondary = AppearanceColors.gray(0.72)
    /// rgba(60, 60, 67, .6): tails, the port, "+1".
    static let tertiary = AppearanceColors.gray(0.6)
    /// rgba(60, 60, 67, .5): placeholders, faint marks.
    static let faint = AppearanceColors.gray(0.5)
    /// A row's folder and Mac glyphs: #3a3a3c.
    static let rowGlyph = AppearanceColors.color(0x3A3A3C, 0xEBEBF5)
    /// Needs you: the Now line's words (#A44B05) and its action (#FF9F0A).
    static let warn = AppearanceColors.color(0xA44B05, 0xFFC078)
    static let warnFill = Color(red: 1, green: 0x9F / 255, blue: 0x0A / 255)
    /// Done and not opened yet.
    static let done = AppearanceColors.color(0x1E6B3A, 0x79D99B)
    /// iOS's system red for Close, blue for Unread, gray for Archive.
    static let close = Color(red: 1, green: 0x3B / 255, blue: 0x30 / 255)
    static let unread = Color(red: 0x0A / 255, green: 0x84 / 255, blue: 1)
    static let archive = Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255)
    /// New answers use the iPhone's primary text color in both appearances.
    static let newAnswer = Color(uiColor: .label)
    static let onNewAnswer = Color(uiColor: .systemBackground)
    /// Text on a dark plate.
    static let onDark = Color.white
    /// A private tab's glass: rgba(44, 42, 52, .78).
    static let privateGlass = Color(red: 44 / 255, green: 42 / 255, blue: 52 / 255)
    /// The Mac's thrown file on iPad: near black with a teal glow.
    static let downloadDiscFill = Color(red: 13 / 255, green: 26 / 255, blue: 20 / 255)
    static let downloadDiscGlow = Color(red: 90 / 255, green: 190 / 255, blue: 170 / 255)
    /// The iPad's chrome, as the Mac's: a control's ground, the tab in front,
    /// a pin at rest, a press, a dimmed mark, the band and its line.
    static let tabletWash = primary.opacity(0.055)
    static let tabletSelected = primary.opacity(0.09)
    static let tabletPinRest = primary.opacity(0.04)
    static let tabletPressed = primary.opacity(0.1)
    static let tabletDisabled = secondary.opacity(0.5)
    static let tabletBand = Ink.surface.opacity(0.92)
    static let tabletRule = primary.opacity(0.08)
    /// A split's chip; the row in front (a tab's, the split's); a pin in
    /// front and at rest; the space in front in the foot; Clear's line.
    static let tabletPairChip = primary.opacity(0.07)
    static let tabletRowFront = Ink.surface.opacity(0.85)
    static let tabletPinFront = Ink.surface.opacity(0.95)
    static let tabletPinGround = Ink.surface.opacity(0.5)
    static let tabletSpaceFront = Ink.surface.opacity(0.8)
    static let tabletClearRule = primary.opacity(0.12)
    /// The focused pane's rim in an iPad split.
    static let splitFocus = Color(red: 86 / 255, green: 125 / 255, blue: 168 / 255)
}

extension Color {
    /// A color the prototype writes as rgb(r, g, b) out of 255.
    init(rgb: RGB, opacity: Double = 1) {
        self.init(red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255, opacity: opacity)
    }
}

extension UIImage {
    /// The side of a glyph's 24 grid in a native menu. Menus draw SF Symbols
    /// at the body style (17 pt at the default text size, measured on iOS 26
    /// beside WebKit's own link menu, 2026-10-16): square.on.square inks
    /// 17.7 pt there, Copy's two squares ink 20 of the grid's 24, so the grid
    /// is 1.25 of the body size (21.25 pt), and grows with it as the menu's
    /// words do. (It was 18: every glyph a sixth smaller than the symbols
    /// beside it.)
    static var menuGlyphSide: CGFloat { (UIFont.preferredFont(forTextStyle: .body).pointSize * 1.25).rounded(.toNearestOrAwayFromZero) }

    /// A drawing for a native menu, as large as an SF Symbol stands there and
    /// centered where a symbol is: on the middle of the words' capitals.
    static func menuGlyph(_ mac: MacGlyph) -> UIImage? { menuGlyph(mac.rawValue) }

    static func menuGlyph(_ name: String) -> UIImage? {
        let side = menuGlyphSide
        let key = "\(name)@\(side)" as NSString
        if let kept = menuGlyphs.object(forKey: key) { return kept }
        guard let drawing = UIImage(named: name) else { return nil }
        let image = menuPicture(side: side) { box in drawing.draw(in: box) }.withRenderingMode(.alwaysTemplate)
        menuGlyphs.setObject(image, forKey: key)
        return image
    }

    /// Menu glyphs already drawn, by name and side. A menu is made again
    /// whenever the tabs it offers change, and each glyph used to be rendered
    /// afresh on the main thread inside SwiftUI's update (crash 405, 0.1.21:
    /// the app was stopped there while an update loop was rebuilding the
    /// plus menu). Drawn once per name and text size, it costs a lookup.
    private static let menuGlyphs = NSCache<NSString, UIImage>()

    /// A site's icon in a native menu: the glyphs' inked part (20 of 24),
    /// rounded like a favicon, centered as they are.
    static func menuIcon(_ icon: UIImage, radius: CGFloat) -> UIImage {
        let side = menuGlyphSide
        let inset = (side * 2 / 24).rounded()
        return menuPicture(side: side) { box in
            let face = box.insetBy(dx: inset, dy: inset)
            UIBezierPath(roundedRect: face, cornerRadius: face.width * radius).addClip()
            icon.draw(in: face)
        }.withRenderingMode(.alwaysOriginal)
    }

    private static func menuPicture(side: CGFloat, draw: (CGRect) -> Void) -> UIImage {
        // A zero or non-finite side has no drawing to make; an empty image
        // keeps the menu whole instead of asking the renderer for nothing.
        let side = side.isFinite && side > 0 ? side : 1
        let box = CGRect(x: 0, y: 0, width: side, height: side)
        let image = UIGraphicsImageRenderer(size: box.size).image { _ in draw(box) }
        // Its middle on the capitals' middle, as a symbol's is (a symbol at
        // the body size stands 6 pt over the baseline at its center).
        let capitals = UIFont.preferredFont(forTextStyle: .body).capHeight
        return image.withBaselineOffset(fromBottom: side / 2 - capitals / 2)
    }
}
