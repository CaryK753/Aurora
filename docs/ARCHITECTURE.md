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
| 网络 | 两种实现共用一套订阅与规则：`NetworkProxyKit` 解析订阅 / 生成 mihomo 配置 / 维护内核清单，`SystemProxyService` 负责系统配置事务与生命周期；有 NE 授权时改走 `AuroraTunnel`（`NETransparentProxyProvider` + TCP relay） |
| 文件锁 | `FileLockService`：AES-GCM 1MB 分块流式加解密，密钥 `SecItem` 存登录钥匙串，`LAContext` 验证身份；锁后文件头写 `AURL`、文件夹打成 `AURD` 归档，解锁还原目录树 |

## 进程列表怎么取数

- **图标**：`NSRunningApplication(processIdentifier:).icon`；取不到（守护进程、命令行工具）就画一个主色波形徽标占位，缓存按 pid 失效。
- **CPU / 内存**：`proc_pid_rusage`（CPU 时间差分）与 `ri_phys_footprint`，约 1.2 秒一次。
- **网络**：只在切到「网络」指标时启动 `nettop` 采样，离开即停，避免常驻开销。
- **GPU**：系统只暴露整卡数据（`IOAccelerator`），没有按进程的占用，因此 GPU 页只显示整卡并明确说明。

## 签名与权限

`build.sh` 默认优先使用固定证书（`AURORA_SIGN_ID`），没有就退回 ad-hoc。

> TCC（辅助功能 / 屏幕录制 / 输入监控 / 完全磁盘访问 / 摄像头）按签名的**指定要求**记录授权：
> ad-hoc 签名的指定要求是 `cdhash H"…"`（`codesign -d -r-` 可查），每次重建都会变，于是出现「系统设置里明明勾上了，应用内仍显示未授权」；换一个版本更新后更是全部失效。用固定证书签名时指定要求跟着证书（`certificate leaf[subject.CN] = "…"`）走，跨版本稳定。

Release 工作流（`.github/workflows/release.yml`）从仓库 Secrets 取证书，导入一个临时钥匙串再打包：

| Secret | 内容 |
| --- | --- |
| `AURORA_CERT_P12` | 证书与私钥导出的 p12，base64 后的一行 |
| `AURORA_CERT_PASSWORD` | 上面 p12 的导出密码 |
| `AURORA_SIGN_ID` | 证书全名，如 `Apple Development: name@example.com (XXXXXXXXXX)` |

步骤要点：`security create-keychain` → `import -T /usr/bin/codesign` → `set-key-partition-list`（不加这步 codesign 取私钥会被拦）→ `list-keychains -s` 把临时钥匙串塞进搜索列表（`build.sh` 靠 `find-identity` 认证书）→ 打包 → `always()` 里删除钥匙串。没配 Secrets 时工作流只告警并退回 ad-hoc，fork 出去也能跑通。

重新导出证书（证书续签后要重做）：

```bash
security export -t identities -f pkcs12 -k ~/Library/Keychains/login.keychain-db -o aurora.p12 -P '<密码>'
base64 -i aurora.p12 | gh secret set AURORA_CERT_P12
gh secret set AURORA_CERT_PASSWORD --body '<密码>'
```

`Resources/Aurora.entitlements` 保留 `audio-input` 与 `apple-events`，供按应用音量与自动化动作使用。

## Finder 扩展

- 手工编译：`swiftc -e _NSExtensionMain` 直接产出 appex，不需要 Xcode 工程。
- macOS 26 的 pkd 只接受 `com.apple.security.app-sandbox` 为真的 appex（不沙盒时 `pluginkit -a` 返回 0 但 `-m` 查不到）；而 `com.apple.application-identifier` / `com.apple.developer.team-identifier` 需要描述文件，签进去后 Finder 拉不起进程。二者只能取交集：**沙盒 + 用户选择文件读写，不带 application-identifier**。
- 注册自己做：每次启动跑 `lsregister -f` + `pluginkit -a` + `pluginkit -e use`。
- 日志：`~/Library/Containers/com.cary.aurora.finder/Data/Library/Application Support/Aurora/finder-ext.log`；主 App 的登记结果在 `~/Library/Application Support/Aurora/finder-diag.log`。
- 系统设置里的位置是「通用 › 登录项与扩展 › 文件提供程序」，也可以切到「按应用」查找 Aurora；叫「Finder」的那栏是快速操作。

## 网络代理

- **两条实现路线**：没有 Apple 网络扩展授权（`NetworkSigningCapability` 同时校验证书信任与 `com.apple.developer.networking.networkextension`）就只走系统代理；有授权且构建时传了 `AURORA_NE_PROFILE` 才打 `AuroraTunnel.systemextension`。没有授权却把 entitlement 签进主程序，系统会直接杀掉进程。
- **内核不随包**：`ProxyEngineRelease` 固定 `v1.19.34` 与两个架构的 SHA-256，`ProxyEngineInstaller` 下载 → 校验 → 解压 → 跑一次 `-v` 确认可执行 → 原子替换。直连模式完全不碰内核。
- **应用前验证链**：`ProxyEngineRuntime.start` 轮询进程存活 → `ProxyLocalProbe` 用 `lsof` 核对 `127.0.0.1:<port>` 属于该 pid → SOCKS greeting → `fetch generate_204`。全过才 `SystemProxyPreferences.apply`。
- **系统配置事务**：`SCPreferences` 按服务路径写 `/NetworkServices/<id>/Proxies`，写前把 original / applied 一起存进 `UserDefaults`（重启也能恢复）。`restore()` 会先比对当前值是否仍等于 applied，外部改过就抛错而不是覆盖。
- **生命周期**：`applicationShouldTerminate` 返回 `.terminateLater`，先 `restoreForTermination()`；内核意外退出由 `onUnexpectedExit` 触发恢复。规则模式的大陆地址库是 APNIC 数据转成的 `ipcidr` rule-provider（文件形式，7 天缓存）。

## 文件锁

- 只加密内容，不改权限位：权限位挡不住文件主人，把明文挪走才是真保护。
- 1 MB 分块、每块独立 AEAD（AAD 带块序号与类型），大文件不会一次性读进内存；超过 8 GB 直接拒绝。
- 密钥不用带 `userPresence` 的数据保护钥匙串（需要 `keychain-access-groups` 描述文件，当前签名拿不到，`SecItem` 会返回 -34018），改用登录钥匙串 + `LAContext` 自行验证；菜单栏应用是 accessory，弹系统验证前要临时切成 `.regular`，否则窗口不出现。
- 先写同目录临时密文再 `swap`（备份 → 替换 → 失败回滚），避免中途失败留下半个文件；文件夹先打成归档再整体加密。
- 锁后图标由未沙盒的主 App 设置（扩展只能读文件头，改不了自定义图标），路径来自扩展写的 `lock-icons.txt`，主 App 会重新校验。

## i18n

中文原文作为 key，英文查表（`Localization.swift` 汇总 `ModuleTranslations.swift` / `FeatureTranslations.swift` / `NetworkProxyTranslations.swift`）。系统语言为英文时默认英文，可以在「设置 › 语言」即时切换。插值文案统一走 `TF("格式化串", 参数)`。

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
- **系统代理**：只影响遵循系统代理设置的应用，不接管 UDP 与系统 DNS（不改 macOS DNS），内核固定监听 `127.0.0.1`、不开 TUN。
- **网络扩展**：必须带 `app-proxy-provider-systemextension` 描述文件（要开发者计划），这一版只接管 TCP；Tailscale 组网未实现，界面不提供占位按钮。
- **文件锁**：钥匙串条目丢失或换机即不可恢复；用原 App 打开密文后保存会毁掉密文；8 GB 上限。
- 同时开启 Mos / LinearMouse 会产生叠加效果，建议只保留一个滚轮接管。
