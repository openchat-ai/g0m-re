#!/usr/bin/env bash
# fetch-driver.sh — G0M 驱动包获取 (修正版, 已勘察官方 API)
#
# 已确认的事实:
#   - 官方驱动站 fantasyxpu.com 仅覆盖 "风华 1/2/3号" (消费级品牌),
#     产品树 getProTree 里没有 G0M / 9810 / 9800 / innogpu / 仙境 任何一项。
#   - API 只认一个字段 product_id (三级树上最后一级"CPU架构"叶子 id), 其他字段一律 422。
#     树: 风华1号(26)→统信(39)→ARM(40) | 风华2号(1)→Windows(15)→X86(22) | 风华3号(41)→...→(43/50/52)
#   - G0M = ODM 整机卡 (VEN_1EC8 DEV_9810 → innogpu.inf), 驱动走整机商(OEM)渠道,
#     不在 Fantasy XPU 站。备份方案: 讯联/曙光/整机商驱动包, 或 Treexy innogpu.inf。
#
# 用法:
#   bash fetch-driver.sh tree     # 拉官方产品树
#   bash fetch-driver.sh probe    # 用正确字段试所有叶子 product_id, 列出每个叶子的驱动
#   bash fetch-driver.sh dl <id>  # 用 probe 输出的文件 id 下载

set -uo pipefail
BASE="https://www.fantasyxpu.com:8060"
OUTDIR="$(cd "$(dirname "$0")/.." && pwd)/drivers"

case "${1:-}" in
  tree)
    curl -sk "$BASE/home/drive/getProTree" | head -c 4000; echo
    ;;
  probe)
    for pid in 22 25 30 32 33 35 36 40 43 48 50 52; do
      echo "--- product_id=$pid ---"
      curl -sk -X POST "$BASE/home/drive/index" -d "product_id=$pid" \
        | python3 -c 'import sys,json;
try:
  d=json.load(sys.stdin)
  for it in d.get("data") or []:
    print(it["file_name"], it["file_size"], it["file_url"], it.get("description","")[:60].replace("\\n"," "))
except Exception as e: print("ERR",e)' 2>/dev/null || echo "(无驱动或解析失败)"
    done
    ;;
  dl)
    ID="${2:-}"
    [ -z "$ID" ] && { echo "用法: bash fetch-driver.sh dl <file_url 或 id>"; exit 1; }
    mkdir -p "$OUTDIR"
    if echo "$ID" | grep -q '^https\?://'; then
      curl -sk -o "$OUTDIR/$(basename "$ID")" "$ID" && echo "已下载: $OUTDIR/$(basename "$ID")"
    else
      curl -sk -X POST "$BASE/upload" -d "id=$ID" > "$OUTDIR/$ID.bin" 2>/dev/null \
        || echo "download 接口需整站 JS 会话, 建议直接用 probe 输出的 file_url."
    fi
    ;;
  *)
    echo "用法: bash fetch-driver.sh {tree|probe|dl <file_url>}"
    exit 1
    ;;
esac