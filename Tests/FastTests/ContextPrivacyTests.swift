import Foundation
import Testing
import SyncKit
@testable import Fast

struct ContextPrivacyTests {
    final class Fixture {
        var profile = Profile()
        var addresses: [StreetAddress] = []
        var billing: Set<String> = []
        var erased = false
        var eraseWorks = true
        var saveWorks = true
        var profileWrites = 0
        var addressWrites = 0
        var stores: ContextPrivacy.Stores {
            var stores = ContextPrivacy.Stores()
            stores.profile = { self.profile }
            stores.saveProfile = { self.profileWrites += 1; guard self.saveWorks else { return false }; self.profile = $0; return true }
            stores.saveSyncedProfile = stores.saveProfile
            stores.addresses = { self.addresses }
            stores.saveAddress = { next in
                self.addressWrites += 1
                guard self.saveWorks else { return false }
                self.addresses.removeAll { $0.id == next.id }; self.addresses.append(next); return true
            }
            stores.removeAddress = { id in self.addresses.removeAll { $0.id == id }; return true }
            stores.billingIDs = { self.billing }
            stores.eraseNotes = { guard self.eraseWorks else { return false }; self.erased = true; return true }
            stores.report = { nil }
            return stores
        }
    }

    private func isolated(_ body: (ContextPrivacy, Fixture, UserDefaults, MemoryContextJournal) throws -> Void) rethrows {
        let domain = "context-clear-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        let fixture = Fixture(), journal = MemoryContextJournal()
        let privacy = ContextPrivacy(root: URL(fileURLWithPath: "/fixture/" + domain), settings: settings, storage: journal, stores: fixture.stores)
        try body(privacy, fixture, settings, journal)
    }

    private func profile(_ next: Profile, in fixture: Fixture, privacy: ContextPrivacy, origin: ContextOrigin) -> Bool {
        privacy.mutate(resource: "profile", before: Profile.cells(fixture.profile), after: Profile.cells(next), origin: origin) { fixture.profile = next; return true }
    }
    private func address(_ next: StreetAddress, in fixture: Fixture, privacy: ContextPrivacy, origin: ContextOrigin) -> Bool {
        privacy.saveAddress(next, origin: origin)
    }

    @Test func clearRestoresImportedValuesAndDeletesOnlyUnadoptedCreatedAddress() throws {
        try isolated { privacy, fixture, _, _ in
            fixture.profile.name = "Before"; fixture.profile.sources["name"] = "contact card"
            let imported = StreetAddress(id: "imported", street: "12 Fixture Street", city: "Testville", source: "Chrome")
            fixture.addresses = [imported]
            let grant = privacy.begin()
            var next = fixture.profile; next.name = "Learned"; next.sources["name"] = "memory"
            #expect(profile(next, in: fixture, privacy: privacy, origin: .learned(grant)))
            var enriched = imported; enriched.phone = "+1 555 0100"; enriched.source = "Get to know me, home"; enriched.found = "synthetic page"
            #expect(address(enriched, in: fixture, privacy: privacy, origin: .learned(grant)))
            #expect(address(StreetAddress(id: "created", street: "22 Synthetic Road", city: "Testville", source: "Get to know me"), in: fixture, privacy: privacy, origin: .learned(grant)))
            let plan = privacy.preview()
            // Untouched historical fields have no trustworthy authorship.
            let choices = Dictionary(uniqueKeysWithValues: plan.legacy.map { ($0.id, ContextPrivacy.Choice.keep) })
            let result = privacy.clear(plan, choices: choices)
            #expect(result.complete)
            #expect(fixture.profile.name == "Before" && fixture.profile.sources["name"] == "contact card")
            #expect(fixture.addresses == [imported])
            #expect(fixture.erased && !privacy.valid(grant))
        }
    }

    @Test func explicitSameValueBlankAndABAManualEditsSurviveClear() {
        isolated { privacy, fixture, _, _ in
            let grant = privacy.begin()
            var learned = Profile(); learned.name = "A"; learned.bio = "Learned"; learned.company = "Learned company"
            #expect(profile(learned, in: fixture, privacy: privacy, origin: .learned(grant)))
            var manual = fixture.profile
            #expect(profile(manual, in: fixture, privacy: privacy, origin: .manual(["name"])))
            manual.bio = ""; #expect(profile(manual, in: fixture, privacy: privacy, origin: .manual(["bio"])))
            manual.company = "B"; #expect(profile(manual, in: fixture, privacy: privacy, origin: .manual(["company"])))
            manual.company = "Learned company"; #expect(profile(manual, in: fixture, privacy: privacy, origin: .manual(["company"])))
            #expect(privacy.preview().legacy.isEmpty)
            #expect(privacy.clear(privacy.preview(), choices: [:]).complete)
            #expect(fixture.profile.name == "A" && fixture.profile.bio.isEmpty && fixture.profile.company == "Learned company")
        }
    }

    @Test func staleReviewAndUnknownPostImageNeverDeleteOrClaimComplete() {
        isolated { privacy, fixture, _, _ in
            let grant = privacy.begin()
            var next = Profile(); next.name = "Learned"
            #expect(profile(next, in: fixture, privacy: privacy, origin: .learned(grant)))
            let stale = privacy.preview()
            #expect(profile(next, in: fixture, privacy: privacy, origin: .manual(["name"])))
            #expect(!privacy.clear(stale, choices: [:]).complete)
            #expect(!fixture.erased && fixture.profile.name == "Learned")
        }
        isolated { privacy, fixture, _, _ in
            let grant = privacy.begin()
            var next = Profile(); next.name = "Learned"
            #expect(profile(next, in: fixture, privacy: privacy, origin: .learned(grant)))
            fixture.profile.name = "Unattributed change"
            #expect(!privacy.clear(privacy.preview(), choices: [:]).complete)
            #expect(!fixture.erased && fixture.profile.name == "Unattributed change")
        }
    }

    @Test func legacyRequiresExplicitChoiceAndSupportsExactRestore() throws {
        try isolated { privacy, fixture, _, _ in
            fixture.profile.name = "Legacy learned"; fixture.profile.company = "Legacy company"
            let preview = privacy.preview()
            #expect(preview.legacy.count == 2)
            #expect(!privacy.clear(preview, choices: [:]).complete && !fixture.erased)
            let items = preview.legacy.map { item in
                ContextPrivacy.LegacyItem(id: item.id, label: item.label, value: item.value,
                    restore: item.id == "profile:name" ? .init(value: "Earlier", source: "contact card") : nil)
            }
            let plan = ContextPrivacy.ClearPlan(epoch: preview.epoch, legacy: items, revisions: preview.revisions)
            #expect(privacy.clear(plan, choices: ["profile:name": .restore, "profile:company": .keep]).complete)
            #expect(fixture.profile.name == "Earlier" && fixture.profile.company == "Legacy company")
            #expect(privacy.preview().legacy.isEmpty)
        }
    }

    @Test func billingReferenceAndFailedEraseAreNotSuccessfulClear() {
        isolated { privacy, fixture, _, _ in
            let grant = privacy.begin()
            #expect(address(StreetAddress(id: "billing", street: "22 Synthetic Road", city: "Testville"), in: fixture, privacy: privacy, origin: .learned(grant)))
            fixture.billing = ["billing"]
            #expect(!privacy.clear(privacy.preview(), choices: [:]).complete)
            #expect(fixture.addresses.count == 1 && !fixture.erased)
        }
        isolated { privacy, fixture, _, _ in
            fixture.eraseWorks = false
            #expect(!privacy.clear(privacy.preview(), choices: [:]).complete)
            #expect(!fixture.erased)
        }
    }

    @Test func clearFencesOldSyncButAcceptsLaterRemoteEdits() {
        isolated { privacy, fixture, _, _ in
            let grant = privacy.begin(), oldEpoch = privacy.epoch
            var learned = Profile(); learned.name = "Learned"
            #expect(profile(learned, in: fixture, privacy: privacy, origin: .learned(grant)))
            #expect(privacy.clear(privacy.preview(), choices: [:]).complete)
            #expect(!privacy.mergeSyncedProfile(learned, epoch: oldEpoch, stamp: Stamp(wall: Int64.max, count: 7, device: "fixture")))
            #expect(privacy.mergeSyncedProfile(learned, epoch: privacy.epoch, stamp: Stamp(wall: 0, device: "local-context")))
            #expect(fixture.profile.name.isEmpty)
            #expect(!privacy.mayTakeSync("memory", epoch: privacy.epoch, stamp: Stamp(wall: 0, device: "local-context")))
            let remote = Stamp(wall: Int64.max, count: 7, device: "fixture")
            #expect(privacy.mergeSyncedProfile(learned, epoch: privacy.epoch, stamp: remote))
            #expect(fixture.profile.name.isEmpty)
            #expect(privacy.syncReview["profile:name"] == remote)
            #expect(privacy.resolveSync("profile:name", stamp: remote, accept: true))
            #expect(privacy.mergeSyncedProfile(learned, epoch: privacy.epoch, stamp: remote))
            #expect(fixture.profile.name == "Learned")
            #expect(!privacy.mayTakeSync("memory", epoch: privacy.epoch, stamp: remote))
            #expect(privacy.resolveSync("memory", stamp: remote, accept: true))
            #expect(privacy.mayTakeSync("memory", epoch: privacy.epoch, stamp: remote))
        }
    }

    @Test func corruptJournalCannotBeOverwrittenByANewMutation() {
        isolated { _, fixture, settings, journal in
            journal.data = Data("corrupt".utf8)
            let privacy = ContextPrivacy(root: URL(fileURLWithPath: "/fixture/corrupt"), settings: settings, storage: journal, stores: fixture.stores)
            var next = Profile(); next.name = "Synthetic"
            #expect(!profile(next, in: fixture, privacy: privacy, origin: .learned(privacy.begin())))
            #expect(fixture.profile.name.isEmpty && journal.data == Data("corrupt".utf8))
            #expect(!privacy.clear(privacy.preview(), choices: [:]).complete)
        }
    }

    @Test func failedLegacySaveCanBeRetriedWithoutSilentlyAdoptingTheValue() {
        isolated { privacy, fixture, _, _ in
            fixture.profile.name = "Unattributed legacy"
            fixture.saveWorks = false
            #expect(!privacy.clear(privacy.preview(), choices: ["profile:name": .remove]).complete)
            #expect(fixture.profile.name == "Unattributed legacy" && !fixture.erased)
            fixture.saveWorks = true
            let retry = privacy.preview()
            #expect(retry.legacy.map(\.id) == ["profile:name"])
            #expect(privacy.clear(retry, choices: ["profile:name": .remove]).complete)
            #expect(fixture.profile.name.isEmpty && fixture.erased)
        }
    }

    @Test func sourceLabelsCannotHideUnknownLineageAndKeepProtectsACreatedRecord() {
        isolated { privacy, fixture, _, _ in
            let grant = privacy.begin()
            var learned = Profile(); learned.name = "Learned"
            #expect(profile(learned, in: fixture, privacy: privacy, origin: .learned(grant)))
            var unknown = learned; unknown.name = "Remote"; unknown.sources["name"] = "contact card"; unknown.edited = ["name"]
            #expect(profile(unknown, in: fixture, privacy: privacy, origin: .sync(privacy.epoch)))
            let created = StreetAddress(id: "created", street: "22 Synthetic Road", city: "Testville", source: "Get to know me")
            #expect(address(created, in: fixture, privacy: privacy, origin: .learned(grant)))
            var changed = created; changed.street = "44 Manual Street"; changed.source = nil; changed.found = nil
            #expect(address(changed, in: fixture, privacy: privacy, origin: .unknown))
            let plan = privacy.preview()
            #expect(plan.legacy.contains { $0.id == "profile:name" })
            #expect(plan.legacy.contains { $0.id == "address/created:street" })
            let keep = Dictionary(uniqueKeysWithValues: plan.legacy.map { ($0.id, ContextPrivacy.Choice.keep) })
            #expect(privacy.clear(plan, choices: keep).complete)
            #expect(fixture.profile.name == "Remote")
            #expect(fixture.addresses.first?.street == "44 Manual Street")
        }
    }

    @Test func normalizedAddressPostImageRestoresTheExactOriginal() {
        isolated { privacy, fixture, _, _ in
            let original = StreetAddress(id: "imported", street: "12 Fixture Street", city: "Testville", source: "Chrome").tidied()
            fixture.addresses = [original]
            let grant = privacy.begin()
            var next = original; next.street = "500 Brannan St, San Francisco, CA"; next.city = ""; next.region = ""
            #expect(address(next, in: fixture, privacy: privacy, origin: .learned(grant)))
            #expect(fixture.addresses.first == next.tidied())
            let preview = privacy.preview()
            let keep = Dictionary(uniqueKeysWithValues: preview.legacy.map { ($0.id, ContextPrivacy.Choice.keep) })
            #expect(privacy.clear(preview, choices: keep).complete)
            #expect(fixture.addresses == [original])
        }
    }

    @Test func failedFinalJournalWriteRetainsRecoverableOwnership() {
        final class FailOnce: ContextJournalStorage {
            var data: Data?
            var writes = 0
            var failAt = Int.max
            func read() -> Data? { data }
            func write(_ next: Data) -> Bool { writes += 1; if writes == failAt { return false }; data = next; return true }
        }
        let domain = "context-final-write-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        let fixture = Fixture(), journal = FailOnce(), root = URL(fileURLWithPath: "/fixture/" + domain)
        let privacy = ContextPrivacy(root: root, settings: settings, storage: journal, stores: fixture.stores)
        var next = Profile(); next.name = "Learned"
        #expect(profile(next, in: fixture, privacy: privacy, origin: .learned(privacy.begin())))
        journal.failAt = journal.writes + 2 // Protected clear intent succeeds; final retirement fails.
        #expect(!privacy.clear(privacy.preview(), choices: [:]).complete)
        let restart = ContextPrivacy(root: root, settings: settings, storage: journal, stores: fixture.stores)
        #expect(restart.clear(restart.preview(), choices: [:]).complete)
        #expect(fixture.profile.name.isEmpty)
    }

    @Test func syncUsesFullObservedStampAndUnknownVersionsNeedAnExplicitDecision() throws {
        try isolated { privacy, fixture, _, _ in
            let journal = try SyncKit.Journal(path: nil, device: "fixture-device")
            let known = Stamp(wall: Clock.wallNow() + 1000, count: 90, device: "other-device")
            #expect(journal.clock.observe(known))
            privacy.attachSync(journal)
            #expect(privacy.clear(privacy.preview(), choices: [:]).complete)
            #expect(!privacy.mayTakeSync("memory/page", epoch: privacy.epoch, stamp: known))
            let next = Stamp(wall: known.wall, count: 1000, device: "other-device")
            #expect(!privacy.mayTakeSync("memory/page", epoch: privacy.epoch, stamp: next))
            #expect(privacy.syncReview["memory/page"] == next)
            #expect(privacy.resolveSync("memory/page", stamp: next, accept: false))
            #expect(!privacy.mayTakeSync("memory/page", epoch: privacy.epoch, stamp: next))
            let skewed = Stamp(wall: Int64.max, device: "skewed")
            #expect(!privacy.mayTakeSync("memory/page", epoch: privacy.epoch, stamp: skewed))
            #expect(privacy.resolveSync("memory/page", stamp: skewed, accept: true))
            #expect(privacy.mayTakeSync("memory/page", epoch: privacy.epoch, stamp: skewed))
            #expect(fixture.erased)
        }
    }

    @Test func revocationRejectsAnOldCallbackAndDoesNotAdoptANewerRun() throws {
        let domain = "context-epoch-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        let journal = MemoryContextJournal()
        let privacy = ContextPrivacy(root: URL(fileURLWithPath: "/fixture/a"), settings: settings, storage: journal)
        let old = privacy.begin()
        var commits = 0
        #expect(privacy.mutate(resource: "fixture", before: [:], after: ["x": .init(value: "synthetic")], origin: .learned(old)) { commits += 1; return true })
        privacy.revoke()
        let fresh = privacy.begin()
        #expect(!privacy.mutate(resource: "fixture", before: [:], after: ["x": .init(value: "late")], origin: .learned(old)) { commits += 1; return true })
        #expect(commits == 1)
        #expect(privacy.valid(fresh) && !privacy.valid(old))
        let other = ContextPrivacy(root: URL(fileURLWithPath: "/fixture/b"), settings: settings, storage: MemoryContextJournal())
        #expect(!other.valid(fresh))
        let restart = ContextPrivacy(root: URL(fileURLWithPath: "/fixture/a"), settings: settings, storage: journal)
        #expect(!restart.valid(old) && !restart.valid(fresh), "Restart never revives an active run grant")
    }

    @Test func failedProtectedIntentDoesNotWritePersonalData() {
        final class Failing: ContextJournalStorage {
            func read() -> Data? { nil }
            func write(_ data: Data) -> Bool { false }
        }
        let domain = "context-failure-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        let privacy = ContextPrivacy(root: URL(fileURLWithPath: "/fixture/c"), settings: settings, storage: Failing())
        let grant = privacy.begin()
        var committed = false
        #expect(!privacy.mutate(resource: "fixture", before: [:], after: ["x": .init(value: "synthetic")], origin: .learned(grant)) { committed = true; return true })
        #expect(!committed)
    }
}
