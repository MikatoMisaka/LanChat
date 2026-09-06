# LanChat

LanChat 是一个面向熟人小群组的加密聊天软件。

- **局域网版**：设备直接配对，适合家庭、办公室和临时网络。
- **服务器版**：自建服务器，支持跨网络聊天、好友申请、设备审批、图片和小文件。

服务器只负责认证、转发和缓存。服务器聊天正文由客户端加密，管理员不能直接读取聊天内容。

## 安装客户端

服务器聊天使用服务器版客户端：

- Android：`release/LanChat-server-android.apk`
- Windows：复制整个 `release/windows-server/` 目录，运行其中的 `lanchat.exe`

基础版客户端不包含服务器入口，不用于服务器聊天。

本项目当前版本号见 `pubspec.yaml`。如果 Android 拒绝覆盖安装，请先卸载旧版本，或使用 `adb install -r -d`。

## 服务器一键部署

推荐使用 Linux + Docker Compose。服务器需要准备：

- 一台 Linux 服务器。
- Docker 和 Docker Compose V2。
- 聊天域名、控制室域名，并将两个域名解析到服务器 IP。
- 公网 HTTPS 模式开放 TCP `80` 和 `443`。

从 Git 获取项目：

```bash
git clone https://github.com/MikatoMisaka/LanChat.git /home/LanChat
cd /home/LanChat/server
cp .env.example .env
vi .env
bash start.sh
```

编辑 `.env` 时至少填写：

```dotenv
CHAT_DOMAIN=chat.example.com
ADMIN_DOMAIN=admin.chat.example.com
SYNAPSE_SERVER_NAME=chat.example.com
LANCHAT_SERVER_NAME=My LanChat Server
```

`SYNAPSE_SERVER_NAME` 只能填写域名或域名加端口，不能包含 `https://`、路径或空格。

`bash start.sh` 会自动完成：

- 检查 Docker Compose。
- 创建数据目录和 Caddy 配置。
- 生成 Synapse 配置。
- 关闭公开注册并开启成员目录搜索。
- 设置 HTTPS 地址、500 MB 内部上传上限和 30 天媒体保留策略。
- 构建并启动 control、Synapse、bootstrap 和 Caddy。

首次启动后查看管理员初始化口令：

```bash
docker compose --env-file .env logs control
```

打开 `ADMIN_DOMAIN`，输入一次性口令并设置管理员密码。然后在控制室生成群组邀请码或单人邀请码。

没有域名时，可以使用局域网直连模式：

```dotenv
LANCHAT_PUBLIC_BASEURL=http://192.168.1.10:8080/
```

```bash
bash start.sh --direct
```

客户端地址为 `http://SERVER_IP:8080`，端口可以通过 `LANCHAT_CONTROL_PORT` 修改。直连 HTTP 只适合可信局域网。

详细服务器说明见 [`server/README.md`](server/README.md)。

## 客户端使用

### 加入服务器

1. 管理员在控制室生成邀请码。
2. 客户端打开服务器页面，点击添加服务器。
3. 填写服务器地址、用户名、密码、昵称和邀请码。
4. 管理员在控制室的申请队列中通过申请。
5. 客户端点击连接，完成服务器账号登录。
6. 新设备登录时，需要在控制室单独审批设备。

如果首次申请失败，保存的邀请码会继续走“申请加入”流程，不会错误地当成已有账号登录。

### 加好友和聊天

1. 连接服务器后，成员会自动刷新。
2. 点击成员发送好友申请。
3. 对方在好友申请区域接受后，双方才能进入聊天。
4. 支持文字、表情、图片和小文件。

服务器版默认限制：

- 图片最多 20 MB。
- 服务器小文件默认最多 100 MB，管理员可调整到 500 MB。
- 小于 2 MiB 的入站图片会自动缓存并在聊天中展示，不会自动保存到系统相册。
- 大文件继续使用局域网直连传输。

## 升级服务器

升级前建议备份 `server/data/` 和 `server/synapse/data/`。不要覆盖 `.env`、`Caddyfile`、Synapse 密钥或数据库。

```bash
cd /home/LanChat
git pull --ff-only origin master
cd server
bash start.sh
```

如果现有部署使用旧版 Caddy 配置，先备份后复制新版配置：

```bash
cp Caddyfile "Caddyfile.backup.$(date +%Y%m%d-%H%M%S)"
cp Caddyfile.example Caddyfile
bash start.sh
```

## 重置实验环境

以下操作会删除服务器用户、邀请码、设备、会话、消息和媒体。建议先改名备份：

```bash
cd /home/LanChat/server
docker compose --env-file .env down --remove-orphans
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "../reset-backups/$STAMP"
mv data/control "../reset-backups/$STAMP/control"
mv synapse/data "../reset-backups/$STAMP/synapse-data"
mkdir -p data/control synapse/data
bash start.sh
```

客户端也要删除旧服务器配置后重新添加。

## 常见检查

查看服务状态：

```bash
docker compose --env-file .env ps
```

查看 control 和 bootstrap 日志：

```bash
docker compose --env-file .env logs --tail=200 control synapse-bootstrap
```

如果出现 `matrix_server_name_invalid`，检查 `SYNAPSE_SERVER_NAME` 是否为纯域名，并确认已经重新构建 control：

```bash
docker compose --env-file .env down --remove-orphans
docker compose --env-file .env build --no-cache control
docker compose --env-file .env up -d --force-recreate
```

不要把密码、邀请码、token、`homeserver.yaml`、数据库、签名密钥或 Android 签名文件提交到 Git。

## 开发与构建

```bash
flutter analyze
flutter test
```

服务器版构建：

```powershell
.\tooling\build-lanchat.ps1 -Edition server -Platform android
.\tooling\build-lanchat.ps1 -Edition server -Platform windows
```

控制服务测试：

```bash
cd server/control
dart analyze
dart test
```

本地构建缓存、Rustup、Cargo、Pub 和 Gradle 缓存由构建脚本放在项目所在磁盘，不应提交到 Git。

## 许可证

LanChat 自有代码使用 GNU General Public License v3.0 或更高版本，详见 [`LICENSE`](LICENSE)。Matrix、Synapse、Caddy、Vodozemac、WinToast 及其他依赖保留各自的许可证。
