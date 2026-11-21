import Foundation
import UIKit
import WebKit

/// The part of a real webpage visible between the hardware edges and Yab's
/// floating chrome. WebKit handles fixed elements and CSS viewport units;
/// webpages keep ownership of their own safe-area CSS.
struct PageViewport: Equatable {
    struct Chrome: Equatable {
        var folded: Bool
        var hasNow: Bool
        var visible: Bool
        var verticalControls: Bool? = nil
        var leadingRail = false
    }

    let size: CGSize
    let hardware: UIEdgeInsets
    let chrome: Chrome

    var minimum: UIEdgeInsets { insets(folded: true) }
    var maximum: UIEdgeInsets { insets(folded: false) }
    var current: UIEdgeInsets { insets(folded: chrome.folded) }

    private func insets(folded: Bool) -> UIEdgeInsets {
        let layout = ChromeGeometry(size: size, folded: folded, hasNow: chrome.hasNow, verticalControls: chrome.verticalControls, leadingRail: chrome.leadingRail)
        let topOfChrome = chrome.hasNow ? min(layout.plate.minY, layout.now.minY) : layout.plate.minY
        let occupied = chrome.visible ? max(0, size.height - topOfChrome) : 0
        // The page lays out inside both hardware sides, a Duo's status column
        // included: under the column, a site's own top-right controls stood
        // beneath the camera and a tap there opened Control Center (#989).
        // WebKit fills the column beside the page with its under-page color.
        return UIEdgeInsets(top: max(0, hardware.top), left: max(0, hardware.left),
                            bottom: max(max(0, hardware.bottom), occupied), right: max(0, hardware.right))
    }

    private func fitting(_ insets: UIEdgeInsets, to size: CGSize) -> UIEdgeInsets {
        func axis(_ start: CGFloat, _ end: CGFloat, length: CGFloat) -> (CGFloat, CGFloat) {
            let first = start.isFinite ? max(0, start) : 0
            let last = end.isFinite ? max(0, end) : 0
            let limit = max(0, length - 1)
            let total = first + last
            guard total > limit else { return (first, last) }
            let scale = limit / total
            return (first * scale, last * scale)
        }
        let vertical = axis(insets.top, insets.bottom, length: size.height)
        let horizontal = axis(insets.left, insets.right, length: size.width)
        return UIEdgeInsets(top: vertical.0, left: horizontal.0, bottom: vertical.1, right: horizontal.1)
    }

    // Each live page receives this layout. A global Boolean would also
    // silence a different page while WebKit delivers a nested callback.
    @MainActor private static var applying: [ObjectIdentifier: Int] = [:]

    @MainActor
    static func isApplying(to view: WKWebView) -> Bool {
        applying[ObjectIdentifier(view), default: 0] > 0
    }

    /// When each page last had its insets written (system uptime). A page's
    /// own scrollers re-lay themselves out after that, and their scroll
    /// events are not a person's swipe.
    @MainActor private static var wrote: [ObjectIdentifier: TimeInterval] = [:]
    static let settleTime: TimeInterval = 0.6

    @MainActor
    static func recentlyWrote(to view: WKWebView, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let time = wrote[ObjectIdentifier(view)] else { return false }
        return now - time < settleTime
    }

    @MainActor
    func apply(to view: WKWebView) {
        MainStalls.count("viewport")
        UpdateLoops.count(.viewport) {
            var inputs = UpdateLoops.Fingerprint(fields: [
                "view": Double(ObjectIdentifier(view).hashValue),
                "refreshing": view.scrollView.refreshControl?.isRefreshing == true ? 1 : 0,
            ])
            inputs.chrome(chrome)
            inputs.size("size", size)
            inputs.size("frame", view.frame.size)
            inputs.insets("hardware", hardware)
            inputs.insets("requested.minimum", self.minimum)
            inputs.insets("requested.maximum", self.maximum)
            inputs.insets("requested.current", self.current)
            inputs.insets("applied.minimum", view.minimumViewportInset)
            inputs.insets("applied.maximum", view.maximumViewportInset)
            inputs.insets("applied.current", view.obscuredContentInsets)
            inputs.insets("scroll.content", view.scrollView.contentInset)
            inputs.insets("scroll.indicators", view.scrollView.verticalScrollIndicatorInsets)
            return inputs
        }
        // UIKit can briefly lay out a small view during a transition. WebKit
        // throws an Objective-C exception if either inset pair empties its frame.
        let frame = view.frame.size
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return }
        // A field of the page's own holds the keyboard: the keyboard is chrome
        // over the page as the plate is, so WebKit lays the page out above it
        // and lifts a field low on the page, or a chat's fixed to the bottom,
        // into view. .never keeps UIKit and WebKit from making that room
        // themselves, so such a field stayed under the keyboard (owner, 0.1.39).
        let keyboard = PageKeyboard.room(over: view)
        func raised(_ insets: UIEdgeInsets) -> UIEdgeInsets {
            var out = insets
            out.bottom = max(out.bottom, keyboard)
            return out
        }
        let maximum = fitting(raised(self.maximum), to: frame)
        let folded = fitting(raised(self.minimum), to: frame)
        let minimum = UIEdgeInsets(top: min(folded.top, maximum.top), left: min(folded.left, maximum.left),
                                   bottom: min(folded.bottom, maximum.bottom), right: min(folded.right, maximum.right))
        let current = chrome.folded ? minimum : maximum
        let refreshTop = view.scrollView.refreshControl?.isRefreshing == true
            ? max(0, view.scrollView.contentInset.top - view.obscuredContentInsets.top) : 0
        let identity = ObjectIdentifier(view)
        var scrollInsets = current
        scrollInsets.top += refreshTop
        guard view.minimumViewportInset != minimum || view.maximumViewportInset != maximum
                || view.obscuredContentInsets != current || view.scrollView.contentInset != scrollInsets
                || view.scrollView.verticalScrollIndicatorInsets != current
                || view.scrollView.horizontalScrollIndicatorInsets != current
                || view.scrollView.automaticallyAdjustsScrollIndicatorInsets else { return }
        // These setters can synchronously move contentOffset even during a
        // drag or deceleration. That movement is layout, not a new swipe.
        Self.wrote[identity] = ProcessInfo.processInfo.systemUptime
        Self.applying[identity, default: 0] += 1
        defer {
            if Self.applying[identity] == 1 { Self.applying.removeValue(forKey: identity) }
            else { Self.applying[identity, default: 1] -= 1 }
        }
        if view.minimumViewportInset != minimum || view.maximumViewportInset != maximum {
            view.setMinimumViewportInset(minimum, maximumViewportInset: maximum)
        }
        if view.obscuredContentInsets != current { view.obscuredContentInsets = current }
        // .never prevents UIKit from adding the hardware edges a second time.
        // The scroll range needs the same edges as the viewport.
        if view.scrollView.contentInset != scrollInsets { view.scrollView.contentInset = scrollInsets }
        // The indicators take the viewport's edges. UIKit's own adjustment
        // added the window's safe area on top of these, so on a Duo's cover
        // the bar stood 168 points in (#1945).
        if view.scrollView.automaticallyAdjustsScrollIndicatorInsets {
            view.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        }
        if view.scrollView.verticalScrollIndicatorInsets != current {
            view.scrollView.verticalScrollIndicatorInsets = current
        }
        if view.scrollView.horizontalScrollIndicatorInsets != current {
            view.scrollView.horizontalScrollIndicatorInsets = current
        }
    }
}

/// The keyboard over a page while one of the page's own fields holds it:
/// the page viewport counts it as browser chrome at the bottom.
@MainActor
enum PageKeyboard {
    /// Its frame in screen coordinates, and the page whose field brought it.
    private static var frame: CGRect?
    private static weak var page: WKWebView?
    fileprivate static weak var found: UIResponder?

    /// The page containers call this for each keyboard notification, then
    /// lay their page out again.
    static func note(_ notification: Notification) {
        guard notification.name != UIResponder.keyboardWillHideNotification,
              let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              !end.isEmpty else {
            frame = nil; page = nil; return
        }
        frame = end
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.yabNoteFirstResponder(_:)), to: nil, from: nil, for: nil)
        let responder = found as? UIView
        found = nil
        // The page itself holds the field's focus, or a view of its own does.
        var view: UIView? = responder
        while let current = view, !(current is WKWebView) { view = current.superview }
        page = view as? WKWebView
    }

    static func room(over view: WKWebView) -> CGFloat {
        guard let frame, page === view, let window = view.window else { return 0 }
        let keyboard = view.convert(frame, from: window.screen.coordinateSpace)
        guard keyboard.minY < view.bounds.maxY, keyboard.maxY > view.bounds.minY else { return 0 }
        return max(0, view.bounds.maxY - keyboard.minY)
    }
}

extension UIResponder {
    /// Answers which responder is first (UIKit has no public question for it).
    @objc fileprivate func yabNoteFirstResponder(_ sender: Any?) {
        PageKeyboard.found = self
    }
}

/// Geometry that can move the scroll position without a person's movement.
struct PageScrollGeometry: Equatable {
    let size: CGSize
    let contentSize: CGSize
    let contentInsets: UIEdgeInsets
    let viewportInsets: UIEdgeInsets

    @MainActor
    init(_ view: WKWebView) {
        size = view.scrollView.bounds.size
        contentSize = view.scrollView.contentSize
        contentInsets = view.scrollView.adjustedContentInset
        viewportInsets = view.obscuredContentInsets
    }
}
