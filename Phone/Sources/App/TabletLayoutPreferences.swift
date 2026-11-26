import Foundation
import Observation
import SwiftUI

/// Local layout choices never travel through sync. Fixture worlds use memory only.
@MainActor @Observable
final class TabletLayoutPreferences {
    @ObservationIgnored private let defaults: UserDefaults?
    var sidebarShown: Bool { didSet { save(sidebarShown, "ipadSidebarShown") } }
    var addressBars: Bool { didSet { save(addressBars, "ipadAddressBars") } }
    var framed: Bool { didSet { save(framed, "ipadPageFrame") } }
    private(set) var sidebarWidth: CGFloat
    private(set) var splitFraction: CGFloat

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            defaults?.object(forKey: key) == nil ? fallback : defaults!.bool(forKey: key)
        }
        sidebarShown = flag("ipadSidebarShown", true)
        addressBars = flag("ipadAddressBars", true)
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
