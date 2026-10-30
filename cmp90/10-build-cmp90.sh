#!/bin/bash
# Build open module 595.99.02 có vá mở khoá compute CMP 90HX — CHƯA THỬ VỚI CARD THẬT (xem README.md).
# Chạy bằng user thường TRÊN Jetson, sau ../10-build.sh (cần ~/egpu/ogkm-595.99.02.tar.gz). Không cài gì:
# ra cây riêng ~/egpu/open-gpu-kernel-modules-595.99.02-cmp90, bản gốc không bị đụng. Chọn bản: cmp90-mode.
#   0014+0015: cmpunlocker v0.1.28 90HX stockflow rejoin15 (MIT, pearlfortune), viết cho 610.43.03
#   0016:      port sang 595.99.02 (595 không có confComputeForceUnprotAlloc)
set -euo pipefail
V=595.99.02
W=$HOME/egpu
TGZ=ogkm-$V.tar.gz
SHA_TGZ=b8891cb617683e28ef1e4c3add8dbc30e648b8cd6429a3d521f20dde44633262
N=open-gpu-kernel-modules-$V-cmp90
HERE=$(cd "$(dirname "$0")" && pwd)

cd "$W"
echo "$SHA_TGZ  $TGZ" | sha256sum -c -
rm -rf "$N"
tar xzf "$TGZ" --transform "s|^open-gpu-kernel-modules-$V|$N|"
for p in "$HERE"/patches/00*.patch; do
    patch -d "$N" -p1 --forward < "$p" >/dev/null
    echo "vá: $(basename "$p")"
done
grep -q CMP90_STOCKFLOW_REJOIN15 "$N/kernel-open/nvidia/nv.c"

# ~6 nhân Orin Nano: ~6 phút
make -C "$N" modules -j"$(nproc)" SYSSRC="/lib/modules/$(uname -r)/build"
modinfo -F vermagic "$N/kernel-open/nvidia.ko"
grep -aq CMP90_STOCKFLOW_REJOIN15 "$N/kernel-open/nvidia.ko"
mkdir -p "$W/cmp90" && cp "$HERE/cmp90-mode" "$W/cmp90/"
echo "Xong (chưa cài). Khi đã cắm 90HX: sudo $W/cmp90/cmp90-mode cmp90 && sudo reboot"
