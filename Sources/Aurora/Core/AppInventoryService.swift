//  AppInventoryService.swift
//  Aurora — 应用管理：列出已装应用、估体积、找残留、卸载到废纸篓
//
//  思路参考 Pearcleaner / PureMac 的做法，但代码自己写：
//  · 残留按 bundle id 的路径边界匹配。显示名只在缓存类目录里作参考，且默认不勾选。
//  · 卸载 = 应用本体 + 勾选的残留一起进废纸篓，随时可以放回
//  · Apple 自带应用（com.apple.*）与系统目录一律拒绝

import AppKit
import Combine

struct InstalledApp: Identifiable {
    let id: String
    let name: String
    let bundleID: String
    let version: String
    let path: String
    var bytes: Int64 = 0
    var measured = false
    var lastUsed: Date?
    var isRunning = false
}

struct AppLeftover: Identifiable {
    let id: String
    let path: String
    let category: String
    let bytes: Int64
    var selected = true
}

@MainActor
final class AppInventoryService: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var isScanning = false
    @Published private(set) var progress = ""
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var lastScan: Date?

    private let home = FileManager.default.homeDirectoryForCurrentUser

    func scanIfNeeded() {
        guard lastScan == nil, !isScanning else { return }
        Task { await scan() }
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        message = nil
        progress = T("正在读取应用列表…")
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        apps = await Task.detached(priority: .userInitiated) { Self.list() }.value
            .map { app in
                var copy = app
                copy.isRunning = running.contains(app.path)
                return copy
            }

        for index in apps.indices {
            progress = TF("正在统计 %d / %d", index + 1, apps.count)
            let path = apps[index].path
            let size = await Task.detached(priority: .utility) { Self.size(of: path) }.value
            apps[index].bytes = size
            apps[index].measured = true
        }
        progress = ""
        apps.sort { $0.bytes > $1.bytes }
        lastScan = Date()
    }

    // MARK: - 残留

    func leftovers(for app: InstalledApp) async -> [AppLeftover] {
        await Task.detached(priority: .userInitiated) {
            Self.findLeftovers(bundleID: app.bundleID, name: app.name, home: FileManager.default.homeDirectoryForCurrentUser)
        }.value
    }

    private nonisolated static let leftoverDirectories: [(String, String, Bool)] = [
        ("Library/Caches", "缓存", true),
        ("Library/Preferences", "偏好", false),
        ("Library/Application Support", "支持文件", true),
        ("Library/Saved Application State", "窗口状态", true),
        ("Library/HTTPStorages", "网络缓存", true),
        ("Library/WebKit", "网页数据", true),
        ("Library/Logs", "日志", true),
        ("Library/LaunchAgents", "登录项", false),
        ("Library/Containers", "沙盒容器", false),
        ("Library/Group Containers", "共享容器", false),
        ("Library/Application Scripts", "脚本", false)
    ]

    private nonisolated static func findLeftovers(bundleID: String, name: String, home: URL) -> [AppLeftover] {
        let fm = FileManager.default
        var found: [AppLeftover] = []
        for (relative, label, allowsName) in leftoverDirectories {
            let directory = home.appendingPathComponent(relative)
            guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                            includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles]) else { continue }
            for entry in entries {
                guard let kind = LeftoverMatcher.kind(
                    candidate: entry.lastPathComponent,
                    bundleID: bundleID,
                    displayName: name,
                    allowsName: allowsName
                ) else { continue }
                found.append(AppLeftover(
                    id: entry.path,
                    path: entry.path,
                    category: label,
                    bytes: size(of: entry.path),
                    // 只按 bundle id 命中的默认勾上。同名目录要用户自己点，避免 Code / Google 这类名字带走别的应用的数据。
                    selected: kind == .bundle
                ))
            }
        }
        return found.sorted { $0.bytes > $1.bytes }
    }

    // MARK: - 卸载

    /// 返回 nil 表示成功；否则是失败原因
    func uninstall(app: InstalledApp, leftovers: [AppLeftover]) async -> String? {
        guard !isBusy else { return T("正在处理另一个应用") }
        guard isUninstallable(app) else { return T("这是系统应用，Aurora 不会动它") }
        isBusy = true
        defer { isBusy = false }

        if app.isRunning {
            if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == app.path }) {
                running.terminate()
                try? await Task.sleep(nanoseconds: 900_000_000)
                if running.isTerminated == false {
                    return T("应用还在运行，请先退出")
                }
            }
        }

        var failed: [String] = []
        var removed: Int64 = 0
        for item in leftovers where item.selected {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                removed += item.bytes
            } catch {
                failed.append((item.path as NSString).lastPathComponent)
            }
        }

        let appURL = URL(fileURLWithPath: app.path)
        do {
            try FileManager.default.trashItem(at: appURL, resultingItemURL: nil)
        } catch {
            message = TF("无法移动 %@：%@", app.name, error.localizedDescription)
            return message
        }

        apps.removeAll { $0.id == app.id }
        let total = removed + app.bytes
        message = failed.isEmpty
            ? TF("已卸载 %@，回收 %@（都在废纸篓里）", app.name, Fmt.bytes(UInt64(total)))
            : TF("已卸载 %@，但 %d 个残留没能移动", app.name, failed.count)
        return nil
    }

    func isUninstallable(_ app: InstalledApp) -> Bool {
        app.bundleID.hasPrefix("com.apple.") == false && app.path.hasPrefix("/System") == false
    }

    // MARK: - 扫描辅助

    private nonisolated static func list() -> [InstalledApp] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var apps: [InstalledApp] = []
        for directory in ["/Applications", home.appendingPathComponent("Applications").path] {
            let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: directory),
                                                       includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])) ?? []
            for entry in entries where entry.pathExtension == "app" {
                guard let info = NSDictionary(contentsOf: entry.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else { continue }
                let bundleID = info["CFBundleIdentifier"] as? String ?? ""
                let name = (info["CFBundleDisplayName"] as? String)
                    ?? (info["CFBundleName"] as? String)
                    ?? entry.deletingPathExtension().lastPathComponent
                let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? "—"
                apps.append(InstalledApp(
                    id: entry.path,
                    name: name,
                    bundleID: bundleID,
                    version: version,
                    path: entry.path,
                    lastUsed: lastUsed(at: entry.path)
                ))
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func lastUsed(at path: String) -> Date? {
        guard let mdls = CommandRunner.locate("mdls") else { return nil }
        let result = CommandRunner.runSync(mdls, ["-name", "kMDItemLastUsedDate", "-raw", path], timeout: 8)
        guard result.ok else { return nil }
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != "(null)" else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: text)
    }

    private nonisolated static func size(of path: String) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let du = CommandRunner.locate("du") else { return 0 }
        let result = CommandRunner.runSync(du, ["-skx", path], timeout: 25)
        guard let last = result.output.split(separator: "\n").last,
              let kilobytes = Int64(last.split(separator: "\t").first ?? "") else { return 0 }
        return kilobytes * 1024
    }
}

enum LeftoverMatchKind: Equatable {
    case bundle
    case name
}

/// 残留文件名怎么对上一个应用。bundle id 要按路径组件对齐，不能用子串。
enum LeftoverMatcher {
    /// 至少 `com.company.app` 这种三段名字，避免 `mail`、`com.microsoft` 扫到一串无关目录。
    static func kind(candidate: String, bundleID: String, displayName: String, allowsName: Bool) -> LeftoverMatchKind? {
        if bundleMatch(candidate: candidate, bundleID: bundleID) { return .bundle }
        if allowsName, nameMatch(candidate: candidate, displayName: displayName) { return .name }
        return nil
    }

    static func bundleMatch(candidate: String, bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        guard id.split(separator: ".").count >= 3 else { return false }
        let base = stem(candidate)
        if base == id { return true }
        if base.hasPrefix(id + ".") || base.hasPrefix(id + "-") { return true }
        let group = "group." + id
        if base == group || base.hasPrefix(group + ".") { return true }
        return false
    }

    static func nameMatch(candidate: String, displayName: String) -> Bool {
        let normalized = normalize(displayName)
        guard normalized.count >= 8, !deniedNames.contains(normalized) else { return false }
        return normalize(stem(candidate)) == normalized
    }

    private static func stem(_ candidate: String) -> String {
        let lower = candidate.lowercased()
        if lower.hasSuffix(".plist") { return String(lower.dropLast(".plist".count)) }
        return lower
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    /// 这些名字会撞上别的应用整份资料（配置、登录状态、缓存）。
    private static let deniedNames: Set<String> = [
        "google", "microsoft", "mozilla", "firefox", "chrome", "chromium", "slack", "docker",
        "adobe", "dropbox", "spotify", "zoom", "notion", "discord", "jetbrains", "android",
        "python", "office", "onedrive", "wechat", "telegram", "whatsapp", "figma", "electron",
        "github", "cursor", "obsidian", "steam", "visualstudiocode", "vscode"
    ]
}
