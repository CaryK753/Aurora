//  FinderExtensionService.swift
//  Aurora — Finder 右键扩展的配置与应用侧状态
//
//  真正的右键项由 AuroraFinder.appex（FinderSync 扩展）注入，主 App 只负责编辑配置：
//  写 JSON + 通过 DistributedNotification 推给扩展，扩展下一次右键就能看到新菜单。

import AppKit
import Combine
import FinderSync

struct FinderAction: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case copyPath, openTerminal, openWithApp, runCommand, newFile

        var id: String { rawValue }

        var title: String {
            switch self {
            case .copyPath: return T("复制路径")
            case .openTerminal: return T("在终端打开")
            case .openWithApp: return T("用指定 App 打开")
            case .runCommand: return T("运行命令")
            case .newFile: return T("新建文件")
            }
        }

        var symbol: String {
            switch self {
            case .copyPath: return "doc.on.doc"
            case .openTerminal: return "terminal"
            case .openWithApp: return "arrow.up.forward.app"
            case .runCommand: return "chevron.left.forwardslash.chevron.right"
            case .newFile: return "doc.badge.plus"
            }
        }

        /// 没有参数时，列表里用一句说明代替重复的标题
        var hint: String {
            switch self {
            case .copyPath: return T("把选中项的完整路径复制到剪贴板")
            case .openTerminal: return T("在「终端」中打开当前文件夹")
            case .openWithApp: return T("用指定的 App 打开选中项")
            case .runCommand: return T("对选中项执行 shell 命令")
            case .newFile: return T("在当前文件夹新建文件")
            }
        }

        /// 参数这一栏对用户意味着什么
        var argumentPlaceholder: String? {
            switch self {
            case .copyPath, .openTerminal: return nil
            case .openWithApp: return T("App 路径")
            case .runCommand: return T("shell 命令")
            case .newFile: return T("文件名，例如 未命名.md")
            }
        }
    }

    var id: String
    var title: String
    var kind: Kind
    var argument: String
    var enabled: Bool
    /// 自定义菜单图标（SF Symbol 名）。nil = 用类型默认图标；openWithApp 固定显示目标 App 图标
    var symbol: String?

    static func make(_ kind: Kind, title: String? = nil, argument: String = "") -> FinderAction {
        FinderAction(
            id: UUID().uuidString,
            title: title ?? kind.title,
            kind: kind,
            argument: argument,
            enabled: true,
            symbol: nil
        )
    }

    /// 菜单里实际显示的 SF Symbol：用户自定义优先，否则跟类型走
    var displaySymbol: String { symbol ?? kind.symbol }

    /// 可选的自定义图标（SF Symbols 里适合当右键动作的一组）
    static let iconChoices: [String] = [
        "doc.on.doc", "doc.badge.plus", "terminal", "chevron.left.forwardslash.chevron.right",
        "arrow.up.forward.app", "link", "clipboard", "archivebox",
        "photo.on.rectangle", "music.note", "video.fill", "globe",
        "mail", "message", "folder", "externaldrive",
        "wand.and.stars", "tag", "square.and.arrow.up.on.square", "tray.full"
    ]
}

@MainActor
final class FinderExtensionService: ObservableObject {
    @Published private(set) var actions: [FinderAction] = []
    @Published private(set) var isEnabled: Bool = false
    /// 扩展进程有没有真的被 Finder 拉起（看它自己写的诊断日志）
    @Published private(set) var didLoad: Bool = false

    private var requestObserver: NSObjectProtocol?
    private var requestTimer: Timer?
    private var executeObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private let storeURL: URL

    private static let configChannel = Notification.Name("com.cary.aurora.finder.config")
    private static let requestChannel = Notification.Name("com.cary.aurora.finder.request")
    private static let executeChannel = Notification.Name("com.cary.aurora.finder.execute")

    init() {
        // 扩展是沙盒进程，只能读自己容器里的文件；主 App 未沙盒，可以直接写进它的容器，
        // 这样即使 Aurora 没在运行，右键菜单也是最新的配置。
        let container = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/com.cary.aurora.finder/Data/Library/Application Support/Aurora", isDirectory: true)
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        storeURL = container.appendingPathComponent("finder-actions.json")

        // 旧版本写在共享目录，迁移一次
        let legacy = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aurora/finder-actions.json")
        if !FileManager.default.fileExists(atPath: storeURL.path),
           let data = try? Data(contentsOf: legacy) {
            try? data.write(to: storeURL)
        }

        load()
        refreshEnabled()

        requestObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.requestChannel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.push() }
        }

        executeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.executeChannel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.processPendingRequests() }
        }

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshEnabled() }
        }

        requestTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.processPendingRequests() }
        }

        // 启动后主动补一次注册：系统有时不会自动发现 PlugIns 里的 appex
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            Task { @MainActor in
                self?.repairRegistration()
                self?.refreshEnabled()
            }
        }
    }

    deinit {
        requestTimer?.invalidate()
        if let requestObserver { DistributedNotificationCenter.default().removeObserver(requestObserver) }
        if let executeObserver { DistributedNotificationCenter.default().removeObserver(executeObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    // MARK: - 状态

    /// 用户必须在「系统设置 › 通用 › 登录项与扩展 › Finder 扩展」里勾选，扩展才会被 Finder 加载
    func refreshEnabled() {
        isEnabled = FIFinderSyncController.isExtensionEnabled
        didLoad = loadMarkerExists()
    }

    private func loadMarkerExists() -> Bool {
        // 扩展是沙盒进程，它的 Application Support 落在自己的容器里，两处都查
        let paths = [
            NSHomeDirectory() + "/Library/Containers/com.cary.aurora.finder/Data/Library/Application Support/Aurora/finder-ext.log",
            NSHomeDirectory() + "/Library/Application Support/Aurora/finder-ext.log"
        ]
        for path in paths {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if text.contains("extension loaded") { return true }
        }
        return false
    }

    /// 让 Finder 重新扫描已启用的扩展（等价于 `killall Finder`，Dock 与桌面会自动恢复）
    func restartFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            Task { @MainActor in self?.refreshEnabled() }
        }
    }

    func openExtensionSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    // MARK: - 注册自愈

    /// App 被系统「发现」并把 appex 交给 pkd，有时会滞后甚至漏掉（尤其是用 cp 安装、或构建目录里也有同名包）：
    /// 这里主动跑一次 lsregister + pluginkit，把结果写进 finder-diag.log，既能修也能查。
    func repairRegistration(log: Bool = true) {
        let appex = Bundle.main.bundlePath + "/Contents/PlugIns/AuroraFinder.appex"
        var lines: [String] = ["[\(Self.stamp())] repair start, appex exists=\(FileManager.default.fileExists(atPath: appex))"]

        if !activationsEnabled(appex: appex) {
            lines.append("appex missing on disk — skip")
            writeDiag(lines, enabled: log)
            return
        }

        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        lines.append("lsregister -f app → " + run(lsregister, ["-f", Bundle.main.bundlePath]))
        lines.append("lsregister -f appex → " + run(lsregister, ["-f", appex]))

        var listed = queryPlugin()
        lines.append("pluginkit -m -i (before) → \(listed.isEmpty ? "(none)" : listed)")
        if listed.isEmpty {
            // 换过一次签名后 pkd 里可能留着旧记录，先摘掉再登记
            lines.append("pluginkit -r → " + run("/usr/bin/pluginkit", ["-r", appex]))
        }
        lines.append("pluginkit -a → " + run("/usr/bin/pluginkit", ["-a", appex]))

        // pkd 是异步的，给它几次机会
        for attempt in 1...3 {
            Thread.sleep(forTimeInterval: 0.8)
            listed = queryPlugin()
            lines.append("poll #\(attempt) → \(listed.isEmpty ? "(none)" : listed)")
            if !listed.isEmpty { break }
        }

        lines.append("pluginkit -e use → " + run("/usr/bin/pluginkit", ["-e", "use", "-i", Self.extensionID]))
        lines.append("isExtensionEnabled=\(FIFinderSyncController.isExtensionEnabled)")
        writeDiag(lines, enabled: log)
        refreshEnabled()
    }

    /// 只取 `+  com.cary.aurora.finder(1.0.0)` 这一行，空字符串表示没登记
    private func queryPlugin() -> String {
        run("/usr/bin/pluginkit", ["-m", "-i", Self.extensionID])
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains(Self.extensionID) }
            .joined(separator: " | ")
    }

    private func activationsEnabled(appex: String) -> Bool {
        FileManager.default.fileExists(atPath: appex + "/Contents/MacOS/AuroraFinder")
    }

    private static func stamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func run(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return "launch failed: \(error.localizedDescription)"
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "exit=\(process.terminationStatus) \(text.isEmpty ? "(no output)" : text)"
    }

    private func writeDiag(_ lines: [String], enabled: Bool) {
        guard enabled else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aurora", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let url = support.appendingPathComponent("finder-diag.log")
        let text = lines.joined(separator: "\n") + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(text.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static let extensionID = "com.cary.aurora.finder"

    // MARK: - 增删改

    func importAction(_ action: FinderAction) {
        if let index = actions.firstIndex(where: { $0.id == action.id }) { actions[index] = action }
        else { actions.append(action) }
        save()
    }

    func add(_ kind: FinderAction.Kind) {
        actions.append(.make(kind))
        save()
    }

    func update(_ action: FinderAction) {
        guard let index = actions.firstIndex(where: { $0.id == action.id }) else { return }
        actions[index] = action
        save()
    }

    func remove(_ id: String) {
        actions.removeAll { $0.id == id }
        save()
    }

    func toggle(_ id: String) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        actions[index].enabled.toggle()
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        actions.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: - 持久化与推送

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let parsed = try? JSONDecoder().decode([FinderAction].self, from: data) else {
            actions = Self.seed
            save()
            return
        }
        // 早期版本会重复追加默认项，载入时按「类型 + 标题 + 参数」去重
        var seen = Set<String>()
        let unique = parsed.filter { action in
            seen.insert("\(action.kind.rawValue)|\(action.title)|\(action.argument)").inserted
        }
        actions = unique.isEmpty ? Self.seed : unique
        if unique.count != parsed.count { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(actions) else { return }
        try? data.write(to: storeURL)
        push()
    }

    /// 把配置推给扩展：轻量、即时，不用重启 Finder
    func push() {
        guard let data = try? JSONEncoder().encode(actions),
              let json = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Self.configChannel,
            object: nil,
            userInfo: ["json": json],
            deliverImmediately: true
        )
    }

    // MARK: - 执行扩展转交的动作

    private var requestDirectory: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("requests", isDirectory: true)
    }

    /// 扩展把请求写成文件，这里统一消费；通知只是「尽快看一下」的提示
    private func processPendingRequests() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: requestDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files where file.pathExtension == "json" {
            defer { try? manager.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            performDelegated(info)
        }
    }

    /// 扩展跑在沙盒里，起终端 / 写文件 / 跑命令都交给主 App
    private func performDelegated(_ info: [AnyHashable: Any]) {
        let id = info["id"] as? String ?? ""
        let rawKind = info["kind"] as? String ?? ""
        let action = actions.first(where: { $0.id == id })
            ?? actions.first(where: { $0.kind.rawValue == rawKind })
        let kind = rawKind.isEmpty ? (action?.kind.rawValue ?? "") : rawKind
        let argument = (info["argument"] as? String) ?? action?.argument ?? ""
        let directory = info["directory"] as? String ?? NSHomeDirectory()
        let selection = (info["selection"] as? String ?? "")
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }

        Debug.log("finder perform kind=\(kind) dir=\(directory) sel=\(selection.count)")

        switch kind {
        case "runCommand":
            guard !argument.isEmpty else { return }
            var env = ProcessInfo.processInfo.environment
            env["AURORA_SELECTION"] = selection.joined(separator: "\n")
            env["AURORA_DIRECTORY"] = directory
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", argument]
            process.environment = env
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
            try? process.run()

        case "newFile":
            let name = argument.isEmpty ? "未命名.txt" : argument
            guard name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { return }
            var target = URL(fileURLWithPath: directory).appendingPathComponent(name)
            var index = 2
            while FileManager.default.fileExists(atPath: target.path) {
                let ext = (name as NSString).pathExtension
                let base = (name as NSString).deletingPathExtension
                let suffix = ext.isEmpty ? "" : ".\(ext)"
                target = URL(fileURLWithPath: directory).appendingPathComponent("\(base) \(index)\(suffix)")
                index += 1
            }
            if FileManager.default.createFile(atPath: target.path, contents: Data()) {
                Debug.log("finder newFile ok \(target.path)")
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }

        case "openTerminal":
            // 选中文件夹就打开它，否则打开当前目录
            let folder = selection.first ?? directory
            var isDirectory: ObjCBool = false
            let path = FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue
                ? folder
                : directory
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Terminal", path]
            try? process.run()

        case "openWithApp":
            guard !argument.isEmpty else { return }
            let app = URL(fileURLWithPath: argument)
            let urls = selection.isEmpty
                ? [URL(fileURLWithPath: directory)]
                : selection.map { URL(fileURLWithPath: $0) }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())

        default:
            break
        }
    }

    /// 首次启用时给三个最常用的动作，避免空白页
    private static let seed: [FinderAction] = [
        .make(.copyPath, title: T("复制路径")),
        .make(.openTerminal, title: T("在终端打开")),
        .make(.newFile, title: T("新建文本"), argument: "未命名.txt")
    ]

    var enabledCount: Int { actions.filter(\.enabled).count }
}
