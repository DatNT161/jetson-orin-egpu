#!/bin/bash
# Install the dGPU driver (upstream open-gpu-kernel-modules) for an eGPU on Jetson Orin Nano (JetPack 7.2.1).
# - Self-built modules -> /lib/modules/$KVER/updates/dgpu, selected through the official hook of
#   nv-load-display-modules.sh (/etc/nvidia-display-{depmod,modprobe}-conf) — no L4T package files are modified.
# - dGPU userspace kept separately in /opt/nvidia/dgpu-$V, used via the `dgpu <command>` wrapper; the nvgpu libcuda (iGPU) stays.
# - Side effect: the Jetson loses DP output (Tegra display needs the L4T nvidia.ko). Runs headless.
# Build first: 10-build.sh (into ~/egpu). Uninstall: 90-uninstall-dgpu.sh
set -euo pipefail
V=595.99.02
KVER=$(uname -r)
W=${EGPU_DIR:-$(getent passwd "${SUDO_USER:?run with sudo from the user that built}" | cut -d: -f6)/egpu}
SRC=$W/open-gpu-kernel-modules-$V/kernel-open
X=$W/dgpu-$V
DST=/lib/modules/$KVER/updates/dgpu
PREFIX=/opt/nvidia/dgpu-$V
CONF=/etc/nvidia-dgpu

[ "$(id -u)" = 0 ] || { echo "Run with sudo"; exit 1; }
for m in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do
    [ -f "$SRC/$m.ko" ] || { echo "Missing $SRC/$m.ko — build not finished?"; exit 1; }
done
[ -f "$X/firmware/gsp_tu10x.bin" ] || { echo "Missing $X (did --extract-only run?)"; exit 1; }

echo "== 1. module -> $DST"
install -d "$DST"
install -m644 "$SRC"/*.ko "$DST"/

echo "== 2. firmware GSP -> /lib/firmware/nvidia/$V"
install -d "/lib/firmware/nvidia/$V"
install -m644 "$X"/firmware/*.bin "/lib/firmware/nvidia/$V"/

echo "== 3. userspace dGPU -> $PREFIX"
install -d "$PREFIX/lib" "$PREFIX/bin"
for f in "$X"/lib*.so.*; do install -m755 "$f" "$PREFIX/lib/"; done
cd "$PREFIX/lib"
for f in lib*.so.$V; do
    base=${f%.so.$V}
    ln -sf "$f" "$base.so.1"
    ln -sf "$base.so.1" "$base.so"
done
install -m755 "$X/nvidia-smi" "$PREFIX/bin/nvidia-smi"
# NOT in /usr/bin, NOT setuid: libcuda (including the iGPU nvgpu one) and NVML (nvidia-ctk in
# nvidia-cdi-refresh.service, run as root at boot) call /usr/bin/nvidia-modprobe to auto-load nvidia_uvm,
# and once the upstream uvm is loaded, iGPU CUDA breaks. Only gpu-mode calls it.
rm -f /usr/bin/nvidia-modprobe
install -m755 "$X/nvidia-modprobe" "$PREFIX/bin/nvidia-modprobe"
install -m755 "$W/gpu-mode" /usr/local/sbin/gpu-mode
ln -sf /usr/local/sbin/gpu-mode /usr/local/bin/gpu-mode
# Force iGPU mode after the NVIDIA boot services have run.
cat > /etc/systemd/system/gpu-mode-boot.service <<'EOF'
[Unit]
Description=Boot in iGPU CUDA mode (unload the eGPU driver nvidia_uvm)
After=nv-load-display-modules.service nvidia-cdi-refresh.service systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gpu-mode igpu

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable gpu-mode-boot.service
cat > /usr/local/bin/dgpu <<EOF
#!/bin/sh
# Run a command with the dGPU (eGPU) userspace instead of the iGPU nvgpu libcuda.
[ -d /sys/module/nvidia_uvm ] || { echo "dgpu: in iGPU mode — run 'gpu-mode dgpu' first" >&2; exit 1; }
export LD_LIBRARY_PATH=$PREFIX/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
export PATH=$PREFIX/bin:\$PATH
exec "\$@"
EOF
chmod 755 /usr/local/bin/dgpu

echo "== 4. depmod/modprobe override (nv-load-display-modules.sh hook)"
install -d "$CONF"
cat > "$CONF/depmod.conf" <<EOF
override nvidia * updates/dgpu
override nvidia-modeset * updates/dgpu
override nvidia-drm * updates/dgpu
override nvidia-uvm * updates/dgpu
override nvidia-peermem * updates/dgpu
search updates ubuntu built-in
EOF
cat > "$CONF/modprobe.conf" <<'EOF'
# dGPU: headless, no modeset. Do NOT auto-load nvidia-uvm (boot in iGPU mode) — enable with: gpu-mode dgpu
options nvidia-drm modeset=0
EOF
echo "$CONF/depmod.conf" > /etc/nvidia-display-depmod-conf
echo "$CONF/modprobe.conf" > /etc/nvidia-display-modprobe-conf

echo "== 5. hold L4T kernel packages (an upgrade would overwrite the self-built modules)"
apt-mark hold $(dpkg-query -W -f='${Package}\n' 'nvidia-l4t-kernel*' nvidia-l4t-init 2>/dev/null) >/dev/null
apt-mark showhold | grep -c nvidia-l4t | sed 's/^/   packages on hold: /'

echo "== 6. reload the stack"
# Remove the stamp so nv-load-display-modules.sh re-copies the conf + runs depmod (it skips when the override path is unchanged).
rm -f /var/lib/nvidia/nv-display.stamp
systemctl restart nv-load-display-modules.service || echo "!! service failed — see journalctl -u nv-load-display-modules"
modprobe -r nvidia_uvm 2>/dev/null || true

echo "== 7. check"
modinfo -F version nvidia
lspci -k -s 0004:01:00.0 | grep -E "driver in use" || echo "!! card not bound to the driver"
journalctl -k -b --no-pager -o cat | grep -E "NVRM" | tail -15
ls -l /dev/nvidia*
LD_LIBRARY_PATH=$PREFIX/lib "$PREFIX/bin/nvidia-smi" -L || true
echo "gpu-mode: $(gpu-mode)  (switch: gpu-mode dgpu | gpu-mode igpu)"
