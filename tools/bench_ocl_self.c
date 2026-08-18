// bench_ocl_self.c — G0M OpenCL 微基准(单文件自包含版,真机用)
// 内核已内嵌,无需外部 .cl 文件。复制到 T40 后:
//   cc -O2 -o bench_ocl bench_ocl_self.c -lOpenCL
//   ./bench_ocl [M N K]
#include <CL/cl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void CHECK(cl_int e, const char* what) {
  if (e != CL_SUCCESS) { fprintf(stderr, "FAIL %s: %d\n", what, e); exit(1); }
}
static double now_ms() {
  struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static const char* KERN_GEMM_FP32 =
"__kernel void gemm_fp32(__global const float* restrict A,"
"                        __global const float* restrict B,"
"                        __global float* restrict C,"
"                        unsigned int M, unsigned int N, unsigned int K) {"
"  unsigned int ma = get_global_id(0), mb = get_global_id(1);"
"  if (ma >= M || mb >= N) return;"
"  float acc = 0.0f; unsigned int k = 0;"
"  for (; k + 4 <= K; k += 4) {"
"    float4 av = vload4(0, A + ma*(size_t)K + k);"
"    float4 bv = vload4(0, B + k*(size_t)N + mb);"
"    acc = fma(av.x,bv.x,acc); acc = fma(av.y,bv.y,acc);"
"    acc = fma(av.z,bv.z,acc); acc = fma(av.w,bv.w,acc);"
"  }"
"  for (; k < K; ++k) acc = fma(A[ma*(size_t)K+k], B[k*(size_t)N+mb], acc);"
"  C[ma*(size_t)N+mb] = acc;"
"}";

static const char* KERN_GEMM_FP16 =
"#pragma OPENCL EXTENSION cl_khr_fp16 : enable\n"
"__kernel void gemm_fp16(__global const half* restrict A,"
"                        __global const half* restrict B,"
"                        __global half* restrict C,"
"                        unsigned int M, unsigned int N, unsigned int K) {"
"  unsigned int ma = get_global_id(0), mb = get_global_id(1);"
"  if (ma >= M || mb >= N) return;"
"  half acc = (half)0; unsigned int k = 0;"
"  for (; k + 4 <= K; k += 4) {"
"    half4 av = vload4(0, A + ma*(size_t)K + k);"
"    half4 bv = vload4(0, B + k*(size_t)N + mb);"
"    acc = mad(av.x,bv.x,acc); acc = mad(av.y,bv.y,acc);"
"    acc = mad(av.z,bv.z,acc); acc = mad(av.w,bv.w,acc);"
"  }"
"  for (; k < K; ++k) acc = mad((half)A[ma*(size_t)K+k], (half)B[k*(size_t)N+mb], acc);"
"  C[ma*(size_t)N+mb] = acc;"
"}";

static const char* KERN_COPY =
"__kernel void copy_bench(__global const float* restrict s,"
"                         __global float* restrict d, unsigned int n){"
"  unsigned int i = get_global_id(0); if (i>=n) return; d[i]=s[i]*2.0f; }";

static double run_gemm(cl_device_id dev, cl_context ctx, cl_command_queue q,
                       const char* name, const char* src, unsigned M, unsigned N,
                       unsigned K) {
  cl_int e; cl_program p; cl_kernel k;
  p = clCreateProgramWithSource(ctx, 1, &src, NULL, &e); CHECK(e, "CreateProg");
  e = clBuildProgram(p, 1, &dev, "-cl-std=CL1.2", NULL, NULL);
  if (e != CL_SUCCESS) {
    char lg[8192]; clGetProgramBuildInfo(p, dev, CL_PROGRAM_BUILD_LOG, sizeof lg, lg, NULL);
    fprintf(stderr, "BUILD FAIL (%s):\n%s\n", name, lg); return -1;
  }
  k = clCreateKernel(p, "gemm_fp32", &e);
  if (e != CL_SUCCESS) { fprintf(stderr, "SKIP %s (no kernel)\n", name); return -1; }
  size_t esz = strstr(src, "half") ? 2 : 4;
  size_t Asz = (size_t)M*K, Bsz = (size_t)K*N, Csz = (size_t)M*N;
  cl_mem A = clCreateBuffer(ctx, CL_MEM_READ_ONLY, Asz*esz, NULL, &e); CHECK(e,"A");
  cl_mem Bm = clCreateBuffer(ctx, CL_MEM_READ_ONLY, Bsz*esz, NULL, &e); CHECK(e,"B");
  cl_mem C = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, Csz*esz, NULL, &e); CHECK(e,"C");
  CHECK(clSetKernelArg(k,0,sizeof A,&A),"a"); CHECK(clSetKernelArg(k,1,sizeof Bm,&Bm),"b");
  CHECK(clSetKernelArg(k,2,sizeof C,&C),"c"); CHECK(clSetKernelArg(k,3,sizeof M,&M),"m");
  CHECK(clSetKernelArg(k,4,sizeof N,&N),"n"); CHECK(clSetKernelArg(k,5,sizeof K,&K),"k");
  size_t gs[2] = {M, N};
  clEnqueueNDRangeKernel(q, k, 2, NULL, gs, NULL, 0, NULL, NULL); clFinish(q); /*warm*/
  double t0 = now_ms();
  clEnqueueNDRangeKernel(q, k, 2, NULL, gs, NULL, 0, NULL, NULL); clFinish(q);
  double dt = now_ms() - t0;
  printf("%-12s M=%u N=%u K=%u  %7.2f ms  %7.2f GFLOPS\n", name, M, N, K, dt,
         dt > 0 ? 2.0*M*N*K/(dt*1e6) : -1);
  return dt;
}

static double run_bw(cl_device_id dev, cl_context ctx, cl_command_queue q,
                     unsigned long nints) {
  cl_int e; size_t sz = nints * sizeof(float);
  cl_mem s = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, sz, NULL, &e); CHECK(e,"bs");
  cl_mem d = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, sz, NULL, &e); CHECK(e,"bd");
  cl_program p = clCreateProgramWithSource(ctx, 1, &KERN_COPY, NULL, &e); CHECK(e,"pw");
  e = clBuildProgram(p, 1, &dev, NULL, NULL, NULL);
  if (e) { char lg[4096]; clGetProgramBuildInfo(p,dev,CL_PROGRAM_BUILD_LOG,sizeof lg,lg,NULL);
           fprintf(stderr,"bw build:\n%s\n",lg); return -1; }
  cl_kernel k = clCreateKernel(p, "copy_bench", &e); CHECK(e,"kc");
  CHECK(clSetKernelArg(k,0,sizeof s,&s),""); CHECK(clSetKernelArg(k,1,sizeof d,&d),"");
  CHECK(clSetKernelArg(k,2,sizeof nints),""); size_t g = (nints+255)/256*256;
  clEnqueueNDRangeKernel(q,k,1,NULL,&g,NULL,0,NULL,NULL); clFinish(q);
  double t0 = now_ms();
  clEnqueueNDRangeKernel(q,k,1,NULL,&g,NULL,0,NULL,NULL); clFinish(q);
  double dt = now_ms() - t0;
  printf("bandcopy          %5lu MB   %7.2f ms  %7.2f GB/s (rd+wr)\n",
         (unsigned long)(sz>>20), dt, dt>0? 2.0*sz/(dt*1e6):-1);
  return dt;
}

int main(int argc, char** argv) {
  unsigned M = 1024, N = 1024, K = 1024;
  if (argc >= 4) { M = atoi(argv[1]); N = atoi(argv[2]); K = atoi(argv[3]); }
  cl_int e; cl_uint np;
  CHECK(clGetPlatformIDs(0, NULL, &np), "platcount");
  if (!np) { fprintf(stderr, "NO OpenCL platform! check /etc/OpenCL/vendors\n"); return 1; }
  cl_platform_id* ps = calloc(np, sizeof(cl_platform_id));
  clGetPlatformIDs(np, ps, NULL);
  char pname[256] = {0}, pver[256] = {0};
  clGetPlatformInfo(ps[0], CL_PLATFORM_NAME,  sizeof pname, pname, NULL);
  clGetPlatformInfo(ps[0], CL_PLATFORM_VERSION,sizeof pver,  pver, NULL);
  printf("Platform: %s  %s\n", pname, pver);
  cl_device_id dev = NULL;
  cl_int edev = clGetDeviceIDs(ps[0], CL_DEVICE_TYPE_GPU, 1, &dev, NULL);
  if (edev != CL_SUCCESS) edev = clGetDeviceIDs(ps[0], CL_DEVICE_TYPE_ALL, 1, &dev, NULL);
  if (edev != CL_SUCCESS || dev == NULL) { fprintf(stderr, "no device on %s\n", pname); return 2; }
  char dname[256] = {0}; cl_ulong dmem = 0;
  clGetDeviceInfo(dev, CL_DEVICE_NAME, sizeof dname, dname, NULL);
  clGetDeviceInfo(dev, CL_DEVICE_GLOBAL_MEM_SIZE, sizeof dmem, &dmem, NULL);
  printf("Device : %s  (%.1f GB global)\n", dname, dmem/1e9);
  cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &e); CHECK(e, "ctx");
  cl_command_queue q = clCreateCommandQueue(ctx, dev, 0, &e); CHECK(e, "q");
  run_gemm(dev, ctx, q, "GEMM fp32", KERN_GEMM_FP32, M, N, K);
  run_gemm(dev, ctx, q, "GEMM fp16", KERN_GEMM_FP16, M, N, K);
  run_bw(dev, ctx, q, 1UL<<22);
  return 0;
}