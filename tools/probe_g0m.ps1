<#
probe_g0m.ps1 - G0M (Fantasy II-M?) 探测脚本 (Windows 原生, 无第三方依赖)

用途:
  在 Windows 上不用装 clinfo/vulkaninfo/gcc, 直接用系统自带的
  OpenCL.dll (ICD loader) + PowerShell 探测 G0M 计算栈:
    1. PCI 设备 (VEN_1EC8 / DEV_9810)
    2. 驱动目录 (DriverStore 里 fh2m/fant)
    3. OpenCL ICD 注册表
    4. OpenCL 平台/设备枚举 + CL_DEVICE_GLOBAL_MEM_SIZE 等关键参数
    5. 可选: 一个简单 copy kernel 实测带宽 (测 carve-out 是不是共享内存)

用法 (管理员 PowerShell 或不需管理):
  powershell -ExecutionPolicy Bypass -File probe_g0m.ps1
  或直接右键 "使用 PowerShell 运行"

作者: sram (g0m-re 项目)
#>

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== G0M probe (Windows 原生) ===" -ForegroundColor Cyan
Write-Host "时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Write-Host ""

# ---------- 1. PCI 设备 ----------
Write-Host "--- 1. PCI 设备 (VEN_1EC8=Innosilicon/芯动, DEV_9810=G0M) ---" -ForegroundColor Green
try {
  $pnp = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
         Where-Object { $_.InstanceId -match "VEN_1EC8" -and $_.Status -in @("OK","Unknown") }
  if ($pnp) {
    $pnp | ForEach-Object { Write-Host "  FOUND: $($_.FriendlyName)  [$($_.InstanceId)]  Status=$($_.Status)" }
  } else {
    # 兜底: 全量搜
    $got = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match "VEN_1EC8" }
    if ($got) { $got | ForEach-Object { Write-Host "  (offline?) $($_.FriendlyName) [$($_.InstanceId)] $($_.Status)" } }
    else { Write-Host "  (未发现 1EC8 设备)" }
  }
  $vid = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
         Where-Object { $_.PNPDeviceID -match "VEN_1EC8" }
  if ($vid) { Write-Host "  VideoCard: $($vid.Name) | Driver: $($vid.DriverVersion)" }
} catch { Write-Host "  PCI 探测失败: $_" }

# ---------- 2. 驱动文件 ----------
Write-Host ""
Write-Host "--- 2. 驱动目录 (DriverStore) ---" -ForegroundColor Green
$ds = "$env:SystemRoot\System32\DriverStore\FileRepository"
try {
  Get-ChildItem $ds -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match "1ec8|fh2m|fant" } |
    ForEach-Object { Write-Host "  $($_.Name)" }
  # OpenCL ICD 文件搜索
  $icd = Get-ChildItem $ds -Recurse -Filter "*fh2m*.icd" -ErrorAction SilentlyContinue
  if ($icd) { $icd | ForEach-Object { Write-Host "  OpenCL ICD: $($_.FullName)" } }
} catch { Write-Host "  (DriverStore 不可读, 跳过)" }

# ---------- 3. OpenCL/Vulkan ICD 注册表 ----------
Write-Host ""
Write-Host "--- 3. ICD 注册表 ---" -ForegroundColor Green
$paths = @(
  "HKLM:\SOFTWARE\Khronos\OpenCL\Vendors",
  "HKLM:\SOFTWARE\Khronos\Vulkan\ICD",
  "HKLM:\SOFTWARE\Khronos\Vulkan\ExplicitLayers"
)
foreach ($p in $paths) {
  Write-Host "  [$p]"
  try {
    $k = Get-Item $p -ErrorAction Stop
    foreach ($v in $k.GetValueNames()) { Write-Host "    $v  =>  $($k.GetValue($v))" }
    if (!$k.GetValueNames()) { Write-Host "    (空)" }
  } catch { Write-Host "    (不存在)" }
}

# ---------- 4. OpenCL 枚举 (P/Invoke OpenCL.dll) ----------
# CL 常量
$CL_PLATFORM_NAME        = 0x0902
$CL_PLATFORM_VERSION     = 0x0903
$CL_DEVICE_TYPE          = 0x1000
$CL_DEVICE_NAME          = 0x102B
$CL_DEVICE_VENDOR        = 0x102C
$CL_DEVICE_VERSION       = 0x102F
$CL_DEVICE_MAX_COMPUTE_UNITS = 0x102D
$CL_DEVICE_GLOBAL_MEM_SIZE  = 0x1020
$CL_DEVICE_HALF_FP_CONFIG   = 0x1033
$CL_DEVICE_MAX_CLOCK_FREQUENCY = 0x103C
$CL_DEVICE_TYPE_GPU       = 4L
$CL_DEVICE_TYPE_ALL       = [long]0xFFFFFFFF

Write-Host ""
Write-Host "--- 4. OpenCL 平台/设备 (P/Invoke) ---" -ForegroundColor Green
$ocl = "$env:SystemRoot\System32\OpenCL.dll"
if (!(Test-Path $ocl)) { Write-Host "  OpenCL.dll 不存在 -> G0M 未装 OpenCL 运行时 (或驱动无 ICD)" }
else {
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class CL {
  [DllImport("OpenCL.dll")] public static extern int clGetPlatformIDs(uint n, IntPtr[] p, out uint m);
  [DllImport("OpenCL.dll")] public static extern int clGetPlatformInfo(IntPtr p, uint name, uint size, IntPtr val, out uint sret);
  [DllImport("OpenCL.dll")] public static extern int clGetDeviceIDs(IntPtr p, long type, uint n, IntPtr[] d, out uint m);
  [DllImport("OpenCL.dll")] public static extern int clGetDeviceInfo(IntPtr d, uint name, uint size, IntPtr val, out uint sret);
}
"@

  $np = 0
  $rc = [CL]::clGetPlatformIDs(0, $null, [ref]$np)
  Write-Host "  clGetPlatformIDs rc=$rc 平台数=$np"
  if ($np -eq 0) { Write-Host "  (无 OpenCL 平台)" }
  else {
    $plats = New-Object IntPtr[] $np
    [void][CL]::clGetPlatformIDs($np, $plats, [ref]$np)
    foreach ($plat in $plats) {
      # 平台信息串
      $buf = New-Object byte[] 1024
      $gch = [GCHandle]::Alloc($buf, [GCHandleType]::Pinned)
      $ptr = $gch.AddrOfPinnedObject()
      try {
        $sr = 0
        [void][CL]::clGetPlatformInfo($plat, $CL_PLATFORM_NAME, [uint]$buf.Length, $ptr, [ref]$sr)
        $pname = [Text.Encoding]::ASCII.GetString($buf, 0, $sr)
        $sr = 0
        [void][CL]::clGetPlatformInfo($plat, $CL_PLATFORM_VERSION, [uint]$buf.Length, $ptr, [ref]$sr)
        $pver = [Text.Encoding]::ASCII.GetString($buf, 0, $sr)
        Write-Host "  Platform: $pname  ($pver)"

        # 设备(GPU 优先, 全枚举兜底)
        $nd = 0
        $rc2 = [CL]::clGetDeviceIDs($plat, $CL_DEVICE_TYPE_GPU, 0, $null, [ref]$nd)
        if ($rc2 -ne 0 -or $nd -eq 0) { $rc2 = [CL]::clGetDeviceIDs($plat, $CL_DEVICE_TYPE_ALL, 0, $null, [ref]$nd) }
        Write-Host "    设备数=$nd (rc=$rc2)"
        if ($nd -gt 0) {
          $devs = New-Object IntPtr[] $nd
          $rc2 = [CL]::clGetDeviceIDs($plat, $CL_DEVICE_TYPE_GPU, [uint]$nd, $devs, [ref]$nd)
          if ($rc2 -ne 0) { $rc2 = [CL]::clGetDeviceIDs($plat, $CL_DEVICE_TYPE_ALL, [uint]$nd, $devs, [ref]$nd) }
          foreach ($dev in $devs) {
            function Get-CLString([IntPtr]$handle, [uint]$pname) {
              $b = New-Object byte[] 2048
              $h = [GCHandle]::Alloc($b, [GCHandleType]::Pinned)
              $p = $h.AddrOfPinnedObject()
              $r = 0
              try { [void][CL]::clGetDeviceInfo($handle, $pname, [uint]$b.Length, $p, [ref]$r)
                return [Text.Encoding]::ASCII.GetString($b, 0, $r) }
              finally { $h.Free() }
            }
            function Get-CL64([IntPtr]$handle, [uint]$pname) {
              $b = New-Object byte[] 16
              $h = [GCHandle]::Alloc($b, [GCHandleType]::Pinned)
              $p = $h.AddrOfPinnedObject()
              $r = 0
              try { [void][CL]::clGetDeviceInfo($handle, $pname, [uint]$b.Length, $p, [ref]$r)
                return [BitConverter]::ToUInt64($b, 0) }
              finally { $h.Free() }
            }
            $dt = Get-CL64 $dev $CL_DEVICE_TYPE
            $name = Get-CLString $dev $CL_DEVICE_NAME
            $dver = Get-CLString $dev $CL_DEVICE_VERSION
            $un = Get-CL64 $dev $CL_DEVICE_MAX_COMPUTE_UNITS
            $mem = Get-CL64 $dev $CL_DEVICE_GLOBAL_MEM_SIZE
            $mhz = Get-CL64 $dev $CL_DEVICE_MAX_CLOCK_FREQUENCY
            $fp16 = Get-CL64 $dev $CL_DEVICE_HALF_FP_CONFIG
            Write-Host "    Device: $name ($dver)"
            Write-Host "      type=GPU?$((($dt -band $CL_DEVICE_TYPE_GPU) -ne 0))  compute_units=$un  clock=$mhz MHz"
            Write-Host "      GLOBAL_MEM_SIZE=$mem bytes = $([Math]::Round($mem/1GB,2)) GB"
            Write-Host "      HALF_FP_CONFIG=$fp16 (0=不支持fp16, 非0=支持)"
          }
        }
      } finally { $gch.Free() }
    }
  }
}

Write-Host ""
Write-Host "=== 完成。把以上输出原样贴回给 sram ===" -ForegroundColor Cyan