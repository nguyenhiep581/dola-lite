# Dola browser spike (historical)

Archived on 2026-11-15 when the user approved switching to a standalone, configurable OpenAI-compatible API. These sources and tests preserve the Chromium/CDP experiment, including previously uncommitted editor-readiness fixes. They are outside SwiftPM Sources/Tests and are not compiled or shipped.

The production app uses its own API settings and macOS Keychain. It does not launch Dola, copy its profile or reuse its session. Findings in the older notes remain historical observations; the browser completion gate never passed reliably.
