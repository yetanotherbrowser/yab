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

    @Test func movingPersistsWithoutChangingRulesOrTheirWinner() throws {
        try withSettings { settings in
            let routes = LinkRoutes(settings: settings)
            routes.set("*abc*", to: UUID())
            routes.set("*bcd*", to: UUID())
            routes.set("other.example", to: UUID())
            let url = try #require(URL(string: "https://abcd.example"))
            let original = routes.routes
            let winner = LinkRoutes.best(original, for: url)
            let saved = settings.data(forKey: LinkRoutes.key)

            routes.move("*bcd*", to: 0)

            #expect(routes.displayedRoutes.map(\.site) == ["*bcd*", "*abc*", "other.example"])
            #expect(routes.routes == original)
            #expect(settings.data(forKey: LinkRoutes.key) == saved)
            #expect(LinkRoutes.best(routes.routes, for: url) == winner)
            let reopened = LinkRoutes(settings: settings)
            #expect(reopened.displayedRoutes == routes.displayedRoutes)
            #expect(LinkRoutes.best(reopened.routes, for: url) == winner)
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

    @Test func legacyRulesKeepTheirOrderAndStaleDisplayEntriesAreIgnored() throws {
        try withSettings { settings in
            let rules = [LinkRoute(site: "first.example", space: UUID()), LinkRoute(site: "second.example", space: UUID())]
            settings.set(try JSONEncoder().encode(rules), forKey: LinkRoutes.key)
            #expect(LinkRoutes(settings: settings).displayedRoutes == rules)
            settings.set(["gone.example", "second.example", "second.example"], forKey: LinkRoutes.displayOrderKey)
            let routes = LinkRoutes(settings: settings)
            #expect(routes.displayedRoutes.map(\.site) == ["second.example", "first.example"])
            routes.move("missing.example", to: 0)
            #expect(routes.routes == rules)
            routes.move("first.example", to: -1)
            #expect(routes.displayOrder == ["first.example", "second.example"])
            routes.move("first.example", to: 100)
            #expect(routes.displayOrder == ["second.example", "first.example"])
        }
    }
}
