//  Controls.swift
//  Aurora — 自绘控件

import AppKit
import SwiftUI

struct AuroraSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var tint: LinearGradient = AuroraTheme.accentGradient
    var trackHeight: CGFloat = 7
    /// 刻度间隔（数值单位）：0.1 = 每 10% 一格，拖拽时有清晰的落点参照
    var tickStep: Double? = nil
    /// 刻度画到哪里为止：音量条是 0...1.5，刻度只画到 100%，多出来的算增强区
    var tickLimit: Double? = nil
    /// 取值步进（按住 ⌥ 时再细 10 倍），例如 0.01 = 1%
    var step: Double? = nil
    /// 拖拽结束时回调一次：硬件写入这类「一次就够」的场景用它，避免每个像素都发一遍
    var onCommit: (() -> Void)? = nil
    @State private var isDragging = false
    @State private var wasDragging = false

    private var span: Double { range.upperBound - range.lowerBound }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let knob: CGFloat = isDragging ? 17 : 14
            let percent = span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0

            ZStack(alignment: .leading) {
                ticks(width: width, height: proxy.size.height)

                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: trackHeight)

                // 100% 以后的增强区：淡淡压暗一档，拖过头时能看出已经过载
                if let tickLimit, tickLimit < range.upperBound, span > 0 {
                    let ratio = CGFloat((tickLimit - range.lowerBound) / span)
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: max(width * (1 - ratio), 0), height: trackHeight)
                        .offset(x: width * ratio)
                }

                Capsule()
                    .fill(tint)
                    .frame(width: max(trackHeight, width * CGFloat(percent)), height: trackHeight)
                    .shadow(color: AuroraTheme.accent.opacity(0.25), radius: 3)

                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.22), radius: 2.5, y: 1)
                    .offset(x: min(max(0, width * CGFloat(percent) - knob / 2), width - knob))
                    .animation(.spring(duration: 0.2, bounce: 0.3), value: isDragging)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        // 只有「明确的横向拖动」才改值：
                        // 面板里滑杆铺满整行，之前单击一下、或者想上下滚动列表时
                        // 指针落在这条 24pt 高的轨道上，就会按 x 位置把数值直接跳到 0%。
                        if !isDragging {
                            guard abs(gesture.translation.width) > 3,
                                  abs(gesture.translation.width) >= abs(gesture.translation.height) else { return }
                            isDragging = true
                            wasDragging = true
                        }
                        let progress = min(max(gesture.location.x / width, 0), 1)
                        value = snapped(range.lowerBound + Double(progress) * span)
                    }
                    .onEnded { _ in
                        isDragging = false
                        if wasDragging { onCommit?(); wasDragging = false }
                    }
            )
        }
        .frame(height: 24)
    }

    /// 拖拽取值：默认按 step 吸附（避免出现 37.4% 这种数），按住 ⌥ 再细 10 倍
    private func snapped(_ raw: Double) -> Double {
        guard let step, step > 0 else { return raw }
        let fine = NSEvent.modifierFlags.contains(.option)
        let unit = fine ? step / 10 : step
        let value = (raw / unit).rounded() * unit
        return min(max(value, range.lowerBound), range.upperBound)
    }

    @ViewBuilder
    private func ticks(width: CGFloat, height: CGFloat) -> some View {
        if let tickStep, tickStep > 0, span > 0 {
            let limit = min(tickLimit ?? range.upperBound, range.upperBound)
            let count = max(Int(((limit - range.lowerBound) / tickStep).rounded()), 1)
            let major = count > 10 ? 5 : (count > 4 ? 2 : 1)
            ForEach(0...count, id: \.self) { index in
                let value = range.lowerBound + Double(index) * tickStep
                let ratio = CGFloat((value - range.lowerBound) / span)
                let isMajor = index % major == 0 || index == count
                Capsule()
                    .fill(Color.primary.opacity(isMajor ? 0.20 : 0.11))
                    .frame(width: isMajor ? 1 : 0.7, height: trackHeight + (isMajor ? 9 : 5))
                    .offset(x: min(max(width * ratio - 0.5, 0), width - 1))
            }
        }
    }
}

/// 带图标与数值的滑杆行
struct SliderRow: View {
    var symbol: String
    var title: String?
    var value: Binding<Double>
    var range: ClosedRange<Double> = 0...1
    var displayText: String
    var tint: LinearGradient = AuroraTheme.accentGradient
    var tickStep: Double?
    var step: Double?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            if let title {
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 48, alignment: .leading)
                    .layoutPriority(1)
            }

            AuroraSlider(value: value, range: range, tint: tint, tickStep: tickStep, step: step)

            Text(displayText)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
