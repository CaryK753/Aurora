# 网络模块：系统代理、订阅与 Tailscale 组网

作者：wwj

## 三块拼图

| 能力 | 说明 |
| --- | --- |
| **系统代理** | 把代理写进 macOS 系统代理设置，不要求开发者计划。代理内核是按需下载的 mihomo。 |
| **网络扩展** | 可选。需要带 `app-proxy-provider-systemextension` 的描述文件，接管 TCP。 |
| **Tailscale 组网** | 独立于上面两条：复用官方 App，或自己拉起 userspace tailscaled，给代理提供一条组网出站。 |

面板顶部是状态条（模式、实时速率、本次流量），下面分「概览 / 连接 / 规则 / 日志」四页。数据来自 mihomo 的本机控制器；代理没跑时只显示静态配置。

## 默认方案与首次使用

没有通过 Apple 开发者签名校验或缺少网络扩展 entitlement 时，默认选择系统代理，并禁用不可用的网络扩展入口。存在上次的恢复备份时优先展示系统代理，以便恢复网络。

系统代理使用单独下载的 mihomo 内核（固定 v1.19.34，按架构下载，校验官方 SHA-256）。内核不进入 Aurora 安装包，可随时重新下载或删除；直连模式始终不依赖内核。

## 订阅与节点

- **多份订阅**：可以同时保存多份，切换哪一份就只换节点池，不再互相覆盖。每份订阅单独设置更新周期（关闭 / 6 小时 / 每天 / 3 天）。
- **来源**：URL 下载（HTTP / HTTPS，5 MB、60 秒上限，检查状态码）、本地配置文件（Clash YAML / JSON、Shadowrocket、Base64、常见分享链接）。下载失败不会替换原节点。
- **协议**：SS（含 SIP002 与旧版 Base64）、SSR、VMess、VLESS、Trojan、HTTP(S)、SOCKS5、Hysteria2、TUIC，含常用 TLS、WebSocket、gRPC 与 Reality 参数。外部 provider、脚本、代理链、策略组不导入；Surge 作为后续兼容项。
- **手动节点**：不走订阅时直接填 SOCKS5 / HTTP 主机与端口，应用时写进内核配置。
- **测速**：节点列表显示延迟（走内核实测，失败显示超时）；「下载测速」通过当前策略真实下载一段数据算 Mbit/s，失败只报错，不改配置。

节点名称及用户数据保持原文。订阅 URL、密码及解析后的配置只保存在本机 `~/Library/Application Support/Aurora/Network/`，目录 0700、文件 0600，不上传第三方转换服务。

## 策略组

规则命中的流量指向一个策略组，组类型三选一：

- **手动选择**：自己点用哪个节点。
- **自动测速（url-test）**：内核按健康检查地址定期测速，自动用最快的节点；可设间隔与容差。
- **故障转移（fallback）**：优先用列表里第一个可用节点，连不上才换下一个。

订阅商常用「剩余流量 / 到期时间 / 官网 / 套餐」这类条目展示信息，它们会被识别成伪节点：留在列表里可见，但不会自动选中，也不会进策略组。

## 规则

判定顺序：

1. 自定义规则
2. Tailscale（`ts.net` 与自选域名）
3. 内置 `gov.cn` 直连
4. 局域网与本机直连
5. 大陆 IP（APNIC `CN` 分配数据，排除 HK / MO / TW）
6. 规则集（按添加顺序）
7. 订阅自带规则
8. 兜底（直连或代理）

自定义规则支持 DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD、IP-CIDR、IP-CIDR6、PROCESS-NAME、PROCESS-PATH、DST-PORT、SRC-PORT、NETWORK、MATCH，动作 DIRECT / REJECT / PROXY（等同代理组）/ TAILSCALE（没有组网出口时不接受）。认不出的行会标出行号。

**规则集**：填一个 Clash 风格的 `domain` / `ipcidr` / `classical` 规则地址，按小时更新，落成内核的 rule-provider；命中的流量可选直连或代理。

**规则测试**：输入域名与端口，按当前规则顺序算出命中的那一条与最终策略。IP 规则要看解析结果、规则集内容在文件里、进程规则要真实进程——这三类会在结果里列为「本地无法判断」，不做猜测。

## 仪表盘数据

代理运行时，Aurora 会在 `~/Library/Application Support/Aurora/Network/controller.sock` 开一个**本机 Unix socket** 控制器：不占 TCP 端口、不需要 secret、目录 0700。用到：

- `/traffic`：每秒一次的上下行速率与累计。
- `/connections`：当前连接（域名、进程、命中规则、策略、每条流量、时长），可单条断开。
- `/logs`：内核日志流，可按级别筛选。
- `/proxies`、`/rules`：策略组当前节点、节点延迟历史、规则命中次数。

面板收起或代理停止时整条链路停掉，不在后台空转轮询。

## Tailscale 组网

两条路，能用的那条才显示：

1. **官方 App**（`/Applications/Tailscale.app`）：Aurora 复用它的 CLI 读登录账号、设备名、节点与出口节点，做连接开关与出口节点切换。这种方式拿不到 SOCKS5，因此只做整机接入。
2. **本机 tailscaled**（例如 `brew install tailscale`）：Aurora 用 userspace 模式拉起独立实例（状态目录在 Aurora 下、独立 socket、`--socks5-server`），再把 `127.0.0.1:<端口>` 作为 `TAILSCALE` 代理写进内核配置。于是规则可以把 `ts.net`、MagicDNS 名字和自选域名交给组网，其余流量照常走代理。

两者都没有时，卡片只给安装入口，不伪造开关。登录要在浏览器完成的，会把链接放在卡片上。自己拉起的 tailscaled 随 Aurora 退出；官方 App 的 daemon 不归 Aurora 管。

## 恢复与生命周期

写入系统设置可能请求管理员授权。应用前会验证内核配置、用 `lsof` 确认监听端口属于本进程、做 SOCKS 握手，并通过当前节点真实请求 `generate_204`，全过才写系统代理。

系统代理配置用 SystemConfiguration 事务写入，备份存进偏好因此跨重启保留。恢复前会比对当前值是否仍是我们写进去的那份，外部工具改过就停下不覆盖。正常退出自动恢复，网络操作未完成或恢复失败时会拦住退出；内核意外退出也会自动恢复。

## 验证

```sh
swift build
swift test --filter 'SubscriptionTests|RoutingTests|DownloadTests|DashboardTests|TailscaleTests|ControllerClientTests'
bash Tests/SystemProxy/run.sh
bash Tests/NetworkProxyKit/run-integration.sh

# 有真实内核时还能跑两条更贴近现场的检查：
AURORA_MIHOMO=/path/to/mihomo swift test --filter testGeneratedConfigPassesEngineCheck
AURORA_CONTROLLER_SOCKET=/path/to/ctl.sock swift test --filter testRealEngineSmoke
```

集成测试下载并校验官方内核，只使用本机临时测试服务；不会修改系统代理。

## 已知边界

- 系统代理只影响遵循 macOS 代理设置的应用，不接管 UDP 与系统 DNS；内核只监听 `127.0.0.1`，不开 TUN、局域网访问或控制器端口。
- 网络扩展要求 Apple 授权描述文件，这一版只接管 TCP；Tailscale 只提供出站，不做 TUN 接管。
- userspace tailscaled 不能作为出口被局域网其他设备使用，也不支持子网路由下发。
- 规则测试是本地近似：不解析域名、不读规则集文件、不看真实进程。
- 地址归属（APNIC）不是物理位置保证；CDN 和地址迁移会影响判定。
- DNS 设置只作用于内核内部的域名解析，不改写 macOS DNS。

参考：[mihomo 配置文档](https://wiki.metacubex.one/en/config/)、[固定版本及校验值](https://github.com/MetaCubeX/mihomo/releases/expanded_assets/v1.19.34)、[Tailscale CLI](https://tailscale.com/kb/1080/cli)、[Yams](https://github.com/jpsim/Yams)。第三方声明见 `Resources/NetworkThirdPartyNotices.txt`。
