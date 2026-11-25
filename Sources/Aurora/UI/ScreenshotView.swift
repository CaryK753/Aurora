//  ScreenshotView.swift
//  Aurora — 截图模块页：捕获入口、权限提示、外壳库

import SwiftUI
import AppKit

struct ScreenshotView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var permissions: PermissionService
    @ObservedObject private var frames = ScreenshotService.shared
    /// 其余外壳默认收起
    @State private var showsAllFrames = false

    init(state: AppState) {
        self.state = state
        self.permissions = state.permissions
    }

    var body: some View {
        VStack(spacing: 12) {
            captureCard
            framesCard

        }
        .onAppear {
            frames.reloadIfNeeded()
            // 升级前就指定过外壳的用户：那张图可能在云端，进来先补下
            if let `default` = frames.defaultFrame, frames.needsDownload(`default`), !frames.isDefaultAuto {
                Task { await frames.ensureDownloaded(`default`) }
            }
        }
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
                        Text(T("选区标注、马赛克、滚动长截图、设备外壳"))
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

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
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
                    }.help(T("长截图：选中区域后滚动页面，点「下一屏」逐段捕获，最后「拼接」自动对齐重叠部分。"))
                }.disabled(!permissions.screenRecording)
                Divider()
                Toggle(T("截图包含 Aurora 窗口"), isOn: $frames.includeAurora)
                    .toggleStyle(.switch).controlSize(.small)
                Button { importForFraming() } label: {
                    Label(T("打开图片并套壳…"), systemImage: "photo")
                }.buttonStyle(SoftButtonStyle())
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

    private func importForFraming() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let image = await Task.detached { ScreenshotService.importImage(url) }.value
            guard let image else {
                NSAlert(error: CocoaError(.fileReadCorruptFile)).runModal()
                return
            }
            ScreenshotSession.shared.presentEditor(image: image, chooseFrame: true)
        }
    }

    private func importDeviceFrame() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = true
        panel.message = T("选择带透明屏幕开孔的外壳 PNG")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            let (added, failed) = await Task.detached {
                var added: [DeviceFrame] = []
                var failed: [String] = []
                for url in urls {
                    do { added.append(try autoreleasepool { try ImportedDeviceFrames.importPNG(url) }) }
                    catch { failed.append(url.lastPathComponent) }
                }
                return (added, failed)
            }.value
            for frame in added { frames.registerImportedFrame(frame) }
            if !added.isEmpty { showsAllFrames = true }
            if !failed.isEmpty {
                let alert = NSAlert()
                alert.messageText = T("无法导入外壳 PNG")
                alert.informativeText = failed.joined(separator: "\n")
                alert.runModal()
            }
        }
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

                HStack {
                    Button(T("导入外壳 PNG…")) { importDeviceFrame() }
                    Link(T("Apple 产品外壳"), destination: URL(string: "https://developer.apple.com/design/resources/#product-bezels")!)
                        .font(.caption)
                }
                .buttonStyle(SoftButtonStyle())

                if frames.frames.isEmpty {
                    Text(T("没有内置外壳，请检查应用完整性"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                } else {
                    // 默认那一款直接铺开，其余收在折叠里：面板就这么高，
                    // 六张卡片一次性摊开会把下面全挤掉
                    if let `default` = frames.defaultFrame {
                        defaultFrameCard(`default`)
                    }

                    let others = frames.others
                    if !others.isEmpty {
                        DisclosureGroup(isExpanded: $showsAllFrames) {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 118, maximum: 200), spacing: 8)],
                                alignment: .leading,
                                spacing: 8
                            ) {
                                ForEach(others) { frame in
                                    frameCard(frame)
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            HStack(spacing: 5) {
                                Text(TF("其他外壳（%d）", others.count))
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                if !frames.isDefaultAuto {
                                    Text(T("已指定默认"))
                                        .font(.system(size: 8))
                                        .foregroundStyle(AuroraTheme.accent)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(AuroraTheme.accent.opacity(0.13)))
                                }
                            }
                        }
                        .disclosureGroupStyle(.automatic)
                    }
                }
            }
        }
    }

    /// 选中一款外壳：远程外壳先把大图下下来，落好了再设为默认
    private func choose(_ frame: DeviceFrame) {
        Task {
            if frames.needsDownload(frame), await frames.ensureDownloaded(frame) == false { return }
            frames.preferredFrameID = frame.id
        }
    }

    /// 默认外壳：大图 + 名称 + 自动识别标记 + 恢复自动
    private func defaultFrameCard(_ frame: DeviceFrame) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
                if let thumb = frames.thumbnail(frame) {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                }
            }
            .frame(width: 118, height: 74)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    // 配色已由下面的胶囊表示，标题里就不再重复，免得被截断
                    Text(frames.defaultFrameVariants.count > 1 ? frame.familyName : frame.device)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(T("默认"))
                        .font(.system(size: 7.5, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(AuroraTheme.accent))
                }
                Text("\(Int(frame.screen.width)) × \(Int(frame.screen.height)) · " + T(frame.category == "mac" ? "按屏幕尺寸匹配" : "按比例推荐"))
                    .font(.system(size: 8.5, design: .rounded))
                    .foregroundStyle(.tertiary)

                // 外壳大图不在安装包里（29 款全带太重），第一次用这个机型时下一下
                if frames.needsDownload(frame) {
                    HStack(spacing: 6) {
                        if frames.isDownloading(frame) {
                            ProgressView().controlSize(.small)
                            Text(T("正在下载外壳…"))
                                .font(.system(size: 8.5))
                                .foregroundStyle(.secondary)
                        } else {
                            Button { choose(frame) } label: {
                                Text(T("下载这台机器的外壳"))
                                    .font(.system(size: 8.5, weight: .medium))
                                    .foregroundStyle(AuroraTheme.accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(AuroraTheme.accent.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                            Text(frames.downloadFailure ?? T("外壳图按需下载，约 1–3 MB"))
                                .font(.system(size: 8))
                                .foregroundStyle(frames.downloadFailure == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
                                .lineLimit(2)
                        }
                    }
                }

                // 系统读不到机身配色（ioreg 与 system_profiler 都没有这项），
                // 同尺寸的深空黑 / 银色只能让用户点一下，别假装能识别
                let variants = frames.defaultFrameVariants
                if variants.count > 1 {
                    HStack(spacing: 4) {
                        ForEach(variants) { variant in
                            Button {
                                choose(variant)
                            } label: {
                                Text(variant.variantLabel)
                                    .font(.system(size: 8, weight: variant.id == frame.id ? .semibold : .regular))
                                    .foregroundStyle(variant.id == frame.id ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(variant.id == frame.id
                                                               ? AnyShapeStyle(AuroraTheme.accent)
                                                               : AnyShapeStyle(Color.primary.opacity(0.07))))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text(T("系统读不到机身配色，点一下选中你机器的款式"))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(frames.isDefaultAuto
                         ? T("按本机型号与屏幕分辨率自动识别")
                         : T("已手动指定，截图时会优先用这一款"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !frames.isDefaultAuto {
                    Button {
                        frames.preferredFrameID = nil
                    } label: {
                        Text(T("恢复自动识别"))
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(AuroraTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(AuroraTheme.accent.opacity(0.08))
        }
    }

    private func frameCard(_ frame: DeviceFrame) -> some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumb = frames.thumbnail(frame) {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 56)
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.06))
                            .frame(height: 56)
                    }
                }
                .opacity(frames.needsDownload(frame) ? 0.55 : 1)

                if frames.isDownloading(frame) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(4)
                } else if frames.needsDownload(frame) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(3)
                }
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

            Button {
                choose(frame)
            } label: {
                Text(frames.needsDownload(frame) ? T("下载") : T("设为默认"))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(AuroraTheme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(AuroraTheme.accent.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .disabled(frames.isDownloading(frame))
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
    }

}
