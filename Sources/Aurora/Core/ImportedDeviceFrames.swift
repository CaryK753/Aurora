import CoreGraphics
import Foundation
import ImageIO

enum ImportedDeviceFrames {
    private static let root = URL.applicationSupportDirectory
        .appendingPathComponent("Aurora/ImportedDeviceFrames", isDirectory: true)

    static func imageURL(_ id: String) -> URL? {
        guard id.hasPrefix("imported-"), UUID(uuidString: String(id.dropFirst("imported-".count))) != nil else { return nil }
        let url = root.appendingPathComponent(id).appendingPathComponent("frame.png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func list() -> [DeviceFrame] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                     options: .skipsHiddenFiles)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("frame.json")),
                  let frame = try? JSONDecoder().decode(DeviceFrame.self, from: data),
                  frame.id == folder.lastPathComponent, imageURL(frame.id) != nil else { return nil }
            return frame
        }.sorted { $0.device.localizedStandardCompare($1.device) == .orderedAscending }
    }

    static func importPNG(_ url: URL) throws -> DeviceFrame {
        let name = url.deletingPathExtension().lastPathComponent
        if let existing = list().first(where: {
            guard $0.device == name, let copy = imageURL($0.id) else { return false }
            return FileManager.default.contentsEqual(atPath: url.path, andPath: copy.path)
        }) { return existing }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let hole = screenOpening(image) else { throw CocoaError(.fileReadCorruptFile) }
        let lowerName = name.lowercased()
        let category: String
        if lowerName.contains("iphone") {
            category = "iphone"
        } else if ["macbook", "imac", "studio display", "pro display"].contains(where: lowerName.contains) {
            category = "mac"
        } else {
            category = "imported"
        }
        let frame = DeviceFrame(id: "imported-" + UUID().uuidString, device: name, category: category,
                                pixelWidth: image.width, pixelHeight: image.height, screen: hole)
        let directory = root.appendingPathComponent(frame.id, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try manager.copyItem(at: url, to: directory.appendingPathComponent("frame.png"))
            try JSONEncoder().encode(frame).write(to: directory.appendingPathComponent("frame.json"), options: .atomic)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
        return frame
    }

    /// 寻找最大的封闭透明区域，排除与画布边缘相连的透明背景。
    static func screenOpening(_ image: CGImage) -> CGRect? {
        let factor = min(1, 480 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * factor))
        let height = max(1, Int(CGFloat(image.height) * factor))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var unseen = (0..<(width * height)).map { bytes[$0 * 4 + 3] < 64 }
        var best = CGRect.zero
        var bestCount = 0
        for index in unseen.indices where unseen[index] {
            var queue = [index]
            unseen[index] = false
            var read = 0
            var minX = width, minY = height, maxX = 0, maxY = 0
            func add(_ next: Int) {
                if unseen[next] { unseen[next] = false; queue.append(next) }
            }
            while read < queue.count {
                let pixel = queue[read]
                read += 1
                let x = pixel % width, y = pixel / width
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                if x > 0 { add(pixel - 1) }
                if x + 1 < width { add(pixel + 1) }
                if y > 0 { add(pixel - width) }
                if y + 1 < height { add(pixel + width) }
            }
            guard minX > 0, minY > 0, maxX + 1 < width, maxY + 1 < height,
                  queue.count > bestCount, queue.count > width * height / 20,
                  Double(queue.count) >= Double((maxX - minX + 1) * (maxY - minY + 1)) * 0.7 else { continue }
            bestCount = queue.count
            best = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
        guard !best.isEmpty else { return nil }
        return best.applying(.init(scaleX: CGFloat(image.width) / CGFloat(width),
                                   y: CGFloat(image.height) / CGFloat(height))).integral
    }
}
