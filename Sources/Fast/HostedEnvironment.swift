import SwiftUI

extension View {
    /// The surrounding environment whole, for SwiftUI in a host of our own,
    /// but for whether an assistive app is listening: that is the host's to
    /// know. Copied, it stayed what the window last drew with, false from
    /// launch until something drew again, and the host made no accessibility
    /// tree: Magnet and VoiceOver found nothing in the strip.
    func hosted(in environment: EnvironmentValues) -> some View {
        HostedEnvironment(environment: environment, content: self)
    }
}

private struct HostedEnvironment<Content: View>: View {
    let environment: EnvironmentValues
    let content: Content
    @Environment(\.accessibilityEnabled) private var listening

    var body: some View {
        content
            .environment(\.accessibilityEnabled, listening)
            .environment(\.self, environment)
    }
}
