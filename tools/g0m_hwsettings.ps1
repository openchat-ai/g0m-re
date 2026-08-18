<#
g0m_hwsettings.ps1 - G0M (Fantasy II-M) 驱动注册表配置工具

背景:
  G0M 的 Windows 驱动是 IMG PowerVR EURASIA 血统, 内置注册表配置通道:
    HKLM\SYSTEM\CurrentControlSet\Services\powervr\PowerVREurasia\HWSettings\
      子键 PVRLDDMKMD  -> 内核驱动 (KMD) 配置
      子键 PVRLDDMUMD  -> 用户态驱动 (UMD) 配置
  驱动启动时读取其中的 DWORD 开关, 可手动调整内存分配行为
  (哪些对象进 GTT/系统内存, 哪些常驻板载 4GB 等).

用法 (管理员 PowerShell):
  .\g0m_hwsettings.ps1                      交互菜单: 编号选择开关, 设 0/1 或删
  .\g0m_hwsettings.ps1 list                 列出 KMD/UMD 当前全部配置
  .\g0m_hwsettings.ps1 get  <名字|别名>      读取某选项 (两个键都查)
  .\g0m_hwsettings.ps1 set  <名字|别名> <值>  写 DWORD (别名自动选键, 否则默认 KMD)
  .\g0m_hwsettings.ps1 del  <名字|别名>      删除选项
  .\g0m_hwsettings.ps1 backup               导出 .reg 备份到脚本同目录
  .\g0m_hwsettings.ps1 known                打印候选开关名 + 别名表

别名表 (记短名即可, 中文释义见 known):
  gttdma, gttaperture, gttallow, offerreclaim, constvram,
  vbsysmem, alwaysresident, stagingcache, glgtt, glgttalloc, cbufgtt

  Scope: KMD|UMD, 对应 PVRLDDMKMD / PVRLDDMUMD 子键.

提示:
  - 修改后需重启显卡驱动才生效 (设备管理器禁用/启用, 或重启系统).
  - 闭源驱动选项名是从二进制字符串/符号推断, 不保证每个都被注册表读取;
    `set` 前建议先 `known` 对照, 并用 probe 或 dxdiag 验证效果.
  - 所有 HKLM 写入需管理员权限.

作者: sram (g0m-re 项目)
#>

param(
  [Parameter(Position=0)] [ValidateSet("list","get","set","del","backup","known","menu")]
  [string]$Action = "menu",
  [Parameter(Position=1)] [string]$Name,
  [Parameter(Position=2)] [string]$Value,
  [Parameter()] [ValidateSet("KMD","UMD")] [string]$Scope = "KMD"
)

$ErrorActionPreference = "Stop"

$Root = "HKLM:\SYSTEM\CurrentControlSet\Services\powervr\PowerVREurasia\HWSettings"
$Keys = @{
  KMD = Join-Path $Root "PVRLDDMKMD"
  UMD = Join-Path $Root "PVRLDDMUMD"
}

$Aliases = @{
  "gttdma"       = @{ Name = "ForceGTTWriteWithAXIDMA";          Scope = "KMD"; Desc = "GTT 写入强制走 AXI DMA" }
  "gttaperture"  = @{ Name = "ForceNonsurfaceInApertureSegment"; Scope = "KMD"; Desc = "非表面分配强制放 GTT 段(系统内存)" }
  "gttallow"     = @{ Name = "SupportAllocationInApertureSegment"; Scope = "KMD"; Desc = "允许分配进 GTT 段" }
  "offerreclaim" = @{ Name = "DisableOfferReclaim";              Scope = "UMD"; Desc = "关闭 WDDM offer/reclaim" }
  "constvram"    = @{ Name = "ForceConstantsMemory";             Scope = "UMD"; Desc = "常量缓冲强制进板载显存" }
  "vbsysmem"     = @{ Name = "ForceVbIbNonlocal";                Scope = "UMD"; Desc = "顶点/索引缓冲强制放系统内存" }
  "alwaysresident" = @{ Name = "ForceAlwaysResident";            Scope = "UMD"; Desc = "所有分配强制常驻(不淘汰)" }
  "stagingcache" = @{ Name = "EnableCacheableStaging";           Scope = "UMD"; Desc = "暂存缓冲允许 cacheable" }
  "glgtt"        = @{ Name = "GLUseGttForBuffer";                Scope = "UMD"; Desc = "OpenGL 缓冲走 GTT" }
  "glgttalloc"   = @{ Name = "EnableAllocGttMem";                Scope = "UMD"; Desc = "OpenGL 允许分配 GTT 内存" }
  "cbufgtt"      = @{ Name = "CbufAllocGtt";                     Scope = "UMD"; Desc = "常量缓冲分配在 GTT" }
}

function Resolve-Name([string]$n) {
  if ($Aliases.ContainsKey($n.ToLower())) { return $Aliases[$n.ToLower()] }
  $real = $n -replace "^-", ""
  $hit = $Aliases.Values | Where-Object { $_.Name -ieq $real }
  if ($hit) { return $hit }
  return $null
}

function Get-IsAdmin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

function Show-Menu {
  $opts = $Aliases.GetEnumerator() | Sort-Object Key
  while ($true) {
    Write-Host ""
    Write-Host "=== G0M 显存分配配置 (HWSettings) ===" -ForegroundColor Cyan
    $i = 0
    foreach ($e in $opts) {
      $i++
      $d = $e.Value
      $p = $Keys[$d.Scope]
      $cur = "(未设)"
      try { $cv = (Get-Item $p -ErrorAction Stop).GetValue($d.Name, $null); if ($null -ne $cv) { $cur = $cv } } catch {}
      Write-Host ("  {0,2}. {1,-15} {2,-8} [{3}]  {4}" -f $i, $e.Key, $cur, $d.Scope, $d.Desc)
    }
    Write-Host ("  {0,2}. 查看当前完整配置 (list)" -f ($i+1))
    Write-Host ("  {0,2}. 备份配置到 .reg (backup)" -f ($i+2))
    Write-Host ("  {0,2}. 退出" -f ($i+3))
    $sel = Read-Host "  输入编号选择要设置的项"
    if ($sel -eq ($i+1)) { Read-Key KMD; Read-Key UMD; continue }
    if ($sel -eq ($i+2)) { Invoke-Backup; continue }
    if ($sel -eq ($i+3)) { return }
    $idx = 0
    if ([int]::TryParse($sel, [ref]$idx) -and $idx -ge 1 -and $idx -le $i) {
      $e = @($opts)[$idx-1]
      $d = $e.Value
      Write-Host ""
      Write-Host ("  选中: {0} → {1} [{2}]  {3}" -f $e.Key, $d.Name, $d.Scope, $d.Desc)
      $p = $Keys[$d.Scope]
      try { $cv = (Get-Item $p -ErrorAction Stop).GetValue($d.Name, $null) } catch { $cv = $null }
      $curS = if ($null -ne $cv) { "$cv" } else { "(未设)" }
      Write-Host ("  当前值: {0}" -f $curS)
      $v = Read-Host "  输入 0/1 (回车=1 设置, 直接按 n 删除)"
      if ($v -ieq "n" -or $v -ieq "del") {
        if (!(Get-IsAdmin)) { Write-Host "  需要管理员权限!" -ForegroundColor Red; continue }
        Remove-ItemProperty -Path $p -Name $d.Name -ErrorAction SilentlyContinue
        Write-Host "  已删除 [$($d.Scope)] $($d.Name)" -ForegroundColor Green
      } elseif ($v -match "^\d+$") {
        if (!(Get-IsAdmin)) { Write-Host "  需要管理员权限!" -ForegroundColor Red; continue }
        $val = if ($v -eq "") { 1 } else { [int]$v }
        New-Item -Path $p -Force | Out-Null
        Set-ItemProperty -Path $p -Name $d.Name -Value $val -Type DWord
        Write-Host "  已设置 [$($d.Scope)] $($d.Name) = $val" -ForegroundColor Green
        Write-Host "  提示: 重启显卡驱动或重启系统后生效." -ForegroundColor DarkGray
      } else {
        Write-Host "  输入无效, 跳过" -ForegroundColor Yellow
      }
    } else {
      Write-Host "  无效编号" -ForegroundColor Yellow
    }
  }
}

function Write-Known {
  Write-Host "别名 (可直接用于 set/get/del) → 真实注册表名:" -ForegroundColor Cyan
  Write-Host ""
  $Aliases.GetEnumerator() | Sort-Object Key | ForEach-Object {
    $a = $_.Key; $d = $_.Value
    Write-Host ("  {0,-15} → {1,-40} [{2}]  {3}" -f $a, $d.Name, $d.Scope, $d.Desc)
  }
  Write-Host ""
  Write-Host "其余候选(无别名, 慎用):" -ForegroundColor DarkGray
  $known = @(
    "innokmd64.sys (KMD): ForceGTTWriteWithAXIDMA|ForceNonsurfaceInApertureSegment|SupportAllocationInApertureSegment|DisableDynamicVoltageScaling|DisableVirtualFill|ForcedWddmVersion|ForceDummyKickInPdump|ForceBreakOnResetHW",
    "innoumd64.dll (UMD): DisableOfferReclaim|ForceConstantsMemory|ForceVbIbNonlocal|ForceAlwaysResident|EnableCacheableStaging|ForceFlushMemCacheable|ForceFlushMemNonlocal|DisableDynamicConstants|EnableDynamicSurfaceRenaming|EnableDecoder|EnableEncoder",
    "innoogl64.dll (GL): EnableAllocGttMem|EnableAllocInvMem|GLUseGttForBuffer|CbufAllocGtt|CBufferPoolSizeMax|CBufferPoolSizeMin|GLOptCCBuffersPool|GLOptVBuffers"
  )
  $known | ForEach-Object { Write-Host "  $_" }
  Write-Host ""
  Write-Host "  参考: docs/probe-log.md (2026-08-18 Windows 真机探针复核章节)" -ForegroundColor DarkGray
}

function Read-Key([string]$scope) {
  $p = $Keys[$scope]
  Write-Host "  [$scope] $p" -ForegroundColor DarkGray
  try {
    $k = Get-Item $p -ErrorAction Stop
    if (!$k.GetValueNames()) { Write-Host "    (空键)" }
    foreach ($n in $k.GetValueNames()) {
      $v = $k.GetValue($n)
      $t = if ($v -is [byte[]]) { "[bytes $($v.Length)]" } else { $v }
      Write-Host "    $n = $t"
    }
  } catch { Write-Host "    (不存在)" }
}

switch ($Action) {
  "list" {
    if (!(Test-Path $Root)) { Write-Host "HWSettings 根键不存在: $Root" -ForegroundColor Yellow; exit 1 }
    Write-Host "=== G0M HWSettings 当前配置 ===" -ForegroundColor Cyan
    Read-Key KMD
    Read-Key UMD
  }
  "get" {
    if (!$Name) { Write-Host "用法: g0m_hwsettings.ps1 get <名字|别名>" -ForegroundColor Yellow; exit 1 }
    $opt = Resolve-Name $Name
    $real = if ($opt) { $opt.Name } else { $Name }
    foreach ($scope in @("KMD","UMD")) {
      $p = $Keys[$scope]
      try {
        $k = Get-Item $p -ErrorAction Stop
        $v = $k.GetValue($real, $null)
        if ($null -ne $v) { Write-Host "  [$scope] $real = $v" }
        else { Write-Host "  [$scope] $real = (未设置)" -ForegroundColor DarkGray }
      } catch { Write-Host "  [$scope] (键不存在)" -ForegroundColor DarkGray }
    }
  }
  "set" {
    if (!(Get-IsAdmin)) { Write-Host "写入 HKLM 需要管理员权限!" -ForegroundColor Red; exit 1 }
    if (!$Name -or $null -eq $Value) { Write-Host "用法: g0m_hwsettings.ps1 set <名字|别名> <值> [-Scope KMD|UMD]" -ForegroundColor Yellow; exit 1 }
    if ($Value -notmatch "^-?\d+$") { Write-Host "值必须是整数 (0/1 或其他 DWORD): '$Value'" -ForegroundColor Yellow; exit 1 }
    $opt = Resolve-Name $Name
    $real = if ($opt) { $opt.Name } else { $Name }
    if ($opt) { $Scope = $opt.Scope }
    $p = $Keys[$Scope]
    New-Item -Path $p -Force | Out-Null
    Set-ItemProperty -Path $p -Name $real -Value ([int]$Value) -Type DWord
    $hint = if ($opt) { "  别名 $($opt.Name) → $($opt.Desc)" } else { "" }
    Write-Host "已写入 [$Scope] $real = $Value$hint" -ForegroundColor Green
    Write-Host "提示: 重启显卡驱动或重启系统后生效." -ForegroundColor DarkGray
  }
  "del" {
    if (!(Get-IsAdmin)) { Write-Host "写入 HKLM 需要管理员权限!" -ForegroundColor Red; exit 1 }
    if (!$Name) { Write-Host "用法: g0m_hwsettings.ps1 del <名字|别名> [-Scope KMD|UMD]" -ForegroundColor Yellow; exit 1 }
    $opt = Resolve-Name $Name
    $real = if ($opt) { $opt.Name } else { $Name }
    if ($opt) { $Scope = $opt.Scope }
    $p = $Keys[$Scope]
    if (Test-Path $p) {
      try {
        Remove-ItemProperty -Path $p -Name $real -ErrorAction Stop
        Write-Host "已删除 [$Scope] $Name" -ForegroundColor Green
      } catch { Write-Host "删除失败: $_" -ForegroundColor Red }
    } else { Write-Host "[$Scope] 键不存在, 无需删除" -ForegroundColor DarkGray }
  }
  "backup" { Invoke-Backup }
  "known" { Write-Known }
  "menu" { Show-Menu }
}

function Invoke-Backup {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $out = Join-Path $PSScriptRoot "hwsettings-$stamp.reg"
  & reg.exe export $Root $out /y 2>$null | Out-Null
  if (Test-Path $out) { Write-Host "备份完成: $out" -ForegroundColor Green }
  else { Write-Host "备份失败 (reg export 出错)" -ForegroundColor Red }
}