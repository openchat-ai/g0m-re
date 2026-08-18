# G0M 探针日志（probe.sh 输出归档 + 离线静态取证）

> 由 `scripts/probe.sh --write` 生成/覆盖。运行环境：Suma T40 工作站。
> 日期：待运行

```text
（在此粘贴 probe.sh 输出）
```

## 离线静态取证（2026-08-17，重大）

**不必等真机，已经离线翻开 G0M 的计算路径。来源：fantasyxpu.com 官方 Linux 桌面包 fh2m 3.3.8.126**

证据链（详见 re-plan.md §0 与 §1 深挖，全部可复核）：
1. **G0M 在官方 Linux 驱动支持列表**：`fantgpu_pci_drv.h:#define PCI_DEVICE_ID_G0M_SOC (0x9810)` → 命中你的卡
2. **G0M 是编译期一等公民**：`config_kernel.h:#define __G0M_SOC__`（release build 就是为 G0M 编的）
3. **G0M 算力规格**：1 SPU × 2 TPU（`__G0M_SOC__` 分支强制 NUM_SPU=1/NUM_CLUSTERS=2），低功耗核
4. **shader = RISC-V 微码**（RV32，`ftx_riscv.h`）、计算核心 **CDM** + **TQ2D** 均启用
5. **OpenCL ICD 完整**：`libFTOCL_fh2m.so` 导出全套 cl* API + `clIcdGetPlatformIDsKHR`
6. **OpenCL 设备名唯一写死 = `Fantasy II-M`**（G0M 的商品代号）
7. **内存两级**：VRAM(device memory) → 不够自动 **GTT spill** 系统内存 + `cl_arm_import_memory_dma_buf`
8. **Vulkan 1.3.264**（`libVK_FANT_fh2m.so`）
9. **内核源码全开放**（DKMS 树 + `.o_shipped` 预编译对象可离线逆向）

**判定【离线初判】：分支 [B] 成立，且路径清晰。** G0M 不是"办公/显示卡"，是
有完整原生 OpenCL（3.x，IMG 级实现）+ Vulkan 计算栈的 GPU，被芯动闭源封装。
alama.cpp 认不出是"不识货"不是"没货"。瓶颈 = 1 SPU × 2 TPU 算力 + 4GB 显存/GTT。

## 判定

- [x] 分支 [B]（静态命中，OpenCL ICD 已确认）：驱动暴露了计算 ICD，启动 Ghidra 逆向（见 re-plan.md）
- [x] 分支 [B] 后续借道结论：llama.cpp Vulkan/OpenCL 后端**均无厂商 gate**（源码核对），
      G0M 大概率可直接被枚举（docs/llama-borrow-path.md）
- [ ] 分支 [C]：无计算能力，项目转为技能学习，停止计算期望（暂不排除，等真机探针复核）

## 内存最终定案（2026-08-17）

- **UMA 架构**：显存 = 固件上报 DDR carve-out（4GB 档）
- **GTT**：`prohibit_umd_gtt_alloc=0`（默认允许，root 可改）+ 受控窗口
  （`gtt_max_percent` / `avail_limit_size` / `enable_gtt_oom_check`）
- 真机必须量 `CL_DEVICE_GLOBAL_MEM_SIZE` 实际值

## 27B 最终判定（2026-08-17，归档）

**直接跑 27B：不行（物理墙）。** 模型权重任何量化档（Q3≈11GB 起）都远超 carve-out ≈4GB，
与 GTT 无关——carve-out 就是上限，无本地高速显存可依托。

**间接方式全部赔本（带宽墙）：**

- **流式加载**（== GTT 换页/逐层搬进 4GB）：容量墙可破，但每 token 仍要全量读权重，总量不变。
- **常驻共享内存**：当前最优部署（省搬运税），但 **G0M 是 PCIe 外插卡不是 iGPU**，
  访问宿主内存必经 PCIe（~12GB/s 有效），CPU 直读 DDR4 约 25–30GB/s →
  GPU 反而慢约 2 倍（G0M ~1.1 t/s vs CPU ~2.5 t/s）+ 调度/DRM 开销 + 单 SPU 算力更低。
- **自己写代码变不了 iGPU**：等效带宽限死在铜线（PCIe lane 布线），DMA（fantdma/AXI）
  也只是省 CPU 搬运税，TLP 仍走 PCIe，带宽上限不变。软件改不了物理拓扑。

**结论：27B 推理的唯一路径 = CPU 全加载。G0M 定案为显示卡 + 可演示的
OpenCL/Vulkan 计算栈。** 差异只来自它是"无本地显存 + 弱算力"的外插卡。

> 状态：离线归档完成，等真机 `probe.sh` 复核一个数字
> （CL_DEVICE_GLOBAL_MEM_SIZE 实际值、GEMM 微基准），确认纸面账。

## 下一步

1. **真机跑 `scripts/probe.sh --write`**，确认 clinfo 是否枚举到 `Fantasy II-M` / FANT_fh2m 平台
2. 若枚举到 → `clinfo` 读 G0M 的 CL_DEVICE_* 全参数（CL 版本、**CL_DEVICE_GLOBAL_MEM_SIZE 实际值**、
   工作项上限、fp16 支持）
3. 实测微基准 `tools/bench_ocl_host.c`（GEMM GFLOPs + copy 带宽）
4. 试跑 llama.cpp Vulkan 后端（`GGML_VK_VISIBLE_DEVICES=0 llama-bench -ngl 99`，
   详见 docs/llama-borrow-path.md 无 gate 依据）
5. 若 OOM/慢 → 对照"内存架构定案"（UMD 禁 GTT），改用 CPU
