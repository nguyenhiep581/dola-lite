# Dola Lite — Trợ lý chọn text nhẹ cho macOS (Design Doc)

- **Ngày:** 2026-11-14
- **Trạng thái:** Đã duyệt bởi user
- **Thư mục dự án:** `/Users/hiep/Documents/12_translator`

## 1. Bối cảnh & Mục tiêu

**Dola Browser** trên máy user là Chromium fork v147 nhúng trong `Cici.app` (`com.bot.pc.cici` v2.36.8, ByteDance). Tính năng "Thanh công cụ chọn văn bản" (Dịch / Tóm tắt / Giải thích) rất hữu dụng nhưng phải mở nguyên một trình duyệt nặng.

**Mục tiêu:** App macOS native nhẹ tái tạo đúng 1 tính năng đó — popover tự xuất hiện khi chọn text ở bất kỳ app nào — và **dùng luôn AI backend của Dola** với tài khoản/phiên đăng nhập hiện tại của user. Không cần mở Dola Browser.

**Không phải mục tiêu (v1):** Hỏi Dola, AI Tìm kiếm, tuỳ biến kéo thả kỹ năng, tự update, phân phối App Store.

## 2. Quyết định đã chốt cùng user

| Quyết định | Lựa chọn |
|---|---|
| Trigger popover | Tự động khi chọn text (giống Dola), cần quyền Accessibility |
| Kỹ năng v1 | Chỉ 3: Dịch, Tóm tắt, Giải thích |
| Hiển thị kết quả | Popover nhỏ cạnh đoạn text, stream realtime |
| Nguồn AI | Hướng A — reverse engineer API Dola + tái sử dụng phiên đăng nhập; fallback Hướng C (provider khác) chỉ khi spike bế tắc, user quyết định |

## 3. Kiến trúc

App **Swift/AppKit dạng menu-bar** (`LSUIElement = true`, không icon Dock). Ba thành phần độc lập, giao tiếp qua interface rõ ràng:

```
┌────────────────────────────────────────────────┐
│ Dola Lite (menu-bar app)                       │
│                                                │
│  SelectionWatcher ──selection──▶ PopoverUI     │
│        (AX API)                  │ skill click │
│                                  ▼             │
│                            DolaProvider ──────▶ API Dola (qua mạng)
│                            (AIProvider)        (session từ profile Dola)
└────────────────────────────────────────────────┘
```

### 3.1 SelectionWatcher
- Phát hiện text được chọn hệ thống-wide + hình chữ nhật bao (để đặt pill).
- Cơ chế: Accessibility API — `AXUIElementCopyAttributeValue` với `AXSelectedText` / `AXSelectedTextRange` / bounds; poll có debounce ~300ms trên app foreground (`NSWorkspace.frontmostApplication`).
- Nếu app không cung cấp bounds (một số PDF viewer, Terminal) → fallback: hiển thị cạnh vị trí con trỏ chuột (`NSEvent.mouseLocation` / CGEvent tap).
- Lọc: bỏ qua selection của chính Dola Lite; bỏ qua text rỗng/quá ngắn (<2 ký tự) và quá dài (>~10.000 ký tự — cắt).

### 3.2 PopoverUI
- **Pill (thanh công cụ):** `NSPanel` non-activating (`.nonactivatingPanel`), 3 nút icon+label tiếng Việt: Dịch / Tóm tắt / Giải thích. Xuất hiện cạnh/vừa trên selection.
- **Result popover:** mở ngay khi bấm kỹ năng, `NSTextView` streaming (hỗ trợ markdown cơ bản: bold, code, list), nút Copy, nút Đóng; Esc / click ngoài / đổi selection → đóng.
- Không steal focus khỏi app đang dùng.

### 3.3 DolaProvider (adapter)
- Implement protocol `AIProvider`:
  ```swift
  protocol AIProvider {
      func stream(skill: Skill, text: String) -> AsyncThrowingStream<String, Error>
  }
  enum Skill { case translate, summarize, explain }
  ```
- `translate` dùng ngôn ngữ đích = tiếng Việt (constant `Config.targetLanguage`, auto-detect nguồn).
- Nhờ layer này, khi Dola đổi API (hoặc fallback provider khác) chỉ thay `DolaProvider`, phần còn lại không đổi.

## 4. Phase 0 — Feasibility spike (bắt buộc trước khi build app)

**Mục tiêu:** chứng minh gọi được API Dola từ terminal trước khi viết app.

1. **Chụp API:** khi user bấm Dịch/Tóm tắt/Giải thích trong Dola, bắt traffic:
   - Cách 1: bật remote debugging của Chromium fork (thử env/flag, đọc traffic qua DevTools protocol).
   - Cách 2: mitmproxy + cài cert (rủi ro certificate pinning).
   - Cách 3 (nếu 1-2 fail): **phân tích tĩnh JS bundle của app bằng REA** (`rea analyze-javascript-application`) để tìm endpoint + format request.
2. **Trích auth:** xác định nơi lưu session của Dola (profile Chromium dưới `~/Library/Application Support/`, cookies DB có thể mã hoá bằng Keychain "Chromium Safe Storage" — cần app của chúng ta được cấp quyền đọc key đó).
3. **Tiêu chí thành công:** lệnh `curl` (hoặc script) gọi "Dịch đoạn văn mẫu" trả về kết quả đúng bằng session của user.

**Điều kiện dừng:** nếu cả 3 cách đều bế tắc → báo cáo user, đề xuất Hướng C (API key provider khác với giao diện y hệt). Không build mò khi chưa có spike pass.

## 5. Xử lý lỗi

| Tình huống | Hành vi |
|---|---|
| 401 / session hết hạn | Notification: "Mở Dola Browser đăng nhập lại" → app theo dõi file session, tự đọc lại khi có session mới |
| Lỗi mạng / timeout | Popover hiện thông báo + nút Thử lại |
| Rate limit / quota | Hiện thông điệp từ API (nếu parse được) |
| Thiếu quyền Accessibility | Màn hình onboarding 1 nút mở System Settings → Privacy → Accessibility |
| App không cho đọc selection | Pill không hiện (im lặng) — không spam lỗi |

**Bảo mật:** app không lưu mật khẩu/token riêng; chỉ đọc session Dola đã có trên máy. Toàn bộ traffic đi thẳng tới API Dola, không qua bên thứ ba. Công cụ mang tính cá nhân — không phân phối dùng chung token.

## 6. Kiểm thử

- **Spike:** curl replay thành công = điều kiện cần để tiếp tục Phase 1.
- **Unit test:** `DolaProvider` (mock SSE server), parsing response, debounce logic của SelectionWatcher.
- **Manual matrix (SelectionWatcher + popover):** Safari, Chrome, Notes, Preview (PDF), VS Code, Terminal, Word/Pages; tiếng Việt ↔ Anh, CJK; đoạn dài 10.000 ký tự; text có emoji/code.
- **Regression:** đóng/mở nhanh liên tiếp, đổi app liên tục, hai màn hình.

## 7. Kế hoạch phân phối

- Build local, code sign ad-hoc; chạy trực tiếp trên máy user (ngoài App Store do dùng session app khác).
- Cấu trúc project: Swift Package executable + AppKit (không cần Xcode project nếu dùng `swift build`; sẽ tạo `.app` bundle bằng script).

## 8. Rủi ro đã biết

| Rủi ro | Giảm thiểu |
|---|---|
| API Dola là private, đổi bất kỳ lúc nào | Lớp adapter `AIProvider` cô lập thay đổi; document format đã reverse trong `docs/notes/` |
| Certificate pinning chặn bắt traffic | Có sẵn phương án REA phân tích tĩnh |
| Session cookie bị expire định kỳ | Cơ chế re-read + notification hướng dẫn đăng nhập lại |
| ToS (dùng API ngoài client chính thức) | Phạm vi cá nhân, tài khoản của user, không chia sẻ tool |
| Accessibility API không đọc được selection trong vài app | Fallback hiển thị cạnh chuột; danh sách app đã test trong docs |
