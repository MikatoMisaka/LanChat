# LanChat 桌面交互与玉绿 UI 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 subagent-driven-development 或 executing-plans 逐任务实现此计划。步骤使用复选框跟踪。

**目标：** 提供桌面级复制、拖放、媒体预览、表情管理与一致的绿色白色聊天体验。

**架构：** ChatPage 继续是会话容器，提取媒体预览、待发送附件和表情数据组件；UI 仅消费应用层的安全事件和传输状态，不直接操作 socket。

**技术栈：** Flutter Material 3、`desktop_drop`、`file_selector`、现有 image/file picker。

---

### 任务 1：玉绿主题与动效基元

**文件：**
- 修改：`lib/main.dart`
- 创建：`lib/widgets/chat_theme.dart`
- 测试：`test/widget_test.dart`

- [ ] 编写失败组件测试：主题使用暖白画布、玉绿主操作色且在 `disableAnimations` 下不创建过渡动画。
- [ ] 运行：`flutter test test/widget_test.dart`，预期：主题组件缺失而失败。
- [ ] 实现：集中颜色、间距、圆角、短动效曲线和可访问焦点样式；桌面与移动端共用 token。
- [ ] 运行同一命令，预期：全部通过。

### 任务 2：Windows 选择、复制与附件拖放

**文件：**
- 修改：`lib/pages/chat_page.dart`
- 修改：`pubspec.yaml`
- 测试：`test/chat_page_test.dart`

- [ ] 编写失败组件测试：文本消息在 `SelectionArea` 中；右键菜单含复制；拖入多文件创建待发送列表而不是直接发送。
- [ ] 运行：`flutter test test/chat_page_test.dart`，预期：选择和待发送托盘不存在而失败。
- [ ] 实现：桌面端包裹消息文本选择区，提供右键复制；以 `desktop_drop` 接收文件，显示名称/大小/删除按钮，点击发送后调用既有安全文件邀请流程。
- [ ] 运行同一命令，预期：全部通过。

### 任务 3：图片预览、保存与分享

**文件：**
- 创建：`lib/widgets/media_preview.dart`
- 修改：`lib/pages/chat_page.dart`
- 测试：`test/media_preview_test.dart`

- [ ] 编写失败组件测试：点击图片打开可缩放预览；桌面菜单暴露另存为；移动端长按暴露保存和分享动作。
- [ ] 运行：`flutter test test/media_preview_test.dart`，预期：预览组件不存在而失败。
- [ ] 实现：使用 `InteractiveViewer` 和 Hero 打开全屏预览；平台化保存/分享由文件选择器和现有分享插件处理；读不到文件时显示可恢复错误状态。
- [ ] 运行同一命令，预期：全部通过。

### 任务 4：表情最近、收藏与自定义

**文件：**
- 修改：`lib/services/sticker_service.dart`
- 修改：`lib/widgets/sticker_picker.dart`
- 修改：`lib/services/db_service.dart`
- 测试：`test/sticker_service_test.dart`

- [ ] 编写失败测试：发送表情写入最近记录；收藏状态跨重启保留；添加本地图片时复制到应用目录且不使用原始路径。
- [ ] 运行：`flutter test test/sticker_service_test.dart`，预期：收藏和自定义 API 缺失而失败。
- [ ] 实现：持久化最近和收藏项；导入本地图片到 app sticker 目录；将选择器拆为最近、收藏、自定义、emoji、在线五个标签；在线下载限制响应大小和图片类型。
- [ ] 运行同一命令，预期：全部通过。

### 任务 5：回归与平台构建

**文件：**
- 修改：`test/protocol_test.dart`
- 修改：`test/widget_test.dart`

- [ ] 运行：`flutter analyze`，预期：无问题。
- [ ] 运行：`flutter test`，预期：全部通过。
- [ ] 运行：`flutter build apk --release`，预期：成功。
- [ ] 运行：`flutter build windows --release`，预期：成功。
