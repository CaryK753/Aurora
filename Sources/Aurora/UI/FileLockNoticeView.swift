import SwiftUI

/// 第一次锁定前的说明，版式跟欢迎窗口同一套：透明标题栏、主色图标、左侧说明、底部主按钮。
struct FileLockNoticeView: View {
    var onContinue: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 22) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 78, height: 78)
                    .background(Circle().fill(Color.accentColor.opacity(0.12)))
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(T("锁定前先看一眼"))
                        .font(.system(size: 28, weight: .bold))
                    Text(T("锁定会把内容加密，原文从原来的位置拿掉。"))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 18) {
                    row("eye.slash", "打开后不要保存", "用原来的 App 打开，只能看到空白或乱码。保存会把密文盖掉，之后就解不开。")
                    row("lock.open", "解锁在右键菜单", "选中这一项，点「解锁」，再验证密码或 Touch ID。")
                    row("key", "密钥只在这台 Mac", "存在登录钥匙串里。换一台 Mac，或删掉这项，文件无法恢复。")
                    row("folder", "文件夹会变成文件", "锁定后它会显示成一个带锁的文件，解锁后恢复成文件夹。")
                }
                .frame(maxWidth: 500, alignment: .leading)
            }
            .padding(.horizontal, 40)
            .padding(.top, 32)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack(spacing: 12) {
                Button(T("取消")) { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(T("继续锁定")) { onContinue() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .frame(width: 640, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(T(title)).font(.body.weight(.semibold))
                Text(T(detail))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
