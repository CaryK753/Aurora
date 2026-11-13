# 存储清理模块评估

> 目标：判断「磁盘清理」是否值得作为 Aurora 的独立模块，以及如果要做得基于/参考什么。

## 候选项目（2026-11 核对）

| 项目 | 语言 / 形态 | 许可证 | 规模 | 能力 | 能否直接复用 |
| --- | --- | --- | --- | --- | --- |
| [PureMac](https://github.com/momenbasel/PureMac) | Swift / SwiftUI 原生 App | MIT | ~7.7k★，活跃 | 系统缓存、Xcode / Homebrew 缓存、App 卸载 + 残留、重复文件、定时清理、零遥测 | ✅ 可复用（保留版权声明） |
| [Mole](https://github.com/tw93/mole) | Bash + Go，CLI/TUI | GPL-3.0 | ~68k★，非常活跃 | 深度清理、卸载、磁盘分析、构建产物、系统监控、dry-run、白名单、操作日志 | ❌ GPL 不可嵌入；只能作参考或"已安装则调用" |
| [Pearcleaner](https://github.com/alienator88/Pearcleaner) | Swift / SwiftUI | Apache 2.0 + Commons Clause（非 OSI） | ~14.7k★，维护暂缓 | 以 App 卸载与残留扫描为主 | ❌ 许可与定位都不合适 |
| [GrandPerspective](https://grandperspectiv.sourceforge.net/) | Objective-C | GPL-2.0 | 老牌 | 只做磁盘占用树图（read-only） | ❌ GPL；树图可自己实现 |
| [czkawka](https://github.com/qarmin/czkawka) | Rust / GTK | MIT | 大 | 重复文件、相似图片、大文件 | ⚠️ 语言不通，但算法与判定规则可借鉴 |

## 结论：值得做，但要换一种做法

**值得**，原因有三：

1. Aurora 已经是「菜单栏 Mac 工具箱」，清理是用户最常提的诉求，而现有模块（显示/鼠标/声音/节能）都不解决"磁盘红了"。
2. 这个方向有成熟且**许可证友好**的参考：PureMac 是 MIT + SwiftUI，和 Aurora 技术栈几乎一致，可以合法借鉴扫描路径、安全策略与交互。
3. macOS 的存储面板只覆盖一半场景（iCloud、废纸篓、大文件），开发者缓存、App 残留、构建产物这些真正的大头它不碰。

**不要照搬**：

- Mole 的 GPL 代码不能进 Aurora（会把整个项目拖成 GPL），它的 `optimize`（重建索引 / 清理 swap）在社区有 WindowServer 崩溃报告，属于高风险动作，不值得复刻。
- Pearcleaner 是 source-available 而非开源，且项目暂缓维护。
- 任何"一键优化 / 一键加速"的叙事都不适合 Aurora 的克制风格。

## 建议范围（分两期）

### 第一期：只读体检（零风险，已足够有用）

- 磁盘占用树图 / 条形排行（自绘，不引入 GrandPerspective）。
- 大文件与"很久没动过"的文件清单（按大小、时间排序）。
- 缓存与构建产物**盘点**：Xcode DerivedData / DeviceSupport、node_modules、Python、Rust target、Homebrew 缓存、Docker、Simulator。
- App 残留盘点：已删除 App 留下的 Application Support / Preferences / Caches / LaunchAgents。
- 全部只读，展示"可回收 X GB"，不提供删除按钮。

### 第二期：安全清理

- 只允许在**白名单根目录**下操作；`/`、`/System`、`/usr`、`/bin` 一律拒绝。
- 默认走废纸篓（`NSWorkspace.recycle`），不做 `rm -rf`；提供"放回原处"。
- 先出 dry-run 清单（路径 + 大小 + 最近访问时间），逐项勾选后才执行。
- 30 天未使用才允许判定为"残留"；符号链接先解析目标再判断。
- 每次操作写本地日志，便于回溯。

### 明确不做

- 系统数据库重建、swap 清理、LaunchServices 重建。
- 需要 root 的操作。
- 安全/杀毒类功能。

## 与现有模块的关系

- 复用 `SystemMonitor` 的磁盘容量数据做首页概览。
- 复用 `AppState` 的模块开关与 Toast，新增 `AuroraModule.storage`。
- 清理结果可回到「概览」显示本次回收空间。

## 实现记录（v1.4 第一版）

**取舍变了**：不一定要"原生 SwiftUI 项目才能借鉴"。CLI 工具本身很强，SwiftUI 只要套一层壳就能用，
所以最终做法不是搬某个 App 的代码，而是**原生实现 + CLI 增强**：

| 层 | 做法 |
| --- | --- |
| 统计 | `/usr/bin/du -skx`（进程内调，比 Swift 枚举快一个数量级）；体积未知时退回 `FileManager` |
| 清理 | `FileManager.trashItem`，只搬白名单目录里的**子项**，目录本身保留，App 不会因缺目录报错 |
| 外部 CLI | `brew` / `docker` / `mole` / `ncdu` / `mas` 只做**检测**；有就显示入口，「在终端运行」交给用户确认 |
| 许可 | 不打包任何 GPL 二进制（Mole 等），只调用用户自己装好的命令，避免传染 |

这样既拿到了 CLI 的能力，又保住了三件事：**可核对**（每一项都能在访达里看见）、
**可回退**（进废纸篓而不是删掉）、**不越界**（Aurora 不代跑破坏性命令）。

### 已实现（只读盘点 + 安全清理）

- 磁盘占用条：已用 / 可用 / 总计；扫描完成给出「约 X 可回收」。
- 可清理项：用户缓存、日志与诊断报告、Xcode 派生数据、模拟器缓存、Homebrew 缓存（可安全回收）；
  Xcode 设备支持文件、废纸篓（需确认）。
- 只读盘点：iOS 设备备份、Xcode 归档、Docker 可回收空间——只显示体积与"在访达中显示"，不提供删除。
- 大文件：下载 / 桌面 / 文档 / 影片里超过 1GB 的文件，可单个移到废纸篓。
- 每次清理写 `~/Library/Logs/Aurora/storage.log`。
- 没有「完全磁盘访问」时，页面顶部直接说明统计会不完整，并给出跳转。

### 还没做

- 占用树图（treemap）与"很久没动过"的时间维度。
- App 残留扫描（卸载后遗留的 Application Support / LaunchAgents）。
- node_modules / Rust target 这类项目目录盘点（需要用户指定根目录）。

## 第二版：通用二进制 / 应用管理 / 开发环境

存储页拆成三个分页（清理 / 应用 / 开发），因为一屏塞不下这么多信息。

### 通用二进制

- 直接读 Mach-O fat header（`Core/MachO.swift`），比 `lipo -info` 快，也不用起进程。
- 只算「Intel 那一份」的体积；主程序 + `Contents/Frameworks/*.framework` 一起统计。
- 瘦身 = `lipo -thin arm64` + `codesign --force --deep -s -`（有 entitlements 就带上）。
  任何一步失败都会把备份的原二进制换回去，最后再用 `codesign --verify` 把关。
- **拦下来的**：App Store 应用（有 `_MASReceipt`）、沙盒应用（重签后基本起不来）。
- **提示但允许的**：带 `com.apple.application-identifier` / keychain groups 的应用（重签后可能要重新登录）。
- 自检 `--universal-thin-test`：造一个双架构假 App，走完扫描 → 瘦身 → 验签，实测通过。

### 应用管理

- 与 Pearcleaner / PureMac 同一个思路，代码自己写：列应用的体积、版本、最近使用时间；
  卸载前扫 11 个位置（Caches / Preferences / Application Support / Saved Application State /
  HTTPStorages / WebKit / Logs / LaunchAgents / Containers / Group Containers / Application Scripts）。
- 残留匹配只认 bundle id 命中或「完全同名目录」，宁缺毋滥。
- 卸载 = 应用本体 + 勾选的残留一起 `trashItem`；`com.apple.*` 与 `/System` 直接拒绝。
- 自检 `--app-uninstall-test`：假 App + 假残留，验证两者都进废纸篓。

### 开发环境

- 13 类包管理器缓存（npm / pnpm / Yarn / pip / Cargo / Go build+mod / Gradle / Maven /
  CocoaPods / SwiftPM / pub / Android AVD），路径固定，`du` 量体积，常规 trashChildren 清理。
- 项目产物：在 ~/Developer、~/Projects、~/Code、~/dev、~/Desktop、~/Documents 下
  `find -maxdepth 5` 找 node_modules / target / .build / Pods / .next，小于 8MB 的不列。
  清理是「整个目录移走」，不是清空内容。

## 依赖与体积：没有把 CLI 打包进来

经常被问「存储模块是不是把 du / Mole 这些打包进 Aurora 了」，答案是没有：

- 打包产物只有 `Contents/MacOS/Aurora`、`Contents/PlugIns/AuroraFinder.appex`、
  `Resources/AppIcon.icns` 与 `Resources/DeviceFrames/`，整个 .app 约 21 MB。
- 统计与清理只调用**系统自带**命令：`/usr/bin/du`、`/usr/bin/find`、`/usr/bin/mdls`、
  `/usr/bin/lipo`、`/usr/bin/codesign`。`CommandRunner.locate` 只在
  `/usr/bin`、`/bin`、`/usr/sbin`、`/sbin` 和 Homebrew 目录里查找系统命令。
- `brew` / `docker` / `mole` / `ncdu` / `mas` 只做「装没装」的探测，
  装了就在界面上给一个「在终端运行」入口，命令由用户自己的终端执行。
- 因此：卸载 Aurora 不会带走任何命令行工具，也不存在 GPL 二进制随包分发的问题。

新增的批量能力：通用二进制支持真实应用图标、逐项勾选与全选，
批量瘦身按体积从大到小串行执行，运行中的应用跳过，失败项单独列出且不影响其余项。
