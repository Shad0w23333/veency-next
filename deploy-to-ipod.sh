#!/bin/bash
# Veency 一键部署到 USB 连接的 iPod touch 5(iOS 6.1.3)
# 假设:
#   1. 设备通过 USB 连接,已与 macOS 配对
#   2. 安装了 brew + libimobiledevice + sshpass + ldid + dpkg
#   3. 设备已越狱并装有 OpenSSH(默认密码 alpine)
#   4. 已完整运行过 ./setup-build-env.sh
set -e
cd "$(dirname "$0")"

usage() {
    cat <<EOF
用法:
  ./deploy-to-ipod.sh build     仅本地构建 .dylib + .deb
  ./deploy-to-ipod.sh push      推送 .dylib 到设备(不重启 backboardd)
  ./deploy-to-ipod.sh deploy    构建 + 推送 + 重启 backboardd(完整流程)
  ./deploy-to-ipod.sh revert    恢复设备上的原 Veency.dylib(从 /var/root/*.bak)
  ./deploy-to-ipod.sh test-vnc  快速 VNC 握手 + 抓帧测试(需要 Python)
  ./deploy-to-ipod.sh syslog    流式查看设备 syslog
EOF
}

setup_iproxy() {
    if ! pgrep -f "iproxy 2222" >/dev/null; then
        iproxy 2222 22 >/dev/null 2>&1 &
        sleep 1
    fi
}

ssh_ipod() {
    SSHPASS=alpine sshpass -e ssh -p 2222 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o "HostKeyAlgorithms=+ssh-rsa" -o "PubkeyAcceptedAlgorithms=+ssh-rsa" \
        -o LogLevel=ERROR root@localhost "$@"
}

scp_ipod() {
    SSHPASS=alpine sshpass -e scp -P 2222 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o "HostKeyAlgorithms=+ssh-rsa" -o "PubkeyAcceptedAlgorithms=+ssh-rsa" \
        -o LogLevel=ERROR "$@"
}

cmd_build() {
    ./build.sh package
    # 把 libvncserver 的 libjpeg/libgcrypt 改成弱链接(设备上没这两个 lib)
    if ! python3 -c "
import struct
with open('libvncserver.dylib','rb') as f: d=f.read()
ncmds = struct.unpack_from('<I',d,16)[0]
off = 28
for i in range(ncmds):
    cmd, sz = struct.unpack_from('<II',d,off)
    if cmd == 0x80000018:  # LC_LOAD_WEAK_DYLIB,已经改过
        nameoff, = struct.unpack_from('<I',d,off+8)
        nm = d[off+nameoff:].split(b'\\x00',1)[0].decode()
        if 'libjpeg' in nm:
            print('already weak'); exit(0)
    off += sz
exit(1)
" 2>/dev/null; then
        echo "[deploy] 把 libjpeg/libgcrypt 改成弱链接..."
        python3 stubs/weaken-deps.py libvncserver.dylib libjpeg libgcrypt
        mv libvncserver.dylib.weak libvncserver.dylib
        ldid -S libvncserver.dylib
    fi
}

cmd_push() {
    setup_iproxy
    echo "=== 推送 dylib + 配置文件 ==="
    scp_ipod Veency.dylib libvncserver.dylib libsimulatetouch.dylib \
        Tweak.plist root@localhost:/tmp/
    ssh_ipod '
        # 备份(若不存在则跳过)
        [ -f /var/root/Veency.dylib.bak ] || cp -p /Library/MobileSubstrate/DynamicLibraries/Veency.dylib /var/root/Veency.dylib.bak 2>/dev/null
        mv /tmp/Veency.dylib /Library/MobileSubstrate/DynamicLibraries/Veency.dylib
        mv /tmp/Tweak.plist /Library/MobileSubstrate/DynamicLibraries/Veency.plist
        mv /tmp/libvncserver.dylib /usr/lib/libvncserver.0.dylib
        mv /tmp/libsimulatetouch.dylib /usr/lib/libsimulatetouch.dylib
        chmod 755 /Library/MobileSubstrate/DynamicLibraries/Veency.dylib /usr/lib/libvncserver.0.dylib /usr/lib/libsimulatetouch.dylib
    '
    echo "=== 推送 PreferenceLoader plist (中文 UI + MaxFPS 设置) ==="
    scp_ipod PreferenceLoader/Preferences/Veency.plist root@localhost:/Library/PreferenceLoader/Preferences/Veency.plist
}

cmd_deploy() {
    cmd_build
    cmd_push
    echo "=== 重启 backboardd 让新 Veency 注入 ==="
    ssh_ipod 'killall -9 backboardd' || true
    sleep 6
    cmd_test_vnc
}

cmd_revert() {
    setup_iproxy
    ssh_ipod '
        if [ -f /var/root/Veency.dylib.bak ]; then
            cp -p /var/root/Veency.dylib.bak /Library/MobileSubstrate/DynamicLibraries/Veency.dylib
            rm -f /usr/lib/libvncserver.0.dylib /usr/lib/libsimulatetouch.dylib
            echo "已恢复"
        else
            echo "找不到 /var/root/Veency.dylib.bak,无法恢复"; exit 1
        fi
    '
    ssh_ipod 'killall -9 backboardd' || true
}

cmd_test_vnc() {
    setup_iproxy
    if ! pgrep -f "iproxy 5900" >/dev/null; then
        iproxy 5900 5900 >/dev/null 2>&1 &
        sleep 1
    fi
    PY=$(cat <<'PYEOF'
import socket, struct, sys, time
try:
    from Crypto.Cipher import DES
except ImportError:
    print("[!] 缺 PyCryptodome: pip3 install pycryptodome"); sys.exit(2)
def vnc_resp(p, c):
    pwd = (p.encode()+b'\x00'*8)[:8]
    key = bytes(int(f'{b:08b}'[::-1],2) for b in pwd)
    return DES.new(key, DES.MODE_ECB).encrypt(c)
s=socket.socket(); s.settimeout(15); s.connect(('127.0.0.1',5900))
s.recv(12); s.send(b'RFB 003.008\n')
n=s.recv(1)[0]; m=s.recv(n)
if 2 in m:
    s.send(b'\x02'); chal=s.recv(16); s.send(vnc_resp('alpine', chal))
    sec=s.recv(4)
    if sec != b'\x00\x00\x00\x00':
        print("[!] auth 失败,密码不是 alpine"); sys.exit(1)
elif 1 in m:
    s.send(b'\x01'); s.recv(4)
s.send(b'\x01')
si=s.recv(24); w,h=struct.unpack('>HH',si[:4])
nl=struct.unpack('>I',s.recv(4))[0]; name=s.recv(nl).decode()
print(f"[OK] 连上 Veency: {w}×{h}  name={name!r}")
print("[ ] 请求整屏...")
s.send(struct.pack('>BBHHHH',3,0,0,0,w,h))
hdr=s.recv(4); nr=struct.unpack('>H',hdr[2:4])[0]
total=4
for i in range(nr):
    rh=s.recv(12); rx,ry,rw,rh_,enc=struct.unpack('>HHHHi',rh)
    total+=12
    if enc==0:
        rem=rw*rh_*4
        while rem>0:
            c=s.recv(min(65536,rem))
            if not c: break
            rem-=len(c); total+=len(c)
print(f"[OK] 收到 {nr} rects, {total} 字节")
print("[ ] 等 1.5s 后请求增量(应几乎为 0)...")
time.sleep(1.5)
s.send(struct.pack('>BBHHHH',3,1,0,0,w,h))
s.settimeout(2.0)
total2=0; nr2=0
try:
    hdr=s.recv(4); nr2=struct.unpack('>H',hdr[2:4])[0]; total2=4
    for i in range(nr2):
        rh=s.recv(12); rx,ry,rw,rh_,enc=struct.unpack('>HHHHi',rh)
        total2+=12
        if enc==0:
            rem=rw*rh_*4
            while rem>0:
                c=s.recv(min(65536,rem))
                if not c: break
                rem-=len(c); total2+=len(c)
except socket.timeout: pass
print(f"[OK] 增量收到 {nr2} rects, {total2} 字节  (M2 dirty-tile 生效则 << 第一次)")
PYEOF
)
    python3 -c "$PY"
}

cmd_syslog() {
    idevicesyslog | grep -E --color=auto "Veency|VNC|MS:Error|MS:Notice.*Loading|dyld:|Warning|Error"
}

case "${1:-deploy}" in
    build)     cmd_build ;;
    push)      cmd_push ;;
    deploy)    cmd_deploy ;;
    revert)    cmd_revert ;;
    test-vnc)  cmd_test_vnc ;;
    syslog)    cmd_syslog ;;
    *)         usage; exit 1 ;;
esac
