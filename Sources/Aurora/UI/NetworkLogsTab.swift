//  NetworkLogsTab.swift
//  Aurora — 网络 › 日志：内核日志流

import NetworkProxyKit
import SwiftUI

struct NetworkLogsTab: View {
    @ObservedObject var metrics: ProxyMetricsService
    @State private var level = "all"

    private var filtered: [ProxyLogLine] {
        let list = metrics.logs.reversed()
        guard level != "all" else { return Array(list) }
        return list.filter { $0.level == level }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SectionLabel(text: T("日志"), symbol: "text.alignleft")
                    Text("\(metrics.logs.count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(AuroraTheme.accent)
                    Spacer()
                    NetworkQuietButton(title: metrics.logPaused ? T("继续") : T("暂停")) {
                        metrics.logPaused.toggle()
                    }
                    NetworkQuietButton(title: T("清空")) { metrics.clearLogs() }
                        .disabled(metrics.logs.isEmpty)
                    NetworkQuietButton(title: T("复制")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(metrics.logs.map(\.message).joined(separator: "\n"), forType: .string)
                    }
                    .disabled(metrics.logs.isEmpty)
                }
                HStack(spacing: 5) {
                    ForEach(["all", "info", "warning", "error"], id: \.self) { item in
                        let active = level == item
                        Button { level = item } label: {
                            Text(item == "all" ? T("全部") : item)
                                .font(.system(size: 9.5, weight: active ? .semibold : .regular))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(active ? AnyShapeStyle(AuroraTheme.accent.opacity(0.18)) : AnyShapeStyle(Color.primary.opacity(0.05))))
                                .foregroundStyle(active ? AnyShapeStyle(AuroraTheme.accent) : AnyShapeStyle(Color.secondary))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Text(metrics.live ? T("实时") : T("未连接"))
                        .font(.system(size: 9)).foregroundStyle(metrics.live ? AuroraTheme.ok : Color.secondary)
                }
                if filtered.isEmpty {
                    Text(metrics.live ? T("还没有日志") : T("代理运行后这里会显示内核日志。"))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filtered.prefix(200)) { line in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(timeText(line.time))
                                        .font(.system(size: 8.5, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                    Text(line.message)
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(color(line.level))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 380)
                }
            }
        }
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "error": return AuroraTheme.danger
        case "warning": return AuroraTheme.warn
        case "debug": return .secondary
        default: return .primary
        }
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
