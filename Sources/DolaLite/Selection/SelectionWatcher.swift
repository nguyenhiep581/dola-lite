import AppKit
import ApplicationServices

enum SelectionBoundsSanitizer {
    static func sanitize(axRect: CGRect, primaryTop: CGFloat) -> NSRect? {
        guard primaryTop.isFinite,
              !axRect.isNull, !axRect.isInfinite, !axRect.isEmpty,
              axRect.minX.isFinite, axRect.minY.isFinite,
              axRect.width.isFinite, axRect.height.isFinite,
              axRect.width > 0, axRect.height > 0,
              axRect.minX >= -8_000, axRect.minY >= -8_000,
              axRect.minX <= 32_000, axRect.minY <= 32_000 else {
            return nil
        }
        // Reject Chromium's degenerate (0, 0) placeholder origin rect.
        if abs(axRect.minX) <= 1, abs(axRect.minY) <= 1 {
            return nil
        }
        // AX uses the primary display's top-left origin for the entire virtual desktop.
        return NSRect(x: axRect.minX, y: primaryTop - axRect.maxY, width: axRect.width, height: axRect.height)
    }
}

enum ChromiumAccessibilityDetector {
    private static let exactBundlePrefixes = [
        "com.google.chrome", "org.chromium.chromium", "com.microsoft.edgemac",
        "com.brave.browser", "company.thebrowser.", "com.vivaldi.",
        "com.operasoftware.", "com.microsoft.vscode", "com.todesktop.",
        "com.tinyspeck.slackmacgap", "notion.id", "com.linear",
        "com.hnc.discord", "md.obsidian", "com.figma.desktop",
        "ai.perplexity.comet", "net.imput.helium", "com.electron.",
        "com.anysphere.cursor"
    ]
    private static let componentTokens: Set<String> = [
        "chrome", "chromium", "edgemac", "vscode", "electron"
    ]

    static func shouldEnableEnhancedAX(bundleIdentifier: String?, bundleURL: URL?) -> Bool {
        if let bundleID = bundleIdentifier?.lowercased() {
            if exactBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) {
                return true
            }
            let components = bundleID.split(separator: ".").map(String.init)
            if components.contains(where: { componentTokens.contains($0) }) {
                return true
            }
        }
        guard let bundleURL else { return false }
        let frameworksURL = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        if FileManager.default.fileExists(atPath: frameworksURL.appendingPathComponent("Electron Framework.framework").path) {
            return true
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: frameworksURL.path) else {
            return false
        }
        return entries.contains { name in
            guard name.hasSuffix(".framework") else { return false }
            return name.localizedCaseInsensitiveContains("Chromium")
                || name.localizedCaseInsensitiveContains("Chrome")
                || name.localizedCaseInsensitiveContains("Microsoft Edge")
        }
    }
}

private final class WatcherLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var pollTask: Task<Void, Never>?
    private var appObserver: NSObjectProtocol?

    var isPolling: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pollTask != nil
    }

    func set(pollTask: Task<Void, Never>, appObserver: NSObjectProtocol) {
        lock.lock()
        self.pollTask = pollTask
        self.appObserver = appObserver
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let task = pollTask
        let observer = appObserver
        pollTask = nil
        appObserver = nil
        lock.unlock()
        task?.cancel()
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}

@MainActor
final class SelectionWatcher {
    var onSelection: ((SelectionSnapshot?) -> Void)?
    private let lifecycle = WatcherLifecycle()
    private var debouncer: SelectionDebouncer
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init(debounceInterval: TimeInterval = 0.3) {
        debouncer = SelectionDebouncer(interval: debounceInterval, clearInterval: 0.25)
    }

    deinit {
        lifecycle.cancelAll()
    }

    func start() {
        guard !lifecycle.isPolling else { return }
        let ownPID = self.ownPID
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = application.processIdentifier
            Task { @MainActor [weak self] in
                guard let self, pid != self.ownPID else { return }
                self.clear()
            }
        }
        let task = Task.detached(priority: .utility) { [weak self] in
            enum FrontmostState {
                case external(pid: pid_t, bundleID: String?, bundleURL: URL?, primaryTop: CGFloat, mouseLocation: NSPoint, mouseOverOwnWindow: Bool)
                case ownApp
                case none
                case untrusted
            }
            var context = AXPollContext()
            while !Task.isCancelled {
                // Chromium-family apps (Chrome, Edge, VS Code, Cursor) answer AX
                // queries over IPC and can need more than one runloop tick,
                // so polling must run off the main thread with bounded timeouts.
                let front: FrontmostState = await MainActor.run {
                    guard AXIsProcessTrusted() else { return .untrusted }
                    guard let app = NSWorkspace.shared.frontmostApplication else { return .none }
                    if app.processIdentifier == ownPID { return .ownApp }
                    let mouseLocation = NSEvent.mouseLocation
                    let mouseOverOwnWindow = NSApp?.windows.contains { $0.isVisible && $0.frame.contains(mouseLocation) } ?? false
                    let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
                    return .external(
                        pid: app.processIdentifier,
                        bundleID: app.bundleIdentifier,
                        bundleURL: app.bundleURL,
                        primaryTop: primaryTop,
                        mouseLocation: mouseLocation,
                        mouseOverOwnWindow: mouseOverOwnWindow
                    )
                }
                let read: SelectionRead
                if case let .external(pid, bundleID, bundleURL, primaryTop, mouseLocation, mouseOverOwnWindow) = front {
                    read = Self.readSelection(
                        pid: pid,
                        bundleID: bundleID,
                        bundleURL: bundleURL,
                        primaryTop: primaryTop,
                        mouseLocation: mouseLocation,
                        mouseOverOwnWindow: mouseOverOwnWindow,
                        ownPID: ownPID,
                        context: &context
                    )
                } else {
                    read = .noSelection
                }
                let uptime = ProcessInfo.processInfo.systemUptime
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard AXIsProcessTrusted() else { self.clear(); return }
                    switch front {
                    case .ownApp:
                        // Activating Dola Lite (e.g. History or Settings) must not
                        // emit a synthetic selection clear that kills active results.
                        return
                    case .none, .untrusted:
                        self.clear()
                        return
                    case let .external(pid, _, _, _, _, _):
                        // Re-verify frontmost PID so slow AX IPC never publishes a stale selection
                        // after the user switched into Dola Lite or another app.
                        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                        if let change = self.debouncer.observe(read, at: uptime) {
                            self.onSelection?(change.snapshot)
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        lifecycle.set(pollTask: task, appObserver: observer)
    }

    func stop() {
        lifecycle.cancelAll()
        clear()
    }

    private func clear() {
        let hadSelection = debouncer.published != nil
        debouncer.reset()
        if hadSelection { onSelection?(nil) }
    }

    private struct AXPollContext {
        var evaluatedPIDs: Set<pid_t> = []
        var cachedWebArea: (pid: pid_t, window: AXUIElement, webArea: AXUIElement)?

        mutating func ensureChromiumAXIfNeeded(pid: pid_t, bundleID: String?, bundleURL: URL?, application: AXUIElement) {
            guard !evaluatedPIDs.contains(pid) else { return }
            if evaluatedPIDs.count > 64 {
                evaluatedPIDs.removeAll(keepingCapacity: true)
            }
            guard ChromiumAccessibilityDetector.shouldEnableEnhancedAX(bundleIdentifier: bundleID, bundleURL: bundleURL) else {
                evaluatedPIDs.insert(pid)
                return
            }
            let manualReady = enableBoolAttribute("AXManualAccessibility", on: application)
            let enhancedReady = enableBoolAttribute("AXEnhancedUserInterface", on: application)
            // Keep retrying while Chromium is starting up or AX permission is disabled.
            if manualReady && enhancedReady {
                evaluatedPIDs.insert(pid)
            }
        }

        mutating func cacheWebArea(pid: pid_t, window: AXUIElement?, webArea: AXUIElement) {
            guard let window else { return }
            cachedWebArea = (pid: pid, window: window, webArea: webArea)
        }

        private func enableBoolAttribute(_ name: String, on element: AXUIElement) -> Bool {
            var current: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(element, name as CFString, &current)
            if err == .success, (current as? Bool) == true {
                return true
            }
            if err == .cannotComplete || err == .apiDisabled {
                return false
            }
            let setErr = AXUIElementSetAttributeValue(element, name as CFString, kCFBooleanTrue)
            return setErr != .cannotComplete && setErr != .apiDisabled
        }
    }

    private enum SecureCheck {
        case secure
        case notSecure
        case invalidElement
        case transientError
    }

    private enum PrefixSecurityResult {
        case ok(prefix: [(element: AXUIElement, role: String?)], nextParent: AXUIElement?)
        case secure
        case transientError
    }

    private enum ElementExtraction {
        case found(SelectionSnapshot)
        case none(sawTransient: Bool)
        case secure
        case invalidElement
        case transientError
    }

    private enum ChainProbeResult {
        case found(SelectionSnapshot)
        case secure
        case securityTransient
        case none(sawTransient: Bool)
    }

    private enum BFSSearchResult {
        case found(SelectionSnapshot)
        case none(sawTransient: Bool, confirmedEmpty: Bool)
    }

    nonisolated private static let pollDeadlineSeconds: TimeInterval = 0.35
    nonisolated private static let maxAncestorHops = 24
    nonisolated private static let securityCheckHops = 4
    nonisolated private static let maxBFSVISited = 48
    nonisolated private static let maxBFSDepth = 8
    nonisolated private static let recentInputWindowSeconds: CFTimeInterval = 1.5
    nonisolated private static let skippedBFSRoles: Set<String> = [
        "AXStaticText", "AXButton", "AXImage", "AXMenuItem", "AXCheckBox",
        "AXRadioButton", "AXLink", "AXToolbar", "AXMenuBar",
        kAXTextFieldRole, "AXSecureTextField"
    ]

    /// Synchronous AX reads are thread-safe; called from the background poll task.
    nonisolated private static func readSelection(
        pid: pid_t,
        bundleID: String?,
        bundleURL: URL?,
        primaryTop: CGFloat,
        mouseLocation: NSPoint,
        mouseOverOwnWindow: Bool,
        ownPID: pid_t,
        context: inout AXPollContext
    ) -> SelectionRead {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        context.ensureChromiumAXIfNeeded(pid: pid, bundleID: bundleID, bundleURL: bundleURL, application: application)

        let deadline = ProcessInfo.processInfo.systemUptime + pollDeadlineSeconds
        var sawTransient = false
        var webAreaConfirmedEmpty = false

        var resolvedWindowCache: AXUIElement??
        func focusedWindow() -> AXUIElement? {
            if let cached = resolvedWindowCache { return cached }
            let (err, win) = elementAttribute(application, kAXFocusedWindowAttribute)
            if err == .cannotComplete { sawTransient = true }
            resolvedWindowCache = .some(win)
            return win
        }

        // Probe 1: Focused UI element + ancestor chain up to enclosing AXWebArea.
        let (focusedErr, focused) = elementAttribute(application, kAXFocusedUIElementAttribute)
        if focusedErr == .cannotComplete { sawTransient = true }
        if let focused {
            switch probeChain(from: focused, pid: pid, windowProvider: focusedWindow, primaryTop: primaryTop, deadline: deadline, context: &context) {
            case let .found(snapshot):
                return .selection(snapshot)
            case .secure:
                return .noSelection
            case .securityTransient:
                return .transientError(sourcePID: pid)
            case let .none(chainTransient):
                if chainTransient { sawTransient = true }
            }
        }

        let anyInputEvent = CGEventType(rawValue: UInt32.max) ?? .null
        let hasRecentInput = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEvent) <= recentInputWindowSeconds

        // Probe 2: Element under cursor + ancestor chain (gated on recent input to avoid idle IPC).
        if !mouseOverOwnWindow, hasRecentInput, ProcessInfo.processInfo.systemUptime < deadline {
            let axX = Float(mouseLocation.x)
            let axY = Float(primaryTop - mouseLocation.y)
            var hitElement: AXUIElement?
            let hitErr = AXUIElementCopyElementAtPosition(application, axX, axY, &hitElement)
            if hitErr == .cannotComplete { sawTransient = true }
            if hitErr == .success, let hitElement {
                var hitPID: pid_t = 0
                if AXUIElementGetPid(hitElement, &hitPID) == .success, hitPID != ownPID {
                    switch probeChain(from: hitElement, pid: pid, windowProvider: focusedWindow, primaryTop: primaryTop, deadline: deadline, context: &context) {
                    case let .found(snapshot):
                        return .selection(snapshot)
                    case .secure:
                        return .noSelection
                    case .securityTransient:
                        return .transientError(sourcePID: pid)
                    case let .none(chainTransient):
                        if chainTransient { sawTransient = true }
                    }
                }
            }
        }

        // Probe 3: Cached AXWebArea (idle) and bounded BFS on focused window (active input or cache miss).
        if ProcessInfo.processInfo.systemUptime < deadline, let window = focusedWindow() {
            if let cached = context.cachedWebArea,
               cached.pid != pid || !CFEqual(cached.window, window) {
                context.cachedWebArea = nil
            }

            if !hasRecentInput, let cached = context.cachedWebArea {
                AXUIElementSetMessagingTimeout(cached.webArea, 0.25)
                switch extractSelection(from: cached.webArea, pid: pid, primaryTop: primaryTop, fallbackBoundsElement: nil) {
                case let .found(snapshot):
                    return .selection(snapshot)
                case .secure:
                    return .noSelection
                case .invalidElement:
                    context.cachedWebArea = nil
                case .transientError:
                    sawTransient = true
                case let .none(extractTransient):
                    if extractTransient {
                        sawTransient = true
                    } else {
                        webAreaConfirmedEmpty = true
                    }
                }
            }

            if context.cachedWebArea == nil || hasRecentInput {
                if hasRecentInput {
                    context.cachedWebArea = nil
                }
                switch searchWindowWebAreas(rootWindow: window, pid: pid, primaryTop: primaryTop, deadline: deadline, context: &context) {
                case let .found(snapshot):
                    return .selection(snapshot)
                case let .none(bfsTransient, confirmedEmpty):
                    if confirmedEmpty { webAreaConfirmedEmpty = true }
                    if bfsTransient { sawTransient = true }
                }
            }
        }

        return (sawTransient && !webAreaConfirmedEmpty) ? .transientError(sourcePID: pid) : .noSelection
    }

    nonisolated private static func probeChain(
        from start: AXUIElement,
        pid: pid_t,
        windowProvider: () -> AXUIElement?,
        primaryTop: CGFloat,
        deadline: TimeInterval,
        context: inout AXPollContext
    ) -> ChainProbeResult {
        let verifiedPrefix: [(element: AXUIElement, role: String?)]
        var current: AXUIElement?
        switch fetchCheckedPrefix(from: start, maxHops: securityCheckHops, deadline: deadline) {
        case .secure:
            return .secure
        case .transientError:
            return .securityTransient
        case let .ok(prefix, nextParent):
            verifiedPrefix = prefix
            current = nextParent
        }

        var foundSnapshot: SelectionSnapshot?
        var sawTransient = false
        var hop = 0

        func evaluateNode(_ node: AXUIElement, knownRole: String?) -> ChainProbeResult? {
            if knownRole == kAXWindowRole || knownRole == kAXApplicationRole {
                return foundSnapshot.map(ChainProbeResult.found) ?? .none(sawTransient: sawTransient)
            }
            if knownRole == "AXWebArea" {
                context.cacheWebArea(pid: pid, window: windowProvider(), webArea: node)
            }
            if let pending = foundSnapshot {
                if knownRole == "AXWebArea" {
                    if let webBounds = boundsForTextMarkerRange(on: node, primaryTop: primaryTop) {
                        foundSnapshot = SelectionSnapshot(text: pending.text, bounds: webBounds, sourcePID: pending.sourcePID, range: pending.range)
                    }
                    return .found(foundSnapshot!)
                }
                return nil
            }
            switch extractSelection(from: node, pid: pid, primaryTop: primaryTop, fallbackBoundsElement: nil, alreadyVerifiedSafe: true) {
            case let .found(snapshot):
                if snapshot.bounds != nil || knownRole == "AXWebArea" {
                    return .found(snapshot)
                }
                foundSnapshot = snapshot
            case .secure:
                return .secure
            case .invalidElement, .transientError:
                sawTransient = true
            case let .none(extractTransient):
                if extractTransient { sawTransient = true }
            }
            return nil
        }

        for entry in verifiedPrefix {
            hop += 1
            if let result = evaluateNode(entry.element, knownRole: entry.role) {
                return result
            }
        }

        while hop < maxAncestorHops, let node = current, ProcessInfo.processInfo.systemUptime < deadline {
            hop += 1
            AXUIElementSetMessagingTimeout(node, 0.25)
            let (secCheck, role) = isSecureElement(node)
            switch secCheck {
            case .secure:
                return .secure
            case .invalidElement, .transientError:
                return .securityTransient
            case .notSecure:
                break
            }
            if let result = evaluateNode(node, knownRole: role) {
                return result
            }
            let (parentErr, nextParent) = elementAttribute(node, kAXParentAttribute)
            if parentErr == .cannotComplete { sawTransient = true }
            current = nextParent
        }

        if let foundSnapshot {
            return .found(foundSnapshot)
        }
        return .none(sawTransient: sawTransient)
    }

    nonisolated private static func searchWindowWebAreas(
        rootWindow: AXUIElement,
        pid: pid_t,
        primaryTop: CGFloat,
        deadline: TimeInterval,
        context: inout AXPollContext
    ) -> BFSSearchResult {
        var queue: [(element: AXUIElement, depth: Int)] = [(rootWindow, 0)]
        var head = 0
        var visited = 0
        var firstSeenWebArea: AXUIElement?
        var sawTransient = false
        var confirmedEmpty = false

        while head < queue.count, visited < maxBFSVISited, ProcessInfo.processInfo.systemUptime < deadline {
            let (node, depth) = queue[head]
            head += 1
            visited += 1
            AXUIElementSetMessagingTimeout(node, 0.25)

            let (secCheck, role) = isSecureElement(node)
            switch secCheck {
            case .secure, .invalidElement:
                continue
            case .transientError:
                sawTransient = true
                continue
            case .notSecure:
                break
            }

            if role == "AXWebArea" {
                if firstSeenWebArea == nil { firstSeenWebArea = node }
                switch extractSelection(from: node, pid: pid, primaryTop: primaryTop, fallbackBoundsElement: nil, alreadyVerifiedSafe: true) {
                case let .found(snapshot):
                    context.cacheWebArea(pid: pid, window: rootWindow, webArea: node)
                    return .found(snapshot)
                case .secure, .invalidElement:
                    break
                case .transientError:
                    sawTransient = true
                case let .none(extractTransient):
                    if extractTransient {
                        sawTransient = true
                    } else {
                        confirmedEmpty = true
                    }
                }
                // Do not descend into DOM children inside AXWebArea.
                continue
            }

            if let role, skippedBFSRoles.contains(role) {
                continue
            }
            guard depth < maxBFSDepth else { continue }

            let (childErr, childrenVal) = attributeWithError(node, kAXChildrenAttribute)
            if childErr == .cannotComplete { sawTransient = true }
            guard let children = childrenVal as? [AnyObject] else { continue }
            for item in children {
                let cfItem = item as CFTypeRef
                guard CFGetTypeID(cfItem) == AXUIElementGetTypeID() else { continue }
                let child = unsafeBitCast(cfItem, to: AXUIElement.self)
                queue.append((child, depth + 1))
            }
        }

        if let firstSeenWebArea {
            context.cacheWebArea(pid: pid, window: rootWindow, webArea: firstSeenWebArea)
        }
        return .none(sawTransient: sawTransient, confirmedEmpty: confirmedEmpty)
    }

    nonisolated private static func fetchCheckedPrefix(
        from element: AXUIElement,
        maxHops: Int,
        deadline: TimeInterval
    ) -> PrefixSecurityResult {
        var collected: [(element: AXUIElement, role: String?)] = []
        var current: AXUIElement? = element
        for _ in 0..<maxHops {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return .transientError }
            guard let node = current else { return .ok(prefix: collected, nextParent: nil) }
            AXUIElementSetMessagingTimeout(node, 0.25)
            let (secCheck, role) = isSecureElement(node)
            switch secCheck {
            case .secure:
                return .secure
            case .invalidElement, .transientError:
                return .transientError
            case .notSecure:
                break
            }
            if role == kAXWindowRole || role == kAXApplicationRole {
                return .ok(prefix: collected, nextParent: nil)
            }
            collected.append((node, role))
            let (parentErr, parent) = elementAttribute(node, kAXParentAttribute)
            if parentErr != .success && parentErr != .noValue && parentErr != .attributeUnsupported {
                return .transientError
            }
            current = parent
        }
        return .ok(prefix: collected, nextParent: current)
    }

    nonisolated private static func isSecureElement(_ element: AXUIElement) -> (SecureCheck, String?) {
        let (roleErr, roleValue) = attributeWithError(element, kAXRoleAttribute)
        let role = roleValue as? String
        if roleErr == .invalidUIElement {
            return (.invalidElement, role)
        }
        if roleErr != .success && roleErr != .noValue && roleErr != .attributeUnsupported {
            return (.transientError, role)
        }
        if role == "AXSecureTextField" {
            return (.secure, role)
        }
        let (subroleErr, subroleValue) = attributeWithError(element, kAXSubroleAttribute)
        if let subrole = subroleValue as? String, subrole == kAXSecureTextFieldSubrole {
            return (.secure, role)
        }
        if subroleErr == .invalidUIElement {
            return (.invalidElement, role)
        }
        if subroleErr != .success && subroleErr != .noValue && subroleErr != .attributeUnsupported {
            return (.transientError, role)
        }
        return (.notSecure, role)
    }

    nonisolated private static func extractSelection(
        from element: AXUIElement,
        pid: pid_t,
        primaryTop: CGFloat,
        fallbackBoundsElement: AXUIElement?,
        alreadyVerifiedSafe: Bool = false
    ) -> ElementExtraction {
        if !alreadyVerifiedSafe {
            switch isSecureElement(element).0 {
            case .secure:
                return .secure
            case .invalidElement:
                return .invalidElement
            case .transientError:
                return .transientError
            case .notSecure:
                break
            }
        }

        var sawTransient = false

        // Method A: Standard AXSelectedText + AXBoundsForRange (with AXBoundsForTextMarkerRange fallback).
        let (selectedErr, selectedVal) = attributeWithError(element, kAXSelectedTextAttribute)
        if selectedErr == .cannotComplete { sawTransient = true }
        if let raw = selectedVal as? String, let text = SelectionFilter.sanitize(raw) {
            var selectedRange: NSRange?
            var bounds: NSRect?
            if let rangeObject = attributeWithError(element, kAXSelectedTextRangeAttribute).1,
               CFGetTypeID(rangeObject) == AXValueGetTypeID() {
                let rangeValue = unsafeBitCast(rangeObject, to: AXValue.self)
                var range = CFRange()
                if AXValueGetType(rangeValue) == .cfRange,
                   AXValueGetValue(rangeValue, .cfRange, &range),
                   range.location >= 0, range.length >= 0 {
                    selectedRange = NSRange(location: range.location, length: range.length)
                    var result: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &result) == .success,
                       let result, CFGetTypeID(result) == AXValueGetTypeID() {
                        let rectValue = unsafeBitCast(result, to: AXValue.self)
                        var rect = CGRect.zero
                        if AXValueGetType(rectValue) == .cgRect, AXValueGetValue(rectValue, .cgRect, &rect) {
                            bounds = SelectionBoundsSanitizer.sanitize(axRect: rect, primaryTop: primaryTop)
                        }
                    }
                }
            }
            if bounds == nil {
                bounds = boundsForTextMarkerRange(on: element, primaryTop: primaryTop)
                    ?? fallbackBoundsElement.flatMap { fallback in
                        CFEqual(fallback, element) ? nil : boundsForTextMarkerRange(on: fallback, primaryTop: primaryTop)
                    }
            }
            return .found(SelectionSnapshot(text: text, bounds: bounds, sourcePID: pid, range: selectedRange))
        }

        // Method B: WebKit / Chromium AXSelectedTextMarkerRange.
        let (markerErr, markerVal) = attributeWithError(element, "AXSelectedTextMarkerRange")
        if markerErr == .cannotComplete { sawTransient = true }
        if selectedErr == .invalidUIElement && markerErr == .invalidUIElement {
            return .invalidElement
        }
        if let markerRange = markerVal, CFGetTypeID(markerRange) == AXTextMarkerRangeGetTypeID() {
            var strVal: CFTypeRef?
            let strErr = AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString, markerRange, &strVal)
            if strErr == .cannotComplete { sawTransient = true }
            var extracted = strErr == .success
                ? (strVal as? String).flatMap { SelectionFilter.sanitize($0) }
                : nil
            if extracted == nil {
                var attrVal: CFTypeRef?
                let attrErr = AXUIElementCopyParameterizedAttributeValue(element, "AXAttributedStringForTextMarkerRange" as CFString, markerRange, &attrVal)
                if attrErr == .cannotComplete { sawTransient = true }
                if attrErr == .success {
                    let rawAttr = (attrVal as? NSAttributedString)?.string ?? (attrVal as? String)
                    extracted = rawAttr.flatMap { SelectionFilter.sanitize($0) }
                }
            }
            if let text = extracted {
                let bounds = boundsForMarkerRange(markerRange, on: element, primaryTop: primaryTop)
                    ?? fallbackBoundsElement.flatMap { fallback in
                        CFEqual(fallback, element) ? nil : boundsForMarkerRange(markerRange, on: fallback, primaryTop: primaryTop)
                    }
                return .found(SelectionSnapshot(text: text, bounds: bounds, sourcePID: pid, range: nil))
            }
        }

        return .none(sawTransient: sawTransient)
    }

    nonisolated private static func boundsForTextMarkerRange(on element: AXUIElement, primaryTop: CGFloat) -> NSRect? {
        guard let markerRange = attributeWithError(element, "AXSelectedTextMarkerRange").1,
              CFGetTypeID(markerRange) == AXTextMarkerRangeGetTypeID() else {
            return nil
        }
        return boundsForMarkerRange(markerRange, on: element, primaryTop: primaryTop)
    }

    nonisolated private static func boundsForMarkerRange(_ markerRange: CFTypeRef, on element: AXUIElement, primaryTop: CGFloat) -> NSRect? {
        var boundsVal: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForTextMarkerRange" as CFString, markerRange, &boundsVal) == .success,
              let boundsVal, CFGetTypeID(boundsVal) == AXValueGetTypeID() else {
            return nil
        }
        let rectValue = unsafeBitCast(boundsVal, to: AXValue.self)
        var rect = CGRect.zero
        guard AXValueGetType(rectValue) == .cgRect, AXValueGetValue(rectValue, .cgRect, &rect) else {
            return nil
        }
        return SelectionBoundsSanitizer.sanitize(axRect: rect, primaryTop: primaryTop)
    }

    nonisolated private static func elementAttribute(_ element: AXUIElement, _ name: String) -> (AXError, AXUIElement?) {
        let (err, value) = attributeWithError(element, name)
        guard err == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (err, nil)
        }
        return (err, unsafeBitCast(value, to: AXUIElement.self))
    }

    nonisolated private static func attributeWithError(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        var result: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, name as CFString, &result)
        return (err, err == .success ? result : nil)
    }
}
