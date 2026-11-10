//  AIUsageService.swift
//  Aurora — AI用量：逐个 harness 适配本地落盘数据
//
//  适配思路参考 CodexBar / ccusage / opencode 的统计方式：
//  · Codex        ~/.codex/sessions/**/rollout-*.jsonl → token_count 事件 + rate_limits（真实配额）
//  · Claude Code  ~/.claude/projects/**/*.jsonl        → message.usage
//  · opencode     ~/.local/share/opencode/opencode.db  → message.data.tokens（JSON1 聚合）
//  · WorkBuddy    ~/.workbuddy/workbuddy.db            → session_usage
//  · Antigravity  ~/.gemini/antigravity                → 加密库，只能检测安装
//  · DeepSeek     ~/Library/Application Support/@deepseek-ai/dsh-desktop → 无用量文件
//  · 桌面客户端   ChatGPT / Claude.app                 → 无本地用量
//  全部只读本地文件，不读密钥、不调用任何接口

import AppKit
import Combine

struct DailyTokenUsage: Identifiable {
    let id = UUID()
    let date: Date
    let tokens: Int
}

/// 真实配额窗口（目前只有 Codex 的 rate_limits 会给出百分比）
struct QuotaWindow: Identifiable {
    let id: String
    let label: String
    let usedPercent: Double      // 0…100
    let resetsAt: Date?
    let windowMinutes: Int
}

struct AIProviderUsage: Identifiable {
    enum Source {
        case localLog     // 有可解析的本地用量
        case desktopOnly  // 只检测到安装，无本地用量
    }

    let id: String
    let name: String
    var symbol: String
    var bundleID: String?
    var appPath: String?
    var installed: Bool
    var source: Source = .desktopOnly
    var todayTokens: Int = 0
    var windowTokens: Int = 0      // 近 5 小时
    var weekTokens: Int = 0        // 近 7 天
    var sessionCount: Int = 0
    var lastActive: Date?
    var daily: [DailyTokenUsage] = []
    var quotaWindows: [QuotaWindow] = []
    var planLabel: String?
    var cost: Double?
    var quotaUsed: Int?
    var quotaTotal: Int?
    var sourceNote: String?
    var note: String?
    var icon: NSImage?
}

@MainActor
final class AIUsageService: ObservableObject {
    @Published private(set) var providers: [AIProviderUsage] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?

    private var refreshTimer: Timer?

    init() {
        scan()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.scan() }
        }
    }

    deinit { refreshTimer?.invalidate() }

    var withData: [AIProviderUsage] { providers.filter { $0.source == .localLog } }
    var detectedOnly: [AIProviderUsage] { providers.filter { $0.source != .localLog } }

    /// 所有 harness 的 7 天合计，用于顶部汇总
    var weekTotal: Int { withData.reduce(0) { $0 + $1.weekTokens } }
    var todayTotal: Int { withData.reduce(0) { $0 + $1.todayTokens } }
    var costTotal: Double { withData.compactMap(\.cost).reduce(0, +) }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var results: [AIProviderUsage] = [
                Self.scanCodex(),
                Self.scanClaude(),
                Self.scanOpenCode(),
                Self.scanWorkBuddy(),
                Self.scanAntigravity(),
                Self.scanDeepSeek(),
                Self.scanDesktopApp(
                    id: "chatgpt-desktop",
                    name: "ChatGPT",
                    symbol: "brain.head.profile",
                    bundleID: nil,
                    path: "/Applications/ChatGPT.app"
                ),
                Self.scanDesktopApp(
                    id: "claude-desktop",
                    name: "Claude Desktop",
                    symbol: "text.bubble",
                    bundleID: "com.anthropic.claudefordesktop",
                    path: "/Applications/Claude.app"
                )
            ]
            Task { @MainActor in
                guard let self else { return }
                for index in results.indices {
                    if let bundleID = results[index].bundleID, let icon = Self.appIcon(bundleID) {
                        results[index].icon = icon
                    } else if let path = results[index].appPath, FileManager.default.fileExists(atPath: path) {
                        // 有些 App 和同门的 bundle id 重名（ChatGPT 与 Codex 都叫 com.openai.codex），按路径取更稳
                        let icon = NSWorkspace.shared.icon(forFile: path)
                        icon.size = NSSize(width: 56, height: 56)
                        results[index].icon = icon
                    }
                    // 没有 App bundle 的 CLI / IDE 用官方品牌 mark，不留占位图
                    if results[index].icon == nil {
                        results[index].icon = BrandMarks.image(for: results[index].id, size: 56)
                    }
                }
                // 有本地数据的排前面，数据多的排更前
                results.sort { lhs, rhs in
                    if lhs.source != rhs.source { return lhs.source == .localLog }
                    if lhs.source == .localLog, lhs.weekTokens != rhs.weekTokens {
                        return lhs.weekTokens > rhs.weekTokens
                    }
                    if lhs.installed != rhs.installed { return lhs.installed }
                    return lhs.name < rhs.name
                }
                self.providers = results
                self.isScanning = false
                self.lastScan = Date()
            }
        }
    }

    private static func appIcon(_ bundleID: String, size: CGFloat = 56) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: size, height: size)
        return icon
    }

    // MARK: - Codex

    private nonisolated static func scanCodex() -> AIProviderUsage {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        var usage = AIProviderUsage(
            id: "codex",
            name: "Codex",
            symbol: "chevron.left.forwardslash.chevron.right",
            bundleID: "com.openai.codex",
            appPath: "/Applications/ChatGPT.app",
            installed: FileManager.default.fileExists(atPath: root.path)
        )
        guard usage.installed else { return usage }
        usage.sourceNote = T("rollout 日志 · token_count 事件")

        let files = logFiles(under: root, days: 8)
        var events: [(Date, Int)] = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var sessions = 0
        var latestLimits: (Date, [String: Any])?

        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }

            var fileHasEvents = false
            var previousTotal = 0
            for line in data.split(separator: 0x0A) {
                guard line.count > 20,
                      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let payload = object["payload"] as? [String: Any] else { continue }
                let stamp = (object["timestamp"] as? String).flatMap { formatter.date(from: $0) } ?? Date()

                // 配额快照：只保留最新的一条
                if let limits = payload["rate_limits"] as? [String: Any],
                   !parseRateLimits(limits).isEmpty {
                    if latestLimits == nil || stamp > latestLimits!.0 {
                        latestLimits = (stamp, limits)
                    }
                }

                guard (payload["type"] as? String) == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any],
                      let tokens = total["total_tokens"] as? Int else { continue }
                let delta = max(0, tokens - previousTotal)
                previousTotal = tokens
                if delta > 0 { events.append((stamp, delta)); fileHasEvents = true }
            }
            if fileHasEvents { sessions += 1 }
        }

        var result = summarize(usage, events: events, sessions: sessions)
        if !events.isEmpty { result.source = .localLog }

        if let (_, limits) = latestLimits {
            result.quotaWindows = parseRateLimits(limits)
            if let plan = limits["plan_type"] as? String, !plan.isEmpty {
                result.planLabel = plan.capitalized
            }
            if let credits = limits["credits"] as? [String: Any],
               let balance = credits["balance"] as? String, balance != "0" {
                result.note = TF("剩余额度 %@", balance)
            }
        }
        return result
    }

    private nonisolated static func parseRateLimits(_ limits: [String: Any]) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []
        for key in ["primary", "secondary"] {
            guard let block = limits[key] as? [String: Any],
                  let percent = block["used_percent"] as? Double else { continue }
            let minutes = block["window_minutes"] as? Int ?? 0
            let reset = (block["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                ?? (block["resets_at"] as? Int).map { Date(timeIntervalSince1970: Double($0)) }
            windows.append(
                QuotaWindow(
                    id: key,
                    label: windowLabel(minutes),
                    usedPercent: min(max(percent, 0), 100),
                    resetsAt: reset,
                    windowMinutes: minutes
                )
            )
        }
        return windows
    }

    private nonisolated static func windowLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return T("额度")
        case ..<120: return TF("%d 分钟", minutes)
        case ..<2880: return TF("%d 小时", max(1, minutes / 60))
        case ..<20160: return TF("%d 天", max(1, minutes / 1440))
        default: return TF("%d 天", max(1, minutes / 1440))
        }
    }

    // MARK: - Claude Code

    private nonisolated static func scanClaude() -> AIProviderUsage {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        var usage = AIProviderUsage(
            id: "claude",
            name: "Claude Code",
            symbol: "a.circle.fill",
            bundleID: "com.anthropic.claudefordesktop",
            installed: FileManager.default.fileExists(atPath: root.path)
        )
        guard usage.installed else { return usage }
        usage.sourceNote = T("会话 JSONL · message.usage")

        let files = logFiles(under: root, days: 8)
        var events: [(Date, Int)] = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()

        var sessions = 0
        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }

            var fileHasEvents = false
            for line in data.split(separator: 0x0A) {
                guard line.count > 20,
                      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let message = object["message"] as? [String: Any],
                      let usageBlock = message["usage"] as? [String: Any] else { continue }
                let input = usageBlock["input_tokens"] as? Int ?? 0
                let output = usageBlock["output_tokens"] as? Int ?? 0
                let cacheWrite = usageBlock["cache_creation_input_tokens"] as? Int ?? 0
                let cacheRead = usageBlock["cache_read_input_tokens"] as? Int ?? 0
                let total = input + output + cacheWrite + cacheRead
                guard total > 0 else { continue }
                let stamp = (object["timestamp"] as? String)
                    .flatMap { formatter.date(from: $0) ?? fallback.date(from: $0) } ?? Date()
                events.append((stamp, total))
                fileHasEvents = true
            }
            if fileHasEvents { sessions += 1 }
        }

        var result = summarize(usage, events: events, sessions: sessions)
        if !events.isEmpty {
            result.source = .localLog
        } else if let newest = newestLogDate(under: root) {
            result.note = TF("本地日志最近更新于 %@", Fmt.relative(newest))
        }
        return result
    }

    // MARK: - opencode

    private nonisolated static func scanOpenCode() -> AIProviderUsage {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let db = home.appendingPathComponent(".local/share/opencode/opencode.db")
        var usage = AIProviderUsage(
            id: "opencode",
            name: "opencode",
            symbol: "terminal",
            bundleID: nil,
            installed: FileManager.default.fileExists(atPath: db.path)
        )
        guard usage.installed else { return usage }
        usage.sourceNote = T("本地 sqlite · message.tokens")

        let sql = """
        SELECT date(time_created/1000,'unixepoch','localtime') AS d,
               sum(COALESCE(json_extract(data,'$.tokens.total'),0)),
               round(sum(COALESCE(json_extract(data,'$.cost'),0)),4),
               count(*)
        FROM message
        WHERE json_extract(data,'$.role')='assistant'
        GROUP BY d ORDER BY d DESC LIMIT 10;
        """
        guard let output = runSQLite(db: db, sql: sql) else {
            usage.note = T("数据库读取失败，可能正被占用")
            return usage
        }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")

        var events: [(Date, Int)] = []
        var cost = 0.0
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "|")
            guard fields.count >= 4,
                  let tokens = Int(fields[1]) else { continue }
            guard let day = dayFormatter.date(from: String(fields[0])) else { continue }
            // 统一落到当天 12:00，避免时区把日期挤到前一天
            let stamp = day.addingTimeInterval(12 * 3600)
            if tokens > 0 { events.append((stamp, tokens)) }
            cost += Double(fields[2]) ?? 0
        }

        // 会话数（distinct）与累计用量：库里常留着一两个月前的记录
        var sessions = 0
        var allTime = 0
        let extraSQL = "SELECT count(DISTINCT session_id), COALESCE(sum(CASE WHEN json_extract(data,'$.role')='assistant' THEN json_extract(data,'$.tokens.total') ELSE 0 END),0) FROM message;"
        if let extra = runSQLite(db: db, sql: extraSQL),
           let row = extra.split(separator: "\n").first {
            let fields = row.split(separator: "|")
            if fields.count >= 2 {
                sessions = Int(fields[0]) ?? 0
                allTime = Int(fields[1]) ?? 0
            }
        }

        var result = summarize(usage, events: events, sessions: sessions)
        if !events.isEmpty {
            result.source = .localLog
            result.cost = cost > 0 ? cost : nil
            if result.weekTokens == 0, allTime > 0 {
                result.note = TF("近 7 天没有新记录 · 本地累计 %@ tokens", Fmt.tokens(allTime))
            }
        } else {
            result.note = T("还没有产生用量记录")
        }
        return result
    }

    // MARK: - WorkBuddy（腾讯，桌面端把用量写进 sqlite）

    private nonisolated static func scanWorkBuddy() -> AIProviderUsage {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let db = home.appendingPathComponent(".workbuddy/workbuddy.db")
        var usage = AIProviderUsage(
            id: "workbuddy",
            name: "WorkBuddy",
            symbol: "sparkle.magnifyingglass",
            bundleID: "com.tencent.workbuddy.mac",
            installed: FileManager.default.fileExists(atPath: db.path)
        )
        guard usage.installed else { return usage }
        usage.sourceNote = T("本地 sqlite · session_usage")

        guard let output = runSQLite(db: db, sql: "SELECT used, size, updated_at FROM session_usage;") else {
            usage.note = T("数据库读取失败，可能正被占用")
            return usage
        }

        var events: [(Date, Int)] = []
        var used = 0
        var total = 0
        var sessions = 0

        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "|")
            guard fields.count >= 3,
                  let rowUsed = Int(fields[0]),
                  let rowSize = Int(fields[1]) else { continue }
            let stampMS = Double(fields[2].trimmingCharacters(in: .whitespaces)) ?? 0
            let stamp = Date(timeIntervalSince1970: stampMS > 1e12 ? stampMS / 1000 : stampMS)
            if rowUsed > 0 {
                events.append((stamp, rowUsed))
                used += rowUsed
                total += max(rowSize, 0)
                sessions += 1
            }
        }

        guard !events.isEmpty else {
            usage.note = T("还没有产生用量记录")
            return usage
        }

        var result = summarize(usage, events: events, sessions: sessions)
        result.source = .localLog
        result.quotaUsed = used
        result.quotaTotal = total > 0 ? total : nil
        return result
    }

    private nonisolated static func runSQLite(db: URL, sql: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", db.path, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Google Antigravity（Gemini）

    private nonisolated static func scanAntigravity() -> AIProviderUsage {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var usage = AIProviderUsage(
            id: "antigravity",
            name: "Antigravity",
            symbol: "diamond.fill",
            bundleID: "com.google.antigravity",
            appPath: "/Applications/Antigravity.app",
            installed: false
        )
        let candidates = [
            "\(home.path)/.gemini/antigravity",
            "/Applications/Antigravity.app",
            "/Applications/Gemini.app"
        ]
        usage.installed = candidates.contains { FileManager.default.fileExists(atPath: $0) }
        guard usage.installed else { return usage }
        usage.note = T("会话库为加密格式，系统未提供可读用量")
        return usage
    }

    // MARK: - DeepSeek Harness

    private nonisolated static func scanDeepSeek() -> AIProviderUsage {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var usage = AIProviderUsage(
            id: "deepseek",
            name: "DeepSeek Harness",
            symbol: "waveform",
            bundleID: "com.deepseek.dsh",
            appPath: "/Applications/DeepSeek Harness.app",
            installed: false
        )
        let appPaths = ["/Applications/DeepSeek Harness.app", "\(home.path)/Applications/DeepSeek Harness.app"]
        let dataPath = "\(home.path)/Library/Application Support/@deepseek-ai/dsh-desktop"
        usage.installed = appPaths.contains { FileManager.default.fileExists(atPath: $0) }
            || FileManager.default.fileExists(atPath: dataPath)
        guard usage.installed else { return usage }
        usage.note = T("桌面端未写入可读的用量日志")
        return usage
    }

    // MARK: - 桌面客户端（只在装了的时候出现）

    private nonisolated static func scanDesktopApp(
        id: String,
        name: String,
        symbol: String,
        bundleID: String?,
        path: String
    ) -> AIProviderUsage {
        AIProviderUsage(
            id: id,
            name: name,
            symbol: symbol,
            bundleID: bundleID,
            appPath: path,
            installed: FileManager.default.fileExists(atPath: path),
            note: T("桌面客户端不写本地用量")
        )
    }

    // MARK: - 汇总

    private nonisolated static func summarize(_ base: AIProviderUsage, events: [(Date, Int)], sessions: Int) -> AIProviderUsage {
        var usage = base
        guard !events.isEmpty else {
            usage.note = usage.note ?? T("未检测到本地用量数据")
            return usage
        }
        let now = Date()
        let startOfToday = Calendar.current.startOfDay(for: now)
        let windowStart = now.addingTimeInterval(-5 * 3600)
        let weekStart = now.addingTimeInterval(-7 * 86400)

        var today = 0, window = 0, week = 0
        var last: Date?
        let calendar = Calendar.current
        var buckets: [Date: Int] = [:]

        for (date, tokens) in events {
            if date >= weekStart { week += tokens }
            if date >= windowStart { window += tokens }
            if date >= startOfToday { today += tokens }
            if last == nil || date > last! { last = date }
            let day = calendar.startOfDay(for: date)
            if date >= calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? weekStart {
                buckets[day, default: 0] += tokens
            }
        }

        usage.todayTokens = today
        usage.windowTokens = window
        usage.weekTokens = week
        usage.sessionCount = sessions
        usage.lastActive = last

        var series: [DailyTokenUsage] = []
        for offset in (-6)...0 {
            if let day = calendar.date(byAdding: .day, value: offset, to: startOfToday) {
                series.append(DailyTokenUsage(date: day, tokens: buckets[day] ?? 0))
            }
        }
        usage.daily = series
        return usage
    }

    // MARK: - 工具

    private nonisolated static func newestLogDate(under root: URL) -> Date? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        var newest: Date?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            if newest == nil || date > newest! { newest = date }
        }
        return newest
    }

    private nonisolated static func logFiles(under root: URL, days: Int) -> [URL] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modified = values?.contentModificationDate, modified >= cutoff else { continue }
            result.append(url)
            if result.count >= 400 { break }
        }
        return result
    }
}
