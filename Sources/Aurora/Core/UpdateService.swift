//  UpdateService.swift
//  Aurora — 基于 GitHub Release 的更新检查、自动下载与就地替换
//
//  流程：每小时（或用户点「检查更新」）拉取 latest release → 版本比较 →
//  自动下载 zip 并解包到 Application Support → 询问用户 → 由 shell 脚本
//  等本进程退出后替换 .app 并重新打开。

import AppKit
import Combine

/// 远端 release，只保留 Aurora 用得到的字段
struct AuroraRelease: Equatable {
    var version: String
    var tag: String
    var notes: String
    var publishedAt: Date?
    var asset: URL?
    var assetName: String?
    var page: URL
}

enum UpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case downloading(Double)
    case ready(AuroraRelease)
    case installing
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }
}

enum UpdateError: LocalizedError {
    case network
    case server(Int)
    case decode
    case noAsset
    case unpack

    var errorDescription: String? {
        switch self {
        case .network: return T("网络不可用")
        case .server(let code): return TF("服务器返回 %d", code)
        case .decode: return T("返回内容无法解析")
        case .noAsset: return T("这个版本没有可下载的安装包")
        case .unpack: return T("安装包解压失败")
        }
    }
}

@MainActor
final class UpdateService: ObservableObject {
    static let repository = "CaryK753/Aurora"
    static let homepage = URL(string: "https://github.com/CaryK753/Aurora")!
    static let releasesPage = URL(string: "https://github.com/CaryK753/Aurora/releases")!
    /// 自动检查间隔：一小时
    static let checkInterval: TimeInterval = 3600

    @Published private(set) var phase: UpdatePhase = .idle
    @Published private(set) var lastCheck: Date?
    @Published private(set) var currentVersion: String

    /// 自动检查并下载新版本，默认开启
    @Published var autoUpdate: Bool {
        didSet {
            guard autoUpdate != oldValue else { return }
            UserDefaults.standard.set(autoUpdate, forKey: "update.auto")
            if autoUpdate {
                start()
            } else {
                timer?.invalidate()
                timer = nil
            }
        }
    }

    private var timer: Timer?
    private var task: Task<Void, Never>?
    /// 解包好的新版本 .app
    private var stagedApp: URL?

    init() {
        currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
        autoUpdate = UserDefaults.standard.object(forKey: "update.auto") as? Bool ?? true
    }

    // MARK: - 生命周期

    /// 启动后先等一会儿（不要抢启动时的 IO），之后每小时一次
    func start() {
        timer?.invalidate()
        guard autoUpdate else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        timer.tolerance = 120
        self.timer = timer

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard self.autoUpdate else { return }
            self.check()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
    }

    // MARK: - 检查

    func check(manual: Bool = false) {
        guard task == nil, !phase.isBusy else { return }
        phase = .checking
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await Self.fetchLatest()
                self.lastCheck = Date()
                guard let release else {
                    // 仓库还没有发过 release
                    self.phase = .upToDate
                    self.task = nil
                    return
                }
                if Self.isNewer(release.version, than: self.currentVersion) {
                    if self.autoUpdate {
                        try await self.download(release)
                    } else {
                        self.phase = .ready(release)
                    }
                } else {
                    self.phase = .upToDate
                }
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
            self.task = nil
        }
        _ = manual
    }

    /// 用户点「立即更新」
    func install(_ release: AuroraRelease) {
        guard let app = stagedApp, FileManager.default.fileExists(atPath: app.path) else {
            if let asset = release.asset {
                // 还没下载（用户关了自动更新），先下载再问
                phase = .checking
                task = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.download(release, askAfter: true)
                    } catch {
                        self.phase = .failed(error.localizedDescription)
                    }
                    self.task = nil
                }
            } else {
                NSWorkspace.shared.open(release.page)
            }
            return
        }
        replaceAndRelaunch(with: app)
    }

    // MARK: - 下载

    func download(_ release: AuroraRelease, askAfter: Bool = false, silent: Bool = false) async throws {
        guard let asset = release.asset else {
            phase = .ready(release)
            return
        }
        phase = .downloading(0)

        let directory = Self.updatesDirectory.appendingPathComponent(release.version, isDirectory: true)
        let manager = FileManager.default
        try? manager.removeItem(at: directory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        var request = URLRequest(url: asset)
        request.setValue("Aurora-macOS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let delegate = ProgressDelegate { progress in
            Task { @MainActor [weak self] in
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(progress)
            }
        }
        let (temp, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let archive = directory.appendingPathComponent(release.assetName ?? "Aurora.zip")
        try? manager.removeItem(at: archive)
        try manager.moveItem(at: temp, to: archive)

        let unpacked = directory.appendingPathComponent("unpacked", isDirectory: true)
        try? manager.removeItem(at: unpacked)
        try manager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try Self.unzip(archive, to: unpacked)

        guard let app = Self.findApp(in: unpacked) else { throw UpdateError.unpack }
        stagedApp = app

        // 去掉隔离标记，否则替换后首次启动会被 Gatekeeper 拦住
        _ = Self.shell("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])

        phase = .ready(release)
        if !silent {
            promptInstall(release)
        }
        _ = askAfter
    }

    /// 下载完成后的询问：同意才替换，拒绝就把状态停在「有新版本」
    private func promptInstall(_ release: AuroraRelease) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = TF("发现新版本 %@", release.version)
        let size = stagedApp.map { Self.formattedSize($0) } ?? ""
        var body = TF("当前版本 %@，可以现在更新。", currentVersion)
        if !size.isEmpty {
            body += "\n" + TF("安装包已下载（%@）。", size)
        }
        body += "\n" + T("更新会自动替换 Aurora.app 并重新启动，当前窗口与设置不会丢失。")
        if !release.notes.isEmpty {
            body += "\n\n" + Self.trimmedNotes(release.notes)
        }
        alert.informativeText = body
        alert.addButton(withTitle: T("立即更新"))
        alert.addButton(withTitle: T("稍后"))
        alert.window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let app = stagedApp {
            replaceAndRelaunch(with: app)
        }
    }

    // MARK: - 安装

    private func replaceAndRelaunch(with staged: URL) {
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()

        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            // 装在只有管理员能写的目录：解包在 Finder 里让用户自己拖
            NSWorkspace.shared.activateFileViewerSelecting([staged])
            phase = .failed(T("Aurora 所在目录不可写，已打开下载好的应用，请手动替换"))
            return
        }

        phase = .installing
        let script = Self.installScript(target: target, staged: staged)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        Debug.log("update: handing over to \(scriptURL.lastPathComponent), quitting")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NSApp.terminate(nil)
        }
    }

    /// 等 Aurora 退出 → 备份旧包 → ditto 新包 → 清隔离属性 → 重新打开
    static func installScript(target: URL, staged: URL) -> String {
        let app = target.path
        let src = staged.path
        let pid = ProcessInfo.processInfo.processIdentifier
        return """
        #!/bin/sh
        LOG=/tmp/aurora-update.log
        exec >>"$LOG" 2>&1
        echo "=== $(date) update \(app) <- \(src) pid=\(pid)"
        APP="\(app)"
        SRC="\(src)"
        PID=\(pid)
        i=0
        while kill -0 "$PID" 2>/dev/null && [ $i -lt 120 ]; do
          sleep 0.5
          i=$((i+1))
        done
        # 等 FinderSync 扩展也退出，避免替换时 appex 还映射着旧文件
        pkill -x AuroraFinder 2>/dev/null
        sleep 0.4
        if [ -d "$SRC" ]; then
          rm -rf "$APP.aurora-old"
          if mv "$APP" "$APP.aurora-old" 2>/dev/null; then
            if ditto "$SRC" "$APP"; then
              xattr -dr com.apple.quarantine "$APP" 2>/dev/null
              rm -rf "$APP.aurora-old"
              echo "replaced ok"
            else
              echo "copy failed, rolling back"
              rm -rf "$APP"
              mv "$APP.aurora-old" "$APP"
            fi
          else
            echo "cannot move old app (permission)"
          fi
        fi
        open "$APP"
        """
    }

    // MARK: - 远端

    nonisolated static func fetchLatest() async throws -> AuroraRelease? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Aurora-macOS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.network }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw UpdateError.server(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.decode
        }

        let tag = json["tag_name"] as? String ?? ""
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !version.isEmpty else { throw UpdateError.decode }

        var assetURL: URL?
        var assetName: String?
        for case let asset as [String: Any] in (json["assets"] as? [Any] ?? []) {
            guard let name = asset["name"] as? String,
                  let raw = asset["browser_download_url"] as? String,
                  let url = URL(string: raw) else { continue }
            let lower = name.lowercased()
            if lower.hasSuffix(".zip") {
                assetURL = url
                assetName = name
                break
            }
            if lower.hasSuffix(".dmg"), assetURL == nil {
                assetURL = url
                assetName = name
            }
        }

        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
        let notes = (json["body"] as? String) ?? ""
        let published = (json["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }

        return AuroraRelease(
            version: version,
            tag: tag,
            notes: notes,
            publishedAt: published,
            asset: assetURL,
            assetName: assetName,
            page: page
        )
    }

    /// 开发诊断：只拉远端信息，不下载
    func diagnose() async -> String {
        do {
            guard let release = try await Self.fetchLatest() else {
                return "远端还没有 release（本地 \(currentVersion)）"
            }
            let newer = Self.isNewer(release.version, than: currentVersion)
            return "remote=\(release.version) local=\(currentVersion) newer=\(newer) asset=\(release.assetName ?? "无") notes=\(release.notes.count)字"
        } catch {
            return "失败：\(error.localizedDescription)"
        }
    }

    /// 开发诊断：连下载一起验证（不弹窗、不安装）
    func diagnoseWithDownload() async -> String {
        let summary = await diagnose()
        guard !summary.contains("remote=") else {
            do {
                guard let release = try await Self.fetchLatest(),
                      Self.isNewer(release.version, than: currentVersion) else { return summary }
                try await download(release, silent: true)
                let staged = stagedApp?.path ?? "解包失败"
                let size = stagedApp.map { Self.formattedSize($0) } ?? "-"
                return summary + "\nstaged=\(staged) size=\(size)"
            } catch {
                return summary + "\n下载失败：\(error.localizedDescription)"
            }
        }
        return summary
    }

    // MARK: - 工具

    /// 只比数字段，忽略 build 后缀
    nonisolated static func isNewer(_ remote: String, than local: String) -> Bool {
        let lhs = numbers(remote)
        let rhs = numbers(local)
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private nonisolated static func numbers(_ version: String) -> [Int] {
        version.split(separator: ".").map { chunk in
            Int(chunk.prefix(while: \.isNumber)) ?? 0
        }
    }

    private nonisolated static func unzip(_ archive: URL, to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.unpack }
    }

    private nonisolated static func findApp(in directory: URL) -> URL? {
        if directory.pathExtension == "app" { return directory }
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        if let app = items.first(where: { $0.pathExtension == "app" }) { return app }
        // 有些打包会把 .app 放进一层目录
        for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let nested = findApp(in: item) { return nested }
        }
        return nil
    }

    private nonisolated static var updatesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Aurora/Updates", isDirectory: true)
    }

    @discardableResult
    private nonisolated static func shell(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private nonisolated static func formattedSize(_ app: URL) -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: app,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return "" }
        var total = 0
        for case let url as URL in enumerator {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total > 0 ? ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file) : ""
    }

    private nonisolated static func trimmedNotes(_ notes: String) -> String {
        let lines = notes
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(6)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.joined(separator: "\n")
    }
}

/// 单纯用来把下载进度送回主线程
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }
}
