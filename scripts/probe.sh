#!/usr/bin/env bash
# probe.sh — [0] 探针: G0M 驱动到底暴不暴露计算 ICD (OpenCL / Vulkan)
#
# 目标: 不逆向、不猜, 用驱动自报的能力回答 "G0M 有没有可能跑 LLM 计算"。
# 运行环境: 工作站 (Windows 或 Linux)。
#
# 原理:
#   - OpenCL ICD 存在 → clinfo 会列出非 CPU 平台 (G0M 的 IGX 之类)
#   - Vulkan ICD 存在 → vulkaninfo 会列出 G0M 设备
#   - 都没有 → 办公/显示卡实锤, 直接走决策树分支 [C], 不再逆向
#
# 用法:
#   bash probe.sh            # Windows(Linux shell) 或 Linux
#   bash probe.sh --write    # 把输出归档进 ../docs/probe-log.md

set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="${DIR}/../docs/probe-log.md"

run() {
  echo
  echo "### $1"
  echo '```'
  eval "$2" 2>&1 || echo "(命令不可用/无输出)"
  echo '```'
}

echo "# G0M probe-log ($(date '+%Y-%m-%d %H:%M'))"
echo

if command -v clinfo >/dev/null 2>&1; then
  run "clinfo — 平台与设备列表" "clinfo -l; echo; clinfo | grep -iE 'Number of platforms|Platform Name|Platform Vendor|Device Name|Device Type' | head -30"
else
  echo "## clinfo 未安装 (可装: apt install clinfo; OpenCL 运行时一般随驱动带 libOpenCL)"
fi

echo "## ICD 文件 (OpenCL/Vulkan 加载器会读这些; FANT_fh2m 存在 = 有计算栈)"
echo '```'
ls -la /etc/OpenCL/vendors/ 2>/dev/null || echo "(无 /etc/OpenCL/vendors)"
ls -la /etc/vulkan/icd.d/ 2>/dev/null | grep -i 'fant\|inno' || echo "(无 FANT Vulkan ICD)"
ls /usr/lib/x86_64-linux-gnu/fantgpu-fh2m/ 2>/dev/null | head -5 || echo "(无 fh2m UMD)"
echo '```'

if command -v vulkaninfo >/dev/null 2>&1; then
  run "vulkaninfo — GPU 设备" "vulkaninfo --summary 2>/dev/null | grep -iE 'deviceName|driverName|apiVersion|deviceType' | head -30"
else
  echo "## vulkaninfo 未安装"
fi

run "PCI 设备 (1EC8 = 芯动, 9810 = G0M)" \
  "lspci -nn 2>/dev/null | grep -i '1ec8\\|9810' || (echo 'lspci 不可用; Windows 用设备管理器查 VEN_1EC8&DEV_9810')"

run "驱动目录/文件 (Windows C:\\Windows\\System32\\DriverStore\\FileRepository 找 1ec8)" \
  "ls /d 'C:/Windows/System32/DriverStore/FileRepository' 2>/dev/null | grep -i '1ec8\\|innosilicon\\|g0m' | head; echo '--'; ls '/sys/class/drm/' 2>/dev/null"

echo
echo "## 判定"
echo "- 系统装了 fantgpu 驱动 + /etc/OpenCL/vendors/FANT_fh2m.icd + clinfo 列出 1EC8/G0M"
echo "  → 走分支 [B]: OpenCL 栈已被验证, 直接实测 (clinfo 全量参数, 再试 PoCL/llama ocl 后端)"
echo "- 有驱动但 ICD 未注册/枚举不出 G0M → 反查驱动安装配置, 仍优先 [B]"
echo "- 无驱动 / 全空 → 走分支 [C] 技能项目, 停止计算期望"
echo
echo "(此页内容由 probe.sh 生成; 有 --write 时归档)"

if [ "${1:-}" = "--write" ]; then
  TMP="$(mktemp)"
  bash "$0" > "$TMP" 2>&1 || true
  head -c $(($(wc -c < "$TMP") - 20)) "$TMP" > "$LOG"
  rm -f "$TMP"
  echo "已写入 $LOG"
fi