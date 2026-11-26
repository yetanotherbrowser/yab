import Foundation
import Testing
@testable import Fast

struct MailCodeStateTests {
    @Test func resendSupersedesOnlyItsSenderAcrossThreads() {
        let store = MailStore(file: FileManager.default.temporaryDirectory.appendingPathComponent("mail-resend-\(UUID()).sqlite"))
        let at = Date(timeIntervalSince1970: 1000)
        let sender = MailPerson(name: "Brex", address: "noreply@brex.com")
        let old = MailMessage(id: "old", thread: "first", from: sender, date: at)
        let other = MailMessage(id: "other", thread: "other", from: MailPerson(name: "Other", address: "hi@other.test"), date: at.addingTimeInterval(1))
        let new = MailMessage(id: "new", thread: "second", from: sender, date: at.addingTimeInterval(2))
        let code = MailCodeRead(code: "481902", shown: "481 902")
        store.put([old, other, new])
        store.keepCode(code, message: old); store.keepCode(code, message: other)
        #expect(!store.codeReplaced(message: old.id))
        store.keepCode(MailCodeRead(code: "902114", shown: "902 114"), message: new)
        #expect(store.codeReplaced(message: old.id))
        #expect(!store.codeReplaced(message: new.id))
        #expect(!store.codeReplaced(message: other.id))
        let future = MailMessage(id: "future", thread: "future", from: sender, date: at.addingTimeInterval(1000))
        store.put([future]); store.keepCode(code, message: future)
        #expect(!store.codeReplaced(message: new.id, now: at.addingTimeInterval(20)))
    }

    @Test func theNextNewerCodesDateIsKnownBeforeItReplaces() {
        let store = MailStore(file: FileManager.default.temporaryDirectory.appendingPathComponent("mail-replaced-at-\(UUID()).sqlite"))
        let at = Date(timeIntervalSince1970: 1000)
        let sender = MailPerson(name: "Brex", address: "noreply@brex.com")
        let old = MailMessage(id: "old", thread: "first", from: sender, date: at)
        let ahead = MailMessage(id: "ahead", thread: "second", from: sender, date: at.addingTimeInterval(1000))
        store.put([old, ahead])
        store.keepCode(MailCodeRead(code: "481902", shown: "481 902"), message: old)
        #expect(store.codeReplacedAt(message: old.id) == nil)
        store.keepCode(MailCodeRead(code: "902114", shown: "902 114"), message: ahead)
        // Dated ahead: not replacing yet, but its date is known, for the wake.
        #expect(!store.codeReplaced(message: old.id, now: at.addingTimeInterval(20)))
        #expect(store.codeReplacedAt(message: old.id) == ahead.date)
        #expect(store.codeReplacedAt(message: ahead.id) == nil)
    }
}
