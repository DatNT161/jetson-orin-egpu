// Share frames between two processes over POSIX shared memory: the Orin GPU writes (producer), the discrete card reads (consumer).
// Both sides cudaHostRegister the same shm region: the Orin writes it directly from a kernel (shared memory), the card DMAs over PCIe.
// Ring of SLOTS slots, each with written/read counters so the two sides wait for each other. The consumer verifies every frame on the GPU.
//
//   nvcc -O2 -gencode arch=compute_87,code=sm_87 -gencode arch=compute_86,code=sm_86 \
//        -gencode arch=compute_75,code=sm_75 shm_share.cu -o shm_share
//   gpu-mode dgpu
//   dgpu ./shm_share consume 600 &                                   # discrete card
//   LD_PRELOAD=$PWD/libhideuvm.so ./shm_share produce 600            # GPU Orin
#include <cuda_runtime.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

constexpr int SLOTS = 4;
constexpr size_t FRAME = 1920 * 1080 * 3 / 2;          // NV12 1080p
constexpr size_t HDR = 4096;
const char* NAME = "/egpu_shm_share";

struct Header { volatile unsigned long long written[SLOTS], read[SLOTS]; };

#define CK(x) do { cudaError_t e = (x); if (e != cudaSuccess) { \
    fprintf(stderr, "%s:%d %s: %s\n", __FILE__, __LINE__, #x, cudaGetErrorString(e)); exit(1); } } while (0)

__global__ void fill(unsigned char* p, size_t n, unsigned f) {
    for (size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x; i < n; i += (size_t)gridDim.x * blockDim.x)
        p[i] = (unsigned char)(f * 7 + i * 13);
}

__global__ void check(const unsigned char* p, size_t n, unsigned f, unsigned long long* bad) {
    unsigned long long b = 0;
    for (size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x; i < n; i += (size_t)gridDim.x * blockDim.x)
        b += p[i] != (unsigned char)(f * 7 + i * 13);
    if (b) atomicAdd(bad, b);
}

static void wait_until(volatile unsigned long long* v, unsigned long long want) {
    while (*v != want) std::this_thread::yield();
}

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s produce|consume <frames>\n", argv[0]); return 2; }
    bool prod = !strcmp(argv[1], "produce");
    unsigned n = atoi(argv[2]);
    size_t total = HDR + SLOTS * FRAME;

    int fd = shm_open(NAME, O_CREAT | O_RDWR, 0600);
    if (fd < 0 || ftruncate(fd, total)) { perror("shm"); return 1; }
    char* base = (char*)mmap(nullptr, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) { perror("mmap"); return 1; }
    Header* h = (Header*)base;
    unsigned char* slots = (unsigned char*)base + HDR;

    cudaDeviceProp pr;
    CK(cudaGetDeviceProperties(&pr, 0));
    printf("[%s] %s, integrated=%d\n", argv[1], pr.name, pr.integrated);
    CK(cudaHostRegister(slots, SLOTS * FRAME, cudaHostRegisterMapped));

    auto t0 = std::chrono::steady_clock::now();
    if (prod) {
        unsigned char* d;
        CK(cudaHostGetDevicePointer((void**)&d, slots, 0));
        for (unsigned f = 0; f < n; f++) {
            int s = f % SLOTS;
            wait_until(&h->read[s], h->written[s]);          // slot has been consumed
            fill<<<64, 256>>>(d + s * FRAME, FRAME, f);
            CK(cudaDeviceSynchronize());
            __sync_synchronize();
            h->written[s] = f + 1;
        }
    } else {
        memset((void*)h, 0, sizeof(Header));
        unsigned char* d;
        unsigned long long *bad, bad_h = 0;
        CK(cudaMalloc(&d, FRAME));
        CK(cudaMalloc(&bad, sizeof *bad));
        CK(cudaMemset(bad, 0, sizeof *bad));
        unsigned bad_frames = 0;
        bool started = false;
        for (unsigned f = 0; f < n; f++) {
            int s = f % SLOTS;
            wait_until(&h->written[s], f + 1);
            if (!started) { t0 = std::chrono::steady_clock::now(); started = true; }
            __sync_synchronize();
            CK(cudaMemcpy(d, slots + s * FRAME, FRAME, cudaMemcpyHostToDevice));
            check<<<92, 256>>>(d, FRAME, f, bad);
            unsigned long long prev = bad_h;
            CK(cudaMemcpy(&bad_h, bad, sizeof bad_h, cudaMemcpyDeviceToHost));
            bad_frames += bad_h != prev;
            h->read[s] = f + 1;
        }
        double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        printf("[consume] %u frames in %.2fs = %.0f frames/s, %.2f GB/s · bad frames %u, bad bytes %llu\n",
               n, s, n / s, n * FRAME / s / 1e9, bad_frames, bad_h);
        shm_unlink(NAME);
        return bad_h != 0;
    }
    double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    printf("[produce] %u khung trong %.2fs\n", n, s);
    return 0;
}
