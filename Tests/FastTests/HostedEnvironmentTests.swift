import AppKit
import SwiftUI
import Testing
@testable import Fast

private final class Seen {
    var assisted: Bool?
    var scheme: ColorScheme?
}

private struct Reader: View {
    let seen: Seen
    @Environment(\.accessibilityEnabled) private var assisted
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        seen.assisted = assisted
        seen.scheme = scheme
        return Color.clear.frame(width: 10, height: 10)
    }
}

@MainActor
struct HostedEnvironmentTests {
    private func read(_ root: some View) {
        let host = NSHostingView(rootView: AnyView(root))
        host.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        host.layoutSubtreeIfNeeded()
    }

    @Test func aHostKeepsItsOwnAccessibilityAndTakesTheRest() throws {
        _ = NSApplication.shared
        let own = Seen()
        read(Reader(seen: own))
        let assisted = try #require(own.assisted)

        var copied = EnvironmentValues()
        copied.accessibilityEnabled = !assisted
        copied.colorScheme = .dark
        let hosted = Seen()
        read(Reader(seen: hosted).hosted(in: copied))

        #expect(hosted.assisted == assisted)
        #expect(hosted.scheme == .dark)
    }
}
