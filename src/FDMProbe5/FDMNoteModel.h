// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMNoteModel —— 悬浮便签的「数据 + 坐标」内核（纯 C11，零依赖）
//
// 对标 `mod-src/.../bridge/GmNote.java`（475 行）里除了 Android View 之外的全部逻辑：
//   · 多张便签（items）+ 当前索引（idx）+ 最小化（min）
//   · JSON 存档：{"idx":0,"min":false,"items":[{"t":"文字","x":120,"y":300}]}
//   · 拖完夹紧（clamp）：允许一半出屏，但绝不让整张便签跑没
//
// ★ 为什么这么切：便签的**手感**（圆角/阴影/字体）必须真机调，
//   但"数据存什么、存档坏了怎么办、拖到屏幕外怎么夹回来"是纯逻辑 ——
//   这部分在小窝里能跑 30 条断言，真机上就不用再怀疑它。
//
// ★ 铁律：任何输入都不能崩。JSON 坏、字段缺、坐标是 NaN ⇒ 一律回到安全默认值。
#ifndef FDM_NOTE_MODEL_H
#define FDM_NOTE_MODEL_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** 单张便签 */
typedef struct {
    char *text;      /**< malloc，UTF-8，可为空串（但绝不是 NULL） */
    double x;        /**< 卡片左上角，父视图坐标（点） */
    double y;
    double w;        /**< 用户拖出来的宽度；0 = 用默认宽 */
    double h;        /**< 用户拖出来的高度；0 = 按内容自动算 */
} fdmnote_item;

typedef struct {
    fdmnote_item *items;
    size_t count;
    size_t capacity;
    int idx;         /**< 当前是第几张（0-based；越界会被夹回来） */
    int minimized;   /**< 1 = 缩成圆球 */
} fdmnote_state;

/** 便签默认文字（新建时用 —— 空便签看不见，给一句提示） */
#define FDMNOTE_DEFAULT_TEXT "\u70B9\u4E00\u4E0B\u5199\u70B9\u4EC0\u4E48"

/** 一次性清空（可重复调用） */
void fdmnote_free(fdmnote_state *st);

/** 初始化成「一张空便签、不最小化」。@return 0 成功 */
int fdmnote_init(fdmnote_state *st);

/**
 * 解析存档 JSON。
 * 任何不合法的输入 ⇒ 返回一份可用的默认状态（并返回 0），
 * 只有内存不足才返回负数 —— **存档烂了不能等于功能消失**。
 */
int fdmnote_parse(const char *json, fdmnote_state *st);

/** 序列化成 JSON（malloc，调用方 free）。 */
char *fdmnote_serialize(const fdmnote_state *st);

/** 在当前便签后追加一张（自动选中它）。@return 新索引，失败 -1 */
int fdmnote_add(fdmnote_state *st, const char *text, double x, double y);

/** 删掉当前便签（至少留一张：删到最后一张时清空文字而不是变成 0 张）。 */
void fdmnote_delete_current(fdmnote_state *st);

/** 翻页：delta = ±1，环绕。 */
void fdmnote_step(fdmnote_state *st, int delta);

/** 改当前便签的文字（会释放旧的）。@return 0 成功 */
int fdmnote_set_text(fdmnote_state *st, const char *text);

/** 改当前便签的坐标。 */
void fdmnote_set_pos(fdmnote_state *st, double x, double y);

/** 改当前便签的尺寸（0 = 恢复默认/自动）。 */
void fdmnote_set_size(fdmnote_state *st, double w, double h);

/** 当前便签（永远非 NULL：状态坏了会临时给一张默认的）。 */
fdmnote_item *fdmnote_current(fdmnote_state *st);

/**
 * 拖完夹紧。
 * 规则（与安卓 GmNoteView.clamp() 一致）：
 *   minX = -w/2      maxX = pw - w/2
 *   minY = 0         maxY = ph - h/2
 * 也就是「允许一半出屏」，但拖不丢。
 * 非有限值（NaN/Inf）⇒ 回到 0，不返回 NaN。
 * @param inout_x 允许 NULL（只算不改）
 */
void fdmnote_clamp(double *inout_x, double *inout_y,
                   double w, double h, double pw, double ph);

/** 内置用例自检。@return 0 = 全通过；否则第一个失败用例号。 */
int fdmnote_selftest(char *errbuf, int errlen);

#ifdef __cplusplus
}
#endif

#endif /* FDM_NOTE_MODEL_H */
