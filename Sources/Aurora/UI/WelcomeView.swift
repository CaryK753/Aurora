import SwiftUI

struct WelcomeView: View {
    @ObservedObject var state: AppState
    @State private var selection: Set<AuroraModule>
    @AppStorage("onboarding.step") private var step = 0
    @State private var showImport = false

    init(state: AppState) {
        self.state = state
        let saved = UserDefaults.standard.stringArray(forKey: "onboarding.draftModules")
        let initial = saved.map { $0.compactMap(AuroraModule.init(rawValue:)) } ?? state.settings.visibleModules
        _selection = State(initialValue: Set(initial.filter { $0 != .trackpad || state.trackpad.hasHardware }))
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if step == 0 { introduction }
                else {
                    VStack(spacing: 20) {
                        heading
                        if step == 1 { WelcomeModules(state: state, selection: $selection) }
                        else { WelcomePermissions(state: state, selection: selection) }
                    }
                    .padding(.horizontal, 44)
                    .padding(.top, 24)
                    .padding(.bottom, 20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 700, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: selection) { _, value in
            UserDefaults.standard.set(value.map(\.rawValue).sorted(), forKey: "onboarding.draftModules")
        }
        .onAppear {
            step = min(max(step, 0), 2)
            state.permissions.recheck()
        }
        .sheet(isPresented: $showImport) {
            WelcomeImportSheet(service: state.imports, state: state) {
                showImport = false
            }
        }
    }

    private var introduction: some View {
        VStack(spacing: 24) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high).frame(width: 104, height: 104)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text(T("欢迎使用 Aurora")).font(.system(size: 32, weight: .bold))
                Text(T("让 Mac 更顺手，从这里开始。"))
                    .font(.title3).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 22) {
                benefit("slider.horizontal.3", "常用工具，一处管理", "显示、鼠标、触控板与声音，都在菜单栏中。")
                benefit("hand.raised", "按需选择，由你掌控", "只启用需要的模块，权限也可稍后设置。")
                benefit("arrow.down.doc", "沿用熟悉的配置", "从已安装的参考工具迁移兼容设置。")
            }
            .padding(.top, 10)
            .frame(maxWidth: 460, alignment: .leading)

            Button {
                showImport = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 12, weight: .semibold))
                    Text(T("从其他 App 导入配置"))
                        .font(.system(size: 12.5, weight: .medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background {
                    Capsule().fill(Color.accentColor.opacity(0.12))
                }
                .overlay {
                    Capsule().strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 0.8)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .padding(40)
    }

    private func benefit(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: symbol).font(.system(size: 26, weight: .regular))
                .foregroundStyle(Color.accentColor).frame(width: 38).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(T(title)).font(.body.weight(.semibold))
                Text(T(detail)).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var heading: some View {
        VStack(spacing: 10) {
            Image(systemName: step == 1 ? "square.grid.2x2" : "hand.raised")
                .font(.system(size: 36, weight: .regular)).foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(step == 1 ? T("选择你的工具") : T("允许需要的访问"))
                .font(.system(size: 26, weight: .bold))
            Text(step == 1 ? T("先用默认选择，或按习惯调整。随时可以更改。") : T("了解用途后再授权，也可以直接开始使用。"))
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(T("稍后设置")) { finish(apply: false) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 7) {
                ForEach(0..<3) { index in
                    Circle().fill(step == index ? Color.accentColor : Color.secondary.opacity(0.25)).frame(width: 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(T("设置步骤"))
            .accessibilityValue("\(step + 1) / 3")
            Spacer()
            if step > 0 { Button(T("返回")) { withAnimation(.easeInOut(duration: 0.18)) { step -= 1 } } }
            Button(step == 2 ? T("开始使用") : T("继续")) {
                if step < 2 { withAnimation(.easeInOut(duration: 0.18)) { step += 1 } }
                else { finish(apply: true) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
    }

    private func finish(apply: Bool) {
        if apply {
            for module in AuroraModule.allCases where module.isToggleable {
                state.settings.setModule(module, enabled: selection.contains(module))
            }
        }
        UserDefaults.standard.set(true, forKey: "onboarding.completed")
        UserDefaults.standard.removeObject(forKey: "onboarding.draftModules")
        // 新用户刚看完介绍，不必再叠一个「新功能」窗口
        ReleaseNotesStore.markSeen()
        step = 0
        state.showWelcome = false
        // 「开始使用」→ 立刻从菜单栏把主面板弹出来；「稍后设置」不弹
        if apply { state.presentMainPanel() }
    }
}
