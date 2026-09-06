# 服务器聊天与移动端问题修复计划

> **面向 AI 代理的工作者：** 按任务顺序执行，保留当前工作树已有改动，不使用破坏性 Git 操作。

**目标：** 修复服务器版移动端页面和连接流程，审计好友、文字、图片、文件聊天链路，并实现小于 2 MiB 入站图片自动缓存展示。

**架构：** 保留现有 `ServerPage`、`RemoteMatrixService` 和 `ServerChatPage` 分层。服务器页面负责连接和成员刷新；Matrix 服务负责好友、消息和附件状态；独立附件缓存负责小图片自动接收、缓存和下载去重。

**技术栈：** Flutter/Dart、Matrix SDK、Dart test、Flutter widget tests、现有 server control API。

---

## 文件范围

- 修改：`lib/pages/server_page.dart`，移动服务器选择器、成员刷新和申请/登录流程。
- 修改：`lib/widgets/server_profile_editor.dart`，修复键盘弹起时的 Dialog 约束。
- 修改：`lib/services/server_api_service.dart`，保留服务端业务错误并校验完整 Matrix 用户 ID。
- 修改：`lib/services/remote_matrix_service.dart`，好友状态、消息合并、附件缓存入口和大小边界。
- 修改：`lib/pages/server_chat_page.dart`，实时消息合并、图片缓存展示和文件操作。
- 新增：`lib/services/remote_attachment_cache.dart`，应用缓存中的图片下载、去重和清理。
- 修改：`test/server_api_service_test.dart`，业务错误和完整用户 ID 测试。
- 修改：`test/server_profile_editor_test.dart`，键盘 inset 和申请加入模式测试。
- 修改：`test/remote_matrix_service_test.dart`，好友状态、消息去重和图片自动接收策略测试。
- 新增：`test/remote_attachment_cache_test.dart`，缓存键、大小阈值和重复下载测试。
- 修改：`server/control/test/control_api_test.dart`，目录用户 ID 格式回归测试。
- 可能修改：`server/control/lib/control_server.dart`，仅在目录 ID 回归测试证明服务端仍可返回裸 ID 时修复；否则保持现有映射。

当前已有未提交改动必须保留：

- `lib/pages/server_page.dart`
- `lib/services/server_api_service.dart`
- `lib/widgets/server_profile_editor.dart`
- `test/server_api_service_test.dart`

---

### 任务 1：建立基线与现有改动保护

- [ ] 检查 `git status --short`、`git diff --check` 和当前 HEAD，记录已有四个改动文件。
- [ ] 运行服务器相关测试和 `flutter analyze`，区分已有失败与本次新增失败。
- [ ] 不执行 `git reset`、`git checkout` 或清理未提交文件。

### 任务 2：修复移动端服务器选择器

- [ ] 增加移动端行为测试，验证当前服务器摘要可见，点击后显示服务器选项，选择后收起。
- [ ] 将 `server_page.dart` 移动布局中的固定 `SizedBox(height: 300)` 改为顶部紧凑选择器。
- [ ] 保留桌面端宽屏左侧列表和已有编辑/删除入口。
- [ ] 验证空服务器列表、单服务器、多服务器、切换服务器和连接中状态。

### 任务 3：修复服务器编辑 Dialog 的键盘布局

- [ ] 增加带 `MediaQuery.viewInsets.bottom` 的 widget 测试，覆盖小屏和键盘弹出场景。
- [ ] 移除 `Dialog` 已处理的键盘 inset 在内容底部的重复 padding。
- [ ] 使用 Dialog 实际布局约束限制滚动区域高度，不再单独使用完整屏幕高度推导最大高度。
- [ ] 保证 `SingleChildScrollView` 是唯一滚动区域，焦点输入框可见但不会被顶到屏幕顶部。
- [ ] 保留表单验证、邀请码自动进入“申请加入”模式和底部按钮行为。

### 任务 4：修复申请加入、登录和成员目录同步

- [ ] 为已保存邀请码、待审批申请、已批准账号、设备被撤销四种状态增加测试。
- [ ] 完成 `_connectStored` 的状态分支，避免首次失败后错误走已有账号登录。
- [ ] 成功连接后立即刷新完整成员目录。
- [ ] 定时器同时刷新成员目录和服务器状态，并防止并发请求覆盖较新的结果。
- [ ] 好友申请、接受、拒绝和实时 Matrix 事件后重新计算成员好友状态。
- [ ] 验证目录查询使用服务器会话 token，不回退到延迟更高且可能返回不完整 ID 的 Matrix 搜索。

### 任务 5：修复完整 Matrix 用户 ID

- [ ] 先用服务端回归测试验证 `/api/v1/directory/users` 返回 `@username:server-name`。
- [ ] 检查 `SYNAPSE_SERVER_NAME` 注入到 control 的路径，只有测试失败时才修改服务端。
- [ ] 客户端解析目录时拒绝空 ID、裸用户名和不符合 Matrix 格式的 ID。
- [ ] 好友申请发送前再次校验目标用户 ID，错误提示包含具体用户而不是通用请求失败。
- [ ] 覆盖 `aaaa` 不应进入 Matrix 请求的回归测试。

### 任务 6：审计并修复好友申请链路

- [ ] 测试 `none`、`outgoingPending`、`incomingPending`、`friends` 四种状态的按钮和操作限制。
- [ ] 验证只能对完整目录用户发起申请，重复申请和已是好友时返回明确业务错误。
- [ ] 验证入站邀请只显示有效的直接好友申请，接受后房间成员状态变为 joined。
- [ ] 验证拒绝申请、离开邀请房间和页面刷新不会残留错误状态。
- [ ] 审计直接房间查找、对方成员状态和未接受申请时禁止发送消息的逻辑。

### 任务 7：审计文字消息链路

- [ ] 测试历史消息加载、实时事件、发送成功和发送失败。
- [ ] 按 event ID 合并历史和实时消息，避免重复或因加载竞态丢失消息。
- [ ] 验证只处理目标房间的实时事件，其他房间事件不污染当前聊天列表。
- [ ] 验证空白文字、超长文字、未建立好友关系和房间不存在时的错误处理。
- [ ] 验证发送后刷新不会覆盖刚刚到达的入站消息。

### 任务 8：实现小图片自动接收缓存

- [ ] 先写失败测试：入站图片 `size < 2 * 1024 * 1024` 时进入应用缓存；等于或超过阈值时不自动下载。
- [ ] 新增 `RemoteAttachmentCache`，使用 `getTemporaryDirectory()` 保存缓存文件，并以 event ID 生成稳定键。
- [ ] 为同一个 event ID 复用正在进行的 Future，避免实时事件、图片组件和重建重复下载。
- [ ] 下载后再次校验实际解密字节数；实际超出阈值时删除缓存并返回手动下载错误。
- [ ] 下载失败不能丢弃聊天消息，图片组件显示失败状态并允许再次加载。
- [ ] `RemoteMatrixService._onTimelineEvent` 对符合条件的入站图片启动后台缓存，但不阻塞文字消息事件分发。
- [ ] `ServerChatPage` 优先读取缓存图片，禁止自动写入系统相册。
- [ ] 缓存清理只清理应用缓存，不影响消息事件和用户手动保存文件。

### 任务 9：审计图片和文件收发

- [ ] 测试图片发送的本地大小、服务端能力上限、空文件和读取失败。
- [ ] 测试文件发送的默认 100 MB、服务端调整上限和绝对 500 MB 上限。
- [ ] 检查 `readAsBytes()` 对大文件的内存风险；如果 Matrix SDK 支持路径/流式上传，改用流式接口；否则明确限制并增加错误保护。
- [ ] 验证附件事件的文件名、大小、MXC URI、图片/文件类型解析。
- [ ] 验证图片手动下载、文件手动保存、解密失败和服务器限制错误。
- [ ] 修复文件发送按钮文案，使其反映服务器实际可用上限而不是固定误导文本。

### 任务 10：完整验证与发布产物

- [ ] 运行 `dart format --output=none` 检查所有变更 Dart 文件。
- [ ] 运行完整 `flutter test` 和 `flutter analyze`。
- [ ] 运行完整 server control `dart test`、`dart analyze` 和 Node/Compose 检查。
- [ ] 构建服务器版 Android APK 和 Windows Release。
- [ ] 对照需求逐项检查：服务器下拉、键盘、首次申请、成员刷新、完整 user ID、好友、文字、图片、文件和小图片自动缓存。
- [ ] 检查最终 `git diff`，不加入应用层自动重试、不覆盖用户未提交改动。
- [ ] 只报告实际验证过的结果；提交、推送和目标机部署作为最后独立步骤处理。
