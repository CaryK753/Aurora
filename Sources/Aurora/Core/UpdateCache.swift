import Foundation

enum UpdateCache {
    static func discardArchives(in directory: URL) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for file in files where file.pathExtension.lowercased() == "zip" {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            do { try manager.removeItem(at: file) }
            catch { Debug.log("update ZIP: " + error.localizedDescription) }
        }
    }

    /// 旧版按版本号保存 ZIP 和 unpacked。只清理此应用专属目录中的版本缓存。
    static func prune(in root: URL, through version: String, keeping: URL? = nil, runningApp: URL) {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let running = runningApp.resolvingSymlinksInPath().standardizedFileURL.path
        guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys),
                                                              options: [.skipsHiddenFiles]) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.first?.isNumber == true, name == UpdateSecurity.safeVersion(name),
                  !UpdateService.isNewer(name, than: version),
                  entry.standardizedFileURL.path != keeping?.standardizedFileURL.path,
                  let values = try? entry.resourceValues(forKeys: keys), values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            let path = entry.resolvingSymlinksInPath().standardizedFileURL.path
            guard !running.hasPrefix(path + "/") else { continue }
            do {
                discardArchives(in: entry)
                let unpacked = entry.appendingPathComponent("unpacked")
                if manager.fileExists(atPath: unpacked.path) { try manager.removeItem(at: unpacked) }
                if try manager.contentsOfDirectory(atPath: entry.path).isEmpty { try manager.removeItem(at: entry) }
            } catch { Debug.log("update cache: " + error.localizedDescription) }
        }
    }
}
