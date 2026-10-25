// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMPromptCard.c —— 见头文件注释。这里只放能被单测的纯逻辑。
#include "FDMPromptCard.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ============================================================
 * 〇、小工具
 * ============================================================ */

static char *pc_strdup(const char *s) {
    if (!s) s = "";
    size_t n = strlen(s);
    char *p = (char *)malloc(n + 1);
    if (!p) return NULL;
    memcpy(p, s, n + 1);
    return p;
}

/* 换掉字符串（内存不足就保持原样，绝不留野指针） */
static int pc_replace(char **dst, const char *src) {
    char *n = pc_strdup(src ? src : "");
    if (!n) return -1;
    free(*dst);
    *dst = n;
    return 0;
}

static int pc_eq(const char *a, const char *b) {
    if (!a || !b) return 0;
    return strcmp(a, b) == 0;
}

static int pc_clampi(int v, int lo, int hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

/* 原地 trim（返回同一块内存，方便链式用） */
static char *pc_trim(char *s) {
    if (!s) return s;
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;
    size_t n = strlen(s);
    while (n > 0) {
        char c = s[n - 1];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') s[--n] = '\0';
        else break;
    }
    return s;
}

/* ============================================================
 * 一、类型判定
 * ============================================================ */

int fdmpc_is_builtin_type(const char *type) {
    return pc_eq(type, FDMPC_T_SUGGEST) ||
           pc_eq(type, FDMPC_T_MUSIC) ||
           pc_eq(type, FDMPC_T_RICHTEXT);
}

int fdmpc_is_text_type(const char *type) {
    return pc_eq(type, FDMPC_T_TEXT) || pc_eq(type, FDMPC_T_TEXTSRC);
}

const char *fdmpc_type_title(const char *type) {
    if (pc_eq(type, FDMPC_T_SUGGEST))  return "回复建议";
    if (pc_eq(type, FDMPC_T_MUSIC))    return "音乐";
    if (pc_eq(type, FDMPC_T_RICHTEXT)) return "富文本";
    if (pc_eq(type, FDMPC_T_TEXTSRC))  return "系统提示词内容";
    if (pc_eq(type, FDMPC_T_TEXT))     return "自定义文本";
    return "未知";
}

/* ============================================================
 * 二、★ 内置三张卡「自带的」约定文案
 *
 * 这三段是**提示词的实际内容**，模型靠它们才知道：
 *   · 可以写 <Suggestion>
 *   · 可以用 {music} 之类的变量
 *   · 可以写 <b> <c1> 这些富文本标签
 *
 * ⚠️ 文案改动要**同步安卓**（GmRichText.suggestSpec / GmPromptVars.spec /
 *    GmRichText.spec）。两边不一样，用户在两个平台上会看到不同行为。
 * ============================================================ */

static const char kSpecSuggest[] =
    "【追问建议】当你想让用户继续追问、或想引导对话方向时，"
    "在回复的最后另起一行输出：\n"
    "  <Suggestion>▸ 你的建议问题</Suggestion>\n"
    "可以写多行，每行一条建议，界面会渲染成可点击的按钮。\n"
    "★ 想「显示短一点、实际发的内容长一点」时，用竖线分开：\n"
    "  <Suggestion>▸ 说说看|请从原理上详细解释一下</Suggestion>\n"
    "★ 直接写就行，不要在代码块里写，也不要再用别的符号把它包起来。\n";

static const char kSpecMusic[] =
    "【音乐变量】下面两行是发消息那一刻我在听的歌：\n"
    "[[正在听：{music}]]\n"
    "[[当前唱到：{lyric}]]";

/* ★ 富文本这段和安卓 spec() 的差别：安卓会把「当前模板池」也拼进去
 *   （`另外还有几个现成的排版模板…⟦FDM:名字|参数1|参数2⟧`）。
 *   模板池是**用户配置**，属于 iOS 的 FDMConfig（richtext.templates）。
 *   所以这里提供一个"带模板池"的版本，由 ObjC 层把配置传进来 ——
 *   纯 C 层不读配置（铁律：hook/纯逻辑层不碰 IO）。 */
static const char kSpecRichtextHead[] =
    "【回答排版】以下是可用的富文本标签，写上就会被渲染成真正的样式，"
    "请适当使用来让回答更清楚：\n"
    "  <b>粗体</b>  <i>斜体</i>  <u>下划线</u>  <s>删除线</s>\n"
    "  <c1>文字</c1> … <c9>文字</c9>：九种颜色（结束标签写 </c> 也行）\n"
    "  <c#FF0000>红色</c>：直接指定颜色，用六位十六进制\n"
    "  <bg1>文字</bg1> … <bg9>文字</bg9>：九种背景高亮；<bg#FFFF00>高亮</bg> 同理\n"
    "  <br>：换行\n"
    "★ 直接写就行，不要再用别的符号把标签包起来。"
    "在代码块里不要使用这些标签。\n";

const char *fdmpc_builtin_spec(const char *type) {
    if (pc_eq(type, FDMPC_T_SUGGEST))  return kSpecSuggest;
    if (pc_eq(type, FDMPC_T_MUSIC))    return kSpecMusic;
    if (pc_eq(type, FDMPC_T_RICHTEXT)) return kSpecRichtextHead;
    return NULL;                       /* text / textsrc：内容在卡片里 */
}

/* ============================================================
 * 三、生命周期
 * ============================================================ */

static void pc_list_free(char **list, size_t n) {
    if (!list) return;
    for (size_t i = 0; i < n; i++) free(list[i]);
    free(list);
}

void fdmpc_free(fdmpc_state *st) {
    if (!st) return;
    if (st->cards) {
        for (size_t i = 0; i < st->count; i++) {
            free(st->cards[i].key);
            free(st->cards[i].type);
            free(st->cards[i].title);
            free(st->cards[i].text);
        }
        free(st->cards);
    }
    pc_list_free(st->drawer, st->drawer_n);
    pc_list_free(st->box, st->box_n);
    memset(st, 0, sizeof(*st));
    st->next_id = 1;
}

/* ---- 卡片表扩容 ---- */
static int pc_reserve(fdmpc_state *st, size_t need) {
    if (st->cap >= need) return 0;
    size_t nc = st->cap ? st->cap : 8;
    while (nc < need) nc *= 2;
    fdmpc_card *p = (fdmpc_card *)realloc(st->cards, nc * sizeof(*p));
    if (!p) return -1;
    st->cards = p;
    st->cap = nc;
    return 0;
}

/* ---- 加一张卡（深拷贝） ---- */
static fdmpc_card *pc_add(fdmpc_state *st, const char *key, const char *type,
                          const char *title, const char *text, int withTitle) {
    if (!st || !key || !type) return NULL;
    if (st->count >= FDMPC_MAX_CARDS) return NULL;
    if (fdmpc_find(st, key) >= 0) return NULL;          /* key 不许重复 */
    if (pc_reserve(st, st->count + 1) != 0) return NULL;

    fdmpc_card *c = &st->cards[st->count];
    memset(c, 0, sizeof(*c));
    c->key   = pc_strdup(key);
    c->type  = pc_strdup(type);
    c->title = pc_strdup(title ? title : "");
    c->text  = pc_strdup(text ? text : "");
    c->withTitle = withTitle ? 1 : 0;
    if (!c->key || !c->type || !c->title || !c->text) {
        free(c->key); free(c->type); free(c->title); free(c->text);
        memset(c, 0, sizeof(*c));
        return NULL;
    }
    st->count++;
    return c;
}

/* ---- 往抽屉里推一个 key ---- */
static int pc_drawer_push(fdmpc_state *st, const char *key) {
    if (st->drawer_n >= FDMPC_MAX_LIST) return -1;
    char **p = (char **)realloc(st->drawer, (st->drawer_n + 1) * sizeof(char *));
    if (!p) return -1;
    st->drawer = p;
    char *k = pc_strdup(key);
    if (!k) return -1;
    st->drawer[st->drawer_n++] = k;
    return 0;
}

static int pc_box_push(fdmpc_state *st, const char *key) {
    if (st->box_n >= FDMPC_MAX_LIST) return -1;
    char **p = (char **)realloc(st->box, (st->box_n + 1) * sizeof(char *));
    if (!p) return -1;
    st->box = p;
    char *k = pc_strdup(key);
    if (!k) return -1;
    st->box[st->box_n++] = k;
    return 0;
}

/* ---- 从列表里摘掉某个 key（保持顺序） ---- */
static int pc_list_remove(char **list, size_t *n, const char *key) {
    if (!list || !n || !key) return -1;
    for (size_t i = 0; i < *n; i++) {
        if (pc_eq(list[i], key)) {
            free(list[i]);
            if (i + 1 < *n)
                memmove(&list[i], &list[i + 1], (*n - i - 1) * sizeof(char *));
            (*n)--;
            return 0;
        }
    }
    return -1;
}

/** 从卡片表里硬删（**不做任何保护检查**，只给归一化内部用）。 */
static void pc_remove_card_raw(fdmpc_state *st, const char *key) {
    int i = fdmpc_find(st, key);
    if (i < 0) return;
    free(st->cards[i].key);
    free(st->cards[i].type);
    free(st->cards[i].title);
    free(st->cards[i].text);
    if ((size_t)i + 1 < st->count)
        memmove(&st->cards[i], &st->cards[i + 1],
                (st->count - (size_t)i - 1) * sizeof(fdmpc_card));
    st->count--;
}

int fdmpc_init(fdmpc_state *st) {
    if (!st) return -1;
    memset(st, 0, sizeof(*st));
    st->next_id = 1;

    /* 默认卡片池：内置三张 + 源卡（对应安卓 defaultCards / defaultDrawer） */
    pc_add(st, FDMPC_T_SUGGEST,  FDMPC_T_SUGGEST,  "回复建议", "", 0);
    pc_add(st, FDMPC_T_MUSIC,    FDMPC_T_MUSIC,    "音乐",     "", 0);
    pc_add(st, FDMPC_T_RICHTEXT, FDMPC_T_RICHTEXT, "富文本",   "", 0);
    pc_add(st, FDMPC_K_SRC,      FDMPC_T_TEXTSRC,  "系统提示词内容", "", 0);

    pc_drawer_push(st, FDMPC_T_SUGGEST);
    pc_drawer_push(st, FDMPC_T_MUSIC);
    pc_drawer_push(st, FDMPC_T_RICHTEXT);
    pc_drawer_push(st, FDMPC_K_SRC);
    return 0;
}

/* ============================================================
 * 四、卡片表操作
 * ============================================================ */

fdmpc_card *fdmpc_at(fdmpc_state *st, size_t i) {
    if (!st || i >= st->count) return NULL;
    return &st->cards[i];
}

const fdmpc_card *fdmpc_at_c(const fdmpc_state *st, size_t i) {
    if (!st || i >= st->count) return NULL;
    return &st->cards[i];
}

int fdmpc_find(const fdmpc_state *st, const char *key) {
    if (!st || !key) return -1;
    for (size_t i = 0; i < st->count; i++)
        if (pc_eq(st->cards[i].key, key)) return (int)i;
    return -1;
}

fdmpc_card *fdmpc_get(fdmpc_state *st, const char *key) {
    int i = fdmpc_find(st, key);
    return (i < 0) ? NULL : &st->cards[i];
}

const fdmpc_card *fdmpc_get_c(const fdmpc_state *st, const char *key) {
    int i = fdmpc_find(st, key);
    return (i < 0) ? NULL : &st->cards[i];
}

char *fdmpc_new_text_card(fdmpc_state *st) {
    if (!st) return NULL;
    char key[32];
    /* 跳过已被占用的编号（存档里可能有别的 id 序列） */
    for (int guard = 0; guard < FDMPC_MAX_CARDS; guard++) {
        snprintf(key, sizeof(key), "text#%d", st->next_id);
        st->next_id++;
        if (fdmpc_find(st, key) >= 0) continue;         /* 撞了就下一个 */
        if (!pc_add(st, key, FDMPC_T_TEXT, FDMPC_DEF_TITLE, FDMPC_DEF_TEXT, 0))
            return NULL;
        pc_drawer_push(st, key);
        return pc_strdup(key);
    }
    return NULL;
}

int fdmpc_set_title(fdmpc_state *st, const char *key, const char *title) {
    fdmpc_card *c = fdmpc_get(st, key);
    if (!c) return -1;
    return pc_replace(&c->title, title);
}

int fdmpc_set_text(fdmpc_state *st, const char *key, const char *text) {
    fdmpc_card *c = fdmpc_get(st, key);
    if (!c) return -1;
    return pc_replace(&c->text, text);
}

int fdmpc_set_with_title(fdmpc_state *st, const char *key, int on) {
    fdmpc_card *c = fdmpc_get(st, key);
    if (!c) return -1;
    c->withTitle = on ? 1 : 0;
    return 0;
}

int fdmpc_delete_card(fdmpc_state *st, const char *key) {
    if (!st || !key) return -1;
    const fdmpc_card *c = fdmpc_get_c(st, key);
    if (!c) return -1;
    /* ★ 内置三张和源卡不许删（安卓同语义：它们没有删除按钮） */
    if (fdmpc_is_builtin_type(c->type)) return -1;
    if (pc_eq(c->type, FDMPC_T_TEXTSRC)) return -1;

    /* ★ 同样先复制：下面两个 pc_list_remove 会把 key 本身 free 掉，
     *   之后再 fdmpc_find(st, key) 就是 use-after-free。 */
    char *kcopy = pc_strdup(key);
    if (!kcopy) return -1;

    pc_list_remove(st->drawer, &st->drawer_n, kcopy);
    pc_list_remove(st->box, &st->box_n, kcopy);

    pc_remove_card_raw(st, kcopy);
    free(kcopy);
    return 0;
}

/* ============================================================
 * 五、抽屉 ⇄ 容器
 * ============================================================ */

int fdmpc_where(const fdmpc_state *st, const char *key) {
    if (!st || !key) return -1;
    for (size_t i = 0; i < st->box_n; i++)    if (pc_eq(st->box[i], key)) return 1;
    for (size_t i = 0; i < st->drawer_n; i++) if (pc_eq(st->drawer[i], key)) return 0;
    return -1;
}

int fdmpc_move_in(fdmpc_state *st, const char *key) {
    if (!st || !key) return -1;
    const fdmpc_card *c = fdmpc_get_c(st, key);
    if (!c) return -1;

    /* ---- 源卡片：复制（抽屉里留一份，容器里追加新副本） ---- */
    if (pc_eq(c->type, FDMPC_T_TEXTSRC)) {
        char *nk = fdmpc_new_text_card(st);
        if (!nk) return -1;
        /* 新副本本来就在抽屉末尾；把它搬到容器 */
        pc_list_remove(st->drawer, &st->drawer_n, nk);
        pc_box_push(st, nk);
        free(nk);
        return 0;
    }

    /* ---- 内置 / 自定义：搬 ----
     * ★★ 2026-10-25 真机抓到的 use-after-free（这是本轮最贵的 bug）：
     *
     *   `pc_list_remove(st->drawer, ..., key)` 内部会 **free(list[i])**，
     *   而新版的 `key` 往往就是 `st->drawer[i]` 本身
     *   ⇒ 之后再 `pc_box_push(st, key)` 就是拿**已释放的指针**去 strdup。
     *
     *   小窝的 gcc 不覆写刚 free 的内存，内容还在，所以测试全过；
     *   真机（malloc 的 tcache）立刻把它覆写成垃圾
     *   ⇒ box[] 里存了垃圾 key ⇒ compose 找不到卡 ⇒ 提示词 0 字、
     *     归一化补出来的卡标题是垃圾 ⇒ 界面一片 "?"、拖拽拿到 nil。
     *
     *   ⇒ 必须先复制一份，之后全程用副本。
     */
    char *kcopy = pc_strdup(key);
    if (!kcopy) return -1;

    if (fdmpc_where(st, kcopy) == 1) { free(kcopy); return -1; }   /* 已在容器里 */
    if (pc_list_remove(st->drawer, &st->drawer_n, kcopy) != 0) {
        free(kcopy);
        return -1;
    }
    if (pc_box_push(st, kcopy) != 0) {          /* 失败要退回抽屉 */
        pc_drawer_push(st, kcopy);
        free(kcopy);
        return -1;
    }
    free(kcopy);
    return 0;
}

int fdmpc_move_out(fdmpc_state *st, const char *key) {
    if (!st || !key) return -1;
    if (fdmpc_where(st, key) != 1) return -1;   /* 不在容器里 */

    /* ★ 同上：先复制，避免 pc_list_remove 把 key 本身 free 掉 */
    char *kcopy = pc_strdup(key);
    if (!kcopy) return -1;

    if (pc_list_remove(st->box, &st->box_n, kcopy) != 0) {
        free(kcopy);
        return -1;
    }
    if (pc_drawer_push(st, kcopy) != 0) {
        pc_box_push(st, kcopy);                  /* 退回容器 */
        free(kcopy);
        return -1;
    }
    free(kcopy);
    return 0;
}

int fdmpc_box_move(fdmpc_state *st, size_t from, size_t to) {
    if (!st || from >= st->box_n || to >= st->box_n) return -1;
    if (from == to) return 0;
    char *k = st->box[from];
    if (from < to) {
        memmove(&st->box[from], &st->box[from + 1], (to - from) * sizeof(char *));
    } else {
        memmove(&st->box[to + 1], &st->box[to], (from - to) * sizeof(char *));
    }
    st->box[to] = k;
    return 0;
}

/* ============================================================
 * 六、★ 重建系统提示词
 * ============================================================ */

char *fdmpc_compose(const fdmpc_state *st) {
    if (!st) return NULL;

    /* 先算长度，一次分配 —— 别用反复 realloc（真机上是热路径） */
    size_t need = 1;
    for (size_t i = 0; i < st->box_n; i++) {
        const fdmpc_card *c = fdmpc_get_c(st, st->box[i]);
        if (!c) continue;
        const char *sp = fdmpc_builtin_spec(c->type);
        if (sp) need += strlen(sp) + 2;
        else    need += strlen(c->title) + strlen(c->text) + 3;
    }

    char *out = (char *)malloc(need);
    if (!out) return NULL;
    out[0] = '\0';
    size_t w = 0;

    for (size_t i = 0; i < st->box_n; i++) {
        const fdmpc_card *c = fdmpc_get_c(st, st->box[i]);
        if (!c) continue;

        /* 每张卡生成「它那一段」（malloc，稍后释放） */
        char *seg = NULL;
        const char *sp = fdmpc_builtin_spec(c->type);
        if (sp) {
            seg = pc_strdup(sp);
        } else if (pc_eq(c->type, FDMPC_T_TEXT)) {
            if (c->withTitle && c->title[0]) {
                size_t n = strlen(c->title) + strlen(c->text) + 2;
                seg = (char *)malloc(n);
                if (seg) snprintf(seg, n, "%s\n%s", c->title, c->text);
            } else {
                seg = pc_strdup(c->text);
            }
        }
        /* textsrc 不该出现在容器里（归一化会保证），真出现了就跳过 */
        if (!seg) continue;

        /* ★ 空段跳过：不占位、不产生多余空行 */
        char *t = pc_trim(seg);
        if (!t[0]) { free(seg); continue; }

        if (w > 0) { out[w++] = '\n'; out[w++] = '\n'; }
        size_t sl = strlen(t);
        memcpy(out + w, t, sl);
        w += sl;
        out[w] = '\0';
        free(seg);
    }
    return out;
}

/* ============================================================
 * 七、JSON 序列化
 * ============================================================ */

static size_t pc_esc_len(const char *s) {
    size_t n = 0;
    for (const unsigned char *p = (const unsigned char *)(s ? s : ""); *p; p++) {
        if (*p == '"' || *p == '\\') n += 2;
        else if (*p < 0x20) n += 6;
        else n += 1;
    }
    return n;
}

static char *pc_esc_into(char *o, const char *s) {
    static const char *hex = "0123456789abcdef";
    for (const unsigned char *p = (const unsigned char *)(s ? s : ""); *p; p++) {
        if (*p == '"')       { *o++ = '\\'; *o++ = '"'; }
        else if (*p == '\\') { *o++ = '\\'; *o++ = '\\'; }
        else if (*p == '\n') { *o++ = '\\'; *o++ = 'n'; }
        else if (*p == '\r') { *o++ = '\\'; *o++ = 'r'; }
        else if (*p == '\t') { *o++ = '\\'; *o++ = 't'; }
        else if (*p < 0x20) {
            *o++ = '\\'; *o++ = 'u'; *o++ = '0'; *o++ = '0';
            *o++ = hex[(*p >> 4) & 0xF]; *o++ = hex[*p & 0xF];
        }
        else *o++ = (char)*p;
    }
    return o;
}

char *fdmpc_to_json(const fdmpc_state *st) {
    if (!st) return NULL;

    size_t need = 256;
    for (size_t i = 0; i < st->count; i++) {
        const fdmpc_card *c = &st->cards[i];
        need += pc_esc_len(c->key) + pc_esc_len(c->type) +
                pc_esc_len(c->title) + pc_esc_len(c->text) + 80;
    }
    for (size_t i = 0; i < st->drawer_n; i++) need += pc_esc_len(st->drawer[i]) + 4;
    for (size_t i = 0; i < st->box_n; i++)    need += pc_esc_len(st->box[i]) + 4;

    char *out = (char *)malloc(need);
    if (!out) return NULL;
    char *o = out;

    o += sprintf(o, "{\"nextId\":%d,\"drawer\":[", st->next_id);
    for (size_t i = 0; i < st->drawer_n; i++) {
        /* ★ 格式串里**别**再带 \" —— 分隔符已经在 %s 里了。
         *   曾经写成 "%s\"" ⇒ 第一个元素变成 ""music（多一对引号）⇒ JSON 坏掉。 */
        o += sprintf(o, "%s", i ? ",\"" : "\"");
        o = pc_esc_into(o, st->drawer[i]);
        o += sprintf(o, "\"");
    }
    o += sprintf(o, "],\"box\":[");
    for (size_t i = 0; i < st->box_n; i++) {
        o += sprintf(o, "%s", i ? ",\"" : "\"");
        o = pc_esc_into(o, st->box[i]);
        o += sprintf(o, "\"");
    }
    o += sprintf(o, "],\"cards\":[");
    for (size_t i = 0; i < st->count; i++) {
        const fdmpc_card *c = &st->cards[i];
        o += sprintf(o, "%s{\"k\":\"", i ? "," : "");
        o = pc_esc_into(o, c->key);
        o += sprintf(o, "\",\"t\":\"");
        o = pc_esc_into(o, c->type);
        o += sprintf(o, "\",\"ti\":\"");
        o = pc_esc_into(o, c->title);
        o += sprintf(o, "\",\"tx\":\"");
        o = pc_esc_into(o, c->text);
        o += sprintf(o, "\",\"wt\":%d}", c->withTitle);
    }
    o += sprintf(o, "]}");
    (void)o;
    return out;
}

/* ============================================================
 * 八、JSON 宽容解析（复用音乐那边验证过的写法）
 * ============================================================ */

static const char *pc_skip_ws(const char *p) {
    while (p && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
    return p;
}

static const char *pc_skip_value(const char *p) {
    p = pc_skip_ws(p);
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
            if (*p == '"') {
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
            else if (*p == '}' || *p == ']') { depth--; if (depth == 0) return p + 1; }
            p++;
        }
        return NULL;
    }
    while (*p && *p != ',' && *p != '}' && *p != ']' &&
           *p != ' ' && *p != '\t' && *p != '\n' && *p != '\r') p++;
    return p;
}

static const char *pc_find_key(const char *p, const char *end, const char *key) {
    if (!p || !key) return NULL;
    size_t kl = strlen(key);
    while (p < end) {
        while (p < end && *p != '"') p++;
        if (p >= end) return NULL;
        const char *ks = p + 1, *ke = ks;
        while (ke < end && *ke != '"') {
            if (*ke == '\\') ke++;
            ke++;
        }
        if (ke >= end) return NULL;
        const char *after = ke + 1;
        if ((size_t)(ke - ks) == kl && memcmp(ks, key, kl) == 0) {
            const char *c = pc_skip_ws(after);
            if (c && c < end && *c == ':') {
                c = pc_skip_ws(c + 1);
                return (c && c < end) ? c : NULL;
            }
        }
        p = after;
    }
    return NULL;
}

static int pc_unescape(const char *p, const char *end, char *out, size_t n) {
    if (!out || n == 0) return -1;
    size_t w = 0;
    if (!p || p >= end || *p != '"') { out[0] = '\0'; return -1; }
    p++;
    while (p < end && *p != '"') {
        unsigned char c = (unsigned char)*p;
        if (c == '\\') {
            p++;
            if (p >= end) break;
            switch (*p) {
                case '"':  c = '"';  p++; break;
                case '\\': c = '\\'; p++; break;
                case '/':  c = '/';  p++; break;
                case 'n':  c = '\n'; p++; break;
                case 'r':  c = '\r'; p++; break;
                case 't':  c = '\t'; p++; break;
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
                    if (cp < 0x80) { if (w + 1 < n) out[w++] = (char)cp; }
                    else if (cp < 0x800) {
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

static long pc_get_ll(const char *obj, const char *end, const char *key, long def) {
    const char *v = pc_find_key(obj, end, key);
    if (!v) return def;
    v = pc_skip_ws(v);
    if (!v || *v == '"' || *v == '{' || *v == '[') return def;
    char *tail = NULL;
    long r = strtol(v, &tail, 10);
    if (tail == v) return def;
    return r;
}

/** 取一个字符串字段（成功 1 / 没这个键 0）。 */
static int pc_get_str(const char *obj, const char *end, const char *key, char **out) {
    const char *v = pc_find_key(obj, end, key);
    if (!v) return 0;
    v = pc_skip_ws(v);
    if (!v || *v != '"') return 0;
    const char *after = pc_skip_value(v);
    if (!after) return 0;
    size_t cap = (size_t)(after - v) + 1;
    char *buf = (char *)malloc(cap);
    if (!buf) return 0;
    if (pc_unescape(v, end, buf, cap) < 0) { free(buf); return 0; }
    free(*out);
    *out = buf;
    return 1;
}

/** 读一个字符串数组到 out（最多 max 个）。返回读到的个数。 */
static size_t pc_get_str_array(const char *p, const char *end,
                               char ***out, size_t max) {
    *out = NULL;
    const char *v = pc_skip_ws(p);
    if (!v || *v != '[') return 0;
    const char *q = v + 1;
    size_t n = 0;
    char **list = NULL;
    while (q && *q) {
        q = pc_skip_ws(q);
        if (!q || *q == ']') break;
        if (*q != '"') { q = pc_skip_value(q); if (q && *q == ',') q++; continue; }
        const char *after = pc_skip_value(q);
        if (!after) break;
        if (n < max) {
            size_t cap = (size_t)(after - q) + 1;
            char *buf = (char *)malloc(cap);
            if (buf && pc_unescape(q, end, buf, cap) >= 0) {
                char **np = (char **)realloc(list, (n + 1) * sizeof(char *));
                if (np) { list = np; list[n++] = buf; }
                else free(buf);
            } else {
                free(buf);
            }
        }
        q = after;
        if (q && *q == ',') q++;
    }
    *out = list;
    return n;
}

/* ============================================================
 * 九、★ 归一化（这里是整个存档最容易出事的地方）
 * ============================================================ */

/**
 * 归一化规则（逐条对应安卓 3.62.2 那次修复）：
 *   ① 列表里出现但卡片表里没有的 key → 补一张卡（按 key 猜类型）
 *   ② 卡片表里有但不认识类型 → 丢掉
 *   ③ 内置三张 + 源卡**必须存在**，缺了补回抽屉
 *   ④ 同一个 key 不能同时在两个列表里（优先保留容器里的）
 *   ⑤ 数量超上限 → 截断
 */
static void pc_normalize(fdmpc_state *st) {
    if (!st) return;

    /* ③ 内置三张 + 源卡必须存在 */
    static const struct { const char *key, *type, *title; } need[] = {
        { FDMPC_T_SUGGEST,  FDMPC_T_SUGGEST,  "回复建议" },
        { FDMPC_T_MUSIC,    FDMPC_T_MUSIC,    "音乐" },
        { FDMPC_T_RICHTEXT, FDMPC_T_RICHTEXT, "富文本" },
        { FDMPC_K_SRC,      FDMPC_T_TEXTSRC,  "系统提示词内容" },
    };
    for (size_t i = 0; i < sizeof(need) / sizeof(need[0]); i++) {
        if (fdmpc_find(st, need[i].key) < 0)
            pc_add(st, need[i].key, need[i].type, need[i].title, "", 0);
    }

    /* ① 列表里出现但卡片表没有 → 补（按 key 猜类型：textsrc → 源卡，其余 → 自定义） */
    for (int pass = 0; pass < 2; pass++) {
        char **list = pass ? st->box : st->drawer;
        size_t n = pass ? st->box_n : st->drawer_n;
        for (size_t i = 0; i < n; i++) {
            const char *k = list[i];
            if (fdmpc_find(st, k) >= 0) continue;
            const char *t = pc_eq(k, FDMPC_K_SRC) ? FDMPC_T_TEXTSRC : FDMPC_T_TEXT;
            pc_add(st, k, t, fdmpc_type_title(t), "", 0);
        }
    }

    /* ② 卡片表里有、但类型不认识的 → 丢掉（连引用一起） */
    for (size_t i = 0; i < st->count; ) {
        const char *t = st->cards[i].type;
        if (!fdmpc_is_builtin_type(t) && !fdmpc_is_text_type(t)) {
            char bad[128];
            snprintf(bad, sizeof(bad), "%s", st->cards[i].key ? st->cards[i].key : "");
            pc_list_remove(st->drawer, &st->drawer_n, bad);
            pc_list_remove(st->box, &st->box_n, bad);
            pc_remove_card_raw(st, bad);
            continue;                       /* 不 i++，因为挪过来了 */
        }
        i++;
    }

    /* ④ 同 key 不许同时在两个列表：容器优先 */
    for (size_t i = 0; i < st->box_n; ) {
        if (fdmpc_where(st, st->box[i]) != 1) { i++; continue; }
        /* 在抽屉里也有一份 → 抽屉那份删掉 */
        for (size_t j = 0; j < st->drawer_n; ) {
            if (pc_eq(st->drawer[j], st->box[i])) {
                pc_list_remove(st->drawer, &st->drawer_n, st->drawer[j]);
            } else j++;
        }
        i++;
    }

    /* 源卡不该在容器里（它在容器里会变成"复制"而不是"搬"，语义就乱了） */
    for (size_t i = 0; i < st->box_n; ) {
        if (pc_eq(st->box[i], FDMPC_K_SRC)) {
            pc_list_remove(st->box, &st->box_n, FDMPC_K_SRC);
        } else i++;
    }
    /* 源卡也不该是自定义副本类型 */
    fdmpc_card *src = fdmpc_get(st, FDMPC_K_SRC);
    if (src && !pc_eq(src->type, FDMPC_T_TEXTSRC)) {
        pc_replace(&src->type, FDMPC_T_TEXTSRC);
    }

    /* ⑤ 截断 */
    while (st->drawer_n > FDMPC_MAX_LIST) {
        free(st->drawer[st->drawer_n - 1]);
        st->drawer_n--;
    }
    while (st->box_n > FDMPC_MAX_LIST) {
        free(st->box[st->box_n - 1]);
        st->box_n--;
    }
}

/* ============================================================
 * 十、反序列化
 * ============================================================ */

int fdmpc_from_json(fdmpc_state *st, const char *json) {
    if (!st) return -1;
    if (!json || !*json) return -1;

    const char *end = json + strlen(json);
    const char *root = pc_skip_ws(json);
    if (!root || *root != '{') return -1;

    /* 先读 nextId（丢了就重算） */
    long nextId = pc_get_ll(root, end, "nextId", 0);

    /* ---- cards ---- */
    const char *cards = pc_find_key(root, end, "cards");
    if (!cards) return -1;
    cards = pc_skip_ws(cards);
    if (!cards || *cards != '[') return -1;

    /* 清空但保留 nextId */
    fdmpc_free(st);
    st->next_id = 1;

    const char *p = cards + 1;
    size_t loaded = 0;
    while (p && *p) {
        p = pc_skip_ws(p);
        if (!p || *p == ']') break;
        if (*p != '{') { p = pc_skip_value(p); if (p && *p == ',') p++; continue; }

        const char *objEnd = pc_skip_value(p);
        if (!objEnd) break;

        char *k = NULL, *t = NULL, *ti = NULL, *tx = NULL;
        pc_get_str(p, objEnd, "k",  &k);
        pc_get_str(p, objEnd, "t",  &t);
        pc_get_str(p, objEnd, "ti", &ti);
        pc_get_str(p, objEnd, "tx", &tx);
        long wt = pc_get_ll(p, objEnd, "wt", 0);

        if (k && k[0] && t && t[0]) {
            /* 只收认识的类型（不认识的归一化步骤也会丢，这里先省点内存） */
            if (fdmpc_is_builtin_type(t) || fdmpc_is_text_type(t)) {
                if (pc_add(st, k, t, ti ? ti : fdmpc_type_title(t),
                           tx ? tx : "", wt ? 1 : 0))
                    loaded++;
            }
        }
        free(k); free(t); free(ti); free(tx);

        p = objEnd;
        if (p && *p == ',') p++;
        if (loaded >= FDMPC_MAX_CARDS) break;
    }

    if (loaded == 0) {
        /* 一张都没读到 ⇒ 当作坏存档，回到默认池 */
        fdmpc_init(st);
        return -1;
    }

    /* ---- drawer ---- */
    {
        const char *v = pc_find_key(root, end, "drawer");
        if (v) {
            char **arr = NULL;
            size_t n = pc_get_str_array(v, end, &arr, FDMPC_MAX_LIST);
            st->drawer = arr;
            st->drawer_n = n;
        }
    }
    /* ---- box ---- */
    {
        const char *v = pc_find_key(root, end, "box");
        if (v) {
            char **arr = NULL;
            size_t n = pc_get_str_array(v, end, &arr, FDMPC_MAX_LIST);
            st->box = arr;
            st->box_n = n;
        }
    }

    /* nextId：存档里有且比现有编号大就用它，否则重算 */
    if (nextId > 0) {
        st->next_id = pc_clampi((int)nextId, 1, FDMPC_MAX_CARDS * 10);
    } else {
        st->next_id = 1;
    }
    /* 保险：把 next_id 推到「所有 text#N 的最大 N + 1」之后，避免重号 */
    for (size_t i = 0; i < st->count; i++) {
        const char *k = st->cards[i].key;
        if (k && strncmp(k, "text#", 5) == 0) {
            int n = atoi(k + 5);
            if (n >= st->next_id) st->next_id = n + 1;
        }
    }

    /* ★ 归一化（坏存档在这里被救回来） */
    pc_normalize(st);
    return 0;
}

/* ============================================================
 * 十一、自检
 * ============================================================ */

static int pc_chk(char *errbuf, int errlen, int no, const char *what, int ok) {
    if (ok) return 1;
    snprintf(errbuf, (size_t)errlen, "#%d %s", no, what);
    return 0;
}

int fdmpc_selftest(char *errbuf, int errlen) {
    char local[512];
    if (!errbuf) { errbuf = local; errlen = (int)sizeof(local); }
    errbuf[0] = '\0';

    fdmpc_state st;
    /* int i 没用到，删掉 */

    /* 1. 默认池：内置三张 + 源卡，全在抽屉里 */
    fdmpc_init(&st);
    if (!pc_chk(errbuf, errlen, 1, "默认应有 4 张卡",
                st.count == 4 && st.drawer_n == 4 && st.box_n == 0)) {
        fdmpc_free(&st); return 1;
    }
    if (!pc_chk(errbuf, errlen, 2, "默认抽屉顺序",
                pc_eq(st.drawer[0], FDMPC_T_SUGGEST) &&
                pc_eq(st.drawer[1], FDMPC_T_MUSIC) &&
                pc_eq(st.drawer[2], FDMPC_T_RICHTEXT) &&
                pc_eq(st.drawer[3], FDMPC_K_SRC))) {
        fdmpc_free(&st); return 2;
    }

    /* 2. 类型判定 */
    if (!pc_chk(errbuf, errlen, 3, "内置类型判定",
                fdmpc_is_builtin_type(FDMPC_T_SUGGEST) &&
                fdmpc_is_builtin_type(FDMPC_T_MUSIC) &&
                fdmpc_is_builtin_type(FDMPC_T_RICHTEXT) &&
                !fdmpc_is_builtin_type(FDMPC_T_TEXT) &&
                !fdmpc_is_builtin_type(NULL))) {
        fdmpc_free(&st); return 3;
    }
    if (!pc_chk(errbuf, errlen, 4, "文本类型判定",
                fdmpc_is_text_type(FDMPC_T_TEXT) &&
                fdmpc_is_text_type(FDMPC_T_TEXTSRC) &&
                !fdmpc_is_text_type(FDMPC_T_MUSIC))) {
        fdmpc_free(&st); return 4;
    }

    /* 3. 内置文案必须有内容且互不相同 */
    {
        const char *a = fdmpc_builtin_spec(FDMPC_T_SUGGEST);
        const char *b = fdmpc_builtin_spec(FDMPC_T_MUSIC);
        const char *c = fdmpc_builtin_spec(FDMPC_T_RICHTEXT);
        if (!pc_chk(errbuf, errlen, 5, "三段内置文案都要有",
                    a && b && c && strlen(a) > 50 && strlen(b) > 20 && strlen(c) > 100)) {
            fdmpc_free(&st); return 5;
        }
        if (!pc_chk(errbuf, errlen, 6, "内置文案都得带特征串（幂等判断靠它）",
                    strstr(a, "【追问建议】") && strstr(b, "【音乐变量】") &&
                    strstr(c, "【回答排版】"))) {
            fdmpc_free(&st); return 6;
        }
        if (!pc_chk(errbuf, errlen, 7, "text 类型不该有内置文案",
                    fdmpc_builtin_spec(FDMPC_T_TEXT) == NULL &&
                    fdmpc_builtin_spec("nonsense") == NULL)) {
            fdmpc_free(&st); return 7;
        }
    }

    /* 4. 容器空 ⇒ compose 返回空串（不是 NULL） */
    {
        char *s0 = fdmpc_compose(&st);
        if (!pc_chk(errbuf, errlen, 8, "容器空应返回空串",
                    s0 != NULL && s0[0] == '\0')) {
            free(s0); fdmpc_free(&st); return 8;
        }
        free(s0);
    }

    /* 5. 搬一张内置卡进容器 → 提示词就是它的文案 */
    if (!pc_chk(errbuf, errlen, 9, "move_in(suggest) 应返回 0",
                fdmpc_move_in(&st, FDMPC_T_SUGGEST) == 0)) {
        fdmpc_free(&st); return 9;
    }
    if (!pc_chk(errbuf, errlen, 10, "搬进去之后抽屉里不该还有它",
                fdmpc_where(&st, FDMPC_T_SUGGEST) == 1 &&
                st.box_n == 1 && st.drawer_n == 3)) {
        fdmpc_free(&st); return 10;
    }
    {
        char *s1 = fdmpc_compose(&st);
        const char *want = fdmpc_builtin_spec(FDMPC_T_SUGGEST);
        /* ⚠️ compose 会对每段做 trim（和安卓 `sb.append(seg.trim())` 一致），
         *    所以这里要拿 want 的 trim 版本比，不能直接 strcmp 原文。 */
        char wbuf[4096];
        snprintf(wbuf, sizeof(wbuf), "%s", want ? want : "");
        size_t wl = strlen(wbuf);
        while (wl > 0 && (wbuf[wl-1] == '\n' || wbuf[wl-1] == ' ' ||
                          wbuf[wl-1] == '\t' || wbuf[wl-1] == '\r')) wbuf[--wl] = '\0';
        char *wp = wbuf;
        while (*wp == '\n' || *wp == ' ' || *wp == '\t' || *wp == '\r') wp++;

        if (!pc_chk(errbuf, errlen, 11, "compose 应等于内置文案（trim 后）",
                    s1 && strcmp(s1, wp) == 0)) {
            free(s1); fdmpc_free(&st); return 11;
        }
        free(s1);
    }

    /* 6. 再搬两张 → 三段之间是空行（\n\n） */
    fdmpc_move_in(&st, FDMPC_T_MUSIC);
    fdmpc_move_in(&st, FDMPC_T_RICHTEXT);
    {
        char *s2 = fdmpc_compose(&st);
        /* ⚠️ 用特征串定位（compose 会 trim，完整文案对不上） */
        const char *ps = s2 ? strstr(s2, "【追问建议】") : NULL;
        const char *pm = s2 ? strstr(s2, "【音乐变量】") : NULL;
        const char *pr = s2 ? strstr(s2, "【回答排版】") : NULL;
        if (!pc_chk(errbuf, errlen, 12, "三段都得在，且之间有空行",
                    ps && pm && pr && strstr(s2, "\n\n") != NULL)) {
            free(s2); fdmpc_free(&st); return 12;
        }
        /* 顺序必须是 建议 → 音乐 → 富文本 */
        if (!pc_chk(errbuf, errlen, 13, "compose 顺序应跟容器一致",
                    ps < pm && pm < pr)) {
            free(s2); fdmpc_free(&st); return 13;
        }
        free(s2);
    }

    /* 7. 源卡片是"复制"不是"搬" */
    if (!pc_chk(errbuf, errlen, 14, "源卡 move_in 应返回 0",
                fdmpc_move_in(&st, FDMPC_K_SRC) == 0)) {
        fdmpc_free(&st); return 14;
    }
    if (!pc_chk(errbuf, errlen, 15, "源卡搬完后抽屉里还得留着它",
                fdmpc_where(&st, FDMPC_K_SRC) == 0)) {
        fdmpc_free(&st); return 15;
    }
    if (!pc_chk(errbuf, errlen, 16, "容器里应多了一张 text#N",
                st.box_n == 4 && strncmp(st.box[3], "text#", 5) == 0)) {
        fdmpc_free(&st); return 16;
    }
    if (!pc_chk(errbuf, errlen, 17, "源卡能无限复制（再来一次还是新增）",
                fdmpc_move_in(&st, FDMPC_K_SRC) == 0 && st.box_n == 5)) {
        fdmpc_free(&st); return 17;
    }

    /* 8. 新建副本的默认文案 */
    {
        char *k = fdmpc_new_text_card(&st);
        const fdmpc_card *c = fdmpc_get_c(&st, k);
        if (!pc_chk(errbuf, errlen, 18, "新副本默认标题/正文",
                    k && c && pc_eq(c->title, FDMPC_DEF_TITLE) &&
                    pc_eq(c->text, FDMPC_DEF_TEXT) && c->withTitle == 0)) {
            free(k); fdmpc_free(&st); return 18;
        }
        free(k);
    }

    /* 9. 自定义文本进提示词：withTitle 关 → 只有正文 */
    {
        char *k = fdmpc_new_text_card(&st);
        fdmpc_set_title(&st, k, "我的标题");
        fdmpc_set_text(&st, k, "我的正文内容");
        fdmpc_move_in(&st, k);
        char *s3 = fdmpc_compose(&st);
        if (!pc_chk(errbuf, errlen, 19, "withTitle=0 时标题不该进提示词",
                    s3 && strstr(s3, "我的正文内容") && !strstr(s3, "我的标题"))) {
            free(s3); free(k); fdmpc_free(&st); return 19;
        }
        free(s3);

        /* withTitle 开 → 标题 + \n + 正文 */
        fdmpc_set_with_title(&st, k, 1);
        char *s4 = fdmpc_compose(&st);
        if (!pc_chk(errbuf, errlen, 20, "withTitle=1 时标题要在正文前面",
                    s4 && strstr(s4, "我的标题\n我的正文内容"))) {
            free(s4); free(k); fdmpc_free(&st); return 20;
        }
        free(s4);
        free(k);
    }

    /* 10. 空正文的卡不占位（不产生多余空行） */
    {
        char *k = fdmpc_new_text_card(&st);
        fdmpc_set_text(&st, k, "   \n\t  ");      /* 全空白 */
        fdmpc_move_in(&st, k);
        char *s5 = fdmpc_compose(&st);
        if (!pc_chk(errbuf, errlen, 21, "空正文不该产生多余空行",
                    s5 && strstr(s5, "\n\n\n") == NULL)) {
            free(s5); free(k); fdmpc_free(&st); return 21;
        }
        free(s5);
        free(k);
    }

    /* 11. 内置卡和源卡不许删 */
    if (!pc_chk(errbuf, errlen, 22, "内置卡不许删",
                fdmpc_delete_card(&st, FDMPC_T_SUGGEST) == -1)) {
        fdmpc_free(&st); return 22;
    }
    if (!pc_chk(errbuf, errlen, 23, "源卡不许删",
                fdmpc_delete_card(&st, FDMPC_K_SRC) == -1)) {
        fdmpc_free(&st); return 23;
    }

    /* 101. ★★ use-after-free（编号跳开，避免和上面的撞） 检测（2026-10-25 真机抓到的那个 bug）
     *
     * 症状：move_in 之后 box[] 里存的是**已释放内存**的副本。
     * gcc 不覆写刚 free 的内存 ⇒ 小窝全过；真机 malloc 把它覆写成垃圾
     *       ⇒ compose 出 0 字、界面一片 "?"、拖拽拿到 nil。
     *
     * 检测手法：move_in 之后**故意大量分配+释放**（把刚 free 的那块覆盖掉），
     * 再检查 box[0] 的内容和 compose 的长度。如果实现里没先 strdup，
     * 这一步一定露馅。 */
    {
        fdmpc_state u;
        fdmpc_init(&u);
        const fdmpc_card *sc = fdmpc_get_c(&u, FDMPC_T_SUGGEST);
        size_t specLen = sc ? strlen(fdmpc_builtin_spec(sc->type)) : 0;

        if (!pc_chk(errbuf, errlen, 101, "UAF 前置：move_in 应成功",
                    fdmpc_move_in(&u, FDMPC_T_SUGGEST) == 0)) {
            fdmpc_free(&u); fdmpc_free(&st); return 101;
        }

        /* ★ 关键：用 200 个同尺寸块把 tcache 灌满，逼它复用刚 free 的那块 */
        for (int k = 0; k < 200; k++) {
            char *junk = (char *)malloc(32);
            if (junk) memset(junk, 'X', 31), junk[31] = '\0';
            free(junk);
        }

        if (!pc_chk(errbuf, errlen, 102, "UAF：box[0] 内容不该被覆写",
                    u.box_n == 1 && u.box[0] && pc_eq(u.box[0], FDMPC_T_SUGGEST))) {
            fdmpc_free(&u); fdmpc_free(&st); return 102;
        }
        char *cu = fdmpc_compose(&u);
        /* ⚠️ 别比长度 —— compose 会 trim 掉末尾换行。比特征串最稳。 */
        if (!pc_chk(errbuf, errlen, 103, "UAF：compose 不该是 0 字",
                    cu && strlen(cu) > specLen / 2 &&
                    strstr(cu, "【追问建议】") != NULL)) {
            free(cu); fdmpc_free(&u); fdmpc_free(&st); return 103;
        }
        free(cu);

        /* move_out 同理 */
        if (!pc_chk(errbuf, errlen, 104, "UAF：move_out 应成功",
                    fdmpc_move_out(&u, FDMPC_T_SUGGEST) == 0)) {
            fdmpc_free(&u); fdmpc_free(&st); return 104;
        }
        for (int k = 0; k < 200; k++) {
            char *junk = (char *)malloc(32);
            if (junk) memset(junk, 'Y', 31), junk[31] = '\0';
            free(junk);
        }
        if (!pc_chk(errbuf, errlen, 105, "UAF：move_out 后抽屉里的 key 也不该坏",
                    u.drawer_n == 4 && u.drawer[3] && pc_eq(u.drawer[3], FDMPC_T_SUGGEST))) {
            fdmpc_free(&u); fdmpc_free(&st); return 105;
        }
        fdmpc_free(&u);
    }

    /* 25. 自定义副本可以删，且会从两个列表里一起摘掉 */
    {
        char *k = fdmpc_new_text_card(&st);
        fdmpc_move_in(&st, k);
        size_t boxBefore = st.box_n;
        int rc = fdmpc_delete_card(&st, k);
        if (!pc_chk(errbuf, errlen, 24, "副本可以删",
                    rc == 0 && st.box_n == boxBefore - 1 &&
                    fdmpc_get_c(&st, k) == NULL && fdmpc_where(&st, k) == -1)) {
            free(k); fdmpc_free(&st); return 24;
        }
        free(k);
    }

    /* 13. 容器内重排 */
    {
        fdmpc_state t2;
        fdmpc_init(&t2);
        fdmpc_move_in(&t2, FDMPC_T_SUGGEST);
        fdmpc_move_in(&t2, FDMPC_T_MUSIC);
        fdmpc_move_in(&t2, FDMPC_T_RICHTEXT);
        if (!pc_chk(errbuf, errlen, 25, "box_move 前",
                    pc_eq(t2.box[0], FDMPC_T_SUGGEST) &&
                    pc_eq(t2.box[2], FDMPC_T_RICHTEXT))) {
            fdmpc_free(&t2); fdmpc_free(&st); return 25;
        }
        fdmpc_box_move(&t2, 0, 2);          /* 把建议挪到最后 */
        if (!pc_chk(errbuf, errlen, 26, "box_move 后顺序",
                    pc_eq(t2.box[0], FDMPC_T_MUSIC) &&
                    pc_eq(t2.box[1], FDMPC_T_RICHTEXT) &&
                    pc_eq(t2.box[2], FDMPC_T_SUGGEST))) {
            fdmpc_free(&t2); fdmpc_free(&st); return 26;
        }
        /* compose 得跟着变。
         * ⚠️ 用**特征串**定位，别用完整文案 —— compose 会 trim 掉末尾换行。 */
        char *s6 = fdmpc_compose(&t2);
        const char *pm = s6 ? strstr(s6, "【音乐变量】") : NULL;
        const char *ps = s6 ? strstr(s6, "【追问建议】") : NULL;
        if (!pc_chk(errbuf, errlen, 27, "compose 应跟着重排（音乐在建议前面）",
                    pm && ps && pm < ps)) {
            free(s6); fdmpc_free(&t2); fdmpc_free(&st); return 27;
        }
        free(s6);
        fdmpc_free(&t2);
    }

    /* 14. JSON 往返 */
    {
        char *js = fdmpc_to_json(&st);
        if (!pc_chk(errbuf, errlen, 28, "to_json 应返回非 NULL", js != NULL)) {
            free(js); fdmpc_free(&st); return 28;
        }
        fdmpc_state rt;
        fdmpc_init(&rt);
        int rc = fdmpc_from_json(&rt, js);
        free(js);
        if (!pc_chk(errbuf, errlen, 29, "from_json 应成功", rc == 0)) {
            fdmpc_free(&rt); fdmpc_free(&st); return 29;
        }
        if (!pc_chk(errbuf, errlen, 30, "往返：数量一致",
                    rt.count == st.count && rt.box_n == st.box_n &&
                    rt.drawer_n == st.drawer_n)) {
            fdmpc_free(&rt); fdmpc_free(&st); return 30;
        }
        /* 往返后 compose 必须一模一样 */
        char *sA = fdmpc_compose(&st);
        char *sB = fdmpc_compose(&rt);
        if (!pc_chk(errbuf, errlen, 31, "往返：compose 应逐字节相同",
                    sA && sB && strcmp(sA, sB) == 0)) {
            free(sA); free(sB); fdmpc_free(&rt); fdmpc_free(&st); return 31;
        }
        free(sA); free(sB);
        fdmpc_free(&rt);
    }

    /* 15. 坏存档容错 */
    {
        fdmpc_state bad;
        fdmpc_init(&bad);
        if (!pc_chk(errbuf, errlen, 32, "空串应 -1",
                    fdmpc_from_json(&bad, "") == -1 && bad.count == 4)) {
            fdmpc_free(&bad); fdmpc_free(&st); return 32;
        }
        if (!pc_chk(errbuf, errlen, 33, "乱码应 -1 且回到默认池",
                    fdmpc_from_json(&bad, "{{{<<<") == -1 &&
                    bad.count == 4 && bad.drawer_n == 4)) {
            fdmpc_free(&bad); fdmpc_free(&st); return 33;
        }
        /* 截断 */
        if (!pc_chk(errbuf, errlen, 34, "截断的 JSON 不该崩",
                    fdmpc_from_json(&bad,
                        "{\"drawer\":[\"suggest\"],\"box\":[\"richtext\"],"
                        "\"cards\":[{\"k\":\"suggest\",\"t\":\"sugg") == -1)) {
            fdmpc_free(&bad); fdmpc_free(&st); return 34;
        }
        fdmpc_free(&bad);
    }

    /* 16. ★ 归一化：内置三张丢了要长回来 */
    {
        fdmpc_state n1;
        fdmpc_init(&n1);
        int rc = fdmpc_from_json(&n1,
            "{\"nextId\":1,\"drawer\":[],\"box\":[],"
            "\"cards\":[{\"k\":\"text#1\",\"t\":\"text\",\"ti\":\"A\",\"tx\":\"B\"}]}");
        if (!pc_chk(errbuf, errlen, 35, "只剩一张自定义卡时也要把内置三张补回来",
                    rc == 0 && n1.count == 5 &&
                    fdmpc_get_c(&n1, FDMPC_T_SUGGEST) != NULL &&
                    fdmpc_get_c(&n1, FDMPC_T_MUSIC) != NULL &&
                    fdmpc_get_c(&n1, FDMPC_T_RICHTEXT) != NULL &&
                    fdmpc_get_c(&n1, FDMPC_K_SRC) != NULL)) {
            fdmpc_free(&n1); fdmpc_free(&st); return 35;
        }
        fdmpc_free(&n1);
    }

    /* 17. ★ 归一化：列表里有、卡片表没有 → 补一张 */
    {
        fdmpc_state n2;
        fdmpc_init(&n2);
        int rc = fdmpc_from_json(&n2,
            "{\"nextId\":1,\"drawer\":[],\"box\":[\"text#9\"],"
            "\"cards\":[{\"k\":\"suggest\",\"t\":\"suggest\"},"
            "{\"k\":\"music\",\"t\":\"music\"},"
            "{\"k\":\"richtext\",\"t\":\"richtext\"},"
            "{\"k\":\"textsrc\",\"t\":\"textsrc\"}]}");
        if (!pc_chk(errbuf, errlen, 36, "箱里的孤儿 key 应补出卡片",
                    rc == 0 && fdmpc_get_c(&n2, "text#9") != NULL)) {
            fdmpc_free(&n2); fdmpc_free(&st); return 36;
        }
        fdmpc_free(&n2);
    }

    /* 18. ★ 归一化：未知类型要丢掉 */
    {
        fdmpc_state n3;
        fdmpc_init(&n3);
        int rc = fdmpc_from_json(&n3,
            "{\"nextId\":1,\"drawer\":[],\"box\":[],"
            "\"cards\":[{\"k\":\"suggest\",\"t\":\"suggest\"},"
            "{\"k\":\"music\",\"t\":\"music\"},"
            "{\"k\":\"richtext\",\"t\":\"richtext\"},"
            "{\"k\":\"textsrc\",\"t\":\"textsrc\"},"
            "{\"k\":\"weird\",\"t\":\"外星类型\"}]}");
        if (!pc_chk(errbuf, errlen, 37, "未知类型应被丢掉",
                    rc == 0 && fdmpc_get_c(&n3, "weird") == NULL)) {
            fdmpc_free(&n3); fdmpc_free(&st); return 37;
        }
        fdmpc_free(&n3);
    }

    /* 19. ★ 归一化：源卡不该出现在容器里 */
    {
        fdmpc_state n4;
        fdmpc_init(&n4);
        fdmpc_from_json(&n4,
            "{\"nextId\":1,\"drawer\":[],\"box\":[\"textsrc\"],"
            "\"cards\":[{\"k\":\"suggest\",\"t\":\"suggest\"},"
            "{\"k\":\"music\",\"t\":\"music\"},"
            "{\"k\":\"richtext\",\"t\":\"richtext\"},"
            "{\"k\":\"textsrc\",\"t\":\"textsrc\"}]}");
        if (!pc_chk(errbuf, errlen, 38, "源卡应从容器里被摘掉",
                    fdmpc_where(&n4, FDMPC_K_SRC) != 1)) {
            fdmpc_free(&n4); fdmpc_free(&st); return 38;
        }
        fdmpc_free(&n4);
    }

    /* 20. ★ 归一化：同一个 key 不许同时在两个列表 */
    {
        fdmpc_state n5;
        fdmpc_init(&n5);
        fdmpc_from_json(&n5,
            "{\"nextId\":1,\"drawer\":[\"suggest\"],\"box\":[\"suggest\"],"
            "\"cards\":[{\"k\":\"suggest\",\"t\":\"suggest\"},"
            "{\"k\":\"music\",\"t\":\"music\"},"
            "{\"k\":\"richtext\",\"t\":\"richtext\"},"
            "{\"k\":\"textsrc\",\"t\":\"textsrc\"}]}");
        int inDrawer = 0, inBox = 0;
        for (size_t i = 0; i < n5.drawer_n; i++) if (pc_eq(n5.drawer[i], FDMPC_T_SUGGEST)) inDrawer++;
        for (size_t i = 0; i < n5.box_n; i++)    if (pc_eq(n5.box[i], FDMPC_T_SUGGEST)) inBox++;
        if (!pc_chk(errbuf, errlen, 39, "同 key 不该同时在两个列表",
                    inDrawer + inBox == 1)) {
            fdmpc_free(&n5); fdmpc_free(&st); return 39;
        }
        fdmpc_free(&n5);
    }

    /* 21. nextId 不重号 */
    {
        fdmpc_state n6;
        fdmpc_init(&n6);
        fdmpc_from_json(&n6,
            "{\"nextId\":1,\"drawer\":[],\"box\":[],"
            "\"cards\":[{\"k\":\"suggest\",\"t\":\"suggest\"},"
            "{\"k\":\"music\",\"t\":\"music\"},"
            "{\"k\":\"richtext\",\"t\":\"richtext\"},"
            "{\"k\":\"textsrc\",\"t\":\"textsrc\"},"
            "{\"k\":\"text#7\",\"t\":\"text\",\"ti\":\"x\",\"tx\":\"y\"}]}");
        char *nk = fdmpc_new_text_card(&n6);
        if (!pc_chk(errbuf, errlen, 40, "新副本编号不能和存档里的撞",
                    nk && !pc_eq(nk, "text#7"))) {
            free(nk); fdmpc_free(&n6); fdmpc_free(&st); return 40;
        }
        free(nk);
        fdmpc_free(&n6);
    }

    /* 22. free 可重复调用 */
    fdmpc_free(&st);
    fdmpc_free(&st);
    if (!pc_chk(errbuf, errlen, 41, "free 两次不崩且状态归零",
                st.count == 0 && st.box_n == 0 && st.drawer_n == 0)) return 41;

    /* 23. 超长文本不越界 */
    {
        fdmpc_state big;
        fdmpc_init(&big);
        char *k = fdmpc_new_text_card(&big);
        char buf[4096];
        memset(buf, 'A', sizeof(buf) - 1);
        buf[sizeof(buf) - 1] = '\0';
        fdmpc_set_text(&big, k, buf);
        fdmpc_move_in(&big, k);
        char *s = fdmpc_compose(&big);
        if (!pc_chk(errbuf, errlen, 42, "超长文本应完整拼进去",
                    s && strstr(s, buf) != NULL)) {
            free(s); free(k); fdmpc_free(&big); return 42;
        }
        free(s);
        free(k);
        fdmpc_free(&big);
    }

    return 0;
}
