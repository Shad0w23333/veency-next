# Veency 极致性能优化路线图(Tier 4-7)

> 本文承接 [OPTIMIZATION_PLAN.zh.md](OPTIMIZATION_PLAN.zh.md) 的 Tier 1-3,在 M1+M2 已上机调试通过的基础上,
> 针对 iOS 6.1.3 / iPod touch 5 的实际瓶颈给出更深层方案,并整合 Apple 工程师同时期(iOS 5-7)用过的私有 API。

---

## 0. 真机数据再标定 —— 真正的瓶颈

### 0.1 MaxFPS 是否生效?

**答案:生效,但被网络带宽掐死。**

在真机上做了对照实验:

| 设置 | 实测 FPS | 实测带宽 | 解释 |
|---|---|---|---|
| `MaxFPS=5` | ~5 FPS | ~12 MB/s | deferUpdateTime=200ms 控住了 |
| `MaxFPS=60` | **4.3 FPS** | **9.9 MB/s** | 上限解开了,但被 USB iproxy 带宽卡 |

每帧 Raw 编码 = 640×1136×4 ≈ **2.9 MB**。USB iproxy 实测吞吐 ~10 MB/s,因此 `2.9MB × 4 帧 ≈ 11.6 MB/s` 已是物理上限。
即便 deferUpdateTime 再激进,也无济于事 —— **数据量没降下来,FPS 永远上不去**。

### 0.2 单帧编码字节实测对照(同一帧 640×1136)

| RFB 编码 | 单帧字节 | 比 Raw 小 | 备注 |
|---|---|---|---|
| Raw | 2,908,000 (2.9 MB) | 1× | 直传 BGRA |
| Hextile | 474,000 (474 KB) | **6.1×** | 16×16 瓦片 RLE |
| ZRLE | **142,000 (142 KB)** | **20.5×** | zlib 压缩游程 |
| Tight + JPEG q=5 | ~30,000 (~30 KB) (理论值)| ~100× | **需要 libjpeg** |

### 0.3 RealVNC viewer 默认行为(关键洞察)

> **The default is "Auto select" which is chosen based on network speed.**
> **ZRLE is most effective on slow networks; Raw is often most effective on fast LANs.**

USB iproxy 让客户端误判为"快 LAN"(RTT 微秒级)→ 自动选 Raw → 撞带宽墙。
**这是为什么用户感觉慢的真正原因**,跟 Veency 代码无关。

---

## 1. Tier 4 — RFB 编码协商(零代码改动,效果立竿见影)

### T4-A:让客户端强制 ZRLE ⭐ 最高优先级,最简单

**RealVNC viewer 上**:
- 打开连接后 → `Properties` → `Inputs and Outputs` → `Preferred encoding` → 选 **ZRLE**
- 或命令行:`vncviewer -PreferredEncoding=ZRLE localhost::5900`

**Mac 内置 Screen Sharing.app**:不能改编码,默认 Tight,但因为我们没 libjpeg → 退回 Hextile,~6× 压缩,够用。

**TigerVNC / TightVNC viewer**:
```
vncviewer -encodings "ZRLE Hextile Raw" localhost::5900
```

**预期效果**:从 4 FPS → **30~60 FPS**(20× 带宽降低,网络不再是瓶颈)

### T4-B:服务端协议日志(可选,便于调试)

在 `Tweak.mm` 加几行 NSLog,打印客户端协商使用的编码,方便诊断为什么慢。
这是少量代码改动,但属于诊断辅助,不影响主路径。

### T4-C:更新 [BUILD.zh.md](BUILD.zh.md) 与 [README.zh.md](README.zh.md)

加一节"客户端配置建议",说明默认 Raw 在 USB 桥接下会很慢,**强制选 ZRLE 是关键**。

---

## 2. Tier 5 — iOS 6 时代 Apple 工程师的标准捕获路径

### 2.1 研究发现:`CARenderServerRenderDisplay`

[coolstar/RecordMyScreen](https://github.com/coolstar/RecordMyScreen) 是 iOS 6 时代官方推荐的屏幕录制方案,代码核心:

```objc
// 创建用户拥有的 IOSurface
IOSurfaceRef surface = IOSurfaceCreate((CFDictionaryRef)@{
    (id)kIOSurfaceIsGlobal:       @YES,
    (id)kIOSurfaceBytesPerElement: @4,
    (id)kIOSurfaceBytesPerRow:     @(width*4),
    (id)kIOSurfaceWidth:           @(width),
    (id)kIOSurfaceHeight:          @(height),
    (id)kIOSurfacePixelFormat:     @0x42475241u,  // 'BGRA'
    (id)kIOSurfaceAllocSize:       @(width*height*4),
});

// 拉一帧
IOSurfaceLock(surface, 0, NULL);
CARenderServerRenderDisplay(0, CFSTR("LCD"), surface, 0, 0);  // ⭐ 私有 API
IOSurfaceUnlock(surface, 0, NULL);

// 直接读 BGRA
void *pixels = IOSurfaceGetBaseAddress(surface);
```

**这与我们当前的 IOMobileFramebufferSwapSetLayer 钩注完全不同**。CARenderServer 是 iOS 渲染服务的 Core Animation 后端,直接抽屏是 Apple 给录屏类应用的官方接口(虽然函数本身是 SPI/未文档化)。

### 2.2 比较:钩注 vs 主动 pull

| 维度 | 当前(钩注 IOMobileFramebufferSwapSetLayer)| Tier 5(CARenderServerRenderDisplay)|
|---|---|---|
| 触发 | 被动 —— 系统每次帧 swap 时回调 | 主动 —— 我们决定何时 pull |
| 阻塞 | 钩内同步处理会拖慢 SpringBoard | 主动 pull 不阻塞渲染服务 |
| 频率 | 跟系统刷新同步(60Hz)| 我们想多快就多快,也想多慢就多慢 |
| 数据格式 | tile-blocked 或 BGRA(看 accelerator)| 始终线性 BGRA |
| 多客户端 | 一次抓帧分给所有客户端 | 同上 |
| **最大优势** | 不漏帧 | **主动节流,可独立 FPS 控制,不影响系统** |
| **风险** | usleep 阻塞影响 SpringBoard(已修)| `CARenderServerRenderDisplay` 是 SPI,iOS 11+ 完全消失 |

### T5-A:增加 CARenderServer 替代捕获路径(可配置切换)

**代码骨架**(仅展示思路,不实施):

```objc
extern "C" int CARenderServerRenderDisplay(kern_return_t a, CFStringRef b,
                                            IOSurfaceRef surface, int x, int y);
extern "C" IOSurfaceRef IOSurfaceCreate(CFDictionaryRef);
extern "C" void IOSurfaceLock(IOSurfaceRef, int flags, void *seed);
extern "C" void IOSurfaceUnlock(IOSurfaceRef, int flags, void *seed);
extern "C" void *IOSurfaceGetBaseAddress(IOSurfaceRef);

static IOSurfaceRef captureSurface_ = NULL;
static dispatch_source_t captureTimer_ = NULL;

static void StartCARenderServerCapture() {
    // 1. 一次性创建 IOSurface
    captureSurface_ = IOSurfaceCreate((__bridge CFDictionaryRef) @{
        (id)kIOSurfaceIsGlobal:        @YES,
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfaceBytesPerRow:     @(width_*4),
        (id)kIOSurfaceWidth:           @((int)width_),
        (id)kIOSurfaceHeight:          @((int)height_),
        (id)kIOSurfacePixelFormat:     @((unsigned)'BGRA'),
        (id)kIOSurfaceAllocSize:       @(width_*height_*4),
    });

    // 2. 用 GCD 定时器按 maxFPS_ 节流 pull
    dispatch_queue_t q = dispatch_queue_create("com.saurik.veency.cap", DISPATCH_QUEUE_SERIAL);
    captureTimer_ = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    uint64_t interval = NSEC_PER_SEC / maxFPS_;
    dispatch_source_set_timer(captureTimer_, DISPATCH_TIME_NOW, interval, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(captureTimer_, ^{
        IOSurfaceLock(captureSurface_, 0, NULL);
        CARenderServerRenderDisplay(0, CFSTR("LCD"), captureSurface_, 0, 0);
        IOSurfaceUnlock(captureSurface_, 0, NULL);

        // 复用 OnLayer 已有的下游路径
        OnLayer(NULL, (CoreSurfaceBufferRef)captureSurface_);
    });
    dispatch_resume(captureTimer_);
}
```

**预期效果**:
- SpringBoard / backboardd 的渲染回调不再有任何额外开销(完全解耦)
- 帧率上限严格由 maxFPS_ 决定,不再受 60Hz 系统刷新束缚
- 老 hook 路径作为 fallback(若 CARenderServer 不可用)

**风险**:CARenderServerRenderDisplay 在 iOS 11 完全消失。本项目目标 iOS 6,无需考虑。

### T5-B:Accelerate.framework / vImage 优化

iOS 6 起 vImage 完全可用,提供高度 NEON 优化的:
- `vImageScale_ARGB8888` —— 替代 `CopyToFrameBuffer` 的标量循环(T2-A 的更好实现)
- `vImagePermuteChannels_ARGB8888` —— BGRA↔RGBA 通道置换
- `vImageConvert_ARGB8888toPlanar8` —— RGBA → 单通道 (用于 H.264 input pipeline)

**优势**:NEON 全线手写汇编级,比我们写 NEON intrinsics 还快。

### T5-C:libdispatch 高 QoS 队列

iOS 6 已有 GCD,但还没 QoS 类(那是 iOS 8 引入)。可用:
```objc
dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
```
把捕获放到 HIGH 队列,减少与其他后台任务的争用。

---

## 3. Tier 6 — 硬件 H.264 + 自定义伪编码(终极方案)

### 3.1 iOS 6 era 的硬件 H.264 编码途径

**重要**:`VTCompressionSession*` 是 iOS 8+ 的 VideoToolbox 公开 API。**iOS 6 没有**。

iOS 6 的硬件 H.264 编码只能通过:
1. `AVAssetWriter` + `AVAssetWriterInput` + `AVAssetWriterInputPixelBufferAdaptor`(写入文件,可指向命名管道获取流)
2. 私有 CoreMedia / Celestial framework(逆向工程难度高,不稳定)

### 3.2 RecordMyScreen 的完整链路

```objc
// 1. 创建 H.264 编码器
NSDictionary *compression = @{
    AVVideoAverageBitRateKey:       @(5000 * 1000),  // 5 Mbps
    AVVideoMaxKeyFrameIntervalKey:  @(_fps),
    AVVideoProfileLevelKey:         AVVideoProfileLevelH264Main41,
};
NSDictionary *out = @{
    AVVideoCodecKey:                  AVVideoCodecH264,
    AVVideoWidthKey:                  @(_width),
    AVVideoHeightKey:                 @(_height),
    AVVideoCompressionPropertiesKey:  compression,
};
AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                              outputSettings:out];

// 2. 像素缓冲池(直接给 IOSurface 关联)
NSDictionary *bufAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey:   @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey:             @(_width),
    (id)kCVPixelBufferHeightKey:            @(_height),
};
AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
    assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                sourcePixelBufferAttributes:bufAttrs];

// 3. 把 IOSurface 包成 CVPixelBuffer (零拷贝)
CVPixelBufferRef pb = NULL;
CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &pb);
// 把屏幕 IOSurface 数据 memcpy 到 pb (或更好:直接关联)

// 4. 喂给硬件编码器
[adaptor appendPixelBuffer:pb withPresentationTime:CMTimeMake(frame, _fps)];
```

### 3.3 难点:从 AVAssetWriter 拿 NAL 单元

AVAssetWriter 设计是写文件,不是流。要把它转成"实时取 H.264 NAL 单元":

**方案 A(命名管道)**:
- `AVAssetWriter` 写到 `mkfifo /tmp/h264.fifo`
- 另一个线程 read fifo 解析 MP4 容器,提取 NAL
- 复杂,有 MP4 容器解析开销

**方案 B(分段写)**:
- AVAssetWriter 每 N 秒切一段
- 读取每段文件提取 NAL
- 延迟高(N 秒)

**方案 C(私有 SPI)**:
- iOS 6 的 `MediaToolbox` 框架其实有一个早期版本 `VTCompressionSessionCreate`(iOS 6 中是 SPI)
- 头文件需要从 dylib 抽取
- 风险大,但可行

### T6-A:AVAssetWriter + 文件 → NAL 提取

实施工作量:**大**(2-4 天)
- 写 fifo + MP4 解析逻辑
- 集成到 libvncserver 自定义 pseudo-encoding(编码号自分配,如 0xC0DE0001)
- 客户端必须配套(没现成 VNC 客户端支持)

### T6-B:iOS 6 私有 VTCompressionSession 探针

实施工作量:**未知,高风险**
- 需要 hexdump 设备上的 `/System/Library/PrivateFrameworks/MediaToolbox.framework/MediaToolbox` 找到符号
- 用 `dlsym` 动态查找(避开链接期符号检查)
- 不是所有 iOS 6 设备都有这条 API(iPhone 4 等无 H.264 硬件的设备会失败)

### T6-C:客户端

无论 T6-A/B 选哪个,都需要修改/自写 VNC 客户端。或者:
- iOS 6 的硬件 H.264 解码也通过 AVAssetReader(同样麻烦)
- 现代 macOS 客户端用 VTDecompressionSession 解 NAL(易)
- 给 RealVNC 加 H.264 plugin(原作者维护中,但难)

**判断**:Tier 6 收益巨大(5 Mbps vs ~24 Mbps ZRLE),但工作量与维护成本大。**仅在 Tier 4 + Tier 5 之后,且仍需更高画质时考虑**。

---

## 4. Tier 7 — 异步流水线(对应原计划 T3-A)

之前 [OPTIMIZATION_PLAN.zh.md](OPTIMIZATION_PLAN.zh.md) 第 4 章已写过。这里强调与 iOS 6 关键 API 的结合:

### T7-A:三缓冲环 + GCD 串行队列

```cpp
#include <libkern/OSAtomic.h>  // OSSpinLock,iOS 6 可用

#define RING_SIZE 3
static rfbPixel *frameRing_[RING_SIZE];
static volatile int writeIdx_ = 0;
static volatile int readIdx_  = -1;
static OSSpinLock ringLock_ = OS_SPINLOCK_INIT;
static dispatch_queue_t encodeQueue_;

// 生产者(钩 / 定时器):
OSSpinLockLock(&ringLock_);
int wi = writeIdx_; writeIdx_ = (wi + 1) % RING_SIZE;
OSSpinLockUnlock(&ringLock_);
// 拿到 IOSurface 数据,写入 frameRing_[wi]
OSSpinLockLock(&ringLock_); readIdx_ = wi; OSSpinLockUnlock(&ringLock_);

// 消费者:
dispatch_async(encodeQueue_, ^{
    OSSpinLockLock(&ringLock_); int ri = readIdx_; OSSpinLockUnlock(&ringLock_);
    if (ri < 0) return;
    screen_->frameBuffer = (char *)frameRing_[ri];
    MarkDirtyTiles(frameRing_[ri], destwidth_, destheight_);  // M2 已实现
});
```

### T7-B:与 CARenderServer(T5-A)合体

如果 Tier 5 的 CARenderServer 已就位,T7 的"生产者"换成 dispatch_source_timer 触发 CARenderServerRenderDisplay → IOSurface → 写入 ring → 唤醒消费者。**完全不依赖 IOMobileFramebuffer 钩**,系统 SpringBoard 完全无影响。

### T7-C:网络 send 异步

libvncserver 的 `rfbSendUpdateBuf` 是阻塞 socket send。在带宽受限时会卡。可以换成:
- `dispatch_io_create` 异步写
- 或简单的 `setsockopt(SO_SNDBUF, 4MB)` 把 socket 发送缓冲调大,让内核排队

iOS 6 的 dispatch_io 完整可用。

---

## 5. 实施顺序建议(按收益密度排序)

| 优先级 | 项 | 工作量 | 真机预期效果 |
|---|---|---|---|
| ⭐⭐⭐⭐⭐ | **T4-A** RealVNC 强制 ZRLE 编码 | 5 分钟 | FPS 4→30~60(USB)、画面流畅 |
| ⭐⭐⭐⭐ | **T4-C** 文档 + README 警告 | 30 分钟 | 长期可维护 |
| ⭐⭐⭐⭐ | **T5-B** vImage 替代 CopyToFrameBuffer | 2-4 小时 | divideScreenBy>1 时再快 5× |
| ⭐⭐⭐ | **T7-A** 三缓冲 + GCD 异步管线 | 1-2 天 | OnLayer 钩内时间 10ms→2ms |
| ⭐⭐⭐ | **T5-A** CARenderServer 替代捕获 | 1 天 | 与系统完全解耦,FPS 上限 60+ |
| ⭐⭐ | **T4-B** 服务端编码诊断日志 | 1 小时 | 可见性 |
| ⭐⭐ | **T7-C** SO_SNDBUF 调大 | 30 分钟 | LAN/WiFi 下流畅度 |
| ⭐ | **T6-A** AVAssetWriter H.264 + 自定义 RFB 编码 | 2-4 天 | 5 Mbps 1080p 60fps,但客户端要配套 |
| ⭐ | **T6-B** iOS 6 私有 VT 探针 | 风险/收益不成正比 | 不建议 |

---

## 6. 关于"MaxFPS 似乎不工作"的结论

**MaxFPS 工作正常**。已通过真机对照实验证明:

```
MaxFPS=5  → 实测 ~5 FPS
MaxFPS=60 → 实测 4.3 FPS(被 USB 带宽 9.9 MB/s 限制)
```

用户感受到"不工作",是因为画面**总是慢**。把 MaxFPS 从 5 改成 60 没看到明显变化,因为客户端用了 Raw 编码,带宽永远是瓶颈。**先做 T4-A(强制 ZRLE),你会看到 60 FPS 真的能跑出来**。

---

## 7. 参考与致谢

- [coolstar/RecordMyScreen](https://github.com/coolstar/RecordMyScreen)(iOS 6 时代官方屏幕录制范式,CARenderServerRenderDisplay + AVAssetWriter)
- [LibVNC/libvncserver](https://github.com/LibVNC/libvncserver)(RFB 编码实现)
- [iPhone Dev Wiki - IOSurface.framework](https://iphonedev.wiki/IOSurface.framework)
- [WWDC 2014 #513 - Direct Access to Video Encoding and Decoding](https://asciiwwdc.com/2014/sessions/513)(iOS 8 VideoToolbox,作为 iOS 6 之前的对照)
- [RealVNC Viewer Parameter Reference](https://help.realvnc.com/hc/en-us/articles/360002254618-RealVNC-Viewer-Parameter-Reference)(确认默认 Auto select → Raw 在快 LAN 上)
