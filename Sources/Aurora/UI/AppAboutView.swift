//  AppAboutView.swift
//  Aurora — 设置 › 关于
//
//  重新排布过的「关于」：身份 → 更新 → 新功能 → 链接 → 维护，
//  五块内容各自独立、从上到下按「先看版本、再管更新、最后才敢动设置」的顺序排。

import SwiftUI

struct AppAboutView: View {
    @ObservedObject var settings: SettingsService
    @ObservedObject var state: AppState
    @ObservedObject private var updates: UpdateService

    /// 当前版本的更新说明（只解析一次，面板每次重建不必重读 CHANGELOG）
    @State private var notes: ReleaseNotes?

    init(settings: SettingsService, state: AppState) {
        self.settings = settings
        self.state = state
        self.updates = state.updates
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            identity
            divider
            updateSection
            divider
            whatsNewSection
            divider
            linksSection
            divider
            maintenanceSection
        }
        .onAppear {
            // previewContent 在开发态（可执行文件没有 Info.plist）也能取到最新一版说明
            if notes == nil { notes = ReleaseNotesStore.previewContent().notes }
        }
    }

    // MARK: - 身份

    private var identity: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high).frame(width: 54, height: 54)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Aurora").font(.system(size: 15, weight: .semibold))
                    if case .ready(let release) = updates.phase {
                        Text(TF("v%@", release.version))
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(AuroraTheme.ok))
                    }
                }
                Text("\(T("版本")) \(settings.version) (\(settings.build)) · \(settings.systemVersion)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Text(T("一站式 Mac 优化与增强工具：显示、鼠标、触控板、键盘、剪贴板、声音、节能，以及截图、录屏与动态壁纸，全部收进菜单栏。"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 更新

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel(T("更新"), symbol: "arrow.triangle.2.circlepath")

            HStack(spacing: 8) {
                Text(statusText)
                    .font(.system(size: 9))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if case .downloading = updates.phase {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
                }
                Button(updateButtonTitle) {
                    switch updates.phase {
                    case .ready(let release):
                        updates.install(release)
                    default:
                        updates.check(manual: true)
                    }
                }
                .buttonStyle(SoftButtonStyle())
                .disabled(updates.phase.isBusy)
            }

            HStack(spacing: 9) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(T("自动检查新版本"))
                        .font(.system(size: 11, weight: .medium))
                    Text(updates.autoUpdate
                         ? T("每小时检查一次，下载完成后由你确认再安装")
                         : T("只在你手动检查时提示新版本"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                AuroraToggle(isOn: $updates.autoUpdate)
            }
        }
    }

    // MARK: - 新功能

    private var whatsNewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(T("新功能"), symbol: "sparkles")

            // 整块都能点：摘要、要点、底部胶囊是一个点击目标
            VStack(alignment: .leading, spacing: 6) {
                Text(whatsNewSummary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(notes.allItems.prefix(3).enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 6) {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.55))
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 5)
                                Text(item.summary)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }

                HStack(spacing: 5) {
                    Text(T("查看这一版的新功能"))
                        .font(.system(size: 10, weight: .medium))
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 8.5, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor.opacity(0.10)))
                .padding(.top, 1)
            }
            .contentShape(Rectangle())
            .onTapGesture { state.openWhatsNew() }
            .help(T("查看这一版的更新说明"))
        }
    }

    private var whatsNewSummary: String {
        guard let notes, !notes.isEmpty else {
            return T("这个版本没有单独的更新说明，可以到 GitHub 上看完整日志。")
        }
        let version = notes.version.isEmpty ? settings.version : notes.version
        if notes.headline.isEmpty {
            return TF("Aurora %@ 的更新内容", version)
        }
        return TF("Aurora %@ · %@", version, notes.headline)
    }

    // MARK: - 链接

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionLabel(T("链接"), symbol: "link")
            linkRow(symbol: "chevron.left.forwardslash.chevron.right", title: T("在 GitHub 上为我们点星"),
                    detail: UpdateService.repository, url: UpdateService.homepage)
            linkRow(symbol: "exclamationmark.bubble", title: T("问题反馈"),
                    detail: T("报告问题或提建议"), url: URL(string: "\(UpdateService.homepage.absoluteString)/issues")!)
            linkRow(symbol: "list.bullet.rectangle", title: T("完整更新日志"),
                    detail: "CHANGELOG.md", url: UpdateService.releasesPage)
        }
    }

    private func linkRow(symbol: String, title: String, detail: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title).font(.system(size: 10.5, weight: .medium))
                Spacer(minLength: 4)
                Text(detail)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 维护

    private var maintenanceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(T("维护"), symbol: "wrench.and.screwdriver")
            HStack(spacing: 8) {
                Text(T("会清空全部偏好与历史"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Button {
                    guard AuroraAlert.confirmReset() else { return }
                    state.resetSettings()
                    state.showToast(
                        settings.launchAtLoginError ?? T("已重置"),
                        symbol: settings.launchAtLoginError == nil ? "arrow.counterclockwise" : "exclamationmark.triangle"
                    )
                } label: {
                    Text(T("重置所有设置"))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(AuroraTheme.danger.opacity(0.9))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(AuroraTheme.danger.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 小组件

    private func sectionLabel(_ text: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(text.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
        }
    }

    private var updateButtonTitle: String {
        switch updates.phase {
        case .ready: return T("立即更新")
        case .checking: return T("检查中…")
        case .downloading: return T("正在下载…")
        case .installing: return T("正在更新…")
        default: return T("检查更新")
        }
    }

    private var statusText: String {
        switch updates.phase {
        case .idle:
            guard let last = updates.lastCheck else { return T("尚未检查") }
            return TF("上次检查 %@", Fmt.relative(last))
        case .checking:
            return T("正在检查更新…")
        case .upToDate:
            guard let last = updates.lastCheck else { return T("已是最新版本") }
            return TF("已是最新版本 · %@", Fmt.clock(last))
        case .downloading(let progress):
            return progress > 0 ? TF("正在下载 %d%%", Int(progress * 100)) : T("正在下载…")
        case .ready(let release):
            return TF("新版本 %@ 已就绪", release.version)
        case .installing:
            return T("正在替换并重启…")
        case .failed(let message):
            return message
        }
    }

    private var statusColor: AnyShapeStyle {
        switch updates.phase {
        case .failed: return AnyShapeStyle(AuroraTheme.warn)
        case .ready: return AnyShapeStyle(AuroraTheme.ok)
        default: return AnyShapeStyle(Color.secondary)
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)
    }
}
