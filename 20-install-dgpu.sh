#!/bin/bash
# Cài driver dGPU (open-gpu-kernel-modules upstream) cho eGPU trên Jetson Orin Nano (JetPack 7.2.1).
# - Module tự build -> /lib/modules/$KVER/updates/dgpu, trỏ vào bằng hook chính thức của
#   nv-load-display-modules.sh (/etc/nvidia-display-{depmod,modprobe}-conf) — không sửa file của gói L4T.
# - Userspace dGPU tách ở /opt/nvidia/dgpu-$V, chạy qua wrapper `dgpu <lệnh>`; libcuda nvgpu (iGPU) giữ nguyên.
# - Hệ quả: mất xuất hình DP của Jetson (display Tegra dùng nvidia.ko bản L4T). Máy chạy headless.
# Build trước: 10-build.sh (ra ~/egpu). Gỡ: 90-uninstall-dgpu.sh
set -euo pipefail
V=595.99.02
KVER=$(uname -r)
W=${EGPU_DIR:-$(getent passwd "${SUDO_USER:?chạy bằng sudo từ user đã build}" | cut -d: -f6)/egpu}
SRC=$W/open-gpu-kernel-modules-$V/kernel-open
X=$W/dgpu-$V
DST=/lib/modules/$KVER/updates/dgpu
PREFIX=/opt/nvidia/dgpu-$V
CONF=/etc/nvidia-dgpu

[ "$(id -u)" = 0 ] || { echo "Chạy bằng sudo"; exit 1; }
for m in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do
    [ -f "$SRC/$m.ko" ] || { echo "Thiếu $SRC/$m.ko — build chưa xong?"; exit 1; }
done
[ -f "$X/firmware/gsp_tu10x.bin" ] || { echo "Thiếu $X (chưa --extract-only?)"; exit 1; }

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
# KHÔNG để ở /usr/bin, KHÔNG setuid: libcuda (cả bản nvgpu của iGPU) và NVML (nvidia-ctk của
# nvidia-cdi-refresh.service, chạy root lúc boot) gọi /usr/bin/nvidia-modprobe để tự nạp nvidia_uvm,
# mà uvm upstream nạp lên là CUDA iGPU hỏng. Chỉ gpu-mode gọi nó.
rm -f /usr/bin/nvidia-modprobe
install -m755 "$X/nvidia-modprobe" "$PREFIX/bin/nvidia-modprobe"
install -m755 "$W/gpu-mode" /usr/local/sbin/gpu-mode
ln -sf /usr/local/sbin/gpu-mode /usr/local/bin/gpu-mode
# Chốt chế độ iGPU sau khi các service NVIDIA lúc boot chạy xong.
cat > /etc/systemd/system/gpu-mode-boot.service <<'EOF'
[Unit]
Description=Boot ở chế độ CUDA iGPU (gỡ nvidia_uvm của driver eGPU)
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
# Chạy lệnh với userspace dGPU (eGPU) thay cho libcuda nvgpu của iGPU.
[ -d /sys/module/nvidia_uvm ] || { echo "dgpu: đang ở chế độ iGPU — chạy 'gpu-mode dgpu' trước" >&2; exit 1; }
export LD_LIBRARY_PATH=$PREFIX/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
export PATH=$PREFIX/bin:\$PATH
exec "\$@"
EOF
chmod 755 /usr/local/bin/dgpu

echo "== 4. depmod/modprobe override (hook của nv-load-display-modules.sh)"
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
# dGPU: headless, không bật modeset. KHÔNG tự nạp nvidia-uvm (boot ở chế độ iGPU) — bật bằng: gpu-mode dgpu
options nvidia-drm modeset=0
EOF
echo "$CONF/depmod.conf" > /etc/nvidia-display-depmod-conf
echo "$CONF/modprobe.conf" > /etc/nvidia-display-modprobe-conf

echo "== 5. ghim gói kernel L4T (nâng cấp sẽ đè module tự build)"
apt-mark hold $(dpkg-query -W -f='${Package}\n' 'nvidia-l4t-kernel*' nvidia-l4t-init 2>/dev/null) >/dev/null
apt-mark showhold | grep -c nvidia-l4t | sed 's/^/   số gói đã hold: /'

echo "== 6. nạp lại stack"
# Xoá stamp để nv-load-display-modules.sh chép lại conf + depmod (nó bỏ qua khi đường dẫn override không đổi).
rm -f /var/lib/nvidia/nv-display.stamp
systemctl restart nv-load-display-modules.service || echo "!! service lỗi — xem journalctl -u nv-load-display-modules"
modprobe -r nvidia_uvm 2>/dev/null || true

echo "== 7. kiểm tra"
modinfo -F version nvidia
lspci -k -s 0004:01:00.0 | grep -E "driver in use" || echo "!! card chưa bind driver"
journalctl -k -b --no-pager -o cat | grep -E "NVRM" | tail -15
ls -l /dev/nvidia*
LD_LIBRARY_PATH=$PREFIX/lib "$PREFIX/bin/nvidia-smi" -L || true
echo "gpu-mode: $(gpu-mode)  (đổi: gpu-mode dgpu | gpu-mode igpu)"
