# Dola Lite for Windows

Planned independent Windows desktop app using Rust + Tauri 2. The existing macOS Swift/AppKit app remains at the repository root and is not part of this project.

## Status

Planning and feasibility spike. A small standalone Rust UI Automation diagnostic lives in `ui-automation-spike/`; its core unit tests run on macOS and the Windows target passes cross-compile checks (`x86_64-pc-windows-msvc`), but it is not the production watcher and has not yet been executed on a real Windows machine. The full Tauri, Rust backend, and frontend scaffold has not been generated.

## Planning documents

- [Feature inventory and Windows parity goal](../docs/superpowers/specs/2026-11-19-windows-tauri-feature-parity.md)
- [Implementation plan and milestones](../docs/superpowers/plans/2026-11-19-windows-tauri-plan.md)

The intended Tauri 2 layout is documented in the plan. Keep all eventual Windows code, dependencies, assets, and build scripts under this directory; do not add them to the root Swift package.
