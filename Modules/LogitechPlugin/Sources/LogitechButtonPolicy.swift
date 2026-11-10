import Foundation

/// 蓝牙直连的标准按钮保留原生事件；接收器与特殊按钮使用 HID++。
public enum LogitechButtonPolicy {
    public static func nativeButton(cid: UInt16, transport: String) -> Int? {
        guard transport.localizedCaseInsensitiveContains("bluetooth") else { return nil }
        switch cid {
        case 0x52: return 2
        case 0x53: return 3
        case 0x56: return 4
        default: return nil
        }
    }
}
