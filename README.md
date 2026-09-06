# LanChat

LanChat 是一个 Flutter 聊天软件。局域网设备之间可以直接通信；需要跨网络时，可以部署一个自己的 LanChat 服务器。

服务器版面向熟人小群组。服务器拥有者通过其他渠道发出服务器地址和邀请码，朋友在客户端提交申请，管理员在网页控制室审批。聊天内容在客户端加密，服务器只负责认证、转发和缓存。

## 两种使用方式

### 局域网版

- 通过组播、广播或手动方式发现设备。
- 配对前显示六位确认码，确认后才建立信任关系。
- 使用 X25519 密钥协商和 ChaCha20-Poly1305 加密通信。
- 支持文字、图片和文件消息。
- 文件传输支持分块、断点续传和完整性校验，单个文件最多 5 GiB。
- Windows 支持文本选择、复制粘贴和多文件拖放。

### 服务器版

- 服务器地址可以是域名，也可以是 IP 和自定义端口。
- 用户使用邀请码、用户名、密码和昵称提交入群申请。
- 管理员网页审批账号和每台新设备。
- 远程文字和图片通过内部 Matrix/Synapse 传输层转发。
- 客户端只接收服务器换发的内部会话，不需要填写 Matrix 账号或 access token。
- 远程图片默认最多 20 MB；大文件仍然只走局域网直连。
- 消息默认保留 30 天，管理员可以在控制室修改保留时间和容量限制。
- 不依赖 Firebase、FCM 或常驻后台推送。应用进程运行时使用本地通知。

## 服务器结构

```text
朋友的 LanChat 客户端
        │ 一个服务器地址
        ▼
LanChat control  ── 认证、邀请码、审批、设备和管理 API
        │
        ├── 内部 Matrix/Synapse  ── 加密事件同步和缓存
        └── Caddy（可选） ── 公网 HTTPS
```

控制服务负责 LanChat 账号和设备状态。Synapse 只在服务器内部使用，普通用户和管理员不需要维护它的账号体系。

## 第一次部署

服务器部署文件在 [`server/`](server/)：

- `server/docker-compose.yml`：域名 HTTPS 模式。
- `server/docker-compose.direct.yml`：IP 和自定义端口直连模式。
- `server/control/`：控制服务和管理员控制室。
- `server/synapse/bootstrap.sh`：自动创建内部 Matrix 管理账号，不需要手填 token。
- `server/Caddyfile.example`：Caddy HTTPS 配置。
- `server/.env.example`：部署环境变量示例。

### 域名 HTTPS 模式

需要一台安装了 Docker Compose 的 Linux 服务器，并准备聊天域名和管理域名。两个域名都解析到服务器 IP，开放 TCP `80` 和 `443`。

```bash
cd server
cp .env.example .env
cp Caddyfile.example Caddyfile
mkdir -p synapse/data data/control data/caddy data/caddy-config
sudo chown -R 991:991 synapse/data
docker compose --env-file .env run --rm synapse generate
docker compose --env-file .env up -d --build
docker compose --env-file .env logs control synapse-bootstrap
```

编辑 `.env` 时至少确认：

- `CHAT_DOMAIN` 是聊天域名。
- `ADMIN_DOMAIN` 是管理员域名。
- `SYNAPSE_SERVER_NAME` 与聊天域名一致。
- `LANCHAT_SERVER_NAME` 是控制室里显示的服务器名称。

首次启动如果没有设置 `LANCHAT_BOOTSTRAP_ADMIN_PASSWORD`，控制服务会在日志中打印一次性初始化口令。打开 `ADMIN_DOMAIN`，输入口令并设置管理员密码。之后在控制室生成群组邀请码或单人邀请码，再通过其他渠道发送给朋友。

不需要注册 Let’s Encrypt 账号，也不需要 ZeroSSL EAB。Caddy 会自动申请证书。

### IP 和端口直连模式

没有域名时使用直连覆盖文件。它只向外暴露 LanChat 控制入口，Matrix 请求由控制服务在内部转发，Synapse 不直接暴露到公网。

```bash
cd server
cp .env.example .env
mkdir -p synapse/data data/control
sudo chown -R 991:991 synapse/data
docker compose --env-file .env run --rm synapse generate
docker compose -f docker-compose.yml -f docker-compose.direct.yml --env-file .env up -d --build
```

客户端地址使用 `http://SERVER_IP:8080`。可以在 `.env` 中设置 `LANCHAT_CONTROL_PORT` 修改外部端口。HTTP 只适合可信的局域网或临时环境，客户端会显示非 HTTPS 安全提示；公网部署应使用域名 HTTPS 模式。

## 客户端入群流程

1. 管理员在控制室生成邀请码。
2. 朋友在服务器版 LanChat 中填写服务器地址、邀请码、用户名、密码和昵称。
3. 管理员在控制室的申请队列中通过或拒绝申请。
4. 通过后，客户端用用户名和密码登录并建立加密聊天会话。
5. 同一用户从新设备登录时，该设备会单独进入待审批列表。

## 升级已有服务器

先备份 `server/data/` 和 `server/synapse/data/`，不要覆盖已有的 Synapse 数据或控制服务配置，然后在服务器上执行：

```bash
cd /home/LanChat
git pull --ff-only
cd server
docker compose --env-file .env up -d --build
docker compose --env-file .env logs control synapse-bootstrap
```

旧版本的 `.env` 中如果还留有 `SYNAPSE_ADMIN_TOKEN`，新控制室不要求它；真正的内部 token 会由 `synapse-bootstrap` 写入 `data/control/`。`.env`、生成的 `homeserver.yaml`、token、密钥和聊天数据都不要提交到 Git。

## 开发环境

- Flutter `3.47.0`
- Dart `3.13.0`
- Android SDK / Visual Studio Windows 桌面工具链
- Matrix Dart SDK
- Rustup（用于 Vodozemac）

项目把 Rustup 和 Cargo 放在仓库内的 `.rustup/`、`.cargo/` 目录中，这些目录已加入 Git 忽略列表。

本地运行：

```text
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

Windows 构建：

```powershell
.\tooling\flutter-local-rust.ps1 build windows --release
```

基础版 Android 构建：

```powershell
.\tooling\flutter-local-rust.ps1 build apk --release
```

服务器版 Android 构建：

```powershell
.\tooling\flutter-local-rust.ps1 build apk --release --dart-define=LANCHAT_SERVER_EDITION=true
```

控制服务测试：

```text
cd server/control
dart pub get
dart analyze
dart test
```

## 数据和安全

- 局域网通信在完成配对和身份校验后才启用。
- 服务器聊天内容由客户端加密，控制室不能读取正文。
- 管理员密码、群组邀请码和用户密码只保存哈希值。
- 客户端凭据和会话保存在平台安全存储中。
- 直连 HTTP 不提供传输层保密，只适合可信网络。
- 定期备份 `server/data/` 和 `server/synapse/data/`，并限制目录权限。
- 不要提交 `.env`、生成的 Synapse 配置、token、私钥、数据库、上传文件、keystore 或构建缓存。

## 许可证

LanChat 自有代码使用 GNU General Public License v3.0 或更高版本，详见 [`LICENSE`](LICENSE)。Matrix、Synapse、Caddy、Vodozemac、WinToast 及其他依赖保留各自的许可证。
