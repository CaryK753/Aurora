//  ScreenshotView.swift
//  Aurora — 截图模块页：捕获入口、权限提示、外壳库

import SwiftUI
import AppKit

struct ScreenshotView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var permissions: PermissionService
    @State private var frames: [DeviceFrame] = []

    init(state: AppState) {
        self.state = state
        self.permissions = state.permissions
    }

    var body: some View {
        VStack(spacing: 12) {
            captureCard
            framesCard
            tipCard
        }
        .onAppear { frames = ScreenshotService.shared.frames }
    }

    // MARK: 捕获

    private var captureCard: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(AuroraTheme.accentGradient)
                        )
                        .shadow(color: AuroraTheme.accent.opacity(0.3), radius: 5, y: 2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(T("截图"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(T("选区标注、马赛克、滚动长截图、Apple 官方设备外壳"))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }

                if !permissions.screenRecording {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(AuroraTheme.warn)
                            Text(T("需要「屏幕录制」权限才能截取屏幕内容"))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(T("去授权")) {
                                permissions.requestScreenRecording()
                            }
                            .buttonStyle(SoftButtonStyle())
                        }
                        Text(T("录屏与截图共用这一项权限；画面只在本机处理，不会上传。"))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(9)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AuroraTheme.warn.opacity(0.1))
                    }
                }

                HStack(spacing: 8) {
                    captureButton(
                        title: T("区域截图"),
                        symbol: "viewfinder",
                        prominent: true
                    ) {
                        ScreenshotSession.shared.startRegionCapture()
                    }
                    captureButton(title: T("窗口截图"), symbol: "macwindow.on.rectangle") {
                        ScreenshotSession.shared.startRegionCapture(windowOnly: true)
                    }
                    captureButton(title: T("全屏截图"), symbol: "rectangle.inset.filled") {
                        ScreenshotSession.shared.startFullscreenCapture()
                    }
                    captureButton(title: T("长截图"), symbol: "arrow.down.forward.and.arrow.up.backward") {
                        ScreenshotSession.shared.startRegionCapture(longMode: true)
                    }
                }
            }
        }
    }

    private func captureButton(title: String, symbol: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(AuroraTheme.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.05)))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 外壳库

    private var framesCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    SectionLabel(text: T("设备外壳"), symbol: "iphone.gen3")
                    Spacer()
                    Text(T("截图后点「带壳」，自动按设备比例推荐"))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if frames.isEmpty {
                    Text(T("没有内置外壳，请检查应用完整性"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 128, maximum: 200), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(frames) { frame in
                            frameCard(frame)
                        }
                    }
                }
            }
        }
    }

    private func frameCard(_ frame: DeviceFrame) -> some View {
        VStack(spacing: 5) {
            if let url = ScreenshotService.resourceURL(frame.id + ".png"),
               let thumb = NSImage(contentsOf: url) {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 64)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 64)
            }

            VStack(spacing: 1) {
                Text(frame.device)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                Text("\(Int(frame.screen.width)) × \(Int(frame.screen.height))")
                    .font(.system(size: 7.5, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
    }

    private var tipCard: some View {
        GlassCard(padding: 12) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(T("保存与复制在编辑器里完成：标注支持撤销 / 重做，马赛克按原图像素化。"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(T("长截图：选中区域后滚动页面，点「下一屏」逐段捕获，最后「拼接」自动对齐重叠部分。"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(T("设备外壳使用 Apple Design Resources 官方素材，仅用于展示你自己的截图。"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
