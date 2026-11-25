import Foundation

/// What the App Intents in SystemIntents.swift ask of the app. build.sh
/// compiles that file alone, to extract the intents' metadata, with a stub of
/// this enum; the real one lives here, where the settings are.
enum SystemIntentsBridge {
    static let enabledKey = "ai.siri.enabled"

    /// Settings › Shortcuts › Siri & App Intents. Off until the person turns it on.
    static var siriEnabled: Bool { Store.settings.bool(forKey: enabledKey) }
}
