import AppKit

/// Owns one request at a time. Invalidating the generation before cancellation
/// prevents a late network event from changing a newer panel.
@MainActor
final class PanelCoordinator {
    private let pill: PillPanel
    private let result: ResultPanel
    private let provider: AIProvider
    private let settings: APISettingsStore
    private let historyStore: HistoryStore?
    private let openSettings: () -> Void
    private var selection: SelectionSnapshot?
    private var retryRequest: (Skill, String, NSRect?)?
    private var requestTask: Task<Void, Never>?
    private var generation = UUID()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var suspended = false
    private var isPinned = false

    init(pill: PillPanel, result: ResultPanel, provider: AIProvider,
         settings: APISettingsStore, historyStore: HistoryStore? = nil,
         openSettings: @escaping () -> Void) {
        self.pill = pill
        self.result = result
        self.provider = provider
        self.settings = settings
        self.historyStore = historyStore
        self.openSettings = openSettings
        pill.onSkillTap = { [weak self] skill, text in
            guard let self else { return }
            self.run(skill: skill, text: text, anchor: self.pill.frame)
        }
        result.onClose = { [weak self] in self?.dismissAll() }
        result.onPinChange = { [weak self] pinned in self?.isPinned = pinned }
        result.onSelectHistory = { [weak self] in self?.stopCurrentRequestForHistory() }
        result.onRetry = { [weak self] in
            guard let self, let request = self.retryRequest else { return }
            self.run(skill: request.0, text: request.1, anchor: request.2)
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, local: false) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown, event.keyCode == 53,
                   self.pill.isVisible || self.result.isVisible {
                    self.dismissAll()
                    return true
                }
                self.handle(event, local: true)
                return false
            }
            return consumed ? nil : event
        }
    }

    func handleSelection(_ snapshot: SelectionSnapshot?) {
        guard snapshot != selection else { return }
        selection = snapshot
        if isPinned {
            if !suspended, let snapshot {
                pill.show(text: snapshot.text, near: snapshot.bounds)
            } else {
                pill.dismiss()
            }
            return
        }
        dismissAll()
        guard !suspended, let snapshot else { return }
        pill.show(text: snapshot.text, near: snapshot.bounds)
    }

    func suspend() {
        suspended = true
        dismissAll()
    }

    func resume() { suspended = false }

    func dismissAll() {
        generation = UUID()
        requestTask?.cancel()
        requestTask = nil
        retryRequest = nil
        isPinned = false
        pill.dismiss()
        result.dismiss()
    }

    func shutdown() {
        dismissAll()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent, local: Bool) {
        guard pill.isVisible || result.isVisible else { return }
        if event.type == .keyDown {
            if event.keyCode == 53 { dismissAll() }
            return
        }
        if local, event.window === pill || event.window === result { return }
        let point = NSEvent.mouseLocation
        if pill.isVisible && pill.frame.contains(point) { return }
        if result.isVisible && result.frame.contains(point) { return }
        if isPinned && result.isVisible {
            pill.dismiss()
            return
        }
        dismissAll()
    }

    private func run(skill: Skill, text: String, anchor: NSRect?) {
        guard settings.hasAPIKey else {
            dismissAll()
            openSettings()
            return
        }
        generation = UUID()
        let requestID = generation
        let requestModel = settings.configuration.model
        requestTask?.cancel()
        retryRequest = (skill, text, anchor)
        pill.dismiss()
        result.show(skill: skill, near: anchor)
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await provider.ensureReady()
                for try await chunk in provider.stream(skill: skill, text: text) {
                    try Task.checkCancellation()
                    guard generation == requestID else { return }
                    result.append(chunk)
                }
                guard generation == requestID, !Task.isCancelled else { return }
                result.finish()
                if let historyStore, !result.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try historyStore.add(HistoryEntry(skill: skill, model: requestModel,
                                                          sourceText: text, resultText: result.fullText))
                    } catch {
                        result.showHistorySaveWarning(error.localizedDescription)
                    }
                }
            } catch {
                guard generation == requestID, !Task.isCancelled else { return }
                result.fail(error.localizedDescription)
            }
            if generation == requestID { requestTask = nil }
        }
    }

    private func stopCurrentRequestForHistory() {
        generation = UUID()
        requestTask?.cancel()
        requestTask = nil
        retryRequest = nil
    }

}
