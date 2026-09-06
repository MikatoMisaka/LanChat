# LanChat 服务器版体验修复实施计划

> **面向 AI 代理的工作者：** 使用本计划逐项实现。每个行为变更先写失败测试，再写最小实现；不要改动局域网 P2P 协议。

**目标：** 修复 Android 服务器版的多服务器管理、表单反馈、成员目录、好友申请、设备撤销和远程附件问题，并让 Windows 服务器版与 Android 服务器版行为一致。

**架构：** 服务器配置是本地 profile，在线检测只读服务器健康/能力接口；服务器成员目录和好友状态由 LanChat API 提供，Matrix/Synapse 只作为内部聊天传输层。管理员网页继续使用本地 HTML/CSS/JS，并扩展为成员、设备、邀请码、资源和运行状态控制室。

**技术栈：** Flutter/Dart、Matrix Dart SDK、Dart Shelf、文件数据卷、Docker Compose、Caddy。

---

## 任务 1：多服务器 profile 管理

**文件：**

- 修改：`lib/services/server_profile.dart`
- 修改：`lib/services/server_profile_store.dart`
- 修改：`lib/pages/server_page.dart`
- 测试：`test/server_profile_test.dart`

- [x] 保存最近使用的服务器 ID。
- [x] 支持编辑名称、地址、用户名、密码、邀请码和兼容旧接入码。
- [x] 支持删除 profile，并清理安全存储和本地远程数据库。
- [x] 桌面端使用左侧列表和右侧详情，移动端使用上下布局。
- [x] 页面打开自动连接最近服务器，同时保留切换入口。
- [x] 页面打开和每 30 秒执行服务器状态检测，显示最近检测时间和错误原因。

## 任务 2：表单校验和状态反馈

**文件：**

- 创建或修改：`lib/services/server_form_validator.dart`
- 修改：`lib/pages/server_page.dart`
- 修改：`lib/services/server_api_service.dart`
- 测试：`test/server_form_validator_test.dart`
- 测试：`test/server_api_service_test.dart`

- [x] 添加服务器表单按服务器、账号、加入方式分组。
- [x] 地址实时校验 `http/https`、IP、域名、端口和非法 query/userinfo。
- [x] 密码显示明确规则：8 至 128 位，允许任意字符。
- [x] 用户名、昵称、邀请码实时校验。
- [x] 区分申请、待审批、设备待审批、认证失败、服务器不可达和账号禁用。
- [x] 申请模式要求邀请码，已有账号登录模式允许邀请码为空。

## 任务 3：成员目录和好友关系

**文件：**

- 修改：`server/control/lib/control_server.dart`
- 修改：`server/control/lib/join_store.dart`
- 修改：`lib/services/server_api_service.dart`
- 修改：`lib/services/remote_matrix_service.dart`
- 修改：`lib/pages/server_page.dart`
- 修改：`lib/services/remote_message_adapter.dart`
- 测试：`server/control/test/control_api_test.dart`
- 测试：`test/server_api_service_test.dart`

- [x] 增加需要用户 session 的成员目录 API。
- [x] 默认加载所有已批准且未禁用成员，搜索只做客户端筛选。
- [x] 返回在线状态、好友状态和申请状态。
- [x] 已有好友直接打开会话。
- [x] 非好友才调用 `startDirectChat`。
- [x] 待发送申请禁止重复提交。
- [x] 记录并显示 Matrix 房间创建错误，不再只显示泛化失败信息。

## 任务 4：设备撤销和重审批

**文件：**

- 修改：`server/control/lib/join_store.dart`
- 修改：`server/control/lib/session_store.dart`
- 修改：`server/control/lib/control_server.dart`
- 修改：`server/control/web/app.js`
- 测试：`server/control/test/join_store_test.dart`
- 测试：`server/control/test/control_api_test.dart`

- [x] 撤销立即使 LanChat session 和对应 Matrix device 失效。
- [x] 被撤销设备再次登录时进入 `device_pending`，不永久拒绝。
- [x] 重新批准后生成新的 Matrix device mapping。
- [x] 管理员页面区分 pending、approved、revoked。
- [x] 禁用/恢复用户时同步处理会话和内部 Matrix 账号状态。

## 任务 5：远程小文件、表情和额度

**文件：**

- 修改：`server/control/lib/config_store.dart`
- 修改：`server/control/lib/control_server.dart`
- 修改：`server/control/web/index.html`
- 修改：`server/control/web/app.js`
- 修改：`lib/services/remote_matrix_service.dart`
- 修改：`lib/services/remote_message_adapter.dart`
- 修改：`lib/pages/server_chat_page.dart`
- 修改：`lib/widgets/sticker_picker.dart`
- 测试：`server/control/test/config_store_test.dart`
- 测试：`server/control/test/matrix_proxy_test.dart`
- 测试：`test/remote_matrix_service_test.dart`

- [x] 增加默认 100 MB、可调 1 至 500 MB 的服务器小文件上限。
- [x] 图片保持独立的 20 MB 上限。
- [x] 文件消息支持选择、发送、下载和状态显示。
- [x] Emoji 作为文本发送，贴纸作为加密图片发送。
- [x] Matrix 代理使用流式请求，不将整个附件一次性缓冲到内存。
- [x] 按用户和全局额度限制附件流量，超限返回 429/413。
- [x] 大文件继续显示局域网直连入口，不上传服务器。

## 任务 6：管理员控制室

**文件：**

- 修改：`server/control/lib/control_server.dart`
- 修改：`server/control/lib/config_store.dart`
- 创建：`server/control/lib/synapse_policy_store.dart`
- 修改：`server/control/web/index.html`
- 修改：`server/control/web/styles.css`
- 修改：`server/control/web/app.js`
- 测试：`server/control/test/control_web_test.dart`
- 测试：`server/control/test/control_api_test.dart`

- [x] 增加邀请码列表、类型、使用次数、过期时间和撤销。
- [x] 增加成员、设备、会话和状态操作。
- [x] 增加 control/Synapse/Caddy 状态和最近同步时间。
- [x] 增加图片、小文件、保留时间和流量设置。
- [x] 配置保存后显示 Synapse 重启提示，不提供 Docker socket 或网页重启按钮。
- [x] E2EE 固定开启，页面不提供服务器可读开关。

## 任务 7：配置策略和发布

**文件：**

- 修改：`server/docker-compose.yml`
- 修改：`server/docker-compose.direct.yml`
- 修改：`server/synapse/bootstrap.sh`
- 修改：`server/README.md`
- 修改：`README.md`
- 修改：`pubspec.yaml`
- 创建或修改：`tooling/build-lanchat.ps1`
- 修改：`lib/services/edition.dart`
- 测试：`test/edition_test.dart`

- [x] Synapse 生成配置继续保留，不覆盖部署数据。
- [x] 保留策略和上传策略更新后显示是否需要重启。
- [x] Android/Windows 基础版和服务器版使用明确的独立构建命令。
- [x] 版本号提升，Android build number 单调递增。
- [x] README 写清从 clone/pull 到启动、初始化、入群和升级的完整流程。

## 任务 8：验收

- [x] 运行 `flutter analyze` 和 `flutter test`。
- [x] 运行控制服务 `dart analyze` 和 `dart test`。
- [x] 构建基础版和服务器版 Android APK。
- [x] 构建基础版和服务器版 Windows Release。
- [ ] 使用 Docker 主机验收两台服务器 profile、成员目录、好友、附件和撤销重审批。
- [x] 检查 Git 差异，不包含 `.env`、密钥、数据库、token、构建产物和部署数据。
