// Quick eGPU check: device info, H2D/D2H (pinned) bandwidth, cuBLAS SGEMM/HGEMM.
#include <cstdio>
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cublas_v2.h>
#define CK(x) do { cudaError_t e = (x); if (e != cudaSuccess) { printf("CUDA %s @%d: %s\n", #x, __LINE__, cudaGetErrorString(e)); return 1; } } while (0)

static float bw(void* dst, void* src, size_t n, cudaMemcpyKind k) {
    cudaEvent_t a, b; cudaEventCreate(&a); cudaEventCreate(&b);
    cudaMemcpy(dst, src, n, k);
    cudaEventRecord(a);
    for (int i = 0; i < 10; i++) cudaMemcpy(dst, src, n, k);
    cudaEventRecord(b); cudaEventSynchronize(b);
    float ms; cudaEventElapsedTime(&ms, a, b);
    return 10.0f * n / (ms * 1e6f);
}

int main() {
    int n; CK(cudaGetDeviceCount(&n));
    for (int i = 0; i < n; i++) {
        cudaDeviceProp p; cudaGetDeviceProperties(&p, i);
        printf("GPU%d: %s sm_%d%d, %.1f GiB, %d SM, integrated=%d, pci %04x:%02x\n", i, p.name, p.major, p.minor,
               p.totalGlobalMem / 1073741824.0, p.multiProcessorCount, p.integrated, p.pciDomainID, p.pciBusID);
    }
    const size_t B = 256u << 20;
    void *h, *d; CK(cudaMallocHost(&h, B)); CK(cudaMalloc(&d, B));
    printf("H2D pinned 256MB: %.2f GB/s\n", bw(d, h, B, cudaMemcpyHostToDevice));
    printf("D2H pinned 256MB: %.2f GB/s\n", bw(h, d, B, cudaMemcpyDeviceToHost));

    cublasHandle_t cb; cublasCreate(&cb);
    const int N = 8192; const float al = 1, be = 0;
    float *A, *Bm, *C; CK(cudaMalloc(&A, 4ull*N*N)); CK(cudaMalloc(&Bm, 4ull*N*N)); CK(cudaMalloc(&C, 4ull*N*N));
    cudaMemset(A, 0, 4ull*N*N); cudaMemset(Bm, 0, 4ull*N*N);
    cudaEvent_t a, b; cudaEventCreate(&a); cudaEventCreate(&b); float ms;
    cublasSgemm(cb, CUBLAS_OP_N, CUBLAS_OP_N, N, N, N, &al, A, N, Bm, N, &be, C, N);
    cudaEventRecord(a);
    for (int i = 0; i < 5; i++) cublasSgemm(cb, CUBLAS_OP_N, CUBLAS_OP_N, N, N, N, &al, A, N, Bm, N, &be, C, N);
    cudaEventRecord(b); cudaEventSynchronize(b); cudaEventElapsedTime(&ms, a, b);
    printf("SGEMM %d: %.1f TFLOPS\n", N, 5 * 2.0 * N * N * N / (ms * 1e9));
    // FP16 inputs, FP32 accumulate (Tensor Cores)
    cublasGemmEx(cb, CUBLAS_OP_N, CUBLAS_OP_N, N, N, N, &al, A, CUDA_R_16F, N, Bm, CUDA_R_16F, N, &be, C, CUDA_R_16F, N,
                 CUBLAS_COMPUTE_32F, CUBLAS_GEMM_DEFAULT);
    cudaEventRecord(a);
    for (int i = 0; i < 5; i++)
        cublasGemmEx(cb, CUBLAS_OP_N, CUBLAS_OP_N, N, N, N, &al, A, CUDA_R_16F, N, Bm, CUDA_R_16F, N, &be, C, CUDA_R_16F, N,
                     CUBLAS_COMPUTE_32F, CUBLAS_GEMM_DEFAULT);
    cudaEventRecord(b); cudaEventSynchronize(b); cudaEventElapsedTime(&ms, a, b);
    printf("HGEMM %d (acc32): %.1f TFLOPS\n", N, 5 * 2.0 * N * N * N / (ms * 1e9));
    CK(cudaGetLastError());
    printf("OK\n");
    return 0;
}
