// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMPromptVars —— 系统提示词里的「音乐变量」引擎（纯 C11，零依赖）
//
// 这是 `mod-src/src/com/nidyaber/fuckdsmanger/gm/GmPromptVars.java` 的逐条等价移植。
//
//   {music}        《歌名》 - 歌手 (1:23/3:42)     ← 没在听 = 空串
//   {music_or_none} 同上；总开关开着但真没在听 = "没有在听歌"
//   {song} {artist} {album}
//   {music_pos} {music_dur} {music_left}          ← mm:ss
//   {music_state}  playing / paused
//   {lyric} {lyric_prev} {lyric_next}             ← 受歌词开关保护（版权）
//
//   糖：`[[ … ]]` —— 块内有我们的变量且**全部为空** ⇒ 连块带括号删掉；
//       否则只脱掉 `[[ ]]` 两层壳。**只认一层，不嵌套**。
//       块里一个变量都没有 ⇒ 原样保留（连壳都不脱），避免误伤普通文本。
//
// ★ 为什么不直接用 NSString 写？
//   因为要能在小窝 Linux 上 gcc 编译 + 单测，把「替换规则」这件容易写错的事
//   变成一组可复跑的断言。iOS 侧只做 NSData/NSString 的薄封装。
//
// ★ 热路径纪律（来自 Java 版类头）：
//   调用点在「每次发消息」的 hook 里 ⇒ 纯内存、零 IO、绝不抛异常。
//   参数非法时一律**原样返回**（宁可变量没替换，也不能让消息发不出去）。
#ifndef FDM_PROMPT_VARS_H
#define FDM_PROMPT_VARS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** 此刻的播放快照。所有字符串都是 UTF-8、可为 NULL（等价空串）。 */
typedef struct {
    int enabled;            ///< 总开关。0 ⇒ 所有变量按「空」处理（功能不存在⇒不留痕迹）
    const char *song;
    const char *artist;
    const char *album;
    long long pos_ms;
    long long dur_ms;
    int playing;            ///< 1 = playing, 0 = paused
    int lyric_on;           ///< 歌词开关（默认 0 —— 版权：歌词会随提示词上传）
    const char *lyric;      ///< 当前唱到的一句
    const char *lyric_prev;
    const char *lyric_next;
} fdmpv_snap;

/** 文本里有没有我们的变量（inject 的快判据，不用正则）。 */
int fdmpv_has_any(const char *s);

/**
 * 把一段文本里的全部音乐变量替换成此刻的真值。
 * @return malloc 的字符串，调用方 free；参数非法时返回 NULL（调用方应原样放行）。
 */
char *fdmpv_resolve(const char *s, const fdmpv_snap *snap);

/** 毫秒 → "m:ss"（0 或负数 ⇒ "0:00"）。out 至少 16 字节。 */
void fdmpv_fmt_time(long long ms, char out[32]);

/** 内置用例自检。@return 0 = 全通过；否则第一个失败用例号。 */
int fdmpv_selftest(char *errbuf, size_t errlen);

#ifdef __cplusplus
}
#endif

#endif /* FDM_PROMPT_VARS_H */
