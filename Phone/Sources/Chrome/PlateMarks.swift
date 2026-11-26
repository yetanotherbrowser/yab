import SwiftUI

/// The link that turns into a tick when it copies, as the Mac's address
/// bar draws it (CopyMark): the link shrinks to 0.2 as it goes, the tick
/// draws itself in its place, and both turn back after `held`.
struct LinkMark: View {
    let ticked: Bool
    let size: CGFloat
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var still

    /// How long the tick stays, the same as on the Mac.
    static let held: Duration = .milliseconds(1100)

    var body: some View {
        let quiet = still || Motion.disabled
        ZStack {
            Glyph(.link, size: size, color: color)
                .scaleEffect(ticked && !quiet ? 0.2 : 1)
                .opacity(ticked ? 0 : 1)
                .animation(quiet ? nil : ticked ? .easeIn(duration: 0.09) : .easeOut(duration: 0.16).delay(0.12), value: ticked)
            Tick()
                .trim(from: 0, to: ticked || quiet ? 1 : 0)
                .stroke(color, style: StrokeStyle(lineWidth: size / 12, lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
                .opacity(quiet && !ticked ? 0 : 1)
                .animation(quiet ? nil : ticked ? .easeOut(duration: 0.16).delay(0.1) : .easeIn(duration: 0.13), value: ticked)
        }
        .frame(width: size, height: size)
    }

    /// The checkmark's own line on its 24 square (Checkmark1).
    private struct Tick: Shape {
        func path(in rect: CGRect) -> Path {
            let unit = rect.width / 24
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + 5 * unit, y: rect.minY + 12.75 * unit))
            path.addLine(to: CGPoint(x: rect.minX + 10 * unit, y: rect.minY + 19 * unit))
            path.addLine(to: CGPoint(x: rect.minX + 19 * unit, y: rect.minY + 5 * unit))
            return path
        }
    }
}

/// Reload and Stop as the Mac swaps them (Unwind): the
/// glyph going shrinks to 0.8 as it fades while the one coming grows from
/// 0.8, a tenth of a second, so it reads as one icon turning into the
/// other. Stop shows only if the page is still loading half a second after
/// the press, so a quick load never flashes the cross.
struct ReloadMark: View {
    let stop: Bool
    let size: CGFloat
    let stopSize: CGFloat
    let color: Color
    @State private var showingStop = false

    private static let shrunk: CGFloat = 0.8

    var body: some View {
        ZStack {
            // The Mac's marks, as the iPad's and the Mac's own Reload and Stop.
            Glyph(mac: .yabReload, size: size, color: color)
                .scaleEffect(showingStop ? Self.shrunk : 1)
                .opacity(showingStop ? 0 : 1)
            Glyph(mac: .yabStop, size: stopSize, color: color)
                .scaleEffect(showingStop ? 1 : Self.shrunk)
                .opacity(showingStop ? 1 : 0)
        }
        .animation(Motion.disabled ? nil : .easeInOut(duration: 0.1), value: showingStop)
        .task(id: stop) {
            if stop, !Motion.disabled {
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            showingStop = stop
        }
    }
}

/// Reload's press, the Mac's (Side.Door.Give): a quarter turn the moment
/// the finger lands, in about a tenth of a second, back a little slower;
/// Stop only presses.
struct QuarterTurnPress: ButtonStyle {
    let stop: Bool
    @Environment(\.accessibilityReduceMotion) private var still

    func makeBody(configuration: Configuration) -> some View {
        let turns = !stop && !still && !Motion.disabled
        configuration.label
            .rotationEffect(.degrees(turns && configuration.isPressed ? 90 : 0))
            .opacity(!turns && configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.1 : 0.14), value: configuration.isPressed)
    }
}
