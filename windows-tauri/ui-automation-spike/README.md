# Windows UI Automation selection spike

This is the first, deliberately small Windows-only proof of concept for Dola Lite. It checks whether the currently focused UI Automation element exposes selected text through `TextPattern.GetSelection()` and whether UI Automation can return visible range bounds.

## Run on Windows

Install a stable Rust toolchain, then open PowerShell and run:

```powershell
cd windows-tauri\ui-automation-spike
cargo test
cargo run --release -- --watch
```

The watcher prints JSON when a stable selection is detected. By default, it prints only the foreground process ID, selection length, and bounds—not the selected text. To explicitly print the text for manual debugging:

```powershell
cargo run --release -- --watch --print-text
```

Add `--verbose` to print UI Automation provider errors, throttled to one message every two seconds. On a normal watch, the spike emits a `deselection` event only after the selection has remained unavailable for the debounce interval, reducing noise when an app briefly fails a UIA query.

To take one snapshot instead of watching:

```powershell
cargo run --release
```

The spike never reads or modifies the clipboard. It skips secure/password controls, ignores its own process, requires at least two characters, bounds each read to 10,000 characters, and sets finite UIA connection/transaction timeouts. This console diagnostic initializes COM in MTA mode on its polling thread; the eventual Tauri app must put these calls on a dedicated backend worker rather than its UI thread. Browser renderer PIDs are recorded separately instead of requiring an unsafe match to the top-level browser PID.

## Initial manual support matrix

Run the watcher in a terminal. In each application, select a visible phrase and note whether the watcher emits an event and a useful rectangle. Also record how quickly it recovers after switching apps or clearing the selection.

| Application/control | Expected observation | Result |
|---|---|---|
| Windows Notepad — selected text in an edit/document control | Text and visible selection bounds | Not tested yet |
| Browser — selected page text | Text and visible selection bounds if the browser exposes a UIA TextPattern range | Not tested yet |
| Win32 edit control | Text and visible selection bounds if supported by the control provider | Not tested yet |
| Office/Electron applications available on the test machine | Record each app/version separately; providers may differ | Not tested yet |

## Limits and safety

- The Windows target and `--tests` compile-check successfully from macOS, but UI Automation calls cannot be executed on this host. Run the manual matrix below on a real Windows machine before calling any app supported.
- The spike is a diagnostic, not a production selection watcher. It uses bounded UIA connection and transaction timeouts, but Windows-only testing is still required to validate real provider behavior and confirm those limits are respected. The full Tauri app still needs a dedicated worker and lifecycle/cancellation handling.
- UI Automation selection support is control-specific; a missing TextPattern or empty range means the app cannot offer selection to this client through this path. Do not treat this as proof that every Windows application is supported.
- UI Automation can expose sensitive text. Text is omitted from output unless `--print-text` is deliberately supplied. Do not attach unredacted diagnostic output to bug reports.
