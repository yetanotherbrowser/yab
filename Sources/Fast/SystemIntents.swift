import AppIntents
import Foundation

// build.sh compiles this file alone to extract the App Intents metadata, with
// a stub of what it names beside it. Anything the intents need from the app
// goes through SystemIntentsBridge (SystemIntentsBridge.swift), so the stub
// stays short.

/// Why an intent could not answer, in the words Siri and Shortcuts say.
enum SystemIntentError: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    case disabled
    case invalidAddress

    var errorDescription: String? {
        switch self {
        case .disabled: "Siri & App Intents is off in Yab Settings."
        case .invalidAddress: "Enter an HTTP or HTTPS web address."
        }
    }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .disabled: "Siri & App Intents is off in Yab Settings."
        case .invalidAddress: "Enter an HTTP or HTTPS web address."
        }
    }
}

/// Every intent opens something in Yab only while Siri & App Intents is on.
enum SystemIntentsGuard {
    static func check() throws {
        guard SystemIntentsBridge.siriEnabled else { throw SystemIntentError.disabled }
    }
}

/// Actions for the macOS Shortcuts app. The app's URL and window handoff
/// already handles calls made before its first browser window exists.
struct OpenPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Page in Yab"
    static let description = IntentDescription("Open a web address in Yab.")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Web Address") var address: URL

    @MainActor
    func perform() async throws -> some IntentResult {
        try SystemIntentsGuard.check()
        guard Bookmark.keepable(address) else { throw SystemIntentError.invalidAddress }
        Links.take(address)
        return .result()
    }
}

struct NewTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Tab in Yab"
    static let description = IntentDescription("Open a new tab in Yab.")
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        try SystemIntentsGuard.check()
        Links.requestNewTab()
        return .result()
    }
}

/// The voice shortcuts Siri offers without a shortcut being made by hand.
/// Open Page stays in the Shortcuts app: it needs an address, and nobody
/// says one aloud.
struct YabShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewTabIntent(),
            phrases: [
                "New tab in \(.applicationName)",
                "Open a new tab in \(.applicationName)"
            ],
            shortTitle: "New Tab",
            systemImageName: "plus"
        )
    }
}
