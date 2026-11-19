import Foundation
import AppKit
import Testing
@testable import DolaLite

@MainActor
@Suite struct HistoryStoreTests {
    @Test func persistsEntriesInNewestFirstOrderAndKeepsPrivateFilePermissions() throws {
        try withTemporaryDirectory { directory in
            let store = HistoryStore(directory: directory)
            let older = HistoryEntry(skill: .translate, createdAt: Date(timeIntervalSince1970: 1),
                                     model: "model-a", sourceText: "Hello", resultText: "Xin chào")
            let newer = HistoryEntry(skill: .summarize, createdAt: Date(timeIntervalSince1970: 2),
                                     model: "model-b", sourceText: "Long text", resultText: "Summary")
            try store.add(older)
            try store.add(newer)

            let restored = HistoryStore(directory: directory)
            #expect(restored.entries == [newer, older])
            #expect(restored.entries.first?.sourcePreview == "Long text")
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("history.json").path)
            #expect(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o600)
        }
    }

    @Test func removesOneEntryAndClearsHistory() throws {
        try withTemporaryDirectory { directory in
            let store = HistoryStore(directory: directory)
            let first = makeEntry("first")
            let second = makeEntry("second")
            try store.add(first)
            try store.add(second)
            try store.remove(id: first.id)
            #expect(store.entries == [second])
            try store.removeAll()
            #expect(store.entries.isEmpty)
            #expect(HistoryStore(directory: directory).entries.isEmpty)
        }
    }

    @Test func limitsHistoryToMostRecentTwoHundredEntries() throws {
        try withTemporaryDirectory { directory in
            let store = HistoryStore(directory: directory)
            for index in 0...HistoryStore.maximumEntries {
                try store.add(makeEntry("entry-\(index)"))
            }
            #expect(store.entries.count == HistoryStore.maximumEntries)
            #expect(store.entries.first?.sourceText == "entry-\(HistoryStore.maximumEntries)")
            #expect(!store.entries.contains(where: { $0.sourceText == "entry-0" }))
        }
    }

    @Test @MainActor func historyListUsesTopToBottomLayout() {
        #expect(FlippedHistoryStackView().isFlipped)
    }

    @Test @MainActor func historyBrowserSeparatesRowsAndPreviewAndShowsNewestFirst() throws {
        _ = NSApplication.shared
        try withTemporaryDirectory { directory in
            let store = HistoryStore(directory: directory)
            let oldest = HistoryEntry(skill: .translate, createdAt: Date(timeIntervalSince1970: 1), model: "old",
                                      sourceText: "old source", resultText: "old result")
            let newest = HistoryEntry(skill: .explain, createdAt: Date(timeIntervalSince1970: 2), model: "new",
                                      sourceText: "new source", resultText: "new result")
            try store.add(oldest)
            try store.add(newest)

            let controller = HistoryWindowController(store: store)
            defer { controller.close() }
            controller.present()
            controller.window?.contentView?.layoutSubtreeIfNeeded()

            @MainActor func descendants(of view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap(descendants)
            }
            guard let content = controller.window?.contentView else {
                Issue.record("Expected history window content")
                return
            }
            let views = descendants(of: content)
            guard let listScroll = views.compactMap({ $0 as? NSScrollView }).first,
                  let list = listScroll.documentView as? FlippedHistoryStackView else {
                Issue.record("Expected the history list to use a flipped document view")
                return
            }
            #expect(listScroll.frame.height >= 200)
            let rowButtons = list.arrangedSubviews.compactMap { $0 as? NSButton }
            #expect(rowButtons.count == 2)
            #expect(rowButtons.first?.title.hasPrefix("Giải thích") == true)
            #expect(rowButtons.last?.title.hasPrefix("Dịch") == true)
            if rowButtons.count == 2 {
                #expect(rowButtons[0].frame.height >= 36)
                #expect(rowButtons[0].frame.minY < rowButtons[1].frame.minY)
            }
            #expect(list.arrangedSubviews.contains(where: { ($0 as? HistoryDividerView)?.axis == .horizontal }))
            #expect(views.contains(where: { ($0 as? HistoryDividerView)?.axis == .vertical }))
        }
    }

    @Test func reportsCorruptHistoryAndDoesNotLoadPartialEntries() throws {
        try withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("not-json".utf8).write(to: directory.appendingPathComponent("history.json"))
            let store = HistoryStore(directory: directory)
            #expect(store.entries.isEmpty)
            #expect(store.hasReadError)
        }
    }

    @Test func rejectsOversizedEntryWithoutChangingExistingHistory() throws {
        try withTemporaryDirectory { directory in
            let store = HistoryStore(directory: directory)
            let existing = makeEntry("existing")
            try store.add(existing)
            let oversized = HistoryEntry(skill: .translate, model: "model", sourceText: "source",
                                         resultText: String(repeating: "x", count: 600_000))
            #expect(throws: HistoryStoreError.entryTooLarge) { try store.add(oversized) }
            #expect(store.entries == [existing])
        }
    }

    private func makeEntry(_ source: String) -> HistoryEntry {
        HistoryEntry(skill: .explain, model: "fixture", sourceText: source, resultText: "result")
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DolaLite-HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
