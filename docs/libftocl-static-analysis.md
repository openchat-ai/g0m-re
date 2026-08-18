# libFTOCL 静态逆向笔记（clGetPlatformIDs 调用链）

> 分析对象：`fh2-deb/usr/lib/x86_64-linux-gnu/fantgpu-fh2m/libFTOCL_fh2m.so.1`
> 工具：capstone 5.0.9（python），readelf，objdump -T
> 日期：2026-08-17
> 状态：实现级分析，未触真机

## 1. 导出符号：标准 ICD stub

- `clGetPlatformIDs`、`clIcdGetPlatformIDsKHR`、`clGetPlatformInfo` = **5 字节跳板**（`e9 rel32`）
- `clGetDeviceIDs`、`clGetDeviceInfo` = 同样的 5 字节 stub 模式
- `.symtab` 被 strip（只有 `.dynsym`，354 个导出符号中 cl* 系、PVRSRV* 系齐全）
- **结论：这是完整 ICD 加载器实现，符号打掉了，但行为完整**

## 2. clGetPlatformIDs 跳板 → 0x96d0

`0x96d0` 是平台对象调度入口：
- `0x96e2: mov rbx, [rip+0x2a18cf]` → 读静态平台对象（快照）
- `je 0x9790`（空）→ 走初始化路径
- `0x971c: call 0x95d0`（`edi=0x36`）→ 枚举/填充平台结构
- 校验参数（numPlatforms/numPlatformsRet）返回 CLXXX 错误码模式（`0xffffffe2`=CL_INVALID_VALUE 等）

## 3. 枚举核心 0x95d0（设备表拉取）

- `mov rbp, [rip+0x2a19d7]` → 全局上下文基址
- `[rbp+0x130]` → 设备枚举表地址（非空则走 0x7b00）
- `0x7b00` = 设备枚举核心（返回设备结构）
- `[rax+0xad8] & 2` = **设备状态标志位**（bit1），决定 0x9640（新建）还是 0x9690（复用已有）
- `0x964e→0x9679: call 0x76ce0` = context/open 设备（大变参函数，栈帧 0xd70，OCL context 级）
- `[rbp+0x158]`、`[rbp+0x3c0]` = 设备特征字段（CL_VERSION/feature mask）

## 4. context 核心 0x76ce0

- 变参函数（`test al,al` + xmm 传参），栈帧 0xd70 ≈ 大结构初始化
- 符合 clCreateContext/DeviceInfo 构造逻辑；内部调 srv_um（`libsrv_um_fh2m.so` 是 extern NEEDED）

## 5. 关键负结论：无厂商白名单 gate

- 全库搜 `1ec8`、`unsupported vendor`、`unknown vendor`、`recognized` → **零命中**
- 错误串只有 `CL_DEVICE_NOT_FOUND`、`Device not found`、`No device provided`
  → **它枚举的是本机 FANT 设备，不挑厂商 ID**
- ⇒ 「llama.cpp/其它工具认不出 G0M」的墙在 llama.cpp 侧（vendor 白名单），**不在驱动侧**
- ⇒ G0M 对 OpenCL 加载器是"正常可见设备"

## 6. 对真机的验收钩子

1. `clinfo -l` 若列出 `Fantasy II-M` → 上面整条链成立
2. `clinfo` 平台数=1 且名字含 Fantasy → OK
3. 若平台枚举为空 → 查 `/etc/OpenCL/vendors/FANT_fh2m.icd` 与 `libOpenCL.so.1` 加载是否到位
4. 借道（llama.cpp）：只需在 llama.cpp OpenCL 后端的厂商检查里接受 FANT，无驱动侧阻碍

## 6b. libFTOCL 的 srv_um 依赖层（关键架构事实）

- libFTOCL 大量 `UND` 导入 → 指向 `libsrv_um_fh2m.so`（用户态 PowerVR Services）
  - `PVRSRVGetDevices` = 设备枚举核心（0x95d0 枚举落在此）
  - `RGXKickCDM` = 计算提交
  - `PVRSRVConnectionCreateDevice`、`PVRSRVMapToDevice`、`PVRSRVSubAllocDeviceMem` 等
- 0x7b00 等跳板 = PLT stub（`push 序号; jmp resolver`）→ 动态解析到 srv_um 导入
- **架构定性**：libFTOCL = 薄 OpenCL 规范层，包在完整 PowerVR srv_um 之上。
  ⇒ 设备枚举/计算提交的"真实现"在 srv_um（同名 .so 在 fh2-deb UMD 目录），

## 7. 进度

- [x] 跳板确认（5B stub）
- [x] 平台枚举核心定位（0x96d0 / 0x95d0 / 0x7b00 / 0x76ce0）
- [x] 无 vendor gate 负结论
- [x] srv_um 依赖层（PVRSRVGetDevices/RGXKickCDM 导入）
- [ ] 真机 clinfo 对照（验收，需在 T40 前）
- [ ] （可选）libsrv_um_fh2m.so 的 PVRSRVGetDevices 逐位解码（拿 CL_DEVICE_* 字段）