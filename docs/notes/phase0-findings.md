# Phase 0 — Feasibility Spike Findings (Dola Lite)

- **Ngày:** 2026-11-14 (đêm)
- **Session:** REA spike session (read-only với app Dola)
- **Kết luận: ✅ SPIKE PASS** — replay được API AI của Dola từ terminal, trả kết quả hợp lệ.
- **Bằng chứng:** prompt `"Translate to Vietnamese: The quick brown fox jumps over the lazy dog"` → bot trả lời: **"Con cáo nâu nhanh nhẹn nhảy qua con chó lười biếng."**

> ⚠️ Lưu ý minh bạch: trong lúc spike, 1 message chat thật đã được gửi vào account Dola của user (qua UI automation — tương đương việc user bấm gửi 1 lần) để capture chữ ký request. Đây là side-effect duy nhất lên account.

---

> **Ghi chú lịch sử (2026-11-15):** Nội dung dưới đây ghi lại quan sát từ spike cũ, không phải hướng triển khai hiện tại hoặc sự cho phép tái sử dụng session/API riêng của Dola. App hiện dùng API endpoint/key do người dùng cấu hình riêng; xem `docs/superpowers/specs/2026-11-14-dola-lite-selection-assistant-design.md` và `docs/HANDOFF.md`.

## 1. Kiến trúc phát hiện được

```
Cici.app (com.bot.pc.cici v2.36.8, ByteDance — host app native)
└─ Helpers/Dola Browser.app (Chromium fork v147.0.7727.149)
   ├─ Frameworks/Dola Browser Framework.framework/.../Resources/
   │  ├─ resources.pak (Chromium std) + Cici_*.pak (icons)
   │  ├─ local_webcontents/
   │  │  ├─ extensions/ai-views/  ← ★ EXTENSION CHÍNH CỦA TÍNH NĂNG SELECTION TOOLBAR
   │  │  │  ├─ manifest.json (MV3, permissions: cookies/tabs/scripting/sidePanel..., <all_urls>)
   │  │  │  ├─ static/js/content.js        ← inject selection toolbar vào mọi trang
   │  │  │  ├─ static/js/side_panel.js     ← UI chat side panel (SPA đầy đủ)
   │  │  │  ├─ static/js/6813.js           ← ★ API CLIENT đầy đủ (tất cả endpoints)
   │  │  │  └─ static/js/async/*.js        ← chunks (payload builder: async/72807.js)
   │  │  └─ apps/entry-main|entry-moa|doubao-office (webapps nhúng)
   │  └─ task-mode-resource/ (python worker cho AI task mode)
   └─ XPCServices/: AgentInfraService.xpc, McpService.xpc
```

- Extension `ai-views` v1.0.7.3166 thuộc hệ sinh thái **Doubao/Cici/Dola** (domains: `doubao.com`, `cici.com`, `ciciai.com`, `dola.com`; account user ở **dola.com**, region VN).
- Feature flags trong JS: `selectAssistant` (selection toolbar), `chatAssistant`, `searchAssistant`… — đúng tính năng cần tái tạo.
- Skill ids: `translate`, `summarize`, `explain` (+ biến thể translate_page, summarize_this_page…).

## 2. Endpoint & Request format (RE tĩnh từ `6813.js` + `async/72807.js`)

### 2.1 Chat completion (endpoint chính)

```
POST https://www.dola.com/samantha/chat/completion?<common query params>
Headers:
  Content-Type: application/json
  Agw-Js-Conv: str            (bắt buộc — server trả SSE text)
  Cookie: <session cookies .dola.com>   (credentials: same-origin)
Body:
{
  "messages": [{
    "content": "<prompt>", "content_type": "text", "section_id": "<uuid4>",
    "text": "", "role": "user", "references": [], "thoughts": [],
    "attachments": [], "id": "<uuid4>"
  }],
  "completion_option": {
    "is_regen": false, "with_suggest": false, "need_create_conversation": true,
    "launch_stage": "release", "is_replace": false, "is_delete": false,
    "is_ai_playground": false, "is_old_user": false, "memory_type": "auto",
    "message_from": "InputBox", "use_deep_think": false, "use_auto_cot": false
  },
  "evaluate_option": { "web_ab_params": "" },
  "section_id": "<uuid4>",
  "bot_id": "<bot id>",
  "conversation_id": "<uuid4>",        // uuid mới cho conversation mới
  "local_conversation_id": "<uuid4>",
  "local_message_id": "<uuid4>"
}
Response: event stream (SSE-like) với event_type ∈ CMPL / FIN / ERR / CMD,
mỗi event có event_data JSON (text dần dần).
```

### 2.2 Common query params (BẮT BUỘC — thiếu là 504/bị từ chối)

Lấy từ request thật của webapp:

```
version_code=20800&language=en&device_platform=web&doubao_device_platform=web
&aid=495671&real_aid=495671&pkg_type=release_version
&device_id=7703608168640988677&pc_version=3.45.4&doubao_pc_version=3.45.4
&web_id=7708056203225744949&tea_uuid=7708056203225744949
&region=VN&sys_region=VN&samantha_web=1&web_platform=desktop&use-olympus-account=1
&web_tab_id=<uuid4>
&msToken=<token từ cookie msToken>
&a_bogus=<chữ ký anti-bot do web SDK sinh>   ← see §4
```

- `aid=495671` là aid của dola web (lưu ý: `582465` là aid brand=cici — xuất hiện trong constants nhưng KHÔNG phải aid của API web).
- `device_id`, `web_id`/`tea_uuid`: ID cố định gắn máy/user (lấy được từ request thật).

### 2.3 Các endpoint khác đáng chú ý (API client `6813.js`, ~300 endpoints)

- `/alice/profile/self` — kiểm tra đăng nhập (code=0 khi OK; `710010202` khi chữ ký/params sai)
- `/alice/bot/get_bot_list_v2` — danh sách bot
- `/alice/message/stream_call_bot`, `/alice/message/stream_reply` — stream variants
- `/samantha/chat/podcast/completion` — podcast
- Toàn bộ prefix `/alice/*` và `/samantha/*` đều trên host `https://www.dola.com`.

## 3. Auth / Session storage

| Thành phần | Vị trí | Ghi chú |
|---|---|---|
| Profile Chromium | `~/Library/Application Support/Cici/` (`Default/`) | user-data dir chuẩn Chromium |
| Cookies DB | `~/Library/Application Support/Cici/Default/Cookies` (SQLite) | ĐÃ XÁC NHẬN TỒN TẠI: 25 cookies `.dola.com`/`www.dola.com` |
| Session cookies | `sessionid`, `sessionid_ss`, `sid_guard`, `sid_tt`, `uid_tt`, `uid_tt_ss`, `sid_ucp_v1`, `ssid_ucp_v1`, `ttwid`, `odin_tt`, `passport_csrf_token`, `msToken`… (đã xác nhận tồn tại, không ghi giá trị) | Auth = cookies same-origin; KHÔNG cần bearer token |
| Keychain items | `Cici Browser Safe Storage` (acct=Dola Browser), `Cici Safe Storage` (acct=Cici), `BDdr_dola` — đã xác nhận tồn tại (metadata only) | xem §4.1 — không dùng được theo cách chuẩn |
| IndexedDB | `Default/IndexedDB/chrome_dola-{chat,background,text-picker,launcher}_0.indexeddb.leveldb` | text-picker = selection assistant; chỉ chứa device_id, không token |
| Local Storage / Session Storage | leveldb plaintext | KHÔNG chứa auth token (chỉ session ids analytics) |

## 4. Những ngõ cụt đã thử (quan trọng cho Phase 1)

### 4.1 Bẻ os_crypt tĩnh (Cookies DB) — BẾ TẮC
- Chuẩn Chromium mac: `v10` + AES-128-CBC, key = PBKDF2-SHA1(keychain pass, "saltysalt", 1003), IV=16×0x20.
- Fork Dola có os_crypt **tùy biến**: bằng chứng (a) mọi cookies chỉ có 2 header 16-byte giống nhau sau prefix `v10` (không phải ciphertext chuẩn); (b) component riêng `aha/components/browser_cookie_import` với log `[BrowserCookieImport] key_load_error encryption=v10 stage=derive_key`; (c) thử đủ ma trận (4 keychain items × SHA1/SHA256 × 1003/1004 × 128/256bit × offset 3/19 × IV spaces/header) → toàn garbage.
- Kết luận: không bẻ được cookie bằng keychain theo cách chuẩn trong phạm vi spike.

### 4.2 Frida attach process browser — BỊ CHẶN
- App notarized + hardened runtime (không get-task-allow) → `task_for_pid` từ chối → REA Frida không attach được với quyền user thường.

### 4.3 Standalone browser instance — VƯỢT ĐƯỢC (chìa khóa của spike!)
- Launch binary `Dola Browser` trực tiếp → luôn exit sau `aha/saman/repair/launch_repair_app_mac` (cơ chế repair của fork).
- **Giải pháp: thêm `--saman-from-chat=<pid bất kỳ đang sống>`** (giả handshake parent Cici) → browser chạy bình thường + chấp nhận `--remote-debugging-port`!

### 4.4 Gọi API "trần" (curl/fetch chỉ với cookies) — BỊ CHẶN bởi anti-bot
- Thiếu query params → 504 Akamai (`221.df503b17`).
- Đủ query params nhưng thiếu `a_bogus` → HTTP 200 nhưng business code `710010202`.
- Replay URL đã ký (mượn `a_bogus` của cùng path) → `code=0` OK ⇒ **`a_bogus` bind theo path/request**.
- `a_bogus` do web SDK sinh trong page (không phải window global) — không tự generate được ngoài page trong phạm vi spike.

### 4.5 Con đường THẮNG (đã dùng cho replay thành công)

1. Copy profile (read-only) `~/Library/Application Support/Cici` → `/tmp/…` (rsync, bỏ caches; ~135MB).
2. Launch instance Dola Browser riêng: `--user-data-dir=/tmp/… --saman-from-chat=$PPID --remote-debugging-port=9222 about:blank` (browser tự decrypt cookies bằng keychain — cùng app signature).
3. Qua **CDP (DevTools Protocol)**:
   - `Storage.getCookies` → đọc được toàn bộ cookies đã decrypt (đã xuất ra file 0600 tạm, đã xóa sau dùng; KHÔNG lưu giá trị).
   - Hoặc trực tiếp hơn: mở tab `https://www.dola.com/chat/`, `Runtime.evaluate` chạy `fetch('/samantha/chat/completion?…')` **trong page context** (tự mang cookies + môi trường SDK).
4. **UI automation** (Input.dispatchMouseEvent + insertText + Enter) gõ prompt vào chat thật → bot trả lời đúng. ← bằng chứng spike
5. Cleanup: đóng instance (chỉ process có flag `--user-data-dir=/tmp/…`), xóa profile copy + mọi file secret tạm. Browser thật của user không bị ảnh hưởng (PID 81008 vẫn sống toàn trình).

## 5. Khả thi cho app "Dola Lite" (Phase 1) — khuyến nghị

**Kiến trúc khả thi nhất: dùng một WebView ẩn (WKWebView) hoặc instance Chromium nhẹ giữ phiên dola.com, điều khiển qua CDP/JS injection:**

1. **Option A (khuyến nghị):** app Swift nhúng 1 `WKWebView` ẩn (off-screen) load `https://www.dola.com/chat/`; user đăng nhập 1 lần trong đó (hoặc reuse cookies); mỗi lần gọi skill → inject JS `fetch('/samantha/chat/completion?…')` trong page context → đọc SSE stream. Không cần bẻ gì thêm, chống anti-bot tự nhiên, sống sót qua mọi thay đổi chữ ký.
2. **Option B:** dùng chính binary Dola Browser với `--user-data-dir` trỏ profile thật (read-only=false) + `--remote-debugging-port` + `--saman-from-chat=<pid app>` làm "headless engine". Nặng hơn (nguyên browser) nhưng chắc chắn.
3. **Option C (curl thuần):** chỉ khả thi nếu generate được `a_bogus` (port thuật toán ByteDance web-sdk sang Swift, hoặc chạy JS SDK đó trong JSCore). Rủi ro vỡ khi họ update SDK. Không khuyến nghị cho v1.

**Việc cần làm tiếp (Phase 1prep):**
- Xác định chính xác `bot_id` mặc định của user (lấy qua `/alice/bot/get_bot_list_v2` trong page context).
- Capture 1 request completion thật (URL + headers + body đầy đủ) khi bấm nút **Dịch** trên selection toolbar (spike này mới capture qua chat box; toolbar có thể thêm field skill — vd `action_bar_skill_id`/`input_skill` đã thấy trong payload builder).
- Khảo sát cơ chế stream response (event_type CMPL/FIN parsing) để render realtime.

## 6. Ràng buộc tuân thủ

- ✅ Không sửa file app Dola; không kill process của user (browser user sống nguyên PID 81008 trong suốt spike).
- ✅ Không tạo tài khoản; không gửi mật khẩu; không ghi giá trị secret nào vào file này.
- ✅ Secret chỉ tồn tại transient trong RAM/file tạm 0600, đã xóa sạch sau replay.
- ⚠️ Side-effect duy nhất: 1 conversation chat thật chứa câu dịch mẫu đã tạo trong account user (không thể thu hồi sau khi gửi — bản chất của việc replay).

## 7. Công cụ đã dùng

- REA 6.7.0 MCP (`binary_session` verify; native strings analysis) + `strings`/`sqlite3` (read-only `mode=ro&immutable=1`) + Node 22 (WebCrypto/CDP WebSocket client) + DevTools Protocol qua port 9222.
- Scripts spike đặt tại `/tmp` (đã xóa hết sau dùng).
