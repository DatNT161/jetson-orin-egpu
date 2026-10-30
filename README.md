# Discrete GPU (eGPU over OCuLink) on Jetson Orin Nano

Run a desktop NVIDIA GPU on a **Jetson Orin Nano** through an OCuLink adapter in the M.2 slot. The card runs
alongside the Orin's integrated GPU, using a self-built upstream `open-gpu-kernel-modules` driver.

Tested with an **RTX 2080 Ti** (Turing) and an **RTX 3070** (Ampere) on a Jetson Orin Nano Super Developer Kit.

> NVIDIA does not support discrete GPUs on Jetson. This is an experiment: it works on the setup below, and it
> gives up the Jetson's DisplayPort output. Use at your own risk.

*Vietnamese version: [README.vi.md](README.vi.md).*

## Setup

| | |
|---|---|
| Board | Jetson Orin Nano Super Dev Kit, 8 GB |
| Software | JetPack 7.2.1 (L4T R39.2.1), Ubuntu 24.04 aarch64, kernel `6.8.12-tegra`, CUDA 13.2, TensorRT 10.16 |
| Link | M.2 Key M → OCuLink adapter in slot **C4** (`0004:01:00.0`), **PCIe Gen3 x4** |
| GPU | RTX 2080 Ti / RTX 3070 in an OCuLink dock with its own PSU |
| Driver | `open-gpu-kernel-modules` **595.99.02** built on the Jetson, plus the matching aarch64 userspace |

## Why a custom build is needed

The L4T `nvidia.ko` (open 595.78, a Tegra-specific build) rejects discrete cards:
`GPU 10de:1e04 is not supported by the NVIDIA 595.78 driver release`, and the firmware directory has no
`gsp_tu10x.bin`. The T234 SoC itself can drive a dGPU (IGX Orin has a dGPU mode). Building the upstream open modules
for the Tegra kernel was enough; no non-coherent DMA patches were needed.

## Install

```bash
# On the Jetson, as a normal user (no sudo): downloads + verifies sha256, builds modules,
# extracts the userspace into ~/egpu (~6 min on 6 cores)
bash 10-build.sh

sudo bash 20-install-dgpu.sh && sudo reboot
```

`20-install-dgpu.sh` does the following:
- **Kernel modules** go to `/lib/modules/$KVER/updates/dgpu`. They are selected through the official hook of
  `/etc/systemd/nv-load-display-modules.sh` (`/etc/nvidia-display-{depmod,modprobe}-conf`), so no L4T package
  files are modified.
- **GSP firmware** goes to `/lib/firmware/nvidia/595.99.02/`.
- **dGPU userspace** goes to `/opt/nvidia/dgpu-595.99.02` and is used through the `dgpu <command>` wrapper.
  The iGPU's `libcuda` (nvgpu) stays the system default.
- **Package holds:** `apt-mark hold` on `nvidia-l4t-kernel*` and `nvidia-l4t-init`, because an upgrade would
  overwrite the self-built modules.
- **`gpu-mode-boot.service`** boots into iGPU mode.

If `~/egpu` is not where you built, set `EGPU_DIR`.

To uninstall: `sudo bash 90-uninstall-dgpu.sh`.

## Usage

```bash
gpu-mode            # prints: igpu | dgpu
gpu-mode dgpu       # load nvidia_uvm -> CUDA on the discrete card
dgpu nvidia-smi
dgpu ./egpu_bench   # nvcc -O2 -gencode arch=compute_86,code=sm_86 egpu_bench.cu -lcublas -o egpu_bench
gpu-mode igpu       # unload nvidia_uvm -> back to the Orin iGPU (JetPack TensorRT/DeepStream)
```

`sudo bash 30-sudoers-gpu-mode.sh <user>` lets that user run exactly `gpu-mode igpu` / `gpu-mode dgpu` without a
password. The rule is checked with `visudo`.

### Why there are two modes

The iGPU's `libcuda` checks for `/sys/module/nvidia_uvm/initstate`. If that file exists, it opens
`/dev/nvidia-uvm`, but the upstream UVM module does not understand nvgpu, so the call fails with
`CUDA_ERROR_NOT_INITIALIZED`. As a result, iGPU CUDA breaks while `nvidia_uvm` is loaded. Related details:
- `nvidia-modprobe` is installed outside `/usr/bin` and without setuid. Both `libcuda` and NVML (for example
  `nvidia-ctk` in `nvidia-cdi-refresh.service` at boot) call `/usr/bin/nvidia-modprobe` to auto-load UVM.
- Persistence mode is turned on in `dgpu` mode. Without it, every new CUDA process waits ~20 s for GSP init.

## Using the Orin GPU and the discrete GPU at the same time

The two GPUs use two different `libcuda` builds, so **each process can use only one GPU**. Two processes can still
run in parallel. In `dgpu` mode, run the iGPU process with the `hideuvm` shim (`LD_PRELOAD`). The shim hides
`/sys/module/nvidia_uvm` and `/dev/nvidia-uvm` from the nvgpu `libcuda`. It needs no root. (Hiding the paths with
`unshare -rm` would also work, but AppArmor on Ubuntu 24.04 blocks unprivileged user namespaces.)

```bash
gcc -O2 -shared -fPIC hideuvm.c -o libhideuvm.so -ldl
gpu-mode dgpu
dgpu <command using the discrete GPU> &
LD_PRELOAD=$PWD/libhideuvm.so <command using the Orin GPU>   # TensorRT, nvv4l2decoder/nvvidconv, ...
```

Measured with an RTX 3070:
- **iGPU `cuInit` in dgpu mode:** fails with `CUDA_ERROR_NOT_INITIALIZED` without the shim, returns `CUDA_SUCCESS`
  with it.
- **TensorRT fp16 conv benchmark on both GPUs at once:** Orin 10.3 qps (11.0 alone), RTX 3070 65.1 qps (64.5 alone).
- **Jetson hardware decode** (`nvv4l2decoder ! nvvidconv`): works in dgpu mode with the shim. Without it, the
  pipeline fails to preroll.

### Sharing frames between the two processes

`shm_share.cu` demonstrates the transfer. Both processes `cudaHostRegister` the same POSIX shared-memory region.
The Orin kernel writes into it directly, because the Orin GPU shares memory with the CPU. The discrete card DMAs
the data over PCIe and checks every byte on the GPU.

```bash
nvcc -O2 -gencode arch=compute_87,code=sm_87 -gencode arch=compute_86,code=sm_86 \
     -gencode arch=compute_75,code=sm_75 shm_share.cu -o shm_share
dgpu ./shm_share consume 6000 &
LD_PRELOAD=$PWD/libhideuvm.so ./shm_share produce 6000
# [consume] 6000 frames in 5.98s = 1003 frames/s, 3.12 GB/s · bad frames 0, bad bytes 0
```

The test streams 1080p NV12 frames through a 4-slot ring with synchronous copies. 3.12 GB/s is close to the
PCIe Gen3 x4 ceiling (3.29 GB/s measured), so no copy is made outside the PCIe transfer. It has not been tested on
multi-hour runs.

## Benchmarks

| | RTX 3070 | RTX 2080 Ti | Orin iGPU |
|---|---|---|---|
| H2D / D2H pinned | 3.29 / 3.39 GB/s | 3.29 / 3.39 GB/s | ~24 GB/s |
| SGEMM fp32 (8192) | 17.4 TFLOPS | 15.0 TFLOPS | 1.2 TFLOPS |
| HGEMM fp16, fp32 accumulate | 44.8 TFLOPS | ~61 TFLOPS | — |
| TensorRT fp16, 16-layer conv, 8×3×640×640 (~813 GFLOP) | 64.5 qps (15.4 ms) | 63.5 qps (15.7 ms) | 11.3 qps (86.1 ms) |
| NVDEC decode → TensorRT on the card, 1080p H.264, YOLOX / YOLO11m | 446 / 102 fps | 403 / 90 fps | — |

The GEMMs were measured on all-zero matrices, so the TFLOPS numbers may be slightly optimistic. Build the TensorRT
engine with `trt_conv_bench.py`:

```bash
gpu-mode dgpu
dgpu python3 trt_conv_bench.py conv-dgpu.engine --fp16
dgpu /usr/src/tensorrt/bin/trtexec --loadEngine=conv-dgpu.engine
```

Notes:
- **TensorRT** from JetPack (the unified SBSA build) already ships sm_75/sm_86 kernels, so it runs under `dgpu`
  as-is.
- **Engines are tied to one GPU.** An engine built for sm_87 (Orin) fails under `dgpu` with
  `expecting compute 7.5 got compute 8.7`. Build one engine per GPU.
- **PCIe x4 is the bottleneck.** A 39 MB fp32 input takes 12 ms to copy, about as long as the compute. Upload
  uint8/fp16 data and preprocess on the GPU.

## DeepStream 9.1

- **RTX 3070 (Ampere): works.** `nvh264dec ! nvvideoconvert ! nvstreammux ! nvinfer` (resnet18 trafficcamnet, fp16)
  runs at ~305 fps with correct boxes.
- **RTX 2080 Ti (Turing): does not work.** The closed `libnvbufsurftransform` and `libnvds_infer` in the Jetson
  build have no sm_75 kernels.

On the Jetson build, DeepStream allocates NVMM surfaces. `rmshim.c` overrides `NvBufSurfaceGetDeviceInfo` so
DeepStream treats the card as an RM (desktop) driver and allocates CUDA buffers instead:

```bash
D=~/ds/root/opt/nvidia/deepstream/deepstream-9.1      # DeepStream 9.1 .deb extracted, not installed
gcc -O2 -shared -fPIC -I$D/sources/includes rmshim.c -o librmshim.so -ldl
RMSHIM_ALL=1 LD_PRELOAD=$PWD/librmshim.so dgpu gst-launch-1.0 filesrc location=$D/samples/streams/sample_1080p_h264.mp4 ! \
  qtdemux ! h264parse ! nvh264dec ! nvvideoconvert ! m.sink_0 nvstreammux name=m batch-size=1 width=1920 height=1080 ! \
  nvinfer config-file-path=<pgie.txt> ! fakesink
```

## CMP 90HX compute unlock (experimental, UNTESTED)

`cmp90/` ports the [cmpunlocker](https://github.com/pearlfortune/cmpunlocker) CMP 90HX patches (written for
610.43.03) to 595.99.02. It also adds `cmp90-mode stock|cmp90` to switch between the stock and patched modules.
**The patched module builds, but it has never been loaded with a real CMP 90HX on the Jetson.** Details, risks and
usage: [cmp90/README.md](cmp90/README.md).

## Files

| File | Purpose |
|---|---|
| `10-build.sh` | Download + verify + build modules, extract userspace (normal user) |
| `20-install-dgpu.sh` | Install modules/firmware/userspace, `dgpu` wrapper, boot service (sudo) |
| `30-sudoers-gpu-mode.sh` | Passwordless `gpu-mode igpu` / `gpu-mode dgpu` for one user |
| `90-uninstall-dgpu.sh` | Remove everything, back to stock L4T |
| `gpu-mode` | Switch between iGPU and dGPU CUDA |
| `hideuvm.c` | `LD_PRELOAD` shim: run iGPU CUDA while in dgpu mode |
| `shm_share.cu` | Orin → dGPU frame sharing over POSIX shm |
| `rmshim.c` | `LD_PRELOAD` shim for DeepStream on the dGPU |
| `egpu_bench.cu` | Bandwidth + cuBLAS GEMM benchmark |
| `trt_conv_bench.py` | Build a pure-TensorRT conv benchmark engine |
| `cmp90/` | CMP 90HX unlock patches (untested) |

Script comments and messages are in Vietnamese.

## License

MIT (see `LICENSE`). `cmp90/patches/0014` and `0015` come from cmpunlocker (MIT,
`cmp90/patches/LICENSE.cmpunlocker`). The patches apply to NVIDIA open-gpu-kernel-modules (MIT/GPLv2).
