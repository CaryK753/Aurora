//  StorageService.swift
//  Aurora — 存储：只读盘点 + 安全清理
//
//  设计取向（对照 docs/storage-module-eval.md）：
//  · 统计与清理都在 Swift 里做，不把第三方清理器的 GPL 代码并进来；
//    目录体积统计借 /usr/bin/du（比 Swift 枚举快一个数量级），其余用 FileManager。
//  · 清理一律走「移到废纸篓」，随时可以放回；根目录是硬编码白名单，只会动配置里列出的路径。
//  · 已有的外部 CLI（brew / docker / mole / ncdu）只做检测与「在终端运行」入口，
//    由用户自己确认执行，Aurora 不代为调用破坏性命令。

import AppKit
import Combine

enum StoragePolicy {
    case safe      // 缓存类，删了会自动重建
    case confirm   // 可能含个人数据，勾选后需要再确认一次
    case readOnly  // 只统计，不提供清理

    var label: String {
        switch self {
        case .safe: return T("可安全回收")
        case .confirm: return T("需确认")
        case .readOnly: return T("只读")
        }
    }
}

struct StorageItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let policy: StoragePolicy
    /// 白名单里的目录：清理时只动它们的「子项」，不删目录本身
    let paths: [String]
    /// 非空表示清理走外部命令（不做废纸篓）
    var command: [String]?
    var tool: String?
    var note: String?
    var bytes: Int64 = 0
    var measured = false
    var available = true
    /// 有体积才值得列出
    var isCleanable: Bool { policy != .readOnly && available && bytes > 0 }
    /// 废纸篓再往废纸篓搬没有意义：这一类是真的删除
    var permanentlyDeletes: Bool { id == "trash" }
}

struct StorageBigFile: Identifiable {
    let id: String
    let name: String
    let path: String
    let bytes: Int64
    let modified: Date
}

struct StorageVolume {
    var name: String
    var total: Int64
    var free: Int64
    var used: Int64 { max(0, total - free) }
    var usedFraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
}

@MainActor
final class StorageService: ObservableObject {
    @Published private(set) var volume: StorageVolume?
    @Published private(set) var items: [StorageItem] = []
    @Published private(set) var bigFiles: [StorageBigFile] = []
    @Published private(set) var tools: [String: Bool] = [:]
    @Published private(set) var dockerSummary: String?
    @Published private(set) var isScanning = false
    @Published private(set) var isFindingBigFiles = false
    @Published private(set) var scanningLabel = ""
    @Published private(set) var isCleaning = false
    @Published private(set) var cleaningLabel = ""
    @Published private(set) var lastScan: Date?
    @Published private(set) var status: String?
    @Published var selection: Set<String> = []

    private var scanTask: Task<Void, Never>?
    private let home = FileManager.default.homeDirectoryForCurrentUser

    var cleanableItems: [StorageItem] {
        items.filter { $0.policy != .readOnly }
    }

    var readOnlyItems: [StorageItem] {
        items.filter { $0.policy == .readOnly && $0.available && ($0.bytes > 0 || $0.note != nil) }
    }

    var selectedBytes: Int64 {
        items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    var totalReclaimable: Int64 {
        cleanableItems.reduce(0) { $0 + $1.bytes }
    }

    // MARK: - 扫描

    func scanIfNeeded() {
        guard lastScan == nil, !isScanning else { return }
        scan()
    }

    func scan() {
        scanTask?.cancel()
        isScanning = true
        scanningLabel = T("正在读取磁盘信息…")
        status = nil
        items = Self.catalog(home: home).map { spec in
            var item = spec
            item.available = spec.paths.contains { FileManager.default.fileExists(atPath: $0) } || spec.command != nil
            return item
        }
        bigFiles = []
        scanTask = Task { [weak self] in await self?.performScan() }
    }

    private func performScan() async {
        refreshVolume()
        tools = await Self.detectTools()
        if let docker = tools["docker"], docker {
            dockerSummary = await Self.dockerReclaimable()
        } else {
            dockerSummary = nil
        }

        let snapshot = items
        await withTaskGroup(of: (String, Int64, String?).self) { group in
            for item in snapshot where !item.paths.isEmpty {
                group.addTask {
                    let result = await Self.measure(item.paths)
                    return (item.id, result.bytes, result.error)
                }
            }
            for await (id, bytes, error) in group {
                guard !Task.isCancelled else { return }
                guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
                items[index].bytes = bytes
                items[index].measured = true
                if let error { items[index].note = error }
                scanningLabel = TF("已统计 %d / %d 项", items.filter(\.measured).count, snapshot.count)
            }
        }

        guard !Task.isCancelled else { return }
        // 清理入口命令的项（brew 缓存走的是目录统计，这里只处理 docker 这类纯 CLI 项）
        if let dockerIndex = items.firstIndex(where: { $0.id == "docker" }) {
            // docker 没有本地目录可量：装没装、能回收多少，都靠 CLI 回答
            items[dockerIndex].available = tools["docker"] == true
            items[dockerIndex].measured = true
            if let summary = dockerSummary {
                items[dockerIndex].note = summary
            }
        }

        // 大文件另开一轮：目录体积已经量完了，不该让「找 1GB 文件」继续堵着整页
        scanningLabel = ""
        isScanning = false
        lastScan = Date()
        let total = totalReclaimable
        status = total > 0 ? TF("扫描完成，约 %@ 可回收", Fmt.bytes(UInt64(total))) : T("扫描完成，没有发现明显可回收的空间")

        isFindingBigFiles = true
        bigFiles = await Self.findBigFiles(roots: [
            home.appendingPathComponent("Downloads").path,
            home.appendingPathComponent("Desktop").path,
            home.appendingPathComponent("Documents").path,
            home.appendingPathComponent("Movies").path
        ])
        isFindingBigFiles = false
    }

    private func refreshVolume() {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) else {
            volume = nil
            return
        }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        volume = StorageVolume(name: FileManager.default.displayName(atPath: "/"), total: total, free: free)
    }

    // MARK: - 清理

    func cleanSelection() async {
        guard !isCleaning, !selection.isEmpty else { return }
        isCleaning = true
        defer { isCleaning = false }

        var moved = 0
        var failed = 0
        var commandRuns: [String] = []
        let targets = items.filter { selection.contains($0.id) && $0.policy != .readOnly }

        for item in targets {
            if let command = item.command {
                cleaningLabel = item.title
                let result = await CommandRunner.run(command[0], Array(command.dropFirst()), timeout: 120)
                commandRuns.append("\(command.joined(separator: " ")) → \(result.ok ? "ok" : "status \(result.status)")")
                if result.ok { moved += 1 } else { failed += 1 }
                continue
            }
            for path in item.paths {
                cleaningLabel = path
                let permanent = item.permanentlyDeletes
                let outcome = await Task.detached(priority: .userInitiated) {
                    permanent ? Self.removeChildren(of: path) : Self.trashChildren(of: path)
                }.value
                moved += outcome.moved
                failed += outcome.failed
            }
        }

        writeLog(targets: targets, moved: moved, failed: failed, commands: commandRuns)

        // 清理完把涉及的分类重量一遍，避免界面还显示旧数字
        for id in targets.map(\.id) {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            if items[index].command != nil {
                items[index].bytes = 0
                continue
            }
            let measured = await Self.measure(items[index].paths)
            items[index].bytes = measured.bytes
        }

        selection = []
        cleaningLabel = ""
        refreshVolume()
        let emptied = targets.contains(where: \.permanentlyDeletes)
        status = failed == 0
            ? (emptied ? TF("已清空 %d 项（废纸篓中的项目无法恢复）", moved)
                       : TF("已把 %d 项移到废纸篓，随时可以在废纸篓里放回", moved))
            : TF("已处理 %d 项，%d 项失败（可能正在被使用）", moved, failed)
        lastScan = Date()
    }

    /// 把目录下的子项逐个移到废纸篓；不删目录本身，App 不会因为缺目录报错
    nonisolated static func trashChildren(of path: String) -> (moved: Int, failed: Int) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: path) else { return (0, 0) }
        var moved = 0, failed = 0
        // 一次最多搬 3000 项：再多就该走命令行，别让面板卡住
        for child in children.prefix(3000) {
            let url = URL(fileURLWithPath: path).appendingPathComponent(child)
            var resulting: NSURL?
            do {
                try fm.trashItem(at: url, resultingItemURL: &resulting)
                moved += 1
            } catch {
                failed += 1
            }
        }
        return (moved, failed)
    }

    /// 供开发环境模块复用：只量体积
    nonisolated static func measurePath(_ path: String) -> Int64 { size(of: path).bytes }

    /// 把整个目录（而不是它的内容）移到废纸篓，用于 node_modules 这类构建产物
    nonisolated static func trashItem(at path: String) -> Bool {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            return true
        } catch {
            return false
        }
    }

    /// 清空：直接删，只用于废纸篓本身
    nonisolated static func removeChildren(of path: String) -> (moved: Int, failed: Int) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: path) else { return (0, 0) }
        var moved = 0, failed = 0
        for child in children.prefix(3000) {
            do {
                try fm.removeItem(at: URL(fileURLWithPath: path).appendingPathComponent(child))
                moved += 1
            } catch {
                failed += 1
            }
        }
        return (moved, failed)
    }

    private func writeLog(targets: [StorageItem], moved: Int, failed: Int, commands: [String]) {
        let directory = home.appendingPathComponent("Library/Logs/Aurora", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("storage.log")
        let formatter = ISO8601DateFormatter()
        var text = "[\(formatter.string(from: Date()))] moved=\(moved) failed=\(failed) targets=\(targets.map(\.id).joined(separator: ","))\n"
        for line in commands { text += "    cmd: \(line)\n" }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 单文件操作

    func trash(file: StorageBigFile) async -> Bool {
        let url = URL(fileURLWithPath: file.path)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            bigFiles.removeAll { $0.id == file.id }
            return true
        } catch {
            status = TF("无法移走 %@：%@", file.name, error.localizedDescription)
            return false
        }
    }

    @MainActor
    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openFolder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - 目录统计

    private nonisolated static func measure(_ paths: [String]) async -> (bytes: Int64, error: String?) {
        var total: Int64 = 0
        var failure: String?
        for path in paths {
            let result = size(of: path)
            total += result.bytes
            if let error = result.error, failure == nil { failure = error }
        }
        return (total, failure)
    }

    nonisolated static func size(of path: String) -> (bytes: Int64, error: String?) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return (0, nil)
        }
        if !isDirectory.boolValue {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return (size, nil)
        }
        guard let du = CommandRunner.locate("du") else { return (0, T("找不到 du")) }
        let result = CommandRunner.runSync(du, ["-skx", path], timeout: 40)
        guard let last = result.output.split(separator: "\n").last,
              let kilobytes = Int64(last.split(separator: "\t").first ?? "") else {
            // 没有完全磁盘访问权限时 du 会只报权限错误
            if result.error.contains("Permission denied") || result.error.contains("Operation not permitted") {
                return (0, T("需要「完全磁盘访问」权限才能统计这个目录"))
            }
            return (0, nil)
        }
        return (kilobytes * 1024, nil)
    }

    // MARK: - 大文件

    private nonisolated static func findBigFiles(roots: [String], minimum: Int64 = 1_500_000_000) async -> [StorageBigFile] {
        await withTaskGroup(of: [StorageBigFile].self) { group in
            for root in roots {
                group.addTask { find(in: root, minimum: minimum) }
            }
            var all: [StorageBigFile] = []
            for await files in group { all += files }
            return Array(all.sorted { $0.bytes > $1.bytes }.prefix(12))
        }
    }

    private nonisolated static func find(in root: String, minimum: Int64) -> [StorageBigFile] {
        guard FileManager.default.fileExists(atPath: root), let find = CommandRunner.locate("find") else { return [] }
        // 只看 4 层以内、同卷；BSD find 的 -size 支持 G 后缀
        let gigabytes = max(1, minimum / 1_000_000_000)
        let result = CommandRunner.runSync(find, [root, "-xdev", "-maxdepth", "4", "-type", "f", "-size", "+\(gigabytes)G"], timeout: 10)
        guard result.ok else { return [] }
        var files: [StorageBigFile] = []
        for line in result.output.split(separator: "\n") {
            let path = String(line)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? Int64 else { continue }
            files.append(StorageBigFile(
                id: path,
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                bytes: size,
                modified: attributes[.modificationDate] as? Date ?? .distantPast
            ))
        }
        return files
    }

    // MARK: - 外部 CLI

    private nonisolated static func detectTools() async -> [String: Bool] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var found: [String: Bool] = [:]
                for tool in ["brew", "docker", "mole", "ncdu", "mas"] {
                    found[tool] = CommandRunner.exists(tool)
                }
                continuation.resume(returning: found)
            }
        }
    }

    private nonisolated static func dockerReclaimable() async -> String? {
        guard let docker = CommandRunner.locate("docker") else { return nil }
        let result = CommandRunner.runSync(docker, ["system", "df", "--format", "{{.Type}}: {{.Reclaimable}}"],
                                           timeout: 8)
        guard result.ok, !result.output.isEmpty else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").joined(separator: " · ")
    }

    // MARK: - 目录清单

    private static func catalog(home: URL) -> [StorageItem] {
        func path(_ relative: String) -> String {
            home.appendingPathComponent(relative).path
        }
        let library = path("Library")

        return [
            StorageItem(
                id: "user-cache",
                title: T("用户缓存"),
                detail: T("~/Library/Caches：App 的临时缓存，删掉会在下次启动时重建"),
                symbol: "shippingbox.fill",
                policy: .safe,
                paths: [path("Library/Caches")],
                note: nil
            ),
            StorageItem(
                id: "logs",
                title: T("日志与诊断报告"),
                detail: T("~/Library/Logs：崩溃日志与运行日志，排查问题后可以清掉"),
                symbol: "doc.text.magnifyingglass",
                policy: .safe,
                paths: [path("Library/Logs"), library + "/DiagnosticReports"]
            ),
            StorageItem(
                id: "xcode-derived",
                title: T("Xcode 派生数据"),
                detail: T("索引与中间产物；删掉后首次编译会慢一次"),
                symbol: "hammer.fill",
                policy: .safe,
                paths: [path("Library/Developer/Xcode/DerivedData")]
            ),
            StorageItem(
                id: "simulator",
                title: T("模拟器缓存"),
                detail: T("CoreSimulator 的运行时缓存，不含模拟器本体"),
                symbol: "iphone.gen3",
                policy: .safe,
                paths: [path("Library/Developer/CoreSimulator/Caches")]
            ),
            StorageItem(
                id: "brew-cache",
                title: T("Homebrew 缓存"),
                detail: T("下载过的安装包与旧版本；brew cleanup 也是清这里"),
                symbol: "mug.fill",
                policy: .safe,
                paths: [path("Library/Caches/Homebrew")],
                tool: "brew"
            ),
            StorageItem(
                id: "xcode-devicesupport",
                title: T("Xcode 设备支持文件"),
                detail: T("真机调试用的符号文件，换系统版本后会重新生成"),
                symbol: "cable.connector",
                policy: .confirm,
                paths: [path("Library/Developer/Xcode/iOS DeviceSupport"),
                        path("Library/Developer/Xcode/watchOS DeviceSupport"),
                        path("Library/Developer/Xcode/tvOS DeviceSupport")]
            ),
            StorageItem(
                id: "trash",
                title: T("废纸篓"),
                detail: T("清空后无法再放回；里面的项目不会计入上面的统计"),
                symbol: "trash.fill",
                policy: .confirm,
                paths: [path(".Trash")]
            ),
            StorageItem(
                id: "ios-backup",
                title: T("iOS 设备备份"),
                detail: T("整机备份可以从「访达」重新备份，但删掉就没有了"),
                symbol: "ipad.and.iphone",
                policy: .readOnly,
                paths: [path("Library/Application Support/MobileSync/Backup")]
            ),
            StorageItem(
                id: "xcode-archives",
                title: T("Xcode 归档"),
                detail: T("历史 .xcarchive，可能含发布用的包；确认不再需要时手动删"),
                symbol: "archivebox.fill",
                policy: .readOnly,
                paths: [path("Library/Developer/Xcode/Archives")]
            ),
            StorageItem(
                id: "docker",
                title: T("Docker 可回收空间"),
                detail: T("未使用的镜像与构建缓存；需要自己确认后再清理"),
                symbol: "shippingbox.and.arrow.backward.fill",
                policy: .readOnly,
                paths: [],
                command: nil,
                tool: "docker"
            )
        ]
    }
}
