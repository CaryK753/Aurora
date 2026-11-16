//  ContextMenuService.swift
//  Aurora — 右键菜单管理：读取/写入 pbs.plist 的 FinderActive 与 NSServicesStatus，
//  并扫描系统与第三方 .appex / .workflow 以列出可管理的菜单项。

import AppKit
import Combine

struct ContextMenuItem: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case quickAction     // Finder 右键「快速操作」
        case service         // 右键「服务」子菜单
        case finderExtension // 第三方 Finder 扩展

        var title: String {
            switch self {
            case .quickAction: return T("快速操作")
            case .service: return T("服务")
            case .finderExtension: return T("Finder 扩展")
            }
        }

        var symbol: String {
            switch self {
            case .quickAction: return "bolt.fill"
            case .service: return "square.stack.3d.up.fill"
            case .finderExtension: return "puzzlepiece.extension.fill"
            }
        }
    }

    let id: String
    var title: String
    var provider: String
    var kind: Kind
    var isEnabled: Bool
    var writable: Bool
}

@MainActor
final class ContextMenuService: ObservableObject {
    @Published private(set) var items: [ContextMenuItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastError: String?
    @Published private(set) var applyingIDs: Set<String> = []
    private var extensionStates: [String: Bool] = [:]
    private var electionGeneration = 0
    @Published private(set) var lastApplied = Date.distantPast

    private var finderActive: [String: Bool] = [:]
    private var serviceStatus: [String: [String: Any]] = [:]
    private var foundBundles: [String: (name: String, kind: ContextMenuItem.Kind)] = [:]
    private var pendingFinderRestart: Timer?

    private let prefsDomain = "pbs" as CFString

    init() {
        reload()
    }

    // MARK: - 读取

    func reload() {
        finderActive = (CFPreferencesCopyAppValue("FinderActive" as CFString, prefsDomain) as? [String: Bool]) ?? [:]
        serviceStatus = (CFPreferencesCopyAppValue("NSServicesStatus" as CFString, prefsDomain) as? [String: [String: Any]]) ?? [:]
        rebuildList()

        if foundBundles.isEmpty {
            if !isScanning { scanBundles() }
        } else {
            refreshExtensionStates()
        }
    }

    private func refreshExtensionStates() {
        let generation = electionGeneration
        Task {
            let query = await CommandRunner.run("/usr/bin/pluginkit", ["-m", "-A", "-D", "-p", "com.apple.FinderSync"])
            guard generation == electionGeneration, applyingIDs.isEmpty else { return }
            guard query.ok else { return }
            extensionStates = FinderElection.parse(query.output)
            rebuildList()
        }
    }

    private func rebuildList() {
        var result: [ContextMenuItem] = []

        // 1) pbs 中已登记的右键项（快速操作 / 快捷指令动作）
        for (key, enabled) in finderActive.sorted(by: { $0.key < $1.key }) {
            let bundleID = key.hasPrefix("APPEXTENSION-") ? String(key.dropFirst("APPEXTENSION-".count)) : key
            let discovered = foundBundles[bundleID]
            let title = discovered?.name ?? humanize(key)
            let provider = discovered?.name == nil ? providerFor(key) : (discovered?.name ?? "")
            result.append(
                ContextMenuItem(
                    id: key,
                    title: title,
                    provider: provider.isEmpty ? ContextMenuItem.Kind.quickAction.title : provider,
                    kind: .quickAction,
                    isEnabled: enabled,
                    writable: true
                )
            )
        }

        // 2) 扫描到但未在 pbs 登记的快速操作 / 扩展 / 服务
        for (bundleID, info) in foundBundles.sorted(by: { $0.value.name < $1.value.name }) {
            switch info.kind {
            case .quickAction:
                let key = "APPEXTENSION-\(bundleID)"
                if finderActive[key] == nil {
                    result.append(
                        ContextMenuItem(id: key, title: info.name, provider: T("快速操作"), kind: .quickAction, isEnabled: true, writable: true)
                    )
                }
            case .finderExtension:
                if !result.contains(where: { $0.id == bundleID }) {
                    result.append(
                        ContextMenuItem(id: bundleID, title: info.name, provider: T("Finder 扩展"), kind: .finderExtension, isEnabled: extensionStates[bundleID] ?? false, writable: true)
                    )
                }
            case .service:
                if !result.contains(where: { $0.id == bundleID }) {
                    result.append(
                        ContextMenuItem(id: bundleID, title: info.name, provider: T("服务"), kind: .service, isEnabled: true, writable: true)
                    )
                }
            }
        }

        // 3) NSServicesStatus 中的服务项
        for (key, value) in serviceStatus.sorted(by: { $0.key < $1.key }) {
            let enabled = (value["enabled_context_menu"] as? Bool) ?? (value["enabled_context_menu"] as? Int == 1)
            let parts = key.components(separatedBy: " - ")
            let title = parts.first ?? key
            result.append(
                ContextMenuItem(
                    id: key,
                    title: title,
                    provider: parts.count > 1 ? parts[1] : T("服务"),
                    kind: .service,
                    isEnabled: enabled,
                    writable: true
                )
            )
        }

        items = result.sorted {
            if $0.kind == $1.kind { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    /// 把 bundle id / 动作标识转成可读名称（尽可能贴近系统中文显示）
    private func humanize(_ key: String) -> String {
        var text = key
        if text.hasPrefix("APPEXTENSION-") { text = String(text.dropFirst("APPEXTENSION-".count)) }

        let known: [(needle: String, name: String)] = [
            ("CreatePDFQuickAction", T("创建 PDF")),
            ("MarkupQuickAction", T("标记")),
            ("TrimQuickAction", T("裁剪")),
            ("RotateQuickAction", T("旋转")),
            ("remove-background", T("移除背景")),
            ("image.convert.finder", T("转换图像格式")),
            ("image.removebackground", T("移除图像背景")),
            ("CreatePDF", T("创建 PDF")),
            ("QuickAction", "")
        ]
        for entry in known where text.localizedCaseInsensitiveContains(entry.needle) {
            if !entry.name.isEmpty { return entry.name }
        }

        for prefix in ["com.apple.finder.", "com.apple.pixelmator.", "is.workflow.actions.", "com.apple."] {
            if text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        }
        if text.hasSuffix(".finder") { text = String(text.dropLast(".finder".count)) }

        text = text
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
        text = text.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        text = text.replacingOccurrences(of: "([A-Z]+)([A-Z][a-z])", with: "$1 $2", options: .regularExpression)

        let words = text.split(separator: " ").map { word -> String in
            let value = String(word)
            if value.count <= 3, value == value.uppercased() { return value }
            return value.prefix(1).uppercased() + value.dropFirst()
        }
        let result = words.joined(separator: " ")
        return result.isEmpty ? key : result
    }

    private func providerFor(_ key: String) -> String {
        if key.hasPrefix("is.workflow.actions.") { return T("快捷指令") }
        return ContextMenuItem.Kind.quickAction.title
    }

    // MARK: - 扫描

    private func scanBundles() {
        isScanning = true
        let generation = electionGeneration
        let roots = [
            "/Applications",
            "/System/Applications",
            NSHomeDirectory() + "/Applications"
        ]
        let serviceDirs = [
            NSHomeDirectory() + "/Library/Services",
            "/Library/Services",
            "/System/Library/Services"
        ]

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [String: (name: String, kind: ContextMenuItem.Kind)] = [:]

            func inspect(_ url: URL) {
                guard let bundle = Bundle(url: url), let info = bundle.infoDictionary else { return }
                guard let identifier = info["CFBundleIdentifier"] as? String else { return }
                let name = (info["CFBundleDisplayName"] as? String)
                    ?? (info["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                if let extensionInfo = info["NSExtension"] as? [String: Any],
                   let point = extensionInfo["NSExtensionPointIdentifier"] as? String {
                    if point == "com.apple.services" {
                        found[identifier] = (name, .quickAction)
                    } else if point == "com.apple.FinderSync" {
                        found[identifier] = (name, .finderExtension)
                    }
                }
                if info["NSServices"] != nil, found[identifier] == nil {
                    found[identifier] = (name, .service)
                }
            }

            for root in roots {
                let fileManager = FileManager.default
                guard let enumerator = fileManager.enumerator(
                    at: URL(fileURLWithPath: root),
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                var visited = 0
                for case let url as URL in enumerator {
                    visited += 1
                    if visited > 12_000 { break }
                    let path = url.path
                    if url.pathExtension == "app" {
                        let plugins = url.appendingPathComponent("Contents/PlugIns")
                        let entries = (try? fileManager.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? []
                        for entry in entries where entry.pathExtension == "appex" { inspect(entry) }
                    }
                    if path.contains(".app/Contents/PlugIns") || path.hasSuffix(".appex") {
                        if path.hasSuffix(".appex") { inspect(url) }
                    }
                    // 深度限制：/Applications 下最多 5 层
                    if url.pathComponents.count > 7 {
                        enumerator.skipDescendants()
                    }
                }
            }

            for dir in serviceDirs {
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: dir),
                    includingPropertiesForKeys: nil
                ) else { continue }
                for entry in entries where entry.pathExtension == "workflow" || entry.pathExtension == "service" {
                    inspect(entry)
                }
            }

            let snapshot = found
            let query = CommandRunner.runSync("/usr/bin/pluginkit", ["-m", "-A", "-D", "-p", "com.apple.FinderSync"])
            let states = FinderElection.parse(query.output)
            Task { @MainActor in
                guard let self else { return }
                self.foundBundles = snapshot
                if self.electionGeneration == generation { self.extensionStates = states }
                self.isScanning = false
                self.rebuildList()
            }
        }
    }

    // MARK: - 写入

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let item = items.first(where: { $0.id == id }), item.writable,
              !applyingIDs.contains(id) else { return }
        lastError = nil
        if item.kind == .finderExtension {
            electionGeneration += 1
            applyingIDs.insert(id)
            Task {
                defer { applyingIDs.remove(id) }
                let ok = await runPluginkit(argument: enabled ? "use" : "ignore", identifier: id)
                guard ok else { return }
                extensionStates[id] = enabled
                rebuildList()
                lastApplied = Date()
                scheduleFinderRefresh()
            }
            return
        }
        let key = item.kind == .quickAction ? "FinderActive" : "NSServicesStatus"
        let previous = CFPreferencesCopyAppValue(key as CFString, prefsDomain)
        if item.kind == .quickAction {
            var updated = finderActive
            updated[id] = enabled
            CFPreferencesSetAppValue(key as CFString, updated as CFDictionary, prefsDomain)
        } else {
            var updated = serviceStatus
            var entry = updated[id] ?? [:]
            entry["enabled_context_menu"] = enabled ? 1 : 0
            entry["enabled_services_menu"] = enabled ? 1 : 0
            updated[id] = entry
            CFPreferencesSetAppValue(key as CFString, updated as CFDictionary, prefsDomain)
        }
        let synced = CFPreferencesAppSynchronize(prefsDomain)
        let stored = CFPreferencesCopyAppValue(key as CFString, prefsDomain)
        let actual: Bool?
        if item.kind == .quickAction {
            actual = (stored as? [String: Bool])?[id]
        } else {
            actual = ((stored as? [String: [String: Any]])?[id]?["enabled_context_menu"] as? NSNumber)?.boolValue
        }
        guard synced, actual == enabled else {
            CFPreferencesSetAppValue(key as CFString, previous, prefsDomain)
            CFPreferencesAppSynchronize(prefsDomain)
            lastError = T("菜单设置未保存，请在系统设置中重试")
            reload()
            return
        }
        reload()
        lastApplied = Date()
        scheduleFinderRefresh()
    }

    private func runPluginkit(argument: String, identifier: String) async -> Bool {
        let result = await CommandRunner.run("/usr/bin/pluginkit", ["-e", argument, "-i", identifier])
        guard result.ok else {
            lastError = T("扩展设置失败，请在系统设置中重试")
            return false
        }
        let query = await CommandRunner.run("/usr/bin/pluginkit", ["-m", "-A", "-D", "-i", identifier])
        guard query.ok, FinderElection.parse(query.output)[identifier] == (argument == "use") else {
            lastError = T("系统未确认扩展状态，请在系统设置中检查")
            return false
        }
        return true
    }

    private func scheduleFinderRefresh() {
        pendingFinderRestart?.invalidate()
        pendingFinderRestart = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshFinderNow() }
        }
    }

    @discardableResult
    static func restartFinder() -> Bool { DesktopService.restartFinder() }

    @discardableResult
    func refreshFinderNow() -> Bool {
        lastError = nil
        guard Self.restartFinder() else {
            lastError = T("未能重新启动访达，请手动重试")
            return false
        }
        return true
    }

    /// 供配置导入使用：启用 RClick 的 Finder 扩展
    func enableRClickExtension() {
        if let item = items.first(where: {
            $0.id.localizedCaseInsensitiveContains("rclick") || $0.title.localizedCaseInsensitiveContains("rclick")
        }) {
            if !item.isEnabled { setEnabled(true, for: item.id) }
            return
        }
        Task {
            if await runPluginkit(argument: "use", identifier: "cn.wflixu.RClick.FinderSyncExt") {
                lastApplied = Date()
                scheduleFinderRefresh()
            }
        }
    }
}
