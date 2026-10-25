// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMGlass.m —— 设备画像 / 全局决策 / 装饰层渲染 / effect 改造
#import "FDMGlass.h"
#import "FLog.h"
#import "FDMConfig.h"

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>

/* ══════════════════════════════════════════════════════════════════════════
 *  一、设备画像（进程内只探一次）
 * ══════════════════════════════════════════════════════════════════════════ */

static fdmgp_profile gProfile;
static BOOL gProfileReady = NO;
static int  gUserTier = -1;
static int  gForceTier = 0;   /* 1 = 无视硬件上限（用户显式指定时）*/
static BOOL gGlassEnabled = NO;  /* 总开关（Install/ReloadConfig 里维护）*/

/* NSString 的 %s 会按系统编码解释 C 字符串 ⇒ 中文变乱码（真机实测
 * 「无底色」显示成 Êó†Â∫ïËâ≤）。这里先用 UTF-8 转成 NSString 再 %@。 */
static NSString *U8(const char *s) {
    if (!s) return @"";
    NSString *r = [NSString stringWithUTF8String:s];
    return r ?: @"?";
}



/** Metal GPU family：从高往低试（1009 = Apple9 ... 1001 = Apple1）。 */
static int ProbeGpuFamily(void) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) return 0;
    for (int f = 9; f >= 1; f--) {
        if ([dev supportsFamily:(MTLGPUFamily)(1000 + f)]) return f;
    }
    return 0;
}

static long long SysctlI64(const char *name) {
    long long v = 0;
    size_t sz = sizeof(v);
    if (sysctlbyname(name, &v, &sz, NULL, 0) != 0) return 0;
    return v;
}

static void ProbeDevice(void) {
    if (gProfileReady) return;
    memset(&gProfile, 0, sizeof(gProfile));

    /* ★ 真机教训（2026-10-23 · iPhone9,2 / A10）：
     *   hw.ncpu 报 **2** —— A10 是「2 大 + 2 小、同一时刻只跑一组」的设计，
     *   hw.physicalcpu 才是 4。取两者较大值，否则 A10 会被当成双核老机器。 */
    int ncpu = (int)SysctlI64("hw.ncpu");
    int phys = (int)SysctlI64("hw.physicalcpu");
    int cores = ncpu > phys ? ncpu : phys;
    if (cores <= 0) cores = (int)[[NSProcessInfo processInfo] processorCount];
    gProfile.cpu_cores = cores;

    long long mem = SysctlI64("hw.memsize");
    gProfile.ram_mb = mem > 0 ? (mem / (1024 * 1024)) : 0;

    gProfile.gpu_family = ProbeGpuFamily();
    gProfile.has_metallic = 1;
    gProfile.user_tier = gUserTier;

    gProfileReady = YES;
    FLOGI(FC_UI, @"[glass] 设备画像 cores=%d(ncpu=%d phys=%d) ram=%lldMB gpu=Apple%d score=%d",
          gProfile.cpu_cores, ncpu, phys, gProfile.ram_mb, gProfile.gpu_family,
          fdmgp_hardware_score(&gProfile));
}

/* ══════════════════════════════════════════════════════════════════════════
 *  二、系统原生材质探测（iOS 26+）
 * ══════════════════════════════════════════════════════════════════════════ */

static BOOL gNativeProbed = NO;
static BOOL gNativeAvailable = NO;

/**
 * 探测系统是否真的提供了玻璃材质。
 * **不硬编码 iOS 26 的 API 名** —— 只按类名找，找不到就当没有。
 * 将来 Apple 改名 / 换签名也不会崩。
 */
static BOOL ProbeNativeGlass(void) {
    if (gNativeProbed) return gNativeAvailable;
    gNativeProbed = YES;

    gNativeAvailable = (NSClassFromString(@"UIGlassEffect") != Nil);
    if (gNativeAvailable) {
        FLOGW(FC_UI, @"[glass] 探测到系统 UIGlassEffect ⇒ 走 T4 原生材质");
    } else {
        FLOGI(FC_UI, @"[glass] 系统无 UIGlassEffect（iOS %@）⇒ 自合成方案",
              [[UIDevice currentDevice] systemVersion]);
    }
    return gNativeAvailable;
}

/* ══════════════════════════════════════════════════════════════════════════
 *  三、场景状态
 * ══════════════════════════════════════════════════════════════════════════ */

static int gScrolling = 0;
static int gKeyboardUp = 0;
static int gGlassCount = 0;

/* ══════════════════════════════════════════════════════════════════════════
 *  四、全局决策（1 秒缓存 + 场景变化立即失效）
 * ══════════════════════════════════════════════════════════════════════════ */

/** 所有已接管的玻璃控件（弱引用：宿主释放就自动消失）。 */
static NSHashTable *gTouched = nil;

/** ★ 早期层排进来的「待装饰」控件（didMoveToWindow 捕获，巡检时统一处理）*/
static NSMutableArray *gPendingQueue = nil;

static fdmgp_plan gPlan;
static CFAbsoluteTime gPlanAt = 0;
static BOOL gPlanValid = NO;
static inline void InvalidatePlan(void) { gPlanValid = NO; }

static void RecomputePlan(void) {
    ProbeDevice();

    fdmgp_profile p = gProfile;
    p.user_tier = gUserTier;
    p.force_tier = gForceTier;
    p.reduce_transparency = UIAccessibilityIsReduceTransparencyEnabled() ? 1 : 0;
    p.reduce_motion = UIAccessibilityIsReduceMotionEnabled() ? 1 : 0;
    p.low_power = [[NSProcessInfo processInfo] isLowPowerModeEnabled] ? 1 : 0;
    p.scrolling = gScrolling;
    p.keyboard_up = gKeyboardUp;
    p.glass_count = gGlassCount;

    if (ProbeNativeGlass() && (gUserTier < 0 || gUserTier == FDMGlassTierNative)) {
        p.user_tier = FDMGlassTierNative;
    }

    fdmgp_plan np;
    fdmgp_decide(&p, &np);
    np.score = fdmgp_hardware_score(&p);

    BOOL changed = (!gPlanValid || np.tier != gPlan.tier);
    gPlan = np;
    gPlanAt = CFAbsoluteTimeGetCurrent();
    gPlanValid = YES;

    if (changed) {
        FLOGI(FC_UI, @"[glass] 决策 ⇒ %s 模糊%.0f 饱和%.2f 高光%.2f 折射%d (score=%d %@)",
              fdmgp_tier_name(np.tier), (double)np.blur_radius,
              (double)np.blur_saturation, (double)np.highlight_alpha,
              np.refraction, np.score, U8(np.reason));
    }
}

fdmgp_plan FDMGlassCurrentPlan(void) {
    /* 同屏玻璃数：weak 表会随对象释放自动变小，所以每次读的时候同步一次。
     * 这是填充率保护的输入 —— 20 块 22pt 半径的模糊在 A10 上就开始掉帧了。 */
    if (gTouched) gGlassCount = (int)gTouched.count;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!gPlanValid || now - gPlanAt > 1.0) RecomputePlan();
    return gPlan;
}

void FDMGlassSetUserTier(int tier) {
    gUserTier = (tier < -1 || tier > 4) ? -1 : tier;
    /* ★ 用户显式指定 0..4 ⇒ 允许越过硬件上限
     *   （真机教训：A10 手动选 T3 被静默钳到 T2，用户以为功能坏了）*/
    gForceTier = (gUserTier >= 0) ? 1 : 0;
    InvalidatePlan();
    FLOGI(FC_UI, @"[glass] 用户定档 → %@",
          tier < 0 ? @"自动" : U8(fdmgp_tier_name(tier)));
    FDMGlassRefreshAll();
}

int FDMGlassUserTier(void) { return gUserTier; }

NSString *FDMGlassStatusLine(void) {
    fdmgp_plan p = FDMGlassCurrentPlan();

    /* ★ 真机教训（2026-10-23）：NSString 的 %s 会按系统编码解释 C 字符串，
     *   传中文字面量（UTF-8 多字节）⇒ 界面上变成「ÈùôÊÄÅ」。
     *   中文一律走 %@（NSString），只有纯 ASCII（tier 名 / reason）才用 %s。 */
    NSString *refract = p.refraction ? @" · 折射" : @"";
    NSString *anim = p.animated ? @"动效" : @"静态";
    return [NSString stringWithFormat:@"%s · 模糊%.0f 饱和%.2f 高光%.2f%@ · %@@%@",
            fdmgp_tier_name(p.tier),
            (double)p.blur_radius, (double)p.blur_saturation,
            (double)p.highlight_alpha,
            refract, anim, U8(p.reason)];
}

void FDMGlassNoteScrolling(BOOL scrolling) {
    int v = scrolling ? 1 : 0;
    if (v == gScrolling) return;
    gScrolling = v;
    InvalidatePlan();
}

void FDMGlassNoteKeyboard(BOOL up) {
    int v = up ? 1 : 0;
    if (v == gKeyboardUp) return;
    gKeyboardUp = v;
    InvalidatePlan();
}

/* ══════════════════════════════════════════════════════════════════════════
 *  五、装饰层渲染
 * ══════════════════════════════════════════════════════════════════════════ */

static UIColor *GlassWhite(CGFloat a) { return [UIColor colorWithWhite:1.0 alpha:a]; }
static UIColor *GlassBlack(CGFloat a) { return [UIColor colorWithWhite:0.0 alpha:a]; }

/** 从视图往上找它所在的圆角（宿主控件常见 10~22），拿不到就 14。 */
static CGFloat GuessCornerRadius(UIView *v) {
    @try {
        CALayer *l = v.layer;
        if (l.cornerRadius > 0.5) return l.cornerRadius;
        for (UIView *s in v.subviews) {
            if (s.layer.cornerRadius > 0.5) return s.layer.cornerRadius;
        }
    } @catch (NSException *e) { }
    return 14.0;
}

/**
 * 圆角描边 mask。
 * UIKit 的描边是**居中**的：lineWidth=1 会向内向外各溢 0.5pt。
 * 高光要落在圆角内侧才像玻璃边缘，所以线宽取 2xwidth、视觉上正好一半可见。
 */
static CAShapeLayer *MakeStrokeMask(CGRect bounds, CGFloat radius, CGFloat width) {
    CAShapeLayer *m = [CAShapeLayer layer];
    m.frame = bounds;
    m.path = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:radius].CGPath;
    m.fillColor = nil;
    m.strokeColor = [UIColor whiteColor].CGColor;
    m.lineWidth = width * 2.0;
    return m;
}

/**
 * 边缘高光层。
 * 渐变 45 度（左上亮 → 右下淡）是 Liquid Glass 的「光源在上方」约定。
 * 深色模式下白色高光会刺眼 ⇒ 调用方已经把 alpha 打过折。
 */
static CAGradientLayer *MakeHighlight(CGRect bounds, CGFloat radius,
                                      CGFloat alpha, CGFloat width) {
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = bounds;
    g.startPoint = CGPointMake(0.0, 0.0);
    g.endPoint = CGPointMake(1.0, 1.0);
    g.colors = @[(id)GlassWhite(alpha).CGColor,
                 (id)GlassWhite(alpha * 0.06).CGColor,
                 (id)GlassWhite(alpha * 0.50).CGColor];
    g.locations = @[@0.0, @0.52, @1.0];
    g.mask = MakeStrokeMask(bounds, radius, width);
    return g;
}

/** 内部透光：上亮 → 中间透明 → 下暗（玻璃厚度感）。 */
static CAGradientLayer *MakeInnerGlow(CGRect bounds, CGFloat alpha) {
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = bounds;
    g.startPoint = CGPointMake(0.5, 0.0);
    g.endPoint = CGPointMake(0.5, 1.0);
    g.colors = @[(id)GlassWhite(alpha).CGColor,
                 (id)GlassWhite(0.0).CGColor,
                 (id)GlassBlack(alpha * 0.45).CGColor];
    g.locations = @[@0.0, @0.45, @1.0];
    return g;
}

/**
 * T3 的「折射感」：贴着内缘的一条极淡反光线。
 *
 * 诚实说明：iOS 15 拿不到宿主合成好的背景纹理去做扭曲
 * （那需要 Metal shader / RuntimeShader），所以这**不是**真折射，
 * 而是「玻璃边缘把光拢住」的近似。真折射要等 iOS 26 的系统材质。
 * 真正带来透镜感的是 effect 的 scale=1.02（采样放大），那个是真的。
 */
static CAShapeLayer *MakeEdgeRefract(CGRect bounds, CGFloat radius, CGFloat alpha) {
    CAShapeLayer *s = [CAShapeLayer layer];
    s.frame = bounds;
    s.path = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:radius].CGPath;
    s.fillColor = [UIColor clearColor].CGColor;
    s.strokeColor = GlassWhite(alpha * 0.55).CGColor;
    s.lineWidth = 2.0;
    return s;
}

static CALayer *FindNamed(UIView *v, NSString *name) {
    for (CALayer *l in v.layer.sublayers) {
        if ([l.name isEqualToString:name]) return l;
    }
    return nil;
}

static char kLastLayoutKey;

/**
 * 找到/创建/更新装饰层。
 *
 * ★ layoutSubviews 里每帧都会被调到，所以这里必须有「没变化就直接返回」的守卫 ——
 *   否则每帧 new 一个 CAShapeLayer + CAGradientLayer，A10 上直接掉帧。
 *   判据：bounds + 圆角 + 档位 + 高光强度 四样都没变 ⇒ 什么都不做。
 */
static void EnsureDecorLayers(UIVisualEffectView *vev, fdmgp_plan plan) {
    if (plan.tier < FDMGlassTierHighlight) return;

    CGRect b = vev.bounds;
    if (b.size.width < 4 || b.size.height < 4) return;   /* 还没布局 */
    CGFloat r = GuessCornerRadius(vev);

    CGFloat hAprobe = plan.highlight_alpha;
    if (@available(iOS 13.0, *)) {
        if (vev.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) hAprobe *= 0.55;
    }
    NSString *sig = [NSString stringWithFormat:@"%.1fx%.1f@%.1f r%.1f t%d a%.3f d%d",
                     b.size.width, b.size.height, b.origin.y, r,
                     plan.tier, hAprobe, plan.refraction];
    if ([sig isEqualToString:objc_getAssociatedObject(vev, &kLastLayoutKey)]) return;
    objc_setAssociatedObject(vev, &kLastLayoutKey, sig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGFloat hA = plan.highlight_alpha;
    if (@available(iOS 13.0, *)) {
        if (vev.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            hA *= 0.55;                                   /* 深色下别太刺眼 */
        }
    }

    /* ── 边缘高光 ── */
    CAGradientLayer *hl = (CAGradientLayer *)FindNamed(vev, FDM_GLASS_NAME_HIGHLIGHT);
    if (!hl) {
        hl = MakeHighlight(b, r, hA, plan.highlight_width);
        hl.name = FDM_GLASS_NAME_HIGHLIGHT;
        hl.zPosition = 100;
        [vev.layer addSublayer:hl];
    } else {
        hl.frame = b;
        hl.colors = @[(id)GlassWhite(hA).CGColor,
                      (id)GlassWhite(hA * 0.06).CGColor,
                      (id)GlassWhite(hA * 0.50).CGColor];
        hl.mask = MakeStrokeMask(b, r, plan.highlight_width);
    }

    /* ── 内部透光 ── */
    CAGradientLayer *inner = (CAGradientLayer *)FindNamed(vev, FDM_GLASS_NAME_INNER);
    if (!inner) {
        inner = MakeInnerGlow(b, plan.inner_grad_alpha);
        inner.name = FDM_GLASS_NAME_INNER;
        inner.zPosition = 99;
        [vev.layer addSublayer:inner];
    } else {
        inner.frame = b;
    }

    /* ── 折射内缘线（只有 T3）── */
    CAShapeLayer *glow = (CAShapeLayer *)FindNamed(vev, FDM_GLASS_NAME_GLOW);
    if (plan.refraction) {
        if (!glow) {
            glow = MakeEdgeRefract(b, r, plan.refraction_alpha);
            glow.name = FDM_GLASS_NAME_GLOW;
            glow.zPosition = 101;
            [vev.layer addSublayer:glow];
        } else {
            glow.frame = b;
            glow.path = [UIBezierPath bezierPathWithRoundedRect:b cornerRadius:r].CGPath;
            glow.strokeColor = GlassWhite(plan.refraction_alpha * 0.55).CGColor;
        }
    } else if (glow) {
        [glow removeFromSuperlayer];
    }
}

static void RemoveDecorLayers(UIVisualEffectView *vev) {
    NSMutableArray *doomed = [NSMutableArray array];
    for (CALayer *l in vev.layer.sublayers) {
        NSString *n = l.name;
        if ([n isEqualToString:FDM_GLASS_NAME_HIGHLIGHT] ||
            [n isEqualToString:FDM_GLASS_NAME_INNER] ||
            [n isEqualToString:FDM_GLASS_NAME_GLOW]) {
            [doomed addObject:l];
        }
    }
    for (CALayer *l in doomed) [l removeFromSuperlayer];
}

/* ══════════════════════════════════════════════════════════════════════════
 *  六、effect 改造（_UICustomBlurEffect）
 * ══════════════════════════════════════════════════════════════════════════ */

static BOOL gCustomEffectOK = NO;
static BOOL gCustomEffectProbed = NO;

/**
 * _UICustomBlurEffect 是私有类（iOS 8 起一直存在，越狱圈长期使用）。
 * 探测方式：能找到类 + 能 setValue:forKey: 就算可用 —— 不硬信版本号。
 */
static Class CustomBlurClass(void) {
    if (gCustomEffectProbed) {
        return gCustomEffectOK ? NSClassFromString(@"_UICustomBlurEffect") : Nil;
    }
    gCustomEffectProbed = YES;
    Class c = NSClassFromString(@"_UICustomBlurEffect");
    if (!c) {
        FLOGW(FC_UI, @"[glass] 没有 _UICustomBlurEffect ⇒ 模糊参数不可调（只做高光）");
        return Nil;
    }
    @try {
        id e = [[c alloc] init];
        if (![e isKindOfClass:[UIVisualEffect class]]) {
            FLOGW(FC_UI, @"[glass] _UICustomBlurEffect 不是 UIVisualEffect 子类 ⇒ 放弃");
            return Nil;
        }
        [e setValue:@(20.0) forKey:@"blurRadius"];
        [e setValue:@(1.8) forKey:@"saturationDeltaFactor"];
        gCustomEffectOK = YES;
        FLOGI(FC_UI, @"[glass] _UICustomBlurEffect 可用（radius/saturation 可调）");
        return c;
    } @catch (NSException *ex) {
        FLOGW(FC_UI, @"[glass] _UICustomBlurEffect 设参数失败: %@ ⇒ 放弃", ex.reason);
        return Nil;
    }
}

/** 造一个「玻璃参数」的 effect；失败返回 nil（调用方保留原 effect）。 */
static UIVisualEffect *MakeGlassEffect(fdmgp_plan plan) {
    Class c = CustomBlurClass();
    if (!c || plan.blur_radius <= 0.0f) return nil;
    @try {
        id e = [[c alloc] init];
        [e setValue:@(plan.blur_radius) forKey:@"blurRadius"];
        [e setValue:@(plan.blur_saturation) forKey:@"saturationDeltaFactor"];
        /* scale > 1 = 采样放大 = 透镜放大感（只有 T3 给） */
        if (plan.blur_scale > 1.0f) {
            [e setValue:@(plan.blur_scale) forKey:@"scale"];
        }
        return (UIVisualEffect *)e;
    } @catch (NSException *ex) {
        return nil;
    }
}

/** 系统原生材质（iOS 26+）：只按类名造，不猜方法名。 */
static UIVisualEffect *MakeNativeGlassEffect(void) {
    Class c = NSClassFromString(@"UIGlassEffect");
    if (!c) return nil;
    @try {
        id e = [[c alloc] init];
        return [e isKindOfClass:[UIVisualEffect class]] ? (UIVisualEffect *)e : nil;
    } @catch (NSException *ex) {
        return nil;
    }
}

/* ══════════════════════════════════════════════════════════════════════════
 *  七、对外：应用（幂等）
 * ══════════════════════════════════════════════════════════════════════════ */

static char kGlassMarkKey;
static char kGlassOrigKey;

static void Mark(UIVisualEffectView *v, int tier) {
    objc_setAssociatedObject(v, &kGlassMarkKey, @(tier),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void RememberTouched(UIVisualEffectView *v) {
    if (!gTouched) {
        gTouched = [NSHashTable weakObjectsHashTable];
    }
    if (![gTouched containsObject:v]) {
        [gTouched addObject:v];
        gGlassCount = (int)gTouched.count;
        InvalidatePlan();
    }
}

void FDMGlassRefreshAll(void) {
    if (!gTouched) return;
    NSArray *all = gTouched.allObjects;
    FLOGI(FC_UI, @"[glass] 重建 %lu 块玻璃", (unsigned long)all.count);
    for (UIVisualEffectView *v in all) FDMGlassApply(v);
}

void FDMGlassApply(UIVisualEffectView *vev) {
    if (!vev) return;
    @try {
        fdmgp_plan plan = FDMGlassCurrentPlan();

        /* T0：全撤，恢复原 effect（用户可能刚开了「降低透明度」）*/
        if (plan.tier == FDMGlassTierOff) {
            RemoveDecorLayers(vev);
            UIVisualEffect *orig = objc_getAssociatedObject(vev, &kGlassOrigKey);
            if (orig && vev.effect != orig) vev.effect = orig;
            Mark(vev, FDMGlassTierOff);
            return;
        }

        /* T4：交给系统 */
        if (plan.tier == FDMGlassTierNative) {
            UIVisualEffect *ne = MakeNativeGlassEffect();
            if (ne) {
                RemoveDecorLayers(vev);
                if (vev.effect != ne) vev.effect = ne;
                Mark(vev, FDMGlassTierNative);
                RememberTouched(vev);
                return;
            }
            /* 探测说有、造不出来 ⇒ 退回自合成（别留个空 glass）*/
        }

        /* 记下原始 effect（只记第一次）*/
        if (!objc_getAssociatedObject(vev, &kGlassOrigKey) && vev.effect) {
            objc_setAssociatedObject(vev, &kGlassOrigKey, vev.effect,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        /* T2/T3：换 effect 参数 */
        if (plan.blur_radius > 0.0f) {
            UIVisualEffect *ge = MakeGlassEffect(plan);
            if (ge && vev.effect != ge) vev.effect = ge;
        }
        /*
         * T1 的取舍：不做模糊增强，但**也不把 effect 置空** ——
         * 置空会露出未模糊的背景（比原来更难看）。
         * T1 的定义是「不增加模糊成本」，不是「拆掉宿主的模糊」。
         */

        EnsureDecorLayers(vev, plan);
        Mark(vev, plan.tier);
        RememberTouched(vev);

    } @catch (NSException *ex) {
        FLOGE(FC_UI, @"[glass] apply 异常（已吞）: %@", ex.reason);
    }
}

/* ══════════════════════════════════════════════════════════════════════════
 *  八、帧时间监测 —— 真正的性能分级依据
 *
 *  硬件型号只能「猜」；这一层是**实测**。
 *  每 40 帧算一次平均帧耗时，超预算就降一档并**本会话锁死**（不来回跳）。
 * ══════════════════════════════════════════════════════════════════════════ */

@interface FDMGlassTicker : NSObject
- (void)tick:(CADisplayLink *)link;
@end

static CADisplayLink *gLink = nil;
static FDMGlassTicker *gTicker = nil;
static CFTimeInterval gLastFrame = 0;
static int gSampleCount = 0;
static double gSampleSum = 0.0;
static BOOL gEverDowngraded = NO;

@implementation FDMGlassTicker

- (void)tick:(CADisplayLink *)link {
    CFTimeInterval now = link.timestamp;
    if (gLastFrame > 0) {
        double ms = (now - gLastFrame) * 1000.0;
        if (ms > 0 && ms < 500.0) {          /* 丢掉切后台/卡死的异常样本 */
            gSampleSum += ms;
            gSampleCount++;
        }
    }
    gLastFrame = now;

    if (gSampleCount < 40 || gEverDowngraded) return;

    double avg = gSampleSum / (double)gSampleCount;
    gSampleSum = 0.0;
    gSampleCount = 0;

    fdmgp_profile p = gProfile;
    p.user_tier = gUserTier;
    p.force_tier = gForceTier;
    p.low_power = [[NSProcessInfo processInfo] isLowPowerModeEnabled] ? 1 : 0;
    p.reduce_transparency = UIAccessibilityIsReduceTransparencyEnabled() ? 1 : 0;
    p.glass_count = gGlassCount;
    p.scrolling = gScrolling;
    p.keyboard_up = gKeyboardUp;

    int changed = fdmgp_note_frame_ms(&p, avg, 0.0);
    gProfile.penalty = p.penalty;

    if (changed) {
        gEverDowngraded = YES;
        InvalidatePlan();
        FLOGW(FC_UI, @"[glass] 帧耗时 %.1fms 超预算 ⇒ 自动降档并锁定（本会话不再升）", avg);
        FDMGlassRefreshAll();
    } else if (p.penalty > 0) {
        FLOGD(FC_UI, @"[glass] 帧耗时 %.1fms（penalty=%d）", avg, p.penalty);
    }
}

@end

static void StartFrameWatch(void) {
    if (gLink) return;
    gTicker = [[FDMGlassTicker alloc] init];
    gLink = [CADisplayLink displayLinkWithTarget:gTicker selector:@selector(tick:)];
    if (!gLink) return;
    if (@available(iOS 15.0, *)) {
        gLink.preferredFrameRateRange = CAFrameRateRangeMake(30.0, 60.0, 60.0);
    } else {
        gLink.preferredFramesPerSecond = 60;
    }
    [gLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    FLOGI(FC_UI, @"[glass] 帧时间监测已启动（40 帧一评）");
}

/* ══════════════════════════════════════════════════════════════════════════
 *  九、安装
 * ══════════════════════════════════════════════════════════════════════════ */

static BOOL gInstalled = NO;
static void StartFrameWatch(void);
static void StartButtonGlassWatch(void);   /* 见文件末尾「十、按钮玻璃」*/
static void ScanButtonGlass(void);
static void InstallCellReuseHook(void);
static void DecorateView(UIView *v, fdmgp_plan plan);

/* ══════════════════════════════════════════════════════════════════════════
 *  读用户开关（Documents/fdm-debug.json）
 *    glass_on   BOOL，默认 YES（主人明确要「强开」）
 *    glass_tier 整数，默认 -1 = 自动；0..4 = 强制
 *  和 FDMProbeReadDebugBool 区别：那个第二参是 BOOL，读不了整数，所以自带一份。
 * ══════════════════════════════════════════════════════════════════════════ */

static NSDictionary *GlassDebugDict(void) {
    @try {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                             NSUserDomainMask, YES).firstObject;
        if (!docs.length) return nil;
        NSString *p = [docs stringByAppendingPathComponent:@"fdm-debug.json"];
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (!d) return nil;
        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        return [j isKindOfClass:[NSDictionary class]] ? (NSDictionary *)j : nil;
    } @catch (NSException *e) {
        return nil;
    }
}

void FDMGlassInstall(void) {
    if (gInstalled) return;

    /* ★ 必须在主线程装：
     *   ① CADisplayLink 要 add 到 mainRunLoop
     *   ② method_setImplementation 虽然线程安全，但宿主 layout 在主线程，
     *      从后台改 IMP 有可能撞上正在执行的 layoutSubviews
     *   FDMProbe 的 6s 定时器跑在后台队列，所以这里自己跳回主线程。 */
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FDMGlassInstall();
        });
        return;
    }

    gInstalled = YES;

    /* ⓪ 读开关
     *
     * ★ 两个来源，优先级从高到低：
     *   ① FDMConfig（设置页 UI 写的 fdm-glass.json）—— 正常路径
     *   ② fdm-debug.json 的 glass_on / glass_tier —— 调试通道（保留）
     *
     * 为什么两套都要：设置页是给用户用的，fdm-debug.json 是给
     * 「UI 还没加载出来时」快速验证用的（比如 TrollFools 注入后
     * 宿主立刻要看效果，来不及点设置页）。
     */
    BOOL fromUI = NO;
    @try {
        FDMConfig *c = [FDMConfig shared];
        /* allGroups 里有没有 glass 组？没有说明 UI 还没注册（不该发生），跳过 */
        if ([c groupByID:@"glass"]) {
            fromUI = YES;
            /* ★ 2026-10-23：玻璃改为**常量开启**（主人要求）。
             *   设置页不再提供总开关，所以这里不看 on，也不看 enabledFor。 */
            id onv = [c boolFor:@"glass" key:@"on"] ? @YES : nil;
            (void)onv;
            NSString *tn = [c stringFor:@"glass" key:@"tier"];
            int want = -1;
            if ([tn isEqualToString:@"off"])          want = FDMGlassTierOff;
            else if ([tn isEqualToString:@"light"])   want = FDMGlassTierHighlight;
            else if ([tn isEqualToString:@"blur"])    want = FDMGlassTierBlur;
            else if ([tn isEqualToString:@"refract"]) want = FDMGlassTierRefract;
            else if ([tn isEqualToString:@"native"])  want = FDMGlassTierNative;
            if (want >= 0 && want <= 4) {
                gUserTier = want;
                /* ★★ 2026-10-23 真机二次踩坑：这里原来只设了 gUserTier，
                 *   **忘了设 gForceTier** ⇒ 强制档仍然被硬件上限 + 低电量钳制，
                 *   界面上看起来"设了 T3 但毫无变化"。
                 *   两处（这里 和 FDMGlassSetUserTier）必须都设。 */
                gForceTier = 1;
                FLOGI(FC_UI, @"[glass] 设置页 tier=%@ ⇒ 强制 %@（无视硬件上限）",
                      tn, U8(fdmgp_tier_name(want)));
            } else {
                gForceTier = 0;
                FLOGI(FC_UI, @"[glass] 设置页 tier=%@ ⇒ 自动", tn ?: @"(空)");
            }
        }
    } @catch (NSException *e) {
        fromUI = NO;
    }

    if (!fromUI) {
        NSDictionary *dbg = GlassDebugDict();
        if (dbg) {
            id on = dbg[@"glass_on"];
            if (on && ![on boolValue]) {
                FLOGI(FC_UI, @"[glass] glass_on=0 ⇒ 跳过（一条 hook 都不下）");
                return;
            }
            id t = dbg[@"glass_tier"];
            if (t) {
                int want = [t intValue];
                if (want >= 0 && want <= 4) {
                    gUserTier = want;
                    FLOGI(FC_UI, @"[glass] glass_tier=%d ⇒ 用户定档 %@",
                          want, U8(fdmgp_tier_name(want)));
                }
            }
        }
    }

    /* ① 内核自检（39 条断言） */
    char err[512] = {0};
    int bad = fdmgp_selftest(err, sizeof(err));
    if (bad) {
        FLOGE(FC_UI, @"[glass] 分级内核自检失败 #%d\n%@", bad, U8(err));
        return;
    }
    FLOGI(FC_UI, @"[glass] 分级内核 OK（44 组断言：机型落档/强制档/low-power/滚动/辅助功能）");

    /* ② 设备画像 + 原生材质探测 */
    ProbeDevice();
    ProbeNativeGlass();

    /* ③ 首次决策 */
    InvalidatePlan();
    fdmgp_plan p = FDMGlassCurrentPlan();
    FLOGI(FC_UI, @"[glass] 当前 %@", FDMGlassStatusLine());

    /* ④ 场景通知 */
    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillShowNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        FDMGlassNoteKeyboard(YES);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillHideNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        FDMGlassNoteKeyboard(NO);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIAccessibilityReduceTransparencyStatusDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        InvalidatePlan();
        FLOGW(FC_UI, @"[glass] 辅助功能「降低透明度」变化 ⇒ 重算并重建");
        FDMGlassRefreshAll();
    }];

    /* ⑤ 装 hook（只在真的要玻璃时才装；T0 时一条 hook 都不下）*/
    if (p.tier >= FDMGlassTierHighlight) {
        FDMGlassHookInstall();
    } else {
        FLOGW(FC_UI, @"[glass] 当前档位 %@ ⇒ 不装 hook", U8(fdmgp_tier_name(p.tier)));
    }

    /* ⑥ 帧监测：只有真会开模糊才需要 */
    if (p.tier >= FDMGlassTierBlur) StartFrameWatch();

    /* ⑦ 按钮玻璃：宿主按钮不是 UIVisualEffectView，要另外叠 */
    if (p.tier >= FDMGlassTierHighlight) {
        InstallCellReuseHook();
        StartButtonGlassWatch();
    }

    gGlassEnabled = YES;

    /* ★ 把早期层（didMoveToWindow 捕获的）控件补处理一遍 */
    FDMGlassEarlyFlush();

    FLOGI(FC_UI, @"[glass] 安装完成（%@）", FDMGlassStatusLine());
}

/* ══════════════════════════════════════════════════════════════════════════
 *  ★ 配置热生效：设置页改完立刻按新档位重建
 *
 *  和 Install 时的读开关是同一份逻辑，只是多了一步「档位变了就 SetUserTier」。
 *  关掉（on=0）时要做的是「把所有已挂的装饰层撤掉」而不是「什么都不做」——
 *  否则界面上会留着一堆已经不该存在的玻璃。
 * ══════════════════════════════════════════════════════════════════════════ */

static int GlassTierFromName(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return -1;
    if ([s isEqualToString:@"off"])     return FDMGlassTierOff;
    if ([s isEqualToString:@"light"])   return FDMGlassTierHighlight;
    if ([s isEqualToString:@"blur"])    return FDMGlassTierBlur;
    if ([s isEqualToString:@"refract"]) return FDMGlassTierRefract;
    if ([s isEqualToString:@"native"])  return FDMGlassTierNative;
    return -1;   /* auto 或未知 ⇒ 自动 */
}

void FDMGlassReloadConfig(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ FDMGlassReloadConfig(); });
        return;
    }

    /* ① 读总开关 */
    NSInteger wantTier = -1;
    BOOL on = YES;
    @try {
        FDMConfig *c = [FDMConfig shared];
        on = [c boolFor:@"glass" key:@"on"];
        NSString *tn = [c stringFor:@"glass" key:@"tier"];
        wantTier = GlassTierFromName(tn);
    } @catch (NSException *e) {
        on = YES;
    }

    if (!on) {
        FLOGW(FC_UI, @"[glass] 关掉 ⇒ 撤掉所有装饰层（hook 保留但不干活）");
        gGlassEnabled = NO;
        gUserTier = FDMGlassTierOff;
        gForceTier = 0;
        InvalidatePlan();
        FDMGlassRefreshAll();
        ScanButtonGlass();          /* 把按钮上叠的也撤掉 */
        return;
    }
    gGlassEnabled = YES;

    gUserTier = (wantTier >= 0 && wantTier <= 4) ? (int)wantTier : -1;
    InvalidatePlan();

    fdmgp_plan p = FDMGlassCurrentPlan();
    FLOGI(FC_UI, @"[glass] 配置变更 ⇒ %@（tier=%d）",
          FDMGlassStatusLine(), gUserTier);

    /* ② 之前因为 T0 没装 hook 的话，现在要补上 */
    if (p.tier >= FDMGlassTierHighlight) {
        FDMGlassHookInstall();
        if (p.tier >= FDMGlassTierBlur) StartFrameWatch();
    }

    /* ③ 按钮玻璃（普通控件另走一条）*/
    if (p.tier >= FDMGlassTierHighlight) StartButtonGlassWatch();
    else ScanButtonGlass();     /* T0：撤掉已叠的 */

    /* ④ 重建所有已挂的玻璃 */
    FDMGlassRefreshAll();
}

/* ══════════════════════════════════════════════════════════════════════════
 *  十、★ 给普通控件（非 UIVisualEffectView）加玻璃质感
 *
 *  ══ 为什么需要这一段 ══
 *  真机反馈（2026-10-23）：「手动改成 T3 但按钮没区别」。
 *  查下来两个原因：
 *    ① 用户强制档被硬件上限静默钳到 T2（已在上面的 decide 里修掉）
 *    ② **宿主按钮不是 UIVisualEffectView** —— 它们是普通 UIButton /
 *       自绘视图，而我们原来只对 UIVisualEffectView 生效 ⇒ 完全没碰它们。
 *
 *  ══ 为什么不能直接塞一个 UIVisualEffectView 当底 ══
 *  宿主按钮自己有不透明底色（背景色画在自己身上），
 *  把模糊层放在它下面 ⇒ **被完全盖住，看不见**。
 *  要做成「玻璃」必须让按钮自己的底透出来，但那会改变宿主的配色。
 *
 *  ══ 所以走「叠加式玻璃」══
 *  不改宿主任何背景色，只往按钮上叠两层纯装饰（全部 userInteractionEnabled=NO）：
 *    ① 半透明白色填充（模拟玻璃体）—— 只有 T2+ 才有
 *    ② 边缘高光 + 上亮下暗渐变（模拟厚度与折射）
 *  这样任何按钮都会「看起来像玻璃」，且**不改宿主的排版与颜色语义**。
 *
 *  ══ 安全边界（血的教训：上次 3132 个按钮条）══
 *    · 只在**低频巡检**里做（3 秒一次），绝不 hook layoutSubviews
 *    · 单次巡检**最多处理 40 个**控件（硬上限）
 *    · 每个控件用关联对象做幂等标记，重复巡检只更新参数不叠层
 *    · 跳过：太小的、透明的、我们自己加的（fdm.filecard.bar 里的）
 *    · 关掉（T0）时把叠加层全撤掉
 * ══════════════════════════════════════════════════════════════════════════ */

static char kBtnTintKey;
static char kBtnGlowKey;
static char kBtnHiKey;
static NSTimer *gBtnTimer = nil;
static int gBtnDecorated = 0;          /* 本次巡检计数 */

/* 已经叠过的控件（弱引用，系统回收自动消失）*/
static NSHashTable *gDecoratedSet = nil;

/* ★ 真机反馈（2026-10-23）：「一些提前在模块之前的按钮没有玻璃」
 *   原来是「单次上限 40 个，超了就永远不叠」⇒ 后面那些按钮永远没份。
 *   改成**渐进式**：每轮新增最多 20 个，总数上限 120。
 *   这样启动后几轮内能覆盖全屏，又不会某一轮突然卡住。 */
#define FDM_GLASS_MAX_TOTAL     120
#define FDM_GLASS_MAX_PER_ROUND  20

/** 我们自己加的东西（按钮条里的 chip 等），别再叠玻璃 */
static BOOL IsOurOwnView(UIView *v) {
    UIView *p = v;
    for (int i = 0; i < 6 && p; i++) {
        NSString *aid = p.accessibilityIdentifier ?: @"";
        if ([aid isEqualToString:@"fdm.filecard.bar"]) return YES;
        p = p.superview;
    }
    return NO;
}

/* ══════════════════════════════════════════════════════════════════════════
 *  ★★ 2026-10-23 真机二次反馈（截图）：
 *     ① 「对话名称是空的你也加玻璃」—— 空搜索框被叠了一层大白底
 *     ② 「可变性按钮你说关了但还是加了玻璃」—— 左上角那个圆形按钮
 *
 *  根因：原来的判断是**黑名单**（排除几个类名 + 排除几个关键词），
 *        宿主的自绘控件类名千奇百怪，黑名单永远漏。
 *
 *  ⇒ 改成**白名单 + 内容要求**（宁可少加，绝不多加）：
 *      必须同时满足：
 *        A. 是 UIControl / UIButton（或类名含 Button/Chip）
 *        B. **有可见内容**（文字非空 或 图片非空 或 有可见子视图）
 *        C. **有自己的底**（背景图 / 背景色 alpha>0.25 / 渐变层）
 *        D. 不是圆形（w≈h 且圆角≈半宽）—— 圆形多是图标/可变形按钮
 *      任一条不满足 ⇒ 完全不碰（连高光都不加）
 *
 *  另外加诊断：被跳过的控件会打一行 `[glass] 跳过 <类名> <原因>`，
 *  前 30 条，方便对着屏幕找。
 * ══════════════════════════════════════════════════════════════════════════ */

static int gSkipLogN = 0;

/* ══════════════════════════════════════════════════════════════════════════
 *  ★ 结构诊断：把一个控件的「底到底在哪」完整打出来
 *
 *  为什么需要：DSButton / DSNavigationButton 这些宿主自绘按钮，
 *  我的四层查底全都没抓到（日志显示「无底色」）——
 *  再猜下去就是浪费编译周期。直接把它的真实结构打出来看。
 * ══════════════════════════════════════════════════════════════════════════ */

static int gStructDumpN = 0;

static void DumpViewStructure(UIView *v, int depth) {
    if (!v || depth > 3) return;
    if (gStructDumpN > 120) return;
    gStructDumpN++;

    NSString *ind = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2)
                                      withString:@" " startingAtIndex:0];
    CGRect b = v.bounds;

    UIColor *bg = v.backgroundColor;
    NSString *bgS = @"nil";
    if (bg) {
        CGFloat r=0,g=0,bl=0,a=0;
        if ([bg getRed:&r green:&g blue:&bl alpha:&a]) {
            bgS = [NSString stringWithFormat:@"#%02X%02X%02X/%.2f",
                   (int)(r*255),(int)(g*255),(int)(bl*255),a];
        } else {
            bgS = @"(nonRGB)";
        }
    }

    const char *layBg = "nil";
    CGFloat layA = 0;
    if (v.layer.backgroundColor) {
        layA = CGColorGetAlpha(v.layer.backgroundColor);
        layBg = "set";
    }

    NSInteger grad = 0, imgLayers = 0, shapeMask = 0;
    for (CALayer *l in v.layer.sublayers) {
        if ([l isKindOfClass:[CAGradientLayer class]]) grad++;
        if (l.contents) imgLayers++;
    }
    if ([v.layer.mask isKindOfClass:[CAShapeLayer class]]) shapeMask = 1;

    FLOGD(FC_UI, @"[glass-dump] %@%@ %.0fx%.0f r=%.1f bg=%@ layBg=%s(%.2f) grad=%ld img=%ld mask=%ld subs=%lu",
          ind, NSStringFromClass([v class]),
          b.size.width, b.size.height, v.layer.cornerRadius,
          bgS, layBg, layA, (long)grad, (long)imgLayers, (long)shapeMask,
          (unsigned long)v.subviews.count);

    for (UIView *sv in v.subviews) {
        DumpViewStructure(sv, depth + 1);
    }
}

static void SkipLog(UIView *v, const char *why) {
    if (gSkipLogN >= 30) return;
    gSkipLogN++;
    CGRect b = v.bounds;
    FLOGD(FC_UI, @"[glass] 跳过 %@ %.0fx%.0f（%@）",
          NSStringFromClass([v class]), b.size.width, b.size.height, U8(why));

    /* ★ 对「无底色」的宿主按钮补一次结构 dump —— 我们要看它的底在哪 */
    if (why && strcmp(why, "无底色") == 0 && gStructDumpN < 100) {
        NSString *cn = NSStringFromClass([v class]) ?: @"";
        if ([cn containsString:@"DS"] || [cn containsString:@"Button"]) {
            FLOGD(FC_UI, @"[glass-dump] ── 结构 ──");
            DumpViewStructure(v, 0);
        }
    }
}

/**
 * A. 这个视图像不像「会有点击反馈的 UI 元素」？
 *
 * ★★ 2026-10-23 真机第四次反馈（截图）：设置页那些列表行
 *    （朗读音色 / 检查更新 / 服务协议…）全都没玻璃，只有我们
 *    自己加的那行有。
 *
 *    查日志：跳过名单里**根本没有 UITableViewCell** —— 因为它们
 *    在第一步 `IsControlLike` 就被否了（cell 不是 UIControl）。
 *
 * ⇒ 候选范围扩成四类：
 *    ① UIControl 家族（UIButton / 自绘按钮）
 *    ② UITableViewCell / UICollectionViewCell（列表行）
 *    ③ 类名含 Button / Chip / Cell / Row 的
 *    ④ 「有圆角 + 有底色」的容器视图（宿主的卡片式按钮，如
 *       ReasoningOperationView，它不是 UIControl 但是个胶囊按钮）
 *
 * 仍然排除：开关/滑块/分段控件/滚动视图/文本类，以及过小的。
 */
static BOOL IsGlassCandidate(UIView *v) {
    if (!v) return NO;

    /* ── 排除项（形状会变 / 会自己画）── */
    if ([v isKindOfClass:[UISwitch class]]) return NO;
    if ([v isKindOfClass:[UISlider class]]) return NO;
    if ([v isKindOfClass:[UISegmentedControl class]]) return NO;
    if ([v isKindOfClass:[UIScrollView class]]) return NO;
    if ([v isKindOfClass:[UITextView class]]) return NO;
    if ([v isKindOfClass:[UITextField class]]) return NO;
    if ([v isKindOfClass:[UILabel class]]) return NO;
    if ([v isKindOfClass:[UIImageView class]]) return NO;
    if ([v isKindOfClass:[UIWindow class]]) return NO;
    if ([v isKindOfClass:[UITableView class]]) return NO;
    if ([v isKindOfClass:[UICollectionView class]]) return NO;

    /* 尺寸下限：太小的不处理（分隔线/角标）*/
    CGRect b = v.bounds;
    if (b.size.width < 28 || b.size.height < 18) return NO;

    /* ── ① UIControl 家族 ── */
    if ([v isKindOfClass:[UIControl class]]) return YES;

    /* ── ② 列表行 ── */
    if ([v isKindOfClass:[UITableViewCell class]]) return YES;
    if ([v isKindOfClass:[UICollectionViewCell class]]) return YES;
    if ([v isKindOfClass:[UITableViewHeaderFooterView class]]) return YES;

    /* ── ③ 类名像按钮/行 ── */
    NSString *cn = NSStringFromClass([v class]) ?: @"";
    if (cn.length) {
        if ([cn rangeOfString:@"Button"].location != NSNotFound) return YES;
        if ([cn rangeOfString:@"Chip"].location != NSNotFound) return YES;
        if ([cn rangeOfString:@"Cell"].location != NSNotFound) return YES;
        if ([cn rangeOfString:@"Row"].location != NSNotFound) return YES;
        if ([cn rangeOfString:@"OperationView"].location != NSNotFound) return YES;
        if ([cn rangeOfString:@"Item"].location != NSNotFound &&
            v.layer.cornerRadius > 4) return YES;
    }

    /* ── ④ 有圆角 + 有底色的容器（宿主自绘的胶囊按钮）── */
    if (v.layer.cornerRadius >= 8) {
        if (v.backgroundColor || v.layer.backgroundColor) {
            /* 太高的多半是卡片/面板，不是按钮 */
            if (b.size.height <= 80) return YES;
        }
    }

    return NO;
}

/**
 * B. 有没有可见内容？
 *
 * ★ 「对话名称是空的」那个搜索框：它是个**空容器**，
 *   我们叠的半透明白底直接把整个框变成一个白条 —— 非常难看。
 *   ⇒ 空容器一律跳过。
 */
static BOOL HasVisibleContent(UIView *v, int depth) {
    if (!v || depth > 3) return NO;

    /* 按钮自己的文字/图片 */
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        NSString *t = [b titleForState:UIControlStateNormal];
        if (t.length) return YES;
        if ([b imageForState:UIControlStateNormal]) return YES;
        if ([b backgroundImageForState:UIControlStateNormal]) return YES;
    }
    if ([v isKindOfClass:[UILabel class]]) {
        if (((UILabel *)v).text.length) return YES;
    }
    if ([v isKindOfClass:[UIImageView class]]) {
        if (((UIImageView *)v).image) return YES;
    }

    /* 子视图里有没有可见的文字/图片 */
    for (UIView *sv in v.subviews) {
        if (sv.hidden || sv.alpha < 0.05) continue;
        if ([sv isKindOfClass:[UILabel class]] && ((UILabel *)sv).text.length) return YES;
        if ([sv isKindOfClass:[UIImageView class]] && ((UIImageView *)sv).image) return YES;
        if ([sv isKindOfClass:[UIButton class]]) {
            UIButton *b = (UIButton *)sv;
            if ([b titleForState:UIControlStateNormal].length) return YES;
            if ([b imageForState:UIControlStateNormal]) return YES;
        }
        if (HasVisibleContent(sv, depth + 1)) return YES;
    }

    /* 按钮的 titleLabel / imageView（可能在子视图里但被上面漏掉）*/
    if ([v isKindOfClass:[UIButton class]]) {
        UILabel *tl = ((UIButton *)v).titleLabel;
        if (tl && tl.text.length) return YES;
    }
    return NO;
}

/**
 * C. 有没有自己的底？
 *
 * ★ 「文字按钮文字上盖玻璃」：没底的按钮如果加白底体，
 *   白色会盖在文字上 ⇒ 看着像「文字和边框都成了玻璃」。
 */
/**
 * C. 有没有自己的底？
 *
 * ★★ 2026-10-23 真机三次反馈（截图）：
 *   「设置里面的按钮不一样」—— 宿主设置页那些列表行只有它们没有玻璃，
 *    而「FDM 模块设置」那行（我们自己加的）有。
 *
 *   查日志：`跳过 ... 无底色` 出现 20 次，全是被跳过的 UITableViewCell。
 *
 *   根因：宿主设置行是 UITableViewCell，它的**底色不是 backgroundColor**，
 *        而是 iOS 14+ 的 `UIBackgroundConfiguration`，由内部的
 *        `UISystemBackgroundView` 子视图画出来 ⇒ 我只查 backgroundColor
 *        当然查不到。
 *
 *   ⇒ 现在按「四层」依次找底：
 *      ① backgroundColor / layer.backgroundColor
 *      ② 背景图（UIButton backgroundImage / UITableViewCell backgroundView）
 *      ③ 自己层里的渐变 / 有色的 sublayer
 *      ④ **子视图里有没有一块盖住大半个自己的有色视图**
 *         （UISystemBackgroundView、cell 的 selectedBackgroundView 等）
 */
static BOOL HasOwnBackground(UIView *v) {
    if (!v) return NO;

    /* ① 自己的底色 */
    UIColor *bg = v.backgroundColor;
    if (bg) {
        CGFloat a = 0;
        if ([bg getWhite:NULL alpha:&a] || [bg getRed:NULL green:NULL blue:NULL alpha:&a]) {
            if (a > 0.25) return YES;
        }
    }
    if (v.layer.backgroundColor) {
        if (CGColorGetAlpha(v.layer.backgroundColor) > 0.25) return YES;
    }

    /* ② 背景图 */
    if ([v isKindOfClass:[UIButton class]]) {
        if ([(UIButton *)v backgroundImageForState:UIControlStateNormal]) return YES;
    }
    if ([v isKindOfClass:[UITableViewCell class]]) {
        UITableViewCell *c = (UITableViewCell *)v;
        if (c.backgroundView) return YES;
        if (@available(iOS 14.0, *)) {
            if (c.backgroundConfiguration) return YES;   /* 有配置 ⇒ 会画底色 */
        }
    }
    if ([v isKindOfClass:[UICollectionViewCell class]]) {
        if (@available(iOS 14.0, *)) {
            if (((UICollectionViewCell *)v).backgroundConfiguration) return YES;
        }
    }

    /* ③ 自己层里的渐变 / 有色 sublayer */
    for (CALayer *l in v.layer.sublayers) {
        if ([l isKindOfClass:[CAGradientLayer class]]) return YES;
        if (l.backgroundColor && CGColorGetAlpha(l.backgroundColor) > 0.25) return YES;
    }

    /* ④ ★ 子视图里有没有「盖住大半个自己」的有色块
     *    这一条正是为了抓到 UISystemBackgroundView（设置页列表行的底）。 */
    CGRect mb = v.bounds;
    CGFloat myArea = mb.size.width * mb.size.height;
    if (myArea < 1) return NO;

    for (UIView *sv in v.subviews) {
        if (sv.hidden || sv.alpha < 0.05) continue;

        /* 明显是「背景层」的类名，直接认 */
        NSString *cn = NSStringFromClass([sv class]) ?: @"";
        if ([cn containsString:@"SystemBackground"] ||
            [cn containsString:@"BackgroundView"] ||
            [cn containsString:@"Background"]) {
            /* 但要排除分隔线那种细条 */
            if (sv.bounds.size.height > 8) return YES;
        }

        /* 有色的、且面积占自己 40% 以上 ⇒ 认定为底 */
        CGFloat a = 0;
        BOOL colored = NO;
        UIColor *c = sv.backgroundColor;
        if (c && ([c getRed:NULL green:NULL blue:NULL alpha:&a] ||
                  [c getWhite:NULL alpha:&a]) && a > 0.25) {
            colored = YES;
        }
        if (!colored && sv.layer.backgroundColor &&
            CGColorGetAlpha(sv.layer.backgroundColor) > 0.25) {
            colored = YES;
        }
        if (!colored) continue;

        CGFloat area = sv.bounds.size.width * sv.bounds.size.height;
        if (area / myArea > 0.40) return YES;
    }

    return NO;
}

/**
 * D. 是不是圆形？
 *
 * ★ 「可变性按钮还是加了玻璃」：左上角那个 ≡ 是个圆形按钮，
 *   而且这类按钮往往会在点击时变形（morph），我们按固定形状画的
 *   装饰层一定会露缝 ⇒ 圆形一律跳过。
 */
static BOOL LooksCircular(UIView *v) {
    CGRect b = v.bounds;
    if (b.size.width < 4 || b.size.height < 4) return NO;
    CGFloat ratio = b.size.width / b.size.height;
    if (ratio < 0.82 || ratio > 1.22) return NO;      /* 明显不是正方形 */
    CGFloat r = v.layer.cornerRadius;
    /* 圆角接近半宽 ⇒ 圆形/胶囊 */
    if (r >= b.size.width * 0.42) return YES;
    /* 有圆形 mask path 的 */
    if ([v.layer.mask isKindOfClass:[CAShapeLayer class]]) {
        CAShapeLayer *m = (CAShapeLayer *)v.layer.mask;
        if (m.path) {
            CGRect pb = CGPathGetBoundingBox(m.path);
            CGFloat pr = pb.size.width / (pb.size.height > 0 ? pb.size.height : 1);
            if (pr > 0.82 && pr < 1.22) {
                /* 再看 path 是不是圆弧：粗判为「近似圆」*/
                return YES;
            }
        }
    }
    return NO;
}

/**
 * 按钮自己的轮廓路径。
 * 优先复制 mask path（这样绝不会和按钮形状对不上），
 * 其次用 cornerRadius，最后按形状猜。
 */
static UIBezierPath *OwnShapePath(UIView *v, CGRect b, CGFloat *outRadius) {
    if ([v.layer.mask isKindOfClass:[CAShapeLayer class]]) {
        CAShapeLayer *m = (CAShapeLayer *)v.layer.mask;
        if (m.path && CGPathGetBoundingBox(m.path).size.width > 1) {
            if (outRadius) *outRadius = -1;
            return [UIBezierPath bezierPathWithCGPath:m.path];
        }
    }
    CGFloat r = v.layer.cornerRadius;
    if (r > 0.5) {
        if (outRadius) *outRadius = r;
        return [UIBezierPath bezierPathWithRoundedRect:b cornerRadius:r];
    }
    CGFloat w = b.size.width, h = b.size.height;
    CGFloat guess = (h > 0 && w / h > 2.2) ? h / 2.0 : MIN(10.0, MIN(w, h) / 2.0);
    if (outRadius) *outRadius = guess;
    return [UIBezierPath bezierPathWithRoundedRect:b cornerRadius:guess];
}

/** 综合判断：这个控件该不该叠玻璃？返回 1 = 该叠 */
static BOOL ShouldDecorate(UIView *v, const char **why) {
    if (!IsGlassCandidate(v)) { if (why) *why = "非候选"; return NO; }

    CGRect b = v.bounds;
    if (b.size.width < 28 || b.size.height < 18) { if (why) *why = "太小"; return NO; }
    if (v.hidden || v.alpha < 0.05) { if (why) *why = "不可见"; return NO; }
    if (IsOurOwnView(v)) { if (why) *why = "我们自己的"; return NO; }

    /* ★ 2026-10-23 真机：气泡上被叠了玻璃高光 ⇒ 一圈蓝色光晕。
     *   气泡是「模块自己画的底色」，不需要也不该再叠玻璃。 */
    {
        NSString *bcn = NSStringFromClass([v class]) ?: @"";
        if ([bcn containsString:@"BubbleView"] ||
            [bcn containsString:@"MessageView"] ||
            [bcn containsString:@"MessageCell"]) {
            if (why) *why = "气泡本体"; return NO;
        }
        /* 父链里有两层以上气泡类的，也跳过（气泡内部子视图）*/
        UIView *pv = v.superview;
        for (int i = 0; i < 3 && pv; i++) {
            NSString *pcn = NSStringFromClass([pv class]) ?: @"";
            if ([pcn containsString:@"BubbleView"] && ![pcn containsString:@"User"]) {
                if (why) *why = "气泡内部"; return NO;
            }
            pv = pv.superview;
        }
    }

    if (LooksCircular(v)) { if (why) *why = "圆形/可变形"; return NO; }
    if (!HasVisibleContent(v, 0)) { if (why) *why = "空容器"; return NO; }
    if (!HasOwnBackground(v)) { if (why) *why = "无底色"; return NO; }

    if (why) *why = "ok";
    return YES;
}

/* ══════════════════════════════════════════════════════════════════════════
 *  ★ 2026-10-23 真机第五次反馈：「滑动菜单项停一会又没了，再打开又好了」
 *
 *  根因：UITableView / UICollectionView **复用 cell** 时，宿主会：
 *    ① 重设 backgroundView / backgroundConfiguration
 *    ② 有时直接清 layer.sublayers
 *  ⇒ 我们的装饰 layer 被移除了，但**关联对象还指着它**。
 *    下次 DecorateView 拿到这个孤儿 layer，改它的 frame/colors
 *    —— 它不在树上，改什么都没用 ⇒ 视觉上「玻璃消失了」。
 *    再打开设置页时 cell 是新建的，所以又好了。
 *
 *  ⇒ 修复：**每轮都检查 layer 是否还挂在视图的层树上**，
 *    不在就重新 addSublayer。这个检查很便宜（比较一下 superlayer 指针）。
 * ══════════════════════════════════════════════════════════════════════════ */

/** 确保 layer 还在 v.layer 的子层里；不在就重新挂回去。 */
static void EnsureAttached(UIView *v, CALayer *l, NSInteger z) {
    if (!v || !l) return;
    if (l.superlayer == v.layer) {
        l.zPosition = z;
        return;
    }
    [l removeFromSuperlayer];
    l.zPosition = z;
    [v.layer addSublayer:l];
}

static void RemoveBtnDecor(UIView *v) {
    CALayer *a = objc_getAssociatedObject(v, &kBtnTintKey);
    CALayer *b = objc_getAssociatedObject(v, &kBtnGlowKey);
    CALayer *c = objc_getAssociatedObject(v, &kBtnHiKey);
    if (a) [a removeFromSuperlayer];
    if (b) [b removeFromSuperlayer];
    if (c) [c removeFromSuperlayer];
    objc_setAssociatedObject(v, &kBtnTintKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(v, &kBtnGlowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(v, &kBtnHiKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/**
 * 给一个普通视图叠玻璃质感（幂等）。
 * 只动 layer，不动视图树、不改底色、不抢交互。
 */
static void DecorateView(UIView *v, fdmgp_plan plan) {
    if (!v) return;

    if (plan.tier < FDMGlassTierHighlight) {
        RemoveBtnDecor(v);
        return;
    }

    /* ★ 统一入口判断：内容/底色/圆形/大小 一次过 */
    const char *why = NULL;
    if (!ShouldDecorate(v, &why)) return;

    CGRect b = v.bounds;

    /* ★ 用按钮**自己的形状**（mask path 优先），保证装饰层不出缝 */
    CGFloat r = 0;
    UIBezierPath *shape = OwnShapePath(v, b, &r);
    if (!shape) return;

    CGFloat hA = plan.highlight_alpha;
    if (@available(iOS 13.0, *)) {
        if (v.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) hA *= 0.55;
    }

    /* ★ 纯文字按钮（自己没有底）：不加白色体，只加边缘高光 ——
     *   否则半透明白底会盖在文字上，看起来「文字和边框都是玻璃」。 */
    const BOOL hasOwnBg = HasOwnBackground(v);   /* ShouldDecorate 已保证为真 */

    /* ① 玻璃体（半透明白）—— 只有 T2+ 且按钮自己有底时才加 */
    CALayer *tint = objc_getAssociatedObject(v, &kBtnTintKey);
    BOOL wantTint = (plan.tier >= FDMGlassTierBlur) && hasOwnBg;
    if (wantTint) {
        if (!tint) {
            tint = [CALayer layer];
            [v.layer addSublayer:tint];
            objc_setAssociatedObject(v, &kBtnTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        EnsureAttached(v, tint, 900);
        tint.frame = b;
        tint.backgroundColor = GlassWhite(0.09).CGColor;
        /* 形状：有 mask path 就用 mask，否则用圆角 */
        if (r < 0) {
            CAShapeLayer *m = [CAShapeLayer layer];
            m.path = shape.CGPath;
            m.frame = b;
            tint.mask = m;
            tint.cornerRadius = 0;
            tint.borderWidth = 0;
        } else {
            tint.mask = nil;
            tint.cornerRadius = r;
            tint.cornerCurve = kCACornerCurveContinuous;
            tint.borderWidth = 0.5;
            tint.borderColor = GlassWhite(0.14).CGColor;
        }
    } else if (tint) {
        [tint removeFromSuperlayer];
        objc_setAssociatedObject(v, &kBtnTintKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    /* ② 内部透光（上亮下暗）—— 同样只给有底的按钮 */
    CAGradientLayer *glow = (CAGradientLayer *)objc_getAssociatedObject(v, &kBtnGlowKey);
    if (hasOwnBg && plan.inner_grad_alpha > 0.001) {
        if (!glow) {
            glow = [CAGradientLayer layer];
            glow.startPoint = CGPointMake(0.5, 0.0);
            glow.endPoint = CGPointMake(0.5, 1.0);
            [v.layer addSublayer:glow];
            objc_setAssociatedObject(v, &kBtnGlowKey, glow,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        EnsureAttached(v, glow, 901);
        glow.frame = b;
        glow.colors = @[(id)GlassWhite(plan.inner_grad_alpha).CGColor,
                        (id)GlassWhite(0.0).CGColor,
                        (id)GlassBlack(plan.inner_grad_alpha * 0.35).CGColor];
        glow.locations = @[@0.0, @0.5, @1.0];
        /* 用按钮自己的形状裁剪，圆角/胶囊都对 */
        CAShapeLayer *gm = (CAShapeLayer *)glow.mask;
        if (![gm isKindOfClass:[CAShapeLayer class]]) {
            gm = [CAShapeLayer layer];
            glow.mask = gm;
        }
        gm.path = shape.CGPath;
        gm.frame = b;
    } else if (glow) {
        [glow removeFromSuperlayer];
        objc_setAssociatedObject(v, &kBtnGlowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    /* ③ 边缘高光（所有按钮都有）—— 用按钮形状做 mask，绝不出缝 */
    CAGradientLayer *hi = (CAGradientLayer *)objc_getAssociatedObject(v, &kBtnHiKey);
    if (!hi) {
        hi = [CAGradientLayer layer];
        hi.startPoint = CGPointMake(0.0, 0.0);
        hi.endPoint = CGPointMake(1.0, 1.0);
        [v.layer addSublayer:hi];
        objc_setAssociatedObject(v, &kBtnHiKey, hi, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    EnsureAttached(v, hi, 902);
    hi.frame = b;
    hi.colors = @[(id)GlassWhite(hA).CGColor,
                  (id)GlassWhite(hA * 0.05).CGColor,
                  (id)GlassWhite(hA * 0.45).CGColor];
    hi.locations = @[@0.0, @0.52, @1.0];

    /* 高光遮罩 = 形状路径的**内缩描边**
     *   居中描边会向外溢一半，所以线宽取 2 倍、并用内缩后的路径，
     *   保证高光完整落在按钮轮廓内侧。 */
    CGFloat lw = plan.highlight_width > 0 ? plan.highlight_width : 1.0;
    CAShapeLayer *hm = (CAShapeLayer *)hi.mask;
    if (![hm isKindOfClass:[CAShapeLayer class]]) {
        hm = [CAShapeLayer layer];
        hi.mask = hm;
    }
    hm.frame = b;
    hm.path = shape.CGPath;
    hm.fillColor = nil;
    hm.strokeColor = [UIColor whiteColor].CGColor;
    hm.lineWidth = lw * 2.0;
}

/**
 * 低频巡检：找宿主按钮并叠玻璃。
 *
 * ★ 渐进式覆盖（真机反馈：「一些提前在模块之前的按钮没有玻璃」）
 *   · 已叠过的用 weak 集合记账，每轮只维护它们（更新几何/颜色）
 *   · 新控件每轮最多叠 20 个，总数上限 120
 *   ⇒ 启动后几轮内能覆盖全屏，又不会某一轮突然卡住。
 */
static void ScanButtonGlass(void) {
    extern UIWindow *FDMFindBestWindow(void);
    UIWindow *w = FDMFindBestWindow();
    if (!w) return;

    if (!gDecoratedSet) gDecoratedSet = [NSHashTable weakObjectsHashTable];

    fdmgp_plan plan = FDMGlassCurrentPlan();

    /* T0：把所有已叠的撤掉 */
    if (!gGlassEnabled || plan.tier < FDMGlassTierHighlight) {
        NSArray *all = gDecoratedSet.allObjects;
        for (UIView *v in all) RemoveBtnDecor(v);
        [gDecoratedSet removeAllObjects];
        return;
    }

    gBtnDecorated = 0;
    int added = 0;

    /* ★★ 先处理早期层排进来的（didMoveToWindow 捕获的「刚上屏」控件）。
     *   这批是宿主创建 UI 时我们就记下的，正是之前漏掉的那批。 */
    if (gPendingQueue.count) {
        NSArray *snapshot = [gPendingQueue copy];
        [gPendingQueue removeAllObjects];
        int q = 0;
        for (UIView *v in snapshot) {
            if (q >= FDM_GLASS_MAX_PER_ROUND) {
                /* 本轮处理不完，剩下的下一轮继续（不丢）*/
                [gPendingQueue addObjectsFromArray:
                    [snapshot subarrayWithRange:NSMakeRange(q, snapshot.count - q)]];
                break;
            }
            if (v.window != w) continue;
            if ([gDecoratedSet containsObject:v]) continue;
            const char *whyQ = NULL;
            if (ShouldDecorate(v, &whyQ)) {
                DecorateView(v, plan);
                [gDecoratedSet addObject:v];
                added++;
                gBtnDecorated++;
            }
            q++;
        }
        if (added > 0) {
            FLOGI(FC_UI, @"[glass] 早期队列补处理 %d 个（剩余 %lu）",
                  added, (unsigned long)gPendingQueue.count);
        }
    }

    /* ★ 维护已叠的。
     *   ★★ 关键改动（2026-10-23）：cell 复用时宿主会重设背景，
     *      ShouldDecorate 可能**临时**返回 NO（比如那一刻还没有底），
     *      但我们不该就此放弃它 —— 下一轮它又有底了。
     *   ⇒ 只要它还在树上、尺寸还合理，就**无条件重叠**
     *      （DecorateView 内部幂等，会自己判断要不要加白底体）。
     *   只有「彻底不该有玻璃」的（变成圆形/太小/隐藏）才移除。 */
    NSArray *known = gDecoratedSet.allObjects;
    for (UIView *v in known) {
        if (v.window != w) continue;          /* 滚出屏幕：保留记录，回来再说 */

        CGRect vb = v.bounds;
        BOOL dead = (vb.size.width < 28 || vb.size.height < 18) ||
                    v.hidden || v.alpha < 0.05 || LooksCircular(v);
        if (dead) {
            RemoveBtnDecor(v);
            [gDecoratedSet removeObject:v];
            continue;
        }

        DecorateView(v, plan);
        gBtnDecorated++;
    }

    const int totalKnown = (int)gDecoratedSet.count;

    /* 再补新出现的 —— 每轮限量，避免一次扫太多 */
    NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
    int guard = 0;
    while (stack.count && guard++ < 6000) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];

        if (IsGlassCandidate(v) && ![gDecoratedSet containsObject:v]) {
            const char *why = NULL;
            if (ShouldDecorate(v, &why)) {
                if (added >= FDM_GLASS_MAX_PER_ROUND) break;
                if (totalKnown + added >= FDM_GLASS_MAX_TOTAL) break;
                DecorateView(v, plan);
                [gDecoratedSet addObject:v];
                added++;
                gBtnDecorated++;
            } else if (why && strcmp(why, "ok") != 0 &&
                       strcmp(why, "我们自己的") != 0 &&
                       strcmp(why, "太小") != 0) {
                /* 只记录「值得关注」的跳过原因（空容器/圆形/无底色）*/
                SkipLog(v, why);
            }
        }
        for (UIView *sv in v.subviews) [stack addObject:sv];
    }

    static int lastN = -1;
    if (gBtnDecorated != lastN) {
        lastN = gBtnDecorated;
        FLOGI(FC_UI, @"[glass] 按钮玻璃：已叠 %d 个（本轮新增 %d，上限 %d，tier=%@）",
              gBtnDecorated, added, FDM_GLASS_MAX_TOTAL, U8(fdmgp_tier_name(plan.tier)));
    }
}

static void StartButtonGlassWatch(void) {
    if (gBtnTimer) return;
    ScanButtonGlass();
    /* ★ 2026-10-23：3.0s 太长 —— cell 复用后玻璃会「消失」最多 3 秒，
     *   用户能明显看出来。缩到 1.2s（60fps 下相当于 72 帧），
     *   视觉上基本察觉不到；而且巡检本身很轻（只比较指针 + 改 frame）。 */
    gBtnTimer = [NSTimer scheduledTimerWithTimeInterval:1.2
                                                repeats:YES
                                                  block:^(NSTimer *t) {
        @try { ScanButtonGlass(); }
        @catch (NSException *e) {
            FLOGE(FC_UI, @"[glass] 按钮巡检异常: %@", e.reason);
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:gBtnTimer forMode:NSRunLoopCommonModes];
    FLOGI(FC_UI, @"[glass] 按钮玻璃巡检已启动（1.2s 一次，最多 %d 个）",
          FDM_GLASS_MAX_TOTAL);
}

/* ══════════════════════════════════════════════════════════════════════════
 *  十一、★ 早期注入层的对接点（见 FDMGlassEarly.m）
 *
 *  背景（2026-10-23 主人指出）：
 *    原来 Install 放在 6 秒定时器里 ⇒ 宿主 UI 早就渲染完了，
 *    那批「注入前就存在」的按钮永远拿不到玻璃。
 *    正确做法是：构造函数里就 swizzle UIView.didMoveToWindow，
 *    宿主每创建一个视图上屏，我们立刻知道。
 *
 *  但构造函数里**不能读配置**（碰 Foundation 会死在 dyld 阶段），
 *  所以早期只能「收集」，等 real_init 之后才真正处理。
 *  这两个函数就是两侧的接口。
 * ══════════════════════════════════════════════════════════════════════════ */

/** 给早期层用：总开关是否已经打开（且不是 T0）。 */
int FDMGlassIsEnabled(void) {
    return gGlassEnabled ? 1 : 0;
}

/**
 * 给早期层用：把一个刚上屏的控件排进「待装饰」队列。
 *
 * 为什么不在这里直接画？
 *   didMoveToWindow 时 bounds 可能还是 0（还没布局），
 *   而且会在一个个创建过程中被调用几百次 ——
 *   直接 DecorateView 会做大量无用功。
 *   ⇒ 只入队，等下一次巡检（3s 内）统一处理。
 */
void FDMGlassQueueView(UIView *v) {
    if (!v) return;
    if (!gGlassEnabled) return;

    static char kQueuedKey;
    if (objc_getAssociatedObject(v, &kQueuedKey)) return;   /* 已入队 */
    objc_setAssociatedObject(v, &kQueuedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (!gPendingQueue) gPendingQueue = [NSMutableArray array];
    if (gPendingQueue.count < 300) {                        /* 硬上限 */
        [gPendingQueue addObject:v];
    }
}

/* ══════════════════════════════════════════════════════════════════════════
 *  十二、★ cell 复用即时补叠（hook prepareForReuse）
 *
 *  真机反馈（2026-10-23 第六次）：「滑动后还是会消失，但恢复很快」。
 *  ⇒ EnsureAttached + 1.2s 巡检让恢复变快了，但**消失窗口仍然存在**，
 *    因为补叠要等下一轮巡检。
 *
 *  cell 复用的时间线：
 *    scrollView 滚动 → cell 出屏 → prepareForReuse（宿主清背景）
 *    → 重新 configure（宿主设新内容/背景）→ layoutSubviews → 上屏
 *
 *  最佳补叠点：**prepareForReuse 之后、configure 之前**只能清不能叠
 *  （那时还没内容）；所以正确做法是：
 *    prepareForReuse 里记一笔「这个 cell 需要重叠」，
 *    然后 dispatch_async 到主队列（等宿主 configure + layout 走完），
 *    立刻 DecorateView —— 零延迟，不用等巡检。
 *
 *  频率：滑动时每个被复用的 cell 一次，远低于 layoutSubviews。
 * ══════════════════════════════════════════════════════════════════════════ */

static void FDMGlassReapplySoon(UIView *v) {
    if (!v) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!gGlassEnabled) return;
            if (!v.window) return;                 /* 已经被丢弃 */
            if (![gDecoratedSet containsObject:v]) return;
            fdmgp_plan plan = FDMGlassCurrentPlan();
            if (plan.tier < FDMGlassTierHighlight) return;
            DecorateView(v, plan);
        } @catch (NSException *e) { }
    });
}

static void HookCellReuse(Class cls) {
    if (!cls) return;
    static char kMark;
    if (objc_getAssociatedObject(cls, &kMark)) return;
    objc_setAssociatedObject(cls, &kMark, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    SEL sel = @selector(prepareForReuse);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    IMP orig = method_getImplementation(m);
    IMP mine = imp_implementationWithBlock(^(id self) {
        /* 先让宿主清理（它会把背景/子视图重置）*/
        @try { ((void (*)(id, SEL))orig)(self, sel); } @catch (NSException *e) { }

        /* 我们的装饰层可能刚被清掉了 —— 记下来，等 configure 完立刻补 */
        UIView *v = (UIView *)self;
        FDMGlassReapplySoon(v);
    });
    method_setImplementation(m, mine);
}

static BOOL gCellHookDone = NO;

static void InstallCellReuseHook(void) {
    if (gCellHookDone) return;
    gCellHookDone = YES;

    HookCellReuse([UITableViewCell class]);
    HookCellReuse([UICollectionViewCell class]);
    HookCellReuse([UITableViewHeaderFooterView class]);

    FLOGI(FC_UI, @"[glass] 已 hook cell prepareForReuse（复用后即时补叠）");
}
