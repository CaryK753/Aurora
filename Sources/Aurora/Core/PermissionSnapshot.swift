import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import IOKit.hid

struct PermissionSnapshot: Codable {
    enum Disk: String, Codable { case granted, denied, unknown }
    let accessibility: Bool
    let screenRecording: Bool
    let inputMonitoring: Bool
    let disk: Disk
    var accessibilityAPI: Bool? = nil
    var eventPosting: Bool? = nil
    var accessibilityOperation: Bool? = nil

    static func capture() -> PermissionSnapshot {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let ax = AXIsProcessTrustedWithOptions([prompt: false] as CFDictionary)
        let posting = CGPreflightPostEventAccess()
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &focused)
        let operation = result == .success
        return PermissionSnapshot(
            accessibility: ax || operation,
            screenRecording: CGPreflightScreenCaptureAccess(),
            inputMonitoring: CGPreflightListenEventAccess(),
            disk: diskAccess(), accessibilityAPI: ax, eventPosting: posting, accessibilityOperation: operation
        )
    }

    /// 仅验证受保护文件能否读取，不解析权限数据库，也不把不存在当作拒绝。
    static func diskAccess(paths: [String] = [NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
                                            "/Library/Application Support/com.apple.TCC/TCC.db"]) -> Disk {
        var denied = false
        for path in paths {
            let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else {
                if errno == EACCES || errno == EPERM { denied = true }
                continue
            }
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            let error = errno
            close(fd)
            if count >= 0 { return .granted }
            if error == EACCES || error == EPERM { denied = true }
        }
        return denied ? .denied : .unknown
    }
}

enum PermissionStatus: Equatable {
    case granted, denied, unknown, restartRequired
    var isGranted: Bool { self == .granted }
    var title: String {
        switch self {
        case .granted: return T("已授权")
        case .denied: return T("未授权")
        case .unknown: return T("无法确认")
        case .restartRequired: return T("重启生效")
        }
    }

    static func resolve(current: Bool, fresh: Bool?) -> PermissionStatus {
        guard let fresh else { return current ? .granted : .denied }
        if !fresh { return .denied }
        return current ? .granted : .restartRequired
    }
}
