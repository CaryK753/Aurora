import CoreImage

struct RecordingFinishLayers {
    let canvas: CGRect
    private let base: CIImage
    private let still: CIImage?
    private let bezel: CIImage?
    private let cursor: CIImage?
    private let cursorSize: CGFloat
    private let effect: RecordingAppearance.CursorEffect?
    private let ripple: CIImage?
    private let arrow: Bool
    private let screenRect: CGRect

    init(canvas: CGRect, frame: DeviceFrame?, appearance: RecordingAppearance, still: CIImage?) throws {
        self.canvas = canvas
        base = CIImage(color: appearance.solidBackdrop ? CIColor(red: 0.10, green: 0.17, blue: 0.29) : .black)
            .cropped(to: canvas)
        self.still = still.map { Self.place($0, in: canvas, fill: true) }
        if let frame {
            guard let url = ScreenshotService.resourceURL(frame.id + ".png"),
                  let image = CIImage(contentsOf: url) else { throw VideoBezelError.frameUnavailable }
            let placed = Self.place(image, in: canvas.insetBy(dx: canvas.width * 0.06, dy: canvas.height * 0.06), fill: false)
            bezel = placed
            let scale = placed.extent.width / CGFloat(frame.pixelWidth)
            screenRect = CGRect(x: placed.extent.minX + frame.screen.minX * scale,
                                y: placed.extent.minY + (CGFloat(frame.pixelHeight) - frame.screen.maxY) * scale,
                                width: frame.screen.width * scale, height: frame.screen.height * scale)
        } else {
            bezel = nil
            screenRect = appearance.hasBackdrop ? canvas.insetBy(dx: canvas.width * 0.08, dy: canvas.height * 0.08) : canvas
        }
        effect = appearance.cursorEffect
        var ring = appearance
        ring.cursor = .ring
        ripple = effect == .ripple ? try Self.cursorGraphic(ring) : nil
        cursor = try Self.cursorGraphic(appearance)
        cursorSize = max(10, min(64, min(canvas.width, canvas.height) * 0.032)) * appearance.cursorSize
        arrow = appearance.cursor == .arrow || appearance.cursor == .image
    }

    func render(screen: CIImage?, background: CIImage?, time: Double,
                segments: [ZoomSegment], trace: RecordingZoom) -> CIImage {
        let backdrop = background.map { Self.place($0, in: canvas, fill: true) } ?? still
        var result = backdrop?.cropped(to: canvas).composited(over: base) ?? base
        guard let screen else { return result }
        let crop = ZoomSegment.crop(segments, trace: trace, at: time, extent: screen.extent)
        // 壳内等比容纳，保留窗口边缘，避免裁掉贴近窗口边缘的指针。
        let video = Self.place(screen.cropped(to: crop), in: screenRect, fill: false)
        let black = CIImage(color: .black).cropped(to: screenRect)
        result = video.composited(over: black).composited(over: result)
        if let cursor {
            func overlay(_ image: CIImage, at position: CGPoint, size: CGFloat, opacity: Double, anchored: Bool) {
                let point = CGPoint(x: screen.extent.minX + screen.extent.width * position.x,
                                    y: screen.extent.minY + screen.extent.height * position.y)
                guard crop.contains(point) else { return }
                let extent = video.extent
                let x = extent.minX + (point.x - crop.minX) / crop.width * extent.width
                let y = extent.minY + (point.y - crop.minY) / crop.height * extent.height
                var artwork = Self.place(image, in: CGRect(x: anchored ? x : x - size / 2,
                                                           y: anchored ? y - size : y - size / 2,
                                                           width: size, height: size), fill: false)
                if opacity < 1 {
                    artwork = artwork.applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
                    ])
                }
                result = artwork.cropped(to: extent).composited(over: result)
            }
            if effect == .ripple, let ripple, let click = trace.recentClick(at: time, within: 0.5) {
                let progress = (time - click.time) / 0.5
                overlay(ripple, at: CGPoint(x: click.x, y: click.y), size: cursorSize * (1.2 + 2 * progress),
                        opacity: 0.8 * (1 - progress), anchored: false)
            }
            if let position = trace.cursor(at: time) {
                if effect == .trail {
                    for step in (1...4).reversed() {
                        if let prior = trace.cursor(at: time - Double(step) * 0.035), prior != position {
                            overlay(cursor, at: prior, size: cursorSize, opacity: 0.43 - Double(step) * 0.075, anchored: arrow)
                        }
                    }
                }
                overlay(cursor, at: position, size: cursorSize, opacity: 1, anchored: arrow)
            }
        }
        return (bezel?.composited(over: result) ?? result).cropped(to: canvas)
    }

    private static func place(_ image: CIImage, in box: CGRect, fill: Bool) -> CIImage {
        let x = box.width / image.extent.width, y = box.height / image.extent.height
        let scale = fill ? max(x, y) : min(x, y)
        let scaled = image.transformed(by: .init(scaleX: scale, y: scale))
        return scaled.transformed(by: .init(translationX: box.midX - scaled.extent.midX,
                                            y: box.midY - scaled.extent.midY))
    }

    private static func cursorGraphic(_ style: RecordingAppearance) throws -> CIImage? {
        guard style.cursor != .none else { return nil }
        if style.cursor == .image {
            guard let url = style.cursorImage, let image = ScreenshotService.importImage(url) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return CIImage(cgImage: image)
        }
        guard let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw VideoBezelError.exportUnavailable }
        let color: CGColor
        switch style.cursorTint {
        case .white: color = CGColor(gray: 1, alpha: 1)
        case .black: color = CGColor(gray: 0.08, alpha: 1)
        case .blue: color = CGColor(red: 0.18, green: 0.54, blue: 1, alpha: 1)
        case .orange: color = CGColor(red: 1, green: 0.43, blue: 0.08, alpha: 1)
        }
        let outline = CGColor(gray: style.cursorTint == .black ? 1 : 0.10, alpha: 1)
        if style.cursor == .arrow {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 3, y: 61))
            path.addLines(between: [CGPoint(x: 43, y: 27), CGPoint(x: 26, y: 27),
                                    CGPoint(x: 35, y: 8), CGPoint(x: 25, y: 3),
                                    CGPoint(x: 16, y: 23), CGPoint(x: 3, y: 11)])
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(4)
            ctx.setFillColor(color)
            ctx.setStrokeColor(outline)
            ctx.drawPath(using: .fillStroke)
        } else if [.crosshair, .beam, .diamond].contains(style.cursor) {
            let path = CGMutablePath()
            switch style.cursor {
            case .diamond:
                path.move(to: CGPoint(x: 32, y: 59))
                path.addLines(between: [.init(x: 54, y: 32), .init(x: 32, y: 5), .init(x: 10, y: 32)])
                path.closeSubpath()
            case .beam:
                for pair in [[CGPoint(x: 20, y: 8), CGPoint(x: 44, y: 8)],
                             [.init(x: 32, y: 8), .init(x: 32, y: 56)],
                             [.init(x: 20, y: 56), .init(x: 44, y: 56)]] {
                    path.move(to: pair[0]); path.addLine(to: pair[1])
                }
            default:
                path.move(to: .init(x: 32, y: 5)); path.addLine(to: .init(x: 32, y: 59))
                path.move(to: .init(x: 5, y: 32)); path.addLine(to: .init(x: 59, y: 32))
            }
            ctx.setLineCap(.round)
            for (width, ink) in [(CGFloat(8), outline), (CGFloat(4), color)] {
                ctx.addPath(path)
                ctx.setLineWidth(width)
                ctx.setStrokeColor(ink)
                ctx.strokePath()
            }
        } else {
            let oval = CGRect(x: 10, y: 10, width: 44, height: 44)
            ctx.setStrokeColor(outline)
            ctx.setLineWidth(12)
            ctx.strokeEllipse(in: oval)
            if style.cursor == .ring {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(7)
                ctx.strokeEllipse(in: oval)
            } else {
                ctx.setFillColor(color)
                ctx.fillEllipse(in: oval)
            }
        }
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }
}
