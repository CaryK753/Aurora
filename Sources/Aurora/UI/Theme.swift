//  Theme.swift
//  Aurora — 视觉基线：单一主色 + 语义色，玻璃层级组件

import SwiftUI

enum AuroraTheme {
    // 主色（单一色相，避免彩虹感）
    // 主色：在深色玻璃上够亮，在浅色卡片上也能保证对比度
    static let accent = Color(red: 0.22, green: 0.62, blue: 0.96)
    static let accentDeep = Color(red: 0.09, green: 0.42, blue: 0.86)

    // 语义色：只用于状态，不用于装饰
    static let ok = Color(red: 0.20, green: 0.83, blue: 0.60)
    static let warn = Color(red: 0.98, green: 0.75, blue: 0.25)
    static let danger = Color(red: 0.98, green: 0.42, blue: 0.47)

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var accentSoft: LinearGradient {
        LinearGradient(
            colors: [accent.opacity(0.85), accentDeep.opacity(0.65)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 仪表盘：单色相由浅到深，仅高负载时切语义色
    static func gaugeGradient(_ value: Double) -> AngularGradient {
        if value > 0.9 {
            return AngularGradient(colors: [danger, warn, danger], center: .center, startAngle: .degrees(-90), endAngle: .degrees(270))
        }
        return AngularGradient(
            colors: [accent.opacity(0.55), accent, accentDeep, accent.opacity(0.55)],
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
    }

    static func barGradient(_ value: Double) -> LinearGradient {
        if value > 0.9 {
            return LinearGradient(colors: [warn, danger], startPoint: .leading, endPoint: .trailing)
        }
        return LinearGradient(colors: [accent, accentDeep], startPoint: .leading, endPoint: .trailing)
    }

    static func statusColor(_ value: Double, warnThreshold: Double = 0.7, dangerThreshold: Double = 0.88) -> Color {
        if value >= dangerThreshold { return danger }
        if value >= warnThreshold { return warn }
        return ok
    }
}

// MARK: - 玻璃卡片

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 14
    var corner: CGFloat = 20
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(fill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.10 : 0.04), radius: 8, x: 0, y: 4)
    }

    /// 两种外观共用同一套半透明白叠加：卡片始终是玻璃上的一层薄雾，而不是实心白块
    private var fill: AnyShapeStyle {
        if scheme == .dark {
            return AnyShapeStyle(Color.white.opacity(0.055))
        }
        return AnyShapeStyle(Color.white.opacity(0.34))
    }

    private var stroke: LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [Color.white.opacity(0.18), Color.white.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [Color.black.opacity(0.10), Color.black.opacity(0.045)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - 区块标题

struct SectionLabel: View {
    let text: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }
}

// MARK: - 环形仪表

struct RingGauge: View {
    var value: Double
    var size: CGFloat = 74
    var lineWidth: CGFloat = 7
    var centerText: String
    var caption: String?

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.07), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: max(0.004, min(value, 1)))
                .stroke(AuroraTheme.gaugeGradient(value), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: AuroraTheme.accent.opacity(0.22), radius: 4)
                .animation(.smooth(duration: 0.55), value: value)

            VStack(spacing: 0) {
                Text(centerText)
                    .font(.system(size: size * 0.27, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let caption {
                    Text(caption)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 迷你折线图

struct Sparkline: View {
    var values: [Double]
    var color: Color = AuroraTheme.accent
    var filled: Bool = true
    var maxValue: Double? = nil

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let upper = maxValue ?? max(values.max() ?? 1, 0.0001)
            let stepX = values.count > 1 ? width / CGFloat(values.count - 1) : width

            let points: [CGPoint] = values.enumerated().map { index, value in
                let normalized = upper > 0 ? min(value / upper, 1) : 0
                return CGPoint(x: CGFloat(index) * stepX, y: height - normalized * (height - 2) - 1)
            }

            ZStack {
                if filled, points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: height))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.26), color.opacity(0.01)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }

                if points.count > 1 {
                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            }
            .animation(.linear(duration: 0.2), value: values.count)
        }
    }
}

// MARK: - 横向进度条

struct MeterBar: View {
    var value: Double
    var height: CGFloat = 5
    var gradient: LinearGradient? = nil

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(gradient ?? AuroraTheme.barGradient(value))
                    .frame(width: max(3, proxy.size.width * min(max(value, 0), 1)))
                    .animation(.smooth(duration: 0.45), value: value)
            }
        }
        .frame(height: height)
    }
}

// MARK: - 自绘开关

struct AuroraToggle: View {
    @Binding var isOn: Bool
    var tint: Color = AuroraTheme.accent

    var body: some View {
        Capsule()
            .fill(isOn ? AnyShapeStyle(AuroraTheme.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.12)))
            .frame(width: 40, height: 23)
            .overlay {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.8)
                    .padding(2.5)
                    .offset(x: isOn ? 8.5 : -8.5)
            }
            .overlay {
                Capsule().strokeBorder(isOn ? Color.white.opacity(0.32) : Color.primary.opacity(0.14), lineWidth: 0.7)
            }
            .animation(.spring(duration: 0.28, bounce: 0.28), value: isOn)
            .onTapGesture { isOn.toggle() }
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 图标徽章（统一主色，不再按模块换色）

struct IconBadge: View {
    var symbol: String
    var color: Color = AuroraTheme.accent
    var size: CGFloat = 30
    var style: Style = .tinted

    enum Style { case tinted, solid, neutral }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(background)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(style == .solid ? AnyShapeStyle(Color.white) : AnyShapeStyle(color))
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.7)
            }
    }

    private var borderColor: Color {
        style == .solid ? Color.white.opacity(0.22) : Color.primary.opacity(0.10)
    }

    private var background: AnyShapeStyle {
        switch style {
        case .solid:
            return AnyShapeStyle(LinearGradient(colors: [color, color.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .tinted:
            return AnyShapeStyle(color.opacity(0.16))
        case .neutral:
            return AnyShapeStyle(Color.primary.opacity(0.07))
        }
    }
}

// MARK: - 按钮样式

struct SoftButtonStyle: ButtonStyle {
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                if prominent {
                    Capsule().fill(AuroraTheme.accentGradient)
                } else {
                    Capsule().fill(Color.primary.opacity(0.08))
                }
            }
            .overlay {
                Capsule().strokeBorder(prominent ? Color.white.opacity(0.28) : Color.primary.opacity(0.12), lineWidth: 0.7)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - 设置行

struct SettingRow<Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

// MARK: - 空态

struct EmptyHint: View {
    var symbol: String
    var text: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}
