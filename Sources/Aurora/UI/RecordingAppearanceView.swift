import SwiftUI
import UniformTypeIdentifiers

struct RecordingAppearanceView: View {
    @Binding var appearance: RecordingAppearance
    let hasTrace: Bool
    let embeddedCursor: Bool
    @ObservedObject private var screenshots = ScreenshotService.shared

    var body: some View {
        Form {
            Section(T("背景")) {
                HStack {
                    Button(T("无")) {
                        appearance.backdrop = nil
                        appearance.solidBackdrop = false
                    }
                    Button(T("深蓝底色")) {
                        appearance.backdrop = nil
                        appearance.solidBackdrop = true
                    }
                    Button(T("选择图片或视频…")) { selectBackground() }
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
                    Text(frame.device).tag(Optional(frame.id))
                }
            }
            Section(T("光标")) {
                Picker(T("光标样式"), selection: $appearance.cursor) {
                    Text(T("无")).tag(RecordingAppearance.Cursor.none)
                    Text(T("箭头")).tag(RecordingAppearance.Cursor.arrow)
                    Text(T("圆点")).tag(RecordingAppearance.Cursor.dot)
                    Text(T("圆环")).tag(RecordingAppearance.Cursor.ring)
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
                    Slider(value: $appearance.cursorSize, in: 0.5...2) { Text(T("光标大小")) }
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
        .frame(width: 380)
        .frame(maxHeight: 570)
    }

    private func selectBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appearance.solidBackdrop = false
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
