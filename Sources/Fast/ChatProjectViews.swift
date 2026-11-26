import AppKit
import SwiftUI
import SyncKit

// The chat column's list as Messages lays it (docs/chat-projects.md,
// concept KGEud9jpw3Rq4Jn9xho4hL): rows of 74 with a round face, the name,
// when, two lines of the answer and a blue dot for one not yet read; a
// project of chats a circle with its emoji, as a contact.

/// The namespace the column's circles morph in: a pinned circle into the
/// project it opens, the New Project form's into the project it makes.
private struct ProjectMorphSpace: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var projectMorph: Namespace.ID? {
        get { self[ProjectMorphSpace.self] }
        set { self[ProjectMorphSpace.self] = newValue }
    }
}

/// The project just made, whose circle came out of the New Project form
/// (its id until the form's circle has landed).
@MainActor enum ProjectMorph {
    static let form = "project.new"
    static var fresh: String?

    /// The morph id of a project's circle: the form's while it is new.
    static func id(_ project: Project) -> String { fresh == project.id ? form : project.id }

    static func made(_ project: Project) {
        fresh = project.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if fresh == project.id { fresh = nil } }
    }
}

private struct MorphsModifier: ViewModifier {
    let id: String
    @Environment(\.projectMorph) private var space

    func body(content: Content) -> some View {
        if let space {
            content.matchedGeometryEffect(id: id, in: space)
        } else {
            content
        }
    }
}

extension View {
    /// This circle flies to the same id's place on the screen that comes.
    func morphs(_ id: String) -> some View { modifier(MorphsModifier(id: id)) }
}

/// A project's circle: its emoji on its color, light at the top.
struct ProjectCircle: View {
    let project: Project
    let size: CGFloat

    var body: some View {
        Text(project.emoji)
            .font(.system(size: (size * 0.5).rounded())) // design: the emoji half the circle, at every size
            .frame(width: size, height: size)
            .background(Self.fill(project.tint), in: Circle())
            .accessibilityLabel(project.name)
    }

    /// The two stops of a tint, as the concept draws them.
    static func fill(_ tint: String) -> LinearGradient {
        let (top, foot) = stops[tint] ?? stops["blue"]!
        return LinearGradient(colors: [Color(rgb: top), Color(rgb: foot)], startPoint: UnitPoint(x: 0.3, y: 0), endPoint: UnitPoint(x: 0.7, y: 1))
    }

    private static let stops: [String: (UInt32, UInt32)] = [
        "blue": (0xC9D8FF, 0x9DB6FF), "green": (0xCDEED6, 0x9FDCB1), "orange": (0xFFD9A8, 0xFFB877),
        "purple": (0xE4DCFF, 0xC3B4FF), "pink": (0xFFD6E4, 0xFFAFC9), "yellow": (0xFFEFB0, 0xFFDD70),
        "teal": (0xC4EEEC, 0x8FDAD6), "gray": (0xE2E2E6, 0xC4C4CA),
    ]
}

private extension Color {
    init(rgb hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// A chat's round face in a row: the first site its agent went to, else
/// a routine's clock or its agent's mark, on the column's wash; its
/// project's circle on its shoulder when it is in one.
struct ChatAvatar: View {
    let chat: Chat
    let size: CGFloat
    /// The project's circle on the shoulder, where a chat outside its
    /// project shows (search, ⌘T).
    var badge = false

    var body: some View {
        ZStack {
            Circle().fill(Palette.ink.opacity(0.08))
            if let host = Self.host(chat) {
                SiteMark(host: host, size: (size * 0.5).rounded())
            } else {
                Symbol(Self.routine(chat) ? "clock.arrow.circlepath" : FieldAnswer.mark(chat.cli), size: (size * 0.4).rounded())
                    .foregroundStyle(Palette.muted)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if badge, let project = Projects.shared.project(chat.project) {
                ProjectCircle(project: project, size: (size * 0.42).rounded())
                    .padding(1) // design: a ring of the row's ground round the badge
                    .background(Palette.ground, in: Circle())
                    .offset(x: 4, y: -4)
            }
        }
    }

    static func routine(_ chat: Chat) -> Bool {
        chat.routine != nil || chat.source == "routine" || Routines.shared.all.contains { $0.chat == chat.id }
    }

    /// The site it worked on first, worked out once for each length of the chat.
    @MainActor private static var kept: [String: (count: Int, host: String?)] = [:]

    @MainActor static func host(_ chat: Chat) -> String? {
        if let first = chat.tabs.first, let host = URL(string: first.url)?.host() { return StepWords.bare(host) }
        if let hit = kept[chat.id], hit.count == chat.items.count { return hit.host }
        let host = ChatSteps.hosts(chat.items).first
        kept[chat.id] = (chat.items.count, host)
        return host
    }
}

/// One row of the list, as Messages has it: the dot, the face, the name
/// and when, two lines under them; a hairline under the words.
struct ChatListRowBody<Face: View>: View {
    let title: String
    let when: String
    let working: Bool
    let preview: String
    let unread: Bool
    var pinned = false
    /// The chat whose name flies to its head and back (ChatZoom).
    var zoom: String? = nil
    @ViewBuilder let face: () -> Face

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if unread {
                    Circle().fill(Color.accentColor).frame(width: 9, height: 9) // design: Messages' unread dot
                        .accessibilityLabel("New")
                }
            }
            .frame(width: 10)
            face()
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.system(size: ChatZoomStage.cardType, weight: .semibold))
                        .lineLimit(1)
                        .modifier(ChatZoomVeiled(card: zoom ?? "-"))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatCards.space)) } action: { frame in
                            if let zoom { ChatCards.titles[zoom] = frame }
                        }
                    if pinned {
                        Symbol("pin.fill", size: 9)
                            .foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 2) {
                        Text(when)
                        Symbol("chevron.right", size: 10)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(working ? ChatListRows.workingInk : Palette.faint)
                }
                if !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.faint)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.trailing, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.hairline).frame(height: 0.5) // design: Messages' row rule, under the words only
            }
        }
        .padding(.leading, 6) // design: Messages' row, the dot's room at the edge
        .padding(.trailing, 12) // design: Messages' row, when and its chevron in from the edge
        .frame(height: ChatListRows.height)
        .contentShape(Rectangle())
    }
}

@MainActor enum ChatListRows {
    static let height: CGFloat = 74
    static let face: CGFloat = 44

    /// "working" in the iPhone's green for done (Ink.done).
    static let workingInk = Color(nsColor: NSColor(name: nil) { look in
        look.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x79 / 255.0, green: 0xD9 / 255.0, blue: 0x9B / 255.0, alpha: 1)
            : NSColor(srgbRed: 0x1E / 255.0, green: 0x6B / 255.0, blue: 0x3A / 255.0, alpha: 1)
    })

    /// "working", "12:40", "Tue", "Oct 12".
    static func when(_ date: Date, working: Bool) -> String {
        if working { return "working" }
        let calendar = Calendar.current
        let format = AppDates.formatter()
        if calendar.isDateInToday(date) { format.dateFormat = "HH:mm" }
        else if calendar.isDateInYesterday(date) { return "Yesterday" }
        else if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 { format.dateFormat = "EEE" }
        else { format.dateFormat = "MMM d" }
        return format.string(from: date)
    }
}

// MARK: - projects in the list

/// What the list of chats holds: a chat, or a project of them, which
/// stands among the chats by its latest one, as a group in Messages.
enum ChatListEntry: Identifiable {
    case chat(Chat)
    case project(Project, latest: Chat?)

    var id: String {
        switch self {
        case .chat(let chat): chat.listed
        case .project(let project, _): "project:" + project.id
        }
    }

    /// When it last moved, for its place among the rest.
    var at: Date {
        switch self {
        case .chat(let chat): chat.updated
        case .project(let project, let latest): max(project.updated, latest?.updated ?? .distantPast)
        }
    }

    /// The chats, pinned first as they came, with the projects put in among
    /// the rest by when each last moved.
    static func merge(_ chats: [Chat], projects: [(Project, Chat?)]) -> [ChatListEntry] {
        let pinned = chats.filter(\.pinned).map(ChatListEntry.chat)
        var rest = chats.filter { !$0.pinned }.map(ChatListEntry.chat)
        for (project, latest) in projects {
            let entry = ChatListEntry.project(project, latest: latest)
            let at = rest.firstIndex { $0.at < entry.at } ?? rest.count
            rest.insert(entry, at: at)
        }
        return pinned + rest
    }
}

/// A project's row in the list: its circle, its name, when its latest
/// chat moved, and what that chat said, its name first.
struct ProjectListRow: View {
    let browser: Browser
    let project: Project
    let latest: Chat?
    @ObservedObject private var chats = Chats.shared
    @State private var over = false
    @State private var dropping = false

    var body: some View {
        let mine = chats.of(project: project.id)
        let working = mine.contains { Agents.shared.session($0.id)?.state.live == true }
        let unread = mine.contains { $0.unread == true }
        return Button {
            browser.openProject(project.id)
        } label: {
            ChatListRowBody(title: project.name,
                            when: ChatListRows.when(max(project.updated, latest?.updated ?? project.updated), working: working),
                            working: working, preview: Self.preview(latest), unread: unread) {
                ProjectCircle(project: project, size: ChatListRows.face)
            }
            .background(Palette.ink.opacity(over || dropping ? 0.05 : 0))
        }
        .buttonStyle(.plain)
        .onHover { over = $0 }
        .takesChats(into: project.id, over: $dropping)
        .accessibilityLabel("Project " + project.name)
    }

    /// "Receipts: Found 14 receipts…", or nothing in it yet.
    static func preview(_ latest: Chat?) -> String {
        guard let latest else { return "No chats yet" }
        let said = latest.preview
        return said.isEmpty ? latest.title : latest.title + ": " + said
    }
}

/// The pinned projects over the list, three a row, big circles as pinned
/// contacts in Messages: over one, what is new in it, or three dots while
/// one of its chats is at work.
struct ChatPinnedProjects: View {
    let browser: Browser
    let projects: [Project]
    @ObservedObject private var chats = Chats.shared
    /// The circle a chat's row is held over.
    @State private var dropping: String?

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .top), count: 3), spacing: 16) {
            ForEach(projects) { project in
                pin(project)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 32) // design: room over the first row for its bubbles
        .padding(.bottom, 16)
    }

    private func pin(_ project: Project) -> some View {
        let mine = chats.of(project: project.id)
        let latest = mine.max { $0.updated < $1.updated }
        let working = mine.contains { Agents.shared.session($0.id)?.state.live == true }
        let unread = mine.contains { $0.unread == true }
        return Button {
            browser.openProject(project.id)
        } label: {
            VStack(spacing: 6) {
                ProjectCircle(project: project, size: Self.circle)
                    .morphs(project.id)
                HStack(spacing: 4) {
                    if unread {
                        Circle().fill(Color.accentColor).frame(width: 9, height: 9) // design: Messages' unread dot
                    }
                    Text(project.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) {
                // Hung from a line of no height at the circle's top, its
                // foot there: an alignment guide in an overlay was let go,
                // and the bubble covered the circle.
                Color.clear.frame(height: 0).overlay(alignment: .bottom) {
                    if working {
                        ProjectPeek { ChatTypingDots().frame(width: 32, height: 8) }
                    } else if unread, let latest {
                        ProjectPeek {
                            (Text(latest.title).fontWeight(.semibold) + Text(" " + latest.preview))
                                .font(.system(size: 11.5))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A chat's row let go over the circle goes in, the circle lifted to take it.
        .takesChats(into: project.id, over: Binding(get: { dropping == project.id }, set: { dropping = $0 ? project.id : dropping == project.id ? nil : dropping }))
        .scaleEffect(dropping == project.id ? 1.08 : 1)
        .animation(Motion.chatQuick, value: dropping)
        .accessibilityLabel("Project " + project.name)
        .accessibilityValue(working ? "working" : unread ? "new" : "")
    }

    static let circle: CGFloat = 72
}

/// A small bubble over a pinned circle, its tail toward it.
private struct ProjectPeek<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 132, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Radius.floating, style: .continuous)
                    .fill(Palette.ground) // design: Messages' bubble over a pinned contact, not a card
                    .shadow(color: .black.opacity(0.14), radius: 5, y: 2) // design: the concept's bubble over a circle
            }
            .fixedSize(horizontal: false, vertical: true)
            .offset(x: 12, y: 8) // design: its foot a little over the circle's top, the tail's side toward its middle
            .allowsHitTesting(false)
    }
}
