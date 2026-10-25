// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMFileCard.c —— 见 FDMFileCard.h
#include "FDMFileCard.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *fc_strdup(const char *s) {
    if (!s) s = "";
    size_t n = strlen(s);
    char *p = (char *)malloc(n + 1);
    if (!p) return NULL;
    memcpy(p, s, n + 1);
    return p;
}

void fdmfc_free(fdmfc_list *list) {
    if (!list) return;
    if (list->items) {
        for (int i = 0; i < list->count; i++) {
            free(list->items[i].label);
            free(list->items[i].prompt);
        }
        free(list->items);
    }
    list->items = NULL;
    list->count = 0;
    list->capacity = 0;
}

static int fc_reserve(fdmfc_list *l, int need) {
    if (need <= l->capacity) return 1;
    int cap = l->capacity ? l->capacity : 4;
    while (cap < need) cap *= 2;
    fdmfc_item *n = (fdmfc_item *)realloc(l->items, (size_t)cap * sizeof(fdmfc_item));
    if (!n) return 0;
    l->items = n;
    l->capacity = cap;
    return 1;
}

static int fc_push(fdmfc_list *l, const char *label, const char *prompt) {
    if (l->count >= FDMFC_MAX_ITEMS) return 0;
    if (!fc_reserve(l, l->count + 1)) return 0;
    l->items[l->count].label = fc_strdup(label ? label : "");
    l->items[l->count].prompt = fc_strdup(prompt ? prompt : "");
    if (!l->items[l->count].label || !l->items[l->count].prompt) {
        free(l->items[l->count].label);
        free(l->items[l->count].prompt);
        return 0;
    }
    l->count++;
    return 1;
}

int fdmfc_defaults(fdmfc_list *out) {
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    fc_push(out, "\u603b\u7ed3", "\u5e2e\u6211\u7528\u8981\u70b9\u603b\u7ed3\u8fd9\u4e2a\u6587\u4ef6");
    fc_push(out, "\u7ffb\u8bd1", "\u628a\u8fd9\u4e2a\u6587\u4ef6\u7ffb\u8bd1\u6210\u4e2d\u6587");
    fc_push(out, "\u8868\u683c", "\u628a\u8fd9\u4e2a\u6587\u4ef6\u91cc\u7684\u6570\u636e\u6574\u7406\u6210\u8868\u683c");
    return 0;
}

/* ── UTF-8 字符数（用于 label 截断，不能按字节截）── */
static int utf8_len(const char *s) {
    int n = 0;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        if ((*p & 0xC0) != 0x80) n++;
    }
    return n;
}

/** 截到 max_chars 个 UTF-8 字符（返回 malloc 的新串）。 */
static char *utf8_trunc(const char *s, int max_chars) {
    if (!s) return fc_strdup("");
    int n = 0;
    const unsigned char *p = (const unsigned char *)s;
    const unsigned char *cut = p;
    while (*p) {
        if ((*p & 0xC0) != 0x80) {
            if (n >= max_chars) break;
            n++;
        }
        p++;
        while ((*p & 0xC0) == 0x80) p++;
        cut = p;
    }
    size_t len = (size_t)(cut - (const unsigned char *)s);
    char *out = (char *)malloc(len + 1);
    if (!out) return NULL;
    memcpy(out, s, len);
    out[len] = '\0';
    return out;
}

/** 去掉首尾空白（含全角空格）。返回 malloc。 */
static char *trim_dup(const char *s, size_t n) {
    const unsigned char *b = (const unsigned char *)s;
    size_t a = 0, e = n;
    while (a < e && (b[a] == ' ' || b[a] == '\t' || b[a] == '\r' ||
                     (a + 2 < e && b[a] == 0xE3 && b[a+1] == 0x80 && b[a+2] == 0x80))) {
        a += (b[a] == 0xE3) ? 3 : 1;
    }
    while (e > a && (b[e-1] == ' ' || b[e-1] == '\t' || b[e-1] == '\r')) e--;
    size_t len = e - a;
    char *o = (char *)malloc(len + 1);
    if (!o) return NULL;
    memcpy(o, s + a, len);
    o[len] = '\0';
    return o;
}

int fdmfc_parse(const char *text, fdmfc_list *out) {
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    if (!text) { fdmfc_defaults(out); return 0; }

    const char *p = text;
    int pushed = 0;

    while (*p) {
        const char *nl = strchr(p, '\n');
        const char *le = nl ? nl : p + strlen(p);
        size_t linelen = (size_t)(le - p);

        /* 找分隔符：ASCII '|' 或全角 '｜'(EF BD 9C) */
        const char *sep = NULL;
        size_t sep_len = 1;
        for (size_t k = 0; k < linelen; k++) {
            if (p[k] == '|') { sep = p + k; sep_len = 1; break; }
            if (k + 3 <= linelen && (unsigned char)p[k] == 0xEF &&
                (unsigned char)p[k+1] == 0xBD && (unsigned char)p[k+2] == 0x9C) {
                sep = p + k; sep_len = 3; break;
            }
        }

        char *lab_raw = NULL, *prm_raw = NULL;
        if (sep) {
            lab_raw = trim_dup(p, (size_t)(sep - p));
            prm_raw = trim_dup(sep + sep_len, linelen - (size_t)(sep - p) - sep_len);
        } else {
            lab_raw = trim_dup(p, linelen);
            prm_raw = fc_strdup("");
        }

        if (lab_raw && *lab_raw) {
            char *label = NULL;
            if (utf8_len(lab_raw) > FDMFC_MAX_LABEL) {
                label = utf8_trunc(lab_raw, FDMFC_MAX_LABEL);
            } else {
                label = fc_strdup(lab_raw);
            }
            /* prompt 空 => 用 label（至少点了有反应）*/
            const char *prompt = (prm_raw && *prm_raw) ? prm_raw : label;
            if (label) {
                if (fc_push(out, label, prompt)) pushed++;
                free(label);
            }
        }
        free(lab_raw);
        free(prm_raw);

        if (!nl) break;
        p = nl + 1;
    }

    /* 一条都没解析出来 => 用默认（不能因为用户手滑就让功能消失）*/
    if (pushed == 0) {
        fdmfc_free(out);
        fdmfc_defaults(out);
    }
    return 0;
}

char *fdmfc_serialize(const fdmfc_list *list) {
    if (!list || list->count == 0) return fc_strdup("");
    size_t cap = 256, len = 0;
    char *buf = (char *)malloc(cap);
    if (!buf) return NULL;
    buf[0] = '\0';

    for (int i = 0; i < list->count; i++) {
        const char *lab = list->items[i].label ? list->items[i].label : "";
        const char *prm = list->items[i].prompt ? list->items[i].prompt : "";
        size_t need = len + strlen(lab) + strlen(prm) + 4;
        if (need > cap) {
            size_t nc = cap * 2;
            while (nc < need) nc *= 2;
            char *nb = (char *)realloc(buf, nc);
            if (!nb) { free(buf); return NULL; }
            buf = nb;
            cap = nc;
        }
        len += (size_t)snprintf(buf + len, cap - len, "%s|%s\n", lab, prm);
    }
    return buf;
}

int fdmfc_sanitize(fdmfc_list *list) {
    if (!list || list->count == 0) return 0;
    int changed = 0;

    /* 1. 删空项（label 为空）*/
    for (int i = 0; i < list->count; ) {
        if (!list->items[i].label || !*list->items[i].label) {
            free(list->items[i].label);
            free(list->items[i].prompt);
            memmove(&list->items[i], &list->items[i + 1],
                    (size_t)(list->count - i - 1) * sizeof(fdmfc_item));
            list->count--;
            changed++;
        } else {
            i++;
        }
    }

    /* 2. prompt 空 => 用 label 补上 */
    for (int i = 0; i < list->count; i++) {
        if (!list->items[i].prompt || !*list->items[i].prompt) {
            free(list->items[i].prompt);
            list->items[i].prompt = fc_strdup(list->items[i].label);
            changed++;
        }
    }

    /* 3. 去重（label 相同）*/
    for (int i = 0; i < list->count; i++) {
        for (int j = i + 1; j < list->count; ) {
            if (strcmp(list->items[i].label, list->items[j].label) == 0) {
                free(list->items[j].label);
                free(list->items[j].prompt);
                memmove(&list->items[j], &list->items[j + 1],
                        (size_t)(list->count - j - 1) * sizeof(fdmfc_item));
                list->count--;
                changed++;
            } else {
                j++;
            }
        }
    }

    /* 4. 超上限截断 */
    while (list->count > FDMFC_MAX_ITEMS) {
        free(list->items[list->count - 1].label);
        free(list->items[list->count - 1].prompt);
        list->count--;
        changed++;
    }

    return changed;
}

/* ══════════════════════════════════ 自检 ══════════════════════════════════ */

#define FCHK(no, cond, ...)                                   \
    do {                                                      \
        if (!(cond)) {                                        \
            snprintf(errbuf, (size_t)errlen, __VA_ARGS__);    \
            return no;                                        \
        }                                                     \
    } while (0)

int fdmfc_selftest(char *errbuf, int errlen) {
    char local[512];
    if (!errbuf) { errbuf = local; errlen = (int)sizeof(local); }
    errbuf[0] = '\0';
    fdmfc_list l;

    /* 1. 默认三条 */
    fdmfc_defaults(&l);
    FCHK(1, l.count == 3, "#1 默认应有 3 条，得到 %d", l.count);
    FCHK(1, strcmp(l.items[0].label, "总结") == 0, "#1 第 1 条 label 不对：「%s」",
         l.items[0].label);
    FCHK(1, strstr(l.items[0].prompt, "总结") != NULL, "#1 第 1 条 prompt 不对");
    fdmfc_free(&l);

    /* 2. 基本解析 */
    fdmfc_parse("A|aaa\nB|bbb", &l);
    FCHK(2, l.count == 2, "#2 应解析 2 条，得到 %d", l.count);
    FCHK(2, strcmp(l.items[0].label, "A") == 0 && strcmp(l.items[0].prompt, "aaa") == 0,
         "#2 第 1 条不对");
    FCHK(2, strcmp(l.items[1].label, "B") == 0, "#2 第 2 条不对");
    fdmfc_free(&l);

    /* 3. prompt 里可以有 | */
    fdmfc_parse("X|a|b|c", &l);
    FCHK(3, l.count == 1, "#3 count=%d", l.count);
    FCHK(3, strcmp(l.items[0].label, "X") == 0, "#3 label 不对：「%s」", l.items[0].label);
    FCHK(3, strcmp(l.items[0].prompt, "a|b|c") == 0, "#3 prompt 应保留后面的 |，得到「%s」",
         l.items[0].prompt);
    fdmfc_free(&l);

    /* 4. 全角 ｜ */
    fdmfc_parse("Y｜全角分隔", &l);
    FCHK(4, l.count == 1, "#4 count=%d", l.count);
    FCHK(4, strcmp(l.items[0].label, "Y") == 0, "#4 全角分隔失败：「%s」", l.items[0].label);
    FCHK(4, strcmp(l.items[0].prompt, "全角分隔") == 0, "#4 prompt 不对：「%s」",
         l.items[0].prompt);
    fdmfc_free(&l);

    /* 5. 空行跳过 */
    fdmfc_parse("A|1\n\n\n  \nB|2\n", &l);
    FCHK(5, l.count == 2, "#5 空行应跳过，count=%d", l.count);
    fdmfc_free(&l);

    /* 6. 没有 | 的行：整行当 label，prompt 用 label */
    fdmfc_parse("只有文字", &l);
    FCHK(6, l.count == 1, "#6 count=%d", l.count);
    FCHK(6, strcmp(l.items[0].label, "只有文字") == 0, "#6 label 不对");
    FCHK(6, strcmp(l.items[0].prompt, "只有文字") == 0, "#6 prompt 应回退成 label");
    fdmfc_free(&l);

    /* 7. 行尾空白被去掉 */
    fdmfc_parse("A  |  aaa  \n", &l);
    FCHK(7, l.count == 1, "#7 count=%d", l.count);
    FCHK(7, strcmp(l.items[0].label, "A") == 0, "#7 label 空白没去：「%s」", l.items[0].label);
    FCHK(7, strcmp(l.items[0].prompt, "aaa") == 0, "#7 prompt 空白没去：「%s」",
         l.items[0].prompt);
    fdmfc_free(&l);

    /* 8. 空文本 => 默认 */
    fdmfc_parse("", &l);
    FCHK(8, l.count == 3, "#8 空文本应回退默认，count=%d", l.count);
    fdmfc_free(&l);

    /* 9. NULL => 默认 */
    fdmfc_parse(NULL, &l);
    FCHK(9, l.count == 3, "#9 NULL 应回退默认，count=%d", l.count);
    fdmfc_free(&l);

    /* 10. 超上限截断 */
    fdmfc_parse("1|a\n2|a\n3|a\n4|a\n5|a\n6|a\n7|a\n8|a\n9|a\n10|a\n11|a", &l);
    FCHK(10, l.count == FDMFC_MAX_ITEMS, "#10 应截到 %d 条，得到 %d",
         FDMFC_MAX_ITEMS, l.count);
    fdmfc_free(&l);

    /* 11. label 超长按字符截断（不切坏 UTF-8）*/
    fdmfc_parse("一二三四五六七八九十十一十二十三|p", &l);
    FCHK(11, l.count == 1, "#11 count=%d", l.count);
    FCHK(11, utf8_len(l.items[0].label) <= FDMFC_MAX_LABEL,
         "#11 label 应截到 %d 字符，得到 %d 字符「%s」",
         FDMFC_MAX_LABEL, utf8_len(l.items[0].label), l.items[0].label);
    FCHK(11, strcmp(l.items[0].label, "一二三四五六七八九十十一") == 0,
         "#11 截断结果不对：「%s」", l.items[0].label);
    fdmfc_free(&l);

    /* 12. 序列化再解析（往返）*/
    fdmfc_parse("总结|帮我总结\n翻译|翻译成中文", &l);
    {
        char *s = fdmfc_serialize(&l);
        fdmfc_list l2;
        FCHK(12, s != NULL, "#12 serialize NULL");
        fdmfc_parse(s, &l2);
        FCHK(12, l2.count == 2, "#12 往返 count=%d", l2.count);
        FCHK(12, strcmp(l2.items[0].label, "总结") == 0, "#12 往返 label 不对");
        FCHK(12, strcmp(l2.items[0].prompt, "帮我总结") == 0, "#12 往返 prompt 不对");
        free(s);
        fdmfc_free(&l2);
    }
    fdmfc_free(&l);

    /* 13. sanitize：删空 label */
    l.count = 0; l.capacity = 0; l.items = NULL;
    fc_push(&l, "", "x");
    fc_push(&l, "ok", "y");
    FCHK(13, fdmfc_sanitize(&l) >= 1, "#13 sanitize 应报告改动");
    FCHK(13, l.count == 1, "#13 删空项后 count=%d", l.count);
    FCHK(13, strcmp(l.items[0].label, "ok") == 0, "#13 剩下的不对");
    fdmfc_free(&l);

    /* 14. sanitize：prompt 空补 label */
    l.count = 0; l.capacity = 0; l.items = NULL;
    fc_push(&l, "abc", "");
    fdmfc_sanitize(&l);
    FCHK(14, strcmp(l.items[0].prompt, "abc") == 0,
         "#14 prompt 应补成 label，得到「%s」", l.items[0].prompt);
    fdmfc_free(&l);

    /* 15. sanitize：去重 */
    l.count = 0; l.capacity = 0; l.items = NULL;
    fc_push(&l, "dup", "1");
    fc_push(&l, "dup", "2");
    fc_push(&l, "other", "3");
    fdmfc_sanitize(&l);
    FCHK(15, l.count == 2, "#15 去重后 count=%d（应 2）", l.count);
    FCHK(15, strcmp(l.items[1].label, "other") == 0, "#15 去重后顺序不对");
    fdmfc_free(&l);

    /* 16. sanitize NULL / 空 不崩 */
    FCHK(16, fdmfc_sanitize(NULL) == 0, "#16 sanitize(NULL) 应返回 0");
    {
        fdmfc_list t;
        memset(&t, 0, sizeof(t));
        FCHK(16, fdmfc_sanitize(&t) == 0, "#16 空 list 应返回 0");
    }

    /* 17. serialize 空 list => 空串 */
    {
        fdmfc_list t;
        memset(&t, 0, sizeof(t));
        char *s = fdmfc_serialize(&t);
        FCHK(17, s != NULL && s[0] == '\0', "#17 空 list 应序列化成空串");
        free(s);
    }

    /* 18. free 幂等 */
    {
        fdmfc_list t;
        fdmfc_defaults(&t);
        fdmfc_free(&t);
        fdmfc_free(&t);
        FCHK(18, t.count == 0 && t.items == NULL, "#18 free 两次后应为空");
    }

    /* 19. CRLF 行尾 */
    fdmfc_parse("A|1\r\nB|2\r\n", &l);
    FCHK(19, l.count == 2, "#19 CRLF count=%d", l.count);
    FCHK(19, strcmp(l.items[0].prompt, "1") == 0, "#19 CRLF 没去掉 \\r：「%s」",
         l.items[0].prompt);
    fdmfc_free(&l);

    /* 20. 全角空格 label 视为空 */
    fdmfc_parse("\u3000\u3000|有prompt", &l);
    FCHK(20, l.count >= 1, "#20 count=%d", l.count);
    /* 全角空格 trim 后 label 为空 => 该行被丢，回退默认 */
    fdmfc_free(&l);

    return 0;
}
