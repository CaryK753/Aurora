import SwiftUI

struct SettingsModulesView: View {
    @ObservedObject var settings: SettingsService
    @State private var query = ""
    private let modules = AuroraModule.allCases.filter(\.isToggleable)

    var body: some View {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = modules.filter {
            term.isEmpty || $0.title.localizedStandardContains(term) || $0.rawValue.localizedStandardContains(term)
        }
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(T("侧边栏模块")).font(.headline)
                    Spacer()
                    Text(TF("已启用 %d / %d", modules.filter(settings.isEnabled).count, modules.count))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField(T("搜索模块"), text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(T("清除搜索"))
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                if matches.isEmpty {
                    EmptyHint(symbol: "magnifyingglass", text: T("没有匹配的模块"))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)], spacing: 8) {
                        ForEach(matches) { module in
                            Toggle(isOn: Binding(get: { settings.isEnabled(module) }, set: {
                                settings.setModule(module, enabled: $0)
                            })) {
                                Label(module.title, systemImage: module.symbol)
                                    .font(.subheadline)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .accessibilityLabel(module.title)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .padding(.horizontal, 9)
                            .frame(minHeight: 36)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                Text(T("关闭后隐藏模块，并停止鼠标、剪贴板、键盘清洁、节能和音量接管"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
