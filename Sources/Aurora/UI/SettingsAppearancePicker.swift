import SwiftUI

struct SettingsAppearancePicker: View {
    @Binding var selection: AppAppearance

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AppAppearance.allCases) { style in
                let selected = selection == style
                Button {
                    selection = style
                } label: {
                    VStack(spacing: 7) {
                        preview(style)
                            .frame(height: 35)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .accessibilityHidden(true)
                        HStack(spacing: 4) {
                            if selected { Image(systemName: "checkmark").font(.caption2.bold()) }
                            Text(style.title).font(.caption.weight(.medium))
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(selected ? Color.accentColor : .secondary.opacity(0.24), lineWidth: selected ? 2 : 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(style.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(T("外观"))
    }

    private func preview(_ style: AppAppearance) -> some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            let window = CGRect(x: bounds.width * 0.15, y: 6, width: bounds.width * 0.70, height: bounds.height)
            func draw(dark: Bool, in region: CGRect) {
                var part = context
                part.clip(to: Path(region))
                part.fill(Path(bounds), with: .color(dark ? Color(red: 0.17, green: 0.24, blue: 0.35) : Color(red: 0.80, green: 0.87, blue: 0.96)))
                part.fill(Path(roundedRect: window, cornerRadius: 4), with: .color(dark ? Color(white: 0.24) : .white))
                let ink = dark ? Color.white : Color.black
                part.fill(Path(CGRect(x: window.minX + 1, y: 7, width: window.width * 0.26, height: window.height)), with: .color(ink.opacity(0.08)))
                for i in 0..<2 {
                    let line = CGRect(x: window.minX + window.width * 0.34, y: 13 + CGFloat(i * 7),
                                      width: window.width * (i == 0 ? 0.46 : 0.29), height: 3)
                    part.fill(Path(roundedRect: line, cornerRadius: 1.5), with: .color(ink.opacity(0.24)))
                }
            }
            if style == .system {
                let halves = bounds.divided(atDistance: bounds.midX, from: .minXEdge)
                draw(dark: false, in: halves.slice)
                draw(dark: true, in: halves.remainder)
            } else { draw(dark: style == .dark, in: bounds) }
        }
    }
}
