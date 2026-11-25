//  DeviceFrameDownload.swift
//  Aurora — 设备外壳的按需下载
//
//  外壳大图不再全部塞进 app 包（29 款全带是 30MB），只留最常用的 MacBook Pro / iPhone
//  在包里，其余放在仓库的 FrameLibrary/ 目录，用到时按需下载到本机缓存。
//  包内仍带 320px 缩略图，所以外壳库即便离线也能浏览、能看出是哪一款。

import Foundation

enum DeviceFrameDownload {
    /// 外壳图所在的仓库与目录（与 app 内 Resources/DeviceFrames 分开，不进包）
    static let repository = "CaryK753/Aurora"
    static let remoteDirectory = "FrameLibrary"

    /// 下载缓存：Application Support/Aurora/DeviceFrames
    static var cacheDirectory: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Aurora/DeviceFrames", isDirectory: true)
    }

    static func cachedURL(_ name: String) -> URL? {
        let url = cacheDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 优先按版本号 tag 取（tag 里的图与包内清单一一对应），开发版没有对应 tag 时退回 main
    static func sources(for name: String) -> [URL] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var refs: [String] = []
        if !version.isEmpty { refs.append("v\(version)") }
        if !refs.contains("main") { refs.append("main") }
        return refs.compactMap { ref in
            URL(string: "https://raw.githubusercontent.com/\(repository)/\(ref)/\(remoteDirectory)/\(name)")
        }
    }

    /// 下载一张外壳图到缓存，返回本地路径。已存在则直接返回
    @discardableResult
    static func download(_ name: String) async throws -> URL {
        if let cached = cachedURL(name) { return cached }
        var lastError: Error = URLError(.badURL)
        for url in sources(for: name) {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, isPNG(data) else {
                    lastError = URLError(.badServerResponse)
                    continue
                }
                let directory = cacheDirectory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let target = directory.appendingPathComponent(name)
                try data.write(to: target, options: .atomic)
                Debug.log("device frame downloaded: \(name) (\(data.count) bytes)")
                return target
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func isPNG(_ data: Data) -> Bool {
        data.count > 1024 && data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// 缓存里已下载的外壳占用（给设置页 / 自检看）
    static func cachedSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory,
                                                                  includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}
