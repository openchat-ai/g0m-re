// gemm_microbench.cl — G0M(Fantasy II-M) OpenCL GEMM 微基准
//
// 目标：真机上量化 1SPU×2TPU 的 GFLOPs 与内存带宽，回答"到底能不能用"。
// 用法：配合 tools/bench_ocl_host.c 编译运行，或直接 clinfo+此文件人工测试。
//
// 设计：三种测法
//  1) FP32 GEMM C[MxN] = A[MxK] x B[KxN]  (纯算力上限)
//  2) FP16 GEMM (若有 cl_khr_fp16)       (低精度算力)
//  3) 大 buffer copy                      (内存带宽, GTT spill 效果)
//
// 设计约束：让 M/N/K 可被 workgroup 整除，tile 128/64，1 次读多复用。

#define TILE 32   // 每个 workgroup 处理 tile: C[TILE][TILE]

// ---- FP32 GEMM kernel ----
// C[i,j] = sum_k A[i,k]*B[k,j]
// 每个 workgroup 一个 TILExTILE 输出块；每个 work-item 1 个输出。
__kernel void gemm_fp32(__global const float* __restrict A,
                        __global const float* __restrict B,
                        __global float* __restrict C,
                        unsigned int M, unsigned int N, unsigned int K) {
  unsigned int ma = get_global_id(0);   // row within C
  unsigned int mb = get_global_id(1);   // col within C
  if (ma >= M || mb >= N) return;
  float acc = 0.0f;
  // 逐 K 累加，K 对齐 4 便于向量化
  unsigned int k = 0;
  const float4 zero4 = 0.0f;
  for (; k + 4 <= K; k += 4) {
    float4 av = vload4(0, A + ma * (size_t)K + k);
    float4 bv = vload4(0, B + k * (size_t)N + mb);
    acc = fma(av[0], bv[0], acc);
    acc = fma(av[1], bv[1], acc);
    acc = fma(av[2], bv[2], acc);
    acc = fma(av[3], bv[3], acc);
  }
  for (; k < K; ++k) acc = fma(A[ma*(size_t)K+k], B[k*(size_t)N+mb], acc);
  C[ma*(size_t)N+mb] = acc;
}

// ---- FP16 GEMM kernel（需 cl_khr_fp16；不支持则跳过本测）----
#ifdef cl_khr_fp16
#pragma OPENCL EXTENSION cl_khr_fp16 : enable
__kernel void gemm_fp16(__global const half* __restrict A,
                        __global const half* __restrict B,
                        __global half* __restrict C,
                        unsigned int M, unsigned int N, unsigned int K) {
  unsigned int ma = get_global_id(0);
  unsigned int mb = get_global_id(1);
  if (ma >= M || mb >= N) return;
  half acc = 0;
  unsigned int k = 0;
  for (; k + 4 <= K; k += 4) {
    half4 av = vload4(0, A + ma*(size_t)K + k);
    half4 bv = vload4(0, B + k*(size_t)N + mb);
    acc = mad(av[0], bv[0], acc);
    acc = mad(av[1], bv[1], acc);
    acc = mad(av[2], bv[2], acc);
    acc = mad(av[3], bv[3], acc);
  }
  for (; k < K; ++k) acc = mad((half)A[ma*(size_t)K+k], (half)B[k*(size_t)N+mb], acc);
  C[ma*(size_t)N+mb] = acc;
}
#endif

// ---- 带宽测试：大 buffer 读改写（测 GTT spill / VRAM 上限）----
__kernel void copy_bench(__global const float* __restrict src,
                         __global float* __restrict dst,
                         unsigned int n) {
  unsigned int i = get_global_id(0);
  if (i >= n) return;
  dst[i] = src[i] * 2.0f;
}