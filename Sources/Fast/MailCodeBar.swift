import SwiftUI

struct MailCodeBar: View {
    let item: MailCodeItem
    var browser: Browser?
    @ObservedObject private var codes = MailCodeState.shared

    var body: some View {
        let state = codes.state(item)
        let destination = browser?.codeBox(for: item)
        HStack(spacing: 16) {
            MailCodeChip(item: item, size: 30) // design: the chosen code card uses a 30 pt code
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(detail(state)).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            Button { codes.copy(item) } label: {
                HStack(spacing: 8) { Text("Copy"); KeyGlyphs(keys: "⌘C", size: 12, tint: nil) }
            }
            .buttonStyle(.yab(destination == nil ? .primary : .secondary, .regular))
            .focusable(false)
            .keyTip("Copy code", keys: "⌘C")
            if let destination, let site = destination.address?.host(), let browser {
                Button("Fill on " + site) { browser.fillCode(item, into: destination) }
                    .buttonStyle(.yab(.primary, .regular))
                    .focusable(false)
            }
        }
        .cardFrame()
    }

    private var title: String { FieldMail.title(item.read) }

    private func detail(_ state: MailCodes.State) -> String {
        let time = item.expires.englishFormatted(date: .omitted, time: .shortened)
        if state == .used, let used = MailCenter.shared.engines[item.account]?.store.codeUse(message: item.message) {
            return "Entered on " + used.site + " at " + used.at.englishFormatted(date: .omitted, time: .shortened)
        }
        if state == .copied { return "On the clipboard until " + time }
        let prefix = item.read.card.map { "Card ••" + $0 + " · " } ?? ""
        if state == .expired { return prefix + "Expired at " + time }
        return prefix + "Expires at " + time + ", \(max(1, Int(ceil(item.expires.timeIntervalSinceNow / 60)))) min left"
    }
}
