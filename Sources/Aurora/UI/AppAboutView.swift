import SwiftUI

struct AppAboutView: View {
    @ObservedObject var settings: SettingsService
    @ObservedObject var state: AppState
    @ObservedObject private var updates: UpdateService

    init(settings: SettingsService, state: AppState) {
        self.settings = settings
        self.state = state
        self.updates = state.updates
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            identity

            Text(T("一站式 Mac 优化与增强工具，把显示、鼠标、触控板、剪贴板、声音与节能管理收进菜单栏。"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            divider
            updateRow
            divider
            githubRow
            divider
            resetRow
        }
    }

    // MARK: - 头部

    private var identity: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high).frame(width: 46, height: 46)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
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
                Text("\(T("版本")) \(settings.version) (\(settings.build))")
                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
                Text(settings.systemVersion).font(.system(size: 8.5)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 更新

    private var updateRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(T("自动更新"))
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

            HStack(spacing: 8) {
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

                Spacer(minLength: 6)

                HStack(spacing: 4) {
                    if case .downloading = updates.phase {
                        ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
                    }
                    Text(statusText)
                        .font(.system(size: 8.5))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
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

    // MARK: - GitHub

    private var githubRow: some View {
        Button {
            NSWorkspace.shared.open(UpdateService.homepage)
        } label: {
            HStack(spacing: 8) {
                if let mark = BrandMarks.github(size: 13) {
                    Image(nsImage: mark)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 13, height: 13)
                        .foregroundStyle(.primary.opacity(0.85))
                } else {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 10))
                }
                Text(T("在 GitHub 上为我们点星"))
                    .font(.system(size: 10.5, weight: .medium))
                Text("MIT")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                Spacer(minLength: 4)
                Text("\(UpdateService.repository)")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(T("在浏览器中打开项目主页"))
    }

    // MARK: - 重置

    private var resetRow: some View {
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

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)
    }
}
