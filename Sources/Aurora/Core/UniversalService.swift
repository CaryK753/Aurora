//  UniversalService.swift
//  Aurora — 通用二进制：找出同时带 Intel 与 Apple Silicon 两份的 App
//
//  Apple Silicon 上用不到 x86_64 那一份。这里只报告体积，瘦身需要用户明确点一次：
//  `lipo -thin` 会把代码签名弄坏，随后用 ad-hoc 重签；App Store 应用与沙盒应用一律跳过。

import AppKit
import Combine

struct UniversalApp: Identifiable {
    let id: String            // bundle 路径
    let name: String
    let path: String
    /// 可以回收的字节数（Intel 那一片）
    let wasted: Int64
    /// 需要瘦身的可执行文件（主程序 + 内嵌框架）
    let binaries: [String]
    var isRunning = false
    /// 不能瘦身的原因；nil 表示可以
    var blockReason: String?
    /// 可以瘦身但要提醒的副作用（例如可能丢失钥匙串授权）
    var caution: String?
}

@MainActor
final class UniversalService: ObservableObject {
    @Published private(set) var apps: [UniversalApp] = []
    @Published private(set) var isScanning = false
    @Published private(set) var thinningID: String?
    @Published private(set) var message: String?
    @Published private(set) var lastScan: Date?
    /// 勾选的应用（可批量瘦身）
    @Published var selection: Set<String> = []
    /// 批量瘦身进度：done / total，nil 表示没在批量处理
    @Published private(set) var batchDone: Int?
    @Published private(set) var batchTotal = 0

    private let home = FileManager.default.homeDirectoryForCurrentUser

    var totalWasted: Int64 { apps.reduce(0) { $0 + $1.wasted } }
    var thinableApps: [UniversalApp] { apps.filter { $0.blockReason == nil && !$0.isRunning } }
    var thinableBytes: Int64 { thinableApps.reduce(0) { $0 + $1.wasted } }

    /// 当前能勾选的应用（在运行 / 被系统限制的不算）
    var selectableApps: [UniversalApp] { apps.filter { $0.blockReason == nil } }
    var selectedApps: [UniversalApp] { apps.filter { selection.contains($0.id) && $0.blockReason == nil } }
    var selectedBytes: Int64 { selectedApps.reduce(0) { $0 + $1.wasted } }
    var allSelected: Bool {
        !selectableApps.isEmpty && selectableApps.allSatisfy { selection.contains($0.id) }
    }
    var isBatching: Bool { batchDone != nil }

    func toggleSelection(_ app: UniversalApp) {
        if selection.contains(app.id) { selection.remove(app.id) } else { selection.insert(app.id) }
    }

    func toggleSelectAll() {
        if allSelected {
            selection.removeAll()
        } else {
            selection = Set(selectableApps.map(\.id))
        }
    }

    func scanIfNeeded() {
        guard lastScan == nil, !isScanning else { return }
        Task { await scan() }
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        message = nil
        apps = []
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        let found = await Task.detached(priority: .userInitiated) {
            Self.collect()
        }.value
        apps = found.map { app in
            var item = app
            item.isRunning = running.contains(app.path)
            return item
        }.sorted { lhs, rhs in
            // 能瘦身的排前面，其余的按体积排
            let left = lhs.blockReason == nil ? 0 : 1
            let right = rhs.blockReason == nil ? 0 : 1
            return left == right ? lhs.wasted > rhs.wasted : left < right
        }
        isScanning = false
        lastScan = Date()
        // 瘦身过的应用已经不在列表里，勾选状态跟着清掉
        let ids = Set(apps.map(\.id))
        selection = selection.filter { ids.contains($0) }
        message = apps.isEmpty ? T("没有发现同时带两种架构的应用") : nil
    }

    // MARK: - 瘦身

    /// 返回 nil 表示成功，否则是失败原因
    func thin(_ app: UniversalApp) async -> String? {
        guard thinningID == nil, !isBatching else { return T("正在处理另一个应用") }
        thinningID = app.id
        defer { thinningID = nil }

        let result = await Task.detached(priority: .userInitiated) {
            Self.performThinning(app)
        }.value

        switch result {
        case .success:
            apps.removeAll { $0.id == app.id }
            message = TF("%@ 已瘦身，回收 %@", app.name, Fmt.bytes(UInt64(app.wasted)))
            return nil
        case .failure(let reason):
            message = reason
            return reason
        }
    }

    private enum ThinResult {
        case success
        case failure(String)
    }

    struct ThinSummary {
        var thinned = 0
        var bytes: Int64 = 0
        var skipped: [String] = []
        var failures: [String] = []
    }

    /// 批量瘦身：按体积从大到小逐个处理，任何一个失败都不影响后面的
    @discardableResult
    func thinSelection() async -> ThinSummary {
        guard !isBatching, thinningID == nil else { return ThinSummary() }
        let targets = selectedApps.sorted { $0.wasted > $1.wasted }
        guard !targets.isEmpty else { return ThinSummary() }

        var summary = ThinSummary()
        batchTotal = targets.count
        batchDone = 0
        defer {
            batchDone = nil
            batchTotal = 0
            thinningID = nil
        }

        for app in targets {
            thinningID = app.id
            if app.isRunning {
                summary.skipped.append(app.name)
                batchDone = (batchDone ?? 0) + 1
                continue
            }
            let result = await Task.detached(priority: .userInitiated) {
                Self.performThinning(app)
            }.value
            switch result {
            case .success:
                apps.removeAll { $0.id == app.id }
                selection.remove(app.id)
                summary.thinned += 1
                summary.bytes += app.wasted
            case .failure(let reason):
                summary.failures.append("\(app.name)：\(reason)")
            }
            batchDone = (batchDone ?? 0) + 1
        }

        if summary.failures.isEmpty {
            message = summary.skipped.isEmpty
                ? TF("已瘦身 %d 个应用，回收 %@", summary.thinned, Fmt.bytes(UInt64(summary.bytes)))
                : TF("已瘦身 %d 个应用，回收 %@；%d 个正在运行已跳过",
                     summary.thinned, Fmt.bytes(UInt64(summary.bytes)), summary.skipped.count)
        } else {
            message = TF("已瘦身 %d 个，%d 个失败：%@",
                         summary.thinned, summary.failures.count, summary.failures.joined(separator: "、"))
        }
        return summary
    }

    private nonisolated static func performThinning(_ app: UniversalApp) -> ThinResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: app.path) else { return .failure(T("应用已经不在了")) }

        // 1) 先把原二进制留一份：任何一步失败都能原样换回去
        let backupRoot = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Aurora/Thinned", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        var backups: [(original: String, copy: String)] = []
        defer { try? fm.removeItem(at: backupRoot) }

        for (index, binary) in app.binaries.enumerated() {
            let copy = backupRoot.appendingPathComponent("\(index).bin").path
            guard (try? fm.copyItem(atPath: binary, toPath: copy)) != nil else {
                return .failure(TF("无法备份 %@", (binary as NSString).lastPathComponent))
            }
            backups.append((binary, copy))
        }

        // 2) 逐个头文件做 lipo -thin
        guard let lipo = CommandRunner.locate("lipo") else { return .failure(T("找不到 lipo")) }
        for binary in app.binaries {
            let staged = binary + ".aurora-thin"
            let result = CommandRunner.runSync(lipo, ["-thin", MachOBinary.arm64, "-output", staged, binary], timeout: 120)
            guard result.ok, fm.fileExists(atPath: staged) else {
                restore(backups)
                return .failure(TF("lipo 处理 %@ 失败", (binary as NSString).lastPathComponent))
            }
            guard (try? fm.removeItem(atPath: binary)) != nil,
                  (try? fm.moveItem(atPath: staged, toPath: binary)) != nil else {
                try? fm.removeItem(atPath: staged)
                restore(backups)
                return .failure(TF("替换 %@ 失败", (binary as NSString).lastPathComponent))
            }
        }

        // 3) 重新签名（ad-hoc）；带沙盒 / team 标识的应用在扫描阶段就被挡掉了
        guard let codesign = CommandRunner.locate("codesign") else {
            restore(backups)
            return .failure(T("找不到 codesign"))
        }
        var arguments = ["--force", "--deep", "--sign", "-"]
        if let entitlements = temporaryEntitlements(for: app.path, codesign: codesign) {
            arguments += ["--entitlements", entitlements]
        }
        arguments.append(app.path)
        let sign = CommandRunner.runSync(codesign, arguments, timeout: 180)
        if !sign.ok {
            restore(backups)
            return .failure(TF("重新签名失败：%@", sign.error.split(separator: "\n").last.map(String.init) ?? "codesign 报错"))
        }

        let verify = CommandRunner.runSync(codesign, ["--verify", "--deep", app.path], timeout: 120)
        if !verify.ok {
            restore(backups)
            _ = CommandRunner.runSync(codesign, ["--force", "--deep", "--sign", "-", app.path], timeout: 180)
            return .failure(T("签名校验没通过，已还原"))
        }
        return .success
    }

    private nonisolated static func restore(_ backups: [(original: String, copy: String)]) {
        let fm = FileManager.default
        for pair in backups {
            try? fm.removeItem(atPath: pair.original)
            try? fm.copyItem(atPath: pair.copy, toPath: pair.original)
        }
    }

    private nonisolated static func temporaryEntitlements(for path: String, codesign: String) -> String? {
        let result = CommandRunner.runSync(codesign, ["-d", "--entitlements", ":-", path], timeout: 30)
        let text = result.output.isEmpty ? result.error : result.output
        guard text.contains("<plist"), text.contains("</plist>") else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aurora-entitlements.plist")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // MARK: - 扫描

    private nonisolated static func collect() -> [UniversalApp] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var bundles: [URL] = []
        for directory in ["/Applications", home.appendingPathComponent("Applications").path] {
            let contents = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: directory),
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])) ?? []
            bundles += contents.filter { $0.pathExtension == "app" }
        }

        var result: [UniversalApp] = []
        for bundle in bundles {
            guard let app = inspect(bundle) else { continue }
            result.append(app)
        }
        return result
    }

    private nonisolated static func inspect(_ bundle: URL) -> UniversalApp? {
        let fm = FileManager.default
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else { return nil }
        guard let executable = info["CFBundleExecutable"] as? String else { return nil }

        let mainBinary = bundle.appendingPathComponent("Contents/MacOS/\(executable)").path
        guard MachOBinary.isUniversal(mainBinary) else { return nil }

        var binaries = [mainBinary]
        var wasted = MachOBinary.wasted(in: mainBinary)

        // 内嵌框架通常也带两份，一起算进去
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        if let list = try? fm.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil) {
            for item in list where item.pathExtension == "framework" {
                let name = item.deletingPathExtension().lastPathComponent
                let candidates = [
                    item.appendingPathComponent("Versions/A/\(name)"),
                    item.appendingPathComponent(name)
                ]
                for candidate in candidates where fm.fileExists(atPath: candidate.path) && MachOBinary.isUniversal(candidate.path) {
                    binaries.append(candidate.path)
                    wasted += MachOBinary.wasted(in: candidate.path)
                    break
                }
            }
        }

        guard wasted > 0 else { return nil }
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? bundle.deletingPathExtension().lastPathComponent

        return UniversalApp(
            id: bundle.path,
            name: name,
            path: bundle.path,
            wasted: wasted,
            binaries: binaries,
            blockReason: blockReason(for: bundle),
            caution: caution(for: bundle)
        )
    }

    /// App Store 安装与沙盒应用重新签名后基本起不来，一律不碰
    private nonisolated static func blockReason(for bundle: URL) -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: bundle.appendingPathComponent("Contents/_MASReceipt/receipt").path) {
            return T("App Store 应用，签名受保护")
        }
        guard CommandRunner.locate("codesign") != nil else { return T("找不到 codesign") }
        if entitlements(of: bundle).contains("com.apple.security.app-sandbox") {
            return T("沙盒应用，重新签名后会失去权限")
        }
        return nil
    }

    /// 有 team 标识 / 钥匙串分组的应用，重签后这些授权会失效，登录状态可能要重来
    private nonisolated static func caution(for bundle: URL) -> String? {
        let text = entitlements(of: bundle)
        if text.contains("com.apple.application-identifier") || text.contains("keychain-access-groups") {
            return T("瘦身后可能需要重新登录")
        }
        return nil
    }

    private nonisolated static func entitlements(of bundle: URL) -> String {
        guard let codesign = CommandRunner.locate("codesign") else { return "" }
        let result = CommandRunner.runSync(codesign, ["-d", "--entitlements", ":-", bundle.path], timeout: 20)
        return result.output.isEmpty ? result.error : result.output
    }
}
