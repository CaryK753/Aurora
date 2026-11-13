//  make-frames.swift
//  Aurora — 设备外壳生成器：按现有扁平风格画出 Apple 显示器与多代笔记本外壳，
//  输出 PNG 到 Resources/DeviceFrames，并把清单条目合并进 frames.json。
//
//  用法：swift Tools/make-frames.swift
//
//  画法（和仓库里原有的 4 张 Apple 素材同一路数）：
//  · 机身一层渐变圆角矩形，屏幕孔洞用 .clear 抠成透明；
//  · 笔记本下面压一条转轴底座，中间留一个小小的「抠手」凹槽；
//  · 显示器在机身下面接脖子 + 底座。

import AppKit

// MARK: - 规格

enum Kind {
    case laptop
    case display
    case imac
}

struct Finish {
    let name: String
    let top: NSColor
    let bottom: NSColor
    let edge: NSColor

    static let silver = Finish(
        name: "银色",
        top: NSColor(srgbRed: 0.87, green: 0.87, blue: 0.89, alpha: 1),
        bottom: NSColor(srgbRed: 0.73, green: 0.73, blue: 0.76, alpha: 1),
        edge: NSColor(srgbRed: 0.62, green: 0.62, blue: 0.65, alpha: 1)
    )
    static let spaceBlack = Finish(
        name: "深空黑",
        top: NSColor(srgbRed: 0.24, green: 0.24, blue: 0.25, alpha: 1),
        bottom: NSColor(srgbRed: 0.15, green: 0.15, blue: 0.16, alpha: 1),
        edge: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
    )
    static let midnight = Finish(
        name: "午夜色",
        top: NSColor(srgbRed: 0.22, green: 0.26, blue: 0.33, alpha: 1),
        bottom: NSColor(srgbRed: 0.13, green: 0.16, blue: 0.21, alpha: 1),
        edge: NSColor(srgbRed: 0.09, green: 0.11, blue: 0.15, alpha: 1)
    )
    static let gold = Finish(
        name: "金色",
        top: NSColor(srgbRed: 0.90, green: 0.82, blue: 0.70, alpha: 1),
        bottom: NSColor(srgbRed: 0.78, green: 0.69, blue: 0.55, alpha: 1),
        edge: NSColor(srgbRed: 0.66, green: 0.57, blue: 0.44, alpha: 1)
    )
    static let spaceGray = Finish(
        name: "深空灰",
        top: NSColor(srgbRed: 0.62, green: 0.62, blue: 0.63, alpha: 1),
        bottom: NSColor(srgbRed: 0.48, green: 0.48, blue: 0.50, alpha: 1),
        edge: NSColor(srgbRed: 0.40, green: 0.40, blue: 0.42, alpha: 1)
    )
    static let blue = Finish(
        name: "蓝色",
        top: NSColor(srgbRed: 0.55, green: 0.70, blue: 0.83, alpha: 1),
        bottom: NSColor(srgbRed: 0.41, green: 0.56, blue: 0.70, alpha: 1),
        edge: NSColor(srgbRed: 0.33, green: 0.46, blue: 0.59, alpha: 1)
    )
}

struct Spec {
    let file: String
    let device: String
    let screenW: Int
    let screenH: Int
    let kind: Kind
    let finish: Finish
    let notch: Bool
    let chin: Bool          // iMac 的下巴
    let maxWidth: CGFloat   // 输出宽度上限（不同机型拉开尺寸，避免被当成同款配色）

    init(_ file: String, _ device: String, _ w: Int, _ h: Int,
         kind: Kind, finish: Finish, notch: Bool = false, chin: Bool = false, maxWidth: CGFloat = 3000) {
        self.file = file
        self.device = device
        self.screenW = w
        self.screenH = h
        self.kind = kind
        self.finish = finish
        self.notch = notch
        self.chin = chin
        self.maxWidth = maxWidth
    }
}

let specs: [Spec] = [
    // 笔记本：新款（有刘海）
    Spec("macbook-air-13-silver", "MacBook Air 13″ 银色", 2560, 1664, kind: .laptop, finish: .silver, notch: true),
    Spec("macbook-air-13-midnight", "MacBook Air 13″ 午夜色", 2560, 1664, kind: .laptop, finish: .midnight, notch: true),
    Spec("macbook-air-15-silver", "MacBook Air 15″ 银色", 2880, 1864, kind: .laptop, finish: .silver, notch: true),
    Spec("macbook-air-15-midnight", "MacBook Air 15″ 午夜色", 2880, 1864, kind: .laptop, finish: .midnight, notch: true),
    // 笔记本：老款（无刘海）
    Spec("macbook-pro-13-space-gray", "MacBook Pro 13″ 深空灰", 2560, 1600, kind: .laptop, finish: .spaceGray),
    Spec("macbook-pro-15-silver", "MacBook Pro 15″ 银色", 2880, 1800, kind: .laptop, finish: .silver),
    Spec("macbook-12-gold", "MacBook 12″ 金色", 2304, 1440, kind: .laptop, finish: .gold),
    // 显示器
    Spec("studio-display-silver", "Studio Display 27″", 5120, 2880, kind: .display, finish: .silver),
    Spec("pro-display-xdr", "Pro Display XDR 32″", 6016, 3384, kind: .display, finish: .spaceGray, maxWidth: 3300),
    Spec("imac-24-blue", "iMac 24″ 蓝色", 4480, 2520, kind: .imac, finish: .blue, chin: true, maxWidth: 3120),
]

/// 输出宽度上限：外壳原图够用就行，太大只会撑大 App 与导出耗时
let maxOutputWidth: CGFloat = 3000

// MARK: - 绘制

/// 位图画布：显式指定像素尺寸，避免 lockFocus 在 Retina 上偷偷画成 2×
final class Canvas {
    let rep: NSBitmapImageRep
    let width: CGFloat
    let height: CGFloat

    init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
        rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width), pixelsHigh: Int(height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: width, height: height)
    }

    func begin() {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    }

    func end() {
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 左上原点 → AppKit 左下原点
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x, y: height - y - h, width: w, height: h)
    }
}


func verticalGradient(_ rect: NSRect, top: NSColor, bottom: NSColor) {
    let gradient = NSGradient(starting: top, ending: bottom)
    gradient?.draw(in: rect, angle: -90)
}

func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

/// 用 clear 合成把一块区域抠成透明
func punch(_ rect: NSRect, radius: CGFloat) {
    guard let context = NSGraphicsContext.current else { return }
    context.saveGraphicsState()
    context.compositingOperation = .clear
    NSColor.white.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    context.restoreGraphicsState()
}

func drawLaptop(spec: Spec, scale: CGFloat) -> (NSBitmapImageRep, NSRect) {
    let sw = CGFloat(spec.screenW) * scale
    let sh = CGFloat(spec.screenH) * scale
    let bezel = sw * 0.016
    let deck = sw * 0.048
    let padX = sw * 0.085
    let padTop = sw * 0.050
    let padBottom = sw * 0.018

    let bodyW = sw + bezel * 2
    let bodyH = sh + bezel * 2
    let width = bodyW + padX * 2
    let height = padTop + bodyH + deck + padBottom

    let canvas = Canvas(width: width.rounded(), height: height.rounded())
    let cw = canvas.width
    canvas.begin()
    let r = canvas.r

    let body = r(padX, padTop, bodyW, bodyH)
    let bodyRadius = bodyW * 0.022

    // 底座（压在本体下缘，比本体略宽一点）
    let deckRect = r(padX - bodyW * 0.012, padTop + bodyH - 2, bodyW + bodyW * 0.024, deck)
    let deckPath = NSBezierPath(roundedRect: deckRect, xRadius: deck * 0.42, yRadius: deck * 0.42)
    NSGraphicsContext.saveGraphicsState()
    deckPath.addClip()
    verticalGradient(deckRect, top: spec.finish.top, bottom: spec.finish.bottom)
    NSGraphicsContext.restoreGraphicsState()
    spec.finish.edge.setStroke()
    deckPath.lineWidth = max(1, deck * 0.03)
    deckPath.stroke()

    // 抠手：底座中间一个小小的暗色凹槽
    let scoopW = bodyW * 0.085
    let scoop = r((cw - scoopW) / 2, padTop + bodyH + deck * 0.14, scoopW, deck * 0.36)
    rounded(scoop, radius: scoop.height * 0.5, fill: spec.finish.edge.withAlphaComponent(0.5))

    // 机身外壳
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: bodyRadius, yRadius: bodyRadius)
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    verticalGradient(body, top: spec.finish.top, bottom: spec.finish.bottom)
    NSGraphicsContext.restoreGraphicsState()

    // 屏幕四周的黑边（比机身外框略小一圈，露出一条金属边）
    let innerInset = bezel * 0.42
    let bezelRect = body.insetBy(dx: innerInset, dy: innerInset)
    rounded(bezelRect, radius: bodyRadius * 0.82, fill: NSColor(srgbRed: 0.045, green: 0.045, blue: 0.05, alpha: 1))

    // 屏幕孔洞
    let screen = r(padX + bezel, padTop + bezel, sw, sh)
    punch(screen, radius: min(bezel * 0.30, 10))

    // 刘海
    if spec.notch {
        let notchW = sw * 0.088
        let notchH = bezel * 0.92
        let notchRect = r(padX + bezel + (sw - notchW) / 2, padTop + bezel - 1, notchW, notchH + 1)
        rounded(notchRect, radius: notchH * 0.55,
                fill: NSColor(srgbRed: 0.035, green: 0.035, blue: 0.04, alpha: 1))
    }

    canvas.end()
    return (canvas.rep, screen)
}

func drawDisplay(spec: Spec, scale: CGFloat) -> (NSBitmapImageRep, NSRect) {
    let sw = CGFloat(spec.screenW) * scale
    let sh = CGFloat(spec.screenH) * scale
    let rim = sw * 0.009            // 露在外面的金属边
    let bezel = sw * 0.009          // 屏幕四周的黑边
    let chin = spec.chin ? sw * 0.062 : 0
    let neckW = sw * 0.055
    let neckH = sh * 0.145
    let footW = sw * 0.26
    let footH = max(8, sh * 0.020)
    let padX = sw * 0.045
    let padTop = sw * 0.030
    let padBottom = sw * 0.022

    let bodyW = sw + (rim + bezel) * 2
    let bodyH = sh + (rim + bezel) * 2 + chin
    let width = bodyW + padX * 2
    let height = padTop + bodyH + neckH + footH + padBottom

    let canvas = Canvas(width: width.rounded(), height: height.rounded())
    let cw = canvas.width
    canvas.begin()
    let r = canvas.r

    let body = r(padX, padTop, bodyW, bodyH)
    let bodyRadius = bodyW * (spec.chin ? 0.030 : 0.016)

    // 脖子 + 底座（先画，被机身压住上端）
    let neckRect = r((cw - neckW) / 2, padTop + bodyH - 2, neckW, neckH + 2)
    let neckPath = NSBezierPath(roundedRect: neckRect, xRadius: neckW * 0.30, yRadius: neckW * 0.30)
    NSGraphicsContext.saveGraphicsState()
    neckPath.addClip()
    verticalGradient(neckRect, top: spec.finish.bottom, bottom: spec.finish.edge)
    NSGraphicsContext.restoreGraphicsState()

    let footRect = r((cw - footW) / 2, padTop + bodyH + neckH - footH * 0.55, footW, footH)
    let footPath = NSBezierPath(roundedRect: footRect, xRadius: footH * 0.48, yRadius: footH * 0.48)
    NSGraphicsContext.saveGraphicsState()
    footPath.addClip()
    verticalGradient(footRect, top: spec.finish.top, bottom: spec.finish.bottom)
    NSGraphicsContext.restoreGraphicsState()
    spec.finish.edge.setStroke()
    footPath.lineWidth = max(1, footH * 0.06)
    footPath.stroke()

    // 机身（金属）
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: bodyRadius, yRadius: bodyRadius)
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    verticalGradient(body, top: spec.finish.top, bottom: spec.finish.bottom)
    NSGraphicsContext.restoreGraphicsState()

    // 黑边玻璃面板（iMac 的下巴要留给机身颜色）
    let glassRect = r(padX + rim, padTop + rim, bodyW - rim * 2, sh + bezel * 2)
    rounded(glassRect, radius: bodyRadius * 0.78,
            fill: NSColor(srgbRed: 0.035, green: 0.035, blue: 0.04, alpha: 1))

    // 屏幕孔洞
    let screen = r(padX + rim + bezel, padTop + rim + bezel, sw, sh)
    punch(screen, radius: min(bezel * 0.28, 8))

    canvas.end()
    return (canvas.rep, screen)
}

// MARK: - 输出

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let dir = root.appendingPathComponent("Resources/DeviceFrames")

var manifest: [[String: Any]] = (try? Data(contentsOf: dir.appendingPathComponent("frames.json")))
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []

for spec in specs {
    let scale = min(1, spec.maxWidth / CGFloat(spec.screenW))
    let (rep, screenRect) = spec.kind == .laptop
        ? drawLaptop(spec: spec, scale: scale)
        : drawDisplay(spec: spec, scale: scale)

    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("✗ \(spec.file) 生成失败")
        continue
    }
    let url = dir.appendingPathComponent(spec.file + ".png")
    try? png.write(to: url)

    let w = rep.pixelsWide
    let h = rep.pixelsHigh
    // 清单里的 screen 是左上原点
    let screenTopLeft = [
        Int(screenRect.minX.rounded()),
        Int((CGFloat(rep.pixelsHigh) - screenRect.maxY).rounded()),
        Int(screenRect.width.rounded()),
        Int(screenRect.height.rounded())
    ]
    let entry: [String: Any] = [
        "file": spec.file + ".png",
        "device": spec.device,
        "category": "mac",
        "w": w,
        "h": h,
        "screen": screenTopLeft
    ]
    manifest.removeAll { ($0["file"] as? String) == spec.file + ".png" }
    manifest.append(entry)
    print("✓ \(spec.file).png  \(w)×\(h)  屏幕 \(screenTopLeft)")
}

if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
    try? data.write(to: dir.appendingPathComponent("frames.json"))
    print("已更新 frames.json（\(manifest.count) 项）")
}
