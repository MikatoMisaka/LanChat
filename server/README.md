# LanChat Server Edition

这里是 LanChat 自建服务器的部署目录。服务器版保留局域网 P2P 功能，并增加跨网络的文字、图片、入群审批、设备审批、离线同步和管理员控制室。

服务器由三个运行单元组成：

- `control`：LanChat 认证、邀请码、申请、设备、会话、容量设置和管理员网页。
- `synapse`：内部 Matrix/Synapse 传输层，客户端不需要理解它的账号体系。
- `caddy`：可选的公网 HTTPS 前置。域名模式使用它，直连模式不启动它。

大文件仍然只通过局域网传输。远程图片默认上限为 20 MB。消息正文在客户端加密，控制室显示的是状态、设备和容量信息。

## 文件说明

```text
server/
├── control/
│   ├── bin/server.dart       控制服务入口
│   ├── lib/                  账号、会话和 HTTP API
│   ├── test/                 控制服务测试
│   └── web/                  管理控制室 HTML/CSS/JS
├── synapse/
│   ├── bootstrap.sh          自动创建内部 Matrix 管理账号
│   └── homeserver.yaml.example
├── docker-compose.yml        域名 HTTPS 模式
├── docker-compose.direct.yml IP 和端口直连模式
├── Caddyfile.example         Caddy 配置示例
└── .env.example              环境变量示例
```

## 域名 HTTPS 部署

### 准备目录和环境变量

在 Linux 服务器上执行：

```bash
cd /home/LanChat/server
cp .env.example .env
cp Caddyfile.example Caddyfile
mkdir -p synapse/data data/control data/caddy data/caddy-config
sudo chown -R 991:991 synapse/data
```

编辑 `.env`：

```dotenv
CHAT_DOMAIN=chat.example.com
ADMIN_DOMAIN=admin.chat.example.com
SYNAPSE_SERVER_NAME=chat.example.com
LANCHAT_SERVER_NAME=My LanChat Server
```

`LANCHAT_BOOTSTRAP_ADMIN_PASSWORD` 和 `LANCHAT_BOOTSTRAP_ACCESS_CODE` 可以留空。留空时，控制服务会生成一次性管理员初始化口令；群组邀请码登录控制室后生成。

### 生成 Synapse 配置

```bash
docker compose --env-file .env run --rm synapse generate
```

检查 `synapse/data/homeserver.yaml`，确认：

- `server_name` 与 `SYNAPSE_SERVER_NAME` 一致。
- `public_baseurl` 使用聊天域名 HTTPS 地址。
- 关闭公开注册。
- 开启用户目录搜索。
- `max_upload_size` 不超过 20 MB。
- `retention` 和 `media_retention` 使用 30 天策略。
- 文件保持可写，供内部 bootstrap 容器在需要时补齐 `registration_shared_secret`。

不要把生成的 `homeserver.yaml`、签名密钥或数据库提交到 Git。

### 启动

```bash
docker compose --env-file .env up -d --build
docker compose --env-file .env ps
docker compose --env-file .env logs control synapse-bootstrap
```

`synapse-bootstrap` 会：

1. 确保 Synapse 配置里有内部注册所需的共享密钥。
2. 创建或登录隐藏的 `lanchat-control` Matrix 管理账号。
3. 把短期使用的内部 access token 写入 `data/control/matrix-admin-token`。

控制服务从这个数据文件读取 token，不需要把 token 放进 `.env`。这个文件属于部署数据，不能提交。

Caddy 使用 Let’s Encrypt ACME endpoint。无需提前注册 Let’s Encrypt 或 ZeroSSL 账号，也不需要 EAB 配置。

## 首次设置和入群

如果第一次启动没有设置 `LANCHAT_BOOTSTRAP_ADMIN_PASSWORD`，读取初始化口令：

```bash
docker compose --env-file .env logs control
```

打开 `ADMIN_DOMAIN`：

1. 输入一次性初始化口令。
2. 设置管理员密码。
3. 在首页生成群组邀请码或单人邀请码。
4. 通过其他渠道把服务器地址和邀请码发给朋友。
5. 在申请队列中通过或拒绝新申请。
6. 在设备队列中审批新设备。

用户不需要 Matrix 用户 ID、Synapse 管理员账号或 access token。

## IP 和端口直连

直连模式通过控制服务内部代理 Matrix 路径，让客户端仍然只需要一个服务器地址。Synapse 不直接发布端口，Caddy 也不会启动。

```bash
cd /home/LanChat/server
docker compose -f docker-compose.yml -f docker-compose.direct.yml --env-file .env up -d --build
```

默认地址：

```text
http://SERVER_IP:8080
```

修改外部端口：

```dotenv
LANCHAT_CONTROL_PORT=18080
```

然后客户端使用 `http://SERVER_IP:18080`。HTTP 适合可信的局域网，不适合公网；公网请使用 Caddy HTTPS 模式。

## 升级已有部署

先备份：

```bash
cp -a data "../lanchat-control-backup-$(date +%Y%m%d-%H%M%S)"
cp -a synapse/data "../lanchat-synapse-backup-$(date +%Y%m%d-%H%M%S)"
```

拉取并重建：

```bash
git pull --ff-only
docker compose --env-file .env up -d --build
docker compose --env-file .env ps
```

不要删除或覆盖：

- `data/control/lanchat-control.json`
- `data/control/joins.json`
- `data/control/sessions.json`
- `data/control/matrix-admin-password`
- `data/control/matrix-admin-token`
- `synapse/data/`

旧版 `.env` 如果包含 `SYNAPSE_ADMIN_TOKEN`，新版本不要求它。保留也不会成为新控制室的日常配置；新部署优先使用自动 bootstrap 文件。

## Docker 镜像拉取失败

如果 Docker 拉取 `dart:3.13.0` 时返回 HTTP 500，通常是当前镜像源的问题。可以先测试备用仓库：

```bash
docker pull m.daocloud.io/docker.io/library/dart:3.13.0
```

成功后在 `.env` 中设置：

```dotenv
LANCHAT_DART_IMAGE=m.daocloud.io/docker.io/library/dart:3.13.0
```

不要关闭 Docker 镜像签名检查或 APT 签名检查来绕过拉取错误。

## 控制服务开发和测试

```text
cd server/control
dart pub get
dart analyze
dart test
```

控制室不依赖外部 CDN。`control/Dockerfile` 会把 `web/` 下的 `index.html`、`styles.css` 和 `app.js` 一起复制到镜像。
