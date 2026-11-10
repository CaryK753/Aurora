//  BrandMarks.swift
//  Aurora — 没有 App Bundle 的 CLI / IDE 品牌图标
//
//  opencode 与 Antigravity 没有可取的 .app 图标，这里用品牌方公开的 mark：
//  · opencode：官方 favicon.svg 的几何（512 视图框，白色外框 + 灰色内块）
//  · Antigravity：官方站 favicon（256px PNG，渐变 A）

import AppKit

enum BrandMarks {
    static func image(for id: String, size: CGFloat = 64) -> NSImage? {
        switch id {
        case "opencode": return opencode(size: size)
        case "antigravity": return bitmap(antigravityPNG, size: size)
        default: return nil
        }
    }

    /// GitHub mark：simple-icons 的官方几何（24×24），用模板渲染跟随明暗主题
    static func github(size: CGFloat = 14) -> NSImage? {
        guard let data = githubSVG.data(using: .utf8), let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }

    private static let githubSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#000000" d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/></svg>
    """

    static func bitmap(_ base64: String, size: CGFloat) -> NSImage? {
        guard let data = Data(base64Encoded: base64), let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: size, height: size)
        return image
    }

    /// 512 视图框：外框 128,96–384,416；内孔 192,160–320,352；灰块 192,224–320,352
    private static func opencode(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        let scale = size / 512
        let background = NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
            xRadius: size * 0.22,
            yRadius: size * 0.22
        )
        NSColor(srgbRed: 0x13 / 255, green: 0x10 / 255, blue: 0x10 / 255, alpha: 1).setFill()
        background.fill()

        let outer = NSRect(x: 128 * scale, y: 96 * scale, width: 256 * scale, height: 320 * scale)
        let inner = NSRect(x: 192 * scale, y: 160 * scale, width: 128 * scale, height: 192 * scale)
        let frame = NSBezierPath(rect: outer)
        frame.append(NSBezierPath(rect: inner))
        frame.windingRule = .evenOdd
        NSColor.white.setFill()
        frame.fill()

        // SVG 的 y 从顶部算，这里翻成 AppKit 的底部原点：512 - (224 + 128) = 160
        let block = NSRect(x: 192 * scale, y: 160 * scale, width: 128 * scale, height: 128 * scale)
        NSColor(srgbRed: 0x5A / 255, green: 0x58 / 255, blue: 0x58 / 255, alpha: 1).setFill()
        NSBezierPath(rect: block).fill()

        return image
    }

    private static let antigravityPNG = [
        "iVBORw0KGgoAAAANSUhEUgAAAQAAAAEACAMAAABrrFhUAAABKVBMVEVHcEw7ifQ5ifc4ivXeqCw1ivZytXWJdrw/je3phjA1iPxKmbM4ifc8ivQziPw3jPHl",
        "YU7UclvmXk7oVU2iulfnWk13vnOiuljUtzGGu2s6j98slNenbKGIe8gwh/s0h/85iP8vifY+if4wjekvivIvi+9Gi/0zk9kwkOJQi/g2l89Ah/c6nMQ/obfu",
        "UkXbWFhGpqpQrZpDhuxThexwf9Ragdx5esftXECma5NgtYXIXW9qheNdifCZb6a1ZITUZ1N1vXDqaTxegsWJv19drIzjly6fv1FHj8iIdalJhtu3vEF2fbC7",
        "am6Teow+jNqoeXVXoJ3PtjO/d13XeEZXj7V2qHrtdjOkrFSanGXMh0i/mUmLr2WvimB1nIWDiI2TjnZok5pth6a+qEN/YvewAAAAHnRSTlMAJro+/lb9/xH+",
        "1v6fc+2MPBdhzmyesyOtSdLjoFjdi0DlAAASr0lEQVR4nO2caUMaSxOFLyBIkCW5MbjdF3DDBQ2KO2qIS+Iejca4JRr9/z/irapepntm8BozMDPePo3mm3Ke",
        "OlXdM0P86y8jIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyNv9abn9evXf8NCvfH73bRbr/u63/W+In0HvX337u//EIQ3fd29nz59",
        "kvZRGxtvgYHf76wtekPuEQAh+I4MNgDAxsbS23f/AQTdvR0dHZyAFQHyv7H08hH0oH0A0CES8P2VkgDU27/9fo+tVHeH5V8Q0BIAev/u5U7D3o6vOgHZBBQB",
        "QeDtC22DN71fv3ICDECTBCy9f/8iCfRY/rUpaEWAEwAA71/gIED/XwUCJQEsAhtWBjABL5CA9P/VNgXPXp19P2M9sCF64AVm4A3zrw2BK1ycwIY2BUgvaw70",
        "ft23CDx0PHy6hvUJ/V+9+o4RONtQCCy9OALd+xIAuO/ouO4A+1cQgKurV2dX0j8HwKbA+7cv5zzQt7+PBIDBAxF46LimCGALXEELoDbO1ClABN75/b69Uk8v",
        "mOcZeHj4iv4fyP81JuAK7UMEGrCWtAi8GAK9+ySAsI/2QdACKOqBqzNE0Dj73tjYaGhD4KUcCbuF/a8PAsADuP+E9ZcAIAEYAkCgRuBFjIEeHgASICD/D9dM",
        "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",
    ].joined()
}
