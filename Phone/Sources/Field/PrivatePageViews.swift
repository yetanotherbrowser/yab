import SwiftUI

/// What Private's New Tab page shows by itself, with no plate under it: the
/// lock while it is locked (its shackle springs open on Unlock), the mask while
/// nothing is open.
struct PrivateMark: View {
    typealias M = Metrics.PrivatePage

    enum Mark: Equatable {
        case lock(open: Bool)
        case mask
    }

    let mark: Mark

    var body: some View {
        Group {
            switch mark {
            case let .lock(open):
                Image(systemName: open ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: M.lock, weight: .regular))
                    .contentTransition(.symbolEffect(.replace))
            case .mask:
                Glyph(.incognito, size: M.mask, color: Color.white.opacity(M.ink))
            }
        }
        .foregroundStyle(Color.white.opacity(mark == .mask ? M.ink : M.lockInk))
        .accessibilityHidden(true)
    }
}

/// Private with nothing open, once it is unlocked: the mask stands where the
/// lock opened, in the middle of the page, with two lines under it. The field
/// below is the action.
struct PrivateEmptyPage: View {
    typealias M = Metrics.PrivatePage

    var body: some View {
        GeometryReader { page in
            words
                .frame(maxWidth: .infinity)
                .padding(.top, max(0, page.size.height / 2 - M.mask / 2))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("private.empty")
    }

    private var words: some View {
        VStack(spacing: 0) {
            PrivateMark(mark: .mask)
            Text("Nothing open in Private")
                .font(.system(size: M.title, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.top, M.titleGap)
            Text("What you open here stays on this \(DeviceWord.name),\nwith no history or sync.")
                .font(.system(size: M.note))
                .foregroundStyle(Color.white.opacity(M.noteInk))
                .multilineTextAlignment(.center)
                .padding(.top, M.noteGap)
                .padding(.horizontal, M.noteInset)
        }
    }
}

extension Metrics {
    /// Private's page in New Tab, kept small. Locked: the lock (34,
    /// gray, no plate), "Private is Locked" 17 and an Unlock button, 20 apart,
    /// and nothing that says whether there is anything behind it: no count.
    /// Empty and unlocked, the mask (28), its words 16 semibold 12 under it
    /// and a line of 13.
    enum PrivatePage {
        static let lock: CGFloat = 34
        static let mask: CGFloat = 28
        static let ink: Double = 0.92
        static let lockInk: Double = 0.55
        static let lockGap: CGFloat = 20
        static let lockTitle: CGFloat = 17
        static let unlock: CGFloat = 15
        static let title: CGFloat = 16
        static let titleGap: CGFloat = 12
        static let note: CGFloat = 13
        static let noteGap: CGFloat = 3
        static let noteInk: Double = 0.6
        static let noteInset: CGFloat = 32
        /// The open lock is seen this long before the page takes its place, which
        /// grows in from `swapIn` as the lock fades to `swapOut`.
        static let openHold: TimeInterval = 0.1
        static let swapIn: CGFloat = 0.94
        static let swapOut: CGFloat = 0.9
    }
}
