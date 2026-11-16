//  IMEHealthService.swift
//  Aurora — 输入法健康监测
//
//  macOS 自带输入法的 SCIM / CursorUIViewService 进程是「Mac 打字卡死」的惯犯
//  （V2EX 上多年老毛病）。这里定期采样这两个进程的内存与 CPU，
//  异常时提醒并提供一键修复（安全终止进程，系统会自动拉起新的）。

import AppKit
import Combine

struct IMEProcessStatus: Identifiable, Equatable {
    let name: String
    /// 展示名
    let label: String
    var pid: Int32?
    var memoryMB: Double
    var cpuPercent: Double
    /// 连续异常（内存超限或 CPU 持续偏高）
    var stuck: Bool

    var id: String { name }
    var running: Bool { pid != nil }
}

struct IMEHealthEvent: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let processName: String
    let reason: String
    var repaired: Bool
}

@MainActor
final class IMEHealthService: ObservableObject {
    @Published var monitoringEnabled: Bool {
        didSet { ud.set(monitoringEnabled, forKey: Keys.enabled); applyEnabled() }
    }
    @Published private(set) var processes: [IMEProcessStatus] = []
    @Published private(set) var events: [IMEHealthEvent] = []
    @Published private(set) var lastChecked: Date?
    @Published private(set) var repairingIDs: Set<String> = []

    var onToast: ((String, String) -> Void)?

    /// 内存超过这个值（MB）判定异常
    static let memoryLimitMB: Double = 500
    /// CPU 连续超过这个百分比判定异常
    static let cpuLimitPercent: Double = 35

    private let ud = UserDefaults.standard
    private enum Keys {
        static let enabled = "input.health.enabled"
    }

    private var timer: Timer?
    private var moduleEnabled = true
    /// 每个进程最近几次 CPU 采样（算「持续偏高」用）
    private var cpuSamples: [String: [Double]] = [:]
    private var notifiedStuck: Set<String> = []

    /// 盯着的进程：自带输入法相关 + 常见卡死源
    private static let targets: [(name: String, label: String)] = [
        ("SCIM", "macOS 拼音输入法"),
        ("CursorUIViewService", "输入候选视图服务"),
    ]

    init() {
        monitoringEnabled = ud.object(forKey: Keys.enabled) as? Bool ?? true
    }

    deinit { timer?.invalidate() }

    func setModuleEnabled(_ value: Bool) {
        moduleEnabled = value
        if !value { timer?.invalidate(); timer = nil } else { applyEnabled() }
    }

    func start() {
        applyEnabled()
        sample()
    }

    private func applyEnabled() {
        if monitoringEnabled, moduleEnabled {
            if timer == nil {
                let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.sample() }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: - 采样

    func sample() {
        let targets = Self.targets
        Task { [weak self] in
            let results = await Task.detached {
                targets.map { target -> (String, String, Int32?, Double, Double) in
                let pid = Self.findPID(name: target.name)
                let (cpu, memMB) = pid.map { Self.sample(pid: $0) } ?? (0, 0)
                return (target.name, target.label, pid, cpu, memMB)
            }
            }.value
            self?.apply(results)
        }
    }

    nonisolated private static func findPID(name: String) -> Int32? {
        // pgrep -x 精确按进程名查
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-u", String(getuid()), "-x", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            let lines = text.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            return lines.first
        } catch {
            return nil
        }
    }

    /// 返回 (CPU%, 内存 MB)
    nonisolated private static func sample(pid: Int32) -> (Double, Double) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "%cpu=,rss="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parts = text.split(separator: " ").map(String.init)
            guard parts.count >= 2,
                  let cpu = Double(parts[0]),
                  let rssKB = Double(parts[1]) else { return (0, 0) }
            return (cpu, rssKB / 1024)
        } catch {
            return (0, 0)
        }
    }

    private func apply(_ results: [(String, String, Int32?, Double, Double)]) {
        var newProcesses: [IMEProcessStatus] = []
        for (name, label, pid, cpu, memMB) in results {
            var samples = cpuSamples[name] ?? []
            samples.append(cpu)
            if samples.count > 3 { samples.removeFirst(samples.count - 3) }
            cpuSamples[name] = samples

            let cpuStuck = samples.count == 3 && samples.allSatisfy { $0 > Self.cpuLimitPercent }
            let memStuck = memMB > Self.memoryLimitMB
            let stuck = pid != nil && (cpuStuck || memStuck)

            newProcesses.append(IMEProcessStatus(
                name: name, label: label, pid: pid,
                memoryMB: memMB, cpuPercent: cpu, stuck: stuck
            ))

            if stuck, !notifiedStuck.contains(name) {
                notifiedStuck.insert(name)
                let reason = memStuck
                    ? TF("内存占用 %.0f MB", memMB)
                    : TF("CPU 持续 %.0f%%", cpu)
                events.insert(IMEHealthEvent(date: Date(), processName: label, reason: reason, repaired: false), at: 0)
                if events.count > 20 { events.removeLast(events.count - 20) }
                onToast?(TF("%@ 可能卡住了，可以一键修复", label), "exclamationmark.triangle")
            } else if !stuck {
                notifiedStuck.remove(name)
            }
        }
        processes = newProcesses
        lastChecked = Date()
    }

    // MARK: - 修复

    /// 只有确认原进程已退出且替代进程已出现，才报告重新启动成功。
    func repair(_ status: IMEProcessStatus) {
        guard let pid = status.pid, pid > 1, !repairingIDs.contains(status.id) else { return }
        repairingIDs.insert(status.id)
        Task {
            defer { repairingIDs.remove(status.id); sample() }
            let signalled = await Task.detached {
                guard Self.findPID(name: status.name) == pid else { return false }
                return kill(pid, SIGKILL) == 0
            }.value
            guard signalled else {
                onToast?(T("未能停止输入法进程，权限不足或进程状态已变化"), "exclamationmark.triangle")
                return
            }
            cpuSamples[status.name] = []
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                let replacement = await Task.detached { Self.findPID(name: status.name) }.value
                if let replacement, replacement != pid {
                    if let index = events.firstIndex(where: { $0.processName == status.label && !$0.repaired }) {
                        events[index].repaired = true
                    }
                    onToast?(TF("%@ 已重新启动", status.label), "checkmark.circle.fill")
                    return
                }
            }
            onToast?(T("已发送停止请求，尚未确认输入法重新启动"), "exclamationmark.triangle")
        }
    }
}
