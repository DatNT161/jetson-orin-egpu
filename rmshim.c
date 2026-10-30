// LD_PRELOAD: tell DeepStream the GPU is discrete (RM driver) so it allocates CUDA buffers instead of iGPU NVMM/EGL.
// By default only for callers under ~/ds/root; RMSHIM_ALL=1 applies to every caller (including libnvbufsurftransform).
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include "nvbufsurface.h"
int NvBufSurfaceGetDeviceInfo(NvBufSurfaceDeviceInfo *info) {
  static int (*real)(NvBufSurfaceDeviceInfo *);
  if (!real) real = dlsym(RTLD_NEXT, "NvBufSurfaceGetDeviceInfo");
  if (!real) real = dlsym(dlopen("/usr/lib/aarch64-linux-gnu/nvidia/libnvbufsurface.so.1.0.0", RTLD_NOW | RTLD_GLOBAL), "NvBufSurfaceGetDeviceInfo");
  int r = real(info);
  Dl_info d;
  if (getenv("RMSHIM_ALL") ||
      (dladdr(__builtin_return_address(0), &d) && d.dli_fname && strstr(d.dli_fname, "/ds/root/"))) {
    info->driverType = NVBUF_DRIVER_TYPE_RM;
    info->isIntegratedGpu = 0;
  }
  return r;
}
