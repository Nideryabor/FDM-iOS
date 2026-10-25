// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMGlassEarly.m —— ★★ 早期注入层：在宿主创建任何 UI 之前就把 hook 装好
//
// ═══════════════════════════════════════════════════════════════════════════
//  ★ 为什么要这一层（2026-10-23 主人指出的架构问题）
//
//  原来的流程：
//    dyld 加载 dylib → 宿主 main() → 宿主创建全部 UI → 渲染完成
//                                    → 3.5s 我们 fdm_real_init
//                                    → 6s 我们才装 hook          ← 太晚了
//
//  ⇒ 结果：宿主「注入前就存在」的那些按钮永远拿不到玻璃（其实根本没有
//    「注入前」—— TrollFools 的 dylib 是进程启动就加载的，
//     只是**我们自己**拖到 6 秒才装 hook）。
//
//  正确流程（三阶段）：
//
//    ① 构造函数（dyld 阶段，早于 main）
//       · 只 swizzle，不做任何业务逻辑
//       · 纯 objc runtime + C 数组，**不碰 Foundation**
//       · hook 里只做一件事：把新出现的控件指针塞进缓冲区
//
//    ② fdm_real_init（3.5s，Foundation 就绪）
//       · 读配置、建索引
//       · 把缓冲区的控件补处理一遍（那时它们可能还没布局，先记账）
//
//    ③ 之后的增量
//       · didMoveToWindow 继续捕获
//       · 每轮巡检只处理「新学到的」+ 维护已处理的
//
//  ⚠️ 铁律：构造函数里绝不能调用 Foundation（NSString/NSArray/NSLog…），
//     只能 objc_getClass + method_setImplementation + C 数组。
// ═══════════════════════════════════════════════════════════════════════════
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <string.h>

#import "FDMGlass.h"
#import "FLog.h"

/* ══════════════════════════════════ 早期缓冲区 ══════════════════════════════════ */
/*
 *  刻意用**定长 C 数组 + 手写锁**：
 *   · 定长：构造函数里不能 malloc 失败就崩（虽然 malloc 可用，但不想冒这个险）
 *   · 手写自旋锁：os_unfair_lock 也可以，但这里临界区极短，自旋更省
 *   · 满了就丢最旧的 —— 早期控件数量不会超过 512（正常首页几十个）
 */
#define FDM_EARLY_CAP 512

static UIView *__unsafe_unretained gEarlyBuf[FDM_EARLY_CAP];
static volatile int gEarlyCount = 0;
static volatile int gEarlyLock = 0;      /* 自旋锁 */
static volatile int gEarlyReady = 0;     /* 0 = 只收集；1 = 可以实时处理 */
static volatile int gEarlyInstalled = 0;

static inline void early_lock(void) {
    while (__sync_lock_test_and_set(&gEarlyLock, 1)) {
        /* 自旋：临界区只有几条指令 */
    }
}
static inline void early_unlock(void) {
    __sync_lock_release(&gEarlyLock);
}

/** 往缓冲区塞一个控件（满了丢最旧的一半，避免数组永远满）。 */
static void early_push(UIView *v) {
    if (!v) return;
    early_lock();
    if (gEarlyCount >= FDM_EARLY_CAP) {
        /* 丢弃前一半，把后一半往前挪（早期控件通常已经不在树上了）*/
        int keep = FDM_EARLY_CAP / 2;
        memmove(gEarlyBuf, gEarlyBuf + (FDM_EARLY_CAP - keep),
                sizeof(UIView *) * (size_t)keep);
        gEarlyCount = keep;
    }
    gEarlyBuf[gEarlyCount++] = v;
    early_unlock();
}

/* ══════════════════════════════════ hook：didMoveToWindow ══════════════════════════════════ */
/*
 *  为什么选这个方法：
 *   · 每个视图「上屏」时必调一次 —— 这正是我们想知道的时机
 *   · 比 layoutSubviews 少得多（layout 每帧都可能调）
 *   · 比 init 晚一点，那时 window 已经有了，能判断「是否真的显示」
 */
static IMP gOrigDidMoveToWindow = NULL;

static void fdm_earlyDidMoveToWindow(UIView *self, SEL _cmd) {
    /* 必须先调原实现，否则宿主布局会坏。
     * ⚠️ gOrigDidMoveToWindow 可能为 NULL（极端情况）—— 那时只能跳过，
     *    宁可丢一次原实现，也不要因为空指针崩整个 App。 */
    if (gOrigDidMoveToWindow) {
        @try {
            ((void (*)(id, SEL))gOrigDidMoveToWindow)(self, _cmd);
        } @catch (NSException *e) { }
    }

    if (gEarlyReady) {
        /* 已就绪：直接交给实时处理（内部只做很轻的判断）*/
        FDMGlassEarlyHandleView(self);
    } else {
        /* 未就绪：只记账。
         * ★ 这里**只判断是不是 UIControl**（一条 isKindOfClass，很便宜），
         *   不满足的直接丢 —— 否则 512 的缓冲会被一堆容器/CALayer 视图占满，
         *   真正要处理的按钮反而被挤掉。 */
        const char *cn = object_getClassName(self) ?: "";
        if ([self isKindOfClass:[UIControl class]] ||
            [self isKindOfClass:[UITableViewCell class]] ||
            [self isKindOfClass:[UICollectionViewCell class]] ||
            strstr(cn, "Button") != NULL ||
            strstr(cn, "Chip") != NULL ||
            strstr(cn, "Cell") != NULL) {
            early_push(self);
        }
    }
}

/* ══════════════════════════════════ 安装（构造函数里调）══════════════════════════════════ */

/**
 * 在构造函数里调用。
 *
 * ⚠️ 只做 swizzle，绝不碰 Foundation：
 *    用 objc_getClass（不是 NSClassFromString）、method_setImplementation、
 *    imp 直接调用 —— 全部是 objc runtime 层，dyld 阶段就可用。
 */
/**
 * 真正的 swizzle（必须在 runtime 完全就绪后调）。
 *
 * ★★ 2026-10-23 崩溃复盘（在构造函数里直接 swizzle 导致注入瞬间崩）：
 *
 *   坑 1：`method_getImplementation(class_getInstanceMethod(uiview, sel))`
 *         如果 UIView **自己没有**实现 didMoveToWindow，拿到的是**父类**
 *         （UIResponder）的 Method 对象 ⇒ `method_setImplementation`
 *         改的是**父类的方法表** ⇒ 所有 UIResponder 子类（包括 UIKit 内部
 *         的私有类）都会走到我们的 IMP ⇒ 立刻崩。
 *
 *   坑 2：构造函数（dyld 阶段）里 UIKit 可能还没完成类的 realize，
 *         此时动它的方法表也可能崩。
 *
 *   ⇒ 现在的做法：
 *      ① 用 `class_addMethod` 先尝试**只在本类**加一个方法；
 *         成功 = 本类原来没有 ⇒ 已达成覆盖，orig 用 super 的实现
 *         失败 = 本类原来有 ⇒ 才用 method_setImplementation
 *      ② swizzle 本身延后到「第一个 runloop」，那时 main 已启动、
 *         runtime 完全就绪，但**宿主还没开始建 UI**（UI 创建排在后面）
 */
static void fdm_doSwizzle(void) {
    Class uiview = objc_getClass("UIView");
    if (!uiview) return;

    SEL sel = sel_registerName("didMoveToWindow");
    Method m = class_getInstanceMethod(uiview, sel);
    if (!m) return;

    IMP cur = method_getImplementation(m);
    if (cur == (IMP)fdm_earlyDidMoveToWindow) return;   /* 已装过 */

    const char *types = method_getTypeEncoding(m);

    /* ① 先试「只在本类加方法」（不会污染父类）*/
    IMP superImp = class_getMethodImplementation(class_getSuperclass(uiview), sel);
    if (class_addMethod(uiview, sel, (IMP)fdm_earlyDidMoveToWindow, types)) {
        /* 加成功：说明 UIView 原本没实现，转发时调父类 */
        gOrigDidMoveToWindow = superImp;
        return;
    }

    /* ② 本类已有实现 ⇒ 直接换 */
    gOrigDidMoveToWindow = cur;
    method_setImplementation(m, (IMP)fdm_earlyDidMoveToWindow);
}

/**
 * 在构造函数里调用 —— **只登记，不 swizzle**。
 *
 * 为什么要延后到第一个 runloop：
 *   · 构造函数阶段 UIKit 可能未就绪（类还没 realize），动方法表会崩
 *   · dispatch_async 到主队列 ≈ main() 刚起来、宿主还没建 UI，
 *     比原来的 6 秒早得多，仍然满足「宿主渲染前」的要求
 */
void FDMGlassEarlyInstall(void) {
    if (gEarlyInstalled) return;
    gEarlyInstalled = 1;

    /* 只登记一个主队列任务；真正 swizzle 在里面做（带异常保护）
     *  UIKit 若还没加载，隔 0.05s 重试，最多 40 次（2 秒） */
    static int tries = 0;
    static void (^retry)(void) = nil;
    if (!retry) {
        retry = ^{
            @try {
                if (!objc_getClass("UIView")) {
                    if (++tries < 40) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                        (int64_t)(0.05 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), retry);
                    }
                    return;
                }
                fdm_doSwizzle();
            } @catch (NSException *e) {
                /* 早期阶段 FLog 可能还没初始化，先不写日志 */
            }
        };
    }
    dispatch_async(dispatch_get_main_queue(), retry);
}

/* ══════════════════════════════════ 交接：早期缓冲 → 实时处理 ══════════════════════════════════ */

/**
 * 配置就绪后调用（fdm_real_init 的 6s 阶段）。
 * 把缓冲区里的控件全部补处理一遍，然后切到实时模式。
 */
int FDMGlassEarlyFlush(void) {
    gEarlyReady = 1;

    early_lock();
    int n = gEarlyCount;
    gEarlyCount = 0;
    early_unlock();

    if (n <= 0) {
        FLOGI(FC_UI, @"[glass-early] 无早期控件需要补处理");
        return 0;
    }

    int done = 0;
    for (int i = 0; i < n; i++) {
        UIView *v = gEarlyBuf[i];
        if (!v) continue;
        @try {
            if (FDMGlassEarlyHandleView(v)) done++;
        } @catch (NSException *e) {
        }
    }
    if (FDMGlassIsEnabled()) {
        FLOGI(FC_UI, @"[glass-early] 补处理 %d/%d 个早期控件", done, n);
    }
    return done;
}

/* ══════════════════════════════════ 单个控件的实时处理 ══════════════════════════════════ */

/**
 * 处理一个「刚上屏」的视图。
 *
 * 由两处调用：
 *   · didMoveToWindow hook（实时）
 *   · FDMGlassEarlyFlush（补处理早期缓冲）
 *
 * ★ 这里必须**极轻** —— 它在每次视图上屏时都会跑。
 *   真正的判断（ShouldDecorate）和绘制（DecorateView）都在 FDMGlass.m，
 *   这里只做「要不要把它们排队」这一步。
 *
 * @return 1 = 交给后续处理了
 */
int FDMGlassEarlyHandleView(UIView *v) {
    if (!v) return 0;

    /* 总开关没开就当没装（一行判断，零开销）*/
    if (!FDMGlassIsEnabled()) return 0;

    /* 快速筛选：只有控件才值得排队（避免每个 UIView 都进队列）*/
    if (![v isKindOfClass:[UIControl class]]) {
        const char *cn = object_getClassName(v);
        if (!cn) return 0;
        BOOL ok = strstr(cn, "Button") || strstr(cn, "Chip") ||
                  strstr(cn, "Cell") || strstr(cn, "Row");
        if (!ok && ![v isKindOfClass:[UITableViewCell class]] &&
            ![v isKindOfClass:[UICollectionViewCell class]]) {
            return 0;
        }
    }

    FDMGlassQueueView(v);
    return 1;
}
