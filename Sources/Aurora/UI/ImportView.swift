//  ImportView.swift
//  Aurora — 配置迁移：从已安装的同类工具一键导入

import SwiftUI

struct ImportView: View {
    @ObservedObject var service: ImportService
    @ObservedObject var state: AppState

    init(state: AppState) {
        self.state = state
        self.service = state.imports
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    ForEach(service.sources) { source in
                        sourceCard(source)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.never)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Button {
                withAnimation(.smooth(duration: 0.22)) { state.showImport = false }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(T("配置迁移"))
                    .font(.system(size: 13, weight: .semibold))
                Text(T("从同类工具导入已有设置"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                service.scan(displays: state.display.displays)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(T("重新扫描"))
        }
        // 固定窗口下左上角是红绿灯，顶栏内容往右让
        .padding(.leading, state.isPinned ? 76 : 14)
        .padding(.trailing, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func sourceCard(_ source: ImportSource) -> some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    IconBadge(symbol: source.symbol, color: source.tint, size: 26)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.name)
                            .font(.system(size: 12, weight: .semibold))
                        Text(source.subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    if source.detected {
                        if source.fields.isEmpty {
                            Text(T("暂无可迁移项"))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                        } else {
                            Text("\(source.fields.filter(\.selected).count)/\(source.fields.count)")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(AuroraTheme.ok)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(AuroraTheme.ok.opacity(0.12)))
                        }
                    } else {
                        Text(T("未检测到"))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.04)))
                    }
                }

                if !source.fields.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(source.fields) { field in
                            fieldRow(field, sourceID: source.id)
                        }
                    }
                } else if !source.detected {
                    Text(T("未检测到配置文件 · 安装并运行过该应用后可导入"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }

                if let note = source.note {
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .opacity(source.detected ? 1 : 0.55)
    }

    private func fieldRow(_ field: ImportField, sourceID: String) -> some View {
        HStack(spacing: 8) {
            Button {
                service.toggle(field.id, in: sourceID, selected: !field.selected)
            } label: {
                Image(systemName: field.selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(field.selected ? AuroraTheme.accent : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(field.title)
                    .font(.system(size: 10.5, weight: .medium))
                Text(field.detail).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(2)
                Text("→ \(field.targetText)")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(field.valueText)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.8))
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .opacity(field.selected ? 1 : 0.6)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(service.selectableCount > 0 ? TF("已选择 %d 项", service.selectableCount) : T("暂无可导入项"))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            Spacer()
            Button(T("一键导入")) {
                service.apply(state: state)
                withAnimation(.smooth(duration: 0.22)) { state.showImport = false }
            }
            .buttonStyle(SoftButtonStyle(prominent: true))
            .disabled(service.selectableCount == 0)
            .opacity(service.selectableCount == 0 ? 0.4 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.06)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}
