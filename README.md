# LanChat

LanChat 是一个使用 Flutter 编写的 Android 和 Windows 聊天软件。它把局域网直连作为主要通信方式，也提供基于 Matrix/Synapse 的自建服务器版。

## 当前状态

- 局域网版可以直接使用，核心功能已经完成并通过测试。
- 服务器版已经有客户端、控制服务和 Docker 部署模板，适合继续做实际服务器验收。
- 通知采用本地通知，不依赖 Firebase、FCM 或常驻推送服务。

## 功能

### 局域网版

- 通过组播、广播和手动方式发现设备。
- 配对前显示设备昵称，使用六位数字确认码确认身份。
- 使用 X25519 密钥协商和 ChaCha20-Poly1305 加密通信。
- 支持文字、图片和文件消息。
- 文件接收需要确认，单个文件最多 5 GiB。
- 文件传输使用分块、断点续传和完整性校验。
- Windows 支持文本选择、复制粘贴和多文件拖放。
- 图片支持全屏查看、缩放、保存和分享。
- 支持表情、最近使用、收藏、自定义贴纸和在线贴纸。

### 服务器版

- 自建 Matrix/Synapse 服务器。
- 服务器地址、用户名、密码和独立接入码登录。
- 远程文字和图片聊天，远程图片默认最多 20 MB。
- 好友申请、接受、拒绝和屏蔽。
- Matrix 客户端数据库保存同步状态，打开聊天时补齐离线消息。
- 管理员控制台支持创建、停用和重置用户，查看和撤销设备。
- 可配置端到端加密模式、图片限制、保留天数和流量配额。
- 大文件继续使用局域网直连，不上传到服务器。
- 应用进程仍在运行时显示本地通知；进程被系统终止后不保持后台推送。

## 通信方式

- 局域网设备之间直接建立加密连接。
- 服务器版的远程文字和图片通过 Matrix/Synapse 转发。
- LanChat 控制服务只负责接入码、管理员配置、统计和 Synapse 管理接口，不复制 Matrix 协议。
- 服务器版和局域网版目前使用两个入口；同一联系人在两个入口之间的自动合并路由仍未完成。

## 开发环境

- Flutter `3.47.0`
- Dart `3.13.0`
- Android SDK / Visual Studio Windows 桌面工具链
- Matrix Dart SDK
- Rustup（用于 Vodozemac）

项目把 Rustup 和 Cargo 放在仓库内的 `.rustup/`、`.cargo/` 目录中。它们已加入 Git 忽略列表。

## 本地运行

```text
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

Windows 构建使用项目内 Rust 工具链：

```powershell
.\tooling\flutter-local-rust.ps1 build windows --release
```

## 构建 APK

Android Release 构建需要本地签名配置和 keystore。不要把 `android/key.properties` 或 `*.jks` 提交到 Git。

基础版：

```powershell
.\tooling\flutter-local-rust.ps1 build apk --release
```

服务器版：

```powershell
.\tooling\flutter-local-rust.ps1 build apk --release --dart-define=LANCHAT_SERVER_EDITION=true
```

## 部署服务器

服务器部署文件位于 `server/`，包括：

- `server/docker-compose.yml`
- `server/control/`：LanChat 控制服务和管理员页面
- `server/Caddyfile.example`：HTTPS 反向代理示例
- `server/synapse/homeserver.yaml.example`：Synapse 配置检查清单
- `server/.env.example`：环境变量示例

完整步骤见 [`server/README.md`](server/README.md)。基本流程如下：

1. 准备一台有公网 IP 的 Linux 服务器，安装 Docker Compose。
2. 为聊天域名和管理员域名配置 DNS，并开放 80、443 端口。
3. 在 `server/` 下创建 `.env` 和 `Caddyfile`。
4. 执行 `docker compose run --rm synapse generate` 生成 Synapse 配置。
5. 检查服务器名、HTTPS 地址、注册开关、20 MB 上传限制和 30 天保留策略。
6. 执行 `docker compose up -d --build` 启动服务。
7. 创建第一个 Synapse 管理员，再把管理员 access token 写入 `SYNAPSE_ADMIN_TOKEN`。
8. 打开管理员域名，创建普通用户。
9. 在服务器版 LanChat 中填写聊天域名、用户名、密码和服务器接入码。

当前开发机没有 Docker，因此 Compose 需要在目标服务器上运行并验证：

```bash
docker compose --env-file .env config
```

## 数据和安全

- 局域网通信在配对并完成身份校验后才启用。
- 服务器地址只接受 HTTPS。
- 用户密码和服务器接入码不写入 SQLite，客户端使用平台安全存储。
- 服务器管理员密码和接入码只保存哈希值。
- 服务端数据位于 Docker 数据卷或绑定目录中，应定期备份并限制权限。
- 不要提交 `.env`、SQLite 数据库、上传文件、签名文件或本地构建缓存。
- 第三方组件的许可证见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

## 测试

```text
flutter analyze
flutter test
```

控制服务测试：

```text
cd server/control
dart pub get
dart analyze
dart test
```

## 发布目录

本地发布产物放在 `release/`，该目录已被 Git 忽略。它可以包含基础版和服务器版 APK，以及 Windows 发布目录。

## 许可证

LanChat 自有代码使用 GNU General Public License v3.0 或更高版本，详见 [`LICENSE`](LICENSE)。Matrix、Synapse、Caddy、Vodozemac、WinToast 及其他依赖保留各自的许可证。
