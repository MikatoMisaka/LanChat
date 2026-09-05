# LanChat 安全传输实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 subagent-driven-development 或 executing-plans 逐任务实现此计划。步骤使用复选框跟踪。

**目标：** 用显式配对、认证加密帧和受限可续传文件传输替换开放式 TCP 协议。

**架构：** 发现服务只产生待配对候选地址；独立的身份服务持有设备密钥和已配对公钥；传输服务只暴露认证后的事件。文件邀请、确认、分块和恢复状态在应用层协调，文件系统仅使用本地生成的路径。

**技术栈：** Flutter/Dart、`cryptography`、项目自有 MethodChannel 安全存储桥接、sqflite、TCP/UDP。

---

### 任务 1：身份模型与密钥存储

**文件：**
- 创建：`lib/services/identity_service.dart`
- 修改：`pubspec.yaml`
- 测试：`test/identity_service_test.dart`

- [ ] 编写失败测试：新身份在安全存储中持久化；相同实例重开后公钥不变；配对码对相同协商密钥稳定且限定六位。
- [ ] 运行：`flutter test test/identity_service_test.dart`，预期：因 `IdentityService` 不存在而失败。
- [ ] 实现：生成 X25519 身份密钥，通过项目自有安全存储桥接保存私钥，以 SHA-256 派生短验证数字；为已配对公钥提供显式增删查 API。
- [ ] 运行同一命令，预期：全部通过。

### 任务 2：清除旧数据并建立新 schema

**文件：**
- 修改：`lib/services/db_service.dart`
- 修改：`lib/services/app_state.dart`
- 测试：`test/db_service_test.dart`

- [ ] 编写失败测试：从 v1 打开数据库时删除旧 `devices`/`messages` 数据，并创建带 `publicKey` 和配对状态的联系人表与传输表。
- [ ] 运行：`flutter test test/db_service_test.dart`，预期：v1 迁移断言失败。
- [ ] 实现：将 schema 升至 v2；在事务内删除遗留记录并创建 `peers`、`messages`、`transfers`、`stickers`；应用启动时删除旧接收目录。
- [ ] 运行同一命令，预期：全部通过。

### 任务 3：安全会话与受限帧

**文件：**
- 创建：`lib/services/secure_session.dart`
- 修改：`lib/services/transport_service.dart`
- 测试：`test/secure_session_test.dart`
- 修改：`test/protocol_test.dart`

- [ ] 编写失败测试：未配对公钥被拒绝；密文可由对应会话解密；修改字节或重复序号被拒绝；8 KiB 头、64 KiB 文本、5 GiB 文件之外的事件被拒绝。
- [ ] 运行：`flutter test test/secure_session_test.dart test/protocol_test.dart`，预期：缺少安全会话或边界验证而失败。
- [ ] 实现：在 socket 首帧完成认证密钥协商；之后以 ChaCha20-Poly1305 加密 `type/sequence/payload` 信封；删除网络头中的 `fromId`、文件路径和未认证昵称；为连接增加空闲计时与全局/每 IP 上限。
- [ ] 运行同一命令，预期：全部通过。

### 任务 4：配对发现与邀请

**文件：**
- 修改：`lib/services/discovery_service.dart`
- 修改：`lib/services/app_state.dart`
- 修改：`lib/pages/add_device_page.dart`
- 修改：`lib/pages/devices_page.dart`
- 测试：`test/discovery_service_test.dart`

- [ ] 编写失败测试：发现包只能构建待配对候选项；候选包不能覆盖已配对联系人地址；一分钟内第二次全网段刷新被限流。
- [ ] 运行：`flutter test test/discovery_service_test.dart`，预期：候选与配对状态未区分而失败。
- [ ] 实现：发现 payload 仅包含昵称、临时公钥和地址；扫码或手动 IP 建立配对邀请；两端确认验证数字才持久化联系人。默认广播保留，手动逐 IP 扫描按一分钟冷却。
- [ ] 运行同一命令，预期：全部通过。

### 任务 5：确认式断点续传

**文件：**
- 修改：`lib/services/transport_service.dart`
- 修改：`lib/services/app_state.dart`
- 修改：`lib/services/db_service.dart`
- 测试：`test/file_transfer_test.dart`

- [ ] 编写失败测试：未确认邀请不创建文件；非法远端 ID 不能改变本地路径；中断后保存偏移；恢复仅发送剩余块；完成前 `.part` 文件不显示为消息附件。
- [ ] 运行：`flutter test test/file_transfer_test.dart`，预期：邀请、路径隔离和恢复 API 缺失而失败。
- [ ] 实现：定义 `offer/accept/chunk/pause/resume/complete` 加密事件；每块写随机本地 `.part`，完成后校验并原子改名；持久化传输状态；在 60 秒无进度或两小时后暂停。
- [ ] 运行同一命令，预期：全部通过。

### 任务 6：Android 发布边界

**文件：**
- 修改：`android/app/src/main/AndroidManifest.xml`
- 修改：`android/app/build.gradle.kts`
- 创建：`android/key.properties.example`
- 修改：`.gitignore`

- [ ] 编写配置检查：release 不再引用 `signingConfigs.debug`，Manifest 禁用全局明文流量与自动备份。
- [ ] 生成不受版本控制的 release keystore 和 `android/key.properties`，并以环境/本机路径读取。
- [ ] 运行：`flutter build apk --release`，预期：生成使用 release 签名的 APK。
