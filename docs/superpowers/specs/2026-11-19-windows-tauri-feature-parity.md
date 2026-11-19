# Dola Lite — Windows Feature Inventory & Parity Goal

- Date: 2026-11-19
- Status: Product inventory and target behavior; Windows implementation not started
- Proposed independent app root: `windows-tauri/`
- Stack: Rust + Tauri 2; TypeScript/HTML/CSS frontend; native Windows UI Automation integration

## Goal

Add a Windows desktop edition of Dola Lite without replacing or restructuring the existing Swift/AppKit macOS app. Preserve the useful selection-to-result workflow, API configuration, streaming, and local history while using Windows-native selection and secure-storage mechanisms.

The target is **functional parity where Windows APIs permit it**, not a claim that every Windows application exposes selected text to accessibility clients. The app must fail gracefully and document the verified support matrix.

## Current macOS feature inventory

### Selection and quick actions

- Watches the foreground application for selected text using macOS Accessibility APIs.
- Ignores Dola Lite itself and secure text fields; handles foreground-app changes and selection clearing.
- Sanitizes selection text and limits it to 10,000 characters/graphemes; debounces stable selection changes before showing UI.
- Uses selection text bounds when available and falls back to the pointer location when bounds are unavailable.
- Shows a compact, non-activating pill with three actions: **Dịch**, **Tóm tắt**, and **Giải thích**.
- Dismisses on outside click, Escape, clearing/changing selection, or explicit close, except that a pinned result survives outside clicks and selection changes.

### Result panel

- Shows the selected action's response as it streams, with a spinner and elapsed wait display.
- Renders basic Markdown (headings, lists, bold, inline code, and fenced code) and wraps long text with vertical scrolling.
- Provides Copy, Retry, Pin/Unpin, History, and Close controls.
- Can be moved and resized, remembers its size, clamps itself to the available display, and opens near the selection.
- Expands an inline history tray below the result; selecting a previous entry displays that response in the same panel.
- Escape and explicit Close still dismiss a pinned result. Starting another task replaces the current visible result safely.

### Translation, summary, and explanation requests

- Sends selected text to a configurable OpenAI-compatible endpoint.
- Supports both Chat Completions and Responses request/stream formats.
- Dịch targets Vietnamese and prioritizes low reasoning effort. Tóm tắt and Giải thích target Vietnamese and use the configured effort.
- Streams text incrementally, cancels obsolete requests, ignores non-user-facing reasoning events, and rejects malformed, incomplete, oversized, or failed streams.
- Maps common HTTP/network failures to safe user-facing messages; does not display arbitrary server bodies or credentials.

### API settings and models

- Configures Base URL, model, API key, wire/API format, and reasoning effort.
- Fetches model identifiers from the configured endpoint's `/models`; users can also enter a model manually.
- Tests the selected endpoint/model with a representative translation and reports total elapsed time.
- Keeps the existing key when saving endpoint/model changes with the key field blank.
- Opens settings on first run if no key is configured and exposes current API/model status in the app menu.

### History and privacy

- Saves successful completed translations, summaries, and explanations locally; partial, failed, and cancelled operations are not saved.
- An entry records skill, time, model, source text, and result text. The history is newest-first, bounded to 200 entries, and survives restart.
- Offers a full history browser from the app menu, plus per-item delete, clear-all confirmation, and copy.
- macOS stores the API key separately from history, with owner-only file/directory permissions. The current UI includes an accessibility onboarding prompt and a menu action to check permission.

### macOS-only implementation details (not Windows requirements)

- AppKit menu-bar/status item, `NSPanel`, Accessibility API, and `UserDefaults`/Application Support storage.
- macOS Accessibility permission and Chromium renderer-accessibility setup.
- These exact APIs, entitlements, and permission instructions must not be carried over to Windows.

## Windows edition parity goals

1. **Separate source tree:** Keep all Windows frontend/backend/build configuration under `windows-tauri/`; leave the root `Package.swift`, `Sources/DolaLite`, and macOS app workflow intact.
2. **Selection detection:** Use a Rust Windows UI Automation adapter to inspect the foreground focused element and its selected text/range bounds. Run blocking COM/UIA calls away from the UI thread, debounce selection, and ignore secure inputs and the app's own windows.
3. **Known limitations:** Verify UIA selection support with representative Win32, WinUI, browser, Office, and Electron applications. Show a clear, non-blocking explanation when the focused application does not expose a selection. Do not silently change the user's clipboard as a fallback in the initial release.
4. **Floating quick-action pill:** Show the same three actions near the selection without stealing focus from the source application; clamp to the correct monitor and account for display scaling/multiple monitors.
5. **Result experience:** Streaming result with Markdown, Copy, Retry, Pin, Close, wait timing, resize/move with remembered size, Escape/outside-click dismissal, and inline newest-first history tray.
6. **API parity:** OpenAI-compatible Chat Completions and Responses, `/models` discovery, manual model entry, timing test, configurable Base URL/key/model/effort, cancellation, sanitized errors, and bounded SSE parsing.
7. **Data parity:** Persist settings and up to 200 successful local history entries across restarts. Keep secrets out of frontend storage, logs, and history; use Windows Credential Manager/DPAPI-backed secret storage.
8. **Windows distribution:** Produce a repeatable Windows x64 release build and installer, document prerequisites and UI Automation limits, and leave macOS packaging unchanged.

## UI/UX craft baseline for the Windows Tauri frontend

To keep the Windows WebView2 UI feeling like a focused, native desktop utility rather than a generic web template, frontend work in `windows-tauri/src/` should follow these constraints (combining `taste-skill`'s utility profile and Hallmark's "The Floor"):

- **Calibrated utility dials:** `DESIGN_VARIANCE = 2` (clean, predictable desktop symmetry), `MOTION_INTENSITY = 2` (crisp hover/press/copy micro-feedback only; no gratuitous animations), `VISUAL_DENSITY = 7` (compact, text-first utility density).
- **Tokenized Light/Dark styling:** Declare all colors, surfaces, borders, radii, and font stacks as CSS custom properties at `:root` (with `prefers-color-scheme: dark` overrides); do not scatter literal colors or font families inside component rules.
- **Layout & motion restraint:** Never use `transition: all`; never animate `width`, `height`, `top`, or `left`; use `overflow-x: clip`; respect `prefers-reduced-motion: reduce`.
- **Clean hierarchy & accessibility:** Provide an immediate `:focus-visible` indicator on every interactive control; use sentence-case labels (no tracked capitals or decorative badges); structure history rows with a clear two-line hierarchy (source preview + separate left/right skill and timestamp) rather than middle-dot-joined meta strings (`·`).

## Non-goals for the first Windows release

- Replacing the macOS AppKit app or forcing a cross-platform rewrite of the existing project.
- Cloud-synced history, user accounts, telemetry, or uploading history anywhere.
- Clipboard-based selection capture without explicit product approval and a tested save/restore/privacy design.
- Guaranteeing UIA selection support for every third-party application.
- Reimplementing macOS Accessibility onboarding or browser-specific instructions.
