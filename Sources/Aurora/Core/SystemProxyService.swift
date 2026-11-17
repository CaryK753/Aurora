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
    let runtime = ProxyEngineRuntime()
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
    var isLocked: Bool { hasBackup || isBusy }

    init() {
        let url = Self.directory.appendingPathComponent("profile.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { profile = try ProxyProfileStorage.load(from: url) }
            catch { profile = ProxyProfile(); self.error = T("本地订阅配置读取失败，请重新导入") }
        } else { profile = ProxyProfile() }
        if profile.subscription.nodes.first(where: { $0.name == profile.settings.selectedNode })?.isLikelyStatusEntry == true,
           let fallback = profile.subscription.nodes.first(where: { !$0.isLikelyStatusEntry }) {
            profile.settings.selectedNode = fallback.name
            try? ProxyProfileStorage.save(profile, to: url)
        }
        engineInstalled = FileManager.default.isExecutableFile(atPath: executable.path)
        mainlandUpdatedAt = Self.modificationDate(mainlandURL)
        if hasBackup { status = T("检测到上次保留的代理配置，请先恢复原配置") }
        saveObserver = $profile.dropFirst().handleEvents(receiveOutput: { [weak self] _ in self?.hasEdits = true }).debounce(for: .milliseconds(400), scheduler: RunLoop.main).sink { [weak self] profile in
            guard let self else { return }
            do { try ProxyProfileStorage.save(profile, to: self.profileURL) }
            catch { self.error = T("本地订阅配置保存失败") }
        }
        runtime.onUnexpectedExit = { [weak self] in self?.recoverAfterEngineExit() }
        configureSubscriptionTimer()
    }

    deinit { subscriptionTimer?.invalidate() }

    func importSubscription() {
        guard !isBusy else { return }
        guard let url = URL(string: profile.settings.subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = T("请输入有效的 HTTP 或 HTTPS 地址"); return
        }
        perform(T("正在下载订阅")) { try await self.updateSubscription(from: url) }
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
                try self.accept(subscription)
                self.status = T("配置已导入") + " · \(subscription.nodes.count)"
            }
        }
    }

    func updateRefreshInterval(_ hours: Int) {
        profile.settings.subscriptionRefreshHours = hours
        configureSubscriptionTimer()
    }

    func testNodes() {
        guard !isBusy, !testingNodes, !profile.subscription.nodes.isEmpty else { return }
        testingNodes = true
        nodeLatencies = [:]
        failedNodes = []
        let nodes = profile.subscription.nodes
        Task {
            await withTaskGroup(of: (String, Int?).self) { group in
                for node in nodes { group.addTask { (node.id, await ProxyNodeTester.latency(node)) } }
                for await result in group {
                    if let latency = result.1 { nodeLatencies[result.0] = latency }
                    else { failedNodes.insert(result.0) }
                }
            }
            testingNodes = false
            status = T("节点连接测试完成")
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

    func installEngine() {
        guard !isLocked else { return }
        perform(T("正在下载并校验代理内核")) {
            let version = try await ProxyEngineInstaller.install(in: Self.directory)
            self.engineInstalled = true
            self.status = T("代理内核已安装") + " · " + version
        }
    }

    func updateMainland() {
        guard !isLocked else { return }
        perform(T("正在更新大陆 IP 地址库")) { try await self.downloadMainland(); self.status = T("大陆 IP 地址库已更新") }
    }

    func apply(manual: NetworkTunnelService) {
        guard !isLocked else { return }
        var subscription = profile.subscription
        var settings = profile.settings
        if settings.source == "manual", settings.mode != .direct {
            do {
                guard let port = Int(manual.proxyPort) else { throw ProxyFailure("先填有效的代理主机和端口") }
                let node = try ProxyNode(["name": "Manual", "type": manual.proxyKind.rawValue,
                                          "server": manual.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines), "port": port])
                subscription = ProxySubscription(nodes: [node])
                settings.selectedNode = node.name
            } catch { self.error = T("先填有效的代理主机和端口"); return }
        }
        let snapshot = subscription
        let options = settings
        perform(T("正在应用系统代理")) {
            if options.mode == .direct {
                try await Task.detached { try SystemProxyPreferences.applyDirect() }.value
            } else {
                guard self.engineInstalled else { throw ProxyFailure("请先下载代理内核") }
                if options.mode == .rule, options.bypassMainland {
                    let stale = self.mainlandUpdatedAt.map { Date().timeIntervalSince($0) > 7 * 86400 } ?? true
                    if self.mainlandUpdatedAt == nil || (stale && options.refreshMainlandOnStart) {
                        // 更新失败保留旧库；没有任何地址库时不启动一个名不符实的规则模式。
                        do { try await self.downloadMainland() }
                        catch {
                            guard self.mainlandUpdatedAt != nil else { throw error }
                            self.error = T("地址库更新失败，本次使用缓存数据")
                        }
                    }
                }
                let data = try ProxyConfiguration.generate(settings: options, subscription: snapshot,
                    mainlandFile: self.mainlandUpdatedAt == nil ? nil : self.mainlandURL.path)
                let config = Self.directory.appendingPathComponent("active.json")
                try ProxyProfileStorage.save(data, to: config)
                try await self.runtime.start(executable: self.executable, config: config, directory: Self.directory, port: options.localPort)
                do {
                    try await Task.detached { try SystemProxyPreferences.apply(host: "127.0.0.1", port: options.localPort, socks: false) }.value
                    guard self.runtime.isRunning else { throw ProxyFailure("代理内核已退出，请恢复原配置") }
                } catch {
                    // 写入失败仍可能已经提交；有恢复备份时保留内核以便用户恢复。
                    if !SystemProxyPreferences.hasBackup { await self.runtime.stop() }
                    else if !self.runtime.isRunning {
                        do { try await self.restoreConfiguration() }
                        catch { throw ProxyFailure("代理内核已退出且恢复失败，请恢复原配置") }
                    }
                    throw error
                }
            }
            self.status = T("系统代理已应用")
        }
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

    private func updateSubscription(from url: URL) async throws {
        let data = try await ProxyHTTPClient.fetch(url)
        let subscription = try await Task.detached(priority: .utility) { try SubscriptionParser.parse(data) }.value
        try accept(subscription)
        status = T("订阅已导入") + " · \(subscription.nodes.count)"
    }

    private func accept(_ subscription: ProxySubscription) throws {
        let previous = profile.settings.selectedNode
        profile.subscription = subscription
        profile.updatedAt = Date()
        profile.settings.source = "subscription"
        let previousNode = subscription.nodes.first { $0.name == previous }
        profile.settings.selectedNode = previousNode.map { !$0.isLikelyStatusEntry } == true
            ? previous : (subscription.nodes.first { !$0.isLikelyStatusEntry } ?? subscription.nodes[0]).name
        try ProxyProfileStorage.save(profile, to: profileURL)
    }

    private func configureSubscriptionTimer() {
        subscriptionTimer?.invalidate()
        subscriptionTimer = nil
        let hours = profile.settings.subscriptionRefreshHours ?? 0
        guard hours > 0 else { return }
        subscriptionTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(hours * 3600), repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isLocked,
                      let url = URL(string: self.profile.settings.subscriptionURL),
                      self.profile.settings.source == "subscription" else { return }
                self.perform(T("正在自动更新订阅")) { try await self.updateSubscription(from: url) }
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
        if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
