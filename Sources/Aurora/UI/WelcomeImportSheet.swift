//  WelcomeImportSheet.swift
//  Aurora — 欢迎页里的配置迁移（复用 ImportService 的扫描与落地逻辑）

import SwiftUI

struct WelcomeImportSheet: View {
    @ObservedObject var service: ImportService
    @ObservedObject var state: AppState
    var onClose: () -> Void

    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    ForEach(service.sources) { source in
                        sourceCard(source)
                    }
                    if service.sources.isEmpty {
                        Text(T("正在扫描已安装的工具…"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.top, 30)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.never)
            Divider()
            footer
        }
        .frame(width: 560, height: 470)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            service.scan(displays: state.display.displays)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: "arrow.down.doc", size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(T("从其他 App 导入配置"))
                    .font(.system(size: 15, weight: .semibold))
                Text(T("读取 Mos、LinearMouse、MonitorControl、RClick、Maccy 等工具的设置，转换成 Aurora 的对应项。只读取本地偏好，不会修改原 App。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                service.scan(displays: state.display.displays)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help(T("重新扫描"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private func sourceCard(_ source: ImportSource) -> some View {
        let selected = source.fields.filter(\.selected).count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                IconBadge(symbol: source.symbol, color: source.tint, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(source.name)
                            .font(.system(size: 12, weight: .semibold))
                        if source.detected {
                            Text(T("已安装"))
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(AuroraTheme.ok)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(AuroraTheme.ok.opacity(0.14)))
                        }
                    }
                    Text(source.detected ? source.subtitle : T("未检测到，可跳过"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(selected > 0 ? TF("已选 %d 项", selected) : T("无"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                AuroraToggle(isOn: Binding(
                    get: { selected == source.fields.count && !source.fields.isEmpty },
                    set: { on in service.toggleSource(source.id, selected: on) }
                ))
                .opacity(source.fields.isEmpty ? 0.35 : 1)
                .disabled(source.fields.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if expanded.contains(source.id) {
                VStack(spacing: 4) {
                    ForEach(source.fields) { field in
                        HStack(spacing: 8) {
                            Button {
                                service.toggle(field.id, in: source.id, selected: !field.selected)
                            } label: {
                                Image(systemName: field.selected ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 11))
                                    .foregroundStyle(field.selected ? AuroraTheme.accent : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            Text(field.title)
                                .font(.system(size: 10))
                            Spacer(minLength: 6)
                            Text(field.valueText)
                                .font(.system(size: 9, design: .rounded))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
        .overlay(alignment: .bottomTrailing) {
            if !source.fields.isEmpty {
                Button {
                    withAnimation(.smooth(duration: 0.18)) {
                        if expanded.contains(source.id) { expanded.remove(source.id) }
                        else { expanded.insert(source.id) }
                    }
                } label: {
                    Image(systemName: expanded.contains(source.id) ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .padding(.bottom, 6)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(service.selectableCount > 0 ? TF("已选择 %d 项", service.selectableCount) : T("暂无可导入项"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button(T("稍后再说")) { onClose() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Button(T("导入选中项")) {
                service.apply(state: state)
                state.showToast(T("配置已导入"), symbol: "arrow.down.doc.fill")
                onClose()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(service.selectableCount == 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}
