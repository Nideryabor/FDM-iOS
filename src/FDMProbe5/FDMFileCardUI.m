// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMFileCardUI.m —— 文件快捷选项（上传文件后的快捷发送项）
//
// ═══════════════════════════════════════════════════════════════════════════
//  宿主结构（类表实锤）
//    _TtC13DeepSeek_Chat22FileInputContainerView     ← 输入区的文件条
//    _TtC13DeepSeek_Chat12FileIconView
//    _TtC13DeepSeek_Chat8FileView / FileCell / InputFileCell
//
//  做法：在 FileInputContainerView 下面挂一条**我们自己的**横向按钮条：
//    · 只在「有文件」时显示（容器高度/子视图数变化时重算）
//    · 点一下 = 把 prompt 塞进输入框并尝试发送（复用 FDMComposer 的能力）
//    · 完全不动宿主自己的文件卡片布局
//
//  ★ 为什么挂在容器「下面」而不是「里面」
//    挂在里面会被宿主的 autolayout 重排覆盖；挂成兄弟视图，
//    用 frame 跟着容器走最稳（和悬浮便签同一思路）。
// ═══════════════════════════════════════════════════════════════════════════
#import "FDMFileCardUI.h"
#import "FLog.h"
#import "FDMConfig.h"
#import "FDMNote.h"        /* FDMRGBAColor */

#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

#include "FDMFileCard.h"

/* ══════════════════════════════════ 配置 ══════════════════════════════════ */

static BOOL gOn = NO;
static BOOL gLoaded = NO;
static fdmfc_list gItems;
static BOOL gItemsReady = NO;
static CGFloat gBtnH = 30.0;
static CGFloat gGap = 6.0;

static NSString *const kBarTag = @"fdm.filecard.bar";

/* ══════════════════════════════════ 读配置 ══════════════════════════════════ */

static void FileCardReload(void) {
    @try {
        FDMConfig *c = [FDMConfig shared];
        gOn = [c boolFor:@"filecard" key:@"on"] && [c enabledFor:@"filecard"];

        NSString *txt = [c stringFor:@"filecard" key:@"items"];
        if (gItemsReady) fdmfc_free(&gItems);
        fdmfc_parse(txt.length ? txt.UTF8String : NULL, &gItems);
        fdmfc_sanitize(&gItems);
        gItemsReady = YES;

        NSInteger h = [c intFor:@"filecard" key:@"btn_h"];
        gBtnH = h > 0 ? (CGFloat)h : 30.0;
        if (gBtnH < 22) gBtnH = 22;
        if (gBtnH > 48) gBtnH = 48;

        gLoaded = YES;
        FLOGI(FC_UI, @"[filecard] 配置 on=%d %d 条按钮 高=%.0f",
              gOn, gItems.count, gBtnH);
    } @catch (NSException *e) {
        gOn = NO;
        FLOGE(FC_UI, @"[filecard] 读配置异常: %@", e.reason);
    }
}

/* ══════════════════════════════════ 发送能力（复用 FDMComposer）══════════════════════════════════ */

extern BOOL FDMComposerSendText(NSString *text);       /* FDMComposer.m 提供 */
extern BOOL FDMComposerFillText(NSString *text);

/* ══════════════════════════════════ 按钮条 ══════════════════════════════════ */

@interface FDMFileCardBar : UIView
@property (nonatomic, copy) NSString *prompt;
@end

extern UIWindow *FDMFindBestWindow(void);

@implementation FDMFileCardBar
@end


static void BuildBarContent(FDMFileCardBar *bar, CGSize size) {
    for (UIView *sv in bar.subviews) [sv removeFromSuperview];

    const int n = gItems.count;
    if (n <= 0) return;

    CGFloat x = 0;
    for (int i = 0; i < n; i++) {
        fdmfc_item *it = &gItems.items[i];
        if (!it->label) continue;

        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
        b.layer.cornerRadius = gBtnH / 2.0;
        b.layer.cornerCurve = kCACornerCurveContinuous;
        b.layer.borderWidth = 0.5;
        b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.20].CGColor;
        [b setTitle:@(it->label) forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        [b setTitleColor:[UIColor colorWithWhite:0.98 alpha:1.0] forState:UIControlStateNormal];

        CGSize fit = [b sizeThatFits:CGSizeMake(200, gBtnH)];
        CGFloat w = fit.width + 24.0;
        if (w > size.width - x) w = size.width - x;
        if (w < 40) break;

        b.frame = CGRectMake(x, 0, w, gBtnH);

        /* 每个按钮自己的 prompt 挂在关联对象上（target-action 只有 sender）*/
        static char kPromptKey;
        objc_setAssociatedObject(b, &kPromptKey, @(it->prompt ?: ""),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [b addTarget:bar action:@selector(onChip:) forControlEvents:UIControlEventTouchUpInside];

        [bar addSubview:b];
        x += w + gGap;
    }
}

/*
 * target-action 要一个方法。FDMFileCardBar 上没有 onChip:，
 * 用 category 补一个（同时把 prompt 从按钮的关联对象里取出来）。
 */
@interface FDMFileCardBar (Chips)
- (void)onChip:(UIButton *)b;
@end

@implementation FDMFileCardBar (Chips)

- (void)onChip:(UIButton *)b {
    static char kPromptKey;
    NSString *p = objc_getAssociatedObject(b, &kPromptKey);
    if (!p.length) p = self.prompt;
    if (!p.length) return;
    FLOGI(FC_UI, @"[filecard] 点击「%@」", [b titleForState:UIControlStateNormal]);
    @try {
        if (FDMComposerFillText(p)) FLOGI(FC_UI, @"[filecard] 已填入输入框");
        else FLOGW(FC_UI, @"[filecard] 填不进去");
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[filecard] 异常: %@", e.reason);
    }
}

@end

/* ══════════════════════════════════════════════════════════════════════════
 *  ★★ 2026-10-23 真机血案（最严重的一个）
 *
 *  症状：屏幕上每条消息都长出一排「总结 / 翻译 / 表格」，日志里
 *        「创建按钮条」被记录了 **3132 次**。
 *
 *  根因三条，缺一条都不会这么惨：
 *    ① `FileInputContainerLayoutWrapperView` **不是只有输入区有** ——
 *       宿主的每个文件消息 cell 里都有这个类 ⇒ 每个 cell 都建了一个 bar
 *    ② 找已有 bar 用的是「superview 的直接子视图」，而宿主复用 cell 时
 *       会把子视图清掉 ⇒ 永远找不回来 ⇒ 永远新建
 *    ③ hook 挂在 `layoutSubviews`（每帧都会调）⇒ 上面两条被疯狂放大
 *
 *  ⇒ 现在的规则（三重保险）：
 *    A. 只认**输入区**（父链里必须有 InputArea）—— 其它地方一律不碰
 *    B. bar 是**全局唯一的 weak 单例**：找不回来就重新挂，**绝不新建第二个**
 *    C. 不再 hook layoutSubviews，改成 3 秒一次的低频巡检
 * ══════════════════════════════════════════════════════════════════════════ */

static __weak FDMFileCardBar *gTheBar = nil;    /* 全局唯一 */
static int gBarCreateCount = 0;                 /* 硬上限保护 */

/** 这个视图是不是在输入区里面？（父链最多 12 层）*/
static BOOL IsInInputArea(UIView *v) {
    UIView *p = v;
    for (int i = 0; i < 12 && p; i++) {
        NSString *cn = NSStringFromClass([p class]);
        if ([cn containsString:@"InputArea"]) return YES;
        if ([cn containsString:@"PromptInput"]) return YES;
        p = p.superview;
    }
    return NO;
}

/** 在容器下面放/更新按钮条（全局唯一）。 */
static void LayoutBar(UIView *container) {
    if (!container || !gOn) return;

    /* A. 只处理输入区 —— 宿主每个文件消息 cell 也有同名类 */
    if (!IsInInputArea(container)) return;

    if (gItems.count <= 0) {
        if (gTheBar) gTheBar.hidden = YES;
        return;
    }

    UIView *host = container.superview ?: container;
    if (!host) return;

    /* B. 单例：只有「根本没有」时才创建，且全局最多 1 个 */
    FDMFileCardBar *bar = gTheBar;
    if (!bar) {
        if (gBarCreateCount >= 1) {
            /* 曾经创建过但已经被系统回收了 —— 宁可没有，也不再造第二个 */
            return;
        }
        bar = [[FDMFileCardBar alloc] initWithFrame:CGRectZero];
        bar.accessibilityIdentifier = kBarTag;
        bar.backgroundColor = [UIColor clearColor];
        gTheBar = bar;
        gBarCreateCount++;
        FLOGW(FC_UI, @"[filecard] ★ 创建按钮条（全局第 %d 个，宿主 %@）",
              gBarCreateCount, NSStringFromClass([host class]));
    }

    /* 不在树上就挂回去（复用同一个实例，不新建）*/
    if (bar.superview != host) {
        [bar removeFromSuperview];
        [host addSubview:bar];
        FLOGD(FC_UI, @"[filecard] 按钮条挂到 %@", NSStringFromClass([host class]));
    }

    CGRect cb = [container convertRect:container.bounds toView:host];
    CGFloat h = gBtnH;
    CGFloat y = CGRectGetMaxY(cb) + 4.0;

    /* 输入区一般在屏幕下半部分 ⇒ 优先放上方 */
    CGFloat hostH = host.bounds.size.height;
    if (y + h > hostH - 4.0) {
        y = CGRectGetMinY(cb) - h - 4.0;
        if (y < 0) y = CGRectGetMaxY(cb) + 4.0;
    }

    CGFloat w = CGRectGetWidth(cb);
    if (w < 80) w = 80;

    bar.hidden = NO;
    CGRect want = CGRectMake(CGRectGetMinX(cb), y, w, h);
    if (!CGRectEqualToRect(bar.frame, want)) bar.frame = want;

    /* 内容只在「尺寸/条数变了」时重建（用 bar 自己的关联对象存，不用 static）*/
    static char kLastKey;
    NSString *sig = [NSString stringWithFormat:@"%.0fx%.0f#%d",
                     bar.bounds.size.width, bar.bounds.size.height, gItems.count];
    if (![sig isEqualToString:objc_getAssociatedObject(bar, &kLastKey)]) {
        objc_setAssociatedObject(bar, &kLastKey, sig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        BuildBarContent(bar, bar.bounds.size);
    }
}


/* ══════════════════════════════════ hook ══════════════════════════════════ */

static BOOL gHooked = NO;

static BOOL IsFileContainer(NSString *cn) {
    if (!cn.length) return NO;
    if ([cn containsString:@"FileInputContainer"]) return YES;
    if ([cn containsString:@"FileInputContainerLayoutWrapper"]) return YES;
    return NO;
}

/* ══════════════════════════════════════════════════════════════════════════
 *  ★ 不再 hook layoutSubviews
 *
 *  真机上 layoutSubviews 每帧都会调，而「宿主复用 cell 会清子视图」
 *  导致 bar 一直在被重建（3132 次）。改成低频巡检：
 *    · 每 3 秒扫一次，找输入区的 FileInputContainer
 *    · bar 是全局单例，只在「不在树上」时重新挂
 *  代价是最多 3 秒延迟出现，但换来「绝不爆炸」。
 * ══════════════════════════════════════════════════════════════════════════ */

static NSTimer *gFCScanTimer = nil;

static void FCScanOnce(void) {
    if (!gOn) return;
    @try {
        NSMutableArray *wins = [NSMutableArray array];
        extern UIWindow *FDMFindBestWindow(void);
        UIWindow *best = FDMFindBestWindow();
        if (best) [wins addObject:best];

        for (UIWindow *w in wins) {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
            int guard = 0;
            while (stack.count && guard++ < 4000) {
                UIView *v = stack.lastObject;
                [stack removeLastObject];
                if (IsFileContainer(NSStringFromClass([v class])) && IsInInputArea(v)) {
                    LayoutBar(v);
                }
                for (UIView *sv in v.subviews) [stack addObject:sv];
            }
        }
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[filecard] 巡检异常: %@", e.reason);
    }
}

void FDMFileCardInstall(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ FDMFileCardInstall(); });
        return;
    }
    if (!gLoaded) {
        /* ① 内核自检（20 条断言）*/
        char err[512] = {0};
        int bad = fdmfc_selftest(err, sizeof(err));
        if (bad) {
            FLOGE(FC_UI, @"[filecard] 内核自检失败 #%d\n%s", bad, err);
        } else {
            FLOGI(FC_UI, @"[filecard] 内核 OK（20 组断言：宽容解析/全角分隔/超长截断/去重）");
        }
        FileCardReload();
    }
    if (!gOn) {
        FLOGI(FC_UI, @"[filecard] 开关关着，不装");
        return;
    }
    if (gHooked) {
        FCScanOnce();
        return;
    }
    gHooked = YES;

    /* 只启动巡检，不 hook 任何宿主方法 —— 零污染 */
    FCScanOnce();
    if (!gFCScanTimer) {
        gFCScanTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                       repeats:YES
                                                         block:^(NSTimer *t) {
            FCScanOnce();
        }];
        [[NSRunLoop mainRunLoop] addTimer:gFCScanTimer forMode:NSRunLoopCommonModes];
    }
    FLOGI(FC_UI, @"[filecard] 已启动巡检（3s 一次，全局最多 1 个按钮条）");
}

void FDMFileCardReload(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ FDMFileCardReload(); });
        return;
    }
    FileCardReload();
    if (!gOn) {
        FDMFileCardRefreshAll();
        return;
    }
    if (!gHooked) FDMFileCardInstall();
    else FDMFileCardRefreshAll();
}

void FDMFileCardRefreshAll(void) {
    if (!gOn) {
        if (gTheBar) [gTheBar removeFromSuperview];
        FLOGI(FC_UI, @"[filecard] 已关闭，按钮条已移除");
        return;
    }
    FCScanOnce();
}
