import Foundation
import Testing
@testable import Fast

@MainActor
struct LinkRouteOrderTests {
    private func withSettings(_ test: (UserDefaults) throws -> Void) throws {
        let suite = "LinkRouteOrderTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        try test(settings)
    }

    @Test func movingChangesTheWinningRuleAndPersists() throws {
        try withSettings { settings in
            let routes = LinkRoutes(settings: settings)
            let home = UUID(), work = UUID()
            routes.set("*abc*", to: home)
            routes.set("*bcd*", to: work)
            routes.set("other.example", to: UUID())
            let url = try #require(URL(string: "https://abcd.example"))
            let original = routes.routes
            routes.manualPriority = true
            #expect(LinkRoutes.best(original, for: url)?.space == home)

            routes.move("*bcd*", to: 0)

            #expect(routes.displayedRoutes.map(\.site) == ["*bcd*", "*abc*", "other.example"])
            #expect(Set(routes.routes.map(\.id)) == Set(original.map(\.id)))
            #expect(routes.routes == routes.displayedRoutes)
            #expect(LinkRoutes.best(routes.routes, for: url)?.space == work)
            #expect(LinkRoutes.destination(routes: routes.routes, for: url, available: [home, work], recent: home, fallback: home) == work)
            #expect(LinkRoutes.pageLinkDestination(routes: routes.routes, for: url, available: [home, work], current: home) == work)
            let reopened = LinkRoutes(settings: settings)
            #expect(reopened.displayedRoutes == routes.displayedRoutes)
            #expect(LinkRoutes.best(reopened.routes, for: url)?.space == work)
            routes.move("*bcd*", to: 2)
            #expect(LinkRoutes.best(routes.routes, for: url)?.space == home)
        }
    }

    @Test func newRulesAppendAndEditedRulesKeepTheirPlace() throws {
        try withSettings { settings in
            let routes = LinkRoutes(settings: settings)
            let space = UUID()
            routes.manualPriority = true
            routes.set("first.example", to: space)
            routes.set("second.example", to: space)
            routes.move("second.example", to: 0)
            routes.set("third.example", to: space)
            routes.replace("second.example", with: "renamed.example", to: UUID())
            #expect(routes.displayedRoutes.map(\.site) == ["renamed.example", "first.example", "third.example"])
            #expect(LinkRoutes(settings: settings).displayedRoutes == routes.displayedRoutes)
        }
    }

    @Test(arguments: [0, 2])
    func mergingRulesKeepsTheEditedRulesDisplayPosition(destination: Int) throws {
        try withSettings { settings in
            let routes = LinkRoutes(settings: settings)
            let space = UUID()
            routes.manualPriority = true
            for site in ["first.example", "edited.example", "last.example"] { routes.set(site, to: space) }
            let target = routes.displayedRoutes[destination].site
            routes.replace("edited.example", with: target, to: space)
            let expected = destination == 0 ? [target, "last.example"] : ["first.example", target]
            #expect(routes.displayedRoutes.map(\.site) == expected)
            #expect(Set(routes.displayOrder).count == routes.displayOrder.count)
        }
    }

    @Test func removingRulesAndSpacesCleansTheirDisplayOrder() throws {
        try withSettings { settings in
            let routes = LinkRoutes(settings: settings)
            let home = UUID(), work = UUID()
            routes.set("home.example", to: home)
            routes.set("work.example", to: work)
            routes.set("removed.example", to: home)
            routes.manualPriority = true
            routes.move("work.example", to: 0)
            routes.remove("removed.example")
            #expect(routes.displayOrder == ["work.example", "home.example"])
            routes.forget(space: work)
            #expect(routes.displayOrder == ["home.example"])
            #expect(LinkRoutes(settings: settings).displayOrder == ["home.example"])
        }
    }

    @Test func staleAndDuplicateSavedOrderEntriesAreIgnored() throws {
        try withSettings { settings in
            let rules = [LinkRoute(site: "first.example", space: UUID()), LinkRoute(site: "second.example", space: UUID())]
            settings.set(try JSONEncoder().encode(rules), forKey: LinkRoutes.key)
            #expect(LinkRoutes(settings: settings).displayedRoutes.map(\.id) == rules.reversed().map(\.id))
            settings.set(["gone.example", "second.example", "second.example"], forKey: "links.routes.display-order")
            let routes = LinkRoutes(settings: settings)
            routes.manualPriority = true
            #expect(routes.displayedRoutes.map(\.site) == ["second.example", "first.example"])
            routes.move("missing.example", to: 0)
            #expect(routes.routes.map(\.id) == rules.reversed().map(\.id))
            routes.move("first.example", to: -1)
            #expect(routes.displayOrder == ["first.example", "second.example"])
            routes.move("first.example", to: 100)
            #expect(routes.displayOrder == ["second.example", "first.example"])
        }
    }

    @Test func legacyRulesMigrateToTheirPreviousPriorityOnce() throws {
        try withSettings { settings in
            let home = UUID(), work = UUID()
            let rules = [
                LinkRoute(site: "example.com", space: home),
                LinkRoute(site: "docs.example.com", space: work),
                LinkRoute(site: "docs.example.com/work", space: home),
                LinkRoute(site: "*example*", space: work),
                LinkRoute(site: "*docs.example*", space: home),
            ]
            settings.set(try JSONEncoder().encode(rules), forKey: LinkRoutes.key)
            let routes = LinkRoutes(settings: settings)
            #expect(routes.displayOrder == ["*docs.example*", "*example*", "docs.example.com/work", "docs.example.com", "example.com"])
            let url = try #require(URL(string: "https://docs.example.com/work/task"))
            #expect(LinkRoutes.best(routes.routes, for: url)?.site == "*docs.example*")
            routes.manualPriority = true
            routes.move("example.com", to: 0)
            let reopened = LinkRoutes(settings: settings)
            #expect(reopened.displayOrder.first == "example.com")
            #expect(LinkRoutes.best(reopened.routes, for: url)?.space == home)
        }
    }

    @Test func movingASiteAboveAPatternChangesPriorityAndWindowChoice() throws {
        try withSettings { settings in
            let home = UUID(), work = UUID()
            let rules = [
                LinkRoute(site: "*example*", space: work, opensInMain: true),
                LinkRoute(site: "example.com", space: home),
            ]
            settings.set(try JSONEncoder().encode(rules), forKey: LinkRoutes.key)
            let routes = LinkRoutes(settings: settings)
            let url = try #require(URL(string: "https://example.com/"))
            #expect(LinkRoutes.opensInMain(routes.routes, for: url))
            routes.manualPriority = true
            routes.move("example.com", to: 0)
            #expect(LinkRoutes.best(routes.routes, for: url)?.space == home)
            #expect(!LinkRoutes.opensInMain(routes.routes, for: url))
            #expect(LinkRoutes(settings: settings).routes == routes.routes)
        }
    }

    @Test func legacyEqualPriorityRulesKeepTheirPreviousWinner() throws {
        try withSettings { settings in
            let rules = [LinkRoute(site: "*abc*", space: UUID()), LinkRoute(site: "*bcd*", space: UUID())]
            settings.set(try JSONEncoder().encode(rules), forKey: LinkRoutes.key)
            let routes = LinkRoutes(settings: settings)
            #expect(routes.routes.map(\.id) == rules.map(\.id))
            #expect(LinkRoutes.best(routes.routes, for: try #require(URL(string: "https://abcd.example")))?.space == rules.first?.space)
        }
    }

    @Test func turningManualPriorityOffRestoresTheOriginalTieWinner() throws {
        try withSettings { settings in
            let routes = LinkRoutes(settings: settings), first = UUID(), second = UUID()
            let url = try #require(URL(string: "https://abcd.example"))
            routes.set("*abc*", to: first)
            routes.set("*bcd*", to: second)
            routes.manualPriority = true
            routes.move("*bcd*", to: 0)
            #expect(LinkRoutes.best(routes.displayedRoutes, for: url)?.space == second)
            routes.manualPriority = false
            #expect(LinkRoutes.best(routes.displayedRoutes, for: url)?.space == first)
            let reopened = LinkRoutes(settings: settings)
            #expect(LinkRoutes.best(reopened.displayedRoutes, for: url)?.space == first)
            reopened.manualPriority = true
            #expect(LinkRoutes.best(reopened.displayedRoutes, for: url)?.space == second)
        }
    }

    @Test func legacyRenamePreservesOriginalTieAfterRestart() throws {
        try withSettings { settings in
            let first = UUID(), second = UUID()
            let legacy = [LinkRoute(site: "*z*", space: first), LinkRoute(site: "*bcd*", space: second)]
            settings.set(try JSONEncoder().encode(legacy), forKey: LinkRoutes.key)
            let routes = LinkRoutes(settings: settings)
            routes.replace("*z*", with: "*abc*", to: first)
            let url = try #require(URL(string: "https://abcd.example"))
            let reopened = LinkRoutes(settings: settings)
            #expect(LinkRoutes.best(reopened.displayedRoutes, for: url)?.space == first)
            reopened.manualPriority = true
            #expect(LinkRoutes.best(reopened.displayedRoutes, for: url)?.space == second)
        }
    }

    @Test(arguments: [false, true]) func olderWriterKeepsEstablishedPriority(coldStart: Bool) throws {
        try withSettings { settings in
            let routes = LinkRoutes(settings: settings), home = UUID(), work = UUID(), changed = UUID()
            routes.set("docs.example.com", to: work)
            routes.set("example.com", to: home)
            routes.set("deleted.example", to: work)
            routes.manualPriority = true
            routes.move("example.com", to: 0)
            let newerOrder = settings.data(forKey: LinkRoutes.key)
            let legacy = [LinkRoute(site: "docs.example.com", space: work), LinkRoute(site: "added.example", space: home),
                          LinkRoute(site: "example.com", space: changed, opensInMain: true)]
            settings.set(try JSONEncoder().encode(legacy), forKey: LinkRoutes.key)
            let live = coldStart ? LinkRoutes(settings: settings) : routes
            if !coldStart { live.adoptSyncedSettings([LinkRoutes.key]) }
            let url = try #require(URL(string: "https://docs.example.com"))
            #expect(live.displayOrder == ["example.com", "docs.example.com", "added.example"])
            #expect(LinkRoutes.best(live.displayedRoutes, for: url)?.space == changed)
            #expect(live.opensInMain(for: url))
            let removed = live.forget(space: changed)
            live.bringBack(removed, kept: [])
            let reopened = LinkRoutes(settings: settings)
            #expect(LinkRoutes.best(reopened.displayedRoutes, for: url)?.space == changed)
            reopened.manualPriority = false
            #expect(LinkRoutes.best(reopened.displayedRoutes, for: url)?.space == work)
            reopened.manualPriority = true
            reopened.move("docs.example.com", to: 0)
            settings.set(newerOrder, forKey: LinkRoutes.key)
            reopened.adoptSyncedSettings([LinkRoutes.key])
            #expect(LinkRoutes.best(reopened.displayedRoutes, for: url)?.space == home)
        }
    }

    @Test func localEditKeepsLiveSyncedOrder() throws {
        try withSettings { sender in
            let routes = LinkRoutes(settings: sender), work = UUID(), home = UUID()
            routes.set("docs.example.com", to: work)
            routes.set("example.com", to: home)
            let original = try #require(sender.data(forKey: LinkRoutes.key))
            routes.manualPriority = true
            routes.move("example.com", to: 0)
            let received = try #require(sender.data(forKey: LinkRoutes.key))
            try withSettings { receiver in
                receiver.set(original, forKey: LinkRoutes.key)
                let live = LinkRoutes(settings: receiver)
                receiver.set(received, forKey: LinkRoutes.key)
                receiver.set(true, forKey: LinkRoutes.manualKey)
                live.adoptSyncedSettings([LinkRoutes.key, LinkRoutes.manualKey])
                #expect(live.manualPriority)
                #expect(live.displayOrder == ["example.com", "docs.example.com"])
                live.set("other.example", to: work)
                #expect(LinkRoutes(settings: receiver).displayOrder == ["example.com", "docs.example.com", "other.example"])
            }
        }
    }

    @Test func undoSpaceDeletionRestoresInterleavedPriorities() throws {
        try withSettings { settings in
            let routes = LinkRoutes(settings: settings), work = UUID(), home = UUID()
            routes.manualPriority = true
            routes.set("docs.example.com", to: work)
            routes.set("example.com", to: home)
            routes.set("other.example", to: work)
            routes.setMainWindow("docs.example.com", enabled: true)
            let before = routes.routes, url = try #require(URL(string: "https://docs.example.com"))
            let removed = routes.forget(space: work)
            #expect(!routes.opensInMain(for: url))
            routes.bringBack(removed, kept: [])
            let reopened = LinkRoutes(settings: settings)
            #expect(reopened.routes == before)
            #expect(reopened.opensInMain(for: url))
            #expect(LinkRoutes.best(reopened.displayedRoutes, for: url)?.space == work)
        }
    }

    @Test(arguments: [false, true]) func syncedPrioritySurvivesRestart(stale: Bool) throws {
        try withSettings { sender in
            let routes = LinkRoutes(settings: sender), home = UUID(), work = UUID()
            routes.set("docs.example.com", to: work)
            routes.set("example.com", to: home)
            routes.setMainWindow("docs.example.com", enabled: true)
            routes.manualPriority = true
            routes.move("example.com", to: 0)
            try withSettings { receiver in
                if stale { receiver.set(["docs.example.com", "example.com"], forKey: "links.routes.display-order") }
                receiver.set(sender.data(forKey: LinkRoutes.key), forKey: LinkRoutes.key)
                let received = LinkRoutes(settings: receiver)
                let url = try #require(URL(string: "https://docs.example.com"))
                #expect(!received.manualPriority)
                #expect(received.opensInMain(for: url))
                receiver.set(sender.bool(forKey: LinkRoutes.manualKey), forKey: LinkRoutes.manualKey)
                let reopened = LinkRoutes(settings: receiver)
                #expect(reopened.displayedRoutes == routes.routes)
                #expect(!reopened.opensInMain(for: url))
                reopened.manualPriority = false
                #expect(reopened.opensInMain(for: url))
                reopened.manualPriority = true
                #expect(!reopened.opensInMain(for: url))
            }
        }
    }
}
