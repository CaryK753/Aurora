//  DisplayOSD.swift
//  Aurora — 显示器 HUD（复刻 macOS 原生的方块 OSD）
//
//  用键盘调亮度/对比度/音量时，在被调整的那块屏底部中间显示 16 格方块，
//  1.2 秒后自动淡出。窗口不抢焦点、不拦截鼠标，全屏 App 上也能显示。

import AppKit
import SwiftUI

/// 显示内容
struct DisplayOSDState: Equatable {
    var symbol: String
    var value: Double
    var caption: String
}

@MainActor
final class DisplayOSD {
    static let shared = DisplayOSD()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private static let size = CGSize(width: 196, height: 64)

    func show(channel: DisplayChannel, value: Double, muted: Bool = false, displayName: String? = nil, on screen: NSScreen?) {
        let clamped = min(max(value, 0), 1)
        let state = DisplayOSDState(
            symbol: symbol(for: channel, value: clamped, muted: muted),
            value: clamped,
            caption: muted ? T("静音") : displayName ?? channel.title
        )
        present(state, on: screen)
    }

    private func symbol(for channel: DisplayChannel, value: Double, muted: Bool) -> String {
        switch channel {
        case .brightness:
            return value < 0.34 ? "sun.min.fill" : "sun.max.fill"
        case .contrast:
            return "circle.lefthalf.filled"
        case .volume:
            if muted || value <= 0.001 { return "speaker.slash.fill" }
            if value < 0.34 { return "speaker.wave.1.fill" }
            if value < 0.7 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }

    private func present(_ state: DisplayOSDState, on screen: NSScreen?) {
        guard let target = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = TransparentHostingView(rootView: DisplayOSDView(state: state))

        let visible = target.visibleFrame
        let frame = NSRect(
            x: visible.midX - Self.size.width / 2,
            y: visible.minY + 72,
            width: Self.size.width,
            height: Self.size.height
        )
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()

        if panel.alphaValue < 1 {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }

        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard let panel, panel.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .init(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        return panel
    }
}

private struct DisplayOSDView: View {
    let state: DisplayOSDState

    private var filled: Int {
        max(Int((state.value * 16).rounded()), state.value > 0.001 ? 1 : 0)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 3) {
                    ForEach(0..<16, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1.6, style: .continuous)
                            .fill(index < filled ? Color.white.opacity(0.95) : Color.white.opacity(0.22))
                            .frame(maxWidth: .infinity)
                            .frame(height: 11)
                    }
                }
                .frame(height: 11)

                HStack(spacing: 6) {
                    Text(state.caption)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                    Spacer(minLength: 0)
                    Text(Fmt.percent(state.value))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(width: 196, height: 64)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.62))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.7)
        }
    }
}
