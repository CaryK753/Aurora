//  ProxyMetricsService.swift
//  Aurora — 网络页的实时数据：流量曲线、连接列表、日志、策略组状态
//
//  数据都来自 mihomo 的本机控制器（Unix socket）。面板收起或代理停止时整条链路会停掉，
//  不在后台空转轮询。

import Foundation
import NetworkProxyKit

@MainActor
final class ProxyMetricsService: ObservableObject {
    struct TrafficPoint: Identifiable, Equatable {
        let id = UUID()
        var up: Int
        var down: Int
    }

    @Published private(set) var sample = ProxyTrafficSample()
    @Published private(set) var history: [TrafficPoint] = []
    @Published private(set) var connections: [ProxyConnection] = []
    @Published private(set) var memory = 0
    @Published private(set) var group: ProxyEntry?
    @Published private(set) var proxies: [String: ProxyEntry] = [:]
    @Published private(set) var live = false
    @Published private(set) var error: String?
    @Published private(set) var startedAt: Date?
    @Published var logPaused = false
    @Published private(set) var logs: [ProxyLogLine] = []

    private var client: ProxyControllerClient?
    private var trafficStream: ProxyControllerClient.Stream?
    private var logStream: ProxyControllerClient.Stream?
    private var pollTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var socketPath: String?
    private var visible = false
    /// 连续读失败次数：内核刚起来时第一次读可能失败，连着失败才算真的断了。
    private var failures = 0

    var downloadSpeed: Int { sample.down }
    var uploadSpeed: Int { sample.up }
    var sessionDuration: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    // MARK: - 生命周期

    func start(socketPath: String) {
        guard self.socketPath != socketPath || client == nil else {
            if visible { resume() }
            return
        }
        stop()
        self.socketPath = socketPath
        let client = ProxyControllerClient(socketPath: socketPath)
        self.client = client
        startedAt = Date()
        live = true
        error = nil
        failures = 0
        openStreams(client)
        if visible { resume() }
    }

    func stop() {
        reconnectTask?.cancel(); reconnectTask = nil
        trafficStream?.onClose = nil; trafficStream?.cancel(); trafficStream = nil
        logStream?.onClose = nil; logStream?.cancel(); logStream = nil
        pollTask?.cancel(); pollTask = nil
        client = nil
        socketPath = nil
        live = false
        failures = 0
        startedAt = nil
        connections = []
        group = nil
        proxies = [:]
        memory = 0
        history = []
        sample = ProxyTrafficSample()
    }

    /// 面板可见时才轮询；收起面板就停，避免后台每秒读一次连接表。
    func setVisible(_ value: Bool) {
        visible = value
        if value { resume() } else { pollTask?.cancel(); pollTask = nil }
    }

    private func resume() {
        guard live, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshConnections()
                await self?.refreshProxies()
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    private func openStreams(_ client: ProxyControllerClient) {
        trafficStream = try? client.stream("/traffic") { [weak self] payload in
            guard let data = payload.data(using: .utf8),
                  let sample = try? ProxyControllerPayload.traffic(data) else { return }
            Task { @MainActor in self?.apply(sample) }
        }
        trafficStream?.onClose = { [weak self] in
            Task { @MainActor in self?.streamClosed() }
        }
        logStream = try? client.stream("/logs?level=info") { [weak self] payload in
            guard let data = payload.data(using: .utf8),
                  let line = try? ProxyControllerPayload.logLine(data) else { return }
            Task { @MainActor in self?.append(line) }
        }
        logStream?.onClose = { [weak self] in
            Task { @MainActor in self?.streamClosed() }
        }
    }

    /// 内核重启、socket 被换掉时流会断。隔一秒重开一次，别让面板停在一张旧数据上。
    private func streamClosed() {
        guard live, let path = socketPath, reconnectTask == nil else { return }
        live = false
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, self.socketPath == path, self.client != nil else { return }
            self.reconnectTask = nil
            let client = ProxyControllerClient(socketPath: path)
            self.client = client
            self.failures = 0
            self.error = nil
            self.live = true
            self.openStreams(client)
            if self.visible { self.resume() }
        }
    }

    private func apply(_ sample: ProxyTrafficSample) {
        self.sample = sample
        history.append(TrafficPoint(up: sample.up, down: sample.down))
        if history.count > 90 { history.removeFirst(history.count - 90) }
    }

    private func append(_ line: ProxyLogLine) {
        guard !line.message.isEmpty, !logPaused else { return }
        logs.append(line)
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
    }

    func clearLogs() { logs.removeAll() }

    // MARK: - 拉取

    func refreshConnections() async {
        guard let client else { return }
        do {
            let data = try await client.get("/connections")
            let snapshot = try ProxyControllerPayload.connections(data)
            connections = snapshot.connections.sorted { $0.start ?? .distantPast > $1.start ?? .distantPast }
            memory = snapshot.memory
            failures = 0
            error = nil
        } catch {
            register(failure: error, fallback: T("无法读取代理连接"))
        }
    }

    func refreshProxies() async {
        guard let client else { return }
        do {
            let data = try await client.get("/proxies")
            let map = try ProxyControllerPayload.proxies(data)
            proxies = map
            group = map[ProxyConfiguration.groupName]
            failures = 0
            error = nil
        } catch {
            register(failure: error, fallback: T("无法读取策略组"))
        }
    }

    /// 读失败不代表内核真死了（刚启动、正在重载配置）。先留着界面继续试；
    /// 连续失败多次才认定断开，避免一次抖动就把整页数据清空。
    private func register(failure: Error, fallback: String) {
        failures += 1
        error = (failure as? ProxyFailure).map { NetworkProxyLocalization.text($0.message) } ?? fallback
        guard failures >= 5 else { return }
        stop()
        error = T("代理内核没有响应，请恢复原代理后重新应用")
    }

    func fetchRules() async -> [ProxyRuleInfo] {
        guard let client else { return [] }
        guard let data = try? await client.get("/rules") else { return [] }
        return (try? ProxyControllerPayload.rules(data)) ?? []
    }

    // MARK: - 操作

    func close(connectionID: String) async {
        guard let client else { return }
        _ = try? await client.request("DELETE", "/connections/\(connectionID)")
        await refreshConnections()
    }

    func closeAllConnections() async {
        guard let client else { return }
        _ = try? await client.request("DELETE", "/connections")
        await refreshConnections()
    }

    func select(node: String, group: String = ProxyConfiguration.groupName) async throws {
        guard let client else { throw ProxyFailure("代理未运行") }
        let body = try JSONSerialization.data(withJSONObject: ["name": node])
        _ = try await client.request("PUT", "/proxies/\(group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group)",
                                     body: body)
        await refreshProxies()
    }

    /// 让内核用当前策略真实请求一次测试地址，返回毫秒。失败返回 nil。
    func delay(for node: String, url: String, timeout: Int = 5000) async -> Int? {
        guard let client else { return nil }
        let name = node.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? node
        let testURL = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
        guard let data = try? await client.get("/proxies/\(name)/delay?url=\(testURL)&timeout=\(timeout)",
                                              timeout: Double(timeout) / 1000 + 3) else { return nil }
        return try? ProxyControllerPayload.delay(data)
    }
}
