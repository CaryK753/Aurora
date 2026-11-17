import Foundation

/// 固定经过验证的版本，避免 GitHub API 限流影响首次安装。
/// 校验值来源：https://github.com/MetaCubeX/mihomo/releases/expanded_assets/v1.19.34
public enum ProxyEngineRelease {
    public static let version = "v1.19.34"
    public static let checksums = [
        "arm64": "1a7a20eca63fbbaec90137717465bfde488d0db2a3a79b8fadebf9b2545b6e4c",
        "amd64-compatible": "703bceaa494732fa456f47e6ac2f06bf0bc5593d4c927d5f61e10f1a31039c37"
    ]
    public static func downloadURL(platform: String) -> URL {
        URL(string: "https://github.com/MetaCubeX/mihomo/releases/download/\(version)/mihomo-darwin-\(platform)-\(version).gz")!
    }
}
