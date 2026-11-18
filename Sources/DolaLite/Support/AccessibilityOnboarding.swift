import AppKit
import ApplicationServices

@MainActor
enum AccessibilityOnboarding {
    private static var shownThisLaunch = false
    static func isGranted() -> Bool { AXIsProcessTrusted() }

    static func showPromptIfNeeded() {
        guard !isGranted(), !shownThisLaunch else { return }
        shownThisLaunch = true
        let alert = NSAlert()
        alert.messageText = "Cho phép Dola Lite đọc văn bản được chọn"
        alert.informativeText = "Bật Dola Lite trong System Settings → Privacy & Security → Accessibility để dùng Dịch, Tóm tắt và Giải thích. Sau khi cấp quyền, chọn Kiểm tra quyền Trợ năng trong menu Dola Lite."
        alert.addButton(withTitle: "Mở System Settings")
        alert.addButton(withTitle: "Để sau")
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
