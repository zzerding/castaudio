# 投音 Mac — 架构说明

参考项目：`/Users/zzerd/Documents/src/zzerduk/googlecast`（Android/Kotlin，"ScreenCast Audio"）
本项目：macOS 原生 Swift 应用，用 macOS 的公开 API 重做 Android 版的三条核心能力。

## 1. 参考项目在做什么

Android 版是一条完整的「本机应用音频 → Google Cast 音箱」链路：

| 层 | Android 实现 | 文件 |
|---|---|---|
| 采集 | `AudioPlaybackCapture`，按 UID 白名单回采指定应用的播放音频（48kHz 立体声 PCM16） | `media/AudioCastCaptureService.kt` |
| 本机静音 | Shizuku + `VolumeShaper` 定向静音单个应用；无 Shizuku 时降级为全局媒体静音或仅采集不静音 | `shizuku/ShizukuSessionMuteController.kt`、`media/PhoneGlobalMediaMuteController.kt` |
| 传输 | WebRTC（48kHz 立体声 PCM）经 Cast 自定义接收器（receiver app id `9098830C`）投送 | `webrtc/WebRtcAudioSession.kt` |
| 兜底 | Ktor 分块 HTTP 推 ADTS AAC 流 | `media/AudioStreamConfig.kt` |
| 音箱控制 | 官方 Cast SDK：`CastSession` 音量/静音，读写 `Cast.Listener.onVolumeChanged()` | `cast/CastSdkSessionController.kt` |
| 目标管理 | `CaptureTargetRepository` + `TargetPreset` 命名组合持久化 | `target/CaptureTargetRepository.kt` |
| UI | Compose 深色「Dark Studio Console」，四维状态灯 + dBFS 表 + 音量滑块 | `ui/ScreenCastAudioScreen.kt` |

## 2. macOS 端的对应方案

### 2.1 采集：ScreenCaptureKit（替代 AudioPlaybackCapture）

macOS 没有公开的「按应用回采播放音频」API。对应能力由 **ScreenCaptureKit** 提供：

- `SCShareableContent.getShareableContent` 枚举当前运行的 `SCRunningApplication` 与 `SCWindow` → 对应 Android 的目标应用列表。
- `SCContentFilter(display:includingApplications:exceptingWindows:)` 按应用过滤采集范围。
- `SCStreamConfiguration`：`capturesAudio = true`、`sampleRate = 48000`、`channelCount = 2`、`excludesCurrentProcessAudio = true` → 对应 Android 的 48kHz 立体声 PCM16。
- `SCStreamOutputType.audio` 回调拿到 `CMSampleBuffer`，取 `AudioBufferList` 的 PCM 字节。

关键约束：**需要用户授予「屏幕录制」权限**（系统设置 → 隐私与安全性 → 屏幕录制），这是 Android `MediaProjection` 弹窗权限的 macOS 对应物，必须在 UI 里做成显式的授权引导步骤。

`excludesCurrentProcessAudio = true` 是必须的，否则投音应用自身播放的声音会形成回授。

### 2.2 本机静音：降级为两档（Shizuku 定向静音在 macOS 无对应）

Android 的 Shizuku 定向静音依赖 Android 专有的 `VolumeShaper` 独占 ID 机制，macOS 无公开等价物。保留 Android 参考实现里**已经存在的备选模式**，砍掉 Shizuku 专属档：

| Android 档位 | macOS 档位 | 说明 |
|---|---|---|
| `SHIZUKU_SESSION_MUTE`（定向静音） | **删除** | macOS 无公开 API 实现单应用静音 |
| `GLOBAL_MEDIA_MUTE`（全局媒体静音） | **保留**，改为系统输出音量归零 | 需先快照当前输出音量，停止时恢复；用户在投放中手动调过音量则尊重用户操作不覆盖 |
| `CAPTURE_ONLY_UNMUTED`（仅采集不静音） | **保留** | 本机与音箱同时发声 |

系统输出音量用 CoreAudio 的 `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` 读写。

### 2.3 传输：Cast V2 + 本机 HTTP 分块推 ADTS AAC

macOS 上没有可用的官方 Cast 发送端 SDK（Google Cast iOS SDK 不支持 macOS 原生，只支持 Catalyst，而 Catalyst 无法用 ScreenCaptureKit 采集本机应用音频）。因此直接实现 **Cast V2 协议**：

- 设备发现：Bonjour `_googlecast._tcp`（NWBrowser + TXT 记录）。
- 传输层：TLS 8009 端口，protobuf 编码的 `CastMessage`。
- 命名空间：`urn:x-cast:com.google.cast.tp.connection`（CONNECT）、`urn:x-cast:com.google.cast.tp.heartbeat`（PING/PONG）、`urn:x-cast:com.google.cast.receiver`（LAUNCH/GET_STATUS/SET_VOLUME）、`urn:x-cast:com.google.cast.media`（LOAD）。
- 接收端用内置的 Default Media Receiver（`CC1AD845`）播放本机 HTTP 服务提供的 ADTS AAC 流。

音频流路径：ScreenCaptureKit PCM → ADTS AAC 封装 → 本机 HTTP 服务（分块传输，`Transfer-Encoding: chunked`）→ Cast 媒体接收器拉流。

推流 URL 必须是**本机局域网 IP**，不是 `localhost`，否则音箱拉不到。

协议实现要点（均已按 Chromium 的 `cast_channel.proto` 核对）：

| 细节 | 约定 |
|---|---|
| 帧格式 | 4 字节大端长度前缀 + protobuf 消息体 |
| `CastMessage` 字段号 | `protocol_version=1`、`source_id=2`、`destination_id=3`、`namespace=4`、`payload_type=5`、`payload_utf8=6`、`payload_binary=7` |
| 协议版本 | `CASTV2_1_0 = 0` |
| 负载类型 | `STRING = 0`（JSON），`BINARY = 1` |
| 端点 id | 发送端 `sender-castaudio`，设备端未建应用会话时 `receiver-0` |
| TLS | 音箱用自签证书，握手时不做证书校验（只走本地网络控制通道） |
| 心跳 | 每 5 秒发一次 PING，收到 PING 回 PONG；否则音箱会主动断开 |

protobuf 线格式在工程内自己实现（`Sources/CastAudio/Cast/Protobuf.swift`），不引入外部包依赖，CI 不需要拉取第三方源码。

**投送顺序**：连接 → `CONNECT` → `LAUNCH`（Default Media Receiver）→ 等设备回报 `RECEIVER_STATUS` 里的 sessionId → `LOAD`（指向本机 HTTP 流地址）。

### 2.4 音箱控制

`SET_VOLUME` / `SET_MUTE` 走 `urn:x-cast:com.google.cast.receiver` 命名空间；音量变化通过接收端的 `RECEIVER_STATUS` 推送同步到 UI。对应 Android 的 `CastSdkSessionController` 那一层，接口形状保持一致。

### 2.5 目标管理与 UI

- `TargetPreset`（命名组合）→ macOS 侧保留为「采集组合预设」，用 `UserDefaults` 持久化。
- 深色控制台 UI 用 SwiftUI 重做，四维状态灯语义照搬：
  1. 音箱已连接 2. 流正在发送 3. 已有有效音频（dBFS 判定）4. 本机已静音
- 配色沿用 `StudioTheme`（已在 `Sources/CastAudio/Design/StudioTheme.swift`）。

## 3. 工程约束

- **SwiftPM 工程**（`Package.swift`），不用 Xcode 项目文件：本机只有 Command Line Tools，没有完整 Xcode，`swift build` 可用但 `xcodebuild` 不可用。
- **CI 出包**：`.github/workflows/build.yml` 在 GitHub Actions 的 macOS runner 上跑 `scripts/package_app.sh`，产出 `build/CastAudio.app` 与 zip artifact。
- 本机打包：`./scripts/package_app.sh release`（用 codesign ad-hoc 签名）。
- 最低系统版本 macOS 14（ScreenCaptureKit 音频采集 + `SCContentFilter` 应用过滤需要）。
- Swift 5 语言模式（`swiftLanguageMode(.v5)`），避开 Swift 6 严格并发带来的编译噪音。

## 4. 权限清单

| 权限 | 用途 | 获取方式 |
|---|---|---|
| 屏幕录制 | ScreenCaptureKit 采集应用音频 | 系统设置 → 隐私与安全性 → 屏幕录制 → 添加本应用 |
| 本地网络 | 发现并连接局域网 Cast 音箱 | 首次连接时弹窗 |
| 麦克风 | **不需要**（不采集麦克风，仅回采应用播放音频） | Info.plist 中不声明 |

## 5. 已知取舍

1. 无法单应用静音 → 只能全局静音或双端同时出声。
2. ScreenCaptureKit 的应用过滤粒度是「应用的所有窗口」，不是 Android 那种按 UID 的包级回采；部分自绘音频的应用可能采集不到。
3. 需要屏幕录制权限，比 Android 的 MediaProjection 更重（用户要手动去系统设置里开）。
4. 首版用 Default Media Receiver 播放本机 HTTP 流，延迟高于 Android 版的 WebRTC 直连自定义接收器。
