import Foundation
import Testing
import WebKit
import SyncKit
@testable import Fast

/// #220: the unused built-in Personal beside two imported Dia profiles.
/// Every file and cookie below belongs to an isolated test world.
@MainActor
@Suite(.serialized)
struct ProfileDeletionTests {
    private func world(_ check: (Browser, Space, Space) throws -> Void) throws {
        try #require(Store.testing)
        Session.settle()
        let saved = Spaces.read(), sharing = Spaces.sharing, current = Spaces.current
        let settings = Store.settings
        let keys = ["spaces", "space.current", "spaces.erasing-soon", "spaces.erasing", "pins.everySpace"]
        let kept = keys.map { ($0, settings.object(forKey: $0)) }
        let files = ["session.json", "session-\(Space.pinsID.uuidString).json"]
            .map { (Store.file($0), try? Data(contentsOf: Store.file($0))) }
        let personal = Space(id: UUID(), name: "Dia Personal", icon: "🏠", ownSignIns: true,
                             origin: "Dia:Default", signedInAs: "Dia:Default")
        let work = Space(id: UUID(), name: "Work", icon: "💼", ownSignIns: true,
                         origin: "Dia:Profile 1", signedInAs: "Dia:Profile 1")
        let initial = Space(id: Space.firstID, name: "Personal", icon: "🏠", ownSignIns: false)
        settings.set(false, forKey: "pins.everySpace")
        Spaces.write([initial, personal, work])
        let browser = Browser(windowID: UUID())
        browser.prefs.usesSpaces = true
        browser.spaces = [initial, personal, work]
        browser.spaceID = initial.id
        Spaces.sharing = [initial.id]
        browser.lay([])
        defer {
            browser.letGo()
            Spaces.write(saved); Spaces.sharing = sharing; Spaces.current = current
            for (key, value) in kept { settings.set(value, forKey: key) }
            // Restoring the list can switch the fixture window and queue
            // one final row write. Drain it before removing its files.
            Session.settle()
            for id in [initial.id, personal.id, work.id] {
                let suffix = id == Space.firstID ? "" : "-\(id.uuidString)"
                try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString)\(suffix).json"))
            }
            Session.erase(space: personal.id); Session.erase(space: work.id)
            settings.removeObject(forKey: "window.\(browser.windowID!.uuidString).space")
            for (url, data) in files {
                if let data { try? data.write(to: url, options: .atomic) }
                else { try? FileManager.default.removeItem(at: url) }
            }
        }
        try check(browser, personal, work)
    }

    @Test func deletesBuiltInAndKeepsBothImportedProfilesAndStores() throws {
        try world { browser, personal, work in
            let homeStore = Spaces.store(for: Space.firstID)
            let personalStore = Spaces.store(for: personal.id), workStore = Spaces.store(for: work.id)
            browser.deleteSpace(Space.firstID)
            #expect(browser.spaces.map(\.id) == [personal.id, work.id])
            #expect(browser.spaces.map(\.signedInAs) == [personal.signedInAs, work.signedInAs])
            #expect(browser.spaceID == personal.id)
            #expect(Spaces.read().map(\.id) == [personal.id, work.id])
            #expect(Spaces.store(for: personal.id) === personalStore)
            #expect(Spaces.store(for: work.id) === workStore)
            #expect(Spaces.store(for: Space.firstID) === homeStore)
            #expect(!(Store.settings.stringArray(forKey: "spaces.erasing") ?? []).contains(Space.firstID.uuidString))
        }
    }

    @Test func deletingInactiveBuiltInKeepsActiveWorkProfile() throws {
        try world { browser, personal, work in
            browser.switchSpace(to: work.id)
            browser.deleteSpace(Space.firstID)
            #expect(browser.spaceID == work.id)
            #expect(browser.spaces.map(\.id) == [personal.id, work.id])
        }
    }

    @Test func lastImportedProfileCannotBeDeleted() throws {
        try world { browser, personal, work in
            browser.deleteSpace(Space.firstID)
            browser.deleteSpace(personal.id)
            browser.deleteSpace(work.id)
            #expect(browser.spaces.map(\.id) == [work.id])
            #expect(browser.spaceID == work.id)
            #expect(Spaces.read().map(\.id) == [work.id])
        }
    }

    @Test func lastBuiltInProfileCannotBeDeleted() throws {
        try world { browser, _, _ in
            browser.spaces = [browser.spaces[0]]
            Spaces.write(browser.spaces)
            browser.deleteSpace(Space.firstID)
            #expect(browser.spaces.count == 1)
            #expect(browser.spaceID == Space.firstID)
        }
    }

    @Test func undoRestoresBuiltInTabsAndSelection() throws {
        try world { browser, personal, _ in
            let tab = Tab()
            tab.restore(url: URL(string: "https://profile-deletion.test/kept")!, title: "Keep me")
            browser.prepare(tab)
            browser.lay([tab]); browser.activeID = tab.id
            browser.deleteSpace(Space.firstID, undoable: true)
            #expect(browser.spaceID == personal.id)
            #expect(!browser.spaces.contains { $0.isFirst })
            #expect(browser.undoWindow())
            #expect(browser.spaces.first?.isFirst == true)
            #expect(browser.spaceID == Space.firstID)
            #expect(browser.pages(in: Space.firstID).map(\.url.absoluteString) == ["https://profile-deletion.test/kept"])
            #expect(!(Store.settings.stringArray(forKey: "spaces.erasing-soon") ?? []).contains(Space.firstID.uuidString))
        }
    }

    @Test func restartWithStaleSelectionUsesAnExistingProfile() throws {
        try world { browser, personal, work in
            Spaces.write([personal, work])
            let id = UUID(), key = "window.\(id.uuidString).space"
            Store.settings.set(Space.firstID.uuidString, forKey: key)
            let reopened = Browser(windowID: id)
            defer { reopened.letGo(); Store.settings.removeObject(forKey: key) }
            #expect(reopened.spaces.map(\.id) == [personal.id, work.id])
            #expect(reopened.spaceID == personal.id)
            #expect(browser.spaces.contains { $0.id == browser.spaceID })
        }
    }

    @Test func turningSpacesOffUsesSurvivingProfile() throws {
        try world { browser, personal, work in
            browser.deleteSpace(Space.firstID)
            browser.switchSpace(to: work.id)
            browser.prefs.usesSpaces = false
            browser.leaveSpaces()
            #expect(browser.spaceID == personal.id)
            #expect(!browser.prefs.usesSpaces)
        }
    }

    @Test func deletingActiveProfileWhileSpacesOffStillSelectsAnother() throws {
        try world { browser, personal, _ in
            browser.prefs.usesSpaces = false
            browser.deleteSpace(Space.firstID)
            #expect(browser.spaceID == personal.id)
            #expect(!browser.prefs.usesSpaces)
        }
    }

    @Test func laterImportNeverTargetsDeletedBuiltIn() throws {
        try world { browser, _, _ in
            browser.deleteSpace(Space.firstID)
            let a = TabImport.Place(id: "Chrome:Default", name: "Chrome Home", profile: "Default", shared: true, isProfile: true, pinned: [], open: [])
            let b = TabImport.Place(id: "Chrome:Profile 1", name: "Chrome Work", profile: "Profile 1", shared: false, isProfile: true, pinned: [], open: [])
            #expect(browser.landing(of: a, among: [a, b], asSpaces: true) == .new)
        }
    }

    @Test func sharedPinsStayReachableWhenSharingIsTurnedOff() throws {
        try world { browser, personal, _ in
            browser.deleteSpace(Space.firstID)
            let pin = Tab()
            pin.restore(url: URL(string: "https://profile-deletion.test/pin")!, title: "Shared pin")
            let key = UUID()
            pin.pin = "a"; pin.everywhere = key
            pin.name = "Keep my name"; pin.customMark = "star"
            browser.prepare(pin)
            browser.pinsShared = true
            browser.parked[Space.pinsID] = Parked(tabs: [pin], active: nil)
            browser.unsharePins(spacesOn: true)
            #expect(browser.spaceID == personal.id)
            let restored = try #require(browser.tabs.first { ($0.pending ?? $0.address)?.absoluteString == "https://profile-deletion.test/pin" })
            #expect(restored.store === Spaces.store(for: personal.id))
            #expect(KeptEverywhere.key(restored) == key)
            #expect(restored.pin == "a" && restored.name == "Keep my name" && restored.customMark == "star")
            #expect(pin.everywhere == nil)
            #expect(browser.parked[Space.firstID] == nil)
        }
    }

    @Test func deletingBuiltInDoesNotClearSharedSignInCookies() async throws {
        try #require(Store.testing)
        let store = Store.websites.httpCookieStore
        let cookie = try #require(HTTPCookie(properties: [.name: "profile220-session", .value: "fixture-only",
                                                         .domain: "profile-deletion.test", .path: "/"]))
        await store.setCookie(cookie)
        defer { Task { @MainActor in await store.deleteCookie(cookie) } }
        try world { browser, _, _ in browser.deleteSpace(Space.firstID) }
        let cookies = await store.allCookies()
        #expect(cookies.contains { $0.name == cookie.name && $0.value == "fixture-only" })
    }

    @Test func syncKeepsSharedPinsWithoutResurrectingDeletedPersonalTabs() throws {
        try world { browser, personal, work in
            browser.deleteSpace(Space.firstID)
            let pin = Session.Entry(url: "https://profile-deletion.test/shared", title: "Shared", pin: "a", id: "shared-pin")
            let old = Session.Entry(url: "https://profile-deletion.test/old", title: "Closed", pin: nil, id: "old-personal-tab")
            Session.write(now: true, space: Space.pinsID, .init(tabs: [pin], active: 0))
            // The original session is deliberately kept as a local backup.
            Session.write(now: true, space: Space.firstID, .init(tabs: [old], active: 0))
            SyncShapes.register()
            let journal = try Journal(path: nil, device: "profile220")
            var flush = SyncCenter.Flush(collections: [SyncShapes.tab])
            flush.rows = [personal.id, work.id]
            // Shared, as SyncCenter.read says while they head the first space.
            flush.pinsShown = true
            try SyncCenter.tell(flush, into: journal)
            #expect(journal.living(SyncShapes.tab).map(\.id) == ["shared-pin"])
            #expect(!Spaces.read().contains { $0.isFirst })
        }
    }
}
