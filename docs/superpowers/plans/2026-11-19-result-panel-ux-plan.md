# Result Panel UX — Goals & Implementation Plan

- Date: 2026-11-19
- Status: Implemented; automated tests and release build pass; manual UI verification remains
- Scope: Result panel resizing, move/positioning, pinning, and translation history

## Goal

Make the translation, summary, and explanation result panel adaptable and persistent without losing the current lightweight selection workflow:

1. Users can resize and move the result panel; its size is remembered across app launches.
2. Users can pin a result so clicks outside and unrelated selection changes do not dismiss it.
3. Users can reopen completed translations, summaries, and explanations from local history, inspect an entry, and copy its result.
4. Streaming, cancellation, Escape/close, accessibility, screen-edge placement, and existing selection behavior continue to work.

## Current implementation

- `ResultPanel` is a borderless `NSPanel` with a fixed 390 × 350 frame, a header, streaming text, Copy, Retry, and Close.
- `PanelPlacement.frame` clamps the fixed-size panel to the screen containing the selection.
- `PanelCoordinator` closes the result panel on outside clicks and selection changes, and owns request cancellation/generation checks.
- There is no result-history store or history UI.

## Product decisions for the first release

- **Resize:** Allow resizing with a visible, accessible resize affordance. Reflow wrapped text and keep the existing vertical scrolling behavior. Remember the last width and height, not the last screen coordinates; clamp the saved size to the current display's usable area when reopening.
- **Move:** Allow dragging the panel from its header. Keep it within a visible screen. Do not persist its position, so a later result still opens near the current selection.
- **Pin:** Add a pin toggle beside Copy in the result header. A pinned panel stays open on outside clicks and selection changes. Escape and the Close button still close it. If the user explicitly starts another translation/summary/explanation, archive the completed previous result and show the new request in the single result panel.
- **History:** Add a history icon in the result header. Store completed results only, locally, with skill, timestamp, model, source text, and result text. Open a browsable list; selecting an entry shows its full formatted result and supports copying it. Provide per-entry removal and a clear-history action.
- **Privacy and size:** Store history in the app's Application Support directory, separate from API credentials, with owner-only directory/file permissions and atomic writes. Keep at most 200 entries, newest first. Do not store failed or partial requests. Clearly label the source text in the history detail view.

## Implementation plan

### Phase 1 — Resizable and movable result panel

1. Add minimum and maximum sizing rules to `ResultPanel`; enable window resizing and provide a discoverable resize handle.
2. Update `PanelPlacement` to accept the saved panel size and clamp both the dimensions and frame to the active display's visible frame.
3. Add a small size store using app preferences. On panel resize, save the new dimensions; restore them on the next result and clamp stale values for smaller screens.
4. Add a header drag affordance. Move the panel without confusing a drag with Copy, Pin, History, or Close clicks; clamp the moved panel so it remains reachable.
5. Re-run the text container width synchronization after layout/resize so long text wraps correctly and the vertical scroller remains usable.

### Phase 2 — Pinning and dismissal behavior

1. Add pin state and an SF Symbol button with an accessible label and tooltip that reflect the current state.
2. Route pin changes from `ResultPanel` to `PanelCoordinator` rather than putting dismissal rules in the view.
3. Update outside-click and selection-change handling to preserve a pinned result. Keep explicit Escape, Close, app shutdown, and user-started replacement behavior deterministic.
4. Ensure unpinning returns to normal automatic dismissal and that starting a new request still cancels stale streaming work safely.

### Phase 3 — Persistent result history

1. Add a `HistoryEntry` model and a focused `HistoryStore` with bounded entry count, safe decoding, atomic writes, and private file permissions.
2. Save an entry only after `PanelCoordinator` receives a successful completed response. Capture skill, current model, source text, full response, and timestamp. Exclude failed and cancelled/partial requests.
3. Add a history icon to the result header and an AppKit history browser with an empty state, skill/date context, and a detail view that renders the saved result using the existing Markdown renderer.
4. Add Copy, remove-entry, and clear-history actions. Keep history browsing separate from the active stream so browsing cannot corrupt or cancel the current request.
5. Handle corrupt/unavailable history storage with a safe user-facing status; never show raw file errors or lose the ability to use translation.

### Phase 4 — Validation and release

1. Add placement/size tests for minimums, screen clamping, restored dimensions, and secondary displays.
2. Add panel/coordinator tests for pin toggle, outside click, selection change, Escape/Close, and replacement while pinned.
3. Add history-store tests for round trip, ordering, retention limit, removal, clear, corrupt data, and atomic-write failure. Add coordinator tests proving only completed results are recorded.
4. Run `swift test`, build with `bash scripts/make-app.sh`, and verify the resulting bundle signature.
5. Manually verify resizing, dragging, pinned behavior, history browsing/copy/delete, light/dark appearance, accessibility labels, and small/secondary displays.

## Implementation progress

- [x] Resizable result panel with a visible drag handle, persistent size, and display clamping.
- [x] Header drag handle to reposition the panel while keeping it reachable.
- [x] Pin/unpin control; pinned results survive outside clicks and selection changes, while explicit close/Escape remains available.
- [x] Owner-only local history for completed results, bounded to 200 entries and protected by atomic writes.
- [x] Inline history tray below result content with newest-first entries; the menu-bar history browser remains available for full preview, copy, and deletion.
- [x] Automated history, placement, preference, pinning, and successful-completion tests.
- [x] `swift test` and release app build/signature verification.
- [ ] Manual visual/accessibility checks across appearance modes and multiple display sizes.

## Acceptance criteria

- Resizing visibly changes the result panel; long content continues to wrap and scroll vertically without horizontal overflow.
- A resized panel reopens with its previous dimensions, adjusted if those dimensions do not fit the current display.
- The panel can be repositioned by dragging its header and stays reachable on screen.
- With Pin enabled, an outside click or changed selection does not hide the result. Escape and Close still work; an explicit new request replaces it only after the previous completed result is available in history.
- The history icon opens local history. Each completed Dịch / Tóm tắt / Giải thích entry can be reopened and copied after an app restart.
- Cancelled, failed, and partial responses are not presented as completed history entries; the history limit and deletion controls work.
- Existing streaming, Retry, Copy, dismiss, screen placement, and API behavior continue to pass tests.

## Out of scope

- Persisting the panel's last screen coordinates.
- Cloud sync, exporting, or sending history to an external service.
- Editing or re-running a historical entry from the history browser.
- Changing model selection or provider request behavior.
