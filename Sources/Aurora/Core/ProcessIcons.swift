//  ProcessIcons.swift
//  Aurora — 进程图标缓存（取运行中 App 的官方图标，取不到时由 UI 用占位符）

import AppKit

@MainActor
final class ProcessIcons {
    static let shared = ProcessIcons()

    private var cache: [pid_t: NSImage] = [:]
    private var misses: Set<pid_t> = []
    private var tick = 0

    /// 单个进程的图标；守护进程/命令行工具通常没有图标，返回 nil 交给占位符
    func icon(for pid: pid_t) -> NSImage? {
        if let cached = cache[pid] { return cached }
        if misses.contains(pid) { return nil }
        guard let app = NSRunningApplication(processIdentifier: pid),
              let icon = app.icon, icon.size.width > 1 else {
            misses.insert(pid)
            return nil
        }
        let resized = icon.copy() as? NSImage ?? icon
        resized.size = NSSize(width: 18, height: 18)
        cache[pid] = resized
        return resized
    }

    /// 定期丢弃已经退出的 pid，避免缓存无限增长
    func prune(alive: Set<pid_t>) {
        tick += 1
        guard tick % 12 == 0 else { return }
        cache = cache.filter { alive.contains($0.key) }
        misses = misses.filter { alive.contains($0) }
    }
}
