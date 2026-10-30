// LD_PRELOAD: báo DeepStream là GPU rời (driver RM) để nó cấp bộ đệm CUDA thay vì NVMM/EGL của iGPU.
// Mặc định chỉ đổi cho thư viện dưới ~/ds/root; RMSHIM_ALL=1 đổi cho mọi nơi gọi (cả libnvbufsurftransform).
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
