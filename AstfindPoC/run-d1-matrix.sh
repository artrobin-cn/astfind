#!/bin/bash
# Astfind D1 · 真实 SMB 一键实验矩阵
# 用法: ./run-d1-matrix.sh <SMB挂载点> [规模: 10000|100000]
# 前置: 挂载点存在且可写; astfind-smb-poc 已构建 (debug)
set -uo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
BIN=./.build/debug/astfind-smb-poc
ROOT="${1:?用法: run-d1-matrix.sh <SMB挂载点> [规模]}"
COUNT="${2:-10000}"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="/tmp/astfind-d1-nas-$STAMP"
MAN=$OUT/manifest.tsv; DB=$OUT/index.oilfind
SUB="$ROOT/astfind-d1-$$"

[ -x "$BIN" ] || { echo "先构建: swift build"; exit 2; }
[ -d "$ROOT" ] || { echo "挂载点不存在: $ROOT"; exit 2; }
touch "$ROOT/.astfind-write-test" 2>/dev/null && rm "$ROOT/.astfind-write-test" || { echo "挂载点不可写（只读共享?）——仍可扫描，生成/变更实验将失败"; }

mkdir -p "$OUT"
echo "== D1 NAS matrix: root=$ROOT count=$COUNT out=$OUT =="

echo "--- [1/7] generate on share (POC-02 数据准备, 记录 SMB 写吞吐) ---"
time $BIN generate "$SUB" "$COUNT" --manifest "$MAN" || exit 1

echo "--- [2/7] first scan (POC-02 首扫) ---"
$BIN scan "$SUB" "$DB" || exit 1

echo "--- [3/7] offline: 源目录在共享上改名移走(等效卸载), 验证进程级重启+离线查询 ---"
mv "$SUB" "$SUB-away" || exit 1
$BIN offline "$SUB" "$DB" "$MAN" --sample 200 --runs 50 || { mv "$SUB-away" "$SUB"; exit 1; }
mv "$SUB-away" "$SUB"

echo "--- [4/7] second-client mutate (POC-06) ---"
$BIN mutate "$SUB" $OUT/changes.tsv --manifest "$MAN" --add 100 --rename 20 --delete 50 || exit 1

echo "--- [5/7] rescan convergence (POC-06, 完整重扫语义) ---"
$BIN sync "$SUB" "$DB" "$MAN" --rescan || exit 1

echo "--- [6/7] interrupted rescan safety (POC-03 中断注入) ---"
$BIN scan "$SUB" "$DB" --kill-at-count $((COUNT / 4))
echo "kill exit=$? (137=SIGKILL 预期)"
mv "$SUB" "$SUB-away" || exit 1
$BIN offline "$SUB" "$DB" "$MAN" --sample 100 --runs 10 || { mv "$SUB-away" "$SUB"; exit 1; }
mv "$SUB-away" "$SUB"

echo "--- [7/7] reconnect: 卸载后换挂载点名重挂, 然后运行: ---"
echo "  $BIN reconnect <旧挂载点> <新挂载点> $DB $MAN"
echo "(真实卸载: Finder 弹出卷, 或 sudo umount <挂载点>)"

echo "== 完成. 结果目录: $OUT =="
echo "真实断网/重挂载/弱网场景按 D1 报告 §4 清单人工配合执行"
