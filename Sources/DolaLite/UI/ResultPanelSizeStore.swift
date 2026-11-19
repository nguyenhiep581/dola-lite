import AppKit

@MainActor
final class ResultPanelSizeStore {
    private static let widthKey = "result.panel.width.v1"
    private static let heightKey = "result.panel.height.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(default fallback: NSSize) -> NSSize {
        let width = defaults.double(forKey: Self.widthKey)
        let height = defaults.double(forKey: Self.heightKey)
        guard defaults.object(forKey: Self.widthKey) != nil,
              defaults.object(forKey: Self.heightKey) != nil,
              width.isFinite, height.isFinite, width > 0, height > 0 else {
            return fallback
        }
        return NSSize(width: width, height: height)
    }

    func save(_ size: NSSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        defaults.set(Double(size.width), forKey: Self.widthKey)
        defaults.set(Double(size.height), forKey: Self.heightKey)
    }
}
