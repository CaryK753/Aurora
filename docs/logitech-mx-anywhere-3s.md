# 罗技 MX Anywhere 3S 适配

作者：wwj

## 已实现

独立 `LogitechPlugin` 已接入 Aurora 鼠标页面。通过设备特性查询显示支持项，而不是按型号假设所有功能均存在。

| 能力 | 当前实现 |
| --- | --- |
| 硬件 DPI | 查询有效档位、调节并读回确认 |
| MagSpeed | SmartShift 自动切换、分段滚动、自由滚动 |
| 滚轮力度 | 设备支持时显示分段阻尼与自动切换阈值 |
| 高分辨率滚轮 | 读取及设置 HiRes 模式，保留其他模式位 |
| 特殊按键 | 中键、侧键、模式切换键与设备公开的其他可接管按钮 |
| 鼠标方案 | 按设备保存硬件设置和按键映射，支持按键切换方案、DPI、滚轮模式 |
| 应用动作 | 新系统优先打开 Apps.app，旧系统回退 Launchpad；自选应用弹出应用选择器 |
| 显示桌面 | Dock 通知及用户已启用的系统快捷键两种方案 |

普通 Aurora 指针倍率仍是软件位移倍率，会与硬件 DPI 叠加。MagSpeed 的电磁滚轮由模式、阈值和阻尼控制，不是一个通用“开启电磁滚轮”开关。

## 验证范围

2026-11-10，MX Anywhere 3S 经 Bluetooth Low Energy 连接，真实查询到 200–8000 DPI、SmartShift 增强特性、HiRes Wheel、可重编程按键和电量。DPI、滚轮、HiRes 原值写入读回，以及模式切换键临时接管再恢复均通过。安装到 `/Applications/Aurora.app` 后，插件页面能读取设备和接管状态。

12 项自动测试覆盖报文匹配、接收器槽位隔离、DPI 范围、按键保护、持久化、写入读回、模式位保留、接管恢复、按键边沿及方案失败回滚。接收器尚未真机验证。Apps 和显示桌面等系统动作仍需通过真实按键验收；快捷键方案要求系统中已启用相应快捷键。Dock 方案使用系统私有接口，后续系统升级可能需要调整。

## 使用与恢复

明确选择映射后才接管对应按键；左、右键保持原样。停用或正常退出时恢复原上报方式；异常退出的恢复记录下次连接时处理。重新连接不会自动覆盖设备当前方案。与其他驱动争用时返回错误，避免相互覆盖。

- [独立模块说明](../Modules/LogitechPlugin/README.md)
- [罗技使用指南](https://support.logi.com/hc/en-au/articles/12895016873495-Getting-Started-MX-Anywhere-3S)
- [HID++ 协议](https://github.com/Logitech/cpg-docs/blob/master/hidpp20/README.rst)
