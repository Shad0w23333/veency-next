#!/usr/bin/env python3
"""Veency-next H.264 实时预览 + 鼠标键盘控制
   ① ffplay 子进程显示 H.264 流(硬件解码)
   ② tkinter 窗口捕获鼠标 + 键盘 → 通过同一 VNC 连接转发给 iPod
   用法:
     python3 veency-h264-viewer.py [host] [port] [password]
"""
import socket, struct, sys, subprocess, threading, time

VEENCY_H264 = 0x48323634  # 'H264'

def _ensure_pycryptodome():
    try:
        from Crypto.Cipher import DES  # noqa
        return
    except ImportError:
        pass
    print("[setup] 自动安装 PyCryptodome...")
    for args in (
        [sys.executable, '-m', 'pip', 'install', '--quiet', 'pycryptodome'],
        [sys.executable, '-m', 'pip', 'install', '--quiet', '--user', 'pycryptodome'],
        [sys.executable, '-m', 'pip', 'install', '--quiet', '--break-system-packages', 'pycryptodome'],
    ):
        try:
            subprocess.check_call(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            import importlib, site
            importlib.reload(site)
            from Crypto.Cipher import DES  # noqa
            print("[setup] ✅"); return
        except Exception:
            continue
    print("[!] 自动安装失败,请手动: pip3 install pycryptodome"); sys.exit(2)

_ensure_pycryptodome()
from Crypto.Cipher import DES

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

# 共享状态(由网络线程 + 输入线程共同访问)
class State:
    def __init__(self):
        self.sock = None
        self.lock = threading.Lock()
        self.w = 0
        self.h = 0
        self.running = True
        self.h264_count = 0
        self.h264_bytes = 0

S = State()

def send_pointer(buttons, x, y):
    """发送 PointerEvent 到 iPod。x/y 是 iPod 实际坐标(0..w / 0..h)"""
    if S.sock is None: return
    x = max(0, min(S.w - 1, int(x)))
    y = max(0, min(S.h - 1, int(y)))
    msg = struct.pack('>BBHH', 5, buttons, x, y)
    with S.lock:
        try: S.sock.send(msg)
        except Exception: pass

def send_key(keysym, down):
    """发送 KeyEvent。keysym 是 X11 keysym。"""
    if S.sock is None: return
    msg = struct.pack('>BBHI', 4, 1 if down else 0, 0, keysym & 0xFFFFFFFF)
    with S.lock:
        try: S.sock.send(msg)
        except Exception: pass

# ASCII → keysym(简化映射,大多数可见字符 ASCII 即 keysym)
def char_to_keysym(c):
    # 直接 ASCII 即 X11 keysym
    return ord(c)

# 特殊键 keysym
SPECIAL_KEYS = {
    'Return': 0xFF0D, 'BackSpace': 0xFF08, 'Tab': 0xFF09,
    'Escape': 0xFF1B, 'Up': 0xFF52, 'Down': 0xFF54,
    'Left': 0xFF51, 'Right': 0xFF53, 'space': 0x20,
    # iPod 系统按键(走 VNCPointer 的 button bits)
    'Home': 'home', 'Lock': 'lock', 'Headset': 'headset',
}

def setup_input_window():
    """启动 tkinter 输入窗口,捕获鼠标键盘并转发给 iPod"""
    try:
        import tkinter as tk
    except ImportError:
        print("[input] tkinter 不可用 — 跳过输入窗口")
        return None

    root = tk.Tk()
    root.title("Veency 输入板(在此处点击/拖动控制 iPod)")
    # 缩小一半显示作为触摸板
    pad_w, pad_h = S.w // 2, S.h // 2
    root.geometry(f"{pad_w + 220}x{pad_h + 80}")

    # 触摸区
    pad = tk.Canvas(root, width=pad_w, height=pad_h, bg='#222', highlightthickness=2,
                    highlightbackground='#888')
    pad.grid(row=0, column=0, padx=10, pady=10, rowspan=10)

    # 控制面板
    info = tk.Label(root, text=f"iPod {S.w}×{S.h}\n输入板 {pad_w}×{pad_h}",
                    fg='#888', font=('Helvetica', 11))
    info.grid(row=0, column=1, sticky='nw', padx=5, pady=10)

    status = tk.Label(root, text='等待…', fg='#0a0', font=('Helvetica', 11))
    status.grid(row=1, column=1, sticky='nw', padx=5)

    def on_motion(e):
        x = int(e.x * S.w / pad_w); y = int(e.y * S.h / pad_h)
        send_pointer(0, x, y)

    def on_press(e):
        x = int(e.x * S.w / pad_w); y = int(e.y * S.h / pad_h)
        send_pointer(1, x, y)
        status.config(text=f'点击 ({x},{y})')

    def on_release(e):
        x = int(e.x * S.w / pad_w); y = int(e.y * S.h / pad_h)
        send_pointer(0, x, y)

    def on_drag(e):
        x = int(e.x * S.w / pad_w); y = int(e.y * S.h / pad_h)
        send_pointer(1, x, y)

    pad.bind('<Motion>', on_motion)
    pad.bind('<Button-1>', on_press)
    pad.bind('<ButtonRelease-1>', on_release)
    pad.bind('<B1-Motion>', on_drag)

    # iPod 系统按键
    def home_press():
        send_pointer(0x04, S.w // 2, S.h // 2)
        time.sleep(0.05)
        send_pointer(0x00, S.w // 2, S.h // 2)
    def lock_press():
        send_pointer(0x02, 0, 0); time.sleep(0.05); send_pointer(0x00, 0, 0)

    btn_frame = tk.Frame(root)
    btn_frame.grid(row=2, column=1, sticky='nw', padx=5, pady=5)
    tk.Button(btn_frame, text='Home', command=home_press, width=8).pack(pady=2)
    tk.Button(btn_frame, text='Lock',  command=lock_press, width=8).pack(pady=2)

    # 文字输入框
    entry_label = tk.Label(root, text='文字输入(回车发送 Enter)', fg='#888')
    entry_label.grid(row=3, column=1, sticky='nw', padx=5, pady=(10, 0))
    entry = tk.Entry(root, width=24)
    entry.grid(row=4, column=1, sticky='nw', padx=5)
    def on_entry_key(e):
        # 把字符当 keypress 发,然后清回车发送
        if e.keysym == 'Return':
            send_key(SPECIAL_KEYS['Return'], True)
            send_key(SPECIAL_KEYS['Return'], False)
            entry.delete(0, 'end')
            return 'break'
        if e.keysym == 'BackSpace':
            send_key(SPECIAL_KEYS['BackSpace'], True)
            send_key(SPECIAL_KEYS['BackSpace'], False)
            return None  # 同时让 entry 自己删
        if len(e.char) == 1 and e.char.isprintable():
            ks = ord(e.char)
            send_key(ks, True); send_key(ks, False)
        return None
    entry.bind('<Key>', on_entry_key)

    # 帧速显示
    fps_label = tk.Label(root, text='', fg='#888', font=('Courier', 10))
    fps_label.grid(row=9, column=1, sticky='sw', padx=5, pady=10)
    last_count = [0, time.time()]
    def update_fps():
        now = time.time(); dt = now - last_count[1]
        if dt > 1:
            cur = S.h264_count
            fps = (cur - last_count[0]) / dt
            fps_label.config(text=f'{fps:.1f} FPS\n{S.h264_bytes/1e3:.0f} KB / {cur} 帧')
            last_count[0] = cur; last_count[1] = now
        if S.running: root.after(500, update_fps)
    root.after(500, update_fps)

    return root

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
    si = recv_n(s, 24); w, h = struct.unpack('>HH', si[:4])
    nl = struct.unpack('>I', si[20:24])[0]
    name = recv_n(s, nl).decode('utf-8', errors='replace')
    print(f"[veency] 已连 {w}×{h} ({name})")

    S.sock = s; S.w = w; S.h = h

    # 唤醒
    send_pointer(0x04, w // 2, h // 2); time.sleep(0.05)
    send_pointer(0x00, w // 2, h // 2)
    print("[veency] 已发 home 唤醒事件")

    # 启动低延迟 ffplay
    ffplay = subprocess.Popen([
        'ffplay',
        '-hide_banner', '-loglevel', 'error',
        '-probesize', '32', '-analyzeduration', '0',
        '-fflags', 'nobuffer+flush_packets', '-flags', 'low_delay',
        '-framedrop', '-vf', 'setpts=N/(30*TB)',
        '-f', 'h264',
        '-window_title', f'Veency H.264 — {w}×{h}',
        '-i', 'pipe:0',
    ], stdin=subprocess.PIPE)

    # 持续 incremental + keep-alive 微动光标
    def request_thread():
        toggle = 0
        while S.running:
            try: s.send(struct.pack('>BBHHHH', 3, 1, 0, 0, w, h))
            except Exception: return
            # 每 0.5s 微动光标维持 SpringBoard 重绘
            if toggle % 5 == 4:
                send_pointer(0, w // 2 + (toggle % 3), h // 2)
            toggle += 1
            time.sleep(0.1)
    threading.Thread(target=request_thread, daemon=True).start()

    # 网络读循环
    def network_thread():
        try:
            while S.running:
                hdr = recv_n(s, 4); mt = hdr[0]
                if mt == 2: continue
                if mt == 3:
                    ln = struct.unpack('>I', recv_n(s, 4))[0]; recv_n(s, ln); continue
                if mt != 0: print(f"[net] 未知 msg {mt},终止"); return
                nrects = struct.unpack('>H', hdr[2:4])[0]
                for _ in range(nrects):
                    rh = recv_n(s, 12)
                    rx, ry, rw, rh_, enc = struct.unpack('>HHHHi', rh)
                    enc_u = enc & 0xFFFFFFFF
                    if enc_u == VEENCY_H264:
                        ln = struct.unpack('>I', recv_n(s, 4))[0]
                        data = recv_n(s, ln)
                        try: ffplay.stdin.write(data); ffplay.stdin.flush()
                        except (BrokenPipeError, IOError): return
                        S.h264_count += 1; S.h264_bytes += ln
                    elif enc == 0:
                        recv_n(s, rw * rh_ * 4)
                    elif enc == 16:
                        ln = struct.unpack('>I', recv_n(s, 4))[0]; recv_n(s, ln)
                    else:
                        print(f"[net] 未知 enc 0x{enc_u:08x},终止"); return
        except EOFError: print("server closed")
        except Exception as e: print(f"[net] err: {e}")
        finally:
            S.running = False
    threading.Thread(target=network_thread, daemon=True).start()

    # 启动输入窗口(主线程,会阻塞)
    win = setup_input_window()
    if win:
        try:
            win.mainloop()
        except KeyboardInterrupt:
            pass

    S.running = False
    try: ffplay.stdin.close()
    except: pass
    ffplay.terminate()
    s.close()
    print(f"\n=== {S.h264_count} 帧 H.264 / {S.h264_bytes/1e6:.2f} MB ===")

if __name__ == '__main__':
    main()
