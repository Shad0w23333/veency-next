# Veency-next H.264 延迟优化研究笔记

## 1. 实测延迟构成(估算)

延迟链路:
```
iPod 屏幕变化
   ↓ ~16.6ms (60Hz 系统刷新)
IOMobileFramebufferSwapSetLayer 钩 → OnLayer
   ↓ ~3-5ms (CoreSurfaceAcceleratorTransferSurface BGRA → 我们的 buffer_)
VTCompressionSessionEncodeFrame (异步)
   ↓ ~5-15ms (PowerVR SGX543MP2 GPU 硬件 H.264)
Encoder callback → AVCC→Annex B → SendH264NALUToClients
   ↓ ~1ms (NSLock + rfbWriteExact 串行写)
TCP socket → iproxy USB → Mac socket
   ↓ ~1-3ms (USB RTT)
ffplay stdin → libavcodec H.264 解码 → SDL 显示
   ↓ ~5-20ms (Mac VT 硬解 + 显示器刷新)
─────────────────
总计 ~30-60ms 理论下限
```

**一帧从 iPod 屏幕变化到 Mac 屏幕显示,理论最低 30-60ms**。
当前实测感觉延迟高很可能是 **ffplay 启动阶段的缓冲** 或 **iPod 编码器初始化**(首关键帧前 P 帧被丢弃)。

## 2. iPod touch 5 硬件资源

- **CPU**: Apple A5(双核 1 GHz Cortex-A9,32位 ARMv7)
- **GPU**: PowerVR SGX543MP2(双核 200 MHz)
- **iOS**: 6.1.3
- **私有 H.264 硬件编码器**: VTCompressionSession SPI 在 iOS 6 已存在(iOS 8 公开)
- **私有 H.264 硬件解码器**: VTDecompressionSession SPI(我们这里在服务端不用)
- **私有色空间转换**: VTPixelTransferSession SPI(BGRA → YUV NV12)

## 3. VTCompressionSession 已应用的低延迟参数

```objc
RealTime                       = TRUE         // 优先速度,牺牲压缩比
AllowFrameReordering           = FALSE        // 禁 B 帧
MaxFrameDelayCount             = 0            // 编码器不缓存
ExpectedFrameRate              = maxFPS_      // 帮助内部 pacing
AverageBitRate                 = 4 Mbps       // 目标码率
DataRateLimits                 = [5 Mbps, 1s] // 严格突发上限
MaxKeyFrameInterval            = 30 帧         // 每秒 1 关键帧
MaxKeyFrameIntervalDuration    = 1.0 秒        // 同上,以时间触发
ProfileLevel                   = Baseline      // 无 B 帧,iPod GPU 最快
```

## 4. 还能进一步降低延迟的方向(尚未实施)

### 4.1 编码端

- **AllowTemporalCompression=FALSE** — 全部 I 帧。延迟极低但码率激增 5-10×(每帧 ~50KB→ ~200KB)。USB 桥接下勉强能跑;WiFi 下放弃。
- **MaxKeyFrameInterval=10** — 每 333ms 一个关键帧,丢包后快速恢复(但每秒 3 个关键帧,流量 +30%)。
- **VTPixelTransferSession** 替代 BGRA 直送 — VT 内部要求的可能是 YUV NV12,iOS 6 有这个 SPI 做硬件转换。
- **DivideScreenBy=2** — 320×568 编码,GPU 工作量减半,延迟也减半。画质损失可接受。

### 4.2 客户端

- **替换 ffplay 为定制 Mac viewer**:用 VTDecompressionSession 直接硬解,渲染到 NSWindow + CAMetalLayer,跳过 ffmpeg/SDL 全部缓冲。预期再节省 5-10ms。
- **AVSampleBufferDisplayLayer**(Apple 内部 AirPlay 用的)— 直接喂 CMSampleBuffer,Metal 渲染。
- **UDP 替代 TCP** — TCP ack/retransmit 增延迟。但需要在 NALU 边界做 packetization;丢包要靠应用层重发关键帧。本地 USB 几乎不丢包,意义不大。

### 4.3 网络/协议

- **去 iproxy** — 改走 WiFi 直连(LAN RTT ~1ms 同样)。但远程更通用。
- **VNC 协议本身** — RFB 头每帧 4+12+4 = 20 bytes 开销。跟 NALU 几 KB 比不算什么。
- **预读 SPS/PPS** — 当前每个关键帧前注入,客户端连接到第一个关键帧到达前会丢弃 P 帧(最长 KFI/FPS 秒)。可在客户端连接时立即 push 一个独立 SPS/PPS 帧。

## 5. 已知问题与诊断

### 5.1 长时间 H.264 会话后 iPod 进入劣化状态

**症状**:1000+ 帧后,后续客户端连 5900 → TCP accept OK → 服务端不发 RFB 003.008 greeting → 客户端 recv() 拿到空字节 → IndexError。SSH 也会同步劣化("kex_exchange_identification: read: Connection reset by peer")。

**根因尚不明**,可能性:
- backboardd 内 libvncserver 的 socket 状态机卡住
- 长会话累积内存/资源泄漏
- iOS 6 的 lockdownd / usbmuxd 崩溃影响 iproxy
- iPod 屏幕睡眠后 daemon 调度异常

**Workaround**:
- 物理按 home/power 唤醒 iPod
- 严重时彻底重启 iPod(关机再开机)
- 重启 iproxy: `pkill -f iproxy; iproxy 5900 5900 & iproxy 2222 22 &`

### 5.2 客户端 ffplay 启动延迟

ffplay 开始解码 H.264 流时,需要至少 1 个关键帧才能解第一帧。
连接后第一个 IDR 到达前的 P 帧被 ffplay 丢弃,显示空黑屏。
当前 KFI=30 帧 = 1 秒,可能等 1 秒才看到第一帧。
KFI=10 改为 333ms 可以加速但流量稍涨。

### 5.3 keyframe interval 的取舍

| KFI | 关键帧周期 | 流量(估)| 重连/丢包恢复 |
|---|---|---|---|
| 1  | 33ms (帧帧 I) | 极高 (5-10×)| 即时 |
| 10 | 333ms | +30% | 快 |
| 30 | 1 秒 | 基线 | 一般 |
| 60 | 2 秒 | -20% | 慢 |

USB / LAN 推荐 30,WiFi 远程推荐 60。

## 6. 参考链接

- [Apple WWDC 2021: Use VideoToolbox to Explore Low-Latency Video Coding](https://developer.apple.com/videos/play/wwdc2021/10158/)
- [Apple Developer: VTCompressionPropertyKey](https://developer.apple.com/documentation/videotoolbox/compression-properties)
- [theos/sdks - VTCompressionProperties.h](https://github.com/theos/sdks/blob/master/iPhoneOS9.3.sdk/System/Library/Frameworks/VideoToolbox.framework/Headers/VTCompressionProperties.h)
- [PowerVR SGX543 - Wikipedia](https://en.wikipedia.org/wiki/PowerVR)
- [Capturing Video on iOS · objc.io](https://www.objc.io/issues/23-video/capturing-video/)
- [coolstar/RecordMyScreen](https://github.com/coolstar/RecordMyScreen) — iOS 6 时代屏幕录制 IOSurface + AVAssetWriter 范式
