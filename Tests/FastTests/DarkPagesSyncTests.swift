import Foundation
import Testing
@testable import Fast

/// #755: Dark pages chosen on another Mac reaches this one's settings by
/// sync. The store took it and every new page was darkened, while the live
/// preferences, and so Settings, still said Off.
@MainActor @Suite(.serialized)
struct DarkPagesSyncTests {
    @Test func aModeAndLookFromSyncReachTheLivePreferences() throws {
        let store = Store.settings
        let mode = store.object(forKey: DarkMode.key), look = store.object(forKey: DarkLook.key)
        defer {
            store.set(mode, forKey: DarkMode.key)
            store.set(look, forKey: DarkLook.key)
        }
        store.set(DarkMode.off.rawValue, forKey: DarkMode.key)
        store.removeObject(forKey: DarkLook.key)
        let live = Preferences()
        try #require(live.darkPages == .off && live.darkLook == DarkLook())

        // As SyncCenter takes settings in: the store first, then what a
        // fresh read of it says, into each window's preferences.
        let warm = DarkLook(brightness: 90, contrast: 110, warmth: 20, ground: .black, dimPictures: true)
        store.set(DarkMode.always.rawValue, forKey: DarkMode.key)
        store.set(try JSONEncoder().encode(warm), forKey: DarkLook.key)
        live.adopt(Preferences())

        #expect(live.darkPages == .always)
        #expect(live.darkLook == warm)
        #expect(DarkMode.read(in: store) == .always)
    }
}
