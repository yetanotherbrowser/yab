import SwiftUI
import YabDesign

extension EnvironmentValues {
    /// Pins' squares as panes of Liquid Glass (#176): on macOS 26, whose own
    /// controls are made of it, unless the person asked for less
    /// transparency or more contrast. Elsewhere the flat squares as before.
    var panes: Bool { WindowGlassPolicy.supported && !accessibilityReduceTransparency && colorSchemeContrast != .increased }
}

/// A pin's square's ground. Where the column has panes, the system's clear
/// glass tinted with the square's own fill (a little less of it than the
/// flat square wears: the glass lightens it), light along the top edge and
/// fading down it, a sheen over the top half, and a shadow just under it.
/// The open one: the selection's fill and sheen, as the flat selection has
/// (SelectionPlate), and a heavier, brighter edge. Elsewhere, or with Glass
/// pins turned off, the flat square, the selection for the open one.
struct PinGround: View {
    let corner: CGFloat
    let live: Bool
    let picked: Bool
    let hovering: Bool
    /// Settings › Appearance › Glass pins.
    let glass: Bool
    let prefs: Preferences
    @Environment(\.panes) private var panes
    @Environment(\.tone) private var tone
    @Environment(\.colorScheme) private var scheme

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: corner, style: .continuous) }

    var body: some View {
        if #available(macOS 26.0, *), panes, glass {
            pane
        } else if live || picked {
            // A picked pin gets the open one's ground, as a picked row
            // gets the open row's, and both wear the open tab's selection.
            SelectionPlate(corner: corner, state: .selected, prefs: prefs)
        } else {
            shape.fill(Palette.pin(on: tone, dark: scheme == .dark, hovering: hovering))
        }
    }

    @available(macOS 26.0, *)
    private var pane: some View {
        let dark = scheme == .dark
        let lit = live || picked
        let fill = lit ? Palette.selection(on: tone, dark: dark)
            : dark ? Color.white.opacity(hovering ? 0.11 : 0.07) : Palette.ink.opacity(hovering ? 0.07 : 0.045)
        let edge = LinearGradient(colors: dark ? [.white.opacity(lit ? 0.45 : 0.16), .white.opacity(lit ? 0.2 : 0.05)]
                                               : [.white.opacity(0.95), .white.opacity(0.45)],
                                  startPoint: .top, endPoint: .bottom)
        let sheen = LinearGradient(colors: [.white.opacity(dark ? 0.05 : 0.22), .clear], startPoint: .top, endPoint: .center)
        return Color.clear
            .glassEffect(.clear.tint(fill), in: shape)
            .overlay { if lit { shape.fill(Palette.selectionSheen).allowsHitTesting(false) } }
            .overlay { shape.fill(sheen).allowsHitTesting(false) }
            .overlay { shape.strokeBorder(edge, lineWidth: live ? 1.5 : 1).allowsHitTesting(false) }
            .cast(dark ? Shadow.paneDark : Shadow.pane)
    }
}
