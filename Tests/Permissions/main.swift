import Foundation

func T(_ text: String) -> String { text }
func check(_ name: String, _ value: @autoclosure () -> Bool) {
    precondition(value(), name)
    print("✓ \(name)")
}
check("当前进程与系统均授权", PermissionStatus.resolve(current: true, fresh: true) == .granted)
check("系统已允许但当前进程未生效", PermissionStatus.resolve(current: false, fresh: true) == .restartRequired)
check("系统撤销后不沿用进程旧缓存", PermissionStatus.resolve(current: true, fresh: false) == .denied)
check("尚未授权不显示重启可解决", PermissionStatus.resolve(current: false, fresh: false) == .denied)
check("无新进程结果时保留本地检测", PermissionStatus.resolve(current: true, fresh: nil) == .granted)
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let missing = folder.appendingPathComponent("missing.db").path
let readable = folder.appendingPathComponent("readable.db")
try Data([1]).write(to: readable)
check("路径不存在属于无法确认，不能误报拒绝", PermissionSnapshot.diskAccess(paths: [missing]) == .unknown)
check("新系统路径可读取时不被旧路径缺失干扰", PermissionSnapshot.diskAccess(paths: [missing, readable.path]) == .granted)
let snapshot = PermissionSnapshot(accessibility: true, screenRecording: false, inputMonitoring: true, disk: .unknown)
let data = try JSONEncoder().encode(snapshot)
let decoded = try JSONDecoder().decode(PermissionSnapshot.self, from: data)
check("探针结构完整传回三项系统权限及磁盘状态", decoded.accessibility && !decoded.screenRecording && decoded.inputMonitoring && decoded.disk == .unknown)
