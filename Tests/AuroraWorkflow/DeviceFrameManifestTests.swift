import CoreGraphics
import ImageIO
import XCTest
@testable import Aurora

/// 设备外壳清单的完整性：清单里列到的每一张 PNG 都要在仓库里，尺寸要对得上，
/// 屏幕孔洞要落在画布内。少一张 = 装机后少一款外壳（Bundle 不递归找子目录）。
final class DeviceFrameManifestTests: XCTestCase {
    private var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AuroraWorkflow
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Resources/DeviceFrames", isDirectory: true)
    }

    private func entries() throws -> [[String: Any]] {
        let data = try Data(contentsOf: directory.appendingPathComponent("frames.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    func testEveryManifestEntryHasItsImage() throws {
        let list = try entries()
        XCTAssertGreaterThanOrEqual(list.count, 20, "外壳库应该覆盖 Apple 全系列")
        var missing: [String] = []
        for entry in list {
            guard let file = entry["file"] as? String else {
                XCTFail("清单条目缺少 file：\(entry)")
                continue
            }
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) {
                missing.append(file)
            }
        }
        XCTAssertTrue(missing.isEmpty, "清单里有 PNG 没进仓库：\(missing.joined(separator: "、"))")
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

            let url = directory.appendingPathComponent(file)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "读不到 \(file)")
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "解不开 \(file)")
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
    func testDeviceNamesAreUniquePerGeometry() throws {
        var seen = Set<String>()
        for entry in try entries() {
            let device = try XCTUnwrap(entry["device"] as? String)
            XCTAssertTrue(seen.insert(device).inserted, "外壳显示名重复：\(device)")
        }
    }
}
