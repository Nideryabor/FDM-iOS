/* ============================================================
 * FDMXray —— 宿主渲染层「X 光机」🐲
 *
 * 目的（P1 · 明文承载 + 渲染抹除）：
 *   安卓那套「⟦FDM⟧…⟦/FDM⟧ 明文拼进 prompt，渲染层抹显示」在 iOS 上
 *   需要一个**抹除落点**。iOS 是 Swift + UIKit，没有安卓那个
 *   `AnnotatedString.Builder` 唯一汇流点，所以要先把候选方法表摸出来。
 *
 * 三个能力（都是只读 / 只记录，绝不改宿主数据）：
 *   1) DumpClasses   —— 把宿主里名字像「消息 / 文本 / Markdown」的类
 *                       连同方法表打进日志（一次就够，之后照着挑）
 *   2) InstallProbe  —— 给几个**低风险**渲染入口挂「检测钩子」：
 *                       发现字符串里含 ⟦FDM 标记就记一行 + 前几帧调用栈，
 *                       **不修改任何东西**
 *   3) StripMarks    —— 纯函数：把 ⟦FDM⟧…⟦/FDM⟧ 整块抹掉（后续抹除器用它）
 *
 * 铁律遵守：
 *   • 钩子内只读参数指针，不调宿主方法
 *   • 只在「命中标记」时才写日志（O(1) 长度预检，绝大多数调用直接返回）
 *   • 全部包 @try，出错静默
 * ============================================================ */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "FLog.h"

/* ★ 提前定义：DumpClasses / Install 都要用它 */
static BOOL gXrayOn = NO;

/* 定界符常量（抹除函数在 FDMStrip.m，这里只做勘察用） */
extern NSString *FDMStripMarks(NSString *s);
extern BOOL FDMHasMarks(NSString *s);

/* ------------------------------------------------------------------
 * 1. 类方法表 dump
 * ------------------------------------------------------------------ */
static BOOL XrayIsHostClass(Class cls) {
    const char *img = class_getImageName(cls);
    if (!img) return NO;
    /* 宿主主二进制叫 "DeepSeek Chat"；Swift 扩展也可能在 framework 里 */
    return (strstr(img, "DeepSeek") != NULL);
}

/* 只挑跟「把文本画到屏幕上」有关的类名 */
static BOOL XrayNameInteresting(const char *name) {
    if (!name) return NO;
    static const char *kw[] = {
        "Message", "Bubble", "Markdown", "TextView", "TextLayout",
        "Attributed", "Session", "Content", "RichText", "Style",
    };
    for (size_t k = 0; k < sizeof(kw)/sizeof(kw[0]); k++) {
        if (strstr(name, kw[k])) return YES;
    }
    return NO;
}

/* 只要方法名里跟「设值 / 渲染」有关的，省日志 */
static BOOL XraySelInteresting(SEL s) {
    if (!s) return NO;
    const char *n = sel_getName(s);
    if (!n) return NO;
    static const char *kw[] = {
        "setText", "Text", "setString", "String", "Attributed",
        "render", "Render", "layout", "Layout", "configure",
        "display", "Display", "apply", "Apply", "update", "Update",
    };
    for (size_t k = 0; k < sizeof(kw)/sizeof(kw[0]); k++) {
        if (strstr(n, kw[k])) return YES;
    }
    return NO;
}

void FDMXrayDumpClasses(void) {
    /* ★ 默认不 dump：遍历 5 万个类很贵，而且只在「找 Hook 落点」时才需要 */
    if (!gXrayOn) { FLOGI(FC_HOOK, @"[xray] 未开启，跳过类表勘察"); return; }
    @autoreleasepool {
        unsigned int total = 0;
        Class *all = objc_copyClassList(&total);
        if (!all) return;

        int dumped = 0, matched = 0;
        FLOGI(FC_HOOK, @"=== Xray 类表勘察开始（宿主类 %u 个里挑）===", total);

        for (unsigned int i = 0; i < total && dumped < 90; i++) {
            Class c = all[i];
            if (!XrayIsHostClass(c)) continue;
            const char *cn = class_getName(c);
            if (!XrayNameInteresting(cn)) continue;
            matched++;

            /* 本类挑出来的方法名（上限 24 个，够认路） */
            NSMutableArray *sels = [NSMutableArray array];
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(c, &mc);
            if (ms) {
                for (unsigned int j = 0; j < mc && sels.count < 24; j++) {
                    if (XraySelInteresting(method_getName(ms[j]))) {
                        [sels addObject:@(sel_getName(method_getName(ms[j])))];
                    }
                }
                free(ms);
            }
            Class sup = class_getSuperclass(c);
            FLOGI(FC_HOOK, @"  [xray] %s ⊂ %s (%u 方法) : %@",
                  cn, sup ? class_getName(sup) : "-", mc,
                  [sels componentsJoinedByString:@", "]);
            dumped++;
        }
        free(all);
        FLOGI(FC_HOOK, @"=== Xray 类表勘察结束：命中 %d 类，打印 %d 类 ===", matched, dumped);
        FLogFlush();
    }
}

/* ------------------------------------------------------------------
 * 2. 检测钩子（只记录，不改）
 * ------------------------------------------------------------------ */
static int   gXrayHits = 0;
static BOOL  gXrayInHook = NO;   /* 防递归 */

typedef void (*SetObjIMP)(id, SEL, id);

static void Xray_NoteHit(id self, SEL _cmd, id val) {
    if (gXrayInHook) return;
    gXrayInHook = YES;
    @try {
        NSString *s = nil;
        if ([val isKindOfClass:[NSString class]]) s = val;
        else if ([val isKindOfClass:[NSAttributedString class]]) s = [(NSAttributedString *)val string];
        if (s && FDMHasMarks(s)) {
            gXrayHits++;
            if (gXrayHits <= 12) {
                NSArray *st = [NSThread callStackSymbols];
                NSMutableString *brief = [NSMutableString string];
                NSUInteger start = 2;
                for (NSUInteger i = start; i < st.count && i < start + 5; i++) {
                    [brief appendFormat:@"\n      %@", st[i]];
                }
                FLOGI(FC_UI, @"★[xray] 命中 -[%@ %@] 长度%lu 含标记%@",
                      NSStringFromClass([self class]), NSStringFromSelector(_cmd),
                      (unsigned long)s.length, brief);
            } else if (gXrayHits % 50 == 0) {
                FLOGI(FC_UI, @"★[xray] 累计命中 %d 次（同类不再展开栈）", gXrayHits);
            }
        }
    } @catch (NSException *e) {
        /* 静默 */
    }
    gXrayInHook = NO;
}

/* 通用：给一个类的一个 setter 挂检测（幂等） */
static void Xray_HookSetter(Class c, SEL sel) {
    if (!c || !sel) return;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    IMP old = method_getImplementation(m);
    if (!old || old == (IMP)Xray_NoteHit) return;
    /* 只处理「一个对象参数」的签名 */
    const char *types = method_getTypeEncoding(m);
    if (!types || types[0] != 'v' || types[1] != '@' || types[2] != ':') return;
    /* 替换实现为通用入口（保存原 IMP 以便透传？ 我们不改宿主数据，
       但必须调用原实现，否则界面会不刷新 —— 用 imp_implementationWithBlock 包一层 */
    IMP wrapper = imp_implementationWithBlock(^(id self_, id val) {
        Xray_NoteHit(self_, sel, val);
        ((SetObjIMP)old)(self_, sel, val);
    });
    method_setImplementation(m, wrapper);
}

static BOOL Xray_HookHostClass(const char *cn) {
    Class c = objc_getClass(cn);
    if (!c) return NO;
    static const char *sels[] = { "setText:", "setAttributedText:" };
    BOOL any = NO;
    for (size_t i = 0; i < sizeof(sels)/sizeof(sels[0]); i++) {
        SEL s = sel_registerName(sels[i]);
        if (class_getInstanceMethod(c, s)) { Xray_HookSetter(c, s); any = YES; }
    }
    if (any) FLOGI(FC_HOOK, @"[xray] 已挂检测: %s", cn);
    return any;
}

void FDMXrayInstall(void) {
    if (!gXrayOn) { FLOGI(FC_HOOK, @"[xray] 未开启（配置里开 xray）"); return; }
    @try {
        /* UILabel / UITextView：UIKit 侧最后一道，Swift 自定义视图可能绕过 */
        Xray_HookHostClass("UILabel");
        Xray_HookHostClass("UITextView");
        /* 宿主自己的文本视图（名字来自类表，找不到就跳过） */
        static const char *hosts[] = {
            "_TtC13DeepSeek_Chat20UserHintTextView",
            "_TtC13DeepSeek_Chat9MarkdownX",
        };
        for (size_t i = 0; i < sizeof(hosts)/sizeof(hosts[0]); i++) Xray_HookHostClass(hosts[i]);

        FLOGI(FC_HOOK, @"[xray] 检测钩子安装完成（只记录，不改数据）");
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[xray] 安装失败: %@", e.reason);
    }
}

void FDMXraySetEnabled(BOOL on) { gXrayOn = on; }
int  FDMXrayHitCount(void) { return gXrayHits; }
