import AppKit

struct SelectionSnapshot: Equatable {
    let text: String
    let bounds: NSRect?
    let sourcePID: pid_t
    let range: NSRange?

    init(text: String, bounds: NSRect?, sourcePID: pid_t, range: NSRange? = nil) {
        self.text = text
        self.bounds = bounds
        self.sourcePID = sourcePID
        self.range = range
    }
}

enum SelectionFilter {
    static func sanitize(_ text: String, minimum: Int = 2, maximum: Int = 10_000) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard minimum > 0, maximum >= minimum, clean.count >= minimum else { return nil }
        return String(clean.prefix(maximum))
    }
}

/// A stable observation is published once; repeated polling does not extend its deadline.
struct SelectionDebouncer {
    struct Change: Equatable { let snapshot: SelectionSnapshot? }
    let interval: TimeInterval
    private(set) var published: SelectionSnapshot?
    private var pending: SelectionSnapshot?
    private var changedAt: TimeInterval = 0

    init(interval: TimeInterval = 0.3) { self.interval = interval }

    mutating func observe(_ snapshot: SelectionSnapshot?, at now: TimeInterval) -> Change? {
        guard let snapshot else {
            pending = nil
            guard published != nil else { return nil }
            published = nil
            return Change(snapshot: nil)
        }
        if published?.sourcePID != nil, published?.sourcePID != snapshot.sourcePID {
            published = nil
            pending = snapshot
            changedAt = now
            return Change(snapshot: nil)
        }
        if snapshot != pending {
            pending = snapshot
            changedAt = now
        }
        guard snapshot != published, now - changedAt >= interval else { return nil }
        published = snapshot
        return Change(snapshot: snapshot)
    }

    mutating func reset() { pending = nil; published = nil; changedAt = 0 }
}
