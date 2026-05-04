# Veency 架构说明 (中文)

> 本文档面向第一次接触本项目代码的中文读者,目的是让你在 5 分钟内理解 Veency 是怎样把 iOS 屏幕画面与远程 VNC 客户端连接起来的。

## 1. 项目概述

**Veency** 是 Jay Freeman (saurik) 编写的 iOS 越狱设备 VNC 服务器。

VNC(Virtual Network Computing)使用 RFB(Remote Framebuffer)协议在网络上传输屏幕像素与输入事件。Veency 把 iOS 设备做成一个 VNC 服务端,任何标准 VNC 客户端(RealVNC、TightVNC、UltraVNC、Linux 的 vncviewer 等)都能远程查看与操控这台 iOS 设备。

**应用场景**:屏幕碎了或触摸失灵时的紧急救援、自动化测试、远程演示。

**实现关键**:
- 用 **CydiaSubstrate** 把代码注入 SpringBoard / `IOMobileFramebuffer` 服务进程。
- 钩注 `IOMobileFramebufferSwapSetLayer` 拦截每一帧屏幕缓冲。
- 通过 **libvncserver** 库提供 RFB 协议的网络服务(默认端口 5900)。
- 用 **SimulateTouch** 库把远程客户端发来的鼠标点击转成系统级触摸事件。
- 可选支持 **Ashikase MouseSupport** 在屏幕上显示鼠标光标。

## 2. 依赖关系图

```
┌─────────────────────────────────────────────────────┐
│ SpringBoard (iOS 桌面进程)                          │
│  ┌────────────────────────────────────────────────┐ │
│  │ Veency.dylib (本仓库构建产物)                  │ │
│  │  ├─→ libvncserver.dylib  (RFB 协议网络服务)    │ │
│  │  ├─→ libsimulatetouch.dylib (触摸事件注入)     │ │
│  │  ├─→ CydiaSubstrate (函数钩注框架)             │ │
│  │  ├─→ SpringBoardAccess (可选:状态栏图标)      │ │
│  │  └─→ Ashikase (可选:屏幕鼠标光标)             │ │
│  └────────────────────────────────────────────────┘ │
│                       ↓ 钩注                        │
│  IOMobileFramebufferSwapSetLayer / SwapWait         │
└─────────────────────────────────────────────────────┘
        ↑ TCP 5900                       ↓ 触摸/键盘事件
        ↓                                ↑
┌──────────────┐                  ┌──────────────────┐
│ VNC 客户端   │                  │ iOS 前台应用     │
│ (RealVNC 等) │                  │ (Safari/相机等)  │
└──────────────┘                  └──────────────────┘
```

## 3. 源代码与配置文件清单

| 文件 | 用途 |
|---|---|
| **Tweak.mm** (1144 行) | 全部主逻辑:VNC 启停、帧捕获、像素拷贝、输入事件、Substrate 钩注 |
| **SpringBoardAccess.h / .c** | 与 SpringBoardAccess(第三方 Substrate 助手)通信,用于状态栏图标添加/移除 |
| **Tweak.plist** | Substrate 注入过滤器,只在 `com.apple.IOMobileFramebuffer` 进程中加载 dylib |
| **Settings.plist** | iOS 系统"设置"app 的 Veency 入口 UI 定义 |
| **PreferenceLoader/Preferences/Veency.plist** | PreferenceLoader 注册的设置页 UI(包含完整设置项,Settings.plist 是简化版) |
| **control** | Debian 包元数据(包名、版本、依赖) |
| **Makefile.osx** | OS X 上的 Theos 构建配置 |
| **make.sh** | 用 telesphoreo 工具链脚本化构建 |
| **theos_includes.zip** | Theos 构建系统所需的私有头文件压缩包 |
| **Default_Veency.png / FSO_Veency.png** | 状态栏图标 |
| **VeencyIcon.png / Settings.png** | 设置页图标 |
| **Veency.dylib / libvncserver.dylib / libsimulatetouch.dylib** | 已编译的二进制(可直接用于打包) |
| **veency_0.9.3379_iphoneos-arm.deb** | 预编译的安装包 |

## 4. 运行时启动顺序

```
1. SpringBoard 启动
   ↓
2. Substrate 检查每个加载的 dylib 的 filter
   ↓
3. com.apple.IOMobileFramebuffer 命中 Veency 的 Tweak.plist filter
   ↓
4. Veency.dylib 被注入,MSInitialize 执行 (Tweak.mm:1073)
   ├─ MSHookSymbol 解析 _GSGetPurpleSystemEventPort 等私有符号
   ├─ sysctl 检测 hw.machine,记录是否 iPad1,1
   ├─ 钩注 IOMobileFramebufferSwapSetLayer / rfbRegisterSecurityHandler
   ├─ 注册 Darwin 通知 (com.saurik.Veency-Enabled / -Settings)
   └─ 创建 NSCondition 等同步原语
   ↓
5. 第一次屏幕刷新触发 IOMobileFramebufferSwapSetLayer
   ↓
6. OnLayer 检测 width_/height_ 未设置,创建 NSThread
   ↓
7. 后台线程跑 VNCSetup → rfbGetScreen → rfbInitServer
   ↓
8. rfbRunEventLoop(screen_, -1, true) 进入 VNC 主循环 (Tweak.mm:794)
   ↓
9. 等待客户端连接……
```

## 5. 每帧捕获流水线

Veency 有**两条并行的捕获路径**,根据系统能力自动选择。

### 5.1 加速路径(iOS 7+ 强制启用)

```
IOMobileFramebufferSwapSetLayer 钩入口  (Tweak.mm:1017)
  ↓
OnLayer(fb, layer)  (Tweak.mm:911)
  ├─ 检查 clients_ 计数,无客户端则跳过
  ├─ 加 CoreSurface 锁 (Tweak.mm:953)
  ├─ CoreSurfaceAcceleratorTransferSurface(accelerator_, layer, buffer_, options2_)
  │   └─ GPU 把当前帧从 layer 拷到我们的 PurpleEDRAM 区域
  ├─ if (skipBlack_): usleep(skipBlack_) + isBottomScreenBlack 检测
  ├─ if (divideScreenBy_>1): CopyToFrameBuffer 缩放
  │   else: memcpy 到 mainFrameBuffer_
  ├─ 解 CoreSurface 锁
  └─ rfbMarkRectAsModified(0, 0, destwidth_, destheight_)  全屏标脏
  ↓
libvncserver 主循环 (后台线程)
  └─ 取 frameBuffer 编码 (Raw / RRE / Hextile / Tight / ZRLE) → 发送给客户端
```

### 5.2 软件路径(iOS 6 及以下)

```
OnLayer
  ├─ CoreSurfaceBufferLock(layer, 2)
  ├─ data = CoreSurfaceBufferGetBaseAddress(layer)  (Tweak.mm:976)
  │   注: iOS 6 这里给出的是 64×16 PowerVR 瓦片化内存
  ├─ CoreSurfaceBufferFlushProcessorCaches(layer)
  ├─ Copy64x16BlockedImage(mainFrameBuffer_, data)  (Tweak.mm:816)
  │   └─ 把 64×16 瓦片重排成线性 BGRA 像素
  ├─ if (divideScreenBy_>1): CopyToFrameBuffer(mainFrameBuffer_, correctedBlocksBuffer_)
  ├─ CoreSurfaceBufferUnlock(layer)
  └─ rfbMarkRectAsModified(...)
```

### 5.3 像素格式

服务端格式固定为 **BGRA 32-bit**(Tweak.mm:715-717):
```cpp
serverFormat.redShift   = 16   // R 在字节 2
serverFormat.greenShift = 8    // G 在字节 1
serverFormat.blueShift  = 0    // B 在字节 0
                                // A 在字节 3 (libvncserver 忽略)
```

无颜色空间转换、无 NEON 矢量化、无 GPU 后处理 —— 全部在 CPU 上做标量逐像素操作。

## 6. 输入事件流水线

### 6.1 鼠标 / 触摸 (VNCPointer @ Tweak.mm:435)

```
RFB 客户端发来 (buttons, x, y)
  ↓
旋转坐标 (横屏机型 width>height 时翻转)
  ↓
x /= ratio_ (retina 缩放因子)
y /= ratio_
x *= divideScreenBy_
y *= divideScreenBy_
  ↓
分支判断:
  ├─ 系统按键变化 (headset/menu/lock 位 0x10/0x04/0x02)
  │   └─ GSSendSystemEvent(GSEventTypeXxxButtonDown/Up)
  └─ 普通触摸
      ├─ iOS<7 且 Ashikase 可用: AshikaseSendEvent(x, y, buttons)
      └─ 其他: [SimulateTouch simulateTouch:downFinger_ atPoint:... withType:...]
```

### 6.2 键盘 (VNCKeyboard @ Tweak.mm:591)

```
RFB 客户端发来 (down, keysym)
  ├─ 只处理 down=true
  ├─ XK_Return → '\r'
  ├─ XK_BackSpace → 0x7f
  ├─ keysym > 0xfff → 忽略 (跳过功能键)
  ↓
GSEventCreateKeyEvent (新 iOS) 或 _GSCreateSyntheticKeyEvent (旧 iOS) 创建事件
  ↓
通过 CAWindowServer 找到 (x_,y_) 处的前台 app mach port
  └─ 找不到时退回 GSTakePurpleSystemEventPort 系统全局端口
  ↓
GSSendEvent(record, port)
```

## 7. 配置项与 Darwin 通知

**配置文件**: `~/Library/Preferences/com.saurik.Veency.plist`

| Key | 类型 | 默认 | 含义 |
|---|---|---|---|
| Enabled | bool | YES | 主开关 |
| Password | string | "" | VNC 密码;留空时每次连接弹窗确认 |
| ShowCursor | bool | YES | 是否显示鼠标光标(iOS 7+ 强制 NO) |
| SkipBlack | int | 8000 | 跳过黑屏的延时(微秒);设为 0 关闭 |
| DivideScreenBy | int | 1 | 屏幕缩小倍数;1=原始大小,3=1/9 像素量 |

**Darwin 通知**(Tweak.mm:1115-1123):
- `com.saurik.Veency-Enabled` → `VNCNotifyEnabled` → 启停 VNC 服务
- `com.saurik.Veency-Settings` → `VNCNotifySettings` → 重新加载所有设置

设置 app 通过 PostNotification 字段触发这两个通知;如果 DivideScreenBy 改了,VNCSettingsScreenSize 会自动 ShutDown + Setup + Enabled 重启服务以应用新分辨率(Tweak.mm:358-362)。

## 8. 关键代码行号索引

| 模块 | Tweak.mm 行号 | 备注 |
|---|---|---|
| 全局状态变量 | 72-105 | screen_、accelerator_、buffer_、mainFrameBuffer_、divideScreenBy_ 等 |
| 黑屏 mmap 分配 | 124-128 | VNCBlack |
| Ashikase 鼠标 IPC | 130-177 | jp.ashikase.mousesupport |
| VNC 弹窗 | 220-302 | VNCBridge / VNCAlertItem |
| 设置加载 | 348-411 | VNCSettingsScreenSize / VNCSettings,由 Darwin 通知触发 |
| 密码校验 | 413-423 | VNCCheck;memcmp 鉴权 |
| 鼠标事件 | 435-586 | VNCPointer |
| 键盘事件 | 591-651 | VNCKeyboard |
| 客户端断连 | 653-658 | VNCDisconnect;clients_ 减一 |
| 客户端连接 | 660-681 | VNCClient;弹窗 / 密码两条路径 |
| VNC 服务设置 | 688-775 | VNCSetup;rfbGetScreen / 检测加速器 / 分配 buffer_ |
| 服务启停 | 777-799 | VNCShutDown / VNCEnabled |
| **块状内存→线性** | **816-845** | `Copy64x16BlockedImage` —— 嵌套 memcpy 热点 ⚠️ |
| **缩放拷贝** | **847-893** | `CopyToFrameBuffer` —— 标量循环热点 ⚠️ |
| 黑屏检测 | 894-907 | isBottomScreenBlack;只扫底 1/8 |
| **每帧入口** | **910-1013** | `OnLayer` —— 含 8 ms `usleep` 阻塞 ⚠️ |
| Substrate 钩入口 | 1017-1054 | IOMobileFramebufferSwapSetLayer / SwapWait |
| 安全处理器钩 | 1057-1066 | rfbRegisterSecurityHandler |
| 模块初始化 | 1073-1142 | MSInitialize |

## 9. 已知问题与注释中的 TODO

- **Tweak.mm:274** `// XXX: this could find a better home` —— ratio_ 的初始化位置不理想。
- **Tweak.mm:947** 直通模式条件 `!divideScreenBy_` 永远为假(因 divideScreenBy_ 在 354 行被钳制为 ≥1)—— 这是个长期未发现的 bug,直通快速路径事实上从未被触发。
- **Tweak.mm:957** `usleep(skipBlack_)` 默认 8 ms,直接阻塞捕获钩,严重影响 SpringBoard 帧调度。
- **Tweak.mm:1011** 每帧整屏 `rfbMarkRectAsModified` —— libvncserver 无法做差分压缩。
- **Tweak.mm:1047** `// XXX: beg rpetrich for the type of this function` —— IOMobileFramebufferSwapWait 函数签名仍不确定。
- **Tweak.mm:937-940** 加速路径下注释掉了帧清零逻辑,因为它会让 OpenGL 应用画面错乱。

详细优化方案见 [OPTIMIZATION_PLAN.zh.md](OPTIMIZATION_PLAN.zh.md)。
