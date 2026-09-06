# LanChat 轻量服务器版实现计划

> **面向 AI 代理的工作者：** 使用已批准的 lightweight-server 设计逐任务实现。客户端、控制服务和管理页面必须保持简单；不要把 Matrix/Synapse 内部配置暴露给用户。

**目标：** 将现有服务器版骨架改为邀请码申请、管理员审批、用户名密码登录和单入口远程聊天的轻量 MVP。

**架构：** LanChat 控制服务负责申请、审批、账号会话、设备和消息 API；Matrix/Synapse 如保留只在 Docker 内部运行。客户端通过 LanChat API 获取会话和同步数据，不再直接要求用户理解 Matrix 账号。管理 Web 页面使用无框架 HTML/CSS/JS，首页优先展示状态和待审批申请。

**技术栈：** Flutter/Dart、Dart Shelf、Matrix/Synapse 内部后端、SQLite/文件数据卷、Caddy 可选 HTTPS。

---

### 任务 1：申请与账号模型

**文件：**
- 创建：`server/control/lib/join_store.dart`
- 创建：`server/control/lib/session_store.dart`
- 修改：`server/control/lib/config_store.dart`
- 测试：`server/control/test/join_store_test.dart`

- [x] 加入群组邀请码和单人邀请码模型。
- [x] 保存待审批申请、审批状态、用户名、昵称、密码哈希和设备信息；不保存普通用户密码明文。
- [x] 生成一次性管理员初始化口令和每台设备的会话状态。
- [x] 覆盖重复用户名、邀请码失效、申请状态转换和设备撤销。

### 任务 2：单入口控制 API

**文件：**
- 修改：`server/control/lib/control_server.dart`
- 修改：`server/control/bin/server.dart`
- 测试：`server/control/test/control_api_test.dart`

- [x] 增加加入申请、申请状态、用户登录和设备登录 API；消息同步继续由现有内部 Matrix 传输层提供。
- [x] 增加管理员待审批列表、通过、拒绝、禁用用户和撤销设备 API。
- [x] 管理员初始化只允许一次；日常配置不再要求 Synapse 管理 token。
- [x] 客户端地址校验支持 IP、域名和自定义端口；内部服务端口不出现在管理员页面。

### 任务 3：客户端服务器流程

**文件：**
- 创建：`lib/services/server_api_service.dart`
- 修改：`lib/services/server_profile.dart`
- 修改：`lib/services/server_profile_store.dart`
- 修改：`lib/services/remote_matrix_service.dart`
- 修改：`lib/pages/server_page.dart`
- 修改：`lib/pages/server_chat_page.dart`
- 测试：`test/server_api_service_test.dart`

- [x] 将服务器表单改为地址、邀请码、用户名、密码和昵称，并保留旧服务器兼容折叠项。
- [x] 提交申请并提供登录状态 API；通过后会把会话 token 写入平台安全存储。
- [x] 远程图片继续限制 20 MB，远程大文件入口保持隐藏。
- [x] 服务器地址模型允许 HTTP IP，并在客户端添加非 HTTPS 安全提示。
- [x] 将新的 LanChat 会话作为唯一认证入口；Matrix SDK 仅使用服务器换发的内部 token 同步聊天。

### 任务 4：管理员 Web 页面

**文件：**
- 重写：`server/control/web/index.html`
- 创建：`server/control/web/styles.css`
- 创建：`server/control/web/app.js`

- [x] 使用控制室视觉方向：状态总览、申请队列、用户/设备页、设置页。
- [x] 响应式适配手机和桌面；不引入 CDN 或前端框架。
- [x] 审批操作提供明确状态反馈，危险操作要求二次确认。
- [x] 删除当前复杂的 Matrix/Synapse token 和手动创建用户表单。

### 任务 5：默认部署

**文件：**
- 修改：`server/docker-compose.yml`
- 修改：`server/.env.example`
- 修改：`server/Caddyfile.example`
- 修改：`server/README.md`
- 修改：`README.md`

- [x] 默认配置允许省略管理员密码和群组邀请码，首次启动从日志完成初始化。
- [x] Caddy 作为可选前置代理；直连模式通过控制入口内部代理 Matrix，不依赖证书。
- [x] 保持数据目录、密钥和环境变量不入 Git。
- [x] 写出首次启动、申请审批、创建会话和升级的完整步骤。

### 任务 6：验证与发布

**文件：**
- 修改：`.github/workflows/test.yml`
- 测试：`test/`、`server/control/test/`

- [x] 运行 Flutter 和控制服务全量测试。
- [ ] 使用 Docker 主机验收申请、审批、登录、消息、图片、撤销设备和重启恢复。
- [x] 构建服务器版 Android 和 Windows Release 产物。
- [x] 审计 Git 差异，确认没有密码、私钥、数据库和部署数据。
