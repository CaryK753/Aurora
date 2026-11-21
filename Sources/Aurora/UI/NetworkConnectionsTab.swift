//  NetworkConnectionsTab.swift
//  Aurora — 网络 › 连接：当前连接、每条连接的规则与流量

import NetworkProxyKit
import SwiftUI

struct NetworkConnectionsTab: View {
    @ObservedObject var system: SystemProxyService
    @ObservedObject var metrics: ProxyMetricsService
    @State private var query = ""

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                header
                if !metrics.live {
                    placeholder(T("代理未运行"), detail: T("应用系统代理后，这里会列出每条连接。"))
                } else if filtered.isEmpty {
                    placeholder(T("没有连接"), detail: T("当前没有正在使用的连接，或者搜索没有匹配项。"))
                } else {
                    list
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel(text: T("连接"), symbol: "arrow.left.arrow.right")
                Text("\(metrics.connections.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(AuroraTheme.accent)
                Spacer()
                NetworkQuietButton(title: T("断开全部"), tint: AuroraTheme.danger) {
                    Task { await metrics.closeAllConnections() }
                }
                .disabled(metrics.connections.isEmpty)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(.tertiary)
                TextField(T("按域名、进程或规则筛选"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 10.5))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
                Text("↓ " + NetworkFormat.bytes(metrics.sample.downTotal) + "  ↑ " + NetworkFormat.bytes(metrics.sample.upTotal))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
    }

    private var filtered: [ProxyConnection] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return metrics.connections }
        return metrics.connections.filter {
            $0.target.lowercased().contains(text)
                || $0.processName.lowercased().contains(text)
                || $0.ruleDescription.lowercased().contains(text)
                || $0.policy.lowercased().contains(text)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(filtered) { connection in
                    row(connection)
                }
            }
        }
        .frame(maxHeight: 420)
    }

    private func row(_ connection: ProxyConnection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: connection.network == "udp" ? "bolt.horizontal" : "arrow.left.arrow.right")
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(connection.target)
                        .font(.system(size: 11))
                        .lineLimit(1).truncationMode(.middle)
                    if !connection.destinationPort.isEmpty {
                        Text(":" + connection.destinationPort)
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 4) {
                    if !connection.processName.isEmpty {
                        Text(connection.processName)
                            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !connection.ruleDescription.isEmpty {
                        Text(connection.ruleDescription)
                            .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            if !connection.policy.isEmpty {
                NetworkChip(text: connection.policy, maxWidth: 110)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text("↓ " + NetworkFormat.bytes(connection.download) + "  ↑ " + NetworkFormat.bytes(connection.upload))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(NetworkFormat.duration(connection.duration()))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Button {
                Task { await metrics.close(connectionID: connection.id) }
            } label: {
                Image(systemName: "xmark.circle").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(T("断开这条连接"))
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.03)))
    }

    private func placeholder(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .medium))
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
    }
}
