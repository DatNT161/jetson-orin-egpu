# eGPU qua OCuLink trên Jetson Orin Nano (RTX 2080 Ti, RTX 3070)

Dựng 22/10/2026. Jetson Orin Nano Super, JetPack 7.2.1 (L4T R39.2.1, kernel 6.8.12-tegra, CUDA 13.2).
eGPU cắm qua adapter OCuLink ở khe M.2 Key M **C4** (`0004:01:00.0`, PCIe Gen3 x4).

## Vì sao phải tự build

`nvidia.ko` của L4T (open 595.78, bản build riêng cho Tegra) từ chối card rời:
`GPU 10de:1e04 is not supported by the NVIDIA 595.78 driver release`, và thư mục firmware thiếu `gsp_tu10x.bin`.
NVIDIA không hỗ trợ dGPU trên Jetson. Chip T234 thì chạy được dGPU (IGX Orin có chế độ dGPU), nên
build open-gpu-kernel-modules upstream là đủ, không cần bản vá non-coherent của mariobalanica.

## Các bước

```bash
# trên Jetson, user thường
bash 10-build.sh                  # tải + kiểm sha256 + build module, giải nén userspace → ~/egpu
sudo bash 20-install-dgpu.sh && sudo reboot
```

`20-install-dgpu.sh`:
- module → `/lib/modules/$KVER/updates/dgpu`, trỏ vào bằng hook chính thức của
  `/etc/systemd/nv-load-display-modules.sh`: `/etc/nvidia-display-{depmod,modprobe}-conf`
  (không sửa file của gói L4T). Xoá `/var/lib/nvidia/nv-display.stamp` để script đó chép lại conf.
- firmware GSP → `/lib/firmware/nvidia/595.99.02/`
- userspace dGPU → `/opt/nvidia/dgpu-595.99.02`, chạy qua wrapper `dgpu <lệnh>`; libcuda nvgpu của iGPU giữ nguyên
- `apt-mark hold` các gói `nvidia-l4t-kernel*` + `nvidia-l4t-init` (nâng cấp sẽ đè module tự build)
- `gpu-mode-boot.service`: boot ở chế độ iGPU

Gỡ: `sudo bash 90-uninstall-dgpu.sh`

## Dùng

```bash
gpu-mode            # igpu | dgpu
gpu-mode dgpu       # nạp nvidia_uvm (sudo NOPASSWD sau khi chạy 30-sudoers-gpu-mode.sh)
dgpu nvidia-smi
dgpu ./egpu_bench   # nvcc -O2 -gencode arch=compute_75,code=sm_75 egpu_bench.cu -lcublas -o egpu_bench
gpu-mode igpu       # gỡ nvidia_uvm, về CUDA iGPU (TensorRT/DeepStream của JetPack)
```

**Mặc định iGPU và eGPU không chạy CUDA đồng thời.** libcuda nvgpu (iGPU) thấy `/sys/module/nvidia_uvm/initstate`
thì mở `/dev/nvidia-uvm`, mà uvm upstream không hiểu nvgpu → `CUDA_ERROR_NOT_INITIALIZED`. Muốn chạy cả hai cùng lúc
thì dùng shim `hideuvm` (mục dưới). Ngoài ra:
- `nvidia-modprobe` không đặt ở `/usr/bin` và không setuid: libcuda và NVML (`nvidia-ctk` của
  `nvidia-cdi-refresh.service`, chạy root lúc boot) gọi `/usr/bin/nvidia-modprobe` để tự nạp uvm.
- `gpu-mode-boot.service` chạy `gpu-mode igpu` sau các service NVIDIA lúc boot.

## Số đo (22/10/2026)

| | 2080 Ti qua OCuLink | iGPU Orin |
|---|---|---|
| H2D / D2H pinned | 3,29 / 3,39 GB/s | ~24 GB/s |
| SGEMM fp32 8192 | 15,0 TFLOPS | 1,2 TFLOPS |
| HGEMM fp16 (acc fp32) | ~61 TFLOPS | — |

| TensorRT fp16, conv 16 lớp, 8×3×640×640 (~813 GFLOP) | **63,5 qps**, compute 15,7 ms | 11,3 qps, compute 86,1 ms |

Số GEMM đo trên ma trận toàn 0 nên có thể hơi cao. nvidia.ko upstream vẫn bind display Tegra (`13800000.display`).

## Không cần mật khẩu cho gpu-mode

`sudo bash 30-sudoers-gpu-mode.sh [user]` ghi `/etc/sudoers.d/gpu-mode`, chỉ miễn mật khẩu cho đúng
`/usr/local/sbin/gpu-mode igpu` và `... dgpu`, đã kiểm bằng `visudo`. gpu-mode tự gọi lại sudo bằng đường dẫn thật,
nên chạy qua symlink `/usr/local/bin/gpu-mode` vẫn khớp luật.

## TensorRT trên 2080 Ti

TensorRT 10.16 của JetPack (bản SBSA hợp nhất) có sẵn kernel sm_75, nên chạy được dưới `dgpu` mà không cần cài thêm:

```bash
gpu-mode dgpu
dgpu python3 trt_conv_bench.py conv-2080ti.engine --fp16   # build ~40 s
dgpu /usr/src/tensorrt/bin/trtexec --loadEngine=conv-2080ti.engine
gpu-mode igpu
```

- Engine gắn với GPU: engine sm_87 (Orin) nạp dưới `dgpu` báo `expecting compute 7.5 got compute 8.7`. Mỗi GPU phải build engine riêng.
- PCIe x4 là nút cổ chai: input fp32 39 MB mất 12 ms H2D, gần bằng 15,7 ms compute. trtexec chồng transfer lên compute
  nên vẫn đạt 63 qps. Pipeline thật nên đưa ảnh uint8/fp16 lên GPU rồi tiền xử lý trên GPU.
- DeepStream 9.1 bản Jetson KHÔNG chạy được trên 2080 Ti: `libnvbufsurftransform` và `libnvds_infer` (đóng) không có
  kernel sm_75. Trên card Ampere (3070) thì chạy được, xem dưới.

## Chạy GPU Orin và card rời cùng lúc (28/10/2026)

Hai GPU dùng hai libcuda khác nhau nên **mỗi tiến trình chỉ dùng một GPU**, nhưng hai tiến trình chạy song song được.
Ở chế độ `dgpu`, tiến trình dùng GPU Orin chạy kèm shim `hideuvm`: nó giấu `/sys/module/nvidia_uvm` và `/dev/nvidia-uvm`
khỏi libcuda nvgpu. Không cần sudo (`unshare -rm` để che bằng namespace thì bị AppArmor chặn với user thường).

```bash
gcc -O2 -shared -fPIC hideuvm.c -o libhideuvm.so -ldl
gpu-mode dgpu
dgpu <lệnh dùng card rời> &
LD_PRELOAD=$PWD/libhideuvm.so <lệnh dùng GPU Orin>    # TensorRT, nvv4l2decoder/nvvidconv của JetPack...
```

Đo trên Jetson + RTX 3070:
- `cuInit` iGPU ở chế độ dgpu: không shim `CUDA_ERROR_NOT_INITIALIZED`, có shim `CUDA_SUCCESS`.
- TensorRT conv fp16 chạy cùng lúc: Orin 10,3 qps (chạy riêng 11,0) + 3070 65,1 qps (chạy riêng 64,5).
- `nvv4l2decoder ! nvvidconv` (giải mã phần cứng Jetson) chạy được ở chế độ dgpu khi có shim; không shim thì lỗi preroll.

Chia dữ liệu giữa hai tiến trình: `shm_share.cu`. Hai bên `cudaHostRegister` cùng một vùng POSIX shared memory; kernel
Orin ghi thẳng vào đó (bộ nhớ chung với CPU), card rời DMA qua PCIe rồi kiểm trên GPU:

```bash
nvcc -O2 -gencode arch=compute_87,code=sm_87 -gencode arch=compute_86,code=sm_86 \
     -gencode arch=compute_75,code=sm_75 shm_share.cu -o shm_share
dgpu ./shm_share consume 6000 &
LD_PRELOAD=$PWD/libhideuvm.so ./shm_share produce 6000
# [consume] 6000 frames in 5.98s = 1003 frames/s, 3.12 GB/s · bad frames 0, bad bytes 0
```

Khung NV12 1080p, vòng 4 ô, chép đồng bộ: 3,12 GB/s là sát trần PCIe Gen3 x4 (3,29 GB/s), tức không tốn bản sao nào
ngoài đường PCIe. Chưa chạy dài nhiều giờ.

## RTX 3070 thay 2080 Ti (28/10/2026)

Cùng driver 595.99.02, không sửa gì: Gen3 x4, persistence bật như cũ.

| | RTX 3070 | 2080 Ti |
|---|---|---|
| H2D / D2H pinned | 3,29 / 3,39 GB/s | 3,29 / 3,39 GB/s |
| SGEMM fp32 / HGEMM fp16 | 17,4 / 44,8 TFLOPS | 15,0 / ~61 TFLOPS |
| TensorRT conv fp16 | 64,5 qps (15,4 ms) | 63,5 qps (15,7 ms) |
| giải mã NVDEC → TensorRT trên card, 1080p, YOLOX / yolo11m | 446 / 102 khung/s | 403 / 90 khung/s |

`egpu_bench` phải build lại cho sm_86 (`-gencode arch=compute_86,code=sm_86`). DeepStream 9.1 bản Jetson chạy được:
`nvh264dec ! nvvideoconvert ! nvstreammux ! nvinfer` (resnet18 trafficcamnet fp16) ~305 khung/s, box đúng, cần
`LD_PRELOAD` shim `rmshim.c` (sửa kết quả `NvBufSurfaceGetDeviceInfo` thành driver RM, `RMSHIM_ALL=1`) để DeepStream
cấp bộ đệm CUDA thay NVMM:

```bash
D=~/ds/root/opt/nvidia/deepstream/deepstream-9.1      # deb DeepStream 9.1 giải nén, không cài
gcc -O2 -shared -fPIC -I$D/sources/includes rmshim.c -o librmshim.so -ldl
RMSHIM_ALL=1 LD_PRELOAD=$PWD/librmshim.so dgpu gst-launch-1.0 filesrc location=$D/samples/streams/sample_1080p_h264.mp4 ! \
  qtdemux ! h264parse ! nvh264dec ! nvvideoconvert ! m.sink_0 nvstreammux name=m batch-size=1 width=1920 height=1080 ! \
  nvinfer config-file-path=<pgie.txt> ! fakesink
```

## CMP 90HX — module vá mở khoá (28/10/2026, CHƯA TEST)

`cmp90/`: port bản vá cmpunlocker (610.43.03) sang 595.99.02 + `cmp90-mode stock|cmp90` để chuyển. **Mới build,
chưa thử với card thật.** Chi tiết, rủi ro và cách dùng: [`cmp90/README.vi.md`](cmp90/README.vi.md).

## License

MIT (`LICENSE`). `cmp90/patches/0014`, `0015` thuộc cmpunlocker (MIT, `cmp90/patches/LICENSE.cmpunlocker`).
