# llama.cpp 借道: FANT/G0M 设备认可链路（无 gate 实战分析）

> 分析对象：ggml-org/llama.cpp（main 分支，2026-08-17 拉取）
> 结论：**llama.cpp Vulkan 后端对 G0M 无厂商 gate，只须满足 1 个特性即可被接受。**
> 本文件 = 借道的"认证最终判据"，供真机验证。

## 1. Vulkan 后端设备接受条件（唯一检查点）

文件：`ggml/src/ggml-vulkan/ggml-vulkan.cpp`

```cpp
// 18807 起
static bool ggml_vk_device_is_supported(const vk::PhysicalDevice & vkdev) {
    ...
    vkGetPhysicalDeviceFeatures2(vkdev, &device_features2);
    return vk11_features.storageBuffer16BitAccess;   // ← 唯一的必要条件
}
```

- **无厂商 ID 匹配、无设备名匹配、无白名单**
- 枚举注册条件（7468 行）：`deviceType == eDiscreteGpu || eIntegratedGpu` **且** 上面函数返回 true
- 默认行为：`GGML_VK_VISIBLE_DEVICES` 未设时"use all dedicated GPUs"，无默认 `device_indices` 时 fallback 到第一个非 CPU 设备
- 可选环境变量：`GGML_VK_VISIBLE_DEVICES=idx` 手动指定设备索引

## 2. FANT 侧满足性判据

| 要求 | 我们掌握的静态证据 | 判定 |
|---|---|---|
| Vulkan ≥ 1.2 instance | FANT ICD `etc/vulkan/icd.d/fh2m_conf.json` = **1.3.264** | ✅ |
| `deviceType == GPU`（非 CPU） | IDC 名称 `Fantasy II-M`，定制 GPU | ✅ 待真机 |
| `storageBuffer16BitAccess` | 126 扩展含 `VK_KHR_16bit_storage`、`VK_KHR_shader_float16_int8` | ✅ 极大概率（真机 `vulkaninfo` 确认） |
| 派生路径非 AMD/Intel/NV 也不会被拒 | 设备注册循环**不拒绝未知 vendor**；仅 dedup 与 priority 特化 | ✅ |

## 3. 真机验证命令（按顺序）

```bash
# 1. 确认 FANT Vulkan 设备可见
vulkaninfo --summary | grep -A8 "GPU"
# 2. 确认 storageBuffer16BitAccess = yes（vulkaninfo 长期输出里 features）
vulkaninfo | grep -i "storagebuffer16bit"
# 3. 用 llama.cpp Vulkan 后端直接尝试（GGML_VK_VISIBLE_DEVICES 找到 FANT 的索引）
GGML_VK_VISIBLE_DEVICES=0 llama-bench -m models.gguf -ngl 99
#    -ngl 99 = 全权重用 GPU；溢出 GTT 会走系统内存
```

## 4. 若 3 失败的可能原因（排查表）

| 症状 | 原因 | 处置 |
|---|---|---|
| "No devices found" | FANT ICD 未注册 / vulkan loader 没加载 | 装 deb 后 `ldconfig`；确认 `/etc/vulkan/icd.d/` |
| 设备可见但报错 | `storageBuffer16BitAccess=false` | 关 fp16 路径（`-DT fake` 不行，改用 `mmvq`） |
| 跑起来很慢 | 1 SPU×2 TPU 算力弱 + GTT spill | 接受现实，用 CPU 更快的模型 |
| OOM / 显存不足 | 4GB VRAM | `GGML_VK_ALLOW_SYSMEM_FALLBACK=1` |

## 5. 结论

- llama.cpp Vulkan 后端 = 理论可行的主路径（**无代码修改**）
- 兜底路径：OpenCL 后端（同样无 vendor gate，但功能不完整）
- PoCL：非必要（Vulkan 已能过）
- 物理上限不变：单 SPU×2TPU + 4GB/GTT → 性能大概率远低于 CPU 现成方案
- **真实问题不是"认不认"，是"值不值"** —— 由真机 GEMM 微基准回答

## 5b. OpenCL 后端交叉验证（同样无 gate）

文件：`ggml/src/ggml-opencl/ggml-opencl.cpp`（5479 起）

- 枚举全部平台（`clGetPlatformIDs`），对每个平台拉设备，**不检查 vendor 白名单**
- 默认选第一个 `CL_DEVICE_TYPE_GPU` 作为 default_device
- 可指定：`GGML_OPENCL_PLATFORM=<数字|名字子串>` + `GGML_OPENCL_DEVICE=<数字>`
- 借道使用：`GGML_OPENCL_PLATFORM=Fantasy llama-bench -m model.gguf -ngl 99`
- **与 Vulkan 相同的"无 gate"结论**，且 OpenCL 3.0 设备在 llama.cpp OpenCL 后端仅需支持
  所需 kernel 子集（OpenCL 1.2+ 语义即可）
- 注意：llama.cpp OpenCL 后端维护优先级低于 Vulkan，部分新 kernel 可能不完整；
  主路径仍推荐 Vulkan

## 6. 参考文件

- llama.cpp `ggml/src/ggml-vulkan/ggml-vulkan.cpp`
  - 18807 `ggml_vk_device_is_supported`
  - 7468 设备注册环路（`use all dedicated GPUs`）
  - 7440 `GGML_VK_VISIBLE_DEVICES` 处理
- llama.cpp `ggml/src/ggml-opencl/ggml-opencl.cpp`
  - 5479 平台枚举（无 vendor gate）
- FANT: `libVK_FANT_fh2m.so.1`（1.3.264，126 扩展）
- 微基准: `tools/bench_ocl_host.c`（OpenCL 先量化 GFLOPs）

## 7. 勘误：早期"llama.cpp 只认高通 OpenCL"的说法不成立

> 本项目早期（以及部分网络资料）声称 llama.cpp OpenCL 后端"只认高通 Adreno"、
> Vulkan 后端"有厂商白名单"。**源码级核对推翻此说法**：
> - Vulkan：唯一条件 `vk11_features.storageBuffer16BitAccess`（18807）
> - OpenCL：枚举所有平台，默认选第一个 GPU（5479）
> - 两者均无厂商 ID/设备名/白名单过滤；按 vendor 走的只是 AMD/Intel/NV 的
>   **性能路径特化**（coopmat 等），不是准入检查。
> 此勘误**上修**了借道可行性："Drive 能枚举" → "llama 能接受"。