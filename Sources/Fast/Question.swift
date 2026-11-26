import AppKit
import SwiftUI

// What yab itself asks, rather than a page: an extension to add, one that
// wants more than it had, one to remove, a choice in Settings that can't be
// taken back, ⌘Q. It wears the card a page's question wears (Asks.swift), the
// well in its corner, the words, the buttons with their keys, where it used
// to be the system's alert, gray glass and all, the one thing on screen that
// wasn't yab's.
//
// In the middle of the window, always, as Arc's: the window asks, not the
// page, so with the sidebar out a card in the middle of the page stood off to
// the right of everything. What waits on you, an extension the store's page
// is adding, ⌘Q, a space to delete, stands over the whole window dimmed,
// sidebar and all, which takes no clicks until it is answered; what an
// extension asks by itself, an update or a reload that wants more,
// permissions.request, stands without it, as another app's link does, since
// nobody is waiting. A question asked from Settings is asked in the middle of
// it, in a window of its own over it (SettingsCards), so a tall one isn't cut. A page's own alert is the page's, and stays on it (Asks.swift).
// Every one comes and goes as ⌘L's field does: in from a touch smaller on
// arrive's curve, gone at once when answered.
//
// In the window it was asked from, the one in front then, and only there:
// with three windows on three screens, Delete Chat's question stood in all
// three (#1097). Its keys are that window's alone; the others go on as ever.
//
// One at a time, for every window: the next waits for the answer. Return
// is the yes, Escape the no; a yes that can't be taken back, Remove, Clear
// History, takes ⌘Return and a bare Return goes nowhere (c110c88).

/// A space as a question's well draws it: its emoji on its color.
struct SpaceWell: Equatable {
    let emoji: String
    let light: NSColor
    let dark: NSColor
}

struct Question: Identifiable, Equatable {
    enum Place: Equatable {
        /// The middle of the window, over the dimming.
        case page
        /// The middle of the window, left undimmed.
        case plain
        /// The middle of the Settings window.
        case settings
    }

    let id = UUID()
    var title: String
    var detail = ""
    /// What it could do, a line each, under the words.
    var lines: [String] = []
    /// More of what it could do, behind "N more" beside the buttons: an
    /// extension's lines after the one that matters most, said in `detail`.
    var folded: [String] = []
    /// Under the folded lines, in the muted gray: what it may ask for later.
    var foldedNote = ""
    /// One glyph for every line, for a list of names rather than of powers.
    var lineGlyph: String? = nil
    /// Its own icon in the corner, an extension's; the glyph on the quiet
    /// well when it has none.
    var icon: NSImage? = nil
    /// The icon is the app's own, cut to the Dock's shape with the Dock's
    /// margin round it: drawn larger, so its tile fills the well as an
    /// extension's square icon does, rather than standing back inside it.
    var ownIcon = false
    var glyph = "puzzlepiece.extension"
    /// A space's emoji on its color in the well, in place of the glyph,
    /// with the glyph small in its corner: what is asked about, and what
    /// is done to it.
    var space: SpaceWell? = nil
    /// Empty: no yes button; the accessory answers it (Questions.answer).
    var yes: String
    var no = "Cancel"
    /// Can't be taken back: red, and ⌘Return.
    var danger = false
    /// A box beside the buttons, "Don't ask again", as a page's card has
    /// one; ticked or not is read from `Questions.ticked` once answered.
    var box: String? = nil
    /// A second yes beside the first, between it and Cancel: the other
    /// way to go on, a button rather than a box that changes what yes
    /// does without the yes saying so. Pressed, `Questions.ticked` is on
    /// and the answer is yes.
    var other: String? = nil
    var place = Place.page
    /// A helper's code window: this card stands above or below it in its
    /// own panel, rather than covering it in the browser or Settings.
    var anchor: QuestionAnchor? = nil
    /// The window it stands in, by number: the browser's or a small
    /// window's for a link that was in front when it was asked. Nil, in
    /// every window, when none of them was there to ask from.
    var window: Int? = nil
    /// Things to tick, none ticked to begin with: what an extension may ask
    /// for later. What is ticked when it is answered is in `ticks`.
    var boxes: [Box] = []
    var ticks: Ticks? = nil
    /// A line to type into under the words, a new name: Return is yes,
    /// Escape no, and yes waits for something typed. What it holds when
    /// answered is read from it by whoever asked.
    var field: Field? = nil
    /// Something of its own under the words, before the field: Add a
    /// Device's code as a QR (SyncInvite).
    var accessory: AnyView? = nil
    /// A review may need explicit choices before its destructive action is
    /// available. This also guards keyboard and semantic answers.
    var enablement: Enablement? = nil
    /// No well in the head: the words alone, when what is under them has
    /// pictures of its own (the ad blocker's tiles).
    var bare = false
    /// Keys of its own, before Return and Escape: the arrows moving a
    /// choice under the words. True when taken.
    var keys: ((NSEvent) -> Bool)? = nil

    struct Box: Hashable {
        let key: String
        let words: String
    }

    final class Field: ObservableObject {
        @Published var text: String
        let prompt: String
        init(_ text: String, prompt: String) {
            self.text = text
            self.prompt = prompt
        }
        var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The ticked boxes, read by whoever asked once it is answered.
    final class Ticks: ObservableObject {
        @Published var on: Set<String> = []
    }

    final class Enablement: ObservableObject {
        @Published var allowed: Bool
        init(_ allowed: Bool = false) { self.allowed = allowed }
    }

    func canAnswer(_ yes: Bool) -> Bool {
        !yes || ((enablement?.allowed ?? true) && (field == nil || field?.trimmed.isEmpty == false))
    }

    static func == (a: Question, b: Question) -> Bool { a.id == b.id }

    /// 380 for a line or two; wider for a list, so each of its lines stays
    /// one. Boxes wrap inside it rather than widening the card.
    var width: CGFloat { bare ? 380 : lines.isEmpty && folded.isEmpty && boxes.isEmpty && accessory == nil && detail.count < 90 ? 380 : 420 }
}

@MainActor
final class Questions: ObservableObject {
    static let shared = Questions()

    @Published private(set) var current: Question?
    /// The box on the question now, or on the one just answered.
    @Published var ticked = false
    /// The question now's folded lines open, under "N more".
    @Published var unfolded = false
    private var owed: CheckedContinuation<Bool, Never>?
    private var waiting: [(Question, CheckedContinuation<Bool, Never>)] = []
    private var keys: Any?
    private var closing: Any?
    /// The windows whose stand shows the card now, by number (Bench).
    var shownIn: Set<Int> = []

    /// Asked where it belongs, once the one before has been answered.
    func ask(_ question: Question) async -> Bool {
        var question = question
        // Asked while Settings is in front, it is answered there.
        if question.anchor == nil, question.place != .settings, SettingsCards.owns(NSApp.keyWindow) { question.place = .settings }
        if question.window == nil { question.window = Self.standing(for: NSApp.keyWindow)?.windowNumber }
        return await withCheckedContinuation { done in
            waiting.append((question, done))
            if current == nil { next() } else if question.place == .settings, current?.place != .settings,
                current?.anchor == nil, SettingsCards.shared.showing {
                // One is up over the browser's window, behind Settings,
                // where this one would wait for it unseen: brought to
                // Settings, so what is asked first is answered first (#379).
                current?.place = .settings
            }
        }
    }

    /// A question no longer worth an answer (what it asked about moved on):
    /// answered no if it is up, taken out of the queue if it waits.
    func withdraw(_ id: UUID) {
        if current?.id == id { return answer(false) }
        guard let index = waiting.firstIndex(where: { $0.0.id == id }) else { return }
        waiting.remove(at: index).1.resume(returning: false)
    }

    /// Settings closed: the question up in it is answered no, as Escape
    /// would have, rather than left up where nothing shows it. Up there and
    /// unseen, it held every question after it, so Delete Space… and an
    /// extension's Remove… did nothing at all (#379).
    func settingsClosed() {
        if current?.place == .settings { answer(false) }
    }

    func answer(_ yes: Bool) {
        guard let current, current.canAnswer(yes) else { return }
        let done = owed
        owed = nil
        // Gone at once, as ⌘L's field is: nothing is left to watch leave.
        self.current = nil
        current.anchor?.dismiss()
        done?.resume(returning: yes)
        // The next one after this one has gone, not in its place.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.current == nil else { return }
            next()
        }
    }

    private func next() {
        guard !waiting.isEmpty else {
            listen(false)
            return
        }
        let (asked, done) = waiting.removeFirst()
        var question = asked
        // Settings put away while this one waited its turn: asked over the
        // browser's window, which shows it, not in a panel nobody sees,
        // where it held every question after it (#379).
        if question.place == .settings, !SettingsCards.shared.showing { question.place = .page }
        // Its window closed while it waited: the one in front now has it.
        if !Self.open(question.window) { question.window = Self.standing(for: NSApp.keyWindow)?.windowNumber }
        owed = done
        ticked = false
        unfolded = false
        withAnimation(Motion.arrive) { current = question }
        question.anchor?.show(question, questions: self)
        listen(true)
        watchClosing()
    }

    // MARK: its window

    /// The window a question asked now stands in: a small window's for a
    /// link, or the browser's window that a window of its own belongs to
    /// (DevTools apart), or else the browser's window in front.
    static func standing(for window: NSWindow?) -> NSWindow? {
        if let window {
            if LinkWindow.owning(window) != nil { return window }
            let windows = BrowserWindows.shared
            if let browser = windows.browser(for: window), let own = windows.window(for: browser) { return own }
        }
        return BrowserWindows.shared.activeWindow
    }

    private static func open(_ number: Int?) -> Bool {
        guard let number else { return true }
        return NSApp.window(withWindowNumber: number)?.isVisible == true
    }

    /// Whether the question now stands in this window: the stand's own, or
    /// the one a key was pressed in. Nil asked, every window.
    func stands(in window: NSWindow?) -> Bool {
        if let anchor = current?.anchor { return anchor.owns(window) }
        guard let asked = current?.window else { return true }
        guard let window else { return false }
        if window.windowNumber == asked { return true }
        let windows = BrowserWindows.shared
        guard LinkWindow.owning(window) == nil, let browser = windows.browser(for: window) else { return false }
        return windows.window(for: browser)?.windowNumber == asked
    }

    /// Its window closed under it: the window in front now has it, rather
    /// than nothing showing it while it holds every question after it.
    private func watchClosing() {
        guard closing == nil else { return }
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let number = (note.object as? NSWindow)?.windowNumber
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let number, self.current?.window == number else { return }
                    self.current?.window = Self.standing(for: NSApp.keyWindow)?.windowNumber
                }
            }
        }
    }

    // MARK: keys

    /// Return, ⌘Return and Escape, for the window the question is in.
    /// A modal card keeps them even if the underlying field editor still
    /// has focus. Its own field keeps editing keys, as do fields under an
    /// undimmed card and Settings' search.
    func key(_ event: NSEvent, typing: Bool = false) -> Bool {
        // The code's field editor keeps its typing keys; Escape still
        // cancels pairing, even while that editor is first responder.
        if let anchor = current?.anchor {
            guard anchor.owns(event.window) else { return false }
            if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                answer(false)
                return true
            }
        }
        guard let question = current,
              SettingsCards.owns(event.window) == (question.place == .settings),
              question.place == .settings || stands(in: event.window),
              !(event.window?.firstResponder is NSText)
                || (question.place == .page && question.field == nil),
              question.place == .page || !typing
        else { return false }
        if let own = question.keys, own(event) { return true }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // A second ⌘Q still reaches the app's Quit action (Links).
        if flags == .command, Hotkey(event)?.key == "q" { return false }
        if event.keyCode == 53 {
            guard flags.isEmpty else { return question.place == .page }
            answer(false)
            return true
        }
        if question.danger, Keymap.shared.matches(event, .confirmDanger) {
            answer(true)
            return true
        }
        guard !question.danger, [36, 76].contains(event.keyCode), flags.isEmpty else {
            // The modal card holds every other key too: arrows, typing and
            // shortcuts cannot operate the omnibox or page underneath it.
            return question.place == .page
                || (question.danger && flags.isEmpty && [36, 76].contains(event.keyCode))
        }
        // Focus reaches the card's field on the next run-loop pass. Return
        // during that gap still belongs here, and cannot submit an empty name.
        if let field = question.field, field.trimmed.isEmpty { return true }
        answer(true)
        return true
    }

    /// The browser's window hears its keys through its own watcher, before
    /// the page does (App.take); Settings has none, so it gets one here,
    /// only while something is being asked.
    private func listen(_ on: Bool) {
        if on, keys == nil {
            keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, SettingsCards.owns(event.window) || self.current?.anchor?.owns(event.window) == true else { return event }
                return key(event) ? nil : event
            }
        } else if !on, let keys {
            NSEvent.removeMonitor(keys)
            self.keys = nil
        }
    }
}

// MARK: - the card

struct QuestionCard: View {
    @ObservedObject var questions: Questions = .shared
    @ObservedObject private var confirmation = Keymap.shared.slot(.confirmDanger)
    @Environment(\.colorScheme) private var scheme
    let question: Question
    /// Whether Return and Escape would reach it, so the buttons say so.
    var keyed = true
    /// How tall the card may be, the room it is shown in less a margin.
    var room: CGFloat = .infinity
    /// The words' own height, as they would stand with nothing in the way.
    @State private var tall: CGFloat = 0
    private var unfolded: Bool { questions.unfolded }

    var body: some View {
        // Taller than the room, an extension with a long list of things it
        // may ask for in a small window, the words scroll and the buttons
        // stay in sight. A ScrollView only then: most questions are short.
        let words = max(80, room - 2 * CardFrame.inset - CardFrame.buttonGap - CardFrame.button.height)
        VStack(alignment: .leading, spacing: 0) {
            if tall > words {
                ThreadScrollView(.vertical) { top }
                    .frame(height: words)
            } else {
                top
            }
            buttons
        }
        .cardFrame(glass: true)
        .frame(width: question.width)
    }

    private var top: some View {
        content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tall = $0 }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: CardFrame.wellGap) {
            if !question.bare { well }
            VStack(alignment: .leading, spacing: 2) {
                Text(question.title)
                    .font(CardFrame.title)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !question.detail.isEmpty {
                    Text(question.detail)
                        .font(CardFrame.detail)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }
                if !question.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(question.lines, id: \.self) { line in
                            row(line)
                        }
                    }
                    .padding(.top, 6)
                }
                if unfolded, !question.folded.isEmpty {
                    fold.padding(.top, 10)
                }
                if !question.boxes.isEmpty, let ticks = question.ticks {
                    QuestionBoxes(boxes: question.boxes, ticks: ticks)
                        .padding(.top, 10)
                }
                if let accessory = question.accessory {
                    accessory.padding(.top, 10)
                }
                if let field = question.field {
                    QuestionField(field: field, questions: questions)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            if let box = question.box {
                Toggle(isOn: $questions.ticked) {
                    Text(box).font(.system(size: CardFrame.words)).foregroundStyle(Palette.muted)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .fixedSize()
                .padding(.leading, CardFrame.checkInset)
            }
            if !question.folded.isEmpty {
                Button(unfolded ? "Less" : "\(question.folded.count) more") { questions.unfolded.toggle() }
                    .buttonStyle(.yab(.quiet, CardFrame.button))
                    .fixedSize()
            }
            Spacer(minLength: 8)
            button(question.no, kind: .secondary, key: "esc") { questions.answer(false) }
            if let other = question.other {
                button(other, kind: .secondary, key: "") {
                    questions.ticked = true
                    questions.answer(true)
                }
            }
            if question.yes.isEmpty {
                // No yes to press: what is under the words answers it (the
                // code from Apple Passwords, its sixth digit).
                EmptyView()
            } else if let enablement = question.enablement {
                QuestionEnabled(enablement: enablement) { yesButton }
            } else if let field = question.field {
                QuestionYes(field: field) {
                    button(question.yes, kind: question.danger ? .danger : .primary, key: question.danger ? (confirmation.keys?.text ?? "") : "⏎") {
                        questions.answer(true)
                    }
                }
            } else {
                yesButton
            }
        }
        .padding(.top, CardFrame.buttonGap)
    }

    private var yesButton: some View {
        button(question.yes, kind: question.danger ? .danger : .primary, key: question.danger ? (confirmation.keys?.text ?? "") : "⏎") {
            questions.answer(true)
        }
    }

    /// The glyph at a space's corner: the size and place of the badge on a
    /// page's question and the password card (Asks, Keep).
    private static let badge: CGFloat = 15
    private static let badgeOffset: CGFloat = 5

    @ViewBuilder
    private var well: some View {
        let side = CardFrame.well
        if let space = question.space {
            let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            shape.fill(Color(nsColor: scheme == .dark ? space.dark : space.light))
                .overlay { SpaceMark(icon: space.emoji, size: 19).foregroundStyle(Palette.ink) }
                .frame(width: side, height: side)
                // The glyph small at the corner, in a hole cut out of the
                // well, the way a site's mark sits in a kept offer's.
                .notched(true, side: Self.badge, radius: Self.badge / 2, offset: Self.badgeOffset)
                .overlay(alignment: .bottomTrailing) {
                    Symbol(question.glyph, size: 9, weight: .semibold)
                        .foregroundStyle(question.danger ? ButtonCSS.danger : Palette.ink)
                        .frame(width: Self.badge, height: Self.badge)
                        .offset(x: Self.badgeOffset, y: Self.badgeOffset)
                }
        } else if let icon = question.icon, !question.ownIcon {
            // An extension's icon on the quiet well, as a glyph stands: its
            // own art, often bare, would otherwise float beside the words.
            let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            shape.fill(Palette.ink.opacity(0.05))
                .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
                .overlay {
                    Image(nsImage: icon)
                        .resizable().interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 26, height: 26)
                }
                .frame(width: side, height: side)
        } else if let icon = question.icon {
            // A Dock tile is 824 of its icon's 1024 points.
            let drawn = question.ownIcon ? (side * 1024 / 824).rounded() : side
            Image(nsImage: icon)
                .resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: drawn, height: drawn)
                .frame(width: side, height: side)
        } else {
            let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            shape.fill(Palette.ink.opacity(0.05))
                .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
                .overlay {
                    Symbol(question.glyph, size: 16)
                        .foregroundStyle(question.danger ? ButtonCSS.danger : Palette.ink)
                }
                .frame(width: side, height: side)
        }
    }

    /// One thing it could do: every site in the ink, as the one that
    /// matters most, the rest in the muted gray.
    private func row(_ line: String) -> some View {
        let strong = line.contains("every site")
        // Centered on the capitals of the line's first row: on the baseline,
        // as an image stands by itself, it rode high and made every row taller.
        let cap = NSFont.systemFont(ofSize: 12.5).capHeight
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Symbol(question.lineGlyph ?? Self.glyph(line, fallback: question.glyph), size: 11)
                .foregroundStyle(strong ? Palette.ink : Palette.muted)
                .frame(width: Self.lineGlyph, height: Self.lineGlyph)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + cap / 2 }
            Text(line)
                .font(.system(size: 12.5))
                .foregroundStyle(strong ? Palette.ink : Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The rest of what it could do, opened, and what it may ask later.
    private var fold: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(question.folded, id: \.self) { line in
                row(line)
            }
            if !question.foldedNote.isEmpty {
                Text(question.foldedNote)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Palette.ink.opacity(0.05)))
    }

    /// The glyph's own side, size 11 as Symbol draws it.
    private static let lineGlyph = (11 * Glyphs.scale).rounded()

    private func button(_ title: String, kind: ButtonKind, key: String, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            labeled(title, key: key)
        }
        .buttonStyle(.yab(kind, CardFrame.button))
        .fixedSize()
    }

    private func labeled(_ title: String, key: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if keyed, !key.isEmpty { keys(key) }
        }
    }

    private func keys(_ keys: String) -> some View {
        KeyGlyphs(keys: keys, size: ButtonSize.regular.wordSize, tint: nil, rest: 0.6)
            .transaction { $0.animation = nil }
    }

    /// A glyph for each thing Extensions.describe can say.
    private static func glyph(_ line: String, fallback: String) -> String {
        let words: [(String, String)] = [
            ("site", "globe"), ("pages on", "globe"), ("own code", "chevron.left.forwardslash.chevron.right"),
            ("tabs", "square.on.square"), ("cookies", "key"), ("browse", "arrow.triangle.turn.up.right.diamond"),
            ("load", "arrow.down.circle"), ("clipboard", "doc.on.clipboard"), ("other apps", "app.connected.to.app.below.fill"),
            ("bookmark", "bookmark"), ("history", "clock"), ("download", "arrow.down.circle"),
            ("reading list", "eyeglasses"), ("visit most", "star"), ("notification", "bell"),
            ("whole pages", "yab.doc.dl"), ("proxy", "yab.globe.right"), ("where you are", "location"),
        ]
        let lower = line.lowercased()
        return words.first { lower.contains($0.0) }?.1 ?? fallback
    }
}

/// The line to type into: in the keys from the moment the card is up, its
/// words picked so typing replaces them, Return for yes once something is
/// there, Escape for no.
private struct QuestionField: View {
    @ObservedObject var field: Question.Field
    let questions: Questions
    @FocusState private var typing: Bool

    var body: some View {
        TextField(field.prompt, text: $field.text,
                  prompt: Text(field.prompt).foregroundStyle(Palette.muted))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .font(.system(size: 13.5))
            .focused($typing)
            .onSubmit { if !field.trimmed.isEmpty { questions.answer(true) } }
            .onExitCommand { questions.answer(false) }
            .onAppear { DispatchQueue.main.async { typing = true } }
    }
}

/// Yes, waiting for something typed.
private struct QuestionYes<Label: View>: View {
    @ObservedObject var field: Question.Field
    @ViewBuilder let label: () -> Label

    var body: some View {
        label().disabled(field.trimmed.isEmpty)
    }
}

private struct QuestionEnabled<Label: View>: View {
    @ObservedObject var enablement: Question.Enablement
    @ViewBuilder let label: () -> Label
    var body: some View { label().disabled(!enablement.allowed) }
}

/// "It would also like to", and a box for each thing, unticked. A tick is a
/// state and lands at once. Long words wrap within the card.
private struct QuestionBoxes: View {
    let boxes: [Question.Box]
    @ObservedObject var ticks: Question.Ticks

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("It would also like to")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
            ForEach(boxes, id: \.key) { box in
                Toggle(isOn: Binding(
                    get: { ticks.on.contains(box.key) },
                    set: { on in if on { ticks.on.insert(box.key) } else { ticks.on.remove(box.key) } }
                )) {
                    Text(box.words)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - where it stands

/// Over the browser's window: in its middle, over the dimming or not.
struct QuestionLayer: View {
    @ObservedObject var browser: Browser

    var body: some View {
        QuestionStand { question in question.place == .page || (!browser.editing && browser.active?.typing != true) }
    }
}

/// A question in the middle of the window it stands over, the browser's or
/// a small window's for a link (LinkWindow), over the dimming or not.
/// Only the window it was asked from shows it, the small window in front of
/// the browser's included (#178), not every window on every screen (#1097).
struct QuestionStand: View {
    @ObservedObject var questions: Questions = .shared
    @Environment(\.colorScheme) private var scheme
    /// Whether Return and Escape reach it in this window, so the buttons say so.
    let keyed: (Question) -> Bool
    /// The card come up in this window, or gone from it.
    var shown: (Bool) -> Void = { _ in }
    /// The window this stand is in, once it is in one. Held weakly: the
    /// window holds this view, and a strong hold kept every closed window
    /// and its browser for as long as Yab ran (#1046).
    @State private var host = Host()
    private struct Host { weak var window: NSWindow? }

    var body: some View {
        GeometryReader { proxy in
            let window = proxy.size
            ZStack {
                Color.clear.allowsHitTesting(false)
                    .background(QuestionHost(window: $host.window).accessibilityHidden(true))
                if let question = questions.current, question.place != .settings, question.anchor == nil,
                   host.window.map(questions.stands(in:)) ?? (question.window == nil) {
                    if question.place == .page {
                        // The window clips it to its own corners.
                        Color.black.opacity(Question.dim(scheme))
                            .contentShape(Rectangle())
                            .transition(Question.veil)
                    }
                    QuestionCard(question: question, keyed: keyed(question), room: window.height - 48)
                        .transition(Question.appear)
                        .id(question.id)
                        .onAppear {
                            if let host = host.window { questions.shownIn.insert(host.windowNumber) }
                            shown(true)
                        }
                        .onDisappear {
                            if let host = host.window { questions.shownIn.remove(host.windowNumber) }
                            shown(false)
                        }
                }
            }
            .frame(width: window.width, height: window.height)
        }
    }
}

/// The window a stand is in, told as it comes to one.
private struct QuestionHost: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> Reader { Reader { window = $0 } }
    func updateNSView(_ view: Reader, context: Context) {}

    final class Reader: NSView {
        let found: (NSWindow?) -> Void
        init(_ found: @escaping (NSWindow?) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            DispatchQueue.main.async { [found] in found(window) }
        }
    }
}

extension Question {
    /// The dimming under a question: deeper on a dark window, where the
    /// light one's 0.12 could not be seen at all.
    static func dim(_ scheme: ColorScheme) -> Double { scheme == .dark ? 0.45 : 0.2 }

    /// ⌘L's field's way (ContentView.field): in from a touch smaller, out of
    /// its own middle, and gone at once when it is answered.
    static let appear = AnyTransition.asymmetric(
        insertion: .scale(scale: 0.97).combined(with: .opacity).animation(Motion.arrive),
        removal: .identity
    )
    /// The dimming under it, in the same beat and gone with it.
    static let veil = AnyTransition.asymmetric(
        insertion: .opacity.animation(Motion.arrive),
        removal: .identity
    )
}

/// In Settings' own window over it (SettingsCards): the card at its
/// middle, nothing dimmed, the rest held still under it.
struct SettingsQuestionLayer: View {
    @ObservedObject var questions: Questions = .shared
    /// How tall the card may be: the screen's height less a margin.
    let room: CGFloat

    var body: some View {
        if let question = questions.current, question.place == .settings, question.anchor == nil {
            QuestionCard(question: question, room: room)
                .transition(Question.appear)
                .id(question.id)
        }
    }
}
