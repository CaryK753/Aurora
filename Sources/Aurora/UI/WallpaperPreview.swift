//  WallpaperPreview.swift
//  Aurora — 壁纸全屏预览（黑场 + 内容 + 底部提示条，Esc / 点击退出）

import AppKit
import SwiftUI

@MainActor
enum WallpaperPreview {
    private static var window: WallpaperPreviewWindow?

    static func present(item: WallpaperItem, fill: WallpaperFill) {
        dismiss()
        guard let screen = NSScreen.main else { return }
        let window = WallpaperPreviewWindow(screen: screen, item: item, fill: fill)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    static func dismiss() {
        window?.closePreview()
        window = nil
    }
}

final class WallpaperPreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private let surface = WallpaperSurfaceView(frame: .zero)
    private var hud: NSHostingView<WallpaperPreviewHUD>!
    private var item: WallpaperItem
    private var fill: WallpaperFill

    init(screen: NSScreen, item: WallpaperItem, fill: WallpaperFill) {
        self.item = item
        self.fill = fill
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = false

        surface.frame = NSRect(origin: .zero, size: screen.frame.size)
        surface.autoresizingMask = [.width, .height]
        surface.show(item: item, fill: fill, animated: false)
        contentView = surface

        hud = NSHostingView(rootView: WallpaperPreviewHUD(item: item, fill: fill) { [weak self] in
            self?.applyFillSafe($0)
        })
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.wantsLayer = true
        hud.layer?.backgroundColor = NSColor.clear.cgColor
        contentView?.addSubview(hud)
        if let content = contentView {
            NSLayoutConstraint.activate([
                hud.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                hud.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -26)
            ])
        }
        refreshHUD()
    }

    fileprivate func closePreview() {
        surface.clear()
        orderOut(nil)
    }

    private func refreshHUD() {
        hud.rootView = WallpaperPreviewHUD(item: item, fill: fill) { [weak self] newFill in
            self?.applyFillSafe(newFill)
        }
    }

    private func applyFillSafe(_ newFill: WallpaperFill) {
        MainActor.assumeIsolated {
            guard newFill != fill else { return }
            fill = newFill
            surface.show(item: item, fill: fill, animated: false)
            refreshHUD()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.characters == "q" {
            WallpaperPreview.dismiss()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        WallpaperPreview.dismiss()
    }
}

private struct WallpaperPreviewHUD: View {
    let item: WallpaperItem
    let fill: WallpaperFill
    var onChangeFill: (WallpaperFill) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 9, weight: .bold))
                Text(item.name)
                    .font(.system(size: 11, weight: .semibold))
                if item.kind.isMotion {
                    Text(T("循环播放"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .foregroundStyle(.white)

            HStack(spacing: 4) {
                ForEach(WallpaperFill.allCases) { candidate in
                    Button {
                        onChangeFill(candidate)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: candidate.symbol)
                                .font(.system(size: 7.5, weight: .bold))
                            Text(candidate.title)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(fill == candidate ? AnyShapeStyle(Color.black) : AnyShapeStyle(.white.opacity(0.85)))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background {
                            Capsule().fill(
                                fill == candidate
                                    ? AnyShapeStyle(Color.white)
                                    : AnyShapeStyle(Color.black.opacity(0.35))
                            )
                        }
                        .overlay {
                            Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.6)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(T("点一下任意位置或按 Esc 退出预览"))
                .font(.system(size: 8.5))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        }
    }
}
