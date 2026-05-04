# Veency 性能翻倍优化路线图

> 本文档定义"如何把 Veency 的实测帧率从 ~10 FPS 提升到 ~50 FPS"的具体优化方案。
> 兼容性约束:**iOS 6 / 7 双兼容**,不引入 iOS 8+ 才有的 API(无 Metal、无 iOS 8 之后的 CoreImage)。

---

## 第 1 章 现状基线分析

### 1.1 帧率上限
当前硬编码 25 FPS:
```cpp
// Tweak.mm:713
screen_->deferUpdateTime = 1000 / 25;
```

### 1.2 每帧默认配置开销(retina 设备 ~750×1334,~4 MB/帧)

| 阶段 | 估算耗时 | 位置 | 备注 |
|---|---|---|---|
| 1. CoreSurfaceAcceleratorTransferSurface | 1-2 ms | Tweak.mm:954 | GPU→共享内存,基本免不掉 |
| 2. **`usleep(skipBlack_)`** | **8 ms** | Tweak.mm:957 | ❗默认 8000 微秒,纯阻塞 |
| 3. isBottomScreenBlack | 0.1 ms | Tweak.mm:894 | 抽样底部 1/8,影响小 |
| 4. memcpy(全屏) | 3-5 ms | Tweak.mm:964 | 4 MB 拷贝,标量 |
| 5. rfbMarkRectAsModified(整屏) | <0.1 ms | Tweak.mm:1011 | ❗触发 libvncserver 整屏编码 |
| 6. libvncserver 编码 | 5-10 ms | 后台线程 | 整屏拷贝压缩,CPU 重 |
| **合计每帧主路径** | **~17-25 ms** | | 实测 FPS ~10-15 |

### 1.3 真实瓶颈排序(从大到小)

1. **`usleep(skipBlack_)` 阻塞捕获钩** —— 影响 SpringBoard 帧调度,直接让 OnLayer 频率从 60 Hz 降到 ~50 Hz。
2. **每帧整屏标脏** —— libvncserver 不能用差分压缩,网络流量与编码 CPU 暴涨。
3. **CopyToFrameBuffer 标量循环** —— divideScreenBy>1 时每像素 1 周期。
4. **memcpy 缺乏矢量化** —— 标量拷贝 vs NEON 拷贝有 3-4× 差距。
5. **钩函数同线程做完所有事** —— 无法利用第二个 CPU 核。
6. **🐛 直通模式条件 bug** —— 见 T1-E。

### 1.4 严重 bug:直通模式从未触发

```cpp
// Tweak.mm:947
if(!skipBlack_ && !divideScreenBy_) {     // <-- BUG
    screen_->frameBuffer=(char *)bufferData_;
    CoreSurfaceAcceleratorTransferSurface(accelerator_, layer, buffer_, options_);
}
```

`divideScreenBy_` 在 Tweak.mm:354 被钳制到 `[1, 320]`:
```cpp
if(divideScreenBy_<1 || divideScreenBy_>320) divideScreenBy_=1;
```

所以 `!divideScreenBy_` **永远为假**,这条最快路径(直接把 frameBuffer 指向 bufferData_,免掉 4 MB memcpy)**从未被触发**。这是个被忽视了多年的 bug,修复它只需把条件改成 `divideScreenBy_ == 1`。

---

## 第 2 章 Tier 1 — 高收益、低风险(累计预期 +60-100% 吞吐量)

### T1-A:消除 `usleep(skipBlack_)` 同步阻塞 ⭐ 最高优先级

**现状代码** (Tweak.mm:954-959):
```cpp
CoreSurfaceAcceleratorTransferSurface(accelerator_, layer, buffer_, options2_);
if(skipBlack_) {
    usleep(skipBlack_);  // 默认 8000us = 8ms 纯睡眠
    ok=isBottomScreenBlack(bufferData_)?0:1;
}
```

**设计**:
TransferSurface 在现代 iOS 上是同步等待 GPU 完成的,这个 sleep 是 saurik 当年为了等显存可读加的保守保险;改成显式刷新缓存后立即检测:

```cpp
CoreSurfaceAcceleratorTransferSurface(accelerator_, layer, buffer_, options2_);
if(skipBlack_) {
    CoreSurfaceBufferFlushProcessorCaches(buffer_);
    ok = isBottomScreenBlack(bufferData_) ? 0 : 1;
}
```

**回退方案**:若直接删除 sleep 在某些 OpenGL 应用上花屏,降到 `usleep(500)`(0.5 ms)而非 8000。

**预期收益**:每帧省 8 ms,OnLayer 不再拖慢 SpringBoard。

---

### T1-B:把 25 FPS 硬上限改成可配置

**现状** (Tweak.mm:713):
```cpp
screen_->deferUpdateTime = 1000 / 25;
```

**设计**:
1. 在 `com.saurik.Veency.plist` 增加 `MaxFPS` 整型设置(范围 5-60,默认 30)。
2. `PreferenceLoader/Preferences/Veency.plist` 添加对应 `PSEditTextCell`。
3. `VNCSettings` 中读取并写入 deferUpdateTime:

```cpp
NSNumber *maxFPS = [settings objectForKey:@"MaxFPS"];
int fps = maxFPS == nil ? 30 : [maxFPS intValue];
if (fps < 5 || fps > 60) fps = 30;
screen_->deferUpdateTime = 1000 / fps;
```

**预期收益**:LAN 上 FPS 上限从 25 提升到 30-60。

---

### T1-C:基于 64×64 瓦片的脏矩形跟踪 ⭐

**现状** (Tweak.mm:1011):
```cpp
rfbMarkRectAsModified(screen_, 0, 0, destwidth_, destheight_);  // 整屏标脏
```

**设计**:

```cpp
static uint32_t *tileChecksums_ = NULL;
static const int TILE = 64;

static void MarkDirtyTiles(rfbPixel *fb, int width, int height) {
    int tilesX = (width + TILE - 1) / TILE;
    int tilesY = (height + TILE - 1) / TILE;
    if (!tileChecksums_) {
        tileChecksums_ = (uint32_t *)calloc(tilesX * tilesY, sizeof(uint32_t));
        // 第一帧:全屏标脏
        rfbMarkRectAsModified(screen_, 0, 0, width, height);
        // 同时初始化 checksums
        for (int ty = 0; ty < tilesY; ++ty)
            for (int tx = 0; tx < tilesX; ++tx)
                tileChecksums_[ty * tilesX + tx] = TileChecksum(fb, tx, ty, width, height);
        return;
    }

    // 安全网:每 30 帧强制全屏一次,防止哈希碰撞漏帧
    static int forceFullFrameCounter = 0;
    if (++forceFullFrameCounter >= 30) {
        forceFullFrameCounter = 0;
        rfbMarkRectAsModified(screen_, 0, 0, width, height);
        // 仍然刷新 checksums
        for (int ty = 0; ty < tilesY; ++ty)
            for (int tx = 0; tx < tilesX; ++tx)
                tileChecksums_[ty * tilesX + tx] = TileChecksum(fb, tx, ty, width, height);
        return;
    }

    for (int ty = 0; ty < tilesY; ++ty) {
        for (int tx = 0; tx < tilesX; ++tx) {
            uint32_t c = TileChecksum(fb, tx, ty, width, height);
            int idx = ty * tilesX + tx;
            if (c != tileChecksums_[idx]) {
                tileChecksums_[idx] = c;
                int x0 = tx * TILE, y0 = ty * TILE;
                int x1 = MIN(x0 + TILE, width);
                int y1 = MIN(y0 + TILE, height);
                rfbMarkRectAsModified(screen_, x0, y0, x1, y1);
            }
        }
    }
}
```

`TileChecksum` 用 FNV-1a(平台无关)或 ARMv8 CRC32 内置(`__crc32cw`,A53/A72 直接硬件加速):

```cpp
static inline uint32_t TileChecksum(rfbPixel *fb, int tx, int ty, int width, int height) {
    int x0 = tx * TILE, y0 = ty * TILE;
    int x1 = MIN(x0 + TILE, width);
    int y1 = MIN(y0 + TILE, height);
    uint32_t h = 0x811c9dc5u;  // FNV-1a 偏移量
    for (int y = y0; y < y1; ++y) {
        uint32_t *row = (uint32_t *)fb + y * width + x0;
        for (int x = x0; x < x1; ++x) {
            h ^= *row++;
            h *= 0x01000193u;
        }
    }
    return h;
}
```

**典型 UI**(锁屏、桌面)只有 5-10% 瓦片变化,libvncserver 的编码量与网络流量按比例下降。

**预期收益**:静止画面 CPU 接近 0,滚动画面 CPU 减半,网络带宽 ↓ 70-90%。

---

### T1-D:静止帧短路检测

**设计**:在 OnLayer 入口处先对整帧抽样(16 个均匀分布的像素 + 4 个 corner)算 64-bit 哈希;与上一帧相同则直接跳过整个流水线:

```cpp
static uint64_t lastFrameSig_ = 0;

static inline uint64_t QuickFrameSignature(const uint32_t *fb, int width, int height) {
    uint64_t h = 0;
    int dx = width / 5, dy = height / 5;
    for (int y = dy; y < height; y += dy)
        for (int x = dx; x < width; x += dx)
            h = h * 31 + fb[y * width + x];
    h = h * 31 + fb[0];
    h = h * 31 + fb[width - 1];
    h = h * 31 + fb[(height - 1) * width];
    h = h * 31 + fb[height * width - 1];
    return h;
}

// 在 OnLayer 中:
uint64_t sig = QuickFrameSignature((uint32_t *)bufferData_, width_, height_);
if (sig == lastFrameSig_) {
    return;  // 整帧未变,跳过 memcpy + standify
}
lastFrameSig_ = sig;
```

**预期收益**:与 T1-C 互补,静止时把流水线降到几乎 0。注意签名比较仅在 transfer 完成后做,因此 GPU 拷贝代价仍存在。

---

### T1-E:修复直通模式条件 bug ⭐

**现状** (Tweak.mm:947):
```cpp
if(!skipBlack_ && !divideScreenBy_) {     // ❌ divideScreenBy_ 永远 ≥1
    screen_->frameBuffer=(char *)bufferData_;
    CoreSurfaceAcceleratorTransferSurface(accelerator_, layer, buffer_, options_);
}
```

**修复**:
```cpp
if(!skipBlack_ && divideScreenBy_ == 1) {     // ✅ 默认配置就是 1
    screen_->frameBuffer=(char *)bufferData_;
    CoreSurfaceAcceleratorTransferSurface(accelerator_, layer, buffer_, options_);
}
```

修复后,默认配置(SkipBlack=0 + DivideScreenBy=1)能直接把 `screen_->frameBuffer` 指到 `bufferData_`,**完全免去 4 MB 主拷贝**。

**预期收益**:启用直通时每帧省 3-5 ms 主拷贝。

---

## 第 3 章 Tier 2 — 中等收益、需要 NEON 知识(累计 +30-50%)

### T2-A:CopyToFrameBuffer 改 NEON 矢量化

**现状** (Tweak.mm:884-888):
```cpp
while(fromUpto<fromNextLine) {
    *destUpto=*fromUpto;
    ++destUpto;
    fromUpto+=skipDots;   // 每像素 1 周期标量
}
```

**设计**:对常用的 divideBy=2/3/4 写 NEON 专用路径,其他走标量回退。

**divideBy=2** 示例(每两像素取一):
```cpp
#include <arm_neon.h>

static void CopyToFrameBuffer_div2_neon(uint32_t *dst, const uint32_t *src,
                                        int width, int height, int destWidth) {
    int dstW = destWidth;  // 假设 destWidth = width/2
    for (int y = 0; y < height; y += 2) {
        const uint32_t *s = src + y * width;
        uint32_t *d = dst + (y / 2) * dstW;
        int x = 0;
        for (; x + 8 <= dstW; x += 8) {
            // 一次取 16 个像素 (源),交替选 8 个
            uint32x4x2_t v0 = vld2q_u32(s);
            uint32x4x2_t v1 = vld2q_u32(s + 8);
            vst1q_u32(d, v0.val[0]);
            vst1q_u32(d + 4, v1.val[0]);
            s += 16;
            d += 8;
        }
        // 处理尾部
        for (; x < dstW; ++x) {
            *d++ = *s;
            s += 2;
        }
    }
}
```

**divideBy=4** 用 `vld4q_u32` 取 16 像素中的第一个 lane,效率更高。

**头文件**:`<arm_neon.h>`(Xcode/Theos 内置,iOS 4+ 通用)。

**预期收益**:CopyToFrameBuffer 由 ~5 ms 降到 ~1 ms。

---

### T2-B:Copy64x16BlockedImage 单次拷贝优化

**现状** (Tweak.mm:816-845):
每帧 ~150-200 个 `memcpy(dst, src, 256)` 调用,函数调用与小拷贝头开销巨大。

**设计**:
1. 先验证现代 iOS 是否还使用 64×16 PowerVR 瓦片格式 —— 自 iOS 7 加速路径起 layer 已是线性 BGRA,这条路径只在 iOS 6 及以下生效。
2. 在加速路径下根本不会进入这个函数(看 Tweak.mm:992-993,只有 accelerator_=NULL 才走这里)。
3. 若仍需块状重排:用一段 NEON 循环替代嵌套 memcpy:

```cpp
static void Copy64x16BlockedImage_neon(uint8_t *dst, const uint8_t *src,
                                       int width, int height) {
    const int blkW = 64, blkH = 16;
    int blocksX = width / blkW;
    int blocksY = height / blkH;
    int rowStride = width * 4;
    for (int by = 0; by < blocksY; ++by) {
        for (int bx = 0; bx < blocksX; ++bx) {
            uint8_t *d = dst + by * blkH * rowStride + bx * blkW * 4;
            for (int row = 0; row < blkH; ++row) {
                // 每行 64 像素 = 256 字节 = 4 个 q-reg (16 字节 each)
                uint8x16_t a = vld1q_u8(src);
                uint8x16_t b = vld1q_u8(src + 16);
                uint8x16_t c = vld1q_u8(src + 32);
                uint8x16_t e = vld1q_u8(src + 48);
                uint8x16_t f = vld1q_u8(src + 64);
                uint8x16_t g = vld1q_u8(src + 80);
                uint8x16_t h = vld1q_u8(src + 96);
                uint8x16_t i = vld1q_u8(src + 112);
                vst1q_u8(d,      a);
                vst1q_u8(d + 16, b);
                vst1q_u8(d + 32, c);
                vst1q_u8(d + 48, e);
                vst1q_u8(d + 64, f);
                vst1q_u8(d + 80, g);
                vst1q_u8(d + 96, h);
                vst1q_u8(d + 112, i);
                src += 128;  // 一行 64 像素中的前 32 + 后 32 = 128 字节? 重新核对
                d += rowStride;
            }
        }
    }
}
```
**注**: 上面的步长需要根据具体的 PowerVR 瓦片打包顺序调整,实际写时需要先测试再 commit。

**预期收益**:软件路径每帧节省 1-2 ms(对 iPhone 4 等老设备有意义)。

---

### T2-C:把"直通模式"作为推荐默认配置

**设计**:配合 T1-E 的 bug 修复,把 SkipBlack 默认值从 8000 改为 0(由用户主动启用),这样默认配置走直通路径,完全免拷贝。

**变更点**:
1. `PreferenceLoader/Preferences/Veency.plist` 中 SkipBlack 的 `default` 改为 `0`。
2. `Tweak.mm:394` 中 `skipBlack_ = skipBlack == nil ? 0 : ...`(本来就是 0,只需改 plist 默认值)。
3. README.zh.md 中说明:"相机/OpenGL ES 用户可在设置中把 SkipBlack 启用为 8000"。

**风险**:既有用户升级后默认行为改变 —— 在 README 中加显眼的"升级提示"段落。

**预期收益**:消除主拷贝路径,~4 ms/帧。

---

## 第 4 章 Tier 3 — 高收益、架构改动(累计 +50-100%,需充分测试)

### T3-A:捕获/编码异步流水线 ⭐

**现状**:OnLayer 在 IOMobileFramebufferSwapSetLayer 钩内同步完成所有事(transfer + 拷贝 + 标脏),阻塞 SpringBoard 渲染。

**设计**:三缓冲环 + 后台 GCD 队列。

```cpp
#define RING_SIZE 3
static rfbPixel *frameRing_[RING_SIZE];
static int writeIdx_ = 0;
static int readIdx_  = -1;  // -1 表示无可读帧
static OSSpinLock ringLock_ = OS_SPINLOCK_INIT;
static dispatch_queue_t encodeQueue_;

// VNCSetup 中:
encodeQueue_ = dispatch_queue_create("com.saurik.Veency.encode",
                                     DISPATCH_QUEUE_SERIAL);
for (int i = 0; i < RING_SIZE; ++i)
    frameRing_[i] = (rfbPixel *)mmap(...);

// OnLayer 中(简化伪码):
OSSpinLockLock(&ringLock_);
int wi = writeIdx_;
writeIdx_ = (writeIdx_ + 1) % RING_SIZE;
OSSpinLockUnlock(&ringLock_);

// transfer + 拷贝到 frameRing_[wi]
// (这一段如果 T1-E 直通生效,就是 0 拷贝;否则是 1 次 memcpy)

OSSpinLockLock(&ringLock_);
readIdx_ = wi;  // 发布最新帧
OSSpinLockUnlock(&ringLock_);

// 钩立即返回!不等编码

dispatch_async(encodeQueue_, ^{
    OSSpinLockLock(&ringLock_);
    int ri = readIdx_;
    OSSpinLockUnlock(&ringLock_);
    if (ri < 0) return;
    screen_->frameBuffer = (char *)frameRing_[ri];
    MarkDirtyTiles(frameRing_[ri], destwidth_, destheight_);  // T1-C
});
```

**同步原语**:
- iOS 6/7: `OSSpinLock` (有弃用警告,无碍)
- iOS 10+: `os_unfair_lock`

**风险**:撕裂、ABA 问题 —— 三缓冲 + 显式发布顺序可解决。

**预期收益**:
- OnLayer 钩内时间降 50-70%(SpringBoard 不再被拖慢)
- 真正利用第二个 CPU 核(iPhone 4s 起就是双核)
- FPS 上限从 30 提升到 60+

---

### T3-B:libvncserver 编码参数优化

**设计**:

1. **VNCSetup 中显式设置**:
```cpp
screen_->serverFormat.trueColour = TRUE;
screen_->serverFormat.bitsPerPixel = 32;
screen_->serverFormat.depth = 24;
```

2. **README 中给客户端命令行示例**:
```bash
vncviewer -encodings tight -quality 5 -compresslevel 9 <设备IP>
```

3. **如果 libvncserver 编译时启用了 libjpeg-turbo**,Tight 编码 + JPEG 5 在 retina 屏幕上能把 4 MB/帧 压缩到 50-100 KB/帧。

**预期收益**:网络瓶颈机器(WiFi/4G)上 FPS 翻倍。

---

## 第 5 章 实施顺序与里程碑

每个里程碑独立提交,各自可观测、可回退。

| 里程碑 | 包含项 | 预计工作量 | 预期效果 |
|---|---|---|---|
| **M1**(快速胜利) | T1-A + T1-B + T1-E | 0.5-1 天 | 默认配置 FPS 从 ~10 → ~25 |
| **M2**(算法升级) | T1-C + T1-D | 1-2 天 | 静止 CPU 降 90%,滚动减半 |
| **M3**(NEON) | T2-A + T2-B | 1 天 | CopyToFrameBuffer 提速 5× |
| **M4**(默认改动) | T2-C | 0.5 天 | 默认配置每帧再省 4 ms |
| **M5**(架构) | T3-A | 2-3 天 ❗高风险 | FPS 上限 60+,SpringBoard 不再被拖慢 |
| **M6**(网络) | T3-B + 文档 | 0.5 天 | WiFi 用户带宽减少 10× |

**总计**:M1+M2+M3+M4 实施完,默认配置 FPS 应当从 ~10 提升到 **~50**(翻 5 倍)。M5 进一步提升到 60+ 上限。

---

## 第 6 章 真机验证方法

1. **CPU 占用**:`top -pid $(pgrep SpringBoard)` 观察 SpringBoard 与 backboardd 的 CPU%,目标:无 VNC 客户端时基线,有客户端连接时 +30% 内。
2. **OnLayer 频率**:在函数内累加帧计数,每秒 NSLog 打印,目标 ≥ 30 fps。
3. **VNC 客户端体验**:用 RealVNC 客户端连接,记录:
   - 滚动 Safari 的视觉流畅度
   - 启动相机的画面刷新
   - Reachability/锁屏切换时的延迟
4. **Instruments Time Profiler**:在 Xcode 中通过越狱设备桥接,Profile SpringBoard,验证 OnLayer 不再是第一热点。
5. **网络吞吐**:用 `tcpdump -i en0 'port 5900'` 抓包统计每秒 KB,T1-C 后应有 5-10× 下降。

**简易帧率打印 patch**(用于 M1 之前的基线):
```cpp
// 在 OnLayer 末尾加:
static int frameCount = 0;
static uint64_t lastTick = 0;
uint64_t now = mach_absolute_time();
mach_timebase_info_data_t tb;
mach_timebase_info(&tb);
uint64_t nowNs = now * tb.numer / tb.denom;
++frameCount;
if (nowNs - lastTick > 1000000000ULL) {
    NSLog(@"[Veency] FPS=%d", frameCount);
    frameCount = 0;
    lastTick = nowNs;
}
```

---

## 第 7 章 不做的事(范围控制)

- **不**引入 Metal / 新版 CoreImage(违反 iOS 6/7 兼容性约束)
- **不**替换 libvncserver(过于激进,且会破坏既有客户端兼容)
- **不**改 Substrate 钩注方式
- **不**改 SimulateTouch / Ashikase 等外部依赖
- **不**重写鼠标/键盘事件路径(非性能瓶颈)
- **不**改 RFB 协议或新增自定义编码

---

## 第 8 章 风险登记

| 编号 | 风险 | 缓解 |
|---|---|---|
| R1 | 移除 `usleep` 后某些 OpenGL 应用花屏 | 回退到 `usleep(500)` 或加 GPU fence 等待 |
| R2 | 异步管线撕裂 | 三缓冲 + acquire/release 屏障 |
| R3 | NEON 在 iPad1,1 等老设备上指令集不全 | `__ARM_NEON` 宏检测,fallback 标量路径 |
| R4 | Tile checksum 漏判(碰撞) | 每 30 帧强制全屏标脏 |
| R5 | 改 deferUpdateTime 影响低端设备发热/掉帧 | 默认 30,允许用户回退到 25 |
| R6 | 直通模式 bug 修复后 SkipBlack 默认行为变化 | README.zh.md 中专门说明该兼容性变化 |
| R7 | OSSpinLock 在 iOS 10+ 弃用 | 编译时 `__IPHONE_OS_VERSION_MAX_ALLOWED` 判断,iOS 10+ 用 os_unfair_lock |

---

## 附录 A:本计划与原代码的关系

本路线图 **不包含任何已实施的代码改动**。Tweak.mm、SpringBoardAccess.h、SpringBoardAccess.c、Tweak.plist、所有 Makefile 与 .dylib 文件均未变。

修改在后续会话中按里程碑推进时进行,每个里程碑都需要在真机上验证再合入。

## 附录 B:术语表

| 英文 | 中文 |
|---|---|
| RFB / Remote Framebuffer | 远程帧缓冲(VNC 使用的协议) |
| IOSurface / CoreSurface | iOS 私有的跨进程图像缓冲 |
| IOMobileFramebuffer | iOS 显示帧缓冲服务 |
| CydiaSubstrate | iOS 越狱钩注框架 |
| dirty rectangle | 脏矩形(自上一帧以来发生变化的区域) |
| tile checksum | 瓦片校验和 |
| deferUpdateTime | libvncserver 中"等待这么多毫秒再合并发送"的参数 |
| BGRA | 蓝-绿-红-透明 像素分量顺序(iOS / Win32 GDI 默认) |
| NEON | ARM CPU 上的 SIMD 指令集 |
