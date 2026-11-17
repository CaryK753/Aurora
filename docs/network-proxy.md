# 网络模块：系统代理与订阅

作者：wwj

## 默认方案与首次使用

没有通过 Apple 开发者签名校验或缺少网络扩展 entitlement 时，默认选择系统代理，并禁用不可用的网络扩展入口。存在上次的恢复备份时优先展示系统代理，以便恢复网络。

系统代理使用单独下载的 mihomo 内核（固定 v1.19.34，Apple Silicon / Intel 按架构下载，校验官方 SHA-256）。内核不进入 Aurora 安装包，可在界面重新下载或删除，以控制安装体积；直连模式始终不依赖内核。

## 订阅支持范围

- URL 下载支持 HTTP / HTTPS，限制 5 MB、60 秒，检查响应状态。失败不会替换原节点。
- 支持手动更新，以及 Aurora 运行期间每 6 小时、每天或每 3 天自动更新；活动代理不会热切换，更新后的节点在下次应用时生效。
- 支持从本地文件导入 Clash / Shadowrocket 配置；Surge 作为后续兼容项。
- Clash YAML / JSON：支持内联 `proxies`、YAML 别名、基础 `rules`。
- Shadowrocket：普通或 Base64 分享链接列表，以及基础 `[Proxy]` 配置。
- 链接支持 SS（含 SIP002 与旧版 Base64）、SSR、VMess JSON、VLESS、Trojan、HTTP(S)、SOCKS5、Hysteria2、TUIC；支持常用 TLS、WebSocket、gRPC 和 Reality 参数。
- Clash 内联节点保留内核支持的节点字段；节点有效性以应用前的内核校验为准。
- 外部 provider、脚本、代理链不导入。策略组不保留，规则中的组策略统一转为当前所选节点。无法识别的节点和规则有提示，不能把此基础支持视为完整兼容所有客户端配置。

节点名称及用户数据保持原文。订阅 URL、密码及解析后的配置只保存到本机 `~/Library/Application Support/Aurora/Network/`，目录权限 0700、文件权限 0600，不上传第三方转换服务。不会在界面错误中回显原链接或内核原始日志。

## 三种出站模式

- **全局**：所有进入系统代理的连接使用所选节点。
- **规则**：优先自定义规则，再内置 `gov.cn` 域名后缀（覆盖 `gov.cn` 与 `*.gov.cn`）、局域网、大陆 IP、订阅基础规则，最后用户指定的直连或代理兜底。
- **直连**：关闭当前启用网络服务的代理与 PAC / 自动发现设置，保留原配置备份。

系统代理只影响遵循 macOS 代理设置的应用，不接管所有 UDP 或系统 DNS。已有系统绕过列表继续生效。内核固定监听 `127.0.0.1`，不开启 TUN、局域网访问或控制器端口。高级选项中的 DNS 用于内核内的域名解析，不会改写 macOS DNS 设置。

节点列表可进行 TCP 连接耗时测试；它只验证服务器与端口能否建立连接，不等同于节点协议鉴权或完整代理可用性测试。

## 大陆 IP 识别

地址库来自 [APNIC 官方统计](https://ftp.apnic.net/stats/apnic/delegated-apnic-latest)，只选 `CN` 的已分配 / 已指派 IPv4 和 IPv6，排除 HK、MO、TW。对域名请求，内核解析目的 IP 后匹配地址段。地址分配归属不是物理位置保证；CDN 和地址迁移可能影响结果。

缓存 7 天，可手动更新或在启动代理时更新过期数据。更新失败时保留旧缓存并提示；首次没有可用数据时不启动宣称支持大陆分流的规则模式。

自定义规则支持 DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD、IP-CIDR、IP-CIDR6、PROCESS-NAME、PROCESS-PATH、DST-PORT、SRC-PORT、NETWORK、MATCH。动作 DIRECT / PROXY / REJECT，例如：

```text
DOMAIN-SUFFIX,example.com,PROXY
IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
PROCESS-NAME,Example,DIRECT
DST-PORT,25,REJECT
```

订阅的 MATCH 以本页兜底选项替代；GEOIP,CN 可转换为大陆本地规则集，GEOSITE 和外部 RULE-SET 暂不导入。

## 恢复与生命周期

写入系统设置可能请求管理员授权。应用前会验证内核配置、进程监听归属及 SOCKS 握手，通过后才写入系统代理。恢复成功后才停止内核。正常退出自动恢复，恢复失败或网络操作正在进行时取消退出并提示用户，避免留下失效的本地代理。程序崩溃或被强制终止时，系统代理可能保留；下次启动会显示恢复入口。更换或新增网络服务后请先恢复再应用。

如果外部工具修改过代理，恢复会停止，避免覆盖外部变更。备份跨应用重启保存。

## 后续 Tailscale

实现类型预留 `tailscale`，界面说明后续支持；当前没有启用占位的连接按钮，也不会把它作为可用代理。后续可独立接入组网状态与服务，复用现有实现选择入口。

## 验证命令

```sh
swift build
swift test --filter 'SubscriptionTests|RoutingTests|DownloadTests'
bash Tests/SystemProxy/run.sh
bash Tests/NetworkProxyKit/run-integration.sh
# 已有经过校验的内核时，还可验证 Aurora 的原生进程生命周期：
AURORA_PROXY_TEST_CORE=/path/to/mihomo bash Tests/SystemProxy/run-runtime.sh
```

集成测试下载并校验官方内核，只使用本机临时测试服务，验证全局、直连、自定义规则、大陆规则集与兜底路径，另下载 APNIC 数据检查 IPv4 / IPv6。不会修改系统代理。

参考：[mihomo 配置文档](https://wiki.metacubex.one/en/config/)、[固定版本及校验值](https://github.com/MetaCubeX/mihomo/releases/expanded_assets/v1.19.34)、[Yams](https://github.com/jpsim/Yams)。第三方声明见 `Resources/NetworkThirdPartyNotices.txt`。
