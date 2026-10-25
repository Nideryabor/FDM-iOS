#!/usr/bin/env bash
# 全部离线测试（不需要真机）
#   bash tests/run-all.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../src/FDMProbe5"
OUT="$HERE/.build"
CC="${CC:-gcc}"
CFLAGS="-O2 -Wall -Wextra -std=c11 -I$SRC"
mkdir -p "$OUT"
fail=0
pass=0

say() { printf '\n\033[1m══ %s ══\033[0m\n' "$1"; }
run() {
    local name="$1" bin="$2"
    if "$bin" > "$OUT/$name.log" 2>&1; then
        head -1 "$OUT/$name.log" | sed 's/^/  \033[32m✓\033[0m /'
        pass=$((pass+1))
    else
        printf '  \033[31m✗ %s\033[0m\n' "$name"
        sed 's/^/    /' "$OUT/$name.log" | head -20
        fail=$((fail+1))
    fi
}

say "1/6 音乐：加密层（与 Java 对拍）"
$CC $CFLAGS -o "$OUT/t_crypto" "$HERE/music/test_crypto.c" \
    "$SRC/FDMMusicCrypto.c" -lcrypto 2>"$OUT/cc1.log" \
  && run crypto "$OUT/t_crypto" || { echo "  编译失败"; cat "$OUT/cc1.log"|head -5; fail=$((fail+1)); }

say "2/6 音乐：提示词变量 / LRC / 播放内核"
$CC $CFLAGS -o "$OUT/t_pv" "$HERE/music/test_pv.c" "$SRC/FDMPromptVars.c" 2>/dev/null \
  && run pvar "$OUT/t_pv" || { echo "  编译失败"; fail=$((fail+1)); }
$CC $CFLAGS -o "$OUT/t_lyric" "$HERE/music/test_lyric.c" "$SRC/FDMLyric.c" 2>/dev/null \
  && run lyric "$OUT/t_lyric" || { echo "  编译失败"; fail=$((fail+1)); }
$CC $CFLAGS -o "$OUT/t_model" "$HERE/music/test_model.c" "$SRC/FDMMusicModel.c" 2>"$OUT/cc_model.log" \
  && run model "$OUT/t_model" || { echo "  编译失败"; head -5 "$OUT/cc_model.log"; fail=$((fail+1)); }

say "3/6 液态玻璃：性能分级"
$CC $CFLAGS -o "$OUT/t_glass" "$HERE/glass/test_glass.c" "$SRC/FDMGlassPolicy.c" 2>/dev/null \
  && run glass "$OUT/t_glass" || { echo "  编译失败"; fail=$((fail+1)); }

say "4/6 气泡：几何与锚点"
$CC $CFLAGS -o "$OUT/t_bubble" "$HERE/bubble/test_bubble.c" "$SRC/FDMBubbleStyle.c" 2>/dev/null \
  && run bubble "$OUT/t_bubble" || { echo "  编译失败"; fail=$((fail+1)); }

say "5/6 便签 + 文件快捷 + 卡片提示词"
$CC $CFLAGS -o "$OUT/t_note" "$HERE/note/test_note.c" "$SRC/FDMNoteModel.c" 2>/dev/null \
  && run note "$OUT/t_note" || { echo "  编译失败"; fail=$((fail+1)); }
$CC $CFLAGS -o "$OUT/t_fc" "$HERE/filecard/test_fc.c" "$SRC/FDMFileCard.c" 2>/dev/null \
  && run filecard "$OUT/t_fc" || { echo "  编译失败"; fail=$((fail+1)); }
$CC $CFLAGS -o "$OUT/t_pc" "$HERE/promptcard/test_promptcard.c" "$SRC/FDMPromptCard.c" 2>"$OUT/cc_pc.log" \
  && run promptcard "$OUT/t_pc" || { echo "  编译失败"; head -5 "$OUT/cc_pc.log"; fail=$((fail+1)); }

say "6/6 安全基线（口令不进 argv / 备份无明文）"
if bash "$HERE/security/test_secrets.sh" > "$OUT/secret.log" 2>&1; then
    tail -1 "$OUT/secret.log" | sed 's/^/  \033[32m✓\033[0m /'
    pass=$((pass+1))
else
    printf '  \033[31m✗ 安全基线\033[0m\n'
    sed 's/^/    /' "$OUT/secret.log" | head -20
    fail=$((fail+1))
fi

printf '\n────────────────────────────\n'
if [ $fail -eq 0 ]; then
    printf '\033[32m全部通过 ✅  共 %d 套\033[0m\n' $pass
else
    printf '\033[31m有失败 ✗  %d 套通过 / %d 套失败\033[0m\n' $pass $fail
fi
exit $fail
