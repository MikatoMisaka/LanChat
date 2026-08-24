# LanChat 设计文档

日期：2026-08-19
状态：已批准

## 1. 目标

局域网内 Android 手机间互发文本消息和文件/图片，无服务器，纯 P2P。自用/小圈子，不上架商店。技术栈 Flutter（为将来 iOS 留口子）。

## 2. 已确认需求

- 发文本消息、发文件、发图片
- 设备发现三通道：UDP 自动扫描（主）、手动输 IP、扫二维码（后两者在"添加设备"页）
- 纯 P2P 无服务器：对方不在线则显示离线、发送失败，不暂存补发
- 聊天记录存本机 SQLite，支持导出（JSON + 纯文本），支持清空
- 不做：群聊、语音视频、撤回、已读回执、断点续传、iOS 构建（代码保持跨平台）

## 3. 架构（四层，纯 Dart 为主）

```
UI 层      设备页(首页) / 聊天页 / 设置页 / 添加设备页
应用层     消息模型、会话管理、聊天记录(sqflite)
传输层     TCP ServerSocket/Socket，长度前缀 JSON 消息 + 文件字节流
发现层     UDP 组播 239.255.42.99:45678，广播/应答
```

### 3.1 发现协议

- App 前台时每 3 秒组播广播 `{"id","name","ip","tcpPort"}`
- 收到广播的设备单播应答（同样结构）
- 10 秒无应答/广播的设备标记离线，从列表淡出
- Android 需 MulticastLock（Kotlin MethodChannel，约 20 行），发现层启动时 acquire，销毁时 release

### 3.2 消息协议（TCP）

帧格式：`[4字节大端长度][JSON 头]`

头结构：
```json
{"v":1,"type":"text","msgId":"uuid","ts":1234567890}
{"v":1,"type":"file","msgId":"uuid","ts":123,"fileId":"uuid","fileName":"a.zip","size":1024,"mime":"application/zip"}
{"v":1,"type":"image","msgId":"uuid","ts":123,"fileId":"uuid","fileName":"img.jpg","size":2048,"mime":"image/jpeg"}
{"v":1,"type":"receipt","msgId":"uuid","for":"原消息id","status":"received"}
```

- text：头后跟 UTF-8 文本字节
- file/image：头后跟 size 字节原始文件流
- TCP 端口：启动时系统分配（端口 0），经发现协议/二维码内容通告
- 发送失败（连接不上）：消息标记失败，不自动重试

### 3.3 二维码内容

`lanchat://<deviceId>?name=<urlencoded>&ip=<ip>&port=<tcpPort>`

## 4. 页面

1. **设备页（首页）**：在线设备列表（头像/昵称/最近一条消息/在线圆点），右上角"+"进添加设备页；列表含历史会话设备（离线置灰）
2. **聊天页**：微信式气泡；顶部对方昵称+在线状态；底部输入框+附件按钮（选文件/拍照/选图）；文件消息卡片（文件名/大小/进度条/点按保存到下载）；图片消息显示缩略图，点按全屏
3. **设置页**：改昵称、头像（选图）、导出聊天记录（JSON+txt 两个文件到下载目录）、清空所有记录
4. **添加设备页**：输入框 ip:port + 连接按钮；扫码按钮调相机（mobile_scanner）

## 5. 数据

- `devices` 表：id(TEXT PK), name, ip, port, avatarPath, lastSeen, isManual
- `messages` 表：id(TEXT PK), deviceId, direction(0收/1发), type(text/file/image), content, filePath, fileSize, status(0发送中/1已送达/2失败), createdAt
- 收到的文件存 `getApplicationDocumentsDirectory()/files/<deviceId>/<fileId>_<fileName>`
- 头像存 App 文档目录
- 设备自身 id/昵称存 shared_preferences

## 6. 权限（AndroidManifest）

INTERNET, ACCESS_WIFI_STATE, CHANGE_WIFI_MULTICAST_STATE, CAMERA（扫码）, READ_MEDIA_IMAGES（选图，仅 Android 13+；低版本用 READ_EXTERNAL_STORAGE）

## 7. 依赖

sqflite, path_provider, file_picker, image_picker, qr_flutter, mobile_scanner, provider, uuid, shared_preferences, path, intl

## 8. 测试与验收

- 协议编解码、DAO 单元测试
- 双机（真机+真机/模拟器）全流程：发现->聊天->传文件->传图->导出
- 最终产物：release APK（自签名 debug key 即可，自用）
