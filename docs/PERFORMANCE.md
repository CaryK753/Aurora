# Aurora 性能与资源占用评测

> 版本 1.3.0 (130) · macOS 27.2.1 (26B131) · Apple Silicon 11 核 · 双屏（1512×982 + 1920×1080）
> 评测时间 2026-11-12 · 全部数据来自真实进程采样，非估算

## 一、测量方法

`ps` / `top` 在当前沙箱下不可用，因此用 `proc_pid_rusage` 写了两个小工具：

- **pmeter**：每 0.5s 读一次 `rusage_info_v4`，给出 CPU%（user+sys 差分）、`phys_footprint`、
  线程数、**每秒唤醒次数**（`ri_pkg_idle_wkups + ri_interrupt_wkups`）。唤醒次数比 CPU% 更能
  反映耗电，是笔记本续航的头部指标。
- **sysmeter**：`host_processor_info` 读整机 CPU。
- 交叉验证：`footprint(1)`、`vmmap -summary`、`sample(1)` 调用图、`CGWindowListCopyWindowInfo`
  确认窗口是否真的在屏、`ioreg` 读 GPU 利用率、`screencapture` 截图佐证界面状态。

结论的可信度：CPU 与 footprint 由两个独立来源交叉验证一致；唤醒次数与 `sample` 的调用图一致
（两者都指向同一个 60fps 显示周期）。

## 二、静态体积

| 项目 | 数值 |
| --- | --- |
| 应用包总大小 | **31 MB** |
| 主二进制（universal） | 26 MB（单架构 13 MB） |
| 其中 `__TEXT` | 4.3 MB（`__text` 3.3 MB） |
| 其中 `__LINKEDIT` | **8.6 MB**（含 96 491 条符号，未 strip） |
| Finder 扩展 | 273 KB |
| `DeviceFrames/` | **4.5 MB**（6 张 PNG，单张最大 1.0 MB，未压缩优化） |
| 图标 | 674 KB |
| 源码规模 | 111 个文件 / 30 856 行 |
| 第三方依赖 | **0**（全部系统框架） |

包体没有失控，但有两处明显可省：`__LINKEDIT` 里 8.6 MB 符号（发布包可 `strip -x`）、
`DeviceFrames` 4.5 MB 的原始 PNG（转 HEIC 或按需下采样）。两项合计可把 31 MB 压到 20 MB 左右。

## 三、运行时数据

| 场景 | CPU | 唤醒/秒 | footprint | 线程 |
| --- | --- | --- | --- | --- |
| 空载（面板收起、无窗口在屏） | **0.14%** | 17 | 90–190 MB¹ | 6–7 |
| **面板在屏（静止不动）** | **1.14–1.17%** | **110–132** | 240 MB | 7–8 |
| 桌面模块（卡片彩虹动画） | 0.70% | — | 226 MB | 7 |
| 剪贴板模块 | 0.13% | 17 | 236 MB | 7 |
| 设置模块 | 0.14% | — | 247 MB | 7 |
| 动态壁纸（程序化 20fps，双屏） | app 侧 <0.2% | — | 218 MB | 10 |
| 录屏（20.2s，含系统声+麦克风） | **0.18%** | 19 | 93 MB | 10 |
| 启动 → 首帧界面 | **0.99 s**（含 LaunchServices） | — | — | — |

¹ footprint 在 90–250 MB 之间来回抖动，是 CoreAnimation / IOSurface 表面随窗口显隐回收，
回落稳定，**没有发现内存泄漏**（连续观察 60s 单调性为 0）。

历史上出现过 623 MB 峰值（长时间运行 + 录屏 + 壁纸 + 面板叠加），属于瞬时高水位，不是稳态。

### 亮点

- **空载真的空载**：面板收起时 0.14% CPU / 17 次唤醒/秒，是干净的后台常驻水平。
- **录屏开销极低**：20 秒实拍 CPU 仅 0.18%、内存 93 MB。编码走 VideoToolbox 系统进程，
  主进程只做帧搬运，这个架构是对的。
- **0 第三方依赖**，启动 1 秒内出界面，对 30k 行的 SwiftUI 应用来说是合理水平。

### 问题

**1）面板在屏时，主线程有一半时间在跑 60fps 显示周期（P0）**

`sample` 对主线程的统计（5 秒窗口，2 662 个样本）：

```
NSDisplayCycleFlush                     1348  (51%)   ← 每帧 layout + DisplayList 重建
mach_msg2_trap（空闲等待）               496  (19%)
SystemMonitor.sampleOnce                 189   (7%)
```

调用链是固定的：
`NSDisplayCycleFlush → NSWindow layoutIfNeeded → NSHostingView.layout → ViewGraphRootValueUpdater.render
→ ViewGraph.renderDisplayList → DisplayList.ViewUpdater.render`。

也就是说：**面板什么也不做、静止在屏幕上时，SwiftUI 视图图仍然每帧失效重建**，代价是
1.1% CPU 与 110+ 次唤醒/秒。这对一个「打开看一眼就关」的面板来说纯属浪费；如果用户习惯把
面板固定（pin）在桌面，这个开销会一直存在。

**2）三处 `repeatForever` 装饰动画，`onAppear` 之后永不停止（P1）**

| 位置 | 动画 | 实测代价 |
| --- | --- | --- |
| `UI/DesktopView.swift:116` | 卡片渐变 `hueRotation` 8s 循环 | **+0.57%**（0.70% vs 0.13%） |
| `UI/RecorderBar.swift:140` | 红色录制点扩散脉冲 | 悬浮条在场时常驻 |
| `UI/RootView.swift:557` | 截图状态条脉冲（短生命周期，可接受） | — |

这三个动画都只依赖 `@State` 翻转一次，之后由 CoreAnimation 无限循环。视图从窗口上移除时才会停，
而面板窗口是常驻的，所以桌面模块那张小卡片的彩虹一直转。

**3）`SystemMonitor` 每 1.2 秒枚举一次全机进程，且从不暂停（P1）**

`Core/SystemMonitor.swift:116` 的定时器在建实例时就启动；`PanelController` 只在 `show()` 里调
`resume()`（`PanelController.swift:136`），**没有任何地方调 `pause()`**。结果面板收起后仍在
每 1.2s 做一次 `host_processor_info` + 内存 + 网络 + 磁盘 + GPU + 电池 + 全进程采样，
空载时占主线程样本的 7%。

**4）一批固定频率的常驻轮询（P2）**

| 服务 | 周期 | 说明 |
| --- | --- | --- |
| `ClipboardService` | **0.6 s** | 轮询 `changeCount`，100 次/分钟，纯空转 |
| `PermissionService` | 3 s | 探测 AX / 屏幕录制 / 磁盘权限，且每 30s 往 `/tmp/aurora-debug.log` 写一次 |
| `PerAppAudioService` | 2 s | 逐 App 音量重扫 |
| `NetworkService` | 3 s | — |
| `HIDDeviceService` | 4 s | — |
| `TrackpadService` | 5 s | — |
| `DisplayService` | 8 s | — |
| `DeviceService` | 45 s | — |
| `WallpaperService` | 20 s | 规则检查 |

单个都很便宜（否则空载不会只有 0.14%），但叠起来是「永远醒着」的功耗形状。
`/tmp/aurora-debug.log` 还会无限增长（里面每 30s 一条权限探测记录）。

**5）两个全局事件 tap 常开（P2）**

`PointerService.swift:249` 与 `KeyboardService.swift:54` 都用
`.cgSessionEventTap` + `.headInsertEventTap` + `.defaultTap`，挂在主 RunLoop 上。
`.defaultTap` 是**同步拦截**语义：鼠标每移动一次都要过一遍我们的进程，即使功能是关闭的
（代码里只是在回调里 `guard config.speed != 1.0` 提前返回，代价已经付掉了）。
建议：功能关闭时不创建 tap，开启时才装、关闭时拆。

**6）内存分配碎片偏高（P3）**

`vmmap` 显示 DefaultMallocZone 有 **546 104 个活跃分配 / 75.8 MB**，碎片率 **33%**；
AttributeGraph 另有 12.3 万个分配。对 240 MB 稳态的 SwiftUI 应用不算离谱，
但如果后面要压内存，先从「大图（DeviceFrames）重复解码」和「数组式历史（cpuHistory 等）」入手。

**7）录制默认码率偏高（P3）**

`RecorderService.swift:406`：`bitrate = max(4M, w*h*fps*0.1)`，默认 **60fps**。
实测 20.2 秒成片 **46.5 MB ≈ 18.4 Mbps**，10 分钟约 1.3 GB。
屏幕内容用 0.06–0.08 bpp 观感几乎无差，可省 30–40%；或把 HEVC 设为默认。

## 四、修复优先级与预期收益

| 优先级 | 动作 | 预期 |
| --- | --- | --- |
| P0 | 面板 `orderOut` 时暂停视图渲染（装饰动画改 `TimelineView(paused:)` 或按可见性卸载） | 在屏 1.15% → ~0.15%，唤醒 110 → ~17 |
| P1 | 三处 `repeatForever` 加可见性门控 | 桌面模块 0.70% → ~0.13% |
| P1 | `SystemMonitor` 在面板隐藏 15s 后 `pause()`，显示时 `resume()` | 空载主线程成本 −7% |
| P2 | 剪贴板 0.6s → 1.0s（或 `NSPasteboard` 变化通知） | 唤醒 −1.7/s |
| P2 | 权限探测改为「进入设置页时 + 面板可见时」，日志按大小轮转 | 写盘归零 |
| P2 | 两个 event tap 按功能开关装卸 | 输入路径延迟与常驻唤醒下降 |
| P3 | `strip -x` + DeviceFrames 转 HEIC | 31 MB → ~20 MB |
| P3 | 录制默认 30fps 可选、bpp 降到 0.07 | 成片体积 −35% |

## 五、附注：一个疑似 UI 问题

评测过程中发现面板窗口的 frame 是 `x=0 y=416 476×664`（屏幕 1512×982），
即贴在**屏幕最左侧、底部被截断**，而不是菜单栏图标下方；截图里能看到左边缘一条 25px 的图标残影。
`CGWindowListCopyWindowInfo(.optionOnScreenOnly)` 也查不到它（说明 WindowServer 认为它不在当前空间）。
它和 P0 的 60fps 渲染是同时出现的，建议一并排查 `PanelController.show(relativeTo:)` 的定位逻辑，
以及 `TransparentHostingView` 的 frame 同步。

## 六、总体评价

- **常驻成本控制得不错**：0.14% CPU / 17 唤醒，属于「装上不用也不心疼」的水平。
- **重活都外包出去了**：录屏编码交给 VideoToolbox 后只剩 0.18%，方向完全正确。
- **真正的浪费集中在一处**：面板在屏时的 60fps 空转。它不是功能需要，纯粹是「动画没人叫停」。
  修掉这一条，Aurora 就从「还行」变成「安静」。
- 包体与录制码率属于「顺手就能省」的优化，不影响体验。
