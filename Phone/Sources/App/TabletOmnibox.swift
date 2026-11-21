import SwiftUI
import UIKit

/// Parity with Sources/Fast/Omnibox.swift's compact surface and YabDesign's
/// Palette, KeyGlyphs, and Shadow. iPad keeps its existing input and eyes.
@MainActor
enum TabletOmniboxStyle {
    static let width: CGFloat = 540
    static let corner: CGFloat = 18
    static let header: CGFloat = 52
    static let row: CGFloat = 40
    static let inset: CGFloat = 6
    static let gutter: CGFloat = 16
    static let slot: CGFloat = 22
    static let gap: CGFloat = 12
    static let ink = AppearanceColors.color(0x171717, 0xEDEDED)
    static let muted = AppearanceColors.color(0x474747, 0xD1D1D1)
    static let uiInk = AppearanceColors.ui(0x171717, 0xEDEDED)
    static let uiMuted = AppearanceColors.ui(0x474747, 0xD1D1D1)
    static let selection = AppearanceColors.ui(0x171717, 0xEDEDED, alpha: 0.12)
    static func input(dark: Bool) -> FieldInputStyle {
        let ink = UIColor(white: dark ? 0.93 : 0.09, alpha: 1)
        return FieldInputStyle(fontSize: 20, ink: ink, selection: ink.withAlphaComponent(0.12), caret: ink,
                               placeholder: UIColor(white: dark ? 0.82 : 0.28, alpha: 1))
    }

    static func top(in height: CGFloat) -> CGFloat {
        max(16, min(((height - 58 - 417) / 2).rounded(), (height * 0.18).rounded()))
    }
    static func spaceTone(_ space: Space, dark: Bool) -> Color {
        let rgb = space.look?.displayColors(dark: dark).first ?? space.tint
        let color = UIColor(red: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let gray = saturation < 0.06
        return Color(uiColor: UIColor(hue: hue, saturation: gray ? 0 : max(saturation, 0.55),
                                      brightness: gray ? (dark ? 0.46 : 0.40) : (dark ? 0.58 : 0.62), alpha: 1))
    }
}

struct TabletOmnibox: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceTransparency) private var solid
    @ScaledMetric(relativeTo: .body) private var rowHeight = TabletOmniboxStyle.row
    @State private var selectedID: String?
    let geometry: TabletWorkspaceGeometry
    private typealias S = TabletOmniboxStyle
    private let shape = RoundedRectangle(cornerRadius: TabletOmniboxStyle.corner, style: .continuous)
    private var dark: Bool { app.field.isPrivate || app.pageIsPrivate || app.pageIsDark || AppAppearance.current == .dark }
    private var privateField: Bool { app.field.isPrivate || app.pageIsPrivate }
    /// What the card shows, made once for each drawing of it. The field's
    /// rows and New Tab's walk every tab; asked for in each row's `chosen`,
    /// they were made again for every row, and an iPad with many tabs spent
    /// its launch on them until the watchdog ended it (#546-#561).
    private struct Lines {
        var rows: [WordRow] = []
        var recent: [NewTabItem] = []
        var key: WordRow.Key = .go
        var choiceIDs: [String] = []
        var choice: String?
    }

    private func makeLines() -> Lines {
        var lines = Lines()
        let all = app.fieldRows
        lines.key = app.fieldKey(rows: all)
        lines.rows = app.field.showsAddress ? [] : Array(all.prefix(app.fieldAnswer == nil ? 5 : 4))
        // Recent shows only where there are no rows.
        if lines.rows.isEmpty, !app.field.showsAddress, !privateField, app.field.words.isEmpty {
            lines.recent = Array(NewTabContent.make(for: app).recent.prefix(5))
        }
        let ids = (app.fieldAnswer != nil && !app.field.showsAddress ? ["answer"] : [])
            + (lines.rows.isEmpty ? lines.recent.map { "recent:" + $0.id } : lines.rows.map { "row:" + $0.id })
        lines.choiceIDs = ids
        if let selectedID, ids.contains(selectedID) { lines.choice = selectedID }
        else if app.fieldAnswerTakesKey, ids.contains("answer") { lines.choice = "answer" }
        else { lines.choice = ids.first(where: { $0 != "answer" }) ?? ids.first }
        return lines
    }

    var body: some View {
        let lines = makeLines()
        let rows = lines.rows, recent = lines.recent, choice = lines.choice
        let model = app.field
        let available = geometry.size.height - geometry.top - (model.resting ? 0 : max(0, model.keyboard))
        let top = S.top(in: available)
        let count = rows.isEmpty ? recent.count : rows.count
        let answerHeight = app.fieldAnswer == nil || model.showsAddress ? 0 : rowHeight
        let wanted = count == 0 && answerHeight == 0 ? 0 : CGFloat(count) * rowHeight + 2 * S.inset + answerHeight
        let bodyHeight = min(wanted, max(0, available - top - S.header - 16))
        ZStack(alignment: .top) {
            Color.clear.contentShape(Rectangle()).onTapGesture { model.close() }
                .accessibilityLabel("Close Search").accessibilityAddTraits(.isButton)
            VStack(spacing: 0) {
                header(lines)
                if bodyHeight > 0 {
                    ScrollViewReader { scroll in
                        ScrollView {
                            VStack(spacing: 0) {
                                if let answer = app.fieldAnswer {
                                    Button(action: app.copyFieldAnswer) {
                                        line(icon: .magnifier, title: answer.result, detail: answer.resultNote,
                                             end: "Copy", chosen: choice == "answer", markAsset: "TabletPlus")
                                    }
                                    .buttonStyle(.plain).accessibilityIdentifier("tablet.search.answer")
                                    .accessibilityAddTraits(choice == "answer" ? .isSelected : [])
                                    .id("answer")
                                }
                                if rows.isEmpty {
                                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, item in
                                        Button { app.choose(item) } label: {
                                            line(icon: item.icon, title: item.title, detail: nil, end: index == 0 ? "Open" : "Recent", chosen: choice == "recent:" + item.id)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("tablet.search.recent.\(index)")
                                        .accessibilityAddTraits(choice == "recent:" + item.id ? .isSelected : [])
                                        .id("recent:" + item.id)
                                    }
                                } else {
                                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                        Button { app.choose(row) } label: {
                                            line(icon: row.icon, title: row.line.main, detail: row.line.detail,
                                                 end: action(row), chosen: choice == "row:" + row.id)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("tablet.search.row.\(index)")
                                        .accessibilityAddTraits(choice == "row:" + row.id ? .isSelected : [])
                                        .id("row:" + row.id)
                                    }
                                }
                            }.padding(S.inset)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: bodyHeight)
                        .onChange(of: choice) { _, id in if let id { scroll.scrollTo(id) } }
                    }
                }
            }
            .frame(width: min(S.width, geometry.size.width - 32))
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(shape)
            .background { surface }
            .overlay { shape.strokeBorder(dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08), lineWidth: 0.5).allowsHitTesting(false) }
            .overlay {
                shape.inset(by: 0.5)
                    .stroke(LinearGradient(colors: [.white.opacity(dark ? 0.18 : 0.7), .white.opacity(0)],
                                           startPoint: .top, endPoint: .center), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("tablet.omnibox")
            .padding(.top, geometry.top + top)
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        .accessibilityAction(.escape) { model.close() }
        .onDisappear { model.presentationFrame = nil }
        .onChange(of: model.text) { _, _ in selectedID = nil }
        .onChange(of: model.isPrivate) { _, _ in selectedID = nil }
        .onChange(of: model.showsAddress) { _, _ in selectedID = nil }
        .onChange(of: lines.choiceIDs) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
        }
    }

    private func header(_ lines: Lines) -> some View {
        HStack(spacing: S.gap) {
            FieldInput(text: app.field.text, selected: app.field.showsAddress, placeholder: "Search or enter address",
                       style: S.input(dark: dark), dark: dark, key: lines.key, focusRequest: app.field.focusRequest,
                       blurRequest: app.field.blurRequest, typed: app.field.typed, editAddress: app.field.editAddress,
                       submit: submit, escape: app.field.close,
                       moveSelection: lines.choiceIDs.isEmpty ? nil : moveSelection,
                       allowsEmptySubmit: !lines.choiceIDs.isEmpty)
                .frame(height: 26)
            if !app.field.pageIsPrivate {
                Button { app.field.setPrivate(!app.field.isPrivate) } label: {
                    HStack(spacing: 8) {
                        if app.field.isPrivate { Text("Incognito").font(.system(size: 13.5)).foregroundStyle(S.muted) }
                        Eyes(shut: app.field.isPrivate ? 1 : 0, color: S.ink)
                    }
                    .frame(minWidth: 32, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityElement(children: .ignore)
                .accessibilityIdentifier("field.eyes").accessibilityLabel("Incognito")
                .accessibilityValue(app.field.isPrivate ? "on" : "off").accessibilityAddTraits(.isToggle)
            }
            Button { app.field.close() } label: {
                Image("TabletFieldClose").renderingMode(.template).resizable().frame(width: 14, height: 14)
                    .foregroundStyle(S.muted).frame(width: 32, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Close Search").accessibilityIdentifier("field.close")
        }
        .padding(.horizontal, S.gutter)
        .frame(height: S.header)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { app.field.presentationFrame = $0 }
    }

    private var surface: some View {
        let ground: Color = dark ? Color(white: 0.13) : .white
        return ZStack {
            TabletOmniboxShadow(shape: shape, dark: dark)
            if solid {
                shape.fill(ground)
            } else {
                shape.fill(privateField ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.ultraThinMaterial))
                Color.clear.glassEffect(.regular.tint(ground.opacity(privateField ? 0.3 : dark ? 0.45 : 0.18)), in: shape)
            }
            if privateField { shape.fill(Color(red: 0.28, green: 0.16, blue: 0.72).opacity(0.06)) }
        }
        .allowsHitTesting(false)
    }

    private func line(icon: WordRow.Icon, title: String, detail: String?, end: String, chosen: Bool, markAsset: String? = nil) -> some View {
        HStack(spacing: S.gap) {
            Group {
                if let markAsset {
                    Image(markAsset).renderingMode(.template).resizable().frame(width: 14, height: 14)
                        .foregroundStyle(chosen ? .white : S.ink)
                        .frame(width: S.slot, height: S.slot)
                        .background((chosen ? Color.white : S.ink).opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                } else { mark(icon, chosen: chosen) }
            }.frame(width: S.slot, height: S.slot)
            Text(title).font(.system(size: 13.5)).foregroundStyle(chosen ? .white : S.ink).lineLimit(1)
            if let detail, !detail.isEmpty {
                Text(detail).font(.system(size: 13.5)).foregroundStyle(chosen ? .white.opacity(0.8) : S.muted)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text(end).font(.system(size: 13.5)).lineLimit(1)
                if chosen {
                    Image("TabletReturnKey").renderingMode(.template).resizable().frame(width: 14, height: 14)
                        .frame(width: 20, height: 20)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .foregroundStyle(chosen ? .white.opacity(0.8) : S.muted)
        }
        .padding(.horizontal, S.gutter - S.inset)
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .background {
            if chosen {
                RoundedRectangle(cornerRadius: S.corner - S.inset, style: .continuous)
                    .fill(S.spaceTone(app.browser.space, dark: dark))
                    .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
            }
        }
        .environment(\.colorScheme, chosen ? .dark : dark ? .dark : .light)
    }

    @ViewBuilder private func mark(_ icon: WordRow.Icon, chosen: Bool) -> some View {
        switch icon {
        case let .favicon(key, host): Favicon(icon: key, host: host, size: 18, isPrivate: privateField)
        default:
            let asset: String = switch icon {
            case .magnifier: "TabletFind"
            case .settings: MacGlyph.gearshape.rawValue
            case .clipboard: "TabletFieldClipboard"
            case .onPage: MacGlyph.yabPageSearch.rawValue
            case .globe: "TabletFieldGlobe"
            case .agent: MacGlyph.agentFace.rawValue
            case .sparkle: "TabletFieldAsk"
            case .favicon: "TabletFind"
            }
            Image(asset).renderingMode(.template).resizable().frame(width: 14, height: 14)
                .foregroundStyle(chosen ? .white : S.ink)
                .frame(width: S.slot, height: S.slot)
                .background((chosen ? Color.white : S.ink).opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func action(_ row: WordRow) -> String {
        switch row.action {
        case .tab: "Switch to Tab"
        case .search, .searchFor: "Search " + app.field.searchSettings.searchSelection.name
        case .site, .place, .open: "Open"
        case .ask: "Ask"
        case .task: "Send"
        case .settings: "Open Settings"
        case .command: "Do"
        case .findOnPage: "Find"
        }
    }
    private func submit() {
        let lines = makeLines(), choice = lines.choice
        if choice == "answer" { app.copyFieldAnswer() }
        else if let row = lines.rows.first(where: { choice == "row:" + $0.id }) { app.choose(row) }
        else if let item = lines.recent.first(where: { choice == "recent:" + $0.id }) { app.choose(item) }
        else { app.fieldReturn() }
    }

    private func moveSelection(_ delta: Int) {
        let lines = makeLines(), ids = lines.choiceIDs
        guard let choice = lines.choice, let index = ids.firstIndex(of: choice) else { return }
        selectedID = ids[max(0, min(ids.count - 1, index + delta))]
    }
}

private struct TabletOmniboxShadow: View {
    let shape: RoundedRectangle
    let dark: Bool
    var body: some View {
        ZStack {
            shape.fill(.black)
                .shadow(color: .black.opacity(dark ? 0.20 : 0.10), radius: 8, y: 6)
                .shadow(color: .black.opacity(dark ? 0.45 : 0.26), radius: 32, y: 24)
            shape.fill(.black).blendMode(.destinationOut)
        }
        .compositingGroup().allowsHitTesting(false)
    }
}
