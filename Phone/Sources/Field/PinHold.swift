import SwiftUI
import UIKit

/// A hold on a pin of a space's page. The grid is one List row, and SwiftUI's
/// context menu inside it did not open on an iPhone (0.1.15), so UIKit owns
/// this one: each square hosts its cell with an interaction of its own. The menu is
/// the column's for pins (TabHold's), the lift the page's picture over it.
struct PinHold: UIViewControllerRepresentable {
    @Environment(AppModel.self) private var app
    let tab: Tab?
    let content: AnyView

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIHostingController<AnyView> {
        let host = UIHostingController(rootView: AnyView(content.environment(\.self, context.environment)))
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        return host
    }

    func updateUIViewController(_ host: UIHostingController<AnyView>, context: Context) {
        host.rootView = AnyView(content.environment(\.self, context.environment))
        context.coordinator.app = app
        context.coordinator.tab = tab
        context.coordinator.environment = context.environment
    }

    @MainActor final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        weak var app: AppModel?
        var tab: Tab?
        var environment = EnvironmentValues()

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard let app, let tab else { return nil }
            let environment = environment
            return UIContextMenuConfiguration(identifier: tab.id as NSString, previewProvider: {
                let preview = UIHostingController(rootView: TabHoldPreview(tab: tab, picture: app.pages.snapshots[tab.id], pool: app.pages)
                    .environment(\.self, environment))
                preview.sizingOptions = .preferredContentSize
                return preview
            }, actionProvider: { _ in PinHold.menu(tab, app: app) })
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
            lift(interaction)
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
            lift(interaction)
        }

        /// The square itself, at its own corners, grows into the picture.
        private func lift(_ interaction: UIContextMenuInteraction) -> UITargetedPreview? {
            guard let view = interaction.view, view.window != nil else { return nil }
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: Metrics.Column.pinRadius)
            return UITargetedPreview(view: view, parameters: parameters)
        }
    }

    /// TabHold's menu for a pin: Copy Link, Share, Open on Mac; Unpin, Move
    /// to Space, Ask About Page; Close Tab, each with the column's glyph.
    @MainActor static func menu(_ tab: Tab, app: AppModel) -> UIMenu {
        let column = ColumnState.of(app)
        func item(_ title: String, _ glyph: MacGlyph, _ run: @escaping () -> Void) -> UIAction {
            UIAction(title: title, image: UIImage.menuGlyph(glyph)) { _ in run() }
        }
        var page: [UIMenuElement] = []
        if app.workspace.canSplit, !tab.isPrivate, !tab.isMail, tab.id != app.browser.tab?.id, app.browser.space.tab(tab.id) != nil {
            page.append(item("Split View", .yabSplitPlus) { app.openTabBeside(tab) })
        }
        page.append(item("Copy Link", .link) { app.copyLink(of: tab) })
        page.append(item("Share", .yabShare) { app.share(tab) })
        if !tab.isPrivate {
            page.append(item("Open on Mac", .yabLaptopRight) {
                if app.isFixture { app.say("Opened on \(app.macName)", glyph: .macbook) } else { app.sync.openOnMac(tab) }
            })
        }
        var sections = [UIMenu(options: .displayInline, children: page)]
        if !tab.isPrivate {
            var own: [UIMenuElement] = []
            if !tab.isMail, let space = app.browser.space(holding: tab.id) {
                own.append(item("Rename Tab…", .pencil) { app.tabEdits.begin(.tab(space.id, tab)) })
                if let folderMenu = TabEdits.folderMenu(tab, app: app) { own.append(folderMenu) }
            }
            if !tab.isMail { own.append(item("Unpin Tab", .pinSlash) { column.unpin(tab.id) }) }
            let home = app.browser.space(holding: tab.id)?.id
            let others = app.browser.spaces.filter { !$0.isPrivate && $0.id != home }
            if !others.isEmpty {
                own.append(UIMenu(title: "Move to Space", image: UIImage.menuGlyph(.square2Layers3d), children: others.map { space in
                    UIAction(title: "\(space.emoji) \(space.name)") { _ in column.move(tab.id, to: space.id) }
                }))
            }
            own.append(item("Ask About Page", .yabChatSpark) { TabHold.ask(tab, app: app) })
            sections.append(UIMenu(options: .displayInline, children: own))
        }
        sections.append(UIMenu(options: .displayInline, children: [item("Close Tab", .yabTabX) { column.close(tab.id) }]))
        return UIMenu(children: sections)
    }
}
