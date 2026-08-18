// bench_ocl_host.c — G0M OpenCL 微基准宿主（真机用）
//
// 依赖: libOpenCL.so.1 (ICD loader) + FANT_fh2m.icd 注册
// 编译: cc -O2 -o bench_ocl bench_ocl_host.c -lOpenCL
// 运行: ./bench_ocl
//
// 输出: 每个 kernel 的耗时 / GFLOPs / 带宽 估算。
// 大小参数可用 args 覆盖: ./bench_ocl M N K

#include <CL/cl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void CHECK(cl_int e, const char* what) {
  if (e != CL_SUCCESS) {
    fprintf(stderr, "FAIL %s: %d\n", what, e);
    exit(1);
  }
}

static double now_ms() {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static double run_gemm(cl_device_id dev, cl_context ctx, cl_command_queue q,
                       const char* name, unsigned M, unsigned N, unsigned K,
                       int fp16) {
  cl_int e;
  const char* src = NULL;
  cl_program prog;
  cl_kernel k;
  size_t sz;

  FILE* fcp = fopen("kernels/gemm_microbench.cl", "r");
  if (!fcp) { fprintf(stderr, "cannot open .cl\n"); exit(1); }
  fseek(fcp, 0, SEEK_END); sz = ftell(fcp); fseek(fcp, 0, SEEK_SET);
  src = malloc(sz + 1); fread((void*)src, 1, sz, fcp); fclose(fcp);
  ((char*)src)[sz] = 0;

  prog = clCreateProgramWithSource(ctx, 1, &src, &sz, &e); CHECK(e, "CreateProg");
  e = clBuildProgram(prog, 1, &dev, "-cl-std=CL1.2", NULL, NULL);
  if (e != CL_SUCCESS) {
    char log[8192]; clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, sizeof(log), log, NULL);
    fprintf(stderr, "BUILD FAIL (%s):\n%s\n", name, log);
    return -1;
  }
  k = clCreateKernel(prog, fp16 ? "gemm_fp16" : "gemm_fp32", &e); CHECK(e, "Kernel");

  size_t Asz = (size_t)M * K, Bsz = (size_t)K * N, Csz = (size_t)M * N;
  size_t esz = fp16 ? 2 : 4;
  cl_mem A = clCreateBuffer(ctx, CL_MEM_READ_ONLY, Asz * esz, NULL, &e); CHECK(e, "bufA");
  cl_mem B = clCreateBuffer(ctx, CL_MEM_READ_ONLY, Bsz * esz, NULL, &e); CHECK(e, "bufB");
  cl_mem C = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, Csz * esz, NULL, &e); CHECK(e, "bufC");

  CHECK(clSetKernelArg(k, 0, sizeof(A), &A), "arg0");
  CHECK(clSetKernelArg(k, 1, sizeof(B), &B), "arg1");
  CHECK(clSetKernelArg(k, 2, sizeof(C), &C), "arg2");
  CHECK(clSetKernelArg(k, 3, sizeof(M), &M), "arg3");
  CHECK(clSetKernelArg(k, 4, sizeof(N), &N), "arg4");
  CHECK(clSetKernelArg(k, 5, sizeof(K), &K), "arg5");

  size_t gsize[2] = {M, N};
  // 预热
  clEnqueueNDRangeKernel(q, k, 2, NULL, gsize, NULL, 0, NULL, NULL);
  clFinish(q);

  double t0 = now_ms();
  clEnqueueNDRangeKernel(q, k, 2, NULL, gsize, NULL, 0, NULL, NULL);
  clFinish(q);
  double dt = now_ms() - t0;

  double flop = 2.0 * (double)M * N * K;
  printf("%s  M=%u N=%u K=%u  %.2f ms   %.2f GFLOPS  (%d MB in+out)\n",
         name, M, N, K, dt, dt > 0 ? flop / (dt * 1e6) : -1,
         (int)((Asz + Bsz) / (1024*1024)));
  return dt;
}

static double run_bw(cl_device_id dev, cl_context ctx, cl_command_queue q,
                     unsigned long nints) {
  cl_int e; size_t sz = nints * sizeof(float);
  cl_mem s = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, sz, NULL, &e); CHECK(e, "bufSrc");
  cl_mem d = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, sz, NULL, &e); CHECK(e, "bufDst");
  const char* src = "__kernel void copy_bench(__global const float* s, __global float* d, unsigned n){unsigned i=get_global_id(0);if(i<n)d[i]=s[i]*2.0f;}";
  cl_program p = clCreateProgramWithSource(ctx, 1, &src, NULL, &e); CHECK(e,"pw");
  e = clBuildProgram(p, 1, &dev, NULL, NULL, NULL);
  if (e) { char lg[4096]; clGetProgramBuildInfo(p, dev, CL_PROGRAM_BUILD_LOG, sizeof lg, lg, NULL); fprintf(stderr,"bw build:\n%s\n",lg); return -1;}
  cl_kernel k = clCreateKernel(p, "copy_bench", &e); CHECK(e,"kc");
  CHECK(clSetKernelArg(k,0,sizeof(s),&s),""); CHECK(clSetKernelArg(k,1,sizeof(d),&d),"");
  CHECK(clSetKernelArg(k,2,sizeof(unsigned),&nints),"");
  size_t g = (nints + 255)/256 * 256;
  clEnqueueNDRangeKernel(q, k, 1, NULL, &g, NULL, 0, NULL, NULL); clFinish(q);
  double t0 = now_ms();
  clEnqueueNDRangeKernel(q, k, 1, NULL, &g, NULL, 0, NULL, NULL); clFinish(q);
  double dt = now_ms() - t0;
  double gbps = 2.0 * sz / (dt * 1e6);   // read+write
  printf("bandwidth(copy)  %lu MB   %.2f ms   %.2f GB/s (rd+wr)\n",
         (unsigned long)(sz>>20), dt, gbps);
  return gbps;
}

int main(int argc, char** argv) {
  unsigned M = 1024, N = 1024, K = 1024;
  if (argc >= 4) { M = atoi(argv[1]); N = atoi(argv[2]); K = atoi(argv[3]); }

  cl_int e;
  cl_uint nplat;
  CHECK(clGetPlatformIDs(0, NULL, &nplat), "platcount");
  if (!nplat) { fprintf(stderr, "no OpenCL platform! check /etc/OpenCL/vendors\n"); return 1; }
  cl_platform_id* plats = calloc(nplat, sizeof(cl_platform_id));
  clGetPlatformIDs(nplat, plats, NULL);

  /* 选第一个非 CPU 平台，否则选第一个 */
  cl_platform_id plat = plats[0];
  char pname[256] = {0}, pver[256] = {0};
  clGetPlatformInfo(plat, CL_PLATFORM_NAME, sizeof pname, pname, NULL);
  clGetPlatformInfo(plat, CL_PLATFORM_VERSION, sizeof pver, pver, NULL);
  printf("Platform: %s  %s\n", pname, pver);

  cl_device_id dev = NULL;
  cl_int edev = clGetDeviceIDs(plat, CL_DEVICE_TYPE_GPU, 1, &dev, NULL);
  if (edev != CL_SUCCESS)
    edev = clGetDeviceIDs(plat, CL_DEVICE_TYPE_ALL, 1, &dev, NULL);
  if (edev != CL_SUCCESS || dev == NULL) {
    fprintf(stderr, "no device on platform %s\n", pname);
    return 2;
  }
  char dname[256] = {0};
  cl_ulong dmem = 0;
  clGetDeviceInfo(dev, CL_DEVICE_NAME, sizeof dname, dname, NULL);
  clGetDeviceInfo(dev, CL_DEVICE_GLOBAL_MEM_SIZE, sizeof dmem, &dmem, NULL);
  printf("Device : %s  (%.1f GB global)\n", dname, dmem / 1e9);

  cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &e); CHECK(e, "ctx");
  cl_command_queue q = clCreateCommandQueue(ctx, dev, 0, &e); CHECK(e, "q");

  run_gemm(dev, ctx, q, "GEMM fp32", M, N, K, 0);
  run_gemm(dev, ctx, q, "GEMM fp16", M, N, K, 1);
  run_bw(dev, ctx, q, 1UL<<22);   // 16M floats = 64MB each

  return 0;
}