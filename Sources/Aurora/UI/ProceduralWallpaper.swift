//  ProceduralWallpaper.swift
//  Aurora — 程序生成的动态壁纸：GPU 上跑的流动渐变场景
//
//  相比视频壁纸的优势：零文件、零版权、可以改配色，
//  用 SwiftUI TimelineView + 渐变/形状实现，负载集中在合成器上。

import SwiftUI

// MARK: - 场景定义

enum ProceduralWallpaper {
    static let styles = ["aurora", "waves", "mesh", "sunset"]

    /// 每个场景的默认基础色相（0~1）
    static func baseHues(for style: String) -> [Double] {
        switch style {
        case "waves": return [0.58, 0.52, 0.63, 0.47, 0.66]
        case "mesh": return [0.83, 0.62, 0.55, 0.9, 0.72, 0.5]
        case "sunset": return [0.07, 0.9, 0.78, 0.98]
        default: return [0.38, 0.47, 0.72, 0.42]   // aurora：绿→青→紫
        }
    }

    static func color(_ hue: Double, shift: Double, sat: Double = 0.62, bri: Double = 0.55, opacity: Double = 1) -> Color {
        let h = (hue + shift / 360).truncatingRemainder(dividingBy: 1)
        return Color(hue: h < 0 ? h + 1 : h, saturation: sat, brightness: bri, opacity: opacity)
    }

    static func displayName(for style: String) -> String {
        switch style {
        case "waves": return T("波浪")
        case "mesh": return T("流光")
        case "sunset": return T("暮色")
        default: return T("极光")
        }
    }
}

// MARK: - 桌面层实时画面

struct ProceduralWallpaperView: View {
    let style: String
    /// 用户自定义的色相偏移（度），0 = 默认配色
    var hueShift: Double = 0

    @ObservedObject private var clock = ProceduralClock.shared

    var body: some View {
        ZStack {
            backdrop
            scene(t: clock.time)
        }
        .clipped()
        .ignoresSafeArea()
        .onAppear { clock.retain() }
        .onDisappear { clock.release() }
    }

    private var backdrop: some View {
        LinearGradient(
            colors: [
                ProceduralWallpaper.color(0.62, shift: hueShift, sat: 0.5, bri: 0.07),
                ProceduralWallpaper.color(0.7, shift: hueShift, sat: 0.55, bri: 0.04)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ViewBuilder
    private func scene(t: Double) -> some View {
        switch style {
        case "waves": waves(t: t)
        case "mesh": mesh(t: t)
        case "sunset": sunset(t: t)
        default: aurora(t: t)
        }
    }

    // 极光：几条大光带在缓慢摇摆
    private func aurora(t: Double) -> some View {
        let hues = ProceduralWallpaper.baseHues(for: "aurora")
        return ZStack {
            ForEach(0..<hues.count, id: \.self) { i in
                let phase = t * 0.18 + Double(i) * 1.7
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                ProceduralWallpaper.color(hues[i], shift: hueShift, bri: 0.7, opacity: 0.0),
                                ProceduralWallpaper.color(hues[i], shift: hueShift, bri: 0.65, opacity: 0.34),
                                ProceduralWallpaper.color(hues[i], shift: hueShift, bri: 0.7, opacity: 0.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 900, height: 340 + CGFloat(i) * 60)
                    .rotationEffect(.degrees(-24 + Double(i) * 5))
                    .position(
                        x: 0.5 + 0.16 * sin(phase) * 1.0,
                        y: 0.32 + 0.1 * cos(phase * 0.8 + Double(i))
                    )
                    .blur(radius: 70)
            }
        }
    }

    // 波浪：层叠的半透明波带水平流动
    private func waves(t: Double) -> some View {
        let hues = ProceduralWallpaper.baseHues(for: "waves")
        return ZStack {
            ForEach(0..<hues.count, id: \.self) { i in
                WaveBand(
                    phase: t * (0.35 + Double(i) * 0.07),
                    amplitude: 0.045 + Double(i) * 0.012,
                    baseline: 0.58 + Double(i) * 0.075
                )
                .fill(
                    LinearGradient(
                        colors: [
                            ProceduralWallpaper.color(hues[i], shift: hueShift, bri: 0.55, opacity: 0.32),
                            ProceduralWallpaper.color(hues[i], shift: hueShift, bri: 0.4, opacity: 0.18)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
    }

    // 流光：一团团柔光缓慢漂移
    private func mesh(t: Double) -> some View {
        let hues = ProceduralWallpaper.baseHues(for: "mesh")
        return ZStack {
            ForEach(0..<hues.count, id: \.self) { i in
                let phase = t * (0.1 + Double(i) * 0.03) + Double(i) * 2.1
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                ProceduralWallpaper.color(hues[i], shift: hueShift, bri: 0.6, opacity: 0.4),
                                ProceduralWallpaper.color(hues[i], shift: hueShift, bri: 0.6, opacity: 0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 480
                        )
                    )
                    .frame(width: 900, height: 900)
                    .position(
                        x: 0.5 + 0.34 * sin(phase),
                        y: 0.5 + 0.3 * cos(phase * 1.31 + 1.2)
                    )
                    .blur(radius: 30)
            }
        }
    }

    // 暮色：地平线上的落日光晕，颜色随时间缓慢游移
    private func sunset(t: Double) -> some View {
        let hues = ProceduralWallpaper.baseHues(for: "sunset")
        let glow = 0.5 + 0.06 * sin(t * 0.1)
        return ZStack {
            LinearGradient(
                colors: [
                    ProceduralWallpaper.color(hues[3], shift: hueShift, sat: 0.6, bri: 0.16),
                    ProceduralWallpaper.color(hues[2], shift: hueShift, sat: 0.62, bri: 0.3),
                    ProceduralWallpaper.color(hues[0], shift: hueShift, sat: 0.72, bri: 0.5),
                    ProceduralWallpaper.color(hues[1], shift: hueShift, sat: 0.6, bri: 0.32)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            ProceduralWallpaper.color(hues[0], shift: hueShift, sat: 0.55, bri: 0.85, opacity: 0.8),
                            ProceduralWallpaper.color(hues[0], shift: hueShift, sat: 0.6, bri: 0.7, opacity: 0)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 520
                    )
                )
                .frame(width: 900, height: 900)
                .position(x: 0.5 + 0.1 * sin(t * 0.05), y: glow)
                .blur(radius: 26)
        }
    }
}

// MARK: - 波浪形状

struct WaveBand: Shape {
    var phase: Double
    var amplitude: Double
    var baseline: Double

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 48
        path.move(to: CGPoint(x: 0, y: rect.height))
        for i in 0...steps {
            let x = rect.width * CGFloat(i) / CGFloat(steps)
            let wave = sin(Double(i) / Double(steps) * .pi * 2.4 + phase)
                + 0.5 * sin(Double(i) / Double(steps) * .pi * 5.1 - phase * 0.6)
            let y = rect.height * (baseline + amplitude * wave)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.closeSubpath()
        return path
    }
}

// MARK: - 卡片上的静态预览（网格里跑动画太浪费）

struct ProceduralStaticPreview: View {
    let style: String
    var hueShift: Double = 0

    var body: some View {
        let hues = ProceduralWallpaper.baseHues(for: style)
        ZStack {
            LinearGradient(
                colors: hues.map { ProceduralWallpaper.color($0, shift: hueShift, bri: 0.5) },
                startPoint: style == "sunset" ? .top : .topLeading,
                endPoint: style == "sunset" ? .bottom : .bottomTrailing
            )
            LinearGradient(
                colors: [.clear, .black.opacity(0.25)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - 动画时钟
//
// 桌面层窗口（desktopWindow + 1）会被桌面图标层盖住，SwiftUI 的
// TimelineView(.animation) 在"被遮挡"的窗口里会暂停刷新——表现就是
// 程序化壁纸设上去以后完全静止。这里用自建 Timer 驱动时间，
// 不依赖窗口可见性，只要视图在刷新就会重绘。

@MainActor
final class ProceduralClock: ObservableObject {
    static let shared = ProceduralClock()

    /// 绝对时间（秒），与之前 TimelineView 的 date 语义一致
    @Published private(set) var time: Double = Date().timeIntervalSinceReferenceDate

    private var timer: Timer?
    private var users = 0
    // 壁纸是缓慢漂移的渐变，20fps 足够顺滑，也能省电
    private let fps: Double = 20

    func retain() {
        users += 1
        guard timer == nil else { return }
        let interval = 1.0 / fps
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.time = Date().timeIntervalSinceReferenceDate
            }
        }
        timer.tolerance = interval * 0.35
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
    }
}
