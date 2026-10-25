// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMNoteModel.c —— 见 FDMNoteModel.h
#include "FDMNoteModel.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ══════════════════════════════════ 小工具 ══════════════════════════════════ */

static char *nm_strdup(const char *s) {
    if (!s) s = "";
    size_t n = strlen(s);
    char *p = (char *)malloc(n + 1);
    if (!p) return NULL;
    memcpy(p, s, n + 1);
    return p;
}

static int bad_num(double v) {
    if (v != v) return 1;
    if (v > 1e18 || v < -1e18) return 1;
    return 0;
}

/* ══════════════════════════════════ 生命周期 ══════════════════════════════════ */

void fdmnote_free(fdmnote_state *st) {
    if (!st) return;
    if (st->items) {
        for (size_t i = 0; i < st->count; i++) {
            free(st->items[i].text);
            st->items[i].text = NULL;
        }
        free(st->items);
    }
    st->items = NULL;
    st->count = 0;
    st->capacity = 0;
    st->idx = 0;
    st->minimized = 0;
}

static int reserve(fdmnote_state *st, size_t need) {
    if (need <= st->capacity) return 1;
    size_t cap = st->capacity ? st->capacity : 4;
    while (cap < need) cap *= 2;
    fdmnote_item *n = (fdmnote_item *)realloc(st->items, cap * sizeof(fdmnote_item));
    if (!n) return 0;
    st->items = n;
    st->capacity = cap;
    return 1;
}

static int push_item(fdmnote_state *st, const char *text, double x, double y) {
    if (!reserve(st, st->count + 1)) return 0;
    fdmnote_item *it = &st->items[st->count];
    it->text = nm_strdup(text ? text : "");
    if (!it->text) return 0;
    it->x = bad_num(x) ? 0.0 : x;
    it->y = bad_num(y) ? 0.0 : y;
    it->w = 0.0;          /* 0 = 默认宽（由 UI 层决定）*/
    it->h = 0.0;          /* 0 = 按内容自动算高 */
    st->count++;
    return 1;
}

int fdmnote_init(fdmnote_state *st) {
    if (!st) return -1;
    memset(st, 0, sizeof(*st));
    if (!push_item(st, FDMNOTE_DEFAULT_TEXT, 40, 160)) {
        fdmnote_free(st);
        return -2;
    }
    st->idx = 0;
    st->minimized = 0;
    return 0;
}

/* ══════════════════════════════════ 极简 JSON ══════════════════════════════════
 *
 *  存档形状（固定，不需要通用解析器）：
 *    {"idx":0,"min":false,"items":[{"t":"文字","x":120,"y":300}, ...]}
 *
 *  iOS 上有 NSJSONSerialization，但这份要塞进纯 C 内核才能在小窝里测。
 */

typedef struct {
    const char *s;
    size_t i;
    size_t n;
} jp;

static void jp_ws(jp *p) {
    while (p->i < p->n) {
        char c = p->s[p->i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') p->i++;
        else break;
    }
}

static int jp_eat(jp *p, char c) {
    jp_ws(p);
    if (p->i < p->n && p->s[p->i] == c) { p->i++; return 1; }
    return 0;
}

static int jp_peek(jp *p) {
    jp_ws(p);
    return p->i < p->n ? (unsigned char)p->s[p->i] : -1;
}

/** 读字符串到 out（malloc）。返回 1 成功。 */
static int jp_string(jp *p, char **out) {
    *out = NULL;
    if (!jp_eat(p, '"')) return 0;

    size_t start = p->i;
    size_t len = 0;
    size_t k = start;
    while (k < p->n) {
        char c = p->s[k];
        if (c == '"') break;
        if (c == '\\' && k + 1 < p->n) { k += 2; len++; continue; }
        k++;
        len++;
    }
    if (k >= p->n) return 0;

    char *buf = (char *)malloc(len + 1);
    if (!buf) return 0;
    size_t o = 0;
    k = start;
    while (k < p->n && p->s[k] != '"') {
        char c = p->s[k];
        if (c == '\\' && k + 1 < p->n) {
            char e = p->s[k + 1];
            if (e == 'n') { buf[o++] = '\n'; k += 2; continue; }
            if (e == 't') { buf[o++] = '\t'; k += 2; continue; }
            if (e == 'r') { buf[o++] = '\r'; k += 2; continue; }
            if (e == '"') { buf[o++] = '"';  k += 2; continue; }
            if (e == '\\'){ buf[o++] = '\\'; k += 2; continue; }
            if (e == '/') { buf[o++] = '/';  k += 2; continue; }
            if (e == 'u') {
                /* \uXXXX —— 只处理 BMP，够用（存的是用户自己的字）*/
                unsigned v = 0;
                int j, ok = 1;
                for (j = 0; j < 4; j++) {
                    size_t idx = k + 2 + (size_t)j;
                    if (idx >= p->n) { ok = 0; break; }
                    char h = p->s[idx];
                    unsigned d;
                    if (h >= '0' && h <= '9') d = (unsigned)(h - '0');
                    else if (h >= 'a' && h <= 'f') d = (unsigned)(h - 'a' + 10);
                    else if (h >= 'A' && h <= 'F') d = (unsigned)(h - 'A' + 10);
                    else { ok = 0; break; }
                    v = v * 16 + d;
                }
                if (ok) {
                    if (v < 0x80) {
                        buf[o++] = (char)v;
                    } else if (v < 0x800) {
                        buf[o++] = (char)(0xC0 | (v >> 6));
                        buf[o++] = (char)(0x80 | (v & 0x3F));
                    } else {
                        buf[o++] = (char)(0xE0 | (v >> 12));
                        buf[o++] = (char)(0x80 | ((v >> 6) & 0x3F));
                        buf[o++] = (char)(0x80 | (v & 0x3F));
                    }
                    k += 6;
                    continue;
                }
                buf[o++] = '?';
                k += 2;
                continue;
            }
            buf[o++] = e;
            k += 2;
            continue;
        }
        buf[o++] = c;
        k++;
    }
    buf[o] = '\0';
    p->i = (k < p->n) ? k + 1 : k;
    *out = buf;
    return 1;
}

static int jp_number(jp *p, double *out) {
    jp_ws(p);
    size_t start = p->i;
    if (p->i < p->n && (p->s[p->i] == '-' || p->s[p->i] == '+')) p->i++;
    int digits = 0;
    while (p->i < p->n) {
        char c = p->s[p->i];
        if (c >= '0' && c <= '9') { digits++; p->i++; }
        else if (c == '.' || c == 'e' || c == 'E' || c == '-' || c == '+') p->i++;
        else break;
    }
    if (!digits) { p->i = start; return 0; }
    char tmp[64];
    size_t len = p->i - start;
    if (len >= sizeof(tmp)) len = sizeof(tmp) - 1;
    memcpy(tmp, p->s + start, len);
    tmp[len] = '\0';
    double v = strtod(tmp, NULL);
    if (bad_num(v)) return 0;
    *out = v;
    return 1;
}

static int jp_bool(jp *p, int *out) {
    jp_ws(p);
    if (p->i + 4 <= p->n && strncmp(p->s + p->i, "true", 4) == 0) { p->i += 4; *out = 1; return 1; }
    if (p->i + 5 <= p->n && strncmp(p->s + p->i, "false", 5) == 0) { p->i += 5; *out = 0; return 1; }
    return 0;
}

/** 跳过一个值（未知键用）。 */
static void jp_skip_value(jp *p) {
    int c = jp_peek(p);
    if (c == '"') {
        char *skip = NULL;
        if (jp_string(p, &skip)) free(skip);
        return;
    }
    if (c == '{' || c == '[') {
        char open = (char)c;
        char close = (open == '{') ? '}' : ']';
        int depth = 0;
        while (p->i < p->n) {
            char ch = p->s[p->i++];
            if (ch == open) depth++;
            else if (ch == close) { depth--; if (depth == 0) break; }
        }
        return;
    }
    double dv;
    int bv;
    if (!jp_number(p, &dv)) jp_bool(p, &bv);
}

/* ══════════════════════════════════ 解析 / 序列化 ══════════════════════════════════ */

int fdmnote_parse(const char *json, fdmnote_state *st) {
    if (!st) return -1;

    /* 先给一份可用默认值 —— 后面任何一步失败都保留它，
     * 「存档烂了」绝不能等于「功能消失」。 */
    if (fdmnote_init(st) != 0) return -2;
    if (!json) return 0;

    jp p;
    p.s = json;
    p.i = 0;
    p.n = strlen(json);

    if (!jp_eat(&p, '{')) return 0;

    int have_idx = 0, have_min = 0;
    int idx_v = 0, min_v = 0;
    int items_read = 0;

    while (jp_peek(&p) == '"') {
        char *key = NULL;
        if (!jp_string(&p, &key)) break;
        if (!jp_eat(&p, ':')) { free(key); break; }

        if (strcmp(key, "idx") == 0) {
            double v;
            if (jp_number(&p, &v)) { idx_v = (int)v; have_idx = 1; }
        } else if (strcmp(key, "min") == 0 || strcmp(key, "minimized") == 0) {
            int v;
            if (jp_bool(&p, &v)) { min_v = v; have_min = 1; }
        } else if (strcmp(key, "items") == 0) {
            if (jp_eat(&p, '[')) {
                while (jp_peek(&p) == '{') {
                    if (!items_read) {
                        /* 读到第一个真 item 才丢弃 init 给的默认那张 */
                        for (size_t k = 0; k < st->count; k++) free(st->items[k].text);
                        st->count = 0;
                        items_read = 1;
                    }
                    p.i++;   /* '{' */
                    char *text = NULL;
                    double x = 0, y = 0, iw = 0, ih = 0;
                    int has_text = 0;
                    while (jp_peek(&p) == '"') {
                        char *ik = NULL;
                        if (!jp_string(&p, &ik)) break;
                        if (!jp_eat(&p, ':')) { free(ik); break; }
                        if (strcmp(ik, "t") == 0 || strcmp(ik, "text") == 0) {
                            free(text);
                            has_text = jp_string(&p, &text);
                        } else if (strcmp(ik, "x") == 0) {
                            jp_number(&p, &x);
                        } else if (strcmp(ik, "y") == 0) {
                            jp_number(&p, &y);
                        } else if (strcmp(ik, "w") == 0) {
                            jp_number(&p, &iw);
                        } else if (strcmp(ik, "h") == 0) {
                            jp_number(&p, &ih);
                        } else {
                            jp_skip_value(&p);
                        }
                        free(ik);
                        jp_eat(&p, ',');
                    }
                    jp_eat(&p, '}');
                    if (items_read) {
                        if (push_item(st, has_text ? text : "", x, y)) {
                            fdmnote_item *last = &st->items[st->count - 1];
                            last->w = bad_num(iw) || iw < 0 ? 0.0 : iw;
                            last->h = bad_num(ih) || ih < 0 ? 0.0 : ih;
                        }
                    }
                    free(text);
                    jp_eat(&p, ',');
                }
                jp_eat(&p, ']');
            }
        } else {
            jp_skip_value(&p);
        }
        free(key);
        jp_eat(&p, ',');
    }

    /* idx 夹紧 */
    if (have_idx) {
        if (idx_v < 0) idx_v = 0;
        if ((size_t)idx_v >= st->count) idx_v = (int)(st->count ? st->count - 1 : 0);
        st->idx = idx_v;
    }
    if (have_min) st->minimized = min_v ? 1 : 0;

    /* 一条都没有（items 是空数组 / 全被过滤）=> 至少留一张 */
    if (st->count == 0) {
        if (!push_item(st, FDMNOTE_DEFAULT_TEXT, 40, 160)) return -2;
        st->idx = 0;
    }
    return 0;
}

static void put_need(char **buf, size_t *len, size_t *cap, size_t add) {
    size_t need = *len + add + 1;
    if (need <= *cap) return;
    size_t nc = *cap ? *cap * 2 : 256;
    while (nc < need) nc *= 2;
    char *nb = (char *)realloc(*buf, nc);
    if (!nb) return;
    *buf = nb;
    *cap = nc;
}

static void put_escaped(char **buf, size_t *len, size_t *cap, const char *s) {
    if (!s) s = "";
    for (const char *p = s; *p; p++) {
        unsigned char c = (unsigned char)*p;
        const char *rep = NULL;
        char tmp[8];
        switch (c) {
            case '"':  rep = "\\\""; break;
            case '\\': rep = "\\\\"; break;
            case '\n': rep = "\\n";  break;
            case '\r': rep = "\\r";  break;
            case '\t': rep = "\\t";  break;
            default:
                if (c < 0x20) {
                    snprintf(tmp, sizeof(tmp), "\\u%04x", c);
                    rep = tmp;
                }
                break;
        }
        size_t rl = rep ? strlen(rep) : 1;
        put_need(buf, len, cap, rl);
        if (!*buf) return;
        if (rep) memcpy(*buf + *len, rep, rl);
        else (*buf)[(*len)] = (char)c;
        *len += rl;
    }
}

static void put_raw(char **buf, size_t *len, size_t *cap, const char *s) {
    size_t sl = strlen(s);
    put_need(buf, len, cap, sl);
    if (!*buf) return;
    memcpy(*buf + *len, s, sl);
    *len += sl;
}

char *fdmnote_serialize(const fdmnote_state *st) {
    char *buf = NULL;
    size_t len = 0, cap = 0;
    if (!st) return nm_strdup("{}");

    char tmp[80];
    snprintf(tmp, sizeof(tmp), "{\"idx\":%d,\"min\":%s,\"items\":[",
             st->idx, st->minimized ? "true" : "false");
    put_raw(&buf, &len, &cap, tmp);

    for (size_t i = 0; i < st->count; i++) {
        if (i) put_raw(&buf, &len, &cap, ",");
        put_raw(&buf, &len, &cap, "{\"t\":\"");
        put_escaped(&buf, &len, &cap, st->items[i].text);
        snprintf(tmp, sizeof(tmp), "\",\"x\":%.1f,\"y\":%.1f,\"w\":%.1f,\"h\":%.1f}",
                 st->items[i].x, st->items[i].y, st->items[i].w, st->items[i].h);
        put_raw(&buf, &len, &cap, tmp);
    }
    put_raw(&buf, &len, &cap, "]}");
    if (!buf) return NULL;
    buf[len] = '\0';
    return buf;
}

/* ══════════════════════════════════ 操作 ══════════════════════════════════ */

fdmnote_item *fdmnote_current(fdmnote_state *st) {
    static char fb_text[] = FDMNOTE_DEFAULT_TEXT;
    static fdmnote_item fallback = {fb_text, 40, 160, 0, 0};
    if (!st || st->count == 0) return &fallback;
    if (st->idx < 0) st->idx = 0;
    if ((size_t)st->idx >= st->count) st->idx = (int)(st->count - 1);
    return &st->items[st->idx];
}

int fdmnote_add(fdmnote_state *st, const char *text, double x, double y) {
    if (!st) return -1;
    if (!push_item(st, text ? text : FDMNOTE_DEFAULT_TEXT, x, y)) return -1;
    st->idx = (int)(st->count - 1);
    return st->idx;
}

void fdmnote_delete_current(fdmnote_state *st) {
    if (!st || st->count == 0) return;
    if (st->idx < 0) st->idx = 0;
    if ((size_t)st->idx >= st->count) st->idx = (int)(st->count - 1);

    if (st->count == 1) {
        /* 只剩一张：清空文字而不是变成 0 张 ——
         * 否则界面会出现「一张便签都没有」的空悬浮层，很奇怪 */
        free(st->items[0].text);
        st->items[0].text = nm_strdup(FDMNOTE_DEFAULT_TEXT);
        st->idx = 0;
        return;
    }

    free(st->items[st->idx].text);
    memmove(&st->items[st->idx], &st->items[st->idx + 1],
            (st->count - (size_t)st->idx - 1) * sizeof(fdmnote_item));
    st->count--;
    if ((size_t)st->idx >= st->count) st->idx = (int)(st->count - 1);
}

void fdmnote_step(fdmnote_state *st, int delta) {
    if (!st || st->count == 0 || delta == 0) return;
    int n = (int)st->count;
    int i = st->idx + delta;
    i %= n;
    if (i < 0) i += n;
    st->idx = i;
}

int fdmnote_set_text(fdmnote_state *st, const char *text) {
    if (!st || st->count == 0) return -1;
    fdmnote_current(st);          /* 夹紧 idx */
    char *t = nm_strdup(text ? text : "");
    if (!t) return -1;
    free(st->items[st->idx].text);
    st->items[st->idx].text = t;
    return 0;
}

void fdmnote_set_size(fdmnote_state *st, double w, double h) {
    if (!st || st->count == 0) return;
    fdmnote_current(st);
    st->items[st->idx].w = (bad_num(w) || w <= 0) ? 0.0 : w;
    st->items[st->idx].h = (bad_num(h) || h <= 0) ? 0.0 : h;
}

void fdmnote_set_pos(fdmnote_state *st, double x, double y) {
    if (!st || st->count == 0) return;
    fdmnote_current(st);
    st->items[st->idx].x = bad_num(x) ? 0.0 : x;
    st->items[st->idx].y = bad_num(y) ? 0.0 : y;
}

/* ══════════════════════════════════ 夹紧 ══════════════════════════════════ */

void fdmnote_clamp(double *inout_x, double *inout_y,
                   double w, double h, double pw, double ph) {
    if (!inout_x || !inout_y) return;

    if (bad_num(*inout_x)) *inout_x = 0;
    if (bad_num(*inout_y)) *inout_y = 0;

    /* 尺寸无效就没法夹（只把 NaN 清掉）*/
    if (bad_num(w) || bad_num(h) || bad_num(pw) || bad_num(ph) ||
        w <= 0 || h <= 0 || pw <= 0 || ph <= 0) {
        return;
    }

    /* 与安卓 GmNoteView.clamp() 一致：允许一半出屏，但拖不丢 */
    double minX = -w * 0.5;
    double maxX = pw - w * 0.5;
    double minY = 0.0;
    double maxY = ph - h * 0.5;

    /* 屏幕比控件还窄的极端情况：max < min => 退化成居中 */
    if (maxX < minX) { minX = (pw - w) * 0.5; maxX = minX; }
    if (maxY < minY) maxY = minY;

    if (*inout_x < minX) *inout_x = minX;
    if (*inout_x > maxX) *inout_x = maxX;
    if (*inout_y < minY) *inout_y = minY;
    if (*inout_y > maxY) *inout_y = maxY;
}

/* ══════════════════════════════════ 自检 ══════════════════════════════════ */

#define NCHK(no, cond, ...)                                   \
    do {                                                      \
        if (!(cond)) {                                        \
            snprintf(errbuf, (size_t)errlen, __VA_ARGS__);    \
            return no;                                        \
        }                                                     \
    } while (0)

int fdmnote_selftest(char *errbuf, int errlen) {
    char local[512];
    if (!errbuf) { errbuf = local; errlen = (int)sizeof(local); }
    errbuf[0] = '\0';

    fdmnote_state st;
    char *js;
    int ni;

    /* 1. init */
    if (fdmnote_init(&st) != 0) {
        snprintf(errbuf, (size_t)errlen, "#1 init 失败");
        return 1;
    }
    NCHK(1, st.count == 1, "#1 init 应有 1 张，得到 %zu", st.count);
    NCHK(1, st.idx == 0 && st.minimized == 0, "#1 idx/min 不对");
    NCHK(1, st.items[0].text && *st.items[0].text, "#1 默认文字为空");
    NCHK(1, st.capacity >= 1, "#1 capacity 未分配");

    /* 2. add */
    ni = fdmnote_add(&st, "second", 10, 20);
    NCHK(2, ni == 1 && st.count == 2, "#2 add 后 count=%zu idx=%d", st.count, st.idx);
    NCHK(2, strcmp(st.items[1].text, "second") == 0, "#2 文字不对");
    NCHK(2, st.items[1].x == 10 && st.items[1].y == 20, "#2 坐标不对");

    /* 3. step 环绕 */
    fdmnote_step(&st, 1);
    NCHK(3, st.idx == 0, "#3 +1 应回到 0，得到 %d", st.idx);
    fdmnote_step(&st, -1);
    NCHK(3, st.idx == 1, "#3 -1 应回到 1，得到 %d", st.idx);
    fdmnote_step(&st, 5);          /* 2 张，+5 ≡ +1 */
    NCHK(3, st.idx == 0, "#3 +5 (2 张) 应到 0，得到 %d", st.idx);
    fdmnote_step(&st, 0);
    NCHK(3, st.idx == 0, "#3 +0 不该动");

    /* 4. set_text */
    NCHK(4, fdmnote_set_text(&st, "hello") == 0, "#4 set_text 失败");
    NCHK(4, strcmp(st.items[0].text, "hello") == 0, "#4 文字没改到");

    /* 5. set_pos */
    fdmnote_set_pos(&st, 88, 99);
    NCHK(5, st.items[st.idx].x == 88 && st.items[st.idx].y == 99, "#5 坐标没改到");

    /* 6. 序列化再解析（往返）*/
    st.minimized = 1;
    js = fdmnote_serialize(&st);
    NCHK(6, js != NULL, "#6 serialize 返回 NULL");
    {
        fdmnote_state st2;
        NCHK(6, fdmnote_parse(js, &st2) == 0, "#6 parse 失败");
        NCHK(6, st2.count == 2, "#6 往返 count=%zu（应 2）", st2.count);
        NCHK(6, strcmp(st2.items[0].text, "hello") == 0, "#6 往返文字1 不对：「%s」",
             st2.items[0].text);
        NCHK(6, strcmp(st2.items[1].text, "second") == 0, "#6 往返文字2 不对：「%s」",
             st2.items[1].text);
        NCHK(6, st2.items[0].x == 88 && st2.items[0].y == 99, "#6 往返坐标不对");
        NCHK(6, st2.minimized == 1, "#6 往返 min 丢了");
        NCHK(6, st2.idx == st.idx, "#6 往返 idx 不对（%d vs %d）", st2.idx, st.idx);
        fdmnote_free(&st2);
    }
    free(js);

    /* 7. 特殊字符转义往返 */
    {
        fdmnote_state a, b;
        char *s2;
        fdmnote_init(&a);
        fdmnote_set_text(&a, "引号\" 反斜杠\\ 换行\n tab\t");
        s2 = fdmnote_serialize(&a);
        fdmnote_parse(s2, &b);
        NCHK(7, strcmp(b.items[0].text, "引号\" 反斜杠\\ 换行\n tab\t") == 0,
             "#7 转义往返失败：「%s」", b.items[0].text);
        free(s2);
        fdmnote_free(&a);
        fdmnote_free(&b);
    }

    /* 8. 中文 + emoji 往返 */
    {
        fdmnote_state a, b;
        char *s2;
        fdmnote_init(&a);
        fdmnote_set_text(&a, "买牛奶 🥛 三点前");
        s2 = fdmnote_serialize(&a);
        fdmnote_parse(s2, &b);
        NCHK(8, strcmp(b.items[0].text, "买牛奶 🥛 三点前") == 0,
             "#8 中文往返失败：「%s」", b.items[0].text);
        free(s2);
        fdmnote_free(&a);
        fdmnote_free(&b);
    }

    /* 9. 垃圾 JSON => 默认状态（不是空、不崩）*/
    {
        const char *junk[] = {
            "", "{", "[]", "null", "{{{", "{\"items\":", "not json at all",
            "{\"idx\":\"x\"}", "{\"items\":[{}]}", "{\"items\":[]}", "}{",
            "{\"items\":[{\"t\":}]}",
        };
        size_t i;
        for (i = 0; i < sizeof(junk) / sizeof(junk[0]); i++) {
            fdmnote_state t;
            int rc = fdmnote_parse(junk[i], &t);
            NCHK(9, rc == 0, "#9 垃圾「%s」应返回 0，得到 %d", junk[i], rc);
            NCHK(9, t.count >= 1, "#9 垃圾「%s」必须至少留一张", junk[i]);
            NCHK(9, t.idx >= 0 && (size_t)t.idx < t.count,
                 "#9 垃圾「%s」idx 越界（count=%zu idx=%d）", junk[i], t.count, t.idx);
            NCHK(9, t.items[t.idx].text != NULL, "#9 垃圾「%s」text 为 NULL", junk[i]);
            fdmnote_free(&t);
        }
    }

    /* 10. idx 越界被夹 */
    {
        fdmnote_state t;
        fdmnote_parse("{\"idx\":99,\"items\":[{\"t\":\"a\",\"x\":0,\"y\":0}]}", &t);
        NCHK(10, t.count == 1 && t.idx == 0, "#10 idx=99 应夹到 0（count=%zu idx=%d）",
             t.count, t.idx);
        fdmnote_free(&t);
        fdmnote_parse("{\"idx\":-5,\"items\":[{\"t\":\"a\",\"x\":0,\"y\":0}]}", &t);
        NCHK(10, t.idx == 0, "#10 idx=-5 应夹到 0，得到 %d", t.idx);
        fdmnote_free(&t);
    }

    /* 11. 缺字段用默认 */
    {
        fdmnote_state t;
        fdmnote_parse("{\"items\":[{\"t\":\"只有文字\"}]}", &t);
        NCHK(11, t.count == 1, "#11 count 不对（%zu）", t.count);
        NCHK(11, t.items[0].x == 0 && t.items[0].y == 0, "#11 缺坐标应为 0");
        fdmnote_free(&t);
    }

    /* 12. delete 到只剩一张 => 清空文字而不是变 0 张 */
    {
        fdmnote_state t;
        fdmnote_init(&t);
        fdmnote_add(&t, "b", 1, 2);
        fdmnote_add(&t, "c", 3, 4);
        NCHK(12, t.count == 3, "#12 前置失败 count=%zu", t.count);
        fdmnote_delete_current(&t);
        NCHK(12, t.count == 2, "#12 删一张后 count=%zu", t.count);
        fdmnote_delete_current(&t);
        NCHK(12, t.count == 1, "#12 再删 count=%zu", t.count);
        fdmnote_delete_current(&t);
        NCHK(12, t.count == 1, "#12 删最后一张不该变 0，count=%zu", t.count);
        NCHK(12, t.items[0].text && *t.items[0].text, "#12 最后一张文字不该空");
        fdmnote_free(&t);
    }

    /* 13. clamp 基本规则 */
    {
        double x = 9999, y = 9999;
        fdmnote_clamp(&x, &y, 200, 100, 375, 812);
        NCHK(13, x == 375 - 100, "#13 x 应夹到 275，得到 %.1f", x);
        NCHK(13, y == 812 - 50, "#13 y 应夹到 762，得到 %.1f", y);

        x = -9999; y = -9999;
        fdmnote_clamp(&x, &y, 200, 100, 375, 812);
        NCHK(13, x == -100, "#13 x 应夹到 -100，得到 %.1f", x);
        NCHK(13, y == 0, "#13 y 应夹到 0，得到 %.1f", y);
    }

    /* 14. clamp NaN 输入 */
    {
        double x = 0.0 / 0.0, y = 0.0 / 0.0;
        fdmnote_clamp(&x, &y, 200, 100, 375, 812);
        NCHK(14, x == x && y == y, "#14 NaN 应被清成数字");
        NCHK(14, x >= -100.01 && x <= 275.01, "#14 清完还越界 x=%.1f", x);
    }

    /* 15. clamp 尺寸 0 时不改坐标 */
    {
        double x = 42, y = 43;
        fdmnote_clamp(&x, &y, 0, 0, 375, 812);
        NCHK(15, x == 42 && y == 43, "#15 控件尺寸 0 时不该改坐标");
    }

    /* 16. clamp 屏幕比控件窄 => 不返回 NaN */
    {
        double x = 100, y = 50;
        fdmnote_clamp(&x, &y, 500, 100, 200, 812);
        NCHK(16, x == x && y == y, "#16 异常尺寸不该返回 NaN");
    }

    /* 17. clamp NULL 不崩 */
    {
        double y = 5;
        fdmnote_clamp(NULL, &y, 200, 100, 375, 812);
        fdmnote_clamp(&y, NULL, 200, 100, 375, 812);
        NCHK(17, y == 5, "#17 y 不该被带歪，得到 %.1f", y);
    }

    /* 18. current 空状态给 fallback */
    {
        fdmnote_state t;
        fdmnote_item *it;
        memset(&t, 0, sizeof(t));
        it = fdmnote_current(&t);
        NCHK(18, it != NULL && it->text != NULL, "#18 current 空状态应给 fallback");
        it = fdmnote_current(NULL);
        NCHK(18, it != NULL && it->text != NULL, "#18 current(NULL) 应给 fallback");
    }

    /* 19. free 幂等 */
    {
        fdmnote_state t;
        fdmnote_init(&t);
        fdmnote_free(&t);
        fdmnote_free(&t);
        NCHK(19, t.count == 0 && t.items == NULL && t.capacity == 0, "#19 free 两次后应为空");
    }

    /* 20. parse NULL */
    {
        fdmnote_state t;
        NCHK(20, fdmnote_parse(NULL, &t) == 0, "#20 parse(NULL) 应成功");
        NCHK(20, t.count == 1, "#20 parse(NULL) 应给一张默认（%zu）", t.count);
        fdmnote_free(&t);
    }

    /* 21. serialize(NULL) */
    {
        char *s = fdmnote_serialize(NULL);
        NCHK(21, s != NULL && s[0] == '{', "#21 serialize(NULL) 应给 {}");
        free(s);
    }

    /* 22. HTML/script 字符不影响 */
    {
        fdmnote_state a, b;
        char *s2;
        fdmnote_init(&a);
        fdmnote_set_text(&a, "</script><b>x</b> \\u0041");
        s2 = fdmnote_serialize(&a);
        fdmnote_parse(s2, &b);
        NCHK(22, strcmp(b.items[0].text, "</script><b>x</b> \\u0041") == 0,
             "#22 特殊字符往返失败：「%s」", b.items[0].text);
        free(s2);
        fdmnote_free(&a);
        fdmnote_free(&b);
    }

    /* 23. \uXXXX 解码 */
    {
        fdmnote_state t;
        fdmnote_parse("{\"items\":[{\"t\":\"\\u4e70\\u725b\\u5976\"}]}", &t);
        NCHK(23, strcmp(t.items[0].text, "买牛奶") == 0,
             "#23 \\u 解码失败：「%s」", t.items[0].text);
        fdmnote_free(&t);
    }

    /* 24. 未知键被跳过（将来加字段不会崩）*/
    {
        fdmnote_state t;
        fdmnote_parse("{\"future\":{\"a\":[1,2]},\"idx\":0,"
                      "\"items\":[{\"t\":\"x\",\"x\":1,\"y\":2,\"new\":\"z\"}]}", &t);
        NCHK(24, t.count == 1, "#24 未知键导致解析失败（count=%zu）", t.count);
        NCHK(24, strcmp(t.items[0].text, "x") == 0, "#24 文字不对");
        NCHK(24, t.items[0].x == 1 && t.items[0].y == 2, "#24 坐标不对");
        fdmnote_free(&t);
    }

    /* 25. w/h 往返 */
    {
        fdmnote_state a, b;
        char *s2;
        fdmnote_init(&a);
        fdmnote_set_size(&a, 300, 180);
        NCHK(25, a.items[0].w == 300 && a.items[0].h == 180, "#25 set_size 没生效");
        s2 = fdmnote_serialize(&a);
        fdmnote_parse(s2, &b);
        NCHK(25, b.items[0].w == 300 && b.items[0].h == 180,
             "#25 w/h 往返丢了（%.1f x %.1f）", b.items[0].w, b.items[0].h);
        free(s2);
        fdmnote_free(&a);
        fdmnote_free(&b);
    }

    /* 26. 空文字便签保留（用户可能故意清空）*/
    {
        fdmnote_state t;
        fdmnote_parse("{\"items\":[{\"t\":\"\",\"x\":5,\"y\":6}]}", &t);
        NCHK(26, t.count == 1, "#26 空文字便签应保留（count=%zu）", t.count);
        NCHK(26, t.items[0].text != NULL && t.items[0].text[0] == '\0',
             "#26 空文字应为空串而不是 NULL");
        fdmnote_free(&t);
    }

    fdmnote_free(&st);
    return 0;
}
