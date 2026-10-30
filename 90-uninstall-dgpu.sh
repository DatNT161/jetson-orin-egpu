#!/bin/bash
# Remove the self-built dGPU driver and return the Jetson to the stock L4T display/iGPU stack.
set -euo pipefail
V=595.99.02
[ "$(id -u)" = 0 ] || { echo "Run with sudo"; exit 1; }
rm -f /etc/nvidia-display-depmod-conf /etc/nvidia-display-modprobe-conf
rm -rf /etc/nvidia-dgpu "/lib/modules/$(uname -r)/updates/dgpu" "/opt/nvidia/dgpu-$V" "/lib/firmware/nvidia/$V"
systemctl disable gpu-mode-boot.service 2>/dev/null || true
rm -f /etc/systemd/system/gpu-mode-boot.service
systemctl daemon-reload
modprobe -r nvidia_uvm 2>/dev/null || true
rm -f /usr/local/bin/dgpu /usr/bin/nvidia-modprobe /usr/local/sbin/gpu-mode /usr/local/bin/gpu-mode
apt-mark unhold $(dpkg-query -W -f='${Package}\n' 'nvidia-l4t-kernel*' nvidia-l4t-init 2>/dev/null) >/dev/null
depmod -a
systemctl restart nv-load-display-modules.service
modinfo -F version nvidia
