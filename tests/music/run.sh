#!/usr/bin/env bash
# 音乐内核离线测试（完全不需要真机）
#
#   bash tests/music/run.sh            # 只跑 C 侧自检 + 对拍向量
#   bash tests/music/run.sh --java     # 额外跑 Java 参考实现，打印基准向量
#   bash tests/music/run.sh --net      # 额外打一次真实网易云搜索（验证协议还活着）
#
# 为什么有这套东西：
#   加密 / LRC / 变量替换三块都是**纯算法**，能在小窝里做到"确定性正确"。
#   真机只负责验证「网络层 + UI」，不负责验证算法。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../../src/FDMProbe5"
OUT="$HERE/.build"
CC="${CC:-gcc}"
CFLAGS="-O2 -Wall -Wextra -std=c11 -I$SRC"

mkdir -p "$OUT"
fail=0

say() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

say "1/3 加密层（AES/MD5/Base64/RSA-eapi-weapi）"
"$CC" $CFLAGS -o "$OUT/test_crypto" "$HERE/test_crypto.c" \
      "$SRC/FDMMusicCrypto.c" -lcrypto || { echo "编译失败"; exit 1; }
"$OUT/test_crypto" || fail=1

say "2/3 提示词变量引擎"
"$CC" $CFLAGS -o "$OUT/test_pv" "$HERE/test_pv.c" "$SRC/FDMPromptVars.c" || { echo "编译失败"; exit 1; }
"$OUT/test_pv" || fail=1

say "3/3 LRC 歌词引擎"
"$CC" $CFLAGS -o "$OUT/test_lyric" "$HERE/test_lyric.c" "$SRC/FDMLyric.c" || { echo "编译失败"; exit 1; }
"$OUT/test_lyric" || fail=1

if [[ "${1:-}" == "--java" ]]; then
    say "附加：Java 参考实现基准向量（真跑 GmMusicCrypto.java）"
    MOD=/workspace/mod-src/src
    if [[ -d "$MOD" ]]; then
        JB="$OUT/java"
        mkdir -p "$JB/src" "$JB/out"
        cp "$MOD/com/nidyaber/fuckdsmanger/music/GmMusicCrypto.java" \
           "$MOD/com/nidyaber/fuckdsmanger/music/GmMusicJson.java" "$JB/src/" 2>/dev/null || true
        # 这两个文件带 package 声明，需要目录结构
        mkdir -p "$JB/src/com/nidyaber/fuckdsmanger/music"
        mv "$JB/src/GmMusicCrypto.java" "$JB/src/GmMusicJson.java" \
           "$JB/src/com/nidyaber/fuckdsmanger/music/" 2>/dev/null || true
        cp "$MOD/com/nidyaber/fuckdsmanger/music/GmMusicApi.java" \
           "$JB/src/com/nidyaber/fuckdsmanger/music/" 2>/dev/null || true
        if [[ -f "$HERE/CryptoVec.java" ]]; then
            cp "$HERE/CryptoVec.java" "$JB/src/"
            javac -encoding UTF-8 -d "$JB/out" $(find "$JB/src" -name '*.java') 2>/dev/null \
              && java -cp "$JB/out" CryptoVec
        else
            echo "（缺 CryptoVec.java，跳过）"
        fi
    else
        echo "（找不到 $MOD，跳过）"
    fi
fi

if [[ "${1:-}" == "--net" ]]; then
    say "附加：协议活性（Java 真发请求）"
    echo "用 /workspace/ios-port/tmp/musictest 里的 MusicSmoke，或直接："
    echo "  cd /workspace/ios-port/tmp/musictest && java -cp out MusicSmoke"
fi

if [[ $fail -eq 0 ]]; then
    printf '\n\033[32m全部通过 ✅\033[0m\n'
else
    printf '\n\033[31m有失败 ✗\033[0m\n'
fi
exit $fail
