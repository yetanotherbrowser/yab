import CoreGraphics
import SwiftUI

/// Every size in Yab for iPhone, in points, one to one from the prototype's
/// size system ("Sizes" in Phone/Reference/prototype.html and its
/// system.css). The prototype draws an iPhone 17 Pro, 402 x 874; sizes that
/// depend on the screen are worked out from these for the other iPhones.
///
/// The rules behind the numbers: sheets stand 8 from the screen's edges,
/// floating bars 12; inside a sheet the gutter is 12, so icons and text start
/// 20 from the screen at half and at full height; floating pieces stack 10
/// apart; anything a finger hits is at least 44 x 44; a nested radius is the
/// outer one less the inset.
enum Metrics {
    /// The prototype's screen, the iPhone 17 Pro.
    static let screen = CGSize(width: 402, height: 874)
    /// The status bar's band on a phone with the Dynamic Island.
    static let statusBar: CGFloat = 54

    // MARK: - edges and steps

    enum Edge {
        /// Sheets (column, chat, code, the yes) from the screen's edges.
        static let sheet: CGFloat = 8
        /// Floating bars (round buttons, plate, Now line, field, its cards).
        static let bar: CGFloat = 12
        /// Inside a sheet.
        static let gutter: CGFloat = 12
        /// Where a sheet's icons and text start, from the screen's edge.
        static let content: CGFloat = 20
        /// Between floating pieces: the Now line over the plate, the field over
        /// the keyboard, a card over the field.
        static let stack: CGFloat = 10
        /// Between a round button and the plate.
        static let control: CGFloat = 8
    }

    /// The smallest thing a finger is asked to hit.
    static let touch: CGFloat = 44

    // MARK: - the page's chrome

    enum Chrome {
        /// Plate, round buttons and the field: one height for everything at
        /// the bottom, Safari's 48 (measured off its iOS 26 bar).
        static let height: CGFloat = 48
        /// From the screen's bottom edge to the buttons' and the plate's.
        static let bottom: CGFloat = 28
        /// The round buttons, back on the left and the space on the right.
        static let round: CGFloat = 48
        /// The round buttons from the screen's sides, and the step to the plate.
        static let side: CGFloat = 26
        static let step: CGFloat = 7
        /// Stop while loading: Safari's small ✕ where ↻ was, 14 against ↻'s 22.
        static let stopGlyph: CGFloat = 14
        /// The plate's edges: past a button and the step beside it (26 + 48 + 7).
        static let plateInset: CGFloat = side + round + step
        static func plateWidth(screen: CGFloat) -> CGFloat { screen - plateInset * 2 }
        static let plateRadius: CGFloat = height / 2

        // What the plate says: the site's icon and name.
        /// The host: regular 16 between ≡ and ↻. Large text grows it one
        /// step at most (callout's xLarge, 17), so the plate keeps its height.
        static let labelFont: CGFloat = 16
        static let labelLargestText: UIContentSizeCategory = .extraLarge
        /// A host wider than its room keeps its end and fades out over this
        /// much at its start, never "…".
        static let labelFade: CGFloat = 26
        static let labelWeight: UIFont.Weight = .regular
        static let labelTracking: CGFloat = -0.32 // -.02em
        static let labelIcon: CGFloat = 18
        static let labelGap: CGFloat = 8
        static let labelPadding: CGFloat = 16
        static let pageActionIcon: CGFloat = 18
        /// ≡ and ↻ drawn 15 from the plate's edges: their 44 targets 4 in.
        static let pageGlyphInset: CGFloat = 15 + 22 / 2 - 44 / 2
        static let progressHeight: CGFloat = 2
        static let readerHintFont: CGFloat = 12

        // The icons on the round buttons.
        static let backIcon: CGFloat = 22
        static let spaceEmoji: CGFloat = 22
        /// The + before "New Tab" on the empty page's plate.
        static let emptyPlus: CGFloat = 18

        // Scrolled down: the plate folds into a capsule, the buttons go.
        // Safari's, measured off its recording (2026-10-09): 31 high, 16 from
        // the bottom, round its words with 22 on each side ("google.com" 106).
        static let minHeight: CGFloat = 31
        static let minBottom: CGFloat = 16
        static let minRadius: CGFloat = minHeight / 2
        static let minPadding: CGFloat = 22
        /// The capsule alone at most, centered (402 - 2 x 122); a short
        /// address makes it narrower (ChromeGeometry.words).
        static let minWidth: CGFloat = 158
        /// ‹ and the stack as they go: toward the capsule, smaller, melting.
        static let foldSlide: CGFloat = 26
        static let foldButtonScale: CGFloat = 0.8
        /// The capsule beside the Now line's short word: the two centered as one,
        /// 8 apart (64...196 and 204...338 on the 17 Pro).
        static let minWidthBesideNow: CGFloat = 132
        static let minGap: CGFloat = 8
        static let minLabelFont: CGFloat = 13
        static let minLabelGap: CGFloat = 6
        static let minLabelIcon: CGFloat = 14

        /// When a scroll folds the chrome and when it brings it back.
        static let foldAfter: CGFloat = 50
        static let foldStep: CGFloat = 3
        static let unfoldBefore: CGFloat = 20
    }

    // MARK: - the Now line

    enum Now {
        static let height: CGFloat = 52
        static let radius: CGFloat = height / 2
        /// Its foot, 10 over the plate's top (26 + 50 + 10).
        static let bottom: CGFloat = Chrome.bottom + Chrome.height + Edge.stack
        static func width(screen: CGFloat) -> CGFloat { screen - Edge.bar * 2 }
        static let leading: CGFloat = 12
        static let trailing: CGFloat = 8
        static let gap: CGFloat = 10
        static let iconBox: CGFloat = 28
        static let icon: CGFloat = 24
        static let titleFont: CGFloat = 14.5
        static let subtitleFont: CGFloat = 13
        static let lineGap: CGFloat = 2
        /// The action capsule (Review, Enter Code, Retry): 32 to see, 44 to hit.
        static let actionHeight: CGFloat = 32
        static let actionPadding: CGFloat = 12
        static let actionFont: CGFloat = 13.5
        static let moreFont: CGFloat = 12.5
        static let moreTrailing: CGFloat = 8

        // Folded beside the plate's capsule: one short word.
        static let minWidth: CGFloat = 134
        static let minHeight: CGFloat = Chrome.minHeight
        static let minIconBox: CGFloat = 18
        static let minIcon: CGFloat = 16
        static let minFont: CGFloat = 13
        static let minGap: CGFloat = 6
        static let minPadding: CGFloat = 10
        /// How far it sinks as it goes.
        static let goneDrop: CGFloat = 8

        // The Mac hint's chip: a small glass capsule centered over the plate,
        // 10 above it like the line, hugging its words.
        static let chipHeight: CGFloat = 38
        static let chipLeading: CGFloat = 9
        static let chipIcon: CGFloat = 22
        /// The Mac's mark in its round bite of the icon: the mark 15, the bite
        /// 18, the mark's box 4 past the icon's corner.
        static let chipBadge: CGFloat = 15
        static let chipBadgeGlyph: CGFloat = 12
        static let chipCut: CGFloat = 18
        static let chipBadgeOut: CGFloat = 4
        static let chipGap: CGFloat = 8
        static let chipFont: CGFloat = 13.5
        /// The cross: 26 to see, 40 wide and the chip's height to hit.
        static let chipCross: CGFloat = 26
        static let chipCrossGlyph: CGFloat = 12
        static let chipCrossHit: CGFloat = 40
        static let chipTrailing: CGFloat = 2
        /// Everything in the chip but its words.
        static let chipFixed: CGFloat = chipLeading + chipIcon + chipGap + 4 + chipCrossHit + chipTrailing
        // Swept aside: far enough (or quick enough) and it goes, else it springs back.
        static let sweepFar: CGFloat = 56
        static let sweepFlick: CGFloat = 160
        static let sweepAway: CGFloat = 360
        /// The nudge when it needs you.
        static let nudgeScale: CGFloat = 1.035
    }

    // MARK: - the toast

    enum Toast {
        /// Under the status bar and the island.
        static let top: CGFloat = 60
        static let height: CGFloat = 40
        static let radius: CGFloat = height / 2
        static let leading: CGFloat = 12
        static let trailing: CGFloat = 16
        static let gap: CGFloat = 8
        static let icon: CGFloat = 17
        static let font: CGFloat = 14.5
        /// Where it comes from: a little above its place.
        static let rise: CGFloat = 14
        /// How long it stays.
        static let shows: TimeInterval = 2.2
        /// At the bottom: its foot 14 over the plate (the prototype's 740 + 44
        /// on 874), up from 24 below.
        static let bottom: CGFloat = Chrome.bottom + Chrome.height + 14
        static let bottomRise: CGFloat = 24
    }

    // MARK: - the column

    enum Column {
        /// Its top at half and at full height, from the screen's top, and the
        /// place it waits at, off screen.
        static let halfTop: CGFloat = 352
        static let fullTop: CGFloat = 64
        static let goneTop: CGFloat = 900
        /// As drawn, 40 (the size table says 38 for sheets; the column's CSS keeps 40).
        static let radius: CGFloat = 40
        /// Let go between detents: thrown by velocity x 0.18; above the middle
        /// of half and full it goes full, up to 160 under half it stays half.
        static let projection: CGFloat = 0.18
        static let halfReach: CGFloat = 160
        /// Pulled past full, it resists.
        static let rubber: CGFloat = 60
        /// The space strip's throw, and resistance at the ends.
        static let spaceProjection: CGFloat = 0.16
        static let spaceRubber: CGFloat = 70
        /// Half keeps its height above the bottom on taller and shorter
        /// screens; full keeps its top.
        static func halfTop(screenHeight: CGFloat) -> CGFloat { screenHeight - (screen.height - halfTop) }
        /// One content box, centered, the same at half and at full height: 386.
        static func contentWidth(screen: CGFloat) -> CGFloat { screen - Edge.sheet * 2 }
        static let stripTop: CGFloat = 26
        static let spacePadding: CGFloat = 12
        static let spaceBottomPadding: CGFloat = 100
        // The space's name.
        static let nameTop: CGFloat = 10
        static let nameBottom: CGFloat = 12
        static let nameHorizontal: CGFloat = 12
        static let nameGap: CGFloat = 8
        static let nameFont: CGFloat = 20
        // Rows.
        static let row: CGFloat = 44
        static let rowWithSubtitle: CGFloat = 52
        static let rowPadding: CGFloat = 12
        static let rowGap: CGFloat = 12
        static let rowRadius: CGFloat = 12
        /// A row inside a folder: its icon right under the folder's name.
        static let nestedLeading: CGFloat = 44
        static let rowFont: CGFloat = 16
        static let rowIcon: CGFloat = 20
        // The line between kept and today, and Clear on it.
        static let lineHeight: CGFloat = 32
        static let lineMargin: CGFloat = 4
        // Pins: the whole width, at most five a row, rows as even as they can be.
        static let pinHeight: CGFloat = 52
        static let pinGap: CGFloat = 8
        static let pinRadius: CGFloat = 14
        static let pinIcon: CGFloat = 24
        static let pinsPerRow = 5
        static let pinRowsMax = 3
        // The grab bar.
        static let grabWidth: CGFloat = 38
        static let grabHeight: CGFloat = 5
        static let grabTop: CGFloat = 7
        // The capsule of spaces at the bottom: + and Chats round, 8 apart, 362 in all.
        static let barWidth: CGFloat = 362
        static let barHeight: CGFloat = 50
        static let barBottom: CGFloat = 16
        static let barButton: CGFloat = 50
        static let capsuleInset: CGFloat = 58
        static let lensHeight: CGFloat = 40
        /// The lens is this much wider than the name under it.
        static let lensExtra: CGFloat = 8
        static let nameInCapsuleFont: CGFloat = 15.5
        static let nameInCapsulePadding: CGFloat = 14
        static let capsuleFade: CGFloat = 22
        /// How far the side buttons step aside while the capsule is swiped.
        static let sideStep: CGFloat = 70
        // Swipes on a tab row: past 250 a long swipe acts, its capsule grows to 300.
        static let swipeAct: CGFloat = 250
        static let swipeCapsuleFull: CGFloat = 300
        static let swipeCapsule = CGSize(width: 96, height: 36)
        /// The page behind the open column: how much smaller and how round.
        static let pageShrink: CGFloat = 0.06
        static let pageRadius: CGFloat = 30
    }

    // MARK: - the field

    enum Field {
        static let height: CGFloat = 48
        static let radius: CGFloat = height / 2
        static let leading: CGFloat = 14
        static let trailing: CGFloat = 8
        static let gap: CGFloat = 8
        /// 17, where people type: iOS doesn't zoom the page.
        static let font: CGFloat = 17
        /// The keyboard the prototype draws, and the field 10 over it.
        static let keyboard: CGFloat = 302
        static let aboveKeyboard: CGFloat = 8
        /// Safari's field: 8 from the screen's sides, its ✕ in a 48 circle 7 beside it.
        static let side: CGFloat = 8
        static let close: CGFloat = 48
        static let closeGap: CGFloat = 7
        /// New Tab: the field inside its card, 8 from the screen as the
        /// typed rows' card is, 48 high.
        static let newTabHeight: CGFloat = 48
        static let newTabInset: CGFloat = 8
        /// The ✕ on its gray plate, 32 to see, 44 to hit.
        static let clear: CGFloat = 32
    }

    // MARK: - sheets: chat, code, the yes, settings

    enum Sheet {
        static let radius: CGFloat = 38
        /// A chat at full height, from the screen's top.
        static let fullTop: CGFloat = 60
        /// An answer, before it is a chat.
        static let answerTop: CGFloat = 400
        /// The page behind a full chat.
        static let pageScale: CGFloat = 0.94
        static let headHeight: CGFloat = 50
    }

    // MARK: - radii, icons, text

    enum Radius {
        static let sheet: CGFloat = 38
        static let card: CGFloat = 24
        static let row: CGFloat = 12
        static let pin: CGFloat = 14
        /// Plate and field: half their height.
        static func capsule(_ height: CGFloat) -> CGFloat { height / 2 }
    }

    enum Icon {
        static let row: CGFloat = 20
        static let pin: CGFloat = 24
        static let now: CGFloat = 28
        static let plate: CGFloat = 18
    }

    enum Text {
        static let field: CGFloat = 17
        static let row: CGFloat = 16
        static let chat: CGFloat = 15.5
        static let caption: CGFloat = 13
        static let spaceTitle: CGFloat = 20
    }

    /// Small capsules (Hide, Keep, Retry): 32 to see, 44 to hit.
    static let capsuleButton: CGFloat = 32

    // MARK: - the page

    enum Page {
        /// Where the page shrinks toward as it steps back behind a sheet: 50%
        /// across, 32% down.
        static let recedeAnchor = UnitPoint(x: 0.5, y: 0.32)
        /// Pages pad their tops by the prototype's status bar (--top).
        static let top: CGFloat = 54
        /// Each test page ends with this much room for the plate.
        static let bottomSpace: CGFloat = 120
        /// Paging tabs: the page slots are this far apart; the plate's label
        /// moves by x times the plate's width over it.
        static let slot: CGFloat = 416
        /// Safari's pages (its recording, 2026-10-08): the one coming in starts
        /// `lead` beyond the screen's edge and moves `lag` times the finger, so
        /// the gap between the two closes from 117 to 33 as they turn.
        static let lead: CGFloat = 117
        static let lag: CGFloat = 1.2
        /// The pages' corners while they move: the screen's.
        static let cardCorner: CGFloat = 55
        /// A paging swipe commits past this, projected by velocity x 0.2.
        static let commit: CGFloat = 150
        static let projection: CGFloat = 0.2
        /// Resistance at the ends: past the first or last tab, past New Tab.
        static let rubber: CGFloat = 70
        static let rubberPastNewTab: CGFloat = 40
        /// How far a finger pulls against a rubber band (the first tab, a
        /// page with nothing behind) before its wall is felt.
        static let resistFelt: CGFloat = 24
        /// The blank page past the last tab: #EDEDF1.
        static let blank = RGB(0xED, 0xED, 0xF1)
    }

    // MARK: - menus

    enum Menu {
        static let row: CGFloat = 44
        static let padding: CGFloat = 6
        static let icon: CGFloat = 19
        static let iconBox: CGFloat = 24
        static let gap: CGFloat = 12

        /// Holding the plate: 44 from the sides, 10 over the plate, out of it.
        enum Plate {
            static let inset: CGFloat = 44
            static let bottom: CGFloat = 86
            static let radius: CGFloat = 26
            static let rowRadius: CGFloat = 14
            static let font: CGFloat = 16.5
            /// The page's short title over the items.
            static let headFont: CGFloat = 13
            static let headIcon: CGFloat = 18
            /// It grows from .6 of its size, 30 lower.
            static let fromScale: CGFloat = 0.6
            static let fromDrop: CGFloat = 30
        }

        /// ⋯ beside a space's name: 6 under it, right edges aligned.
        enum Space {
            static let width: CGFloat = 250
            static let radius: CGFloat = 22
            static let rowRadius: CGFloat = 16
            static let font: CGFloat = 16
            static let below: CGFloat = 6
            static let fromScale: CGFloat = 0.3
        }

        /// Holding +: New Tab, New Chat; 8 from the sheet's right, 76 from its bottom.
        enum Plus {
            static let width: CGFloat = 210
            static let radius: CGFloat = 22
            static let right: CGFloat = 8
            static let bottom: CGFloat = 76
            static let heldScale: CGFloat = 1.08
        }

        /// A chat's ⋯: 12 from the right.
        enum Chat {
            static let width: CGFloat = 250
            static let radius: CGFloat = 24
            static let rowRadius: CGFloat = 16
            static let font: CGFloat = 16
        }
    }

    // MARK: - holding a row, swiping a row

    enum Hold {
        /// A held tab: a sketch of its page and its row.
        static let tabSketch: CGFloat = 104
        static let tabRow: CGFloat = 46
        static let tabMenuWidth: CGFloat = 236
        /// The lifted row in hand.
        static let carriedScale: CGFloat = 1.03
        static let carriedRadius: CGFloat = 16
        /// How long a hold takes, and how far the finger moves to carry instead.
        static let duration: TimeInterval = 0.46
        static let carryAfter: CGFloat = 10
    }

    enum Swipe {
        /// Tab rows: a 96 x 36 capsule, the word inside.
        static let tabCapsule = CGSize(width: 96, height: 36)
        static let tabWord: CGFloat = 14
        static let tabOpen: CGFloat = 108
        static let tabCardRadius: CGFloat = 22
        /// A long swipe acts past 250; its capsule grows to 300; pulled past 330 it resists.
        static let act: CGFloat = 250
        static let fullCapsule: CGFloat = 300
        static let limit: CGFloat = 330
    }

    // MARK: - the field's cards and New Tab

    enum FieldAnswer {
        static let height: CGFloat = 84
        static let control: CGFloat = 44
        static let arrow: CGFloat = 15
        static let noteGap: CGFloat = 3
        static let sidePadding: CGFloat = 6
        static let minimumScale: CGFloat = 0.6
        static let keysHeight: CGFloat = 56
        static let keysInset: CGFloat = 8
        static let keysVertical: CGFloat = 6
        static let keysGap: CGFloat = 4
        static let keyRadius: CGFloat = 8
    }

    enum FieldCard {
        /// The page's card over the plate's field: 10 over it, the bars' edges.
        static let radius: CGFloat = 24
        static let headPadding = EdgeInsets(top: 14, leading: 16, bottom: 13, trailing: 16)
        static let headIcon: CGFloat = 30
        static let headTitle: CGFloat = 16
        static let headSubtitle: CGFloat = 13
        /// Copy Link, Share, Ask, On Mac: four equal cells.
        static let actionHeight: CGFloat = 62
        static let actionIcon: CGFloat = 21
        static let actionLabel: CGFloat = 12
        /// Rows for typed words: the icon's column.
        static let rowIconColumn: CGFloat = 22
    }

    enum NewTab {
        /// The approved phone space picker, between New Tab and Done.
        static let spacePickerGap: CGFloat = 6
        static let spacePickerLabelInset: CGFloat = 12
        static let spacePickerControlGap: CGFloat = 12
        static let spacesHeaderMark: CGFloat = 30
        /// All Tabs into the spaces sidebar, in place: how blurred the one going is.
        static let sidebarBlur: CGFloat = 18
        /// The Chats page's chats as cards, two a row (the A5 pick, 2026-10-13):
        /// a chat whose agent went to sites lies as a stack, a sheet behind it
        /// for one site, two for three and more.
        static let chatCardGap: CGFloat = 10
        static let chatCardRadius: CGFloat = 22
        static let chatCardPadding: CGFloat = 14
        static let chatCardHeight: CGFloat = 150
        static let chatCardFavicon: CGFloat = 20
        static let chatStackStep: CGFloat = 6
        /// The card: 8 from the sides, below the status bar, 8 over the keyboard.
        static let inset: CGFloat = 8
        static let top: CGFloat = 64
        static let maxHeight: CGFloat = 502
        static let bottom: CGFloat = 310
        static let radius: CGFloat = 30
        static let row: CGFloat = 52
        static let rowPadding = EdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8)
        static let rowRadius: CGFloat = 14
        static let sectionFont: CGFloat = 12
        static let sectionPadding = EdgeInsets(top: 12, leading: 10, bottom: 6, trailing: 10)
        /// Frequent: tiles and their names.
        static let tile: CGFloat = 48
        static let tileName: CGFloat = 11
        /// The field's bottom, inside the card.
        static let fieldBottom: CGFloat = 322
        /// The eyes: 36 high, at least 40 wide.
        static let eyesHeight: CGFloat = 36
        static let eyesMinWidth: CGFloat = 40
    }

    // MARK: - the chat sheet, Your Chats

    enum Chat {
        /// An answer's head, and a chat's at full height.
        static let answerHead: CGFloat = 50
        static let chatHead: CGFloat = 92
        static let headButton: CGFloat = 44
        static let whoIcon: CGFloat = 22
        static let whoFont: CGFloat = 16
        static let wherePill: CGFloat = 12.5
        /// The answer's height grows to at most this much of turns.
        static let answerTurnsMax: CGFloat = 330
        /// The question's bubble: at most 290 wide, 20 round but its corner;
        /// one line of 17 stands 38 tall, as in Messages.
        static let bubbleMaxWidth: CGFloat = 290
        static let bubblePadding = EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        static let bubbleRadius: CGFloat = 20
        static let bubbleCorner: CGFloat = 6
        static let text: CGFloat = 17
        static let lineHeight: CGFloat = 1.5
        static let byline: CGFloat = 12
        static let actionFont: CGFloat = 13.5
        static let actionIcon: CGFloat = 15
        static let actionGap: CGFloat = 18
        static let pagePill: CGFloat = 28
        /// The follow-up field.
        static let field: CGFloat = 46
        static let fieldRadius: CGFloat = 23
        static let sendButton: CGFloat = 34
        static let footAnswer: CGFloat = 14
        static let footFull: CGFloat = 30
        /// Who: the face in its circle, the title, its line.
        static let face: CGFloat = 30
        static let titleFont: CGFloat = 15
        static let lineFont: CGFloat = 12
    }

    enum Chats {
        static let head: CGFloat = 60
        static let titleFont: CGFloat = 30
        static let rowRadius: CGFloat = 14
        static let rowIconBox: CGFloat = 34
        /// Search at the bottom, New Chat beside it, 30 over the screen's bottom.
        static let searchWidth: CGFloat = 320
        static let searchHeight: CGFloat = 50
        static let newChat: CGFloat = 50
        static let footBottom: CGFloat = 30
        /// Searching, the bar rides on the keyboard.
        static let searchingBottom: CGFloat = 312
        static let footFade: CGFloat = 120
        /// The Chats button's count: violet, 18 round, at the corner.
        static let badge: CGFloat = 18
        static let badgeFont: CGFloat = 11
    }

    // MARK: - sheets for the person: the code, the yes, Face ID

    enum Code {
        static let radius: CGFloat = 34
        /// Over the number pad.
        static let bottom: CGFloat = 300
        static let headIcon: CGFloat = 30
        static let headTitle: CGFloat = 18
        static let headLine: CGFloat = 13.5
        static let box: CGFloat = 52
        static let boxGap: CGFloat = 8
        static let boxRadius: CGFloat = 12
        static let digit: CGFloat = 24
        /// The number pad: QuickType on top, then keys.
        static let pad: CGFloat = 292
        static let quickType: CGFloat = 48
        static let key: CGFloat = 47
        static let keyGap: CGFloat = 7
        static let keyRadius: CGFloat = 8
        static let keyDigit: CGFloat = 25
    }

    enum Consent {
        static let factsRadius: CGFloat = 16
        static let factsLabel: CGFloat = 70
        static let pay: CGFloat = 52
        static let payRadius: CGFloat = 16
        static let notNow: CGFloat = 44
        /// The Face ID panel, centered.
        static let faceID: CGFloat = 150
        static let faceIDRadius: CGFloat = 34
        static let faceIDGlyph: CGFloat = 66
    }

    enum Settings {
        static let top: CGFloat = 60
        /// The iPad's card: its head this far in from the card's top, as from its sides.
        static let cardTop: CGFloat = 12
        static let titleFont: CGFloat = 28
        static let groupRadius: CGFloat = 16
        /// A page's row as tall as the root's, its icon the root's tile.
        static let row: CGFloat = 50
        static let iconBox: CGFloat = 30
        static let iconRadius: CGFloat = 8
        static let sectionGap: CGFloat = 22
    }

    // MARK: - outside Yab

    enum Island {
        static let size = CGSize(width: 126, height: 37)
        static let top: CGFloat = 11
        static let radius: CGFloat = 19
        static let compactWidth: CGFloat = 200
        static let expanded = CGSize(width: 378, height: 168)
        static let expandedRadius: CGFloat = 46
    }

    enum LiveActivity {
        static let bottom: CGFloat = 118
        static let radius: CGFloat = 26
        static let padding = EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        static let button: CGFloat = 34
        static let title: CGFloat = 21
    }

    /// The system's home indicator, for frames drawn around it.
    static let homeIndicator = CGSize(width: 140, height: 5)
    /// Where the scroll edge's fade is drawn: a 26-point band, blurred 6.
    static let scrollEdge: CGFloat = 26
}
