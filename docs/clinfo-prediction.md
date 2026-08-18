# 静态预测: clinfo 在 G0M 上会输出什么（验收清单）

> 全部由 **2026-08-17 静态分析** libFTOCL_fh2m.so（OpenCL ICD）推断。
> 真机 `clinfo` 后对照本页。**偏差即线索**：若与预测不符，说明安装/枚举有 GFW（gate）。
> 生成依据：libFTOCL 的设备名、扩展、版本字符串 + fh2m 内核源码。

## 平台层（clGetPlatformInfo）

| 字段 | 预测值 | 依据 |
|---|---|---|
| Platform Name | `Fantasy` 系（大概率 `Fantasy II-M`） | libFTOCL 唯一设备名 `Fantasy II-M` |
| Platform Version | `OpenCL 3.0 ` | libFTOCL 硬编码串 |
| Platform Vendor | `Fantasy` / 芯动 | libFTOCL `Fantasy` |
| Extension | `cl_khr_icd` 等 | 见下扩展表 |

## 设备层（clGetDeviceInfo）

| 字段 | 预测值 | 依据 |
|---|---|---|
| Device Name | **`Fantasy II-M`** | 唯一 .rodata 字面量 |
| Device Type | GPU（CL_DEVICE_TYPE_GPU） | ICD 内计算路径齐全 |
| CL version | **OpenCL 3.0** | ICD 版本串 |
| FP16 | 有（`cl_khr_fp16`） | 扩展表 |
| 指令 | sdot/udot（`cl_khr_integer_dot_product`） | 扩展表 |
| 显存 | 查询实际 VRAM（若安装正确）或走 GTT | `OCL_GetVramVISFreeSize` |
| 核心数 | 受 1 SPU × 2 TPU 限制 | config_kernel.h |
| Sub-devices | 支持 `clCreateSubDevices` | 扩展表 |
| Command buffer | 支持 `cl_khr_command_buffer` | 扩展表 |

## 完整扩展清单（libFTOCL 全部 cl_* 扩展，真机上 clinfo 扩展段应对等）

- subgroup 全家桶：`cl_khr_subgroups` `cl_khr_subgroup_ballot` `cl_khr_subgroup_clustered_reduce`
  `cl_khr_subgroup_extended_types` `cl_khr_subgroup_non_uniform_arithmetic`
  `cl_khr_subgroup_non_uniform_vote` `cl_khr_subgroup_rotate` `cl_khr_subgroup_shuffle`
  `cl_khr_subgroup_shuffle_relative`
- 数学/精度：`cl_khr_fp16` `cl_khr_fp64`(待真机)`cl_khr_integer_dot_product`
- 内存：`cl_khr_external_memory` `cl_khr_external_memory_dma_buf` `cl_khr_byte_addressable_store`
  `cl_khr_image2d_from_buffer` `cl_arm_import_memory` `cl_arm_import_memory_dma_buf`
- 调度：`cl_khr_command_buffer` `cl_khr_create_command_queue` `cl_khr_priority_hints`
  `cl_khr_suggested_local_work_size` `cl_arm_scheduling_controls`
- IMG 专用：`cl_img_spirv` `cl_img_external_semaphore` `cl_img_semaphore`
  `cl_img_yuv_image` `cl_img_generate_mipmap` `cl_img_mem_properties` `cl_img_protected_content`
- 其它：`cl_khr_icd` `cl_khr_il_program` `cl_khr_device_uuid` `cl_khr_extended_versioning`
  `cl_khr_egl_image` `cl_khr_mipmap_image` `cl_khr_global/local_int32_*`

## 判定规则

- 真机输出与上表一致 → G0M OpenCL **全开**，可直接考虑 llama.cpp 借道（OpenCL 后端 / PoCL / 直写命令）
- 平台枚举为空 / 设备名非 `Fantasy II-M` / 无计算扩展 → **驱动未装全**，回查 fh2m.icd 注册
- `clinfo` 报告 CPU 假平台 → ICD 没挂上（clinfo 走 XUser；`clGetDeviceIDs` 走 FANT UMD）