//  WallpaperModels.swift
//  Aurora — 动态壁纸的数据模型（库条目 / 填充方式 / 自动切换规则）

import Foundation

// MARK: - 壁纸类型

enum WallpaperKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case image, video, gif, procedural

    var id: String { rawValue }

    var isMotion: Bool { self != .image }

    var symbol: String {
        switch self {
        case .image: return "photo.fill"
        case .video: return "video.fill"
        case .gif: return "rectangle.stack.badge.play.fill"
        case .procedural: return "sparkles.tv"
        }
    }

    var title: String {
        switch self {
        case .image: return T("静态图片")
        case .video: return T("视频")
        case .gif: return T("动图")
        case .procedural: return T("动态场景")
        }
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "webp"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    static let gifExtensions: Set<String> = ["gif"]

    init?(url: URL) {
        let ext = url.pathExtension.lowercased()
        if Self.gifExtensions.contains(ext) {
            self = .gif
        } else if Self.videoExtensions.contains(ext) {
            self = .video
        } else if Self.imageExtensions.contains(ext) {
            self = .image
        } else {
            return nil
        }
    }

    static var allExtensions: [String] {
        Array(imageExtensions).sorted() + Array(videoExtensions).sorted() + Array(gifExtensions).sorted()
    }
}

// MARK: - 填充方式

enum WallpaperFill: String, Codable, CaseIterable, Identifiable {
    case fill, fit, stretch, center, tile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fill: return T("填充")
        case .fit: return T("适应")
        case .stretch: return T("拉伸")
        case .center: return T("居中")
        case .tile: return T("平铺")
        }
    }

    var detail: String {
        switch self {
        case .fill: return T("铺满屏幕，超出部分裁掉")
        case .fit: return T("完整显示，空余留黑边")
        case .stretch: return T("拉伸到全屏，比例可能会变形")
        case .center: return T("按原始尺寸居中")
        case .tile: return T("按原始尺寸平铺重复")
        }
    }

    var symbol: String {
        switch self {
        case .fill: return "arrow.up.left.and.arrow.down.right"
        case .fit: return "rectangle.arrowtriangle.2.inward"
        case .stretch: return "arrow.left.and.right"
        case .center: return "smallcircle.filled.circle"
        case .tile: return "square.grid.3x3"
        }
    }
}

// MARK: - 壁纸条目

struct WallpaperItem: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var name: String
    var path: String
    var kind: WallpaperKind
    var bytes: Int
    var addedAt: Date
    /// 系统自带壁纸（Apple 库）：只引用，不复制进库里
    var isSystem: Bool = false
    /// 视频裁剪：起点（秒）
    var trimStart: Double = 0
    /// 视频裁剪：终点（秒），0 表示到片尾
    var trimEnd: Double = 0
    /// 程序生成场景：样式 ID（aurora / waves / mesh / sunset）
    var style: String?
    /// 程序生成场景：用户自定义色相偏移（度），nil / 0 = 默认配色
    var hue: Double?

    var url: URL { URL(fileURLWithPath: path) }

    /// 程序生成的场景没有文件，永远视为「存在」，否则 apply() 会被 guard 挡掉导致设置无反应
    var fileExists: Bool { kind == .procedural || FileManager.default.fileExists(atPath: path) }

    var byteText: String {
        guard bytes > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    var subtitle: String {
        if kind == .procedural {
            let customized = (hue ?? 0) != 0
            return customized ? T("动态场景 · 已自定义配色") : T("动态场景 · 程序生成")
        }
        if kind.isMotion, trimEnd > trimStart + 0.1, trimEnd > 0 {
            return "\(kind.title) · \(durationText(trimEnd - trimStart))"
        }
        return byteText.isEmpty ? kind.title : "\(kind.title) · \(byteText)"
    }

    private func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 自动切换规则

enum WallpaperRuleKind: String, Codable, CaseIterable, Identifiable {
    case single, appearance, schedule, random

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: return T("固定一张")
        case .appearance: return T("跟随外观")
        case .schedule: return T("按时间")
        case .random: return T("随机轮播")
        }
    }

    var detail: String {
        switch self {
        case .single: return T("一直显示同一张壁纸")
        case .appearance: return T("浅色 / 深色模式各用一张，切换系统外观时柔和过渡")
        case .schedule: return T("按一天里的时间点切换，比如早上、中午、晚上各一张")
        case .random: return T("从壁纸库或指定文件夹里随机挑，按间隔轮换")
        }
    }

    var symbol: String {
        switch self {
        case .single: return "pin.fill"
        case .appearance: return "circle.lefthalf.filled"
        case .schedule: return "clock.fill"
        case .random: return "shuffle"
        }
    }
}

/// 时间轴上的一格：一天中的第几分钟 → 某张壁纸
struct WallpaperSlot: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var minutes: Int = 0
    var itemID: String = ""

    var timeText: String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    var hour: Int {
        get { minutes / 60 }
        set { minutes = max(0, min(23, newValue)) * 60 + minute }
    }

    var minute: Int {
        get { minutes % 60 }
        set { minutes = hour * 60 + max(0, min(59, newValue)) }
    }
}

enum WallpaperRandomSource: String, Codable, CaseIterable, Identifiable {
    case library, folder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return T("整个壁纸库")
        case .folder: return T("指定文件夹")
        }
    }
}

struct WallpaperRule: Codable, Equatable {
    var kind: WallpaperRuleKind = .single
    var single: String = ""
    var light: String = ""
    var dark: String = ""
    var slots: [WallpaperSlot] = []
    var randomSource: WallpaperRandomSource = .library
    var randomFolder: String = ""
    /// 轮播间隔（分钟）
    var randomInterval: Int = 30

    func normalized() -> WallpaperRule {
        var copy = self
        copy.slots = copy.slots.sorted { $0.minutes < $1.minutes }
        return copy
    }
}

// MARK: - 整体配置

struct WallpaperConfig: Codable, Equatable {
    var enabled: Bool = false
    var fill: WallpaperFill = .fill
    var rule: WallpaperRule = WallpaperRule()
    /// 单独指定的显示器：displayKey -> itemID
    var perDisplay: [String: String] = [:]
    /// 单独指定的填充方式：displayKey -> fill
    var perDisplayFill: [String: WallpaperFill] = [:]

    static let storageKey = "wallpaper.config"

    static func load() -> WallpaperConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let config = try? JSONDecoder().decode(WallpaperConfig.self, from: data) else {
            return WallpaperConfig()
        }
        return config
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
