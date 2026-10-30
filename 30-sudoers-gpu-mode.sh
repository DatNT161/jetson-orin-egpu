#!/bin/bash
# Let a user switch the CUDA mode (gpu-mode igpu|dgpu) without a sudo password.
# Only these 2 commands with fixed arguments; gpu-mode must be owned by root and not writable by the user.
# Remove: sudo rm /etc/sudoers.d/gpu-mode
set -euo pipefail
U=${1:-${SUDO_USER:?give a user name: sudo bash 30-sudoers-gpu-mode.sh <user>}}
BIN=/usr/local/sbin/gpu-mode
HERE=$(cd "$(dirname "$0")" && pwd)
F=/etc/sudoers.d/gpu-mode

[ "$(id -u)" = 0 ] || { echo "Run with sudo"; exit 1; }
id "$U" >/dev/null

# gpu-mode re-invokes sudo with its real path (matches the rule below)
install -o root -g root -m755 "$HERE/gpu-mode" "$BIN"
[ "$(stat -c %U%a "$BIN")" = root755 ] || { echo "$BIN must be root:755"; exit 1; }

tmp=$(mktemp)
cat > "$tmp" <<EOF
# gpu-mode: switch CUDA iGPU <-> eGPU on Jetson (30-sudoers-gpu-mode.sh)
$U ALL=(root) NOPASSWD: $BIN igpu, $BIN dgpu
EOF
visudo -cf "$tmp"
install -o root -g root -m440 "$tmp" "$F"
rm -f "$tmp"
visudo -c >/dev/null && echo "OK: $F"
sudo -l -U "$U" | grep gpu-mode
