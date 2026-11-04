#!/bin/bash
# A0-b 本地模型环境（可复现）：uv venv + PyPI 镜像 + hf-mirror 权重。
# 用法：./setup-a0b-local.sh [base|large]
# 产物在 ~/.astfind/a0b（模型/venv 不提交仓库；磁盘约 2.5GB/base、4.5GB/large）。
set -euo pipefail

VARIANT="${1:-base}"
ROOT="${ASTFIND_A0B_HOME:-$HOME/.astfind/a0b}"
PYPI="${A0B_PYPI_MIRROR:-https://pypi.tuna.tsinghua.edu.cn/simple}"
HF="${A0B_HF_MIRROR:-https://hf-mirror.com}"

if [ "$VARIANT" = "large" ]; then
  REPO="OFA-Sys/chinese-clip-vit-large-patch14"
  DIR="$ROOT/chinese-clip-vit-l14"
else
  REPO="OFA-Sys/chinese-clip-vit-base-patch16"
  DIR="$ROOT/chinese-clip-vit-b16"
fi

mkdir -p "$ROOT" "$DIR"
if [ ! -x "$ROOT/.venv/bin/python" ]; then
  echo "== venv =="
  uv venv --python 3.11 "$ROOT/.venv"
fi
echo "== python deps =="
uv pip install --python "$ROOT/.venv/bin/python" --index-url "$PYPI" \
  "torch==2.5.1" "transformers==4.46.3" pillow numpy

echo "== model files: $REPO =="
for file in config.json preprocessor_config.json vocab.txt; do
  [ -s "$DIR/$file" ] || curl -sSL --max-time 120 -o "$DIR/$file" "$HF/$REPO/resolve/main/$file"
done
if [ ! -s "$DIR/pytorch_model.bin" ]; then
  curl -L --retry 5 --retry-delay 3 --retry-all-errors --max-time 1800 \
    -o "$DIR/pytorch_model.bin" "$HF/$REPO/resolve/main/pytorch_model.bin"
fi

echo "OK: $DIR"
echo "Benchmark:"
echo "  TRANSFORMERS_OFFLINE=1 $ROOT/.venv/bin/python AstfindKit/scripts/a0/a0b-local-bench.py \\"
echo "    --model-dir $DIR --per-source 300 --out AstfindKit/scripts/a0/a0b-results.json"
echo "Server:"
echo "  $ROOT/.venv/bin/python AstfindKit/scripts/a0/a0b-local-server.py --model-dir $DIR --port 8099"
