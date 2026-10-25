// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMBubbleStyle.c —— 见 FDMBubbleStyle.h
#include "FDMBubbleStyle.h"

#include <stdio.h>
#include <string.h>

/* ══════════════════════════════════════════════════════════════════════════
 *  小工具
 * ══════════════════════════════════════════════════════════════════════════ */

/* NaN / Inf 判定：不用 isnan()，避免 -ffast-math 下被优化掉 */
static int bad_num(double v) {
    if (v != v) return 1;                      /* NaN */
    if (v > 1e18 || v < -1e18) return 1;       /* Inf 附近 */
    return 0;
}

static double clampd(double v, double lo, double hi) {
    if (bad_num(v)) return lo;
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

void fdmbubble_style_default(fdmbubble_style *s) {
    if (!s) return;
    memset(s, 0, sizeof(*s));
    s->corner = 0.0;
    s->corner_individual = 0;
    s->fill_enabled = 0;
    s->image_enabled = 0;
    s->scale = FDMBubbleScaleCover;
    s->anchor = FDMBubbleAnchorCenter;
    s->image_alpha = 1.0;
    s->clip_image = 1;
}

/* ══════════════════════════════════════════════════════════════════════════
 *  锚点 -> 归一化偏移
 * ══════════════════════════════════════════════════════════════════════════ */

/**
 * 锚点 -> 归一化偏移（0 = 靠左/上，0.5 = 居中，1 = 靠右/下）。
 *
 * 这是唯一把「锚点」翻译成数字的地方 ——
 * cover 时它是「裁剪偏移」，contain 时它是「留边偏移」，语义自动统一：
 *   偏移 = (容器 - 图片) * n
 *   · cover: 容器-图片 是负数 => 偏移为负 => 图片往左/上移，右边/下边被裁
 *   · contain: 容器-图片 是正数 => 偏移为正 => 图片往右/下留边
 */
static void anchor_norm(FDMBubbleAnchor a, double *nx, double *ny) {
    switch (a) {
        case FDMBubbleAnchorTop:         *nx = 0.5; *ny = 0.0; break;
        case FDMBubbleAnchorBottom:      *nx = 0.5; *ny = 1.0; break;
        case FDMBubbleAnchorLeft:        *nx = 0.0; *ny = 0.5; break;
        case FDMBubbleAnchorRight:       *nx = 1.0; *ny = 0.5; break;
        case FDMBubbleAnchorTopLeft:     *nx = 0.0; *ny = 0.0; break;
        case FDMBubbleAnchorTopRight:    *nx = 1.0; *ny = 0.0; break;
        case FDMBubbleAnchorBottomLeft:  *nx = 0.0; *ny = 1.0; break;
        case FDMBubbleAnchorBottomRight: *nx = 1.0; *ny = 1.0; break;
        case FDMBubbleAnchorCenter:
        default:                         *nx = 0.5; *ny = 0.5; break;
    }
}

fdmrect fdmbubble_image_rect(double image_w, double image_h,
                             double view_w, double view_h,
                             FDMBubbleScale scale, FDMBubbleAnchor anchor,
                             double inset) {
    fdmrect r = {0, 0, 0, 0};

    /* 容器无效 => 什么都不画（调用方应跳过） */
    if (bad_num(view_w) || bad_num(view_h) || view_w <= 0 || view_h <= 0) return r;

    /* inset：把可用区往里缩。负值当 0；过大则夹到「至少留 1pt」*/
    double in = (bad_num(inset) || inset < 0) ? 0.0 : inset;
    double aw = view_w - in * 2.0;
    double ah = view_h - in * 2.0;
    if (aw < 1.0) aw = 1.0;
    if (ah < 1.0) ah = 1.0;
    double ox = (view_w - aw) * 0.5;
    double oy = (view_h - ah) * 0.5;

    /* 图片尺寸未知 => 铺满可用区（宁可铺满，也不要留个空洞）*/
    int unknown = (bad_num(image_w) || bad_num(image_h) || image_w <= 0 || image_h <= 0);
    if (unknown || scale == FDMBubbleScaleStretch) {
        r.x = ox; r.y = oy; r.w = aw; r.h = ah;
        return r;
    }

    if (scale == FDMBubbleScaleTile) {
        /* 平铺：不缩放，从可用区左上角开始 */
        r.x = ox; r.y = oy;
        r.w = image_w > aw ? aw : image_w;
        r.h = image_h > ah ? ah : image_h;
        return r;
    }

    double nx = 0.5, ny = 0.5;
    anchor_norm(anchor, &nx, &ny);

    if (scale == FDMBubbleScaleCover) {
        /* 等比填满：取较大的缩放比 => 图片 >= 容器，多出部分按锚点裁 */
        double sx = aw / image_w;
        double sy = ah / image_h;
        double s = sx > sy ? sx : sy;
        double dw = image_w * s;
        double dh = image_h * s;
        r.x = ox + (aw - dw) * nx;
        r.y = oy + (ah - dh) * ny;
        r.w = dw;
        r.h = dh;
        return r;
    }

    /* contain：取较小的缩放比 => 图片 <= 容器，留边按锚点分配 */
    double sx = aw / image_w;
    double sy = ah / image_h;
    double s = sx < sy ? sx : sy;
    double dw = image_w * s;
    double dh = image_h * s;
    r.x = ox + (aw - dw) * nx;
    r.y = oy + (ah - dh) * ny;
    r.w = dw;
    r.h = dh;
    return r;
}

/* ══════════════════════════════════════════════════════════════════════════
 *  校验
 * ══════════════════════════════════════════════════════════════════════════ */

int fdmbubble_style_sanitize(fdmbubble_style *s) {
    if (!s) return 0;
    int changed = 0;

    /* 圆角：只防负数 / NaN / 离谱大值（200 是远大于任何气泡半径的上界）*/
    double c = clampd(s->corner, 0.0, 200.0);
    if (c != s->corner) { s->corner = c; changed = 1; }

    double tl = clampd(s->corner_tl, 0.0, 200.0);
    double tr = clampd(s->corner_tr, 0.0, 200.0);
    double bl = clampd(s->corner_bl, 0.0, 200.0);
    double br = clampd(s->corner_br, 0.0, 200.0);
    if (tl != s->corner_tl || tr != s->corner_tr ||
        bl != s->corner_bl || br != s->corner_br) {
        s->corner_tl = tl; s->corner_tr = tr;
        s->corner_bl = bl; s->corner_br = br;
        changed = 1;
    }

    double in = clampd(s->inset, 0.0, 64.0);
    if (in != s->inset) { s->inset = in; changed = 1; }

    double al = clampd(s->image_alpha, 0.0, 1.0);
    if (al != s->image_alpha) { s->image_alpha = al; changed = 1; }

    if (s->scale < FDMBubbleScaleCover || s->scale > FDMBubbleScaleTile) {
        s->scale = FDMBubbleScaleCover;
        changed = 1;
    }
    if (s->anchor < FDMBubbleAnchorCenter || s->anchor > FDMBubbleAnchorBottomRight) {
        s->anchor = FDMBubbleAnchorCenter;
        changed = 1;
    }

    /* 布尔量规整成 0/1 */
    {
        int *bools[] = {&s->corner_individual, &s->fill_enabled,
                        &s->image_enabled, &s->clip_image};
        for (size_t i = 0; i < sizeof(bools) / sizeof(bools[0]); i++) {
            int v = *bools[i] ? 1 : 0;
            if (v != *bools[i]) { *bools[i] = v; changed = 1; }
        }
    }
    return changed;
}

void fdmbubble_corner_desc(const fdmbubble_style *s, char *out, int outlen) {
    if (!out || outlen <= 0) return;
    out[0] = '\0';
    if (!s) { snprintf(out, (size_t)outlen, "(null)"); return; }
    if (!s->corner_individual) {
        snprintf(out, (size_t)outlen, "r=%.1f", s->corner);
    } else {
        snprintf(out, (size_t)outlen, "r=%.1f/%.1f/%.1f/%.1f",
                 s->corner_tl, s->corner_tr, s->corner_bl, s->corner_br);
    }
}

/* ══════════════════════════════════════════════════════════════════════════
 *  自检
 * ══════════════════════════════════════════════════════════════════════════ */

static int rclose(fdmrect r, double x, double y, double w, double h) {
    const double t = 0.01;
    if (r.x - x > t || x - r.x > t) return 0;
    if (r.y - y > t || y - r.y > t) return 0;
    if (r.w - w > t || w - r.w > t) return 0;
    if (r.h - h > t || h - r.h > t) return 0;
    return 1;
}

#define CHK_RECT(no, r, X, Y, W, H)                                          \
    do {                                                                     \
        if (!rclose((r), (X), (Y), (W), (H))) {                              \
            snprintf(errbuf, (size_t)errlen,                                 \
                     "#%d got (%.2f,%.2f %.2fx%.2f) want (%.2f,%.2f %.2fx%.2f)", \
                     no, (r).x, (r).y, (r).w, (r).h,                         \
                     (double)(X), (double)(Y), (double)(W), (double)(H));    \
            return no;                                                       \
        }                                                                    \
    } while (0)

int fdmbubble_selftest(char *errbuf, int errlen) {
    char local[512];
    int no = 0;   /* CHK_RECT 宏会写它；末尾的 (void) 防止 -Wunused */
    if (!errbuf) { errbuf = local; errlen = (int)sizeof(local); }
    errbuf[0] = '\0';
    fdmrect r;

    /* 1. 容器 0 => 全 0 */
    no = 1;
    r = fdmbubble_image_rect(100, 100, 0, 100, FDMBubbleScaleCover, FDMBubbleAnchorCenter, 0);
    if (r.w != 0 || r.h != 0) {
        snprintf(errbuf, (size_t)errlen, "#1 容器宽 0 应返回全 0，得到 %.2fx%.2f", r.w, r.h);
        return 1;
    }

    /* 2. 图片尺寸未知 => 铺满容器 */
    no = 2;
    r = fdmbubble_image_rect(0, 0, 300, 200, FDMBubbleScaleCover, FDMBubbleAnchorCenter, 0);
    CHK_RECT(2, r, 0, 0, 300, 200);

    /* 3. Stretch => 忽略比例与锚点 */
    no = 3;
    r = fdmbubble_image_rect(1000, 10, 300, 200, FDMBubbleScaleStretch,
                             FDMBubbleAnchorTopLeft, 0);
    CHK_RECT(3, r, 0, 0, 300, 200);

    /* 4. Cover + 居中：正方图进 300x200 => 300x300，上下各裁 50 => y=-50 */
    no = 4;
    r = fdmbubble_image_rect(100, 100, 300, 200, FDMBubbleScaleCover,
                             FDMBubbleAnchorCenter, 0);
    CHK_RECT(4, r, 0, -50, 300, 300);

    /* 5. Cover + 顶部对齐：图从 y=0 开始 */
    no = 5;
    r = fdmbubble_image_rect(100, 100, 300, 200, FDMBubbleScaleCover,
                             FDMBubbleAnchorTop, 0);
    CHK_RECT(5, r, 0, 0, 300, 300);

    /* 6. Cover + 底部对齐：图底贴容器底 => y = 200-300 = -100 */
    no = 6;
    r = fdmbubble_image_rect(100, 100, 300, 200, FDMBubbleScaleCover,
                             FDMBubbleAnchorBottom, 0);
    CHK_RECT(6, r, 0, -100, 300, 300);

    /* 7. Cover + 左对齐：宽图进窄容器，横向也超 */
    no = 7;
    r = fdmbubble_image_rect(400, 100, 200, 200, FDMBubbleScaleCover,
                             FDMBubbleAnchorLeft, 0);
    /* s = max(200/400, 200/100) = 2 => 800x200，左对齐 x=0 */
    CHK_RECT(7, r, 0, 0, 800, 200);

    /* 8. Cover + 右对齐：x = 200-800 = -600 */
    no = 8;
    r = fdmbubble_image_rect(400, 100, 200, 200, FDMBubbleScaleCover,
                             FDMBubbleAnchorRight, 0);
    CHK_RECT(8, r, -600, 0, 800, 200);

    /* 9. Contain + 居中：正方图进 300x200 => 200x200，左右各留 50 */
    no = 9;
    r = fdmbubble_image_rect(100, 100, 300, 200, FDMBubbleScaleContain,
                             FDMBubbleAnchorCenter, 0);
    CHK_RECT(9, r, 50, 0, 200, 200);

    /* 10. Contain + 左对齐 */
    no = 10;
    r = fdmbubble_image_rect(100, 100, 300, 200, FDMBubbleScaleContain,
                             FDMBubbleAnchorLeft, 0);
    CHK_RECT(10, r, 0, 0, 200, 200);

    /* 11. Contain + 右下 */
    no = 11;
    r = fdmbubble_image_rect(100, 100, 300, 200, FDMBubbleScaleContain,
                             FDMBubbleAnchorBottomRight, 0);
    CHK_RECT(11, r, 100, 0, 200, 200);

    /* 12. Tile：大图裁到容器 */
    no = 12;
    r = fdmbubble_image_rect(1000, 1000, 300, 200, FDMBubbleScaleTile,
                             FDMBubbleAnchorCenter, 0);
    CHK_RECT(12, r, 0, 0, 300, 200);

    /* 13. Tile：小图保持原尺寸 */
    no = 13;
    r = fdmbubble_image_rect(50, 40, 300, 200, FDMBubbleScaleTile,
                             FDMBubbleAnchorCenter, 0);
    CHK_RECT(13, r, 0, 0, 50, 40);

    /* 14. inset 生效：300x200 inset 10 => 280x180 居中 */
    no = 14;
    r = fdmbubble_image_rect(0, 0, 300, 200, FDMBubbleScaleStretch,
                             FDMBubbleAnchorCenter, 10);
    CHK_RECT(14, r, 10, 10, 280, 180);

    /* 15. inset 过大 => 至少留 1pt */
    no = 15;
    r = fdmbubble_image_rect(0, 0, 300, 200, FDMBubbleScaleStretch,
                             FDMBubbleAnchorCenter, 1000);
    if (r.w < 1.0 || r.h < 1.0) {
        snprintf(errbuf, (size_t)errlen, "#15 inset 过大应至少留 1pt，得到 %.2fx%.2f", r.w, r.h);
        return 15;
    }

    /* 16. inset 负数当 0 */
    no = 16;
    r = fdmbubble_image_rect(0, 0, 300, 200, FDMBubbleScaleStretch,
                             FDMBubbleAnchorCenter, -50);
    CHK_RECT(16, r, 0, 0, 300, 200);

    /* 17. NaN 图片尺寸不产生 NaN 矩形 */
    no = 17;
    r = fdmbubble_image_rect(0.0 / 0.0, 100, 300, 200, FDMBubbleScaleCover,
                             FDMBubbleAnchorCenter, 0);
    if (bad_num(r.x) || bad_num(r.y) || bad_num(r.w) || bad_num(r.h)) {
        snprintf(errbuf, (size_t)errlen, "#17 NaN 图片尺寸产生了 NaN 矩形");
        return 17;
    }

    /* 18. NaN 容器 => 全 0 */
    no = 18;
    r = fdmbubble_image_rect(100, 100, 0.0 / 0.0, 200, FDMBubbleScaleCover,
                             FDMBubbleAnchorCenter, 0);
    if (r.x != 0 || r.y != 0 || r.w != 0 || r.h != 0) {
        snprintf(errbuf, (size_t)errlen, "#18 NaN 容器应返回全 0");
        return 18;
    }

    /* 19. 所有锚点 x Cover：必须盖住整个容器（无露白）*/
    no = 19;
    {
        int a;
        for (a = FDMBubbleAnchorCenter; a <= FDMBubbleAnchorBottomRight; a++) {
            r = fdmbubble_image_rect(100, 100, 300, 200, FDMBubbleScaleCover,
                                     (FDMBubbleAnchor)a, 0);
            if (r.x > 0.01 || r.y > 0.01 ||
                r.x + r.w < 299.99 || r.y + r.h < 199.99) {
                snprintf(errbuf, (size_t)errlen,
                         "#19 anchor=%d cover 后没盖住容器 (%.2f,%.2f %.2fx%.2f)",
                         a, r.x, r.y, r.w, r.h);
                return 19;
            }
        }
    }

    /* 20. 所有锚点 x Contain：必须完整落在容器内 */
    no = 20;
    {
        int a;
        for (a = FDMBubbleAnchorCenter; a <= FDMBubbleAnchorBottomRight; a++) {
            r = fdmbubble_image_rect(100, 100, 300, 200, FDMBubbleScaleContain,
                                     (FDMBubbleAnchor)a, 0);
            if (r.x < -0.01 || r.y < -0.01 ||
                r.x + r.w > 300.01 || r.y + r.h > 200.01) {
                snprintf(errbuf, (size_t)errlen,
                         "#20 anchor=%d contain 后跑出容器 (%.2f,%.2f %.2fx%.2f)",
                         a, r.x, r.y, r.w, r.h);
                return 20;
            }
        }
    }

    /* 21. 默认样式 */
    no = 21;
    {
        fdmbubble_style st;
        fdmbubble_style_default(&st);
        if (st.image_enabled || st.fill_enabled || st.corner != 0.0 ||
            st.image_alpha != 1.0 || st.clip_image != 1) {
            snprintf(errbuf, (size_t)errlen, "#21 默认样式不对");
            return 21;
        }
    }

    /* 22. sanitize：负圆角被夹到 0 */
    no = 22;
    {
        fdmbubble_style st;
        int ch;
        fdmbubble_style_default(&st);
        st.corner = -20;
        ch = fdmbubble_style_sanitize(&st);
        if (ch != 1 || st.corner != 0.0) {
            snprintf(errbuf, (size_t)errlen, "#22 负圆角应被夹到 0（ch=%d corner=%.1f）",
                     ch, st.corner);
            return 22;
        }
    }

    /* 23. sanitize：alpha 越界被夹 */
    no = 23;
    {
        fdmbubble_style st;
        fdmbubble_style_default(&st);
        st.image_alpha = 3.5;
        fdmbubble_style_sanitize(&st);
        if (st.image_alpha > 1.0) {
            snprintf(errbuf, (size_t)errlen, "#23 alpha 应被夹到 1，得到 %.2f", st.image_alpha);
            return 23;
        }
        st.image_alpha = -1;
        fdmbubble_style_sanitize(&st);
        if (st.image_alpha < 0.0) {
            snprintf(errbuf, (size_t)errlen, "#23 alpha 应被夹到 0");
            return 23;
        }
    }

    /* 24. sanitize：非法枚举回默认 */
    no = 24;
    {
        fdmbubble_style st;
        fdmbubble_style_default(&st);
        st.scale = (FDMBubbleScale)99;
        st.anchor = (FDMBubbleAnchor)-7;
        fdmbubble_style_sanitize(&st);
        if (st.scale != FDMBubbleScaleCover || st.anchor != FDMBubbleAnchorCenter) {
            snprintf(errbuf, (size_t)errlen, "#24 非法枚举应回默认（scale=%d anchor=%d）",
                     (int)st.scale, (int)st.anchor);
            return 24;
        }
    }

    /* 25. sanitize：干净输入返回 0 */
    no = 25;
    {
        fdmbubble_style st;
        fdmbubble_style_default(&st);
        st.corner = 12; st.inset = 4; st.image_alpha = 0.8;
        if (fdmbubble_style_sanitize(&st) != 0) {
            snprintf(errbuf, (size_t)errlen, "#25 干净的样式不该被改动");
            return 25;
        }
    }

    /* 26. sanitize(NULL) 不崩 */
    no = 26;
    if (fdmbubble_style_sanitize(NULL) != 0) {
        snprintf(errbuf, (size_t)errlen, "#26 sanitize(NULL) 应返回 0");
        return 26;
    }

    /* 27. corner_desc */
    no = 27;
    {
        char desc[64];
        fdmbubble_style st;
        fdmbubble_style_default(&st);
        st.corner = 14;
        fdmbubble_corner_desc(&st, desc, sizeof(desc));
        if (strncmp(desc, "r=14.0", 6) != 0) {
            snprintf(errbuf, (size_t)errlen, "#27 corner_desc 得到「%s」", desc);
            return 27;
        }
        st.corner_individual = 1;
        st.corner_tl = 20; st.corner_tr = 4; st.corner_bl = 20; st.corner_br = 4;
        fdmbubble_corner_desc(&st, desc, sizeof(desc));
        if (strncmp(desc, "r=20.0/4.0/20.0/4.0", 19) != 0) {
            snprintf(errbuf, (size_t)errlen, "#27 四角描述得到「%s」", desc);
            return 27;
        }
    }

    /* 28. corner_desc(NULL) 不崩 */
    no = 28;
    {
        char desc[64];
        fdmbubble_corner_desc(NULL, desc, sizeof(desc));
        if (desc[0] == '\0') {
            snprintf(errbuf, (size_t)errlen, "#28 NULL 样式也该写出点什么");
            return 28;
        }
    }

    /* 29. 极端比例 contain */
    no = 29;
    r = fdmbubble_image_rect(1, 1000, 300, 200, FDMBubbleScaleContain,
                             FDMBubbleAnchorCenter, 0);
    if (r.w <= 0 || r.h <= 0 || r.h > 200.01) {
        snprintf(errbuf, (size_t)errlen, "#29 极端比例 contain 异常 (%.2fx%.2f)", r.w, r.h);
        return 29;
    }

    /* 30. 极端比例 cover：必须盖满 */
    no = 30;
    (void)no;
    r = fdmbubble_image_rect(1, 1000, 300, 200, FDMBubbleScaleCover,
                             FDMBubbleAnchorCenter, 0);
    if (r.x > 0.01 || r.y > 0.01 || r.x + r.w < 299.99 || r.y + r.h < 199.99) {
        snprintf(errbuf, (size_t)errlen, "#30 极端比例 cover 没盖满");
        return 30;
    }

    return 0;
}
