/* ============================================================
 * FDMStrip —— ⟦FDM⟧…⟦/FDM⟧ 标记抹除（**仅显示层**）
 *
 * 背景：
 *   宿主协议没有 system 通道 ⇒ 提示词只能拼在 prompt 里 ⇒ 用户也能看见。
 *   安卓的做法是「明文承载 + 渲染抹除」，iOS 这里同样只做显示层抹除：
 *   在 UILabel / UITextView / NSAttributedString / CATextLayer
 *   的**入参**上先洗干净，画出来的永远是干净的。
 *
 * ★★ 数据库层（sqlite3_bind_*）已经被**永久删除**，原因见文件末尾注释。
 *
 * 性能铁律：
 *   hook 最前面做长度预检 + rangeOfString，绝大多数调用直接透传。
 * ============================================================ */

#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "FLog.h"

static NSString *const kOpen  = @"\u27E6" @"FDM" @"\u27E7";
static NSString *const kClose = @"\u27E6" @"/FDM" @"\u27E7";

/* ============ 一、纯函数 ============ */

BOOL FDMHasMarks(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length < 6) return NO;
    if ([s rangeOfString:kOpen].location != NSNotFound) return YES;
    /* ★ 2026-10-17 深夜：<Suggestion> 也算「需要处理的标记」，
     *   历史消息补扫（STDeepSweep）靠它判定要不要重设一次。 */
    if ([s rangeOfString:@"<Suggestion>" options:NSCaseInsensitiveSearch].location != NSNotFound)
        return YES;
    return NO;
}

/* ★ 容错找 ⟦/FDM⟧：允许 "⟦/FDM ⟧"、"⟦/ FDM⟧"、"⟦/FDM\n⟧" 这类
 *   （实测模型会在闭合标记里插空格/换行 ⇒ 严格搜会漏 ⇒ 标记裸奔） */
static NSRange FindCloseTolerant(NSString *s, NSUInteger from) {
    NSUInteger n = s.length;
    if (from >= n) return NSMakeRange(NSNotFound, 0);
    NSRange ro = [s rangeOfString:@"\u27E6/" options:0 range:NSMakeRange(from, n - from)];
    if (ro.location == NSNotFound) return NSMakeRange(NSNotFound, 0);
    NSUInteger p = NSMaxRange(ro);
    /* 跳过空白 */
    while (p < n) {
        unichar c = [s characterAtIndex:p];
        if (c == ' ' || c == '\n' || c == '\r' || c == '\t') p++;
        else break;
    }
    if (p + 3 > n) return NSMakeRange(NSNotFound, 0);
    NSString *w = [s substringWithRange:NSMakeRange(p, 3)];
    if (![w isEqualToString:@"FDM"]) return NSMakeRange(NSNotFound, 0);
    p += 3;
    while (p < n) {
        unichar c = [s characterAtIndex:p];
        if (c == ' ' || c == '\n' || c == '\r' || c == '\t') p++;
        else break;
    }
    if (p >= n || [s characterAtIndex:p] != 0x27E7) return NSMakeRange(NSNotFound, 0);
    return NSMakeRange(ro.location, p + 1 - ro.location);
}

NSString *FDMStripMarks(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length < 6) return s;
    NSRange first = [s rangeOfString:kOpen];
    if (first.location == NSNotFound) return s;

    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    NSUInteger i = 0;
    while (i < s.length) {
        NSRange r = [s rangeOfString:kOpen options:0 range:NSMakeRange(i, s.length - i)];
        if (r.location == NSNotFound) {
            [out appendString:[s substringFromIndex:i]];
            break;
        }
        if (r.location > i)
            [out appendString:[s substringWithRange:NSMakeRange(i, r.location - i)]];

        NSUInteger afterOpen = r.location + r.length;
        NSRange rc = FindCloseTolerant(s, afterOpen);
        if (rc.location == NSNotFound)
            rc = [s rangeOfString:kClose options:0
                            range:NSMakeRange(afterOpen, s.length - afterOpen)];
        if (rc.location == NSNotFound) break;
        NSUInteger next = rc.location + rc.length;
        if (next < s.length && [s characterAtIndex:next] == '\n') next++;
        i = next;
    }
    NSString *res = [out copy];
    while (res.length && [res hasPrefix:@"\n"]) res = [res substringFromIndex:1];
    return res;
}

/* ============ 二、开关 ============ */

static BOOL gStripDisplay = YES;
static int  gNStripDisplay = 0;

void FDMStripSetEnabled(BOOL display, BOOL db) {
    (void)db;                      /* 数据库层已弃用，参数保留以兼容调用方 */
    gStripDisplay = display;
    FLOGW(FC_HOOK, @"[strip] 显示层抹除=%@（数据库层已弃用）", display?@"开":@"关");
}
int FDMStripDisplayCount(void) { return gNStripDisplay; }
int FDMStripDBCount(void) { return 0; }

/* ============ 三、显示层 hook（洗入参） ============ */

/* 5 个 wrapper 的前向声明（STOrig 要用它们的地址排除「别调自己」） */
static void st_setText(id, SEL, NSString *);

/* ★ 前置声明：BTIsUserBubble 定义在后面（348 行），但 st_setText 要用它 */
static BOOL BTIsUserBubble(UIView *v);

/* 诊断计数：经由 setText: 转成 attributedText 的次数 */
static int gNRichViaSetText = 0;

/* ★ v77 诊断：谁在"回复完成"那一刻把我们改回原文？
 *   症状：流式过程中是彩色的，**完成的一瞬间变裸**。
 *   做法：记住每个控件上一次我们设进去的"彩色版指纹"，
 *        如果之后又被设成"原文（含 < 标签）"，就把调用栈打出来。 */
static NSMapTable<UIView *, NSString *> *gLastRichFP = nil;
static int gNRevertLogged = 0;

static void STNoteRichOK(UIView *v, NSAttributedString *rich) {
    if (!v || !rich) return;
    if (!gLastRichFP) {
        gLastRichFP = [NSMapTable weakToStrongObjectsMapTable];
    }
    @try { [gLastRichFP setObject:rich.string forKey:v]; } @catch (NSException *e) { }
}

/** 如果这次设的串**又带上了 < 标签**，而之前设过渲染版 ⇒ 就是"被打回原形"。 */
static void STCheckRevert(UIView *v, NSString *incoming, const char *from) {
    if (!v || gNRevertLogged >= 6) return;
    if (!gLastRichFP || ![incoming isKindOfClass:[NSString class]]) return;
    if ([incoming rangeOfString:@"<"].location == NSNotFound) return;
    NSString *prev = nil;
    @try { prev = [gLastRichFP objectForKey:v]; } @catch (NSException *e) { }
    if (!prev.length) return;
    /* 之前是干净的（渲染过），现在又来带标签的了 ⇒ 打回原形 */
    if ([prev rangeOfString:@"<"].location != NSNotFound) return;

    gNRevertLogged++;
    NSArray<NSString *> *st = [NSThread callStackSymbols];
    NSMutableString *sig = [NSMutableString string];
    for (NSUInteger i = 1; i < st.count && i <= 16; i++) {
        NSString *line = st[i];
        /* 只留类名.方法名 那一段，砍掉地址 */
        NSRange r = [line rangeOfString:@"0x"];
        NSString *shortLine = line;
        if (r.location != NSNotFound) {
            NSArray *parts = [line componentsSeparatedByString:@" "];
            NSMutableArray *keep = [NSMutableArray array];
            for (NSString *pp in parts) {
                if (!pp.length) continue;
                if ([pp hasPrefix:@"0x"]) continue;
                [keep addObject:pp];
            }
            shortLine = [keep componentsJoinedByString:@" "];
        }
        [sig appendFormat:@"\n  %2lu %@", (unsigned long)i, shortLine];
        if (sig.length > 1400) break;
    }
    FLOGE(FC_UI, @"[REVERT] ⚠️ 被打回原形！来源=%@ 类=%@ 来串=%lu字 之前渲染版=%lu字\n调用栈:%@",
          @(from), NSStringFromClass([v class]),
          (unsigned long)incoming.length, (unsigned long)prev.length, sig);
}
static void st_setAttributedText(id, SEL, NSAttributedString *);
static id   st_as_initWithString(id, SEL, NSString *);
static id   st_as_initWithStringAttrs(id, SEL, NSString *, NSDictionary *);
static void st_layerSetString(id, SEL, id);


#define ST_MAX 32
typedef struct { Class cls; SEL sel; IMP orig; } STHook;
static STHook gST[ST_MAX];
static int    gSTN = 0;
static __thread int gStReent = 0;

/* ============================================================
 * STSwap —— 显示层安全替换（和 FDMBeauty.BTSwap 同一套防护）
 *
 * 两道防护：
 *   ① 若目标类自己没实现该方法，用 class_addMethod 加覆盖，
 *      绝不动父类（否则会污染全局，见 FDMBeauty 里的注释）
 *   ② 若原 IMP 已经是我们的某个 wrapper，直接拒绝（防无限递归）
 * ============================================================ */
static IMP STSwap(Class c, const char *selName, IMP imp) {
    if (!c || !selName || !imp) return NULL;
    @try {
        SEL s = sel_registerName(selName);
        Method m = class_getInstanceMethod(c, s);
        if (!m) return NULL;

        const char *types = method_getTypeEncoding(m);
        if (!types) return NULL;

        IMP old = method_getImplementation(m);

        /* ② 防递归：原实现已是我们自己 */
        if (old == imp ||
            old == (IMP)st_setText || old == (IMP)st_setAttributedText ||
            old == (IMP)st_as_initWithString || old == (IMP)st_as_initWithStringAttrs ||
            old == (IMP)st_layerSetString) {
            return NULL;
        }

        /* ① 这个类自己有没有实现？ */
        BOOL hasOwn = NO;
        unsigned int mc = 0;
        Method *own = class_copyMethodList(c, &mc);
        if (own) {
            for (unsigned int i = 0; i < mc; i++)
                if (sel_isEqual(method_getName(own[i]), s)) { hasOwn = YES; break; }
            free(own);
        }

        if (!hasOwn) {
            /* 自己没实现 ⇒ 只在本类加覆盖，不动父类 */
            if (!class_addMethod(c, s, imp, types)) return NULL;
        } else {
            method_setImplementation(m, imp);
        }

        if (gSTN < ST_MAX) { gST[gSTN].cls = c; gST[gSTN].sel = s; gST[gSTN].orig = old; gSTN++; }
        return old;
    } @catch (NSException *e) { return NULL; }
}

/* ============================================================
 * ★★ 2026-10-17 致命 bug 修复：STOrig 必须按 (类, 方法) 查
 *
 * 旧实现只按 selector 查：
 *      for (i) if (sel_isEqual(gST[i].sel, sel)) return gST[i].orig;
 *
 * 而 setText: 挂了 3 个类：
 *      gST[0] = (UILabel,     setText:, UILabel 的 IMP)
 *      gST[1] = (UITextView,  setText:, UITextView 的 IMP)
 *      gST[2] = (UITextField, setText:, UITextField 的 IMP)
 *
 * ⇒ UITextView 实例调用 setText: 时，它拿到的是 **gST[0]（UILabel 的 IMP）**
 *   ⇒ 用 UILabel 的代码去操作 UITextView 对象
 *   ⇒ 类型不匹配 → 内存越界 → SIGSEGV（点进对话立刻崩）
 *
 * 同理 initWithString: 在 NSAttributedString / NSMutableAttributedString
 * 都挂了，后者永远取到前者的 IMP。
 *
 * 修法：按类沿继承链查，和 FDMBeauty.BTFind 一个套路。
 * ============================================================ */
static IMP STOrigFor(Class cls, SEL sel) {
    for (Class c = cls; c != Nil; c = class_getSuperclass(c))
        for (int i = 0; i < gSTN; i++)
            if (gST[i].cls == c && sel_isEqual(gST[i].sel, sel)) return gST[i].orig;
    return NULL;
}

/* 兜底：查不到就问 runtime，但**绝不返回自己**（否则无限递归） */
static IMP STOrig(id self, SEL _cmd) {
    Class cls = object_getClass(self);
    IMP o = STOrigFor(cls, _cmd);
    if (o && o != (IMP)st_setText && o != (IMP)st_setAttributedText &&
             o != (IMP)st_as_initWithString && o != (IMP)st_as_initWithStringAttrs &&
             o != (IMP)st_layerSetString)
        return o;

    /* 往父类找（也可能是我们挂在父类上的） */
    for (Class c = class_getSuperclass(cls); c != Nil; c = class_getSuperclass(c)) {
        IMP p = STOrigFor(c, _cmd);
        if (p && p != (IMP)st_setText && p != (IMP)st_setAttributedText &&
                 p != (IMP)st_as_initWithString && p != (IMP)st_as_initWithStringAttrs &&
                 p != (IMP)st_layerSetString)
            return p;
    }
    return NULL;
}

/* ============ 三·b 五个 wrapper 实现 ============ */

/* -[UILabel setText:] / -[UITextView setText:] / -[UITextField setText:] */
static void st_setText(id self, SEL _cmd, NSString *text) {
    IMP o = STOrig(self, _cmd);
    if (!o) return;                                  /* 拿不到原实现就啥也不做，比崩强 */

    /* ★ v76 诊断：搞清楚这条路到底走没走、卡在哪个条件上 */
    {
        static int dbg = 0;
        if (dbg < 24 && [text isKindOfClass:[NSString class]] &&
            [text rangeOfString:@"<"].location != NSNotFound) {
            dbg++;
            FLOGW(FC_UI, @"[setText-dbg] cls=%@ len=%lu 重入=%d user气泡=%d canAttr=%d",
                  NSStringFromClass([self class]),
                  (unsigned long)text.length,
                  gStReent ? 1 : 0,
                  BTIsUserBubble((UIView *)self) ? 1 : 0,
                  [self respondsToSelector:@selector(setAttributedText:)] ? 1 : 0);
        }
    }

    if (!gStripDisplay || gStReent || ![text isKindOfClass:[NSString class]] || text.length < 6) {
        ((void(*)(id,SEL,id))o)(self, _cmd, text);
        return;
    }

    /* ★★★ 2026-10-25 v75：**流式输出时宿主会用 setText: 把渲染结果盖掉**
     *
     * 主人描述：「标签成功渲染了一瞬间又变回裸的」。
     *
     * 日志证据：
     *   [rich] 裸标签渲染 130 → 100 字
     *   [rich] 裸标签渲染 132 → 102 字      ← 字数在涨 = **流式输出**
     *   [rich] 裸标签渲染 150 → 108 字
     *   ...
     *
     * 真实流程：
     *   ① 宿主 setAttributedText: → 我们渲染 → **彩色（一瞬间）**
     *   ② 宿主紧接着 setText: 原文 → **覆盖成纯文本** → 变回裸标签
     *
     * 因为 `UILabel.text` 和 `.attributedText` 是互斥的：
     *   设 text 会**清掉所有 attributes**。
     *
     * ⇒ 修法：setText: 里如果发现「有标签 + 看着像正文」，
     *   就**改成设置 attributedText（渲染版）**，而不是调原 setText:。
     *   这样宿主最后看到的状态是彩色的。
     *
     * ⚠️ 三条安全线：
     *   ① gStReent 挡递归（attributedText setter 内部会回调 text setter）
     *   ② 只在「控件确实是文本控件」时做（UILabel/UITextView 才有 attributedText）
     *   ③ 长按/输入框之类短文本一律不碰（length < 12 跳过渲染）
     */
    STCheckRevert((UIView *)self, text, "setText");

    BOOL hasTag = ([text rangeOfString:@"<"].location != NSNotFound);
    BOOL canAttr = [self respondsToSelector:@selector(setAttributedText:)];

    if (hasTag && canAttr && text.length >= 12) {
        /* 用户气泡只删不渲染（否则整段系统提示词会吐出来）*/
        BOOL userBubble = BTIsUserBubble((UIView *)self);

        if (!userBubble) {
            gStReent = 1;
            NSAttributedString *rich = nil;
            @try {
                /* 用**当前控件的字体**当底，渲染结果才和宿主一致 */
                UIFont *f = nil;
                UIColor *col = nil;
                if ([self isKindOfClass:[UILabel class]]) {
                    f = [(UILabel *)self font];
                    col = [(UILabel *)self textColor];
                } else if ([self isKindOfClass:[UITextView class]]) {
                    f = [(UITextView *)self font];
                    col = [(UITextView *)self textColor];
                }
                if (!f) f = [UIFont systemFontOfSize:16];
                NSMutableDictionary *base = [NSMutableDictionary dictionary];
                base[NSFontAttributeName] = f;
                if (col) base[NSForegroundColorAttributeName] = col;

                extern NSAttributedString *FDMRichRenderBare(NSAttributedString *input);
                NSAttributedString *probe =
                    [[NSAttributedString alloc] initWithString:text attributes:base];
                rich = FDMRichRenderBare(probe);
            } @catch (NSException *e) { rich = nil; }

            if (rich && rich.length && ![rich.string isEqualToString:text]) {
                gNRichViaSetText++;
                if (gNRichViaSetText <= 10)
                    FLOGI(FC_UI, @"[rich] ★ setText 转 attributedText %lu → %lu 字（%@）",
                          (unsigned long)text.length, (unsigned long)rich.length,
                          NSStringFromClass([self class]));
                /* ★★ 2026-10-25 v75 血的教训：**必须保持在 gStReent=1 内**调用！
                 *
                 *   `setAttributedText:` 内部会回调 `setText:`，
                 *   而如果这里已经把 gStReent 清成 0 —— 就会再次进入本函数
                 *   ⇒ 再渲染 ⇒ 再 setAttributedText ⇒ **无限递归**
                 *   ⇒ 栈溢出 ⇒ **SIGSEGV，整个 App 被杀**。
                 *
                 *   第一次部署上去就是崩在这里（日志停在 glass 安装完之后）。 */
                @try {
                    [(id)self setAttributedText:rich];
                } @catch (NSException *e) {
                    ((void(*)(id,SEL,id))o)(self, _cmd, text);
                }
                gStReent = 0;
                return;
            }
            gStReent = 0;
        }
    }

    gStReent = 1;
    NSString *clean = text;
    @try {
        clean = FDMStripMarks(text);
        if (clean != text) {
            gNStripDisplay++;
            if (gNStripDisplay <= 6)
                FLOGI(FC_UI, @"[strip] 显示层命中 -[%@ setText:] %lu→%lu 字",
                      NSStringFromClass([self class]),
                      (unsigned long)text.length, (unsigned long)clean.length);
        }
    } @catch (NSException *e) { clean = text; }
    ((void(*)(id,SEL,id))o)(self, _cmd, clean);
    gStReent = 0;
}

/* ---- 富文本引擎（FDMRichText.m）---- */
extern NSAttributedString *FDMRichRender(NSAttributedString *input);
extern NSAttributedString *FDMRichRenderBare(NSAttributedString *input);
/* v76 诊断用：两个开关的当前值 */
extern BOOL FDMRichOnFlag(void);
extern BOOL FDMRichBareFlag(void);

/* ============================================================
 * ★★★ 判断「这个 view 是不是用户发的那条消息」（2026-10-17 血案）
 *
 *   背景：系统提示词是用 ⟦FDM⟧…⟦/FDM⟧ 包裹后拼在用户 prompt 前面的。
 *   而富文本引擎把 ⟦FDM⟧…⟦/FDM⟧ 当成「匿名包裹」来**渲染**
 *   （因为 AI 回复里这也是合法标记）。
 *
 *   ⇒ 结果：主人发一条消息，气泡里吐出**整段系统提示词**（含示例标记）。
 *
 *   区分办法：看 view 的 superview 链。
 *     用户气泡：UserRequestBubbleView / UserBubbleView / UserMessageCell
 *     AI 气泡：AgentMessageCell / ResponseFragmentView / RequestFragmentView
 *   ⇒ 用户气泡里**只删不渲染**；AI 气泡里才渲染。
 * ============================================================ */
static BOOL BTIsUserBubble(UIView *v) {
    int d = 0;
    for (UIView *p = v; p && d++ < 12; p = p.superview) {
        const char *cn = class_getName([p class]);
        if (!cn) continue;
        if (strstr(cn, "UserRequestBubble") != NULL ||
            strstr(cn, "UserBubble") != NULL ||
            strstr(cn, "UserMessageCell") != NULL ||
            strstr(cn, "UserTextCell") != NULL) {
            return YES;
        }
        if (strstr(cn, "AgentMessageCell") != NULL ||
            strstr(cn, "ResponseFragment") != NULL ||
            strstr(cn, "Markdown") != NULL) {
            return NO;
        }
    }
    return NO;
}

/* ============================================================
 * ★ 把「最终要显示的 attributedString」交给建议按钮模块
 *
 *   只在两种情况下递出去（避免每个 label 都白跑一遍）：
 *     · 原文本里还带 <Suggestion>（宿主第一次渲染）
 *     · 渲染后的文本能命中建议注册表（最常见）
 *   递出去之后，矩形由 FDMEnsureSugBox 用**同一份 AS** 算 ⇒ 不会错位。
 * ============================================================ */
static void STPushSug(UIView *v, NSString *raw, NSAttributedString *finalAS) {
    if (!v || !finalAS.length) return;
    @try {
        extern NSArray<NSDictionary *> *FDMSugsForText(NSString *text);
        BOOL tagPath = (raw.length &&
                        [raw rangeOfString:@"Suggestion"
                                   options:NSCaseInsensitiveSearch].location != NSNotFound);
        BOOL regPath = (FDMSugsForText(finalAS.string).count > 0);
        if (!tagPath && !regPath) return;
        extern void FDMEnsureSugBox(UIView *anchor, NSString *rawText, NSAttributedString *as);
        NSString *r = [raw copy];
        NSAttributedString *a = [finalAS copy];
        __weak UIView *wv = v;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (wv) FDMEnsureSugBox(wv, r, a);
        });
    } @catch (NSException *e) { }
}

/* -[UILabel setAttributedText:] / -[UITextView setAttributedText:] */
static void st_setAttributedText(id self, SEL _cmd, NSAttributedString *as) {
    IMP o = STOrig(self, _cmd);
    if (!o) return;
    if (!gStripDisplay || gStReent || ![as isKindOfClass:[NSAttributedString class]]) {
        ((void(*)(id,SEL,id))o)(self, _cmd, as);
        return;
    }

    /* ★ v76 诊断：这条路走没走、渲染结果有没有真设上去 */
    {
        static int dbg = 0;
        if (dbg < 20 && as.length > 12 &&
            [as.string rangeOfString:@"<"].location != NSNotFound) {
            dbg++;
            FLOGW(FC_UI, @"[setAttr-dbg] cls=%@ len=%lu 重入=%d user气泡=%d richOn=%d bare=%d",
                  NSStringFromClass([self class]),
                  (unsigned long)as.length,
                  gStReent ? 1 : 0,
                  BTIsUserBubble((UIView *)self) ? 1 : 0,
                  FDMRichOnFlag(), FDMRichBareFlag());
        }
    }
    STCheckRevert((UIView *)self, as.string, "setAttributedText");
    gStReent = 1;
    NSAttributedString *clean = as;
    @try {
        {
            static int dbg3 = 0;
            if (dbg3 < 30) {
                dbg3++;
                FLOGW(FC_UI, @"[attrs] %@ %lu字",
                      NSStringFromClass([self class]), (unsigned long)as.length);
            }
        }
        /* ★★★ 2026-10-17 真气泡方案：**在这里就直接铺**
         *
         *   为什么放在最前面：前面几版都挂在「渲染成功」分支里，
         *   但实测 rendered 经常是 nil（消息已是最终形态、
         *   或宿主重复 set 导致我们二次处理时没东西可改）
         *   ⇒ 那段代码根本不执行 ⇒ 按钮永远不出现。
         *
         *   这里改成：**只要文本里有 <Suggestion> 就铺**，和渲染解耦。
         */
        /* ★ 判据：这段文本能不能从「建议记忆表」里查到条目？
         *   （不能用 rangeOfString:@"Suggestion" —— 实测原始文本里
         *     根本不含该字样：AI 回复走的是流式拼接，到我们这里
         *     已经是渲染后的中间态；而记忆表是渲染那一刻写的，最可靠） */
        /* ★★★ 关键：AI 正文的承载控件**不是 UILabel**！
         *
         *   [attrs] 日志实锤：
         *     _TtGC13DeepSeek_Chat17PlainTextNodeViewOS_23ResponseMarkdownA...
         *   —— 这是个泛型 Swift 类（ResponseMarkdownNodeView），
         *   之前所有版本都写了 isKindOfClass:[UILabel class]，
         *   于是**永远为假** ⇒ 铺按钮的代码一次都没跑。
         *
         *   ⇒ 去掉 UILabel 限制，任何 UIView 都接受。
         */
        /* ★★★ 2026-10-17 深夜（v3）：**这里不再铺按钮**。
         *
         *   这里拿到的是「宿主还没渲染、也没被我们抹除」的 as，
         *   而真正显示出去的是下面的 clean（rendered / 删完标记的副本）。
         *   用 as 算矩形 ⇒ 必然错位（"位置偏上"的根源之一）。
         *
         *   ⇒ 改成：函数末尾拿到最终 clean 之后，把 clean 一起递给
         *     FDMEnsureSugBox（见 STPushSug）。
         */

        /* ============================================================
         * ★★★ 2026-10-17 P2：AI 气泡富文本（⟦FDM:模板|参数⟧）
         *
         *   这是整个 iOS 侧**唯一**需要的落点 ——
         *   宿主 markdown 渲染完，成品 NSAttributedString 必从这里过，
         *   等价于安卓的 fz2.p(AnnotatedString)。
         *
         *   处理顺序（★ 不能反）：
         *     ① 模板标记 ⟦FDM:名字|参数⟧  → 渲染模板
         *     ② 匿名包裹 ⟦FDM⟧…⟦/FDM⟧      → 内部按 HTML 子集渲染
         *        （★ 必须在③之前！否则 AI 写的包裹标记会被当成
         *          系统提示词删掉，玩家永远看不到富文本效果）
         *     ③ 裸标签模式（AI 直接写 <b> 之类）
         *     ④ 残留标记交给 FDMStripMarks 删除
         * ============================================================ */
        /* ★ 诊断：哪个控件在承载 AI 正文？（决定「可点击」怎么接） */
        {
            static int shown = 0;
            if (shown < 20) {
                const char *cn = class_getName([self class]);
                if (cn && (strstr(cn, "TextView") || strstr(cn, "Label"))) {
                    NSString *cls = [NSString stringWithUTF8String:cn];
                    static NSMutableSet *seen = nil;
                    if (!seen) seen = [NSMutableSet set];
                    if (![seen containsObject:cls]) {
                        [seen addObject:cls];
                        shown++;
                        FLOGW(FC_UI, @"[strip-target] 承载富文本的控件: %@（%lu 字）",
                              cls, (unsigned long)as.length);
                    }
                }
            }
        }

        /* ★★★ 用户气泡里的 ⟦FDM⟧…⟦/FDM⟧ 是**系统提示词**，
         *   必须删掉，绝不能当匿名包裹渲染（否则整段提示词会泄露）。 */
        BOOL isUserBubble = BTIsUserBubble((UIView *)self);

        NSAttributedString *rendered = nil;
        if (!isUserBubble) {
            rendered = FDMRichRender(as);
            if (!rendered) rendered = FDMRichRenderBare(as);
        } else {
            static int logged = 0;
            if (logged < 3 && [as.string rangeOfString:@"\u27E6"].location != NSNotFound) {
                logged++;
                FLOGW(FC_UI, @"[strip] 用户气泡：跳过富文本渲染，只删标记（%lu 字）",
                      (unsigned long)as.length);
            }
        }
        if (rendered && rendered.length > 0) {
            /* ★ 建议按钮：渲染后铺覆盖按钮（点一下就自动发送）。
             *
             * ⚠️ 判据不能看 attribute ——
             *   宿主重建 attributedString 时会把自定义 attribute 清掉。
             *   改用 FDMSugsForText()（按文本内容查表，渲染时已登记）。 */
            if ([self isKindOfClass:[UILabel class]] && rendered.length > 0) {
                extern NSArray<NSDictionary *> *FDMSugsForText(NSString *text);
                NSArray *sugs = FDMSugsForText(rendered.string);
                {
                    static int dbg = 0;
                    if (dbg < 8) {
                        dbg++;
                        FLOGW(FC_UI, @"[sug-dbg] label=%d 长度=%lu 查到=%lu 首30「%@」",
                              (int)[self isKindOfClass:[UILabel class]],
                              (unsigned long)rendered.length,
                              (unsigned long)sugs.count,
                              rendered.length > 30
                                ? [rendered.string substringToIndex:30]
                                : rendered.string);
                    }
                }
                (void)sugs;
            }
            clean = rendered;
            STNoteRichOK((UIView *)self, clean);     /* 记住"我们设过渲染版" */
            /* ★ v76 诊断：确认 rendered 到底有没有带样式属性 */
            {
                static int dbg4 = 0;
                if (dbg4 < 12) {
                    dbg4++;
                    NSDictionary *a0 = clean.length ? [clean attributesAtIndex:0
                                                               effectiveRange:NULL] : nil;
                    NSDictionary *aN = clean.length > 4
                        ? [clean attributesAtIndex:clean.length - 1 effectiveRange:NULL] : nil;
                    FLOGW(FC_UI, @"[render-out] %lu字 首属性=%lu项 尾属性=%lu项 有字体=%d 有颜色=%d 串=「%@」",
                          (unsigned long)clean.length,
                          (unsigned long)a0.count,
                          (unsigned long)aN.count,
                          a0[NSFontAttributeName] ? 1 : 0,
                          a0[NSForegroundColorAttributeName] ? 1 : 0,
                          clean.length > 24
                            ? [[clean.string substringToIndex:24]
                               stringByReplacingOccurrencesOfString:@"\n" withString:@"⏎"]
                            : clean.string);
                }
            }
            STPushSug((UIView *)self, as.string, clean);
            ((void(*)(id,SEL,id))o)(self, _cmd, clean);

            /* ★ v76 生存检测：50ms 后回头看，我们设的彩色版还在不在？
             *   在  ⇒ 数据是对的，问题在绘制层
             *   不在 ⇒ 宿主覆盖了，得换 hook 点 */
            {
                static int dg = 0;
                if (dg < 10) {
                    dg++;
                    __weak id wv = self;
                    NSString *wantHead = clean.length > 12
                        ? [clean.string substringToIndex:12] : clean.string;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(0.05 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        @try {
                            id v = wv;
                            if (!v) return;
                            NSAttributedString *now = nil;
                            if ([v respondsToSelector:@selector(attributedText)])
                                now = [v attributedText];
                            NSDictionary *a = (now.length > 0)
                                ? [now attributesAtIndex:0 effectiveRange:NULL] : nil;
                            FLOGW(FC_UI, @"[survive] 50ms后 %@字 属性%lu项 有颜色=%d 头一致=%d 现在头=「%@」",
                                  @(now.length),
                                  (unsigned long)a.count,
                                  a[NSForegroundColorAttributeName] ? 1 : 0,
                                  (now.length >= 12 && [[now.string substringToIndex:12]
                                                        isEqualToString:wantHead]) ? 1 : 0,
                                  now.length > 16 ? [[now.string substringToIndex:16]
                                                     stringByReplacingOccurrencesOfString:@"\n"
                                                     withString:@"⏎"] : now.string);
                        } @catch (NSException *e) { }
                    });
                }
            }
            gStReent = 0;
            return;
        }

        NSString *str = as.string;
        NSString *cs = FDMStripMarks(str);
        if (cs != str) {
            /* ============================================================
             * ★★★ 2026-10-17 主人实拍发现的血案：
             *   用户消息的气泡「字小一半 + 颜色变黑」。
             *
             *   旧代码：clean = [[NSAttributedString alloc] initWithString:cs]
             *     ⇒ 用纯字符串**重建**，把宿主设置的全部 attributes
             *       （字体字号、前景色、段落样式、字距…）统统丢掉
             *     ⇒ 渲染成系统默认 12pt 黑色
             *     ⇒ 因为原文很长而抹除后很短，气泡尺寸又按原文算，
             *        于是「一个小气泡里塞着小黑字」
             *
             *   正确做法：**就地删除标记区间**，其余文字的属性一动不动。
             *     NSMutableAttributedString 的 replaceCharactersInRange
             *     会保留未触及区间的全部属性。
             *
             *   ⚠️ 不查一遍「按 cs 逐字符对齐」这种花活 ——
             *     直接迭代删除开闭标记块，逻辑简单、属性一定保得住。
             * ============================================================ */
            NSMutableAttributedString *m = [as mutableCopy];
            int guard = 0;
            while (m.length > 0 && guard++ < 32) {
                NSRange a = [m.string rangeOfString:kOpen];
                if (a.location == NSNotFound) break;
                NSRange tail = NSMakeRange(a.location, m.length - a.location);
                NSRange b = [m.string rangeOfString:kClose options:0 range:tail];
                NSUInteger end = (b.location == NSNotFound)
                                 ? m.length : NSMaxRange(b);
                /* 顺手吃掉紧跟的一个换行，避免留下空行 */
                if (end < m.length) {
                    unichar nl = [m.string characterAtIndex:end];
                    if (nl == '\n') end++;
                }
                if (end <= a.location) break;
                [m replaceCharactersInRange:NSMakeRange(a.location, end - a.location)
                                 withString:@""];
            }
            /* 与 FDMStripMarks 行为对齐：吃掉开头多余的换行（同样保属性） */
            while (m.length > 0 && [m.string characterAtIndex:0] == '\n')
                [m replaceCharactersInRange:NSMakeRange(0, 1) withString:@""];
            if (m.length > 0) clean = m;
            gNStripDisplay++;
            if (gNStripDisplay <= 6)
                FLOGI(FC_UI, @"[strip] 显示层命中 -[%@ setAttributedText:] %lu→%lu 字（保留属性）",
                      NSStringFromClass([self class]),
                      (unsigned long)str.length, (unsigned long)m.length);
        }
    } @catch (NSException *e) { clean = as; }
    STPushSug((UIView *)self, as.string, clean);
    ((void(*)(id,SEL,id))o)(self, _cmd, clean);
    gStReent = 0;
}

/* 诊断计数：经由 initWithString 完成的富文本渲染次数 */
static int gNRichViaInit = 0;

/* -[NSAttributedString initWithString:] —— ★ 极其高频，必须绝对安全 */
static id st_as_initWithString(id self, SEL _cmd, NSString *s) {
    IMP o = STOrig(self, _cmd);
    if (!o) return nil;                    /* ARC 下 init 返回 nil 是合法的（调用方要判空） */
    if (!gStripDisplay || gStReent || ![s isKindOfClass:[NSString class]] || s.length < 6)
        return ((id(*)(id,SEL,id))o)(self, _cmd, s);

    /* ★★★ 2026-10-25 v74：**这条路也要渲染富文本！**
     *
     * 主人截图：AI 回复里 `<c1>` `<br>` `<c2><b>` 全当文字显示，
     * 但日志明明有「[rich] ★ 裸标签渲染 726 → 668 字」⇒ 渲染是成功的。
     *
     * 原因：宿主**走的是 `initWithString:` 这条路**（Swift 里
     * `NSAttributedString(string:)`），根本没调 `setAttributedText:` ——
     * 而原来这一支**只删标记、不渲染**，所以渲染结果被丢掉了。
     *
     * ⚠️ 这里的限制：`initWithString:` 只能返回**纯字符串**，
     *    所以只能把标签变成纯文本（去掉 `<c1>` 之类），样式由调用方自己加。
     *    真正的带样式渲染仍在 `setAttributedText:` 那一支（如果宿主会走）。
     *
     * ⚠️ 这是极高频方法，闸必须便宜：
     *    ① gStReent 防重入（上面已判）  ② 长度 < 6（上面已判）
     *    ③ **必须含 '<'** 才继续       ④ 只对 >= 12 字的做渲染尝试
     */
    if ([s rangeOfString:@"<"].location == NSNotFound)
        return ((id(*)(id,SEL,id))o)(self, _cmd, s);

    gStReent = 1;
    NSString *use = s;
    @try {
        BOOL didRich = NO;

        /* ---- ① 试着渲染（只取字符串部分；样式这里拿不到）---- */
        if (s.length >= 12) {
            extern NSAttributedString *FDMRichRenderBare(NSAttributedString *input);
            NSAttributedString *probe =
                [[NSAttributedString alloc] initWithString:s
                                                attributes:@{ NSFontAttributeName:
                                                    [UIFont systemFontOfSize:16] }];
            NSAttributedString *rich = FDMRichRenderBare(probe);
            if (rich && rich.length && ![rich.string isEqualToString:s]) {
                use = rich.string;
                didRich = YES;
                gNRichViaInit++;
                if (gNRichViaInit <= 8)
                    FLOGI(FC_UI, @"[rich] ★ initWithString 渲染 %lu → %lu 字",
                          (unsigned long)s.length, (unsigned long)use.length);
            }
        }

        /* ---- ② 没渲染成功，就只删 ⟦FDM⟧ 标记（原逻辑）---- */
        if (!didRich) {
            NSString *clean = FDMStripMarks(s);
            if (clean != s) {
                use = clean;
                gNStripDisplay++;
                if (gNStripDisplay <= 6)
                    FLOGI(FC_UI, @"[strip] 显示层命中 -[%@ initWithString:] %lu→%lu 字",
                          NSStringFromClass([self class]),
                          (unsigned long)s.length, (unsigned long)clean.length);
            }
        }
    } @catch (NSException *e) {
        use = s;
    }

    id r = ((id(*)(id,SEL,id))o)(self, _cmd, use);
    gStReent = 0;
    return r;
}

static id st_as_initWithStringAttrs(id self, SEL _cmd, NSString *s, NSDictionary *attr) {
    IMP o = STOrig(self, _cmd);
    if (!o) return nil;
    if (!gStripDisplay || gStReent || ![s isKindOfClass:[NSString class]] || s.length < 6)
        return ((id(*)(id,SEL,id,id))o)(self, _cmd, s, attr);

    /* ★★ v74：这条路**能保留样式** —— 渲染后把 rich 的属性并进 attr 里。
     *   为什么这里比 initWithString: 更好：我们手上就有 attr（宿主的字体/颜色），
     *   渲染结果可以叠加在上面，不会丢样式。 */
    if ([s rangeOfString:@"<"].location != NSNotFound && s.length >= 12) {
        gStReent = 1;
        NSAttributedString *rich = nil;
        @try {
            extern NSAttributedString *FDMRichRenderBare(NSAttributedString *input);
            NSAttributedString *probe =
                [[NSAttributedString alloc] initWithString:s
                                                attributes:attr ?: @{ NSFontAttributeName:
                                                    [UIFont systemFontOfSize:16] }];
            rich = FDMRichRenderBare(probe);
        } @catch (NSException *e) { rich = nil; }
        gStReent = 0;

        if (rich && rich.length && ![rich.string isEqualToString:s]) {
            /* 用 rich 的属性（颜色/bold 都在），但**把字体留给宿主** */
            NSMutableAttributedString *m = [rich mutableCopy];
            UIFont *hostFont = attr[NSFontAttributeName];
            if ([hostFont isKindOfClass:[UIFont class]] && m.length) {
                /* 只覆盖纯字号（保留 bold trait 由 rich 决定） */
                [m enumerateAttribute:NSFontAttributeName
                              inRange:NSMakeRange(0, m.length)
                              options:0
                           usingBlock:^(UIFont *f, NSRange r, BOOL *stop) {
                    if (![f isKindOfClass:[UIFont class]]) return;
                    CGFloat size = hostFont.pointSize;
                    UIFont *nf = (f.fontDescriptor.symbolicTraits & UIFontDescriptorTraitBold)
                        ? [UIFont boldSystemFontOfSize:size]
                        : [UIFont systemFontOfSize:size];
                    [m addAttribute:NSFontAttributeName value:nf range:r];
                }];
            }
            id r = nil;
            gStReent = 1;
            @try {
                /* 用「纯字符串 + 我们已经算好的属性」重建 —— 传 rich.string 会丢属性，
                 * 所以这里用 initWithAttributedString 的等价做法：先调原 init 再替换。 */
                NSAttributedString *tmp =
                    [[NSAttributedString alloc] initWithAttributedString:m];
                r = tmp;
            } @catch (NSException *e) { r = nil; }
            gStReent = 0;
            if (r) {
                gNRichViaInit++;
                if (gNRichViaInit <= 8)
                    FLOGI(FC_UI, @"[rich] ★ initWithString:attributes: 渲染 %lu → %lu 字",
                          (unsigned long)s.length, (unsigned long)m.length);
                return r;
            }
        }
    }

    gStReent = 1;
    NSString *clean = s;
    @try {
        clean = FDMStripMarks(s);
        if (clean != s) {
            gNStripDisplay++;
            if (gNStripDisplay <= 6)
                FLOGI(FC_UI, @"[strip] 显示层命中 -[%@ initWithString:attributes:] %lu→%lu 字",
                      NSStringFromClass([self class]),
                      (unsigned long)s.length, (unsigned long)clean.length);
        }
    } @catch (NSException *e) { clean = s; }
    id r = ((id(*)(id,SEL,id,id))o)(self, _cmd, clean, attr);
    gStReent = 0;
    return r;
}

/* -[CATextLayer setString:] */
static void st_layerSetString(id self, SEL _cmd, id val) {
    IMP o = STOrig(self, _cmd);
    if (!o) return;
    if (!gStripDisplay || gStReent || ![val isKindOfClass:[NSString class]] ||
        [(NSString *)val length] < 6) {
        ((void(*)(id,SEL,id))o)(self, _cmd, val);
        return;
    }
    NSString *clean = FDMStripMarks(val);
    if (clean != val) {
        gNStripDisplay++;
        if (gNStripDisplay <= 6)
            FLOGI(FC_UI, @"[strip] 显示层命中 CATextLayer setString %lu→%lu 字",
                  (unsigned long)[(NSString *)val length], (unsigned long)clean.length);
    }
    ((void(*)(id,SEL,id))o)(self, _cmd, clean);
}

/* ============ 五、安装（只装显示层） ============ */

/* ============================================================
 * ★★ 2026-10-17：数据库层抹除**永久放弃**
 *
 * 为什么放弃（血泪史）：
 *   iOS 的 WCDBSwift 把 sqlite3 **静态编进自己**（不依赖 libsqlite3.dylib），
 *   所以我们 hook 不到系统那份。唯一的路是 inline hook 改它 __TEXT 段——
 *   而这条路踩了三个坑，全部无法收场：
 *
 *     ① bind_text16 的地址 = bind_text + 8，**不是函数开头**，
 *        是从中间切进去的一小段，含 adrp（PC 相对）
 *        ⇒ 搬到跳板执行必然算错地址 ⇒ SIGSEGV
 *
 *     ② bind_blob 第 0 条是 tbnz，目标是 +0x1c（超出 8 字节覆盖窗口）
 *        ⇒ 无法在 8 字节内表达 ⇒ 只能放弃
 *
 *     ③ 就算跳板逻辑正确，改了带签名的 __TEXT 段之后，
 *        iOS 在特定路径上仍会触发 SIGBUS
 *
 *   而收益始终是 **0**：每次启动的调用计数都是 text=0 blob=0 text16=0
 *   ⇒ 说明消息根本不是本地写入的，是服务端同步下来的。
 *
 *   ⇒ 这条路从一开始方向就错了。**彻底删除，不再尝试。**
 *
 * 保留的：显示层抹除（UILabel / UITextView / NSAttributedString / CATextLayer）
 *         纯函数 FDMStripMarks / FDMHasMarks
 * ============================================================ */

static BOOL gInstalled = NO;

/* ============================================================
 * ★★★ 历史消息补扫（2026-10-17 深夜 · 修"历史消息裸奔"）
 *
 *   问题：strip hook 装在启动 6 秒后，而 App 在 1~2 秒内就把
 *   聊天记录从 DB 画到屏幕上了 —— 那批文字**没经过任何 hook**
 *   ⇒ 屏幕上留着一堆 ⟦FDM:tip|…⟧ 和 <Suggestion>…
 *   （主人 22:41 的截图就是这个，要杀掉重进才好看）
 *
 *   ⇒ 做法：hook 装完 1.5 秒起做 3 轮补扫（3s / 8s / 20s），
 *     遍历所有 UILabel / UITextView，凡文本里还有标记的，
 *   把**已经设好的** attributedText / text 再 set 一次 ——
 *     这一次会经过我们的 wrapper，于是被洗干净 + 上富文本。
 *
 *   成本：遍历 ~600 视图 × 3 次，只在启动后做，之后再也不跑。
 * ============================================================ */
static void STDeepSweepOnce(int round) {
    @try {
        UIWindow *w = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *x in ((UIWindowScene *)sc).windows)
                if (x.windowLevel == UIWindowLevelNormal) { w = x; break; }
            if (w) break;
        }
        if (!w) return;

        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:w];
        int visited = 0, fixedLabel = 0, fixedTV = 0;
        while (stack.count && visited++ < 4000) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            for (UIView *sv in v.subviews) [stack addObject:sv];

            if ([v isKindOfClass:[UILabel class]]) {
                UILabel *lb = (UILabel *)v;
                NSString *t = lb.attributedText.length ? lb.attributedText.string : lb.text;
                if (t.length && FDMHasMarks(t)) {
                    if (lb.attributedText.length) lb.attributedText = lb.attributedText;
                    else { NSString *x = lb.text; lb.text = x; }
                    fixedLabel++;
                }
            } else if ([v isKindOfClass:[UITextView class]]) {
                UITextView *tv = (UITextView *)v;
                NSString *t = tv.attributedText.length ? tv.attributedText.string : tv.text;
                if (t.length && FDMHasMarks(t)) {
                    if (tv.attributedText.length) tv.attributedText = tv.attributedText;
                    else { NSString *x = tv.text; tv.text = x; }
                    fixedTV++;
                }
            }
        }
        if (fixedLabel || fixedTV) {
            FLOGW(FC_UI, @"[strip] 补扫 #%d：访问 %d 视图，重设 label=%d textview=%d",
                  round, visited, fixedLabel, fixedTV);
        } else {
            FLOGI(FC_UI, @"[strip] 补扫 #%d：访问 %d 视图，无需重设", round, visited);
        }
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[strip] 补扫异常: %@", e.reason);
    }
}

void FDMStripDeepSweep(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ STDeepSweepOnce(1); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ STDeepSweepOnce(2); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ STDeepSweepOnce(3); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ STDeepSweepOnce(4); });
}

/** ★ v78：独立的常驻巡检定时器（0.5 秒一拍，内部还有 0.4s 节流）。
 *  为什么不挂在音乐定时器上：音乐可能被用户关掉（on=false），
 *  那样定时器根本不建 ⇒ 富文本巡检跟着一起死。富文本的事归富文本管。 */
static dispatch_source_t gEnsureTimer = nil;

/* 前置声明（定义在 STRichify 之后） */
void FDMStripEnsureRichTick(void);

static void STStartEnsureTimer(void) {
    if (gEnsureTimer) return;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                 dispatch_get_main_queue());
    if (!t) return;
    dispatch_source_set_timer(t,
                              dispatch_time(DISPATCH_TIME_NOW, 1ull * NSEC_PER_SEC),
                              500ull * NSEC_PER_MSEC,
                              200ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{ FDMStripEnsureRichTick(); });
    dispatch_resume(t);
    gEnsureTimer = t;
    FLOGI(FC_UI, @"[ensure] 巡检定时器已启动（0.5s 一拍，内部 0.4s 节流）");
}

/* ============================================================
 * ★★★ v76：TimeKit 最后一公里 —— 补 hook NSTextStorage
 *
 * 问题（2026-10-25 真机确诊）：
 *   AI 正文的承载控件是
 *     `_TtGC13DeepSeek_Chat17PlainTextNodeViewOS_23ResponseMarkdownAdapter_`
 *   （Swift 泛型特化类，本质是 UITextView）
 *
 *   我们的 `setAttributedText:` 确实生效了 —— 日志「[render-out] 尾属性=6项」
 *   证明渲染结果**带着颜色/粗体**，也调用了原实现。
 *
 *   但屏幕上还是裸标签 ⇒ 宿主在 UITextView 内部**用 TextKit 重新排版**，
 *   排版时按自己的 markdown 规则**重建了 attributes**，把我们的覆盖掉。
 *
 *   TextKit 的最终数据源是 `NSTextStorage`（NSMutableAttributedString 子类）：
 *     UITextView.attributedText = X
 *       → textStorage.setAttributedString(X)   ← 数据存这儿
 *       → layoutManager 排版（读 textStorage）
 *
 *   ⇒ 在这一层再渲染一次，排版读到的就是我们想要的了。
 * ============================================================ */

/* 诊断计数：TextStorage 层渲染次数 */
static int gNRichViaTextStorage = 0;

/** 对一段 attributedString 就地做富文本渲染（保留原有属性作底）。*/
static NSAttributedString *STRichify(NSAttributedString *in) {
    if (![in isKindOfClass:[NSAttributedString class]] || in.length < 12) return nil;
    if ([in.string rangeOfString:@"<"].location == NSNotFound) return nil;

    extern NSAttributedString *FDMRichRenderBare(NSAttributedString *input);
    return FDMRichRenderBare(in);
}

/* ============================================================
 * ★★★ v78：状态驱动巡检 —— 「EnsureRich」
 *
 * 为什么放弃「找谁覆盖」：
 *   2026-10-25 真机诊断链已经证明：
 *     ① 渲染逻辑对（属性 4→6 项）
 *     ② 数据存活（[survive] 50ms 后属性5项、有颜色、内容一致）
 *     ③ 思考块正常显示彩色，**只有回复块完成瞬间变裸**
 *     ④ 回复块完成后**不再走 setAttributedText**（REVERT 只命中 Thinking）
 *   ⇒ 说明宿主的**绘制**没读我们设的 attributes，或者中途又用原文重排了。
 *     这个点在 app 二进制里（符号都没了），硬追成本极高。
 *
 * 换打法 —— 和玻璃(EnsureAttached) / 气泡(BubbleEnsureAll) 一模一样的思路：
 *   **不问"谁改的"，只问"结果对不对"**。每 0.4 秒扫一遍屏幕上的
 *   PlainTextNodeView，发现 attributedText 里还带 < 标签 ⇒ 现场渲染重设。
 *   状态驱动天然免疫"事件漏了"。
 *
 * 成本控制：
 *   · 只走可见 window 的视图树，且只在「字数 < 8000」的控件上干活
 *   · 快速闸：字符串不含 '<' 立刻跳过（绝大多数控件）
 *   · 每个控件记一个"上次已修正的串指纹"，同一串不重复渲染
 * ============================================================ */

static NSMapTable<UIView *, NSString *> *gEnsuredFP = nil;
static int gNEnsureFixed = 0;

static void STEnsureRichOnce(void) {
    @try {
        UIWindow *w = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *x in ((UIWindowScene *)sc).windows) {
                if (!w && x.windowLevel == UIWindowLevelNormal) w = x;
            }
        }
        if (!w) return;

        if (!gEnsuredFP) gEnsuredFP = [NSMapTable weakToStrongObjectsMapTable];

        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:w];
        int visited = 0, fixed = 0;

        while (stack.count && visited++ < 3000) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            for (UIView *sv in v.subviews) [stack addObject:sv];

            /* 只看带 attributedText 的控件 */
            if (![v respondsToSelector:@selector(attributedText)] ||
                ![v respondsToSelector:@selector(setAttributedText:)]) continue;

            NSAttributedString *cur = nil;
            @try { cur = [(id)v attributedText]; } @catch (NSException *e) { continue; }
            if (![cur isKindOfClass:[NSAttributedString class]]) continue;
            if (cur.length < 8 || cur.length > 8000) continue;

            NSString *str = cur.string;
            /* ★ 快速闸：不含 '<' 立刻跳过（命中率 99.9% 都不含） */
            if ([str rangeOfString:@"<"].location == NSNotFound) continue;

            /* 同一个串修正过就别重复干（避免每 0.4s 重渲染） */
            NSString *prev = nil;
            @try { prev = [gEnsuredFP objectForKey:v]; } @catch (NSException *e) { }
            if (prev && [prev isEqualToString:str]) continue;

            /* 干正事：渲染 + 重设 */
            NSAttributedString *rich = nil;
            @try {
                rich = STRichify(cur);
            } @catch (NSException *e) { rich = nil; }
            if (!rich || !rich.length) continue;
            if ([rich.string isEqualToString:str]) continue;   /* 没变化，跳过 */

            @try {
                [(id)v setAttributedText:rich];
                [gEnsuredFP setObject:str forKey:v];           /* 记住原串，避免重复 */
                fixed++;
                gNEnsureFixed++;
                if (gNEnsureFixed <= 12) {
                    FLOGI(FC_UI, @"[ensure] ★ 巡检修正 %@ %lu→%lu 字",
                          NSStringFromClass([v class]),
                          (unsigned long)str.length, (unsigned long)rich.length);
                }
            } @catch (NSException *e) { }
        }
        if (fixed) {
            FLOGW(FC_UI, @"[ensure] 本轮修正 %d 个控件（累计 %d）", fixed, gNEnsureFixed);
        }
    } @catch (NSException *e) { }
}

/** 由 FDMMusicTick 之类的高频定时器调用（内部自带节流）。 */
void FDMStripEnsureRichTick(void) {
    static CFAbsoluteTime last = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last < 0.4) return;      /* 节流：0.4 秒一次 */
    last = now;
    STEnsureRichOnce();
}

/* -[NSTextStorage setAttributedString:] —— TextKit 数据源换血 */
static void st_ts_setAttributedString(id self, SEL _cmd, NSAttributedString *as) {
    IMP o = STOrig(self, _cmd);
    if (!o) return;
    if (gStReent || ![as isKindOfClass:[NSAttributedString class]]) {
        ((void(*)(id,SEL,id))o)(self, _cmd, as);
        return;
    }

    gStReent = 1;
    NSString *use = nil;
    NSAttributedString *out = as;
    @try {
        out = STRichify(as) ?: as;
        if (out != as) {
            use = out.string;
            if (gNRichViaTextStorage < 10) {
                gNRichViaTextStorage++;
                FLOGI(FC_UI, @"[rich] ★ TextStorage 渲染 %lu → %lu 字（属性%lu项）",
                      (unsigned long)as.length, (unsigned long)out.length,
                      (unsigned long)(out.length ? [out attributesAtIndex:0
                                                         effectiveRange:NULL].count : 0));
            }
        }
    } @catch (NSException *e) { out = as; }
    ((void(*)(id,SEL,id))o)(self, _cmd, out);
    (void)use;
    gStReent = 0;
}

/* -[NSTextStorage replaceCharactersInRange:withAttributedString:] —— 增量更新也要管 */
static void st_ts_replace(id self, SEL _cmd, NSRange r, NSAttributedString *with) {
    IMP o = STOrig(self, _cmd);
    if (!o) return;
    if (gStReent || ![with isKindOfClass:[NSAttributedString class]]) {
        ((void(*)(id,SEL,NSRange,id))o)(self, _cmd, r, with);
        return;
    }
    gStReent = 1;
    NSAttributedString *out = with;
    @try { out = STRichify(with) ?: with; }
    @catch (NSException *e) { out = with; }
    ((void(*)(id,SEL,NSRange,id))o)(self, _cmd, r, out);
    gStReent = 0;
}

int FDMStripInstall(void) {
    if (gInstalled) return 1;
    int n = 0;
    @try {
        Class lb = [UILabel class];
        Class tv = [UITextView class];
        Class tf = [UITextField class];

        if (STSwap(lb, "setText:", (IMP)st_setText)) n++;
        if (STSwap(lb, "setAttributedText:", (IMP)st_setAttributedText)) n++;
        if (STSwap(tv, "setText:", (IMP)st_setText)) n++;
        if (STSwap(tv, "setAttributedText:", (IMP)st_setAttributedText)) n++;
        if (STSwap(tf, "setText:", (IMP)st_setText)) n++;

        if (STSwap([NSAttributedString class], "initWithString:", (IMP)st_as_initWithString)) n++;
        if (STSwap([NSAttributedString class], "initWithString:attributes:",
                   (IMP)st_as_initWithStringAttrs)) n++;
        if (STSwap([NSMutableAttributedString class], "initWithString:",
                   (IMP)st_as_initWithString)) n++;

        Class layerCls = NSClassFromString(@"CATextLayer");
        if (layerCls) {
            if (STSwap(layerCls, "setString:", (IMP)st_layerSetString)) n++;
        }

        /* ★★★ v76：TextKit 数据源
         *
         * ⚠️ `NSTextStorage` 是**类簇**：真实对象是 `NSConcreteTextStorage`。
         *   只 hook 抽象父类的话，`class_addMethod` 加在父类上，
         *   而子类自己实现了该方法 ⇒ **永远命中不到**（实测零调用）。
         *
         *   ⇒ 必须把**运行时真实的子类**也一起 hook。
         *     做法：实例化一个 NSTextStorage，看它的真实类名。 */
        {
            Class tsCls = [NSTextStorage class];
            NSMutableSet<NSString *> *seen = [NSMutableSet set];
            NSMutableArray<Class> *targets = [NSMutableArray arrayWithObject:tsCls];

            @try {
                NSTextStorage *probe = [[NSTextStorage alloc] init];
                if (probe) {
                    Class real = object_getClass(probe);
                    if (real && real != tsCls) {
                        [targets addObject:real];
                        FLOGI(FC_UI, @"[strip] NSTextStorage 真实类 = %@",
                              NSStringFromClass(real));
                    }
                }
            } @catch (NSException *e) { }

            /* 再把 NSString/NSAttributedString 的所有已加载子类里
             * 名字像 TextStorage 的也加上（覆盖其它私有实现） */
            @try {
                int cnt = objc_getClassList(NULL, 0);
                if (cnt > 0) {
                    Class *all = (Class *)malloc(sizeof(Class) * (size_t)cnt);
                    if (all) {
                        cnt = objc_getClassList(all, cnt);
                        for (int i = 0; i < cnt; i++) {
                            const char *cn = class_getName(all[i]);
                            if (!cn) continue;
                            if (strstr(cn, "TextStorage") && all[i] != tsCls)
                                [targets addObject:all[i]];
                        }
                        free(all);
                    }
                }
            } @catch (NSException *e) { }

            for (Class t in targets) {
                NSString *nm = NSStringFromClass(t);
                if ([seen containsObject:nm]) continue;
                [seen addObject:nm];
                if (STSwap(t, "setAttributedString:", (IMP)st_ts_setAttributedString)) {
                    n++;
                    FLOGI(FC_UI, @"[strip] ✓ hook %@ setAttributedString:", nm);
                }
                if (STSwap(t, "replaceCharactersInRange:withAttributedString:",
                           (IMP)st_ts_replace)) {
                    n++;
                    FLOGI(FC_UI, @"[strip] ✓ hook %@ replaceCharactersInRange:", nm);
                }
            }
            FLOGI(FC_UI, @"[strip] TextStorage 层处理完 %lu 个类", (unsigned long)seen.count);
        }

        FLOGW(FC_HOOK, @"[strip] 安装完成：%d 处（仅显示层，数据库层已弃用）", n);
        gInstalled = (n > 0);
        if (gInstalled) {
            /* ★ 装完 0.6 秒开始补扫（等宿主把首屏画完） */
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ FDMStripDeepSweep(); });
            /* ★ v78：启动常驻巡检（治"回复完成瞬间变裸"） */
            STStartEnsureTimer();
        }
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[strip] 安装异常: %@", e.reason);
    }
    return gInstalled ? 1 : 0;
}
