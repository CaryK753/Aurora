//  UpdateService.swift
//  Aurora — 基于 GitHub Release 的更新检查、自动下载与就地替换
//
//  流程：每小时（或用户点「检查更新」）拉取 latest release → 版本比较 →
//  自动下载 zip 并解包到 Application Support → 询问用户 → 由 shell 脚本
//  等本进程退出后替换 .app 并重新打开。

import AppKit
import Combine
import CryptoKit

/// 远端 release，只保留 Aurora 用得到的字段
struct AuroraRelease: Equatable {
    var version: String
    var tag: String
    var notes: String
    var publishedAt: Date?
    var asset: URL?
    var assetName: String?
    var page: URL
    /// 与 zip 一起发布的 SHA256 清单。没有这份清单就不自动安装。
    var checksum: URL? = nil
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
    case checksum
    case signature
    case untrusted

    var errorDescription: String? {
        switch self {
        case .network: return T("网络不可用")
        case .server(let code):
            // GitHub API 未认证限额（60 次/小时/IP）耗尽会返回 403，与网络无关
            if code == 403 { return T("GitHub 接口被限流（403），备用渠道也不可用，请稍后再试") }
            return TF("服务器返回 %d", code)
        case .decode: return T("返回内容无法解析")
        case .noAsset: return T("这个版本没有可下载的安装包")
        case .unpack: return T("安装包解压失败")
        case .checksum: return T("安装包校验失败，已取消更新")
        case .signature: return T("安装包签名与 Aurora 不符，已取消更新")
        case .untrusted: return T("这个版本没有可校验的安装包")
        }
    }
}

@MainActor
final class UpdateService: ObservableObject {
    /// `codesign -dv` 打印的 TeamIdentifier，取证书 OU。
    /// 本机这张 Apple Development 的名称括号里是 6BGNXNX5FT，OU 实际是 P26UV6YB94。
    nonisolated static let expectedTeamID = "P26UV6YB94"
    nonisolated static let expectedBundleID = "com.cary.aurora"
    nonisolated static let repository = "CaryK753/Aurora"
    nonisolated static let homepage = URL(string: "https://github.com/CaryK753/Aurora")!
    nonisolated static let releasesPage = URL(string: "https://github.com/CaryK753/Aurora/releases")!
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
    /// 用户点过「稍后」的版本：自动检查不再重复打扰，手动检查会重置
    private var declinedVersion: String?

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
        if manual { declinedVersion = nil }
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
                    // 存一份远端正文：本机 CHANGELOG 里还没有这一版时，「新功能」窗口拿它兜底
                    ReleaseNotesStore.cacheRemoteNotes(release.notes, version: release.version)
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
        declinedVersion = nil
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
        guard let checksumURL = release.checksum else { throw UpdateError.untrusted }
        guard UpdateSecurity.allowed(asset), UpdateSecurity.allowed(checksumURL) else { throw UpdateError.untrusted }
        phase = .downloading(0)

        let directory = Self.updatesDirectory.appendingPathComponent(UpdateSecurity.safeVersion(release.version), isDirectory: true)
        let manager = FileManager.default
        try? manager.removeItem(at: directory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let delegate = ProgressDelegate { progress in
            Task { @MainActor [weak self] in
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(progress)
            }
        }

        var request = URLRequest(url: asset)
        request.setValue("Aurora-macOS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        let (temp, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              UpdateSecurity.allowed(response.url) else {
            throw UpdateError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // 资源名来自发布页，只留最后一段文件名，避免 `../` 把 zip 写到更新目录外面。
        let assetFile = ((release.assetName ?? "Aurora.zip") as NSString).lastPathComponent
        guard !assetFile.isEmpty, assetFile != ".", assetFile != "..",
              assetFile.lowercased().hasSuffix(".zip"),
              !assetFile.lowercased().hasSuffix(".zip.sha256") else {
            try? manager.removeItem(at: temp)
            try? manager.removeItem(at: directory)
            throw UpdateError.untrusted
        }
        let archive = directory.appendingPathComponent(assetFile)
        try? manager.removeItem(at: archive)
        try manager.moveItem(at: temp, to: archive)

        var sumRequest = URLRequest(url: checksumURL)
        sumRequest.setValue("Aurora-macOS", forHTTPHeaderField: "User-Agent")
        sumRequest.timeoutInterval = 20
        let (sumTemp, sumResponse) = try await URLSession.shared.download(for: sumRequest, delegate: delegate)
        let sumData = try? Data(contentsOf: sumTemp)
        let expected = sumData.flatMap { String(data: $0, encoding: .utf8) }.flatMap(UpdateSecurity.parseSHA256)
        let actual = try? UpdateSecurity.sha256Hex(of: archive)
        guard let sumHTTP = sumResponse as? HTTPURLResponse, sumHTTP.statusCode == 200,
              UpdateSecurity.allowed(sumResponse.url),
              let expected, actual == expected else {
            try? manager.removeItem(at: directory)
            throw UpdateError.checksum
        }

        let unpacked = directory.appendingPathComponent("unpacked", isDirectory: true)
        try? manager.removeItem(at: unpacked)
        try manager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try Self.unzip(archive, to: unpacked)

        guard let app = Self.findApp(in: unpacked) else { throw UpdateError.unpack }
        guard Self.acceptedBuild(app) else {
            try? manager.removeItem(at: directory)
            stagedApp = nil
            throw UpdateError.signature
        }
        stagedApp = app

        phase = .ready(release)
        if !silent, declinedVersion != release.version {
            NotificationService.shared.notifyUpdateReady(version: release.version, currentVersion: currentVersion)
            promptInstall(release)
        }
        _ = askAfter
    }

    /// 下载完成后的询问：同意才替换，拒绝就把状态停在「有新版本」
    /// 正文统一走 ReleaseNotes 解析，绝不再把 <h2>/<li> 这类标签直接显示出来。
    private func promptInstall(_ release: AuroraRelease) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = TF("发现新版本 %@", release.version)
        let size = stagedApp.map { Self.formattedSize($0) } ?? ""
        alert.informativeText = Self.installSummary(release: release, currentVersion: currentVersion, size: size)
        alert.addButton(withTitle: T("立即更新"))
        alert.addButton(withTitle: T("稍后"))
        alert.window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let app = stagedApp {
            // 说明已缓存在 ReleaseNotesStore，替换重启后由新版本自己弹「新功能」
            replaceAndRelaunch(with: app)
        } else {
            declinedVersion = release.version
        }
    }

    /// 更新弹窗的正文：几行版本信息 + 这次更新的要点（自动去标签、去 Markdown 记号）
    nonisolated static func installSummary(release: AuroraRelease, currentVersion: String, size: String) -> String {
        var body = TF("当前版本 %@，可以现在更新。", currentVersion)
        if !size.isEmpty {
            body += "\n" + TF("安装包已下载（%@）。", size)
        }
        body += "\n" + T("更新会自动替换 Aurora.app 并重新启动，当前窗口与设置不会丢失。")

        let notes = ReleaseNotesParser.parse(release.notes, version: release.version)
        let highlights = notes.highlights(limit: 4)
        guard !highlights.isEmpty else { return body }
        body += "\n\n" + T("本次更新") + "：\n" + highlights.map { "• " + $0 }.joined(separator: "\n")
        let rest = notes.itemCount - highlights.count
        if rest > 0 {
            body += "\n" + TF("…以及另外 %d 项更新", rest)
        }
        body += "\n\n" + T("更新后的首次启动会打开「新功能」窗口，可查看完整说明。")
        return body
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

        guard Self.acceptedBuild(staged) else {
            phase = .failed(UpdateError.signature.localizedDescription)
            return
        }

        phase = .installing
        let script = Self.installScript()
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
        process.arguments = [
            scriptURL.path,
            target.path,
            staged.path,
            String(ProcessInfo.processInfo.processIdentifier),
            Self.expectedTeamID
        ]
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

    /// 等 Aurora 退出 → 再验一次签名和 Team ID → 备份旧包 → ditto 新包 → 重新打开。
    /// 路径只从参数读，不拼进脚本，避免安装包文件名变成 shell。
    nonisolated static func installScript() -> String {
        let bundleID = expectedBundleID
        return """
        #!/bin/sh
        set -eu
        LOG=/tmp/aurora-update.log
        exec >>"$LOG" 2>&1
        echo "=== $(date) update"
        APP="$1"
        SRC="$2"
        PID="$3"
        TEAM="$4"
        finish() {
          if [ -n "$APP" ] && [ -d "$APP" ]; then
            open "$APP" || true
          fi
        }
        trap finish EXIT
        i=0
        while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 120 ]; do
          sleep 0.5
          i=$((i+1))
        done
        # 等 FinderSync 扩展也退出，避免替换时 appex 还映射着旧文件
        pkill -x AuroraFinder 2>/dev/null || true
        sleep 0.4
        if [ ! -d "$SRC" ]; then
          echo "missing source"
          exit 1
        fi
        /usr/bin/codesign --verify --deep --strict "$SRC"
        BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SRC/Contents/Info.plist")
        if [ "$BID" != "\(bundleID)" ]; then
          echo "unexpected bundle id $BID"
          exit 1
        fi
        ACTUAL=$(/usr/bin/codesign -dv "$SRC" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')
        if [ "$ACTUAL" != "$TEAM" ]; then
          echo "unexpected team $ACTUAL"
          exit 1
        fi
        xattr -dr com.apple.quarantine "$SRC" 2>/dev/null || true
        rm -rf "$APP.aurora-old"
        if mv "$APP" "$APP.aurora-old" 2>/dev/null; then
          if ditto "$SRC" "$APP"; then
            xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
            if /usr/bin/codesign --verify --deep --strict "$APP"; then
              rm -rf "$APP.aurora-old"
              echo "replaced ok"
            else
              echo "verify failed, rolling back"
              rm -rf "$APP"
              mv "$APP.aurora-old" "$APP"
            fi
          else
            echo "copy failed, rolling back"
            rm -rf "$APP"
            mv "$APP.aurora-old" "$APP"
          fi
        else
          echo "cannot move old app (permission)"
        fi
        """
    }

    /// 解压后的包必须是 Aurora，并且由发布团队签名。隔离属性留到替换脚本里再清。
    nonisolated static func acceptedBuild(_ app: URL) -> Bool {
        guard bundleIdentifier(of: app) == expectedBundleID else { return false }
        guard teamIdentifier(of: app) == expectedTeamID else { return false }
        return CommandRunner.runSync("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 60).ok
    }

    nonisolated static func bundleIdentifier(of app: URL) -> String? {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        return info?["CFBundleIdentifier"] as? String
    }

    nonisolated static func teamIdentifier(of app: URL) -> String? {
        let result = CommandRunner.runSync("/usr/bin/codesign", ["-dv", "--verbose=4", app.path], timeout: 30)
        let text = result.output + "\n" + result.error
        for line in text.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = String(line.dropFirst("TeamIdentifier=".count)).trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value.lowercased() == "not set" { return nil }
            return value
        }
        return nil
    }

    // MARK: - 远端

    nonisolated static func fetchLatest() async throws -> AuroraRelease? {
        do {
            return try await fetchViaAPI()
        } catch let error as UpdateError {
            switch error {
            case .server(403), .server(429):
                // API 限额耗尽（403/429）走网页渠道：releases/latest 重定向拿 tag
                return try await fetchViaWeb()
            default:
                throw error
            }
        }
    }

    /// 主渠道：GitHub REST API（信息最全，但未认证每小时只有 60 次/IP）
    nonisolated private static func fetchViaAPI() async throws -> AuroraRelease? {
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

        var assets: [(name: String, url: URL)] = []
        for case let asset as [String: Any] in (json["assets"] as? [Any] ?? []) {
            guard let name = asset["name"] as? String,
                  let raw = asset["browser_download_url"] as? String,
                  let url = URL(string: raw),
                  UpdateSecurity.allowed(url) else { continue }
            assets.append((name, url))
        }
        let zip = assets.first { $0.name.lowercased().hasSuffix(".zip") }
        let assetURL = zip?.url
        let assetName = zip?.name
        let checksumURL = zip.flatMap { item in
            assets.first { $0.name == item.name + ".sha256" }?.url
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
            page: page,
            checksum: checksumURL
        )
    }

    /// 备用渠道：不经过 api.github.com，不受 REST 限额约束
    /// 1) releases/latest 会 302 到 /releases/tag/<tag>，从最终 URL 解析 tag；
    /// 2) 再拉 expanded_assets/<tag> 页面，从 HTML 里解析安装包下载链接。
    nonisolated private static func fetchViaWeb() async throws -> AuroraRelease? {
        var request = URLRequest(url: URL(string: "https://github.com/\(repository)/releases/latest")!)
        request.setValue("Aurora-macOS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.network }
        guard (200..<300).contains(http.statusCode) else { throw UpdateError.server(http.statusCode) }
        guard let finalURL = response.url else { throw UpdateError.decode }

        let parts = finalURL.path.split(separator: "/").map(String.init)
        // /releases/latest 没有重定向（仓库还没有 release）时最后一节就是 latest
        guard let tag = parts.last, tag != "latest", parts.count >= 2, parts[parts.count - 2] == "tag" else {
            return nil
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

        var assetURL: URL?
        var assetName: String?
        var checksumURL: URL?
        if let assetsURL = URL(string: "https://github.com/\(repository)/releases/expanded_assets/\(tag)") {
            var assetsRequest = URLRequest(url: assetsURL)
            assetsRequest.setValue("Aurora-macOS", forHTTPHeaderField: "User-Agent")
            assetsRequest.timeoutInterval = 20
            if let (data, assetsResponse) = try? await URLSession.shared.data(for: assetsRequest),
               let assetsHTTP = assetsResponse as? HTTPURLResponse, assetsHTTP.statusCode == 200,
               let html = String(data: data, encoding: .utf8) {
                let links = Self.downloadLinks(in: html).compactMap { raw -> URL? in
                    guard let url = URL(string: raw), UpdateSecurity.allowed(url) else { return nil }
                    return url
                }
                if let zip = links.first(where: { $0.path.lowercased().hasSuffix(".zip") }) {
                    assetURL = zip
                    assetName = zip.lastPathComponent
                    checksumURL = links.first { $0.lastPathComponent == zip.lastPathComponent + ".sha256" }
                }
            }
        }

        // 备用渠道拿不到 API 的 body，用 releases.atom 补更新说明（不计入 REST 限额）
        let notes = await releaseNotesFromAtom(tag: tag) ?? ""

        return AuroraRelease(
            version: version,
            tag: tag,
            notes: notes,
            publishedAt: nil,
            asset: assetURL,
            assetName: assetName,
            page: URL(string: "https://github.com/\(repository)/releases/tag/\(tag)") ?? releasesPage,
            checksum: checksumURL
        )
    }


    /// 从 releases.atom 取某个 tag 的正文（原样返回 HTML，交给 ReleaseNotesParser 解析）
    nonisolated private static func releaseNotesFromAtom(tag: String) async -> String? {
        guard let url = URL(string: "https://github.com/\(repository)/releases.atom") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Aurora-macOS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let xml = String(data: data, encoding: .utf8) else { return nil }
        // 找出含该 tag 的 <entry>，取其中的 <content type="html">…</content>
        let entries = xml.components(separatedBy: "<entry>")
        guard let entry = entries.first(where: { $0.contains("/releases/tag/\(tag)") }) else { return nil }
        guard let open = entry.range(of: "<content"),
              let openEnd = entry.range(of: ">", range: open.lowerBound..<entry.endIndex)?.upperBound,
              let close = entry.range(of: "</content>", range: openEnd..<entry.endIndex) else { return nil }
        let html = String(entry[openEnd..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return html.isEmpty ? nil : html
    }

    /// 从 expanded_assets 的 HTML 里提取 /releases/download/... 链接
    nonisolated private static func downloadLinks(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"/[^"\s<>]+/releases/download/[^"\s<>]+"#) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range)
            .compactMap { Range($0.range, in: html).map { String(html[$0]) } }
            .map { $0.hasPrefix("http") ? $0 : "https://github.com\($0)" }
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

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard UpdateSecurity.allowed(request.url) else {
            task.cancel()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum UpdateSecurity {
    static func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
        if host == "github.com" || host == "api.github.com" { return true }
        return host == "githubusercontent.com" || host.hasSuffix(".githubusercontent.com")
    }

    static func safeVersion(_ version: String) -> String {
        let cleaned = version.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
        if cleaned.isEmpty { return "unknown" }
        return String(cleaned.prefix(64))
    }

    /// `shasum -a 256` 的第一列，64 位十六进制。
    static func parseSHA256(_ text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).first else { return nil }
        guard let token = line.split(whereSeparator: \.isWhitespace).first else { return nil }
        let hex = String(token).lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
