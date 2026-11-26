import SwiftUI
import UIKit

/// Settings' head and bodies in a real clipped UIKit window inside the sheet,
/// without the system's safe areas: nothing extends into the status bar.
struct SettingsViewport: UIViewControllerRepresentable {
    let app: AppModel
    let size: CGSize
    var top: CGFloat = 0
    var keyboardOffset: CGFloat = 0
    var column: SettingsColumn? = nil

    func makeUIViewController(context: Context) -> SettingsViewportController {
        let controller = SettingsViewportController()
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: SettingsViewportController, context: Context) {
        controller.update(AnyView(SettingsSheet(size: size, top: top, keyboardOffset: keyboardOffset, column: column)
            .environment(app)
            .environment(\.colorScheme, context.environment.colorScheme)
            .environment(\.dynamicTypeSize, context.environment.dynamicTypeSize)
            .environment(\.layoutDirection, context.environment.layoutDirection)))
    }
}

@MainActor
final class SettingsViewportController: UIViewController {
    private let host = UIHostingController(rootView: AnyView(EmptyView()))

    override func loadView() {
        let viewport = UIView()
        viewport.backgroundColor = .clear
        viewport.clipsToBounds = true
        viewport.accessibilityIdentifier = "settings.sheet"
        viewport.accessibilityViewIsModal = true
        viewport.accessibilityContainerType = .semanticGroup
        view = viewport
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        host.safeAreaRegions = []
        host.sizingOptions = []
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    func update(_ content: AnyView) {
        host.rootView = content
        if isViewLoaded { view.setNeedsLayout() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        host.view.frame = view.bounds
    }
}
