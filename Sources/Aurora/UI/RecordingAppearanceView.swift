import SwiftUI
import UniformTypeIdentifiers

struct RecordingAppearanceView: View {
    @Binding var appearance: RecordingAppearance
    let library: WallpaperLibrary
    let hasTrace: Bool
    let embeddedCursor: Bool
    @ObservedObject private var screenshots = ScreenshotService.shared

    var body: some View {
        Form {
            Section(T("背景")) {
                HStack {
                    Button(T("无")) {
                        appearance.wallpaper = nil
                        appearance.backdrop = nil
                        appearance.solidBackdrop = false
                    }
                    Button(T("深蓝底色")) {
                        appearance.wallpaper = nil
                        appearance.backdrop = nil
                        appearance.solidBackdrop = true
                    }
                }
                Button(T("选择图片或视频…")) { selectBackground() }
                RecordingWallpaperPicker(library: library, selection: appearance.wallpaper) { item in
                    appearance.backdrop = nil
                    appearance.solidBackdrop = false
                    appearance.wallpaper = item
                }
                if let file = appearance.backdrop {
                    Text(file.lastPathComponent)
                        .lineLimit(1)
                    Text(T("视频背景静音循环"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker(T("设备外壳"), selection: $appearance.frameID) {
                Text(T("无")).tag(nil as String?)
                if let id = appearance.frameID, !screenshots.frames.contains(where: { $0.id == id }) {
                    Text(T("外壳已移除")).tag(Optional(id))
                }
                ForEach(screenshots.frames) { frame in
                    Text(screenshots.needsDownload(frame)
                         ? "\(frame.device) · \(T("需下载"))"
                         : frame.device)
                        .tag(Optional(frame.id))
                }
            }
            // 远程外壳要等大图下完才导得出，选中的时候就下
            .onChange(of: appearance.frameID) { _, id in
                guard let id, let frame = screenshots.frames.first(where: { $0.id == id }) else { return }
                Task { await screenshots.ensureDownloaded(frame) }
            }
            Section(T("光标")) {
                Picker(T("光标样式"), selection: $appearance.cursor) {
                    Text(T("无")).tag(RecordingAppearance.Cursor.none)
                    Text(T("箭头")).tag(RecordingAppearance.Cursor.arrow)
                    Text(T("圆点")).tag(RecordingAppearance.Cursor.dot)
                    Text(T("圆环")).tag(RecordingAppearance.Cursor.ring)
                    Text(T("准星")).tag(RecordingAppearance.Cursor.crosshair)
                    Text(T("菱形")).tag(RecordingAppearance.Cursor.diamond)
                    Text(T("文本指针")).tag(RecordingAppearance.Cursor.beam)
                    if appearance.cursorImage != nil { Text(T("自定义 PNG")).tag(RecordingAppearance.Cursor.image) }
                }
                Button(T("导入光标 PNG…")) { selectCursor() }
                if appearance.cursor != .none {
                    if appearance.cursor != .image {
                        Picker(T("颜色"), selection: $appearance.cursorTint) {
                            Text(T("白色")).tag(RecordingAppearance.CursorTint.white)
                            Text(T("黑色")).tag(RecordingAppearance.CursorTint.black)
                            Text(T("蓝色")).tag(RecordingAppearance.CursorTint.blue)
                            Text(T("橙色")).tag(RecordingAppearance.CursorTint.orange)
                        }
                    }
                    Picker(T("光标特效"), selection: $appearance.cursorEffect) {
                        Text(T("无")).tag(nil as RecordingAppearance.CursorEffect?)
                        Text(T("点击波纹")).tag(Optional(RecordingAppearance.CursorEffect.ripple))
                        Text(T("移动拖尾")).tag(Optional(RecordingAppearance.CursorEffect.trail))
                    }
                    LabeledContent(T("光标大小"), value: appearance.cursorSize.formatted(.percent))
                    Slider(value: $appearance.cursorSize, in: 0.5...3, step: 0.05)
                        .accessibilityLabel(T("光标大小"))
                }
            }.disabled(!hasTrace)
            if !hasTrace {
                Text(T("录制时开启鼠标跟随缩放或后期编辑光标，即可使用此处设置。"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if embeddedCursor {
                Text(T("这段录像可能已有原始光标，新样式会叠加显示。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)

    }

    private func selectBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appearance.solidBackdrop = false
        appearance.wallpaper = nil
        appearance.backdrop = url
    }

    private func selectCursor() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appearance.cursorImage = url
        appearance.cursor = .image
    }
}
