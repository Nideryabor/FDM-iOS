// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMMusicModel.c —— 见头文件注释。这里只放「能被单测」的纯逻辑。
#include "FDMMusicModel.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

/* ============================================================
 * 〇、小工具
 * ============================================================ */

static char *ms_strdup(const char *s) {
    if (!s) s = "";
    size_t n = strlen(s);
    char *p = (char *)malloc(n + 1);
    if (!p) return NULL;
    memcpy(p, s, n + 1);
    return p;
}

static int ms_clampi(int v, int lo, int hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

/* ============================================================
 * 一、生命周期
 * ============================================================ */

void fdmmusic_clear(fdmmusic_queue *q) {
    if (!q) return;
    if (q->items) {
        for (size_t i = 0; i < q->count; i++) {
            free(q->items[i].name);
            free(q->items[i].artist);
            free(q->items[i].album);
            free(q->items[i].pic);
        }
        free(q->items);
    }
    q->items = NULL;
    q->count = 0;
    q->cap = 0;
    q->idx = -1;
    q->state = FDMMS_STOPPED;
    q->pos_ms = 0;
    free(q->lrc);
    q->lrc = NULL;
}

int fdmmusic_init(fdmmusic_queue *q) {
    if (!q) return -1;
    memset(q, 0, sizeof(*q));
    q->idx = -1;
    q->state = FDMMS_STOPPED;
    q->repeat = FDMMR_ALL;
    q->shuffle = 0;
    q->vol = 70;
    q->quality = FDMMQ_EXHIGH;
    q->pos_ms = 0;
    return 0;
}

void fdmmusic_free(fdmmusic_queue *q) {
    if (!q) return;
    fdmmusic_clear(q);
    /* 偏好归位（下次 init 会再设一遍，这里是不让外部看到脏值） */
    q->repeat = FDMMR_ALL;
    q->shuffle = 0;
    q->vol = 70;
    q->quality = FDMMQ_EXHIGH;
}

/* ============================================================
 * 二、队列操作
 * ============================================================ */

static int ms_reserve(fdmmusic_queue *q, size_t need) {
    if (q->cap >= need) return 0;
    size_t nc = q->cap ? q->cap : 8;
    while (nc < need) nc *= 2;
    fdmmusic_track *p = (fdmmusic_track *)realloc(q->items, nc * sizeof(*p));
    if (!p) return -1;
    q->items = p;
    q->cap = nc;
    return 0;
}

/* 深拷贝一首进来（先拷字符串，成功才落座 —— 避免半成品进队列） */
static int ms_copy_track(fdmmusic_track *dst, const fdmmusic_track *src) {
    memset(dst, 0, sizeof(*dst));
    dst->id = src->id;
    dst->duration_ms = src->duration_ms;
    dst->fee = src->fee;
    dst->name   = ms_strdup(src->name);
    dst->artist = ms_strdup(src->artist);
    dst->album  = ms_strdup(src->album);
    dst->pic    = ms_strdup(src->pic);
    if (!dst->name || !dst->artist || !dst->album || !dst->pic) {
        free(dst->name); free(dst->artist); free(dst->album); free(dst->pic);
        memset(dst, 0, sizeof(*dst));
        return -1;
    }
    return 0;
}

int fdmmusic_push(fdmmusic_queue *q, const fdmmusic_track *t) {
    if (!q || !t) return -1;
    if (ms_reserve(q, q->count + 1) != 0) return -1;
    if (ms_copy_track(&q->items[q->count], t) != 0) return -1;
    q->count++;
    if (q->idx < 0) q->idx = 0;          /* 第一首自动成为当前曲 */
    return 0;
}

int fdmmusic_set_queue(fdmmusic_queue *q, const fdmmusic_track *items,
                       size_t n, int start) {
    if (!q) return -1;
    /* 先清空（保留偏好），再逐个拷；中途失败就返回，但队列是干净的 */
    fdmmusic_clear(q);
    if (n == 0 || !items) return 0;
    if (ms_reserve(q, n) != 0) return -1;
    for (size_t i = 0; i < n; i++) {
        if (ms_copy_track(&q->items[q->count], &items[i]) != 0) return -1;
        q->count++;
    }
    q->idx = ms_clampi(start, 0, (int)q->count - 1);
    q->state = FDMMS_LOADING;
    q->pos_ms = 0;
    return 0;
}

const fdmmusic_track *fdmmusic_current(const fdmmusic_queue *q) {
    if (!q || q->idx < 0 || (size_t)q->idx >= q->count) return NULL;
    return &q->items[q->idx];
}

int fdmmusic_find(const fdmmusic_queue *q, long long songId) {
    if (!q) return -1;
    for (size_t i = 0; i < q->count; i++)
        if (q->items[i].id == songId) return (int)i;
    return -1;
}

int fdmmusic_remove(fdmmusic_queue *q, int at) {
    if (!q || at < 0 || (size_t)at >= q->count) return -1;
    fdmmusic_track *t = &q->items[at];
    free(t->name); free(t->artist); free(t->album); free(t->pic);
    /* 后面的往前挪一格 */
    if ((size_t)at + 1 < q->count)
        memmove(&q->items[at], &q->items[at + 1],
                (q->count - (size_t)at - 1) * sizeof(fdmmusic_track));
    q->count--;

    if (q->count == 0) {
        q->idx = -1;
        q->state = FDMMS_STOPPED;
        q->pos_ms = 0;
        return 0;
    }
    if (at < q->idx) {
        q->idx--;                     /* 删的是前头的，当前曲下标前移 */
    } else if (at == q->idx) {
        /* 删的就是当前曲：还在原位就顺位接上，删的是最后一个就退一首 */
        if ((size_t)q->idx >= q->count) q->idx = (int)q->count - 1;
        q->pos_ms = 0;
        q->state = FDMMS_LOADING;
    }
    if (q->idx < 0) q->idx = 0;
    return 0;
}

/* ============================================================
 * 三、切歌决策
 * ============================================================ */

int fdmmusic_next_index(const fdmmusic_queue *q, int manual) {
    if (!q || q->count == 0) return -1;
    int n = (int)q->count;
    int cur = (q->idx < 0) ? 0 : q->idx;

    /* 单曲循环：主动切歌仍然要换（否则用户点了没反应），自动接才原地 */
    if (q->repeat == FDMMR_ONE && !manual) return cur;

    /* 随机：自动接时随机挑（避开当前）；手动也随机 —— 和安卓一致 */
    if (q->shuffle) {
        unsigned seed = (unsigned)(q->pos_ms ^ (long long)(cur * 2654435761u) ^ 0x9E3779B9u);
        int k = fdmmusic_shuffle_pick(seed, n, cur);
        return (k < 0) ? -1 : k;
    }

    if (cur + 1 < n) return cur + 1;                   /* 后面还有 */
    /* 尾巴上：ALL 一定绕回；ONE 在**手动**时也绕回（用户想换歌）
     * OFF 到尾巴就停 —— 不绕。 */
    if (q->repeat == FDMMR_ALL) return 0;
    if (q->repeat == FDMMR_ONE && manual) return 0;
    return -1;
}

int fdmmusic_prev_index(const fdmmusic_queue *q) {
    if (!q || q->count == 0) return -1;
    int n = (int)q->count;
    int cur = (q->idx < 0) ? 0 : q->idx;
    if (cur > 0) return cur - 1;
    /* 已经在第一首 */
    if (q->repeat == FDMMR_ALL || q->repeat == FDMMR_ONE) return n - 1;
    return -1;
}

int fdmmusic_shuffle_pick(unsigned seed, int count, int avoid) {
    if (count <= 0) return -1;
    if (count == 1) return 0;

    /* xorshift32 —— 确定性，方便单测；质量够挑个下标 */
    unsigned x = seed ? seed : 2463534242u;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    int k = (int)(x % (unsigned)count);

    /* 撞上要避开的那首就顺移一格（保证一定换歌） */
    if (k == avoid) k = (k + 1) % count;
    if (k < 0) k = 0;
    if (k >= count) k = count - 1;
    return k;
}

/* ============================================================
 * 四、显示辅助
 * ============================================================ */

int fdmmusic_is_active(const fdmmusic_queue *q) {
    if (!q) return 0;
    return q->state == FDMMS_PLAYING || q->state == FDMMS_LOADING;
}

void fdmmusic_fmt_time(long long ms, char *buf, size_t n) {
    if (!buf || n == 0) return;
    if (ms < 0) ms = 0;
    long long total = ms / 1000;
    long long h = total / 3600;
    long long m = (total % 3600) / 60;
    long long s = total % 60;
    if (h > 0)
        snprintf(buf, n, "%lld:%02lld:%02lld", h, m, s);
    else
        snprintf(buf, n, "%lld:%02lld", m, s);
}

const char *fdmmusic_quality_name(int quality) {
    switch (quality) {
        case FDMMQ_LOSSLESS: return "lossless";
        case FDMMQ_EXHIGH:   return "exhigh";
        case FDMMQ_HIGHER:   return "higher";
        case FDMMQ_STANDARD: return "standard";
        default:             return "exhigh";
    }
}

int fdmmusic_quality_downgrade(int quality) {
    if (quality < FDMMQ_LOSSLESS) quality = FDMMQ_LOSSLESS;
    if (quality >= FDMMQ_STANDARD) return FDMMQ_STANDARD;
    return quality + 1;
}

int fdmmusic_clamp_vol(int v) { return ms_clampi(v, 0, 100); }

int fdmmusic_repeat_next(int repeat) {
    switch (repeat) {
        case FDMMR_OFF: return FDMMR_ALL;
        case FDMMR_ALL: return FDMMR_ONE;
        default:        return FDMMR_OFF;
    }
}

/* ============================================================
 * 五、JSON 序列化
 * ============================================================ */

/* 估一个够用的长度：每个字符最多转义成 6 字节，再加结构开销 */
static size_t ms_esc_len(const char *s) {
    size_t n = 0;
    for (const unsigned char *p = (const unsigned char *)(s ? s : ""); *p; p++) {
        if (*p == '"' || *p == '\\') n += 2;
        else if (*p < 0x20) n += 6;
        else n += 1;
    }
    return n;
}

static char *ms_esc_into(char *o, const char *s) {
    for (const unsigned char *p = (const unsigned char *)(s ? s : ""); *p; p++) {
        if (*p == '"')       { *o++ = '\\'; *o++ = '"'; }
        else if (*p == '\\') { *o++ = '\\'; *o++ = '\\'; }
        else if (*p == '\n') { *o++ = '\\'; *o++ = 'n'; }
        else if (*p == '\r') { *o++ = '\\'; *o++ = 'r'; }
        else if (*p == '\t') { *o++ = '\\'; *o++ = 't'; }
        else if (*p < 0x20) {
            static const char *hex = "0123456789abcdef";
            *o++ = '\\'; *o++ = 'u'; *o++ = '0'; *o++ = '0';
            *o++ = hex[(*p >> 4) & 0xF]; *o++ = hex[*p & 0xF];
        }
        else *o++ = (char)*p;
    }
    return o;
}

char *fdmmusic_to_json(const fdmmusic_queue *q) {
    if (!q) return NULL;

    size_t need = 256;                       /* 顶层字段 + 括号 */
    for (size_t i = 0; i < q->count; i++) {
        const fdmmusic_track *t = &q->items[i];
        /* 名字/歌手/专辑 各最多转义，pic 不进存档 */
        need += ms_esc_len(t->name) + ms_esc_len(t->artist) + ms_esc_len(t->album);
        need += 160;                         /* id/d/fee/引号/逗号等固定开销 */
    }
    char *out = (char *)malloc(need);
    if (!out) return NULL;

    char *o = out;
    o += sprintf(o, "{\"v\":1,\"idx\":%d,\"pos\":%lld,\"repeat\":%d,\"shuffle\":%d,"
                    "\"vol\":%d,\"quality\":%d,\"items\":[",
                 q->idx, q->pos_ms, q->repeat, q->shuffle,
                 q->vol, q->quality);
    for (size_t i = 0; i < q->count; i++) {
        const fdmmusic_track *t = &q->items[i];
        o += sprintf(o, "%s{\"id\":%lld,\"n\":\"", i ? "," : "",
                     t->id);
        o = ms_esc_into(o, t->name);
        o += sprintf(o, "\",\"a\":\"");
        o = ms_esc_into(o, t->artist);
        o += sprintf(o, "\",\"al\":\"");
        o = ms_esc_into(o, t->album);
        o += sprintf(o, "\",\"d\":%lld,\"fee\":%d}",
                     t->duration_ms, t->fee);
    }
    o += sprintf(o, "]}");
    (void)o;
    return out;
}

/* ============================================================
 * 六、JSON 宽容解析
 *
 * 不引第三方库（dylib 里能少一个依赖就少一个）。
 * 策略：**按 key 线性找值**，不认识的全跳过；坏值用默认值。
 * 只支持本文件自己产出的格式 + 少量手改容错，不是通用 JSON 解析器。
 * ============================================================ */

static const char *ms_skip_ws(const char *p) {
    while (p && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
    return p;
}

/* 从 p 起跳过一个 JSON 值（字符串/数字/对象/数组/字面量），返回其后的位置 */
static const char *ms_skip_value(const char *p) {
    p = ms_skip_ws(p);
    if (!p) return NULL;
    if (*p == '"') {
        p++;
        while (*p) {
            if (*p == '\\') { p++; if (!*p) return NULL; p++; continue; }
            if (*p == '"') return p + 1;
            p++;
        }
        return NULL;
    }
    if (*p == '{' || *p == '[') {
        int depth = 0;
        while (*p) {
            if (*p == '"') {                     /* 字符串里的括号不算 */
                p++;
                while (*p) {
                    if (*p == '\\') { p++; if (!*p) return NULL; p++; continue; }
                    if (*p == '"') break;
                    p++;
                }
                if (!*p) return NULL;
                p++;
                continue;
            }
            if (*p == '{' || *p == '[') depth++;
            else if (*p == '}' || *p == ']') {
                depth--;
                if (depth == 0) return p + 1;
            }
            p++;
        }
        return NULL;
    }
    /* 数字 / true / false / null */
    while (*p && *p != ',' && *p != '}' && *p != ']' &&
           *p != ' ' && *p != '\t' && *p != '\n' && *p != '\r') p++;
    return p;
}

/* 在 [p, end) 内找 "key" : value，返回值起点。找不到 NULL。 */
static const char *ms_find_key(const char *p, const char *end, const char *key) {
    if (!p || !key) return NULL;
    size_t kl = strlen(key);
    while (p < end) {
        while (p < end && *p != '"') p++;
        if (p >= end) return NULL;
        const char *ks = p + 1;
        const char *ke = ks;
        while (ke < end && *ke != '"') {
            if (*ke == '\\') ke++;
            ke++;
        }
        if (ke >= end) return NULL;
        size_t sl = (size_t)(ke - ks);
        const char *after = ke + 1;
        if (sl == kl && memcmp(ks, key, kl) == 0) {
            const char *c = ms_skip_ws(after);
            if (c && c < end && *c == ':') {
                c = ms_skip_ws(c + 1);
                return (c && c < end) ? c : NULL;
            }
        }
        p = after;
    }
    return NULL;
}

/* 反转义一个 JSON 字符串到 out（截断到 n-1）。返回写入了多少字节，-1 = 格式坏 */
static int ms_unescape(const char *p, const char *end, char *out, size_t n) {
    if (!out || n == 0) return -1;
    size_t w = 0;
    if (!p || p >= end || *p != '"') { out[0] = '\0'; return -1; }
    p++;
    while (p < end && *p != '"') {
        unsigned char c = (unsigned char)*p;
        if (c == '\\') {
            p++;
            if (p >= end) { out[0] = '\0'; return -1; }
            switch (*p) {
                case '"':  c = '"';  p++; break;
                case '\\': c = '\\'; p++; break;
                case '/':  c = '/';  p++; break;
                case 'n':  c = '\n'; p++; break;
                case 'r':  c = '\r'; p++; break;
                case 't':  c = '\t'; p++; break;
                case 'b':  c = '\b'; p++; break;
                case 'f':  c = '\f'; p++; break;
                case 'u': {
                    p++;
                    unsigned cp = 0;
                    int k = 0;
                    for (; k < 4 && p < end; k++, p++) {
                        char h = *p;
                        unsigned d;
                        if (h >= '0' && h <= '9') d = (unsigned)(h - '0');
                        else if (h >= 'a' && h <= 'f') d = (unsigned)(h - 'a' + 10);
                        else if (h >= 'A' && h <= 'F') d = (unsigned)(h - 'A' + 10);
                        else break;
                        cp = cp * 16 + d;
                    }
                    if (k < 4) { out[w] = '\0'; return (int)w; }
                    /* BMP → UTF-8（代理对不处理，本文件自己写不出） */
                    if (cp < 0x80) {
                        if (w + 1 < n) out[w++] = (char)cp;
                    } else if (cp < 0x800) {
                        if (w + 2 < n) {
                            out[w++] = (char)(0xC0 | (cp >> 6));
                            out[w++] = (char)(0x80 | (cp & 0x3F));
                        }
                    } else {
                        if (w + 3 < n) {
                            out[w++] = (char)(0xE0 | (cp >> 12));
                            out[w++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                            out[w++] = (char)(0x80 | (cp & 0x3F));
                        }
                    }
                    continue;
                }
                default: c = (unsigned char)*p; p++; break;
            }
        } else {
            p++;
        }
        if (w + 1 < n) out[w++] = (char)c;
    }
    out[w] = '\0';
    return (int)w;
}

static long long ms_get_ll(const char *obj, const char *end,
                           const char *key, long long def) {
    const char *v = ms_find_key(obj, end, key);
    if (!v) return def;
    v = ms_skip_ws(v);
    if (!v || *v == '"' || *v == '{' || *v == '[') return def;
    char *tail = NULL;
    long long r = strtoll(v, &tail, 10);
    if (tail == v) return def;
    return r;
}

static int ms_get_str(const char *obj, const char *end, const char *key,
                      char **dst) {
    const char *v = ms_find_key(obj, end, key);
    if (!v) return 0;
    v = ms_skip_ws(v);
    if (!v || *v != '"') return 0;
    /* 先量长度（反转义后不会超过原串长度） */
    const char *q = v;
    if (!ms_skip_value(v)) return 0;
    size_t cap = (size_t)((ms_skip_value(v)) - q) + 1;
    char *buf = (char *)malloc(cap);
    if (!buf) return 0;
    if (ms_unescape(v, end, buf, cap) < 0) { free(buf); return 0; }
    free(*dst);
    *dst = buf;
    return 1;
}

int fdmmusic_from_json(fdmmusic_queue *q, const char *json) {
    if (!q) return -1;
    if (!json || !*json) return -1;

    const char *end = json + strlen(json);
    const char *root = ms_skip_ws(json);
    if (!root || *root != '{') return -1;

    /* ---- 先读顶层偏好（队列清空但保留偏好，所以先把偏好存起来再清） ---- */
    int idx     = (int)ms_get_ll(root, end, "idx", -1);
    long long pos = ms_get_ll(root, end, "pos", 0);
    int repeat  = (int)ms_get_ll(root, end, "repeat", FDMMR_ALL);
    int shuffle = (int)ms_get_ll(root, end, "shuffle", 0);
    int vol     = (int)ms_get_ll(root, end, "vol", 70);
    int quality = (int)ms_get_ll(root, end, "quality", FDMMQ_EXHIGH);

    fdmmusic_clear(q);
    q->repeat = ms_clampi(repeat, FDMMR_OFF, FDMMR_ONE);
    q->shuffle = shuffle ? 1 : 0;
    q->vol = fdmmusic_clamp_vol(vol);
    q->quality = ms_clampi(quality, FDMMQ_LOSSLESS, FDMMQ_STANDARD);
    q->pos_ms = (pos < 0) ? 0 : pos;

    /* ---- items ---- */
    const char *arr = ms_find_key(root, end, "items");
    int loaded = 0;
    if (arr) {
        arr = ms_skip_ws(arr);
        if (arr && *arr == '[') {
            const char *p = arr + 1;
            while (p && *p) {
                p = ms_skip_ws(p);
                if (!p || *p == ']') break;
                if (*p != '{') { p = ms_skip_value(p); if (p && *p == ',') p++; continue; }

                const char *obj_end = ms_skip_value(p);      /* 指向 '}' 之后 */
                if (!obj_end) break;

                fdmmusic_track t;
                memset(&t, 0, sizeof(t));
                t.id = ms_get_ll(p, obj_end, "id", 0);
                t.duration_ms = ms_get_ll(p, obj_end, "d", 0);
                t.fee = (int)ms_get_ll(p, obj_end, "fee", 0);
                t.name = t.artist = t.album = t.pic = NULL;
                ms_get_str(p, obj_end, "n", &t.name);
                ms_get_str(p, obj_end, "a", &t.artist);
                ms_get_str(p, obj_end, "al", &t.album);
                ms_get_str(p, obj_end, "pic", &t.pic);

                if (t.duration_ms < 0) t.duration_ms = 0;

                if (fdmmusic_push(q, &t) == 0) loaded++;
                free(t.name); free(t.artist); free(t.album); free(t.pic);

                p = obj_end;
                if (p && *p == ',') p++;
                if (loaded > 5000) break;                    /* 防呆上限 */
            }
        }
    }

    if (q->count == 0) {
        q->idx = -1;
        q->state = FDMMS_STOPPED;
        q->pos_ms = 0;
        return loaded > 0 ? 0 : -1;
    }

    q->idx = ms_clampi(idx, 0, (int)q->count - 1);
    /* 重启不该自动出声 */
    q->state = FDMMS_PAUSED;
    return 0;
}

/* ============================================================
 * 七、自检
 * ============================================================ */

static int ms_chk(char *errbuf, int errlen, int no, const char *msg, int ok) {
    if (ok) return 1;
    snprintf(errbuf, (size_t)errlen, "#%d %s", no, msg);
    return 0;
}

int fdmmusic_selftest(char *errbuf, int errlen) {
    char local[512];
    if (!errbuf) { errbuf = local; errlen = (int)sizeof(local); }
    errbuf[0] = '\0';

    fdmmusic_queue q;
    fdmmusic_track t;
    int i;

    /* 1. init 默认值 */
    fdmmusic_init(&q);
    if (!ms_chk(errbuf, errlen, 1, "init 默认值不对",
                q.count == 0 && q.idx == -1 && q.state == FDMMS_STOPPED &&
                q.repeat == FDMMR_ALL && q.quality == FDMMQ_EXHIGH &&
                q.vol == 70))
        return 1;

    /* 2. push + current */
    memset(&t, 0, sizeof(t));
    t.id = 111; t.name = "晴天"; t.artist = "周杰伦"; t.album = "叶惠美";
    t.duration_ms = 269000; t.fee = 1; t.pic = "https://x/1.jpg";
    fdmmusic_push(&q, &t);
    t.id = 222; t.name = "稻香";
    fdmmusic_push(&q, &t);
    t.id = 333; t.name = "七里香";
    fdmmusic_push(&q, &t);
    if (!ms_chk(errbuf, errlen, 2, "push/current",
                q.count == 3 && q.idx == 0 &&
                fdmmusic_current(&q) && fdmmusic_current(&q)->id == 111 &&
                strcmp(fdmmusic_current(&q)->name, "晴天") == 0))
        return 2;

    /* 3. find */
    if (!ms_chk(errbuf, errlen, 3, "find",
                fdmmusic_find(&q, 333) == 2 && fdmmusic_find(&q, 999) == -1))
        return 3;

    /* 4. next 真值表：repeat=ALL */
    q.repeat = FDMMR_ALL;
    q.idx = 2;
    if (!ms_chk(errbuf, errlen, 4, "ALL 自动应绕回 0",
                fdmmusic_next_index(&q, 0) == 0)) return 4;
    q.idx = 2;
    if (!ms_chk(errbuf, errlen, 5, "ALL 手动应绕回 0",
                fdmmusic_next_index(&q, 1) == 0)) return 5;

    /* 5. repeat=OFF */
    q.repeat = FDMMR_OFF;
    q.idx = 2;
    if (!ms_chk(errbuf, errlen, 6, "OFF 最后一首自动应停",
                fdmmusic_next_index(&q, 0) == -1)) return 6;
    q.idx = 0;
    if (!ms_chk(errbuf, errlen, 7, "OFF 第一首应下一首",
                fdmmusic_next_index(&q, 1) == 1)) return 7;

    /* 6. repeat=ONE */
    q.repeat = FDMMR_ONE;
    q.idx = 1;
    if (!ms_chk(errbuf, errlen, 8, "ONE 自动应原地",
                fdmmusic_next_index(&q, 0) == 1)) return 8;
    if (!ms_chk(errbuf, errlen, 9, "ONE 手动应换歌",
                fdmmusic_next_index(&q, 1) == 2)) return 9;
    q.idx = 2;
    if (!ms_chk(errbuf, errlen, 10, "ONE 手动到尾巴应绕回",
                fdmmusic_next_index(&q, 1) == 0)) return 10;

    /* 7. prev */
    q.repeat = FDMMR_ALL; q.idx = 0;
    if (!ms_chk(errbuf, errlen, 11, "ALL prev 应绕到尾巴",
                fdmmusic_prev_index(&q) == 2)) return 11;
    q.repeat = FDMMR_OFF;
    if (!ms_chk(errbuf, errlen, 12, "OFF prev 在第一首应 -1",
                fdmmusic_prev_index(&q) == -1)) return 12;
    q.idx = 1;
    if (!ms_chk(errbuf, errlen, 13, "prev 正常退一首",
                fdmmusic_prev_index(&q) == 0)) return 13;

    /* 8. shuffle_pick 永不返回 avoid */
    for (i = 0; i < 64; i++) {
        int k = fdmmusic_shuffle_pick((unsigned)(i * 7919u + 13u), 3, 1);
        if (k < 0 || k > 2 || k == 1) {
            snprintf(errbuf, (size_t)errlen, "#14 shuffle_pick 撞到 avoid (i=%d k=%d)", i, k);
            return 14;
        }
    }
    if (!ms_chk(errbuf, errlen, 15, "shuffle_pick 单元素",
                fdmmusic_shuffle_pick(1u, 1, 0) == 0 &&
                fdmmusic_shuffle_pick(1u, 0, 0) == -1)) return 15;

    /* 9. 空队列切歌 */
    fdmmusic_queue empty;
    fdmmusic_init(&empty);
    if (!ms_chk(errbuf, errlen, 16, "空队列 next/prev 应 -1",
                fdmmusic_next_index(&empty, 1) == -1 &&
                fdmmusic_prev_index(&empty) == -1)) return 16;

    /* 10. set_queue 夹紧 */
    fdmmusic_track arr[2];
    memset(arr, 0, sizeof(arr));
    arr[0].id = 7; arr[0].name = "A";
    arr[1].id = 8; arr[1].name = "B";
    if (!ms_chk(errbuf, errlen, 17, "set_queue 返回",
                fdmmusic_set_queue(&empty, arr, 2, 99) == 0)) return 17;
    if (!ms_chk(errbuf, errlen, 18, "set_queue 应夹到最后一首",
                empty.count == 2 && empty.idx == 1 &&
                empty.state == FDMMS_LOADING)) return 18;

    /* 11. remove 三种情况 */
    q.repeat = FDMMR_ALL; q.idx = 1;                 /* 3 首，当前第 2 首 */
    fdmmusic_remove(&q, 0);                          /* 删前头的 */
    if (!ms_chk(errbuf, errlen, 19, "remove 前头：当前下标应前移",
                q.count == 2 && q.idx == 0 && q.items[0].id == 222)) return 19;
    fdmmusic_remove(&q, 0);                          /* 删当前曲，后面还有 */
    if (!ms_chk(errbuf, errlen, 20, "remove 当前：应顺位接上",
                q.count == 1 && q.idx == 0 && q.items[0].id == 333 &&
                q.state == FDMMS_LOADING)) return 20;
    fdmmusic_remove(&q, 0);                          /* 删光 */
    if (!ms_chk(errbuf, errlen, 21, "remove 最后一首：应 STOPPED",
                q.count == 0 && q.idx == -1 && q.state == FDMMS_STOPPED)) return 21;

    /* 12. fmt_time */
    {
        char b[32];
        fdmmusic_fmt_time(0, b, sizeof(b));
        if (!ms_chk(errbuf, errlen, 22, "fmt 0", strcmp(b, "0:00") == 0)) return 22;
        fdmmusic_fmt_time(62000, b, sizeof(b));
        if (!ms_chk(errbuf, errlen, 23, "fmt 1:02", strcmp(b, "1:02") == 0)) return 23;
        fdmmusic_fmt_time(3723000, b, sizeof(b));
        if (!ms_chk(errbuf, errlen, 24, "fmt 1:02:03", strcmp(b, "1:02:03") == 0)) return 24;
        fdmmusic_fmt_time(-5000, b, sizeof(b));
        if (!ms_chk(errbuf, errlen, 25, "fmt 负数", strcmp(b, "0:00") == 0)) return 25;
    }

    /* 13. quality / vol / repeat 轮转 */
    if (!ms_chk(errbuf, errlen, 26, "quality 降级链",
                fdmmusic_quality_downgrade(FDMMQ_LOSSLESS) == FDMMQ_EXHIGH &&
                fdmmusic_quality_downgrade(FDMMQ_EXHIGH) == FDMMQ_HIGHER &&
                fdmmusic_quality_downgrade(FDMMQ_HIGHER) == FDMMQ_STANDARD &&
                fdmmusic_quality_downgrade(FDMMQ_STANDARD) == FDMMQ_STANDARD)) return 26;
    if (!ms_chk(errbuf, errlen, 27, "quality 名字",
                strcmp(fdmmusic_quality_name(FDMMQ_LOSSLESS), "lossless") == 0 &&
                strcmp(fdmmusic_quality_name(99), "exhigh") == 0)) return 27;
    if (!ms_chk(errbuf, errlen, 28, "vol 夹紧",
                fdmmusic_clamp_vol(-5) == 0 && fdmmusic_clamp_vol(150) == 100 &&
                fdmmusic_clamp_vol(42) == 42)) return 28;
    if (!ms_chk(errbuf, errlen, 29, "repeat 轮转",
                fdmmusic_repeat_next(FDMMR_OFF) == FDMMR_ALL &&
                fdmmusic_repeat_next(FDMMR_ALL) == FDMMR_ONE &&
                fdmmusic_repeat_next(FDMMR_ONE) == FDMMR_OFF)) return 29;

    /* 14. JSON 往返（含中文 + 需要转义的字符） */
    {
        fdmmusic_queue a, b;
        fdmmusic_init(&a);
        memset(&t, 0, sizeof(t));
        t.id = 186016; t.name = "晴天 \"Live\""; t.artist = "周杰伦";
        t.album = "叶惠美\\2003"; t.duration_ms = 269000; t.fee = 1;
        fdmmusic_push(&a, &t);
        t.id = 185809; t.name = "稻香"; t.artist = "周杰伦"; t.album = "魔杰座";
        fdmmusic_push(&a, &t);
        a.idx = 1; a.pos_ms = 65000; a.repeat = FDMMR_ONE;
        a.shuffle = 1; a.vol = 55; a.quality = FDMMQ_STANDARD;

        char *js = fdmmusic_to_json(&a);
        if (!ms_chk(errbuf, errlen, 30, "to_json 返回 NULL", js != NULL)) {
            free(js); fdmmusic_free(&a); return 30;
        }
        if (!ms_chk(errbuf, errlen, 31, "to_json 不该含 pic（版权）",
                    strstr(js, ".jpg") == NULL && strstr(js, "http") == NULL)) {
            free(js); fdmmusic_free(&a); return 31;
        }

        fdmmusic_init(&b);
        int rc = fdmmusic_from_json(&b, js);
        free(js);
        if (!ms_chk(errbuf, errlen, 32, "from_json 应成功", rc == 0)) {
            fdmmusic_free(&a); fdmmusic_free(&b); return 32;
        }
        if (!ms_chk(errbuf, errlen, 33, "往返：数量/下标/偏好",
                    b.count == 2 && b.idx == 1 && b.pos_ms == 65000 &&
                    b.repeat == FDMMR_ONE && b.shuffle == 1 &&
                    b.vol == 55 && b.quality == FDMMQ_STANDARD)) {
            fdmmusic_free(&a); fdmmusic_free(&b); return 33;
        }
        if (!ms_chk(errbuf, errlen, 34, "往返：转义字符还原",
                    strcmp(b.items[0].name, "晴天 \"Live\"") == 0 &&
                    strcmp(b.items[0].album, "叶惠美\\2003") == 0)) {
            fdmmusic_free(&a); fdmmusic_free(&b); return 34;
        }
        if (!ms_chk(errbuf, errlen, 35, "往返：重启后应是 PAUSED 不是 PLAYING",
                    b.state == FDMMS_PAUSED)) {
            fdmmusic_free(&a); fdmmusic_free(&b); return 35;
        }
        fdmmusic_free(&a);
        fdmmusic_free(&b);
    }

    /* 15. 坏 JSON 容错 */
    {
        fdmmusic_queue c;
        fdmmusic_init(&c);
        if (!ms_chk(errbuf, errlen, 36, "空串应 -1",
                    fdmmusic_from_json(&c, "") == -1)) return 36;
        if (!ms_chk(errbuf, errlen, 37, "乱码应 -1 且不崩",
                    fdmmusic_from_json(&c, "\x01\x02 {{{") == -1)) return 37;
        if (!ms_chk(errbuf, errlen, 38, "截断应 -1 且不崩",
                    fdmmusic_from_json(&c, "{\"idx\":0,\"items\":[{\"id\":1,") == -1)) return 38;

        /* 字段缺失 / 类型不对 ⇒ 用默认值 */
        int rc2 = fdmmusic_from_json(&c,
            "{\"idx\":\"abc\",\"vol\":999,\"repeat\":77,\"quality\":-3,"
            "\"items\":[{\"id\":1,\"n\":\"只有名字\"},{\"id\":2}]}");
        if (!ms_chk(errbuf, errlen, 39, "缺字段应能恢复",
                    rc2 == 0 && c.count == 2)) return 39;
        if (!ms_chk(errbuf, errlen, 40, "坏值应回到安全范围",
                    c.vol == 100 && c.repeat == FDMMR_ONE &&
                    c.quality == FDMMQ_LOSSLESS && c.idx == 0)) return 40;
        if (!ms_chk(errbuf, errlen, 41, "缺名字应是空串不是 NULL",
                    c.items[1].name && c.items[1].name[0] == '\0' &&
                    c.items[1].artist && c.items[1].artist[0] == '\0')) return 41;

        /* 下标越界 ⇒ 夹紧 */
        fdmmusic_free(&c);
        fdmmusic_init(&c);
        fdmmusic_from_json(&c, "{\"idx\":99,\"items\":[{\"id\":5,\"n\":\"x\"}]}");
        if (!ms_chk(errbuf, errlen, 42, "idx 越界应夹到最后一个",
                    c.idx == 0 && c.count == 1)) return 42;
        fdmmusic_free(&c);
    }

    /* 16. 未知键 + 嵌套对象不能把解析带跑偏 */
    {
        fdmmusic_queue d;
        fdmmusic_init(&d);
        int rc3 = fdmmusic_from_json(&d,
            "{\"zzz\":{\"idx\":1},\"idx\":0,\"items\":["
            "{\"id\":10,\"meta\":{\"name\":\"陷阱\"},\"n\":\"真的名字\"}]}");
        if (!ms_chk(errbuf, errlen, 43, "未知/嵌套键应被跳过",
                    rc3 == 0 && d.count == 1 &&
                    strcmp(d.items[0].name, "真的名字") == 0)) return 43;
        fdmmusic_free(&d);
    }

    /* 17. 超长字段不越界 */
    {
        fdmmusic_queue e;
        fdmmusic_init(&e);
        char big[1024];
        memset(big, 'A', sizeof(big) - 1);
        big[sizeof(big) - 1] = '\0';
        char js2[1200];
        snprintf(js2, sizeof(js2), "{\"items\":[{\"id\":1,\"n\":\"%s\"}]}", big);
        int rc4 = fdmmusic_from_json(&e, js2);
        if (!ms_chk(errbuf, errlen, 44, "超长字段应完整读入",
                    rc4 == 0 && e.count == 1 &&
                    strlen(e.items[0].name) == sizeof(big) - 1)) return 44;
        fdmmusic_free(&e);
    }

    /* 18. free 可重复调用 & 空队列 JSON 往返 */
    {
        fdmmusic_queue f;
        fdmmusic_init(&f);
        fdmmusic_free(&f);
        fdmmusic_free(&f);
        char *js3 = fdmmusic_to_json(&f);
        if (!ms_chk(errbuf, errlen, 45, "空队列也能 to_json", js3 != NULL)) {
            free(js3); return 45;
        }
        fdmmusic_queue g;
        fdmmusic_init(&g);
        int rc5 = fdmmusic_from_json(&g, js3);
        free(js3);
        if (!ms_chk(errbuf, errlen, 46, "空队列往返应 -1 但不崩",
                    (rc5 == -1 || rc5 == 0) && g.count == 0 && g.idx == -1)) return 46;
        fdmmusic_free(&g);
    }

    /* 19. is_active */
    {
        fdmmusic_queue h;
        fdmmusic_init(&h);
        h.state = FDMMS_PLAYING;
        int a1 = fdmmusic_is_active(&h);
        h.state = FDMMS_PAUSED;
        int a2 = fdmmusic_is_active(&h);
        h.state = FDMMS_LOADING;
        int a3 = fdmmusic_is_active(&h);
        h.state = FDMMS_ERROR;
        int a4 = fdmmusic_is_active(&h);
        if (!ms_chk(errbuf, errlen, 47, "is_active",
                    a1 == 1 && a2 == 0 && a3 == 1 && a4 == 0)) return 47;
    }

    return 0;
}
