//  DevCleanupService.swift
//  Aurora — 开发环境：语言包管理器缓存 + 项目里的构建产物
//
//  两类东西分开处理：
//  · 缓存（npm / pip / cargo / gradle …）在固定位置，删了下次自动下载
//  · 构建产物（node_modules / target / .build）在各项目目录里，需要先扫出来

import AppKit
import Combine

struct DevCategory: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let paths: [String]
    var bytes: Int64 = 0
    var measured = false
    var available = true
    var tool: String?
}

struct DevProject: Identifiable {
    let id: String
    let kind: String
    let project: String
    let path: String
    let bytes: Int64
}

@MainActor
final class DevCleanupService: ObservableObject {
    @Published private(set) var categories: [DevCategory] = []
    @Published private(set) var projects: [DevProject] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isFindingProjects = false
    @Published private(set) var isCleaning = false
    @Published private(set) var progress = ""
    @Published private(set) var message: String?
    @Published private(set) var lastScan: Date?
    @Published var selection: Set<String> = []
    @Published var projectSelection: Set<String> = []

    private let home = FileManager.default.homeDirectoryForCurrentUser

    var totalCache: Int64 { categories.reduce(0) { $0 + $1.bytes } }
    var totalProjects: Int64 { projects.reduce(0) { $0 + $1.bytes } }
    var selectedBytes: Int64 {
        categories.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.bytes }
            + projects.filter { projectSelection.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    func scanIfNeeded() {
        guard lastScan == nil, !isScanning else { return }
        Task { await scan() }
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        message = nil
        progress = T("正在统计数据…")
        categories = Self.catalog(home: home).map { spec in
            var item = spec
            item.available = spec.paths.contains { FileManager.default.fileExists(atPath: $0) }
            return item
        }
        let snapshot = categories
        await withTaskGroup(of: (String, Int64).self) { group in
            for item in snapshot where item.available {
                group.addTask { (item.id, await Self.measure(item.paths)) }
            }
            for await (id, bytes) in group {
                guard let index = categories.firstIndex(where: { $0.id == id }) else { continue }
                categories[index].bytes = bytes
                categories[index].measured = true
                progress = TF("已统计 %d / %d 项", categories.filter(\.measured).count, snapshot.count)
            }
        }
        isScanning = false
        lastScan = Date()
        progress = ""

        isFindingProjects = true
        progress = T("正在找项目构建产物…")
        projects = await Task.detached(priority: .utility) { Self.findProjects(home: FileManager.default.homeDirectoryForCurrentUser) }.value
        isFindingProjects = false
        progress = ""
    }

    func cleanSelection() async {
        guard !isCleaning else { return }
        isCleaning = true
        defer { isCleaning = false }
        message = nil

        var moved = 0, failed = 0
        let cacheTargets = categories.filter { selection.contains($0.id) && $0.available }
        for item in cacheTargets {
            for path in item.paths {
                let outcome = await Task.detached(priority: .userInitiated) {
                    StorageService.trashChildren(of: path)
                }.value
                moved += outcome.moved
                failed += outcome.failed
            }
        }

        let projectTargets = projects.filter { projectSelection.contains($0.id) }
        for project in projectTargets {
            let ok = await Task.detached(priority: .userInitiated) {
                StorageService.trashItem(at: project.path)
            }.value
            if ok { moved += 1 } else { failed += 1 }
        }

        // 清理完把数字对齐
        for id in cacheTargets.map(\.id) {
            guard let index = categories.firstIndex(where: { $0.id == id }) else { continue }
            categories[index].bytes = await Self.measure(categories[index].paths)
        }
        projects.removeAll { projectSelection.contains($0.id) }
        selection = []
        projectSelection = []
        message = failed == 0
            ? TF("已回收 %d 项，都在废纸篓里", moved)
            : TF("已处理 %d 项，%d 项失败", moved, failed)
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - 扫描实现

    private nonisolated static func measure(_ paths: [String]) async -> Int64 {
        var total: Int64 = 0
        for path in paths { total += StorageService.measurePath(path) }
        return total
    }

    private nonisolated static func findProjects(home: URL) -> [DevProject] {
        let fm = FileManager.default
        let roots = ["Developer", "Projects", "Code", "dev", "Desktop", "Documents"]
            .map { home.appendingPathComponent($0).path }
            .filter { fm.fileExists(atPath: $0) }
        guard !roots.isEmpty, let find = CommandRunner.locate("find") else { return [] }

        var found: [DevProject] = []
        for root in roots {
            let result = CommandRunner.runSync(find, [
                root, "-xdev", "-maxdepth", "5", "-type", "d",
                "(", "-name", "node_modules", "-o", "-name", "target",
                "-o", "-name", ".build", "-o", "-name", "Pods", "-o", "-name", ".next", ")",
                "-prune", "-print"
            ], timeout: 20)
            guard result.ok else { continue }
            for line in result.output.split(separator: "\n") {
                let path = String(line)
                guard let size = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
                _ = size
                let bytes = StorageService.measurePath(path)
                guard bytes > 8 * 1024 * 1024 else { continue }   // 太小的项目不值得列
                let project = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
                found.append(DevProject(
                    id: path,
                    kind: URL(fileURLWithPath: path).lastPathComponent,
                    project: project,
                    path: path,
                    bytes: bytes
                ))
            }
        }
        return Array(found.sorted { $0.bytes > $1.bytes }.prefix(24))
    }

    private static func catalog(home: URL) -> [DevCategory] {
        func path(_ relative: String) -> String { home.appendingPathComponent(relative).path }
        return [
            DevCategory(id: "npm", title: T("npm 缓存"), detail: "~/.npm/_cacache",
                        symbol: "shippingbox", paths: [path(".npm/_cacache")], tool: "npm"),
            DevCategory(id: "pnpm", title: T("pnpm 存储"), detail: "~/Library/pnpm/store",
                        symbol: "shippingbox", paths: [path("Library/pnpm/store")], tool: "pnpm"),
            DevCategory(id: "yarn", title: T("Yarn 缓存"), detail: "~/Library/Caches/Yarn",
                        symbol: "shippingbox", paths: [path("Library/Caches/Yarn")], tool: "yarn"),
            DevCategory(id: "pip", title: T("pip 缓存"), detail: "~/Library/Caches/pip",
                        symbol: "shippingbox", paths: [path("Library/Caches/pip")], tool: "pip"),
            DevCategory(id: "cargo", title: T("Cargo 注册表"), detail: "~/.cargo/registry",
                        symbol: "shippingbox", paths: [path(".cargo/registry")], tool: "cargo"),
            DevCategory(id: "go-build", title: T("Go 构建缓存"), detail: "~/Library/Caches/go-build",
                        symbol: "shippingbox", paths: [path("Library/Caches/go-build")], tool: "go"),
            DevCategory(id: "go-mod", title: T("Go 模块缓存"), detail: "~/go/pkg/mod",
                        symbol: "shippingbox", paths: [path("go/pkg/mod")], tool: "go"),
            DevCategory(id: "gradle", title: T("Gradle 缓存"), detail: "~/.gradle/caches",
                        symbol: "shippingbox", paths: [path(".gradle/caches")], tool: "gradle"),
            DevCategory(id: "maven", title: T("Maven 仓库"), detail: "~/.m2/repository",
                        symbol: "shippingbox", paths: [path(".m2/repository")], tool: "mvn"),
            DevCategory(id: "cocoapods", title: T("CocoaPods 缓存"), detail: "~/Library/Caches/CocoaPods",
                        symbol: "shippingbox", paths: [path("Library/Caches/CocoaPods")], tool: "pod"),
            DevCategory(id: "swiftpm", title: T("SwiftPM 缓存"), detail: "~/Library/Caches/org.swift.swiftpm",
                        symbol: "shippingbox", paths: [path("Library/Caches/org.swift.swiftpm")], tool: "swift"),
            DevCategory(id: "pub", title: T("Dart / Flutter 缓存"), detail: "~/.pub-cache",
                        symbol: "shippingbox", paths: [path(".pub-cache")], tool: "flutter"),
            DevCategory(id: "android-avd", title: T("Android 模拟器"), detail: "~/.android/avd",
                        symbol: "shippingbox", paths: [path(".android/avd")], tool: "avd")
        ]
    }
}
