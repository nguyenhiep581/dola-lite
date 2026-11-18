# Dola Lite — Xingchi Native v1 Plan

## Goal

Build a lightweight macOS menu-bar assistant with Dola-inspired selection UI and three Vietnamese skills. All inference uses an app-owned OpenAI-compatible API configuration, not Dola. Translation requests always set reasoning effort to `low`.

## Architecture

- Swift 5.10+ / AppKit / URLSession / Swift Package Manager.
- Accessibility selection watcher → floating pill → result panel → coordinator → streaming API provider.
- API defaults: `https://api.xingchiapi.com/v1`, `gpt-6.1-sol`.
- API key in the macOS Keychain; first-launch-only import of `XINGCHI_API_KEY` from DSH local credentials or environment.
- UserDefaults hold non-secret endpoint/model/reasoning preferences. DSH is not read after first import.
- No Dola browser, profile, cookies, private API, automation or bundled assets.

## Work and acceptance criteria

1. API settings validate HTTP(S) root, model, effort, and key; edits to endpoint/model preserve an existing key. Keychain failures do not partially persist preferences. Explicit key deletion prevents reimport.
2. The OpenAI-compatible provider builds `/chat/completions` streaming requests with Vietnamese-only prompts and Unicode-safe user text. Translation uses `reasoning_effort: low`; other skills use the configured setting.
3. SSE parser handles arbitrary transport splits, Unicode, CRLF, multiline data, keepalive, terminal/error frames, empty/incomplete/truncated replies and bounded buffering. Cancellation reaches URLSession. Server bodies/credentials are not logged or exposed.
4. AX selection is filtered and stable-debounced; pill/result do not activate the source app. Panel placement handles missing bounds and secondary displays. Dismissal cancels the current generation and discards late results.
5. Settings window allows API configuration, connection check and key removal. Menu provides Accessibility status/onboarding. Copy, Retry, Escape and outside-click behavior work.
6. `swift test`, release build, ad-hoc signing and signature verification pass. Manual UI tests and a real authorized API response are recorded separately.

## Verification record (2026-11-18)

- `swift test` passed **47 tests**, including all three skills and cancellation through URLSession with fixture responses.
- `bash scripts/make-app.sh`: release build succeeded.
- `codesign --verify --strict DolaLite.app`: succeeded.
- `swift run DolaLite --preview /tmp/dolalite-ui-preview`: pill/result PNGs rendered. Visual inspection was unavailable in this session.
- Authenticated `GET /v1/models` returned HTTP 200 and listed `gpt-6.1-sol`; returned metadata did not declare completion permissions. Live probe `POST /v1/chat/completions` for `translate` at `low` returned **HTTP 403** from app and a direct HTTP client. Ask Xingchi what restriction/client requirement caused it; translation success remains unverified.
- Accessibility permission, full interactive UI matrix, and second-display manual behavior remain for device/user verification.

## Release steps

```sh
swift test
bash scripts/make-app.sh
open DolaLite.app
```

To configure a key or run a real connection check, open **Cài đặt API…** from the menu-bar icon. Do not commit credentials, settings state or generated `DolaLite.app`.
