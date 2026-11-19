import Foundation
import ServiceManagement

enum LaunchAtLoginState: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
}

enum LaunchAtLoginError: LocalizedError, Equatable {
    case requiresApproval
    case operationFailed

    var errorDescription: String? {
        switch self {
        case .requiresApproval:
            return "macOS cần bạn xác nhận trong Cài đặt hệ thống → Cài đặt chung → Mục đăng nhập."
        case .operationFailed:
            return "Không thể thay đổi mục khởi động cùng macOS. Hãy chạy Dola Lite từ thư mục /Applications."
        }
    }
}

@MainActor
protocol LaunchAtLoginControlling: AnyObject {
    var state: LaunchAtLoginState { get }
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

extension LaunchAtLoginControlling {
    var isEnabled: Bool { state == .enabled }
}

@MainActor
final class SystemLaunchAtLoginController: LaunchAtLoginControlling {
    var state: LaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if state == .enabled { return }
            if state == .requiresApproval {
                throw LaunchAtLoginError.requiresApproval
            }
            do {
                try SMAppService.mainApp.register()
            } catch {
                if state == .requiresApproval {
                    throw LaunchAtLoginError.requiresApproval
                }
                throw LaunchAtLoginError.operationFailed
            }
            if state == .requiresApproval {
                throw LaunchAtLoginError.requiresApproval
            }
        } else {
            if state == .disabled || state == .unavailable { return }
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                throw LaunchAtLoginError.operationFailed
            }
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
