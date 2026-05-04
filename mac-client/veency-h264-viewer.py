#!/usr/bin/env python3
"""Veency H.264 实时预览客户端(MVP)
   连 Veency,把硬件 H.264 NALU 流 pipe 给 ffplay 做硬件解码 + 显示。
   用法:
     python3 veency-h264-viewer.py [host] [port] [password]
     例: python3 veency-h264-viewer.py 127.0.0.1 5900 alpine
"""
import socket, struct, sys, subprocess, threading
try:
    from Crypto.Cipher import DES
except ImportError:
    print("缺 PyCryptodome: pip3 install pycryptodome"); sys.exit(2)

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
    si = recv_n(s, 24); w, h = struct.unpack('>HH', si[:4])
    nl = struct.unpack('>I', recv_n(s, 4))[0]; recv_n(s, nl)
    print(f"[veency] 已连 {w}×{h}")

    # 启动 ffplay 用 VideoToolbox 硬解
    ffplay = subprocess.Popen([
        'ffplay',
        '-loglevel', 'error',
        '-fflags', 'nobuffer',
        '-flags', 'low_delay',
        '-framedrop',
        '-strict', 'experimental',
        '-vf', 'setpts=0',           # 不插帧延迟
        '-f', 'h264',
        '-c:v', 'h264',              # 也可改 h264_videotoolbox 强制 HW 解
        '-window_title', f'Veency H.264 — {w}×{h}',
        '-i', 'pipe:0',
    ], stdin=subprocess.PIPE)

    # 持续发增量请求
    def request_thread():
        while True:
            try:
                s.send(struct.pack('>BBHHHH', 3, 1, 0, 0, w, h))
            except Exception:
                return
            import time; time.sleep(0.02)

    threading.Thread(target=request_thread, daemon=True).start()

    # 第一帧整屏
    s.send(struct.pack('>BBHHHH', 3, 0, 0, 0, w, h))

    h264_count = 0; h264_bytes = 0
    other_skip = 0
    try:
        while True:
            hdr = recv_n(s, 4)
            if hdr[0] != 0:  # not FramebufferUpdate
                continue
            nrects = struct.unpack('>H', hdr[2:4])[0]
            for _ in range(nrects):
                rh = recv_n(s, 12)
                rx, ry, rw, rh_, enc = struct.unpack('>HHHHi', rh)
                enc_u = enc & 0xFFFFFFFF
                if enc_u == VEENCY_H264:
                    ln = struct.unpack('>I', recv_n(s, 4))[0]
                    data = recv_n(s, ln)
                    ffplay.stdin.write(data); ffplay.stdin.flush()
                    h264_count += 1; h264_bytes += ln
                    if h264_count % 30 == 1:
                        print(f"  [{h264_count} 帧, {h264_bytes/1e3:.0f} KB 累计]")
                elif enc == 0:
                    recv_n(s, rw * rh_ * 4); other_skip += 1
                elif enc == 16:  # ZRLE
                    ln = struct.unpack('>I', recv_n(s, 4))[0]
                    recv_n(s, ln); other_skip += 1
                elif enc == 5:  # Hextile - too complex to skip cleanly
                    print(f"  Hextile encoding encountered, can't skip — stopping")
                    return
                else:
                    print(f"  unknown enc 0x{enc_u:08x} — stopping")
                    return
    except EOFError:
        print("server closed")
    except KeyboardInterrupt:
        pass
    finally:
        try: ffplay.stdin.close()
        except: pass
        ffplay.terminate()
        s.close()
    print(f"\n=== 共 {h264_count} 帧, {h264_bytes/1e6:.2f} MB,跳过 {other_skip} 个非 H.264 rect ===")

if __name__ == '__main__':
    main()
