//  ScreenshotEditor.swift
//  Aurora — 截图编辑器：画笔 / 箭头 / 矩形 / 椭圆 / 文字 / 马赛克，
//  复制 / 保存 / 带壳截图（Apple 官方外壳，按设备自动推荐）。
//
//  渲染全部走 SwiftUI Canvas（含像素化马赛克），导出用 ImageRenderer 按
//  原图像素密度重绘，所见即所得。

import AppKit
import SwiftUI

// MARK: - 窗口

final class EditorWindow: NSWindow {
    init(image: CGImage) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW = screen.width * 0.82
        let maxH = (screen.height - 120) * 0.92
        let scale = min(maxW / CGFloat(image.width), maxH / CGFloat(image.height), 1)
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        title = T("截图")
        titlebarAppearsTransparent = true
        // 液态玻璃底：窗口透明，NSGlassEffectView 垫在内容后面（与主面板同款）
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        center()

        let bounds = NSRect(origin: .zero, size: size)
        let glass = NSGlassEffectView(frame: bounds)
        glass.cornerRadius = 0
        glass.tintColor = NSColor.white.withAlphaComponent(0.03)
        glass.autoresizingMask = [.width, .height]

        let hosting = TransparentHostingView(rootView: ScreenshotEditorView(image: image, window: self))
        hosting.safeAreaRegions = []
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]

        let container = NSView(frame: bounds)
        container.autoresizingMask = [.width, .height]
        container.addSubview(glass)
        container.addSubview(hosting, positioned: .above, relativeTo: glass)
        contentView = container
    }
}

// MARK: - 数据

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, pen, line, arrow, rect, filledRect, ellipse, highlighter, blur, mosaic, spotlight, counter, text
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil.tip"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .filledRect: return "rectangle.fill"
        case .ellipse: return "circle"
        case .highlighter: return "highlighter"
        case .blur: return "blur"
        case .mosaic: return "squareshape.split.3x3"
        case .spotlight: return "circle.lefthalf.filled"
        case .counter: return "1.circle"
        case .text: return "textformat"
        }
    }

    var title: String {
        switch self {
        case .select: return T("选择 / 移动")
        case .pen: return T("画笔")
        case .line: return T("直线")
        case .arrow: return T("箭头")
        case .rect: return T("矩形")
        case .filledRect: return T("实心矩形")
        case .ellipse: return T("椭圆")
        case .highlighter: return T("荧光笔")
        case .blur: return T("模糊")
        case .mosaic: return T("马赛克")
        case .spotlight: return T("聚光灯")
        case .counter: return T("步骤序号")
        case .text: return T("文字")
        }
    }

    /// 需要按住拖拽来绘制的工具（其余是点击放置或选择）
    var isDrawingTool: Bool {
        switch self {
        case .select, .text, .counter: return false
        default: return true
        }
    }
}

enum Annotation: Identifiable {
    case stroke(Stroke)
    case text(TextItem)

    var id: UUID {
        switch self {
        case .stroke(let s): return s.id
        case .text(let t): return t.id
        }
    }
}

struct Stroke: Identifiable {
    let id = UUID()
    var kind: AnnotationTool      // pen / line / arrow / rect / ... / mosaic
    var points: [CGPoint]         // 归一化（0-1）
    var color: Color
    var width: CGFloat
    /// counter 工具：序号
    var number: Int = 0
}

struct TextItem: Identifiable {
    let id = UUID()
    var point: CGPoint            // 归一化
    var content: String
    var color: Color
}

// MARK: - 编辑器视图

struct ScreenshotEditorView: View {
    let image: CGImage
    private weak var window: NSWindow?

    @State private var annotations: [Annotation] = []
    /// 快照式撤销 / 重做：移动、删除也能撤销
    @State private var undoStack: [[Annotation]] = []
    @State private var redoStack: [[Annotation]] = []
    @State private var tool: AnnotationTool = .select
    @State private var color: Color = .red
    @State private var strokeWidth: CGFloat = 4
    @State private var pendingTextPoint: CGPoint?
    @State private var draftText = ""
    @State private var showFramePicker = false
    @State private var showContinuity = false
    /// 正在绘制的草稿（AppKit 鼠标跟踪回传，画布实时渲染）
    @State private var draft: Annotation?
    /// 选择模式下当前选中的标注
    @State private var selectedID: UUID?
    /// 马赛克底图只生成一次：放在 body 计算路径里会每帧全图重采样，笔画掉点卡顿
    @State private var pixelated: CGImage?
    /// 高斯模糊底图（首次用到模糊工具时生成）
    @State private var blurred: CGImage?

    init(image: CGImage, window: NSWindow) {
        self.image = image
        self.window = window
        _pixelated = State(initialValue: Self.pixelate(image, factor: 14))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.4)
            canvasArea
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(Color.clear)
        // ⌘Z / ⇧⌘Z 撤销重做（隐藏按钮承载快捷键）
        .background {
            Button { undo() } label: { EmptyView() }
                .keyboardShortcut("z", modifiers: .command)
            Button { redo() } label: { EmptyView() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .onExitCommand { window?.close() }
    }

    // MARK: 画布

    private var aspectRatio: CGFloat { CGFloat(image.width) / CGFloat(image.height) }

    private var canvasArea: some View {
        ZStack {
            EditorCanvasView(
                image: image,
                pixelated: pixelated,
                blurred: blurred,
                annotations: annotations,
                draft: draft,
                selectedID: tool == .select ? selectedID : nil
            )
            // 鼠标交互走 AppKit 原生跟踪：SwiftUI DragGesture 在非激活窗口
            // 上会"点击即定格、拖动不跟踪"，画笔形状全都画不连续
            CanvasMouseView(
                tool: tool,
                color: color,
                strokeWidth: strokeWidth,
                annotations: annotations,
                draft: draft,
                onDraft: { draft = $0 },
                onCommit: { annotation in
                    pushHistory()
                    annotations.append(annotation)
                },
                onMoveStart: { pushHistory() },
                onMove: { id, delta in moveAnnotation(id: id, delta: delta) },
                onSelect: { selectedID = $0 },
                onTap: { point in
                    if tool == .counter {
                        // 步骤序号：点击即放置，编号自动递增
                        let next = annotations.reduce(0) { count, item in
                            if case .stroke(let stroke) = item, stroke.kind == .counter { return count + 1 }
                            return count
                        } + 1
                        pushHistory()
                        annotations.append(.stroke(Stroke(
                            kind: .counter, points: [point], color: color, width: strokeWidth, number: next
                        )))
                    } else {
                        pendingTextPoint = point
                        draftText = ""
                    }
                }
            )
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
        .overlay(alignment: .top) {
            if let point = pendingTextPoint {
                textEditor(at: point)
            }
        }
        .background {
            // ⌫ 删除选中的标注（选择模式下）
            Button { deleteSelected() } label: { EmptyView() }
                .keyboardShortcut(.delete, modifiers: [])
                .keyboardShortcut(.deleteForward, modifiers: [])
        }
    }

    private func textEditor(at point: CGPoint) -> some View {
        HStack(spacing: 6) {
            TextField(T("输入文字，回车确认"), text: $draftText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .onSubmit {
                    commitText(at: point)
                }
            Button(T("取消")) {
                pendingTextPoint = nil
            }
            .buttonStyle(SoftButtonStyle())
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThickMaterial)
                .shadow(radius: 8, y: 3)
        }
        .frame(maxWidth: 320)
        .offset(y: 24)
    }

    // MARK: 工具条

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(AnnotationTool.allCases) { candidate in
                    Button {
                        tool = candidate
                        if candidate == .blur { ensureBlurred() }
                    } label: {
                        Image(systemName: candidate.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tool == candidate ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary))
                            .frame(width: 26, height: 26)
                            .background {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(tool == candidate ? AnyShapeStyle(AuroraTheme.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.05)))
                            }
                    }
                    .buttonStyle(.plain)
                    .help(candidate.title)
                }

            Divider().frame(height: 18)

            // 颜色
            HStack(spacing: 4) {
                ForEach([Color.red, Color.yellow, Color.green, Color.blue, Color.white, Color.black], id: \.self) { candidate in
                    Circle()
                        .fill(candidate)
                        .frame(width: 14, height: 14)
                        .overlay {
                            Circle().strokeBorder(
                                color == candidate ? AuroraTheme.accent : Color.primary.opacity(0.2),
                                lineWidth: color == candidate ? 2 : 0.7
                            )
                        }
                        .contentShape(Circle())
                        .onTapGesture { color = candidate }
                }
            }

            Divider().frame(height: 18)

            // 粗细
            Menu {
                ForEach([(2, T("细")), (4, T("中")), (7, T("粗"))], id: \.0) { value, label in
                    Button(label) { strokeWidth = CGFloat(value) }
                }
            } label: {
                Image(systemName: "circle.circle")
                    .font(.system(size: 10 + strokeWidth * 0.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Divider().frame(height: 18)

            Button {
                undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(annotations.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.secondary))
            }
            .buttonStyle(.plain)
            .disabled(annotations.isEmpty)
            .help(T("撤销"))

            Button {
                redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(redoStack.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.secondary))
            }
            .buttonStyle(.plain)
            .disabled(redoStack.isEmpty)
            .help(T("重做"))

            Spacer(minLength: 6)

            // 连续互通：发到 iPhone / iPad 上标注
            Button {
                showContinuity = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: 10, weight: .semibold))
                    Text(T("连续互通"))
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showContinuity, arrowEdge: .bottom) {
                continuityPicker
            }

            // 带壳
            Button {
                showFramePicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "iphone.gen3.landscape")
                        .font(.system(size: 10, weight: .semibold))
                    Text(T("带壳"))
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showFramePicker, arrowEdge: .bottom) {
                framePicker
            }

            Button {
                save()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 10, weight: .semibold))
                    Text(T("保存"))
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)

            Button {
                copyToPasteboard()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                    Text(T("复制"))
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(AuroraTheme.accentGradient))
            }
            .buttonStyle(.plain)
            }
        }
        // 透明标题栏里有系统红绿灯，工具条往右、往下让开；工具多时可横向滚动
        .padding(.leading, 78)
        .padding(.trailing, 12)
        .padding(.top, 26)
        .padding(.bottom, 6)
        .frame(minWidth: 640)
    }

    // MARK: 连续互通

    private var continuityPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                SectionLabel(text: T("连续互通"), symbol: "iphone.and.arrow.forward")
                Spacer()
            }

            Button {
                airdropForMarkup()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AuroraTheme.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("发送到附近的 iPhone / iPad"))
                            .font(.system(size: 11, weight: .medium))
                        Text(T("隔空投送后，在设备上用「标记」标注"))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.035)))
            }
            .buttonStyle(.plain)

            Button {
                retrieveFromPasteboard()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AuroraTheme.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("取回标注结果"))
                            .font(.system(size: 11, weight: .medium))
                        Text(T("在 iPhone 上标注并复制后，点这里取回（通用剪贴板）"))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.035)))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 300)
    }

    /// 隔空投送 PNG 给附近设备做标注
    private func airdropForMarkup() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Aurora Markup \(Int(Date().timeIntervalSince1970)).png")
        guard let composed = renderComposed(),
              let tiff = composed.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: url)
        } catch { return }
        guard let service = NSSharingService(named: .sendViaAirDrop) else { return }
        service.perform(withItems: [url])
    }

    /// 通用剪贴板：iPhone 上「标记」完拷贝，这里取回继续编辑
    private func retrieveFromPasteboard() {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        window?.close()
        ScreenshotSession.shared.presentEditor(image: cg)
    }

    // MARK: 外壳选择

    private var framePicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                SectionLabel(text: T("设备外壳"), symbol: "iphone.gen3")
                Spacer()
                Text(T("Apple 官方 Product Bezels"))
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }

            let frames = ScreenshotService.shared.frames
            if frames.isEmpty {
                Text(T("没有可用的外壳资源"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        if let suggested = suggestFrame() {
                            frameRow(suggested, badge: T("自动识别"))
                        }
                        ForEach(frames.filter { $0.id != suggestFrame()?.id }) { frame in
                            frameRow(frame, badge: nil)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func suggestFrame() -> DeviceFrame? {
        ScreenshotService.shared.suggestFrame(for: CGSize(width: image.width, height: image.height))
    }

    private func frameRow(_ frame: DeviceFrame, badge: String?) -> some View {
        Button {
            applyFrame(frame)
            showFramePicker = false
        } label: {
            HStack(spacing: 8) {
                if let url = ScreenshotService.resourceURL(frame.id + ".png"),
                   let thumb = NSImage(contentsOf: url) {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 44, height: 34)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(frame.device)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundStyle(AuroraTheme.accent)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(AuroraTheme.accent.opacity(0.14)))
                        }
                    }
                    Text("\(frame.screen.width) × \(frame.screen.height)")
                        .font(.system(size: 8, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.035)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 动作

    /// 每次改动前压入当前快照；移动、删除同样可撤销
    private func pushHistory() {
        undoStack.append(annotations)
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack = []
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        selectedID = nil
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
    }

    private func moveAnnotation(id: UUID, delta: CGPoint) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        func shifted(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x + delta.x, 0), 1), y: min(max(p.y + delta.y, 0), 1))
        }
        switch annotations[index] {
        case .stroke(var stroke):
            stroke.points = stroke.points.map(shifted)
            annotations[index] = .stroke(stroke)
        case .text(var item):
            item.point = shifted(item.point)
            annotations[index] = .text(item)
        }
    }

    private func deleteSelected() {
        guard let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        pushHistory()
        annotations.remove(at: index)
        selectedID = nil
    }

    private func commitText(at point: CGPoint) {
        let content = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingTextPoint = nil
        guard !content.isEmpty else { return }
        pushHistory()
        annotations.append(.text(TextItem(point: point, content: content, color: color)))
    }

    /// 当前画布（底图 + 标注）渲染为原图分辨率
    private func renderComposed() -> NSImage? {
        let view = EditorCanvasView(
            image: image,
            pixelated: pixelated,
            blurred: blurred,
            annotations: annotations,
            draft: nil,
            selectedID: nil
        )
        let renderer = ImageRenderer(content: view.aspectRatio(aspectRatio, contentMode: .fit))
        renderer.scale = CGFloat(image.width) / max(1, 900)
        renderer.proposedSize = ProposedViewSize(width: 900, height: 900 / aspectRatio)
        return renderer.nsImage
    }

    private func copyToPasteboard() {
        guard let composed = renderComposed() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([composed])
        auroraDelegate?.state.showToast(T("已复制到剪贴板"), symbol: "checkmark.circle.fill")
    }

    private func save() {
        guard let composed = renderComposed() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        panel.nameFieldStringValue = "Aurora 截图 \(formatter.string(from: Date())).png"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let tiff = composed.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        auroraDelegate?.state.showToast(TF("已保存 · %@", url.lastPathComponent), symbol: "square.and.arrow.down.fill")
        NotificationService.shared.notifyScreenshotSaved(name: url.lastPathComponent)
    }

    private func applyFrame(_ frame: DeviceFrame) {
        guard let composed = renderComposed() else { return }
        guard let tiff = composed.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage,
              let framed = ScreenshotService.compose(image: cg, frame: frame) else { return }
        annotations = []
        undoStack = []
        redoStack = []
        selectedID = nil
        // 用带壳结果替换编辑内容
        window?.close()
        ScreenshotSession.shared.presentEditor(image: framed)
    }

    /// 首次使用模糊工具时生成高斯模糊底图（CIGaussianClamp，边缘不泛白）
    private func ensureBlurred() {
        guard blurred == nil, let blurredImage = Self.gaussianBlur(image, radius: 12) else { return }
        blurred = blurredImage
    }

    nonisolated private static func gaussianBlur(_ image: CGImage, radius: Double) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianClamp") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(output, from: ciImage.extent)
    }

    /// 简单盒式像素化：缩小再放大
    nonisolated private static func pixelate(_ image: CGImage, factor: Int) -> CGImage? {
        let smallW = max(1, image.width / factor)
        let smallH = max(1, image.height / factor)
        guard let small = CGContext(
            data: nil, width: smallW, height: smallH, bitsPerComponent: 8,
            bytesPerRow: smallW * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        small.interpolationQuality = .low
        small.draw(image, in: CGRect(x: 0, y: 0, width: smallW, height: smallH))
        guard let smallImage = small.makeImage() else { return nil }
        guard let big = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        big.interpolationQuality = .none
        big.draw(smallImage, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return big.makeImage()
    }
}

// MARK: - 画布

struct EditorCanvasView: View {
    let image: CGImage
    let pixelated: CGImage?
    let blurred: CGImage?
    let annotations: [Annotation]
    /// 正在绘制的草稿（交互画布传入，导出传 nil）
    var draft: Annotation? = nil
    /// 选择模式下高亮的标注（导出传 nil）
    var selectedID: UUID? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Canvas { context, size in
                    let base = Image(nsImage: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)))
                    context.draw(base, in: CGRect(origin: .zero, size: size))

                    if let pixelated {
                        let pixelImage = Image(nsImage: NSImage(cgImage: pixelated, size: CGSize(width: image.width, height: image.height)))
                        for case .stroke(let stroke) in annotations where stroke.kind == .mosaic {
                            // pixelated 已是最近邻放大的块状图，直接盖在描边区域内
                            var scoped = context
                            scoped.clip(to: mosaicPath(stroke, in: size))
                            scoped.draw(pixelImage, in: CGRect(origin: .zero, size: size))
                        }
                        if case .stroke(let stroke)? = draft, stroke.kind == .mosaic {
                            var scoped = context
                            scoped.clip(to: mosaicPath(stroke, in: size))
                            scoped.draw(pixelImage, in: CGRect(origin: .zero, size: size))
                        }
                    }

                    if let blurred {
                        let blurImage = Image(nsImage: NSImage(cgImage: blurred, size: CGSize(width: image.width, height: image.height)))
                        for case .stroke(let stroke) in annotations where stroke.kind == .blur {
                            var scoped = context
                            scoped.clip(to: regionPath(stroke, in: size))
                            scoped.draw(blurImage, in: CGRect(origin: .zero, size: size))
                        }
                        if case .stroke(let stroke)? = draft, stroke.kind == .blur {
                            var scoped = context
                            scoped.clip(to: regionPath(stroke, in: size))
                            scoped.draw(blurImage, in: CGRect(origin: .zero, size: size))
                        }
                    }

                    for annotation in annotations {
                        draw(annotation, in: &context, size: size)
                    }
                    if let draft {
                        draw(draft, in: &context, size: size)
                    }

                    // 选中态：虚线包围盒
                    if let selectedID,
                       let annotation = annotations.first(where: { $0.id == selectedID }),
                       let bounds = annotationBounds(annotation, in: size) {
                        context.stroke(
                            Path(roundedRect: bounds.insetBy(dx: -6, dy: -6), cornerRadius: 4),
                            with: .color(AuroraTheme.accent),
                            style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])
                        )
                    }
                }
            }
            .clipShape(Rectangle())
            .overlay {
                Rectangle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.7)
            }
        }
        .aspectRatio(CGFloat(image.width) / CGFloat(image.height), contentMode: .fit)
    }

    private func normalize(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x / max(size.width, 1), 0), 1),
                y: min(max(point.y / max(size.height, 1), 0), 1))
    }

    /// 标注在画布上的包围盒（归一化坐标 × size）
    private func annotationBounds(_ annotation: Annotation, in size: CGSize) -> CGRect? {
        func box(of points: [CGPoint]) -> CGRect? {
            guard let first = points.first else { return nil }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            return CGRect(x: minX * size.width, y: minY * size.height,
                          width: (maxX - minX) * size.width, height: (maxY - minY) * size.height)
        }
        switch annotation {
        case .stroke(let stroke):
            return box(of: stroke.points)
        case .text(let item):
            let origin = item.point
            let width = CGFloat(max(item.content.count, 1)) * 9.2 / size.width
            return CGRect(x: origin.x * size.width, y: origin.y * size.height,
                          width: width * size.width, height: 22)
        }
    }

    private func draw(_ annotation: Annotation, in context: inout GraphicsContext, size: CGSize) {
        switch annotation {
        case .stroke(let stroke):
            switch stroke.kind {
            case .select:
                break // 选择工具本身不产生笔画
            case .mosaic:
                break // 已在像素化阶段画过
            case .pen:
                guard stroke.points.count > 1 else { return }
                var path = Path()
                path.move(to: CGPoint(x: stroke.points[0].x * size.width, y: stroke.points[0].y * size.height))
                for point in stroke.points.dropFirst() {
                    path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                }
                context.stroke(path, with: .color(stroke.color), style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round))
            case .line:
                guard stroke.points.count > 1 else { return }
                let from = CGPoint(x: stroke.points[0].x * size.width, y: stroke.points[0].y * size.height)
                let to = CGPoint(x: stroke.points[1].x * size.width, y: stroke.points[1].y * size.height)
                var line = Path()
                line.move(to: from)
                line.addLine(to: to)
                context.stroke(line, with: .color(stroke.color), style: StrokeStyle(lineWidth: stroke.width, lineCap: .round))
            case .arrow:
                guard stroke.points.count > 1 else { return }
                let from = CGPoint(x: stroke.points[0].x * size.width, y: stroke.points[0].y * size.height)
                let to = CGPoint(x: stroke.points[1].x * size.width, y: stroke.points[1].y * size.height)
                var line = Path()
                line.move(to: from)
                line.addLine(to: to)
                context.stroke(line, with: .color(stroke.color), style: StrokeStyle(lineWidth: stroke.width, lineCap: .round))

                // 箭头头部
                let angle = atan2(to.y - from.y, to.x - from.x)
                let head = stroke.width * 3.4
                var arrow = Path()
                arrow.move(to: to)
                arrow.addLine(to: CGPoint(
                    x: to.x - head * cos(angle - 0.44),
                    y: to.y - head * sin(angle - 0.44)
                ))
                arrow.move(to: to)
                arrow.addLine(to: CGPoint(
                    x: to.x - head * cos(angle + 0.44),
                    y: to.y - head * sin(angle + 0.44)
                ))
                context.stroke(arrow, with: .color(stroke.color), style: StrokeStyle(lineWidth: stroke.width, lineCap: .round))
            case .rect:
                guard stroke.points.count > 1 else { return }
                let rect = regionRect(stroke, in: size)
                context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(stroke.color), lineWidth: stroke.width)
            case .filledRect:
                guard stroke.points.count > 1 else { return }
                let rect = regionRect(stroke, in: size)
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(stroke.color))
            case .ellipse:
                guard stroke.points.count > 1 else { return }
                let rect = regionRect(stroke, in: size)
                context.stroke(Path(ellipseIn: rect), with: .color(stroke.color), lineWidth: stroke.width)
            case .highlighter:
                // 荧光笔：粗、半透明，压在内容上像马克笔
                guard stroke.points.count > 1 else { return }
                var path = Path()
                path.move(to: CGPoint(x: stroke.points[0].x * size.width, y: stroke.points[0].y * size.height))
                for point in stroke.points.dropFirst() {
                    path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                }
                context.stroke(
                    path,
                    with: .color(stroke.color.opacity(0.4)),
                    style: StrokeStyle(lineWidth: stroke.width * 3.2, lineCap: .round, lineJoin: .round)
                )
            case .blur:
                break // 已在模糊底图阶段画过
            case .spotlight:
                // 聚光灯：整图压暗，只留选中区域透亮（destinationOut 在图层上开洞）
                guard stroke.points.count > 1 else { return }
                let rect = regionRect(stroke, in: size)
                context.drawLayer { layer in
                    layer.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
                    layer.blendMode = .destinationOut
                    layer.fill(Path(ellipseIn: rect.insetBy(dx: -6, dy: -6)), with: .color(.black))
                }
            case .counter:
                guard let point = stroke.points.first else { return }
                let center = CGPoint(x: point.x * size.width, y: point.y * size.height)
                let radius: CGFloat = 14 + stroke.width
                let circle = Path(ellipseIn: CGRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2
                ))
                context.fill(circle, with: .color(stroke.color))
                context.stroke(circle, with: .color(.white), lineWidth: 2)
                context.draw(
                    Text(String(stroke.number))
                        .font(.system(size: radius * 1.15, weight: .bold, design: .rounded))
                        .foregroundColor(.white),
                    at: center
                )
            case .text:
                break
            }
        case .text(let item):
            context.draw(
                Text(item.content)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(item.color),
                at: CGPoint(x: item.point.x * size.width, y: item.point.y * size.height)
            )
        }
    }

    /// 两点工具（矩形 / 模糊 / 聚光灯）的矩形区域
    private func regionRect(_ stroke: Stroke, in size: CGSize) -> CGRect {
        let a = CGPoint(x: stroke.points[0].x * size.width, y: stroke.points[0].y * size.height)
        let b = CGPoint(x: stroke.points[1].x * size.width, y: stroke.points[1].y * size.height)
        return CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(b.x - a.x), height: abs(b.y - a.y)
        )
    }

    private func regionPath(_ stroke: Stroke, in size: CGSize) -> Path {
        Path(roundedRect: regionRect(stroke, in: size), cornerRadius: 4)
    }

    private func mosaicPath(_ stroke: Stroke, in size: CGSize) -> Path {
        var path = Path()
        let radius = max(stroke.width * 2.4, 16)
        for (index, point) in stroke.points.enumerated() {
            let center = CGPoint(x: point.x * size.width, y: point.y * size.height)
            path.addEllipse(in: CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            ))
            if index > 0 {
                let previous = CGPoint(x: stroke.points[index - 1].x * size.width, y: stroke.points[index - 1].y * size.height)
                var connector = Path()
                connector.move(to: previous)
                connector.addLine(to: center)
                path = path.union(connector.strokedPath(StrokeStyle(lineWidth: radius * 2, lineCap: .round)))
            }
        }
        return path
    }
}

extension Path {
    /// 手写 union：SwiftUI Path 没有 union，用两段叠加实现（clip 场景足够）
    func union(_ other: Path) -> Path {
        var result = self
        result.addPath(other)
        return result
    }
}

// MARK: - 鼠标交互（AppKit 原生跟踪）

/// 覆盖在画布上的透明交互层。SwiftUI 的 DragGesture 在非激活窗口上
/// 会"点击即定格、拖动不跟踪"，这里用 AppKit 的 mouseDown/Dragged/Up
/// 完整跟踪：绘制工具连续出稿，选择工具支持点选与拖拽移动标注。
struct CanvasMouseView: NSViewRepresentable {
    let tool: AnnotationTool
    let color: Color
    let strokeWidth: CGFloat
    let annotations: [Annotation]
    var draft: Annotation?
    var onDraft: (Annotation?) -> Void
    var onCommit: (Annotation) -> Void
    var onMoveStart: () -> Void
    var onMove: (UUID, CGPoint) -> Void
    var onSelect: (UUID?) -> Void
    var onTap: (CGPoint) -> Void

    func makeNSView(context: Context) -> CanvasMouseNSView {
        let view = CanvasMouseNSView()
        view.representable = self
        return view
    }

    func updateNSView(_ view: CanvasMouseNSView, context: Context) {
        view.representable = self
    }
}

final class CanvasMouseNSView: NSView {
    var representable: CanvasMouseView?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private enum DragState {
        case drawing
        case moving(id: UUID, last: CGPoint)
    }
    private var drag: DragState?
    private var downLocation: CGPoint?
    /// 手绘类工具的累计点列（归一化）
    private var livePoints: [CGPoint] = []

    // 归一化坐标与 SwiftUI 一致：左上原点
    private func norm(_ location: CGPoint) -> CGPoint {
        CGPoint(x: min(max(location.x / max(bounds.width, 1), 0), 1),
                y: min(max((bounds.height - location.y) / max(bounds.height, 1), 0), 1))
    }
    /// 归一化 → 视图坐标（左下原点），用于命中测试
    private func viewPoint(_ normalized: CGPoint) -> CGPoint {
        CGPoint(x: normalized.x * bounds.width, y: (1 - normalized.y) * bounds.height)
    }

    override func resetCursorRects() {
        let tool = representable?.tool ?? .select
        addCursorRect(bounds, cursor: tool.isDrawingTool ? .crosshair : .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        guard let rep = representable else { return }
        let p = convert(event.locationInWindow, from: nil)
        downLocation = p
        let n = norm(p)
        switch rep.tool {
        case .select:
            if let hit = hitTestAnnotation(at: n) {
                rep.onSelect(hit)
                drag = .moving(id: hit, last: n)
                rep.onMoveStart()
            } else {
                rep.onSelect(nil)
                drag = nil
            }
        case .text, .counter:
            drag = nil // 等 mouseUp 判定是不是一次点击
        default:
            livePoints = [n]
            drag = .drawing
            rep.onDraft(.stroke(Stroke(
                kind: rep.tool, points: livePoints, color: rep.color, width: rep.strokeWidth
            )))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let rep = representable else { return }
        let p = convert(event.locationInWindow, from: nil)
        let n = norm(p)
        switch drag {
        case .drawing:
            switch rep.tool {
            case .pen, .highlighter, .mosaic, .blur, .spotlight:
                // 手绘：原地微抖不加点，笔画才顺滑
                if let last = livePoints.last, hypot(n.x - last.x, n.y - last.y) < 0.0015 { return }
                livePoints.append(n)
            default:
                // 直线 / 箭头 / 矩形 / 椭圆：始终是 [起点, 当前点]
                livePoints = [livePoints[0], n]
            }
            rep.onDraft(.stroke(Stroke(
                kind: rep.tool, points: livePoints, color: rep.color, width: rep.strokeWidth
            )))
        case .moving(let id, let last):
            rep.onMove(id, CGPoint(x: n.x - last.x, y: n.y - last.y))
            drag = .moving(id: id, last: n)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let rep = representable else { return }
        let p = convert(event.locationInWindow, from: nil)
        let n = norm(p)
        defer {
            drag = nil
            downLocation = nil
            livePoints = []
        }
        switch drag {
        case .drawing:
            let points = livePoints
            rep.onDraft(nil)
            // 手绘至少两点，形状两点成一线；单击不成形
            guard points.count > 1 else { return }
            rep.onCommit(.stroke(Stroke(
                kind: rep.tool, points: points, color: rep.color, width: rep.strokeWidth
            )))
        case .moving:
            break
        case nil:
            // 点击（文字 / 步骤序号落点）
            if let down = downLocation, rep.tool == .text || rep.tool == .counter, hypot(p.x - down.x, p.y - down.y) < 4 {
                rep.onTap(n)
            }
        }
    }

    // MARK: 命中测试

    private func hitTestAnnotation(at n: CGPoint) -> UUID? {
        guard let rep = representable else { return nil }
        let p = viewPoint(n)
        // 从最上层往下找
        for annotation in rep.annotations.reversed() {
            switch annotation {
            case .stroke(let stroke):
                if hitStroke(stroke, at: p) { return stroke.id }
            case .text(let item):
                let origin = viewPoint(item.point)
                let width = CGFloat(max(item.content.count, 1)) * 9.2
                // 文字从落点向下渲染（视图坐标里向上为正）
                let rect = CGRect(x: origin.x - 4, y: origin.y - 26, width: width + 10, height: 30)
                if rect.contains(p) { return item.id }
            }
        }
        return nil
    }

    private func hitStroke(_ stroke: Stroke, at p: CGPoint) -> Bool {
        let points = stroke.points.map { viewPoint($0) }
        guard let first = points.first else { return false }
        switch stroke.kind {
        case .counter:
            let center = first
            let radius = 14 + stroke.width + 5
            return hypot(p.x - center.x, p.y - center.y) <= radius
        case .rect, .filledRect, .ellipse, .spotlight:
            guard points.count > 1 else { return false }
            let a = points[0], b = points[1]
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                              width: abs(b.x - a.x), height: abs(b.y - a.y))
            return rect.insetBy(dx: -8, dy: -8).contains(p)
        default:
            // 画笔 / 荧光笔 / 直线 / 箭头 / 马赛克 / 模糊：包围盒外扩命中
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .insetBy(dx: -9, dy: -9).contains(p)
        }
    }
}
