[English](README.md) | 简体中文

### 这是一个面向 iPhone、iPod touch、iPad 等设备的 VNC 服务器
* 当设备触摸屏(数字化触控板)损坏时,你应当在设备上安装它。它允许你在屏幕不可用的情况下远程访问设备。



### 安装步骤
* 将 .deb 文件拷贝到设备上,执行 `dpkg -i veency....deb`
* 关机后再开机。(只重启 SpringBoard 而不彻底关机可能会留下残留的 Veency 进程)

### 使用方法
* retina 设备的原始屏幕分辨率对 VNC 来说太大,直传会很慢。请进入"设置 → Veency",把"屏幕尺寸缩小倍数"(Divide screen size by)调到 `3` 或更高,如果你不在意画质损失。
* **⚠️ 客户端编码必须强制 ZRLE**。RealVNC 默认 "Auto select" 在快网/USB 桥接下会选 Raw 编码,2.9 MB/帧瞬间打爆带宽,实测只能跑 4 FPS。强制 ZRLE 后单帧 ~142 KB(20× 压缩),立刻 30+ FPS。
  - RealVNC viewer:`Properties → Inputs and Outputs → Preferred encoding → ZRLE`
  - TigerVNC / TightVNC:`vncviewer -encodings "ZRLE Hextile Raw" <ip>::5900`
  - macOS 内置 Screen Sharing:不能改编码,但会退回 Hextile(6× 压缩,够用)
* http://www.realvnc.com/  RealVNC viewer 是免费的客户端。
* 在 Linux 上也可以使用 `vncviewer -encodings tight quality 5 <设备 IP>`

### 这是一个可在 OSX 上编译的 Veency 版本
* 新增"跳过黑屏"(Skip black screens)选项,使 VNC 在相机、OpenGL ES 等应用下也能正常更新画面。
* 新增"屏幕尺寸缩小倍数"(divide screen size)功能以提速,在 retina 设备上效果尤其明显。
* 使用 SimulateTouch 进行触摸事件注入。

### 编译方法
* `git clone https://github.com/DHowett/theos.git`(此版本较老。我没试过最新版本,新版本在 https://github.com/theos/theos)
* `git clone https://github.com/iolate/SimulateTouch.git`
* 将 `theos_includes.zip` 解压到 `theos/include`(也可以从 iphone-dev 等其他地方获取头文件)
* 编辑 `Makefile.osx`,把里面的 framework 路径改成你本地 Xcode 安装的位置。
* 执行 `make -f Makefile.osx package`

### 中文文档导航
* [README.zh.md](README.zh.md) — 项目简介与安装(本文件)
* [ARCHITECTURE.zh.md](ARCHITECTURE.zh.md) — 代码架构与每帧数据流向
* [OPTIMIZATION_PLAN.zh.md](OPTIMIZATION_PLAN.zh.md) — Tier 1-3 优化路线图(M1+M2 已上机)
* [OPTIMIZATION_TIER4-7.zh.md](OPTIMIZATION_TIER4-7.zh.md) — Tier 4-7 极致优化(含 iOS 6 时代 Apple 私有 API 研究)
* [BUILD.zh.md](BUILD.zh.md) — 在 macOS 上从源码构建 .deb 的完整指南
