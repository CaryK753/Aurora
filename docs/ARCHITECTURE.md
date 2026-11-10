# 架构与实现

本文记录 Aurora 的实现路线、踩过的坑与已知限制。安装与使用见 [README](../README.md)。

## 面板与视觉

- 面板是 `NSPanel(.borderless, .nonactivatingPanel, .fullSizeContentView)`，背景为 `NSGlassEffectView`，SwiftUI 内容通过 `TransparentHostingView` 叠在玻璃之上；卡片用半透明填充加高光描边做次级层，避免多层玻璃互相折射发浑。
- 面板层级为 `CGWindowLevelForKey(.popUpMenuWindow)`，所以所有确认弹窗都要再抬一层（`ConfirmationAlerts.swift` 统一处理），否则会被压在面板下面。
- `nonactivatingPanel` 让点击面板不会抢走前台应用的焦点；代价是窗口离开边界后 SwiftUI 的拖动手势会断，侧栏排序因此改用原生 `NSDraggingSession`。
- 明暗主题由 `NSApp.appearance` 控制，卡片填充与描边按 `colorScheme` 反转；配色只保留一个主色（`#5FC9FF → #2B8CE8`），绿 / 琥珀 / 红只用于状态。
- 顶部标题栏用 `.ultraThinMaterial` + 下沿渐隐 mask，配合 `.scrollEdgeEffectStyle(.soft, for: .top)`，内容从栏下柔和淡出。

## 各模块技术路线

| 模块 | 关键实现 |
| --- | --- |
| 显示 | `dlopen` 运行时解析 `DisplayServicesGet/SetBrightness`、`IOAVServiceWrite/ReadI2C`（DDC/CI，含校验和与重试）；`CGConfigureDisplayWithDisplayMode` 切分辨率；亮度切换用 12 帧 easeOutCubic 过渡 |
| 屏幕检测 | 每块屏幕一个无边框 `ScreenTestWindow`（覆写 `canBecomeKey` 才能收到 ESC），层级 `screenSaverWindow`；坏点图用 `TimelineView` 让白点移动找卡死像素 |
| 鼠标 | `CGEventTap`（`.cgSessionEventTap`，headInsert）改写位移与滚轮 delta；平滑滚动把行事件换算成像素后交给 120Hz `DispatchSourceTimer` 按一阶惯性逐帧 post `.pixel` 事件，并用 `eventSourceUserData` 标记自己的事件避免回环；侧键按下与抬起成对拦截 |
| 触控板 | 读写 `com.apple.AppleMultitouchTrackpad` 等域的系统偏好 |
| 键盘 | IOKit `IOHIDDevice` 枚举；键盘类型写 `/Library/Preferences/com.apple.keyboardtype.plist`（`ProductID-VendorID-0` → 40/41/42 = ANSI/ISO/JIS）；清洁模式是独立的事件 tap，唯一解锁手势为 ⌃⌥⌘K |
| 菜单 | 自定义项由 FinderSync 扩展 `AuroraFinder.appex` 提供；扩展在沙盒里不能起进程、不能跨目录写盘，动作被写成 `requests/<uuid>.json` 请求文件，主 App 每秒扫描并执行 |
| 剪贴板 | `NSPasteboard.changeCount` 轮询；图片与 RTF 落盘，历史存 `~/Library/Application Support/Aurora/clipboard.json`；`IsSecureEventInputEnabled()` 期间暂停记录 |
| 节能 | `IOPMAssertionCreateWithName`（`PreventUserIdleSystemSleep` / `PreventUserIdleDisplaySleep`）+ 计时器 |
| 声音 | CoreAudio HAL：设备列表、默认设备、`VolumeScalar` / `Mute` |
| 按应用音量 | `CATapDescription`（`muteBehavior = .muted`）→ `AudioHardwareCreateProcessTap` → 私有聚合设备读 PCM（`AudioDeviceCreateIOProcIDWithBlock`）→ AUHAL 渲染回调乘增益送回当前输出设备；增益逐帧平滑，超过 100% 做硬限幅，100% 时完全不介入 |
| AI 用量 | 只读本地数据：`~/.codex/sessions/**/*.jsonl`（`token_count` 增量 + `rate_limits` 配额窗口）、`~/.claude/projects/**/*.jsonl`（`message.usage`）、`~/.local/share/opencode/opencode.db`（SQLite JSON1 聚合）、`~/.workbuddy/workbuddy.db`（`session_usage`）；桌面客户端只做安装检测并如实说明原因 |
| 资源 | `host_processor_info`、`host_statistics64`、`getifaddrs`、IOPS、`proc_pid_rusage`；GPU 读 `IOAccelerator.PerformanceStatistics`；磁盘读写取 `IOBlockStorageDriver.Statistics` 差分；电池健度与循环读 `AppleSmartBattery` 注册表；进程网络用 `nettop -x -L 1` 采样 |
| 外部设备 | `system_profiler SPBluetoothDataType / SPUSBDataType -json`，iPhone / iPad 型号走 `xcrun devicectl list devices` 并缓存 5 分钟 |
| 更新 | GitHub Release API → 版本比较 → 下载 zip → `ditto` 解包 → 询问 → shell 脚本等本进程退出后替换并重启 |

## 进程列表怎么取数

- **图标**：`NSRunningApplication(processIdentifier:).icon`；取不到（守护进程、命令行工具）就画一个主色波形徽标占位，缓存按 pid 失效。
- **CPU / 内存**：`proc_pid_rusage`（CPU 时间差分）与 `ri_phys_footprint`，约 1.2 秒一次。
- **网络**：只在切到「网络」指标时启动 `nettop` 采样，离开即停，避免常驻开销。
- **GPU**：系统只暴露整卡数据（`IOAccelerator`），没有按进程的占用，因此 GPU 页只显示整卡并明确说明。

## 签名与权限

`build.sh` 默认优先使用固定证书（`AURORA_SIGN_ID`），没有就退回 ad-hoc。

> TCC（辅助功能 / 屏幕录制 / 输入监控 / 完全磁盘访问）按「签名 + bundle id」记录授权。ad-hoc 每次重建 cdhash 都会变，于是出现「系统设置里明明勾上了，应用内仍显示未授权」。

`Resources/Aurora.entitlements` 保留 `audio-input` 与 `apple-events`，供按应用音量与自动化动作使用。

## Finder 扩展

- 手工编译：`swiftc -e _NSExtensionMain` 直接产出 appex，不需要 Xcode 工程。
- macOS 26 的 pkd 只接受 `com.apple.security.app-sandbox` 为真的 appex（不沙盒时 `pluginkit -a` 返回 0 但 `-m` 查不到）；而 `com.apple.application-identifier` / `com.apple.developer.team-identifier` 需要描述文件，签进去后 Finder 拉不起进程。二者只能取交集：**沙盒 + 用户选择文件读写，不带 application-identifier**。
- 注册自己做：每次启动跑 `lsregister -f` + `pluginkit -a` + `pluginkit -e use`。
- 日志：`~/Library/Containers/com.cary.aurora.finder/Data/Library/Application Support/Aurora/finder-ext.log`；主 App 的登记结果在 `~/Library/Application Support/Aurora/finder-diag.log`。
- 系统设置里的位置是「通用 › 登录项与扩展 › 文件提供程序」，也可以切到「按应用」查找 Aurora；叫「Finder」的那栏是快速操作。

## i18n

中文原文作为 key，英文查表（`Localization.swift` 与 `ModuleTranslations.swift`）。系统语言为英文时默认英文，可以在「设置 › 语言」即时切换。插值文案统一走 `TF("格式化串", 参数)`。

> 词条是用字典字面量声明的，重复 key 会让应用在启动时直接崩溃（`Dictionary literal contains duplicate keys`），加词条后务必去重。

## 自检

音频相关自检默认使用**听不见的音源**：一个只输出 ±1 LSB 噪底（约 -90 dBFS）的 WAV，交给 `afplay` 播放。它同样会被注册成「正在发声」的进程、tap 也能捕获，但扬声器完全没有声音；需要真声音时才加 `AURORA_LOUD_SOURCE=1`。

## 已知限制

- **神经网络引擎**：Apple 未开放 ANE 利用率遥测，当前只显示「可用 / 不可用」，不虚构占用率。
- **按进程 GPU 占用**：无公开 API，只提供整卡数据。
- **按应用音量**：依赖 macOS 14.2+ 的进程 tap，被接管的 App 声音会经 Aurora 重混（几十毫秒缓冲）；100% 时完全走原生通路。
- **外接屏亮度**：需要显示器支持 DDC/CI。
- **键盘类型**：写入 `/Library/Preferences` 需要管理员密码，且要重连键盘或重新登录才生效。
- **自定义右键菜单**：扩展必须沙盒化，因此落盘与 shell 动作要委托主 App，主 App 没运行时会自动拉起。
- 同时开启 Mos / LinearMouse 会产生叠加效果，建议只保留一个滚轮接管。
