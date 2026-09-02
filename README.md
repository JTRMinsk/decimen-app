# Decimen 光传（Android）

用 Flutter 复刻 [decimen-optical-transfer](https://github.com/bashalarmistalt/decimen-optical-transfer) 光传协议的
Android 应用。文件/文本 → 喷泉码分帧 → 全屏动态二维码流；另一端摄像头扫二维码 → 喷泉码重组 →
SHA-256 校验 → 保存文件或显示文本。**两端完全无网络**，只需要摄像头权限。

**与网页版（decimen.app）线上兼容（wire v3）**：APP 发的码网页版能收，网页版发的码 APP 能收，
文本片段双向互通。协议层逐函数移植自参考实现的 `shared/*.ts`，并用 golden vectors
（固定字节指纹）锁死，见 `test/`。

## 结构

```
lib/src/protocol/   纯 Dart、零 Flutter 依赖，可独立单测
  fountain.dart     系统轮播喷泉码（sweep + mid-degree repair；v1 soliton 仍 golden-test）
  protocol.dart     22 字节 v3 帧头 + DCF2 文件容器 + SHA-256 / gzip / FNV-1a
  frame_capacity.dart  blockLength / fitsInOneStream / …
  snippet.dart       文本片段容器（application/vnd.decimen.snippet）
  progress.dart      进度估算与喷泉码开销模型
  send_settings.dart 帧率 / 帧字节选项
  display.dart / format.dart / qr_raster.dart
lib/src/app/       UI / 相机 / 文件
  sender_screen.dart   发送端（选文件 / 粘贴文本 → 二维码流）
  receiver_screen.dart 接收端（camera → mobile_scanner → 重组 → SAF 保存）
  qr_encoder.dart / qr_painter.dart / mime_types.dart / pack_background.dart
test/               golden vector 测试（线协议兼容性的硬证据）
```

## 构建

要求：Flutter（stable）、Android SDK（compileSdk 36）、JDK 17。

```bash
flutter pub get
flutter build apk --debug     # 产物：build/app/outputs/flutter-apk/app-debug.apk
flutter build apk --release   # 产物：build/app/outputs/flutter-apk/app-release.apk
```

## 测试

```bash
flutter test       # 全部 golden vectors 必须全绿
flutter analyze    # 应输出 "No issues found!"
```

## 协议红线（移植时不可违反）

- `dlog()` 是自实现的确定性对数（精确指定的 IEEE-754 运算序列），**绝不能换成 `dart:math` 的 `log`**——原生
  log 是平台近似实现，收发端 soliton 分布差 1 ulp 就会静默全盘失败。
- `splitmix32` / `fnv1a` 逐位移植，Dart 侧用 `& 0xffffffff` 模拟 32 位运算与无符号右移。
- gzip 用 `dart:io` 顶层 `gzip` codec（标准 RFC-1952，与网页端 `CompressionStream("gzip")` 互解）；
  压缩决策照搬 `isPrecompressedType`（JPEG/PNG/MP4/ZIP 等预压缩类型直接跳过）。
- 帧头 22 字节小端（wire v3）：`magic 0xD1 0xC3 + version u8 + flags u8 + sessionId u16 + seq u32 + k u16 + blockLen u16 + totalLen u32 + payloadFnv u32`。
- 遇到旧版（magic1 `0x0C`/`0x0D`）或更新版本时必须**说出来**，不能再静默丢帧。
- 当前发射的喷泉码是系统轮播（`frameComposition`），不是 v1 的 robust-soliton 流。

## 与网页版互测清单

1. **APP 发送 → 网页版接收**：打开 decimen.app 的接收页，APP 选文件开始播放二维码，
   网页版应在校验通过后收到文件。
2. **网页版发送 → APP 接收**：网页版发送页选文件，APP 进入「接收」对准屏幕，应在 SHA-256 校验通过后提示保存。
   若手机相机扫不动默认的 60fps / 2953 字节码，把网页发送端降到 24 fps / 1465 字节。
3. **文本片段双向**：两端发送文本，接收端应直接显示文本（媒体类型 `application/vnd.decimen.snippet`）。
4. **丢帧只降速不错乱**：发送中途把手机屏幕遮挡 / 息屏几秒再继续，接收端应继续推进（进度变慢但不错乱），
   最终仍能完整恢复。

## 说明

- **不加密**：界面已标注「明文光传，摄像头可读」。屏幕上的内容可被任何指向它的摄像头读取。
- **权限**：只申请 `CAMERA`。保存文件走 Android 10+ 的 SAF（`ACTION_CREATE_DOCUMENT`），无需存储权限。
- **发送帧率 / 帧字节**：默认 60fps / 2953 字节（对应 `send-settings.dart` 默认值），可在发送页调整；
  接收端无需任何设置，中途锁定流（`streamIdentity`）任一字段变化即重建解码器。
