import AppKit
import ApplicationServices

@MainActor
final class SelectionWatcher {
    var onSelection: ((SelectionSnapshot?) -> Void)?
    private var pollTask: Task<Void, Never>?
    private var appObserver: NSObjectProtocol?
    private var debouncer: SelectionDebouncer
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init(debounceInterval: TimeInterval = 0.3) {
        debouncer = SelectionDebouncer(interval: debounceInterval)
    }

    func start() {
        guard pollTask == nil else { return }
        let ownPID = self.ownPID
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = application.processIdentifier
            Task { @MainActor [weak self] in
                guard let self, pid != self.ownPID else { return }
                self.clear()
            }
        }
        pollTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                // Chromium-family apps (Chrome, VS Code, Cursor, Kiro) answer AX
                // queries over IPC and can need far more than one runloop tick,
                // so polling must run off the main thread with a patient timeout.
                let front: (pid: pid_t, primaryTop: CGFloat)? = await MainActor.run {
                    guard let front = NSWorkspace.shared.frontmostApplication,
                          front.processIdentifier != ownPID else { return nil }
                    return (front.processIdentifier, NSScreen.screens.first?.frame.maxY ?? 0)
                }
                let snapshot = front.flatMap { Self.readSelection(pid: $0.pid, primaryTop: $0.primaryTop) }
                let uptime = ProcessInfo.processInfo.systemUptime
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard AXIsProcessTrusted() else { self.clear(); return }
                    guard front != nil else { self.clear(); return }
                    if let change = self.debouncer.observe(snapshot, at: uptime) {
                        self.onSelection?(change.snapshot)
                    }
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        clear()
    }

    private func clear() {
        let hadSelection = debouncer.published != nil
        debouncer.reset()
        if hadSelection { onSelection?(nil) }
    }

    /// Synchronous AX reads are thread-safe; called from the background poll task.
    nonisolated private static func readSelection(pid: pid_t, primaryTop: CGFloat) -> SelectionSnapshot? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1.2)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let focused = unsafeBitCast(focusedValue, to: AXUIElement.self)
        if attribute(focused, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return nil }
        guard let raw = attribute(focused, kAXSelectedTextAttribute) as? String,
              let text = SelectionFilter.sanitize(raw) else { return nil }

        var selectedRange: NSRange?
        var bounds: NSRect?
        if let rangeObject = attribute(focused, kAXSelectedTextRangeAttribute),
           CFGetTypeID(rangeObject) == AXValueGetTypeID() {
            let rangeValue = unsafeBitCast(rangeObject, to: AXValue.self)
            var range = CFRange()
            if AXValueGetType(rangeValue) == .cfRange, AXValueGetValue(rangeValue, .cfRange, &range), range.location >= 0, range.length >= 0 {
                selectedRange = NSRange(location: range.location, length: range.length)
                var result: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(focused, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &result) == .success,
                   let result, CFGetTypeID(result) == AXValueGetTypeID() {
                    let rectValue = unsafeBitCast(result, to: AXValue.self)
                    var rect = CGRect.zero
                    if AXValueGetType(rectValue) == .cgRect, AXValueGetValue(rectValue, .cgRect, &rect),
                       !rect.isEmpty, !rect.isInfinite, !rect.isNull {
                        // AX uses the main display's top-left origin for the entire virtual desktop.
                        bounds = NSRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
                    }
                }
            }
        }
        return SelectionSnapshot(text: text, bounds: bounds, sourcePID: pid, range: selectedRange)
    }

    nonisolated private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
}
