#!/usr/bin/env bash
# 液态玻璃的离线测试（不需要真机）
#   bash tests/glass/run.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../../src/FDMProbe5"
OUT="$HERE/.build"
mkdir -p "$OUT"
gcc -O2 -Wall -Wextra -std=c11 -I"$SRC" -o "$OUT/test_glass" \
    "$HERE/test_glass.c" "$SRC/FDMGlassPolicy.c" || exit 1
"$OUT/test_glass"
