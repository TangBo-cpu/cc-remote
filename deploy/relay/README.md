# 自建公网入口与 WebRTC

这是可选连接方式。未启用配置时，原有 Cloudflare 模式照常使用。需要同时更新电脑 daemon、桌面启动器和手机 App。

手机先通过自建 HTTPS/WSS 入口连接电脑，完成现有设备鉴权。鉴权成功后，双方通过这条 WSS 连接交换 WebRTC 信令，并尝试建立可靠、有序的数据通道。ICE 优先选择可用的直连候选，必要时使用 TURN；协商期间 WSS 继续承载业务。

数据通道建立后，聊天消息、目录操作、图片和附件接口都可以通过它传输。大消息分块发送，上传和下载保留流式处理。通道切换使用 WSS 标记确认旧消息已送达；已建立的数据通道断开时重新连接并恢复会话。HTTP 写操作失败后不会自动重发，prompt 继续使用现有回执去重。

## 组件

| 位置 | 组件 | 用途 |
| --- | --- | --- |
| 云服务器 | Caddy | 提供公开 HTTPS/WSS 入口和证书 |
| 云服务器 | frps | 接收电脑主动建立的加密隧道，仅向服务器回环地址开放 daemon 转发端口 |
| 电脑 | frpc | 将服务器入口转发到本机 daemon，无需开放电脑路由器端口 |
| 云服务器 | coturn | 提供 STUN，以及带临时凭据的 TURN UDP/TCP 服务 |
| 手机、电脑 | WebRTC DataChannel | 直连或通过 TURN 传输业务数据 |

这里复用 CC Remote 的设备配对与授权，不接入 dsh-go 的账号服务。网关与 frp 是受信任的服务端，可以看到经它们转发的 HTTP/WSS 内容；TURN 转发的是 WebRTC 加密数据。本实现没有新增 dsh-go 的 Noise 加密层。

## 服务器配置

使用独立目录，例如 `/opt/cc-remote-relay`。将本目录的 `compose.yaml`、`Caddyfile` 和填好值的配置复制到该目录。配置中的域名、地址和密钥均使用占位符，真实值不要提交 Git。

1. 将 `frps.toml.example`、`turnserver.conf.example` 分别保存为 `frps.toml`、`turnserver.conf`。为 frp token 和 TURN secret 分别生成至少 32 字节随机值。
2. 创建 `.env`，写入 `RELAY_DOMAIN=你的域名`。
3. 为 frp 创建独立 CA，以及 SAN 包含该域名的服务器证书，保存为 `tls/server.crt` 和 `tls/server.key`。CA 私钥留在服务器；只将 CA 证书复制到电脑的 `.data/relay-ca.crt`。
4. 父目录权限设为 `700`；容器需要读取的配置和服务器证书文件可设为 `644`。CA 私钥设为 `600`，不要挂载到容器。
5. 先检查配置和端口，再启动对应服务。网关签发公开证书前，需要域名指向这台服务器。

服务器需要放行以下入站端口，云安全组和系统防火墙都要核对：

| 端口 | 协议 | 用途 |
| --- | --- | --- |
| 80、443 | TCP | HTTPS 证书校验和手机连接 |
| 7000 | TCP | frpc 到 frps 的连接；可仅允许电脑的出口地址 |
| 3478 | UDP、TCP | STUN/TURN |
| 49160–49200 | UDP | TURN 分配的中继端口 |

不要公开 `18787`，该端口仅供服务器本机网关访问。模板禁止 TURN 访问回环、私网和组播地址，并限制中继分配数量。TURN 支持客户端通过 TCP 连接，但这个模板不提供 TURN TLS；若网络仅允许 HTTPS，仍可使用 WSS。

服务器有公网地址映射时，`external-ip` 填 `公网IP/实际网卡私网IP`，`relay-ip` 填实际网卡私网 IP。

## 电脑配置

- 将经官方 SHA-256 校验的 frp 0.72.0 Windows x64 客户端放到 `.run/frp/frpc.exe`。
- 将填写后的 `frpc.toml.example` 保存为 `.data/frpc.toml`。`trustedCaFile` 校验服务器 CA，`serverName` 校验服务器证书域名。
- 将 `relay.json.example` 保存为 `.data/relay.json`，先保留 `enabled: false`。
- 将 `peer.json.example` 保存为 `.data/peer.json`。其中 TURN secret 与服务器一致，长期 secret 不会发送给手机；手机只能在鉴权后取得一小时有效的 TURN 凭据。

桌面启动器和命令行脚本在 `relay.json` 启用后会管理 frpc，并使用其中的 HTTPS 地址。frp 断开后自行重连；桌面启动器也会复用原有固定隧道恢复逻辑。

## 切换与回退

先在新服务器验证 frp、TURN 和网关配置，再将原域名从 Tunnel 的 CNAME 改为指向服务器公网 IP 的 A 记录，并设为 **DNS only（灰云）**。如果同时存在 AAAA 记录，也应确认它指向正确的服务器，不能继续指向旧入口。保留原 Tunnel 记录值，方便回退。

域名解析与 HTTPS 证书就绪后，将电脑 `.data/relay.json` 和 `.data/peer.json` 的 `enabled` 改为 `true`，重启更新后的桌面启动器。原域名和 `.data/state.json` 保持不变时，现有配对可以继续使用。旧 App 仍可通过 WSS 连接；新 App 才会尝试 WebRTC。

停用新入口时，将两个配置改回 `false`，恢复原 Tunnel 的 DNS 记录并重启启动器。此回退保留设备授权与会话数据；Cloudflare 不会在域名指向新服务器时自动接管流量。

上线前需分别确认：同 Wi-Fi 直连、手机流量下的跨网络连接、强制 TURN、WebRTC 不可用时的 WSS，以及附件和断线恢复。构建或静态检查通过不能替代这些联网验证。

参考：[frp TLS](https://gofrp.org/en/docs/features/common/network/network-tls/)、[coturn](https://github.com/coturn/coturn)、[Cloudflare DNS only](https://developers.cloudflare.com/dns/proxy-status/)。
