import CoreGraphics
import ImageIO
import XCTest
@testable import Aurora

/// 设备外壳清单：内置款的 PNG 要在 `Resources/DeviceFrames/`，
/// 按需下载款的整图要在仓库 `FrameLibrary/`（装机后从这个目录下载），
/// 两款都要有 320px 缩略图，清单里的尺寸和孔洞要对得上。
final class DeviceFrameManifestTests: XCTestCase {
    private var repo: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AuroraWorkflow
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
    }

    private var directory: URL { repo.appendingPathComponent("Resources/DeviceFrames", isDirectory: true) }
    private var library: URL { repo.appendingPathComponent("FrameLibrary", isDirectory: true) }

    private func entries() throws -> [[String: Any]] {
        let data = try Data(contentsOf: directory.appendingPathComponent("frames.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func image(at url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "读不到 \(url.lastPathComponent)")
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "解不开 \(url.lastPathComponent)")
    }

    func testEveryManifestEntryHasAnImage() throws {
        let list = try entries()
        XCTAssertGreaterThanOrEqual(list.count, 20, "外壳库应该覆盖 Apple 全系列")
        var missing: [String] = []
        for entry in list {
            let file = try XCTUnwrap(entry["file"] as? String)
            let remote = entry["remote"] as? Bool ?? false
            let url = (remote ? library : directory).appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: url.path) {
                missing.append(remote ? "FrameLibrary/\(file)" : file)
            }
        }
        XCTAssertTrue(missing.isEmpty, "清单里的图找不到：\(missing.joined(separator: "、"))")
    }

    /// 大图留在仓库里按需下载，包内只带缩略图 —— 这条守住「别又把 30MB 全塞回包里」
    func testBulkFramesStayOutOfTheBundle() throws {
        let list = try entries()
        let remote = list.filter { $0["remote"] as? Bool ?? false }
        XCTAssertFalse(remote.isEmpty, "全部打成内置会让安装包涨到 60MB")
        let bundled = list
            .filter { !($0["remote"] as? Bool ?? false) }
            .compactMap { $0["file"] as? String }
        XCTAssertFalse(bundled.contains("imac-24-blue.png"), "大尺寸机型应该按需下载")
        XCTAssertTrue(bundled.contains("macbook-pro-14-space-black.png"), "最常见机型要能离线直接用")
    }

    func testThumbnailsExistAndStaySmall() throws {
        for entry in try entries() {
            let file = try XCTUnwrap(entry["file"] as? String)
            let url = directory.appendingPathComponent("thumbs").appendingPathComponent(file)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "缺缩略图：\(file)")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let thumb = try image(at: url)
            XCTAssertLessThanOrEqual(max(thumb.width, thumb.height), 400, "\(file) 的缩略图太大")
        }
    }

    func testManifestSizesAndScreenOpening() throws {
        let list = try entries()
        var ids = Set<String>()
        for entry in list {
            let file = try XCTUnwrap(entry["file"] as? String)
            let device = try XCTUnwrap(entry["device"] as? String)
            let width = try XCTUnwrap(entry["w"] as? Int)
            let height = try XCTUnwrap(entry["h"] as? Int)
            let rect = try XCTUnwrap(entry["screen"] as? [Int])
            XCTAssertEqual(rect.count, 4, "\(device) 的 screen 必须是四个数")

            let id = (file as NSString).deletingPathExtension
            XCTAssertTrue(ids.insert(id).inserted, "外壳 id 重复：\(id)")

            let remote = entry["remote"] as? Bool ?? false
            let url = (remote ? library : directory).appendingPathComponent(file)
            let image = try image(at: url)
            XCTAssertEqual(image.width, width, "\(file) 的清单宽度和实际不符")
            XCTAssertEqual(image.height, height, "\(file) 的清单高度和实际不符")

            // 孔洞必须是画布内的一块矩形，且占画布的大部分：对不上时套壳会露出边框或溢出
            let hole = CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
            XCTAssertGreaterThan(hole.minX, 0, "\(device) 孔洞左边界越界")
            XCTAssertGreaterThan(hole.minY, 0, "\(device) 孔洞上边界越界")
            XCTAssertLessThan(hole.maxX, CGFloat(width), "\(device) 孔洞右边界越界")
            XCTAssertLessThan(hole.maxY, CGFloat(height), "\(device) 孔洞下边界越界")

            let ratio = hole.width * hole.height / (CGFloat(width) * CGFloat(height))
            XCTAssertGreaterThan(ratio, 0.3, "\(device) 孔洞太小，可能识别错了")
            XCTAssertLessThan(ratio, 0.95, "\(device) 孔洞几乎占满画布，可能识别错了")

            // 横屏机型在 1.2 以上，竖屏 iPhone 在 0.46 左右，正方形说明识别到了错的区域
            let aspect = hole.width / hole.height
            XCTAssertTrue((0.4...2.2).contains(aspect), "\(device) 屏幕比例异常：\(aspect)")
            XCTAssertGreaterThan(abs(aspect - 1), 0.4, "\(device) 的孔洞接近正方形，可能识别错了")
        }
    }

    /// 型号名不能重名，否则「换配色」会挑错兄弟款
    func testDeviceNamesAreUnique() throws {
        var seen = Set<String>()
        for entry in try entries() {
            let device = try XCTUnwrap(entry["device"] as? String)
            XCTAssertTrue(seen.insert(device).inserted, "外壳显示名重复：\(device)")
        }
    }
}
