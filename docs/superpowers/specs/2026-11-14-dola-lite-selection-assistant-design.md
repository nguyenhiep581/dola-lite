# Dola Lite — Selection Assistant Design

- Cập nhật: 2026-11-15
- Trạng thái: Thiết kế đã điều chỉnh theo yêu cầu mới

## 1. Mục tiêu

App menu-bar macOS nhẹ tái tạo bằng AppKit phần UI chọn văn bản của Dola: tự hiện pill cạnh selection với ba kỹ năng **Dịch / Tóm tắt / Giải thích**, rồi hiển thị câu trả lời streaming trong result panel. Chỉ học theo bố cục/hành vi; không dùng Dola assets, API riêng tư, session, cookies, profile hay browser.

## 2. Kiến trúc

```text
SelectionWatcher (Accessibility API)
    → PillPanel / ResultPanel (AppKit NSPanel)
    → PanelCoordinator (request ownership, dismissal, cancellation)
    → AIProvider
    → OpenAI-compatible Chat Completions (Xingchi mặc định)
```

`OpenAIProvider` sử dụng `URLSession` native và incremental SSE parser. App không cần DSH hoạt động sau lần import credential đầu tiên.

## 3. Cấu hình API trong app

- Base URL mặc định: `https://api.xingchiapi.com/v1`.
- Model mặc định: `gpt-6.1-sol`.
- API key trong macOS Keychain; không lưu trong preferences hoặc app bundle.
- Lần khởi tạo đầu, thử import reference `XINGCHI_API_KEY` từ DSH credential file `~/.dsh/.credentials.yaml` (hỗ trợ `$DSH_HOME`) hoặc environment fallback. Chỉ đọc reference này, không log giá trị. Kết quả import một lần; app settings sau đó độc lập với DSH.
- Cửa sổ **Cài đặt API…** cho phép sửa Base URL/model/key và mức reasoning Tóm tắt/Giải thích. Kiểm tra kết nối là hành động chủ động gửi request nhỏ.
- Dịch luôn đặt `reasoning_effort: low` để ưu tiên tốc độ; Tóm tắt/Giải thích dùng mức đã chọn trong app, mặc định `high`.
- Lưu cấu hình kiểm tra Base URL HTTP(S), model, effort và key; key chỉ ghi vào Keychain. Mỗi request capture một snapshot để thay đổi mới áp dụng cho request tiếp theo.

## 4. Selection và UI

- Accessibility watcher đọc selection của app foreground, bỏ qua app của chính mình/trường nhập bảo mật, giới hạn 2–10.000 Unicode graphemes và debounce ổn định 300 ms.
- Pill là capsule 3 nút icon/nhãn tiếng Việt; Result panel có tên kỹ năng, nội dung streaming, Copy, Retry, Close và markdown cơ bản.
- Panel không kích hoạt app nguồn. Click ngoài, Escape, đổi/mất selection và đóng panel hủy request hiện hành. Request generation chặn response cũ cập nhật panel mới.
- Bounds thiếu thì đặt gần chuột. Placement xét màn hình chứa selection, gồm màn hình phụ có tọa độ âm.
- Cần Accessibility permission; onboarding mở System Settings. Không đọc được selection thì bỏ qua im lặng.

## 5. Provider và lỗi

- `POST {baseURL}/chat/completions`, Bearer auth, `stream: true`, model và system/user messages.
- Chỉ render `choices[0].delta.content`; reasoning/role/usage không hiển thị. Parser xử lý chia chunk UTF-8, SSE comments/multiline/CRLF, terminal sentinel, stream lỗi/cắt ngang và giới hạn bộ đệm.
- Timeout, mạng, 401/403/429/5xx, phản hồi rỗng/cắt ngang hiển thị thông báo tiếng Việt an toàn. Không echo server body hoặc credential. Không retry tự động sau khi đã nhận nội dung; nút Retry tạo request mới.
- Người dùng tự cấu hình endpoint và API key; chưa cam kết provider nào cấp quyền cho mọi model.

## 6. Kiểm thử và kiểm chứng

Unit tests bao phủ settings/import/keychain abstraction, request builder, SSE, HTTP status, cancellation, selection debounce, panel placement và request generation. `swift test` chạy thành công 47 test, gồm cả ba kỹ năng qua URLSession với phản hồi SSE giả. `scripts/make-app.sh` tạo release `.app` ad-hoc signed; lệnh `codesign --verify --strict` đã pass.

Key hiện tại truy vấn `GET /v1/models` thành công và endpoint liệt kê `gpt-6.1-sol`, nhưng metadata model không nêu quyền completion. Probe thật tới `POST /v1/chat/completions` với `reasoning_effort=low` nhận HTTP 403 từ app lẫn HTTP trực tiếp. Vì vậy chưa xác nhận thành công end-to-end; cần hỏi Xingchi lý do từ chối hoặc yêu cầu client/protocol nào. Manual Accessibility/UI matrix cũng còn cần chạy sau khi cấp quyền macOS.

## 7. Ranh giới sản phẩm

Không bao gồm hỏi chuyện tổng quát, search, Dola private API, scraping cookie/session, Dola Browser automation hay phân phối App Store. UI là mã AppKit tự viết, không sao chép tài sản nhị phân của Dola.
