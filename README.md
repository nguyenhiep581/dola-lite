# Dola Lite

Lightweight desktop selection assistant for **macOS** (Swift/AppKit) and **Windows** (Rust + Tauri 2). Select text in any supported app to trigger a non-activating quick-action pill (**Dịch**, **Tóm tắt**, **Giải thích**) with live streaming Markdown results, pin/resize/move support, and private local history.

## Features

- **Selection-triggered quick actions:** Detects highlighted text via native OS accessibility APIs (macOS Accessibility / Windows UI Automation) — never reads or modifies your clipboard.
- **Three Vietnamese-first skills:**
  - **Dịch** — natural Vietnamese translation (prioritizes low reasoning effort for speed)
  - **Tóm tắt** — concise Vietnamese summary
  - **Giải thích** — plain-language explanation with structured steps and examples
- **Floating Result Panel:** Live streaming Markdown, elapsed timer, Copy confirmation (`✓`), Retry, Pin/Unpin, move & resize with persisted size, Escape/outside-click dismiss, and inline newest-first History tray.
- **Full History Browser:** Master–Detail window storing up to 200 completed entries locally (private, atomic writes; failed/cancelled requests are never saved).
- **OpenAI-compatible APIs:** Supports both **Chat Completions** (`/chat/completions`) and **Responses** (`/responses`), `/models` discovery (works even with blank model input), latency connection test, and no-redirect HTTP transport.
- **Launch at Login:** Native macOS `SMAppService.mainApp` and Windows `tauri-plugin-autostart`.

## Repository Layout

- `Sources/DolaLite/`, `Tests/DolaLiteTests/`, `Package.swift`, `scripts/make-app.sh` — Native **macOS 13+** Swift/AppKit app
- `windows-tauri/` — Independent **Windows 10/11 x64** Rust + Tauri 2 app with per-user **NSIS** installer configuration
- `windows-tauri/ui-automation-spike/` — Standalone Windows UI Automation diagnostic CLI
- `docs/superpowers/` — Feature specs and implementation plans

## Build & Test

### macOS (13+, Apple Silicon)

```bash
swift test
bash scripts/make-app.sh
cp -R DolaLite.app /Applications/DolaLite.app
```

### Windows (10/11 x64 — NSIS Installer)

Requires Node.js 20+, Rust stable (`x86_64-pc-windows-msvc`), Visual Studio C++ Build Tools, and WebView2 Runtime.

```powershell
cd windows-tauri
npm ci
npm run build
cd src-tauri
cargo test
cd ..
npm run tauri -- build --bundles nsis
```

Installer output: `windows-tauri/src-tauri/target/release/bundle/nsis/`

## Privacy & Security

- API keys are stored separately from history and never logged or written to frontend WebView storage (macOS: owner-only `0600` file inside `0700` Application Support directory; Windows: Windows Credential Manager).
- Secure/password inputs and Dola Lite's own windows are ignored by the selection watcher.
- HTTP redirects are disabled so `Authorization` headers cannot leak across hosts.
- No telemetry, accounts, or cloud sync.
