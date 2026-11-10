//  Controls.swift
//  Aurora — 自绘控件

import SwiftUI

struct AuroraSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var tint: LinearGradient = AuroraTheme.accentGradient
    var trackHeight: CGFloat = 7
    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let knob: CGFloat = isDragging ? 17 : 14
            let span = range.upperBound - range.lowerBound
            let percent = span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: trackHeight)

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
                        }
                        let progress = min(max(gesture.location.x / width, 0), 1)
                        value = range.lowerBound + Double(progress) * span
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: 24)
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

            AuroraSlider(value: value, range: range, tint: tint)

            Text(displayText)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
