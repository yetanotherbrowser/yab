import SwiftUI
import AppKit
import MailCore

// What stands beside the list for a request (FieldRequest): the thing
// itself, drawn as it is, not a form about it. A page as its last look, a
// mail as Mail shows it, the tabs that close struck through, a file's first
// page, a person, the day a meeting lands in, the steps the agent takes with
// the one that is yours, the site's own form, the memory line. What Return
// does is the foot's button: nothing under the object says it again. The
// obvious kinds (a setting, the theme, a pin) have no object and no preview.
// Concept: artifact MmijNqbC.

enum RequestObject {
    case page(Diary.Hit, picture: URL?)
    case mail(MailDesk.Row, note: String?)
    case tabs(closing: [Tab], kept: [Tab])
    case moving([Tab], to: String)
    case file(Keep)
    case person(MailDesk.Contact, last: MailDesk.Row?)
    case day(person: MailDesk.Contact?, label: String, start: Date)
    case steps(mail: MailDesk.Row?, steps: [String], yours: Int?)
    case form(site: String, tint: NSColor, team: String?, title: String, lines: [(String, String)], button: String)
    case memory(page: String, line: String)
    case answer(String)
}

struct RequestObjectView: View {
    let object: RequestObject

    var body: some View {
        switch object {
        case .page(let hit, let picture): page(hit, picture)
        case .mail(let row, let note): mail(row, note)
        case .tabs(let closing, let kept): tabs(closing, kept)
        case .moving(let tabs, let to): moving(tabs, to)
        case .file(let keep): file(keep)
        case .person(let contact, let last): person(contact, last)
        case .day(let person, let label, let start): DayStrip(person: person, label: label, start: start)
        case .steps(let row, let steps, let yours): plan(row, steps, yours)
        case .form(let site, let tint, let team, let title, let lines, let button): form(site, tint, team, title, lines, button)
        case .memory(let page, let line): memory(page, line)
        case .answer(let text): answer(text)
        }
    }

    // MARK: parts

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardFrame()
    }

    private func initials(_ said: String, side: CGFloat = 28) -> some View {
        Text(MailDesk.initials(said))
            .font(.system(size: side * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(Circle().fill(Color(nsColor: .systemGray)))
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(2)
    }

    private func small(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(2)
    }

    // MARK: kinds

    private func page(_ hit: Diary.Hit, _ picture: URL?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let picture, let image = NSImage(contentsOf: picture) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: 150, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).strokeBorder(Omnibox.seam, lineWidth: 1))
            }
            title(hit.title.isEmpty ? hit.host : hit.title)
            small(hit.host)
            if let passage = hit.passage {
                Text("\u{201C}\(passage.prefix(160))\u{201D}").font(.system(size: 12.5)).foregroundStyle(Palette.ink).lineLimit(3)
            }
            small("You were here " + hit.at.englishFormatted(date: .abbreviated, time: .shortened))
        }
    }

    private func mail(_ row: MailDesk.Row, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        initials(row.who)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(row.who).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                                Text(row.at.englishFormatted(date: .abbreviated, time: .shortened)).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                            }
                            Text(row.subject.isEmpty ? "(no subject)" : row.subject).font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(1)
                        }
                    }
                    Text(row.line).font(.system(size: 12.5)).foregroundStyle(Palette.muted).lineLimit(3)
                }
            }
            if let note { Text(note).font(.system(size: 13.5)).foregroundStyle(Palette.ink) }
        }
    }

    private func tabRow(_ tab: Tab, struck: Bool, end: String) -> some View {
        HStack(spacing: 10) {
            Mark(icon: tab.icon, letter: tab.monogram, size: 14)
            Text(tab.title).font(.system(size: 12.5)).strikethrough(struck).foregroundStyle(struck ? Palette.muted : Palette.ink).lineLimit(1)
            Spacer(minLength: 8)
            Text(end).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
        }
        .frame(height: 30)
    }

    private func tabs(_ closing: [Tab], _ kept: [Tab]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(closing.prefix(8).enumerated()), id: \.offset) { _, tab in
                tabRow(tab, struck: true, end: tab.touched.formatted(.relative(presentation: .named).locale(AppDates.locale)))
            }
            if closing.count > 8 { small("and \(closing.count - 8) more") }
            ForEach(Array(kept.enumerated()), id: \.offset) { _, tab in tabRow(tab, struck: false, end: "playing, kept") }
        }
    }

    private func moving(_ tabs: [Tab], _ to: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tabs.prefix(8).enumerated()), id: \.offset) { _, tab in tabRow(tab, struck: false, end: "→ " + to) }
        }
    }

    private func file(_ keep: Keep) -> some View {
        HStack(alignment: .top, spacing: 16) {
            FilePicture(path: keep.path, side: 120)
                .frame(width: 96, height: 124)
                .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                title(keep.name)
                small("Downloaded " + keep.date.englishFormatted(date: .abbreviated, time: .shortened))
                if let from = keep.page?.host() ?? keep.source?.host() { small("from " + from) }
                small((keep.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            }
        }
    }

    private func person(_ contact: MailDesk.Contact, _ last: MailDesk.Row?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                initials(contact.said, side: 44)
                VStack(alignment: .leading, spacing: 2) {
                    title(contact.said)
                    small("\(contact.threads) threads · \(contact.address)")
                }
            }
            if let last {
                card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last: " + last.subject).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                        Text(last.line).font(.system(size: 12.5)).foregroundStyle(Palette.muted).lineLimit(2)
                    }
                }
            }
        }
    }

    private func plan(_ row: MailDesk.Row?, _ steps: [String], _ yours: Int?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let row { mail(row, nil) }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        let mine = index == yours
                        Text(mine ? "You" : "\(index + 1)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(mine ? Color(nsColor: .systemOrange) : Palette.muted)
                            .frame(width: 28, height: 18)
                            .background(Capsule().fill(mine ? Color(nsColor: .systemOrange).opacity(0.15) : Omnibox.seam))
                        Text(step).font(.system(size: 12.5, weight: mine ? .semibold : .regular)).foregroundStyle(Palette.ink)
                    }
                }
            }
        }
    }

    /// The site's own form as it opens, Linear's look for every site: the
    /// team, the title in large, what else stays empty, its button.
    private func form(_ site: String, _ tint: NSColor, _ team: String?, _ title: String,
                      _ lines: [(String, String)], _ button: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                pill(team ?? site, dot: tint)
                Text("›").foregroundStyle(Palette.muted)
                pill("New", dot: nil)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 8)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(2)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 6) {
                    Text(line.0).foregroundStyle(Palette.muted)
                    Text(line.1).foregroundStyle(Palette.ink)
                }
                .font(.system(size: 12.5))
                .padding(.top, 4)
            }
            Rectangle().fill(Omnibox.seam).frame(height: 1).padding(.top, 12)
            HStack {
                Spacer(minLength: 0)
                Text(button)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Color(nsColor: tint)))
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardFrame()
    }

    private func pill(_ text: String, dot: NSColor?) -> some View {
        HStack(spacing: 4) {
            if let dot { Circle().fill(Color(nsColor: dot)).frame(width: 8, height: 8) }
            Text(text).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).strokeBorder(Omnibox.seam, lineWidth: 1))
    }

    private func memory(_ page: String, _ line: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            small("memory/" + page + ".md")
            card {
                Text("+ " + line)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.ink)
            }
        }
    }

    private func answer(_ text: String) -> some View {
        Text(text).font(.system(size: 13.5)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
    }
}

/// The day a meeting lands in, from 9 to 6: what is already there, and the
/// new one where it goes. The calendar is read once per day asked about.
struct DayStrip: View {
    let person: MailDesk.Contact?
    /// What the new block says: "You + Taro", "Focus".
    let label: String
    let start: Date
    @State private var busy: [BusyTime]?

    private let first = 9
    private let last = 18
    private let hour: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let person {
            HStack(spacing: 10) {
                Text(MailDesk.initials(person.said))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color(nsColor: .systemGray)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.said).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("\(person.threads) threads with you").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                }
            }
            }
            Text(start.formatted(AppDates.dateTime.weekday(.wide).month().day()))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(first..<last, id: \.self) { h in
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(h > 12 ? h - 12 : h)").font(.system(size: 10)).foregroundStyle(Palette.muted).frame(width: 18, alignment: .trailing)
                            Rectangle().fill(Omnibox.seam).frame(height: 1)
                        }
                        .frame(height: hour, alignment: .top)
                    }
                }
                ForEach(Array((busy ?? []).enumerated()), id: \.offset) { _, slot in
                    block(slot.title, from: slot.start, to: slot.end, new: false)
                }
                block(label, from: start, to: start.addingTimeInterval(1800), new: true)
            }
        }
        .task(id: start) {
            let day = Calendar.current.startOfDay(for: start)
            busy = await Meetings.shared.busy(from: day, to: day.addingTimeInterval(86400))
        }
    }

    private func offset(_ date: Date) -> CGFloat {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (CGFloat(parts.hour ?? 0) - CGFloat(first) + CGFloat(parts.minute ?? 0) / 60) * hour
    }

    @ViewBuilder
    private func block(_ title: String, from: Date, to: Date, new: Bool) -> some View {
        let top = offset(from), height = max(14, offset(to) - offset(from) - 2)
        if top >= 0, top < CGFloat(last - first) * hour {
            Text(title)
                .font(.system(size: 11, weight: new ? .semibold : .regular))
                .foregroundStyle(new ? Color.white : Palette.ink)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(new ? Color(nsColor: .systemBlue) : Omnibox.seam))
                .padding(.leading, 24)
                .offset(y: top + 1)
        }
    }
}
