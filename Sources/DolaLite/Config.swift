import Foundation

enum Config {
    static let targetLanguage = "vi"
    static let chatURL = URL(string: "https://www.dola.com/chat/")!
    static let selectionDebounceMs: Int = 300
    static let minSelectionLength = 2
    static let maxSelectionLength = 10_000
    static let streamTimeoutSec: TimeInterval = 60
    static let pollIntervalMs: Double = 0.3
}
