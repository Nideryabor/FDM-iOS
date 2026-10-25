// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMMusicModel —— 音乐播放的「队列 + 状态 + 存档」内核（纯 C11，零依赖）
//
// 对标安卓 `bridge/GmMusicPlayer.java`（800 行）里**除了 MediaPlayer 之外**的全部逻辑：
//   · 队列增删改查 / 当前曲 / 上一首下一首决策（含三种循环 + 随机）
//   · 播放状态机：STOPPED → LOADING → PLAYING ⇄ PAUSED / ERROR
//   · 音质档位与「失败降级」链（lossless → exhigh → higher → standard）
//   · 进度格式化（0:00 / 1:02:03）
//   · state.json 存档（**只存事实性元数据**，见下）
//
// ★ 版权红线（沿用安卓 GmMusicPlayer 文件头的约定，务必遵守）
//     音频    —— 只在 AVPlayer 里流式播放，**永不下载、永不落盘**
//     封面    —— 由宿主联网取回，**只放内存**
//     歌词    —— 同上，**只放内存**
//     存档    —— 只有 id / 歌名 / 歌手 / 专辑 / 时长 / 进度 / 播放态 /
//                循环 / 随机 / 音量 / 音质 / 队列下标
//                —— **不含任何受版权保护的内容**
//
// ★ 为什么这么切（和便签、气泡同一套方法论）
//   手感（毛玻璃/圆角/拖动惯性）必须真机调；
//   但「点了下一首该放哪首」「存档坏了怎么办」「随机怎么不重复」是纯逻辑 ——
//   这部分在小窝里跑几十条断言，真机上就不用再怀疑它。
//
// ★ 铁律：任何输入都不能崩。JSON 坏 / 字段缺 / idx 越界 / 时长是负数
//         ⇒ 一律回到安全默认值，绝不 return 半个坏状态。
#ifndef FDM_MUSIC_MODEL_H
#define FDM_MUSIC_MODEL_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============ 一、枚举 ============ */

/** 播放状态机 */
typedef enum {
    FDMMS_STOPPED = 0,   /**< 没在放（队列可能是空的，也可能只是停了） */
    FDMMS_LOADING = 1,   /**< 正在取播放地址 / 缓冲 */
    FDMMS_PLAYING = 2,
    FDMMS_PAUSED  = 3,
    FDMMS_ERROR   = 4,   /**< 取地址失败 / 播放失败（要用 quality_downgrade 重试） */
} fdmmusic_state;

/** 循环模式 */
typedef enum {
    FDMMR_OFF = 0,       /**< 放完最后一首就停 */
    FDMMR_ALL = 1,       /**< 列表循环 */
    FDMMR_ONE = 2,       /**< 单曲循环 */
} fdmmusic_repeat;

/** 音质档（数字越大越差 —— 降级就是 +1） */
typedef enum {
    FDMMQ_LOSSLESS = 0,
    FDMMQ_EXHIGH   = 1,
    FDMMQ_HIGHER   = 2,
    FDMMQ_STANDARD = 3,
} fdmmusic_quality;

/* ============ 二、数据结构 ============ */

/** 一首歌（跨接口归一化后的扁平结构，字段与 ObjC 的 FDMMusicTrack 对齐） */
typedef struct {
    long long id;
    char *name;          /**< malloc，UTF-8，绝不为 NULL */
    char *artist;
    char *album;
    char *pic;           /**< 封面 URL；只放内存，不进存档 */
    long long duration_ms;
    int fee;             /**< 0 免费 / 1 VIP / 8 低音质免费 */
} fdmmusic_track;

/** 队列 + 播放状态 + 用户偏好（一个结构全包，省得外面维护 5 份状态） */
typedef struct {
    fdmmusic_track *items;
    size_t count;
    size_t cap;
    int idx;             /**< 当前曲下标；-1 = 没有当前曲 */
    int state;           /**< fdmmusic_state */
    int repeat;          /**< fdmmusic_repeat */
    int shuffle;         /**< 0/1 */
    int vol;             /**< 0..100 */
    int quality;         /**< fdmmusic_quality */
    long long pos_ms;    /**< 当前播放进度（毫秒） */
    char *lrc;           /**< 当前歌词原文（内存缓存，不进存档） */
} fdmmusic_queue;

/* ============ 三、生命周期 ============ */

/** 初始化成安全默认值（vol=70 / quality=EXHIGH / repeat=ALL / idx=-1）。@return 0 成功 */
int  fdmmusic_init(fdmmusic_queue *q);

/** 释放内部所有缓冲（可重复调用；之后结构处于 init 过的状态）。 */
void fdmmusic_free(fdmmusic_queue *q);

/** 清空队列（保留 repeat/shuffle/vol/quality 这些偏好）。 */
void fdmmusic_clear(fdmmusic_queue *q);

/* ============ 四、队列操作 ============ */

/** 追加一首（会深拷贝字符串）。@return 0 成功，-1 内存不足 */
int fdmmusic_push(fdmmusic_queue *q, const fdmmusic_track *t);

/**
 * 整批替换队列（搜索结果 → 队列：点某一条就从这个列表放）。
 * @param start 从第几条开始放（越界会被夹到 [0, n-1]；n==0 则 idx=-1）
 * @return 0 成功，-1 内存不足
 */
int fdmmusic_set_queue(fdmmusic_queue *q, const fdmmusic_track *items,
                       size_t n, int start);

/** 当前曲；没有则 NULL。 */
const fdmmusic_track *fdmmusic_current(const fdmmusic_queue *q);

/** 按 songId 在队列里找（找不到 -1）。 */
int fdmmusic_find(const fdmmusic_queue *q, long long songId);

/**
 * 删掉一条队列项。
 * 规则：删的是当前曲时，若后面还有就顺位接上；否则退一首；空了就 idx=-1。
 * @return 0 成功，-1 下标非法
 */
int fdmmusic_remove(fdmmusic_queue *q, int at);

/* ============ 五、切歌决策（核心，最需要单测的部分） ============ */

/**
 * 算「下一首该是谁」。
 * @param manual 1 = 用户主动点「下一首」；0 = 一首放完自动接
 *
 * 三种循环 × 手动/自动 的完整真值表：
 *   repeat=OFF  手动 → 还有下一首就下一首；最后一首 → -1（停止，但不停列表）
 *   repeat=OFF  自动 → 同上（放完最后一首就停）
 *   repeat=ALL  手动 → 绕回第 0 首
 *   repeat=ALL  自动 → 绕回第 0 首
 *   repeat=ONE  手动 → **跳下一首**（用户想换歌，不能原地循环）
 *   repeat=ONE  自动 → **同一首**（这才是单曲循环）
 *
 * @return 目标下标；-1 = 该停
 */
int fdmmusic_next_index(const fdmmusic_queue *q, int manual);

/**
 * 算「上一首该是谁」。
 *   repeat=OFF 且在第一首 → -1
 *   其余 → 绕回最后一首
 *   （random 模式下「上一首」= 退到第 0 首，和安卓一致：随机模式没有历史栈）
 */
int fdmmusic_prev_index(const fdmmusic_queue *q);

/**
 * 随机挑一首（确定性 PRNG，方便单测）。
 * @param seed  随机种子
 * @param count 队列长度
 * @param avoid 要避开的那个（一般传当前 idx）；count<=1 时直接返回 0
 * @return [0, count-1]；count<=0 返回 -1
 */
int fdmmusic_shuffle_pick(unsigned seed, int count, int avoid);

/* ============ 六、状态 / 显示辅助 ============ */

/** 状态机是否「正在出声」。 */
int fdmmusic_is_active(const fdmmusic_queue *q);

/** 进度格式化：0:00 / 12:34 / 1:02:03。负数和 0 都输出 "0:00"。 */
void fdmmusic_fmt_time(long long ms, char *buf, size_t n);

/** 音质档名（给 UI 显示/给接口当 level 参数用）。 */
const char *fdmmusic_quality_name(int quality);

/** 降一档（已是最低档返回自身）。 */
int fdmmusic_quality_downgrade(int quality);

/** 音量夹紧到 [0,100]。 */
int fdmmusic_clamp_vol(int v);

/** 循环模式的下一个（给 UI 那个 ↻ 按钮轮转：OFF→ALL→ONE→OFF）。 */
int fdmmusic_repeat_next(int repeat);

/* ============ 七、存档（state.json） ============ */

/**
 * 序列化成 JSON（**只有事实性元数据**）。
 * @return malloc 的字符串（调用方 free）；失败 NULL
 */
char *fdmmusic_to_json(const fdmmusic_queue *q);

/**
 * 从 JSON 恢复。**宽容解析**：坏字段用默认值，不认识的键跳过。
 * 恢复后 state 一律变成 PAUSED（重启不该自动出声）或 STOPPED（队列空）。
 * @return 0 = 解析到了能用的东西；-1 = 完全没法用（结构保持默认）
 */
int fdmmusic_from_json(fdmmusic_queue *q, const char *json);

/** 存档路径由 ObjC 层给（它才知道 Documents 在哪），这里只管拼文件名。 */
#define FDMMUSIC_STATE_FILE "state.json"
#define FDMMUSIC_DIR_HINT   "FDMmusic"

/* ============ 八、自检 ============ */

/** 内置断言。@return 0 = 全通过；否则第一个失败用例号 */
int fdmmusic_selftest(char *errbuf, int errlen);

#ifdef __cplusplus
}
#endif

#endif /* FDM_MUSIC_MODEL_H */
