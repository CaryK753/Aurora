//  WallpaperComponents.swift
//  Aurora — 壁纸卡片 / 详情面板 / 片段裁剪

import SwiftUI

struct WallpaperCardView: View {
    let item: WallpaperItem
    let thumb: NSImage?
    let isActive: Bool
    let isSystem: Bool
    var onPreview: () -> Void
    var onUse: () -> Void
    var onInfo: () -> Void
    var onDelete: (() -> Void)?
    var onAdopt: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            artwork
            labels
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onUse() }
        .help(T("双击设为壁纸"))
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.black.opacity(0.35))

            if item.kind == .procedural {
                ProceduralStaticPreview(style: item.style ?? "aurora", hueShift: item.hue ?? 0)
            } else if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
            }

            LinearGradient(
                colors: [.clear, .black.opacity(hovering ? 0.45 : 0.28)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack {
                HStack(alignment: .top) {
                    kindBadge
                    Spacer(minLength: 0)
                    if isActive { activeBadge }
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    if hovering { actions }
                }
            }
            .padding(6)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    isActive ? AuroraTheme.accent.opacity(0.9) : Color.white.opacity(hovering ? 0.30 : 0.12),
                    lineWidth: isActive ? 1.4 : 0.7
                )
        }
        .scaleEffect(hovering ? 1.028 : 1)
        .shadow(color: .black.opacity(hovering ? 0.30 : 0.12), radius: hovering ? 10 : 4, x: 0, y: hovering ? 5 : 2)
        .animation(.spring(duration: 0.3, bounce: 0.32), value: hovering)
        .animation(.smooth(duration: 0.25), value: isActive)
    }

    private var kindBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: item.kind.symbol).font(.system(size: 7, weight: .bold))
            if item.kind.isMotion, item.trimEnd > item.trimStart + 0.1 {
                Image(systemName: "scissors").font(.system(size: 6.5, weight: .bold))
            }
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 4.5)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(.black.opacity(0.35)))
    }

    private var activeBadge: some View {
        Text(T("当前"))
            .font(.system(size: 7.5, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(AuroraTheme.accent))
    }

    private var actions: some View {
        HStack(spacing: 4) {
            actionButton("play.fill", help: T("全屏预览")) { onPreview() }
            if let onAdopt {
                actionButton("plus", help: T("加入壁纸库")) { onAdopt() }
            } else {
                actionButton("checkmark", help: T("设为壁纸")) { onUse() }
            }
            actionButton("info.circle", help: T("详情")) { onInfo() }
            if let onDelete {
                actionButton("trash", help: T("移除")) { onDelete() }
            }
        }
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    private func actionButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(.black.opacity(0.42)))
                .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text(item.subtitle)
                .font(.system(size: 8))
                .lineLimit(1)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 1)
    }
}

// MARK: - 详情 / 片段裁剪

struct WallpaperDetailSheet: View {
    let item: WallpaperItem
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var service: WallpaperService
    @ObservedObject var state: AppState
    var onPreview: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var duration: Double = 0
    @State private var loaded = false
    @State private var name = ""
    @State private var hue: Double?

    private var editable: Bool { !item.isSystem }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            preview

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    IconBadge(symbol: item.kind.symbol, color: AuroraTheme.accent, size: 22, style: .tinted)
                    TextField("", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .disabled(!editable)
                    Spacer(minLength: 0)
                    Text(item.kind.title)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                Text(item.isSystem
                     ? T("Apple 自带壁纸 · 加入壁纸库后可裁剪片段")
                     : (item.kind == .procedural ? T("程序生成的动态场景 · 不占磁盘空间，可以自定义配色") : item.byteText))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            if item.kind == .video, editable {
                trimEditor
            }

            if item.kind == .procedural {
                hueEditor
            }

            HStack(spacing: 8) {
                Button(T("全屏预览")) { onPreview() }
                    .buttonStyle(SoftButtonStyle())
                Spacer()
                if editable {
                    Button(T("移除")) {
                        library.remove(item)
                        dismiss()
                    }
                    .buttonStyle(SoftButtonStyle())
                }
                Button(T("设为壁纸")) {
                    service.useAsWallpaper(item)
                    state.showToast(TF("已设为壁纸 · %@", item.name), symbol: "checkmark.circle.fill")
                    dismiss()
                }
                .buttonStyle(SoftButtonStyle(prominent: true))
            }
        }
        .padding(18)
        .frame(width: 420)
        .overlay(alignment: .topTrailing) {
            // 详情页必须能自己退出：之前没有关闭按钮，Esc 会穿透到主面板整窗隐藏
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .padding(8)
            .help(T("关闭"))
        }
        .onExitCommand { dismiss() }
        .onAppear {
            name = item.name
            guard !loaded else { return }
            loaded = true
            if item.kind == .video {
                duration = WallpaperLibrary.videoDuration(url: item.url)
                trimStart = item.trimStart
                trimEnd = item.trimEnd > 0 ? item.trimEnd : duration
            }
            if item.kind == .procedural {
                hue = item.hue ?? 0
            }
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.4))
            if item.kind == .procedural {
                ProceduralStaticPreview(style: item.style ?? "aurora", hueShift: hue ?? 0)
            } else if let thumb = library.thumbnails[item.id] {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(height: 176)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7)
        }
        .onAppear {
            guard item.kind != .procedural else { return }
            library.requestThumbnail(item, width: 720)
        }
    }

    /// 程序生成场景的配色自定义：色相偏移实时反映在预览里
    private var hueEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionLabel(text: T("配色"), symbol: "paintpalette")
                Spacer()
                Text(T("拖动改变整体色调，预览实时更新"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                Slider(value: Binding(
                    get: { hue ?? 0 },
                    set: { hue = $0 }
                ), in: -180...180)
                .controlSize(.mini)

                Button(T("恢复默认")) { hue = 0 }
                    .buttonStyle(.plain)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)

                Button(T("应用")) {
                    if let updated = library.setHue(item, hue: (hue ?? 0) == 0 ? nil : hue) {
                        if service.current.values.contains(item.id) {
                            service.apply(reason: "hue", force: true)
                        }
                        state.showToast(TF("配色已更新 · %@", updated.name), symbol: "paintpalette")
                    }
                }
                .buttonStyle(SoftButtonStyle(prominent: true))
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }

    private var trimEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionLabel(text: T("播放片段"), symbol: "scissors")
                Spacer()
                Text(TF("%@ → %@ · 共 %@",
                        timeText(trimStart),
                        timeText(trimEnd),
                        timeText(max(0, trimEnd - trimStart))))
                    .font(.system(size: 8.5, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            VStack(spacing: 4) {
                slider(title: T("起点"), value: $trimStart, range: 0...max(0.2, duration))
                slider(title: T("终点"), value: $trimEnd, range: 0...max(0.2, duration))
            }

            HStack(spacing: 8) {
                Text(T("拖动滑块掐头去尾，循环播放时只走这一段"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(T("恢复完整")) {
                    trimStart = 0
                    trimEnd = duration
                }
                .buttonStyle(.plain)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.secondary)
                Button(T("应用")) {
                    let start = min(trimStart, max(0, trimEnd - 0.3))
                    let end = trimEnd >= duration - 0.05 ? 0 : trimEnd
                    library.setTrim(item, start: start, end: end)
                    if service.current.values.contains(item.id) {
                        service.apply(reason: "trim", force: true)
                    }
                    state.showToast(T("片段已更新"), symbol: "scissors")
                }
                .buttonStyle(SoftButtonStyle(prominent: true))
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }

    private func slider(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.mini)
            Text(timeText(value.wrappedValue))
                .font(.system(size: 8.5, design: .rounded))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func timeText(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
