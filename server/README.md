# LanChat Server Edition

服务器版由三个服务组成：

- `control`：LanChat 账号、邀请码、入群审批、设备审批、管理员控制室和文件策略。
- `synapse`：内部 Matrix 传输层，普通用户不需要接触 Matrix 账号。
- `caddy`：公网 HTTPS 入口，域名模式使用；直连模式不启动。

## 推荐：一键启动

### 域名 HTTPS 模式

要求：Linux、Docker Compose V2、聊天域名、控制室域名，且两个域名都解析到服务器 IP。公网需要开放 TCP `80` 和 `443`。

```bash
cd /home
git clone https://github.com/MikatoMisaka/LanChat.git LanChat
cd /home/LanChat/server
cp .env.example .env
vi .env
bash start.sh
```

`.env` 最少配置：

```dotenv
CHAT_DOMAIN=chat.example.com
ADMIN_DOMAIN=admin.chat.example.com
SYNAPSE_SERVER_NAME=chat.example.com
LANCHAT_SERVER_NAME=My LanChat Server
```

`SYNAPSE_SERVER_NAME` 必须是纯域名或域名加端口，不能写 `https://`、路径或空格。

启动脚本会自动：

- 检查 Docker Compose。
- 创建 `data/` 和 `synapse/data/`。
- 创建缺失的 `Caddyfile`。
- 生成缺失的 `homeserver.yaml`。
- 关闭公开注册，开启用户目录搜索。
- 设置 `public_baseurl`、500 MB Synapse 上传硬上限和 30 天媒体保留。
- 创建内部 `lanchat-control` Matrix 管理账号。
- 构建并启动全部服务。

查看首次管理员初始化口令：

```bash
docker compose --env-file .env logs control
```

打开 `ADMIN_DOMAIN`，输入一次性口令并设置管理员密码。然后生成群组邀请码或单人邀请码。

### 局域网直连模式

先在 `.env` 设置实际地址：

```dotenv
LANCHAT_PUBLIC_BASEURL=http://192.168.1.10:8080/
```

再执行：

```bash
bash start.sh --direct
```

客户端地址为 `http://SERVER_IP:8080`。可以通过 `LANCHAT_CONTROL_PORT` 修改端口。直连 HTTP 只适合可信局域网，不适合公网。

## 目录和配置

```text
server/
├── start.sh                 一键启动脚本
├── .env.example             环境变量模板
├── docker-compose.yml        域名 HTTPS 模式
├── docker-compose.direct.yml IP 和端口直连覆盖
├── Caddyfile.example        Caddy 配置模板
├── control/                 控制服务和管理员控制室
├── synapse/bootstrap.sh     自动初始化内部 Matrix 管理账号
├── data/control/            账号、邀请码、设备和会话数据
└── synapse/data/            Synapse 配置、数据库、密钥和媒体数据
```

不要提交以下内容：

- `.env`
- `Caddyfile`
- `data/`
- `synapse/data/`
- `homeserver.yaml`
- token、密码、签名密钥、数据库和上传文件

## 管理员首次操作

1. 打开控制室域名。
2. 输入日志中的一次性初始化口令。
3. 设置管理员密码。
4. 在首页生成群组邀请码或单人邀请码。
5. 在申请队列中通过或拒绝用户。
6. 在设备队列中审批用户的新设备。
7. 在成员与设备页面管理设备、踢出用户和黑名单。

用户不需要 Matrix 用户 ID、Synapse 管理员账号或 access token。

## 客户端使用流程

1. 客户端添加服务器地址。
2. 填写邀请码、用户名、密码和昵称。
3. 管理员审批入群申请。
4. 用户连接服务器。
5. 用户在成员列表发送好友申请。
6. 对方接受后进入聊天。

服务器版默认限制：

- 图片最多 20 MB。
- 服务器小文件默认最多 100 MB，管理员可调整到 500 MB。
- 小于 2 MiB 的入站图片自动缓存并展示，不自动保存系统相册。
- 大文件通过局域网直连传输。

## 升级已有部署

先备份数据：

```bash
cd /home/LanChat/server
cp -a data "../lanchat-control-backup-$(date +%Y%m%d-%H%M%S)"
cp -a synapse/data "../lanchat-synapse-backup-$(date +%Y%m%d-%H%M%S)"
```

拉取并重建：

```bash
cd /home/LanChat
git pull --ff-only origin master
cd server
bash start.sh
```

如果旧部署中的 `Caddyfile` 没有 `/_matrix/*` 路由，先备份后更新：

```bash
cd /home/LanChat/server
cp Caddyfile "Caddyfile.backup.$(date +%Y%m%d-%H%M%S)"
cp Caddyfile.example Caddyfile
bash start.sh
```

脚本不会覆盖已有 `.env`、`Caddyfile` 或服务器数据。

## 重置实验环境

以下操作会清空用户、邀请码、设备、会话、消息和媒体。推荐先改名备份：

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

## 故障排查

查看服务状态：

```bash
docker compose --env-file .env ps
```

查看启动日志：

```bash
docker compose --env-file .env logs --tail=200 control synapse-bootstrap
```

检查 `SYNAPSE_SERVER_NAME`：

```bash
grep -nE '^(CHAT_DOMAIN|ADMIN_DOMAIN|SYNAPSE_SERVER_NAME|LANCHAT_SERVER_NAME)=' .env
docker compose --env-file .env exec control sh -lc 'printf "<%s>\n" "$SYNAPSE_SERVER_NAME"'
```

如果出现 `matrix_server_name_invalid`，强制重建 control：

```bash
docker compose --env-file .env down --remove-orphans
docker compose --env-file .env build --no-cache control
docker compose --env-file .env up -d --force-recreate
```

如果管理员操作返回 502，查看 control 日志中的 Synapse 状态码。不要把密码、token 或初始化口令发到公共聊天中。

## 手动开发检查

```bash
cd server/control
dart analyze
dart test
node --check web/app.js
```

客户端构建请在仓库根目录执行：

```powershell
.\tooling\build-lanchat.ps1 -Edition server -Platform android
.\tooling\build-lanchat.ps1 -Edition server -Platform windows
```
