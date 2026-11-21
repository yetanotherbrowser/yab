import SwiftUI
import UIKit

/// The page menu (the review page's SCENE 6 and 9): ≡ on
/// the plate and the plate itself rises to be the menu's address row while
/// an opaque sheet grows out of it. The same ↻ stays where it is, the
/// plate grows around it; ≡ and "Reader Available" fade, ‹ › and the link
/// come; Back and + step aside. Under the row four tiles (Ask once a Mac has
/// joined, Find on Page, Keep, Share), a grouped list (Reader, Page Zoom,
/// Request Desktop Site, Open on Mac and Give a Task once a Mac has joined)
/// and Site Settings on its own. A swipe down or a tap beside puts the row
/// back into the plate the way it came.
///
/// Site Settings (SCENE 14) is the same sheet: the row shrinks into the
/// header "‹ linear.app", the bodies overlap 8 apart, the height follows one
/// spring. Everything here is laid out in screen points from the
/// prototype's numbers, one function of the motion's progress.
struct PageMenuLayer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let size: CGSize

    var body: some View {
        if let tab = app.browser.tab {
            let menu = app.pageMenu
            let reduced = reduceMotion || FieldMotion.reduced
            PageMenuMorph(tab: tab, size: size,
                          progress: menu.shown ? 1 : 0, drag: menu.drag,
                          site: menu.page == .menu ? 0 : 1, certificate: menu.page == .certificate ? 1 : 0,
                          downloads: menu.page == .downloads ? 1 : 0, deep: menu.downloadsHost != nil,
                          toField: menu.toField,
                          drop: reduced,
                          // A dark page's menu is dark too, whatever the phone's theme.
                          dark: app.pageIsPrivate || app.pageIsDark || colorScheme == .dark)
                .onAppear {
                    guard !menu.shown else { return }
                    // A turn later: the frame that makes the sheet and its
                    // bodies is drawn standing exactly on the plate, so the
                    // spring starts on the next one rather than a slow first
                    // frame eating its start (the open's stutter).
                    DispatchQueue.main.async {
                        guard app.surfaces.menu == .plate, !menu.shown else { return }
                        let open = menu.page == .downloads ? Motion.downloadsFromNow : Motion.pageMenuOpen
                        (reduced ? Motion.crossFade : open).run { menu.shown = true }
                    }
                }
                .confirmationDialog("Clear data for \(app.siteHost(of: tab))?", isPresented: Binding(
                    get: { menu.confirmClear }, set: { menu.confirmClear = $0 }), titleVisibility: .visible) {
                    Button("Clear Data", role: .destructive) { app.clearSiteData() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Cookies go too, so it signs you out.")
                }
        }
    }
}

/// The sheet's colors, in light and dark (Private is dark). The sheet is
/// Liquid Glass (the plate's own, grown); what stands on it is see-through.
struct PageMenuInk: Equatable {
    let dark: Bool
    /// What the sheet stands for where a solid color is needed (a kept tile's glyph).
    var sheet: Color { dark ? Self.hex(0x1C1C1E) : Self.hex(0xF4F4F6) }
    /// The sheet's glass: the plate's light glass, or a private tab's dark one.
    var glass: Glass { dark ? GlassTone.privateTab.glass(for: .dark) : GlassTone.light.glass(for: .light) }

    /// The sheet's glass `p` of the way out of the plate. At the plate it is
    /// the plate's own (SharedBottomToolbar's PlateGlass: the system's glass,
    /// untinted, or a private tab's), so the row lands as the plate it
    /// becomes; the sheet's tint comes in as it grows.
    func glass(_ p: CGFloat, privatePage: Bool) -> Glass {
        if privatePage { return GlassTone.privateTab.glass(for: .dark) }
        let t = Double(PageMenuMorph.clamp(p))
        return .regular.tint(dark ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.55 * t)
                                  : Color.white.opacity(0.58 * t))
    }
    var card: Color { dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06) }
    /// Site Settings' cards, lighter than the glass.
    var siteCard: Color { dark ? Color.white.opacity(0.08) : Color.white.opacity(0.62) }
    var ink: Color { dark ? Self.hex(0xF2F2F5) : Self.hex(0x111111) }
    var secondary: Color { dark ? Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255, opacity: 0.6) : Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255, opacity: 0.62) }
    var gray: Color { dark ? Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255, opacity: 0.25) : Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255, opacity: 0.28) }
    var stepper: Color { dark ? Color.white.opacity(0.12) : Color.black.opacity(0.07) }
    var hairline: Color { dark ? Color.white.opacity(0.1) : Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255, opacity: 0.18) }
    var done: Color { Self.hex(0x1F8F4E) }
    var warn: Color { dark ? Self.hex(0xFF8A65) : Self.hex(0xC2410C) }
    var red: Color { dark ? Self.hex(0xFF453A) : Self.hex(0xD70015) }
    /// The address row: nothing where it starts (the plate is bare glass),
    /// the cards' see-through fill once the sheet is open.
    var plateRGBA: (Double, Double, Double, Double) { (1, 1, 1, 0) }
    var cardRGBA: (Double, Double, Double, Double) { dark ? (1, 1, 1, 0.08) : (0, 0, 0, 0.06) }

    func row(_ p: CGFloat) -> Color {
        let a = plateRGBA, b = cardRGBA, t = Double(p)
        return Color(red: a.0 + (b.0 - a.0) * t, green: a.1 + (b.1 - a.1) * t, blue: a.2 + (b.2 - a.2) * t,
                     opacity: a.3 + (b.3 - a.3) * t)
    }

    static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// One frame of the menu: `progress` 0 at the plate, 1 open; `site` 0 the
/// menu's body, 1 Site Settings'; `certificate` 1 the connection's page.
struct PageMenuMorph: View, Animatable {
    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var displayScale
    let tab: Tab
    let size: CGSize
    var progress: CGFloat
    var drag: CGFloat
    var site: CGFloat
    var certificate: CGFloat
    /// 1 the Downloads page: from the menu with `site`, or from Site Settings
    /// one step deeper (`deep`), as the certificate is.
    var downloads: CGFloat
    let deep: Bool
    /// Shrinking into the field: 0 the sheet, 1 the field's frame.
    var toField: CGFloat
    /// Leaving down and away (an action), or Reduce Motion: no morph, the
    /// open sheet fades and sinks.
    let drop: Bool
    let dark: Bool

    @State private var menuHeight: CGFloat = 0
    @State private var siteHeight: CGFloat = 0
    @State private var certificateHeight: CGFloat = 0
    @State private var downloadsHeight: CGFloat = 0
    /// Copy Link's tick, for a second after each copy.
    @State private var linkTicked = false

    var animatableData: AnimatablePair<AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(AnimatablePair(progress, drag), AnimatablePair(site, certificate)), AnimatablePair(toField, downloads)) }
        set {
            progress = newValue.first.first.first; drag = newValue.first.first.second
            site = newValue.first.second.first; certificate = newValue.first.second.second
            toField = newValue.second.first; downloads = newValue.second.second
        }
    }

    /// Downloads straight over the menu or the plate: Site Settings' body has
    /// no part in the move.
    private var direct: Bool { !deep && downloads > 0 }

    private typealias M = Metrics.PageMenu
    private var ink: PageMenuInk { PageMenuInk(dark: dark) }
    static func clamp(_ x: CGFloat, _ a: CGFloat = 0, _ b: CGFloat = 1) -> CGFloat { min(max(x, a), b) }
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    var body: some View {
        let L = layout
        let p = L.p
        let shown = app.pageMenu.shown
        let interactive = shown && progress > 0.98 && toField == 0
        ZStack(alignment: .topLeading) {
            Color.black.opacity(Double(M.scrim * p * L.fade * (1 - toField)))
                .contentShape(Rectangle())
                .onTapGesture { if shown { app.closePageMenu() } }
                .allowsHitTesting(shown)
                .accessibilityIdentifier("plate.menu.scrim")
                .accessibilityLabel("Close Menu")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.escape) { app.closePageMenu() }

            ZStack(alignment: .topLeading) {
                // The sheet: the plate's Liquid Glass, grown out of it.
                Color.clear
                    .frame(width: L.sheet.width, height: L.sheet.height)
                    .glassEffect(ink.glass(L.p, privatePage: app.pageIsPrivate), in: RoundedRectangle(cornerRadius: L.radius, style: .continuous))
                    .offset(x: L.sheet.minX, y: L.sheet.minY)
                    .accessibilityHidden(true)

                bodies(L)
                    // Into the field: the body goes first, a little upward.
                    .opacity(Double(1 - Self.clamp(toField / 0.35)))
                    .offset(y: -20 * Self.clamp(toField / 0.35))
                    .mask(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: L.radius, style: .continuous)
                            .frame(width: L.sheet.width, height: L.sheet.height)
                            .offset(x: L.sheet.minX, y: L.sheet.minY)
                    }

                addressRow(L)
                    .opacity(Double(1 - Self.clamp((toField - 0.65) / 0.35)))
                headerBack(L)
                    .opacity(Double(1 - Self.clamp(toField / 0.25)))
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            // The field, grown out of the same row, takes over at the end.
            .opacity(Double(L.fade * (1 - Self.clamp((toField - 0.75) / 0.25))))
            .offset(y: L.sink)
            .allowsHitTesting(interactive)
            // Over the buttons: a row travels with the finger, and letting go on it would
            // press it. The pages under Site Settings scroll, so there the pull only joins in.
            .highPriorityGesture(dragDown(L), isEnabled: interactive && app.pageMenu.page == .menu)
            .simultaneousGesture(dragDown(L), isEnabled: interactive && app.pageMenu.page != .menu)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("plate.menu")
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { app.closePageMenu() }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, dark ? .dark : .light)
        .task(id: app.pageMenu.copies) {
            guard app.pageMenu.copies > 0 else { return }
            linkTicked = true
            do { try await Task.sleep(for: LinkMark.held) } catch { return }
            linkTicked = false
        }
    }

    // MARK: - geometry

    struct Layout {
        /// Progress after the finger's pull.
        var p: CGFloat
        var sheet: CGRect
        var radius: CGFloat
        var row: CGRect
        var plate: CGRect
        /// Opacity and sinking when it drops away.
        var fade: CGFloat
        var sink: CGFloat
        /// How far the row travels from the plate, for the finger.
        var travel: CGFloat
    }

    /// An unfolded Duo keeps the phone's sheet, on the screen's middle.
    private var sheetWidth: CGFloat {
        let full = size.width - M.edge * 2
        return app.workspace.unfolded ? min(full, Metrics.Workspace.menuWidth) : full
    }
    private var sheetX: CGFloat { (size.width - sheetWidth) / 2 }

    private var layout: Layout {
        let plate = ChromeGeometry(size: size, folded: false, hasNow: app.nowItem != nil).plate
        let width = sheetWidth
        let bottom = size.height - M.edge
        let menuH = M.bodyTop + (menuHeight > 0 ? menuHeight : estimatedMenuHeight)
        let siteH = M.siteBodyTop + (siteHeight > 0 ? siteHeight : 520)
        let certH = M.siteBodyTop + (certificateHeight > 0 ? certificateHeight : 300)
        let filesH = M.siteBodyTop + (downloadsHeight > 0 ? downloadsHeight : 300)
        var h = Self.lerp(menuH, direct ? filesH : Self.lerp(Self.lerp(siteH, certH, certificate), filesH, downloads), site)
        h = min(h, bottom - M.topRoom)
        let top = bottom - h
        let travel = max(1, plate.midY - (top + M.rowTop + M.rowHeight / 2))
        let p = drop ? 1 : Self.clamp(progress - drag / travel)
        let sheet = CGRect(x: Self.lerp(plate.minX, sheetX, p), y: Self.lerp(plate.minY, top, p),
                           width: Self.lerp(plate.width, width, p), height: Self.lerp(plate.height, h, p))
        let rowFull = CGRect(x: sheetX + M.rowInset, y: top + M.rowTop, width: width - M.rowInset * 2, height: M.rowHeight)
        var row = CGRect(x: Self.lerp(plate.minX, rowFull.minX, p), y: Self.lerp(plate.minY, rowFull.minY, p),
                         width: Self.lerp(plate.width, rowFull.width, p), height: Self.lerp(plate.height, rowFull.height, p))
        // Site Settings: the row shrinks into the header's title.
        // The header's title is always whole and always on the sheet's
        // middle, as a navigation bar's: as wide as its words in the
        // semibold weight, with the glass ‹'s room kept on both sides; only
        // a host longer than that room is cut, at its end as on the plate.
        let words = Self.lerp(Self.lerp(Self.titleWidth(PlateLabel.address(tab)), Self.titleWidth("Certificate"), certificate),
                              Self.titleWidth("Downloads"), downloads)
        let side = M.inset + Metrics.touch + M.headerGap
        let header = min(width - side * 2, max(M.headerWidth, words + M.headerPadding))
        let headerX = sheetX + (width - header) / 2
        // On the plate the row is the plate whatever page it opens on.
        let k = site * p
        row.origin.x = Self.lerp(row.minX, headerX, k)
        row.size.width = Self.lerp(row.width, header, k)
        let fade = drop ? progress : 1
        let sink = drop ? (1 - progress) * M.dropSink : 0
        var radius = Self.lerp(plate.height / 2, M.radius, p)
        var sheetNow = sheet
        if toField > 0 {
            // The sheet closes in on its row while both land on the field.
            // Where the address field stands: in the space's card when there is one.
            let field = FieldGeometry(size: size, keyboard: app.field.keyboard,
                                      mode: app.browser.spaces.contains { !$0.isPrivate } ? .newTab : .address,
                                      textScale: app.field.textScale).field
            let t = toField
            func mix(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
                CGRect(x: Self.lerp(a.minX, b.minX, t), y: Self.lerp(a.minY, b.minY, t),
                       width: Self.lerp(a.width, b.width, t), height: Self.lerp(a.height, b.height, t))
            }
            sheetNow = mix(sheet, field, t)
            row = mix(row, field, t)
            radius = Self.lerp(radius, field.height / 2, t)
        }
        return Layout(p: p, sheet: sheetNow, radius: radius, row: row,
                      plate: plate, fade: fade, sink: sink, travel: travel)
    }

    /// The words' width in the header's semibold, with its tracking; kept,
    /// since every frame of the morph asks for the same few words.
    private static var titleWidths: [String: CGFloat] = [:]
    private static func titleWidth(_ words: String) -> CGFloat {
        if let known = titleWidths[words] { return known }
        let font = UIFont.systemFont(ofSize: M.headerFont, weight: .semibold)
        let width = ceil((words as NSString).size(withAttributes: [.font: font, .kern: -0.3]).width)
        if titleWidths.count > 64 { titleWidths.removeAll() }
        titleWidths[words] = width
        return width
    }

    /// The same for the row's regular host, to know when it fades.
    private static var hostWidths: [String: CGFloat] = [:]
    private static func hostWidth(_ words: String) -> CGFloat {
        if let known = hostWidths[words] { return known }
        let font = UIFont.systemFont(ofSize: M.hostFont, weight: .regular)
        let width = ceil((words as NSString).size(withAttributes: [.font: font, .kern: -0.3]).width)
        if hostWidths.count > 64 { hostWidths.removeAll() }
        hostWidths[words] = width
        return width
    }

    private var estimatedMenuHeight: CGFloat {
        M.tilesBlock + CGFloat(listRows.count) * M.listRow + M.groupGap + M.listRow + M.bottomPad
    }

    /// The finger pulls the sheet down; let go far or fast, it goes into the plate.
    private func dragDown(_ L: Layout) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                var quiet = Transaction(animation: nil)
                quiet.disablesAnimations = true
                withTransaction(quiet) { app.pageMenu.drag = max(0, value.translation.height) }
            }
            .onEnded { value in
                let far = value.translation.height > L.travel * 0.3 || value.predictedEndTranslation.height > L.travel * 0.6
                if far, value.translation.height > 0 { app.closePageMenu() }
                else { Motion.pageMenuOpen.run { app.pageMenu.drag = 0 } }
            }
    }

    // MARK: - the address row (the plate, risen)

    private var state: WebPool.PageState { app.currentPageState }

    private func addressRow(_ L: Layout) -> some View {
        let p = L.p
        let row = L.row
        let k = site * p
        let extras = Self.clamp((p - 0.45) / 0.4) * (1 - Self.clamp(k * 2))
        let lines = 1 - Self.clamp(p / 0.3)
        let failed = state.failure != nil
        // The plate's own line under the address (ToolbarPlateControl):
        // Reader's, or Translate's word, Reader on first.
        let translated = app.translation.plateWords(tab.id)
        let hintWords = state.readerEnabled ? "Reader" : translated ?? "Reader Available"
        let hint = !failed && (state.readerAvailable || state.readerEnabled || translated != nil) ? lines : 0
        let subtitle = failed ? Self.clamp((p - 0.3) / 0.5) * (1 - k) : 0
        // Each line takes as much room as it shows, so the address under
        // them moves on one curve: from over the plate's line to the row's
        // middle as the line fades, never a jump when it is gone.
        let under = M.hintLine * hint + M.failureLine * subtitle
        let host = PlateLabel.address(tab)
        let room = max(0, row.width - Self.lerp(Self.lerp(2 * Metrics.touch, 2 * M.hostSide, p), M.headerPadding / 2, k))
        // Too long for the row: its end stays and its start fades, as the
        // plate's. The header's title keeps its cut at the end.
        let fades = k < 0.5 && certificate < 0.5 && downloads < 0.5 && Self.hostWidth(host) > room
        // The title turns from the host to Downloads as the prototype draws it.
        let files = downloads * p
        return ZStack(alignment: .topLeading) {
            Capsule(style: .continuous)
                .fill(ink.row(p))
                .opacity(Double(1 - k))
                .frame(width: row.width, height: row.height)

            // ≡, fading where it was.
            Glyph(.plateLines, size: M.glyph, color: ink.ink)
                .offset(x: M.plateGlyphInset, y: (row.height - M.glyph) / 2)
                .opacity(Double(lines))
                .accessibilityHidden(true)

            rowButton("plate.menu.back", "Back", enabled: state.canGoBack, x: M.backX, row: row, opacity: extras) {
                app.pageMenuBack()
            } label: { color in Glyph(.chevronLeft, size: M.glyph, color: color) }
            rowButton("plate.menu.forward", "Forward", enabled: state.canGoForward, x: M.forwardX, row: row, opacity: extras) {
                app.pageMenuForward()
            } label: { color in Glyph(.chevronRight, size: M.glyph, color: color) }

            // The host: in the plate over its hint, alone in the row, the
            // header's title in Site Settings.
            VStack(spacing: 0) {
                ZStack {
                    Text(host)
                        .opacity(Double((1 - certificate) * (1 - Self.clamp(files / 0.5))))
                    Text("Certificate")
                        .opacity(Double(certificate))
                    Text("Downloads")
                        .opacity(Double(Self.clamp((files - 0.35) / 0.4)))
                }
                // The weight and size turn with the morph (SF is a variable
                // font), so the words don't widen at once halfway into the header.
                .font(Font(UIFont.systemFont(ofSize: Self.lerp(M.hostFont, M.headerFont, k), weight: UIFont.Weight(Self.lerp(UIFont.Weight.regular.rawValue, UIFont.Weight.semibold.rawValue, k)))))
                .kerning(-0.3)
                .foregroundStyle(ink.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: fades, vertical: false)
                .frame(width: room, alignment: fades ? .trailing : .center)
                .clipped()
                .mask(HeadFade(on: fades, width: room))
                ZStack {
                    Text(hintWords)
                        .font(.system(size: Metrics.Chrome.readerHintFont))
                        .foregroundStyle(ink.secondary)
                        .opacity(Double(hint))
                    Text("Can't open this page")
                        .font(.system(size: 12))
                        .foregroundStyle(ink.warn)
                        .opacity(Double(subtitle))
                }
                .frame(height: under)
                .clipped()
            }
            .frame(width: room)
            .frame(height: row.height)
            // The address, in the menu or as Site Settings' title: the field
            // about this page, grown out of this row as the plate grows it.
            .contentShape(Rectangle())
            .onTapGesture { app.pageMenuEditAddress(from: row) }
            .position(x: row.width / 2, y: row.height / 2)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Edit the address")
            .accessibilityIdentifier("plate.menu.host")

            // Copy Link, as the Mac's: the link turns into a tick for a
            // second where it is, and the menu stays.
            rowButton("plate.menu.copy", "Copy Link", value: app.pageMenu.copies > 0 ? "Copied" : nil, enabled: true,
                      x: row.width - M.linkRight - M.linkGlyph, width: M.linkGlyph, row: row, opacity: extras) {
                app.pageMenuCopyLink()
            } label: { color in LinkMark(ticked: linkTicked, size: M.linkGlyph, color: color) }

            reloadButton(L)
        }
        .frame(width: row.width, height: row.height, alignment: .topLeading)
        .offset(x: row.minX, y: row.minY)
    }

    /// The same ↻ the plate has, staying where it is: Stop while loading, the
    /// row's main button when the page didn't open.
    private func reloadButton(_ L: Layout) -> some View {
        let p = L.p, row = L.row
        let failed = state.failure != nil
        let inset = Self.lerp(M.plateGlyphInset, M.reloadRight, p)
        let prominent = failed ? Self.clamp((p - 0.3) / 0.5) : 0
        let x = row.width - inset - M.glyph / 2 - Metrics.touch / 2
        return ZStack(alignment: .topLeading) {
            Button { app.reloadOrStopPage() } label: {
                ZStack {
                    Circle().fill(ink.ink).frame(width: 32, height: 32).opacity(Double(prominent))
                    ReloadMark(stop: state.isLoading, size: M.glyph, stopSize: Metrics.Chrome.stopGlyph,
                               color: prominent > 0.5 ? ink.sheet : ink.ink)
                }
                .frame(width: Metrics.touch, height: row.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(QuarterTurnPress(stop: state.isLoading))
            .offset(x: x)
            .opacity(Double(1 - Self.clamp(site * p * 2)))
            .allowsHitTesting(site == 0)
            .accessibilityHidden(site > 0.5)
            .accessibilityIdentifier("plate.menu.reload")
            .accessibilityLabel(state.isLoading ? "Stop Loading" : "Reload Page")
        }
    }

    private func rowButton<Label: View>(_ id: String, _ name: String, value: String? = nil, enabled: Bool, x: CGFloat, width: CGFloat = M.glyph,
                                        row: CGRect, opacity: CGFloat, action: @escaping () -> Void,
                                        @ViewBuilder label: @escaping (Color) -> Label) -> some View {
        Button(action: action) {
            label(enabled ? ink.ink : ink.gray)
                .frame(width: Metrics.touch, height: row.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .offset(x: x + width / 2 - Metrics.touch / 2)
        .opacity(Double(opacity))
        .allowsHitTesting(opacity > 0.5)
        .accessibilityHidden(opacity < 0.5)
        .accessibilityIdentifier(id)
        .accessibilityLabel(name)
        .accessibilityValue(value ?? "")
    }

    /// Site Settings' ‹ on glass, on the left where the row's ‹ was.
    @ViewBuilder
    private func headerBack(_ L: Layout) -> some View {
        if site > 0 {
            Button { app.siteSettingsBack() } label: {
                Glyph(.chevronLeft, size: M.glyph, color: ink.ink)
                    .frame(width: Metrics.touch, height: Metrics.touch)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .scaleEffect(0.8 + 0.2 * Self.clamp(site * L.p))
            .opacity(Double(min(Self.clamp((site - 0.3) / 0.5), Self.clamp((L.p - 0.5) / 0.4))))
            .offset(x: L.sheet.minX + M.rowInset + (M.rowHeight - Metrics.touch) / 2, y: L.sheet.minY + M.headerBackTop)
            .allowsHitTesting(site > 0.9)
            .accessibilityIdentifier("site.back")
            .accessibilityLabel("Back")
        }
    }

    // MARK: - the bodies

    private func bodies(_ L: Layout) -> some View {
        let p = L.p
        let shown = app.pageMenu.shown
        // Opening: tiles, list, Site Settings in turn after half the path;
        // closing: all of them first.
        let appear: (Int) -> CGFloat = { k in
            if drop { return 1 }
            return shown ? Self.clamp((p - 0.5 - CGFloat(k) * 0.05) / 0.3) : Self.clamp((p - 0.6) / 0.2)
        }
        let top = L.sheet.minY
        let width = sheetWidth
        // Large text: what doesn't fit under the status bar scrolls.
        let room = size.height - M.edge - M.topRoom - M.bodyTop
        let menuFits = menuHeight <= room
        let siteRoom = size.height - M.edge - M.topRoom - M.siteBodyTop
        // A body at rest out of sight stands off the screen, so nothing of
        // it lies under the one in front, for a finger or VoiceOver.
        let away = size.width * 2
        return ZStack(alignment: .topLeading) {
            // The menu's body stays made while the sheet is up; Site
            // Settings' and the certificate's are made a turn before they
            // come in (AppModel.bringIn), so the sheet's height springs to a
            // body already measured, never to a guess corrected halfway.
            ScrollView {
                menuBody(appear: appear)
                    .frame(width: width)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { menuHeight = $0 }
            }
            // A body out of sight takes no finger: a hidden scroll view's
            // pan would still catch the one meant for the body in front.
            .scrollDisabled(menuFits || site > 0)
            .scrollIndicators(menuFits ? .hidden : .automatic)
            .frame(width: width, height: min(menuHeight > 0 ? menuHeight : estimatedMenuHeight, room))
            .offset(x: sheetX + (site == 1 ? away : 0), y: top + M.bodyTop - 8 * site)
                .opacity(Double(1 - site))
                .allowsHitTesting(site == 0)
                .accessibilityHidden(site > 0.5)
            if (app.pageMenu.preparing == .site || site > 0), !direct {
                ScrollView {
                    SiteSettingsBody(tab: tab, ink: ink)
                        .frame(width: width)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { siteHeight = $0 }
                }
                .scrollDisabled(siteHeight <= siteRoom || site < 1 || certificate > 0 || downloads > 0)
                .frame(width: width, height: min(siteHeight > 0 ? siteHeight : 520, siteRoom))
                .offset(x: sheetX + (site == 0 || certificate == 1 || downloads == 1 ? away : 0),
                        y: top + M.siteBodyTop + 8 * (1 - site) - 8 * max(certificate, downloads))
                    .opacity(Double(site * (1 - certificate) * (1 - downloads) * appear(0)))
                    .allowsHitTesting(site == 1 && certificate == 0 && downloads == 0)
                    .accessibilityHidden(site < 0.5 || certificate > 0.5 || downloads > 0.5)
            }
            if app.pageMenu.preparing == .certificate || certificate > 0 {
                CertificateBody(tab: tab, ink: ink)
                    .frame(width: width)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { certificateHeight = $0 }
                    .offset(x: sheetX + (certificate == 0 ? away : 0), y: top + M.siteBodyTop + 8 * (1 - certificate))
                    .opacity(Double(certificate * appear(0)))
                    .allowsHitTesting(certificate == 1)
                    .accessibilityHidden(certificate < 0.5)
            }
            if app.pageMenu.preparing == .downloads || downloads > 0 {
                // Equatable: every frame of the move lays out this one body,
                // made before it started, and never makes it again.
                ScrollView {
                    DownloadsBody(ink: ink, host: app.pageMenu.downloadsHost, isPrivate: isPrivate)
                        .equatable()
                        .frame(width: width)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { downloadsHeight = $0 }
                }
                .scrollDisabled(downloadsHeight <= siteRoom || downloads < 1)
                .frame(width: width, height: min(downloadsHeight > 0 ? downloadsHeight : 300, siteRoom))
                .offset(x: sheetX + (downloads == 0 ? away : 0), y: top + M.siteBodyTop + 8 * (1 - downloads))
                    .opacity(Double(downloads * appear(0)))
                    .allowsHitTesting(downloads == 1)
                    .accessibilityHidden(downloads < 0.5)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func closeThen(_ then: @escaping () -> Void) {
        app.surfaces.closeMenu()
        app.pageMenu.reset()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Motion.disabled ? 0 : 280))
            then()
        }
    }

    enum Tile: String { case ask, find, keep, share }
    enum ListRow: String { case reader, readerLook, translate, alwaysTranslate, zoom, desktop, onMac, task, beside, fullSpread, closePage }

    private var isPrivate: Bool { app.pageIsPrivate }
    /// Ask opens a chat, and chats are the Mac's: no tile before this iPhone has joined one.
    private var tiles: [Tile] {
        if isPrivate { return [.find, .share] }
        return (app.hasMac ? [.ask] : []) + [.find, .keep, .share]
    }
    private var listRows: [ListRow] {
        var rows: [ListRow] = []
        if app.workspace.canSplit, !isPrivate, !tab.isMail {
            rows += [.beside]
            if app.workspace.paired { rows += [.fullSpread, .closePage] }
        }
        rows += [.reader]
        // In Reader, its themes and text a tap away (ReaderCard).
        if state.readerEnabled { rows.append(.readerLook) }
        // Translate when the page is in a language the person doesn't
        // read; Always Translate once it is translated, or always is.
        if let page = app.translation.page(tab.id) {
            rows.append(.translate)
            if page.phase != .offered || app.pageAlwaysTranslates { rows.append(.alwaysTranslate) }
        }
        rows += [.zoom, .desktop]
        // Open on Mac and tasks are the Mac's: no rows before this iPhone has joined one.
        if !isPrivate, app.hasMac { rows += [.onMac, .task] }
        return rows
    }

    private func menuBody(appear: @escaping (Int) -> CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: M.tileGap) {
                ForEach(tiles, id: \.self) { tile in tileView(tile) }
            }
            .padding(.horizontal, M.inset)
            .padding(.bottom, M.tilesBottom)
            .blockAppear(appear(0))

            VStack(spacing: 0) {
                ForEach(Array(listRows.enumerated()), id: \.element) { i, row in
                    // One device pixel: half a point lands on 1 or 2 of them by where the row falls.
                    if i > 0 { Rectangle().fill(ink.hairline).frame(height: 1 / displayScale) }
                    listRow(row)
                }
            }
            .background(ink.card, in: RoundedRectangle(cornerRadius: M.groupRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: M.groupRadius, style: .continuous))
            .padding(.horizontal, M.inset)
            .blockAppear(appear(1))

            VStack(spacing: 0) {
                Button { app.openSiteSettings() } label: {
                    MenuRowLabel(glyph: .sliderHorizontal2Square, title: "Site Settings", ink: ink)
                }
                .buttonStyle(PageMenuPress(ink: ink, radius: M.groupRadius) { app.prepare(.site, $0) })
                .accessibilityIdentifier("plate.menu.siteSettings")
                DownloadsMenuRow(ink: ink, isPrivate: isPrivate)
            }
            .background(ink.card, in: RoundedRectangle(cornerRadius: M.groupRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: M.groupRadius, style: .continuous))
            .padding(.horizontal, M.inset)
            .padding(.top, M.groupGap)
            .padding(.bottom, M.bottomPad)
            .blockAppear(appear(2))
        }
    }

    private func tileView(_ tile: Tile) -> some View {
        let loading = state.isLoading
        let kept = tile == .keep && app.pageIsKept
        let disabled = (tile == .find && loading) || (tile == .keep && tab.place == .pinned)
        let (glyph, title): (MacGlyph, String) = switch tile {
        case .ask: (.yabChatSpark, "Ask")
        case .find: (.yabPageSearch, loading ? "Loading…" : "Find on Page")
        case .keep: (.yabAnchor, kept ? "Kept" : "Keep")
        case .share: (.yabShare, "Share")
        }
        return Button {
            switch tile {
            case .ask: app.pageMenuAsk()
            case .find: app.pageMenuFind()
            case .keep: app.pageMenuKeep()
            case .share: app.pageMenuShare()
            }
        } label: {
            VStack(spacing: M.tileLabelGap) {
                ZStack {
                    RoundedRectangle(cornerRadius: M.tileRadius, style: .continuous)
                        .fill(kept ? ink.ink : ink.card)
                    Glyph(mac: glyph, size: M.tileGlyph, color: kept ? ink.sheet : disabled ? ink.gray : ink.ink)
                }
                .frame(height: M.tileHeight)
                Text(title)
                    .font(.system(size: M.tileFont, weight: .medium))
                    .foregroundStyle(disabled ? ink.gray : ink.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PageMenuPress(ink: ink, radius: M.tileRadius, dims: true))
        .disabled(disabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(kept ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("plate.menu.\(tile.rawValue)")
    }

    @ViewBuilder
    private func listRow(_ row: ListRow) -> some View {
        switch row {
        case .beside, .fullSpread, .closePage:
            let title = row == .beside ? "Split View" : row == .fullSpread ? "Separate Split View" : "Close Split"
            Button {
                closeThen {
                    switch row {
                    case .beside: app.newTabBeside()
                    case .closePage: app.closeWorkspacePage()
                    default: app.workspace.fullSpread()
                    }
                }
            } label: {
                MenuRowLabel(glyph: row == .closePage ? .yabTabX : row == .beside ? .yabSplitPlus : .yabSplitSlash, title: title, ink: ink)
            }
            .buttonStyle(PageMenuPress(ink: ink, radius: 0))
            .accessibilityIdentifier("plate.menu.\(row.rawValue)")
        case .reader:
            let loading = state.isLoading
            let none = !loading && !state.readerAvailable && !state.readerEnabled
            Button { app.pageMenuReader() } label: {
                MenuRowLabel(glyph: .yabBookopen, title: state.readerEnabled ? "Exit Reader" : "Reader",
                             ink: ink, grayed: loading || none)
            }
            .buttonStyle(PageMenuPress(ink: ink, radius: 0))
            .disabled(loading || none)
            .accessibilityIdentifier("plate.menu.reader")
        case .readerLook:
            Button { app.pageMenuReaderLook() } label: {
                MenuRowLabel(glyph: .yabText, title: "Themes & Settings", subtitle: ReaderStyle.shared.prefs.spec.name, ink: ink)
            }
            .buttonStyle(PageMenuPress(ink: ink, radius: 0))
            .accessibilityIdentifier("plate.menu.readerLook")
        case .translate:
            if let page = app.translation.page(tab.id) {
                // Reader shows a copy of the page: translation is the page's own.
                let reader = state.readerEnabled
                Button { app.pageMenuTranslate() } label: {
                    MenuRowLabel(glyph: .yabTranslate, title: page.phase == .offered ? "Translate to \(page.targetName)" : "Show Original",
                                 subtitle: reader ? "Exit Reader to translate" : TranslateWords.subtitle(page), ink: ink, grayed: reader)
                }
                .buttonStyle(PageMenuPress(ink: ink, radius: 0))
                .disabled(reader)
                .accessibilityIdentifier("plate.menu.translate")
            }
        case .alwaysTranslate:
            if let page = app.translation.page(tab.id) {
                let on = app.pageAlwaysTranslates
                Button { app.pageMenuAlwaysTranslate() } label: {
                    MenuRowLabel(glyph: .yabTranslate, title: "Always Translate \(page.sourceName)", ink: ink, check: on)
                }
                .buttonStyle(PageMenuPress(ink: ink, radius: 0))
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("plate.menu.alwaysTranslate")
            }
        case .zoom:
            HStack(spacing: 0) {
                MenuRowLabel(glyph: .yabZoomin, title: "Page Zoom", ink: ink)
                    .accessibilityHidden(true)
                ZoomStepper(zoom: app.pageZoom, ink: ink, idPrefix: "plate.menu.zoom") { app.pageMenuZoom($0) }
                    .padding(.trailing, M.stepperRight)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("plate.menu.zoom")
        case .desktop:
            Button { app.pageMenuDesktop() } label: {
                MenuRowLabel(glyph: app.pageIsDesktop ? .yabIphone : .yabScreen, title: app.pageIsDesktop ? "Request Mobile Site" : "Request Desktop Site", ink: ink)
            }
            .buttonStyle(PageMenuPress(ink: ink, radius: 0))
            .accessibilityIdentifier("plate.menu.desktop")
        case .onMac:
            let opened = app.pageMenu.openedOnMac
            let macs = app.sync.pageMacs
            let mac = app.sync.pageMac
            // Its Mac by name, and its state when it is down (MacWords).
            let subtitle = opened ? nil : mac.flatMap { MacWords.openSubtitle($0.name, $0.state, several: macs.count > 1) }
                ?? (app.browser.macAsleep ? "Opens when your Mac wakes" : nil)
            let label = MenuRowLabel(glyph: .yabLaptopRight, title: opened ? "Opened on \(mac?.name ?? app.macName)" : "Open on Mac",
                                     subtitle: subtitle, ink: ink, check: opened, chevron: !opened && macs.count > 1)
            if macs.count > 1, !opened {
                // Two Macs or more: which one, each with what it is doing.
                Menu {
                    ForEach(macs) { each in
                        Button { app.pageMenuOpenOnMac(each) } label: {
                            Label { Text(each.name); Text(MacWords.state(each.state, now: Date())) } icon: { UIImage.menuGlyph(MacGlyph.yabLaptop).map { Image(uiImage: $0) } ?? Image(systemName: "laptopcomputer") }
                        }
                    }
                } label: { label }
                .buttonStyle(PageMenuPress(ink: ink, radius: 0))
                .accessibilityIdentifier("plate.menu.onMac")
            } else {
                Button { app.pageMenuOpenOnMac() } label: { label }
                    .buttonStyle(PageMenuPress(ink: ink, radius: 0))
                    .disabled(opened)
                    .accessibilityIdentifier("plate.menu.onMac")
            }
        case .task:
            Button { app.pageMenuTask() } label: {
                MenuRowLabel(glyph: .agentFace, title: "Give a Task About This Page", ink: ink)
            }
            .buttonStyle(PageMenuPress(ink: ink, radius: 0))
            .accessibilityIdentifier("plate.menu.task")
        }
    }
}

/// A row of the grouped list: 24 glyph at 16, words at 54, 54 tall; a
/// second line under the words when there is something to say.
struct MenuRowLabel: View {
    let glyph: MacGlyph
    let title: String
    var subtitle: String? = nil
    let ink: PageMenuInk
    var grayed = false
    var check = false
    /// More behind it: a menu of the Macs.
    var chevron = false
    /// A word at the row's end, as Page Zoom's percent: what goes on in it.
    var value: String? = nil
    /// A file's name: one line, its end kept.
    var fileName = false
    private typealias M = Metrics.PageMenu

    var body: some View {
        HStack(spacing: 0) {
            Glyph(mac: glyph, size: M.rowGlyph, color: grayed ? ink.gray : ink.ink)
                .frame(width: M.rowGlyphBox, height: M.rowGlyphBox)
                .padding(.leading, M.rowGlyphX)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: M.rowFont))
                    .foregroundStyle(grayed ? ink.gray : ink.ink)
                    .lineLimit(fileName ? 1 : 2)
                    .truncationMode(fileName ? .middle : .tail)
                    .minimumScaleFactor(fileName ? 1 : 0.85)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: M.subtitleFont))
                        .foregroundStyle(ink.secondary)
                        .lineLimit(fileName ? 1 : 2)
                }
            }
            .padding(.leading, M.rowTextX - M.rowGlyphX - M.rowGlyphBox)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.system(size: M.valueFont))
                    .monospacedDigit()
                    .foregroundStyle(ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.trailing, 16)
            }
            if check {
                Glyph(.checkmark1, size: 21, color: ink.done)
                    .padding(.trailing, 16)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ink.secondary)
                    .padding(.trailing, 16)
            }
        }
        .frame(minHeight: M.listRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// − N % +: a step each, the percent back to 100 %.
struct ZoomStepper: View {
    let zoom: Double
    let ink: PageMenuInk
    let idPrefix: String
    var compact = false
    let change: (Int) -> Void
    private typealias M = Metrics.PageMenu

    var body: some View {
        let percent = SiteSettings.percent(zoom)
        HStack(spacing: 0) {
            Button { change(-1) } label: {
                Text("−").font(.system(size: compact ? 17 : 20, weight: .medium)).foregroundStyle(ink.ink)
                    .frame(width: compact ? 32 : 40, height: compact ? 32 : M.stepperHeight).contentShape(Rectangle())
            }
            .disabled(SiteSettings.step(zoom, by: -1) == nil)
            .accessibilityIdentifier("\(idPrefix).out")
            .accessibilityLabel("Zoom Out")
            Button { change(0) } label: {
                Text("\(percent) %")
                    .font(.system(size: compact ? 15 : 13, weight: compact ? .medium : .semibold))
                    .monospacedDigit()
                    .foregroundStyle(compact || percent == 100 ? ink.secondary : ink.ink)
                    .frame(minWidth: compact ? 52 : 40, minHeight: compact ? 32 : M.stepperHeight)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("\(idPrefix).reset")
            .accessibilityLabel("Page Zoom \(percent) percent")
            .accessibilityHint(percent == 100 ? "" : "Resets to 100 percent")
            Button { change(1) } label: {
                Text("+").font(.system(size: compact ? 17 : 20, weight: .medium)).foregroundStyle(ink.ink)
                    .frame(width: compact ? 32 : 40, height: compact ? 32 : M.stepperHeight).contentShape(Rectangle())
            }
            .disabled(SiteSettings.step(zoom, by: 1) == nil)
            .accessibilityIdentifier("\(idPrefix).in")
            .accessibilityLabel("Zoom In")
        }
        .buttonStyle(.plain)
        .background(compact ? Color.clear : ink.stepper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A touch darkens the row or tile a little, as the list's own cells do.
struct PageMenuPress: ButtonStyle {
    let ink: PageMenuInk
    let radius: CGFloat
    var dims = false
    /// Told when the finger comes down and goes up (a row that makes what
    /// it opens while it is held).
    var pressed: ((Bool) -> Void)? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed && !dims ? ink.ink.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .opacity(configuration.isPressed && dims ? 0.6 : 1)
            .onChange(of: configuration.isPressed) { _, down in pressed?(down) }
    }
}

private extension View {
    /// A block of the body arriving: transparent and 10 lower until its turn.
    func blockAppear(_ a: CGFloat) -> some View {
        opacity(Double(a)).offset(y: (1 - a) * 10)
    }
}

/// Back and + stepping aside while the plate is the menu's row: 14 out,
/// smaller (0.7) and transparent over the first 35 % of the path.
struct PageMenuSide: ViewModifier, Animatable {
    var progress: CGFloat
    let direction: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let side = PageMenuMorph.clamp(progress / 0.35)
        content
            .scaleEffect(1 - 0.3 * side)
            .offset(x: direction * 14 * side)
            .opacity(Double(1 - side))
    }
}

extension Metrics {
    /// The page menu and Site Settings, the review page's numbers (SCENE 6, 9, 14).
    enum PageMenu {
        /// The sheet: 8 from the screen's edges, 38 round.
        static let edge: CGFloat = Edge.sheet
        static let radius: CGFloat = 38
        /// Everything inside the sheet keeps the row's 14 from its sides.
        static let inset: CGFloat = 14
        static let scrim: CGFloat = 0.22
        static let dropSink: CGFloat = 40
        /// Large text: the sheet stops under the status bar with room to tap beside it.
        static let topRoom: CGFloat = Metrics.statusBar + 24
        /// The address row: the plate's 48, concentric with the sheet's 38
        /// corners, so 14 from its top and its sides (38 = 24 + 14).
        static let rowTop: CGFloat = 14
        static let rowInset: CGFloat = 14
        static let rowHeight: CGFloat = 48
        static let glyph: CGFloat = 22
        static let linkGlyph: CGFloat = 21
        /// ≡ and ↻ on the plate: 15 from its edges; ↻ in the row 16.
        static let plateGlyphInset: CGFloat = 15
        static let reloadRight: CGFloat = 16
        static let backX: CGFloat = 12
        static let forwardX: CGFloat = 50
        static let linkRight: CGFloat = 54
        /// The host in the row as the plate's (16), the header's title 17.
        static let hostFont: CGFloat = 16
        static let headerFont: CGFloat = 17
        /// The lines under the address: the plate's Reader line (its 12 pt
        /// words' line, as ToolbarPlateButton lays it) and Can't open.
        static let hintLine: CGFloat = 15
        static let failureLine: CGFloat = 16
        /// The host's room: 14 clear of › (50 + 22) and of the link (54 + 21).
        static let hostSide: CGFloat = max(forwardX + glyph, linkRight + linkGlyph) + 14
        /// Site Settings' header: the title at least 150 wide, ‹ at 12, 23.
        static let headerWidth: CGFloat = 150
        static let headerBackTop: CGFloat = 16
        /// Room around the header's words: 12 each side, 8 from the ‹.
        static let headerPadding: CGFloat = 24
        static let headerGap: CGFloat = 8
        /// Tiles: from 78 (the row's 14 + 48 + 16), 78 tall, 10 apart, the words 8 under.
        static let bodyTop: CGFloat = 78
        static let tileHeight: CGFloat = 78
        static let tileGap: CGFloat = 10
        static let tileRadius: CGFloat = 20
        static let tileGlyph: CGFloat = 24
        static let tileFont: CGFloat = 12.5
        static let tileLabelGap: CGFloat = 8
        static let tilesBottom: CGFloat = 24
        static let tilesBlock: CGFloat = 126
        /// The grouped list: rows 54, the glyph at 16, the words at 54.
        static let listRow: CGFloat = 54
        static let groupRadius: CGFloat = 20
        static let groupGap: CGFloat = 12
        static let bottomPad: CGFloat = 16
        static let rowGlyph: CGFloat = 20
        static let rowGlyphBox: CGFloat = 24
        static let rowGlyphX: CGFloat = 16
        static let rowTextX: CGFloat = 54
        static let rowFont: CGFloat = 17
        static let subtitleFont: CGFloat = 13
        static let valueFont: CGFloat = 14
        static let stepperHeight: CGFloat = 38
        static let stepperRight: CGFloat = 10
        /// Site Settings' body: its first card where the menu's tiles start, 78.
        static let siteBodyTop: CGFloat = 78
    }
}
