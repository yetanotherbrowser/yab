import Foundation
import Testing
@testable import Fast

// Links from other apps kept to a space: what a typed rule becomes, and
// which route takes an address in Settings order.
struct LinkRouteTests {
    static let work = UUID()
    static let home = UUID()

    @Test func externalMainWindowChoiceUsesOnlyTheWinningRule() throws {
        let docs = try #require(URL(string: "https://docs.google.com/document/d/public-example/edit"))
        let route = LinkRoute(site: "docs.google.com", space: Self.work, opensInMain: true)
        #expect(LinkRoutes.opensInMain([route], for: docs))
        #expect(!LinkRoutes.opensInMain([], for: docs))
        #expect(!LinkRoutes.opensInMain([LinkRoute(site: "docs.google.com", space: Self.work)], for: docs))
        #expect(!LinkRoutes.opensInMain([route], for: URL(string: "https://docs.google.com.evil.test/")!))
        #expect(!LinkRoutes.opensInMain([route], for: URL(string: "ftp://docs.google.com/a")!))
        let narrower = LinkRoute(site: "docs.google.com/document", space: Self.home)
        #expect(LinkRoutes.opensInMain([route, narrower], for: docs))
        #expect(!LinkRoutes.opensInMain([narrower, route], for: docs))
        let pattern = LinkRoute(site: "*public-example*", space: Self.home, opensInMain: true)
        #expect(!LinkRoutes.opensInMain([narrower, pattern], for: docs))
        #expect(LinkRoutes.opensInMain([pattern, narrower], for: docs))
        #expect(LinkRoutes.best([route], for: docs)?.space == Self.work)
    }

    /// Feedback #1305: Teams hands Yab its Safe Links page, the link in its
    /// `url` query; a gitlab.com rule takes it, and the page still opens.
    @Test func safeLinksPagesAreRoutedByTheLinkTheyCarry() throws {
        let gitlab = LinkRoute(site: "gitlab.com", space: Self.work)
        let available = [Self.work, Self.home]
        let wrapped = [
            "https://teams.public.onecdn.static.microsoft/evergreen-assets/safelinks/2/atp-safelinks.html?url=https%3A%2F%2Fgitlab.com%2Fgroup%2Fproject%2F-%2Fmerge_requests%2F12&locale=en-us&dest=https%3A%2F%2Fteams.microsoft.com%2Fv2%2F&pc=abc",
            "https://statics.teams.cdn.office.net/evergreen-assets/safelinks/1/atp-safelinks.html?url=https%3A%2F%2Fgitlab.com%2F&locale=en-us",
            "https://nam01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fwww.gitlab.com%2Fa&data=05%7C01&sdata=x&reserved=0",
        ]
        for address in wrapped {
            let url = try #require(URL(string: address))
            #expect(LinkRoutes.best([gitlab], for: url)?.space == Self.work, "\(address)")
            #expect(LinkRoutes.destination(routes: [gitlab], for: url, available: available, recent: Self.home, fallback: Self.home) == Self.work)
        }
        let pattern = LinkRoute(site: "*merge_requests*", space: Self.home)
        #expect(LinkRoutes.best([pattern, gitlab], for: URL(string: wrapped[0])!)?.space == Self.home)
        // The page itself is what opens: only the rule looks through it.
        #expect(LinkRoutes.carried(URL(string: wrapped[1])!).absoluteString == "https://gitlab.com/")
        // Not a checker's page, or nothing to carry: matched as it is.
        for address in [
            "https://teams.public.onecdn.static.microsoft/evergreen-assets/other.html?url=https%3A%2F%2Fgitlab.com",
            "https://example.com/redirect?url=https%3A%2F%2Fgitlab.com",
            "https://statics.teams.cdn.office.net/evergreen-assets/safelinks/1/atp-safelinks.html?url=javascript%3Aalert(1)",
            "https://nam01.safelinks.protection.outlook.com/?data=05",
        ] {
            #expect(LinkRoutes.best([gitlab], for: URL(string: address)!) == nil, "\(address)")
        }
    }

    @Test func oldRulesKeepTheirWindowBehaviorAndEditsRetainAnExplicitChoice() throws {
        let bytes = Data("[{\"site\":\"docs.google.com\",\"space\":\"\(Self.work.uuidString)\"}]".utf8)
        let old = try JSONDecoder().decode([LinkRoute].self, from: bytes)
        #expect(old.first?.opensInMain == nil)
        let route = LinkRoute(site: "docs.google.com", space: Self.work, opensInMain: true)
        let copied = try JSONDecoder().decode(LinkRoute.self, from: JSONEncoder().encode(route))
        #expect(copied == route)
        let edited = LinkRoutes.replacing([route], "docs.google.com", with: "docs.google.com/document", to: Self.home)
        #expect(edited.first?.opensInMain == true)
        #expect(edited.first?.space == Self.home)
        #expect(edited.first?.site == "docs.google.com/document")
    }

    @Test func fallbackOnlyAppliesWhenNoRuleMatches() {
        let url = URL(string: "https://example.invalid/")!
        let available = [Self.work, Self.home]
        let rule = LinkRoute(site: "example.invalid", space: Self.work)
        #expect(LinkRoutes.destination(routes: [rule], for: url, available: available, recent: Self.home, fallback: Self.home) == Self.work)
        #expect(LinkRoutes.destination(routes: [], for: url, available: available, recent: Self.home, fallback: Self.work) == Self.work)
        #expect(LinkRoutes.destination(routes: [], for: url, available: available, recent: Self.home, fallback: nil) == nil)
        #expect(LinkRoutes.destination(routes: [rule], for: url, available: [Self.home], recent: Self.home, fallback: Self.home) == nil)
        #expect(LinkRoutes.destination(routes: [], for: url, available: available, recent: Self.home, fallback: UUID()) == nil)
        #expect(LinkRoutes.destination(routes: [], for: URL(string: "mailto:someone@example.invalid")!, available: available, recent: Self.home, fallback: Self.work) == nil)
    }

    @Test func recentDestinationUsesEachRequestsCapturedSpace() {
        let url = URL(string: "https://example.invalid/")!
        let available = [Self.work, Self.home]
        let rule = LinkRoute(site: "example.invalid", space: LinkRoutes.recentSpaceID)
        for captured in available {
            #expect(LinkRoutes.destination(routes: [rule], for: url, available: available, recent: captured, fallback: nil) == captured)
            #expect(LinkRoutes.destination(routes: [], for: url, available: available, recent: captured, fallback: LinkRoutes.recentSpaceID) == captured)
        }
        #expect(LinkRoutes.destination(routes: [rule], for: url, available: available, recent: nil, fallback: Self.home) == nil)
    }

    @Test func typedSites() {
        #expect(LinkRoutes.site(from: "linear.app") == "linear.app")
        #expect(LinkRoutes.site(from: " https://www.Linear.app/ ") == "linear.app")
        #expect(LinkRoutes.site(from: "https://docs.google.com/spreadsheets/d/1xY/edit?usp=sharing#gid=0")
            == "docs.google.com/spreadsheets/d/1xy/edit")
        #expect(LinkRoutes.site(from: "github.com/Acme/") == "github.com/acme")
        #expect(LinkRoutes.site(from: "localhost:3000") == "localhost")
        #expect(LinkRoutes.site(from: "linear") == "*linear*")
        #expect(LinkRoutes.site(from: "two words") == nil)
        #expect(LinkRoutes.site(from: "") == nil)
    }

    @Test func typedWordsAndPatterns() {
        #expect(LinkRoutes.site(from: " Megatron ") == "*megatron*")
        #expect(LinkRoutes.site(from: "*.Megatron.dev") == "*.megatron.dev")
        #expect(LinkRoutes.site(from: "github.com/megatron-*") == "github.com/megatron-*")
        #expect(LinkRoutes.site(from: "*Megatron*") == "*megatron*")
        #expect(LinkRoutes.site(from: "HTTPS://www.GitHub.com/Me%67atron-*?q=YES#fragment")
            == "github.com/megatron-*?q=yes")
        #expect(LinkRoutes.site(from: "*") == nil)
        #expect(LinkRoutes.site(from: "**") == nil)
        #expect(LinkRoutes.site(from: "***#fragment") == nil)
        #expect(LinkRoutes.site(from: "two words") == nil)
        #expect(LinkRoutes.site(from: "two\twords") == nil)
        #expect(LinkRoutes.site(from: "two\nwords") == nil)
        #expect(LinkRoutes.site(from: "*two%20words*") == nil)
        #expect(LinkRoutes.site(from: "https://linear") == nil)
        #expect(LinkRoutes.site(from: "localhost") == "localhost")
    }

    @Test func copiedUrlPatternsUseTheMatchersAuthority() throws {
        let site = try #require(LinkRoutes.site(from:
            "https://User:Pass@www.GitHub.com:443/Me%67atron-*?Q=%5Btest%5D%2B#ignored"))
        #expect(site == "github.com/megatron-*?q=[test]+")
        let routes = [LinkRoute(site: site, space: Self.work)]
        let url = URL(string: "https://user:pass@www.GitHub.com:443/megatron-api?q=%5Btest%5D%2B#other")!
        #expect(LinkRoutes.best(routes, for: url)?.space == Self.work)
        let hashes = try #require(LinkRoutes.site(from: "https://user:pass@github.com:443/megatron%23*?q=%23value#ignored"))
        #expect(hashes == "github.com/megatron#*?q=#value")
        #expect(LinkRoutes.best([LinkRoute(site: hashes, space: Self.work)],
                               for: URL(string: "https://github.com/megatron%23api?q=%23value#other")!)?.space == Self.work)
        #expect(LinkRoutes.site(from: "https://user:pass@www.GitHub.com:443/Acme/") == "github.com/acme")
        #expect(LinkRoutes.site(from: "https://*.Megatron.dev/*") == "*.megatron.dev/*")
        #expect(LinkRoutes.site(from: "*[test]+*") == "*[test]+*")
        #expect(LinkRoutes.site(from: "github.com/*?q=[test]+") == "github.com/*?q=[test]+")
    }

    @Test func wordsMatchHostPathAndQuery() {
        let routes = [LinkRoute(site: "*megatron*", space: Self.work)]
        for address in [
            "https://megatron.example.com/",
            "https://github.com/acme/megatron/pull/1",
            "https://github.com/search?q=megatron",
            "https://www.GitHub.com/ACME/MEGATRON",
            "https://github.com/%6Degatron",
            "https://github.com/search?q=%4DeGaTrOn",
        ] {
            #expect(LinkRoutes.best(routes, for: URL(string: address)!)?.space == Self.work)
        }
        #expect(LinkRoutes.best(routes, for: URL(string: "https://github.com/acme#megatron")!) == nil)
        #expect(LinkRoutes.best(routes, for: URL(string: "megatron://github.com/acme")!) == nil)
        #expect(LinkRoutes.best(routes, for: URL(string: "https://github.com/acme")!) == nil)
    }

    @Test func wildcardPositionsAndAddressBoundaries() {
        let subdomain = [LinkRoute(site: "*.megatron.dev", space: Self.work)]
        #expect(LinkRoutes.best(subdomain, for: URL(string: "https://docs.megatron.dev")!) != nil)
        #expect(LinkRoutes.best(subdomain, for: URL(string: "https://docs.megatron.dev/")!) != nil)
        #expect(LinkRoutes.best(subdomain, for: URL(string: "https://docs.megatron.dev/path")!) == nil)
        let pages = [LinkRoute(site: "*.megatron.dev*", space: Self.work)]
        #expect(LinkRoutes.best(pages, for: URL(string: "https://docs.megatron.dev/path")!) != nil)

        let suffix = [LinkRoute(site: "github.com/megatron-*", space: Self.work)]
        #expect(LinkRoutes.best(suffix, for: URL(string: "https://www.github.com/megatron-api/pull/1")!) != nil)
        #expect(LinkRoutes.best(suffix, for: URL(string: "https://github.com/megatron-")!) != nil)
        #expect(LinkRoutes.best(suffix, for: URL(string: "https://notgithub.com/megatron-api")!) == nil)

        let middle = [LinkRoute(site: "github.com/*/pull/1", space: Self.work)]
        #expect(LinkRoutes.best(middle, for: URL(string: "https://github.com/acme/megatron/pull/1")!) != nil)
        #expect(LinkRoutes.best(middle, for: URL(string: "https://github.com/acme/megatron/pull/12")!) == nil)
    }

    @Test func normalizedAddressIncludesQueryButNotFragmentOrWww() {
        let routes = [LinkRoute(site: "*github.com/acme?q=megatron", space: Self.work),
                      LinkRoute(site: "github.com", space: Self.home)]
        #expect(LinkRoutes.best(routes, for: URL(string: "https://www.GITHUB.com/ACME?q=%6Degatron#other")!)?.space == Self.work)
        let www = [LinkRoute(site: "*www.github.com*", space: Self.work)]
        #expect(LinkRoutes.best(www, for: URL(string: "https://www.github.com/")!) == nil)
        let fragment = [LinkRoute(site: "*other*", space: Self.work)]
        #expect(LinkRoutes.best(fragment, for: URL(string: "https://github.com/acme#other")!) == nil)
    }

    @Test func rootPatternsTreatSlashAsOptional() {
        let pages = [LinkRoute(site: "github.com/*", space: Self.work)]
        let query = [LinkRoute(site: "github.com/*?q=megatron", space: Self.work)]
        let fragment = [LinkRoute(site: "github.com/*#megatron", space: Self.work)]
        for address in ["https://github.com", "https://github.com/"] {
            #expect(LinkRoutes.best(pages, for: URL(string: address)!)?.space == Self.work)
            #expect(LinkRoutes.best(pages, for: URL(string: address + "?q=megatron#other")!)?.space == Self.work)
            #expect(LinkRoutes.best(query, for: URL(string: address + "?q=megatron#other")!)?.space == Self.work)
            #expect(LinkRoutes.best(fragment, for: URL(string: address + "#megatron")!) == nil)
        }
    }

    @Test func firstMatchingRuleWinsAcrossSitesAndPatterns() {
        let routes = [
            LinkRoute(site: "github.com/acme/megatron", space: Self.home),
            LinkRoute(site: "*megatron*", space: Self.work),
            LinkRoute(site: "***mega***", space: Self.home),
        ]
        let url = URL(string: "https://github.com/acme/megatron/pull/1")!
        #expect(LinkRoutes.best(routes, for: url)?.site == "github.com/acme/megatron")
        let narrower = routes + [LinkRoute(site: "github.com/acme/megatron/*", space: Self.home)]
        #expect(LinkRoutes.best(narrower, for: url)?.site == "github.com/acme/megatron")
        #expect(LinkRoutes.best(Array(narrower.reversed()), for: url)?.site == "github.com/acme/megatron/*")
    }

    @Test func globOnlyTreatsStarsAsSpecial() {
        #expect(LinkRoutes.matches("a*b*c", "axybzc"))
        #expect(LinkRoutes.matches("a*b*c", "abc"))
        #expect(LinkRoutes.matches("**a**", "a"))
        #expect(LinkRoutes.matches("a*", "a"))
        #expect(!LinkRoutes.matches("a*b", "ac"))
        #expect(!LinkRoutes.matches("*a", "ab"))
        #expect(LinkRoutes.matches("*?q=[test]+*", "example.com/?q=[test]+x"))
        #expect(!LinkRoutes.matches("*?q=[test]+*", "example.com/?q=t"))
    }

    @Test func patternUsesExistingStorageShape() throws {
        let route = LinkRoute(site: "*megatron*", space: Self.work)
        let encoded = try JSONEncoder().encode(route)
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(fields.keys) == ["site", "space"])
        #expect(try JSONDecoder().decode(LinkRoute.self, from: encoded) == route)
        #expect(route.pattern)
        #expect(!LinkRoute(site: "github.com/acme", space: Self.work).pattern)
    }

    @Test func pageSites() {
        #expect(LinkRoutes.site(of: URL(string: "https://www.figma.com/file/abc")) == "figma.com")
        #expect(LinkRoutes.site(of: URL(string: "mailto:a@b.c")) == nil)
        #expect(LinkRoutes.site(of: nil) == nil)
    }

    @Test func siteTakesItsHostsAndSubdomains() {
        let routes = [LinkRoute(site: "google.com", space: Self.home)]
        #expect(LinkRoutes.best(routes, for: URL(string: "https://www.google.com/search?q=a")!)?.space == Self.home)
        #expect(LinkRoutes.best(routes, for: URL(string: "https://mail.google.com/")!)?.space == Self.home)
        #expect(LinkRoutes.best(routes, for: URL(string: "https://notgoogle.com/")!) == nil)
    }

    @Test func pathTakesOnlyItsPages() {
        let routes = [LinkRoute(site: "github.com/acme", space: Self.work)]
        #expect(LinkRoutes.best(routes, for: URL(string: "https://github.com/acme")!) != nil)
        #expect(LinkRoutes.best(routes, for: URL(string: "https://github.com/Acme/api/pull/4")!) != nil)
        #expect(LinkRoutes.best(routes, for: URL(string: "https://github.com/acmeco")!) == nil)
        #expect(LinkRoutes.best(routes, for: URL(string: "https://github.com/")!) == nil)
    }

    @Test func sitesFollowListOrderRatherThanSpecificity() {
        let routes = [
            LinkRoute(site: "google.com", space: Self.home),
            LinkRoute(site: "docs.google.com", space: Self.work),
            LinkRoute(site: "docs.google.com/spreadsheets", space: Self.home),
        ]
        #expect(LinkRoutes.best(routes, for: URL(string: "https://docs.google.com/document/d/1")!)?.space == Self.home)
        #expect(LinkRoutes.best(routes, for: URL(string: "https://docs.google.com/spreadsheets/d/1")!)?.site == "google.com")
        #expect(LinkRoutes.best(Array(routes.reversed()), for: URL(string: "https://docs.google.com/spreadsheets/d/1")!)?.site == "docs.google.com/spreadsheets")
        #expect(LinkRoutes.best(routes, for: URL(string: "https://youtube.google.com/")!)?.site == "google.com")
    }

    @Test func routeParts() {
        let route = LinkRoute(site: "docs.google.com/spreadsheets", space: Self.work)
        #expect(route.host == "docs.google.com")
        #expect(route.path == "/spreadsheets")
        #expect(LinkRoute(site: "linear.app", space: Self.work).path.isEmpty)
    }
}

// The one site offered a route: kept into one space three times this week,
// not waved away, not routed already, with its space still there.
struct LinkRouteSuggestionTests {
    static let work = UUID()
    static let home = UUID()
    static let now = Date()

    static func kept(_ site: String, _ space: UUID, daysAgo: [Double]) -> [LinkRoutes.Kept] {
        daysAgo.map { LinkRoutes.Kept(site: site, space: space, at: now.addingTimeInterval(-$0 * 24 * 3600)) }
    }

    static func offer(_ kept: [LinkRoutes.Kept], routes: [LinkRoute] = [], declined: Set<String> = [],
                      spaces: Set<UUID> = [work, home]) -> LinkRoutes.Suggestion? {
        LinkRoutes.suggestion(kept: kept, routes: routes, declined: declined, spaces: spaces, now: now)
    }

    @Test func threeTimesThisWeek() {
        #expect(Self.offer(Self.kept("figma.com", Self.work, daysAgo: [1, 2]))  == nil)
        #expect(Self.offer(Self.kept("figma.com", Self.work, daysAgo: [1, 2, 3]))
            == LinkRoutes.Suggestion(site: "figma.com", space: Self.work, times: 3))
    }

    @Test func olderThanAWeekDoesNotCount() {
        #expect(Self.offer(Self.kept("figma.com", Self.work, daysAgo: [1, 2, 8])) == nil)
    }

    @Test func countedPerSpace() {
        let split = Self.kept("figma.com", Self.work, daysAgo: [1, 2]) + Self.kept("figma.com", Self.home, daysAgo: [3, 4])
        #expect(Self.offer(split) == nil)
        let more = split + Self.kept("figma.com", Self.home, daysAgo: [5])
        #expect(Self.offer(more)?.space == Self.home)
    }

    @Test func notWhenDeclinedRoutedOrGone() {
        let kept = Self.kept("figma.com", Self.work, daysAgo: [1, 2, 3])
        #expect(Self.offer(kept, declined: ["figma.com"]) == nil)
        #expect(Self.offer(kept, routes: [LinkRoute(site: "figma.com", space: Self.home)]) == nil)
        #expect(Self.offer(kept, spaces: [Self.home]) == nil)
    }

    @Test func theMostKeptWins() {
        let kept = Self.kept("figma.com", Self.work, daysAgo: [1, 2, 3])
            + Self.kept("notion.so", Self.work, daysAgo: [1, 2, 3, 4])
        #expect(Self.offer(kept)?.site == "notion.so")
    }

    // MARK: - editing a rule

    static let rules = [LinkRoute(site: "linear.app", space: work),
                        LinkRoute(site: "*megatron*", space: home),
                        LinkRoute(site: "figma.com", space: work)]

    @Test func anEditedRuleTakesTheOldOnesPlace() {
        let edited = LinkRoutes.replacing(Self.rules, "*megatron*", with: "github.com/megatron-*", to: Self.work)
        #expect(edited.map(\.site) == ["linear.app", "github.com/megatron-*", "figma.com"])
        #expect(edited[1].space == Self.work)
        #expect(LinkRoutes.best(edited, for: URL(string: "https://megatron.dev/")!) == nil)
    }

    @Test func anEditedRuleKeepsItsTextWhenOnlyTheSpaceChanges() {
        let edited = LinkRoutes.replacing(Self.rules, "linear.app", with: "linear.app", to: Self.home)
        #expect(edited.map(\.site) == Self.rules.map(\.site))
        #expect(edited[0].space == Self.home)
    }

    @Test func anEditTypedAsAnotherRuleMergesTheTwo() {
        let edited = LinkRoutes.replacing(Self.rules, "linear.app", with: "figma.com", to: Self.home)
        #expect(edited == [LinkRoute(site: "figma.com", space: Self.home), LinkRoute(site: "*megatron*", space: Self.home)])
    }

    @Test func anEditOfARuleRemovedMeanwhileAddsIt() {
        let edited = LinkRoutes.replacing(Self.rules, "gone.app", with: "notion.so", to: Self.home)
        #expect(edited.map(\.site) == ["linear.app", "*megatron*", "figma.com", "notion.so"])
    }

    // A link a page opens in a new tab (register 604/865): a rule for
    // example.com takes it from space A to B, as Arc's Air Traffic Control.
    @Test func aPagesNewTabLinkFollowsARuleToAnotherSpace() {
        let a = Self.home, b = Self.work
        let rules = [LinkRoute(site: "example.com", space: b)]
        let link = URL(string: "https://www.example.com/docs?x=1")!
        #expect(LinkRoutes.pageLinkDestination(routes: rules, for: link, available: [a, b], current: a) == b)
        #expect(LinkRoutes.pageLinkDestination(routes: rules, for: URL(string: "http://sub.example.com/")!, available: [a, b], current: a) == b)
        // Already in B: it stays, a tab beside the page as before.
        #expect(LinkRoutes.pageLinkDestination(routes: rules, for: link, available: [a, b], current: b) == nil)
        // No rule for the site, or a site that only ends like it: stays.
        #expect(LinkRoutes.pageLinkDestination(routes: rules, for: URL(string: "https://other.org/")!, available: [a, b], current: a) == nil)
        #expect(LinkRoutes.pageLinkDestination(routes: rules, for: URL(string: "https://notexample.com/")!, available: [a, b], current: a) == nil)
        // A rule whose space was deleted moves nothing.
        #expect(LinkRoutes.pageLinkDestination(routes: rules, for: link, available: [a], current: a) == nil)
        // Only web links: a mailto: or a file stays where it is.
        #expect(LinkRoutes.pageLinkDestination(routes: [LinkRoute(site: "*example*", space: b)],
                                               for: URL(string: "mailto:me@example.com")!, available: [a, b], current: a) == nil)
        // "Most recent space" is the one the page is in: it stays.
        let recent = [LinkRoute(site: "example.com", space: LinkRoutes.recentSpaceID)]
        #expect(LinkRoutes.pageLinkDestination(routes: recent, for: link, available: [a, b], current: a) == nil)
        let both = rules + [LinkRoute(site: "example.com/home", space: a)]
        #expect(LinkRoutes.pageLinkDestination(routes: both, for: URL(string: "https://example.com/home/x")!, available: [a, b], current: a) == b)
        #expect(LinkRoutes.pageLinkDestination(routes: both, for: URL(string: "https://example.com/home/x")!, available: [a, b], current: b) == nil)
    }

    // The fallback space is for links from other apps only: a page's link
    // to a site no rule names stays in the page's space.
    @Test func aPagesLinkNeverTakesTheFallback() {
        let url = URL(string: "https://unruled.example/")!
        #expect(LinkRoutes.destination(routes: [], for: url, available: [Self.home, Self.work], recent: Self.home, fallback: Self.work) == Self.work)
        #expect(LinkRoutes.pageLinkDestination(routes: [], for: url, available: [Self.home, Self.work], current: Self.home) == nil)
    }
}
