// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMPromptVars.c —— 见 FDMPromptVars.h
#include "FDMPromptVars.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ══════════════════════════════════════════════════════════════════════════
 *  一、超小 string builder
 * ══════════════════════════════════════════════════════════════════════════ */

typedef struct {
    char *p;
    size_t len;
    size_t cap;
} fdm_sb;

static void sb_init(fdm_sb *b) {
    b->p = NULL;
    b->len = 0;
    b->cap = 0;
}

static int sb_reserve(fdm_sb *b, size_t extra) {
    size_t need = b->len + extra + 1;
    if (need <= b->cap) return 1;
    size_t cap = b->cap ? b->cap : 64;
    while (cap < need) cap *= 2;
    char *np = (char *)realloc(b->p, cap);
    if (!np) return 0;
    b->p = np;
    b->cap = cap;
    return 1;
}

static int sb_addn(fdm_sb *b, const char *s, size_t n) {
    if (!n) return 1;
    if (!s) return 1;
    if (!sb_reserve(b, n)) return 0;
    memcpy(b->p + b->len, s, n);
    b->len += n;
    b->p[b->len] = '\0';
    return 1;
}

static int sb_adds(fdm_sb *b, const char *s) {
    return s ? sb_addn(b, s, strlen(s)) : 1;
}

static char *sb_take(fdm_sb *b) {
    if (!b->p) {
        b->p = (char *)malloc(1);
        if (b->p) b->p[0] = '\0';
        return b->p;
    }
    return b->p;
}

/* ══════════════════════════════════════════════════════════════════════════
 *  二、变量名表（顺序与 Java 版一致）
 * ══════════════════════════════════════════════════════════════════════════ */

static const char *const FDM_PV_NAMES[] = {
    "music", "music_or_none",
    "song", "artist", "album",
    "music_pos", "music_dur", "music_left", "music_state",
    "lyric", "lyric_prev", "lyric_next",
};
#define FDM_PV_NAMES_N (sizeof(FDM_PV_NAMES) / sizeof(FDM_PV_NAMES[0]))

static const char *s_or_empty(const char *s) { return s ? s : ""; }

/* strdup 是 POSIX；用 -std=c11 编译时不一定有声明 ⇒ 自己带一份 */
static char *pv_strdup(const char *s) {
    if (!s) s = "";
    size_t n = strlen(s);
    char *p = (char *)malloc(n + 1);
    if (!p) return NULL;
    memcpy(p, s, n + 1);
    return p;
}

void fdmpv_fmt_time(long long ms, char out[32]) {
    if (ms <= 0) {
        snprintf(out, 32, "0:00");
        return;
    }
    long long s = ms / 1000;
    long long m = s / 60;
    long long r = s % 60;
    snprintf(out, 32, "%lld:%02lld", m, r);
}

/** 《歌名》 - 歌手 (m:ss/dur)；歌名与歌手都空 ⇒ "" */
static void summary_into(fdm_sb *b, const fdmpv_snap *sn) {
    const char *name = s_or_empty(sn->song);
    const char *artist = s_or_empty(sn->artist);
    size_t before = b->len;

    if (*name) {
        sb_adds(b, "\u300A");   /* 《 */
        sb_adds(b, name);
        sb_adds(b, "\u300B");   /* 》 */
    }
    if (*artist) {
        if (b->len > before) sb_adds(b, " - ");
        sb_adds(b, artist);
    }
    if (b->len == before) return;   /* 都空 ⇒ 不加时间 */

    char pos[32];
    fdmpv_fmt_time(sn->pos_ms, pos);
    sb_adds(b, " (");
    sb_adds(b, pos);
    if (sn->dur_ms > 0) {
        char dur[32];
        fdmpv_fmt_time(sn->dur_ms, dur);
        sb_adds(b, "/");
        sb_adds(b, dur);
    }
    sb_adds(b, ")");
}

/**
 * 单个变量的值。*out 需要 free。
 * 语义全部照抄 Java 的 value()：
 *   - music_or_none 是**唯一**会在「开关开着但真没在听」时说话的
 *   - 开关关（enabled=0）时 sn 视为 NULL ⇒ 一切皆空
 */
static char *value_dup(const char *name, const fdmpv_snap *sn) {
    const int on = sn && sn->enabled;

    if (strcmp(name, "music_or_none") == 0) {
        if (!on) return pv_strdup("");
        fdm_sb b;
        sb_init(&b);
        summary_into(&b, sn);
        char *out = sb_take(&b);
        if (!out || !*out) {
            free(out);
            return pv_strdup("\u6CA1\u6709\u5728\u542C\u6B4C");  /* 没有在听歌 */
        }
        return out;
    }

    if (!on) return pv_strdup("");

    if (strcmp(name, "song") == 0)   return pv_strdup(s_or_empty(sn->song));
    if (strcmp(name, "artist") == 0) return pv_strdup(s_or_empty(sn->artist));
    if (strcmp(name, "album") == 0)  return pv_strdup(s_or_empty(sn->album));

    if (strcmp(name, "music") == 0) {
        fdm_sb b;
        sb_init(&b);
        summary_into(&b, sn);
        return sb_take(&b);
    }
    if (strcmp(name, "music_pos") == 0) {
        char t[32];
        fdmpv_fmt_time(sn->pos_ms, t);
        return pv_strdup(t);
    }
    if (strcmp(name, "music_dur") == 0) {
        char t[32];
        fdmpv_fmt_time(sn->dur_ms, t);
        return pv_strdup(t);
    }
    if (strcmp(name, "music_left") == 0) {
        if (sn->dur_ms <= 0) return pv_strdup("");
        long long left = sn->dur_ms - sn->pos_ms;
        if (left < 0) left = 0;
        char t[32];
        fdmpv_fmt_time(left, t);
        return pv_strdup(t);
    }
    if (strcmp(name, "music_state") == 0) {
        return pv_strdup(sn->playing ? "playing" : "paused");
    }

    /* 歌词三兄弟：版权闸门（独立开关） */
    if (strcmp(name, "lyric") == 0 ||
        strcmp(name, "lyric_prev") == 0 ||
        strcmp(name, "lyric_next") == 0) {
        if (!sn->lyric_on) return pv_strdup("");
        const char *v = strcmp(name, "lyric") == 0      ? sn->lyric
                        : strcmp(name, "lyric_prev") == 0 ? sn->lyric_prev
                                                          : sn->lyric_next;
        return pv_strdup(s_or_empty(v));
    }

    return pv_strdup("");
}

int fdmpv_has_any(const char *s) {
    if (!s || !*s) return 0;
    for (size_t i = 0; i < FDM_PV_NAMES_N; i++) {
        /* "{name}" —— 手工拼，避免每次都 snprintf */
        char pat[40];
        snprintf(pat, sizeof(pat), "{%s}", FDM_PV_NAMES[i]);
        if (strstr(s, pat)) return 1;
    }
    return 0;
}

/* ══════════════════════════════════════════════════════════════════════════
 *  三、[[ … ]] 脱壳 / 整块删除
 * ══════════════════════════════════════════════════════════════════════════ */

static char *collapse(const char *s, const fdmpv_snap *sn) {
    if (!s) return pv_strdup("");
    if (!strstr(s, "[[")) return pv_strdup(s);

    fdm_sb out;
    sb_init(&out);
    size_t from = 0;
    const size_t n = strlen(s);

    for (;;) {
        const char *pa = strstr(s + from, "[[");
        if (!pa) {
            sb_addn(&out, s + from, n - from);
            break;
        }
        size_t a = (size_t)(pa - s);
        const char *pb = strstr(pa + 2, "]]");
        if (!pb) {                       /* 不闭合 ⇒ 剩下的原样留着 */
            sb_addn(&out, s + from, n - from);
            break;
        }
        size_t b = (size_t)(pb - s);

        /* 原样搬运 a 之前的内容 */
        sb_addn(&out, s + from, a - from);

        /* 块内容 = s[a+2, b) */
        const char *inner = s + a + 2;
        size_t inner_len = b - (a + 2);

        int has_var = 0;
        int all_empty = 1;
        for (size_t i = 0; i < FDM_PV_NAMES_N; i++) {
            char pat[40];
            snprintf(pat, sizeof(pat), "{%s}", FDM_PV_NAMES[i]);
            size_t plen = strlen(pat);
            int found = 0;
            for (size_t k = 0; k + plen <= inner_len; k++) {
                if (memcmp(inner + k, pat, plen) == 0) { found = 1; break; }
            }
            if (!found) continue;

            has_var = 1;
            char *v = value_dup(FDM_PV_NAMES[i], sn);
            int empty = (!v || !*v);
            free(v);
            if (!empty) { all_empty = 0; break; }
        }

        if (!has_var) {
            /* 块里一个我们的变量都没有 ⇒ **连壳原样保留**。
             * （Java 版类注释明确要求这样，但它的实现是直接 append(inner) ⇒ 会脱壳。
             *  这里按注释的意图走：绝不能因为一段普通文本用了 [[ ]] 就被吃掉两个字符。） */
            sb_addn(&out, s + a, (b + 2) - a);
        } else if (!all_empty) {
            sb_addn(&out, inner, inner_len);   /* 有内容 ⇒ 脱壳保留 */
        }                                          /* 有变量且全空 ⇒ 整块消失 */

        from = b + 2;
        if (from >= n) break;            /* 已经到末尾 */
    }
    return sb_take(&out);
}

/* ══════════════════════════════════════════════════════════════════════════
 *  四、入口
 * ══════════════════════════════════════════════════════════════════════════ */

char *fdmpv_resolve(const char *s, const fdmpv_snap *snap) {
    if (!s) return NULL;
    if (!*s) return pv_strdup("");

    char *mid = collapse(s, snap);
    if (!mid) return NULL;

    fdm_sb out;
    sb_init(&out);

    const char *p = mid;
    while (*p) {
        if (*p != '{') {
            const char *q = strchr(p, '{');
            if (!q) {
                sb_adds(&out, p);
                break;
            }
            sb_addn(&out, p, (size_t)(q - p));
            p = q;
            continue;
        }

        /* 试着匹配一个已知变量 */
        int matched = 0;
        for (size_t i = 0; i < FDM_PV_NAMES_N; i++) {
            char pat[40];
            snprintf(pat, sizeof(pat), "{%s}", FDM_PV_NAMES[i]);
            size_t plen = strlen(pat);
            if (strncmp(p, pat, plen) == 0) {
                char *v = value_dup(FDM_PV_NAMES[i], snap);
                if (v) sb_adds(&out, v);
                free(v);
                p += plen;
                matched = 1;
                break;
            }
        }
        if (!matched) {
            sb_addn(&out, p, 1);   /* 不是我们的变量 ⇒ 原样留一个 '{' */
            p++;
        }
    }

    free(mid);
    return sb_take(&out);
}

/* ══════════════════════════════════════════════════════════════════════════
 *  五、自检
 * ══════════════════════════════════════════════════════════════════════════ */

static int pv_chk(char *err, size_t errlen, int no, const char *what,
                  const fdmpv_snap *sn, const char *src, const char *want) {
    char *got = fdmpv_resolve(src, sn);
    int ok = got && want && strcmp(got, want) == 0;
    if (!ok) {
        snprintf(err, errlen, "#%d %s\n  in  : %s\n  got : %s\n  want: %s", no, what,
                 src ? src : "(null)", got ? got : "(null)",
                 want ? want : "(null)");
    }
    free(got);
    return ok;
}

int fdmpv_selftest(char *errbuf, size_t errlen) {
    char err[512];
    if (!errbuf) { errbuf = err; errlen = sizeof(err); }
    errbuf[0] = '\0';

    fdmpv_snap on = {0};
    on.enabled = 1;
    on.song = "\u6674\u5929";          /* 晴天 */
    on.artist = "\u5468\u6770\u4F26";  /* 周杰伦 */
    on.album = "\u53F6\u60E0\u7F8E";
    on.pos_ms = 83000;
    on.dur_ms = 269000;
    on.playing = 1;
    on.lyric_on = 0;
    on.lyric = "\u6545\u4E8B\u7684\u5C0F\u9EC4\u82B1";  /* 故事的小黄花 */

    fdmpv_snap idle = {0};
    idle.enabled = 1;

    fdmpv_snap off = {0};
    off.enabled = 0;
    off.song = on.song;
    off.artist = on.artist;

    fdmpv_snap lyr = on;
    lyr.lyric_on = 1;

    if (!pv_chk(errbuf, errlen, 1, "music(有歌)", &on,
                "\u6B63\u5728\u542C\uFF1A{music}",
                "\u6B63\u5728\u542C\uFF1A\u300A\u6674\u5929\u300B - \u5468\u6770\u4F26 (1:23/4:29)"))
        return 1;
    if (!pv_chk(errbuf, errlen, 2, "music(没歌)", &idle,
                "\u6B63\u5728\u542C\uFF1A{music}", "\u6B63\u5728\u542C\uFF1A"))
        return 2;
    if (!pv_chk(errbuf, errlen, 3, "music_or_none(没歌)", &idle,
                "[{music_or_none}]",
                "[\u6CA1\u6709\u5728\u542C\u6B4C]"))
        return 3;
    if (!pv_chk(errbuf, errlen, 4, "music_or_none(开关关)", &off,
                "[{music_or_none}]", "[]"))
        return 4;
    if (!pv_chk(errbuf, errlen, 5, "[[ ]] 有歌⇒脱壳", &on,
                "[[\u6B63\u5728\u542C\uFF1A{music}]]",
                "\u6B63\u5728\u542C\uFF1A\u300A\u6674\u5929\u300B - \u5468\u6770\u4F26 (1:23/4:29)"))
        return 5;
    if (!pv_chk(errbuf, errlen, 6, "[[ ]] 没歌⇒整块消失", &idle,
                "[[\u6B63\u5728\u542C\uFF1A{music}]]", ""))
        return 6;
    if (!pv_chk(errbuf, errlen, 7, "[[ ]] 无变量⇒原样保留", &on,
                "[[\u666E\u901A\u65B9\u62EC\u53F7]]", "[[\u666E\u901A\u65B9\u62EC\u53F7]]"))
        return 7;
    if (!pv_chk(errbuf, errlen, 8, "song/artist/album", &on,
                "{song}|{artist}|{album}",
                "\u6674\u5929|\u5468\u6770\u4F26|\u53F6\u60E0\u7F8E"))
        return 8;
    if (!pv_chk(errbuf, errlen, 9, "pos/dur/left", &on,
                "{music_pos}/{music_dur}/{music_left}", "1:23/4:29/3:06"))
        return 9;
    if (!pv_chk(errbuf, errlen, 10, "state=playing", &on, "{music_state}", "playing"))
        return 10;
    if (!pv_chk(errbuf, errlen, 11, "state=paused", &idle, "{music_state}", "paused"))
        return 11;
    if (!pv_chk(errbuf, errlen, 12, "lyric 开关关⇒空", &on, "[{lyric}]", "[]"))
        return 12;
    if (!pv_chk(errbuf, errlen, 13, "lyric 开关开", &lyr, "{lyric}",
                "\u6545\u4E8B\u7684\u5C0F\u9EC4\u82B1"))
        return 13;
    if (!pv_chk(errbuf, errlen, 14, "未知花括号原样", &on, "{hello} {music}",
                "{hello} \u300A\u6674\u5929\u300B - \u5468\u6770\u4F26 (1:23/4:29)"))
        return 14;
    if (!pv_chk(errbuf, errlen, 15, "未闭合的 [[", &on, "[[abc", "[[abc"))
        return 15;
    if (!pv_chk(errbuf, errlen, 16, "多块混排", &on,
                "A[[{song}]]B[[{music}{artist}]]C",
                "A\u6674\u5929B\u300A\u6674\u5929\u300B - \u5468\u6770\u4F26 (1:23/4:29)\u5468\u6770\u4F26C"))
        return 16;
    if (!pv_chk(errbuf, errlen, 17, "空串", &on, "", ""))
        return 17;
    if (!pv_chk(errbuf, errlen, 18, "纯文本不动", &on,
                "\u4F60\u597D\uFF0C\u4E16\u754C", "\u4F60\u597D\uFF0C\u4E16\u754C"))
        return 18;

    if (!fdmpv_has_any("{music}")) { snprintf(errbuf, errlen, "#19 has_any 漏判"); return 19; }
    if (fdmpv_has_any("plain text")) { snprintf(errbuf, errlen, "#20 has_any 误判"); return 20; }

    return 0;
}
