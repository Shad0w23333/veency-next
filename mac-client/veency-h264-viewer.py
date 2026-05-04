#!/usr/bin/env python3
"""Veency H.264 实时预览客户端(MVP)
   连 Veency,把硬件 H.264 NALU 流 pipe 给 ffplay 做硬件解码 + 显示。
   用法:
     python3 veency-h264-viewer.py [host] [port] [password]
     例: python3 veency-h264-viewer.py 127.0.0.1 5900 alpine
"""
import socket, struct, sys, subprocess, threading

def _ensure_pycryptodome():
    try:
        from Crypto.Cipher import DES  # noqa
        return
    except ImportError:
        pass
    print("[setup] 第一次运行 — 自动安装 PyCryptodome (DES 用于 VNC 鉴权)...")
    for args in (
        [sys.executable, '-m', 'pip', 'install', '--quiet', 'pycryptodome'],
        [sys.executable, '-m', 'pip', 'install', '--quiet', '--user', 'pycryptodome'],
        [sys.executable, '-m', 'pip', 'install', '--quiet', '--break-system-packages', 'pycryptodome'],
    ):
        try:
            subprocess.check_call(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            # 确保新装的包能在当前进程立刻 import
            import importlib, site
            importlib.reload(site)
            from Crypto.Cipher import DES  # noqa
            print("[setup] ✅ 安装成功")
            return
        except (subprocess.CalledProcessError, ImportError):
            continue
    print("[setup] 自动安装失败。请手动执行其中一条:")
    print("        pip3 install pycryptodome")
    print("        pip3 install --user pycryptodome")
    print("        pip3 install --break-system-packages pycryptodome")
    sys.exit(2)

_ensure_pycryptodome()
from Crypto.Cipher import DES

VEENCY_H264 = 0x48323634  # 'H264'

def vnc_response(password, challenge):
    pwd = (password.encode() + b'\x00' * 8)[:8]
    key = bytes(int(f'{b:08b}'[::-1], 2) for b in pwd)
    return DES.new(key, DES.MODE_ECB).encrypt(challenge)

def recv_n(s, n):
    buf = b''
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c: raise EOFError()
        buf += c
    return buf

def main():
    host = sys.argv[1] if len(sys.argv) > 1 else '127.0.0.1'
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 5900
    pwd  = sys.argv[3] if len(sys.argv) > 3 else 'alpine'

    s = socket.socket(); s.connect((host, port))
    s.recv(12); s.send(b'RFB 003.008\n')
    nm = s.recv(1)[0]; s.recv(nm); s.send(b'\x02')
    s.send(vnc_response(pwd, s.recv(16)))
    sec = s.recv(4)
    if sec != b'\x00\x00\x00\x00':
        print("auth 失败"); return
    s.send(b'\x01')
    # ServerInit (24 bytes固定):w(2) h(2) pixfmt(16) name-length(4) | 然后 name(N bytes)
    si = recv_n(s, 24)
    w, h = struct.unpack('>HH', si[:4])
    nl = struct.unpack('>I', si[20:24])[0]
    name = recv_n(s, nl).decode('utf-8', errors='replace')
    print(f"[veency] 已连 {w}×{h} ({name})")

    # 发 home (button 0x04) 按下 + 抬起,唤醒 iPod 屏幕,触发 OnLayer 进而触发 VT 编码
    import time
    s.send(struct.pack('>BBHH', 5, 0x04, w//2, h//2))   # PointerEvent: home
    time.sleep(0.05)
    s.send(struct.pack('>BBHH', 5, 0x00, w//2, h//2))   # release
    print(f"[veency] 已发 home 唤醒事件")

    # 启动 ffplay 用 VideoToolbox 硬解 H.264 Annex B 流
    ffplay = subprocess.Popen([
        'ffplay',
        '-hide_banner',
        '-loglevel', 'error',
        '-probesize', '32',
        '-analyzeduration', '0',
        '-fflags', 'nobuffer+flush_packets',
        '-flags', 'low_delay',
        '-framedrop',
        '-vf', 'setpts=N/30/TB',     # 强制 30fps 时间戳,降低延迟
        '-f', 'h264',
        '-window_title', f'Veency H.264 — {w}×{h}',
        '-i', 'pipe:0',
    ], stdin=subprocess.PIPE)

    # 关键:H.264 模式下绝不发 non-incremental(否则 libvncserver 会自动塞 Raw 全屏)
    # 只发 incremental,server 无标脏 → 不主动响应,我们的 VT 异步把 H.264 NALU 直接 push
    def request_thread():
        import time
        while True:
            try:
                s.send(struct.pack('>BBHHHH', 3, 1, 0, 0, w, h))
            except Exception:
                return
            time.sleep(0.1)  # 100ms 节流,避免 libvncserver 主线程发响应造成混流

    threading.Thread(target=request_thread, daemon=True).start()
    print("[veency] 等待第一关键帧(iPod 屏幕变化时触发)...")

    h264_count = 0; h264_bytes = 0
    other_skip = 0
    try:
        while True:
            hdr = recv_n(s, 4)
            mt = hdr[0]
            # 非 FramebufferUpdate 消息要按对应长度跳过 body,否则后续流偏移
            if mt == 2:        # Bell:无 body
                continue
            if mt == 3:        # ServerCutText:7 bytes 已含 + 4 bytes 长度 + N bytes 文字
                #  hdr[1..3] 是 padding,接下来 4 bytes 是长度
                ln = struct.unpack('>I', recv_n(s, 4))[0]; recv_n(s, ln); continue
            if mt != 0:        # 未知,放弃以免把后续 H.264 字节读乱
                print(f"  未知服务端消息 type={mt},终止"); return
            nrects = struct.unpack('>H', hdr[2:4])[0]
            for _ in range(nrects):
                rh = recv_n(s, 12)
                rx, ry, rw, rh_, enc = struct.unpack('>HHHHi', rh)
                enc_u = enc & 0xFFFFFFFF
                if enc_u == VEENCY_H264:
                    ln = struct.unpack('>I', recv_n(s, 4))[0]
                    data = recv_n(s, ln)
                    try:
                        ffplay.stdin.write(data); ffplay.stdin.flush()
                    except (BrokenPipeError, IOError):
                        return
                    h264_count += 1; h264_bytes += ln
                    if h264_count == 1:
                        print(f"[veency] 收到第一帧 H.264 ({ln} bytes)")
                    elif h264_count % 30 == 0:
                        print(f"  [{h264_count} 帧, {h264_bytes/1e3:.0f} KB,即时 {h264_bytes/h264_count:.0f} B/帧]")
                elif enc == 0:
                    # Raw 兜底响应(libvncserver 在 H.264 模式下也可能首帧自动发)
                    recv_n(s, rw * rh_ * 4); other_skip += 1
                elif enc == 16:  # ZRLE
                    ln = struct.unpack('>I', recv_n(s, 4))[0]; recv_n(s, ln); other_skip += 1
                else:
                    print(f"  未知 enc 0x{enc_u:08x},终止"); return
    except EOFError:
        print("server closed")
    except KeyboardInterrupt:
        pass
    finally:
        try: ffplay.stdin.close()
        except: pass
        ffplay.terminate()
        s.close()
    print(f"\n=== 共 {h264_count} 帧 H.264 / {h264_bytes/1e6:.2f} MB / 跳过 {other_skip} non-H.264 rect ===")

if __name__ == '__main__':
    main()
