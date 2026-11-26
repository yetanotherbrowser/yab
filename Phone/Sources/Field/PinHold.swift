import SwiftUI
import UIKit

/// A hold on a pin of a space's page. The grid is one List row, and SwiftUI's
/// context menu inside it did not open on an iPhone (0.1.15), so UIKit owns
/// this one: each square hosts its cell with an interaction of its own. The menu is
/// the column's for pins (TabHold's), the lift the page's picture over it.
struct PinHold: UIViewControllerRepresentable {
    @Environment(AppModel.self) private var app
    let tab: Tab?
    let page: Space.ID
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
        context.coordinator.page = page
        context.coordinator.environment = context.environment
    }

    @MainActor final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        weak var app: AppModel?
        var tab: Tab?
        var page: Space.ID?
        var environment = EnvironmentValues()

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard let app, let tab else { return nil }
            let environment = environment, page = page
            return UIContextMenuConfiguration(identifier: tab.id as NSString, previewProvider: {
                let preview = UIHostingController(rootView: TabHoldPreview(tab: tab, picture: app.pages.snapshots[tab.id], pool: app.pages)
                    .environment(\.self, environment))
                preview.sizingOptions = .preferredContentSize
                return preview
            }, actionProvider: { _ in PinHold.menu(tab, app: app, page: page) })
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

    /// TabHold's menu for a pin: Copy Link, Duplicate Tab, Share, Open on Mac;
    /// Unpin, Move to Space, Ask About Page; Close Tab, each with the
    /// column's glyph.
    @MainActor static func menu(_ tab: Tab, app: AppModel, page: Space.ID?) -> UIMenu {
        let column = ColumnState.of(app)
        func item(_ title: String, _ glyph: MacGlyph, _ run: @escaping () -> Void) -> UIAction {
            UIAction(title: title, image: UIImage.menuGlyph(glyph)) { _ in run() }
        }
        let first = TabHold.pageItems(tab, app: app, page: page).map { item($0.title, $0.glyph, $0.run) }
        var sections = [UIMenu(options: .displayInline, children: first)]
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
            own.append(item("Ask About Page", .yabChatSpark) { TabHold.ask(tab, app: app, page: page) })
            sections.append(UIMenu(options: .displayInline, children: own))
        }
        sections.append(UIMenu(options: .displayInline, children: [item("Close Tab", .yabTabX) { column.close(tab.id) }]))
        return UIMenu(children: sections)
    }
}
