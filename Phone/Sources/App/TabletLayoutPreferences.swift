import Foundation
import Observation
import SwiftUI

extension Metrics {
    enum Tablet {
        static let sidebar: CGFloat = 264
        static let sidebarMinimum: CGFloat = 220
        static let sidebarMaximum: CGFloat = 360
        static let toolbar: CGFloat = 44
        /// The Mac's 36-point address band, centered in the 44-point row.
        static let addressHeight: CGFloat = 36
        static let rim: CGFloat = 8
        static let paneBar: CGFloat = 44
        static let row: CGFloat = 44
        /// The Mac's row ground, inside the finger's row.
        static let rowGround: CGFloat = 36
        static let clearLine: CGFloat = 28
        /// The spaces not in front, in the foot: the Mac's dimmed marks.
        static let dimmedSpace: Double = 0.45
        /// The Mac's two-finger paging (SpacePaging): the row at half the
        /// travel, a 0.15 give past the ends, and a let-go speed (points a
        /// second) that keeps going.
        static let spacePull: CGFloat = 0.5
        static let spaceGive: CGFloat = 0.15
        static let spaceFling: CGFloat = 300
        static let splitGap: CGFloat = 8
        static let resizeTarget: CGFloat = 20
        static let inset: CGFloat = 10
        static let pin: CGFloat = 48
        static let downloadsWidth: CGFloat = 340
        static let downloadsHeight: CGFloat = 480
        static let downloadsInset: CGFloat = 8
        static let downloadDot: CGFloat = 7
        static let downloadDotInset: CGFloat = 9
        /// The Mac's Hoard: the badge's ring round the button's mark, the
        /// disc a file is thrown as, its lift, its arc and how far it rises.
        static let downloadRing: CGFloat = 26
        static let downloadRingLine: CGFloat = 2
        static let downloadDisc: CGFloat = 24
        static let downloadLift: Double = 0.11
        static let downloadArc: Double = 0.56
        static let downloadRise: CGFloat = 6
        static let downloadArcHeight: CGFloat = 90
        static let downloadBump: CGFloat = 1.18
        static let pinGap: CGFloat = 7
        static let pinMinWidth: CGFloat = 47
        static let pinMaxColumns = 4

        /// The Mac's SideBar.pinColumns: as many as fit, four at most, then
        /// only as many as keep the rows even, the row filling the width.
        static func pinColumns(_ count: Int, width: CGFloat) -> Int {
            guard count > 0 else { return 1 }
            let fits = min(pinMaxColumns, max(1, Int((width + pinGap) / (pinMinWidth + pinGap))))
            let rows = (count + fits - 1) / fits
            return (count + rows - 1) / rows
        }
        static let pairInset: CGFloat = 4
        static let pairGap: CGFloat = 4
        static let pairRadius: CGFloat = 5
        static let pairIcon: CGFloat = 15
        static let pairPadding: CGFloat = 6
        static let focusStroke: CGFloat = 1.5
        static let focusColor = Color(red: 86 / 255, green: 125 / 255, blue: 168 / 255)
    }
}

/// Local layout choices never travel through sync. Fixture worlds use memory only.
@MainActor @Observable
final class TabletLayoutPreferences {
    @ObservationIgnored private let defaults: UserDefaults?
    var sidebarShown: Bool { didSet { save(sidebarShown, "ipadSidebarShown") } }
    /// The Mac's Show Address Bar: a band over the page card; off, the
    /// address is a plate in the sidebar, as the Mac's default.
    var addressBars: Bool { didSet { save(addressBars, "ipadAddressBar") } }
    /// The Mac's Show Tabs in Sidebar: off, the tabs go across the top.
    var tabsInSidebar: Bool { didSet { save(tabsInSidebar, "ipadTabsInSidebar") } }
    var framed: Bool { didSet { save(framed, "ipadPageFrame") } }
    private(set) var sidebarWidth: CGFloat
    private(set) var splitFraction: CGFloat

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            defaults?.object(forKey: key) == nil ? fallback : defaults!.bool(forKey: key)
        }
        sidebarShown = flag("ipadSidebarShown", true)
        // A new key: the old one defaulted to the band the Mac keeps off.
        addressBars = flag("ipadAddressBar", false)
        tabsInSidebar = flag("ipadTabsInSidebar", true)
        framed = flag("ipadPageFrame", true)
        let width = defaults?.object(forKey: "ipadSidebarWidth") as? Double ?? Double(Metrics.Tablet.sidebar)
        sidebarWidth = Self.width(CGFloat(width))
        let fraction = defaults?.object(forKey: "ipadSplitFraction") as? Double ?? 0.5
        splitFraction = Self.fraction(CGFloat(fraction))
    }

    func resizeSidebar(to width: CGFloat, save: Bool = true) {
        sidebarWidth = Self.width(width)
        if save { self.save(Double(sidebarWidth), "ipadSidebarWidth") }
    }

    func resizeSplit(to fraction: CGFloat, save: Bool = true) {
        splitFraction = Self.fraction(fraction)
        if save { self.save(Double(splitFraction), "ipadSplitFraction") }
    }

    private static func width(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(Metrics.Tablet.sidebarMaximum, max(Metrics.Tablet.sidebarMinimum, value)) : Metrics.Tablet.sidebar
    }
    private static func fraction(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(0.85, max(0.15, value)) : 0.5
    }
    private func save(_ value: Any, _ key: String) { defaults?.set(value, forKey: key) }
}

/// A generous hit area around a thin divider, for a finger and a pointer alike.
struct TabletResizeHandle: View {
    let label: String
    let identifier: String
    let value: CGFloat
    let changed: (CGFloat, Bool) -> Void
    @State private var start: CGFloat?
    @State private var hovered = false
    @GestureState private var dragging = false

    var body: some View {
        Color.clear
            .overlay {
                Capsule().fill(Ink.primary.opacity(hovered || start != nil ? 0.45 : 0.2))
                    .frame(width: 3, height: 32)
            }
            .frame(width: Metrics.Tablet.resizeTarget)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).updating($dragging) { _, active, _ in
                active = true
            }.onChanged { drag in
                if start == nil { start = value }
                changed((start ?? value) + drag.translation.width, false)
            }.onEnded { drag in
                changed((start ?? value) + drag.translation.width, true)
                start = nil
            })
            .onChange(of: dragging) { _, active in if !active { start = nil } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(value.rounded()))")
            .accessibilityIdentifier(identifier)
            .accessibilityAdjustableAction { direction in
                changed(value + (direction == .increment ? 20 : -20), true)
            }
    }
}
