//  WallpaperService.swift
//  Aurora — 壁纸调度：四种自动规则 + 显示器独立设置 + 外观 / 时间 / 屏幕变化监听

import AppKit
import Combine

@MainActor
final class WallpaperService: ObservableObject {
    struct DisplayInfo: Identifiable {
        let id: String
        let name: String
        let frame: CGRect
        let isMain: Bool
        let pixelText: String
    }

    @Published private(set) var config: WallpaperConfig
    @Published private(set) var current: [String: String] = [:]
    @Published private(set) var isDarkAppearance: Bool
    @Published private(set) var nextRotateAt: Date?
    @Published private(set) var displayTick = 0
    @Published private(set) var isRunning = false

    let library: WallpaperLibrary

    private let renderer = WallpaperRenderer()
    private var timer: Timer?
    private var centerObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var randomPicks: [String: String] = [:]
    private var poolCache: (signature: String, items: [WallpaperItem], at: Date)?

    init(library: WallpaperLibrary) {
        self.library = library
        self.config = WallpaperConfig.load()
        self.isDarkAppearance = Self.systemIsDark()
    }

    // MARK: - 显示器

    static func systemIsDark() -> Bool {
        if let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") {
            return style.lowercased() == "dark"
        }
        return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func displayKey(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
            return (CFUUIDCreateString(nil, uuid) as String).uppercased()
        }
        return screen.localizedName
    }

    var displays: [DisplayInfo] {
        _ = displayTick
        return NSScreen.screens.map { screen in
            let key = Self.displayKey(for: screen)
            let scale = screen.backingScaleFactor
            let pixelText = "\(Int(screen.frame.width * scale)) × \(Int(screen.frame.height * scale))"
            return DisplayInfo(
                id: key,
                name: screen.localizedName,
                frame: screen.frame,
                isMain: screen == NSScreen.main,
                pixelText: pixelText
            )
        }
    }

    func currentItem(for displayKey: String) -> WallpaperItem? {
        guard let id = current[displayKey] else { return nil }
        return library.item(id: id)
    }

    func isOverridden(_ displayKey: String) -> Bool {
        !(config.perDisplay[displayKey] ?? "").isEmpty
    }

    var activeRule: WallpaperRule { config.rule }

    // MARK: - 开关

    func activateIfNeeded() {
        guard config.enabled, !isRunning else { return }
        start()
        apply(reason: "launch", force: true)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != config.enabled else { return }
        config.enabled = enabled
        persist()
        if enabled {
            start()
            apply(reason: "enable", force: true)
        } else {
            stop()
            teardown()
        }
    }

    private func start() {
        guard !isRunning else { return }
        isRunning = true
        installObservers()
        timer?.invalidate()
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.apply(reason: "tick") }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if config.rule.kind == .random, nextRotateAt == nil {
            scheduleNextRotation()
        }
    }

    private func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        for observer in centerObservers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        centerObservers.removeAll()
        workspaceObservers.removeAll()
        distributedObservers.removeAll()
    }

    /// 让桌面回到系统自己的壁纸
    func teardown() {
        renderer.clearAll()
        current = [:]
    }

    private func installObservers() {
        guard centerObservers.isEmpty, workspaceObservers.isEmpty, distributedObservers.isEmpty else { return }

        centerObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.displayTick += 1
                self.apply(reason: "screens", force: true)
            }
        })

        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.apply(reason: "wake", force: true) }
        })

        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.apply(reason: "space") }
        })

        // 系统外观（浅色 / 深色）变化
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isDarkAppearance = Self.systemIsDark()
                self.apply(reason: "appearance")
            }
        })
    }

    // MARK: - 规则

    func setFill(_ fill: WallpaperFill) {
        config.fill = fill
        persist()
        apply(reason: "fill", force: true)
    }

    func setRule(_ rule: WallpaperRule) {
        config.rule = rule.normalized()
        randomPicks.removeAll()
        scheduleNextRotation()
        persist()
        apply(reason: "rule", force: true)
    }

    func setDisplayItem(_ itemID: String?, for displayKey: String) {
        if let itemID, !itemID.isEmpty {
            config.perDisplay[displayKey] = itemID
        } else {
            config.perDisplay.removeValue(forKey: displayKey)
        }
        persist()
        apply(reason: "display", force: true)
    }

    func setDisplayFill(_ fill: WallpaperFill?, for displayKey: String) {
        if let fill {
            config.perDisplayFill[displayKey] = fill
        } else {
            config.perDisplayFill.removeValue(forKey: displayKey)
        }
        persist()
        apply(reason: "displayFill", force: true)
    }

    /// 「用这张当壁纸」：把当前规则改成固定这一张并打开开关
    func useAsWallpaper(_ item: WallpaperItem) {
        var rule = config.rule
        rule.kind = .single
        rule.single = item.id
        config.rule = rule
        config.enabled = true
        persist()
        start()
        apply(reason: "use", force: true)
    }

    /// 只在某个显示器上用这张
    func useOnDisplay(_ item: WallpaperItem, displayKey: String) {
        setDisplayItem(item.id, for: displayKey)
        if !config.enabled {
            config.enabled = true
            persist()
            start()
        }
        apply(reason: "useDisplay", force: true)
    }

    func rotateNow() {
        randomPicks.removeAll()
        scheduleNextRotation()
        apply(reason: "rotate", force: true)
    }

    private func scheduleNextRotation() {
        guard config.rule.kind == .random else {
            nextRotateAt = nil
            return
        }
        nextRotateAt = Date().addingTimeInterval(TimeInterval(max(1, config.rule.randomInterval) * 60))
    }

    // MARK: - 解析 + 应用

    private func randomPool() -> [WallpaperItem] {
        let signature = config.rule.randomSource.rawValue + "|" + config.rule.randomFolder
        if let cache = poolCache, cache.signature == signature,
           Date().timeIntervalSince(cache.at) < 300, !cache.items.isEmpty {
            return cache.items
        }
        let items: [WallpaperItem]
        if config.rule.randomSource == .folder, !config.rule.randomFolder.isEmpty {
            items = WallpaperLibrary.scanFolder(config.rule.randomFolder)
        } else {
            items = library.items
        }
        poolCache = (signature, items, Date())
        return items
    }

    private func randomItemID(for key: String) -> String? {
        if let existing = randomPicks[key], library.item(id: existing) != nil { return existing }
        let pool = randomPool().filter { $0.fileExists }
        guard !pool.isEmpty else { return nil }
        let pick = pool.randomElement()!
        randomPicks[key] = pick.id
        return pick.id
    }

    private func scheduleItemID(at date: Date) -> String? {
        let slots = config.rule.slots.filter { !$0.itemID.isEmpty }
        guard !slots.isEmpty else { return nil }
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let now = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let sorted = slots.sorted { $0.minutes <= $1.minutes }
        if let match = sorted.last(where: { $0.minutes <= now }) { return match.itemID }
        // 还没到第一个时间点：沿用前一天最后一个，保证一天 24 小时都有画面
        return sorted.last?.itemID
    }

    private func resolvedItemID(for key: String, at date: Date) -> String? {
        if let fixed = config.perDisplay[key], !fixed.isEmpty { return fixed }
        switch config.rule.kind {
        case .single:
            return config.rule.single.isEmpty ? nil : config.rule.single
        case .appearance:
            let preferred = isDarkAppearance ? config.rule.dark : config.rule.light
            if !preferred.isEmpty { return preferred }
            let fallback = isDarkAppearance ? config.rule.light : config.rule.dark
            return fallback.isEmpty ? nil : fallback
        case .schedule:
            return scheduleItemID(at: date)
        case .random:
            return randomItemID(for: key)
        }
    }

    /// 当前时间点应当显示的壁纸（给 UI 显示「现在生效」用）
    func previewResolution(displayKey: String? = nil) -> WallpaperItem? {
        let key = displayKey ?? displays.first?.id ?? ""
        guard let id = resolvedItemID(for: key, at: Date()) else { return nil }
        return library.item(id: id)
    }

    func apply(reason: String, force: Bool = false) {
        guard config.enabled else { return }
        if isRunning == false { start() }

        if config.rule.kind == .random, let due = nextRotateAt, Date() >= due {
            randomPicks.removeAll()
            scheduleNextRotation()
        }

        let targets = NSScreen.screens.map { ScreenTarget(key: Self.displayKey(for: $0), screen: $0) }
        renderer.sync(screens: targets)

        var resolved: [String: String] = [:]
        for target in targets {
            guard let id = resolvedItemID(for: target.key, at: Date()),
                  let item = library.item(id: id), item.fileExists else {
                renderer.clear(key: target.key)
                continue
            }
            let fill = config.perDisplayFill[target.key] ?? config.fill
            let animated = current[target.key] != nil
            renderer.show(item: item, fill: fill, on: target.key, screen: target.screen, animated: animated)
            resolved[target.key] = id
        }

        if resolved != current || force {
            current = resolved
            Debug.log("wallpaper apply reason=\(reason) displays=\(resolved.count)")
        }
    }

    // MARK: - 持久化

    private func persist() {
        config.save()
    }

    // MARK: - 状态文案

    var nextRotateText: String? {
        guard config.rule.kind == .random, let next = nextRotateAt else { return nil }
        let remaining = max(0, Int(next.timeIntervalSinceNow))
        if remaining >= 60 { return TF("%d 分钟后换一张", remaining / 60) }
        return TF("%d 秒后换一张", remaining)
    }

    var activeSummary: String {
        switch config.rule.kind {
        case .single:
            guard let item = library.item(id: config.rule.single) else { return T("还没有选择壁纸") }
            return item.name
        case .appearance:
            let id = isDarkAppearance ? config.rule.dark : config.rule.light
            let name = library.item(id: id)?.name ?? T("未指定")
            return TF("当前%@ · %@", isDarkAppearance ? T("深色") : T("浅色"), name)
        case .schedule:
            let name = previewResolution()?.name ?? T("未指定")
            return TF("当前时段 · %@", name)
        case .random:
            return nextRotateText ?? T("等待轮播")
        }
    }
}
