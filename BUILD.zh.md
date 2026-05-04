# Veency 本地构建指南 (中文)

> 适用于 macOS + 现代 Xcode 26.x,目标 iOS 6.0+ (实测兼容 iOS 6.1.3 / iPod touch 5)
> 不需要老版本 Xcode,不需要 iPhoneOS 6.1 SDK,不需要完整 theos 仓库。

## 一键就绪

```bash
./setup-build-env.sh    # 初次配置
./build.sh package      # 编译 + 打 .deb
```

打包产物:`veency_0.9.3379_iphoneos-arm.deb`(arm_v7,~21 KB)。

## 详细步骤(若 `setup-build-env.sh` 失败需要逐步排查)

### 1. 系统前置
- macOS + Xcode (任意现代版本,有 iPhoneOS SDK 即可)
- Homebrew (https://brew.sh/)
- git

### 2. 安装签名/打包工具
```bash
brew install ldid dpkg
```

### 3. 解压 theos 头文件
```bash
unzip theos_includes.zip
mkdir -p theos
mv include theos/include
```
解压后 `theos/include/` 应包含约 11000 个 .h 文件,涵盖:
- `IOMobileFramebuffer/`, `CoreSurface/`, `GraphicsServices/`(私有框架)
- `SpringBoard/`(SBAlertItem 等)
- `rfb/`(libvncserver)
- `CydiaSubstrate.h`、`substrate.h`(钩注框架)

### 4. 克隆 SimulateTouch
```bash
git clone --depth 1 https://github.com/iolate/SimulateTouch.git
```
仅需要 `SimulateTouch/SimulateTouch.h` 一个头文件即可。

### 5. 创建 UIKit stub (避免现代 SDK 级联)

由于现代 SDK 的 UIKit 包含 iOS 13+ API,与 Tweak.mm 引入的老 UIKit class-dump 头不兼容。`setup-build-env.sh` 会自动:
- 给现代 SDK UIKit 中所有 theos 没有的头创建 redirect stub(让 `<UIKit/X.h>` 都被截获)
- 把 `theos/include/UIKit/UIKit.h` 替换为最小声明(只声明 Tweak.mm 用到的 UIScreen/UIDevice/UIApplication/UIModalView/UIAlertItem)
- `theos/include/WebCore/WKTypes.h` 提供 `WKObject` / `WKViewRef` 占位类型

### 6. 编译

```bash
./build.sh             # 只生成 Veency.dylib
./build.sh package     # 同时打 .deb 包
```

`build.sh` 直接调用 `clang++`,**不依赖 theos 的 makefile**:
- arch: `armv7`
- min iOS: `6.0`
- isysroot: 当前 Xcode 的 iPhoneOS SDK
- 链接: `-Wl,-undefined,dynamic_lookup` 把符号解析推到设备运行时
- 签名: `ldid -S`(伪签名,适用于越狱设备)

预期警告(可忽略):
- `-undefined dynamic_lookup is deprecated on iOS` —— 我们故意这么用
- `ld: warning: ignoring file ...armv7 in file (2 slices)` —— 现代 SDK 没有 armv7 切片,运行时由 dyld 在设备上解析
- `Tweak.mm:443 variable sized type ... GNU extension` —— 老代码就这样,不影响运行
- `Tweak.mm:808 dangling else` —— 同上

## 部署到 iOS 6.1.3 / iPod touch 5

### 通过 SSH (推荐)

确保 iPod touch 5 已越狱并装了 OpenSSH。

```bash
# 设备 IP 通常是 192.168.x.y
DEV=root@<设备IP>
scp veency_0.9.3379_iphoneos-arm.deb $DEV:/tmp/
ssh $DEV 'dpkg -i /tmp/veency_0.9.3379_iphoneos-arm.deb && killall -9 SpringBoard'
```

默认 SSH 密码是 `alpine`。

### 通过 Cydia (备选)

1. 把 `.deb` 文件拷到设备的 `/var/root/Media/Cydia/AutoInstall/`
2. 重启设备(冷启动)
3. Cydia 会自动安装

### 验证安装

设备重启后:
1. 打开 "设置 → Veency",应该能看到中文 UI
2. 打开 RealVNC 客户端,连到 `<设备IP>:5900`
3. 看到 iOS 屏幕画面 + 接受连接的弹窗即成功

## M1 + M2 优化的真机验证

### 性能基线测量

无客户端连接时,SpringBoard 应保持低 CPU。连接 VNC 后:
- **M1 之前**:OnLayer 每帧 8 ms 阻塞,SpringBoard 滚动卡顿
- **M1 之后**:阻塞消除,FPS 上限提到 30(可在设置中调到 60)
- **M2 之后**:屏幕静止时 CPU 接近 0,变化区域才编码

### 客户端连接命令

LAN 情况:
```bash
vncviewer -encodings tight -quality 5 <设备IP>
```

或用 RealVNC、TightVNC 等图形客户端。

### 抓包验证 dirty-tile 减少了流量

在 Mac 上:
```bash
sudo tcpdump -i en0 -nn 'host <设备IP> and port 5900' -G 1 -W 60 -w veency-%S.pcap
```
桌面静止时每秒应只有几 KB,滚动时增大,与之前"始终全屏"明显区别。

## 故障排查

| 现象 | 可能原因 | 处理 |
|---|---|---|
| `error: too many errors` | UIKit stub 不全 | 重跑 `setup-build-env.sh` |
| `ldid: command not found` | 未装 ldid | `brew install ldid` |
| 设备装包后 SpringBoard 闪退 | dylib 链接到不存在的符号 | `otool -L Veency.dylib` 检查依赖,确认 libvncserver 等在设备 `/usr/lib/` |
| VNC 连接黑屏 | iOS 7+ 的 cursor 问题 | 设置中关掉 "显示鼠标光标" |
| FPS 没提升 | 设置 SkipBlack=8000 时仍走非直通路径 | 把 SkipBlack 改 0 启用 T1-E 直通 |
| MaxFPS 不生效 | 旧版 Veency 没有此 key | 重启 SpringBoard 后再设置 |

## 文件清单

构建脚本生成的文件:
- `Veency.dylib` —— 编译产物
- `veency_*.deb` —— 安装包
- `pkg-build/` —— 临时打包目录(可删)

`setup-build-env.sh` 创建的文件(纳入 git 跟踪):
- `SimulateKeyboard.h` —— 历史遗留空 stub
- `theos/include/UIKit/UIKit.h` —— 最小 UIKit 声明
- `theos/include/UIKit/*.h`(421 个 redirect stub)—— 截获现代 SDK
- `theos/include/WebCore/WKTypes.h` —— WebCore 占位类型
- `theos/include/{ChatKit,DataAccess,MIME,...}/X.h` —— 大型框架空 stub

可在 `.gitignore` 忽略:`SimulateTouch/`、`theos/include/`(可由脚本重生成)。
