//  DisplayGamma.swift
//  Aurora — 软件调光（gamma 表）与 DDC 写入合并
//
//  软件调光来自 MonitorControl 的 "combined brightness"：硬件亮度到底以后继续压 gamma，
//  可以暗到全黑，也能让「最暗」比显示器自身下限更低。
//  DDC 写入合并解决拖动滑杆时串口队列堆积：同一通道只保留最新值，按顺序刷最后一次。

import CoreGraphics
import Foundation

// MARK: - 软件调光

final class DisplayGamma {
    private struct Table {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
        var count: UInt32
    }

    private var tables: [CGDirectDisplayID: Table] = [:]
    private var levels: [CGDirectDisplayID: Float] = [:]
    private let lock = NSLock()

    /// 记录显示器「未被我们改过」的 gamma 表；重复调用只记第一次
    func capture(_ id: CGDirectDisplayID) {
        lock.lock()
        defer { lock.unlock() }
        guard tables[id] == nil else { return }
        var red = [CGGammaValue](repeating: 0, count: 256)
        var green = [CGGammaValue](repeating: 0, count: 256)
        var blue = [CGGammaValue](repeating: 0, count: 256)
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, 256, &red, &green, &blue, &count) == .success, count > 0 else { return }
        tables[id] = Table(red: red, green: green, blue: blue, count: count)
        levels[id] = 1
    }

    func level(for id: CGDirectDisplayID) -> Float {
        lock.lock()
        defer { lock.unlock() }
        return levels[id] ?? 1
    }

    /// level: 0...1，1 表示不压暗（直接还原原始表）
    @discardableResult
    func apply(_ level: Float, to id: CGDirectDisplayID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let table = tables[id] else { return false }
        let value = min(max(level, 0), 1)
        if value >= 0.999 {
            // 本来就没压暗时不要反复写 gamma 表，否则会和夜览 / True Tone 抢
            guard (levels[id] ?? 1) < 0.999 else { return true }
            levels[id] = 1
            return CGSetDisplayTransferByTable(id, table.count, table.red, table.green, table.blue) == .success
        }
        levels[id] = value
        // 最低不压到 0，留一点可读性；需要全黑时用 0.02 近似
        let scale = CGGammaValue(max(value, 0.02))
        let red = table.red.prefix(Int(table.count)).map { $0 * scale }
        let green = table.green.prefix(Int(table.count)).map { $0 * scale }
        let blue = table.blue.prefix(Int(table.count)).map { $0 * scale }
        return CGSetDisplayTransferByTable(id, table.count, red, green, blue) == .success
    }

    func reset(_ id: CGDirectDisplayID) {
        _ = apply(1, to: id)
    }

    func resetAll() {
        lock.lock()
        let ids = Array(tables.keys)
        lock.unlock()
        for id in ids { reset(id) }
    }

    /// 显示器重新配置后旧表失效，重新抓一次
    func invalidate(_ id: CGDirectDisplayID) {
        lock.lock()
        tables.removeValue(forKey: id)
        levels[id] = 1
        lock.unlock()
    }
}

// MARK: - DDC 写入合并

final class DDCWriter: @unchecked Sendable {
    private struct Job {
        let channel: DDCChannel
        let codes: [UInt8]
        let value: UInt16
    }

    private let queue = DispatchQueue(label: "aurora.display.ddc.write", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [String: Job] = [:]
    private var order: [String] = []
    private var draining = false

    /// 同一个 key（显示器 + 通道）只保留最后一次请求
    func submit(key: String, channel: DDCChannel, codes: [UInt8], value: UInt16) {
        lock.lock()
        if pending[key] == nil { order.append(key) }
        pending[key] = Job(channel: channel, codes: codes, value: value)
        let shouldStart = !draining
        if shouldStart { draining = true }
        lock.unlock()

        guard shouldStart else { return }
        queue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let key = order.first, let job = pending[key] else {
                order.removeAll()
                draining = false
                lock.unlock()
                return
            }
            order.removeFirst()
            pending.removeValue(forKey: key)
            lock.unlock()

            for code in job.codes {
                _ = job.channel.write(code, value: job.value)
            }
        }
    }
}
