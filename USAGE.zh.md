# Veency-next 使用指南 — Mac 端连接

## 两种连接方式速览

| 方式 | 客户端 | 编码 | 带宽 | 建议场景 |
|---|---|---|---|---|
| **A** RealVNC viewer | 通用 | ZRLE / Hextile | 中等(140 KB/帧) | 普通使用,稳定 |
| **B** H.264 实时预览 | 本仓库 Python + ffplay | 硬件 H.264 | 极低(5-15 KB/帧) | 流畅度优先,体验最好 |

## 共用前置:启动 USB ↔ TCP 端口转发

iPod 通过 USB 连 Mac,用 libimobiledevice 的 iproxy 把设备的 5900 暴露到 Mac 的 localhost:

```bash
brew install libimobiledevice  # 一次性安装

# 后台启动转发(Mac:5900 → iPod:5900)
iproxy 5900 5900 &

# 验证
nc -z localhost 5900 && echo "iPod 上 Veency 服务正常"
```

> 不通过 USB,改用 WiFi:`iproxy` 改成连接设备 IP 即可,如 `vncviewer 192.168.1.x:5900`。

---

## 方式 A:用 RealVNC viewer 连(简单)

### 1. 设置 iPod 端

iPod 上打开「设置 → Veency-next」:
- **启用 Veency 服务** → 开
- **VNC 密码** → 设个密码(例:`alpine`)
- **启用硬件 H.264 编码** → **关闭**(关键,RealVNC 不支持 H.264)
- **每秒最大帧数** → 30(默认)
- **屏幕尺寸缩小倍数** → retina 设备建议 2 或 3

### 2. Mac 端连

下载 [RealVNC Viewer](https://www.realvnc.com/en/connect/download/viewer/)(免费),连 `localhost:5900`,密码用第 1 步设的。

**重要:把编码强制设为 ZRLE**(否则默认 Raw,USB 转发下会卡):
- RealVNC 菜单 → Properties → Inputs and Outputs → **Preferred encoding → ZRLE**

或命令行用 TigerVNC viewer:
```bash
brew install tigervnc-viewer
vncviewer -PreferredEncoding=ZRLE localhost:5900
```

---

## 方式 B:H.264 硬件编码模式(推荐,最流畅)

### 1. 设置 iPod 端

iPod 上打开「设置 → Veency-next」:
- **启用 Veency 服务** → 开
- **VNC 密码** → 设个密码
- **启用硬件 H.264 编码** → **开启** ⭐
- **比特率(kbps)** → 4000(默认,可调 1000-10000)
- **关键帧间隔(帧数)** → 60
- **编码 Profile** → main(默认,可选 baseline / high)
- **每秒最大帧数** → 30 或 60

### 2. Mac 端依赖

```bash
brew install ffmpeg
pip3 install pycryptodome
```

### 3. 连接

```bash
cd /path/to/veency-next
python3 mac-client/veency-h264-viewer.py 127.0.0.1 5900 你的密码
```

会弹出 ffplay 窗口实时显示 iPod 屏幕(硬件解码,iPod CPU 几乎为零)。

**注意**:H.264 模式下,普通 RealVNC 会看到乱码 —— 因为我们用了自定义 RFB pseudo-encoding `0x48323634`('H264'),只有兼容客户端能解。

---

## 常见问题排查

| 现象 | 原因 / 解法 |
|---|---|
| `nc -z localhost 5900` 失败 | iproxy 没在跑,或 iPod 未越狱 / 没装 OpenSSH。运行 `pgrep iproxy` 检查 |
| RealVNC 黑屏或乱码 | 90% 概率是 H264Enabled 还开着 → 关掉 |
| RealVNC 帧率很低 | Preferred encoding 没改 ZRLE |
| H.264 viewer 提示 auth 失败 | 密码错。Veency-next 默认 plist 没密码就提示弹窗;若设了密码,要用同一个 |
| H.264 viewer 没画面 | 检查「捕获方式 - 使用 CARenderServer」要关闭(那是实验路径,backboardd 内不可用,会自动 fallback 但有日志噪音) |
| 设置改了不生效 | 通常 plist 写入会自动通知;若不行可 SSH 到设备 `killall -9 backboardd` 强制重启 |

---

## 设备端部署(若需更新 dylib)

```bash
cd /path/to/veency-next
./setup-build-env.sh        # 一次性
./deploy-to-ipod.sh deploy  # 编译 + 推到设备 + 重启 backboardd
```

回退到原版:`./deploy-to-ipod.sh revert`

---

## 状态栏图标含义

iPod 顶部状态栏有 Veency 小图标 = 当前有 VNC 客户端连接中。
没图标 = 服务在跑但无人连。
