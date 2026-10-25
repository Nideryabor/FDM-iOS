// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMMap271.m —— 宿主 2.7.1 锚点重测绘器（纯运行时，零类名依赖）
//
// ═══════════════════════════════════════════════════════════════════════════
//  为什么需要这个文件
//
//  2026-10-24 主人把宿主升到了 **2.7.1**，它做了两件很严重的事：
//
//    ① Swift 类名全部剥离：
//         _TtC13DeepSeek_Chat    2.6.2: 534  →  2.7.1: 0
//         DeepSeek_Chat.         2.6.2: 273  →  2.7.1: 0
//         .swift                 2.6.2: 457  →  2.7.1: 0
//       ⇒ 我原先靠「字符串里找 AgentMessageCell / AgentFragmentsView」
//         定位锚点的办法 **全部失效**。
//
//    ② 助手头像类名（AvatarView / InnerAvatarView）也搜不到了。
//
//  但 `__objc_classlist` 还在（12840 字节）⇒ 类运行时仍然存在，只是名字
//  不再以明文躺在文件里。所以只能**跑起来看**。
//
//  ══════════════════════════════════════════════════════════════════════════
//  测绘策略：不认名字，认**结构**
//
//  上一版 dump 出来的 AI 气泡骨架（docs/37 §2.1）：
//
//     AgentMessageCell        414x303   bg=#0F0F0F
//       └─ UIView
//          └─ AgentMessageView
//             └─ UIView (16,12)
//                └─ UIView (8,0)
//                   ├─ AgentFragmentsView   ← 文字容器（全高）
//                   └─ AgentMessageOperationBar  ← 按钮条
//
//  用户侧：
//     UserRequestBubbleView   414x72
//       └─ UserBubbleView     300x72 @x=93.7   ← 气泡本体
//          ├─ UIView (16,10)
//          │  └─ RequestFragmentView  ← 文字
//          └─ UserMessageFoldButton
//
//  ⇒ 这些**结构特征**（层级、padding、有文字、有按钮条、右对齐）不会因为
//    改个类名就消失。所以按结构特征反查类名，再输出「新名字 ↔ 旧角色」的对照表。
//
//  输出：Documents/fdm-map271.txt
// ═══════════════════════════════════════════════════════════════════════════

#import <UIKit/UIKit.h>
#import <stdarg.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

#import "FLog.h"
#import "FDMConfig.h"

#pragma mark - 文件输出

static NSMutableString *gOut = nil;

static NSString *MapFilePath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES).firstObject;
    return docs ? [docs stringByAppendingPathComponent:@"fdm-map271.txt"] : nil;
}

static void MAP(NSString *fmt, ...) {
    if (!gOut) gOut = [NSMutableString stringWithCapacity:65536];
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [gOut appendString:s];
    [gOut appendString:@"\n"];
}

static void MapFlush(BOOL first) {
    NSString *p = MapFilePath();
    if (!p || !gOut.length) return;
    NSError *err = nil;
    if (first || ![[NSFileManager defaultManager] fileExistsAtPath:p]) {
        [gOut writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:&err];
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0644}
                                         ofItemAtPath:p error:nil];
    } else {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (fh) {
            @try {
                [fh seekToEndOfFile];
                [fh writeData:[gOut dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            } @catch (NSException *e) { }
        }
    }
    gOut = nil;
}

#pragma mark - 结构特征判定

static BOOL HasTextLike(UIView *v, int maxDepth) {
    if (!v) return NO;
    if ([v isKindOfClass:[UITextView class]]) return YES;
    if ([v isKindOfClass:[UILabel class]]) return YES;
    if (maxDepth <= 0) return NO;
    for (UIView *sv in v.subviews) {
        if (HasTextLike(sv, maxDepth - 1)) return YES;
    }
    return NO;
}

/** 这棵树里有没有 UITextView（消息正文一定是 UITextView 系的）。 */
static BOOL HasTextView(UIView *v, int maxDepth) {
    if (!v) return NO;
    if ([v isKindOfClass:[UITextView class]]) return YES;
    if (maxDepth <= 0) return NO;
    for (UIView *sv in v.subviews) {
        if (HasTextView(sv, maxDepth - 1)) return YES;
    }
    return NO;
}

/** 找最深的那个 UITextView（用于量文字区尺寸）。 */
static UITextView *DeepestTextView(UIView *v, int maxDepth) {
    if (!v) return nil;
    if ([v isKindOfClass:[UITextView class]]) return (UITextView *)v;
    if (maxDepth <= 0) return nil;

    UITextView *best = nil;
    CGFloat bestArea = 0;
    for (UIView *sv in v.subviews) {
        UITextView *t = DeepestTextView(sv, maxDepth - 1);
        if (t) {
            CGFloat a = t.bounds.size.width * t.bounds.size.height;
            if (a > bestArea) { best = t; bestArea = a; }
        }
    }
    return best;
}

#pragma mark - 节点描述

static NSString *Desc(UIView *v) {
    CGRect b = v.bounds;
    NSString *bg = @"nil";
    UIColor *c = v.backgroundColor;
    if (c) {
        CGFloat r = 0, g = 0, bl = 0, a = 0;
        if ([c getRed:&r green:&g blue:&bl alpha:&a]) {
            bg = [NSString stringWithFormat:@"#%02X%02X%02X/%.2f",
                  (int)(r * 255), (int)(g * 255), (int)(bl * 255), a];
        }
    }
    return [NSString stringWithFormat:@"%@ %.0fx%.0f corner=%.1f bg=%@ clip=%d subs=%lu",
            NSStringFromClass([v class]), b.size.width, b.size.height,
            v.layer.cornerRadius, bg, v.clipsToBounds ? 1 : 0,
            (unsigned long)v.subviews.count];
}

#pragma mark - 一次完整测绘

static int gDumpBudget = 3;

static void MapOneMessage(UIView *cell, NSString *tag) {
    if (!cell) return;

    MAP(@"");
    MAP(@"════════════════════════════════════════════════════════════════");
    MAP(@"[%@] %@   bounds=%.0fx%.0f", tag,
        NSStringFromClass([cell class]),
        cell.bounds.size.width, cell.bounds.size.height);
    MAP(@"════════════════════════════════════════════════════════════════");

    /* ── ① 沿链路往下走，每层都记录「类名 + 尺寸」 ── */
    MAP(@"");
    MAP(@"── ① 向下逐层（只走单子视图链，遇到分叉记录所有分支）──");

    NSMutableArray *stack = [NSMutableArray arrayWithObject:@[cell, @0]];
    int guard = 0;

    while (stack.count && guard++ < 60) {
        NSArray *pair = stack.lastObject;
        [stack removeLastObject];
        UIView *v = pair[0];
        int depth = [pair[1] intValue];

        NSMutableString *ind = [NSMutableString string];
        for (int i = 0; i < depth; i++) [ind appendString:@"  "];

        BOOL isTV = [v isKindOfClass:[UITextView class]];
        MAP(@"%@%@%@", ind, Desc(v), isTV ? @"   ★UITextView" : @"");

        /* 递归子视图（最多 5 层）*/
        if (depth < 5) {
            for (UIView *sv in v.subviews) {
                [stack addObject:@[sv, @(depth + 1)]];
            }
        }
    }

    /* ── ② 找「文字容器」：有 UITextView 的最小子树根 ── */
    MAP(@"");
    MAP(@"── ② 文字容器链（从 cell 到 UITextView 的每一层）──");

    UITextView *tv = DeepestTextView(cell, 8);
    if (tv) {
        MAP(@"最深 UITextView: %@  bounds=%.0fx%.0f",
            NSStringFromClass([tv class]),
            tv.bounds.size.width, tv.bounds.size.height);

        NSMutableArray *chain = [NSMutableArray array];
        UIView *cur = tv;
        while (cur && cur != cell.superview) {
            [chain insertObject:cur atIndex:0];
            if (cur == cell) break;
            cur = cur.superview;
        }
        for (UIView *v in chain) {
            CGRect inCell = [v convertRect:v.bounds toView:cell];
            MAP(@"  %@  inCell=(%.0f,%.0f %.0fx%.0f)",
                NSStringFromClass([v class]),
                inCell.origin.x, inCell.origin.y,
                inCell.size.width, inCell.size.height);
        }
    } else {
        MAP(@"  ✗ 没找到 UITextView");
    }

    /* ── ③ 找「按钮条」：高 30~40、宽接近满宽、不含文字的视图 ── */
    MAP(@"");
    MAP(@"── ③ 疑似按钮条（h 28~44 且不含文字）──");
    {
        NSMutableArray *s2 = [NSMutableArray arrayWithObject:cell];
        int g2 = 0;
        while (s2.count && g2++ < 200) {
            UIView *v = s2.lastObject;
            [s2 removeLastObject];
            CGFloat h = v.bounds.size.height;
            CGFloat w = v.bounds.size.width;
            if (h >= 28 && h <= 44 && w > cell.bounds.size.width * 0.5 &&
                v != cell && !HasTextLike(v, 2)) {
                CGRect r = [v convertRect:v.bounds toView:cell];
                MAP(@"  %@  inCell=(%.0f,%.0f %.0fx%.0f)",
                    NSStringFromClass([v class]),
                    r.origin.x, r.origin.y, r.size.width, r.size.height);
            }
            for (UIView *sv in v.subviews) [s2 addObject:sv];
        }
    }

    /* ── ④ 全 ivar 表（找 bubbleBox / fragments / avatar 之类） ── */
    MAP(@"");
    MAP(@"── ④ ivar 表（只列 UIView 类型且值非 nil 的）──");
    {
        unsigned int n = 0;
        Ivar *ivs = class_copyIvarList([cell class], &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *nm = ivar_getName(ivs[i]);
            const char *tp = ivar_getTypeEncoding(ivs[i]);
            if (!nm || !tp) continue;
            MAP(@"  %s   type=%s", nm, tp);

            if (tp[0] == '@') {
                id obj = nil;
                @try { obj = object_getIvar(cell, ivs[i]); } @catch (NSException *e) { }
                if (obj) {
                    MAP(@"      → %@", NSStringFromClass([obj class]));
                }
            }
        }
        if (ivs) free(ivs);
    }

    /* ── ⑤ 方法表里跟 layout / bubble / avatar 有关的 ── */
    MAP(@"");
    MAP(@"── ⑤ 方法名（全量，便于找特征）──");
    {
        unsigned int n = 0;
        Method *ms = class_copyMethodList([cell class], &n);
        NSMutableString *m = [NSMutableString string];
        for (unsigned int i = 0; i < n; i++) {
            [m appendFormat:@"%s  ", sel_getName(method_getName(ms[i]))];
        }
        if (ms) free(ms);
        MAP(@"%@", m.length ? m : @"(无)");
    }

    MAP(@"");
    MAP(@"════════════════════════════════════════════════════════════════");
}

#pragma mark - 全类表枚举（找候选容器）

static void MapAllCandidateClasses(void) {
    MAP(@"");
    MAP(@"############################################################");
    MAP(@"#  A. UIView 子类清单（纯 C 遍历继承链，绝不发消息）");
    MAP(@"############################################################");

    int n = objc_getClassList(NULL, 0);
    if (n <= 0) { MAP(@"  objc_getClassList 返回 0"); return; }
    Class *buf = (Class *)malloc(sizeof(Class) * (size_t)n);
    if (!buf) { MAP(@"  malloc 失败"); return; }
    n = objc_getClassList(buf, n);
    MAP(@"  运行时类总数: %d", n);

    Class uiview = [UIView class];
    int viewCount = 0, dsCount = 0;

    for (int i = 0; i < n; i++) {
        Class c = buf[i];
        if (!c) continue;

        /* ★ 纯 C 走继承链：只比较 Class 指针，绝不 [c isKindOfClass:] / [c isSubclassOfClass:] */
        BOOL isView = NO;
        Class cur = class_getSuperclass(c);
        int hop = 0;
        while (cur && hop++ < 40) {
            if (cur == uiview) { isView = YES; break; }
            cur = class_getSuperclass(cur);
        }
        if (!isView) continue;
        viewCount++;

        const char *nm = class_getName(c);
        if (!nm) continue;
        NSString *cn = @(nm);

        /* 只记录「名字里带 DeepSeek / TtC / Chat」的，别的都是系统类 */
        BOOL likelyDS = [cn containsString:@"DeepSeek"] ||
                        [cn containsString:@"TtC"] ||
                        [cn containsString:@"Chat"];
        if (!likelyDS) continue;
        dsCount++;

        MAP(@"");
        MAP(@"[CLASS] %@", cn);

        /* ivar 表（class_copyIvarList 是纯 C，安全）*/
        unsigned int ivn = 0;
        Ivar *ivs = class_copyIvarList(c, &ivn);
        NSMutableString *ivstr = [NSMutableString string];
        for (unsigned int k = 0; k < ivn && k < 30; k++) {
            const char *in = ivar_getName(ivs[k]);
            if (in) [ivstr appendFormat:@"%s ", in];
        }
        if (ivs) free(ivs);
        if (ivstr.length) MAP(@"   ivars: %@", ivstr);

        /* 方法表（纯 C）*/
        unsigned int mn = 0;
        Method *ms = class_copyMethodList(c, &mn);
        NSMutableString *mstr = [NSMutableString string];
        for (unsigned int k = 0; k < mn && k < 60; k++) {
            const char *sn = sel_getName(method_getName(ms[k]));
            if (sn) [mstr appendFormat:@"%s ", sn];
        }
        if (ms) free(ms);
        if (mstr.length) MAP(@"   methods: %@", mstr);
    }
    free(buf);

    MAP(@"");
    MAP(@"#  统计：View 子类 %d 个，名字像 DeepSeek 的 %d 个", viewCount, dsCount);
}

#pragma mark - 入口

/**
 * 一次测绘：等界面稳定后，把消息 cell 的结构全 dump 出来。
 * 开关：fdm-debug.json 里 {"map271": true}
 */
static void MapTick(void) {
    if (gDumpBudget <= 0) return;

    @try {
        extern UIWindow *FDMFindBestWindow(void);
        UIWindow *w = FDMFindBestWindow();
        if (!w) return;

        /* 找「含有 UITextView 且高度 > 40」的 cell 类实例 */
        NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
        int guard = 0;
        UIView *mine = nil, *theirs = nil;

        while (stack.count && guard++ < 3000) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];

            if (v.bounds.size.width > 200 && v.bounds.size.height > 40) {
                BOOL hasTV = HasTextView(v, 4);
                if (hasTV) {
                    /* 判断是不是「消息 cell 级别」：它的父视图里还有别的 cell */
                    BOOL parentIsList = NO;
                    UIView *p = v.superview;
                    if (p && p.subviews.count >= 2) parentIsList = YES;

                    if (parentIsList) {
                        /* 用有没有按钮条/多个子视图来区分「我」和「对方」 */
                        if (!theirs && v.bounds.size.width > 300) theirs = v;
                        else if (!mine) mine = v;
                    }
                }
            }
            for (UIView *sv in v.subviews) [stack addObject:sv];
        }

        if (mine) {
            gDumpBudget--;
            MapOneMessage(mine, @"候选A（宽 >300）");
            MapFlush(gDumpBudget == 2);
        }
        if (theirs) {
            gDumpBudget--;
            MapOneMessage(theirs, @"候选B");
            MapFlush(NO);
        }

        if (gDumpBudget <= 0) {
            FLOGI(FC_UI, @"[map271] 测绘完成 → fdm-map271.txt");
        }
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[map271] 异常: %@", e.reason);
    }
}

void FDMMap271Install(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ FDMMap271Install(); });
        return;
    }

    BOOL on = NO;
    @try {
        on = [[FDMConfig shared] boolFor:@"debug" key:@"map271"];
    } @catch (NSException *e) { }

    if (!on) {
        FLOGI(FC_UI, @"[map271] 关着（fdm-debug.json 里 map271=true 才开）");
        return;
    }

    /* 类清单先写一份（不等界面）*/
    MapAllCandidateClasses();
    MapFlush(YES);

    gDumpBudget = 3;

    /* 每 1.5s 试一次，找到消息就 dump */
    static NSTimer *timer = nil;
    if (timer) return;
    timer = [NSTimer scheduledTimerWithTimeInterval:1.5
                                            repeats:YES
                                              block:^(NSTimer *t) {
        MapTick();
        if (gDumpBudget <= 0) [t invalidate];
    }];

    FLOGI(FC_UI, @"[map271] ★ 2.7.1 锚点测绘启动（零类名依赖，纯结构特征）");
}
