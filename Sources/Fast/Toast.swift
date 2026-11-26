import SwiftUI

/// Whether a notice, "Link copied", "Bookmarked", is up. An object of its own rather than a
/// property of the browser: the whole window watches the browser, and a
/// notice that comes and goes in a corner has no business laying out the
/// tabs, the column and the page twice over on its way through.
@MainActor
final class Toaster: ObservableObject {
    @Published private(set) var shown = false
    /// Pressed again while it is up: counts, so the corner can answer each.
    @Published private(set) var nods = 0

    /// What it says, and what it wears: the chain, or another mark, a key
    /// for a copied password, a hand for a key a request wants. The
    /// same corner and motion answer all of them: one kind of notice for
    /// one kind of act. Set before `shown`, so the words are in place
    /// before anything moves.
    @Published private(set) var words = "Link copied"
    @Published private(set) var mark: String?
    /// The keys it teaches, set after the words as a button sets its key:
    /// "Send with ⌘↩".
    @Published private(set) var keys: [String] = []
    /// What its Undo does, for a notice that offers one: a tab sent to
    /// another space. Set with the words.
    private(set) var undo: (() -> Void)?
    /// The button's word, when the one thing it offers isn't an undo: a
    /// hint's Split View or Set Up (Teach.swift). Set with the words.
    @Published private(set) var act: String?
    /// The tab it names, a link's opened behind the page: its favicon for
    /// the mark, as its row has it, there as soon as the tab has one. Set
    /// with the words.
    private(set) weak var page: Tab?
    /// Something flew to where it stands and became it (mail's Send,
    /// MailMorph): it comes up there, without coming out from under the edge.
    @Published private(set) var landing = false
    /// When what it says happens, for words that count down to it: mail's
    /// "Sending in 5s" while ⌘Z can still take the send back. Set with the
    /// words; `span` is the count it started from, for its width.
    @Published private(set) var until: Date?
    private(set) var span = 0
    /// Taken off where it stands (mail's ⌘Z on a send): gone at once, what
    /// flies from there is it now.
    private(set) var lifted = false

    /// How long it stays up when it says something to act on.
    static let stay: TimeInterval = 1.6
    /// A copy only says it happened, and is done sooner.
    static let brief: TimeInterval = 1.2

    private var hush: DispatchWorkItem?

    /// `stay`, for a notice that asks for something and is good for as long
    /// as the asking is: "Again to remove it" while the second press counts.
    func pop(_ words: String = "Link copied", mark: String? = nil, keys: [String] = [], stay asked: TimeInterval? = nil,
             undo: (() -> Void)? = nil, act: String? = nil, feedback: NoticeFeedback? = nil, landing: Bool = false,
             until: Date? = nil, page: Tab? = nil) {
        self.landing = landing
        lifted = false
        // One apostrophe, the typeset one, whoever wrote the words.
        let words = words.replacingOccurrences(of: "'", with: "\u{2019}")
        let offered = (self.undo != nil) != (undo != nil) || self.act != act
        self.undo = undo
        self.page = page
        let counting = until != self.until
        if counting { span = until.map { Notice.count($0, at: Date()) } ?? 0 }
        // Something else said while it is up: the new words, and a nod.
        if shown, words != self.words || keys != self.keys || offered || counting {
            self.words = words; self.mark = mark; self.keys = keys; self.act = act; self.until = until; nods += 1
        }
        else if shown { nods += 1 }
        else { self.words = words; self.mark = mark; self.keys = keys; self.act = act; self.until = until; shown = true }
        feedback?.play()
        hush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.shown = false }
        hush = work
        let stay = asked ?? (act != nil ? Toaster.offered : undo != nil ? Toaster.undoable : words.hasSuffix(Say.copied) && keys.isEmpty ? Toaster.brief : Toaster.stay)
        DispatchQueue.main.asyncAfter(deadline: .now() + stay, execute: work)
    }

    /// What it says now, for the corner.
    var said: Say { Say.toast(words, mark: mark, keys: keys, undo: undo != nil, act: act, until: until, span: span, page: page?.id) }

    /// A notice with Undo stays long enough to reach it.
    static let undoable: TimeInterval = 4
    /// A hint offering a thing to do is read before it is weighed.
    static let offered: TimeInterval = 7

    /// Undo pressed: done, and the notice goes.
    func undone() {
        let then = undo
        undo = nil
        hush?.cancel()
        shown = false
        then?()
    }

    /// Put a toast away without taking its Undo action.
    func dismiss() {
        hush?.cancel()
        undo = nil
        shown = false
    }

    /// Put away where it stands, at once: something takes off from there.
    func lift() {
        lifted = true
        dismiss()
    }

    /// The pointer over a notice with Undo holds it up; leaving gives it a
    /// little longer.
    func hold(_ on: Bool) {
        guard shown, undo != nil else { return }
        hush?.cancel()
        guard !on else { return }
        let work = DispatchWorkItem { [weak self] in self?.shown = false }
        hush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}

/// What the corner says, whichever of the two is saying it: a mark, the
/// words that change, and what follows them, "copied", which every copy
/// shares, or the tidy-up's Undo.
struct Say: Equatable {
    enum Mark: Equatable { case symbol(String), emoji(String), broom, page(Tab.ID) }
    enum Tail: Hashable { case none, copied, undo, show, keys([String]), act(String) }

    var mark: Mark
    var head: String
    var tail: Tail
    /// Counting down to this: the head is said as "Sending in 4s", its
    /// width that of the count it started from (`span`).
    var until: Date? = nil
    var span = 0

    static let copied = " copied"

    /// Its button does a thing rather than take one back.
    var act: Bool { if case .act = tail { true } else { false } }

    /// "Password copied" is "Password" and the word every copy shares, so
    /// only the first changes when one copy follows another.
    static func toast(_ words: String, mark: String?, keys: [String] = [], undo: Bool = false, act: String? = nil,
                      until: Date? = nil, span: Int = 0, page: Tab.ID? = nil) -> Say {
        // A space's emoji stands where a symbol would: "Work", not a stack
        // and "💼 Work".
        let symbol = page.map(Mark.page) ?? mark.map { Spaces.isEmoji($0) ? Mark.emoji($0) : Mark.symbol($0) } ?? .symbol("link")
        if undo, let act { return Say(mark: symbol, head: words, tail: .act(act), until: until, span: span) }
        if undo { return Say(mark: symbol, head: words, tail: .undo, until: until, span: span) }
        if !keys.isEmpty { return Say(mark: symbol, head: words, tail: .keys(keys), until: until, span: span) }
        guard words.hasSuffix(copied) else { return Say(mark: symbol, head: words, tail: .none, until: until, span: span) }
        return Say(mark: symbol, head: String(words.dropLast(copied.count)), tail: .copied)
    }

    static func tidy(_ count: Int) -> Say {
        Say(mark: .broom, head: count == 1 ? "Cleared a tab" : "Cleared \(count) tabs", tail: .undo)
    }

    /// An agent waiting on you in a tab you aren't looking at.
    static func call(_ name: String) -> Say {
        Say(mark: .symbol("hand"), head: "\(name) needs you", tail: .show)
    }

}

/// The page's top right corner, where the browser says everything it
/// says: ⌘⇧C's "Link copied", the passwords page's copies, "Bookmarked",
/// "Paused", the tidy-up with its Undo. ⌘Q asks in a card (Links).
///
/// It says one thing, so it
/// comes whole and already composed (P3), out from under the page's top
/// edge, the address it is about is just above, and goes back the way it
/// came, quicker. Nothing opens, draws or bounces on the way: a copy is
/// done many times a day, and the paths used all day stay quiet (P10).
///
/// It is one surface, never a stack (P1). Whoever spoke last is what it
/// says: a copy over a tidy-up, a tidy-up over a copy, and back to the
/// tidy-up when the copy is done. Changing, it keeps its place and its
/// mark's square; the words that differ cross over each other while the
/// width follows, and "copied", said by every copy, holds (P5).
///
/// The same copy again moves nothing: the mark dims for a frame and comes
/// back, the way a key answers a press (P6). The broom's one sweep is kept
/// for the tidy-up, rare, and worth noticing.
///
/// Always in the tree, never inserted: at the moment of the press there is
/// nothing to build, measure or decode, only values to animate.
struct Notice: View {
    /// Only asked to undo, never watched: see Toaster.
    let browser: Browser
    @ObservedObject var toaster: Toaster
    @ObservedObject var tidier: Tidier
    /// An agent waiting on you elsewhere: said until it's answered, and
    /// come back to after anything said over it.
    @ObservedObject var agents: Agents
    /// From the edge it comes out from under to where it rests.
    var top: CGFloat
    /// The browser's own corner, which says an agent is waiting on you and
    /// is where mail's Send lands; a small window's (LinkWindow) only says
    /// its own copies.
    var browsers = true

    @State private var say = Say.toast("Link copied", mark: nil)
    @State private var up = false
    @State private var dim = false
    @State private var over = false
    @State private var dismissedCall: NoticeCallTarget?
    @State private var shownCall: NoticeCallTarget?
    /// Its ground is in the tree only while it is up or on its way back:
    /// glass tucked away above the edge was still two backdrop layers and
    /// some thirty more the window server kept compositing under every
    /// scroll of the page.
    @State private var lit = false
    /// Come up where it stands, something having flown there (Toaster.landing).
    @State private var landed = false
    /// The broom's sweep, in degrees, and each spark's size.
    @State private var sweep: Double = 0
    @State private var big: CGFloat = 1
    @State private var small: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var still

    /// A tab's height and corners: it sits right under the row of them.
    static let side: CGFloat = 28
    static let corner: CGFloat = Radius.control
    static let icon: CGFloat = 15
    /// A tab title's size, as the row it sits under writes it.
    static var font: NSFont { .systemFont(ofSize: SidebarTypography.current) }
    static var undoFont: NSFont { font }
    /// The same air at both ends as the eye reads it, measured on screen,
    /// mark and words both stand about half a point inside their boxes, so
    /// the two sides are set alike (the mark in the middle of a tab's
    /// square left it 7.5 against the words' 11.5). Mark and words sit
    /// nearer each other than either is to an edge, so they read as one.
    static let trail: CGFloat = 12
    private static let lead: CGFloat = trail
    static let gap: CGFloat = 5
    static let undo = "Undo"
    /// Room around it inside the clip, for its shadow.
    private static let air: CGFloat = 12

    /// Widths worked out from the words, not measured: a measurement
    /// arrives a frame late, and that frame would be the first one of the
    /// animation.
    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    /// The most the words may take. A notice says one short thing; a name
    /// or an error longer than this is cut, not let to stretch the plate
    /// across the page.
    static var longest: CGFloat { 240 * font.pointSize / 12 }

    static func headWidth(_ text: String) -> CGFloat {
        min(width(text, font), longest)
    }

    /// The head's width saying this: a count's is the count it started
    /// from in the font's even digits, so the plate holds its width as the
    /// seconds go.
    static func headWidth(_ say: Say) -> CGFloat {
        guard say.until != nil else { return headWidth(say.head) }
        return min(width(counting(say.head, say.span, span: say.span), digits), longest)
    }

    /// Digits all as wide as each other, for a count.
    private static var digits: NSFont { .monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular) }

    /// Whole seconds left until then, at least one while it is said.
    static func count(_ until: Date, at now: Date) -> Int {
        max(1, Int((until.timeIntervalSince(now) - 0.001).rounded(.up)))
    }

    /// "Sending in 4s": a figure space for each digit the count has lost
    /// since it began, so the words keep their width as well as the plate.
    static func counting(_ head: String, _ left: Int, span: Int) -> String {
        let pad = max(0, String(span).count - String(left).count)
        return head + " in " + String(repeating: "\u{2007}", count: pad) + String(left) + "s"
    }

    /// Its size saying this, for what flies to where it will stand.
    static func size(of say: Say) -> CGSize {
        CGSize(width: lead + icon + gap + headWidth(say) + tailWidth(say.tail), height: side)
    }

    /// `keys`: the Undo's key, for the tidy-up's.
    private static func tailWidth(_ tail: Say.Tail, keys: String = "") -> CGFloat {
        switch tail {
        case .none: return trail
        case .copied: return width(Say.copied, font) + trail
        case .undo: return ToastButton.width(width(undo, undoFont), keys: keys)
        case .act(let title): return ToastButton.width(width(title, undoFont))
        case .show: return ToastButton.width(width("Show", undoFont))
        case .keys(let keys): return KeyCaps.width(keys) + KeyCaps.inset
        }
    }

    /// The new words up from under, the old ones up and away, quicker, as
    /// every exit is, so they are gone before the new ones have settled.
    private var swap: AnyTransition {
        still ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)),
            removal: .opacity.combined(with: .offset(y: -6)).animation(.easeIn(duration: 0.1))
        )
    }

    var body: some View {
        let head = Self.headWidth(say)
        let flingCall = shownCall
        // The tidy-up's Undo teaches its key; another Undo has none.
        let tail = Self.tailWidth(say.tail, keys: toaster.shown && toaster.undo != nil ? "" : Keymap.shared.text(.reopen))
        HStack(spacing: 0) {
            ZStack { mark.transition(.opacity) }
                .frame(width: Self.icon, height: Self.icon)
                .opacity(dim ? 0.3 : 1)
                .padding(.leading, Self.lead)
                .padding(.trailing, Self.gap)
            // The words that change, against the ones that stay.
            ZStack(alignment: .trailing) {
                words
                    .font(Font(Self.font))
                    .foregroundStyle(HUD.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: head, alignment: .trailing)
                    .id(say.head)
                    .transition(swap)
            }
            .frame(width: head, alignment: .trailing)
            ZStack(alignment: .leading) {
                ending
                    .id(say.tail)
                    .transition(swap)
            }
            .frame(width: tail, alignment: .leading)
        }
        .frame(width: Self.lead + Self.icon + Self.gap + head + tail, height: Self.side, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .background { if lit { HUD.plate(Self.corner, space: browser.prefs.swatch.color(dark: false, custom: browser.prefs.backdropColor)) } }
        .noticeFling(.top, token: "\(say.head)|\(say.tail)|\(toaster.nods)|\(tidier.count)|\(flingCall?.flingToken ?? "none")") {
            dismiss(say, call: flingCall)
        }
        // Tucked up under the edge, whole, until it is wanted; with less
        // motion asked for, it is simply there.
        .offset(y: up || still || landed ? 0 : -(top + Self.side + Self.air))
        .opacity(up || !(still || landed) ? 1 : 0)
        // Where it stands when up: mail's Send flies here (MailMorph).
        .background { if browsers { MailPlace(kind: .notice) } }
        .onHover { on in
            guard say.tail == .undo || say.act else { return }
            if toaster.shown, toaster.undo != nil { toaster.hold(on) } else { tidier.hold(on) }
        }
        // After onHover: on macOS 15 a hover region outside this still took
        // clicks at the tucked-away notice's resting place, the page's top right.
        .allowsHitTesting(up)
        .accessibilityHidden(!up)
        .padding(.top, top)
        .padding([.leading, .trailing, .bottom], Self.air)
        // The edge it comes from: the page's top, or the find bar over it.
        .clipped()
        .padding([.leading, .trailing, .bottom], -Self.air)
        .onChange(of: toaster.shown) { _, shown in
            if shown { show(toaster.said) }
            else if tidier.shown { show(Say.tidy(tidier.count)) }
            else { settle() }
        }
        .onChange(of: callTarget) { _, now in
            if now == nil { dismissedCall = nil }
            if toaster.shown || tidier.shown { return }
            settle()
        }
        .onChange(of: toaster.nods) { _, _ in
            let new = toaster.said
            new == say ? nod() : show(new)
        }
        .onChange(of: tidier.shown) { _, shown in
            if shown { show(Say.tidy(tidier.count)) }
            else if toaster.shown { show(toaster.said) }
            else { settle() }
        }
        .onAppear { settle() }
        .onChange(of: tidier.count) { _, count in
            if tidier.shown { show(Say.tidy(count)) }
        }
    }

    /// The head, or, counting down, the head and the seconds left, a new
    /// count each second: only the digit rolls over, the words stay.
    @ViewBuilder private var words: some View {
        if let until = say.until {
            let span = say.span
            TimelineView(.periodic(from: until.addingTimeInterval(-Double(span)), by: 1)) { context in
                let left = Self.count(until, at: context.date)
                Text(Self.counting(say.head, left, span: span))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(still ? nil : Motion.quick, value: left)
            }
        } else {
            Text(say.head)
        }
    }

    @ViewBuilder private var mark: some View {
        switch say.mark {
        case .symbol(let name):
            Symbol(name, size: Self.icon * 0.72, weight: .medium)
                .foregroundStyle(Self.tone(name))
                .id(name)
        case .emoji(let mark):
            Text(mark)
                .font(.system(size: Self.icon * 0.8))
                .id(mark)
        case .broom:
            Broom(sweep: sweep, big: big, small: small)
                .foregroundStyle(HUD.muted)
        case .page(let id):
            if let tab = toaster.page, tab.id == id {
                // The plate is dark in a light window too.
                Mark(icon: tab.displayIcon, letter: tab.monogram, size: Self.icon)
                    .environment(\.colorScheme, .dark)
                    .id(id)
            }
        }
    }

    /// A mark is quieter than the words, except a warning's: what didn't
    /// work reads at the words' own weight, with no color to lean on.
    static func tone(_ mark: String) -> Color {
        mark.hasPrefix("exclamationmark") ? HUD.ink : HUD.muted
    }

    @ViewBuilder private var ending: some View {
        switch say.tail {
        case .none:
            Color.clear.frame(width: Self.trail, height: Self.side)
        case .copied:
            Text(Say.copied)
                .font(Font(Self.font))
                .foregroundStyle(HUD.ink)
                .fixedSize()
                .padding(.trailing, Self.trail)
        case .keys(let keys):
            KeyCaps(keys: keys)
                .padding(.trailing, KeyCaps.inset)
                .frame(height: Self.side)
        case .act(let title):
            Button(title) { toaster.undone() }
                .buttonStyle(ToastButton(font: Font(Self.undoFont)))
                .focusable(false)
        case .show:
            Button("Show") {
                guard let target = shownCall else { settle(); return }
                let result = target.show(current: callTarget) { BrowserWindows.shared.reveal($0) != nil }
                if result != .stale { dismissedCall = target }
                settle()
            }
            .buttonStyle(ToastButton(font: Font(Self.undoFont)))
            .focusable(false)
        case .undo:
            if toaster.shown, toaster.undo != nil {
                Button(Self.undo) { toaster.undone() }
                    .buttonStyle(ToastButton(font: Font(Self.undoFont)))
                    .focusable(false)
                    .keyTip("Bring them back")
            } else {
                // ⌘⇧T brings a tidy-up back as Undo does, so the button
                // says so: the way to have them back after it has gone.
                Button {
                    for batch in tidier.batches.reversed() { browser.untidy(batch) }
                } label: {
                    let keys = Keymap.shared.text(.reopen)
                    HStack(spacing: ToastButton.keyGap) {
                        Text(Self.undo)
                        if !keys.isEmpty { KeyGlyphs(keys: keys, size: KeyCaps.size, tint: nil, rest: 0.6) }
                    }
                }
                .buttonStyle(ToastButton(font: Font(Self.undoFont)))
                .focusable(false)
                .keyTip("Bring them back", shortcut: "Reopen Closed Tab")
            }
        }
    }

    /// Up with these words, or, already up, these words in place of the
    /// others.
    private func show(_ new: Say) {
        if new.tail != .show { shownCall = nil }
        let broom = new.mark == .broom && (!up || say.mark != .broom)
        if !up {
            // The words in place before anything moves.
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { say = new; over = false; lit = true; landed = toaster.landing }
            withAnimation(still ? Motion.quick : Motion.arrive) { up = true }
        } else if new != say {
            withAnimation(still ? Motion.quick : Motion.arrive) { say = new }
        }
        if broom { flourish() }
    }

    /// With nothing passing, what stays: an agent waiting on you, or nothing.
    private var callTarget: NoticeCallTarget? {
        guard browsers, Agents.speaks(in: browser), let calling = agents.calling,
              let tab = agents.browser?.tabs.first(where: { $0.id == calling.tab }),
              tab.handoff != nil, !agents.sealed(tab), !Agents.inCorner(tab) else { return nil }
        return NoticeCallTarget(tab: tab.id, question: tab.handoffNotice?.id)
    }

    private func settle() {
        if let target = callTarget, target != dismissedCall, let calling = agents.calling {
            shownCall = target
            show(Say.call(calling.name))
        } else {
            shownCall = nil
            if up { hide() }
        }
    }

    private func dismiss(_ current: Say, call capturedCall: NoticeCallTarget?) {
        guard current == say else { return }
        if toaster.shown,
           current == toaster.said {
            toaster.dismiss()
        } else if tidier.shown, current == Say.tidy(tidier.count) {
            tidier.hide()
        } else if current.tail == .show, let capturedCall {
            // A delayed fling belongs to its original question, even when the words match.
            capturedCall.dismiss(current: shownCall == callTarget ? shownCall : nil) { target in
                // Only this notice goes. The question and its permission stay pending.
                dismissedCall = target
                settle()
            }
        }
    }

    private func hide() {
        var quiet = Transaction()
        quiet.disablesAnimations = true
        // Lifted: gone at once. Else back under the edge, however it came.
        if toaster.lifted { return withTransaction(quiet) { landed = true; up = false; lit = false } }
        withTransaction(quiet) { landed = false }
        withAnimation(still ? Motion.quick : Motion.depart) { up = false } completion: {
            if !up { lit = false }
        }
    }

    /// The same thing said again: the mark dims for a frame and is back.
    private func nod() {
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { dim = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            withAnimation(.linear(duration: 0.04)) { dim = false }
        }
    }

    /// The broom's one sweep and its two sparks, the larger first, once
    /// the notice has landed, not on the way.
    private func flourish() {
        var quiet = Transaction()
        quiet.disablesAnimations = true
        guard !still else {
            withTransaction(quiet) { sweep = 0; big = 1; small = 1 }
            return
        }
        withTransaction(quiet) { sweep = -18; big = 0; small = 0 }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.55).delay(0.2)) { sweep = 0 }
        withAnimation(.spring(response: 0.26, dampingFraction: 0.6).delay(0.3)) { big = 1 }
        withAnimation(.spring(response: 0.26, dampingFraction: 0.6).delay(0.38)) { small = 1 }
    }
}

/// The corner's notice held still, words and mark, for a window that has
/// no page corner of its own to say it in: Settings.
struct NoticePlate: View {
    let words: String
    let mark: String?
    var keys: [String] = []
    /// Something done that can be taken back: Undo at its end, as the
    /// page corner's has it (Memory › Days' Forget This Thread).
    var undo: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Notice.gap) {
            Symbol(mark ?? "link", size: Notice.icon * 0.72, weight: .medium)
                .foregroundStyle(Notice.tone(mark ?? "link"))
                .frame(width: Notice.icon, height: Notice.icon)
            HStack(spacing: 0) {
                Text(words)
                    .font(Font(Notice.font))
                    .foregroundStyle(HUD.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: Notice.headWidth(words), alignment: .leading)
                if !keys.isEmpty { KeyCaps(keys: keys) }
            }
            if let undo {
                Button(Notice.undo, action: undo)
                    .buttonStyle(ToastButton(font: Font(Notice.undoFont)))
                    .focusable(false)
                    .padding(.trailing, ToastButton.inset - Notice.trail)
            }
        }
        .padding(.horizontal, Notice.trail)
        .frame(height: Notice.side)
        .background { HUD.plate(Notice.corner) }
    }
}

/// Keys the corner teaches, after the words, the way every button that
/// has a key shows it (Question, Keep): `KeyGlyphs` at the words' size,
/// at 0.6 of the ink, 6 on from the words. "Send with ⌘↩". The corner is
/// as tall as a regular button, and its plates sit in it as a regular
/// button's do: its height less the inset above and below, and the same
/// inset from its end.
struct KeyCaps: View {
    let keys: [String]

    static var size: CGFloat { Notice.font.pointSize }
    static let lead: CGFloat = 6
    static let inset = ButtonSize.regular.keyInset
    static let plate = KeyPlate(height: Notice.side - 2 * ButtonSize.regular.keyInset, pull: 0, corner: Notice.corner - ButtonSize.regular.keyInset)

    private static var widths: [String: CGFloat] = [:]

    /// Worked out before anything moves, as the words' width is (Notice):
    /// the glyphs laid out once, off screen, and kept.
    static func width(_ keys: [String]) -> CGFloat {
        let line = keys.joined()
        let key = "\(size)|\(line)"
        if let known = widths[key] { return lead + known }
        let made = NSHostingView(rootView: KeyGlyphs(keys: line, size: size, tint: nil).environment(\.keyPlate, plate)).fittingSize.width.rounded(.up)
        widths[key] = made
        return lead + made
    }

    var body: some View {
        KeyGlyphs(keys: keys.joined(), size: Self.size, tint: HUD.ink)
            .environment(\.keyPlate, Self.plate)
            .opacity(0.6)
            .padding(.leading, Self.lead)
    }
}

/// The one button the corner holds, Show, Undo, Hand back, as a quiet
/// button (Buttons.swift) sized to sit inside it: 22 high, 3 in from its edge,
/// so its corners are the corner's less 3 (Radius.small), concentric with it
/// the way a tab's close square is with the tab.
struct ToastButton: ButtonStyle {
    let font: Font
    static let inset: CGFloat = 3
    static let padding: CGFloat = 9

    /// From the words' width to the tail's: the gap before it, the button,
    /// and the inset after it. With keys, their plates stand in from the
    /// button's end by its inset, as a small button's do (KeyPlate).
    static func width(_ words: CGFloat, keys: String = "") -> CGFloat {
        guard !keys.isEmpty else { return inset + padding + words + padding + inset }
        return inset + padding + words + keyGap + glyphs(keys) + (padding - plate.pull) + inset
    }

    static let keyGap: CGFloat = 6
    /// The button's plates: its height less the inset top and bottom,
    /// concentric with it as it is with the corner.
    static let plate = KeyPlate(height: Notice.side - inset * 4, pull: padding - inset, corner: Radius.small - inset)

    private static var widths: [String: CGFloat] = [:]

    private static func glyphs(_ keys: String) -> CGFloat {
        let key = "\(KeyCaps.size)|\(keys)"
        if let known = widths[key] { return known }
        let made = NSHostingView(rootView: KeyGlyphs(keys: keys, size: KeyCaps.size, tint: nil).environment(\.keyPlate, KeyPlate(height: plate.height, pull: 0))).fittingSize.width.rounded(.up)
        widths[key] = made
        return made
    }

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, font: font)
    }

    private struct Face: View {
        let configuration: Configuration
        let font: Font
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var still

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(font)
                .environment(\.keyPlate, ToastButton.plate)
                .fixedSize()
                .foregroundStyle(hovering || pressed ? HUD.ink : HUD.muted)
                .padding(.horizontal, ToastButton.padding)
                .frame(height: Notice.side - ToastButton.inset * 2)
                .background(
                    RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                        .fill(HUD.ink.opacity(pressed ? 0.1 : hovering ? 0.06 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                .scaleEffect(pressed && !still ? ButtonSize.small.pressed : 1)
                .animation(pressed ? Press.down : Press.up, value: pressed)
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: hovering)
                .padding(.leading, ToastButton.inset)
                .padding(.trailing, ToastButton.inset)
                .frame(height: Notice.side)
        }
    }
}

/// Identity of one pending question, not just the tab reused by its next ask.
struct NoticeCallTarget: Equatable {
    let tab: UUID
    let question: String?

    enum Result: Equatable { case shown, missing, stale }

    var flingToken: String {
        "\(tab.uuidString)|\(question.map { "q\($0)" } ?? "none")"
    }

    @discardableResult
    func dismiss(current: NoticeCallTarget?, putAway: (NoticeCallTarget) -> Void) -> Bool {
        guard current == self else { return false }
        putAway(self)
        return true
    }

    func show(current: NoticeCallTarget?, reveal: (UUID) -> Bool) -> Result {
        guard current == self else { return .stale }
        return reveal(tab) ? .shown : .missing
    }
}
