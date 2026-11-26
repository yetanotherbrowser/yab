import AppKit
import SwiftUI

/// A native cursor boundary for the card, like the reader's hosting view.
/// It covers only the card, so WebKit keeps mouse delivery outside it.
struct BoostEditorPointer: NSViewRepresentable {
    private let content: AnyView

    init<Content: View>(@ViewBuilder content: () -> Content) {
        self.content = AnyView(content())
    }

    func makeNSView(context: Context) -> Area { Area(rootView: AnyView(EmptyView())) }
    func updateNSView(_ view: Area, context: Context) {
        view.rootView = AnyView(content.hosted(in: context.environment))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Area, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class Area: NSHostingView<AnyView> {
        private static let views = NSHashTable<NSView>.weakObjects()
        private var cursorArea: NSTrackingArea?
        private var cursorUpdates = 0

        required init(rootView: AnyView) {
            super.init(rootView: rootView)
            sizingOptions = []
            safeAreaRegions = []
            Self.views.add(self)
        }
        required init?(coder: NSCoder) { fatalError("not from a nib") }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            super.resetCursorRects()
            // WebKit respects AppKit cursor rectangles when its late IPC
            // cursor reply arrives. cursorUpdate alone is overwritten.
            addCursorRect(bounds, cursor: .arrow)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let cursorArea { removeTrackingArea(cursorArea) }
            let area = NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
            cursorArea = area
            addTrackingArea(area)
        }

        override func cursorUpdate(with event: NSEvent) {
            CursorUpdateGuard.run(self) {
                if Store.testing { cursorUpdates += 1 }
                super.cursorUpdate(with: event)
            }
        }

        static func measure(_ view: NSView) { views.add(view) }
        static func refresh(in window: NSWindow) {
            for view in views.allObjects where view.window === window {
                window.invalidateCursorRects(for: view)
            }
        }
        static func cursorUpdates(in window: NSWindow) -> Int {
            views.allObjects.compactMap { $0 as? Area }
                .filter { $0.window === window }.reduce(0) { $0 + $1.cursorUpdates }
        }
        static func screenRect(in window: NSWindow) -> CGRect? {
            guard let view = views.allObjects.first(where: { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }) else { return nil }
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }
    }
}

/// Read-only baseline geometry, without the cursor boundary or text fix.
struct BoostEditorMeasurement: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = Measure()
        BoostEditorPointer.Area.measure(view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    private final class Measure: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
