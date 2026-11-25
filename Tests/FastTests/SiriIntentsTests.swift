import Foundation
import Testing
@testable import Fast

@Suite(.serialized)
struct SiriIntentsTests {
    /// Runs `body` with the switch set as asked, and puts it back.
    @MainActor
    private func withSwitch(_ on: Bool?, _ body: () async throws -> Void) async rethrows {
        let key = SystemIntentsBridge.enabledKey
        let original = Store.settings.object(forKey: key)
        defer {
            if let original { Store.settings.set(original, forKey: key) } else { Store.settings.removeObject(forKey: key) }
        }
        if let on { Store.settings.set(on, forKey: key) } else { Store.settings.removeObject(forKey: key) }
        try await body()
    }

    @MainActor
    @Test func siriSettingIsThePersonsAloneAndLivesInShortcuts() {
        let item = SettingsItem.all.first { $0.id == "shortcuts-siri" }
        #expect(item != nil)
        #expect(item?.page == .shortcuts)
        #expect(NativeActions.classification(item!) == "user_only")
        #expect(!NativeSetting.all.contains { $0.id == "shortcuts-siri" })
        #expect(!SettingsItem.all.contains { $0.id == "ai-siri" })
        #expect(!(item?.words ?? "").contains("arc-divergent"))
    }

    @MainActor
    @Test func siriIsOffByDefault() async {
        await withSwitch(nil) {
            #expect(!SystemIntentsBridge.siriEnabled)
            #expect(throws: SystemIntentError.disabled) { try SystemIntentsGuard.check() }
        }
    }

    @MainActor
    @Test func intentsAreAllowedWhenSiriIsOn() async {
        await withSwitch(true) {
            #expect(throws: Never.self) { try SystemIntentsGuard.check() }
        }
    }

    @MainActor
    @Test func intentsRefuseWhenSiriIsOff() async {
        await withSwitch(false) {
            var open = OpenPageIntent()
            open.address = URL(string: "https://example.com")!
            await #expect(throws: SystemIntentError.disabled) { try await open.perform() }
            await #expect(throws: SystemIntentError.disabled) { try await NewTabIntent().perform() }
        }
    }

    @Test func errorsSayWhatHappened() {
        #expect(SystemIntentError.disabled.errorDescription == "Siri & App Intents is off in Yab Settings.")
        #expect(SystemIntentError.invalidAddress.errorDescription == "Enter an HTTP or HTTPS web address.")
    }
}
