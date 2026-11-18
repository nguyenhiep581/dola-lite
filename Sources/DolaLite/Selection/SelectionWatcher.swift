import AppKit
import ApplicationServices

@MainActor
final class SelectionWatcher {
    var onSelection: ((SelectionSnapshot?) -> Void)?
    private var timer: Timer?
    private var appObserver: NSObjectProtocol?
    private var debouncer: SelectionDebouncer
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init(debounceInterval: TimeInterval = 0.3) {
        debouncer = SelectionDebouncer(interval: debounceInterval)
    }

    func start() {
        guard timer == nil else { return }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = application.processIdentifier
            Task { @MainActor [weak self] in
                guard let self, pid != self.ownPID else { return }
                self.clear()
                self.poll()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        clear()
    }

    private func clear() {
        let hadSelection = debouncer.published != nil
        debouncer.reset()
        if hadSelection { onSelection?(nil) }
    }

    private func poll() {
        guard AXIsProcessTrusted() else { clear(); return }
        guard let front = NSWorkspace.shared.frontmostApplication else { clear(); return }
        // A result text view may become key for selection/copy without replacing the source selection.
        guard front.processIdentifier != ownPID else { return }
        let snapshot = readSelection(pid: front.processIdentifier)
        if let change = debouncer.observe(snapshot, at: ProcessInfo.processInfo.systemUptime) {
            onSelection?(change.snapshot)
        }
    }

    private func readSelection(pid: pid_t) -> SelectionSnapshot? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        guard let focusedValue = attribute(application, kAXFocusedUIElementAttribute),
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
                        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
                        bounds = NSRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
                    }
                }
            }
        }
        return SelectionSnapshot(text: text, bounds: bounds, sourcePID: pid, range: selectedRange)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
}
