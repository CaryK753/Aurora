//  AIView.swift
//  Aurora — AI用量：本地 harness 用量 + 真实配额窗口

import SwiftUI

struct AIView: View {
    @ObservedObject var service: AIUsageService
    @ObservedObject var state: AppState

    init(state: AppState) {
        self.state = state
        self.service = state.ai
    }

    var body: some View {
        VStack(spacing: 12) {
            summaryCard
            ForEach(service.withData) { provider in
                providerCard(provider)
            }
            if !service.detectedOnly.isEmpty {
                detectedCard
            }
            footer
        }
    }

    // MARK: - 汇总

    private var summaryCard: some View {
        GlassCard(padding: 13) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SectionLabel(text: T("近 7 天用量"), symbol: "sparkles")
                    Spacer(minLength: 0)
                    Button {
                        service.scan()
                        state.showToast(T("已刷新"), symbol: "arrow.clockwise")
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 8, weight: .bold))
                            Text(T("刷新"))
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .disabled(service.isScanning)
                }

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(Fmt.tokens(service.weekTotal))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(T("tokens"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    if let cost = costText {
                        Text(cost)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    metric(T("今日"), Fmt.tokens(service.todayTotal))
                    metric(T("5 小时窗口"), Fmt.tokens(service.withData.reduce(0) { $0 + $1.windowTokens }))
                    metric(T("已适配"), "\(service.withData.count)")
                }

                if service.withData.isEmpty {
                    Text(T("没有读到本地用量，先跑一次任意 harness 再回来刷新"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                } else {
                    shareBar
                }
            }
        }
    }

    private var costText: String? {
        guard service.costTotal > 0 else { return nil }
        return String(format: T("约 $%.2f"), service.costTotal)
    }

    /// 各 harness 占比条：一眼看出用量花在哪
    private var shareBar: some View {
        let items = service.withData.filter { $0.weekTokens > 0 }
        let total = max(items.reduce(0) { $0 + $1.weekTokens }, 1)
        return VStack(alignment: .leading, spacing: 5) {
            GeometryReader { proxy in
                HStack(spacing: 1.5) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(shareColor(index))
                            .frame(width: max(3, proxy.size.width * CGFloat(item.weekTokens) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 5)

            HStack(spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 3.5) {
                        Circle().fill(shareColor(index)).frame(width: 4.5, height: 4.5)
                        Text(item.name)
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func shareColor(_ index: Int) -> Color {
        let palette: [Color] = [
            AuroraTheme.accent,
            AuroraTheme.ok,
            AuroraTheme.warn,
            Color(red: 0.65, green: 0.55, blue: 0.95),
            Color(red: 0.95, green: 0.55, blue: 0.45)
        ]
        return palette[index % palette.count]
    }

    // MARK: - 单个 harness

    private func providerCard(_ provider: AIProviderUsage) -> some View {
        GlassCard(padding: 13) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    appIcon(provider)

                    VStack(alignment: .leading, spacing: 1.5) {
                        HStack(spacing: 5) {
                            Text(provider.name)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            if let plan = provider.planLabel {
                                Text(plan)
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(AuroraTheme.accent)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(AuroraTheme.accent.opacity(0.14)))
                            }
                        }
                        Text(subtitle(provider))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Text(Fmt.tokens(provider.weekTokens))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(AuroraTheme.accent)
                        .monospacedDigit()
                }

                if !provider.quotaWindows.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(provider.quotaWindows) { window in
                            quotaRow(window)
                        }
                    }
                } else if let used = provider.quotaUsed, let total = provider.quotaTotal, total > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(T("会话用量"))
                                .font(.system(size: 8.5))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text("\(Fmt.tokens(used)) / \(Fmt.tokens(total))")
                                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        MeterBar(value: min(Double(used) / Double(total), 1), height: 5)
                    }
                }

                HStack(spacing: 8) {
                    metric(T("今日"), Fmt.tokens(provider.todayTokens))
                    metric(T("5 小时"), Fmt.tokens(provider.windowTokens))
                    metric(T("7 天"), Fmt.tokens(provider.weekTokens))
                    metric(T("会话"), "\(provider.sessionCount)")
                }

                dailyBars(provider.daily)

                if let note = provider.note {
                    Text(note)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func quotaRow(_ window: QuotaWindow) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Text(window.label)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let reset = window.resetsAt {
                    Text(resetLabel(reset))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                Text(Fmt.percent(window.usedPercent / 100))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(window.usedPercent > 85 ? AuroraTheme.danger : .primary.opacity(0.8))
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
            MeterBar(
                value: window.usedPercent / 100,
                height: 5,
                gradient: window.usedPercent > 85
                    ? LinearGradient(colors: [AuroraTheme.warn, AuroraTheme.danger], startPoint: .leading, endPoint: .trailing)
                    : nil
            )
        }
    }

    private func resetLabel(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return T("即将重置") }
        if seconds < 3600 { return TF("%d 分钟后重置", max(1, Int(seconds / 60))) }
        if seconds < 86400 { return TF("%d 小时后重置", max(1, Int(seconds / 3600))) }
        return TF("%d 天后重置", max(1, Int(seconds / 86400)))
    }

    private func subtitle(_ provider: AIProviderUsage) -> String {
        var parts: [String] = []
        if let last = provider.lastActive {
            parts.append(TF("最近活动 %@", Fmt.relative(last)))
        }
        if let source = provider.sourceNote { parts.append(source) }
        if parts.isEmpty { parts.append(provider.installed ? T("已安装") : T("未检测到")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func appIcon(_ provider: AIProviderUsage) -> some View {
        if let icon = provider.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6)
                }
        } else {
            IconBadge(symbol: provider.symbol, size: 26, style: .tinted)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dailyBars(_ daily: [DailyTokenUsage]) -> some View {
        let peak = max(daily.map(\.tokens).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(daily) { day in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(AuroraTheme.accent.opacity(day.tokens > 0 ? 0.75 : 0.16))
                        .frame(height: max(3, CGFloat(day.tokens) / CGFloat(peak) * 24))
                        .frame(maxWidth: .infinity)
                    Text(dayLabel(day.date))
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(height: 38, alignment: .bottom)
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EE"
        formatter.locale = Locale(identifier: L10n.effective == "en" ? "en_US" : "zh_CN")
        return formatter.string(from: date)
    }

    // MARK: - 只检测到安装

    private var detectedCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    SectionLabel(text: T("已安装 · 无本地用量"), symbol: "app.dashed")
                    Spacer()
                    Text("\(service.detectedOnly.count)")
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                ForEach(service.detectedOnly) { provider in
                    HStack(spacing: 7) {
                        if let icon = provider.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 15, height: 15)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .opacity(0.85)
                        } else {
                            Image(systemName: provider.symbol)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .frame(width: 15)
                        }
                        Text(provider.name)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(provider.note ?? T("无本地用量"))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.shield")
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
            Text(T("数据来源：本机日志与本地数据库，不读取密钥、不调用接口"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}
