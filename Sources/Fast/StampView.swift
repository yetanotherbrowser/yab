import AppKit
import SwiftUI

// The stamp itself (Stamp.swift), drawn: cream paper with grain, a printed
// frame, the number, the Yab face pressed into the paper with its blush
// printed red, and the note on the back. A lamp stands at the top left; under
// the pointer it follows it, the pressed face catches the light from there,
// and the paper lets the note on the back show through, mirrored.

/// One stamp, drawn at 360 × 460 points and scaled by whoever shows it.
struct StampArt: View {
    static let size = CGSize(width: 360, height: 460)

    /// Nil before the site gave the number: a dash.
    var number: String?
    var name: String = ""
    /// The printed blush; a best friend's in the sender's half color.
    var blush: Color? = nil
    /// The back's note and who signed it, shown only where the lamp is.
    var note: String = ""
    var signed: String = ""
    /// The lamp, in the stamp's points; how far the light comes through (0 to 1).
    var lamp = CGPoint(x: 70, y: 40)
    var through: Double = 0
    /// The first day with Yab, dated at the top of the note, and the
    /// anniversaries since: a postmark each, the earlier ones kept.
    var since: Date? = nil
    var anniversaries: [Date] = []

    private static let paper = Color(red: 0xF4 / 255, green: 0xEB / 255, blue: 0xD8 / 255)
    private static let ink = Color(red: 0xC8 / 255, green: 0x45 / 255, blue: 0x2F / 255)
    private static let pen = Color(red: 0x2B / 255, green: 0x3A / 255, blue: 0x78 / 255)
    private static let red = Color(red: 0xD8 / 255, green: 0x31 / 255, blue: 0x2B / 255)

    var body: some View {
        ZStack {
            Self.paper
            StampGrain()
            frame
            printed
            face
            postmarks
            back
            // The lamp's warmth on the paper.
            RadialGradient(colors: [Color(red: 1, green: 0.98, blue: 0.93).opacity(0.75 * through), .clear],
                           center: unit(lamp), startRadius: 0, endRadius: 230)
                .blendMode(.screen)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(Perforated())
        .compositingGroup()
    }

    private var frame: some View {
        ZStack {
            Rectangle().stroke(Self.ink, lineWidth: 2.4).padding(34)  // design: stamp artwork, drawn in its own 360 × 460 points
            Rectangle().stroke(Self.ink, lineWidth: 0.8).padding(40)  // design: stamp artwork, drawn in its own 360 × 460 points
        }
    }

    private var printed: some View {
        ZStack(alignment: .topLeading) {
            Text(number ?? "—")
                .font(.system(size: (number?.count ?? 1) > 2 ? 44 : 54, weight: .heavy))
                .tracking(-2)
                .foregroundStyle(Self.ink)
                .position(x: 56 + width(of: number ?? "—", size: (number?.count ?? 1) > 2 ? 44 : 54) / 2, y: 76)
            Text("YAB POST")
                .font(.system(size: 10, weight: .heavy)).tracking(3.2)
                .foregroundStyle(Self.ink)
                .position(x: Self.size.width - 56 - 38, y: 66)
            if !name.isEmpty {
                Text(name)
                    .font(Font(UpdateInk.hand(30, weight: 700)))
                    .foregroundStyle(Color(red: 0x7A / 255, green: 0x3A / 255, blue: 0x2A / 255))
                    .position(x: Self.size.width / 2, y: 384)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    /// The face, pressed: the oval stands up from the paper, the eye and the
    /// smile sink into it. Their light and shadow come from the lamp.
    private var face: some View {
        let center = CGPoint(x: Self.size.width / 2, y: 200)
        let dx = center.x - lamp.x, dy = center.y - lamp.y, length = max(1, hypot(dx, dy))
        let ox = dx / length * 2.4, oy = dy / length * 2.4
        let paper = Self.paper
        return ZStack {
            Ellipse()
                .fill(paper
                    .shadow(.inner(color: .white.opacity(0.9), radius: 1.2, x: -ox, y: -oy))  // design: stamp artwork, drawn in its own 360 × 460 points
                    .shadow(.inner(color: .black.opacity(0.22), radius: 2, x: ox, y: oy))  // design: stamp artwork, drawn in its own 360 × 460 points
                    .shadow(.drop(color: .black.opacity(0.28), radius: 2.6, x: ox * 1.2, y: oy * 1.2))  // design: stamp artwork, drawn in its own 360 × 460 points
                    .shadow(.drop(color: .white.opacity(0.8), radius: 1, x: -ox, y: -oy)))  // design: stamp artwork, drawn in its own 360 × 460 points
                .frame(width: 192, height: 144)
            Ellipse()
                .stroke(Color.black.opacity(0.05), lineWidth: 3)
                .frame(width: 208, height: 160)
            features
                .fill(paper
                    .shadow(.inner(color: .black.opacity(0.38), radius: 2.2, x: -ox, y: -oy))  // design: stamp artwork, drawn in its own 360 × 460 points
                    .shadow(.inner(color: .white.opacity(0.7), radius: 1, x: ox, y: oy)))  // design: stamp artwork, drawn in its own 360 × 460 points
            Ellipse()
                .fill(blush ?? Self.red)
                .frame(width: 30, height: 20)
                .offset(x: 50, y: 24)
                .opacity(0.9)
        }
        .rotationEffect(.degrees(-14))
        .scaleEffect(0.95)
        .position(center)
    }

    /// The eye and the smile, in the face's own points.
    private var features: some Shape {
        FaceFeatures()
    }

    /// One postmark for each anniversary, each year in a place and at a
    /// tilt of its own, the earlier ones left where they fell.
    private var postmarks: some View {
        ZStack {
            ForEach(Array(anniversaries.enumerated()), id: \.offset) { index, day in
                let spot = Postmark.spots[index % Postmark.spots.count]
                Postmark(year: index + 1, day: day, leftward: spot.leftward)
                    .rotationEffect(.degrees(spot.tilt))
                    .position(x: spot.x, y: spot.y)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    /// The note on the back, through the paper: mirrored, softened, and only
    /// where the lamp is.
    private var back: some View {
        StampNote(note: note, signed: signed, since: since)
            .scaleEffect(x: -1, y: 1)
            .blur(radius: 0.7)
            .opacity(0.7 * through)
            .mask(RadialGradient(colors: [.white, .white.opacity(0.6), .clear], center: unit(lamp), startRadius: 0, endRadius: 230))
    }

    private func unit(_ point: CGPoint) -> UnitPoint {
        UnitPoint(x: point.x / Self.size.width, y: point.y / Self.size.height)
    }

    private func width(of text: String, size: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .heavy)]).width - 2 * CGFloat(text.count)
    }
}

/// What is written on the back, as the sender wrote it: the day at the top
/// right like any letter, the note, their name. Drawn in the stamp's points.
private struct StampNote: View {
    let note: String
    let signed: String
    let since: Date?

    private static let pen = Color(red: 0x2B / 255, green: 0x3A / 255, blue: 0x78 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let since {
                Text(Postmark.dateline(since))
                    .font(Font(UpdateInk.hand(22, weight: 600)))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.bottom, 8)
            }
            ForEach(Array(note.split(separator: "\n").enumerated()), id: \.offset) { index, line in
                Text(String(line))
                    .font(Font(UpdateInk.hand(index == 0 ? 36 : 28, weight: index == 0 ? 700 : 600)))
            }
            if !signed.isEmpty {
                Text(signed)
                    .font(Font(UpdateInk.hand(34, weight: 700)))
                    .padding(.leading, 110)  // design: stamp artwork, drawn in its own 360 × 460 points
                    .padding(.top, 8)
            }
        }
        .foregroundStyle(Self.pen)
        .rotationEffect(.degrees(-4))
        .frame(width: StampArt.size.width - 100, alignment: .leading)
        .position(x: StampArt.size.width / 2, y: 210)
        .frame(width: StampArt.size.width, height: StampArt.size.height)
    }
}

/// The stamp turned over: bare paper with what the sender wrote on it.
struct StampBack: View {
    var note: String = ""
    var signed: String = ""
    var since: Date? = nil

    private static let paper = Color(red: 0xF1 / 255, green: 0xE7 / 255, blue: 0xD2 / 255)

    var body: some View {
        ZStack {
            Self.paper
            StampGrain()
            StampNote(note: note, signed: signed, since: since)
        }
        .frame(width: StampArt.size.width, height: StampArt.size.height)
        .clipShape(Perforated())
        .compositingGroup()
    }
}

/// An anniversary's postmark, in dark ink over the print: the year's number
/// in a double ring, YAB POST and the day round it, and the cancel's waves
/// running off to one side.
struct Postmark: View {
    let year: Int
    let day: Date
    let leftward: Bool

    /// Where each year's falls on the stamp, and which way its waves run:
    /// clear of the number and the name, however many years pile up.
    static let spots: [(x: CGFloat, y: CGFloat, tilt: Double, leftward: Bool)] = [
        (262, 152, -12, false), (100, 300, 9, true), (268, 318, -5, false), (96, 196, 8, true),
        (230, 236, -16, false), (170, 150, 13, false), (282, 400, -8, false), (80, 400, 6, true),
        (180, 250, 4, false), (290, 230, -20, false), (120, 250, -9, true), (220, 330, 15, false),
    ]

    private static let ink = Color(red: 0x26 / 255, green: 0x2A / 255, blue: 0x3D / 255)

    private static func format(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter
    }
    private static let stampDay = format("d MMM yyyy")
    private static let letterDay = format("MMM d, yyyy")

    /// "23 OCT 2027", as a postmark prints it.
    static func printed(_ day: Date) -> String { stampDay.string(from: day).uppercased() }
    /// "Oct 23, 2026", as a letter is dated.
    static func dateline(_ day: Date) -> String { letterDay.string(from: day) }

    var body: some View {
        ZStack {
            PostmarkWaves()
                .stroke(Self.ink, lineWidth: 2.2)
                .frame(width: 122, height: 44)
                .offset(x: leftward ? -109 : 109)
            Circle().stroke(Self.ink, lineWidth: 2.6).frame(width: 90, height: 90)
            Circle().stroke(Self.ink, lineWidth: 1.2).frame(width: 46, height: 46)
            ArcText(text: "YAB POST", radius: 30, size: 9, tracking: 2.2, top: true)
            ArcText(text: Self.printed(day), radius: 34, size: 8.5, tracking: 1.6, top: false)
            VStack(spacing: -1) {
                Text("\(year)")
                    .font(.system(size: year > 9 ? 20 : 24, weight: .black))
                    .tracking(-1)
                Text(year == 1 ? "YEAR" : "YEARS")
                    .font(.system(size: 5.5, weight: .heavy))  // design: stamp artwork, drawn in its own 360 × 460 points
                    .tracking(1.2)
            }
            .foregroundStyle(Self.ink)
        }
        .frame(width: 90, height: 90)
        .mask(InkSpeckle().frame(width: 360, height: 120))
        .opacity(0.78)
        .blendMode(.multiply)
    }
}

/// Four wavy cancel lines, a hand-stamp's worth.
private struct PostmarkWaves: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for row in 0 ..< 4 {
            let y = rect.minY + rect.height * (CGFloat(row) + 0.5) / 4
            let step = rect.width / 6
            path.move(to: CGPoint(x: rect.minX, y: y))
            for hump in 1 ... 6 {
                let x = rect.minX + step * CGFloat(hump)
                path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x - step / 2, y: y + (hump % 2 == 1 ? -5 : 5)))
            }
        }
        return path
    }
}

/// Letters set round a circle: over the top reading clockwise, or under the
/// bottom reading left to right, upright.
private struct ArcText: View {
    let text: String
    let radius: CGFloat
    let size: CGFloat
    let tracking: CGFloat
    let top: Bool

    var body: some View {
        let letters = Array(text).map(String.init)
        let font = NSFont.systemFont(ofSize: size, weight: .heavy)
        let widths = letters.map { ($0 as NSString).size(withAttributes: [.font: font]).width + tracking }
        let total = widths.reduce(0, +)
        let centers = widths.indices.map { index in widths[..<index].reduce(0, +) + widths[index] / 2 - total / 2 }
        ZStack {
            ForEach(letters.indices, id: \.self) { index in
                let angle = Double(centers[index] / radius)
                Text(letters[index])
                    .font(.system(size: size, weight: .heavy))
                    .rotationEffect(.radians(top ? angle : -angle))
                    .offset(x: radius * CGFloat(sin(angle)), y: (top ? -1 : 1) * radius * CGFloat(cos(angle)))
            }
        }
        .foregroundStyle(Color(red: 0x26 / 255, green: 0x2A / 255, blue: 0x3D / 255))
    }
}

/// Where a hand-stamp's ink didn't take: specks left out of a postmark.
private struct InkSpeckle: View {
    private static let tile: NSImage = {
        let side = 120
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSGraphicsContext.current?.compositingOperation = .clear
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 1100 {
            let x = CGFloat(Int.random(in: 0 ..< side, using: &generator)), y = CGFloat(Int.random(in: 0 ..< side, using: &generator))
            let r = CGFloat.random(in: 0.4 ... 1.3, using: &generator)
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 2 * r, height: 2 * r)).fill()
        }
        image.unlockFocus()
        return image
    }()

    var body: some View {
        Rectangle().fill(ImagePaint(image: Image(nsImage: Self.tile), scale: 1))
    }
}

/// The eye and the smile, as the face is drawn (the oval is 192 × 144).
private struct FaceFeatures: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        path.addRoundedRect(in: CGRect(x: c.x - 50, y: c.y - 30, width: 22, height: 58), cornerSize: CGSize(width: 11, height: 11))
        var smile = Path()
        smile.move(to: CGPoint(x: c.x - 6, y: c.y + 6))
        smile.addCurve(to: CGPoint(x: c.x + 58, y: c.y - 16), control1: CGPoint(x: c.x + 14, y: c.y - 16), control2: CGPoint(x: c.x + 40, y: c.y - 24))
        path.addPath(smile.strokedPath(StrokeStyle(lineWidth: 18, lineCap: .round)))
        path.addEllipse(in: CGRect(x: c.x + 34, y: c.y + 13, width: 32, height: 22))
        return path
    }
}

/// The stamp's edge: the paper with its perforation bitten out.
private struct Perforated: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / StampArt.size.width, sy = rect.height / StampArt.size.height
        let inner = CGRect(x: 14 * sx, y: 14 * sy, width: 332 * sx, height: 432 * sy)
        var holes = Path()
        let gap = 16 * sx, r = 6.6 * sx
        var x = inner.minX + gap / 2
        while x < inner.maxX {
            holes.addEllipse(in: CGRect(x: x - r, y: inner.minY - r, width: 2 * r, height: 2 * r))
            holes.addEllipse(in: CGRect(x: x - r, y: inner.maxY - r, width: 2 * r, height: 2 * r))
            x += gap
        }
        var y = inner.minY + gap / 2
        while y < inner.maxY {
            holes.addEllipse(in: CGRect(x: inner.minX - r, y: y - r, width: 2 * r, height: 2 * r))
            holes.addEllipse(in: CGRect(x: inner.maxX - r, y: y - r, width: 2 * r, height: 2 * r))
            y += gap
        }
        return Path(inner).subtracting(holes)
    }

    func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { StampArt.size }
}

/// The paper's grain: a speckle drawn once and tiled.
private struct StampGrain: View {
    private static let tile: NSImage = {
        let side = 160
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 2200 {
            let x = CGFloat(Int.random(in: 0 ..< side, using: &generator)), y = CGFloat(Int.random(in: 0 ..< side, using: &generator))
            NSColor(red: 0.42, green: 0.33, blue: 0.2, alpha: CGFloat.random(in: 0.03 ... 0.1, using: &generator)).setFill()
            NSRect(x: x, y: y, width: 1, height: 1).fill()
        }
        for _ in 0 ..< 14 {
            let x = CGFloat.random(in: 0 ..< CGFloat(side)), y = CGFloat.random(in: 0 ..< CGFloat(side)), r = CGFloat.random(in: 0.5 ... 1.2)
            NSColor(red: 0.54, green: 0.42, blue: 0.27, alpha: CGFloat.random(in: 0.15 ... 0.35)).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 2 * r, height: 2 * r)).fill()
        }
        image.unlockFocus()
        return image
    }()

    var body: some View {
        Rectangle().fill(ImagePaint(image: Image(nsImage: Self.tile), scale: 1))
    }
}

/// The stamp with its lamp: the light follows the pointer and the note on
/// the back shows through around it. A click turns it over to read the
/// note as written, dated the first day.
struct StampView: View {
    let info: MemberStamp.Info
    var width: CGFloat = 210
    var since: Date? = nil

    @State private var lamp = CGPoint(x: 70, y: 40)
    @State private var through = 0.0
    @State private var turned = false

    /// The first day and the note, for VoiceOver.
    private var spoken: String {
        let note = info.note.replacingOccurrences(of: "\n", with: " ")
        guard let since else { return note }
        return "With Yab since \(Postmark.dateline(since)). \(note)"
    }

    var body: some View {
        let scale = width / StampArt.size.width
        ZStack {
            StampArt(number: "\(info.number)", name: Invites.firstName, note: info.note, signed: info.from,
                     lamp: lamp, through: through, since: since, anniversaries: MemberStamp.anniversaries(since: since))
                .modifier(TurnedFace(angle: turned ? 180 : 0))
            StampBack(note: info.note, signed: info.from, since: since)
                .modifier(TurnedFace(angle: turned ? 0 : -180))
        }
            .scaleEffect(scale)
            .frame(width: width, height: StampArt.size.height * scale)
            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)  // design: the paper stamp lifts off the page like the friend icons, not a card
            .shadow(color: .black.opacity(0.13), radius: 12, y: 10)  // design: the paper stamp lifts off the page like the friend icons, not a card
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let at):
                    withAnimation(.easeOut(duration: 0.18)) { lamp = CGPoint(x: at.x / scale, y: at.y / scale) }
                    withAnimation(.easeOut(duration: 0.5)) { through = 1 }
                case .ended:
                    withAnimation(.easeOut(duration: 0.6)) {
                        lamp = CGPoint(x: 70, y: 40)
                        through = 0
                    }
                }
            }
            .onTapGesture { withAnimation(.spring(duration: 0.55, bounce: 0.15)) { turned.toggle() } }
            .keyTip(turned ? "Turn Back" : "Turn Over")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Stamp No. \(info.number), from \(info.from)")
            .accessibilityValue(spoken)
            .accessibilityAddTraits(.isButton)
    }
}

/// One side of the stamp as it turns: seen while it faces the viewer,
/// gone once it is edge on.
private struct TurnedFace: ViewModifier, Animatable {
    var angle: Double
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
            .opacity(abs(angle) < 90 ? 1 : 0)
    }
}

/// Settings › About: the stamp, its number and who it's from.
struct StampAboutSection: View {
    @ObservedObject private var stamp = MemberStamp.shared

    var body: some View {
        if let info = stamp.info {
            Section {
                HStack(spacing: 24) {
                    StampView(info: info, width: 170, since: stamp.since)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No. \(info.number)")
                            .font(.system(size: 22, weight: .bold))
                            .monospacedDigit()
                        Text("from \(info.from), \(info.at.formatted(AppDates.dateTime.month(.abbreviated).day()))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 12)
            }
        }
    }
}

/// Invite Friends: what goes on the back of their stamp.
struct StampNoteRow: View {
    @ObservedObject private var stamp = MemberStamp.shared

    /// The stamp's navy pen, lifted to a pale blue on a dark field.
    private static let pen = Color(nsColor: NSColor(name: nil) { look in
        look.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x9C / 255, green: 0xAE / 255, blue: 0xF0 / 255, alpha: 1)
            : NSColor(srgbRed: 0x2B / 255, green: 0x3A / 255, blue: 0x78 / 255, alpha: 1)
    })

    var body: some View {
        SettingsRow("On the back of their stamp", detail: "They read it in Yab.") {
            // Remove the whole hand-drawn prompt on the first character,
            // including any ink above the baseline.
            TextField("On the back of their stamp", text: $stamp.outgoing, prompt: Text(""))
                .labelsHidden()
                .lineLimit(1)
                .textFieldStyle(.plain)
                .font(Font(UpdateInk.hand(20, weight: 600)))
                .foregroundStyle(Self.pen)
                .overlay(alignment: .leading) {
                    if stamp.outgoing.isEmpty {
                        Text("hey,")
                            .font(Font(UpdateInk.hand(20, weight: 600)))
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 220)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(Color.primary.opacity(0.04)))
                .onChange(of: stamp.outgoing) { _, value in
                    if value.count > 140 { stamp.outgoing = String(value.prefix(140)) }
                }
                .benchSpot("stamp-note")
        }
    }
}
