import Foundation

struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let skill: Skill
    let createdAt: Date
    let model: String
    let sourceText: String
    let resultText: String

    init(id: UUID = UUID(), skill: Skill, createdAt: Date = Date(), model: String,
         sourceText: String, resultText: String) {
        self.id = id
        self.skill = skill
        self.createdAt = createdAt
        self.model = model
        self.sourceText = sourceText
        self.resultText = resultText
    }

    var sourcePreview: String {
        let singleLine = sourceText.split(whereSeparator: \.isNewline).joined(separator: " ")
        return singleLine.count > 100 ? String(singleLine.prefix(100)) + "…" : singleLine
    }
}

enum HistoryStoreError: LocalizedError, Equatable {
    case entryTooLarge
    case storageFailure

    var errorDescription: String? {
        switch self {
        case .entryTooLarge:
            return "Kết quả quá lớn để lưu vào lịch sử. Bạn vẫn có thể xem và sao chép kết quả hiện tại."
        case .storageFailure:
            return "Không thể lưu lịch sử trên máy. Các chức năng dịch hiện tại vẫn dùng được."
        }
    }
}

/// Keeps completed results on this Mac, independent of API credentials and preferences.
@MainActor
final class HistoryStore {
    static let maximumEntries = 200
    private static let maximumEntryBytes = 512 * 1_024
    private static let maximumFileBytes = 16 * 1_024 * 1_024

    private let fileURL: URL
    private let fileManager = FileManager.default
    private(set) var entries: [HistoryEntry] = []
    private(set) var hasReadError = false

    init(directory: URL? = nil) {
        let base = directory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DolaLite", isDirectory: true)
        fileURL = base.appendingPathComponent("history.json")
        load()
    }

    func add(_ entry: HistoryEntry) throws {
        let entryData: Data
        do {
            entryData = try JSONEncoder().encode(entry)
        } catch {
            throw HistoryStoreError.storageFailure
        }
        guard entryData.count <= Self.maximumEntryBytes else { throw HistoryStoreError.entryTooLarge }

        var updated = [entry] + entries.filter { $0.id != entry.id }
        if updated.count > Self.maximumEntries {
            updated.removeLast(updated.count - Self.maximumEntries)
        }

        while true {
            let encoded: Data
            do {
                encoded = try JSONEncoder().encode(updated)
            } catch {
                throw HistoryStoreError.storageFailure
            }
            if encoded.count <= Self.maximumFileBytes {
                try write(encoded)
                entries = updated
                hasReadError = false
                return
            }
            guard updated.count > 1 else { throw HistoryStoreError.entryTooLarge }
            updated.removeLast()
        }
    }

    func remove(id: UUID) throws {
        try replace(with: entries.filter { $0.id != id })
    }

    func removeAll() throws {
        try replace(with: [])
    }

    private func load() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.intValue <= Self.maximumFileBytes else {
                throw HistoryStoreError.storageFailure
            }
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let decoded = try JSONDecoder().decode([HistoryEntry].self, from: data)
            guard decoded.count <= Self.maximumEntries else { throw HistoryStoreError.storageFailure }
            entries = decoded
        } catch {
            entries = []
            hasReadError = true
        }
    }

    private func replace(with updated: [HistoryEntry]) throws {
        do {
            let data = try JSONEncoder().encode(updated)
            guard data.count <= Self.maximumFileBytes else { throw HistoryStoreError.storageFailure }
            try write(data)
            entries = updated
            hasReadError = false
        } catch let error as HistoryStoreError {
            throw error
        } catch {
            throw HistoryStoreError.storageFailure
        }
    }

    private func write(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw HistoryStoreError.storageFailure
        }
    }
}
