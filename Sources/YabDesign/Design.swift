import SwiftUI
import AppKit

// The page *is* the ground, and everything the browser draws has to get out
// of its way.
//
// Every color is a pair, one for a light window, one for a dark, and
// resolves itself against whatever appearance the window has. The window
// takes its appearance from the app, and the app from Settings › Appearance:
// light, dark, or whatever the Mac is doing. Nothing else in the code knows
// which it is.
public enum Palette {
    public static let ground = Color(nsColor: NS.ground)
    public static let ink = Color(nsColor: NS.ink)             // neutral-900 · neutral-100
    public static let muted = Color(nsColor: NS.muted)         // secondary words on glass
    public static let faint = Color(nsColor: NS.faint)         // quieter words, still legible
    public static let hairline = Color(nsColor: NS.hairline)   // neutral-200 · neutral-800
    public static let wash = Color(nsColor: NS.wash)           // the live tab
    public static let hover = Color(nsColor: NS.hover)         // the one under the pointer
    /// What went well, said in words: a mail Sent, a step done. Deep
    /// enough to read as words on the light ground, bright on the dark.
    public static let success = Color(nsColor: NS.success)
    /// The brand's colors, for the welcome, the disk image and the
    /// installer, nothing else. The mark itself is a picture (Logomark).
    static let ivory = Color(nsColor: NSColor(srgbRed: 0xF2 / 255.0, green: 0xF0 / 255.0, blue: 0xEA / 255.0, alpha: 1))
    /// The brand's ink as a ground: the welcome's, the disk image's and the
    /// installer's, warm where a neutral near black reads blue beside ivory.
    public static let inkGround = Color(nsColor: NSColor(srgbRed: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x14 / 255.0, alpha: 1))
    /// The welcome's ground: Apple's light gray, so glass and the parts
    /// (on the ground's white) read lighter than it; in the dark, the
    /// brand's ink, the disk image's own, so arriving from it has no seam.
    public static let stage = Color(nsColor: NS.stage)

    /// The same colors for the AppKit corners of the app, a text field's
    /// ink, a window's background, which want an NSColor and keep it.
    public enum NS {
        public static let ground = pair(1.0, 0.11)
        public static let ink = pair(0.09, 0.93)
        // Glass needs legible secondary words over the page's changing colors.
        public static let muted = pair(0.28, 0.82)
        public static let faint = pair(0.38, 0.74)
        public static let hairline = pair(0.91, 0.20)
        public static let wash = pair(0.937, 0.175)
        public static let hover = pair(0.965, 0.15)
        /// #1D8A3A · #30D158.
        public static let success = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0, alpha: 1)
                : NSColor(srgbRed: 0x1D / 255.0, green: 0x8A / 255.0, blue: 0x3A / 255.0, alpha: 1)
        }
        /// #F5F5F7 · #141414 (inkGround).
        public static let stage = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x14 / 255.0, alpha: 1)
                : NSColor(srgbRed: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF7 / 255.0, alpha: 1)
        }

        private static func pair(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
            NSColor(name: nil) { appearance in
                let dim = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(white: dim ? dark : light, alpha: 1)
            }
        }
    }
}

/// The strip, dressed in the color of the page under it.
///
/// The strip takes the page's color as its ground, and the light or dark
/// that goes with that color as its own, so every pair in the palette
/// resolves the way it would on a window of that brightness. The two grays
/// that are a ground of their own, wash and hover, would be a gray slab on
/// a colored strip; on one they are the ink, faintly, instead.
public struct Tone: Equatable {
    public let color: Color
    /// The same color, to work shades of it out from (Palette.shades).
    public let page: NSColor
    public let scheme: ColorScheme
    /// A backdrop rather than a page: the live tab is a chip lifted off the
    /// color, the way a card sits on a table, not the ink pressed into it.
    var lifted = false
    /// On a look worn as glass (WindowGlassPolicy): the words are the
    /// glass's own whites or near blacks, whatever the tint, and no site's
    /// color dresses the window (Worn).
    public var glass = false
    /// So near white that nothing lighter would show on it.
    public var blank = false
    /// Worn by a see-through card over the page, the column brought out:
    /// its words are the color's deep shades (Shades.deep), which the
    /// card's veil is worked out to keep (BackdropVeil.cardVeil).
    public var seeThrough = false
    /// The column's words on a site's color, a gray standing in for the
    /// site's own (Tone.columnInk): what is painted in the ground's color
    /// takes the site's from elsewhere (GroundFill).
    public var ink = false

    public init(_ page: NSColor, lifted: Bool = false, glass: Bool = false) {
        self.lifted = lifted
        self.glass = glass
        self.page = page.usingColorSpace(.sRGB) ?? page
        color = Color(nsColor: page)
        let rgb = page.usingColorSpace(.sRGB) ?? page
        // Perceived brightness, not the average of the three: a saturated
        // blue is darker than its numbers say, a yellow lighter.
        let light = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        scheme = light < 0.6 ? .dark : .light
        blank = light > 0.94
    }

    /// The same, for the AppKit fields in the strip, which resolve their
    /// colors against an appearance rather than SwiftUI's color scheme.
    public var appearance: NSAppearance? {
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    }
}

private struct ToneKey: EnvironmentKey {
    static let defaultValue: Tone? = nil
}

extension EnvironmentValues {
    /// Set on the strip while it wears a page's color; nil everywhere else.
    public var tone: Tone? {
        get { self[ToneKey.self] }
        set { self[ToneKey.self] = newValue }
    }
}

extension View {
    /// Wear the page's color, or the palette's own ground when there is none.
    public func toned(_ tone: Tone?) -> some View {
        environment(\.tone, tone)
            .transformEnvironment(\.colorScheme) { scheme in
                if let tone { scheme = tone.scheme }
            }
    }
}

extension Palette {
    /// The live tab's ground: the gray, or on a colored strip the ink laid
    /// thinly over that color.
    public static func wash(on tone: Tone?) -> Color {
        guard let tone else { return wash }
        // A chip lifted off white is white on white: pressed in, then.
        // Glass is never that white: the desktop shows through its tint
        // (a white space's glass is about 0.86), so a chip on it is lifted.
        guard tone.lifted, tone.glass || !tone.blank else { return ink.opacity(0.1) }
        return .white.opacity(tone.scheme == .dark ? 0.13 : 0.62)
    }
    /// The grays that are text, on a backdrop: a gray on a color is a
    /// smudge, so the text is the color itself, deeper (or paler on a dark
    /// one), as Arc writes a space's tabs in its own hue.
    /// On glass they are white or black let through, as the system's own
    /// labels on glass are: an opaque gray sat on the tint as a gray, where
    /// these take the space's color from under them. The faintest are let
    /// through on a color too (Shades.faintLift).
    public static func muted(on tone: Tone?) -> Color {
        if let tone, tone.glass { return tone.scheme == .dark ? .white.opacity(0.94) : .black.opacity(0.8) }
        return tone.map { shades($0).muted } ?? muted
    }
    public static func faint(on tone: Tone?) -> Color {
        guard let tone else { return faint }
        if tone.glass { return tone.scheme == .dark ? .white.opacity(0.52) : .black.opacity(0.5) }
        // A see-through card's ground moves with the page under it, which
        // a white let through would follow: its deep shade holds.
        if tone.seeThrough { return shades(tone).faint }
        return (tone.scheme == .dark ? Color.white : .black).opacity(shades(tone).faintLift)
    }
    /// A row that is a way in, not a tab, New tab's: faint on the plain
    /// ground, as Arc's; on a color white or black let through a step
    /// further off it than `faint`, which at its 1.9 to 1 read as a gray
    /// smudge on a deep color (owner, 2026-10-24: "+ New tab is still
    /// gray"). Halfway, in contrast, from the faint words to the muted.
    public static func quiet(on tone: Tone?) -> Color {
        guard let tone else { return faint }
        if tone.glass { return tone.scheme == .dark ? .white.opacity(0.7) : .black.opacity(0.64) }
        if tone.seeThrough { return shades(tone).faint }
        return (tone.scheme == .dark ? Color.white : .black).opacity(shades(tone).quietLift)
    }
    /// Text at its fullest on a backdrop, a folder's name, a tab under the
    /// pointer: the ink, or on a color, the color at its deepest.
    public static func strong(on tone: Tone?) -> Color {
        if let tone, tone.glass { return Color(white: tone.scheme == .dark ? 0.98 : 0.1) }
        return tone.map { shades($0).strong } ?? ink
    }
    /// The one under the pointer, likewise.
    public static func hover(on tone: Tone?) -> Color {
        guard let tone else { return hover }
        guard tone.lifted, tone.glass || !tone.blank else { return ink.opacity(0.06) }
        return .white.opacity(tone.scheme == .dark ? 0.07 : 0.3)
    }
    /// A ground that is there at rest, a pin's and the address plate's: the
    /// open tab's wash, lighter. Under the pointer it comes a step toward
    /// the open tab's, as a row's comes up out of nothing, and as Arc's
    /// favorites and URL bar do (measured 2026-10-13: the same step on both).
    /// `hover` over it changed nothing: it is as light as this ground.
    public static func resting(on tone: Tone?, hovering: Bool) -> Color {
        wash(on: tone).opacity(hovering ? 0.8 : 0.55)
    }
    /// A pin's square at rest, as Arc draws its Favorites (measured on m4
    /// 2026-10-19, evals/pin-active): on a dark column white over it, 0.10
    /// at rest and 0.15 under the pointer; on a light one a touch darker
    /// than the column, the ink at 0.055. The open one wears the selection
    /// (SelectionPlate), as the open tab does.
    public static func pin(on tone: Tone?, dark: Bool, hovering: Bool) -> Color {
        if dark { return .white.opacity(hovering ? 0.15 : 0.1) }
        return ink.opacity(hovering ? 0.08 : 0.055)
    }
    /// The selected row's ground, a tab's, a pin's, a folder aimed at, a
    /// pair on screen (SelectionPlate): the column's lifted wash; on a near
    /// white column still darker than white, a cream, a soft white plate;
    /// and wherever the wash is the ink pressed in (a page's own color
    /// across the top, a white column) that wash, flat (`selectionPressed`).
    public static func selection(on tone: Tone?, dark: Bool) -> Color {
        selectionWhitePlate(on: tone, dark: dark) ? .white.opacity(0.72) : wash(on: tone)
    }
    /// The selection is the ink pressed in, drawn flat as it always was,
    /// with no lift, sheen or frost: where `wash(on:)` is pressed in and no
    /// white plate would show instead, and on the bare strip across the top
    /// of a light window (`strip`, no page color), which is white.
    public static func selectionPressed(on tone: Tone?, dark: Bool, strip: Bool = false) -> Bool {
        guard let tone else { return strip && !dark }
        let washPressed = !(tone.lifted && (tone.glass || !tone.blank))
        return washPressed && !selectionWhitePlate(on: tone, dark: dark)
    }
    /// A near white light column the white plate is still lighter than:
    /// it is lifted there rather than pressed in. Not on a ground as white
    /// as the plate (`selectionWhiteGround`), where it would show only by
    /// its shadow.
    private static func selectionWhitePlate(on tone: Tone?, dark: Bool) -> Bool {
        guard !dark, let tone, tone.lifted, !tone.glass, tone.blank else { return false }
        let c = tone.page
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent < selectionWhiteGround
    }
    /// How light a ground is before the white plate stops showing on it:
    /// the plate (white at 0.72) comes out only about 0.02 lighter there.
    public static let selectionWhiteGround: CGFloat = 0.97
    /// The sheen over a selected row's ground, light and dark alike: in the
    /// dark it is most of what lifts the row off the column (the wash there
    /// is white at 0.13), so it stays, with `pinRim` round it.
    public static let selectionSheen = Color.white.opacity(0.18)
    /// A selected row's edge on a dark column, a line lighter than its
    /// ground, as Arc's open favorite has.
    public static let pinRim = Color.white.opacity(0.1)
}

extension NSColor {
    /// The shade of this color for a dark window, by the rule the swatches'
    /// pairs follow: the same hue, lightness down to about a third, and a
    /// little over half the color, a gray going deeper than a color,
    /// the way gray and paper do. Worked in OKLCH, where lightness is what
    /// the eye sees and the hue holds still while it changes.
    public var deepened: NSColor {
        let (l, c, h) = oklch
        let (deep, less) = NSColor.deep(l, c)
        return NSColor(oklch: (deep, less, h))
    }

    /// The same rule on OKLCH's lightness and chroma, for what draws many
    /// colors at once, the wheel's dots.
    public static func deep(_ l: CGFloat, _ c: CGFloat) -> (CGFloat, CGFloat) {
        let gray = c < 0.02
        return (gray ? min(0.24, max(0.2, l * 0.3)) : min(0.35, max(0.2, l * 0.45)), c * 0.6)
    }

    /// WCAG's contrast between two opaque colors, 1 to 21.
    /// This color laid over another at `alpha`, mixed in sRGB as the
    /// layers composite.
    public func mixed(over under: NSColor, _ alpha: CGFloat) -> NSColor {
        let a = usingColorSpace(.sRGB) ?? self, b = under.usingColorSpace(.sRGB) ?? under
        return NSColor(srgbRed: a.redComponent * alpha + b.redComponent * (1 - alpha),
                       green: a.greenComponent * alpha + b.greenComponent * (1 - alpha),
                       blue: a.blueComponent * alpha + b.blueComponent * (1 - alpha), alpha: 1)
    }

    public func contrast(with other: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            let c = color.usingColorSpace(.sRGB) ?? color
            func linear(_ x: CGFloat) -> CGFloat { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        }
        let a = luminance(self), b = luminance(other)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Lightness, chroma and hue (radians), from sRGB.
    public var oklch: (CGFloat, CGFloat, CGFloat) {
        let c = usingColorSpace(.sRGB) ?? self
        func linear(_ x: CGFloat) -> CGFloat { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let r = linear(c.redComponent), g = linear(c.greenComponent), b = linear(c.blueComponent)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return (L, hypot(a, B), atan2(B, a))
    }

    public convenience init(oklch: (CGFloat, CGFloat, CGFloat)) {
        let (L, C, h) = oklch
        let a = C * cos(h), b = C * sin(h)
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        func gamma(_ x: CGFloat) -> CGFloat {
            let y = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
            return min(1, max(0, y))
        }
        self.init(
            srgbRed: gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            green: gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            blue: gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
            alpha: 1
        )
    }
}

/// A color to and from the six hex digits it is kept as.
extension NSColor {
    public convenience init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat(v >> 16 & 0xFF) / 255,
            green: CGFloat(v >> 8 & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }

    public var hex: String {
        let c = usingColorSpace(.sRGB) ?? self
        func byte(_ x: CGFloat) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}

/// Every corner in the app, on five steps. A thing inside another follows
/// its container's curve, its radius is the container's less the gap
/// between them, so the page and the column, laid 8 in from the window's
/// 18, are 10. Anything that floats free of a container takes `floating`;
/// the rows and doors inside a surface take `control`.
public enum Radius {
    /// The window's own corners, for a surface that reaches them.
    public static let window: CGFloat = 18
    /// The page on a backdrop, and the column floating over the page.
    public static let surface: CGFloat = 10
    /// The address field, the panels, the popovers.
    public static let floating: CGFloat = 14
    /// Tabs, rows, doors, pins, what the hand picks inside a surface.
    public static let control: CGFloat = 8
    /// Key caps and tags.
    public static let small: CGFloat = 5
    /// The field's box, ⌘T and ⌘L: a launcher's window has this curve
    /// (Raycast's), rounder than a window's, since it stands alone.
    public static let box: CGFloat = 26
    /// A card that asks something over a page: a control's 8 plus the
    /// card's inset, so its buttons round off on the card's own curve.
    public static let card: CGFloat = CardFrame.inset + control
}

/// The cards that ask something over a page, a page's question, a password
/// to keep, an agent that needs a hand, laid out one way. Everything sits
/// the same inset from every edge, the corner is that inset plus a
/// control's, and the well in the top corner is a control too.
public enum CardFrame {
    public static let inset: CGFloat = 12
    /// A card of rows lit under the pointer (a chat's links, a folder's
    /// tabs): the rows close to its edge, each with its own padding.
    public static let rows: CGFloat = 6
    public static let well: CGFloat = 40
    /// Between the well and the words beside it.
    public static let wellGap: CGFloat = 12
    /// What it asks, and the line under it that says what comes of it.
    public static let title = Font.system(size: 15, weight: .medium)
    public static let detail = Font.system(size: 13)
    /// A card's answers, and the size of their words, which their keys and
    /// a box beside them take too.
    public static let button = ButtonSize.regular
    public static let words: CGFloat = 12.5
    /// Between the words and the buttons under them: the inset, as at
    /// every edge.
    public static var buttonGap: CGFloat { inset }
    /// A checkbox is smaller than the buttons it shares a line with and is
    /// centered on them, so it sits in by as much as it sits up: level with
    /// the buttons' foot, it would look crowded against the edge.
    static let check: CGFloat = 14
    public static var checkInset: CGFloat { (button.height - check) / 2 }
}

/// A bar of controls floating over a page, the find bar: the controls sit
/// close to its edge, and its corner is that inset plus a control's, which
/// is `floating`. Ground, hairline and shadow are a card's.
public enum BarFrame {
    public static let inset: CGFloat = 6
}

/// The context menu (ActionMenu): the Mac's own menu's row and rhythm,
/// rows touching, laid on yab's scale. The rows stand `pad` in from the
/// plate, so a lit row's `Radius.control` runs on the plate's
/// `Radius.floating`; its mark and words sit `inset` in from the row's
/// sides, as a Settings menu's (DropFace.inset).
public enum MenuMetrics {
    /// A row, as an NSMenu's at 13 pt.
    public static let row: CGFloat = 24
    /// Between rows: none, as the Mac's.
    public static let gap: CGFloat = 0
    /// From the plate to the rows, all round: 14 less 8.
    public static let pad: CGFloat = Radius.floating - Radius.control
    /// From a row's sides to its mark and its keys.
    public static let inset: CGFloat = 8
    /// Between the mark and the words, and the words and what ends the row.
    public static let iconGap: CGFloat = 6
    /// The mark's square: a symbol of 11 beside words of 13.
    public static let mark: CGFloat = 15
    /// A line between groups, with its air: 6 above and 6 below.
    public static let separator: CGFloat = 12
    /// The search: one row with the plate's inset under it.
    public static var search: CGFloat { row + pad }
    /// As narrow as its widest line, never narrower than this nor wider
    /// than `widest`.
    public static let narrowest: CGFloat = 160
    public static let widest: CGFloat = 340
    /// The words', the keys' and an emoji mark's size.
    public static let words: CGFloat = 13
}

/// A list dropping from a box on a page: the accounts under a sign-in, the
/// cards and addresses under a checkout. Its rows are controls lit inside
/// it, so its corner is its inset plus a control's, as a card's is.
public enum DropFrame {
    public static let inset: CGFloat = 4
    public static var corner: CGFloat { inset + Radius.control }

    /// Whether the page is dark where a list hangs from a box: the first
    /// ground painted behind the box, going out from it, read through a
    /// pixel so any color the page writes counts, true or false. With
    /// nothing painted, the document's own: the canvas, dark only when the
    /// page asks for dark and gets it; null in a frame, whose page around
    /// it says instead. A white list on a dark site is a lamp in the room.
    ///
    /// `yabColor` reads a computed color as [r, g, b, a] in 0-255. A
    /// computed rgb() or rgba(), what WebKit gives for every sRGB color, is
    /// read from its words; only another space (color(), lab(), oklch())
    /// goes through a pixel, and a pixel that can't be read is null, never
    /// a throw. The pixel is a round trip to the GPU process, which, busy
    /// or coming back, makes getImageData throw InvalidStateError after
    /// 15 s: every focus in a box and every selection read hung on it and
    /// then said nothing.
    public static let ground = """
    function yabColor(c, doc) {
      if (!c || c === 'transparent') return null;
      var m = /^rgba?\\(\\s*([\\d.]+)[\\s,]+([\\d.]+)[\\s,]+([\\d.]+)(?:\\s*[,\\/]\\s*([\\d.]+)(%?))?\\s*\\)$/.exec(c);
      if (m) {
        var a = m[4] === undefined ? 1 : parseFloat(m[4]) / (m[5] ? 100 : 1);
        return [Math.round(+m[1]), Math.round(+m[2]), Math.round(+m[3]), Math.round(Math.min(1, a) * 255)];
      }
      try {
        var pixel = (doc || document).createElement('canvas');
        pixel.width = pixel.height = 1;
        var paint = pixel.getContext('2d', { willReadFrequently: true });
        paint.fillStyle = c;
        paint.fillRect(0, 0, 1, 1);
        return Array.from(paint.getImageData(0, 0, 1, 1).data);
      } catch (e) { return null; }
    }
    function yabGround(el) {
      function up(n) { return n.parentElement || (n.parentNode && n.parentNode.host) || null; }
      for (var n = el ? up(el) : null; n; n = up(n)) {
        var d = yabColor(getComputedStyle(n).backgroundColor);
        if (!d || d[3] < 128) continue;
        return (0.299 * d[0] + 0.587 * d[1] + 0.114 * d[2]) / 255 < 0.5;
      }
      if (window !== window.top) return null;
      var asked = getComputedStyle(document.documentElement).colorScheme || '';
      return asked.indexOf('dark') >= 0 && matchMedia('(prefers-color-scheme: dark)').matches;
    }
    """
}

extension View {
    /// The card's readable glass, or its solid ground, with the same inset.
    public func cardFrame(glass: Bool = false) -> some View {
        padding(CardFrame.inset).floatingFrame(Radius.card, glass: glass)
    }

    /// A card resting among a chat's turns, not floating over a page (an
    /// agent's published page, ArtifactCard): the card's inset, ground,
    /// hairline and corner, and the low shadow of something laid down,
    /// cast by its shape. Its corner is a control's plus the inset, so rows
    /// lit inside it (a chat's links, 6 in) round on the card's own curve.
    public func restingCardFrame(inset: CGFloat = CardFrame.inset) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control + inset, style: .continuous)
        return padding(inset)
            .background(Palette.ground, in: shape)
            .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
            .castShadow(shape, color: .black.opacity(Double(Shadow.rest.opacity)), radius: Shadow.rest.radius, y: Shadow.rest.y)
    }

    /// Agent messages at the foot of a page share the toast's glass, with
    /// the page palette so their controls keep their usual contrast.
    public func agentCardFrame(surface: Bool = true) -> some View {
        padding(CardFrame.inset)
            .background { if surface { HUD.plate(Radius.card, surface: .page) } }
    }

    /// A card's ground, hairline and shadow round something changing shape,
    /// at the corner it is given and with no inset of its own: a tab's row
    /// growing into the card of the window it is about to be (TearCard).
    public func shapeFrame(_ corner: CGFloat) -> some View {
        floatingFrame(corner, glass: false)
    }

    /// The bar's: the card's frame, closer in and on a tighter curve.
    public func barFrame() -> some View {
        padding(BarFrame.inset).floatingFrame(Radius.floating, glass: true)
    }

    /// A bar standing in a page's corner, as the corner's notice does: its
    /// controls `inset` in, its curve theirs plus that, under the page's.
    public func barFrame(inset: CGFloat, corner: CGFloat) -> some View {
        padding(inset).floatingFrame(corner, glass: true)
    }

    /// The list's: the card's frame, around rows, at the width it is given.
    public func dropFrame(width: CGFloat) -> some View {
        padding(DropFrame.inset).frame(width: width, alignment: .leading).modifier(DropGround())
    }

    /// Light or dark as the page is under the box it hangs from
    /// (`DropFrame.ground`), not as the window is; the window's when the
    /// page didn't say.
    public func pageScheme(dark: Bool?) -> some View {
        environment(\.pageGround, dark != nil)
            .transformEnvironment(\.colorScheme) { scheme in
                if let dark { scheme = dark ? .dark : .light }
            }
    }

    @ViewBuilder
    fileprivate func floatingFrame(_ corner: CGFloat, glass: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        if #available(macOS 26.0, *), glass, LiquidGlass.wanted {
            background {
                ZStack {
                    shape.fill(.regularMaterial)
                    Color.clear.glassEffect(.regular.tint(Palette.ground.opacity(0.55)), in: shape)
                }
            }
        } else {
            background(Palette.ground, in: shape)
            .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(Double(Shadow.card.opacity)), radius: Shadow.card.radius, y: Shadow.card.y)
        }
    }
}

private struct PageGroundKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by `pageScheme` when the page said its ground under the box.
    var pageGround: Bool {
        get { self[PageGroundKey.self] }
        set { self[PageGroundKey.self] = newValue }
    }
}

/// A list's ground: glass, or the card's solid ground when the page said
/// its own. Glass picks light or dark by what it sees under it and ignores
/// the color scheme, and over a page it guessed differently from one
/// opening to the next: a white sign-in page got a dark list every other
/// time (Pinterest, 2026-10-27).
private struct DropGround: ViewModifier {
    @Environment(\.pageGround) private var pageGround

    func body(content: Content) -> some View {
        content.floatingFrame(DropFrame.corner, glass: !pageGround)
    }
}

/// Liquid Glass where there is glass and it is wanted: macOS 26 on, and
/// transparency not reduced. Everything that draws glass asks this.
public enum LiquidGlass {
    public static var wanted: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}

/// The shadows, for the layers that draw a card or a picture themselves
/// (Capture) the way SwiftUI's cards do.
public enum Shadow {
    public struct Cast {
        public let opacity: Float
        public let radius: CGFloat
        public let y: CGFloat
    }

    /// A card's, `.cardFrame()`'s.
    public static let card = Cast(opacity: 0.14, radius: 24, y: 8)
    /// A card laid among a chat's turns, `.restingCardFrame()`'s.
    public static let rest = Cast(opacity: 0.06, radius: 8, y: 2)
    /// A picture lifted off its backdrop: a capture in its frame.
    public static let lift = Cast(opacity: 0.22, radius: 22, y: 9)
    /// A slider's pill, lifted off its track.
    public static let thumb = Cast(opacity: 0.25, radius: 2, y: 1)
    /// A selected row or pin lifted off the column (SelectionPlate):
    /// shallow, a point down. In the dark `Palette.pinRim` carries the
    /// separation, with less black gathered under it.
    public static let selection = Cast(opacity: 0.14, radius: 4, y: 1)
    public static let selectionDark = Cast(opacity: 0.06, radius: 4, y: 1)
    /// A pin's pane of glass standing on the column (PinGround): close, a
    /// point down, the foot a pane casts. Deeper in the dark, where its
    /// edge is all that is light.
    public static let pane = Cast(opacity: 0.1, radius: 2, y: 1)
    public static let paneDark = Cast(opacity: 0.35, radius: 2, y: 1)
    /// The field's card standing off the page, full and compact, as
    /// Raycast's window stands off a white page: a close shadow that
    /// gives it a foot, and a wide, faint one round it, never a dark
    /// drop under it (row 1091; Arc's half-black one read as heavy).
    /// Deeper on a dark box, where a faint one would not show.
    public static let fieldNear = Cast(opacity: 0.06, radius: 3, y: 1)
    public static let fieldFar = Cast(opacity: 0.14, radius: 36, y: 16)
    public static let fieldNearDark = Cast(opacity: 0.30, radius: 3, y: 1)
    public static let fieldFarDark = Cast(opacity: 0.42, radius: 36, y: 16)
    /// Its chosen row, lifted off the glass.
    public static let fieldRow = Cast(opacity: 0.22, radius: 6, y: 3)
}

extension View {
    /// A shadow cast by the shape behind the view, not by every pixel drawn
    /// in it. A shadow on a whole view is worked out by the window server
    /// from its pixels, again on every frame anything in it moves; a shape's
    /// is its outline, worked out once. Everything that casts one here is
    /// opaque inside its shape, so the two look the same.
    public func castShadow<S: Shape>(_ shape: S, color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some View {
        background(shape.fill(Color.black).shadow(color: color, radius: radius, x: x, y: y))
    }
    /// One of the shadows above, cast by what the view draws (a see-through
    /// fill casts a lighter one), or none while `on` is false.
    public func cast(_ shadow: Shadow.Cast, on: Bool = true) -> some View {
        self.shadow(color: .black.opacity(on ? Double(shadow.opacity) : 0), radius: shadow.radius, y: shadow.y)
    }
}

// One spring for anything that moves between two places, one for anything that
// arrives or leaves. Using the same two everywhere is most of why a thing feels
// like a single piece of software rather than a pile of views.
public enum Motion {
    public static let glide = Animation.spring(response: 0.34, dampingFraction: 0.82)
    public static let settle = Animation.spring(response: 0.30, dampingFraction: 0.86)
    public static let quick = Animation.easeOut(duration: 0.14)
    /// A mark turning into another where it stands, under the pointer: a
    /// kept tab's minus opening into its cross as the tab is put down
    /// (MinusCross). Quick, with a little give, the strokes swinging just
    /// past their 45° and back.
    public static let markTurn = Animation.spring(response: 0.3, dampingFraction: 0.7)
    /// The kept boundary and New Tab, fitted to the recorded Arc motion.
    public static let keptShift = Animation.spring(response: 0.12, dampingFraction: 0.9)
    public static let keptFade = Animation.easeOut(duration: 0.045)
    /// A surface coming in from the edge it lives past, whole and already
    /// composed, and going back out: in 0.22 s and settling, out quicker and
    /// gathering speed, the way it would leave. No give on either, the
    /// column comes and goes dozens of times a day, and a bounce on a path
    /// that well worn stops being a pleasure by the second day.
    public static let arrive = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)
    public static let depart = Animation.timingCurve(0.4, 0, 0.8, 0.4, duration: 0.15)
    /// One surface changing size, the floating column taking its place in
    /// the window, or giving it up, and the page making room in the same
    /// beat. Longer than arriving: more of it moves.
    public static let reshape = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3)
    /// The column's edge let go past its widest, going back to it: Dia's,
    /// read off its frames (evals/side-width/rubber.py), within 2% of each.
    public static let stretchBack = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.25)
    /// ⌘S with the tabs across the top, the strip put away and brought
    /// back, the page under it on the same curve (Reshape.Pace.strip):
    /// Dia's own, read off 60 fps films of Dia 1.51's ⌘S with its tabs on
    /// top (evals/strip-shut/dia.py, curve.py): the same both ways, a third
    /// of the way in its first frame and landing soft, all of it in 0.11 s,
    /// within 1.2% of every frame. Quicker than the column's `arrive`,
    /// which is 0.22 s and was 10% off: the strip has a short way to go.
    public static let stripCurve: (Float, Float, Float, Float) = (0, 0.4, 0.45, 1)
    public static let stripTime: TimeInterval = 0.11
    /// What a surface says, replaced in place: the old words out and the
    /// new in over the same beat, never an empty moment between them,
    /// quicker than the surface's own change of size around them.
    public static let morph = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)
    /// The row making room: for a tab that arrives, and, quicker, as every
    /// exit is, for one that goes. Short and without give: this is the
    /// thing done a hundred times a day, and it should never be in the way.
    public static let room = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: roomTime)
    static let roomTime: TimeInterval = 0.2
    public static let leave = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.14)
    /// A chat's column (ChatColumn): what arrives, height and opacity
    /// together, long at the end so it settles rather than stops; and what
    /// answers a hand, the field opening, a button coming with the words.
    public static let chatIn = Animation.timingCurve(0.19, 1, 0.22, 1, duration: 0.3)
    public static let chatQuick = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.15)
}

/// Pulled past where it can go, a thing still moves, just less and less,
/// the further it is pulled the harder it holds. `room` is about how far it
/// could ever get.
public func resisted(_ travel: CGFloat, room: CGFloat) -> CGFloat {
    guard travel > 0 else { return 0 }
    return room * (1 - 1 / (travel * 0.55 / room + 1))
}

/// Wrong address, said without a dialog: the field shivers and stops.
public struct Shake: GeometryEffect {
    public var travel: CGFloat

    public init(travel: CGFloat) { self.travel = travel }

    public var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    public func effectValue(size: CGSize) -> ProjectionTransform {
        // Three there-and-backs, tapering to nothing, so it settles rather than
        // stopping mid-swing.
        let decay = 1 - travel
        return ProjectionTransform(
            CGAffineTransform(translationX: sin(travel * .pi * 6) * 7 * decay, y: 0)
        )
    }
}

// MARK: - shades of a space

/// What is drawn on a color in that color: a folder's line, its body and
/// its back, and the text, each the backdrop's hue at another lightness,
/// worked out in OKLCH, where lightness is what the eye sees and the hue
/// holds still (see NSColor.deepened). A gray backdrop gives grays, so a
/// window with no color of its own looks as it always has.
public struct Shades: Equatable {
    /// A folder's outline, its eyes and its hand.
    public let line: NSColor
    /// The folder's body, and its front once let down.
    public let body: NSColor
    /// Its back: the tab, and the band above the front's seam.
    public let back: NSColor
    /// A folder's name, a tab under the pointer.
    public let strongNS: NSColor
    public let mutedNS: NSColor
    public let faintNS: NSColor
    /// The faintest words as white (black on a light color) let through
    /// rather than a gray of their own, so the color comes up through
    /// them: how much of it, to stand as far off the color as `faint`.
    public let faintLift: CGFloat
    /// The same for a row that is a way in (Palette.quiet): halfway, in
    /// contrast, from `faint` to `muted`.
    public let quietLift: CGFloat

    public var strong: Color { Color(nsColor: strongNS) }
    public var muted: Color { Color(nsColor: mutedNS) }
    public var faint: Color { Color(nsColor: faintNS) }

    /// The contrast the words keep with the color under them: coral's, the
    /// palette's quietest (6.1, 4.2 and 1.9 to 1), so no swatch moves.
    public static let least = (strong: CGFloat(6), muted: CGFloat(4.2), faint: CGFloat(1.9))

    public init(on base: NSColor, dark: Bool) {
        let (l, c, h) = base.oklch
        // A little more of the hue than the backdrop has, never so much
        // that a pale swatch's text turns loud.
        func ink(_ L: CGFloat, _ more: CGFloat) -> NSColor { NSColor(oklch: (L, min(0.13, c * more), h)) }
        // Words at least as far off the color as on the palette's own
        // quietest swatch: on a mid gray the shades meant for a deep or a
        // pale color all but vanish, so they go on toward white or black
        // until they stand off it, as far as that goes.
        func words(_ L: CGFloat, _ more: CGFloat, _ least: CGFloat) -> NSColor {
            var L = L, made = ink(L, more)
            while made.contrast(with: base) < least, dark ? L < 1 : L > 0 {
                L = dark ? min(1, L + 0.02) : max(0, L - 0.02)
                made = ink(L, more)
            }
            return made
        }
        // The back and the front apart as a folder's are, the back in
        // shadow and the front catching the light: on a light color the back
        // deeper than the color and the front near white, on a dark one the
        // back just off the color and the front well above it. Both paled
        // from the color, the back all but vanished into a gray window.
        if dark {
            line = ink(0.86, 0.7)
            body = ink(min(0.66, l + 0.18), 1)
            back = ink(min(0.55, l + 0.05), 1.2)
            strongNS = words(0.94, 0.4, Self.least.strong)
            mutedNS = words(0.8, 0.45, Self.least.muted)
            faintNS = words(0.62, 0.45, Self.least.faint)
        } else {
            line = ink(0.34, 1.1)
            body = ink(min(0.99, l + (1 - l) * 0.7), 0.5)
            back = ink(l - 0.09, 1.3)
            strongNS = words(0.26, 1.1, Self.least.strong)
            mutedNS = words(0.38, 0.95, Self.least.muted)
            faintNS = words(0.56, 0.75, Self.least.faint)
        }
        let rgb = base.usingColorSpace(.sRGB) ?? base
        func lift(to goal: CGFloat) -> CGFloat {
            var lift: CGFloat = 0
            while lift < 1, (dark ? NSColor.white : .black).mixed(over: rgb, lift).contrast(with: rgb) < goal {
                lift += 0.01
            }
            return lift
        }
        let faintGoal = faintNS.contrast(with: rgb)
        faintLift = lift(to: faintGoal)
        quietLift = lift(to: (faintGoal * mutedNS.contrast(with: rgb)).squareRoot())
    }

    private init(line: NSColor, body: NSColor, back: NSColor, strong: NSColor, muted: NSColor, faint: NSColor, faintLift: CGFloat, quietLift: CGFloat) {
        self.line = line; self.body = body; self.back = back
        strongNS = strong; mutedNS = muted; faintNS = faint; self.faintLift = faintLift; self.quietLift = quietLift
    }

    /// The words on a see-through card over the page: the color's hue at
    /// the far end of its lightness, so the card's ground may come further
    /// toward the page under it before they're lost, and the veil that
    /// keeps them (BackdropVeil.cardVeil) is thinner. Worked out from the
    /// color alone, the ground's ends being the veil's to hold. Drawn off
    /// a page of tries (docs/card-ink.md): the
    /// swatch's own shades over a black page took a veil of 0.8 and more,
    /// all but opaque; these, half that.
    public static func deep(on base: NSColor, dark: Bool) -> Shades {
        let usual = Shades(on: base, dark: dark)
        let (_, c, h) = base.oklch
        func ink(_ L: CGFloat, _ more: CGFloat) -> NSColor { NSColor(oklch: (L, min(0.11, c * more), h)) }
        return dark
            ? Shades(line: usual.line, body: usual.body, back: usual.back, strong: ink(0.99, 0.2), muted: ink(0.95, 0.25), faint: ink(0.8, 0.35), faintLift: usual.faintLift, quietLift: usual.quietLift)
            : Shades(line: usual.line, body: usual.body, back: usual.back, strong: ink(0.18, 1), muted: ink(0.26, 1), faint: ink(0.44, 0.8), faintLift: usual.faintLift, quietLift: usual.quietLift)
    }
}

extension Palette {
    /// A backdrop's shades, worked out once per color: a see-through
    /// card's its deep ones.
    public static func shades(_ tone: Tone) -> Shades {
        let key = ShadesCache.Key(tone.page, dark: tone.scheme == .dark, deep: tone.seeThrough)
        if let hit = ShadesCache.kept[key] { return hit }
        let made = tone.seeThrough ? Shades.deep(on: tone.page, dark: tone.scheme == .dark)
            : Shades(on: tone.page, dark: tone.scheme == .dark)
        if ShadesCache.kept.count > 64 { ShadesCache.kept.removeAll() }
        ShadesCache.kept[key] = made
        return made
    }

    /// The shades on the window's own ground, when nothing is worn.
    public static func shades(dark: Bool) -> Shades {
        shades(Tone(NS.ground.resolved(dark: dark)))
    }
}

private enum ShadesCache {
    struct Key: Hashable {
        let r: Int, g: Int, b: Int, dark: Bool, deep: Bool
        init(_ color: NSColor, dark: Bool, deep: Bool = false) {
            let c = color.usingColorSpace(.sRGB) ?? color
            r = Int(c.redComponent * 1023); g = Int(c.greenComponent * 1023); b = Int(c.blueComponent * 1023)
            self.dark = dark
            self.deep = deep
        }
    }
    nonisolated(unsafe) static var kept: [Key: Shades] = [:]
}

extension NSColor {
    /// A pair of the palette's as it is in a light or a dark window.
    func resolved(dark: Bool) -> NSColor {
        var out = self
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            out = self.usingColorSpace(.sRGB) ?? self
        }
        return out
    }
}

extension View {
    /// A hole where a badge sits on the corner, `gap` wider than the badge
    /// all round, so the badge stands clear on any ground, no ring in a
    /// color that is only right on one of them. `offset` is how far the
    /// badge hangs past the corner; the hole follows it.
    public func notched(_ on: Bool, side: CGFloat, radius: CGFloat, offset: CGFloat, gap: CGFloat = 2) -> some View {
        mask {
            // Wider than the view, so what it draws past its edges, a
            // ring round it, isn't cut off by the mask.
            Color.black
                .padding(-16)
                .overlay(alignment: .bottomTrailing) {
                    if on {
                        RoundedRectangle(cornerRadius: radius + gap, style: .continuous)
                            .frame(width: side + gap * 2, height: side + gap * 2)
                            .offset(x: offset + gap, y: offset + gap)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
        }
    }
}
