//  FinderSync.swift — Aurora 的 Finder 右键扩展（独立编译，不参与 SwiftPM target）
//
//  为什么单独写一个 .appex：macOS 不允许普通 App 往 Finder 右键菜单里塞自定义项，
//  唯一受支持的入口是 FinderSync 扩展（RClick / Keka / 百度网盘都是这么做的）。
//  配置通过 DistributedNotification 从主 App 推过来（同时缓存到扩展自己的 container），
//  这样无论扩展是否被沙盒化都能拿到最新动作列表。

import Cocoa
import FinderSync

// MARK: - 配置模型（与主 App 的 FinderExtensionService 保持一致）

struct FinderAction: Codable {
    enum Kind: String, Codable, CaseIterable {
        case copyPath
        case openTerminal
        case openWithApp
        case runCommand
        case newFile

        var fallbackSymbol: String {
            switch self {
            case .copyPath: return "doc.on.doc"
            case .openTerminal: return "terminal"
            case .openWithApp: return "arrow.up.forward.app"
            case .runCommand: return "chevron.left.forwardslash.chevron.right"
            case .newFile: return "doc.badge.plus"
            }
        }
    }

    var id: String
    var title: String
    var kind: Kind
    var argument: String     // 打开方式：App 路径；命令：shell；新建：文件名
    var enabled: Bool
    // macOS 27 起系统右键菜单项带图标，Aurora 跟系统风格统一。
    // 旧配置 JSON 里没有这个键，Codable 可选字段解码为 nil，向下兼容。
    var symbol: String? = nil

    /// 菜单图标：「用 App 打开」显示目标 App 的真实图标，其余用 SF Symbol
    func menuItemImage() -> NSImage? {
        if kind == .openWithApp, !argument.isEmpty {
            let icon = NSWorkspace.shared.icon(forFile: argument)
            icon.size = NSSize(width: 16, height: 16)
            return icon
        }
        let name = symbol ?? kind.fallbackSymbol
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: title) {
            let sized = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                let symbol = image.withSymbolConfiguration(config) ?? image
                symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }
            return sized
        }
        return nil
    }
}

private enum Channel {
    static let config = Notification.Name("com.cary.aurora.finder.config")
    static let request = Notification.Name("com.cary.aurora.finder.request")
    static let execute = Notification.Name("com.cary.aurora.finder.execute")
    static let cacheFile = "finder-actions.json"
}

@objc(AuroraFinderExtension)
final class AuroraFinderExtension: FIFinderSync {
    private var actions: [FinderAction] = []
    private var hasConfiguration = false
    /// 当前菜单里每一项对应的动作：Finder 有时不保留 representedObject，用 tag 取更稳
    private var menuActions: [FinderAction] = []

    private static let defaults: [FinderAction] = [
        FinderAction(id: "default.copyPath", title: "复制路径", kind: .copyPath, argument: "", enabled: true),
        FinderAction(id: "default.openTerminal", title: "在终端打开", kind: .openTerminal, argument: "", enabled: true),
        FinderAction(id: "default.newFile", title: "新建文本", kind: .newFile, argument: "未命名.txt", enabled: true)
    ]
    private var observer: NSObjectProtocol?

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
        loadCache()

        observer = DistributedNotificationCenter.default().addObserver(
            forName: Channel.config,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let json = note.userInfo?["json"] as? String else { return }
            self?.apply(json: json)
        }

        // 冷启动时向主 App 要一次最新配置
        DistributedNotificationCenter.default().post(name: Channel.request, object: nil)
        log("extension loaded, cached actions=\(actions.count) enabled=\(actions.filter(\.enabled).count)")
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    // MARK: - 配置

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Aurora/\(Channel.cacheFile)")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let parsed = try? JSONDecoder().decode([FinderAction].self, from: data) else { return }
        actions = parsed
        hasConfiguration = true
    }

    private func apply(json: String) {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([FinderAction].self, from: data) else { return }
        actions = parsed
        hasConfiguration = true
        // 沙盒下写不进共享目录时忽略失败，下次仍靠通知刷新
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL)
    }

    /// 诊断日志：扩展被 Finder 加载后会往这里写一行，方便确认「到底是没启用还是没加载」
    private func log(_ message: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = support.appendingPathComponent("Aurora/finder-ext.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 菜单

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let source = hasConfiguration ? actions : Self.defaults
        let visible = source.filter(\.enabled)
        log("menu kind=\(menuKind.rawValue) actions=\(visible.count) source=\(actions.isEmpty ? "defaults" : "config")")
        guard !visible.isEmpty else { return nil }

        let menu = NSMenu(title: "")
        menuActions = []
        for action in visible {
            // 背景右键（没有选中文件）时，只保留「新建文件」这类不依赖选区的动作
            if menuKind == .contextualMenuForContainer || menuKind == .contextualMenuForSidebar {
                if action.kind != .newFile { continue }
            }
            let item = NSMenuItem(title: action.title, action: #selector(run(_:)), keyEquivalent: "")
            item.target = self
            item.tag = menuActions.count
            item.representedObject = action.id
            item.image = action.menuItemImage()
            menuActions.append(action)
            menu.addItem(item)
        }
        return menu.numberOfItems > 0 ? menu : nil
    }

    // MARK: - 执行

    @objc func run(_ sender: NSMenuItem) {
        log("run clicked title=\(sender.title) tag=\(sender.tag) repr=\(String(describing: sender.representedObject))")
        let source = hasConfiguration ? actions : Self.defaults
        var action: FinderAction?
        // Finder 会把菜单项序列化后再派发事件，representedObject 与 tag 谁丢了都不一定，
        // 两个都试：id 更精确，tag 作为兜底。
        if let id = sender.representedObject as? String {
            action = menuActions.first(where: { $0.id == id }) ?? source.first(where: { $0.id == id })
        }
        if action == nil, sender.tag >= 0, sender.tag < menuActions.count {
            action = menuActions[sender.tag]
        }
        guard let action else {
            log("run: no action matched")
            return
        }

        let controller = FIFinderSyncController.default()
        let targets = controller.selectedItemURLs() ?? []
        let directory = controller.targetedURL() ?? URL(fileURLWithPath: NSHomeDirectory())

        switch action.kind {
        case .copyPath:
            // 沙盒里写系统剪贴板是允许的，直接做，不依赖主 App 是否在跑
            let text = targets.isEmpty ? directory.path : targets.map(\.path).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            log("copied \(targets.count) paths")

        case .openTerminal, .openWithApp, .runCommand, .newFile:
            // 沙盒 appex 里 Process / 跨目录写盘都会被拦，统一交给主 App 执行
            enqueue(action, targets: targets, directory: directory)
        }
    }

    private func requestDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("Aurora/requests", isDirectory: true)
    }

    /// 落一份请求文件 + 推一条通知：主 App 无论因为什么原因没收到通知，都能靠文件补跑
    private func enqueue(_ action: FinderAction, targets: [URL], directory: URL) {
        let payload: [String: Any] = [
            "id": action.id,
            "kind": action.kind.rawValue,
            "argument": action.argument,
            "directory": directory.path,
            "selection": targets.map(\.path).joined(separator: "\n"),
            "created": Date().timeIntervalSince1970
        ]
        let dir = requestDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(UUID().uuidString).json")
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: file)
        }
        DistributedNotificationCenter.default().postNotificationName(
            Channel.execute,
            object: nil,
            userInfo: payload,
            deliverImmediately: true
        )
        log("enqueued \(action.kind.rawValue) at \(file.lastPathComponent) (app running=\(mainAppRunning()))")
        if !mainAppRunning() { launchMainApp() }
    }

    private func mainAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.cary.aurora").isEmpty
    }

    private func launchMainApp() {
        // Aurora.app/Contents/PlugIns/AuroraFinder.appex → Aurora.app
        let app = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

}
