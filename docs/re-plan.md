# [B] Ghidra + LLM 逆向管线方案（已有重大静态命中）

> 前提：`probe.sh` 在 OpenCL/Vulkan 平台列表里**真的出现了 1EC8/G0M**。
> ⚡ 静态分析已提前命中（见 §0）：不需要等真机探针，证据已翻开。
> 目标：拿到驱动暴露的"计算接口"，评估能不能给 llama.cpp 造一个后端/借道运行。

## 0. 重大静态命中（2026-08-17，改动整个结论）

从 fantasyxpu.com 官方下载的 **fh2m Linux 桌面包（3.3.8.126）** 解包后直接拿到：
内核模块**全部源码** + 用户态驱动（含 OpenCL ICD），全包 ~57MB。

关键证据链：
1. **G0M 在支持列表里**：`fantsrvkm` 内核源码
   `fantsrvkm/include/g0m_pdp0_hw.h` 存在；
   PCI 表：
   `fantgpu_pci_drv.h:#define PCI_DEVICE_ID_G0M_SOC (0x9810)` → 你的卡 ID 直接命中。
2. **有原生 OpenCL 计算栈**：`etc/OpenCL/vendors/FANT_fh2m.icd` → `libFTOCL_fh2m.so`，
   导出全套 `clCreateContext/clCreateKernel/clBuildProgram/clCreateCommandQueue…`（真 OpenCL）。
3. **有原生 Vulkan**：`etc/vulkan/icd.d/fh2m_conf.json` → `libVK_FANT_fh2m.so.1`，API 1.3.264，
   导出标准 `vk_icdNegotiateLoaderICDInterfaceVersion`。
4. **PowerVR Rogue/BXT 血统坐实**：用户态文件名含 `powervr/`、`rogue_trace_events.h`、
   `ftxcore_km_35.x`、`libusc`（USC=统一着色器编译器）、`libufwriter`（微码写入器）。
5. **内核源码开放**：DKMS 树 `usr/src/fantgpu-fh2m-kernel-2.2/`，含 `fantsrvkm`(服务内核)、
   `fantdma`(PCIe DMA)、`fantvpu`(视频)、`fantsmmu`、`fantpower`(PMU)、`fantdpu`(显示)。
6. **有编译好的 .o_shipped**：`fantgpu.o_shipped`/`fantsrvkm.o_shipped`/`fantdma.o_shipped`/
   `fantsmmu.o_shipped` → 可以直接去符号化逆向，不用先跑 make。

**意义**：BXT 确实有 compute（OpenCL 3.0 + Vulkan 1.3），只是芯动把它锁在自家闭源栈里，外部工具认不出。
"无计算路径"旧判作废。llama.cpp 认不出，但 **clinfo 会认** —— 探针要直接查系统 ICD 平台列表。

## 0. 为什么不从图形接口下手

G0M 的 3D 图形是 PowerVR 血统（TBDR），llama.cpp 根本不用它。真正要的是**计算
路径**：OpenCL/Vulkan compute shader 或任何 NPU/加速器寄存器。所以整个逆向聚焦
"驱动里给谁送 command buffer、注册了哪些 device"。

## 1. 取证（重组后的真实状态）

驱动落地于 `~/g0m-re/drivers/`（本地已解包）：
- **Linux 补丁已得**：`fh2-deb/` 为 3.3.8.126 deb 解包目录（内核源码 + UMD + ICD）
- **Windows**（如需）：`fh2-v4.3.8.exe` = Qt 安装器 + Enigma 壳；内层
  `*.exe` 也含 9810，但剥壳无必要（Linux 已是全源码）
- **优先分析 Linux 包，因为连内核源码都开放**

### 静态取证结果（2026-08-17 深挖）
1. **G0M 是编译期一等公民**：`config_kernel.h` 里 `#define __G0M_SOC__`（release build），
   DKMS 源码就是为 G0M 编的。
2. **G0M 算力规格**：`ftxconfig_km_35.V.1632.23.h` 里
   `#if __LOW_POWER_USE_1SPU__ || __G0M_SOC__ → NUM_SPU=1, NUM_CLUSTERS=2`；
   `MAX_TPU_PER_SPU=2` → 单 SPU × 2 TPU 的低功耗核。
   核心头 `ftxcore_km_35.4.1632.23.h`（Rogue/Volcanic 血统 35.4）。
3. **G0M 三种子型**：`fantgpu_defs.h` 注释
   `0: G0M_SOC A4&A6, 1: A6S, 2: A6S_UPGRADED`。
4. **shader = RISC-V 微码**：`ftx_riscv.h`（RGX RISCV，RV32，4 个 256MB region，
   bootloader 0xC0000000 起）。
5. **计算主数据路径（CDM）齐全**：CCB 配置表里有 `CDM`（计算数据主）与 `TQ2D`。
6. **OpenCL ICD = 完整 PowerVR OCL 栈**：`libFTOCL_fh2m.so` 导出全部 cl* API +
   `clIcdGetPlatformIDsKHR`（标准 ICD 加载器握手）+ `clGetDeviceIDs/clGetDeviceInfo`。
7. **扩展丰富**：`cl_khr_fp16`、`cl_khr_command_buffer`、`cl_khr_external_memory_dma_buf`、
   `cl_arm_import_memory(_dma_buf)`、`cl_img_spirv`、`clCreateSubDevices`、`clGetDeviceAndHostTimer`。
8. **内存 = VRAM + GTT 两级**：字符串 `failed to allocate device memory and try gtt again`、
   `OCL_GetVramVISFreeSize`、`OCL_CreateBuffer_GttAlloc`、`EnableAllocGttMem`、
   `Local Memory Spill`、`cl_arm_import_memory_dma_buf` → device memory 不够就 spill 系统内存。

### 内存架构定案（源码级，2026-08-17）

**G0M = UMA 架构，显存是 DDR carve-out，GTT 默认允许但受控**

- 固件经 BAR 上报 DDR 大小，`revert_size_to_ddr_index` 映射到 128M/1G/4G/8G…档位；
  `get_hw_size` 运行时可改
- 可见显存：`fh2m_hal_get_visable_mem_total_size`；GPU 核心 MC mode：`get_gpu_mc_mode`
- **G0M 专属 GTT 行为**（`__G0M_SOC__` 宏独有）：
  - `fantgpu_pci_drv.c:164`：`int prohibit_umd_gtt_alloc = 0;`（module_param，0600）
    → **默认不禁止**，root 可 `echo 1 > /sys/module/fantgpu/parameters/...` 再禁
  - `gpu_info_fantml.c:407`：`info->enableGtt` 在 G0M 上取该 modparam（非 G0M 硬编码 1）
- **GTT 受控**（`hal.h:1415`）：`gtt_window_total_size`、`gtt_max_percent`、
  `avail_limit_size`、`enable_gtt_oom_check` → 不是无限吞系统内存，
  是带百分比上限 + OOM 检查的窗口
- LMA 池 = system RAM carve-out（`ftsrv_memalloc_physheap.h`：LMA= "carve out from system RAM
  or local card memory"）；`IMGVK_UMAHeapSizeMB` 可调 UMA 保留
- 真正的"4GB 显存" = 固件上报的 DDR carve-out（可能等于整机内存的固定份额）

**对 LLM 的含义**：权重优先塞 carve-out；GTT 默认可用但受 `gtt_max_percent` 限制；
超出 → OOM 而非无限 spill。真机以 `clinfo` 的 `CL_DEVICE_GLOBAL_MEM_SIZE` 为准。

**判读**：
- OpenCL 栈**真实完整**（IMAGINATION 级），不是空壳。clinfo 应能列出 FANT_fh2m 平台 + G0M 设备。
- G0M = 低规格（1 SPU × 2 TPU），算力弱但**不是不能算**；
- 显存 4GB + GTT spill → 权重最大可放系统内存，走统一地址（SLC/MMU v4）。

下一步分析顺序（全静态，先不碰 G0M 真机）：
1. `fantsrvkm/fantgpu/fantgpu_pci_drv.c` → 读 CHIP_G0M_SOC 初始化分支，确认芯片型号分支范围
2. `libFTOCL_fh2m.so` → `clGetDeviceIDs` 反汇编，看 G0M 要不要特殊 gating
3. `libfuftwriter/usc`（PowerVR 微码编译器）→ 是否有 RISC-V shader ISA（BXT 用 RV32，正好和 ftx_riscv.h 对上）
4. 判定 OpenCL 上 GPU 内存访问路径（显存 4GB 或 system memory）

## 2. 二进制分析（Ghidra + LLM）

- 主目标：`libFTOCL_fh2m.so`（OpenCL ICD）、`libVK_FANT_fh2m.so`
- 直接用 `.o_shipped`（有符号的预编译内核对象）交叉验证
- LLM 辅助：把反汇编/函数列表喂给大模型，让它标函数语义、追 command buffer 路径

### UAPI/compute 提交路径（已理清）

- 用户态 → DRM ioctl：`fantsrvkm/ft_drm.c`，`DRM_IOCTL_DEF_DRV` 系列（PVR 派生）
- 计算核心：`PVRSRV_BRIDGE_RGXCMP_RGXKICKCDM2`（PowerVR compute kick → CDM）
- 传输：`RGXTQ2_RGXTDMSUBMITTRANSFER2` 等全套 TQ2 命令
- firmware：META 处理器（`rgxmetafirmware_t0.elf`，`RGX_FEATURE_META MTP219`），**非** RV32
  （注意 `ftx_riscv.h` 是 RISC-V host 侧 remap，不是 FW 微码）

### OpenCL ICD 逆向（见 libftocl-static-analysis.md）

- `clGetPlatformIDs`/`clIcdGetPlatformIDsKHR` = 5B 跳板 → `0x96d0` 调度 → `0x95d0` 枚举 → `0x76ce0` context
- **关键负结论**：驱动侧**无厂商 ID 白名单 gate**，枚举本机 FANT 设备即视为自有 GPU
- 墙只在 llama.cpp 侧（vendor 白名单），不在 G0M 驱动侧

### Vulkan ICD 静态画像（2026-08-17）

`libVK_FANT_fh2m.so.1`（Vulkan 1.3.264）：
- **126 个 VK_EXT/KHR/ARM 扩展**，含计算关键：`VK_EXT_descriptor_buffer`、
  `VK_EXT_buffer_device_address`、`VK_KHR_shader_float16_int8`、
  `VK_KHR_shader_integer_dot_product`、`VK_KHR_shader_atomic_int64`、
  `VK_KHR_variable_pointers`、`VK_KHR_16bit_storage`/`8bit_storage`、
  `VK_KHR_timeline_semaphore`、subgroup 全家
- feature 串：`shaderFloat16`、`shaderSubgroupClock`、`computeFullSubgroups`、`subgroupSizeControl`
- 环境变量可控 UMA heap：`IMGVK_UMAHeapSizeMB`、`IMGVK_ParamBufferSize`
- 设备名同样 `Fantasy II-M`
- **结论：Vulkan 层与 OpenCL 同源同能力，不是图形摆样子，有完整 compute**

## 3. 借道可行性技术判定（2026-08-17）

### 借道选项

| 路径 | 可行性 | 备注 |
|---|---|---|
| **llama.cpp OpenCL 后端** | ⚠️ 低-B | llama.cpp OpenCL 后端按厂商 ID 白名单（认高通）,须改源码认 FANT（ID 0x1EC8）；OpenCL 3.0 兼容理论上能跑，但 llama.cpp OpenCL 后端已非开发重点 |
| **llama.cpp Vulkan 后端** | 📈 中-B（更优） | llama.cpp 主开发后端即 Vulkan；Vulkan 1.3.264 完整(126拓展) + `dlopen` ICD 加载器能认非白名单设备；只须改 ID 或按 UUID/name 匹配 |
| **PoCL（Portable OpenCL）** | ⚠️ 中-B | 能在开源 ICD 上叠加，但 PoCL GPU 目标需 OpenCL 1.2+ device 语义，可试 |
| **cl_khr_command_buffer 直送 CDM** | 理论可行/工程量大 | UAPI 完整（KICKCDM2），但等于自己写推理引擎，不现实 |
| **自写 OpenCL GEMM 微基准** | ✅ 已备好 | `kernels/gemm_microbench.cl` + `tools/bench_ocl_host.c`，真机编译即测 GFLOPs/带宽 |

### 核心物理结论（不变）

- G0M = 1 SPU × 2 TPU；OpenCL 3.0 GPU，有 fp16、dot product、GTT 二级内存
- **但**：4GB 显存 + GTT spill 走共享内存（PCIe/主机内存），带宽 ≈ CPU 双通道 DDR4，**无 cache 红利**
- 单 SPU 算力弱，无法指望 50 t/s；**到底多少 t/s = 真机微基准才能回答**

### 验收漏斗（真机上执行）

1. `probe.sh --write` → 确认 `Fantasy II-M` 设备出现
2. `clinfo`（对照 `docs/clinfo-prediction.md`）→ 读 CL_VERSION/CL_DEVICE_* 全参数
3. OpenCL GEMM 微基准 → 测 GFLOPs 与带宽（决定 4GB 模型搬移成本）
4. 若 3 不崩 → 试 llama.cpp `CL_*` 后端 hack（改 ID 白名单）或 Vulkan

## 4. 现实复核（时刻提醒自己）

- 即便接口全在：4GB 显存 + PCIe spill → 物理上限远低于 CPU 现成速度
- 本项目价值 = 逆向技能 + 稀缺知识，**不是**"G0M 跑出 50 t/s"
- 每个阶段产出一页笔记，归档进 `docs/`，别让投入失控
- 注意：这些分析是**不依赖真机**的静态取证，可以先于探针进行全面挖掘
