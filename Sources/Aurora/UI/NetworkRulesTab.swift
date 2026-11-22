//  NetworkRulesTab.swift
//  Aurora — 网络 › 规则：测试、规则链、自定义规则与规则集

import NetworkProxyKit
import SwiftUI

struct NetworkRulesTab: View {
    @ObservedObject var system: SystemProxyService
    @ObservedObject var metrics: ProxyMetricsService

    @State private var host = ""
    @State private var port = "443"
    @State private var result: ProxyRuleTester.Result?
    @State private var hits: [Int: Int] = [:]
    @State private var showAllRules = false

    var body: some View {
        VStack(spacing: 12) {
            tester
            chain
            customRules
            ruleSets
        }
        .task(id: metrics.live) { await loadHits() }
    }

    // MARK: - 规则测试

    private var tester: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: T("规则测试"), symbol: "checklist")
                HStack(spacing: 6) {
                    TextField(T("域名，例如 www.example.com"), text: $host)
                        .textFieldStyle(.roundedBorder).font(.system(size: 10.5))
                        .onSubmit(run)
                        .frame(maxWidth: .infinity)
                    TextField("443", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10.5, design: .monospaced))
                        .frame(width: 54)
                    NetworkQuietButton(title: T("测试"), tint: AuroraTheme.accent, action: run)
                        .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let result {
                    resultView(result)
                } else {
                    Text(T("按当前规则顺序算出这个域名会命中哪一条、最终走哪个策略。"))
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func run() {
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        result = system.testRule(host: address, port: Int(port) ?? 443)
    }

    private func resultView(_ result: ProxyRuleTester.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let match = result.match {
                HStack(spacing: 6) {
                    NetworkChip(text: originLabel(match.origin), tint: originTint(match.origin))
                    Text(match.line)
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(policyLabel(result.policy))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(policyColor(result.policy))
                }
            } else {
                Text(T("没有命中任何规则，将走直连。")).font(.system(size: 10.5))
            }
            if !result.skipped.isEmpty {
                Text(T("以下规则需要解析地址或真实进程，本地无法判断："))
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                ForEach(Array(result.skipped.prefix(4).enumerated()), id: \.offset) { _, item in
                    Text("· " + item.rule.line + " — " + item.reason)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - 规则链

    private var plan: [ProxyRuleEntry] { system.rulePlan() }

    private var chain: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: T("规则链"), symbol: "list.number")
                    Text("\(plan.count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(AuroraTheme.accent)
                    Spacer()
                    if system.profile.settings.mode != .rule {
                        Text(T("当前不是规则模式"))
                            .font(.system(size: 9.5)).foregroundStyle(AuroraTheme.warn)
                    }
                    NetworkQuietButton(title: showAllRules ? T("收起") : T("展开全部")) {
                        showAllRules.toggle()
                    }
                    Button {
                        Task { await loadHits() }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(T("刷新命中次数"))
                    .disabled(!metrics.live)
                }
                let visible = showAllRules ? plan : Array(plan.prefix(8))
                VStack(spacing: 2) {
                    ForEach(visible) { entry in
                        ruleRow(entry)
                    }
                }
                if plan.count > visible.count {
                    Text(TF("还有 %d 条，展开后可见", plan.count - visible.count))
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
                Text(T("顺序从上到下：自定义 → Tailscale → 政务域名 → 局域网 → 大陆 IP → 规则集 → 订阅规则 → 兜底。"))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func ruleRow(_ entry: ProxyRuleEntry) -> some View {
        HStack(spacing: 6) {
            Text(String(format: "%02d", entry.id + 1))
                .font(.system(size: 8.5, design: .monospaced)).foregroundStyle(.tertiary)
                .frame(width: 16, alignment: .trailing)
            NetworkChip(text: originLabel(entry.origin), tint: originTint(entry.origin), maxWidth: 72)
            Text(entry.line)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let hit = hits[entry.id], hit > 0 {
                Text(TF("%d 次", hit))
                    .font(.system(size: 8.5, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.025)))
    }

    // MARK: - 自定义规则

    private var customRules: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionLabel(text: T("自定义规则"), symbol: "square.and.pencil")
                    Spacer()
                    Text(T("DIRECT / REJECT / PROXY / TAILSCALE"))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                }
                TextEditor(text: $system.profile.settings.customRules)
                    .font(.system(size: 10.5, design: .monospaced))
                    .frame(height: 92)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
                Text(T("每行一条：DOMAIN-SUFFIX,example.com,PROXY。写错的行会在应用时被指出。"))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 规则集

    private var ruleSets: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: T("规则集"), symbol: "shippingbox")
                    Spacer()
                    Text(T("按地址定期更新"))
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                if system.profile.settings.ruleSets.isEmpty {
                    Text(T("还没有规则集。可以加一份 Clash 的 domain / ipcidr 规则，应用后写入内核。"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 3) {
                        ForEach(system.profile.settings.ruleSets) { set in
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(set.enabled ? AuroraTheme.ok : Color.primary.opacity(0.2))
                                    .frame(width: 5, height: 5)
                                Text(set.name).font(.system(size: 10.5)).lineLimit(1)
                                NetworkChip(text: set.direct ? T("直连") : T("代理"),
                                            tint: set.direct ? .secondary : AuroraTheme.accent, maxWidth: 56)
                                Spacer(minLength: 4)
                                Text(URL(string: set.url)?.host ?? set.url)
                                    .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                                Button {
                                    system.removeRuleSet(set.id)
                                } label: {
                                    Image(systemName: "trash").font(.system(size: 9))
                                }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.03)))
                        }
                    }
                }
                RuleSetEditor { name, url, behavior, direct in
                    system.addRuleSet(name: name, url: url, behavior: behavior, direct: direct)
                }
            }
        }
    }

    private func loadHits() async {
        guard metrics.live else { hits = [:]; return }
        let rules = await metrics.fetchRules()
        // 命中次数按内核里的规则序号对应本地计划。条数对不上（例如还在全局模式、
        // 或者订阅更新后没重新应用）就不显示，免得把别的规则的数字安到这一条上。
        guard rules.count == plan.count else { hits = [:]; return }
        var map: [Int: Int] = [:]
        for rule in rules { map[rule.index] = rule.hitCount }
        hits = map
    }

    private func originLabel(_ origin: ProxyRuleOrigin) -> String {
        switch origin {
        case .custom: return T("自定义")
        case .tailscale: return "Tailscale"
        case .builtin: return T("内置")
        case .lan: return T("局域网")
        case .mainland: return T("大陆")
        case .ruleSet: return T("规则集")
        case .subscription: return T("订阅")
        case .fallback: return T("兜底")
        }
    }

    private func originTint(_ origin: ProxyRuleOrigin) -> Color {
        switch origin {
        case .custom, .tailscale: return AuroraTheme.accent
        case .fallback: return AuroraTheme.warn
        case .mainland: return AuroraTheme.ok
        default: return .secondary
        }
    }

    private func policyLabel(_ policy: String) -> String {
        if policy == ProxyConfiguration.groupName { return T("代理") }
        if policy == ProxyConfiguration.tailscaleName { return "Tailscale" }
        if policy == "DIRECT" { return T("直连") }
        if policy == "REJECT" { return T("拒绝") }
        return policy
    }

    private func policyColor(_ policy: String) -> Color {
        if policy == "DIRECT" { return AuroraTheme.ok }
        if policy == "REJECT" { return AuroraTheme.danger }
        return AuroraTheme.accent
    }
}

private struct RuleSetEditor: View {
    @State private var name = ""
    @State private var url = ""
    @State private var behavior: ProxyRuleSet.Behavior = .domain
    @State private var direct = false
    @State private var editing = false
    var onAdd: (String, String, ProxyRuleSet.Behavior, Bool) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editing {
                HStack(spacing: 6) {
                    TextField(T("名称"), text: $name)
                        .textFieldStyle(.roundedBorder).font(.system(size: 10.5)).frame(width: 92)
                    TextField("https://rules.example.com/ad.yaml", text: $url)
                        .textFieldStyle(.roundedBorder).font(.system(size: 10.5))
                    Picker("", selection: $behavior) {
                        Text("domain").tag(ProxyRuleSet.Behavior.domain)
                        Text("ipcidr").tag(ProxyRuleSet.Behavior.ipcidr)
                        Text("classical").tag(ProxyRuleSet.Behavior.classical)
                    }
                    .labelsHidden().frame(width: 92)
                }
                HStack(spacing: 8) {
                    Toggle(T("命中直连"), isOn: $direct).toggleStyle(.switch).controlSize(.mini)
                        .font(.system(size: 10))
                    Spacer()
                    NetworkQuietButton(title: T("取消")) { editing = false }
                    NetworkQuietButton(title: T("添加"), tint: AuroraTheme.accent) {
                        if onAdd(name, url, behavior, direct) {
                            name = ""; url = ""; direct = false; editing = false
                        }
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            } else {
                NetworkQuietButton(title: T("新增规则集"), tint: AuroraTheme.accent) { editing = true }
            }
        }
    }
}
