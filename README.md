# G0M 驱动逆向项目（g0m-re）

> 独立于 `sram`（缓存/流片研究）的旁支项目，**只做一件事：回答"芯动/仙境 G0M
> 这块国产 PowerVR 衍生卡，有没有可能用上 LLM 推理"，并把这套逆向技能沉淀下来。**
> 规则：与 sram 完全隔离，不互相污染；每个结论必须带证据（命令输出/截图/反汇编）。

## 物理事实（已确认，不再讨论）

- PCI ID：`VEN_1EC8&DEV_9810` → 芯动科技 仙境 G0M
- 板载显存 4GB；驱动版本 20.17.2.18608（2024-08-22）
- 底层 GPU IP = Imagination B-Series **BXT**（PowerVR 血统，非全自主 ISA）
- llama.cpp 官方后端清单 **无 Innosilicon 一行**；OpenCL 后端仅认高通 Adreno
- 4GB 显存装不下 27B/30B-A3B 任何一档 → 即便有计算能力也只能 spill 过 PCIe

## ⚡ 重大发现（2026-08-17，静态命中）

从 fantasyxpu.com 下载 fh2m Linux 桌面包（3.3.8.126，57MB deb），**不需要真机探针就拿到：
驱动包含 OpenCL 计算栈 + Vulkan 1.3.264 + G0M 内核支持 + 内核模块全部源码。**

- **G0M 在官方 Linux 驱动支持表**：`PCI_DEVICE_ID_G0M_SOC = 0x9810`
- **OpenCL ICD**：`libFTOCL_fh2m.so` 导出全套 cl* API，设备名=`Fantasy II-M`
- **Vulkan ICD**：`libVK_FANT_fh2m.so`，1.3.264，126 扩展（含 compute 全套）
- **内核源码开放**（DKMS 树 + `.o_shipped` 可离线逆向）
- 结论：llama.cpp 认不出 G0M ≠ "没有计算"，是芯动把它锁在闭源 FANT 堆里。
  → 分支 [C]"无计算"概率大幅下调，分支 [B] 概率大幅上调。

### 静态分析已定性的架构（离线全做完）

| 层 | 事实 |
|---|---|
| 内核 | `__G0M_SOC__` 编译宏；1 SPU × 2 TPU；CDM/TQ2D 计算 CCB；DRM ioctl |
| 固件 | META(MTP219) 微码，`rgxmetafirmware_t0.elf` |
| OpenCL | `libFTOCL_fh2m.so`=薄壳包在 srv_um 上；**无厂商 gate**（libFTOCL+srv_um 双层验证） |
| Vulkan | `libVK_FANT_fh2m.so` 完整 compute（fp16/int8/dot product/subgroup） |
| 内存 | VRAM→GTT spill 两级；`IMGVK_UMAHeapSizeMB` 可调 |
| 借道 | Linux：墙在 llama.cpp 白名单，不在驱动；Vulkan 为更优路径。**Windows：驱动本身无计算接口（仅 OpenGL），必上 Linux fh2m 驱动** |

详见 `docs/`（clinfo-prediction.md / libftocl-static-analysis.md / re-plan.md）。

## 决策树（严格按此推进，避免做无用功）

```
[0] 探针 probe.sh + 已完成的静态取证
    ├─ 有 OpenCL/Vulkan 计算 ICD（★ 已静态确认存在：libFTOCL + libVK_FANT）
    │     └─ [B] 逆向管线：Ghidra + LLM → 能不能让 llama.cpp 用上它
    │          附：离线先在 fh2m 源码 / .o_shipped 上展开（不依赖真机）
    └─ 真机复核后若并列不出 G0M/G0M 被 gate（极小概率）
          └─ [C] 转身为纯技能项目：逆向一块无人逆向过的国产 GPU 驱动
                （排他性简历资产），不再指望产出 token
```

## 记账原则

- 逆向项目投入上限：**以学习/简历价值为主**，产出以"分析能跑通、知识能沉淀"为准，
  不预期"让 G0M 跑出 50 t/s"（物理已判死，勿重复本项目在 sram 里的老路）。
- 任何阶段跑出"物理不可达"的证据，记录归档，立即停。

## 目录结构

```
g0m-re/
├── README.md            ← 本文件
├── scripts/
│   ├── probe.sh         ← [0] 探针：驱动暴不暴露计算 ICD（已增 ICD 文件检测）
│   └── fetch-driver.sh  ← 官方驱动抓取（已勘察 fantasyxpu API 结构）
├── drivers/             ← 已下载解包的 fh2m 驱动（deb 含内核源码 + ICD）
├── kernels/
│   └── gemm_microbench.cl  ← OpenCL GEMM 微基准（真机量化算力/带宽）
├── tools/
│   └── bench_ocl_host.c ← 微基准宿主（真机 cc -lOpenCL 编译）
└── docs/
    ├── probe-log.md          ← [0] 判定 + 离线静态取证记录
    ├── clinfo-prediction.md  ← 真机 clinfo 验收清单（静态预测）
    ├── libftocl-static-analysis.md ← clGetPlatformIDs 逆向调用链
    └── re-plan.md            ← [B] 逆向管线（已含借道可行性判定）
```