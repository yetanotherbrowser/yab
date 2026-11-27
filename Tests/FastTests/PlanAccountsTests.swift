import Foundation
import Testing
@testable import Fast

// Plan accounts: what counts as a plan's limit, how the room left is said,
// and which account a task starts on.
@MainActor
struct PlanAccountsTests {
    @Test func limitsAreKnownByTheirWords() {
        #expect(PlanAccounts.limitWords("You've hit your weekly limit · resets 10pm (America/Los_Angeles)"))
        #expect(PlanAccounts.limitWords("You've hit your usage limit. Upgrade to Pro or try again at 2:05 PM."))
        #expect(PlanAccounts.limitWords("{\"type\":\"error\",\"status\":429,\"error\":{\"type\":\"usage_limit_reached\"}}"))
        #expect(PlanAccounts.limitWords("Your credit balance is too low to access the Anthropic API."))
        #expect(PlanAccounts.limitWords("{\"error\":{\"code\":\"insufficient_quota\"}}"))
        #expect(!PlanAccounts.limitWords("The 'gpt-5.4-mini' model is not supported when using Codex with a ChatGPT account."))
    }

    @Test func claudesEventSaysHowFull() throws {
        let accounts = PlanAccounts.shared
        let now = Date()
        let resets = now.addingTimeInterval(3 * 3600)
        accounts.heard(claude: [
            "status": "allowed",
            "unifiedWindows": [
                "five_hour": ["utilization": 0.2, "resetsAt": now.addingTimeInterval(3600).timeIntervalSince1970],
                "seven_day": ["utilization": 0.49, "resetsAt": resets.timeIntervalSince1970],
            ],
        ], on: "claude.test01")
        #expect(accounts.words("claude.test01", now: now) == "49% of the week used")
        #expect(!accounts.out("claude.test01", now: now))

        accounts.heard(claude: [
            "status": "rejected", "rateLimitType": "five_hour", "resetsAt": resets.timeIntervalSince1970,
            "unifiedWindows": ["five_hour": ["utilization": 1.0, "resetsAt": resets.timeIntervalSince1970]],
        ], on: "claude.test01")
        #expect(accounts.out("claude.test01", now: now))
        let said = try #require(accounts.words("claude.test01", now: now))
        #expect(said.hasPrefix("5-hour limit, back "))
        // Once the window starts over it is back in use.
        #expect(!accounts.out("claude.test01", now: resets.addingTimeInterval(1)))
        #expect(accounts.words("claude.test01", now: resets.addingTimeInterval(1)) == nil)
    }

    @Test func aTaskSkipsTheAccountThatRanOut() {
        let accounts = PlanAccounts.shared
        accounts.ranOut("codex", until: Date().addingTimeInterval(3600))
        // With no other account, the one back soonest is still tried.
        #expect(accounts.pick("codex")?.id == "codex")
        #expect(accounts.pick("codex", skipping: ["codex"]) == nil)
        #expect(!accounts.hasRoom("codex"))
    }

    @Test func whenInWords() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 9; parts.day = 28; parts.hour = 10
        let now = Calendar.current.date(from: parts)!
        #expect(PlanAccounts.when(now.addingTimeInterval(5 * 3600 + 40 * 60), now: now) == "3:40 PM")
        #expect(PlanAccounts.when(now.addingTimeInterval(4 * 86_400 + 12 * 3600), now: now) == "Fri 10 PM")
        #expect(PlanAccounts.when(now.addingTimeInterval(10 * 86_400), now: now) == "Oct 8")
    }
}

extension PlanAccountsTests {
    /// Tiers as their makers show them; Codex's token ids aren't the names.
    @Test func aPlansTierIsItsMakersName() {
        #expect(PlanAccounts.tier("claude", "max") == "Max")
        #expect(PlanAccounts.tier("codex", "prolite") == "Pro 100")
        #expect(PlanAccounts.tier("codex", "pro") == "Pro 200")
        #expect(PlanAccounts.tier("codex", "team") == "Business")
        #expect(PlanAccounts.tier("codex", "business") == "Enterprise")
        #expect(PlanAccounts.tier("codex", "edu_plus") == "Edu Plus")
        #expect(PlanAccounts.tier("codex", "something_new") == "Something_new")
    }

    /// A Free plan counts a month: it is called so, not a week.
    @Test func aMonthIsAMonth() {
        let accounts = PlanAccounts.shared
        let now = Date()
        let resets = now.addingTimeInterval(20 * 86_400)
        accounts.heard(codex: [
            "primary": ["usedPercent": 30, "windowDurationMins": 43_200, "resetsAt": Int(resets.timeIntervalSince1970)],
            "secondary": NSNull(), "rateLimitReachedType": NSNull(),
        ], on: "codex.test07")
        #expect(accounts.words("codex.test07", now: now) == "30% of the month used")
        #expect(accounts.windows("codex.test07", now: now).map(\.name) == ["thirty_day"])
        #expect(PlanAccounts.named("thirty_day").title == "Monthly")
    }

    @Test func codexsServerSaysItToo() {
        let accounts = PlanAccounts.shared
        let now = Date()
        let resets = now.addingTimeInterval(2 * 86_400)
        accounts.heard(codex: [
            "primary": ["usedPercent": 49, "windowDurationMins": 10080, "resetsAt": Int(resets.timeIntervalSince1970)],
            "secondary": NSNull(), "rateLimitReachedType": NSNull(),
        ], on: "codex.test02")
        #expect(accounts.words("codex.test02", now: now) == "49% of the week used")
        accounts.heard(codex: [
            "primary": ["used_percent": 100.0, "window_minutes": 300, "resets_at": resets.timeIntervalSince1970],
            "rate_limit_reached_type": "primary",
        ], on: "codex.test02")
        #expect(accounts.out("codex.test02", now: now))
    }
}

// Asked before a task: what each CLI reads of its plan's usage, and what a
// task does with it.
extension PlanAccountsTests {
    @Test func claudesUsageSaysItInPercent() throws {
        let accounts = PlanAccounts.shared
        let now = Date()
        let resets = ISO8601DateFormatter().string(from: now.addingTimeInterval(2 * 86_400))
        accounts.heard(claudeUsage: [
            "rate_limits": [
                "five_hour": ["utilization": 12, "resets_at": resets],
                "seven_day": ["utilization": 49, "resets_at": resets],
            ],
        ], on: "claude.test04")
        #expect(accounts.words("claude.test04", now: now) == "49% of the week used")
        #expect(!accounts.full("claude.test04", now: now))
        accounts.heard(claudeUsage: [
            "rate_limits": ["seven_day": ["utilization": 100, "resets_at": resets.replacingOccurrences(of: "Z", with: ".250Z")]],
        ], on: "claude.test04")
        #expect(accounts.out("claude.test04", now: now))
        let said = try #require(accounts.words("claude.test04", now: now))
        #expect(said.hasPrefix("Weekly limit, back "))
        // A plan whose usage it couldn't read says nothing new.
        accounts.heard(claudeUsage: ["rate_limits_available": true, "rate_limits": NSNull()], on: "claude.test04")
        #expect(accounts.out("claude.test04", now: now))
    }

    /// OpenCode's `api get` of its plan's usage: each window's percent and
    /// when it starts over (milliseconds), named as the others' windows
    /// are, for the ring's titles.
    @Test func opencodesUsageSaysItInPercentToo() throws {
        let accounts = PlanAccounts.shared
        let now = Date()
        let hourly = Date(timeIntervalSince1970: Double(Int((now.addingTimeInterval(3 * 3600)).timeIntervalSince1970 * 1000)) / 1000)
        let weekly = Date(timeIntervalSince1970: Double(Int((now.addingTimeInterval(2 * 86_400)).timeIntervalSince1970 * 1000)) / 1000)
        // As the CLI says it: the rest of the document (location, the
        // workspace's own windows, budgets) says nothing to the ring.
        accounts.heard(opencodeUsage: [
            "location": [:], "budgets": [],
            "data": ["workspace": [:], "go": [
                "rolling": ["percent": 92, "limited": false, "resetsAt": Int(hourly.timeIntervalSince1970 * 1000)],
                "weekly": ["percent": 42, "limited": false, "resetsAt": Int(weekly.timeIntervalSince1970 * 1000)],
                "monthly": ["percent": 21, "limited": false, "resetsAt": Int(now.addingTimeInterval(20 * 86_400).timeIntervalSince1970 * 1000)],
            ]],
        ], on: "opencode.test01")
        let quota = try #require(accounts.quotas["opencode.test01"])
        #expect(quota.used == 0.92 && quota.window == "five_hour" && quota.resets == hourly)
        #expect(quota.windows?["seven_day"] == PlanWindow(used: 0.42, resets: weekly))
        #expect(quota.windows?["thirty_day"]?.used == 0.21)
        #expect(accounts.words("opencode.test01", now: now) == "92% of 5 hours used")
        #expect(accounts.windows("opencode.test01", now: now).map(\.name) == ["five_hour", "seven_day", "thirty_day"])
        #expect(!accounts.out("opencode.test01", now: now))
        // A window out of room drives the quota; one with no percent to
        // say is skipped.
        accounts.heard(opencodeUsage: [
            "data": ["go": ["rolling": ["percent": 100, "resetsAt": Int(weekly.timeIntervalSince1970 * 1000)], "monthly": NSNull()]],
        ], on: "opencode.test01")
        #expect(accounts.out("opencode.test01", now: now))
        #expect(accounts.windows("opencode.test01", now: now).map(\.name) == ["five_hour"])
        // A window flagged limited stops work even below 100%, using its
        // own reset time rather than the fullest window's.
        accounts.heard(opencodeUsage: [
            "data": ["go": [
                "rolling": ["percent": 92, "limited": false, "resetsAt": Int(hourly.timeIntervalSince1970 * 1000)],
                "weekly": ["percent": 85, "limited": true, "resetsAt": Int(weekly.timeIntervalSince1970 * 1000)],
            ]],
        ], on: "opencode.test01")
        #expect(accounts.out("opencode.test01", now: now))
        #expect(accounts.quotas["opencode.test01"]?.out == weekly)
    }

    @Test func codexsReadSaysWhenThePlanStopsTakingWork() {
        let accounts = PlanAccounts.shared
        let now = Date()
        let resets = Int(now.addingTimeInterval(86_400).timeIntervalSince1970)
        accounts.heard(codexAsked: [
            "ordinaryUsageAllowed": true,
            "rateLimits": ["primary": ["usedPercent": 52, "windowDurationMins": 10080, "resetsAt": resets], "secondary": NSNull()],
        ], on: "codex.test05")
        #expect(accounts.words("codex.test05", now: now) == "52% of the week used")
        #expect(!accounts.out("codex.test05", now: now))
        accounts.heard(codexAsked: [
            "ordinaryUsageAllowed": false,
            "rateLimits": ["primary": ["usedPercent": 97, "windowDurationMins": 300, "resetsAt": resets], "secondary": NSNull()],
        ], on: "codex.test05")
        #expect(accounts.out("codex.test05", now: now))
    }

    @Test func aWeekUsedUpOnExtraUsageHasNoRoom() {
        let accounts = PlanAccounts.shared
        let now = Date()
        let resets = now.addingTimeInterval(3 * 3600).timeIntervalSince1970
        // Allowed, but paid for: the other plan's room goes first.
        accounts.heard(claude: [
            "status": "allowed", "isUsingOverage": true,
            "unifiedWindows": ["seven_day": ["utilization": 1.0, "resetsAt": resets]],
        ], on: "claude.test06")
        #expect(!accounts.out("claude.test06", now: now))
        #expect(accounts.full("claude.test06", now: now))
        #expect(!accounts.full("claude.test06", now: Date(timeIntervalSince1970: resets + 1)))
    }

    @Test func theOtherAgentHearsWhatWasDone() {
        let items = [
            ChatItem(id: "1", kind: .asked, text: "Find the Pro plan's price", state: .done),
            ChatItem(id: "2", kind: .thinking, text: "Let me look", state: .done),
            ChatItem(id: "3", kind: .tool, name: "open", detail: "example.com", state: .done),
            ChatItem(id: "4", kind: .message, text: "The Pro plan is $20.", state: .done),
            ChatItem(id: "5", kind: .message, name: Agents.handedOver, text: "Claude Code is out of room. Codex carries on.", state: .done),
        ]
        let said = Agents.conversation(items, by: "Claude Code")
        #expect(said == "Person: Find the Pro plan's price\nClaude Code used open \u{00B7} example.com\nClaude Code: The Pro plan is $20.")
        // Nothing done but asking: nothing to tell.
        #expect(Agents.conversation(Array(items.prefix(2)), by: "Claude Code").isEmpty)
    }

    @Test func addAccountSaysEachStep() {
        #expect(PlanAccounts.stepWords("claude", .opening) == "Opening the sign-in…")
        #expect(PlanAccounts.stepWords("claude", nil) == "Opening the sign-in…")
        #expect(PlanAccounts.stepWords("claude", .yab) == "Sign in to your other Claude account in the private tab")
        #expect(PlanAccounts.stepWords("codex", .browser("Chrome"))
                == "Sign in to your other ChatGPT account in Chrome. Sign out of the usual one there first.")
        #expect(PlanAccounts.stepWords("codex", .browser(nil)).contains(" in your browser. "))
        #expect(PlanAccounts.stepWords("claude", .checking) == "Checking the account…")
        #expect(PlanAccounts.Step(.browser("Arc")) == .browser("Arc"))
        #expect(PlanAccounts.Step(.yab) == .yab)
        #expect(PlanAccounts.notAdded == "The account wasn't added.")
        #expect(PlanAccounts.already("me@example.com") == "me@example.com is already here.")
    }
}

extension PlanAccountsTests {
    private func isolatedSettings() -> (UserDefaults, String) {
        let name = "dev.serafim.fast.test.plan-refresh." + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    private func connectedAccounts(_ settings: UserDefaults) -> PlanAccounts {
        let consent = ProviderConsent(settings: settings, history: [])
        if !consent.allows("codex") { consent.grant("codex") }
        return PlanAccounts(settings: settings, consent: consent)
    }

    /// Answers the real read-only app-server exchange, never a model turn.
    private func usageProbe(_ answer: [String: Any], delay: Bool = false) throws -> (root: URL, found: Shell.Found, log: URL, reply: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yab-plan-refresh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binary = root.appendingPathComponent("codex")
        let log = root.appendingPathComponent("requests.jsonl")
        let reply = root.appendingPathComponent("reply.json")
        try """
        #!/bin/sh
        [ "$1" = "app-server" ] || exit 1
        for count in 1 2 3; do
          IFS= read -r line || exit 1
          printf '%s\\n' "$line" >> "$PLAN_USAGE_LOG"
        done
        if [ "$PLAN_USAGE_DELAY" = "1" ]; then /bin/sleep 0.2; fi
        /bin/cat "$PLAN_USAGE_REPLY"
        printf '\\n'
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try JSONSerialization.data(withJSONObject: ["id": 2, "result": answer]).write(to: reply)
        let found = Shell.Found(codex: binary.path, env: [
            "PLAN_USAGE_LOG": log.path, "PLAN_USAGE_REPLY": reply.path,
            "PLAN_USAGE_DELAY": delay ? "1" : "0",
        ])
        return (root, found, log, reply)
    }

    private func codexUsage(_ percent: Int, resets: Date) -> [String: Any] {
        ["ordinaryUsageAllowed": percent < 100, "rateLimits": [
            "primary": ["usedPercent": percent, "windowDurationMins": 10080, "resetsAt": Int(resets.timeIntervalSince1970)],
            "secondary": NSNull(), "rateLimitReachedType": NSNull(),
        ]]
    }

    private func methods(in log: URL) throws -> [String] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").compactMap { line in
            (try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["method"] as? String
        }
    }

    @Test func aCodexResetReplacesThePersistedBlockedQuota() async throws {
        let (settings, name) = isolatedSettings()
        defer { settings.removePersistentDomain(forName: name) }
        let resets = Date().addingTimeInterval(3 * 86_400)
        let original = connectedAccounts(settings)
        original.heard(codexAsked: codexUsage(100, resets: resets), on: "codex")
        let accounts = connectedAccounts(settings)
        #expect(accounts.out("codex"))
        #expect(!accounts.hasRoom("codex"))
        let probe = try usageProbe(codexUsage(0, resets: resets))
        defer { try? FileManager.default.removeItem(at: probe.root) }

        await accounts.ask("codex", found: probe.found, refreshBlocked: true)

        #expect(!accounts.out("codex"))
        #expect(!accounts.full("codex"))
        #expect(accounts.hasRoom("codex"))
        #expect(accounts.fullest("codex") == 0)
        #expect(accounts.words("codex") == "0% of the week used")
        let restarted = connectedAccounts(settings)
        #expect(restarted.quotas["codex"] == accounts.quotas["codex"])
        #expect(restarted.hasRoom("codex"))
        #expect(try methods(in: probe.log) == ["initialize", "initialized", "account/rateLimits/read"])
    }

    @Test func aStaleBlockedPlanIsAskedBeforeItsOldReset() async throws {
        let (settings, name) = isolatedSettings()
        defer { settings.removePersistentDomain(forName: name) }
        let resets = Date().addingTimeInterval(3 * 86_400)
        var quota = PlanQuota(out: resets, used: 1, resets: resets, window: "seven_day")
        quota.seen = Date().addingTimeInterval(-PlanAccounts.fresh - 1)
        settings.set(try JSONEncoder().encode(["codex": quota]), forKey: "plans.quotas")
        let accounts = connectedAccounts(settings)
        let probe = try usageProbe(codexUsage(12, resets: resets))
        defer { try? FileManager.default.removeItem(at: probe.root) }

        await accounts.ask("codex", found: probe.found)

        #expect(accounts.hasRoom("codex"))
        #expect(accounts.words("codex") == "12% of the week used")
        #expect(try methods(in: probe.log).count == 3)
    }

    @Test func openingAgainHearsAResetImmediatelyAfterABlockedRead() async throws {
        let (settings, name) = isolatedSettings()
        defer { settings.removePersistentDomain(forName: name) }
        let accounts = connectedAccounts(settings)
        let resets = Date().addingTimeInterval(3 * 86_400)
        accounts.heard(codexAsked: codexUsage(100, resets: resets), on: "codex")
        let probe = try usageProbe(codexUsage(100, resets: resets))
        defer { try? FileManager.default.removeItem(at: probe.root) }
        await accounts.ask("codex", found: probe.found, refreshBlocked: true)
        #expect(accounts.out("codex"))
        try JSONSerialization.data(withJSONObject: ["id": 2, "result": codexUsage(0, resets: resets)]).write(to: probe.reply)

        await accounts.ask(["codex"], found: probe.found, refreshBlocked: true)

        #expect(accounts.hasRoom("codex"))
        #expect(try methods(in: probe.log).count == 6)
        // Room left keeps the ordinary freshness gate when reopened.
        await accounts.ask("codex", found: probe.found, refreshBlocked: true)
        #expect(try methods(in: probe.log).count == 6)
    }

    @Test func simultaneousBlockedRefreshesShareOneUsageRead() async throws {
        let (settings, name) = isolatedSettings()
        defer { settings.removePersistentDomain(forName: name) }
        let accounts = connectedAccounts(settings)
        let resets = Date().addingTimeInterval(3 * 86_400)
        accounts.heard(codexAsked: codexUsage(100, resets: resets), on: "codex")
        let probe = try usageProbe(codexUsage(0, resets: resets), delay: true)
        defer { try? FileManager.default.removeItem(at: probe.root) }

        let first = Task {
            await accounts.ask("codex", found: probe.found, refreshBlocked: true)
            return accounts.hasRoom("codex")
        }
        let second = Task {
            await accounts.ask("codex", found: probe.found, refreshBlocked: true)
            return accounts.hasRoom("codex")
        }
        let available = await (first.value, second.value)

        #expect(available.0 && available.1)
        #expect(try methods(in: probe.log).count == 3)
    }

    @Test func aMissingUsageAnswerKeepsTheKnownBlockedQuota() async throws {
        let (settings, name) = isolatedSettings()
        defer { settings.removePersistentDomain(forName: name) }
        let accounts = connectedAccounts(settings)
        let resets = Date().addingTimeInterval(3 * 86_400)
        accounts.heard(codexAsked: codexUsage(100, resets: resets), on: "codex")
        let remembered = accounts.quotas["codex"]
        let probe = try usageProbe([:])
        defer { try? FileManager.default.removeItem(at: probe.root) }

        await accounts.ask("codex", found: probe.found, refreshBlocked: true)

        #expect(accounts.quotas["codex"] == remembered)
        #expect(accounts.out("codex"))
        #expect(!accounts.hasRoom("codex"))
        #expect(connectedAccounts(settings).quotas["codex"] == remembered)
        #expect(try methods(in: probe.log).count == 3)
    }
}
