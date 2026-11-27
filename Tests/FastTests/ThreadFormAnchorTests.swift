import AppKit
import SwiftUI
import Testing
@testable import Fast

/// Regression #1184: a Section with `.settingsAnchor` passes that anchor through
/// `ContainerValues` to every row inside it. `FormPiece.all` must give only the
/// first row that anchor id so `LazyVStack`'s `ForEach` never sees duplicate ids
/// and drops rows into blank gaps.
@MainActor
struct ThreadFormAnchorTests {
    private final class Probe {
        var pieces: [FormPiece] = []
        var appeared: Set<String> = []
    }

    private struct SectionProbeView: View {
        let probe: Probe

        var body: some View {
            Group(sections: content) { sections in
                let built = FormPiece.all(Array(sections))
                Color.clear.onAppear { probe.pieces = built }
            }
        }

        @ViewBuilder private var content: some View {
            Section {
                Text("Claude")
                ForEach(["Fable", "Opus", "Sonnet", "Haiku"], id: \.self) { name in
                    Text(name)
                }
            } header: {
                Text("Models in lists")
            }
            .settingsAnchor("models-lists")

            Section {
                Text("ChatGPT")
                ForEach(["GPT-6", "GPT-5"], id: \.self) { name in
                    Text(name)
                }
            }
            .settingsAnchor("models-lists-codex")

            Section {
                Text("First").settingsAnchor("single-one")
                Text("Second").settingsAnchor("single-two")
            }
        }
    }

    private struct FormRenderProbeView: View {
        let probe: Probe

        var body: some View {
            ThreadForm {
                Section {
                    row("Claude")
                    ForEach(["Fable", "Opus", "Sonnet", "Haiku"], id: \.self) { name in
                        row(name)
                    }
                } header: {
                    Text("Models in lists")
                }
                .settingsAnchor("models-lists")
            }
            .frame(width: 500, height: 600)
        }

        private func row(_ name: String) -> some View {
            Text(name)
                .frame(height: 36, alignment: .leading)
                .onAppear { probe.appeared.insert(name) }
        }
    }

    private func pump<V: View>(_ view: V, until ready: () -> Bool) async throws {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 500, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<100 where !ready() {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func anchoredSectionGivesEveryRowAUniquePieceID() async throws {
        let probe = Probe()
        try await pump(SectionProbeView(probe: probe)) { !probe.pieces.isEmpty }
        // 1 header + 5 Claude rows + 3 ChatGPT rows + 2 individually anchored rows.
        #expect(probe.pieces.count == 11)
        let ids = probe.pieces.map(\.id)
        #expect(Set(ids).count == ids.count)
        // First row of each anchored section keeps the anchor id so scrollTo reaches it unbuilt.
        #expect(ids[1] == AnyHashable("models-lists"))
        #expect(ids[6] == AnyHashable("models-lists-codex"))
        #expect(ids[9] == AnyHashable("single-one"))
        #expect(ids[10] == AnyHashable("single-two"))
    }

    @Test func anchoredSectionRendersEveryRowInThreadForm() async throws {
        let probe = Probe()
        let expected: Set<String> = ["Claude", "Fable", "Opus", "Sonnet", "Haiku"]
        try await pump(FormRenderProbeView(probe: probe)) { probe.appeared == expected }
        #expect(probe.appeared == expected)
    }
}
