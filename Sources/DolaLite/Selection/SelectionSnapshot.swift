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

    func isEquivalent(to other: SelectionSnapshot, boundsTolerance: CGFloat = 2.0) -> Bool {
        guard sourcePID == other.sourcePID, text == other.text, range == other.range else {
            return false
        }
        switch (bounds, other.bounds) {
        case (.none, .none):
            return true
        case let (.some(lhs), .some(rhs)):
            return abs(lhs.minX - rhs.minX) <= boundsTolerance
                && abs(lhs.minY - rhs.minY) <= boundsTolerance
                && abs(lhs.width - rhs.width) <= boundsTolerance
                && abs(lhs.height - rhs.height) <= boundsTolerance
        default:
            return false
        }
    }
}

enum SelectionRead: Equatable {
    case selection(SelectionSnapshot)
    case noSelection
    case transientError(sourcePID: pid_t?)
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
    let clearInterval: TimeInterval
    let transientGraceInterval: TimeInterval
    private(set) var published: SelectionSnapshot?
    private var pending: SelectionSnapshot?
    private var changedAt: TimeInterval = 0
    private var missingSince: TimeInterval?

    init(interval: TimeInterval = 0.3, clearInterval: TimeInterval = 0, transientGraceInterval: TimeInterval = 1.2) {
        self.interval = interval
        self.clearInterval = clearInterval
        self.transientGraceInterval = transientGraceInterval
    }

    mutating func observe(_ snapshot: SelectionSnapshot?, at now: TimeInterval) -> Change? {
        observe(snapshot.map(SelectionRead.selection) ?? .noSelection, at: now)
    }

    mutating func observe(_ read: SelectionRead, at now: TimeInterval) -> Change? {
        switch read {
        case let .selection(snapshot):
            missingSince = nil
            if let publishedPID = published?.sourcePID, publishedPID != snapshot.sourcePID {
                published = nil
                pending = snapshot
                changedAt = now
                return Change(snapshot: nil)
            }
            if pending.map({ !$0.isEquivalent(to: snapshot) }) ?? true {
                pending = snapshot
                changedAt = now
            }
            if published.map({ $0.isEquivalent(to: snapshot) }) ?? false {
                return nil
            }
            guard now - changedAt >= interval else { return nil }
            published = snapshot
            return Change(snapshot: snapshot)

        case .noSelection:
            pending = nil
            guard published != nil else {
                missingSince = nil
                return nil
            }
            if clearInterval <= 0 {
                published = nil
                missingSince = nil
                return Change(snapshot: nil)
            }
            let since = missingSince ?? now
            missingSince = since
            guard now - since >= clearInterval else { return nil }
            published = nil
            missingSince = nil
            return Change(snapshot: nil)

        case let .transientError(pid):
            pending = nil
            guard let active = published else {
                missingSince = nil
                return nil
            }
            let grace: TimeInterval
            if let pid, pid != active.sourcePID {
                grace = max(clearInterval, interval)
            } else {
                // Bounded tolerance so brief Jira DOM hiccups survive without leaving ghost pills forever.
                grace = max(transientGraceInterval, max(clearInterval, interval))
            }
            let since = missingSince ?? now
            missingSince = since
            guard grace <= 0 || now - since >= grace else { return nil }
            published = nil
            missingSince = nil
            return Change(snapshot: nil)
        }
    }

    mutating func reset() {
        pending = nil
        published = nil
        changedAt = 0
        missingSince = nil
    }
}
