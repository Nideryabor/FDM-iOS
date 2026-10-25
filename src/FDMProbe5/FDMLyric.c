// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMLyric.c —— 见 FDMLyric.h
#include "FDMLyric.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ══════════════════════════════════════════════════════════════════════════
 *  一、小工具
 * ══════════════════════════════════════════════════════════════════════════ */

/* Java String.trim()：去掉首尾 <= 0x20 的字节（对 UTF-8 安全：续字节都 >= 0x80） */
static char *ly_trim_dup(const char *s, size_t n) {
    size_t a = 0, b = n;
    while (a < b && (unsigned char)s[a] <= 0x20) a++;
    while (b > a && (unsigned char)s[b - 1] <= 0x20) b--;
    size_t len = b - a;
    char *p = (char *)malloc(len + 1);
    if (!p) return NULL;
    if (len) memcpy(p, s + a, len);
    p[len] = '\0';
    return p;
}

/* ══════════════════════════════════════════════════════════════════════════
 *  二、时间标签：[mm:ss] / [mm:ss.xxx] / [mm:ss:xxx]
 *
 *  与 Java 的正则 `\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]` 严格等价：
 *    · 分、秒各 1~2 位（贪婪，但不吃第 3 位数字）
 *    · 小数分隔符是 '.' 或 ':'，1~3 位；1 位 ×100，2 位 ×10，3 位原值
 * ══════════════════════════════════════════════════════════════════════════ */

/** 成功返回标签右括号之后的指针；失败返回 NULL。 */
static const char *parse_time_tag(const char *p, const char *e, long long *out_ms) {
    if (!p || !e || p >= e || *p != '[') return NULL;
    const char *q = p + 1;

    int nd = 0;
    long long mm = 0;
    while (q < e && *q >= '0' && *q <= '9' && nd < 2) {
        mm = mm * 10 + (*q - '0');
        q++;
        nd++;
    }
    if (nd < 1) return NULL;
    if (q >= e || *q != ':') return NULL;
    q++;

    nd = 0;
    long long ss = 0;
    while (q < e && *q >= '0' && *q <= '9' && nd < 2) {
        ss = ss * 10 + (*q - '0');
        q++;
        nd++;
    }
    if (nd < 1) return NULL;

    long long frac = 0;
    if (q < e && (*q == '.' || *q == ':')) {
        q++;
        nd = 0;
        long long f = 0;
        while (q < e && *q >= '0' && *q <= '9' && nd < 3) {
            f = f * 10 + (*q - '0');
            q++;
            nd++;
        }
        if (nd < 1) return NULL;
        if (nd == 1)      frac = f * 100;
        else if (nd == 2) frac = f * 10;
        else              frac = f;
    }

    if (q >= e || *q != ']') return NULL;
    q++;

    *out_ms = mm * 60000 + ss * 1000 + frac;
    return q;
}

/* ══════════════════════════════════════════════════════════════════════════
 *  三、解析
 * ══════════════════════════════════════════════════════════════════════════ */

typedef struct {
    long long ms;
    char *text;
} tmp_line;

static int push_line(tmp_line **arr, size_t *n, size_t *cap, long long ms, char *text) {
    if (*n == *cap) {
        size_t nc = *cap ? *cap * 2 : 64;
        tmp_line *na = (tmp_line *)realloc(*arr, nc * sizeof(tmp_line));
        if (!na) return 0;
        *arr = na;
        *cap = nc;
    }
    (*arr)[*n].ms = ms;
    (*arr)[*n].text = text;
    (*n)++;
    return 1;
}

int fdmlrc_parse(const char *lrc, fdmlrc *out) {
    if (!out) return -1;
    out->lines = NULL;
    out->count = 0;
    if (!lrc) return 0;

    tmp_line *arr = NULL;
    size_t n = 0, cap = 0;

    const char *p = lrc;
    while (*p) {
        const char *nl = strchr(p, '\n');
        const char *le = nl ? nl : p + strlen(p);

        /* 一行里可能有多个标签：取最后一个（与 Java 版 last/end 的语义一致） */
        long long last_ms = -1;
        const char *text_at = NULL;
        const char *q = p;
        while (q < le) {
            const char *hit = memchr(q, '[', (size_t)(le - q));
            if (!hit) break;
            long long t = 0;
            const char *after = parse_time_tag(hit, le, &t);
            if (after) {
                last_ms = t;
                text_at = after;
                q = after;
            } else {
                q = hit + 1;
            }
        }

        if (last_ms >= 0 && text_at) {
            char *txt = ly_trim_dup(text_at, (size_t)(le - text_at));
            if (!txt) {
                for (size_t i = 0; i < n; i++) free(arr[i].text);
                free(arr);
                return -2;
            }
            if (!*txt) {          /* 空文本行丢掉（Java 版同样） */
                free(txt);
            } else if (!push_line(&arr, &n, &cap, last_ms, txt)) {
                free(txt);
                for (size_t i = 0; i < n; i++) free(arr[i].text);
                free(arr);
                return -2;
            }
        }

        if (!nl) break;
        p = nl + 1;
    }

    /* 稳定插入排序（按 ms 升序）—— Java 用的 Arrays.sort(Object[]) 也是稳定的 */
    for (size_t i = 1; i < n; i++) {
        tmp_line key = arr[i];
        size_t j = i;
        while (j > 0 && arr[j - 1].ms > key.ms) {
            arr[j] = arr[j - 1];
            j--;
        }
        arr[j] = key;
    }

    if (n == 0) {
        free(arr);
        return 0;
    }

    out->lines = (fdmlrc_line *)malloc(n * sizeof(fdmlrc_line));
    if (!out->lines) {
        for (size_t i = 0; i < n; i++) free(arr[i].text);
        free(arr);
        return -2;
    }
    for (size_t i = 0; i < n; i++) {
        out->lines[i].ms = arr[i].ms;
        out->lines[i].text = arr[i].text;
    }
    out->count = n;
    free(arr);
    return 0;
}

void fdmlrc_free(fdmlrc *doc) {
    if (!doc) return;
    if (doc->lines) {
        for (size_t i = 0; i < doc->count; i++) free(doc->lines[i].text);
        free(doc->lines);
    }
    doc->lines = NULL;
    doc->count = 0;
}

long long fdmlrc_line_ms(const fdmlrc *doc, long long pos_ms, int which) {
    if (!doc || !doc->lines || !doc->count) return -1;

    /* 与 fdmlrc_around 同一个「线性扫最后一个 ms <= pos」策略 —— 两处必须一致，
     * 否则会出现「显示的是第 5 句、点下去跳到第 4 句」这种灵异现象。 */
    long idx = -1;
    for (size_t i = 0; i < doc->count; i++) {
        if (doc->lines[i].ms <= pos_ms) idx = (long)i;
        else break;
    }

    if (which == 0) {
        if (idx < 0) return -1;                 /* 前奏：没有"当前句" */
        return doc->lines[idx].ms;
    }
    if (which == 1) {                           /* 上一句 */
        if (idx > 0) return doc->lines[idx - 1].ms;
        return -1;
    }
    /* 下一句：前奏阶段是第 0 句 */
    if (idx < 0) return doc->lines[0].ms;
    if ((size_t)(idx + 1) < doc->count) return doc->lines[idx + 1].ms;
    return -1;
}


void fdmlrc_around(const fdmlrc *doc, long long pos_ms,
                   const char **cur, const char **prev, const char **next) {
    const char *c = "", *p = "", *x = "";
    if (doc && doc->lines && doc->count) {
        /* 线性扫最后一个 ms <= pos（与 Java 版一致；歌词几百行，够快） */
        long idx = -1;
        for (size_t i = 0; i < doc->count; i++) {
            if (doc->lines[i].ms <= pos_ms) idx = (long)i;
            else break;
        }
        if (idx >= 0 && (size_t)idx < doc->count) c = doc->lines[idx].text;
        if (idx > 0) p = doc->lines[idx - 1].text;
        if ((size_t)(idx + 1) < doc->count) x = doc->lines[idx + 1].text;
        if (idx < 0) {              /* 前奏：上一句空，下一句是第一句 */
            p = "";
            x = doc->count ? doc->lines[0].text : "";
        }
    }
    if (cur) *cur = c;
    if (prev) *prev = p;
    if (next) *next = x;
}

/* ══════════════════════════════════════════════════════════════════════════
 *  四、自检
 * ══════════════════════════════════════════════════════════════════════════ */

static int ly_expect(char *err, size_t errlen, int no, const fdmlrc *d, long long pos,
                     const char *wc, const char *wp, const char *wx) {
    const char *c = NULL, *p = NULL, *x = NULL;
    fdmlrc_around(d, pos, &c, &p, &x);
    if (strcmp(c, wc) == 0 && strcmp(p, wp) == 0 && strcmp(x, wx) == 0) return 1;
    snprintf(err, errlen,
             "#%d pos=%lld\n  got : [%s] [%s] [%s]\n  want: [%s] [%s] [%s]",
             no, pos, c, p, x, wc, wp, wx);
    return 0;
}

int fdmlrc_selftest(char *errbuf, size_t errlen) {
    char err[512];
    if (!errbuf) { errbuf = err; errlen = sizeof(err); }
    errbuf[0] = '\0';

    /* 真实歌词片段（晴天(深情版)，Java 侧拉到的真数据） */
    const char *src =
        "[00:00.000] 作词 : Lucky 小爱\n"
        "[00:01.000] 作曲 : Lucky 小爱\n"
        "[00:30.542]故事的小黄花\n"
        "[00:34.165]从出生那年就飘着\n"
        "[ti:晴天]\n"
        "[ar:周杰伦]\n"
        "\n"
        "[00:38.000]童年的荡秋千\n";

    fdmlrc d;
    int rc = fdmlrc_parse(src, &d);
    if (rc != 0) { snprintf(errbuf, errlen, "#0 parse rc=%d", rc); return 0; }
    if (d.count != 5) {
        snprintf(errbuf, errlen, "#1 行数 %zu（应为 5：4 句 + 2 元数据被忽略 + 空行被忽略）",
                 d.count);
        fdmlrc_free(&d);
        return 1;
    }
    if (d.lines[0].ms != 0 || strcmp(d.lines[0].text, "作词 : Lucky 小爱") != 0) {
        snprintf(errbuf, errlen, "#2 第一行 ms=%lld text=%s", d.lines[0].ms, d.lines[0].text);
        fdmlrc_free(&d);
        return 2;
    }
    if (d.lines[2].ms != 30542) {
        snprintf(errbuf, errlen, "#3 30542 应为 [00:30.542]，得到 %lld", d.lines[2].ms);
        fdmlrc_free(&d);
        return 3;
    }

    if (!ly_expect(errbuf, errlen, 4, &d, 0, "作词 : Lucky 小爱", "", "作曲 : Lucky 小爱")) { fdmlrc_free(&d); return 4; }
    if (!ly_expect(errbuf, errlen, 5, &d, 20000, "作曲 : Lucky 小爱", "作词 : Lucky 小爱", "故事的小黄花")) { fdmlrc_free(&d); return 5; }
    if (!ly_expect(errbuf, errlen, 6, &d, 30542, "故事的小黄花", "作曲 : Lucky 小爱", "从出生那年就飘着")) { fdmlrc_free(&d); return 6; }
    if (!ly_expect(errbuf, errlen, 7, &d, 38000, "童年的荡秋千", "从出生那年就飘着", "")) { fdmlrc_free(&d); return 7; }
    if (!ly_expect(errbuf, errlen, 8, &d, 999999, "童年的荡秋千", "从出生那年就飘着", "")) { fdmlrc_free(&d); return 8; }
    fdmlrc_free(&d);

    /* 一行多标签：取最后一个（Java 版行为） */
    fdmlrc m;
    if (fdmlrc_parse("[00:01.00][00:05.00]副歌\n[00:09.00]结束\n", &m) != 0) {
        snprintf(errbuf, errlen, "#9 parse fail"); return 9;
    }
    if (m.count != 2 || m.lines[0].ms != 5000) {
        snprintf(errbuf, errlen, "#9 多标签应取最后一个 5000，得到 count=%zu ms=%lld",
                 m.count, m.count ? m.lines[0].ms : -1);
        fdmlrc_free(&m);
        return 9;
    }
    fdmlrc_free(&m);

    /* 小数位归一化：1位×100 / 2位×10 / 3位原值 */
    {
        struct { const char *in; long long want; } cases[] = {
            {"[00:01.5]x", 1500},
            {"[00:01.05]x", 1050},
            {"[00:01.005]x", 1005},
            {"[00:01:5]x", 1500},
            {"[1:2]x", 62000},
            {"[99:59.999]x", 99LL * 60000 + 59 * 1000 + 999},
        };
        for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
            fdmlrc t;
            if (fdmlrc_parse(cases[i].in, &t) != 0 || t.count != 1) {
                snprintf(errbuf, errlen, "#10 解析失败: %s", cases[i].in);
                fdmlrc_free(&t);
                return 10;
            }
            if (t.lines[0].ms != cases[i].want) {
                snprintf(errbuf, errlen, "#11 %s → %lld（应为 %lld）",
                         cases[i].in, t.lines[0].ms, cases[i].want);
                fdmlrc_free(&t);
                return 11;
            }
            fdmlrc_free(&t);
        }
    }

    /* 不该被当成时间标签的东西 */
    {
        const char *bad = "[ti:晴天]\n[ar:周杰伦]\n[offset:500]\n[abc]\n[00:xx]\n";
        fdmlrc t;
        fdmlrc_parse(bad, &t);
        if (t.count != 0) {
            snprintf(errbuf, errlen, "#12 元数据行被误解析 %zu 条", t.count);
            fdmlrc_free(&t);
            return 12;
        }
        fdmlrc_free(&t);
    }

    /* 空歌词 */
    {
        fdmlrc t;
        fdmlrc_parse(NULL, &t);
        if (t.count != 0) { snprintf(errbuf, errlen, "#13 NULL 应得 0 行"); return 13; }
        fdmlrc_parse("", &t);
        if (t.count != 0) { snprintf(errbuf, errlen, "#14 空串应得 0 行"); return 14; }
        const char *c = NULL, *p = NULL, *x = NULL;
        fdmlrc_around(&t, 1234, &c, &p, &x);
        if (*c || *p || *x) { snprintf(errbuf, errlen, "#15 空文档 around 应为空串"); return 15; }
        fdmlrc_free(&t);
    }

    return 0;
}
