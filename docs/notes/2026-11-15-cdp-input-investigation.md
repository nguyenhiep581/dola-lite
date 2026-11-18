# CDP input investigation — 2026-11-15

## Result

Reproduced the old Swift probe failure, isolated a startup/editor readiness race, and verified that the patched Swift code inserts the prompt into the real editor. End-to-end translation still FAILS: Enter opens Dola's client-login modal; the probe ultimately times out. Do not mark Task 2B complete.

The earlier overnight-deployment/binary-update hypothesis is not established. The current browser reports Chrome/147.0.7727.149. There is no archived binary/bundle hash baseline to prove or disprove an update.

## Controlled observations

1. Unchanged debug app launches a separate headless engine with its copied profile. A Node CDP client sends `Input.insertText` after the final editor has appeared: response `{result:{}}`; editor text changes from newline to `diagnostic input`. No mouse click or OS activation needed. This test did not submit.
2. Unchanged Swift `--probe "Hello world."`, observed through a second read-only CDP connection on the correct engine port, times out (exit 2). Startup timeline:
   - document interactive, visible `textarea.textarea-YelHeN[data-testid=chat_input_input]`;
   - hidden `div.tiptap.ProseMirror[contenteditable=true]` appears alongside textarea;
   - textarea replaced by visible ProseMirror;
   - another navigation to `/chat/`, with placeholder changing from Vietnamese to English;
   - final visible ProseMirror. Navigation erases `window.__dolaLite`.
   The old bridge reports FOCUSED on the temporary textarea and does not check readiness, visibility, or actual focus.
3. Same transition/reload occurs in debug mode without sending Enter. Thus it is not solely caused by submission. Locale initialization is a candidate cause for the reload, not proven.
4. Patched bridge waits for document complete and the same visible ProseMirror instance for 3 seconds, then checks actual focus. Real Swift probe now visibly inserts the full translation prompt. After Enter, an extra page appears at `/flow-account/client-login/client-login-modal`; chat resets and no reply appears. Probe still exits 2 with timeout.
5. Fresh copied engine, before and after settled readiness: CDP reports nonempty, locally unexpired `sessionid`, `sessionid_ss`, `sid_guard`, `sid_tt`, `uid_tt`, `uid_tt_ss` cookies for `.dola.com`. Only names/presence/expiration metadata were printed. Cookie presence does not prove server-side session validity; root cause of login rejection remains unresolved.

## Patch and validation

- `ChatPageBridge.focusAndBaselineScript`: reject temporary textarea/hidden editor/loading document; debounce the same visible ProseMirror for 3 seconds; verify active element and document focus. This is a bounded settling heuristic, not a guarantee against a later navigation.
- `pollScript`: an initially empty chat has `selector:null`; discover the first explicit bot selector when the reply appears. Restrict this discovery to bot-specific selectors to avoid returning a user prompt.
- Added JavaScriptCore execution tests for loading/hidden/replaced/unfocusable editor and first reply in an empty chat. Observed failures against old code before fixes; full Swift Testing suite passed with 26 tests after initial fixes.
- Existing broader selector fallback, streaming completion heuristic, navigation during an in-flight request, and login-state error reporting are not fully hardened by this patch.

## Authentication follow-up — 2026-11-15

Observed with `scripts/diagnose-auth.mjs`, attached to the port of the browser whose parent is the spawned probe (avoids attaching to a different engine):

- Startup `/alice/user/launch` returned HTTP 200/code 0. A subsequent read-only run also observed `/alice/profile/self` and `/alice/profile/self_brief` with code 0 and profile-shaped response data; `/passport/token/beat/web/` returned error_code 0. No identity or credential values were logged. This is stronger evidence than cookie presence, but is not proof that completion authorization succeeds.
- The first send run issued `POST /chat/completion` (the observed web UI path, different from the spike's documented `/samantha/chat/completion`). Response HTTP 200 was immediately followed by webapp-initiated `GET /passport/web/logout/`, HTTP 200, then navigation/reset and client-login modal. The completion business body was not captured before navigation. Its error code and the precise logout trigger remain UNKNOWN.
- That first webapp logout really reached the server. Copying a profile isolates local files, NOT server-side session state; the request may have affected the user's shared session. Do not repeat unguarded sends during auth diagnosis.
- The next diagnostic run blocked the logout request at the protocol layer. It stopped at a visible age-confirmation dialog: “Để tiếp tục, vui lòng xác nhận bạn đã đủ 18 tuổi trở lên.” No age confirmation was clicked and no completion error was obtained in that run.
- A later read-only run again observed successful profile/self and token beat responses. Thus a blanket conclusion of expired cookies is not justified.
- The final attempted send exited before an owned engine port was discovered (`appExit:2`, `Owned browser port not found`). No new auth conclusion follows from that launch failure.

The diagnostic script defaults to `--probe-debug` (no chat submission); passing `--send` explicitly runs the synthetic Hello world probe. It suppresses app DOM output, omits query/header/cookie/body values from logs, and projects only response schemas/status fields. It blocks observed logout requests only in the attached page; it is not a browser-wide guarantee. Its response-stage interception changes timing and is diagnostic only, not a production auth fix.

User action needed before further send trials: verify/login in the normal Dola app, and personally complete any age-confirmation requirement if accurate. Then re-establish a fresh copy and capture the exact completion business error before concluding cause. Do not force login flags or bypass account prompts.

## Next work

1. Diagnose why a copied profile with auth cookies opens the login modal. Compare actual authenticated state of the user's normal Dola session and the isolated engine; inspect only necessary status/error metadata, not secret values.
2. Confirm a real reply and its exact DOM selector with an accepted session before declaring provider gate PASS.
3. Replace timeout-on-login with a specific authentication error; handle navigation loss explicitly rather than silently polling missing state.
4. Do not switch to CGEvent or native-tab automation merely to fix insertion: existing CDP Input works after editor readiness is corrected.

No original profile or installed Dola files were edited. Diagnostic engines were owned by the app and cleaned up through its normal shutdown. Test sends used only the synthetic sentence “Hello world.” Changes remain uncommitted for review.
