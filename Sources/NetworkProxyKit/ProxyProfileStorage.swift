import Foundation

public enum ProxyProfileStorage {
    public static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    public static func save(_ data: Data, to url: URL) throws {
        try prepare(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func load(from url: URL) throws -> ProxyProfile {
        try JSONDecoder().decode(ProxyProfile.self, from: Data(contentsOf: url))
    }
    public static func save(_ profile: ProxyProfile, to url: URL) throws {
        try save(JSONEncoder().encode(profile), to: url)
    }
}
