import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The "Dziennik" window: entries by day. Click, ⌘- or ⇧-click to choose entries, then ⌘C,
/// the context menu or the button copies just those; with nothing chosen the button copies all.
struct JournalView: View {
    @ObservedObject var journal: Journal
    @State private var selection = Set<JournalEntry.ID>()
    @State private var problem: String?

    private var chosen: [JournalEntry] { journal.entries.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            if journal.entries.isEmpty {
                ContentUnavailableView("Dziennik jest pusty", systemImage: "book.closed",
                                       description: Text("Dyktuj, gdy nie stoisz w żadnym polu tekstowym — tekst trafi tutaj."))
            } else {
                List(selection: $selection) {
                    ForEach(journal.days, id: \.day) { day in
                        Section(Journal.dayTitle(day.day)) {
                            ForEach(day.entries) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(Journal.time(entry.date))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                    Text(entry.text)
                                }
                                .tag(entry.id)
                            }
                        }
                    }
                }
                .contextMenu(forSelectionType: JournalEntry.ID.self) { ids in
                    if !ids.isEmpty {
                        Button("Kopiuj") { copy(Journal.plainText(journal.entries.filter { ids.contains($0.id) })) }
                        Button("Usuń", role: .destructive) {
                            do {
                                try journal.remove(ids)
                                selection.subtract(ids)
                            } catch {
                                problem = error.localizedDescription
                            }
                        }
                    }
                }
                .onCopyCommand {
                    chosen.isEmpty ? [] : [NSItemProvider(object: Journal.plainText(chosen) as NSString)]
                }
            }
            Divider()
            HStack {
                Text("\(journal.entries.count) wpisów").foregroundStyle(.secondary)
                Spacer()
                if chosen.isEmpty {
                    Button("Kopiuj wszystko") { copy(Journal.markdown(journal.entries)) }
                } else {
                    Button("Kopiuj zaznaczone (\(chosen.count))") { copy(Journal.plainText(chosen)) }
                }
                Button("Eksportuj…") { export() }
            }
            .disabled(journal.entries.isEmpty)
            .padding(10)
        }
        .frame(minWidth: 460, minHeight: 360)
        .alert(Text(verbatim: problem ?? ""), isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = String(localized: "Dziennik VoiceAI") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Journal.markdown(journal.entries).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            problem = error.localizedDescription
        }
    }
}

final class JournalWindow {
    private var window: NSWindow?
    private let journal: Journal

    init(journal: Journal) {
        self.journal = journal
    }

    func show() {
        journal.load()
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: JournalView(journal: journal)))
            window.title = String(localized: "VoiceAI — Dziennik")
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 520, height: 480))
            window.center()
            // Size and place are kept between openings and launches.
            window.setFrameAutosaveName("VoiceAI.Dziennik")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
