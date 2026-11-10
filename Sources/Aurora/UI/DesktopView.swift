//  DesktopView.swift
//  Aurora — 桌面图标开关

import SwiftUI

struct DesktopView: View {
    @ObservedObject var service: DesktopService
    @ObservedObject var state: AppState

    init(state: AppState) {
        self.state = state
        self.service = state.desktop
    }

    var body: some View {
        VStack(spacing: 12) {
            heroCard
            finderCard
            actionCard
            tipCard
        }
    }

    private var heroCard: some View {
        GlassCard(padding: 16) {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    preview

                    VStack(alignment: .leading, spacing: 3) {
                        Text(T("桌面图标"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(service.iconsVisible ? T("图标正在桌面显示") : T("桌面已清空"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    AuroraToggle(
                        isOn: Binding(
                            get: { service.iconsVisible },
                            set: { visible in
                                service.setIconsVisible(visible)
                                state.showToast(
                                    visible ? T("桌面图标已显示") : T("桌面图标已隐藏"),
                                    symbol: visible ? "eye.fill" : "eye.slash.fill"
                                )
                            }
                        )
                    )
                }

                Text(T("隐藏后，桌面上的文件、磁盘与文件夹不再显示。文件仍在原位，可通过访达侧边栏的「桌面」访问。"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            AuroraTheme.accent.opacity(0.55),
                            AuroraTheme.accent.opacity(0.35)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { column in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(.white.opacity(service.iconsVisible ? 0.92 : 0.22))
                                .frame(width: 9, height: 9)
                                .scaleEffect(service.iconsVisible ? 1 : 0.62)
                                .animation(
                                    .spring(duration: 0.42, bounce: 0.35)
                                        .delay(Double(row * 3 + column) * 0.03),
                                    value: service.iconsVisible
                                )
                        }
                    }
                }
            }
        }
        .frame(width: 72, height: 50)
        .overlay(alignment: .top) {
            Capsule()
                .fill(.white.opacity(0.32))
                .frame(width: 24, height: 2.5)
                .padding(.top, 5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
    }

    private var finderCard: some View {
        GlassCard(padding: 12) {
            VStack(spacing: 10) {
                HStack {
                    SectionLabel(text: T("访达显示"), symbol: "eye")
                    Spacer()
                }

                HStack(spacing: 9) {
                    IconBadge(symbol: "eye.slash.fill", color: AuroraTheme.accent, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("显示隐藏文件"))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(T("以半透明样式显示 . 开头的文件"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    AuroraToggle(
                        isOn: Binding(
                            get: { service.showHiddenFiles },
                            set: { value in
                                service.setShowHiddenFiles(value)
                                state.showToast(value ? T("已显示隐藏文件") : T("已隐藏隐藏文件"), symbol: "eye.slash.fill")
                            }
                        )
                    )
                }

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6).padding(.leading, 33)

                HStack(spacing: 9) {
                    IconBadge(symbol: "doc.text.fill", color: AuroraTheme.ok, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("显示所有扩展名"))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(T("让文件后缀始终可见"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    AuroraToggle(
                        isOn: Binding(
                            get: { service.showAllExtensions },
                            set: { value in
                                service.setShowAllExtensions(value)
                                state.showToast(value ? T("已显示扩展名") : T("已隐藏扩展名"), symbol: "doc.text.fill")
                            }
                        )
                    )
                }
            }
        }
    }

    private var actionCard: some View {
        GlassCard(padding: 12) {
            VStack(spacing: 6) {
                Button {
                    DesktopService.restartFinder()
                    state.showToast(T("访达已重新启动"), symbol: "arrow.clockwise")
                } label: {
                    HStack(spacing: 9) {
                        IconBadge(symbol: "arrow.clockwise", color: AuroraTheme.accent, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(T("重启访达"))
                                .font(.system(size: 11.5, weight: .medium))
                            Text(T("若桌面未立即刷新，可手动重启"))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6).padding(.leading, 34)

                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Desktop"))
                } label: {
                    HStack(spacing: 9) {
                        IconBadge(symbol: "folder.fill", color: AuroraTheme.ok, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(T("在访达中打开桌面"))
                                .font(.system(size: 11.5, weight: .medium))
                            Text(T("隐藏图标后从这里取用文件"))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6).padding(.leading, 34)

                Button {
                    service.openFinderSettings()
                } label: {
                    HStack(spacing: 9) {
                        IconBadge(symbol: "gearshape.fill", color: AuroraTheme.accent, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(T("访达设置"))
                                .font(.system(size: 11.5, weight: .medium))
                            Text(T("管理桌面显示的项目"))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var tipCard: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 9))
                .foregroundStyle(AuroraTheme.warn.opacity(0.9))
            Text(T("这是把桌面当作临时工作台时最省心的做法：需要专注时一键清空，文件不会移动或删除。"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }
}
