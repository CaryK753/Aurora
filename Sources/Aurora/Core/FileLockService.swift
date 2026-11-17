//  FileLockService.swift
//  Aurora — 右键锁定 / 解锁
//
//  改权限位挡不住文件主人和其他同用户进程。这里把明文从磁盘上拿掉：
//  AES-GCM 分块加密，密钥在登录钥匙串里。密码 / Touch ID 由 LocalAuthentication 弹出。
//  不用带 userPresence 的数据保护钥匙串：那需要 keychain-access-groups 描述文件，
//  当前签名没有这份授权，SecItem 会直接返回 -34018。
//  锁定后的文件以 AURL 开头，访达和其他 App 读到的是密文。

import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum FileLockService {
    private static let magic = Data("AURL".utf8)
    private static let archiveMagic = Data("AURD".utf8)
    private static let version: UInt8 = 1
    private static let chunkSize = 1024 * 1024
    private static let service = "com.cary.aurora.file-lock"
    private static let account = "content-key"

    static func isLocked(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == magic
    }

    /// 一批选中项只验证一次。菜单栏应用默认是 accessory，系统不会为它弹出密码或 Touch ID，所以先切成普通应用。
    @MainActor
    static func toggle(_ urls: [URL], done: @escaping (String) -> Void) {
        let targets = urls.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        guard !targets.isEmpty else {
            done(T("先选中要锁定的文件或文件夹"))
            return
        }
        if let refused = targets.compactMap(refusal).first {
            done(refused)
            return
        }
        let locking = targets.contains { !isLocked($0) }
        let reason = locking ? T("验证身份后锁定选中的内容") : T("验证身份后解锁选中的内容")
        let context = LAContext()
        context.localizedCancelTitle = T("取消")
        context.touchIDAuthenticationAllowableReuseDuration = 30
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            done(policyError?.localizedDescription ?? T("这台 Mac 没有可用的密码或 Touch ID"))
            return
        }
        let previous = NSApp.activationPolicy()
        if previous != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            Task { @MainActor in
                defer {
                    if previous != .regular {
                        NSApp.setActivationPolicy(previous)
                    }
                }
                guard success else {
                    let cancelled = (error as? LAError)?.code == .userCancel || (error as? LAError)?.code == .appCancel
                    done(cancelled ? T("已取消") : (error?.localizedDescription ?? T("已取消")))
                    return
                }
                let result: String
                do {
                    let key = try loadKey()
                    result = apply(targets, key: key)
                } catch {
                    result = message(for: error)
                }
                Debug.log("file lock: \(result)")
                done(result)
            }
        }
    }

    @MainActor
    private static func apply(_ targets: [URL], key: SymmetricKey) -> String {
        var locked = 0
        var unlocked = 0
        var failures: [String] = []
        for url in targets {
            do {
                if isLocked(url) {
                    try unlock(url, key: key)
                    unlocked += 1
                } else {
                    try lock(url, key: key)
                    locked += 1
                }
            } catch {
                failures.append("\(url.lastPathComponent)：\(message(for: error))")
            }
        }
        var parts: [String] = []
        if locked > 0 { parts.append(TF("已锁定 %d 项", locked)) }
        if unlocked > 0 { parts.append(TF("已解锁 %d 项", unlocked)) }
        if let failure = failures.first { parts.append(failure) }
        return parts.isEmpty ? T("没有需要锁定的内容") : parts.joined(separator: "，")
    }

    /// 不碰钥匙串，用临时密钥把文件和文件夹各锁一次再解开。失败时返回原因。
    static func selfTest() -> String? {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aurora-lock-\(UUID().uuidString)", isDirectory: true)
        let key = SymmetricKey(size: .bits256)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("note.txt")
            let marker = Data("aurora-lock-marker-请勿外泄".utf8)
            try marker.write(to: file)
            try lock(file, key: key)
            let cipher = try Data(contentsOf: file)
            if cipher.prefix(4) != magic { return "锁定后没有写入文件头" }
            if cipher.range(of: marker) != nil { return "密文里还能看到原文" }
            try unlock(file, key: key)
            if try Data(contentsOf: file) != marker { return "解锁后的文件内容和原来不一样" }

            let folder = root.appendingPathComponent("Album", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("one".utf8).write(to: folder.appendingPathComponent("a.txt"))
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try Data("two".utf8).write(to: folder.appendingPathComponent("sub/b.txt"))
            try lock(folder, key: key)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return "文件夹锁定后仍是目录"
            }
            let folderCipher = try Data(contentsOf: folder)
            if folderCipher.range(of: Data("one".utf8)) != nil { return "文件夹密文里还能看到原文" }
            try unlock(folder, key: key)
            let restored = try Data(contentsOf: folder.appendingPathComponent("sub/b.txt"))
            if restored != Data("two".utf8) { return "文件夹解锁后内容不对" }
            return nil
        } catch {
            try? FileManager.default.removeItem(at: root)
            return message(for: error)
        }
    }

    private static func refusal(_ url: URL) -> String? {
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "/" || path == home || path == "/Applications" || path == "/Users" {
            return T("这个位置不能锁定")
        }
        let banned = ["/System", "/usr", "/bin", "/sbin", "/Library", "/private", "/Applications", home + "/Library"]
        if banned.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) || FinderRequestGuard.isSensitive(path) {
            return T("系统位置不能锁定")
        }
        if path.hasSuffix(".app") || path.contains(".app/") || path.hasSuffix(".appex") {
            return T("应用不能锁定")
        }
        return nil
    }

    private static func lock(_ url: URL, key: SymmetricKey) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw FileLockError.unreadable }
        let parent = url.deletingLastPathComponent()
        let cipher = parent.appendingPathComponent(".\(url.lastPathComponent).aurora-locking")
        defer { try? FileManager.default.removeItem(at: cipher) }
        if isDirectory.boolValue {
            let archive = parent.appendingPathComponent(".\(url.lastPathComponent).aurora-archive")
            defer { try? FileManager.default.removeItem(at: archive) }
            try writeArchive(from: url, to: archive)
            try encryptFile(archive, to: cipher, key: key, kind: 2, mode: 0)
        } else {
            let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            try encryptFile(url, to: cipher, key: key, kind: 1, mode: mode)
        }
        try swap(cipher, into: url)
        applyLockedIcon(at: url, folder: isDirectory.boolValue)
    }

    private static func unlock(_ url: URL, key: SymmetricKey) throws {
        let parent = url.deletingLastPathComponent()
        let plain = parent.appendingPathComponent(".\(url.lastPathComponent).aurora-unlocking")
        defer { try? FileManager.default.removeItem(at: plain) }
        let kind = try decryptFile(url, to: plain, key: key)
        if kind == 2 {
            let folder = parent.appendingPathComponent(".\(url.lastPathComponent).aurora-folder")
            try? FileManager.default.removeItem(at: folder)
            defer { try? FileManager.default.removeItem(at: folder) }
            try readArchive(plain, to: folder)
            try swap(folder, into: url)
        } else {
            try swap(plain, into: url)
        }
        NSWorkspace.shared.setIcon(nil, forFile: url.path, options: [])
    }

    private static func swap(_ source: URL, into destination: URL) throws {
        let backup = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).aurora-backup")
        let manager = FileManager.default
        try? manager.removeItem(at: backup)
        do {
            try manager.moveItem(at: destination, to: backup)
        } catch {
            throw FileLockError.unreadable
        }
        do {
            try manager.moveItem(at: source, to: destination)
            try? manager.removeItem(at: backup)
        } catch {
            try? manager.removeItem(at: destination)
            try? manager.moveItem(at: backup, to: destination)
            throw error
        }
    }

    private static func encryptFile(_ source: URL, to destination: URL, key: SymmetricKey, kind: UInt8, mode: UInt16) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        var header = magic
        header.append(version)
        header.append(kind)
        header.append(UInt8(mode >> 8))
        header.append(UInt8(mode & 0xff))
        try output.write(contentsOf: header)
        var index: UInt32 = 0
        while true {
            let chunk = try input.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty {
                try output.write(contentsOf: encode(UInt32(0)))
                break
            }
            let sealed = try AES.GCM.seal(chunk, using: key, authenticating: authenticated(kind: kind, index: index))
            guard let combined = sealed.combined else { throw FileLockError.corrupt }
            try output.write(contentsOf: encode(UInt32(combined.count)))
            try output.write(contentsOf: combined)
            index += 1
        }
        if kind == 1, mode != 0 {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: destination.path)
        }
    }

    private static func decryptFile(_ source: URL, to destination: URL, key: SymmetricKey) throws -> UInt8 {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard try input.read(upToCount: 4) == magic,
              try input.read(upToCount: 1)?.first == version,
              let kind = try input.read(upToCount: 1)?.first,
              let modeBytes = try input.read(upToCount: 2), modeBytes.count == 2 else { throw FileLockError.corrupt }
        let mode = UInt16(modeBytes[0]) << 8 | UInt16(modeBytes[1])
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var index: UInt32 = 0
        while true {
            guard let lengthBytes = try input.read(upToCount: 4), lengthBytes.count == 4 else { throw FileLockError.corrupt }
            let length = uint32(lengthBytes)
            if length == 0 { break }
            guard length < 16 * 1024 * 1024, let combined = try input.read(upToCount: Int(length)), combined.count == length else {
                throw FileLockError.corrupt
            }
            let box = try AES.GCM.SealedBox(combined: combined)
            let chunk = try AES.GCM.open(box, using: key, authenticating: authenticated(kind: kind, index: index))
            try output.write(contentsOf: chunk)
            index += 1
        }
        if kind == 1, mode != 0 {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: destination.path)
        }
        return kind
    }

    private static func authenticated(kind: UInt8, index: UInt32) -> Data {
        var data = Data([kind])
        data.append(encode(index))
        return data
    }

    private static func uint16(_ data: Data) -> UInt16 {
        guard data.count == 2 else { return 0 }
        return UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])
    }

    private static func uint32(_ data: Data) -> UInt32 {
        guard data.count == 4 else { return 0 }
        var value: UInt32 = 0
        for byte in data { value = (value << 8) | UInt32(byte) }
        return value
    }

    private static func uint64(_ data: Data) -> UInt64 {
        guard data.count == 8 else { return 0 }
        var value: UInt64 = 0
        for byte in data { value = (value << 8) | UInt64(byte) }
        return value
    }

    private static func canonical(_ path: String) -> String {
        path.withCString { raw in
            guard let resolved = realpath(raw, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    private static func encode(_ value: UInt32) -> Data {
        var big = value.bigEndian
        return Data(bytes: &big, count: MemoryLayout<UInt32>.size)
    }

    private static func writeArchive(from root: URL, to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var header = archiveMagic
        header.append(1)
        try output.write(contentsOf: header)
        let resolvedPath = canonical(root.path)
        try writeTree(URL(fileURLWithPath: resolvedPath, isDirectory: true), rootPath: resolvedPath, to: output)
        try output.write(contentsOf: Data([0]))
    }

    private static func writeTree(_ directory: URL, rootPath: String, to output: FileHandle) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        )
        for item in children {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            let childPath = item.path.hasPrefix(rootPath + "/") ? item.path : canonical(item.path)
            guard childPath.hasPrefix(rootPath + "/") else { throw FileLockError.corrupt }
            let relative = String(childPath.dropFirst(rootPath.count + 1))
            try validate(relative)
            if values.isSymbolicLink == true {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: item.path)
                try writeRecord(3, path: relative, to: output)
                try writeString(target, to: output)
                continue
            }
            if values.isDirectory == true {
                try writeRecord(2, path: relative, to: output)
                try writeTree(item, rootPath: rootPath, to: output)
                continue
            }
            guard values.isRegularFile == true else { throw FileLockError.unsupported(item.lastPathComponent) }
            let measured = values.fileSize ?? (try? FileManager.default.attributesOfItem(atPath: item.path)[.size] as? NSNumber)?.intValue ?? 0
            let size = Int64(measured)
            if size > 8_000_000_000 { throw FileLockError.tooLarge }
            try writeRecord(1, path: relative, to: output)
            let mode = (try? FileManager.default.attributesOfItem(atPath: item.path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            var modeValue = mode.bigEndian
            try output.write(contentsOf: Data(bytes: &modeValue, count: 2))
            var sizeValue = UInt64(size).bigEndian
            try output.write(contentsOf: Data(bytes: &sizeValue, count: 8))
            let input = try FileHandle(forReadingFrom: item)
            defer { try? input.close() }
            var remaining = size
            while remaining > 0 {
                let count = Int(min(Int64(chunkSize), remaining))
                guard let data = try input.read(upToCount: count), !data.isEmpty else { throw FileLockError.unreadable }
                try output.write(contentsOf: data)
                remaining -= Int64(data.count)
            }
        }
    }

    private static func readArchive(_ archive: URL, to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        guard try input.read(upToCount: 4) == archiveMagic, try input.read(upToCount: 1)?.first == 1 else {
            throw FileLockError.corrupt
        }
        var total = 0
        while true {
            guard let type = try input.read(upToCount: 1)?.first else { throw FileLockError.corrupt }
            if type == 0 { return }
            let relative = try readString(from: input)
            try validate(relative)
            let destination = root.appendingPathComponent(relative)
            switch type {
            case 2:
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            case 3:
                let target = try readString(from: input)
                try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
            case 1:
                guard let modeBytes = try input.read(upToCount: 2), modeBytes.count == 2,
                      let sizeBytes = try input.read(upToCount: 8), sizeBytes.count == 8 else { throw FileLockError.corrupt }
                let mode = uint16(modeBytes)
                let size = uint64(sizeBytes)
                if size > 8_000_000_000 || total > 8_000_000_000 { throw FileLockError.tooLarge }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: destination.path, contents: nil)
                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }
                var remaining = size
                while remaining > 0 {
                    let count = min(UInt64(chunkSize), remaining)
                    guard let data = try input.read(upToCount: Int(count)), !data.isEmpty else { throw FileLockError.corrupt }
                    try output.write(contentsOf: data)
                    remaining -= UInt64(data.count)
                    total += data.count
                }
                try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: destination.path)
            default:
                throw FileLockError.corrupt
            }
        }
    }

    private static func writeRecord(_ type: UInt8, path: String, to output: FileHandle) throws {
        try output.write(contentsOf: Data([type]))
        try writeString(path, to: output)
    }

    private static func writeString(_ text: String, to output: FileHandle) throws {
        let bytes = Array(text.utf8)
        guard bytes.count < 64 * 1024 else { throw FileLockError.unsupported(text) }
        var length = UInt16(bytes.count).bigEndian
        try output.write(contentsOf: Data(bytes: &length, count: 2))
        try output.write(contentsOf: bytes)
    }

    private static func readString(from input: FileHandle) throws -> String {
        guard let lengthBytes = try input.read(upToCount: 2), lengthBytes.count == 2 else { throw FileLockError.corrupt }
        let length = Int(uint16(lengthBytes))
        guard let data = try input.read(upToCount: length), data.count == length, let text = String(data: data, encoding: .utf8) else {
            throw FileLockError.corrupt
        }
        return text
    }

    private static func validate(_ relative: String) throws {
        if relative.isEmpty || relative.hasPrefix("/") || relative.contains("\0") { throw FileLockError.corrupt }
        if relative.split(separator: "/").contains("..") { throw FileLockError.corrupt }
    }

    static let noticeDefaultsKey = "filelock.notice.acknowledged"

    /// 还没看过说明，并且这次会加密至少一项新内容。
    static func needsNotice(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, !UserDefaults.standard.bool(forKey: noticeDefaultsKey) else { return false }
        return urls.contains { !isLocked($0) }
    }

    /// 右键时由主 App 补图标。只处理文件头确实是 AURL 的项。
    static func applyLockedIcons(_ urls: [URL]) {
        for url in urls {
            guard let kind = lockedKind(url), !iconMarked(url) else { continue }
            applyLockedIcon(at: url, folder: kind == 2)
        }
    }

    private static func applyLockedIcon(at url: URL, folder: Bool) {
        NSWorkspace.shared.setIcon(lockedIcon(folder: folder), forFile: url.path, options: [])
        markIcon(url)
    }

    private static func lockedKind(_ url: URL) -> UInt8? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.read(upToCount: 4)) == magic,
              (try? handle.read(upToCount: 1))?.first == version,
              let kind = (try? handle.read(upToCount: 1))?.first else { return nil }
        return kind
    }

    private static let iconAttribute = "com.cary.aurora.lock-icon"

    private static func iconMarked(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, iconAttribute, nil, 0, 0, 0) >= 0
        }
    }

    private static func markIcon(_ url: URL) {
        var byte: UInt8 = 1
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            setxattr(path, iconAttribute, &byte, 1, 0, 0)
        }
    }

    private static let fileIconImage = makeLockedIcon(folder: false)
    private static let folderIconImage = makeLockedIcon(folder: true)

    private static func lockedIcon(folder: Bool) -> NSImage {
        folder ? folderIconImage : fileIconImage
    }

    /// 灰蓝文件 / 文件夹，白锁居中。不用系统默认的白纸图标。
    private static func makeLockedIcon(folder: Bool) -> NSImage {
        let side: CGFloat = 1024
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let slate = NSColor(srgbRed: 0.43, green: 0.48, blue: 0.54, alpha: 1)
            let slateDeep = NSColor(srgbRed: 0.34, green: 0.38, blue: 0.44, alpha: 1)
            if folder {
                let tab = NSBezierPath(roundedRect: NSRect(x: 168, y: 640, width: 300, height: 120), xRadius: 36, yRadius: 36)
                slateDeep.setFill()
                tab.fill()
                let body = NSBezierPath(roundedRect: NSRect(x: 136, y: 168, width: 752, height: 560), xRadius: 72, yRadius: 72)
                slate.setFill()
                body.fill()
                drawLock(center: NSPoint(x: 512, y: 410), scale: 1.22)
            } else {
                let page = NSRect(x: 212, y: 128, width: 600, height: 768)
                let fold: CGFloat = 148
                slate.setFill()
                let shape = NSBezierPath()
                shape.move(to: NSPoint(x: page.minX + 48, y: page.minY))
                shape.appendArc(from: NSPoint(x: page.maxX, y: page.minY), to: NSPoint(x: page.maxX, y: page.minY + 48), radius: 48)
                shape.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
                shape.line(to: NSPoint(x: page.maxX - fold, y: page.maxY))
                shape.line(to: NSPoint(x: page.minX + 48, y: page.maxY))
                shape.appendArc(from: NSPoint(x: page.minX, y: page.maxY), to: NSPoint(x: page.minX, y: page.maxY - 48), radius: 48)
                shape.close()
                shape.fill()
                slateDeep.setFill()
                let ear = NSBezierPath()
                ear.move(to: NSPoint(x: page.maxX - fold, y: page.maxY))
                ear.line(to: NSPoint(x: page.maxX - fold, y: page.maxY - fold + 28))
                ear.appendArc(from: NSPoint(x: page.maxX - fold, y: page.maxY - fold), to: NSPoint(x: page.maxX - fold + 28, y: page.maxY - fold), radius: 28)
                ear.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
                ear.close()
                ear.fill()
                drawLock(center: NSPoint(x: 512, y: 460), scale: 1.18)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawLock(center: NSPoint, scale: CGFloat) {
        NSColor.white.withAlphaComponent(0.94).setFill()
        let body = NSRect(x: center.x - 92 * scale, y: center.y - 118 * scale, width: 184 * scale, height: 150 * scale)
        NSBezierPath(roundedRect: body, xRadius: 28 * scale, yRadius: 28 * scale).fill()
        let shackle = NSBezierPath()
        shackle.lineWidth = 28 * scale
        shackle.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.94).setStroke()
        let radius = 58 * scale
        shackle.appendArc(withCenter: NSPoint(x: center.x, y: body.maxY - 8 * scale), radius: radius, startAngle: 0, endAngle: 180, clockwise: false)
        shackle.stroke()
    }

    /// 登录钥匙串里的普通密码项。身份验证已经在调用前完成。
    private static func loadKey() throws -> SymmetricKey {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var read = base
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        if status != errSecItemNotFound { throw FileLockError.keychain(status) }

        let created = SymmetricKey(size: .bits256)
        let data = created.withUnsafeBytes { Data($0) }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Aurora 文件锁定"
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecDuplicateItem {
            var again: CFTypeRef?
            let againStatus = SecItemCopyMatching(read as CFDictionary, &again)
            if againStatus == errSecSuccess, let data = again as? Data, data.count == 32 {
                return SymmetricKey(data: data)
            }
            throw FileLockError.keychain(againStatus == errSecSuccess ? errSecDecode : againStatus)
        }
        if added != errSecSuccess { throw FileLockError.keychain(added) }
        return created
    }

    private static func message(for error: Error) -> String {
        switch error {
        case FileLockError.cancelled: return T("已取消")
        case FileLockError.unreadable: return T("这个文件正在使用或无法读取")
        case FileLockError.tooLarge: return T("内容超过 8GB，不能锁定")
        case FileLockError.corrupt: return T("锁定数据已损坏")
        case FileLockError.unsupported(let name): return TF("%@ 不能锁定", name)
        case FileLockError.keychain(let status): return TF("钥匙串错误 %d", status)
        default: return error.localizedDescription
        }
    }
}

private enum FileLockError: Error {
    case cancelled
    case unreadable
    case tooLarge
    case corrupt
    case unsupported(String)
    case keychain(OSStatus)
}
