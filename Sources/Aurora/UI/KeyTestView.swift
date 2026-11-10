//  KeyTestView.swift
//  Aurora — 按键测试：高亮物理按键，识别组合键
//
//  只在 Aurora 自己的窗口内监听（本地监视器），不需要辅助功能权限，
//  也不会看到其他 App 里的输入。

import AppKit
import Combine
import SwiftUI

// MARK: - 键位表

struct KeyCap: Identifiable {
    let id: String
    let code: UInt16
    let label: String
    var units: CGFloat = 1
    var fontSize: CGFloat = 9.5
}

enum KeyLayout {
    static let modifiers: Set<UInt16> = [59, 62, 58, 61, 56, 60, 55, 54, 63, 57]

    static let rows: [[KeyCap]] = [
        fRow, row1, row2, row3, row4, row5
    ]

    static let fRow: [KeyCap] = [
        KeyCap(id: "esc", code: 53, label: "esc", units: 1.3, fontSize: 8.5),
        KeyCap(id: "f1", code: 122, label: "F1", fontSize: 8),
        KeyCap(id: "f2", code: 120, label: "F2", fontSize: 8),
        KeyCap(id: "f3", code: 99, label: "F3", fontSize: 8),
        KeyCap(id: "f4", code: 118, label: "F4", fontSize: 8),
        KeyCap(id: "f5", code: 96, label: "F5", fontSize: 8),
        KeyCap(id: "f6", code: 97, label: "F6", fontSize: 8),
        KeyCap(id: "f7", code: 98, label: "F7", fontSize: 8),
        KeyCap(id: "f8", code: 100, label: "F8", fontSize: 8),
        KeyCap(id: "f9", code: 101, label: "F9", fontSize: 8),
        KeyCap(id: "f10", code: 109, label: "F10", fontSize: 8),
        KeyCap(id: "f11", code: 103, label: "F11", fontSize: 8),
        KeyCap(id: "f12", code: 111, label: "F12", fontSize: 8)
    ]

    static let row1: [KeyCap] = [
        KeyCap(id: "`", code: 50, label: "`"),
        KeyCap(id: "1", code: 18, label: "1"),
        KeyCap(id: "2", code: 19, label: "2"),
        KeyCap(id: "3", code: 20, label: "3"),
        KeyCap(id: "4", code: 21, label: "4"),
        KeyCap(id: "5", code: 23, label: "5"),
        KeyCap(id: "6", code: 22, label: "6"),
        KeyCap(id: "7", code: 26, label: "7"),
        KeyCap(id: "8", code: 28, label: "8"),
        KeyCap(id: "9", code: 25, label: "9"),
        KeyCap(id: "0", code: 29, label: "0"),
        KeyCap(id: "-", code: 27, label: "-"),
        KeyCap(id: "=", code: 24, label: "="),
        KeyCap(id: "delete", code: 51, label: "⌫", units: 1.5, fontSize: 11)
    ]

    static let row2: [KeyCap] = [
        KeyCap(id: "tab", code: 48, label: "⇥", units: 1.5, fontSize: 11),
        KeyCap(id: "q", code: 12, label: "Q"),
        KeyCap(id: "w", code: 13, label: "W"),
        KeyCap(id: "e", code: 14, label: "E"),
        KeyCap(id: "r", code: 15, label: "R"),
        KeyCap(id: "t", code: 17, label: "T"),
        KeyCap(id: "y", code: 16, label: "Y"),
        KeyCap(id: "u", code: 32, label: "U"),
        KeyCap(id: "i", code: 34, label: "I"),
        KeyCap(id: "o", code: 31, label: "O"),
        KeyCap(id: "p", code: 35, label: "P"),
        KeyCap(id: "[", code: 33, label: "["),
        KeyCap(id: "]", code: 30, label: "]"),
        KeyCap(id: "\\", code: 42, label: "\\")
    ]

    static let row3: [KeyCap] = [
        KeyCap(id: "caps", code: 57, label: "⇪", units: 1.7, fontSize: 11),
        KeyCap(id: "a", code: 0, label: "A"),
        KeyCap(id: "s", code: 1, label: "S"),
        KeyCap(id: "d", code: 2, label: "D"),
        KeyCap(id: "f", code: 3, label: "F"),
        KeyCap(id: "g", code: 5, label: "G"),
        KeyCap(id: "h", code: 4, label: "H"),
        KeyCap(id: "j", code: 38, label: "J"),
        KeyCap(id: "k", code: 40, label: "K"),
        KeyCap(id: "l", code: 37, label: "L"),
        KeyCap(id: ";", code: 41, label: ";"),
        KeyCap(id: "'", code: 39, label: "'"),
        KeyCap(id: "return", code: 36, label: "⏎", units: 1.8, fontSize: 11)
    ]

    static let row4: [KeyCap] = [
        KeyCap(id: "lshift", code: 56, label: "⇧", units: 2.2, fontSize: 11),
        KeyCap(id: "z", code: 6, label: "Z"),
        KeyCap(id: "x", code: 7, label: "X"),
        KeyCap(id: "c", code: 8, label: "C"),
        KeyCap(id: "v", code: 9, label: "V"),
        KeyCap(id: "b", code: 11, label: "B"),
        KeyCap(id: "n", code: 45, label: "N"),
        KeyCap(id: "m", code: 46, label: "M"),
        KeyCap(id: ",", code: 43, label: ","),
        KeyCap(id: ".", code: 47, label: "."),
        KeyCap(id: "/", code: 44, label: "/"),
        KeyCap(id: "rshift", code: 60, label: "⇧", units: 2.3, fontSize: 11)
    ]

    static let row5: [KeyCap] = [
        KeyCap(id: "fn", code: 63, label: "fn", units: 1, fontSize: 8),
        KeyCap(id: "lctrl", code: 59, label: "⌃", fontSize: 11),
        KeyCap(id: "lopt", code: 58, label: "⌥", fontSize: 11),
        KeyCap(id: "lcmd", code: 55, label: "⌘", units: 1.2, fontSize: 11),
        KeyCap(id: "space", code: 49, label: T("空格"), units: 3.6, fontSize: 8.5),
        KeyCap(id: "rcmd", code: 54, label: "⌘", units: 1.2, fontSize: 11),
        KeyCap(id: "ropt", code: 61, label: "⌥", fontSize: 11),
        KeyCap(id: "left", code: 123, label: "←", fontSize: 11),
        KeyCap(id: "up", code: 126, label: "↑", fontSize: 11),
        KeyCap(id: "down", code: 125, label: "↓", fontSize: 11),
        KeyCap(id: "right", code: 124, label: "→", fontSize: 11)
    ]

    static let maxUnits: CGFloat = 14.6

    static func label(for code: UInt16) -> String {
        for row in rows {
            if let cap = row.first(where: { $0.code == code }) { return cap.label }
        }
        return "key \(code)"
    }
}

// MARK: - 监听

@MainActor
final class KeyTestMonitor: ObservableObject {
    @Published private(set) var pressed: Set<UInt16> = []
    @Published private(set) var lastKey: String = ""
    @Published private(set) var lastCode: UInt16?
    @Published private(set) var count = 0

    private var monitor: Any?

    var combo: String {
        var parts: [String] = []
        if pressed.contains(59) || pressed.contains(62) { parts.append("⌃") }
        if pressed.contains(58) || pressed.contains(61) { parts.append("⌥") }
        if pressed.contains(56) || pressed.contains(60) { parts.append("⇧") }
        if pressed.contains(55) || pressed.contains(54) { parts.append("⌘") }

        let key = pressed
            .filter { !KeyLayout.modifiers.contains($0) }
            .sorted()
            .first
        if let key { parts.append(KeyLayout.label(for: key)) }
        return parts.joined()
    }

    var modifierOnly: Bool {
        !pressed.isEmpty && pressed.allSatisfy { KeyLayout.modifiers.contains($0) }
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.ingest(event)
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pressed.removeAll()
    }

    func reset() {
        pressed.removeAll()
        lastKey = ""
        lastCode = nil
        count = 0
    }

    private func ingest(_ event: NSEvent) {
        let code = event.keyCode
        switch event.type {
        case .keyDown:
            pressed.insert(code)
            count += 1
            lastCode = code
            let characters = event.charactersIgnoringModifiers ?? ""
            let label = KeyLayout.label(for: code)
            lastKey = characters.isEmpty ? label : "\(label) · \(characters)"
            // 长按会重复触发 keyDown，按一次只算一次
            if event.isARepeat { count -= 1 }
        case .keyUp:
            pressed.remove(code)
        case .flagsChanged:
            let down: Bool
            switch code {
            case 59, 62: down = event.modifierFlags.contains(.control)
            case 58, 61: down = event.modifierFlags.contains(.option)
            case 56, 60: down = event.modifierFlags.contains(.shift)
            case 55, 54: down = event.modifierFlags.contains(.command)
            case 57: down = event.modifierFlags.contains(.capsLock)
            case 63: down = event.modifierFlags.contains(.function)
            default: down = false
            }
            if down { pressed.insert(code) } else { pressed.remove(code) }
            lastCode = code
            lastKey = KeyLayout.label(for: code)
        default:
            break
        }
    }
}

// MARK: - 视图

struct KeyTestView: View {
    @ObservedObject var monitor: KeyTestMonitor

    var body: some View {
        VStack(spacing: 14) {
            header
            KeyBoardView(pressed: monitor.pressed)
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 26)
        .padding(.bottom, 14)
        .frame(width: 680, height: 386)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(T("组合键"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(monitor.combo.isEmpty ? T("按下任意键") : monitor.combo)
                    .font(.system(size: monitor.combo.isEmpty ? 13 : 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(monitor.combo.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(AuroraTheme.accent))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .frame(minWidth: 150, alignment: .leading)
            }

            Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 0.7, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(T("最近按键"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(monitor.lastKey.isEmpty ? "—" : monitor.lastKey)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(T("键码"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(monitor.lastCode.map { "\($0)" } ?? "—")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }

            Spacer()

            Text(TF("已按 %d 次", monitor.count))
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.06)))

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(monitor.combo, forType: .string)
            } label: {
                Text(T("复制组合"))
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(SoftButtonStyle())
            .disabled(monitor.combo.isEmpty)

            Button(T("清空")) { monitor.reset() }
                .buttonStyle(SoftButtonStyle())
                .disabled(monitor.count == 0 && monitor.pressed.isEmpty)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
            Text(T("按键只在本窗口内读取，不会记录到任何地方；关闭窗口即结束测试。"))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer()
            Text(T("⌘W 关闭"))
                .font(.system(size: 8.5, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct KeyBoardView: View {
    var pressed: Set<UInt16>

    private let gap: CGFloat = 3
    private let height: CGFloat = 30

    var body: some View {
        GeometryReader { proxy in
            let unit = max(1, (proxy.size.width - gap * (KeyLayout.maxUnits - 1)) / KeyLayout.maxUnits)
            VStack(spacing: gap) {
                ForEach(Array(KeyLayout.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: gap) {
                        ForEach(row) { cap in
                            keyCap(cap, width: cap.units * (unit + gap) - gap)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: height * CGFloat(KeyLayout.rows.count) + gap * CGFloat(KeyLayout.rows.count - 1))
    }

    private func keyCap(_ cap: KeyCap, width: CGFloat) -> some View {
        let active = pressed.contains(cap.code)
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(active ? AnyShapeStyle(AuroraTheme.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.06)))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(active ? Color.white.opacity(0.3) : Color.primary.opacity(0.10), lineWidth: 0.7)
            }
            .overlay {
                Text(cap.label)
                    .font(.system(size: cap.fontSize, weight: active ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary.opacity(0.72)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 2)
            }
            .frame(width: width, height: height)
            .shadow(color: active ? AuroraTheme.accent.opacity(0.3) : .clear, radius: 4, y: 1)
            .animation(.easeOut(duration: 0.1), value: active)
    }
}

// MARK: - 窗口

@MainActor
final class KeyTestWindowController: NSObject, NSWindowDelegate {
    static let shared = KeyTestWindowController()

    private var window: NSWindow?
    private let monitor = KeyTestMonitor()

    func show() {
        monitor.reset()
        monitor.start()

        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 386),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = T("按键测试")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        window.contentView = NSHostingView(rootView: KeyTestView(monitor: monitor))
        window.setContentSize(NSSize(width: 680, height: 386))
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        monitor.stop()
        monitor.reset()
        window = nil
    }
}
