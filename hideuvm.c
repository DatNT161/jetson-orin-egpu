// LD_PRELOAD for processes using the Orin GPU while the discrete-card driver is loaded: hide nvidia_uvm so the nvgpu libcuda does not take the uvm path.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <string.h>
#include <sys/stat.h>
static int hidden(const char *p) { return p && (strstr(p, "/sys/module/nvidia_uvm") || strstr(p, "/dev/nvidia-uvm")); }
#define REAL(name) static __typeof__(name) *real; if (!real) real = dlsym(RTLD_NEXT, #name)
int access(const char *p, int m) { REAL(access); if (hidden(p)) { errno = ENOENT; return -1; } return real(p, m); }
int faccessat(int d, const char *p, int m, int f) { REAL(faccessat); if (hidden(p)) { errno = ENOENT; return -1; } return real(d, p, m, f); }
int stat(const char *p, struct stat *s) { REAL(stat); if (hidden(p)) { errno = ENOENT; return -1; } return real(p, s); }
int fstatat(int d, const char *p, struct stat *s, int f) { REAL(fstatat); if (hidden(p)) { errno = ENOENT; return -1; } return real(d, p, s, f); }
int open(const char *p, int f, ...) { REAL(open); va_list a; va_start(a, f); int m = va_arg(a, int); va_end(a); if (hidden(p)) { errno = ENOENT; return -1; } return real(p, f, m); }
int open64(const char *p, int f, ...) { REAL(open64); va_list a; va_start(a, f); int m = va_arg(a, int); va_end(a); if (hidden(p)) { errno = ENOENT; return -1; } return real(p, f, m); }
int openat(int d, const char *p, int f, ...) { REAL(openat); va_list a; va_start(a, f); int m = va_arg(a, int); va_end(a); if (hidden(p)) { errno = ENOENT; return -1; } return real(d, p, f, m); }
int openat64(int d, const char *p, int f, ...) { REAL(openat64); va_list a; va_start(a, f); int m = va_arg(a, int); va_end(a); if (hidden(p)) { errno = ENOENT; return -1; } return real(d, p, f, m); }
