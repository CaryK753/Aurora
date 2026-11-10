//  Tools/make-icon.swift
//  用 Core Graphics 绘制 Aurora 应用图标，并导出 .icns
//  用法：swift Tools/make-icon.swift <输出目录>

import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let size: CGFloat = 1024

func makeIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    // macOS 图标留边约 8%
    let inset = size * 0.08
    let body = rect.insetBy(dx: inset, dy: inset)
    let radius = body.width * 0.2237
    let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    context.saveGState()
    squircle.addClip()

    // 底色：深色玻璃
    let base = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.19, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: 1).cgColor
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(base, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

    // 极光光斑
    let auroraColors = [
        NSColor(calibratedRed: 0.42, green: 0.87, blue: 1.0, alpha: 0.95).cgColor,
        NSColor(calibratedRed: 0.62, green: 0.52, blue: 1.0, alpha: 0.75).cgColor,
        NSColor(calibratedRed: 0.40, green: 0.93, blue: 0.76, alpha: 0.0).cgColor
    ] as CFArray
    let aurora = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: auroraColors, locations: [0, 0.55, 1])!
    context.drawRadialGradient(
        aurora,
        startCenter: CGPoint(x: size * 0.30, y: size * 0.72),
        startRadius: 0,
        endCenter: CGPoint(x: size * 0.34, y: size * 0.70),
        endRadius: size * 0.55,
        options: []
    )

    let aurora2Colors = [
        NSColor(calibratedRed: 0.55, green: 0.80, blue: 1.0, alpha: 0.55).cgColor,
        NSColor(calibratedRed: 0.35, green: 0.55, blue: 1.0, alpha: 0.0).cgColor
    ] as CFArray
    let aurora2 = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: aurora2Colors, locations: [0, 1])!
    context.drawRadialGradient(
        aurora2,
        startCenter: CGPoint(x: size * 0.78, y: size * 0.26),
        startRadius: 0,
        endCenter: CGPoint(x: size * 0.78, y: size * 0.26),
        endRadius: size * 0.42,
        options: []
    )

    // 顶部高光
    let highlight = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(white: 1, alpha: 0.16).cgColor,
            NSColor(white: 1, alpha: 0.0).cgColor
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        highlight,
        start: CGPoint(x: 0, y: body.maxY),
        end: CGPoint(x: 0, y: body.midY),
        options: []
    )

    // 边缘压暗，让整体更沉一些
    let vignette = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(white: 0, alpha: 0.0).cgColor,
            NSColor(white: 0, alpha: 0.0).cgColor,
            NSColor(white: 0, alpha: 0.42).cgColor
        ] as CFArray,
        locations: [0, 0.62, 1]
    )!
    context.drawRadialGradient(
        vignette,
        startCenter: CGPoint(x: size * 0.5, y: size * 0.5),
        startRadius: 0,
        endCenter: CGPoint(x: size * 0.5, y: size * 0.5),
        endRadius: size * 0.72,
        options: [.drawsAfterEndLocation]
    )

    // 玻璃内描边
    context.restoreGState()
    NSColor(white: 1, alpha: 0.22).setStroke()
    let strokePath = NSBezierPath(roundedRect: body.insetBy(dx: 1, dy: 1), xRadius: radius - 1, yRadius: radius - 1)
    strokePath.lineWidth = size * 0.008
    strokePath.stroke()

    // 中心标记：六边形排布的圆点（与菜单栏图标一致）
    let dotRadius = size * 0.052
    let spread = size * 0.108
    let center = CGPoint(x: size * 0.5, y: size * 0.5)
    var points: [CGPoint] = [center]
    for index in 0..<6 {
        let angle = CGFloat(index) * .pi / 3 + .pi / 6
        points.append(CGPoint(x: center.x + cos(angle) * spread * 1.06, y: center.y + sin(angle) * spread * 1.06))
    }

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.006), blur: size * 0.03, color: NSColor(white: 0, alpha: 0.35).cgColor)
    for point in points {
        let dot = CGRect(x: point.x - dotRadius, y: point.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
        NSColor(white: 1, alpha: 0.96).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }
    context.restoreGState()

    // 中心点加一点极光色
    let centerDot = CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
    NSColor(calibratedRed: 0.72, green: 0.95, blue: 1.0, alpha: 1).setFill()
    NSBezierPath(ovalIn: centerDot).fill()

    image.unlockFocus()
    return image
}

func pngData(_ image: NSImage, size: CGFloat) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let master = makeIcon(size: size)
let iconsetURL = URL(fileURLWithPath: outputDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in variants {
    let pixels = CGFloat(points * scale)
    guard let data = pngData(master, size: pixels) else { continue }
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try? data.write(to: iconsetURL.appendingPathComponent(name))
}

let icnsURL = URL(fileURLWithPath: outputDir).appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try? process.run()
process.waitUntilExit()
print("图标已生成：\(icnsURL.path)")
