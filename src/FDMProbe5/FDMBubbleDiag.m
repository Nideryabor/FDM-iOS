// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMBubbleDiag.m —— 对话气泡「纯诊断模式」
//
// ═══════════════════════════════════════════════════════════════════════════
//  为什么要有这个文件
//
//  2026-10-23 那一轮，气泡上花了 12 个版本，全跪。
//  复盘（docs/36）的结论只有一句：
//
//      **我从来没有先把「气泡到底应该多大」弄清楚，就动手了。**
//
//  所以这个文件只做一件事：**把真相打出来，一个字都不改。**
//
//    · 不碰 backgroundColor / cornerRadius / mask / 任何 layer
//    · 不 addSubview / removeFromSuperview
//    · 不 swizzle 任何东西
//
//  开关：fdm-bubble.json 里 {"diag": true}
//  输出：Documents/fdm-bubble-geom.txt
//
// ═══════════════════════════════════════════════════════════════════════════
//  ★★ 2026-10-24 血案：第一版用 hook layoutSubviews 读 TextKit ⇒ SIGBUS ×2
//
//  第一版在 layoutSubviews 末尾调 `[layoutManager usedRectForTextContainer:]`。
//  而宿主在 `setAttributedText:` 里（[strip] 日志刚打完字）——此时
//  textStorage 的长度和 layoutManager 的 glyph 数**不一致**，
//  usedRect 内部按 glyph 索引访问 ⇒ 越界 ⇒ SIGBUS=10。
//
//  两次崩溃，dump 文件一个字节都没写出来。
//
//  ⇒ 现在的做法：**一次 hook 都不下**。
//    改成 NSTimer 每 0.8s 巡检（跟玻璃那套一样），
//    巡检跑在主 runloop 上，那时 setAttributedText 早已返回、
//    布局也已收敛 —— 读 TextKit 才是安全的。
//
//  这条也是文档 30/36 反复写的：
//    「改属性」不如「加图层」；
//    「在别人的回调里读」不如「等回调结束再读」。
// ═══════════════════════════════════════════════════════════════════════════

#import "FDMBubbleDiag.h"
#import "FLog.h"
#import "FDMConfig.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

/* ══════════════════════════════════ 状态 ══════════════════════════════════ */

static BOOL              gDiag   = NO;    /* 总开关 */
static NSTimer          *gTimer  = nil;   /* 巡检定时器 */
static int               gBudgetMine  = 2;   /* 用户侧还能 dump 几个 */
static int               gBudgetTheir = 2;   /* AI 侧还能 dump 几个 */
static NSMutableString  *gBuf    = nil;   /* 当前这次 dump 的缓冲 */
static int               gWrittenFirst = 0;
static int               gTicks  = 0;     /* 巡检次数（自动停表用）*/

#define kDiagMaxNodes   220               /* 单棵树最多打多少个节点 */
#define kDiagMaxDepth   6                 /* 最多往下几层 */
#define kDiagTickSec    0.8               /* 起步巡检间隔 */
#define kDiagTickSlow   2.5               /* 等会话时的巡检间隔 */

/* ══════════════════════════════════ 格式化 ══════════════════════════════════ */

static NSString *R(CGRect r) {
    if (CGRectIsNull(r))      return @"null";
    if (CGRectIsInfinite(r))  return @"inf";
    return [NSString stringWithFormat:@"%.1f,%.1f %.1fx%.1f",
            r.origin.x, r.origin.y, r.size.width, r.size.height];
}

static NSString *S(CGSize s) {
    return [NSString stringWithFormat:@"%.1fx%.1f", s.width, s.height];
}

static NSString *Ins(UIEdgeInsets e) {
    return [NSString stringWithFormat:@"%.1f,%.1f,%.1f,%.1f",
            e.top, e.left, e.bottom, e.right];
}

static NSString *Col(UIColor *c) {
    if (!c) return @"nil";
    if ([c isEqual:[UIColor clearColor]]) return @"clear";
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if ([c getRed:&r green:&g blue:&b alpha:&a]) {
        return [NSString stringWithFormat:@"#%02X%02X%02X/%.2f",
                (int)(r * 255), (int)(g * 255), (int)(b * 255), a];
    }
    return @"?";
}

static NSString *ColRef(CGColorRef c) {
    if (!c) return @"nil";
    const CGFloat *comp = CGColorGetComponents(c);
    size_t n = CGColorGetNumberOfComponents(c);
    if (n == 4 && comp) {
        return [NSString stringWithFormat:@"#%02X%02X%02X/%.2f",
                (int)(comp[0] * 255), (int)(comp[1] * 255), (int)(comp[2] * 255),
                comp[3]];
    }
    return [NSString stringWithFormat:@"a=%.2f n=%zu", CGColorGetAlpha(c), n];
}

static NSString *Ind(int depth) {
    if (depth <= 0) return @"";
    NSMutableString *s = [NSMutableString stringWithCapacity:(NSUInteger)depth * 2];
    for (int i = 0; i < depth; i++) [s appendString:@"· "];
    return s;
}

/* ══════════════════════════════ 裁剪与可见区 ══════════════════════════════ */

/** v 的可见矩形（root 坐标系）；沿祖先链逐层按 clipsToBounds 求交。 */
static CGRect VisibleInRoot(UIView *v, UIView *root) {
    if (!v || !root) return CGRectNull;

    CGRect r = [v convertRect:v.bounds toView:root];

    UIView *cur = v;
    int guard = 0;
    while (cur && cur != root && guard++ < 40) {
        UIView *parent = cur.superview;
        if (!parent) break;
        if (parent.clipsToBounds || parent.layer.masksToBounds) {
            CGRect pb = [parent convertRect:parent.bounds toView:root];
            r = CGRectIntersection(r, pb);
            if (CGRectIsNull(r)) return CGRectNull;
        }
        cur = parent;
    }
    return r;
}

static BOOL IsTextLike(UIView *v) {
    if (!v) return NO;
    if ([v isKindOfClass:[UITextView class]])  return YES;
    if ([v isKindOfClass:[UILabel class]])     return YES;
    if ([v isKindOfClass:[UITextField class]]) return YES;
    return NO;
}

/**
 * ★ TextKit 读取守卫。
 *
 * SIGBUS 就是从这儿来的：setAttributedText 进行中时，
 * textStorage 长度和 layoutManager 的 glyph 数不一致。
 * 这里把「明显不该读」的情况全部挡在门外，宁可跳过也不崩。
 */
static BOOL TextKitReadable(UITextView *tv) {
    if (!tv) return NO;
    if (![tv isKindOfClass:[UITextView class]]) return NO;

    NSTextStorage *ts = tv.textStorage;
    if (!ts) return NO;
    if (ts.length == 0) return NO;                 /* 空文本没什么可量的 */

    NSTextContainer *tc = tv.textContainer;
    if (!tc) return NO;

    /* ⚠️ 关键：不要碰 layoutManager.usedRect，除非 glyph 数和字符数对得上。
     *    iOS 15 是 TextKit1，numberOfGlyphs 可用；
     *    万一是 TextKit2（iOS 16+）就没有这些方法，直接跳过。 */
    if (![tv respondsToSelector:@selector(layoutManager)]) return NO;

    NSLayoutManager *lm = tv.layoutManager;
    if (!lm) return NO;

    if ([lm respondsToSelector:@selector(numberOfGlyphs)]) {
        NSUInteger glyphs = [lm numberOfGlyphs];
        if (glyphs == 0) return NO;
        /* 正常情况下 glyph ≤ 字符数（合字会更少）。多出来 = 状态没收敛。 */
        if (glyphs > ts.length) return NO;
    } else {
        return NO;      /* TextKit2：本项目不赌，直接不读 */
    }
    return YES;
}

/** 文字类的「真实内容矩形」（root 坐标系，已按裁剪收窄）。 */
static CGRect TextContentRect(UIView *v, UIView *root) {
    if (!v) return CGRectNull;

    CGRect vis = VisibleInRoot(v, root);
    if (CGRectIsNull(vis) || vis.size.width < 0.5 || vis.size.height < 0.5) {
        return CGRectNull;
    }

    if ([v isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)v;
        if (!TextKitReadable(tv)) {
            /* 读不了就退回「可视框」，但绝不猜内容尺寸 */
            return vis;
        }

        CGRect used = [tv.layoutManager usedRectForTextContainer:tv.textContainer];

        CGRect contentLocal;
        if (used.size.height > 0.5) {
            contentLocal = CGRectMake(used.origin.x + tv.textContainerInset.left,
                                      used.origin.y + tv.textContainerInset.top,
                                      used.size.width,
                                      used.size.height);
        } else {
            contentLocal = CGRectMake(0, 0,
                                      tv.contentSize.width,
                                      tv.contentSize.height);
        }

        CGRect contentInRoot = [tv convertRect:contentLocal toView:root];
        CGRect both = CGRectIntersection(contentInRoot, vis);
        if (!CGRectIsNull(both) && both.size.width > 0.5 && both.size.height > 0.5) {
            return both;
        }
        return vis;
    }

    return vis;
}

/** 从 v 往下收集所有文字的真实内容矩形（root 坐标系）。 */
static CGRect CollectTextRects(UIView *v, UIView *root) {
    CGRect uni = CGRectNull;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:v];
    int guard = 0;

    while (stack.count && guard++ < 500) {
        UIView *x = stack.lastObject;
        [stack removeLastObject];

        if (IsTextLike(x)) {
            CGRect r = TextContentRect(x, root);
            if (!CGRectIsNull(r) && r.size.width > 0.5 && r.size.height > 0.5) {
                uni = CGRectIsNull(uni) ? r : CGRectUnion(uni, r);
            }
            continue;
        }

        for (UIView *sv in x.subviews) [stack addObject:sv];
    }
    return uni;
}

/* ══════════════════════════════ 树 dump ══════════════════════════════ */

static void DumpNode(UIView *v, int depth, UIView *root, int *count) {
    if (!v) return;
    if (*count > kDiagMaxNodes) return;
    if (depth > kDiagMaxDepth) return;
    (*count)++;

    CGRect wf  = [v convertRect:v.bounds toView:root];
    CGRect vis = VisibleInRoot(v, root);

    NSMutableString *line = [NSMutableString string];

    [line appendFormat:@"%@%@\n", Ind(depth), NSStringFromClass([v class])];
    [line appendFormat:@"%@  frame=%@  bounds=%@\n", Ind(depth), R(v.frame), R(v.bounds)];
    [line appendFormat:@"%@  win=%@  vis=%@\n", Ind(depth), R(wf), R(vis)];
    [line appendFormat:@"%@  corner=%.1f  clip=%d mask=%d bg=%@ layBg=%@\n",
        Ind(depth),
        v.layer.cornerRadius,
        v.clipsToBounds ? 1 : 0,
        v.layer.masksToBounds ? 1 : 0,
        Col(v.backgroundColor),
        ColRef(v.layer.backgroundColor)];

    if (v.hidden || v.alpha < 0.99 || v.layer.zPosition != 0) {
        [line appendFormat:@"%@  hidden=%d alpha=%.2f z=%.2f\n",
            Ind(depth), v.hidden ? 1 : 0, v.alpha, v.layer.zPosition];
    }
    if (!CGAffineTransformIsIdentity(v.transform)) {
        [line appendFormat:@"%@  transform=[%.3f %.3f %.3f %.3f %.3f %.3f]\n",
            Ind(depth), v.transform.a, v.transform.b, v.transform.c,
            v.transform.d, v.transform.tx, v.transform.ty];
    }
    if (v.layer.mask) {
        [line appendFormat:@"%@  ★layer.mask=%@\n", Ind(depth),
            NSStringFromClass([v.layer.mask class])];
    }

    if ([v isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)v;
        [line appendFormat:@"%@  [scroll] off=%.1f,%.1f contentSize=%@ inset=%@ adj=%@\n",
            Ind(depth), sv.contentOffset.x, sv.contentOffset.y,
            S(sv.contentSize), Ins(sv.contentInset), Ins(sv.adjustedContentInset)];
    }

    if ([v isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)v;

        [line appendFormat:@"%@  [text] len=%lu inset=%@ lfp=%.1f\n",
            Ind(depth), (unsigned long)tv.text.length,
            Ins(tv.textContainerInset),
            tv.textContainer ? tv.textContainer.lineFragmentPadding : -1];

        if (TextKitReadable(tv)) {
            CGRect u = [tv.layoutManager usedRectForTextContainer:tv.textContainer];
            NSUInteger glyphs = [tv.layoutManager numberOfGlyphs];
            CGFloat natural = u.size.height
                            + tv.textContainerInset.top
                            + tv.textContainerInset.bottom;

            [line appendFormat:@"%@  [text] usedRect=%.1fx%.1f glyphs=%lu\n",
                Ind(depth), u.size.width, u.size.height, (unsigned long)glyphs];
            [line appendFormat:@"%@  [text] contentSize=%@  bounds=%@\n",
                Ind(depth), S(tv.contentSize), S(tv.bounds.size)];
            [line appendFormat:@"%@  [text] ★natural=%.1f  →  %@\n",
                Ind(depth), natural,
                (natural <= tv.bounds.size.height + 0.5)
                    ? @"刚好装得下" : @"装不下（可滚动）"];
            [line appendFormat:@"%@  [text] scrollEnabled=%d editable=%d\n",
                Ind(depth), tv.scrollEnabled ? 1 : 0, tv.editable ? 1 : 0];
        } else {
            [line appendFormat:@"%@  [text] ⚠️ TextKit 当前不可读（已跳过，不赌）\n",
                Ind(depth)];
        }
    }

    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *lb = (UILabel *)v;
        NSString *t = lb.text ?: @"";
        if (t.length > 40) t = [t substringToIndex:40];
        [line appendFormat:@"%@  [label] text=%@ lines=%ld\n",
            Ind(depth), t, (long)lb.numberOfLines];
    }

    [gBuf appendString:line];

    for (UIView *sv in v.subviews) DumpNode(sv, depth + 1, root, count);
}

/* ══════════════════════════════ 一次完整 dump ══════════════════════════════ */

static void DumpContainer(UIView *v, const char *side) {
    if (!v) return;

    gBuf = [NSMutableString stringWithCapacity:16384];

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";

    [gBuf appendString:@"\n"];
    [gBuf appendString:@"════════════════════════════════════════════════════════════\n"];
    [gBuf appendFormat:@"[%@]  %@    win=%p\n",
        @(side), NSStringFromClass([v class]), v];
    [gBuf appendFormat:@"时间 %@\n", [df stringFromDate:[NSDate date]]];
    {
        id nr = v.nextResponder;
        if (nr && [nr isKindOfClass:[UIViewController class]]) {
            Class vcCls = [nr class];
            [gBuf appendFormat:@"vc=%s\n", class_getName(vcCls)];
        } else {
            [gBuf appendString:@"vc=(无)\n"];
        }
    }
    [gBuf appendString:@"════════════════════════════════════════════════════════════\n"];

    /* ★ 分段打点：SIGBUS 不是 OC 异常，@try 抓不住。
     *   所以在每个危险动作之前写一行日志 ——
     *   崩溃之后再回来 grep，最后那一行 stage 就是凶案现场。 */
    FLOGI(FC_UI, @"[bubble-diag] stage0 %@ start", NSStringFromClass([v class]));

    /* ── 0. 容器自身 ── */
    [gBuf appendString:@"\n── 0. 容器自身 ──\n"];
    [gBuf appendFormat:@"  frame  = %@\n", R(v.frame)];
    [gBuf appendFormat:@"  bounds = %@\n", R(v.bounds)];
    [gBuf appendFormat:@"  clipsToBounds=%d  corner=%.1f  bg=%@\n",
        v.clipsToBounds ? 1 : 0, v.layer.cornerRadius, Col(v.backgroundColor)];

    FLOGI(FC_UI, @"[bubble-diag] stage1 祖先链");
    /* ── 1. 祖先链 ── */
    [gBuf appendString:@"\n── 1. 祖先链（往上 6 层）──\n"];
    {
        UIView *cur = v.superview;
        int up = 0;
        while (cur && up < 6) {
            [gBuf appendFormat:@"  ↑%d %@ frame=%@ win=%@ clip=%d corner=%.1f\n",
                up + 1, NSStringFromClass([cur class]), R(cur.frame),
                R([cur convertRect:cur.bounds toView:v]),
                cur.clipsToBounds ? 1 : 0, cur.layer.cornerRadius];
            cur = cur.superview;
            up++;
        }
    }

    FLOGI(FC_UI, @"[bubble-diag] stage2 视图树");
    /* ── 2. 视图树 ── */
    [gBuf appendString:@"\n── 2. 视图树 ──\n"];
    {
        int count = 0;
        DumpNode(v, 0, v, &count);
        [gBuf appendFormat:@"\n  （共 %d 个节点）\n", count];
    }

    FLOGI(FC_UI, @"[bubble-diag] stage3 推断（TextKit）");
    /* ── 3. ★ 推断 ── */
    [gBuf appendString:@"\n── 3. ★推断：气泡底该画在哪（容器坐标系）──\n"];
    {
        CGRect tb = CollectTextRects(v, v);
        [gBuf appendFormat:@"  文字真实包围盒 = %@\n", R(tb)];
        [gBuf appendFormat:@"  容器 bounds    = %@\n", R(v.bounds)];

        if (!CGRectIsNull(tb) && tb.size.width > 0.5 && tb.size.height > 0.5) {
            const CGFloat padX = 14.0, padY = 9.0;
            CGRect want = CGRectInset(tb, -padX, -padY);

            if (want.origin.x < 0) {
                want.size.width += want.origin.x;
                want.origin.x = 0;
            }
            if (want.origin.y < 0) {
                want.size.height += want.origin.y;
                want.origin.y = 0;
            }
            if (CGRectGetMaxX(want) > v.bounds.size.width) {
                want.size.width = v.bounds.size.width - want.origin.x;
            }
            if (CGRectGetMaxY(want) > v.bounds.size.height) {
                want.size.height = v.bounds.size.height - want.origin.y;
            }

            [gBuf appendFormat:@"  ★建议气泡底 = %@（padding %.0f/%.0f）\n",
                R(want), padX, padY];
            [gBuf appendFormat:@"  容器比它多出：上 %.1f 下 %.1f 左 %.1f 右 %.1f\n",
                want.origin.y,
                v.bounds.size.height - CGRectGetMaxY(want),
                want.origin.x,
                v.bounds.size.width - CGRectGetMaxX(want)];

            CGFloat ratio = v.bounds.size.height > 0
                ? want.size.height / v.bounds.size.height : 0;
            [gBuf appendFormat:@"  建议高度 / 容器高度 = %.2f\n", ratio];
            if (ratio > 0 && ratio < 0.85) {
                [gBuf appendString:@"  ⚠ 容器比气泡高很多 ⇒ 直接铺满容器会「上宽下空」\n"];
            }
        } else {
            [gBuf appendString:@"  ✗ 一个文字视图都没找到（这本身就是答案）\n"];
        }
    }

    /* ── 4. ivar 扫描 ── */
    FLOGI(FC_UI, @"[bubble-diag] stage4 ivar");
    /* ★★ 2026-10-24 血案 2：原来是 class_copyIvarList 全量遍历。
     *   object_getIvar 对 **weak ivar 不生效** —— weak 引用存的是已释放指针，
     *   object_getIvar 原样返回，接着 [obj isKindOfClass:] ⇒ 野指针 ⇒ SIGBUS。
     *   而且 SIGBUS 不是 OC 异常，外面包 @try 完全没用。
     *
     *   ⇒ 改成「只认气泡专属名字」的白名单。少看十几个 ivar，但不会死。 */
    [gBuf appendString:@"  （白名单：只读 bubble 专属 ivar）\n"];
    {
        static const char *names[] = {
            "bubbleView", "_bubbleView",
            "bubble", "_bubble",
            "bubbleBackgroundView", "_bubbleBackgroundView",
            "nameLabel", "_nameLabel",
        };
        int shown = 0;
        for (size_t i = 0; i < sizeof(names)/sizeof(names[0]); i++) {
            Ivar iv = class_getInstanceVariable([v class], names[i]);
            if (!iv) continue;

            const char *tp = ivar_getTypeEncoding(iv);
            if (!tp || tp[0] != '@') continue;      /* 只处理对象类型 */

            id obj = nil;
            @try { obj = object_getIvar(v, iv); } @catch (NSException *e) { continue; }
            if (!obj) continue;

            /* ★ 再稳一道：只认 UIView 的 type encoding 字串，不认就跳过 */
            Class c = nil;
            @try { c = object_getClass(obj); } @catch (NSException *e) { continue; }
            if (!c || !class_respondsToSelector(c, @selector(isKindOfClass:))) continue;

            BOOL isView = NO;
            @try { isView = [obj isKindOfClass:[UIView class]]; }
            @catch (NSException *e) { continue; }
            if (!isView) continue;

            UIView *sv = (UIView *)obj;
            [gBuf appendFormat:@"  ivar %-28s = %@  bounds=%@  corner=%.1f  bg=%@\n",
                names[i], NSStringFromClass([sv class]), R(sv.bounds),
                sv.layer.cornerRadius, Col(sv.backgroundColor)];
            shown++;
        }
        if (shown == 0) [gBuf appendString:@"  （白名单里一个都没有）\n"];
    }

    [gBuf appendString:@"════════════════════════════════════════════════════════════\n"];
}

/* ══════════════════════════════ 落盘 ══════════════════════════════ */

static NSString *DiagFilePath(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES) firstObject];
    if (!docs) return nil;
    return [docs stringByAppendingPathComponent:@"fdm-bubble-geom.txt"];
}

static void FlushDiag(void) {
    NSString *path = DiagFilePath();
    if (!path || !gBuf) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;

    if (!gWrittenFirst || ![fm fileExistsAtPath:path]) {
        [gBuf writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
        [fm setAttributes:@{NSFilePosixPermissions: @(0644)}
             ofItemAtPath:path error:nil];
        gWrittenFirst = 1;
    } else {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [gBuf writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
        } else {
            @try {
                [fh seekToEndOfFile];
                [fh writeData:[gBuf dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            } @catch (NSException *e) { }
        }
    }

    if (err) FLOGE(FC_UI, @"[bubble-diag] 写文件失败: %@", err.localizedDescription);
}

/* ══════════════════════════════ 类名判定 ══════════════════════════════ */

static BOOL DiagIsUserBubble(NSString *cn) {
    if (!cn.length) return NO;
    static NSSet *ok = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ok = [NSSet setWithArray:@[
            @"DeepSeek_Chat.UserBubbleView",
            @"DeepSeek_Chat.UserRequestBubbleView",
            @"_TtC13DeepSeek_Chat14UserBubbleView",
            @"_TtC13DeepSeek_Chat21UserRequestBubbleView",
        ]];
    });
    return [ok containsObject:cn];
}

static BOOL DiagIsAIBubble(NSString *cn) {
    if (!cn.length) return NO;
    static NSSet *ok = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ok = [NSSet setWithArray:@[
            @"DeepSeek_Chat.AgentMessageCell",
            @"DeepSeek_Chat.AgentMessageView",
            @"_TtC13DeepSeek_Chat16AgentMessageCell",
            @"_TtC13DeepSeek_Chat16AgentMessageView",
        ]];
    });
    return [ok containsObject:cn];
}

/* ══════════════════════════════ 巡检 ══════════════════════════════ */

/**
 * 一次巡检：扫所有窗口，找气泡容器，dump 掉还没 dump 过的。
 *
 * ★ 这个函数跑在 NSTimer 回调里（主 runloop 正常上下文），
 *   此时宿主的 setAttributedText / layout 都已返回 ⇒ 读 TextKit 安全。
 */
static void DiagTick(void) {
    if (!gDiag) return;
    if (gBudgetMine <= 0 && gBudgetTheir <= 0) return;

    /* ★ 不停表 —— 主人什么时候点进会话，就什么时候能抓到。
     *   但会自降频：前 10 次用 kDiagTickSec（快），之后放慢，省 7P 的内存和电。
     *   300 次（约 10 分钟）打一行「还在等」，方便判断是不是压根没进会话。 */
    gTicks++;
    if (gTicks == 10) {
        [gTimer invalidate];
        gTimer = [NSTimer scheduledTimerWithTimeInterval:kDiagTickSlow
                                                 repeats:YES
                                                   block:^(NSTimer *t) { DiagTick(); }];
        FLOGI(FC_UI, @"[bubble-diag] 降频到每 %.1fs 一次（等主人进会话）", kDiagTickSlow);
    }
    if (gTicks % 300 == 0) {
        FLOGI(FC_UI, @"[bubble-diag] 还在等…已扫 %d 次（进任意一个会话就会写文件）", gTicks);
    }

    @try {
        NSMutableArray<UIWindow *> *wins = [NSMutableArray array];

        extern UIWindow *FDMFindBestWindow(void);
        UIWindow *best = FDMFindBestWindow();
        if (best) [wins addObject:best];

        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                    if (w != best) [wins addObject:w];
                }
            }
        }

        for (UIWindow *w in wins) {
            if (gBudgetMine <= 0 && gBudgetTheir <= 0) break;

            NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
            int guard = 0;

            while (stack.count && guard++ < 3000 &&
                   (gBudgetMine > 0 || gBudgetTheir > 0)) {
                UIView *v = stack.lastObject;
                [stack removeLastObject];

                NSString *cn = NSStringFromClass([v class]);
                BOOL isMine  = DiagIsUserBubble(cn);
                BOOL isTheir = !isMine && DiagIsAIBubble(cn);

                if (isMine || isTheir) {
                    if ((isMine && gBudgetMine <= 0) ||
                        (isTheir && gBudgetTheir <= 0)) {
                        for (UIView *sv in v.subviews) [stack addObject:sv];
                        continue;
                    }

                    static char kDone;
                    if (!objc_getAssociatedObject(v, &kDone)) {
                        FLOGI(FC_UI, @"[bubble-diag] cand %@ %.0fx%.0f",
                              cn, v.bounds.size.width, v.bounds.size.height);
                        /* 布局收敛 + 确实有文字，才值得 dump */
                        if (v.bounds.size.width >= 20 && v.bounds.size.height >= 16) {
                            FLOGI(FC_UI, @"[bubble-diag] cand 量文字…");
                            CGRect tb = CollectTextRects(v, v);
                            FLOGI(FC_UI, @"[bubble-diag] cand 文字=%@", R(tb));
                            if (!CGRectIsNull(tb) && tb.size.height > 1) {
                                objc_setAssociatedObject(v, &kDone, @YES,
                                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                                if (isMine) gBudgetMine--; else gBudgetTheir--;
                                DumpContainer(v, isMine ? "我" : "对方");
                                FlushDiag();
                                FLOGI(FC_UI,
                                      @"[bubble-diag] 已 dump %@ %@ %.0fx%.0f（剩 %d）",
                                      isMine ? @"我" : @"对方", cn,
                                      v.bounds.size.width, v.bounds.size.height,
                                      isMine ? gBudgetMine : gBudgetTheir);
                                /* ★ 这个容器的整棵树已经打完了 ⇒ 不再往下走。
                                 *   否则嵌套的白名单类（AgentMessageView /
                                 *   UserBubbleView）会把预算吃光，
                                 *   同一块区域 dump 两遍。 */
                                continue;
                            }
                        }
                    }
                }

                for (UIView *sv in v.subviews) [stack addObject:sv];
            }
        }

        if (gBudgetMine <= 0 && gBudgetTheir <= 0) {
            FLOGI(FC_UI, @"[bubble-diag] 两侧都收够了，停表 → fdm-bubble-geom.txt");
            [gTimer invalidate];
            gTimer = nil;
        }
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[bubble-diag] 巡检异常: %@", e.reason);
    }
}

/* ══════════════════════════════ 入口 ══════════════════════════════ */

void FDMBubbleDiagInstall(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ FDMBubbleDiagInstall(); });
        return;
    }

    @try {
        FDMConfig *c = [FDMConfig shared];
        gDiag = [c boolFor:@"bubble" key:@"diag"];
    } @catch (NSException *e) {
        gDiag = NO;
    }

    if (!gDiag) {
        FLOGI(FC_UI, @"[bubble-diag] 关着（fdm-bubble.json 里 diag=true 才开）");
        return;
    }

    /* 清掉上一次的文件，避免新旧混在一起 */
    NSString *path = DiagFilePath();
    if (path) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        gWrittenFirst = 0;
    }
    gBudgetMine = 2;
    gBudgetTheir = 2;

    if (gTimer) {
        FLOGI(FC_UI, @"[bubble-diag] 巡检已在跑，重置预算");
        return;
    }

    gTimer = [NSTimer scheduledTimerWithTimeInterval:kDiagTickSec
                                             repeats:YES
                                               block:^(NSTimer *t) {
        DiagTick();
    }];
    FLOGI(FC_UI, @"[bubble-diag] ★诊断模式开启：只读不写，每 %.1fs 巡检一次，两侧各 dump 2 个容器",
          kDiagTickSec);
}

void FDMBubbleDiagReload(void) {
    gBudgetMine = 2;
    gBudgetTheir = 2;
    FDMBubbleDiagInstall();
}

int FDMBubbleDiagCount(void) {
    return (2 - gBudgetMine) + (2 - gBudgetTheir);
}
