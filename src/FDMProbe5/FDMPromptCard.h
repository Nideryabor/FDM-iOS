// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMPromptCard —— 「卡片式系统提示词 v2」的纯逻辑内核（纯 C11，零依赖）
//
// 对标安卓 `fdm-app/src/SysPromptV2.kt`（1,362 行）里**除了 Compose UI 之外**的全部逻辑：
//   · 卡片表（内置三张 + 文本源卡 + 自定义副本）
//   · 抽屉 / 容器 两个列表
//   · 存档 JSON 的读写 + **归一化**（坏存档不该把页面卡死）
//   · **按容器顺序重建系统提示词**（这就是 v2 的核心）
//
// ══════════════════════════════════════════════════════════════════════════
//  ★ 核心模型（主人 2026-10-10 定的，一个字都别改）
//
//    系统提示词的正文 = **容器里卡片们的内容按顺序拼起来**（空行分隔）
//
//      回复建议（卡） ⇒ 它自带的【追问建议】约定
//      音乐（卡）     ⇒ 它自带的【音乐变量】示例
//      富文本（卡）   ⇒ 它自带的【回答排版】约定
//      我的自定义文本 ⇒ 卡片里写的字（可选连标题一起）
//
//    ⇒ 那个「提示词内容」字段从此是**派生值**，不再手敲。
//       **容器空 ⇒ 文本字段空**（主人明确确认过这个语义）。
//
//  ★ 三种卡片、三套手势
//    内置三张   ：**搬**（拖进容器 / 拖回抽屉）+ 右边 ▸ 跳页
//    文本源卡   ：**复制**（拖进容器 ⇒ 长出一张新副本，源卡留在抽屉，能无限拖）
//    自定义副本 ：可编辑标题/正文/「标题也进提示词」；在抽屉里可删（要二次确认）
//
//  ★ 为什么纯逻辑要抽出来
//    Compose/UIKit 的拖拽手感必须真机调；但「拖进之后提示词该变成什么」
//    「存档坏了怎么办」「内置卡的自带文案谁负责」全是纯逻辑 ——
//    这部分在小窝跑几十条断言，真机上就不用再怀疑它。
// ══════════════════════════════════════════════════════════════════════════
#ifndef FDM_PROMPT_CARD_H
#define FDM_PROMPT_CARD_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============ 一、卡片类型（和安卓 T_* 常量一一对应） ============ */
#define FDMPC_T_SUGGEST  "suggest"     /* 内置：追问建议 */
#define FDMPC_T_MUSIC    "music"       /* 内置：音乐变量 */
#define FDMPC_T_RICHTEXT "richtext"    /* 内置：回答排版 */
#define FDMPC_T_TEXT     "text"        /* 自定义文本（副本） */
#define FDMPC_T_TEXTSRC  "textsrc"     /* 文本源卡片（只当模板，能无限复制） */

/** 源卡片的固定 key。 */
#define FDMPC_K_SRC      "textsrc"

/** 新建副本的默认文案（对应安卓 spv_001 / spv_002）。 */
#define FDMPC_DEF_TITLE  "点我编辑"
#define FDMPC_DEF_TEXT   "这是尼尼的卡片"

/** 上限（防呆：坏存档塞一万张卡不该把 App 拖死）。 */
#define FDMPC_MAX_CARDS  200
#define FDMPC_MAX_LIST   200

/* ============ 二、数据结构 ============ */

typedef struct {
    char *key;          /**< 唯一键：内置=类型名；副本="text#N"；源卡="textsrc" */
    char *type;         /**< FDMPC_T_* */
    char *title;        /**< malloc，绝不为 NULL */
    char *text;         /**< malloc，绝不为 NULL */
    int   withTitle;    /**< 0/1：标题也进提示词 */
} fdmpc_card;

typedef struct {
    /* 卡片表（按 key 查找） */
    fdmpc_card *cards;
    size_t      count;
    size_t      cap;

    /* 两个列表：抽屉（收着）+ 容器（进提示词）。存的是 key。 */
    char **drawer;
    size_t drawer_n;
    char **box;
    size_t box_n;

    int next_id;        /**< 下一个副本编号（text#1, text#2 …） */
} fdmpc_state;

/* ============ 三、生命周期 ============ */

/** 初始化成「默认卡片池」：内置三张 + 源卡，全在抽屉里（对应安卓 defaultCards）。 */
int  fdmpc_init(fdmpc_state *st);

/** 释放全部内存（可重复调用）。 */
void fdmpc_free(fdmpc_state *st);

/* ============ 四、卡片表操作 ============ */

/** 按下标取卡片；越界 NULL。 */
fdmpc_card *fdmpc_at(fdmpc_state *st, size_t i);
const fdmpc_card *fdmpc_at_c(const fdmpc_state *st, size_t i);

/** 按 key 找（找不到 -1）。 */
int fdmpc_find(const fdmpc_state *st, const char *key);

/** 按 key 取（找不到 NULL）。 */
fdmpc_card *fdmpc_get(fdmpc_state *st, const char *key);
const fdmpc_card *fdmpc_get_c(const fdmpc_state *st, const char *key);

/** 该类型是不是内置（suggest/music/richtext）。 */
int fdmpc_is_builtin_type(const char *type);

/** 该类型是不是文本类（text/textsrc）。 */
int fdmpc_is_text_type(const char *type);

/** 类型显示名（给 UI 用）。 */
const char *fdmpc_type_title(const char *type);

/** 新建一张自定义副本，自动分配 key = "text#N"，放进抽屉。@return 新 key 或 NULL */
char *fdmpc_new_text_card(fdmpc_state *st);

/** 改标题 / 正文 / withTitle（都会深拷贝）。@return 0 成功 */
int fdmpc_set_title(fdmpc_state *st, const char *key, const char *title);
int fdmpc_set_text(fdmpc_state *st, const char *key, const char *text);
int fdmpc_set_with_title(fdmpc_state *st, const char *key, int on);

/**
 * 删一张自定义副本（内置卡和源卡**不许删**）。
 * 会同时从抽屉/容器里摘掉。
 * @return 0 成功；-1 不存在 / 不许删
 */
int fdmpc_delete_card(fdmpc_state *st, const char *key);

/* ============ 五、抽屉 ⇄ 容器 ============ */

/** 该 key 在哪个列表里：0=抽屉 1=容器 -1=都不在。 */
int fdmpc_where(const fdmpc_state *st, const char *key);

/**
 * **搬 / 复制**（v2 最核心的一个动作，把安卓那三套手势合成一个函数）
 *
 * 语义（照抄安卓）：
 *   内置三张   → **搬**：抽屉 → 容器（从抽屉移除）
 *   源卡片     → **复制**：抽屉里留一份，容器里**追加一张新副本**
 *   自定义副本 → **搬**：抽屉 → 容器
 *
 * @return 0 成功；-1 失败（不存在 / 已在容器里 / 满了）
 */
int fdmpc_move_in(fdmpc_state *st, const char *key);

/**
 * **搬回抽屉**（容器 → 抽屉）。
 * 源卡片不会进容器所以不用管；副本搬回来仍然是同一张（不复制）。
 * @return 0 成功；-1 失败
 */
int fdmpc_move_out(fdmpc_state *st, const char *key);

/**
 * 调整容器内顺序（拖动重排）。
 * @return 0 成功；-1 下标非法
 */
int fdmpc_box_move(fdmpc_state *st, size_t from, size_t to);

/* ============ 六、★ 重建系统提示词（v2 的核心） ============ */

/**
 * 内置卡片「自带的」那一段文案。
 *
 * ⚠️ 为什么由**引擎**提供而不是 UI 抄一份：
 *   安卓那边注释写得很清楚 ——
 *   「内置三张卡只送类型名，它们"自带的"那一大段文案由宿主自己取
 *     （GmRichText.suggestSpec / GmPromptVars.spec / GmRichText.spec），
 *     免得同一份文案在界面里再抄一份、两边各说一套。」
 *
 * @param type FDMPC_T_*（text/textsrc 返回 NULL —— 它们的内容来自卡片自身）
 * @return 静态常量字符串（**不要 free**）；不认识的类型返回 NULL
 */
const char *fdmpc_builtin_spec(const char *type);

/**
 * 按容器顺序重建系统提示词。
 *
 * 规则（照抄安卓 prompt_compose）：
 *   · 逐张卡片取「那一段」：
 *       内置三张 → fdmpc_builtin_spec()
 *       text     → withTitle ? (title + "\n" + text) : text
 *   · 每段先 trim；**空段跳过**（不占位、不产生多余空行）
 *   · 段与段之间用 **"\n\n"** 连接
 *   · 容器空 ⇒ 返回空串（**不是 NULL** —— 调用方要能 distinguish）
 *
 * @return malloc 的字符串（调用方 free）；内存不足返回 NULL
 */
char *fdmpc_compose(const fdmpc_state *st);

/* ============ 七、存档（JSON） ============ */

/**
 * 序列化。
 * 格式：{"nextId":3,"drawer":["suggest"],"box":["text#1","richtext"],
 *        "cards":[{"k":"…","t":"…","ti":"…","tx":"…","wt":0}, …]}
 * @return malloc 的字符串（调用方 free）
 */
char *fdmpc_to_json(const fdmpc_state *st);

/**
 * 反序列化 + **归一化**。
 *
 * ★ 归一化是这里最重要的东西（安卓 3.62.2 修过一次「三个内置卡片被当夜宵吃了」）：
 *   ① 卡片表里必须有抽屉/容器里出现的每一张卡 —— 缺了就补
 *   ② 认不出来的（类型不明 / key 脏 / 超过上限）**一律丢掉**，别让坏存档卡死页面
 *   ③ **内置三张永远补回抽屉** —— 它们删不掉，丢了也必须长回来
 *   ④ 同一个 key 不能同时出现在两个列表里
 *
 * @return 0 = 解析成功（哪怕内容被归一化过）；-1 = 完全没法用（保持默认状态）
 */
int fdmpc_from_json(fdmpc_state *st, const char *json);

/* ============ 八、自检 ============ */

/** 内置断言。@return 0 = 全通过；否则第一个失败用例号 */
int fdmpc_selftest(char *errbuf, int errlen);

#ifdef __cplusplus
}
#endif

#endif /* FDM_PROMPT_CARD_H */
