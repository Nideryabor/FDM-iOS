// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMBubbleStyle —— 对话气泡的「几何 + 配色」内核（纯 C11，零依赖）
//
// 把「算」和「画」彻底分开：
//   本文件只算 —— 给定容器尺寸、图片尺寸、缩放模式、锚点，
//   返回图片应该画在哪个矩形；给定圆角配置，返回四个角值。
//   谁来画（CALayer.contents / UIImageView / CAShapeLayer）不归它管。
//
// ═══════════════════════════════════════════════════════════════════════════
//  为什么这段必须单独测
//
//  「图片底 + 锚点」是最容易出错的一块：
//    · cover 模式下图片比容器大 => 要裁，锚点决定裁哪边
//    · contain 模式下图片比容器小 => 要留边，锚点决定靠哪边
//    · stretch 模式忽略比例，锚点没意义
//    · 容器尺寸为 0 / 图片尺寸为 0 / NaN => 必须给出安全值，不能返回 NaN
//  这些全是纯算术，在小窝里跑 30 条断言，
//  比在真机上「看着不对 -> 改 -> 再编 -> 再看」快 100 倍。
// ═══════════════════════════════════════════════════════════════════════════
#ifndef FDM_BUBBLE_STYLE_H
#define FDM_BUBBLE_STYLE_H

#ifdef __cplusplus
extern "C" {
#endif

/* 缩放模式（与设置页枚举顺序一致） */
typedef enum {
    FDMBubbleScaleCover   = 0,   /* 等比填满，超出裁掉（默认）*/
    FDMBubbleScaleContain = 1,   /* 等比装下，留边 */
    FDMBubbleScaleStretch = 2,   /* 拉伸铺满，忽略比例 */
    FDMBubbleScaleTile    = 3,   /* 平铺（不缩放）*/
} FDMBubbleScale;

/* 锚点（9 宫格） */
typedef enum {
    FDMBubbleAnchorCenter      = 0,
    FDMBubbleAnchorTop         = 1,
    FDMBubbleAnchorBottom      = 2,
    FDMBubbleAnchorLeft        = 3,
    FDMBubbleAnchorRight       = 4,
    FDMBubbleAnchorTopLeft     = 5,
    FDMBubbleAnchorTopRight    = 6,
    FDMBubbleAnchorBottomLeft  = 7,
    FDMBubbleAnchorBottomRight = 8,
} FDMBubbleAnchor;

/** 一个矩形（不依赖 CoreGraphics，才能在 Linux 上编译）*/
typedef struct {
    double x, y, w, h;
} fdmrect;

/** 气泡样式 */
typedef struct {
    /* 圆角：0 = 直角；>0 = 统一圆角；corner_individual=1 时用四个角 */
    double corner;
    int    corner_individual;
    double corner_tl, corner_tr, corner_bl, corner_br;

    /* 底色（AARRGGBB）。fill_enabled=0 表示不改（保留宿主原色）*/
    unsigned int fill_argb;
    int          fill_enabled;

    /* 内边距（正数 = 往内缩）*/
    double inset;

    /* 图片底 */
    int             image_enabled;
    FDMBubbleScale  scale;
    FDMBubbleAnchor anchor;
    double          image_alpha;     /* 0..1 */

    /* 圆角裁剪（图片底是否也按圆角裁）*/
    int clip_image;
} fdmbubble_style;

/** 样式默认值：全关、圆角 0、alpha 1。 */
void fdmbubble_style_default(fdmbubble_style *s);

/**
 * 计算图片在容器内的绘制矩形。
 *
 * @param image_w / image_h  图片像素尺寸（<=0 表示未知 => 退化成铺满容器）
 * @param view_w  / view_h   容器尺寸（<=0 => 返回全 0 矩形，调用方应跳过）
 * @param scale              缩放模式
 * @param anchor             锚点（Stretch / Tile 忽略）
 * @param inset              额外内缩（像素）
 * @return 应该画的位置（container 坐标系）
 */
fdmrect fdmbubble_image_rect(double image_w, double image_h,
                             double view_w, double view_h,
                             FDMBubbleScale scale, FDMBubbleAnchor anchor,
                             double inset);

/**
 * 校验并按需夹紧样式。
 * 任何越界/NaN 都会被拉回安全值，返回「有没有改动」（1 = 改过）。
 */
int fdmbubble_style_sanitize(fdmbubble_style *s);

/** 圆角描述（给日志/UI 显示用）。out 至少 64 字节。 */
void fdmbubble_corner_desc(const fdmbubble_style *s, char *out, int outlen);

/** 内置用例自检。@return 0 = 全通过；否则第一个失败用例号。 */
int fdmbubble_selftest(char *errbuf, int errlen);

#ifdef __cplusplus
}
#endif

#endif /* FDM_BUBBLE_STYLE_H */
