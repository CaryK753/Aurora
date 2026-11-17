import SwiftUI

/// 与网络扩展页相同的胶囊选择控件，不依赖原生分段控件的固有宽度。
struct NetworkChoiceControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    var unavailable: Set<Value> = []

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let active = selection == option.0
                Button { selection = option.0 } label: {
                    Text(T(option.1))
                        .font(.system(size: 11, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            Capsule().fill(active ? AnyShapeStyle(AuroraTheme.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.05)))
                        }
                }
                .buttonStyle(.plain)
                .disabled(unavailable.contains(option.0))
                .opacity(unavailable.contains(option.0) ? 0.4 : 1)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }
}
