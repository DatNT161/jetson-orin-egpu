#!/bin/bash
# Build open-gpu-kernel-modules + giải nén userspace cho eGPU trên Jetson Orin Nano (JetPack 7.2.1).
# Chạy bằng user thường TRÊN Jetson, không cần sudo. Ra ~/egpu/, sau đó: sudo bash 20-install-dgpu.sh
# Có Internet (4G) thì tự tải; không thì chép sẵn 2 file vào ~/egpu (tải trên máy khác rồi scp sang).
set -euo pipefail
V=595.99.02
W=$HOME/egpu
RUN=NVIDIA-Linux-aarch64-$V.run
TGZ=ogkm-$V.tar.gz
SHA_RUN=082a8765337628d399e32669dab0dcb91269f691df470e3b9389b87569d2ff6c
SHA_TGZ=b8891cb617683e28ef1e4c3add8dbc30e648b8cd6429a3d521f20dde44633262
HERE=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$W" && cd "$W"
[ -f "$RUN" ] || curl -fL -o "$RUN" "https://us.download.nvidia.com/XFree86/aarch64/$V/$RUN"
[ -f "$TGZ" ] || curl -fL -o "$TGZ" "https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/$V.tar.gz"
echo "$SHA_RUN  $RUN" | sha256sum -c -
echo "$SHA_TGZ  $TGZ" | sha256sum -c -

[ -d "open-gpu-kernel-modules-$V" ] || tar xzf "$TGZ"
[ -d "dgpu-$V" ] || sh "$RUN" --extract-only --target "dgpu-$V" >/dev/null

# ~6 nhân Orin Nano: ~6 phút
make -C "open-gpu-kernel-modules-$V" modules -j"$(nproc)" SYSSRC="/lib/modules/$(uname -r)/build"
modinfo -F vermagic "open-gpu-kernel-modules-$V/kernel-open/nvidia.ko"

# 20-install-dgpu.sh đọc gpu-mode từ ~/egpu
cp "$HERE/gpu-mode" "$HERE/egpu_bench.cu" "$W/"
echo "Xong. Tiếp: sudo bash $HERE/20-install-dgpu.sh && sudo reboot"
