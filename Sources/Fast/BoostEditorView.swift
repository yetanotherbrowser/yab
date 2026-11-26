import AppKit
import SwiftUI

/// A measurement view only. It must not register as an extensions anchor.
private struct BoostEditorAnchor: NSViewRepresentable {
    let box: ViewBox
    func makeNSView(context: Context) -> NSView {
        let view = Anchor(); box.view = view; return view
    }
    func updateNSView(_ view: NSView, context: Context) { box.view = view }

    // This background fills the window, including while the editor is
    // closed. It measures coordinates only; ordinary NSView hit testing
    // would take every press before the page and browser controls see it.
    private final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// One surface over the real page. Site Controls hands over its old pixels
/// and rectangle; the new surface grows there instead of opening a second popover.
struct BoostEditorLayer: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var editor = BoostEditor.shared
    @State private var box = ViewBox()
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear.allowsHitTesting(false)
                if editor.open, editor.browser === browser, editor.valid {
                    BoostEditorSurface(room: geo.size, root: box)
                        .id(editor.identity)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                        .transition(.asymmetric(
                            insertion: editor.oldCard == nil ? .scale(scale: still ? 1 : 0.2, anchor: anchor(in: geo.size)).combined(with: .opacity) : .identity,
                            removal: .scale(scale: still ? 1 : 0.2, anchor: anchor(in: geo.size)).combined(with: .opacity)))
                    if let choice = editor.choice, let spot = pickSpot(choice, in: geo.size) {
                        BoostEditorPick(choice: choice)
                            .offset(x: spot.x, y: spot.y)
                            .transition(.scale(scale: still ? 1 : 0.9, anchor: .topLeading).combined(with: .opacity))
                    }
                    ForEach(editor.flights) { flight in
                        BoostEditorFlight(flight: flight, root: box)
                            .allowsHitTesting(false)
                    }
                }
            }
            .animation(still ? nil : editor.open ? Motion.arrive : Motion.depart, value: editor.open)
            .animation(still ? nil : Motion.chatQuick, value: editor.choice != nil)
            .background(BoostEditorAnchor(box: box).allowsHitTesting(false).accessibilityHidden(true))
        }
        .onChange(of: browser.activeID) { _, _ in if editor.browser === browser { editor.close() } }
        .onChange(of: browser.spaceID) { _, _ in if editor.browser === browser { editor.close() } }
        .onChange(of: browser.active?.address) { _, _ in if editor.browser === browser && !editor.valid { editor.close() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in if editor.browser === browser { editor.cancelOriginal() } }
        .onDisappear { if editor.browser === browser { editor.close() } }
    }

    /// Where the choice stands: under the thing clicked, in this layer's
    /// own points, kept inside the window.
    private func pickSpot(_ choice: BoostEditor.Choice, in size: CGSize) -> CGPoint? {
        guard let rect = choice.rect, let web = editor.tab?.builtPage, let window = web.window, let view = box.view else { return nil }
        let zoom = web.pageZoom * web.magnification
        var spot = CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
        if !web.isFlipped { spot.origin.y = web.bounds.height - spot.maxY }
        var local = view.convert(window.convertFromScreen(window.convertToScreen(web.convert(spot, to: nil))), from: nil)
        if !view.isFlipped { local.origin.y = size.height - local.maxY }
        return CGPoint(x: min(max(12, local.midX - 98), max(12, size.width - 220 - 12)), y: min(max(12, local.maxY + 8), max(12, size.height - 160)))
    }

    private func anchor(in size: CGSize) -> UnitPoint {
        guard let origin = editor.origin, let view = box.view, let window = view.window else { return .topLeading }
        let at = view.convert(window.convertFromScreen(origin), from: nil)
        return UnitPoint(x: at.midX / max(1, size.width), y: (view.isFlipped ? at.midY : size.height - at.midY) / max(1, size.height))
    }
}

private struct BoostEditorSurface: View {
    let room: CGSize
    let root: ViewBox
    @ObservedObject private var editor = BoostEditor.shared
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var arrived = false
    @State private var contentHeight: CGFloat = 550
    private let width: CGFloat = 290

    var body: some View {
        let maxHeight = max(160, room.height - 24)
        let finalHeight = min(contentHeight, maxHeight)
        let target = targetRect(height: finalHeight)
        let previous = editor.oldFrame.map(local) ?? target
        let morph = editor.oldCard != nil
        let rect = morph && !arrived ? previous : target
        BoostEditorPointer {
            ZStack(alignment: .topLeading) {
                ScrollView {
                    BoostEditorView()
                        .padding(CardFrame.inset)
                        .frame(width: width)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollIndicators(.hidden)
                .frame(width: width, height: finalHeight)
                .opacity(morph && !arrived ? 0 : 1)
                .offset(y: morph && !arrived && !still ? 10 : 0)
                .animation(still ? nil : Motion.morph.delay(0.06), value: arrived)
                if let image = editor.oldCard {
                    Image(nsImage: image).resizable().frame(width: previous.width, height: previous.height)
                        .opacity(arrived ? 0 : 1)
                        .offset(y: arrived && !still ? -8 : 0)
                        .animation(still ? nil : Motion.leave, value: arrived)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .padding(-CardFrame.inset)
            .cardFrame()
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
        .animation(still ? nil : Motion.glide, value: arrived)
        .animation(still ? nil : Motion.reshape, value: contentHeight)
        .onAppear { DispatchQueue.main.async { arrived = true } }
        .onChange(of: room) { _, _ in editor.setOriginal(false) }
    }

    private func local(_ screen: CGRect) -> CGRect {
        guard let view = root.view, let window = view.window else { return screen }
        var rect = view.convert(window.convertFromScreen(screen), from: nil)
        if !view.isFlipped { rect.origin.y = room.height - rect.maxY }
        return rect
    }

    private func targetRect(height: CGFloat) -> CGRect {
        let source = editor.oldFrame ?? editor.placementOrigin
        let origin = source.map(local) ?? CGRect(x: browserSide, y: 32, width: 1, height: 1)
        let x = min(max(12, origin.maxX - width), max(12, room.width - width - 12))
        let y = min(max(12, editor.oldFrame == nil ? origin.maxY + 8 : origin.minY), max(12, room.height - height - 12))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private var browserSide: CGFloat {
        guard let browser = editor.browser else { return 12 }
        return browser.prefs.sidebar ? browser.prefs.sideWidth + width : width + 12
    }
}

private struct BoostEditorFlight: View {
    let flight: BoostEditor.Flight
    let root: ViewBox

    var body: some View {
        let from = local(flight.from), to = local(flight.to)
        let rect = flight.landed ? to : from
        ZStack {
            RoundedRectangle(cornerRadius: Radius.control).fill(Palette.ground) // design: the flying row's paper under its fading page snapshot.
            if let image = flight.image {
                Image(nsImage: image).resizable().scaledToFill()
                    .opacity(flight.returning ? (flight.landed ? 1 : 0) : (flight.landed ? 0 : 1))
            }
            Text(flight.label).sidebarFont(size: 12).foregroundStyle(Palette.ink)
                .lineLimit(1).padding(.horizontal, 8)
                .opacity(flight.returning ? (flight.landed ? 0 : 1) : (flight.landed ? 1 : 0))
        }
        .frame(width: max(1, rect.width), height: max(1, rect.height))
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        .shadow(color: .black.opacity(flight.landed ? 0 : Double(Shadow.thumb.opacity)), radius: flight.landed ? 0 : Shadow.thumb.radius, y: Shadow.thumb.y) // design: a lifted page snapshot uses the design system's thumb shadow.
        .position(x: rect.midX, y: rect.midY)
    }

    private func local(_ screen: CGRect) -> CGRect {
        guard let view = root.view, let window = view.window else { return .zero }
        var rect = view.convert(window.convertFromScreen(screen), from: nil)
        if !view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
        return rect
    }
}

struct BoostEditorView: View {
    @ObservedObject private var editor = BoostEditor.shared
    @ObservedObject private var looks = BoostEditorLooks.shared
    @ObservedObject private var boosts = Boosts.shared
    @Environment(\.accessibilityReduceMotion) private var still
    @Namespace private var selection
    @State private var ask = ""
    @GestureState private var originalPressed = false
    /// Code opening or closing: the Code button's plate is on its way
    /// between the button and the field, the word with it.
    @State private var flying = false
    @State private var flight = UUID()
    @State private var buttonRect = CGRect.zero
    @State private var buttonWord = CGRect.zero
    @State private var fieldRect = CGRect.zero
    @State private var headWord = CGRect.zero
    private static let pane = "BoostEditorPane"
    private let families = ["Site", "System", "Rounded", "Serif", "Avenir", "Futura", "Baskerville", "Mono"]
    private let cases = ["Original", "lowercase", "UPPERCASE"]
    /// Each case drawn in its own letters, as Text Case's "Aa".
    private let caseMarks = ["yab.case", "yab.case.lower", "yab.case.upper"]
    /// The card's controls: its width less the frame's inset each side.
    private let inner = LookCardView.inner

    var body: some View {
        VStack(spacing: 12) {
            // Code turns the panel into a code field in the same card: the
            // controls stay in the layout, so the card keeps its size, and
            // fade; the Code button's plate grows into the field.
            panel
                .opacity(editor.code ? 0 : 1)
                .blur(radius: editor.code && !still ? 4 : 0)
                .animation(still ? Motion.morph : editor.code ? Motion.leave : Motion.morph.delay(0.12), value: editor.code)
                .allowsHitTesting(!editor.code)
                .accessibilityHidden(editor.code)
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        plate
                        code
                            .opacity(editor.code ? 1 : 0)
                            .allowsHitTesting(editor.code)
                            .animation(still ? Motion.morph : editor.code ? Motion.morph.delay(0.16) : Motion.leave, value: editor.code)
                            .disabled(!editor.code)
                            .accessibilityHidden(!editor.code)
                        rider
                    }
                }
                .coordinateSpace(.named(Self.pane))
            HStack {
                // Pointer presses peek while held. Keyboard and accessibility
                // activation can toggle without requiring a held pointer.
                Button { editor.setOriginal(!editor.original) } label: { words("Original", keys: "⌥") }
                    .buttonStyle(.yab(editor.original ? .primary : .secondary, .regular))
                    .highPriorityGesture(DragGesture(minimumDistance: 0).updating($originalPressed) { _, pressed, _ in pressed = true })
                    .onChange(of: originalPressed) { _, pressed in editor.holdOriginal(pressed, input: .pointer) }
                    .keyTip(editor.original ? "Show Customized" : "Show Original", keys: "⌥")
                    .accessibilityValue(editor.original ? "Original" : "Customized")
                    .accessibilityAction { editor.setOriginal(!editor.original) }
                Spacer(minLength: 0)
                Button { editor.close() } label: { words("Done", keys: "esc") }.buttonStyle(.yab(.primary, .regular))
            }
        }
        .animation(still ? nil : Motion.room, value: editor.look.hidden.count)
        .onChange(of: editor.code) { _, _ in
            let turn = UUID(); flight = turn; flying = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if flight == turn { flying = false } }
        }
        .onReceive(boosts.$trials) { _ in DispatchQueue.main.async { editor.agentChanged() } }
        .onDisappear { editor.cancelOriginal() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Customize \(editor.host)")
    }

    /// The plate and the word are out of the button while the code is open
    /// or on its way.
    private var morphing: Bool { !still && (editor.code || flying) }

    private var panel: some View {
        VStack(spacing: 12) {
            field.modifier(BoostEditorStagger(delay: 0))
            VStack(spacing: 6) {
                dots("From the site", colors: Array(editor.swatches.prefix(4)), plain: true)
                dots("Presets", colors: ["#ef6461", "#e2b84b", "#66a98d", "#539bd5", "#8074bd"], plain: false)
            }.modifier(BoostEditorStagger(delay: 0.012))
            slider("Photos", value: editor.look.photos, range: 0...1.5, text: percent(editor.look.photos)) { value in editor.change { $0.photos = value } }
                .modifier(BoostEditorStagger(delay: 0.036))
            separator
            VStack(spacing: 12) {
                HStack {
                    Text("Text").sidebarFont(size: 12, weight: .semibold)
                    Spacer(minLength: 0)
                    Text(families[editor.look.font]).foregroundStyle(Palette.faint).sidebarFont(size: 12)
                }
                fonts
            }.modifier(BoostEditorStagger(delay: 0.048))
            slider("Size", value: editor.look.size, range: 0.85...1.6, text: percent(editor.look.size)) { value in editor.change { $0.size = value } }
            slider("Spacing", value: editor.look.spacing, range: min(1, 1.2 / editor.baseLine)...max(1, 2 / editor.baseLine), text: String(format: "%.2f", editor.look.spacing * editor.baseLine)) { value in editor.change { $0.spacing = value } }
                .modifier(BoostEditorStagger(delay: 0.06))
            separator
            HStack(spacing: 6) {
                if let browser = editor.browser { BoostEditorPickButton(browser: browser) }
                Button { editor.code = true } label: {
                    Text("Code")
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.pane)) } action: { buttonWord = $0 }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.yab(.secondary, .regular))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.pane)) } action: { buttonRect = $0 }
                .disabled(morphing)
                .opacity(morphing ? 0 : 1)
            }
            if !editor.look.hidden.isEmpty { hidden }
            if let problem = looks.problem ?? editor.problem {
                Text(problem).sidebarFont(size: 11).foregroundStyle(ButtonCSS.danger)
            }
        }
    }

    /// The Code button's plate, between the button and the field.
    private var plate: some View {
        let rect = editor.code ? fieldRect : buttonRect
        return RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Palette.wash)
            .frame(width: max(1, rect.width), height: max(1, rect.height))
            .offset(x: rect.minX, y: rect.minY)
            .animation(still ? nil : Motion.reshape, value: editor.code)
            .opacity(morphing ? 1 : 0)
            .animation(nil, value: editor.code)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The word Code, riding from the button into the field's header.
    private var rider: some View {
        let rect = editor.code ? headWord : buttonWord
        return Text("Code").font(ButtonSize.regular.font).foregroundStyle(Palette.ink).fixedSize()
            .position(x: rect.midX, y: rect.midY)
            .animation(still ? nil : Motion.reshape, value: editor.code)
            .opacity(morphing ? 1 : 0)
            .animation(nil, value: editor.code)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private func words(_ title: String, keys: String?) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if let keys { KeyGlyphs(keys: keys, size: ButtonSize.regular.wordSize, tint: nil, rest: 0.6) }
        }
    }

    /// A line between parts, edge to edge of the card, as Look's.
    private var separator: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, -CardFrame.inset)
    }

    private var field: some View {
        ColorField(point: CGPoint(x: editor.look.hue / 360, y: 1 - editor.look.amount),
                   fill: Color(hue: editor.look.hue / 360, saturation: editor.look.amount, brightness: 0.85), lightness: 0.65) { point in
            editor.change { $0.hue = Double(point.x) * 360; $0.amount = 1 - Double(point.y) }
        }
        // Look's own proportions: Auto, Light and Dark over its top.
        .frame(height: (inner * 0.62).rounded())
        .overlay(alignment: .top) {
            LookModes(mode: Binding(get: { editor.look.mode }, set: { mode in editor.change("scheme") { $0.mode = mode } }))
        }
        .overlay(alignment: .topTrailing) {
            LookCorner(changed: editor.look.changed, reset: { editor.reset() }, close: { editor.close() },
                       more: AnyView(Picker(selection: Binding(get: { editor.look.textCase }, set: { value in editor.change { $0.textCase = value } })) {
                           ForEach(cases.indices, id: \.self) { MenuMark.label(cases[$0], caseMarks[$0]).tag($0) }
                       } label: { MenuMark.label("Text Case", "yab.case") }))
        }
    }

    private var fonts: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(families.indices, id: \.self) { i in
                Button { editor.change("font") { $0.font = i } } label: {
                    VStack(spacing: 1) {
                        Text("Aa").font(font(i))
                        Text(families[i]).sidebarFont(size: 10).foregroundStyle(Palette.faint).lineLimit(1).minimumScaleFactor(0.8)
                    }.frame(maxWidth: .infinity, minHeight: 46)
                        .overlay {
                            if editor.look.font == i {
                                RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.ink, lineWidth: 1.5)
                                    .matchedGeometryEffect(id: "font", in: selection)
                            }
                        }
                }.buttonStyle(.yab(editor.look.font == i ? .raised : .secondary, .small, icon: .square))
                    .accessibilityLabel("\(families[i]) font").accessibilityAddTraits(editor.look.font == i ? .isSelected : [])
            }
        }
    }

    private func font(_ index: Int) -> Font {
        switch index {
        case 1: return .system(size: 17, weight: .medium)
        case 2: return .system(size: 17, weight: .medium, design: .rounded)
        case 3: return .system(size: 17, weight: .medium, design: .serif)
        case 4: return .custom("Avenir", size: 17)
        case 5: return .custom("Futura", size: 17)
        case 6: return .custom("Baskerville", size: 17)
        case 7: return .system(size: 17, weight: .medium, design: .monospaced)
        default: return .custom("Georgia", size: 17)
        }
    }

    /// A row of colors with its name before them; No Color closes the site's.
    private func dots(_ title: String, colors: [String], plain: Bool) -> some View {
        HStack(spacing: 2) {
            Text(title).foregroundStyle(Palette.muted).frame(width: 82, alignment: .leading)
            ForEach(colors, id: \.self) { hex in swatch(Color(nsColor: NSColor(hex: hex) ?? .gray), hex: hex) { editor.preset(hex) } }
            // Right after the site's colors, however few the site gave: pushed
            // to the far edge it read as a stray dot after an empty gap.
            if plain {
                swatch(Palette.ground, hex: "No Color", none: true) { editor.change("glide") { $0.amount = 0 } }
            }
            Spacer(minLength: 0)
        }.sidebarFont(size: 12)
    }

    private func swatch(_ fill: Color, hex: String, none: Bool = false, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            Circle().fill(fill).frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Palette.ink.opacity(none ? 0.3 : 0.15), lineWidth: none ? 1 : 0.5))
                .overlay {
                    // The usual "no color" mark: a slash across the empty well.
                    if none {
                        Rectangle().fill(Palette.muted).frame(width: 1.5, height: 16)
                            .rotationEffect(.degrees(45))
                    }
                }
                .clipShape(Circle())
        }.buttonStyle(.yab(.quiet, .small, icon: .round)).accessibilityLabel(hex.hasPrefix("#") ? "Color \(hex)" : hex)
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, text: String, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(Palette.muted).frame(width: 54, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range)
                .controlSize(.small).tint(Palette.ink)
                .labelsHidden().accessibilityLabel(title)
            Text(text).monospacedDigit().frame(width: 38, alignment: .trailing).foregroundStyle(Palette.faint)
        }.sidebarFont(size: 12)
    }

    private var hidden: some View {
        VStack(spacing: 2) {
            ForEach(editor.hiddenGroups) { group in
                BoostEditorHiddenRow(group: group)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var code: some View {
        let complete = BoostEditorLook.completeCSS(editor.draft)
        let fieldsVisible = editor.code || (!still && flying)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                Button { editor.code = false } label: { Symbol("chevron.left", size: 12, weight: .semibold) }
                    .buttonStyle(.yab(.quiet, .small, icon: .square))
                    .keyTip("Back to Controls", keys: "esc")
                    .accessibilityLabel("Back")
                Text("Code").font(ButtonSize.regular.font).foregroundStyle(Palette.ink)
                    .opacity(still ? 1 : 0)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.pane)) } action: { headWord = $0 }
                Spacer(minLength: 0)
                Text(complete ? "Live as you type" : "Keeping last working CSS")
                    .sidebarFont(size: 11).foregroundStyle(complete ? Palette.faint : ButtonCSS.danger)
            }.frame(height: 30)
            ZStack(alignment: .topLeading) {
                // Opacity and disabled/hit-testing traits do not unregister
                // AppKit's text cursor. Keep the native field only while it
                // is visible or finishing the existing code morph.
                if fieldsVisible {
                    TextEditor(text: Binding(get: { editor.draft }, set: { editor.editCSS($0) }))
                        .font(.system(size: 11.5, design: .monospaced))
                        .scrollContentBackground(.hidden).padding(6)
                        .accessibilityLabel("Custom CSS")
                } else {
                    Color.clear
                }
                if editor.draft.isEmpty {
                    Text("\u{2325}-click the page for a selector")
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Palette.faint)
                        .padding(.horizontal, 11).padding(.top, 6) // design: lines up with the TextEditor's own text inset (6 + 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                if still { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Palette.wash) }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.pane)) } action: { fieldRect = $0 }
            if !editor.agentRows.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Agent trial · Keep on the page to save").sidebarFont(size: 10).foregroundStyle(Palette.muted)
                    ForEach(Array(editor.agentRows.enumerated()), id: \.offset) { i, line in
                        BoostEditorAgentLine(line: line, delay: Double(i) * 0.035, selectable: fieldsVisible)
                    }
                }
            }
            if Agents.connected {
                HStack(spacing: 6) {
                    Group {
                        if fieldsVisible {
                            TextField("Ask for a change\u{2026}", text: $ask).textFieldStyle(.plain).onSubmit(send)
                        } else {
                            Color.clear
                        }
                    }
                        .padding(.horizontal, 10).frame(height: ButtonSize.regular.height)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    Button("Ask", action: send).buttonStyle(.yab(.secondary, .regular)).disabled(ask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.sidebarFont(size: 12)
            }
        }
        .onChange(of: fieldsVisible) { _, _ in
            // Retire a text control's cursor rectangle after SwiftUI has
            // inserted/removed its native view, even under a still pointer.
            DispatchQueue.main.async {
                if let window = editor.tab?.builtPage?.window { BoostEditorPointer.Area.refresh(in: window) }
            }
        }
    }

    private func send() { editor.ask(ask); ask = "" }
}

/// Hide Elements: lit while the page is taking clicks.
private struct BoostEditorPickButton: View {
    @ObservedObject var browser: Browser
    var body: some View {
        Button { BoostEditor.shared.pick() } label: {
            HStack(spacing: 6) {
                Text("Hide Elements").lineLimit(1)
                KeyGlyphs(keys: "⇧⌘H", size: ButtonSize.regular.wordSize, tint: nil, rest: 0.6)
            }
        }.buttonStyle(.yab(browser.veiling ? .primary : .secondary, .regular)).layoutPriority(1)
    }
}

/// The choice after a click on something the page has more of, at the
/// thing clicked: Only This One, or All of them.
struct BoostEditorPick: View {
    let choice: BoostEditor.Choice
    @ObservedObject private var editor = BoostEditor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(choice.label) · \(choice.siblings.count) like it on this page")
                .sidebarFont(size: 11.5).foregroundStyle(Palette.muted).lineLimit(2)
            Button { editor.choose(all: false) } label: { Text("Only This One").frame(maxWidth: .infinity) }
                .buttonStyle(.yab(.secondary, .regular))
            Button { editor.choose(all: true) } label: {
                HStack(spacing: 6) {
                    Text("All \(choice.siblings.count)")
                    KeyGlyphs(keys: "⏎", size: ButtonSize.regular.wordSize, tint: nil, rest: 0.6)
                }.frame(maxWidth: .infinity)
            }.buttonStyle(.yab(.primary, .regular))
        }
        .frame(width: 196)
        .cardFrame()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hide \(choice.label)")
    }
}

private struct BoostEditorStagger: ViewModifier {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var arrived = false
    func body(content: Content) -> some View {
        let morphing = BoostEditor.shared.oldCard != nil && !still
        content.opacity(!morphing || arrived ? 1 : 0)
            .offset(y: !morphing || arrived ? 0 : 10)
            .onAppear { withAnimation(morphing ? Motion.morph.delay(0.06 + delay) : nil) { arrived = true } }
    }
}

private struct BoostEditorHiddenRow: View {
    let group: BoostEditor.HiddenGroup
    @ObservedObject private var editor = BoostEditor.shared
    @State private var box = ViewBox()
    var body: some View {
        HStack(spacing: 8) {
            Text(group.label).lineLimit(1)
            Spacer(minLength: 0)
            if let note = group.note { Text(note).foregroundStyle(Palette.faint).sidebarFont(size: 11).lineLimit(1) }
            Button("Show") { if let first = group.veils.first { BoostEditor.shared.restoreGroup(first) } }.buttonStyle(.yab(.quiet, .small))
        }.sidebarFont(size: 12).frame(height: 28)
            .opacity(group.veils.allSatisfy { editor.traveling.contains($0.selector) } ? 0 : 1)
            .background(BoostEditorAnchor(box: box))
            .onAppear { group.veils.forEach { BoostEditor.shared.rowBoxes[$0.selector] = box } }
            .onChange(of: group.veils) { _, veils in veils.forEach { BoostEditor.shared.rowBoxes[$0.selector] = box } }
            .onDisappear { group.veils.forEach { BoostEditor.shared.rowBoxes[$0.selector] = nil } }
    }
}

private struct BoostEditorAgentLine: View {
    let line: String
    let delay: Double
    let selectable: Bool
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var arrived = false
    @State private var glowing = true
    var body: some View {
        Group {
            if selectable { Text(line).textSelection(.enabled) }
            else { Text(line) }
        }
            .font(.system(size: 10, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(glowing ? 0.16 : 0))
            .opacity(arrived ? 1 : 0)
            .offset(y: arrived || still ? 0 : 5)
            .onAppear {
                withAnimation(still ? nil : Motion.morph.delay(min(delay, 0.6))) { arrived = true }
                withAnimation(still ? nil : .easeOut(duration: 1.2).delay(min(delay, 0.6))) { glowing = false }
            }
    }
}
