// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMLyric —— LRC 歌词解析 + 「此刻唱到哪一句」（纯 C11，零依赖）
//
// 等价于 `GmMusicPlayer.parseLrc()` / `lyricAround()` 的实现。
//
//   [00:30.542]故事的小黄花
//   [00:34.165]从出生那年就飘着
//   [ti:晴天] [ar:周杰伦]        ← 元数据标签，自动忽略（解析不出时间就不算行）
//   [00:01.00][00:05.00]副歌       ← 一行多标签：取**最后一个**（与 Java 版一致）
//
// ★ 为什么单独抽出来：`{lyric}` / `{lyric_prev}` / `{lyric_next}` 全靠它。
//   这是纯算法，能在小窝里用真实歌词跑单测 —— 不必等真机。
#ifndef FDM_LYRIC_H
#define FDM_LYRIC_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    long long ms;
    char *text;      /* malloc，UTF-8 */
} fdmlrc_line;

typedef struct {
    fdmlrc_line *lines;
    size_t count;
} fdmlrc;

/**
 * 解析 LRC。
 * @return 0 成功（count 可能为 0）；负数 = 内存不足
 * 注意：会按时间升序排序（稳定）。
 */
int fdmlrc_parse(const char *lrc, fdmlrc *out);

/** 释放内部缓冲（可重复调用）。 */
void fdmlrc_free(fdmlrc *doc);

/**
 * 取 pos_ms 时刻的三句。
 * @param cur   当前唱到的（前奏阶段为 ""）
 * @param prev  上一句（前奏阶段为 ""）
 * @param next  下一句（没有则为 ""）
 * 返回的指针指向 doc 内部，doc 释放后失效。参数可为 NULL。
 */
void fdmlrc_around(const fdmlrc *doc, long long pos_ms,
                   const char **cur, const char **prev, const char **next);

/**
 * 取 pos_ms 时刻「当前/上一句/下一句」的**时间戳**（点歌词跳转要用）。
 * @param which 0 = 当前句（前奏阶段返回 -1）/ 1 = 上一句 / 2 = 下一句
 * @return 该句的毫秒时间戳；没有这一句返回 -1
 *
 * ★ 为什么单独一个函数而不是改 fdmlrc_around 的签名：
 *   那个函数在真机上已经跑通了（调试过的接口不要动），
 *   跳转是新增能力，加一个新函数最安全。
 */
long long fdmlrc_line_ms(const fdmlrc *doc, long long pos_ms, int which);

/** 内置用例自检。@return 0 = 全通过；否则第一个失败用例号。 */
int fdmlrc_selftest(char *errbuf, size_t errlen);

#ifdef __cplusplus
}
#endif

#endif /* FDM_LYRIC_H */
