# CMP 90HX on the Jetson eGPU: patched driver to unlock compute

> ⚠️ **UNTESTED WITH REAL HARDWARE.** The patched module builds, but it has never been installed or loaded
> with a CMP 90HX connected to the Jetson. Everything below about it "working" is inferred from the source code,
> not measured.

*Vietnamese version: [README.vi.md](README.vi.md).*

The CMP 90HX (GA102 `10de:220d`, subsystem `10de:1555`, 10 GB, ~693 GB/s measured) is a mining card. NVIDIA limits
its FP32 and tensor throughput to about 1/32. On an x86 host (eGPU over Thunderbolt), it is unlocked with
[cmpunlocker](https://github.com/pearlfortune/cmpunlocker) v0.1.28 (MIT, `patches/LICENSE.cmpunlocker`), which
patches open module **610.43.03**. The Jetson setup uses open module **595.99.02** (`../10-build.sh`), so this
directory is a port of those patches.

## What was checked (source review + build only)

- **Scope of the patches.** The rejoin15 variant (`0014` + `0015`) touches only 6 C files:
  `kernel-open/nvidia/nv.c` and the GSP boot path (`kernel_gsp.c`, GA102 falcon, TU102 booter/FRTS).
  - The constants are GA102 hardware registers; nothing is x86-specific.
  - Userspace and `libcuda` are unchanged, so the same `/opt/nvidia/dgpu-595.99.02` is used.
- **Booter ucode matches.** The patch relies on a stack layout measured on the Booter ucode ("V67"). After
  decompressing the embedded bindata, the GA102 Booter load, Booter unload and GspRmBoot ucode are
  **byte-identical between 595.99.02 and 610.43.03** (image, header and signatures).
- **Applying to 595.99.02.** The patches apply cleanly, with line offsets and one hunk at fuzz 2. The build failed in
  one place, fixed by `0016`: 595 has no `confComputeForceUnprotAlloc`, so the code now always sets
  `MEMDESC_FLAGS_ALLOC_IN_UNPROTECTED_MEMORY`, which is what stock 595 does at that point.
- **Build on the Jetson** (kernel `6.8.12-1021-tegra`): all 4 modules build, and `nvidia.ko` contains the
  `CMP90_STOCKFLOW_REJOIN9..15` and `V67` markers.
- **Other cards are unaffected.** The patched code only activates for exactly `220d`/`1555`. Other cards (e.g. the
  RTX 3070) take the stock path.

## Not checked / risks

- **Never run with a 90HX on the Jetson.** The GSP-RM firmware (`gsp_ga10x.bin`) differs between 595 and 610.
  The Booter is identical, but behaviour after GSP boots may differ.
- **FLR on Tegra.** The patch deliberately lets the first init fail (`RmInitAdapter failed (0x62)`), then does an
  FLR and retries. On the x86 host that is the normal flow. FLR through the Tegra PCIe controller (C4) is untested.
- **`gpu-mode` interaction.** `gpu-mode` loads and unloads `nvidia_uvm` often. This has not been tested together
  with the patch's unload logic.
- **`cmp90` mode with the RTX 3070** (to confirm the stock path still works) has not been tried.

## Usage

```bash
bash cmp90/10-build-cmp90.sh                       # on the Jetson, normal user, ~6 min; installs nothing
sudo ~/egpu/cmp90/cmp90-mode cmp90 && sudo reboot  # once the 90HX is connected
journalctl -k -b | grep -E 'CMP90|NVRM'            # check
gpu-mode dgpu && dgpu nvidia-smi
sudo ~/egpu/cmp90/cmp90-mode stock && sudo reboot  # back to the stock module
~/egpu/cmp90/cmp90-mode                            # prints: selected … · loaded …
```

`cmp90-mode` copies the patched modules to `/lib/modules/$KVER/updates/dgpu-cmp90` and switches the `override` lines
in `/etc/nvidia-dgpu/depmod.conf` (the L4T hook used by `../20-install-dgpu.sh`). The stock modules in
`updates/dgpu` are left untouched. Switching requires a reboot, because `nvidia.ko` holds the card and cannot be
unloaded live.

## What it would give, if it works

| | RTX 3070 | CMP 90HX (unlocked, measured on x86) |
|---|---|---|
| VRAM / bandwidth | 8 GB / 448 GB/s | 10 GB / ~693 GB/s |
| FP16 tensor (fp32 acc) | ~45 TFLOPS | ~71 TFLOPS |
| PCIe | Gen3 x4, 3.3 GB/s | **Gen1 x4, 0.6–0.9 GB/s** (CMP hardware limit) |
| NVDEC / NVENC | yes | **no** |

- **LLM inference:** a good fit, roughly an RTX 3080 10 GB. The slow PCIe link only affects model load time.
- **Video / DeepStream:** worse than the 3070. The card cannot decode video, so frames must be decoded on the Orin
  (`nvv4l2decoder`) and pushed over shared memory (`../shm_share.cu` with `hideuvm`). Gen1 x4 limits this to roughly
  250 frames/s of 1080p NV12.
