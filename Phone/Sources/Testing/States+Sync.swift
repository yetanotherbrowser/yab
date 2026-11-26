import Foundation
#if canImport(SyncKit)
import SyncKit
#endif

/// The named states of sync: the chapter "Sync" step by step
/// (ch-sync.1 to .6), and joining, which the prototype doesn't draw:
/// join.1 in through iCloud Keychain with no step, join.2 the code for a
/// Mac, join.3 the Recovery Key, join.4 a wrong one, join.5 turned away;
/// now.1, the Mac's tab offered on the Now line.
///
/// The Mac here is the bridge's pretend one: its tabs and its presence go
/// through the same path a real Mac's take from the line, so a state shows
/// what sync would make of them, not a picture of it.
extension StateCatalog {
    static let sync: [NamedState] = [
        NamedState("approval.chat", "Chat mail question", "A chat question without a tab, with Search and Not Now.") { app in
            if let request = try? AssistantApprovalRecords.Request(
                id: "3f2c6f0e-2b1a-4c55-9a77-0d6c1b1e7a10", account: "fixture", mac: "mac", assistant: "local.external",
                session: "chat", tab: "chat:travel", permit: "mail.read", title: "Claude: Search your mail?",
                lines: ["Travel plans", "once for this chat"], expires: Date().addingTimeInterval(300)) {
                app.sync.pretendAssistantApprovals([request])
            }
        },
        NamedState("approval.seen", "Opened on Mac", "The notification is quiet; the question still has its answer buttons.") { app in
            if var request = try? AssistantApprovalRecords.Request(
                id: "3f2c6f0e-2b1a-4c55-9a77-0d6c1b1e7a10", account: "fixture", mac: "mac", assistant: "local.external",
                session: "chat", tab: "chat:travel", permit: "mail.site:example.test", title: "Claude: Go to example.test?",
                lines: ["Travel plans", "once for this chat"], expires: Date().addingTimeInterval(300)) {
                request.seen = .init(device: "mac")
                app.sync.pretendAssistantApprovals([request])
            }
        },
        NamedState("approval.answered", "Answered on Mac", "An old notification opens to one quiet line, with no question card.") { app in
            app.sync.assistantApprovalReceipt = "Answered on your Mac"
        },
        NamedState("ch-sync.1", "One list", "The column on the iPhone and Yab's sidebar on the Mac show the same Today tabs, in the same order.") { app in
            await SyncStory.play(1, app)
        },
        NamedState("ch-sync.2", "Opened on Mac", "The tab goes to the top of Today on the iPhone, marked “Mac”.") { app in
            await SyncStory.play(2, app)
        },
        NamedState("ch-sync.3", "Continued on iPhone", "A tap: the tab opens here at the same spot on the page.") { app in
            await SyncStory.play(3, app)
        },
        NamedState("ch-sync.4", "Kept on iPhone", "A link from Telegram, Keep: the tab at the top of Today here and right away on the Mac.") { app in
            await SyncStory.play(4, app)
        },
        NamedState("ch-sync.5", "Mac asleep", "The new tab joins the list; a quiet line: the change arrives when the Mac wakes.") { app in
            await SyncStory.play(5, app)
        },
        NamedState("ch-sync.6", "Mac woke up", "The Mac catches up in a split second, the line at the bottom goes away.") { app in
            await SyncStory.play(6, app)
        },

        NamedState("now.1", "From Mac", "A tap opens the same view here.") { app in
            // The Mac's tab in front offered on the Now line, as sync offers
            // it when this iPhone comes to the front (the atlas's start:
            // Onboarding v3 in Figma).
            if let tab = app.browser.tab { app.tasks.handoff = tab }
        },

        // The Mac's Today on a space's page (docs/iphone-mac-tabs.md, D).
        NamedState("mactabs.off", "Mac's tabs off", "As before: Work's pins, kept and this iPhone's Today; the Mac's tab in front on its own row.") { app in
            MacTabsStory.play(app, on: false, count: 4, awake: true)
        },
        NamedState("mactabs.few", "Mac's tabs", "This iPhone ⌄ with Clear, then MacBook Pro ⌄: its tab in front first, In front on Mac.") { app in
            MacTabsStory.play(app, on: true, count: 4, awake: true)
        },
        NamedState("mactabs.many", "Many Mac tabs", "This iPhone folded by its ⌄; 24 tabs open on the Mac in Work: the first five, then Show all 24.") { app in
            MacTabsStory.play(app, on: true, count: 24, awake: true, folded: true)
        },
        NamedState("mactabs.asleep", "Mac asleep", "This iPhone folded; Asleep · 8:12 at the end of the Mac's line, its list as of the last sync.") { app in
            MacTabsStory.play(app, on: true, count: 9, awake: false, folded: true)
        },
        NamedState("mactabs.settings", "Your Mac's Tabs", "Settings › Today: the switch, off until turned on.") { app in
            SettingsUI.shared.assumeDefaultBrowser = true
            app.surfaces.openSettings()
            SettingsUI.shared.navigation = [.page(.today)]
        },

        NamedState("join.1", "Through iCloud", "The key came from iCloud Keychain: not a single step, the Mac's tabs are already here, and it says so.") { app in
            app.sync.pretendJoinedByICloud()
        },
        NamedState("join.2", "Code for the Mac", "No key here or in iCloud Keychain: a code to enter on the Mac.") { app in
            app.sync.pretend(.joining(.code("K7QM-4XTD")))
        },
        NamedState("join.3", "Recovery Key", "One field that grows to three lines: the whole key in view, the keyboard up at once.") { app in
            app.sync.typed = "AEBA-GBAF-AYDQ-QCIK-BMGA-2DQP-CAIR-EEYU-SJ4E-EWNZ-HHUQ-5PXG-UBBO-JTW"
            app.sync.pretend(.joining(.recovery(wrong: false)))
        },
        NamedState("join.4", "Wrong key", "Words under the field say what's wrong; the whole key in view to check its groups.") { app in
            app.sync.typed = "AEBA-GBAF-AYDQ-QCIK-BMGA-2DQP-CAIR-EEYU-SJ4E-EWNZ-HHUQ-5PXG-UBBO-JTX"
            app.sync.pretend(.joining(.recovery(wrong: true)))
        },
        NamedState("join.5", "Removed from sync", "The account no longer takes this iPhone: why, and a way to sign in again.") { app in
            app.sync.pretend(.refused("This \(DeviceWord.name) was removed from Sync."))
        },
        NamedState("join.6", "Scan QR", "The code from the Mac (Add a Device): the VisionKit camera, QR only; in the simulator, words saying there's no camera, and a field for the code.") { app in
            app.sync.pretend(.joining(.scan))
        },
        NamedState("join.7", "Match with the Mac", "The Mac's code scanned: four digits the Mac asks for before letting it in.") { app in
            app.sync.pretend(.joining(.invite(code: "K7QM-4XTD", check: "4821")))
        },

        NamedState("sendphone.1", "From Mac: card", "The page from the Mac landed at the top of Today; over the plate a “From MacBook Pro: …” card with Open.") { app in
            app.sync.pretendMac(awake: true, front: nil)
            app.sync.pretendArrival(SyncStates.arrival, front: false)
        },
        NamedState("sendphone.2", "From Mac: right away", "Yab in front and nothing being typed: the page opened right away, “From MacBook Pro” in the corner.") { app in
            app.sync.pretendMac(awake: true, front: nil)
            app.sync.pretendArrival(SyncStates.arrival, front: true)
        },

        NamedState("devices.1", "Devices", "Settings › Sync: the account's devices, this iPhone first, each with Syncing now or Last synced; Recovery Key; Turn Off.") { app in
            SyncStates.devices(app)
            app.surfaces.openSettings()
            SettingsUI.shared.openPage(.sync)
        },
        NamedState("devices.2", "Turn off sync", "Turn Off Sync on This iPhone asks: a red button and Cancel.") { app in
            SyncStates.devices(app)
            app.surfaces.openSettings()
            SettingsUI.shared.navigation = [.page(.sync)]
            try? await Task.sleep(for: .milliseconds(500))
            SettingsUI.shared.confirmSyncOff = true
        },
        NamedState("devices.3", "Recovery Key locked", "The Recovery Key page: the key behind Face ID, a Show with Face ID button.") { app in
            SyncStates.devices(app)
            app.surfaces.openSettings()
            SettingsUI.shared.navigation = [.page(.sync), .page(.recoveryKey)]
        },
        NamedState("devices.4", "Recovery Key", "After Face ID: the whole key and Copy.") { app in
            SyncStates.devices(app)
            SettingsUI.shared.recoveryShown = "AEBA-GBAF-AYDQ-QCIK-BMGA-2DQP-CAIR-EEYU-SJ4E-EWNZ-HHUQ-5PXG-UBBO-JTW"
            app.surfaces.openSettings()
            SettingsUI.shared.navigation = [.page(.sync), .page(.recoveryKey)]
        },
    ]
}

/// What the Send to iPhone and Devices states stand on.
@MainActor
enum SyncStates {
    /// A page the Mac sent a moment ago: Paul Graham's essay, a page the
    /// app carries.
    static var arrival: OpenOnPhone.Arrival {
        OpenOnPhone.Arrival(id: "state-arrival", url: URL(string: "https://paulgrahamcom.com")!, title: "How to Do Great Work",
                            space: nil, sender: "mac", sent: Date())
    }

    /// This iPhone, the Mac up now, and an older iPhone last seen hours ago.
    static func devices(_ app: AppModel) {
        SettingsUI.shared.assumeDefaultBrowser = true
        let now = Date()
        app.sync.pretendMac(awake: true, front: nil)
        app.sync.pretendDevices([
            SyncDevice(id: "phone", name: "Mira’s iPhone", model: "iPhone18,1", lastSeen: now),
            SyncDevice(id: "mac", name: "MacBook Pro", model: "Mac16,1", lastSeen: now.addingTimeInterval(-20)),
            SyncDevice(id: "old-phone", name: "Mira’s iPhone 15", model: "iPhone15,2", lastSeen: now.addingTimeInterval(-3 * 3600)),
        ], own: "phone")
    }
}

/// The chapter "Sync", played up to a step the way the prototype
/// does (its `sync` steps after `init: goTab(Work's first kept tab)`).
@MainActor
enum SyncStory {
    /// Mira's world: the local Tern in front on the Mac.
    static let tern = "work-tern-local"
    /// The Linear issue the Mac opens (step 2), and Lumen opened from another app (step 4).
    static let linear = "6F2B1C3A-4E5D-4A7B-9C8D-0E1F2A3B4C5D"
    static let lumen = "work-lumen"
    static let search = "9D8C7B6A-5F4E-4D3C-8B2A-1F0E9D8C7B6A"

    static func play(_ step: Int, _ app: AppModel) async {
        // The chapter's start: Work, its first kept tab, the Lisbon flights
        // done and seen (the prototype's reset), the Mac up with Tern in front.
        app.browser.select("work-figma-onb")
        app.tasks.start("lisbon")
        app.tasks.set("lisbon", status: .done)
        app.tasks.markSeen("lisbon")
        app.sync.pretendMac(awake: true, front: tern)
        if step >= 2 {
            // Opened on the Mac: in today's on the iPhone, at the top, "Mac" on it.
            app.sync.pretendMacOpens(linear, url: "https://linear.app/tern/issue/ENG-412/invite-flow",
                                     title: "ENG-412 · Invite flow · Linear", in: "work")
            app.sync.pretendMac(awake: true, front: linear)
        }
        if step >= 3 {
            // A tap on its row: here, at the same place of the page.
            app.browser.select(linear)
        }
        if step >= 4 {
            // A link from another app: one page, one row; the row already
            // there comes to the top of today's instead of a second one.
            if let tab = app.browser.tab(lumen) {
                app.browser.open(Tab(id: UUID().uuidString, title: "Design Systems Night · Stockholm · Lumen", site: tab.site,
                                     icon: tab.icon, url: tab.url, page: tab.page, host: tab.host))
                if let kept = app.browser.tab(lumen) {
                    var titled = kept
                    titled.title = "Design Systems Night · Stockholm · Lumen"
                    app.browser.navigate(to: titled)
                }
            }
        }
        if step >= 5 {
            // The Mac closed: everything works here, a new tab goes to the top.
            app.sync.pretendMac(awake: false, front: linear)
            app.browser.open(Tab(id: search, title: "lisbon weather october · Google Search", site: "Google", icon: "google",
                                 url: "google.com/search?q=lisbon+weather+october", page: "google", host: "google.com"))
        }
        if step >= 6 {
            // Awake: it catches up, the quiet line goes.
            app.sync.pretendMac(awake: true, front: linear)
        }
    }
}

/// The Mac's Today on Work's page, as the prototype draws it: the Linear
/// issue in front on the Mac, then its other tabs of today in Work.
@MainActor
enum MacTabsStory {
    static let tabs: [(url: String, title: String)] = [
        ("https://linear.app/tern/issue/TERN-412", "TERN-412 Recurring events drop after sync"),
        ("https://github.com/tern/web/pull/881", "Calendar sync retries #881"),
        ("https://www.figma.com/design/pricing-v2", "Pricing page v2"),
        ("https://slack.com/archives/launch", "#launch"),
        ("https://orbit.com/retention", "Retention by cohort"),
        ("https://ledger.app/forecast/q4", "Q4 forecast"),
        ("https://paper.so/weekly-oct-20", "Weekly notes · Oct 20"),
        ("https://daybook.app/2026-10-20", "Monday, October 20"),
        ("https://news.ycombinator.com/item?id=4120", "Show HN: Tern 2.0"),
    ] + [("TERN-398 Invite flow copy", "linear.app/tern/issue/TERN-398"), ("TERN-401 Timezone picker", "linear.app/tern/issue/TERN-401"),
         ("TERN-405 Empty states", "linear.app/tern/issue/TERN-405"), ("TERN-409 Slow week view", "linear.app/tern/issue/TERN-409"),
         ("TERN-415 Dark mode tokens", "linear.app/tern/issue/TERN-415"), ("TERN-417 Drag to reschedule", "linear.app/tern/issue/TERN-417"),
         ("Week view virtualization #874", "github.com/tern/web/pull/874"), ("Bump calendar SDK #879", "github.com/tern/web/pull/879"),
         ("Release 2.0.0-rc.2", "github.com/tern/web/releases"), ("Flaky test: sync merge #883", "github.com/tern/web/issues/883"),
         ("Issues · tern/web", "github.com/tern/web/issues"), ("Launch site · Hero", "www.figma.com/design/launch-site"),
         ("Settings v2", "www.figma.com/design/settings-v2"), ("Mobile week view", "www.figma.com/design/mobile-week"),
         ("Icons 24", "www.figma.com/design/icons-24")].map { (url: "https://" + $0.1, title: $0.0) }

    static func play(_ app: AppModel, on: Bool, count: Int, awake: Bool, folded: Bool = false) {
        SettingsStore.shared.macTabs = on
        if app.browser.spaceID != "work" { app.browser.showSpace("work") }
        if let tab = app.browser.tab("work-figma-onb") { app.browser.select(tab.id) }
        app.sync.pretendMacToday(Array(tabs.prefix(count)), in: "work")
        let calendar = Calendar.current
        let slept = calendar.date(bySettingHour: 8, minute: 12, second: 0, of: Date()) ?? Date()
        let front = SyncPresence(device: "mac", name: "MacBook Pro", at: slept.timeIntervalSince1970, url: tabs[0].url,
                                 title: tabs[0].title, tab: "mac-work-0", asleep: !awake)
        app.sync.pretendMacs([SyncMac(id: "mac", name: "MacBook Pro", model: "Mac16,1", lastSeen: slept, online: awake, front: front,
                                      state: awake ? .up : .asleep(since: slept), usedAt: slept)])
        NewTabPager.shared.startAt = "work"
        // This iPhone's Today folded by its ⌄: the Mac's line in view.
        NewTabPager.shared.startFolded = folded
        app.field.openSpaces()
    }
}
