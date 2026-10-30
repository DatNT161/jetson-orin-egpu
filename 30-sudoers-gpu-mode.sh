#!/bin/bash
# Cho user đổi chế độ CUDA (gpu-mode igpu|dgpu) không cần mật khẩu sudo.
# Chỉ đúng 2 lệnh có tham số cố định; gpu-mode phải thuộc root và user không ghi được.
# Gỡ: sudo rm /etc/sudoers.d/gpu-mode
set -euo pipefail
U=${1:-${SUDO_USER:?cho tên user: sudo bash 30-sudoers-gpu-mode.sh <user>}}
BIN=/usr/local/sbin/gpu-mode
HERE=$(cd "$(dirname "$0")" && pwd)
F=/etc/sudoers.d/gpu-mode

[ "$(id -u)" = 0 ] || { echo "Chạy bằng sudo"; exit 1; }
id "$U" >/dev/null

# Bản gpu-mode mới gọi lại sudo bằng đường dẫn thật (khớp luật dưới)
install -o root -g root -m755 "$HERE/gpu-mode" "$BIN"
[ "$(stat -c %U%a "$BIN")" = root755 ] || { echo "$BIN phải là root:755"; exit 1; }

tmp=$(mktemp)
cat > "$tmp" <<EOF
# gpu-mode: đổi CUDA iGPU <-> eGPU trên Jetson (30-sudoers-gpu-mode.sh)
$U ALL=(root) NOPASSWD: $BIN igpu, $BIN dgpu
EOF
visudo -cf "$tmp"
install -o root -g root -m440 "$tmp" "$F"
rm -f "$tmp"
visudo -c >/dev/null && echo "OK: $F"
sudo -l -U "$U" | grep gpu-mode
