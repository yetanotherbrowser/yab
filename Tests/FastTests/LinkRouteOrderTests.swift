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
            routes.move("work.example", to: 0)
            routes.remove("removed.example")
            #expect(routes.displayOrder == ["work.example", "home.example"])
            routes.forget(space: work)
            #expect(routes.displayOrder == ["home.example"])
            #expect(settings.stringArray(forKey: LinkRoutes.displayOrderKey) == ["home.example"])
        }
    }

    @Test func staleAndDuplicateSavedOrderEntriesAreIgnored() throws {
        try withSettings { settings in
            let rules = [LinkRoute(site: "first.example", space: UUID()), LinkRoute(site: "second.example", space: UUID())]
            settings.set(try JSONEncoder().encode(rules), forKey: LinkRoutes.key)
            #expect(LinkRoutes(settings: settings).displayedRoutes == Array(rules.reversed()))
            settings.set(["gone.example", "second.example", "second.example"], forKey: LinkRoutes.displayOrderKey)
            let routes = LinkRoutes(settings: settings)
            #expect(routes.displayedRoutes.map(\.site) == ["second.example", "first.example"])
            routes.move("missing.example", to: 0)
            #expect(routes.routes == Array(rules.reversed()))
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
            #expect(routes.routes == rules)
            #expect(LinkRoutes.best(routes.routes, for: try #require(URL(string: "https://abcd.example"))) == rules.first)
        }
    }
}
