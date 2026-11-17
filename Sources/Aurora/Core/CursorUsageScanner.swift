import Foundation

enum CursorUsageScanner {
    nonisolated static func scan() -> AIProviderUsage {
        let manager = FileManager.default
        let root = manager.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/projects")
        let appPath = "/Applications/Cursor.app"
        var usage = AIProviderUsage(
            id: "cursor",
            name: "Cursor",
            symbol: "cursorarrow.rays",
            bundleID: "com.todesktop.230313mzl4w4u92",
            appPath: appPath,
            installed: manager.fileExists(atPath: appPath) || manager.fileExists(atPath: root.path)
        )
        guard usage.installed else { return usage }

        let cutoff = Date().addingTimeInterval(-8 * 86_400)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys,
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { url in
            guard url.pathExtension == "jsonl", url.path.contains("/agent-transcripts/"),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return false }
            return (values.contentModificationDate ?? .distantPast) >= cutoff
        }
        usage.sessionCount = files.count
        usage.lastActive = files.compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.compactMap { $0 }.max()
        usage.sourceNote = T("本地 Agent 会话日志")
        usage.note = files.isEmpty
            ? T("尚未发现 Cursor Agent 会话")
            : TF("近 7 天 %d 个 Agent 会话 · 本地日志未提供 token 数", files.count)
        return usage
    }
}
