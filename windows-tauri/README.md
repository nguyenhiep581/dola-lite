# Dola Lite for Windows (Rust + Tauri 2)

Independent Windows 10/11 x64 desktop edition built with Rust, Tauri 2, TypeScript, and Windows UI Automation. The macOS Swift/AppKit app at the repository root remains completely separate.

## Features

- **System tray & Launch at Windows login:** Tray menu with API status, Settings, History, Launch at Windows login (`tauri-plugin-autostart`), and Quit.
- **Native Windows UI Automation watcher:** Dedicated MTA COM worker (`CUIAutomation8` / `IUIAutomation2`, 500 ms connection/transaction timeouts, Per-Monitor V2 DPI awareness, password-field skipping, debounced selection & deselection). Never reads or modifies the clipboard.
- **Non-activating floating pill:** Uses `WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW` + `WM_MOUSEACTIVATE` (`MA_NOACTIVATE`) so showing or clicking **Dịch**, **Tóm tắt**, or **Giải thích** keeps focus in the source app.
- **Streaming Result Panel:** Safe DOM-only Markdown rendering, elapsed wait counter, Copy (`✓` feedback), Retry, Pin/Unpin, drag/resize with remembered size, Escape dismiss, and inline newest-first History tray.
- **Secure credentials & provider parity:** Chat Completions & Responses SSE streaming, `/models` discovery (including with blank model input), latency test, no-redirect HTTP client, and API key storage in **Windows Credential Manager** (`CredReadW`/`CredWriteW`/`CredDeleteW`).
- **NSIS installer:** Configured in `src-tauri/tauri.conf.json` (`bundle.targets: ["nsis"]`, `installMode: "currentUser"`).

## Build NSIS installer on Windows 10/11

Prerequisites: Node.js 20+, Rust stable (`x86_64-pc-windows-msvc`), Visual Studio C++ Build Tools, WebView2 Runtime (preinstalled on Windows 11).

```powershell
cd windows-tauri
npm install
npm run build
cd src-tauri
cargo test
cd ..
npm run tauri -- build --bundles nsis
```

Installer output:
`windows-tauri/src-tauri/target/release/bundle/nsis/Dola Lite_1.0.0_x64-setup.exe`

## Automated CI Release

Pushing a version tag (`v*`) triggers `.github/workflows/release.yml`, which runs tests and builds both `DolaLite-<tag>-macOS-arm64.zip` and `DolaLite-<tag>-windows-x64-setup.exe` (NSIS) on `macos-15` and `windows-latest` runners.

## Phase 0 diagnostic spike

The standalone diagnostic CLI remains in `ui-automation-spike/` for isolating UIA provider behavior on Windows.
