// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMNote.m —— 悬浮便签（贴在宿主窗口上，零权限）
//
// 对标安卓 GmNote + GmNoteView（975 行），但 iOS 侧走更短的路：
//   · 安卓要 hook Activity.onResume 拿 decorView；
//     iOS 只需要找一个 keyWindow，往上面 addSubview。
//   · 安卓要自己画 GradientDrawable 当圆角底；
//     iOS 直接 layer.cornerRadius + UIVisualEffectView。
//   · 数据模型已经抽成纯 C（FDMNoteModel.c，25 条断言），这里只管画和拖。
//
// ═══════════════════════════════════════════════════════════════════════════
//  ★ 为什么这个功能最适合在没有真机时先做
//
//  它是**完全自己控制**的一坨视图：不 hook 宿主任何方法，
//  不依赖宿主类名，不动宿主的视图树（只往 window 最上层加一层）。
//  所以「能不能显示」是可推理的，不需要 dump 真机。
//
//  ★ 三条铁律
//   1. 绝不 hook 宿主方法（避免污染；唯一接触点是每 1.5s 巡一次 keyWindow）
//   2. 所有 touch 都自己处理（UIPanGestureRecognizer / UITapGestureRecognizer），
//      不抢宿主的手势（我们的视图在最上层，只在自己范围内响应）
//   3. 宿主切页/旋转时重新夹紧（用通知 + layoutSubviews 双保险）
// ═══════════════════════════════════════════════════════════════════════════
#import "FDMNote.h"
#import "FLog.h"
#import "FDMConfig.h"

#include <stdlib.h>
#include <string.h>

#import "FDMNoteModel.h"

/* ══════════════════════════════════ 常量 ══════════════════════════════════ */

static const CGFloat kCardW      = 250.0;
static const CGFloat kCardMinH   = 92.0;
static const CGFloat kBarH       = 34.0;
static const CGFloat kBubbleD    = 52.0;
static const CGFloat kPad        = 12.0;
static const CGFloat kCorner     = 14.0;
static const CGFloat kMinCardW   = 160.0;
static const CGFloat kMinCardH   = 92.0;

static NSString *const kNoteFile = @"fdm-note.json";

/* ══════════════════════════════════ 静态状态 ══════════════════════════════════ */

static fdmnote_state gState;
static BOOL gStateReady = NO;

static FDMNoteView *gView = nil;
static BOOL gInstalled = NO;
static BOOL gSessionClosed = NO;      /* 本会话点了 ✕ ⇒ 不再出现 */
static NSTimer *gScanTimer = nil;

/* 配置（从 FDMConfig 读，reload 时刷新）*/
static BOOL  gOn = NO;
static float gAlpha = 0.92f;
static UIColor *gBG = nil;
static CGFloat gFontSize = 15.0;

/* ══════════════════════════════════ 存档 ══════════════════════════════════ */

static NSString *NotePath(void) {
    @try {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                             NSUserDomainMask, YES).firstObject;
        if (!docs.length) return nil;
        return [docs stringByAppendingPathComponent:kNoteFile];
    } @catch (NSException *e) {
        return nil;
    }
}

static void NoteLoad(void) {
    if (gStateReady) return;
    gStateReady = YES;
    NSString *p = NotePath();
    if (!p) { fdmnote_init(&gState); return; }
    @try {
        NSString *txt = [NSString stringWithContentsOfFile:p
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
        fdmnote_parse(txt.UTF8String, &gState);   /* 内部对 NULL/垃圾都兜底 */
    } @catch (NSException *e) {
        fdmnote_init(&gState);
    }
    FLOGI(FC_UI, @"[note] 读到 %zu 张便签 idx=%d min=%d",
          gState.count, gState.idx, gState.minimized);
}

static void NoteSave(void) {
    if (!gStateReady) return;
    NSString *p = NotePath();
    if (!p) return;
    char *js = fdmnote_serialize(&gState);
    if (!js) return;
    @try {
        NSString *s = [NSString stringWithUTF8String:js];
        if (s) [s writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (NSException *e) {
    }
    free(js);
}

/* ══════════════════════════════════ 读配置 ══════════════════════════════════ */

extern id FDMProbeReadDebugBool(NSString *k, BOOL d);

static void NoteReloadConfig(void) {
    @try {
        FDMConfig *c = [FDMConfig shared];

        /* 总开关 + 组开关：任一关着就不显示 */
        gOn = [c boolFor:@"note" key:@"on"] && [c enabledFor:@"note"];

        NSInteger a = [c intFor:@"note" key:@"alpha"];
        if (a <= 0) a = 92;
        gAlpha = (float)a / 100.0f;
        if (gAlpha < 0.2f) gAlpha = 0.2f;
        if (gAlpha > 1.0f) gAlpha = 1.0f;

        NSInteger sz = [c intFor:@"note" key:@"size"];
        gFontSize = sz > 0 ? (CGFloat)sz : 15.0;
        if (gFontSize < 10) gFontSize = 10;
        if (gFontSize > 28) gFontSize = 28;

        NSString *hex = [c stringFor:@"note" key:@"bg"];
        gBG = FDMRGBAColor(hex.length ? hex : nil, 0xFFFFF3B0);   /* 便签黄 */

        FLOGI(FC_UI, @"[note] 配置 on=%d（组开关=%d）alpha=%.2f size=%.0f bg=%@",
              gOn, [c enabledFor:@"note"], gAlpha, gFontSize, hex ?: @"(默认)");
    } @catch (NSException *e) {
        gOn = NO;
        FLOGE(FC_UI, @"[note] 读配置异常: %@", e.reason);
    }
}

/* ══════════════════════════════════ 颜色工具 ══════════════════════════════════ */

UIColor *FDMRGBAColor(NSString *hex, unsigned int fallback) {
    unsigned int v = fallback;
    if (hex.length) {
        @try {
            NSString *s = [hex stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
            if ([s hasPrefix:@"0x"] || [s hasPrefix:@"0X"]) s = [s substringFromIndex:2];
            unsigned int parsed = 0;
            if (s.length == 6) {
                NSScanner *sc = [NSScanner scannerWithString:s];
                if ([sc scanHexInt:&parsed]) v = 0xFF000000u | parsed;
            } else if (s.length == 8) {
                NSScanner *sc = [NSScanner scannerWithString:s];
                if ([sc scanHexInt:&parsed]) v = parsed;
            }
        } @catch (NSException *e) { }
    }
    return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                           green:((v >> 8) & 0xFF) / 255.0
                            blue:(v & 0xFF) / 255.0
                           alpha:((v >> 24) & 0xFF) / 255.0];
}

/* ══════════════════════════════════ 视图 ══════════════════════════════════ */

@interface FDMNoteView () {
    UIView   *_card;
    UILabel  *_bar;         /* ≡ 拖动把手 */
    UILabel  *_counter;     /* 1/3 */
    UILabel  *_text;        /* 正文（点一下进编辑）*/
    UITextView *_editor;    /* 编辑态 */
    UIButton *_add, *_prev, *_next, *_del, *_min, *_close;
    UIView   *_ball;        /* 最小化后的圆球 */
    UILabel  *_ballLabel;
    UIView   *_grip;        /* 右下角缩放手柄 */

    BOOL _editing;
    CGPoint _dragStart;
    CGRect  _dragStartFrame;
    BOOL    _dragging;
}
@end

@implementation FDMNoteView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.autoresizingMask = UIViewAutoresizingNone;
    [self buildUI];
    [self refreshAll];
    return self;
}

- (void)buildUI {
    /* ── 卡片 ── */
    _card = [[UIView alloc] initWithFrame:self.bounds];
    _card.layer.cornerRadius = kCorner;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.clipsToBounds = YES;
    _card.userInteractionEnabled = YES;
    [self addSubview:_card];

    /* ── 顶栏（只有 ≡ 是拖动把手 —— 与安卓同一取舍：整条能拖会让按钮失灵）── */
    _bar = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, kCardW, kBarH)];
    _bar.text = @"\u2261";
    _bar.textAlignment = NSTextAlignmentLeft;
    _bar.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    _bar.userInteractionEnabled = YES;
    _bar.textColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    [_card addSubview:_bar];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(onPan:)];
    [_bar addGestureRecognizer:pan];

    /* ── 按钮（纯几何符号，不用 emoji —— 各机型肥瘦不一）── */
    CGFloat bx = kCardW - 6.0;
    _close = [self mkBtn:@"\u2715" x:&bx action:@selector(onClose)];
    _min   = [self mkBtn:@"\u25A3" x:&bx action:@selector(onMin)];
    _del   = [self mkBtn:@"\uFF0D" x:&bx action:@selector(onDel)];
    _next  = [self mkBtn:@"\u203A" x:&bx action:@selector(onNext)];
    _prev  = [self mkBtn:@"\u2039" x:&bx action:@selector(onPrev)];
    _add   = [self mkBtn:@"\uFF0B" x:&bx action:@selector(onAdd)];

    _counter = [[UILabel alloc] initWithFrame:CGRectMake(bx - 40, 0, 40, kBarH)];
    _counter.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    _counter.textColor = [UIColor colorWithWhite:0.35 alpha:1.0];
    _counter.textAlignment = NSTextAlignmentCenter;
    [_card addSubview:_counter];

    /* ── 正文 ── */
    _text = [[UILabel alloc] initWithFrame:CGRectMake(kPad, kBarH,
                                                      kCardW - kPad * 2,
                                                      kCardMinH - kBarH - kPad)];
    _text.numberOfLines = 0;
    _text.userInteractionEnabled = YES;
    _text.textColor = [UIColor colorWithWhite:0.11 alpha:1.0];
    [_card addSubview:_text];
    [_text addGestureRecognizer:[[UITapGestureRecognizer alloc]
                                 initWithTarget:self action:@selector(beginEdit)]];

    /* ── 编辑态 ── */
    _editor = [[UITextView alloc] initWithFrame:_text.frame];
    _editor.backgroundColor = [UIColor clearColor];
    _editor.textColor = [UIColor colorWithWhite:0.11 alpha:1.0];
    _editor.layer.borderWidth = 1.0;
    _editor.layer.borderColor = [UIColor colorWithWhite:0.0 alpha:0.18].CGColor;
    _editor.layer.cornerRadius = 8;
    _editor.hidden = YES;
    _editor.delegate = (id<UITextViewDelegate>)self;
    [_card addSubview:_editor];

    /* ── 右下角缩放手柄（24x24 的斜纹区）── */
    _grip = [[UIView alloc] initWithFrame:CGRectMake(kCardW - 24, kCardMinH - 24, 24, 24)];
    _grip.backgroundColor = [UIColor clearColor];
    _grip.userInteractionEnabled = YES;
    CAGradientLayer *gs = [CAGradientLayer layer];
    gs.frame = CGRectMake(8, 8, 13, 13);
    gs.startPoint = CGPointMake(0, 0);
    gs.endPoint = CGPointMake(1, 1);
    gs.colors = @[(id)[UIColor colorWithWhite:0.0 alpha:0.30].CGColor,
                  (id)[UIColor colorWithWhite:0.0 alpha:0.05].CGColor];
    gs.locations = @[@0.0, @1.0];
    [_grip.layer addSublayer:gs];
    [_grip addGestureRecognizer:[[UIPanGestureRecognizer alloc]
                                 initWithTarget:self action:@selector(onResize:)]];
    [_card addSubview:_grip];

    /* ── 最小化后的圆球 ── */
    _ball = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kBubbleD, kBubbleD)];
    _ball.layer.cornerRadius = kBubbleD / 2.0;
    _ball.hidden = YES;
    _ball.userInteractionEnabled = YES;
    [self addSubview:_ball];

    _ballLabel = [[UILabel alloc] initWithFrame:_ball.bounds];
    _ballLabel.text = @"\u2261";
    _ballLabel.textAlignment = NSTextAlignmentCenter;
    _ballLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
    [_ball addSubview:_ballLabel];

    [_ball addGestureRecognizer:[[UITapGestureRecognizer alloc]
                                 initWithTarget:self action:@selector(onUnmin)]];
    [_ball addGestureRecognizer:[[UIPanGestureRecognizer alloc]
                                 initWithTarget:self action:@selector(onBallPan:)]];
}

/** 造一个按钮：从右往左排。bx 是「下一个按钮的右边缘」。 */
- (UIButton *)mkBtn:(NSString *)t x:(CGFloat *)bx action:(SEL)sel {
    const CGFloat w = 30.0;
    *bx -= w;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(*bx, 0, w, kBarH);
    [b setTitle:t forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [b setTitleColor:[UIColor colorWithWhite:0.25 alpha:1.0] forState:UIControlStateNormal];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:b];
    return b;
}

/* ══════════════════════════════════ 渲染 ══════════════════════════════════ */

- (void)applyLook {
    gBG = gBG ?: [UIColor colorWithRed:1.0 green:0.95 blue:0.69 alpha:1.0];
    UIColor *bg = [gBG colorWithAlphaComponent:gAlpha];
    _card.backgroundColor = bg;

    /* 最小化圆球用同一个色，但更实一点（不然看不清）*/
    _ball.backgroundColor = [gBG colorWithAlphaComponent:MIN(1.0f, gAlpha + 0.06f)];
    _ball.layer.shadowColor = [UIColor blackColor].CGColor;
    _ball.layer.shadowOpacity = 0.18f;
    _ball.layer.shadowRadius = 6.0f;
    _ball.layer.shadowOffset = CGSizeMake(0, 2);
    _ballLabel.textColor = [UIColor colorWithWhite:0.15 alpha:1.0];

    /* 卡片描边：便签纸的感觉 */
    _card.layer.borderWidth = 0.5;
    _card.layer.borderColor = [UIColor colorWithWhite:0.0 alpha:0.10].CGColor;

    _text.font = [UIFont systemFontOfSize:gFontSize];
    _editor.font = [UIFont systemFontOfSize:gFontSize];
}

- (void)refreshAll {
    [self applyLook];

    fdmnote_item *it = fdmnote_current(&gState);
    NSString *txt = it && it->text ? @(it->text) : @"";
    _text.text = txt;
    if (_editing && ![_editor.text isEqualToString:txt]) _editor.text = txt;

    _counter.text = [NSString stringWithFormat:@"%d/%zu",
                     gState.idx + 1, gState.count];

    const BOOL multi = (gState.count > 1);
    _prev.enabled = multi;
    _next.enabled = multi;
    _prev.alpha = multi ? 1.0 : 0.35;
    _next.alpha = multi ? 1.0 : 0.35;

    [self relayout];
}

/* ══════════════════════════════════════════════════════════════════════════
 *  ★★ 2026-10-23 真机三个 bug 的修复点，全在 relayout
 *
 *  病根：原来 `self.frame` 既当容器又当卡片尺寸，两个形态互相污染 ——
 *   ① 「摘下一张后位置跳」：applyMinimized 用 self.frame.height 当高度，
 *      但那时 frame 还是上一张的高度
 *   ② 「圆球展开回不来」：球是 52x52，展开时 h 直接继承 52 ⇒ 卡片成了扁条
 *   ③ 没有缩放能力：窄卡片没有手柄
 *
 *  ⇒ 现在：**位置只认存档里的 x/y，尺寸只认存档里的 w/h（0 = 默认）**，
 *     self.frame 永远是「当前形态的真实尺寸」，不再被上一态污染。
 * ══════════════════════════════════════════════════════════════════════════ */
- (void)relayout {
    fdmnote_item *it = fdmnote_current(&gState);
    const BOOL mini = gState.minimized ? YES : NO;

    _card.hidden = mini;
    _ball.hidden = !mini;
    _grip.hidden = mini;

    if (mini) {
        /* 圆球：尺寸固定，位置沿用存档坐标（不偏移、不继承卡片尺寸）*/
        CGFloat d = kBubbleD;
        self.frame = CGRectMake((CGFloat)it->x, (CGFloat)it->y, d, d);
        _ball.frame = CGRectMake(0, 0, d, d);
        _ball.layer.cornerRadius = d / 2.0;
        return;
    }

    /* 卡片：宽度优先用用户拖出来的，否则默认宽 */
    CGFloat w = it->w > 1 ? (CGFloat)it->w : kCardW;
    if (w < kMinCardW) w = kMinCardW;

    /* 高度：
     *   · 先按内容算一个「刚好装下文字」的高度 autoH
     *   · 用户拖过就用用户的，但**不能小于 autoH**（否则文字被裁）
     *   · 没拖过就用 autoH
     *
     * ★ 真机反馈（2026-10-23）：新建的便签比上一张矮 ——
     *   因为新便签文字只有一行，autoH 自然更小。
     *   现在「新建时继承上一张的实际高度」，配合这里的 MAX 保证不裁字。 */
    CGFloat textW = w - kPad * 2;
    if (textW < 40) textW = 40;
    CGFloat textH = [_text sizeThatFits:CGSizeMake(textW, CGFLOAT_MAX)].height;
    CGFloat autoH = kBarH + textH + kPad;

    CGFloat h;
    if (it->h > 1) {
        h = (CGFloat)it->h;
        if (h < autoH) h = autoH;      /* 绝不裁字 */
    } else {
        h = autoH;
    }
    if (h < kMinCardH) h = kMinCardH;

    self.frame = CGRectMake((CGFloat)it->x, (CGFloat)it->y, w, h);
    _card.frame = CGRectMake(0, 0, w, h);

    /* 正文区（给手柄留出右下角）*/
    _text.frame = CGRectMake(kPad, kBarH, w - kPad * 2, h - kBarH - kPad);
    _editor.frame = _text.frame;
    _grip.frame = CGRectMake(w - 24, h - 24, 24, 24);
}

/* ══════════════════════════════════ 拖动 ══════════════════════════════════ */

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *host = self.superview;
    if (!host) return;

    CGPoint t = [g translationInView:host];
    switch (g.state) {
        case UIGestureRecognizerStateBegan:
            _dragStartFrame = self.frame;
            _dragging = NO;
            break;
        case UIGestureRecognizerStateChanged: {
            CGRect f = _dragStartFrame;
            f.origin.x += t.x;
            f.origin.y += t.y;
            self.frame = f;
            _dragging = YES;
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            [g setTranslation:CGPointZero inView:host];
            [self clampAndPersist];
            break;
        }
        default:
            break;
    }
}

- (void)onBallPan:(UIPanGestureRecognizer *)g {
    UIView *host = self.superview;
    if (!host) return;
    CGPoint t = [g translationInView:host];
    if (g.state == UIGestureRecognizerStateChanged) {
        CGRect f = self.frame;
        f.origin.x += t.x;
        f.origin.y += t.y;
        self.frame = f;
        [g setTranslation:CGPointZero inView:host];
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled) {
        [self clampAndPersist];
    }
}

- (void)clampAndPersist {
    UIView *host = self.superview;
    if (!host) return;
    CGRect f = self.frame;
    double x = f.origin.x, y = f.origin.y;
    fdmnote_clamp(&x, &y, f.size.width, f.size.height,
                  host.bounds.size.width, host.bounds.size.height);
    f.origin.x = (CGFloat)x;
    f.origin.y = (CGFloat)y;
    self.frame = f;

    fdmnote_set_pos(&gState, x, y);
    NoteSave();
}

/* 右下角拖动 = 缩放（不移动位置）*/
- (void)onResize:(UIPanGestureRecognizer *)g {
    UIView *host = self.superview;
    if (!host) return;

    if (g.state == UIGestureRecognizerStateBegan) {
        _dragStartFrame = self.frame;
        return;
    }
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:host];
        CGFloat w = _dragStartFrame.size.width + t.x;
        CGFloat h = _dragStartFrame.size.height + t.y;
        if (w < kMinCardW) w = kMinCardW;
        if (h < kMinCardH) h = kMinCardH;
        /* 不超过窗口 */
        if (w > host.bounds.size.width - 8) w = host.bounds.size.width - 8;
        if (h > host.bounds.size.height - 8) h = host.bounds.size.height - 8;

        self.frame = CGRectMake(_dragStartFrame.origin.x, _dragStartFrame.origin.y, w, h);
        _card.frame = CGRectMake(0, 0, w, h);
        _text.frame = CGRectMake(kPad, kBarH, w - kPad * 2, h - kBarH - kPad);
        _editor.frame = _text.frame;
        _grip.frame = CGRectMake(w - 24, h - 24, 24, 24);
        return;
    }
    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) {
        CGRect f = self.frame;
        fdmnote_set_size(&gState, f.size.width, f.size.height);
        NoteSave();
        FLOGI(FC_UI, @"[note] 尺寸改为 %.0fx%.0f", f.size.width, f.size.height);
    }
}

/** 宿主尺寸变了（旋转 / 键盘）重新夹紧。 */
- (void)layoutSubviews {
    [super layoutSubviews];
    UIView *host = self.superview;
    if (!host) return;
    CGRect f = self.frame;
    double x = f.origin.x, y = f.origin.y;
    fdmnote_clamp(&x, &y, f.size.width, f.size.height,
                  host.bounds.size.width, host.bounds.size.height);
    if (fabs(f.origin.x - x) > 0.5 || fabs(f.origin.y - y) > 0.5) {
        f.origin.x = (CGFloat)x;
        f.origin.y = (CGFloat)y;
        self.frame = f;
        /* 夹紧后同步回存档，否则下次 relayout 又跳回去 */
        fdmnote_set_pos(&gState, x, y);
    }
}

/* ══════════════════════════════════ 按钮动作 ══════════════════════════════════ */

- (void)onAdd {
    [self commitEdit];
    fdmnote_item *cur = fdmnote_current(&gState);

    /* ★★ 2026-10-23 真机反馈：新便签「位置和大小跟上一张不一样」。
     *   原来是 x+16 / y+16 偏移 + w/h 置 0（回默认宽）——
     *   结果位置错开、尺寸也可能变。
     *   ⇒ 现在**完全复制**当前这张的坐标和尺寸，视觉上严丝合缝。
     *   （翻页靠 ‹ ›，不靠位置错开） */
    double nx = cur->x;
    double ny = cur->y;

    /* ★ 用**当前实际渲染尺寸**（不是存档里的 w/h）——
     *   存档里 w/h 可能是 0（自动），直接复制过去会让新便签重新按内容算 ⇒ 又不一样。 */
    CGRect curFrame = self.frame;
    double nw = curFrame.size.width;
    double nh = curFrame.size.height;

    int idx = fdmnote_add(&gState, NULL, nx, ny);
    if (idx < 0) return;
    fdmnote_set_size(&gState, nw, nh);

    FLOGI(FC_UI, @"[note] 新增第 %d 张（共 %zu）位置(%.0f,%.0f) 尺寸(%.0fx%.0f)",
          idx + 1, gState.count, nx, ny, nw, nh);
    [self refreshAll];
    NoteSave();
    [self beginEdit];
}

- (void)onDel {
    [self commitEdit];
    fdmnote_delete_current(&gState);
    FLOGI(FC_UI, @"[note] 删除后剩 %zu 张", gState.count);
    [self refreshAll];
    NoteSave();
}

- (void)onPrev { [self commitEdit]; fdmnote_step(&gState, -1); [self refreshAll]; NoteSave(); }
- (void)onNext { [self commitEdit]; fdmnote_step(&gState, 1);  [self refreshAll]; NoteSave(); }

- (void)onMin {
    [self commitEdit];
    gState.minimized = 1;
    [self refreshAll];
    NoteSave();
}

- (void)onUnmin {
    gState.minimized = 0;
    [self refreshAll];
    NoteSave();
}

- (void)onClose {
    [self commitEdit];
    gSessionClosed = YES;
    FLOGI(FC_UI, @"[note] 用户关闭（本会话不再出现）");
    NoteSave();
    FDMNoteHide();
}

/* ══════════════════════════════════ 编辑 ══════════════════════════════════ */

- (void)beginEdit {
    if (_editing) return;
    if (gState.minimized) return;
    _editing = YES;
    fdmnote_item *it = fdmnote_current(&gState);
    _editor.text = it && it->text ? @(it->text) : @"";
    _editor.hidden = NO;
    _text.hidden = YES;
    [_editor becomeFirstResponder];
    /* 光标放到末尾 */
    _editor.selectedRange = NSMakeRange(_editor.text.length, 0);
}

- (void)commitEdit {
    if (!_editing) return;
    _editing = NO;
    NSString *t = _editor.text ?: @"";
    fdmnote_set_text(&gState, t.UTF8String);
    _editor.hidden = YES;
    _text.hidden = NO;
    [_editor resignFirstResponder];
    [self refreshAll];
    NoteSave();
}

- (void)textViewDidEndEditing:(UITextView *)tv {
    [self commitEdit];
}

@end


/* ══════════════════════════════════ 找窗口（统一入口）══════════════════════════════════
 *
 *  iOS 13+ 把 keyWindow / UIApplication.windows 标了弃用，理由是「多 scene 时语义不清」。
 *  我们的用法恰恰是「哪个在前台就用哪个」，所以：
 *    ① 先按 connectedScenes 找 ForegroundActive 的（正确做法）
 *    ② 找不到再退回 keyWindow / windows（兜底）
 *  ② 那两行正好是被弃用的 API —— 这里局部屏蔽，不影响别处的检查。
 */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
UIWindow *FDMFindBestWindow(void) {
    @try {
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                UIWindowScene *ws = (UIWindowScene *)sc;
                if (ws.activationState != UISceneActivationStateForegroundActive) continue;
                for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
                for (UIWindow *w in ws.windows) if (!w.hidden && w.alpha > 0.01) return w;
            }
        }
    } @catch (NSException *e) { }
    @try {
        UIWindow *kw = [UIApplication sharedApplication].keyWindow;
        if (kw) return kw;
        NSArray *ws = [UIApplication sharedApplication].windows;
        for (UIWindow *w in ws) {
            if (!w.hidden && w.alpha > 0.01 && w.windowLevel == UIWindowLevelNormal) return w;
        }
        return ws.lastObject;
    } @catch (NSException *e) {
        return nil;
    }
}
#pragma clang diagnostic pop

/* ══════════════════════════════════ 安装 / 显示 ══════════════════════════════════ */

/** 找最合适的 window（实现统一在 FDMFindBestWindow）。 */
static UIWindow *NoteFindWindow(void) { return FDMFindBestWindow(); }

BOOL FDMNoteVisible(void) {
    return (gView != nil && gView.window != nil && !gView.hidden);
}

void FDMNoteHide(void) {
    @try {
        if (gView) {
            [gView removeFromSuperview];
            gView = nil;
        }
    } @catch (NSException *e) { }
}

void FDMNoteShow(void) {
    if (gSessionClosed) return;
    if (!gOn) return;

    NoteLoad();

    UIWindow *w = NoteFindWindow();
    if (!w) return;

    if (gView && gView.superview == w) {
        [gView refreshAll];
        return;
    }

    @try {
        if (gView) [gView removeFromSuperview];
        if (!gView) {
            gView = [[FDMNoteView alloc] initWithFrame:CGRectMake(0, 0, kCardW, kCardMinH)];
        }

        /* 位置：用存档里的坐标，夹进窗口 */
        fdmnote_item *it = fdmnote_current(&gState);
        CGRect f = gView.frame;
        f.origin.x = (CGFloat)it->x;
        f.origin.y = (CGFloat)it->y;
        gView.frame = f;

        [w addSubview:gView];
        [gView refreshAll];

        /* 夹紧一次 —— 存档里的坐标可能是别的屏幕尺寸下的 */
        {
            CGRect vf = gView.frame;
            double x = vf.origin.x, y = vf.origin.y;
            fdmnote_clamp(&x, &y, vf.size.width, vf.size.height,
                          w.bounds.size.width, w.bounds.size.height);
            vf.origin.x = (CGFloat)x;
            vf.origin.y = (CGFloat)y;
            gView.frame = vf;
        }

        FLOGI(FC_UI, @"[note] 已挂到 %@ (%.0fx%.0f) 位置 (%.0f,%.0f) 共 %zu 张",
              NSStringFromClass([w class]), w.bounds.size.width, w.bounds.size.height,
              gView.frame.origin.x, gView.frame.origin.y, gState.count);
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[note] 挂载异常: %@", e.reason);
    }
}

void FDMNoteSetVisible(BOOL on) {
    if (on) {
        gSessionClosed = NO;
        gOn = YES;
        FDMNoteShow();
    } else {
        FDMNoteHide();
    }
}

void FDMNoteReload(void) {
    NoteReloadConfig();
    NoteLoad();
    if (!gOn || gSessionClosed) {
        FDMNoteHide();
        FLOGI(FC_UI, @"[note] 关闭（on=%d closed=%d）", gOn, gSessionClosed);
        return;
    }
    FDMNoteShow();
    if (gView) [gView refreshAll];
}

/* ── 巡扫：宿主切页/旋转后 window 可能换掉 ── */
static void NoteTick(void) {
    if (!gOn || gSessionClosed) {
        if (gView) FDMNoteHide();
        return;
    }
    if (!gView || !gView.superview) {
        FDMNoteShow();
        return;
    }
    UIWindow *w = NoteFindWindow();
    if (w && gView.superview != w) {
        FLOGW(FC_UI, @"[note] window 变了，重新挂");
        FDMNoteShow();
    }
}

void FDMNoteInstall(void) {
    if (gInstalled) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ FDMNoteInstall(); });
        return;
    }
    gInstalled = YES;

    /* ① 模型自检（25 条断言）*/
    {
        char err[512] = {0};
        int bad = fdmnote_selftest(err, sizeof(err));
        if (bad) {
            FLOGE(FC_UI, @"[note] 模型自检失败 #%d\n%s", bad, err);
        } else {
            FLOGI(FC_UI, @"[note] 模型 OK（25 组断言：JSON 往返/转义/夹紧/垃圾输入）");
        }
    }

    NoteReloadConfig();
    NoteLoad();

    if (!gOn) {
        FLOGI(FC_UI, @"[note] 开关关着，不启动巡扫");
        return;
    }

    FDMNoteShow();

    /* ② 1.5 秒巡一次（宿主切页/旋转后重新贴）*/
    if (!gScanTimer) {
        gScanTimer = [NSTimer scheduledTimerWithTimeInterval:1.5
                                                     repeats:YES
                                                       block:^(NSTimer *t) {
            NoteTick();
        }];
        /* 加进 common modes，滚动时不中断 */
        [[NSRunLoop mainRunLoop] addTimer:gScanTimer forMode:NSRunLoopCommonModes];
    }

    /* ③ 键盘/旋转：重新夹紧 */
    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidShowNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        [gView setNeedsLayout];
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        [gView setNeedsLayout];
    }];

    FLOGI(FC_UI, @"[note] 安装完成（%zu 张，alpha=%.2f size=%.0f）",
          gState.count, gAlpha, gFontSize);
}
