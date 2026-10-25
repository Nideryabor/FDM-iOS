// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMGlassHook.m —— 把玻璃装到宿主「已有的」模糊控件上
//
// 只挂三个方法，且都不在热路径上：
//   -[UIVisualEffectView initWithEffect:]   标记「这块可以升级」
//   -[UIVisualEffectView setEffect:]        宿主换主题/换样式时重新标记
//   -[UIVisualEffectView layoutSubviews]    ★ 真正干活的地方
//
// 为什么渲染放在 layoutSubviews：
//   ① init 时 bounds 还是 0，画不了
//   ② 宿主会改 frame（横竖屏 / 键盘 / 导航栏折叠）—— 装饰层必须跟着
//   ③ 里面只是「取一下 plan + 改几个 layer.frame」，没有 new 对象
//
// 为什么不 hook 滚动：
//   hook -[UIScrollView setContentOffset:] 每帧都调，太热；
//   改用 CADisplayLink 实测帧耗时（见 FDMGlass.m）—— 零 hook 成本且更准。
//   滚动导致的掉帧会被帧监测抓到并自动降档，比「假设滚动一定卡」更贴近真实。
#import "FDMGlass.h"
#import "FLog.h"

#import <objc/runtime.h>

static char kWantKey;
static __thread BOOL tInSetEffect = NO;   /* 防我们自己的 setEffect 被自己拦 */

/** 最近的类名（日志用）。 */
static NSString *OwnerHint(UIVisualEffectView *v) {
    @try {
        if (v.superview) return NSStringFromClass([v.superview class]);
    } @catch (NSException *e) { }
    return @"?";
}

static void MarkWant(UIVisualEffectView *v, const char *why) {
    if (!v) return;
    objc_setAssociatedObject(v, &kWantKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    FLOGT(FC_UI, @"[glass] 标记 %@ (%s)", OwnerHint(v), why);
}

static BOOL WantsGlass(UIVisualEffectView *v) {
    return objc_getAssociatedObject(v, &kWantKey) != nil;
}

void FDMGlassHookInstall(void);

void FDMGlassHookInstall(void) {
    Class cls = NSClassFromString(@"UIVisualEffectView");
    if (!cls) {
        FLOGE(FC_UI, @"[glass] 找不到 UIVisualEffectView ⇒ hook 放弃");
        return;
    }

    /* ── ① initWithEffect: ── */
    SEL sInit = @selector(initWithEffect:);
    Method mInit = class_getInstanceMethod(cls, sInit);
    if (mInit) {
        IMP orig = method_getImplementation(mInit);
        IMP mine = imp_implementationWithBlock(^(id self, UIVisualEffect *effect) {
            UIVisualEffectView *v =
                ((id (*)(id, SEL, UIVisualEffect *))orig)(self, sInit, effect);
            @try {
                if (v.effect) MarkWant(v, "init");
            } @catch (NSException *e) { }
            return v;
        });
        method_setImplementation(mInit, mine);
        FLOGI(FC_UI, @"[glass] hook initWithEffect:");
    }

    /* ── ② setEffect: —— 用 __thread 防重入 ── */
    SEL sSet = @selector(setEffect:);
    Method mSet = class_getInstanceMethod(cls, sSet);
    if (mSet) {
        IMP orig = method_getImplementation(mSet);
        IMP mine = imp_implementationWithBlock(^(id self, UIVisualEffect *effect) {
            BOOL outer = !tInSetEffect;
            if (outer) tInSetEffect = YES;
            @try {
                ((void (*)(id, SEL, UIVisualEffect *))orig)(self, sSet, effect);
            } @finally {
                if (outer) tInSetEffect = NO;
            }
            if (outer) {
                @try {
                    UIVisualEffectView *v = (UIVisualEffectView *)self;
                    if (v.effect) MarkWant(v, "setEffect");
                } @catch (NSException *e) { }
            }
        });
        method_setImplementation(mSet, mine);
        FLOGI(FC_UI, @"[glass] hook setEffect:");
    }

    /* ── ③ layoutSubviews ── */
    SEL sLayout = @selector(layoutSubviews);
    Method mLayout = class_getInstanceMethod(cls, sLayout);
    if (mLayout) {
        IMP orig = method_getImplementation(mLayout);
        IMP mine = imp_implementationWithBlock(^(id self) {
            @try {
                ((void (*)(id, SEL))orig)(self, sLayout);
            } @catch (NSException *e) { }

            @try {
                UIVisualEffectView *v = (UIVisualEffectView *)self;
                if (!WantsGlass(v)) return;
                CGRect b = v.bounds;
                if (b.size.width < 4 || b.size.height < 4) return;   /* 还没布局完 */
                FDMGlassApply(v);        /* 内部幂等：有就更新，没有就建 */
            } @catch (NSException *e) {
                /* layoutSubviews 里抛异常 = 污染宿主布局，必须吞掉 */
            }
        });
        method_setImplementation(mLayout, mine);
        FLOGI(FC_UI, @"[glass] hook layoutSubviews");
    }
}
