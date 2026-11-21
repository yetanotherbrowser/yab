import Foundation
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct ClipPaceTests {
    @Test func theClipboardIsLookedAtLessOnlyWhileNobodyIsThere() {
        #expect(ClipPace.every(quiet: 0, locked: false) == 1)
        #expect(ClipPace.every(quiet: 59, locked: false) == 1)
        #expect(ClipPace.every(quiet: 60, locked: false) == 5)
        #expect(ClipPace.every(quiet: 3600, locked: false) == 5)
        #expect(ClipPace.every(quiet: 0, locked: true) == nil)
    }

    @Test func comingBackLooksAtOnceAndQuickensAgain() {
        var quiet: TimeInterval = 0, looks = 0, screen = false
        let pace = ClipPace(quiet: { quiet }, locked: { screen }, look: { looks += 1 })
        pace.start()
        defer { pace.stop() }
        #expect(pace.timer?.timeInterval == 1)
        quiet = 120
        pace.tick()
        #expect(looks == 1 && pace.timer?.timeInterval == 5)
        // Someone back, in Yab or another app: a look now, the quick pace again.
        pace.wake()
        #expect(looks == 2 && pace.timer?.timeInterval == 1)
        // The screen locked: no look at all until it opens.
        screen = true
        pace.lock()
        #expect(pace.timer?.timeInterval == ClipPace.recheck)
        pace.wake()
        #expect(looks == 2 && pace.timer?.timeInterval == ClipPace.recheck)
        quiet = 0
        screen = false
        pace.unlock()
        #expect(looks == 3 && pace.timer?.timeInterval == 1)
        // Its unlock heard late: another app coming forward finds it open.
        screen = true
        pace.lock()
        screen = false
        pace.wake()
        #expect(looks == 4 && pace.timer?.timeInterval == 1)
    }

    @Test func aPressInYabWhileNobodyWasThereLooksAtOnce() {
        var quiet: TimeInterval = 120, looks = 0
        let pace = ClipPace(quiet: { quiet }, locked: { false }, look: { looks += 1 })
        pace.start()
        defer { pace.stop() }
        #expect(pace.timer?.timeInterval == ClipPace.away)
        // A selection and its copy in Yab, a private window's too: looked at
        // now and every second after, so the copy is taken with the window
        // and app it was made in, not one switched to in the slow look's wait.
        quiet = 0
        pace.pressed()
        #expect(looks == 1 && pace.timer?.timeInterval == ClipPace.quick)
        // At the quick pace a press adds no look.
        pace.pressed()
        #expect(looks == 1)
    }

    @Test func aScreenLockedAtLaunchIsNotLookedAt() {
        var looks = 0, screen = true
        let pace = ClipPace(quiet: { 0 }, locked: { screen }, look: { looks += 1 })
        pace.start()
        defer { pace.stop() }
        #expect(pace.timer?.timeInterval == ClipPace.recheck && looks == 0)
        screen = false
        pace.unlock()
        #expect(looks == 1 && pace.timer?.timeInterval == 1)
    }

    @Test func aTestRunsQuickerLookKeepsItsPace() {
        var quiet: TimeInterval = 600
        let pace = ClipPace(steady: 0.05, quiet: { quiet }, locked: { false }, look: {})
        pace.start()
        defer { pace.stop() }
        #expect(pace.timer?.timeInterval == 0.05)
        quiet = 0
        pace.tick()
        #expect(pace.timer?.timeInterval == 0.05)
    }

    @Test func wakingToALockedScreenStopsLooking() {
        var looks = 0, screen = false
        let pace = ClipPace(quiet: { 0 }, locked: { screen }, look: { looks += 1 })
        pace.start()
        defer { pace.stop() }
        // The lock was never heard (Yab behind another app); the Mac wakes to it.
        screen = true
        pace.wake()
        #expect(pace.timer?.timeInterval == ClipPace.recheck && looks == 0)
    }

    @Test func theNoticesOfLockAndUnlockAreTrustedOnlyWhereTheyCanBe() {
        var looks = 0, screen = false
        let pace = ClipPace(quiet: { 0 }, locked: { screen }, look: { looks += 1 })
        pace.start()
        defer { pace.stop() }
        // A lock notice held back until after the unlock: the screen is open, keep looking.
        pace.lock()
        #expect(pace.timer?.timeInterval == 1)
        // The unlock notice before the session says so: the notice is right.
        screen = true
        pace.lock()
        #expect(pace.timer?.timeInterval == ClipPace.recheck)
        pace.unlock()
        #expect(looks == 1 && pace.timer?.timeInterval == 1)
    }

    @Test func anUnlockNobodyHeardIsFoundByTheLocksOwnLook() {
        var looks = 0, screen = true
        let pace = ClipPace(quiet: { 600 }, locked: { screen }, look: { looks += 1 })
        pace.start()
        defer { pace.stop() }
        #expect(pace.timer?.timeInterval == ClipPace.recheck)
        // Still locked: no look at the clipboard.
        pace.tick()
        #expect(looks == 0)
        // Unlocked, and the notice lost: the next look at the lock finds it
        // open, and someone opened it, so the quick pace.
        screen = false
        pace.tick()
        #expect(looks == 1 && pace.timer?.timeInterval == ClipPace.quick)
    }

    @Test func aTestWorldKeepsItsPaceWhateverTheMac() {
        // An eval Mac nobody touches, its screen locked: a test world still looks every second.
        var looks = 0
        let pace = ClipPace(steady: ClipPace.quick, quiet: { 3600 }, locked: { true }, look: { looks += 1 })
        pace.start()
        defer { pace.stop() }
        #expect(pace.timer?.timeInterval == ClipPace.quick)
        pace.tick()
        #expect(looks == 1 && pace.timer?.timeInterval == ClipPace.quick)
    }
}
