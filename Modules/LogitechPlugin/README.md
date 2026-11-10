# LogitechPlugin

作者：wwj

Aurora 鼠标页面使用的独立 Swift 模块，通过非独占 IOHID 通道访问 HID++ 2.0。宿主通过 `LogitechDeviceService` 展示设备并处理 `onAction`，库不依赖 Aurora 的窗口或动作实现。

支持按设备查询 DPI 档位、SmartShift／分段／自由滚轮、阻尼、高分辨率滚动和可重编程按键。仅显示设备报告支持的设置，写入后读回校验。配置方案按设备保存，可映射按键切换方案、DPI 或滚轮模式。

按键接管先保存恢复记录；停用和正常退出时恢复原上报方式，异常退出遗留记录在下次连接时尝试恢复。左、右键不允许接管。其他软件已接管的按钮返回冲突，不覆盖其映射。重连仅刷新设备，不擅自重放保存方案。方案部分失败会尝试回滚，失败信息保留实际状态。

## 验证

```sh
swift test --filter 'HIDPPTests|LogitechSettingsTests'
.build/debug/Aurora --logitech-diagnostics
```

退出主程序后可运行 `.build/debug/Aurora --logitech-verify`，执行原值写入读回及短暂接管恢复测试。此命令会向设备写入，主程序运行时拒绝执行。

MX Anywhere 3S 蓝牙真机通过读写验证。Bolt／Unifying 的共享传输及槽位隔离有自动测试，尚未真机验证。不保证所有罗技型号都实现这些 HID++ 特性。

协议资料：https://github.com/Logitech/cpg-docs/tree/master/hidpp20
