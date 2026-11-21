import AppKit
import SwiftUI

// Settings › Invite Friends and, a page further in, Best Friend
// (Invites.swift): the message and its link, the icons friends unlock,
// the people invited, and the one best friend who shares a charm.

/// The swatch a half's color shows as.
enum CharmSwatch {
    static func color(_ name: String) -> Color {
        let hex: UInt32 = [
            "mint": 0x9fe3be, "lilac": 0xc9aaf0, "sky": 0xa6d3f5, "rose": 0xf4afc8,
            "coral": 0xf4a291, "lemon": 0xeedc86, "indigo": 0xa9aff2, "silver": 0xe4e4e8,
        ][name] ?? 0xe4e4e8
        return Color(.sRGB, red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255,
                     blue: Double(hex & 0xff) / 255)
    }
}

/// The charm as the Dock shows it now, any size.
struct CharmPicture: View {
    @ObservedObject private var invites = Invites.shared
    var side: CGFloat
    /// Drawn whole whatever the Dock shows, for the page's own picture.
    var whole = false

    var body: some View {
        let charm = invites.charm
        Group {
            if let resources = AppIconStyle.resources,
               let image = CharmDraw.image(resources: resources, left: charm.left, right: charm.right,
                                           apart: whole ? false : charm.apart) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Color.clear
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// The page's own charm: whole, or as the Dock shows it, and parted
/// under the pointer, joining again when it leaves. The halves move as
/// layers, out along the break and turned as `CharmDraw` parts them.
private struct HoverCharm: View {
    @ObservedObject private var invites = Invites.shared
    var side: CGFloat
    var whole: Bool
    @State private var hovering = false

    var body: some View {
        let charm = invites.charm
        let apart: CGFloat = hovering || (!whole && charm.apart) ? 1 : 0
        let scale = side / 1024
        let art = CharmDraw.art
        Group {
            if let resources = AppIconStyle.resources,
               let parts = CharmDraw.parts(resources: resources, left: charm.left, right: charm.right) {
                ZStack {
                    Image(nsImage: parts.ground).resizable().interpolation(.high)
                    ZStack {
                        half(parts.left, shift: -apart, width: art.width * scale)
                        half(parts.right, shift: apart, width: art.width * scale)
                    }
                    .shadow(color: Color(.sRGB, red: 0.24, green: 0.12, blue: 0.16, opacity: 0.22), radius: 10 * scale, x: 0, y: 12 * scale) // design: the icon art's shadow
                    .frame(width: art.width * scale, height: art.height * scale)
                    .clipShape(RoundedRectangle(cornerRadius: 185 * scale, style: .continuous)) // design: the icon art's clip, scaled
                }
            } else {
                Color.clear
            }
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.62)) { hovering = inside }
        }
        .accessibilityHidden(true)
    }

    private func half(_ image: NSImage, shift: CGFloat, width: CGFloat) -> some View {
        Image(nsImage: image).resizable().interpolation(.high)
            .rotationEffect(.degrees(shift * 3))
            .offset(x: shift * width * 0.035)
    }
}

/// A row's round swatch: the half's color, ringed when it is the one.
private struct SwatchButton: View {
    let name: String
    let on: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            Circle()
                .fill(CharmSwatch.color(name))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .padding(on ? 2 : 0)
                .overlay(Circle().strokeBorder(on ? Color.primary : Color.clear, lineWidth: 2))
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name.capitalized)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The message you send, in a box you can write in.
private struct MessageBox: View {
    @Binding var text: String

    var body: some View {
        ThreadTextEditor(text: $text)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .frame(height: 64)
            .padding(6)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Color.primary.opacity(0.08)))
            .accessibilityLabel("Message")
    }
}

/// Copy Link: the message and its link onto the pasteboard, then a word
/// on the button itself for a moment, in the same width.
private struct CopyLinkButton: View {
    let best: Bool
    @State private var copied = false
    @State private var busy = false

    var body: some View {
        Button {
            guard !busy else { return }
            busy = true
            Task {
                let done = await Invites.shared.copy(best: best)
                busy = false
                guard done else { return }
                copied = true
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            ZStack {
                Text("Copied").opacity(copied ? 1 : 0)
                Text("Copy Link").opacity(copied ? 0 : 1)
            }
        }
        .buttonStyle(.yab(.primary, .regular))
        .keyboardShortcut("c", modifiers: .command)
        .disabled(busy)
    }
}

/// One of the icons friends unlock, with its name and what it takes.
private struct RewardTile: View {
    let style: AppIconStyle
    let needs: String
    @State private var dark = AppIconStyle.systemDark

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: AppIconStyle.picture(style, dark: dark))
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .grayscale(style.unlocked ? 0 : 1)
                .opacity(style.unlocked ? 1 : 0.55)
            Text(style.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(style.unlocked ? "Yours" : needs)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Post About Yab (PostReward): a post on X for one of three icons, a
/// surprise until its day is up.
private struct PostSection: View {
    @ObservedObject private var reward = PostReward.shared
    @State private var pasting = false

    var body: some View {
        Section {
            SettingsRow(line.title, detail: line.detail) { trailing }
            if reward.canPost, !reward.draft.isEmpty, !reward.waiting {
                MessageBox(text: $reward.draft)
                    .settingsAnchor("post-draft")
                HStack(spacing: 8) {
                    Text("\(PostFacts.xLength(reward.draft)) of 280")
                        .foregroundStyle(PostFacts.xLength(reward.draft) > 280 ? .red : .secondary)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Button(reward.writing ? "Writing…" : "Another") { Task { await reward.write(another: true) } }
                        .buttonStyle(.yab(.secondary, .regular))
                        .disabled(reward.writing)
                    Button("Post on X") { reward.post() }
                        .buttonStyle(.yab(.primary, .regular))
                        .disabled(reward.writing || PostFacts.xLength(reward.draft) > 280)
                }
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(reward.won, id: \.self) { style in
                    RevealTile(style: style, reveal: reward.fresh == style)
                }
                if !reward.allWon {
                    RewardTile(style: .surprise, needs: surpriseLine)
                }
                ForEach(0 ..< max(0, 4 - reward.won.count - (reward.allWon ? 0 : 1)), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
            }
            .padding(.vertical, 4)
            .settingsAnchor("post-icons")
        } footer: {
            if let problem = reward.problem { SettingsNote(problem) }
        }
    }

    private var surpriseLine: String {
        if let opens = reward.live?.opens { return "Opens \(PostReward.words(until: opens))" }
        if let after = reward.after, after > Date() { return "After " + after.formatted(AppDates.dateTime.month(.abbreviated).day()) }
        return "One post"
    }

    private var line: (title: String, detail: String) {
        if reward.allWon { return ("All three are yours", "Find them in Appearance › App Icon.") }
        if reward.waiting {
            return ("Post it on X", reward.waitedLong ? "Didn't see it yet. If it's up, paste its link." : "Yab counts it once X shows your post.")
        }
        if let opens = reward.live?.opens { return ("Your post is up", "The surprise opens \(PostReward.words(until: opens)).") }
        let next = reward.after.map { " The next one with a post after \($0.formatted(AppDates.dateTime.month(.wide).day()))." } ?? ""
        if let fresh = reward.fresh { return ("\(fresh.title) is yours", "\(reward.count) of 3." + next) }
        if let after = reward.after, after > Date() { return ("Next icon after \(after.formatted(AppDates.dateTime.month(.wide).day()))", "One post a week counts.") }
        if reward.lastGone { return ("The post is gone", "So it didn't count. Post again any time.") }
        return ("Post About Yab", "Unlock one of three icons by posting about Yab. One post per week counts.")
    }

    @ViewBuilder private var trailing: some View {
        if let fresh = reward.fresh, !reward.waiting {
            Button("Wear") { fresh.choose() }
                .buttonStyle(.yab(.secondary, .regular))
        } else if reward.waiting {
            HStack(spacing: 8) {
                Button("Paste Link…") { pasting = true }
                    .buttonStyle(.yab(.quiet, .regular))
                    .popover(isPresented: $pasting, arrowEdge: .bottom) { PasteLinkPopover(shown: $pasting) }
                Button(SettingsWords.text("Cancel")) { reward.stopWaiting() }
                    .buttonStyle(.yab(.secondary, .regular))
            }
        } else if reward.canPost {
            HStack(spacing: 8) {
                // Posted already, from X itself or before Yab was closed.
                Button("Paste Link…") { pasting = true }
                    .buttonStyle(.yab(.quiet, .regular))
                    .popover(isPresented: $pasting, arrowEdge: .bottom) { PasteLinkPopover(shown: $pasting) }
                if reward.draft.isEmpty {
                    Button(reward.writing ? "Writing…" : "Write Post") { Task { await reward.write() } }
                        .buttonStyle(.yab(.primary, .regular))
                        .disabled(reward.writing)
                }
            }
        }
    }
}

/// The post's link, given by hand when Yab didn't see X show it.
private struct PasteLinkPopover: View {
    @Binding var shown: Bool
    @ObservedObject private var reward = PostReward.shared
    @State private var link = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Link to your post")
                .font(.system(size: 13, weight: .semibold))
            TextField("Link to your post", text: $link, prompt: Text("https://x.com/you/status/…"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .autocorrectionDisabled()
                .focused($focused)
                .onSubmit(count)
            if let problem = reward.problem {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(SettingsWords.text("Cancel")) { shown = false }
                    .buttonStyle(.yab(.secondary, .regular))
                    .keyboardShortcut(.cancelAction)
                Button(reward.sending ? "Counting…" : "Count It", action: count)
                    .buttonStyle(.yab(.primary, .regular))
                    .keyboardShortcut(.defaultAction)
                    .disabled(reward.sending || link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            // What was copied, when it is a post's own address.
            if let copied = NSPasteboard.general.string(forType: .string), let url = URL(string: copied.trimmingCharacters(in: .whitespacesAndNewlines)),
               PostReward.isPost(url) { link = url.absoluteString }
            focused = true
        }
    }

    private func count() {
        let given = link
        Task {
            await reward.send(given)
            if reward.problem == nil { shown = false }
        }
    }
}

/// A post's icon, the first time in color: out of focus and small, then itself.
private struct RevealTile: View {
    let style: AppIconStyle
    let reveal: Bool
    @State private var shown = false

    var body: some View {
        RewardTile(style: style, needs: "")
            .blur(radius: reveal && !shown ? 8 : 0)
            .scaleEffect(reveal && !shown ? 0.8 : 1)
            .onAppear {
                guard reveal else { return }
                withAnimation(.spring(response: 0.7, dampingFraction: 0.6).delay(0.2)) { shown = true }
            }
    }
}

/// Settings › Invite Friends.
struct InviteFriendsPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var invites = Invites.shared

    var body: some View {
        PageHero(page: .inviteFriends)
        Section {
            SettingsRow("Message", detail: "Your name comes from Autofill › You.") {
                Image(nsImage: AppIconStyle.picture(.waxSeal, dark: false))
                    .resizable().interpolation(.high).frame(width: 30, height: 30)
                    .accessibilityHidden(true)
            }
            MessageBox(text: $invites.message)
                .settingsAnchor("invite-message")
            StampNoteRow()
            HStack(spacing: 8) {
                Text(invites.left == 1 ? "1 invite left this week" : "\(invites.left) invites left this week")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                CopyLinkButton(best: false)
            }
        } footer: {
            if let problem = invites.problem { SettingsNote(problem) }
        }
        Section {
            SettingsRow("Icons from friends", detail: "Find them in Appearance › App Icon.") {
                Text(invites.joined == 1 ? "1 joined" : "\(invites.joined) joined")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(Invites.ladder, id: \.style) { rung in
                    RewardTile(style: rung.style, needs: rung.friends == 1 ? "1 friend" : "\(rung.friends) friends")
                }
                Button { model.go(.bestFriend) } label: {
                    VStack(spacing: 4) {
                        CharmPicture(side: 64)
                        Text("Best Friends")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(invites.best?.name ?? "One friend")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Best Friend")
            }
            .padding(.vertical, 4)
            .settingsAnchor("invite-icons")
        } footer: {
            if let next = invites.next {
                SettingsNote("\(next.more) more \(next.more == 1 ? "friend" : "friends") to \(next.style.title). A friend counts once they open Yab. Best Friends comes from one friend, any time.")
            }
        }
        PostSection()
        Section {
            FeatureRow(.bestFriend, detail: bestLine, model: model)
                .settingsAnchor("best-friend")
        }
        Section {
            if invites.friends.isEmpty {
                SettingsRow("Your invites", detail: "View invited friends and their joining status.") { EmptyView() }
            } else {
                ForEach(invites.friends) { friend in
                    SettingsRow(verbatim: friend.name, detail: state(friend)) {
                        Circle()
                            .fill(Color.primary.opacity(0.08))
                            .overlay(Text(String(friend.name.prefix(1))).font(.system(size: 11, weight: .semibold)))
                            .frame(width: 24, height: 24)
                    }
                }
            }
        }
        .task { await invites.refresh() }
    }

    private var bestLine: String {
        guard let best = invites.best else { return "One friend. You each get half of a charm." }
        guard best.joined else { return "\(best.name) hasn't opened Yab yet." }
        return invites.bestHere ? "\(best.name) · in Yab now, your halves are joined" : "\(best.name) · away"
    }

    private func state(_ friend: Invites.Friend) -> String {
        let prefix = friend.best ? "Best friend · " : ""
        switch friend.state {
        case "joined":
            return prefix + "Opened Yab" + (friend.at.map { " on " + $0.formatted(AppDates.dateTime.month(.abbreviated).day()) } ?? "")
        case "opened": return prefix + "Opened the page, hasn't installed"
        default: return prefix + "Link copied"
        }
    }
}

/// Settings › Invite Friends › Best Friend.
struct BestFriendPage: View {
    @ObservedObject private var invites = Invites.shared
    @State private var changing = false

    var body: some View {
        Section {} header: {
            VStack(spacing: 0) {
                HoverCharm(side: 140, whole: invites.best?.joined != true)
                    .padding(.bottom, 4)
                Text(SettingsWords.text("Best Friend"))
                    .font(.system(size: 22, weight: .bold))
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom in
                        SettingsWindow.shared.heroTitle("Best Friend", bottom: bottom)
                    }
                Text(blurb)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .padding(.horizontal, 24)
            }
            .foregroundStyle(.primary)
            .textCase(nil)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)
            .accessibilityElement(children: .combine)
        }
        Section {
            SettingsRow("Your half", detail: "Your half's color on both Dock icons.") {
                HStack(spacing: 6) {
                    ForEach(CharmDraw.colors, id: \.self) { name in
                        SwatchButton(name: name, on: invites.myColor == name) { invites.myColor = name }
                    }
                }
            }
            .settingsAnchor("best-color")
            SettingsRow("Their half", detail: theirLine) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(CharmSwatch.color(invites.best?.color ?? "silver"))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                        .frame(width: 22, height: 22)
                    Text(invites.best?.color?.capitalized ?? "Their pick")
                        .foregroundStyle(.secondary)
                }
            }
        }
        if let best = invites.best {
            Section {
                SettingsRow(verbatim: best.name, detail: best.joined ? (invites.bestHere ? "In Yab now. Your halves are joined." : "Away right now.") : "Hasn't opened Yab yet.") {
                    CharmPicture(side: 36)
                }
                SettingsSwitch("Let \(best.name) see when I'm in Yab", isOn: $invites.shares)
                    .settingsAnchor("best-shares")
                SettingsSwitch("Show it in the icon", isOn: $invites.showsAway)
                    .settingsAnchor("best-icon")
                SettingsRow("Change best friend", detail: "\(best.name) keeps a whole Wax Seal.") {
                    Button(SettingsWords.text("Change…")) { changing = true }
                        .buttonStyle(.yab(.secondary, .regular))
                }
            } footer: {
                SettingsNote("Share only whether Yab is open with \(best.name). Show it in the icon separates the halves while either person is away.")
            }
            .confirmationDialog("Pick a new best friend?", isPresented: $changing) {
                Button("Change Best Friend", role: .destructive) { Task { await invites.changeBest() } }
            } message: {
                Text("\(best.name) keeps a whole Wax Seal, and you get a new link for your next best friend.")
            }
        } else if let received = invites.received, received.best {
            Section {
                SettingsRow(received.from, detail: invites.bestHere ? "In Yab now. Your halves are joined." : "Away right now.") {
                    CharmPicture(side: 36)
                }
                SettingsSwitch("Let \(received.from) see when I'm in Yab", isOn: $invites.shares)
                SettingsSwitch("Show it in the icon", isOn: $invites.showsAway)
            }
        } else {
            Section {
                SettingsRow("Message", detail: "Their half comes with this link.") { EmptyView() }
                MessageBox(text: $invites.bestMessage)
                    .settingsAnchor("best-message")
                HStack {
                    Text("One best friend").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    CopyLinkButton(best: true)
                }
            } footer: {
                if let problem = invites.problem { SettingsNote(problem) }
            }
        }
    }

    private var blurb: String {
        if let best = invites.best { return "You and \(best.name) each have half. While you're both in Yab, it joins in both Docks." }
        return "One friend, one charm. You keep half, they get the other. While you're both in Yab, it joins in both Docks."
    }

    private var theirLine: String {
        guard let best = invites.best else { return "Silver until your best friend picks a color on their page." }
        return best.color == nil ? "Silver until \(best.name) picks a color." : "\(best.name) picked it. Only they can change it."
    }
}
