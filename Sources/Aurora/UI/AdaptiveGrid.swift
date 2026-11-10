//  AdaptiveGrid.swift
//  Aurora — 宽窗口下的卡片自适应排版
//
//  浮动面板（约 394pt 内容宽）保持单列；固定窗口拉宽后自动排成两列，
//  信息密度低的卡片不再各自占满一整行。

import SwiftUI

private struct AuroraContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 476 - 54 - 28  // 浮动面板的内容宽度
}

extension EnvironmentValues {
    /// 主内容区可用宽度（由 RootView 实时注入）
    var auroraContentWidth: CGFloat {
        get { self[AuroraContentWidthKey.self] }
        set { self[AuroraContentWidthKey.self] = newValue }
    }
}

struct AdaptiveCardGrid: View {
    @Environment(\.auroraContentWidth) private var width

    /// 可以参与两列排布的卡片
    let cards: [AnyView]
    /// 始终独占一整行的卡片（信息密集的列表类）
    let wide: [AnyView]

    init(cards: [AnyView], wide: [AnyView] = []) {
        self.cards = cards
        self.wide = wide
    }

    /// 两列的门槛：再窄就挤了
    private var isWide: Bool { width >= 660 }

    var body: some View {
        VStack(spacing: 12) {
            if isWide {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(cards.indices, id: \.self) { cards[$0] }
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(cards.indices, id: \.self) { cards[$0] }
                }
            }

            ForEach(wide.indices, id: \.self) { wide[$0] }
        }
    }
}
