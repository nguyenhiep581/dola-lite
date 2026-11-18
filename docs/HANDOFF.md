# HANDOFF — Dola Lite

- Cập nhật ngày 2026-11-18
- Bản tải xuống: `DolaLite-macOS.zip` (ad-hoc signed; đã thử unzip, kiểm tra chữ ký bundle và chạy `--help`).
- Worktree: `.worktrees/dola-lite-v1` (branch `dola-lite-v1`)
- Trạng thái: app native đã build; unit/integration tests pass. **Đã xác minh end-to-end thành công với server thật** (translate + summarize qua probe, 2026-11-18 tối). Còn manual Accessibility/UI matrix.

## Mục tiêu hiện tại

App macOS menu-bar tái tạo thanh chọn văn bản của Dola bằng UI AppKit tự viết, chỉ gồm **Dịch / Tóm tắt / Giải thích**. Không gọi Dola và không tái sử dụng browser/session của Dola. AI dùng OpenAI-compatible chat completions với cấu hình riêng trong app.

## Cấu hình API

- Mặc định Base URL: `https://api.xingchiapi.com/v1`
- Mặc định model: `gpt-6.1-sol`
- API key: lưu riêng trong macOS Keychain (item `com.hiep.dolalite.api`), không nằm trong UserDefaults hay bundle.
- **Không đọc bất kỳ dữ liệu nào của Dola/DSH.** Cơ chế import `XINGCHI_API_KEY` từ `~/.dsh/.credentials.yaml` đã bị xóa hẳn (2026-11-18, theo yêu cầu tách hoàn toàn khỏi Dola); dependency Yams đi kèm cũng đã bỏ. Người dùng tự nhập API key trong cửa sổ **Cài đặt API…** (lần đầu chạy, app tự mở cửa sổ này khi chưa có key).
- Cửa sổ **Cài đặt API…** cho sửa Base URL/model/key và mức reasoning của Tóm tắt/Giải thích. Dịch luôn gửi `reasoning_effort=low`.

## Trạng thái triển khai

- SelectionWatcher dùng Accessibility API, lọc text và debounce 300 ms; pill/result là NSPanel không kích hoạt app nguồn.
- Result hỗ trợ stream, markdown cơ bản, Copy, Retry, Escape/click ngoài, đổi selection và placement nhiều màn hình.
- Xingchi provider dùng URLSession streaming, parser SSE incremental và hủy network task khi đóng/yêu cầu mới.
- **Wire API = `responses`** (2026-11-18): relay Xingchi chặn hẳn `POST /chat/completions` cho mọi client (403 `client_not_allowed` — "site chỉ cho phép client lập trình") và chỉ mở `POST /responses` với **User-Agent thuộc danh sách client được phép** (Codex, Claude Code, Cursor…). App gọi `/responses` với `User-Agent: codex_cli_rs/0.42.0` (constant `APIRequestBuilder.allowedClientUserAgent`), body `{model, stream, instructions, input, reasoning:{effort}}`, parse SSE event `response.output_text.delta` / terminal `response.completed` / `response.incomplete` (max_output_tokens → truncated) / `response.failed`. Khớp `wire_api = "responses"` trong config DSH của user.
- Probe thật 2026-11-18: translate ("Good morning…" → "Chào buổi sáng. Chúc bạn một ngày tốt lành!") và summarize đều thành công; first_chunk 13–15 s do reasoning phía server trên `gpt-6.1-sol` — relay chậm, không phải lỗi app.
- `swift test` chạy thành công 37 test, gồm cả ba kỹ năng qua URLSession với phản hồi SSE giả và kiểm tra hủy request thực sự dừng tải. Test Settings dùng `UserDefaults` in-memory (không chạm cfprefsd), hết hẳn rác `DolaLite.SettingsTests.*.plist` trong `~/Library/Preferences`.
- Release build và `codesign --verify --strict DolaLite.app` đã pass.
- Án mystery 403 cũ đã đóng: `POST /chat/completions` bị relay chặn vĩnh viễn cho mọi client; không phải lỗi credential/model. API key đã được lưu sẵn trong keychain (item `com.hiep.dolalite.api`) từ lần verify 2026-11-18 — mở app lên là dùng được ngay; muốn đổi key thì dùng nút "Xóa API key" trong Cài đặt rồi nhập key mới.
- Preview PNG của pill/result đã render ở `/tmp/dolalite-ui-preview`; không thể đánh giá trực quan trong phiên này do model không hỗ trợ ảnh.
- Chưa cấp/xác minh quyền Accessibility và chưa chạy manual app matrix. Người dùng cần bật quyền cho `DolaLite.app` trong System Settings → Privacy & Security → Accessibility; sau đó dùng menu **Kiểm tra quyền Trợ năng…**.

## Chạy và build

Từ worktree `.worktrees/dola-lite-v1`:

```sh
swift test
bash scripts/make-app.sh
open DolaLite.app
```

Probe provider (gửi nội dung thật tới endpoint đã cấu hình, có thể tính phí):

```sh
./DolaLite.app/Contents/MacOS/DolaLite --probe "Good morning." --skill translate
```

Có thể chọn `summarize` hoặc `explain`. Kết quả probe in theo từng chunk; stderr hiển thị model, skill, effort và latency, không in API key.

## Tài liệu

- Thiết kế hiện hành: `docs/superpowers/specs/2026-11-14-dola-lite-selection-assistant-design.md`
- Kế hoạch Xingchi: `docs/superpowers/plans/2026-11-15-xingchi-native-v1.md`
- Thử nghiệm Dola cũ được lưu trong `Archive/DolaBrowserSpike/`; ghi nhận gốc ở `docs/notes/phase0-findings.md` và `docs/notes/2026-11-15-cdp-input-investigation.md` chỉ có giá trị lịch sử, không phải runtime hiện hành.

## Việc còn lại

1. Xác minh thủ công selection/pill/result, cấp Accessibility, các hành vi dismiss/copy/retry, light/dark và màn hình phụ.
2. (Tùy chọn) Nếu đổi UA `codex_cli_rs` bị relay chặn trong tương lai, đổi constant `APIRequestBuilder.allowedClientUserAgent` sang client khác trong danh sách được phép.
