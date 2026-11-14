# HANDOFF — Dola Lite (12_translator)

- **Cập nhật:** 2026-11-14
- **Workspace:** `/Users/hiep/Documents/12_translator` (git repo, branch `master`)
- **Session chính:** `sess_fe500961-c533-40db-90db-acfde849728b`
- **Session spike (đã giao việc, đang chạy):** `sess_d87f2055-71b4-47f6-b24f-4d5f36639f4f`

---

## 1. Project là gì?

Build app macOS native nhẹ ("Dola Lite") tái tạo đúng 1 tính năng của Dola Browser: **popover tự xuất hiện khi chọn text ở bất kỳ app nào** với 3 kỹ năng **Dịch / Tóm tắt / Giải thích**, gọi thẳng AI backend của Dola bằng session đăng nhập hiện có — không cần mở Dola Browser (Chromium fork rất nặng).

## 2. Các quyết định đã chốt với user

| Quyết định | Lựa chọn |
|---|---|
| Trigger popover | Tự động khi chọn text (giống Dola), cần quyền Accessibility |
| Kỹ năng v1 | Chỉ 3: Dịch, Tóm tắt, Giải thích |
| Hiển thị kết quả | Popover nhỏ cạnh text, stream realtime (SSE) |
| Nguồn AI | **Hướng A**: reverse engineer API Dola + tái dùng session; fallback Hướng C (provider khác) chỉ khi spike bế tắc |

## 3. Trạng thái hiện tại

| Việc | Trạng thái |
|---|---|
| Cài REA 6.7.0 (CLI + MCP) | ✅ Xong. CLI: lệnh `rea`. MCP: đã vào `~/.zcode/cli/config.json` → `mcp.servers.rea` (session mới sẽ auto-connect) |
| Recon app Dola | ✅ Xong (xem mục 4) |
| Design spec | ✅ Viết xong, self-review xong, **đã commit `48c229a`**: [docs/superpowers/specs/2026-11-14-dola-lite-selection-assistant-design.md](superpowers/specs/2026-11-14-dola-lite-selection-assistant-design.md) — user chưa duyệt chính thức |
| Phase 0 spike | ✅ **PASS** (đêm 2026-11-14, session `sess_d87f2055...`) — replay thành công 1 call AI dịch từ terminal; chi tiết đầy đủ: [notes/phase0-findings.md](notes/phase0-findings.md) |
| Writing-plans (kế hoạch implement) | ⏳ Chờ: user duyệt spec (kết quả spike không đổi thiết kế — API stream OK, khuyến nghị Option A: WKWebView ẩn + JS injection) |

### Tóm tắt kết quả spike (chi tiết trong notes/phase0-findings.md)

- **Endpoint chat:** `POST https://www.dola.com/samantha/chat/completion?<common-params>` (SSE stream qua header `Agw-Js-Conv: str`). API client đầy đủ ở `local_webcontents/extensions/ai-views/static/js/6813.js`.
- **Auth = cookies same-origin** `.dola.com` (`sessionid`, `sid_guard`… trong `~/Library/Application Support/Cici/Default/Cookies`). KHÔNG cần bearer token.
- **Rào cuối chống curl thuần:** query params bắt buộc (`aid=495671`, `device_id`, `web_id`…) + `msToken` (cookie) + `a_bogus` (chữ ký anti-bot do web SDK sinh, bind theo path).
- **Bế tắc đã xác định:** bẻ cookies DB tĩnh = không khả thi (fork custom os_crypt, đã thử 4 keychain items × đủ biến thể); Frida attach bị hardened-runtime chặn.
- **Chìa khóa vượt:** launch instance Dola Browser riêng với `--user-data-dir=<copy profile> --saman-from-chat=<pid sống> --remote-debugging-port=9222` (bypass cơ chế repair) → điều khiển qua **CDP**: lấy cookies decrypted hoặc gọi API trong page context. Bằng chứng: bot trả lời đúng bản dịch tiếng Việt.
- **Khuyến nghị Phase 1:** Option A = WKWebView ẩn giữ phiên dola.com + inject JS fetch (không cần bẻ gì, sống sót qua thay đổi chữ ký). Option C (curl thuần) cần port thuật toán `a_bogus` — rủi ro cao, không khuyến nghị v1.
- Side-effect duy nhất lên account: 1 conversation chat thật chứa câu dịch mẫu (đã ghi rõ trong findings).

## 4. Facts quan trọng đã recon

- App Dola thật: `/Applications/Cici.app/Contents/Helpers/Dola Browser.app` (trong `Cici.app`, `com.bot.pc.cici` v2.36.8, ByteDance). `/Applications/Dola Browser.app` chỉ là **Alias**.
- Dola Browser = **Chromium fork v147.0.7727.149** → nặng. Tính năng "Text Selection Toolbar" = pill Dịch/Tóm tắt/Giải thích/Hỏi Dola/AI Tìm kiếm.
- Paths đáng chú ý:
  - `.../Dola Browser.app/Contents/Frameworks/Dola Browser Framework.framework/Versions/147.0.7727.149/Resources/resources.pak` (UI JS Chromium)
  - `.../Dola Browser.app/Contents/Resources/cua/` (`libaha_cua.dylib`, `resources/`)
  - `.../Dola Browser.app/Contents/XPCServices/AgentInfraService.xpc`
- Dola Browser thường đang chạy (`Dola Browser Helper` processes).
- Node: fnm v22.23.3 — REA coi là healthy. `~/.zshenv` có lỗi nhỏ: reference tới `/Users/hiep/.cargo/env` không tồn tại (vô hại, chỉ in warning).

## 5. PROMPT SPIKE — copy-paste vào session mới nếu cần tự chạy

> **Lưu ý:** prompt này Y HỆT cái đã gửi cho session `sess_d87f2055...`. Nếu session đó đã xong thì **đọc `docs/notes/phase0-findings.md` trước** để khỏi làm lại.

```text
Phase 0 — Feasibility spike cho project "Dola Lite" (trợ lý chọn text macOS). Bạn là session chuyên làm reverse engineering với REA.

# BỐI CẢNH
Mục tiêu dài hạn: app macOS native nhẹ (Swift) phát hiện text được chọn ở mọi app → popover 3 nút Dịch/Tóm tắt/Giải thích → gọi thẳng AI backend của Dola bằng session đăng nhập hiện có của user, không cần mở Dola Browser.

- Spec đầy đủ (BẮT BUỘC đọc trước): /Users/hiep/Documents/12_translator/docs/superpowers/specs/2026-11-14-dola-lite-selection-assistant-design.md
- App Dola thật: /Applications/Cici.app/Contents/Helpers/Dola Browser.app — Chromium fork v147.0.7727.149, bên trong Cici.app (com.bot.pc.cici v2.36.8, ByteDance). Alias "/Applications/Dola Browser.app" chỉ trỏ tới đó.
- REA 6.7.0 đã cài: CLI `rea` + MCP server `rea` đã đăng ký trong ~/.zcode/cli/config.json (session mới như bạn sẽ auto-connect — verify xem tools MCP rea hiện hữu không, không thì dùng CLI `rea`).
- Vài path đáng chú ý đã recon: Resources/cua/ (libaha_cua.dylib), XPCServices/AgentInfraService.xpc, Frameworks/Dola Browser Framework.framework/Versions/147.0.7727.149/Resources/resources.pak
- Dola Browser CÓ THỂ đang chạy (process "Dola Browser Helper").

# NHIỆM VỤ SPIKE
1. Verify REA sẵn sàng (MCP hoặc CLI `rea doctor`).
2. Phân tích TĨNH bằng REA (read-only):
   a. Extract/inspect resources.pak → tìm JS của "text selection toolbar" (thanh công cụ chọn văn bản), chuỗi kỹ năng ("Dịch", "Tóm tắt", "Giải thích", "Hỏi Dola", "AI Tìm kiếm" hoặc bản English), endpoint API, hostname backend.
   b. Tìm web bundle / JS app của chat sidebar nếu nằm trong bundle.
   c. Nếu cần: inspect libaha_cua.dylib, AgentInfraService.xpc.
3. Xác định nơi Dola lưu session/auth trên máy: profile dir dưới ~/Library/Application Support/ (tìm của Cici/Dola), cookies DB, localStorage, mục Keychain liên quan (CHỈ LIỆT KÊ tên/metadata — không dump giá trị secret ra file).
4. Nếu tìm được endpoint + auth: thử replay bằng curl một request "dịch đoạn văn mẫu ngắn" dùng session hiện có trên máy (KHÔNG tạo tài khoản, KHÔNG gửi đi bất kỳ mật khẩu nào, KHÔNG ghi secret vào file notes).
5. GHI KẾT QUẢ vào /Users/hiep/Documents/12_translator/docs/notes/phase0-findings.md gồm: endpoint(s) + method + request/response format, cơ chế auth (loại token/cookie, header), đường dẫn storage session, kết luận khả thi hay bế tắc + đã thử gì.
6. RÀNG BUỘC: tuyệt đối read-only với app Dola (không sửa file, không kill process); không làm thay đổi trạng thái tài khoản user; mọi phát hiện secret chỉ ghi "đã xác nhận tồn tại tại X" chứ không ghi giá trị.

# TIÊU CHÍ THÀNH CÔNG
Replay được ít nhất 1 call API AI của Dola từ terminal trả kết quả hợp lệ. Nếu bế tắc: báo cáo rõ ngõ cụ thể (vd: cert pinning + không tìm thấy endpoint trong pak) để session chính quyết định fallback.
```

## 6. Bước tiếp theo (theo thứ tự)

1. Đọc `docs/notes/phase0-findings.md` (kết quả từ session spike).
2. User **duyệt spec** (sửa nếu spike phát hiện điều gì thay đổi thiết kế — ví dụ API không stream được thì đổi cơ chế hiển thị).
3. Session chính (hoặc session mới) chạy skill **superpowers:writing-plans** để lập implementation plan chi tiết từ spec + findings.
4. Implement theo plan: Phase 1 = skeleton app Swift (SelectionWatcher + PopoverUI + DolaProvider stub) → Phase 2 = DolaProvider thật từ findings → Phase 3 = polish (onboarding quyền Accessibility, notification hết session).

## 7. Lưu ý an toàn

- Không dán mật khẩu/tokens vào chat hoặc ghi vào file trong repo.
- Tool mang tính cá nhân: dùng session của chính user, không chia sẻ binary kèm token.
- Read-only với app Dola; không phân phối lại tài sản của Dola.
