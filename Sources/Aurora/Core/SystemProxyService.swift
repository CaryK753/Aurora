//  SystemProxyService.swift
//  Aurora — 系统代理：订阅、策略组、内核生命周期与恢复
//
//  代理本体是独立下载的 mihomo：配置由 NetworkProxyKit 生成，控制口走本机 Unix socket，
//  面板上的流量/连接/日志由 ProxyMetricsService 从这里接出去。

import AppKit
import Combine
import Foundation
import NetworkProxyKit
import UniformTypeIdentifiers

@MainActor
final class SystemProxyService: ObservableObject {
    @Published var profile: ProxyProfile
    @Published private(set) var hasBackup = SystemProxyPreferences.hasBackup
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    @Published private(set) var status = ""
    @Published private(set) var engineInstalled = false
    @Published private(set) var mainlandUpdatedAt: Date?
    @Published private(set) var nodeLatencies: [String: Int] = [:]
    @Published private(set) var failedNodes = Set<String>()
    @Published private(set) var testingNodes = false
    @Published private(set) var throughputMbps: Double?
    @Published private(set) var testingSpeed = false
    /// 新订阅地址的输入框内容（只有点“添加”时才落库）。
    @Published var draftSubscriptionURL = ""

    let runtime = ProxyEngineRuntime()
    let metrics = ProxyMetricsService()
    /// Tailscale 组网出口的 SOCKS 端口；由 AppState 注入，没有就返回 nil。
    var tailscaleOutletPort: (() -> Int?)?

    private var saveObserver: AnyCancellable?
    private var hasEdits = false
    private var subscriptionTimer: Timer?

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aurora/Network", isDirectory: true)
    }
    var executable: URL { Self.directory.appendingPathComponent("mihomo") }
    var mainlandURL: URL { Self.directory.appendingPathComponent("mainland.yaml") }
    var profileURL: URL { Self.directory.appendingPathComponent("profile.json") }
    var controllerSocket: URL { Self.directory.appendingPathComponent("controller.sock") }
    var ruleSetDirectory: URL { Self.directory.appendingPathComponent("rules", isDirectory: true) }
    var isLocked: Bool { hasBackup || isBusy }
    var isRunning: Bool { runtime.isRunning }

    init() {
        let url = Self.directory.appendingPathComponent("profile.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { profile = try ProxyProfileStorage.load(from: url) }
            catch { profile = ProxyProfile(); self.error = T("本地订阅配置读取失败，请重新导入") }
        } else { profile = ProxyProfile() }
        normalizeSelection(save: true)
        engineInstalled = FileManager.default.isExecutableFile(atPath: executable.path)
        mainlandUpdatedAt = Self.modificationDate(mainlandURL)
        if hasBackup { status = T("检测到上次保留的代理配置，请先恢复原配置") }
        saveObserver = $profile.dropFirst()
            .handleEvents(receiveOutput: { [weak self] _ in self?.hasEdits = true })
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] profile in
                guard let self else { return }
                do { try ProxyProfileStorage.save(profile, to: self.profileURL) }
                catch { self.error = T("本地订阅配置保存失败") }
            }
        runtime.onUnexpectedExit = { [weak self] in self?.recoverAfterEngineExit() }
        configureSubscriptionTimer()
    }

    deinit { subscriptionTimer?.invalidate() }

    // MARK: - 订阅

    var subscriptions: [SubscriptionProfile] { profile.subscriptions }
    var activeSubscription: SubscriptionProfile? { profile.activeSubscription }
    var nodes: [ProxyNode] { activeSubscription?.selectableNodes ?? [] }
    var selectedNode: String { profile.settings.selectedNode }

    func activate(_ id: UUID) {
        guard profile.subscriptions.contains(where: { $0.id == id }) else { return }
        profile.activeSubscriptionID = id
        profile.settings.source = "subscription"
        normalizeSelection(save: false)
    }

    @discardableResult
    func addSubscription(urlString: String) -> Bool {
        let text = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            error = T("请输入有效的 HTTP 或 HTTPS 地址")
            return false
        }
        let subscription = SubscriptionProfile(name: SubscriptionProfile.suggestedName(for: text, existing: subscriptions),
                                               url: text, refreshHours: 24)
        profile.subscriptions.append(subscription)
        profile.activeSubscriptionID = subscription.id
        profile.settings.source = "subscription"
        draftSubscriptionURL = ""
        Task { await updateSubscription(subscription.id) }
        return true
    }

    func removeSubscription(_ id: UUID) {
        let wasActive = profile.activeSubscriptionID == id || profile.activeSubscription?.id == id
        profile.subscriptions.removeAll { $0.id == id }
        if wasActive {
            profile.activeSubscriptionID = profile.subscriptions.first?.id
            normalizeSelection(save: false)
        }
        configureSubscriptionTimer()
    }

    func renameSubscription(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = profile.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        profile.subscriptions[index].name = trimmed
    }

    func setRefresh(hours: Int, for id: UUID) {
        guard let index = profile.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        profile.subscriptions[index].refreshHours = hours
        configureSubscriptionTimer()
    }

    func updateActiveSubscription() async {
        guard let id = profile.activeSubscription?.id else { return }
        await updateSubscription(id)
    }

    func updateSubscription(_ id: UUID) async {
        guard !isBusy else { return }
        guard let index = profile.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let text = profile.subscriptions[index].url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            error = T("请输入有效的 HTTP 或 HTTPS 地址")
            return
        }
        perform(T("正在下载订阅")) { try await self.download(url, into: id) }
    }

    private func download(_ url: URL, into id: UUID) async throws {
        let data = try await ProxyHTTPClient.fetch(url)
        let subscription = try await Task.detached(priority: .utility) { try SubscriptionParser.parse(data) }.value
        accept(subscription, id: id)
        status = T("订阅已导入") + " · \(subscription.nodes.count)"
    }

    private func accept(_ subscription: ProxySubscription, id: UUID) {
        guard let index = profile.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let previous = profile.settings.selectedNode
        profile.subscriptions[index].nodes = subscription.nodes
        profile.subscriptions[index].rules = subscription.rules
        profile.subscriptions[index].warnings = subscription.warnings
        profile.subscriptions[index].format = subscription.format
        profile.subscriptions[index].updatedAt = Date()
        profile.updatedAt = Date()
        if profile.activeSubscriptionID == id || profile.activeSubscription?.id == id {
            let usable = subscription.nodes.filter { !$0.isLikelyStatusEntry }
            if !usable.contains(where: { $0.name == previous }) {
                profile.settings.selectedNode = usable.first?.name ?? ""
            }
        }
        configureSubscriptionTimer()
    }

    func importConfigurationFile() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["yaml", "yml", "json", "conf", "txt"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.perform(T("正在导入配置")) {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let subscription = try await Task.detached(priority: .utility) { try SubscriptionParser.parse(data) }.value
                let profile = SubscriptionProfile(subscription: subscription, name: url.lastPathComponent,
                                                  url: url.absoluteString, updatedAt: Date())
                if let index = self.profile.subscriptions.firstIndex(where: { $0.url == url.absoluteString }) {
                    self.accept(subscription, id: self.profile.subscriptions[index].id)
                } else {
                    self.profile.subscriptions.append(profile)
                    self.profile.activeSubscriptionID = profile.id
                    self.profile.settings.source = "subscription"
                    self.normalizeSelection(save: false)
                }
                self.status = T("配置已导入") + " · \(subscription.nodes.count)"
            }
        }
    }

    // MARK: - 选择节点与测速

    func selectNode(_ name: String) {
        profile.settings.selectedNode = name
        guard hasBackup, metrics.live else { return }
        Task {
            try? await metrics.select(node: name)
            status = T("已切换节点") + " · \(name)"
        }
    }

    func rotateGroupType(_ type: ProxyGroupType) {
        profile.settings.groupType = type
    }

    func testNodes() async {
        guard !testingNodes, !nodes.isEmpty else { return }
        testingNodes = true
        nodeLatencies = [:]
        failedNodes = []
        let candidates = nodes
        if metrics.live {
            for batch in candidates.chunked(into: 4) {
                await withTaskGroup(of: (String, Int?).self) { group in
                    for node in batch {
                        group.addTask { @MainActor in
                            (node.id, await self.metrics.delay(for: node.name, url: self.profile.settings.testURL))
                        }
                    }
                    for await (name, delay) in group {
                        if let delay { nodeLatencies[name] = delay } else { failedNodes.insert(name) }
                    }
                }
            }
        } else {
            await withTaskGroup(of: (String, Int?).self) { group in
                for node in candidates {
                    group.addTask { (node.id, await ProxyNodeTester.latency(node)) }
                }
                for await (name, delay) in group {
                    if let delay { nodeLatencies[name] = delay } else { failedNodes.insert(name) }
                }
            }
        }
        testingNodes = false
        status = T("节点连接测试完成")
    }

    /// 通过当前策略真实下载一段数据，算出 Mbit/s。失败只报错，不影响配置。
    func measureThroughput() async {
        guard !testingSpeed else { return }
        guard runtime.isRunning else { error = T("请先应用代理再测速"); return }
        testingSpeed = true
        throughputMbps = nil
        let port = profile.settings.localPort
        let target = profile.settings.speedTestURL
        let format = "%{speed_download}"
        let result = await Task.detached(priority: .utility) {
            CommandRunner.runSync("/usr/bin/curl", [
                "--silent", "--show-error", "--max-time", "10",
                "--proxy", "http://127.0.0.1:\(port)",
                "--output", "/dev/null", "--write-out", format, target
            ], timeout: 20)
        }.value
        testingSpeed = false
        if result.ok, let bytes = Double(result.output.trimmingCharacters(in: .whitespacesAndNewlines)), bytes > 0 {
            throughputMbps = bytes * 8 / 1_000_000
        } else {
            error = T("下载测速失败，换一个测速地址再试")
        }
    }

    // MARK: - 规则

    func rulePlan() -> [ProxyRuleEntry] {
        let subscription = profile.settings.source == "manual" ? (try? manualSubscription()) ?? ProxySubscription() : profile.subscription
        return (try? ProxyRulePlanner.plan(settings: profile.settings, subscription: subscription,
                                           tailscaleAvailable: tailscaleOutletPort?() != nil)) ?? []
    }

    func testRule(host: String, port: Int) -> ProxyRuleTester.Result {
        ProxyRuleTester.test(host: host, port: port, plan: rulePlan())
    }

    func addRuleSet(name: String, url: String, behavior: ProxyRuleSet.Behavior, direct: Bool) -> Bool {
        let set = ProxyRuleSet(name: name.trimmingCharacters(in: .whitespaces),
                               url: url.trimmingCharacters(in: .whitespaces),
                               behavior: behavior, direct: direct)
        guard set.isValid else { error = T("规则集名称或地址无效"); return false }
        guard !profile.settings.ruleSets.contains(where: { $0.providerName == set.providerName }) else {
            error = T("规则集名称重复，换一个名字再试")
            return false
        }
        profile.settings.ruleSets.append(set)
        return true
    }

    func removeRuleSet(_ id: UUID) {
        profile.settings.ruleSets.removeAll { $0.id == id }
    }

    func updateRuleSet(_ set: ProxyRuleSet) {
        guard let index = profile.settings.ruleSets.firstIndex(where: { $0.id == set.id }) else { return }
        profile.settings.ruleSets[index] = set
    }

    // MARK: - 内核与地址库

    func installEngine() {
        guard !isLocked else { return }
        perform(T("正在下载并校验代理内核")) {
            let version = try await ProxyEngineInstaller.install(in: Self.directory)
            self.engineInstalled = true
            self.status = T("代理内核已安装") + " · " + version
        }
    }

    func removeEngine() {
        guard !isLocked else { return }
        do {
            if FileManager.default.fileExists(atPath: executable.path) {
                try FileManager.default.removeItem(at: executable)
            }
            engineInstalled = false
            status = T("代理内核已删除")
        } catch { self.error = T("无法删除代理内核") }
    }

    func updateMainland() {
        guard !isLocked else { return }
        perform(T("正在更新大陆 IP 地址库")) { try await self.downloadMainland(); self.status = T("大陆 IP 地址库已更新") }
    }

    // MARK: - 应用与恢复

    func apply() async {
        guard !isLocked else { return }
        perform(T("正在应用系统代理")) { try await self.applyInternal() }
    }

    private func applyInternal() async throws {
        var subscription = profile.subscription
        var settings = profile.settings
        if settings.source == "manual", settings.mode != .direct {
            subscription = try manualSubscription()
            settings.selectedNode = subscription.nodes[0].name
        }
        guard settings.mode == .direct || subscription.nodes.contains(where: { !$0.isLikelyStatusEntry }) else {
            throw ProxyFailure("请先导入订阅或填好手动节点")
        }
        if settings.mode == .direct {
            try await Task.detached { try SystemProxyPreferences.applyDirect() }.value
            hasBackup = SystemProxyPreferences.hasBackup
            status = T("直连模式已生效")
            return
        }
        guard engineInstalled else { throw ProxyFailure("请先下载代理内核") }
        if settings.mode == .rule, settings.bypassMainland {
            let stale = mainlandUpdatedAt.map { Date().timeIntervalSince($0) > 7 * 86400 } ?? true
            if mainlandUpdatedAt == nil || (stale && settings.refreshMainlandOnStart) {
                // 更新失败保留旧库；完全没有地址库时不启动一个名不符实的规则模式。
                do { try await downloadMainland() }
                catch {
                    guard mainlandUpdatedAt != nil else { throw error }
                    self.error = T("地址库更新失败，本次使用缓存数据")
                }
            }
        }
        try FileManager.default.createDirectory(at: ruleSetDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: controllerSocket.path) {
            try? FileManager.default.removeItem(at: controllerSocket)
        }
        let data = try ProxyConfiguration.generate(settings: settings, subscription: subscription,
                                                   mainlandFile: mainlandUpdatedAt == nil ? nil : mainlandURL.path,
                                                   controllerSocket: controllerSocket.path,
                                                   tailscalePort: tailscaleOutletPort?())
        let config = Self.directory.appendingPathComponent("active.json")
        try ProxyProfileStorage.save(data, to: config)
        try await runtime.start(executable: executable, config: config, directory: Self.directory, port: settings.localPort)
        metrics.start(socketPath: controllerSocket.path)
        do {
            try await Task.detached {
                try SystemProxyPreferences.apply(host: "127.0.0.1", port: settings.localPort, socks: false)
            }.value
            guard runtime.isRunning else { throw ProxyFailure("代理内核已退出，请恢复原代理配置") }
        } catch {
            // 写入失败仍可能已经提交；有恢复备份时保留内核以便用户恢复。
            metrics.stop()
            if !SystemProxyPreferences.hasBackup { await runtime.stop() }
            else if !runtime.isRunning {
                do { try await restoreConfiguration() }
                catch { throw ProxyFailure("代理内核已退出且恢复失败，请恢复原代理配置") }
            }
            throw error
        }
        hasBackup = SystemProxyPreferences.hasBackup
        profile.settings.selectedNode = settings.selectedNode
        status = T("系统代理已应用")
    }

    func restore() {
        guard !isBusy else { return }
        perform(T("正在恢复原代理配置")) { try await self.restoreConfiguration(); self.status = T("已恢复原代理配置") }
    }

    func restoreForTermination() async throws {
        guard !isBusy else { throw ProxyFailure("网络操作尚未完成，请稍后退出") }
        isBusy = true
        defer { isBusy = false }
        if hasEdits {
            do { try ProxyProfileStorage.save(profile, to: profileURL) }
            catch { self.error = T("本地订阅配置保存失败") }
        }
        try await restoreConfiguration()
    }

    private func restoreConfiguration() async throws {
        if SystemProxyPreferences.hasBackup {
            try await Task.detached { try SystemProxyPreferences.restore() }.value
        }
        hasBackup = SystemProxyPreferences.hasBackup
        await runtime.stop()
        metrics.stop()
    }

    // MARK: - 内部

    private func manualSubscription() throws -> ProxySubscription {
        let settings = profile.settings
        let host = settings.manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(where: \.isWhitespace), (1...65535).contains(settings.manualPort) else {
            throw ProxyFailure("先填有效的代理主机和端口")
        }
        let node = try ProxyNode(["name": "Manual", "type": settings.manualKind, "server": host, "port": settings.manualPort])
        return ProxySubscription(nodes: [node])
    }

    /// 选中的节点必须还在可用节点里，且不能是订阅商的信息伪节点。
    private func normalizeSelection(save: Bool) {
        let usable = nodes
        if !usable.contains(where: { $0.name == profile.settings.selectedNode }) {
            profile.settings.selectedNode = usable.first?.name ?? ""
            if save { try? ProxyProfileStorage.save(profile, to: profileURL) }
        }
    }

    private func downloadMainland() async throws {
        let data = try await ProxyHTTPClient.fetch(MainlandRanges.sourceURL, limit: 15 * 1024 * 1024)
        let output = try await Task.detached(priority: .utility) {
            guard let text = String(data: data, encoding: .utf8) else { throw ProxyFailure("大陆 IP 数据编码无效") }
            let ranges = try MainlandRanges.parse(text)
            guard ranges.count > 1000 else { throw ProxyFailure("大陆 IP 数据不完整") }
            return try MainlandRanges.providerData(ranges)
        }.value
        try ProxyProfileStorage.save(output, to: mainlandURL)
        mainlandUpdatedAt = Self.modificationDate(mainlandURL)
    }

    private func configureSubscriptionTimer() {
        subscriptionTimer?.invalidate()
        subscriptionTimer = nil
        let hours = profile.activeSubscription?.refreshHours ?? 0
        guard hours > 0 else { return }
        subscriptionTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(hours * 3600), repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isLocked, let id = self.profile.activeSubscription?.id else { return }
                await self.updateSubscription(id)
            }
        }
    }

    private func perform(_ message: String, operation: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true; error = nil; status = message
        Task {
            do { try await operation() }
            catch {
                if let failure = error as? ProxyFailure { self.error = NetworkProxyLocalization.text(failure.message) }
                else if (error as NSError).domain == "Aurora.SystemProxy" { self.error = error.localizedDescription }
                else { self.error = T("网络操作失败，请检查配置和网络连接") }
                status = ""
            }
            hasBackup = SystemProxyPreferences.hasBackup
            isBusy = false
        }
    }

    private func recoverAfterEngineExit() {
        guard !isBusy, hasBackup else { return }
        perform(T("代理内核已退出，正在恢复网络")) {
            try await self.restoreConfiguration()
            self.error = T("代理内核意外退出，已恢复原代理配置")
        }
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
