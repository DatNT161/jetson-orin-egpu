#!/bin/bash
# Build open module 595.99.02 with the CMP 90HX compute-unlock patches — UNTESTED WITH A REAL CARD (see README.md).
# Run as a normal user ON the Jetson, after ../10-build.sh (needs ~/egpu/ogkm-595.99.02.tar.gz). Installs nothing:
# builds a separate tree ~/egpu/open-gpu-kernel-modules-595.99.02-cmp90, the stock tree is untouched. Select with: cmp90-mode.
#   0014+0015: cmpunlocker v0.1.28 90HX stockflow rejoin15 (MIT, pearlfortune), written for 610.43.03
#   0016:      port to 595.99.02 (595 has no confComputeForceUnprotAlloc)
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
    echo "patched: $(basename "$p")"
done
grep -q CMP90_STOCKFLOW_REJOIN15 "$N/kernel-open/nvidia/nv.c"

# 6-core Orin Nano: ~6 min
make -C "$N" modules -j"$(nproc)" SYSSRC="/lib/modules/$(uname -r)/build"
modinfo -F vermagic "$N/kernel-open/nvidia.ko"
grep -aq CMP90_STOCKFLOW_REJOIN15 "$N/kernel-open/nvidia.ko"
mkdir -p "$W/cmp90" && cp "$HERE/cmp90-mode" "$W/cmp90/"
echo "Done (not installed). Once the 90HX is connected: sudo $W/cmp90/cmp90-mode cmp90 && sudo reboot"
