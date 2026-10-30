# CMP 90HX trên Jetson eGPU — module vá mở khoá compute

> ⚠️ **CHƯA TEST VỚI CARD THẬT (28/10/2026).** Module mới chỉ build ra, chưa cài, chưa nạp, chưa cắm 90HX vào
> Jetson lần nào. Mọi điều dưới đây về "chạy được" là suy ra từ mã nguồn, không phải số đo.

CMP 90HX (GA102 `10de:220d`, subsystem `10de:1555`, 10 GB, đo ~693 GB/s trên một máy x86 qua eGPU Thunderbolt) bị NVIDIA khoá compute
(FP32/tensor ~1/32). Trên máy x86 đó nó được mở khoá bằng [cmpunlocker](https://github.com/pearlfortune/cmpunlocker)
v0.1.28 (MIT, `patches/LICENSE.cmpunlocker`) vá open module **610.43.03**. Jetson dùng open module **595.99.02**
tự build (`../10-build.sh`), nên ở đây là bản port.

## Đã kiểm (28/10, chỉ đọc mã + build)

- Bản vá rejoin15 (`0014` + `0015`) chỉ sửa 6 file C: `kernel-open/nvidia/nv.c` và đường boot GSP
  (`kernel_gsp.c`, falcon ga102, booter/frts tu102). Hằng số là thanh ghi GA102, không có gì riêng x86.
  Userspace/libcuda không đổi → dùng chung `/opt/nvidia/dgpu-595.99.02`.
- Bản vá dựa vào một stack map đo trên ucode Booter ("V67"). Đã giải nén so: **Booter load, Booter unload và
  GspRmBoot GA102 của 595.99.02 và 610.43.03 giống nhau từng byte** (image, header, chữ ký).
- Áp vào 595.99.02: vào sạch (lệch dòng, 1 hunk fuzz 2). Build lỗi một chỗ → `0016`: 595 không có
  `confComputeForceUnprotAlloc`, thay bằng đúng cách bản gốc 595 làm (luôn bật `MEMDESC_FLAGS_ALLOC_IN_UNPROTECTED_MEMORY`).
- Build trên Jetson (kernel `6.8.12-1021-tegra`): đủ 4 module, `nvidia.ko` có chuỗi `CMP90_STOCKFLOW_REJOIN9..15`, `V67`.
- Phần vá chỉ chạy khi đúng `220d`/`1555`; card khác (3070 hiện tại) đi đường gốc.

## Chưa kiểm / rủi ro

- Chưa từng chạy với 90HX trên Jetson. Firmware GSP-RM (`gsp_ga10x.bin`) của 595 khác 610 — Booter giống nhưng
  phần sau GSP lên có thể khác.
- Bản vá cố ý cho lần init đầu lỗi (`RmInitAdapter failed (0x62)`) rồi FLR + thử lại; trên máy x86 đó là luồng bình
  thường. FLR qua bộ điều khiển PCIe Tegra (C4) chưa thử.
- `gpu-mode` nạp/gỡ `nvidia_uvm` thường xuyên; chưa thử chung với logic unload của bản vá.
- Chưa thử chuyển `cmp90` khi đang cắm 3070 (để xác nhận đường gốc không hỏng).

## Dùng

```bash
bash cmp90/10-build-cmp90.sh                       # trên Jetson, user thường, ~6 phút; không cài gì
sudo ~/egpu/cmp90/cmp90-mode cmp90 && sudo reboot  # khi đã cắm 90HX
journalctl -k -b | grep -E 'CMP90|NVRM'            # kiểm
gpu-mode dgpu && dgpu nvidia-smi
sudo ~/egpu/cmp90/cmp90-mode stock && sudo reboot  # quay về bản gốc
~/egpu/cmp90/cmp90-mode                            # in: selected: … · loaded: …
```

`cmp90-mode` chép module vá sang `/lib/modules/$KVER/updates/dgpu-cmp90` và đổi dòng `override` trong
`/etc/nvidia-dgpu/depmod.conf` (hook của `nv-load-display-modules.sh`, xem `../20-install-dgpu.sh`). Bản gốc ở
`updates/dgpu` không bị đụng. Đổi bản phải reboot (nvidia.ko giữ card, không gỡ nóng).

## Nếu chạy được thì được gì

| | RTX 3070 (hiện tại) | CMP 90HX (đã mở khoá, số đo trên máy x86) |
|---|---|---|
| VRAM / băng thông | 8 GB / 448 GB/s | 10 GB / ~693 GB/s |
| FP16 tensor (acc32) | ~45 TFLOPS | ~71 TFLOPS |
| PCIe | Gen3 x4, 3,3 GB/s | **Gen1 x4, 0,6–0,9 GB/s** (giới hạn phần cứng CMP) |
| NVDEC / NVENC | có | **không** |

- **LLM:** hợp (≈ 3080 10 GB). PCIe chậm chỉ làm lâu lúc nạp model.
- **Video/DeepStream:** kém hơn — không decode được trên card; phải decode trên Orin (`nvv4l2decoder`) rồi đẩy qua
  shm (`../shm_share.cu`, cần `hideuvm`), Gen1 x4 giới hạn ~250 khung 1080p NV12/s.
