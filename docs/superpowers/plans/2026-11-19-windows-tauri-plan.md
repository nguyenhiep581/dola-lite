# Windows Edition — Rust + Tauri 2 Goals & Plan

- Date: 2026-11-19
- Status: Phase 0 diagnostic cross-compile-check passes; runtime/app-matrix validation remains blocked on a Windows machine; full Tauri implementation not started
- Feature inventory: `docs/superpowers/specs/2026-11-19-windows-tauri-feature-parity.md`
- Independent project directory: `windows-tauri/`

## Primary goal

Deliver a usable Windows edition that lets a user select text in a supported Windows application, invoke Dịch/Tóm tắt/Giải thích from a small floating pill, and see a streaming result without taking focus away from the source app.

Preserve the existing macOS app as-is. Share behavior and requirements, not platform-specific UI code: Rust/Tauri 2 for the Windows desktop shell and backend; TypeScript/HTML/CSS for the Windows UI; Windows UI Automation and Credential Manager/DPAPI for platform services.

## Project layout target

```text
windows-tauri/
├── package.json
├── tsconfig.json
├── vite.config.ts
├── index.html
├── src/                         # Tauri frontend: pill, result, settings, history
│   ├── app/
│   ├── components/
│   ├── styles/
│   └── types/
└── src-tauri/
    ├── Cargo.toml
    ├── tauri.conf.json
    ├── capabilities/
    ├── icons/
    └── src/
        ├── main.rs
        ├── commands/            # typed frontend/backend boundary
        ├── selection/           # Windows UIA, foreground app, selection bounds
        ├── provider/            # HTTP, models, SSE, errors, cancellation
        ├── settings/            # preferences and secret-store adapter
        ├── history/             # local bounded history
        └── tray/                # tray menu and app lifecycle
```

The Tauri project owns its own dependencies, build scripts, tests, and generated output. Do not add Windows modules to the Swift package target or make the root build depend on Node/Rust.

## Milestones and tasks

### Phase 0 — Verify Windows selection feasibility (highest risk)

1. Create a small Rust-only UI Automation spike before building the full frontend.
2. From a background worker, identify the foreground process and focused UIA element; attempt to read selection through the Windows UIA TextPattern/GetSelection API and retrieve bounding rectangles.
3. Validate COM initialization/apartment rules, UIA timeouts, foreground changes, selection-cleared events, and cancellation so a slow control cannot freeze the app.
4. Test a documented matrix of available applications: Notepad, a browser text/content selection, a Win32 edit control, and any installed Office/Electron apps available for manual validation.
5. Record where UIA does not expose selected text. Define a graceful unsupported-control state; leave clipboard injection out of scope unless the user approves a separate design.

**Exit criteria:** A repeatable demo detects text and bounds in the agreed baseline applications without stealing focus or hanging when a UIA provider is slow. Document unsupported apps and decide whether any capability change is needed before proceeding.

**Progress:** A standalone diagnostic scaffold is present at `windows-tauri/ui-automation-spike/`. It initializes Per-Monitor V2 DPI awareness, uses `CUIAutomation8` (`IUIAutomation2`) with bounded connection/transaction timeouts, handles `UIA_IsTextPatternAvailablePropertyId` and `S_OK`+`NULL` / `UIA_E_NOTSUPPORTED` results cleanly without false transient errors, skips password fields, suppresses text output by default, and debounces both selections (including slow-drift protection) and deselections. Core unit tests pass on macOS (`cargo test`) and the Windows target passes `cargo check --target x86_64-pc-windows-msvc --tests`; live Windows UI Automation execution and the application support matrix remain untested (note that Chromium/Electron apps build their UIA tree lazily on first query, so initial queries may time out at 500 ms before warming up).

### Phase 1 — Scaffold an isolated Tauri 2 Windows app

1. Add `windows-tauri/` with the Tauri 2 frontend/backend layout above, independent `package.json` and Cargo manifest.
2. Establish typed Tauri commands/events, error serialization, app logging that redacts prompt/key material, and a testable backend module structure.
3. Add the Windows tray icon/menu and app lifecycle: settings, history, current API/model status, and quit.
4. Configure a Windows development/build workflow and document prerequisites; keep icons/metadata separate from the macOS bundle.

**Exit criteria:** The app launches on Windows, shows a tray entry, invokes a typed command/event round trip, and builds without touching the macOS target.

### Phase 2 — Port settings and secure API credentials

1. Add settings UI for Base URL, model, key entry/update/delete, Chat Completions vs Responses, reasoning effort, and blank-key-preserves-existing behavior.
2. Store non-secret preferences in the Windows app config directory; store the API key using Windows Credential Manager or a reviewed DPAPI-backed Rust credential-store implementation.
3. Keep credentials backend-only: do not write them to WebView local storage, frontend state persistence, logs, crash output, or history.
4. Add authenticated `GET /models` model discovery with manual entry remaining available.
5. Add the deterministic sample translation connection test and display total elapsed time on both success and error where measurable.

**Exit criteria:** Settings survive restart; key CRUD is functional and private; fake-transport tests cover model parsing, invalid config/key, status mapping, and endpoint/model timing UI states.

### Phase 3 — Port AI request and streaming behavior

1. Implement validated OpenAI-compatible Chat Completions and Responses request builders, preserving the existing skill behavior and request options.
2. Use an asynchronous Rust HTTP client with bounded response handling, SSE decoding, task/request cancellation, and safe HTTP/network error mapping.
3. Ensure redirects cannot forward credentials to a different host; redact request headers/body from diagnostics.
4. Cover both Chat `choices[].delta.content` streams and Responses output-text/lifecycle/terminal/error events; never display reasoning events.
5. Add fixture-driven tests for UTF-8/chunk boundaries, malformed/incomplete streams, size caps, status codes, cancellation, and empty responses.

**Exit criteria:** All three skills stream from fixtures for both wire formats and cannot update a replaced/closed result window.

### Phase 4 — Implement Windows selection worker and quick-action pill

1. Port selection filtering, 300 ms debounce, maximum input limit, selection identity, and stale-result generation handling to Rust.
2. Run UIA polling/event handling on a dedicated worker; keep WebView/Tauri UI work on the main thread and send small, typed events.
3. Build a compact transparent/frameless pill with Dịch, Tóm tắt, and Giải thích.
4. Position it from UIA bounding rectangles, with pointer fallback only when bounds are unavailable; support multiple monitors, negative virtual-screen coordinates, and per-monitor DPI (convert UIA physical pixels carefully vs Tauri `PhysicalPosition`/`LogicalPosition`).
5. Keep the source app focused when the pill appears and when its buttons are clicked (Tauri `focus: false` alone is insufficient on Windows — wire Win32 `WS_EX_NOACTIVATE` + `WM_MOUSEACTIVATE` returning `MA_NOACTIVATE` on the pill HWND and verify WebView2 click/Escape handling); support outside click, Escape, app-focus changes, secure-field filtering, and shutdown cancellation.
6. Add a visible fallback/help state for controls/apps where UIA provides no selection. Do not simulate Ctrl+C or modify clipboard contents in this phase.

**Exit criteria:** Pill appears near a detected selection in the Phase 0 baseline apps, does not steal source focus, remains on-screen at common DPI settings, and reliably dismisses/replaces on selection changes.

### Phase 5 — Result panel, pin, resize/move, and history

1. Build the streaming result UI with Markdown, spinner/elapsed wait, Copy, Retry, Pin/Unpin, History, and Close.
2. Preserve outside-click/selection-dismiss behavior; a pinned result remains visible until explicit close/Escape or a user-started replacement.
3. Allow header dragging and corner resizing. Persist size (not stale screen coordinates), clamp the panel to the active monitor, and wrap/scroll long results.
4. Add the inline history tray below current result content and a complete history view reachable from the tray/app menu.
5. Persist only completed results locally, newest-first, at most 200. Provide entry preview, reopen/copy, per-entry delete, clear-all confirmation, and an empty state.
6. Isolate history failures from translation. Make storage atomic and private to the current Windows user.

**Exit criteria:** Pin/dismiss/resize/history tests pass; completed entries survive restart; cancelled, failed, and partial requests do not appear as successful history.

### Phase 6 — Windows release, support matrix, and manual QA

1. Add backend unit/integration tests and frontend component tests for all request, selection, history, and window states.
2. Build a signed/release-ready x64 Windows package and installer (choose MSI or NSIS after testing the target install/update flow); document WebView2/runtime prerequisites.
3. Test install, launch at login only if explicitly enabled, tray lifecycle, upgrade, uninstall, secret retention/deletion behavior, and clean reinstall.
4. Manually verify Notepad/browser and other available UIA apps, 100/125/150/200% DPI, multiple monitors, mixed scaling, keyboard-only/VoiceOver-equivalent Narrator access, light/dark mode, and long translations.
5. Publish the known-compatibility matrix and limitations next to the Windows build instructions.

**Exit criteria:** Clean Windows build/install/uninstall succeeds; core acceptance criteria hold on the baseline support matrix; unsupported selection controls fail clearly without freezing, stealing focus, or altering clipboard contents.

## Priority goals

- **P0 — Selection feasibility:** Prove the UIA path and define its actual app support before investing in the full shell.
- **P1 — Core user path:** tray/startup → detect selection → choose one of three actions → stream result → dismiss/copy.
- **P1 — Safe configuration:** endpoint/key/model settings, model list, connection timing, secure key storage.
- **P2 — Quality of life:** pin, resizable/movable result, persistent size, local history.
- **P2 — Distribution:** repeatable Windows x64 installer, update/uninstall behavior, documented prerequisites.

## Cross-platform test and acceptance goals

- Root `swift test` and the current macOS app remain unaffected by the new project.
- Windows UIA operations never block the frontend and handle inaccessible/slow providers safely.
- Source app retains focus when selection assistance appears.
- For a supported selection, all three actions use the selected text, stream safely, cancel stale work, and show understandable failures.
- Same API provider capabilities as the existing app: Chat/Responses, model discovery, manual model selection, and sample-translation timing.
- Credentials are stored in Windows OS-protected storage, never in WebView storage or logs.
- Result can be copied, retried, pinned, moved, and resized; its size restores and placement stays visible.
- Only successful completed results enter local history; list order and deletion behavior are correct.
- UIA limitations are stated explicitly; clipboard content is not changed by the initial selection implementation.

## Decisions to make during Phase 0/1

- Minimum Windows release and supported CPU architectures (initial proposal: Windows 10/11 x64; validate Rust/Tauri toolchain and WebView2 prerequisites before declaring support).
- Whether unsupported UIA selection gets a future opt-in keyboard shortcut or clipboard-based fallback; no clipboard fallback in v1 without explicit approval.
- Whether history should have an opt-out control in addition to delete/clear.
- Installer format/signing identity and whether updates are distributed in-app or by new installer releases.

## Not included in this plan

- A full rewrite or migration of the macOS application.
- Cloud sync, login/accounts, telemetry, or remote history storage.
- Unreviewed clipboard interception, clipboard modification, or automatic sending of clipboard contents.
- Advertising universal UIA support for all editors, browsers, and custom controls.
