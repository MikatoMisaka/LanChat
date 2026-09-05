# LanChat Server Edition 实现计划

> **面向 AI 代理的工作者：** 使用已批准的 server-edition 设计逐任务实现。任务顺序固定，每完成一组都运行测试；不要复制 Synapse/Matrix 源码。

**目标：** 为现有 Flutter 客户端增加 Matrix/Synapse 自建服务器版，并提供可复现的 Docker 部署和管理员控制台。

**架构：** 远程聊天使用 Matrix Dart SDK 与 Synapse 官方镜像；LanChat 保留现有安全 P2P 传输。一个远程适配器将 Matrix 房间事件转换为本地 `Message` 视图，路由层按 LAN 可达性选择通道。独立控制服务只处理接入码、管理配置和统计，不实现第二套聊天协议。

**技术栈：** Flutter/Dart、Matrix Dart SDK、Synapse、Dart Shelf 控制服务、SQLite 数据卷、Caddy、Flutter Local Notifications。

---

### 任务 1：服务器配置和凭据模型

**文件：**
- 创建：`lib/services/server_profile.dart`
- 创建：`lib/services/server_profile_store.dart`
- 修改：`lib/services/db_service.dart`
- 测试：`test/server_profile_test.dart`

- [ ] 测试服务器地址只接受 HTTPS、规范化尾斜杠并拒绝查询参数；服务器配置可保存多个实例。
- [ ] 测试用户名、密码和接入码不进入 SQLite；只保存非敏感配置和受保护的令牌引用。
- [ ] 实现配置模型、服务器能力和登录状态；使用现有安全存储桥接保存密码/接入码/令牌。
- [ ] 运行：`flutter test test/server_profile_test.dart`。

### 任务 2：Matrix 远程适配器

**文件：**
- 修改：`pubspec.yaml`
- 创建：`lib/services/remote_matrix_service.dart`
- 创建：`lib/services/remote_message_adapter.dart`
- 测试：`test/remote_matrix_service_test.dart`

- [ ] 测试远程文字事件映射为本地消息，事件 ID 去重，图片大小超过 20 MB 被拒绝。
- [ ] 实现 homeserver 检查、登录、设备恢复、同步监听、用户目录搜索、私聊房间建立、文字发送和图片发送。
- [ ] 远程大文件 API 直接返回不支持；好友申请使用私聊邀请/成员状态映射为待处理关系。
- [ ] 端到端加密模式使用 Matrix SDK 原生密钥管理；可读模式仅在服务器初始化能力明确允许时启用。
- [ ] 运行：`flutter test test/remote_matrix_service_test.dart`。

### 任务 3：服务器版导航和联系人

**文件：**
- 修改：`lib/main.dart`
- 创建：`lib/pages/server_page.dart`
- 创建：`lib/pages/server_chat_page.dart`
- 修改：`lib/pages/devices_page.dart`
- 修改：`lib/pages/chat_page.dart`
- 测试：`test/server_page_test.dart`

- [ ] 测试服务器版显示“局域网 / 服务器 / 个人”，基础版隐藏服务器入口。
- [ ] 实现多服务器配置、登录表单、接入码输入、用户目录、好友申请、同意/拒绝/屏蔽和在线状态。
- [ ] 服务器聊天显示文字和 20 MB 以内图片，隐藏大文件入口；复用现有图片预览和保存组件。
- [ ] 实现同一联系人关联 LAN 设备和 Matrix 用户，LAN 在线时优先直接发送。
- [ ] 运行：`flutter test test/server_page_test.dart`。

### 任务 4：离线同步和本地通知

**文件：**
- 创建：`lib/services/notification_service.dart`
- 创建：`lib/services/remote_sync_store.dart`
- 修改：`lib/services/app_state.dart`
- 修改：`android/app/src/main/AndroidManifest.xml`
- 测试：`test/remote_sync_test.dart`

- [ ] 测试从保存的同步游标恢复 30 天内未处理事件，并将多个发送者的遗漏消息合并为摘要。
- [ ] 实现 Matrix sync 游标、远程消息本地缓存、只保留服务端最近 30 天的请求边界。
- [ ] 接入本地通知插件；后台时显示系统通知，前台时显示应用内提示，进程终止后不保持后台推送。
- [ ] 运行：`flutter test test/remote_sync_test.dart`。

### 任务 5：自建服务器控制服务

**文件：**
- 创建：`server/control/pubspec.yaml`
- 创建：`server/control/bin/server.dart`
- 创建：`server/control/lib/src/config_store.dart`
- 创建：`server/control/lib/src/admin_api.dart`
- 创建：`server/control/lib/src/access_api.dart`
- 创建：`server/control/web/index.html`
- 创建：`server/control/Dockerfile`
- 测试：`server/control/test/admin_api_test.dart`

- [ ] 测试管理员密码哈希验证、接入码轮换、访问令牌过期、单用户/全局图片流量限制和统计聚合。
- [x] 实现 Shelf HTTP API 与静态管理页；所有管理接口需要管理员会话，普通客户端只能访问接入码验证和能力接口。
- [ ] 通过 Synapse Admin API 创建/停用/重置用户和撤销设备，不保存 Matrix 用户密码明文。
- [ ] 记录请求字节、图片上传字节、消息/图片计数和每日统计；端到端加密时不解析正文。
- [ ] 运行：`dart test server/control/test`。

### 任务 6：Docker Compose 和 HTTPS

**文件：**
- 创建：`server/docker-compose.yml`
- 创建：`server/.env.example`
- 创建：`server/Caddyfile.example`
- 创建：`server/synapse/homeserver.yaml.example`
- 创建：`server/README.md`
- 修改：`THIRD_PARTY_NOTICES.md`
- 修改：`docs/OPEN_SOURCE.md`

- [ ] 配置 Synapse、控制服务和 Caddy 的持久化卷、健康检查和重启策略。
- [ ] 设置 Synapse 上传上限 20 MB、注册关闭、30 天保留策略和管理 API 最小权限。
- [ ] 管理子域名与客户端域名分离；示例配置不包含真实域名、密码、接入码或用户数据。
- [ ] 记录 Matrix/Synapse/Caddy、通知插件和控制服务依赖许可证。
- [ ] 运行：`docker compose -f server/docker-compose.yml config`。

### 任务 7：集成验证和发布

**文件：**
- 修改：`README.md`
- 修改：`LICENSE`
- 创建：`.github/workflows/test.yml`
- 创建：`.github/workflows/server-image.yml`
- 测试：`test/`

- [ ] 运行：`flutter analyze`。
- [ ] 运行：`flutter test`。
- [ ] 运行：`dart test server/control/test`。
- [ ] 使用 Docker Compose 做登录、好友申请、文字、20 MB 图片、离线同步和管理员配置验收。
- [ ] 构建 Android server edition、Android basic edition 和 Windows release；确认只上传源码/配置/镜像，不上传密钥或用户数据。
