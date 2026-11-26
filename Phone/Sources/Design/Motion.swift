import SwiftUI
import Observation
import os

/// Every movement in Yab for iPhone, named, with the prototype's numbers
/// ("Motion" in Phone/Reference/prototype.html and its springs). A spring
/// here is the prototype's own: `response` in seconds, `damping` 1 is
/// critical, no overshoot, which is SwiftUI's spring(response:dampingFraction:)
/// exactly. Frequent paths (plate, field, paging) have no give: a bounce on a
/// path walked a hundred times a day stops being a pleasure by the second day.
///
/// Each motion runs inside an os_signpost interval of its own name, so
/// Instruments and XCTOSSignpostMetric measure exactly that movement.
struct Motion: Sendable {
    let name: StaticString
    let animation: Animation
    /// How long it takes to arrive, for waits and for the signpost's end.
    let duration: TimeInterval
    /// A spring's own numbers, for movements driven frame by frame (a sheet
    /// thrown by a finger keeps the finger's speed): nil for curves.
    var response: Double? = nil
    var damping: Double? = nil

    /// A spring from the prototype: `response` and `damping` as it writes them.
    static func spring(_ name: StaticString, response: Double, damping: Double = 1) -> Motion {
        // A critically damped spring is visually there after about its response;
        // underdamped ones a little later.
        Motion(name: name, animation: .spring(response: response, dampingFraction: damping),
               duration: response * (damping < 1 ? 1.25 : 1), response: response, damping: damping)
    }
    /// Arriving: fast, then settling (cubic-bezier(.2, .8, .2, 1)).
    static func easeOut(_ name: StaticString, _ duration: TimeInterval, delay: TimeInterval = 0) -> Motion {
        Motion(name: name, animation: .timingCurve(0.2, 0.8, 0.2, 1, duration: duration).delay(delay), duration: duration + delay)
    }
    /// Leaving: gathering speed, the way a thing goes (cubic-bezier(.4, 0, .8, .4)).
    static func easeIn(_ name: StaticString, _ duration: TimeInterval) -> Motion {
        Motion(name: name, animation: .timingCurve(0.4, 0, 0.8, 0.4, duration: duration), duration: duration)
    }
    /// The chrome's own curve (cubic-bezier(.3, .8, .3, 1)).
    static func settle(_ name: StaticString, _ duration: TimeInterval) -> Motion {
        Motion(name: name, animation: .timingCurve(0.3, 0.8, 0.3, 1, duration: duration), duration: duration)
    }
    static func linear(_ name: StaticString, _ duration: TimeInterval) -> Motion {
        Motion(name: name, animation: .linear(duration: duration), duration: duration)
    }
    /// Any other cubic-bezier the prototype writes.
    static func curve(_ name: StaticString, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
                      _ duration: TimeInterval, delay: TimeInterval = 0) -> Motion {
        Motion(name: name, animation: .timingCurve(x1, y1, x2, y2, duration: duration).delay(delay), duration: duration + delay)
    }

    // MARK: - the page and its chrome

    /// The iPad sidebar and the page edge travel together, without bounce.
    static let tabletSidebar = settle("tabletSidebar", 0.3)

    /// The fold (measured frame by frame, 2026-10-09): one
    /// movement, easing in and out, in which the plate shrinks to a capsule
    /// round its words and sinks, while ‹ and the stack slide in toward it,
    /// shrinking, and melt. The same way back.
    static let chromeFold = curve("chromeFold", 0.4, 0, 0.2, 1, 0.3)
    /// The round buttons' glass dematerializing with the fold and coming back
    /// (UIKit's own effect animation: an alpha on glass leaves a pale disc).
    static let chromeButtons = curve("chromeButtons", 0.4, 0, 0.2, 1, 0.3)
    /// A new page in the same place fades in over the old one (CSS ease).
    static let pageSwap = curve("pageSwap", 0.25, 0.1, 0.25, 1, 0.22)
    /// The neighbor tab, following the finger, and settling when it lets go.
    static let tabSwipe = spring("tabSwipe", response: 0.3)
    static let tabSwipeBack = spring("tabSwipeBack", response: 0.32)
    /// The Now line arriving from 8 below, transparent, with a touch of give;
    /// gone quicker. Folding with the chrome is chromeFold.
    static let nowArrive = curve("nowArrive", 0.3, 1.2, 0.4, 1, 0.25)
    static let nowGone = easeOut("nowGone", 0.15)
    /// New words for the same task: changed in place, the color at once.
    static let nowWords = linear("nowWords", 0.15)
    /// Needs you: a short push of the line.
    static let nowNudge = easeOut("nowNudge", 0.3)
    /// "Link copied": in from a little above, with the toast's slight give.
    static let toastIn = Motion(name: "toastIn", animation: .timingCurve(0.3, 1.3, 0.4, 1, duration: 0.35), duration: 0.35)
    static let toastOut = easeIn("toastOut", 0.2)
    /// The plate's menu grows out of the plate (from .6, 30 lower); the
    /// prototype's CSS overshoots, the table and the rules say it doesn't.
    static let plateMenu = easeOut("plateMenu", 0.25)

    // MARK: - the field

    /// The plate grows into the field, the keyboard rising with it; rows come a
    /// little later.
    static let fieldOpen = easeOut("fieldOpen", 0.3)
    static let fieldRows = easeOut("fieldRows", 0.24, delay: 0.07)
    /// Back: the field lands on the plate, the rows go first.
    static let fieldClose = easeOut("fieldClose", 0.24)
    /// The spaces out of the plate and back, frame by frame: one spring for
    /// the frame, the field, the dark and the words (FieldModel.travel).
    static let spacesMorph = spring("spacesMorph", response: 0.42)
    static let fieldRowsOut = easeIn("fieldRowsOut", 0.15)
    /// The search sheet rising on the keyboard and going: 90 % in 0.12 s,
    /// there in 0.25 s, no overshoot.
    static let searchSheet = spring("searchSheet", response: 0.25)
    /// The field growing out of the plate or + as the sheet rises under it.
    static let searchSheetMorph = spring("searchSheetMorph", response: 0.32)
    /// A new page chosen: the sheet goes up to the top and becomes the page.
    static let searchSheetUp = spring("searchSheetUp", response: 0.26)
    static let searchSheetReveal = easeOut("searchSheetReveal", 0.17)
    /// + in the column grows into the field over the keyboard.
    static let plusToField = easeOut("plusToField", 0.3)
    /// The eyes closing or opening for Incognito: the lids, then the word.
    static let eyes = curve("eyes", 0.4, 0, 0.6, 1, 0.2)
    static let eyesWord = easeOut("eyesWord", 0.26)
    /// The keyboard's ghost going down as the field closes.
    static let keyboardGone = easeIn("keyboardGone", 0.24)

    // MARK: - the spaces

    /// A space under the lens.
    static let space = spring("space", response: 0.2)
    /// The page menu's sheet shrinking into its row as it becomes the field.
    static let pageMenuToField = spring("pageMenuToField", response: 0.38)
    /// New Tab's one card: its top hugging the typed rows, and back to the space.
    static let cardHug = spring("cardHug", response: 0.36)
    /// The typed rows rising from the field, one after another.
    static let typedRows = spring("typedRows", response: 0.34)
    /// The shackle of Private's lock springing open once Face ID is sure; the
    /// tabs rise where the lock was when it has done.
    static let privateShackle = spring("privateShackle", response: 0.24, damping: 0.64)
    /// An unlock begins: Private's words and button leave, and the lock glides to
    /// the middle of the page, where it waits for Face ID.
    static let privateWords = easeOut("privateWords", 0.15)
    static let privateGlide = spring("privateGlide", response: 0.34)
    /// The open lock gives way to the empty page: it fades and shrinks as the page grows in.
    static let privateSwap = easeOut("privateSwap", 0.3)
    /// A folder's rows on the Mac's clock (Folders.clock): coming out, going in.
    static let folderOpen = easeOut("folderOpen", 0.22)
    static let folderShut = curve("folderShut", 0, 0, 0.58, 1, 0.14)
    /// Rows to their new places (folder, Clear, Close, Keep, a move).
    static let columnRows = easeOut("columnRows", 0.34, delay: 0.04)
    /// A row that arrives, and one that leaves, fading where it stood.
    static let rowArrive = easeOut("rowArrive", 0.26, delay: 0.06)
    static let rowLeave = easeIn("rowLeave", 0.13)
    /// A closed tab folding away.
    static let rowFold = easeOut("rowFold", 0.24)
    /// A row under a finger's swipe settling.
    static let rowSwipe = spring("rowSwipe", response: 0.3)
    /// A held tab let go.
    static let holdDrop = easeOut("holdDrop", 0.24)
    /// Move to Space swaps the held menu's contents in from the right.
    static let holdSwap = easeOut("holdSwap", 0.2)
    /// Menus (the space's ⋯, +, a held row) grow from their button.
    static let menuOpen = easeOut("menuOpen", 0.22)
    static let menuClose = easeIn("menuClose", 0.15)
    /// The capsule's side buttons stepping aside while it is swiped.
    static let capsuleWide = easeOut("capsuleWide", 0.3)
    /// The scroll edge's fade coming and going.
    static let scrollEdge = linear("scrollEdge", 0.18)

    // MARK: - answers and chats

    /// The answer grows out of the field; the question flies into its bubble.
    static let answerGrow = spring("answerGrow", response: 0.34)
    static let questionFly = spring("questionFly", response: 0.36)
    /// The answer's words, in after the sheet has grown.
    static let answerWords = easeOut("answerWords", 0.26, delay: 0.14)
    /// Claude's answer lands: the sheet takes its new height.
    static let answerHeight = spring("answerHeight", response: 0.3)
    /// The same sheet stands up to a chat, the page steps back.
    static let answerToChat = spring("answerToChat", response: 0.42, damping: 0.9)
    /// A chat folds into its row in Your Chats, and a row opens into its chat.
    static let chatFold = spring("chatFold", response: 0.3)
    static let chatUnfold = spring("chatUnfold", response: 0.34)
    /// ✎ grows a new chat out of the button.
    static let chatGrow = spring("chatGrow", response: 0.36)
    /// The Now line lends itself to a task's chat, and takes it back.
    static let nowToChat = spring("nowToChat", response: 0.38)
    static let chatToNow = spring("chatToNow", response: 0.3)
    /// From the Dynamic Island, a task's chat grows out of it.
    static let islandToChat = spring("islandToChat", response: 0.36)
    /// Swiped down: the sheet flows into the Now line; tapped, it comes back.
    static let park = spring("park", response: 0.3)
    static let unpark = spring("unpark", response: 0.38)
    /// The Now line flicked aside: let go. A short flick springs back.
    static let letGo = curve("letGo", 0.3, 0, 0.8, 0.2, 0.2)
    static let letGoBack = curve("letGoBack", 0.3, 1.2, 0.4, 1, 0.3)
    /// The keyboard with a chat's field, up and down.
    static let keyboardUp = spring("keyboardUp", response: 0.34)
    static let keyboardDown = spring("keyboardDown", response: 0.26)
    /// The chat's ⋯ menu.
    static let chatMenu = curve("chatMenu", 0.2, 0.9, 0.3, 1, 0.19)

    // MARK: - tasks: the code and the yes

    /// The code's and the yes's sheets grow out of the Now line or a button, and
    /// go back there if it is still on screen.
    static let sheetGrow = easeOut("sheetGrow", 0.34)
    static let sheetBack = easeOut("sheetBack", 0.26)
    /// With nowhere to go back to: up from the bottom, and away down.
    static let sheetRise = easeOut("sheetRise", 0.3)
    static let sheetDrop = easeIn("sheetDrop", 0.2)
    /// What a sheet holds, in a little after it has grown.
    static let sheetContents = easeOut("sheetContents", 0.22, delay: 0.09)
    /// The number pad under the code.
    static let padRise = easeOut("padRise", 0.3)
    static let padDrop = easeIn("padDrop", 0.22)

    /// The page behind coming back to its size.
    static let pageReturn = spring("pageReturn", response: 0.38)

    // MARK: - iPad downloads

    /// A file thrown at the iPad's downloads button (the Mac's HoardSkyView):
    /// it lifts off where the link was held, then flies its arc in. The
    /// points along the way are `DownloadFlight`'s.
    static let downloadLift = Motion(name: "downloadLift", animation: .easeOut(duration: 0.11), duration: 0.11)
    static let downloadArc = curve("downloadArc", 0.45, 0, 0.2, 1, 0.56)
    /// Each arrival, the button gives, as the Mac's does.
    static let downloadBump = Bump(scale: 1.18, out: 0.1, back: 0.3)
    /// The last file's mark arriving on the button, grown from this scale.
    static let downloadMarkScale: CGFloat = 0.4

    /// The flight's shape, as fractions of its way: grown from `liftScale`
    /// as it lifts, down to the badge's size from `shrinkFrom`, gone from `fadeFrom`.
    enum DownloadFlight {
        static let liftScale: CGFloat = 0.4
        static let shrinkFrom: CGFloat = 0.55
        static let fadeFrom: CGFloat = 0.94
    }

    /// A give in two springs: out to `scale` in `out` seconds, back in `back`.
    /// Still under Reduce Motion.
    struct Bump: Sendable {
        let scale: CGFloat
        let out: TimeInterval
        let back: TimeInterval

        func keyframes(reduced: Bool) -> some Keyframes<CGFloat> {
            KeyframeTrack {
                SpringKeyframe(reduced ? 1 : scale, duration: out)
                SpringKeyframe(1, duration: back)
            }
        }
    }

    // MARK: - running them

    /// Off in named-state launches (-YabNoAnim YES) and with Reduce Motion's
    /// short cross-fades decided by the caller.
    @MainActor static var disabled = false

    /// With Reduce Motion on, every movement is a short cross-fade's time
    /// instead (the plan's rule: same meaning, no morphs); the views that
    /// morph choose a fade themselves when `Motion.reduced` is true.
    @MainActor static var reduced: Bool {
        #if DEBUG
        UIAccessibility.isReduceMotionEnabled || reducedForTests || testPreference.isReduced
        #else
        UIAccessibility.isReduceMotionEnabled || reducedForTests
        #endif
    }
    #if DEBUG
    /// Tests can change the shared input while a real view remains mounted.
    /// This never disables the actual system preference or ships in Release.
    @MainActor static let testPreference = MotionPreferenceForTests()
    #endif
    static let fade = Animation.easeInOut(duration: fadeDuration)
    static let fadeDuration: TimeInterval = 0.2
    /// -YabReduceMotion YES: Reduce Motion for a test run, without the
    /// simulator's own setting (debug builds).
    static let reducedForTests: Bool = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-YabReduceMotion"), i + 1 < arguments.count else { return false }
        return ["yes", "true", "1"].contains(arguments[i + 1].lowercased())
        #else
        return false
        #endif
    }()

    /// The motion's animation, or none when motion is off.
    @MainActor var current: Animation? { Motion.disabled ? nil : Motion.reduced ? Motion.fade : animation }

    /// Changes `body`'s state under this motion, inside its signpost.
    /// `timed`: the views animate the change with their own
    /// `.animation(_:value:)` (so a scroll's later transaction can't make it
    /// jump), which leaves nothing in this transaction to wait for, and the
    /// signpost would end at once; it lasts the motion's own time instead.
    @MainActor
    func run(timed: Bool = false, _ body: () -> Void, completion: (@MainActor () -> Void)? = nil) {
        if Motion.disabled {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction, body)
            completion?()
            return
        }
        // Reduce Motion's cross-fade runs under a signpost of its own, so a
        // test can tell it from the morph (PLAN-iphone.md 7).
        let reduced = Motion.reduced
        let name = self.name
        let signpost: StaticString = reduced ? "fade" : name
        let seconds = reduced ? Motion.fadeDuration : duration
        let interval = MotionSignposts.begin(signpost, motion: name, expected: seconds)
        if timed {
            withAnimation(reduced ? Motion.fade : animation, body)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                MotionSignposts.end(signpost, interval, motion: name)
                completion?()
            }
            return
        }
        withAnimation(reduced ? Motion.fade : animation, completionCriteria: .logicallyComplete, body) {
            MotionSignposts.end(signpost, interval, motion: name)
            MainActor.assumeIsolated { completion?() }
        }
    }
}

/// The signposts motions run inside: animation intervals, so Instruments'
/// hitches and XCTOSSignpostMetric see each movement by its name. Debug and
/// test builds only.
enum MotionSignposts {
    static let signposter = OSSignposter(subsystem: "dev.serafim.fast.iphone", category: .pointsOfInterest)

    /// `motion` names the Motion when the interval's own name is another
    /// (Reduce Motion's "fade"); `expected` is its duration, for the meters.
    static func begin(_ name: StaticString, motion: StaticString? = nil, expected: TimeInterval = 0) -> OSSignpostIntervalState? {
        #if DEBUG
        Signposts.began(motion ?? name, signpost: name, expected: expected)
        return signposter.beginAnimationInterval(name, id: signposter.makeSignpostID())
        #else
        return nil
        #endif
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState?, motion: StaticString? = nil) {
        #if DEBUG
        Signposts.ended(motion ?? name)
        if let state { signposter.endInterval(name, state) }
        #endif
    }
}

#if DEBUG
@MainActor
@Observable
final class MotionPreferenceForTests {
    var isReduced = false
}
#endif
