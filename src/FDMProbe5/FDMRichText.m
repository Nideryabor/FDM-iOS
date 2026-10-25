// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用

/* ============================================================
 * FDMRichText —— 「AI 气泡富文本」iOS 实现 🐲
 *
 * 对标安卓 GmRichText（44KB）+ GmRichTextHook（40KB），
 * 但 iOS 这边**只需要一个落点**：
 *
 *   安卓要 hook Compose 的 fz2.p(AnnotatedString)
 *   iOS 直接 hook -[UILabel setAttributedText:] 就够了 ——
 *   宿主 markdown 渲染完，成品 NSAttributedString 一定从这里过。
 *
 * ------------------------------------------------------------
 * 标记语法（与安卓对齐）
 *
 *   ⟦FDM:模板名⟧                 渲染模板（无参）
 *   ⟦FDM:模板名|晴|26℃⟧          渲染模板，模板里 {1}=晴  {2}=26℃
 *   ⟦FDM⟧<b>内容</b>⟦/FDM⟧       匿名包裹：内部按 HTML 子集渲染
 *
 *   ⚠️ 为什么「匿名包裹」必须有：模型从系统提示词的 ⟦FDM⟧…⟦/FDM⟧
 *      中学了样，会主动写包裹式标记（安卓真机截图里就是这样）。
 *      识别不了 ⇒ 整段原样露出 ⇒ 功能看着「只成功一半」。
 *
 *   ⚠️ 判定优先级（顺序不能反）：
 *      ① ⟦FDM:xxx⟧   ← 模板模式（有冒号）
 *      ② ⟦FDM⟧…⟦/FDM⟧ ← 匿名包裹（渲染，不是删除）
 *      ③ 残留标记 → 交给 FDMStrip 删除
 *      如果先做③，AI 写的包裹标记会被当系统提示词删掉，看不见效果。
 *
 * ------------------------------------------------------------
 * 模板 = HTML 子集
 *
 *   <b>粗</b>  <i>斜</i>  <u>下划线</u>  <s>删除线</s>（<del> 同义）
 *   <c1>色板1</c>        <c#FF0000>直给色</c>
 *   <bg1>背景色板1</bg>   <bg#FFFF00>直给背景</bg>
 *   <br>                 换行
 *
 *   嵌套随便套（我们逐层 addAttribute，自然合并）。
 *   不认识的标签**整段丢掉**，绝不让尖括号漏到界面上。
 *
 * ------------------------------------------------------------
 * ★ 铁律（来自宿主踩坑 + 安卓 13 条）
 *
 *   1. hook 内只做内存操作，绝不 IO —— 所以配置**一次性缓存**在静态变量里
 *   2. 每次进入先做「有没有可能命中」的快检（长度 + 子串），绝大多数调用直接透传
 *   3. 清洗/重建富文本**永远** mutableCopy + 区间操作，
 *      绝不用 initWithString: 重建（会丢 attributes ⇒ 小号黑字，见文档 18）
 *   4. 必须防重入（我们自己 addAttribute 可能再触发 hook）
 * ============================================================ */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "FLog.h"
#import "FDMConfig.h"

/* ============ 一、定界符 ============ */

static NSString *const kTplOpen   = @"\u27E6" @"FDM:";      /* ⟦FDM: */
static NSString *const kTplClose  = @"\u27E7";              /* ⟧      */
static NSString *const kAnonOpen  = @"\u27E6" @"FDM" @"\u27E7";   /* ⟦FDM⟧  */
static NSString *const kAnonClose = @"\u27E6" @"/FDM" @"\u27E7";  /* ⟦/FDM⟧ */

/* ★ 建议按钮：<Suggestion>显示文字</Suggestion>
 *            <Suggestion>显示文字|真正发送的话</Suggestion>
 *   为什么不复用 ⟦FDM:⟧ —— 这是**裸 HTML 标签**形态，和标记族分开判定，
 *   互相不会撞车（<Suggestion> 里不含 ⟦FDM 的任何子串）。 */
static NSString *const kSugOpen  = @"<Suggestion>";
static NSString *const kSugClose = @"</Suggestion>";
static NSString *const kSugOpen2 = @"<suggestion>";   /* 容错：模型可能小写 */
static NSString *const kSugClose2 = @"</suggestion>";

/* ★ 点歌：⟦DJ:歌名-歌手⟧ / ⟦DJ:歌名-歌手|hidden⟧
 *   对标安卓 `GmMusicDj`（3.69.0 起的约定）。
 *
 *   ⚠️ 加一个新标记族要动**三处**（安卓 3.69.4 的血案：只改两处 ⇒
 *      渲染前的快速闸漏了 DJ 族 ⇒ 模型写了标记但永远不触发）：
 *        ① 这里的定界符常量
 *        ② FDMRichMaybeAffected 的快速闸
 *        ③ 下面主扫描循环里的 kind 判定
 */
static NSString *const kDjOpen  = @"\u27E6" @"DJ:";   /* ⟦DJ: */
static NSString *const kDjClose = @"\u27E7";          /* ⟧     */

/* ★ 建议按钮的「可点击」标记：把 payload 编码进 URL scheme，
 *   配合 UITapGestureRecognizer 反解。
 *   为什么不用 .link 属性 —— AI 正文承载控件是 UILabel，
 *   UILabel 不响应 .link（只有 UITextView 才响应）。 */
NSString *const kFDMSugScheme = @"fdm-sug://";

/* 前置声明（定义在后面） */
static void RegisterSugs(NSAttributedString *out);

/* ★ 全局注册表：显示文字 → 真正要发的内容
 *   为什么不用 attribute：实测 enumerateAttribute 拿不到
 *   （宿主/我们自己的 mutableCopy 都可能丢自定义 key）。
 *   ⇒ 在**生成那一刻**就记住「这段文字对应哪个 payload」，最可靠。 */
static NSMutableArray<NSDictionary *> *gSugRegistry = nil;
NSUInteger gSugRegistryCount(void) { return gSugRegistry.count; }

static void RememberSug(NSString *show, NSString *payload) {
    if (!show.length || !payload.length) return;
    if (!gSugRegistry) gSugRegistry = [NSMutableArray array];
    if (gSugRegistry.count > 300) [gSugRegistry removeAllObjects];
    /* 去重（同一条建议可能被渲染多次） */
    for (NSDictionary *d in gSugRegistry) {
        if ([d[@"show"] isEqualToString:show] && [d[@"payload"] isEqualToString:payload])
            return;
    }
    [gSugRegistry addObject:@{ @"show": show, @"payload": payload }];
    FLOGW(FC_UI, @"[sug] 已记住「%@」→「%@」", show, payload);
}

/* 已知的富文本分组 id（FDMFeatures 里定义） */
static NSString *const kRichGroup = @"richtext";

/* ============ 二、缓存（hook 内绝不 IO） ============ */

static BOOL      gRichOn      = NO;   /* 富文本总开关 */
static BOOL      gBareHTML    = NO;   /* 裸标签模式（AI 直接写 <b> 也生效） */
static NSString *gTplPool     = nil;  /* 模板池原文：每行「名字|HTML」 */
static NSDictionary<NSString *, NSString *> *gColors = nil; /* c1..c9 → #RRGGBB */

static void FDMReloadRichCache(void) {
    @autoreleasepool {
        FDMConfig *C = [FDMConfig shared];
        @try {
            gRichOn   = [C boolFor:kRichGroup key:@"rich_on"];
            gBareHTML = [C boolFor:kRichGroup key:@"bare_html"];
            gTplPool  = [C stringFor:kRichGroup key:@"templates"] ?: @"";
            NSMutableDictionary *m = [NSMutableDictionary dictionary];
            for (int i = 1; i <= 9; i++) {
                NSString *k = [NSString stringWithFormat:@"c%d", i];
                NSString *v = [C stringFor:kRichGroup key:k];
                if ([v isKindOfClass:[NSString class]] && v.length) m[k] = v;
            }
            gColors = m.count ? [m copy] : nil;
        } @catch (NSException *e) {
            gRichOn = NO;
        }
        FLOGW(FC_UI, @"[rich] 缓存刷新：开关=%d 裸标签=%d 模板池=%lu 字 色板=%lu 项",
              (int)gRichOn, (int)gBareHTML,
              (unsigned long)gTplPool.length, (unsigned long)gColors.count);
    }
}

/* 由 FDMBeauty / 配置观察者调用 */
void FDMRichTextReload(void) { FDMReloadRichCache(); }

/* ============ 三、快速闸（性能铁律） ============ */

/* 有没有任何可能需要处理？
 * 绝大多数消息没有标记 ⇒ 这里立刻返回 NO，一个字节都不碰。 */
BOOL FDMRichMaybeAffected(NSString *s) {
    if (!gRichOn || ![s isKindOfClass:[NSString class]] || s.length < 4) return NO;
    /* ① 模板标记 */
    if ([s rangeOfString:kTplOpen].location != NSNotFound) return YES;
    /* ② 匿名包裹 */
    if ([s rangeOfString:kAnonOpen].location != NSNotFound) return YES;
    /* ②b 建议按钮 */
    if ([s rangeOfString:kSugOpen].location != NSNotFound) return YES;
    if ([s rangeOfString:kSugOpen2].location != NSNotFound) return YES;
    /* ②c 点歌（★ 3.69.4 的教训：这一行漏了 ⇒ 标记永远不触发） */
    if ([s rangeOfString:kDjOpen].location != NSNotFound) return YES;
    /* ③ 裸标签（只在裸标签模式下才需要看） */
    if (gBareHTML) {
        if ([s rangeOfString:@"<b>"].location != NSNotFound) return YES;
        if ([s rangeOfString:@"<i>"].location != NSNotFound) return YES;
        if ([s rangeOfString:@"<u>"].location != NSNotFound) return YES;
        if ([s rangeOfString:@"<s>"].location != NSNotFound) return YES;
        if ([s rangeOfString:@"<br"].location != NSNotFound) return YES;
        if ([s rangeOfString:@"<c"].location != NSNotFound) return YES;
        if ([s rangeOfString:@"<bg"].location != NSNotFound) return YES;
    }
    return NO;
}

/* ============ 四、模板池 ============ */

/* 解析「每行一条：名字|HTML」→ 字典 */
static NSDictionary<NSString *, NSString *> *ParseTplPool(NSString *pool) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (!pool.length) return d;
    NSArray<NSString *> *lines = [pool componentsSeparatedByString:@"\n"];
    for (NSString *raw in lines) {
        NSString *ln = [raw stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
        if (!ln.length) continue;
        if ([ln hasPrefix:@"#"]) continue;          /* # 开头当注释 */
        NSRange bar = [ln rangeOfString:@"|"];
        if (bar.location == NSNotFound) continue;
        NSString *name = [[ln substringToIndex:bar.location]
                          stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        NSString *body = [ln substringFromIndex:bar.location + 1];
        if (!name.length || !body.length) continue;
        d[name] = body;
    }
    return d;
}

/* {1} {2} … 替换成参数 */
static NSString *FillParams(NSString *tpl, NSArray<NSString *> *params) {
    if (!tpl.length) return @"";
    if (!params.count) return tpl;
    NSMutableString *out = [NSMutableString stringWithString:tpl];
    for (NSUInteger i = 0; i < params.count; i++) {
        NSString *token = [NSString stringWithFormat:@"{%lu}", (unsigned long)(i + 1)];
        if ([out rangeOfString:token].location == NSNotFound) continue;
        [out replaceOccurrencesOfString:token
                             withString:params[i]
                                options:0
                                  range:NSMakeRange(0, out.length)];
    }
    return out;
}

/* ============ 五、颜色 ============ */

static UIColor *ColorFromHex(NSString *hex) {
    if (![hex isKindOfClass:[NSString class]] || !hex.length) return nil;
    NSString *h = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    h = [h stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    unsigned int v = 0;
    if (h.length == 6) {
        if ([[NSScanner scannerWithString:h] scanHexInt:&v])
            return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                                   green:((v >> 8) & 0xFF) / 255.0
                                    blue:(v & 0xFF) / 255.0 alpha:1.0];
    } else if (h.length == 8) {   /* AARRGGBB */
        if ([[NSScanner scannerWithString:h] scanHexInt:&v])
            return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                                   green:((v >> 8) & 0xFF) / 255.0
                                    blue:(v & 0xFF) / 255.0
                                   alpha:((v >> 24) & 0xFF) / 255.0];
    }
    return nil;
}

/* 色板：c1..c9 → 颜色 */
static UIColor *PaletteColor(NSString *key) {
    if (!gColors) return nil;
    NSString *hex = gColors[key];
    if (!hex.length) return nil;
    return ColorFromHex(hex);
}

/* ============ 六、字体派生（保留字体族！） ============ */

/* ★ 不能用 boldSystemFontOfSize: —— 会丢掉宿主设置的具体字体族，
 *   导致「一个字是 PingFang 一个字是 System」的观感割裂。 */
static UIFont *DeriveFont(UIFont *base, BOOL bold, BOOL italic) {
    if (!base) base = [UIFont systemFontOfSize:16];
    UIFontDescriptorSymbolicTraits want = 0;
    if (bold)   want |= UIFontDescriptorTraitBold;
    if (italic) want |= UIFontDescriptorTraitItalic;
    if (!want) return base;

    UIFontDescriptor *desc = base.fontDescriptor;
    UIFontDescriptorSymbolicTraits cur = desc.symbolicTraits;
    UIFontDescriptorSymbolicTraits need = want & ~cur;
    if (!need) return base;                      /* 已经是粗/斜，不用动 */

    UIFontDescriptor *nd = [desc fontDescriptorWithSymbolicTraits:(cur | need)];
    if (!nd) return base;
    UIFont *f = [UIFont fontWithDescriptor:nd size:base.pointSize];
    return f ?: base;
}

/* ============ 七、HTML 子集解析 ============ */

/* 样式栈帧：只记录「相对父层的变化」，出栈时自然回退 */
typedef struct {
    BOOL bold, italic, underline, strike;
} RSFrame;

/* ============================================================
 * ★ 建议按钮渲染（2026-10-17 P4）
 *
 *   AI 输出：<Suggestion>▸ 帮我再展开讲讲</Suggestion>
 *   或    ：<Suggestion>▸ 说说看|请从原理上详细解释一下</Suggestion>
 *
 *   ⚠️ iOS 的限制：AI 正文承载控件是 **UILabel**，
 *      UILabel 不响应 .link 属性（只有 UITextView 会）。
 *      ⇒ 改用「伪装成按钮的富文本 + tap 手势反查」：
 *        把 payload 编码进一个自定义 attribute，
 *        宿主自己的 gesture 拿不到，就由我们挂一个
 *        UITapGestureRecognizer 到 UILabel 上做命中判定。
 *
 *   为了不动宿主结构，这里先只做「视觉上像按钮」：
 *     圆角背景 + 主题色 + 加粗 + 前后留空。
 *   点击能力在 FDMComposer 那侧挂手势（可选开关）。
 * ============================================================ */

/* 把一段 HTML 子集追加到 out（out 已经带好外部 attributes） */
static void AppendHTML(NSMutableAttributedString *out,
                       NSString *html,
                       NSDictionary *baseAttrs,
                       int depth) {
    if (!html.length || depth > 12) return;

    NSUInteger i = 0;
    NSUInteger n = html.length;
    NSMutableArray<NSString *> *openTags = [NSMutableArray array];

    /* 当前生效的样式（由标签栈推导） */
    BOOL bold = NO, italic = NO, under = NO, strike = NO;
    UIColor *fg = nil, *bg = nil;

    /* 把「当前样式」压成 attributes 字典 */
    #define CURRENT_ATTRS() ({                                                    \
        NSMutableDictionary *a = [NSMutableDictionary dictionaryWithDictionary:baseAttrs]; \
        UIFont *bf = baseAttrs[NSFontAttributeName];                              \
        UIFont *df = DeriveFont(bf, bold, italic);                                \
        if (df) a[NSFontAttributeName] = df;                                      \
        if (under) a[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);  \
        if (strike) a[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle); \
        if (fg) a[NSForegroundColorAttributeName] = fg;                           \
        if (bg) a[NSBackgroundColorAttributeName] = bg;                           \
        a; })

    while (i < n) {
        unichar c = [html characterAtIndex:i];
        if (c != '<') {
            /* ---- 普通文本：攒一段再一次性 append（省得逐字建对象） ---- */
            NSUInteger start = i;
            while (i < n && [html characterAtIndex:i] != '<') i++;
            NSString *chunk = [html substringWithRange:NSMakeRange(start, i - start)];
            chunk = [chunk stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"];
            chunk = [chunk stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];
            chunk = [chunk stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
            if (chunk.length) {
                NSAttributedString *as =
                    [[NSAttributedString alloc] initWithString:chunk
                                                    attributes:CURRENT_ATTRS()];
                [out appendAttributedString:as];
            }
            continue;
        }

        /* ---- 标签 ---- */
        NSRange close = [html rangeOfString:@">"
                                    options:0
                                      range:NSMakeRange(i, MIN((NSUInteger)24, n - i))];
        if (close.location == NSNotFound) {
            /* 不是合法标签：当普通字符 '<' 处理 */
            NSAttributedString *as =
                [[NSAttributedString alloc] initWithString:@"<"
                                                attributes:CURRENT_ATTRS()];
            [out appendAttributedString:as];
            i++;
            continue;
        }
        NSString *tag = [[html substringWithRange:
                          NSMakeRange(i + 1, close.location - i - 1)]
                         lowercaseString];
        i = close.location + 1;

        /* 自闭合 / 空标签 */
        if ([tag isEqualToString:@"br"] || [tag isEqualToString:@"br/"] ||
            [tag isEqualToString:@"br /"]) {
            NSAttributedString *as =
                [[NSAttributedString alloc] initWithString:@"\n"
                                                attributes:CURRENT_ATTRS()];
            [out appendAttributedString:as];
            continue;
        }

        BOOL isEnd = [tag hasPrefix:@"/"];
        if (isEnd) {
            /* 出栈：恢复到上一个同名标签之前的状态 —— 这里用简化策略，
             * 直接按标签类型复位（因为我们的标签都不需要「部分回退」） */
            NSString *name = [tag substringFromIndex:1];
            if ([name isEqualToString:@"b"]) bold = NO;
            else if ([name isEqualToString:@"i"]) italic = NO;
            else if ([name isEqualToString:@"u"]) under = NO;
            else if ([name isEqualToString:@"s"] || [name isEqualToString:@"del"]) strike = NO;
            else if ([name isEqualToString:@"c"]) fg = nil;
            else if ([name isEqualToString:@"bg"]) bg = nil;
            if (openTags.count) [openTags removeLastObject];
            continue;
        }

        /* 开标签 */
        if ([tag isEqualToString:@"b"]) { bold = YES; [openTags addObject:tag]; continue; }
        if ([tag isEqualToString:@"i"]) { italic = YES; [openTags addObject:tag]; continue; }
        if ([tag isEqualToString:@"u"]) { under = YES; [openTags addObject:tag]; continue; }
        if ([tag isEqualToString:@"s"] || [tag isEqualToString:@"del"]) {
            strike = YES; [openTags addObject:tag]; continue;
        }

        /* <c1> .. <c9> / <c#RRGGBB> */
        if ([tag hasPrefix:@"c"] && tag.length > 1) {
            NSString *arg = [tag substringFromIndex:1];
            UIColor *col = nil;
            if ([arg hasPrefix:@"#"]) col = ColorFromHex(arg);
            else col = PaletteColor([@"c" stringByAppendingString:arg]);
            if (col) { fg = col; [openTags addObject:tag]; }
            /* 连不上色板 ⇒ 当未知标签，整段丢掉（不 append 任何东西） */
            continue;
        }

        /* <bg1> .. <bg9> / <bg#RRGGBB> */
        if ([tag hasPrefix:@"bg"] && tag.length > 2) {
            NSString *arg = [tag substringFromIndex:2];
            UIColor *col = nil;
            if ([arg hasPrefix:@"#"]) col = ColorFromHex(arg);
            else col = PaletteColor([@"c" stringByAppendingString:arg]);
            if (col) { bg = col; [openTags addObject:tag]; }
            continue;
        }

        /* 未知标签：整段丢掉（绝不能把 <div> 之类漏到界面上） */
    }

    #undef CURRENT_ATTRS
}

/* ★ 容错找建议的闭合标签。
 *   实测模型会写成 "</\nSuggestion>"（换行夹在中间）——
 *   严格搜 "</Suggestion>" 会失败 ⇒ 整段裸奔在屏幕上。
 *   做法：先找 "</"，跳过空白，再要求 "suggestion"，跳过空白，再 ">"。 */
static NSRange SugFindClose(NSString *src, NSUInteger from) {
    NSUInteger n = src.length;
    NSUInteger i = from;
    while (i + 2 < n) {
        NSRange rc = [src rangeOfString:@"</"
                                options:NSCaseInsensitiveSearch
                                  range:NSMakeRange(i, n - i)];
        if (rc.location == NSNotFound) return NSMakeRange(NSNotFound, 0);
        NSUInteger p = NSMaxRange(rc);
        /* 跳过空白 */
        while (p < n) {
            unichar c = [src characterAtIndex:p];
            if (c == ' ' || c == '\n' || c == '\r' || c == '\t') p++;
            else break;
        }
        /* 需要 suggestion */
        NSUInteger need = 10;   /* "suggestion" */
        if (p + need > n) return NSMakeRange(NSNotFound, 0);
        NSString *w = [src substringWithRange:NSMakeRange(p, need)];
        if ([w caseInsensitiveCompare:@"suggestion"] != NSOrderedSame) { i = NSMaxRange(rc); continue; }
        p += need;
        while (p < n) {
            unichar c = [src characterAtIndex:p];
            if (c == ' ' || c == '\n' || c == '\r' || c == '\t') p++;
            else break;
        }
        if (p >= n || [src characterAtIndex:p] != '>') { i = NSMaxRange(rc); continue; }
        return NSMakeRange(rc.location, p + 1 - rc.location);
    }
    return NSMakeRange(NSNotFound, 0);
}

/* ============================================================
 * 点歌（⟦DJ:歌名-歌手⟧）
 *
 * 为什么带**去重**：渲染层可能对同一条消息调很多次（cell 复用 / 滚动 /
 * 流式每帧），不去重的话「一首歌被点 20 次」。安卓 3.69.5 就是靠
 * 15 秒窗治好的 —— 这里照抄。
 * ============================================================ */

#define kDjDedupSec 15.0

static NSMutableDictionary<NSString *, NSNumber *> *gDjSeen = nil;
static NSLock *gDjLock = nil;

static void DjEnsure(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gDjSeen = [NSMutableDictionary dictionary];
        gDjLock = [NSLock new];
    });
}

/** true = 这条点歌最近刚处理过（跳过：不搜、不播）。 */
static BOOL DjRecentlyHandled(NSString *key) {
    if (!key.length) return YES;
    DjEnsure();
    [gDjLock lock];
    BOOL seen = NO;
    @try {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        for (NSString *k in gDjSeen.allKeys) {          /* 顺手清过期 */
            if (now - gDjSeen[k].doubleValue > kDjDedupSec * 4) [gDjSeen removeObjectForKey:k];
        }
        NSNumber *t = gDjSeen[key];
        if (t && now - t.doubleValue < kDjDedupSec) seen = YES;
        else gDjSeen[key] = @(now);
    } @catch (NSException *e) { seen = YES; }           /* 出异常就别播，宁可没反应 */
    [gDjLock unlock];
    return seen;
}

/** 渲染一条点歌标记：返回要显示的那一行；nil = 什么都不显示（hidden）。 */
static NSAttributedString *RenderDj(NSString *inner, NSDictionary *baseAttrs) {
    NSString *body = [inner stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL hidden = NO;

    /* ⟦DJ:歌名-歌手|hidden⟧ —— 竖线后面是旗标 */
    NSRange bar = [body rangeOfString:@"|"];
    if (bar.location != NSNotFound) {
        NSString *flags = [[body substringFromIndex:bar.location + 1] lowercaseString];
        body = [[body substringToIndex:bar.location]
                stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([flags containsString:@"hidden"]) hidden = YES;
    }
    if (!body.length) return nil;

    /* ① 真正去播（异步，绝不阻塞渲染） */
    if (!DjRecentlyHandled(body)) {
        NSString *spec = [body copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            extern void FDMMusicPlayByKeyword(NSString *keyword,
                                              void (^completion)(BOOL ok, NSString *msg));
            FDMMusicPlayByKeyword(spec, ^(BOOL ok, NSString *msg) {
                if (ok) {
                    FLOGI(FC_MUSIC, @"[dj] ♪ %@ 已开播", msg);
                } else {
                    FLOGW(FC_MUSIC, @"[dj] %@ 点歌失败：%@", spec, msg);
                }
            });
        });
    } else {
        FLOGD(FC_MUSIC, @"[dj] %@ 15 秒内处理过，跳过", body);
    }

    /* ② 要显示的那一行 */
    if (hidden) return nil;

    NSMutableDictionary *a = [NSMutableDictionary dictionaryWithDictionary:baseAttrs];
    UIFont *bf = a[NSFontAttributeName];
    if ([bf isKindOfClass:[UIFont class]]) {
        a[NSFontAttributeName] = [UIFont systemFontOfSize:bf.pointSize
                                                   weight:UIFontWeightSemibold];
    }
    a[NSForegroundColorAttributeName] = [UIColor systemBlueColor];

    NSString *txt = [NSString stringWithFormat:@"♪ 正在给你放：%@", body];
    return [[NSAttributedString alloc] initWithString:txt attributes:a];
}

/* 渲染一条建议按钮：返回已经带好样式的一段富文本 */
static NSAttributedString *RenderSuggestion(NSString *label,
                                            NSString *payload,
                                            NSDictionary *baseAttrs) {
    NSString *show = label.length ? label : payload;
    if (!show.length) return nil;

    NSMutableDictionary *a = [NSMutableDictionary dictionaryWithDictionary:baseAttrs];
    UIFont *bf = baseAttrs[NSFontAttributeName];
    UIFont *df = DeriveFont(bf, YES, NO);          /* 建议按钮默认加粗 */
    if (df) a[NSFontAttributeName] = df;

    /* ============================================================
     * ★★★ 2026-10-17 最终方案：富文本里的建议文字**全透明**
     *
     *   之前画成"假按钮"（带底色文字），结果和真按钮**重复显示**，
     *   而且假按钮点不动（宿主的选择层吃掉事件）。
     *
     *   ⇒ 这里只留**不可见的占位**，真正的按钮由 FDMEnsureSugBox
     *     铺在 cell 上。视觉上只剩我们的真按钮，干净且一定能点。
     *
     *   ⚠️ 不能删掉这段文字 —— 删了就没法从 cell 里定位"建议在哪"。
     * ============================================================ */
    /* ★★★ 2026-10-17 最终定案（主人的思路）：
     *   让**宿主自己画外观**（位置绝对准），
     *   我们的 UIButton 只当透明点击层叠在上面。
     *
     *   为什么反过来：
     *     自己算 CoreText 矩形 ⇒ 跨行/换行差异/容器偏移，永远差几个像素。
     *     而宿主画的文字天然在正确位置。
     *   ⇒ 视觉交给宿主（蓝字 + 淡背景，看着就像按钮），
     *     点击交给我们（透明 UIButton，位置粗略对齐即可）。
     * ============================================================ */
    UIColor *tint = PaletteColor(@"c6") ?: [UIColor systemBlueColor];
    a[NSForegroundColorAttributeName] = tint;
    a[NSBackgroundColorAttributeName] = [tint colorWithAlphaComponent:0.13];

    /* ★ 把 payload 塞进自定义 attribute —— 点击时反查用 */
    if (payload.length) a[@"FDMSugPayload"] = payload;

    RememberSug(show, payload);   /* ★ 生成这一刻就记住 */

    /* 前后各留一个空格，让它看起来像"按钮"而不是紧贴正文 */
    NSString *text = [NSString stringWithFormat:@" %@ ", show];
    NSMutableAttributedString *out =
        [[NSMutableAttributedString alloc] initWithString:text attributes:a];

    /* 圆角背景：NSAttributedString 做不到真正的圆角矩形，
     * 但可以用「两端留空格 + 背景色」得到接近胶囊的观感。 */
    return out;
}

/* ============ 八、标记扫描与渲染 ============ */

/* 解析「模板名|参数1|参数2」 */
static void ParseTplInvocation(NSString *inner,
                               NSString *__strong *outName,
                               NSArray<NSString *> *__strong *outParams) {
    NSArray<NSString *> *parts = [inner componentsSeparatedByString:@"|"];
    if (!parts.count) { *outName = nil; *outParams = nil; return; }
    *outName = [[parts firstObject]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (parts.count > 1) {
        *outParams = [parts subarrayWithRange:NSMakeRange(1, parts.count - 1)];
    } else {
        *outParams = nil;
    }
}

/* 主渲染函数。
 * 返回 nil = 没有需要渲染的东西（调用方保持原样）
 * 返回非 nil = 渲染后的富文本（调用方用它替换） */
NSAttributedString *FDMRichRender(NSAttributedString *input) {
    if (!gRichOn) return nil;
    if (![input isKindOfClass:[NSAttributedString class]] || input.length < 4) return nil;

    NSString *src = input.string;
    if (!FDMRichMaybeAffected(src)) return nil;

    @try {
        /* 用「按区间切段」的方式重建：普通文字原样保留 attributes，
         * 标记段替换成富文本 —— 这样外部样式（字号/行高/颜色）不会丢。 */
        NSMutableAttributedString *out =
            [[NSMutableAttributedString alloc] initWithString:@""];
        NSDictionary<NSString *, NSString *> *tpls = ParseTplPool(gTplPool);

        NSUInteger i = 0;
        NSUInteger n = src.length;
        BOOL changed = NO;

        while (i < n) {
            NSRange rt = [src rangeOfString:kTplOpen
                                    options:0
                                      range:NSMakeRange(i, n - i)];
            NSRange ra = [src rangeOfString:kAnonOpen
                                    options:0
                                      range:NSMakeRange(i, n - i)];
            /* ★ 建议按钮（大小写两种都认） */
            NSRange rs1 = [src rangeOfString:kSugOpen
                                     options:0
                                       range:NSMakeRange(i, n - i)];
            NSRange rs2 = [src rangeOfString:kSugOpen2
                                     options:0
                                       range:NSMakeRange(i, n - i)];
            NSRange rs = rs1;
            if (rs2.location != NSNotFound &&
                (rs.location == NSNotFound || rs2.location < rs.location))
                rs = rs2;

            /* ★ 点歌 ⟦DJ:…⟧ */
            NSRange rd = [src rangeOfString:kDjOpen
                                    options:0
                                      range:NSMakeRange(i, n - i)];

            /* 取更靠前的那个（四种：模板 / 匿名包裹 / 建议按钮 / 点歌） */
            NSUInteger hitLoc = NSNotFound;
            int kind = 0;              /* 0=普通 1=模板 2=匿名 3=建议 4=点歌 */
            if (rt.location != NSNotFound) { hitLoc = rt.location; kind = 1; }
            if (ra.location != NSNotFound &&
                (hitLoc == NSNotFound || ra.location < hitLoc)) {
                hitLoc = ra.location; kind = 2;
            }
            if (rs.location != NSNotFound &&
                (hitLoc == NSNotFound || rs.location < hitLoc)) {
                hitLoc = rs.location; kind = 3;
            }
            if (rd.location != NSNotFound &&
                (hitLoc == NSNotFound || rd.location < hitLoc)) {
                hitLoc = rd.location; kind = 4;
            }
            BOOL isTpl = (kind == 1);

            if (hitLoc == NSNotFound) {
                /* 剩余全部是普通文字 */
                [out appendAttributedString:
                 [input attributedSubstringFromRange:NSMakeRange(i, n - i)]];
                break;
            }

            /* 先追加前缀（普通文字，保留原 attributes） */
            if (hitLoc > i) {
                [out appendAttributedString:
                 [input attributedSubstringFromRange:NSMakeRange(i, hitLoc - i)]];
            }

            if (kind == 3) {
                /* ---- <Suggestion>显示|发送</Suggestion> ---- */
                BOOL lower = (rs.location == [src rangeOfString:kSugOpen2
                                                        options:0
                                                          range:NSMakeRange(hitLoc, n - hitLoc)].location);
                NSString *op = lower ? kSugOpen2 : kSugOpen;
                NSString *cl = lower ? kSugClose2 : kSugClose;
                NSUInteger bodyStart = hitLoc + op.length;
                NSRange rc = SugFindClose(src, bodyStart);
                if (rc.location == NSNotFound) {
                    /* 老写法兜底（大小写不同但没换行的情形） */
                    rc = [src rangeOfString:cl
                                    options:NSCaseInsensitiveSearch
                                      range:NSMakeRange(bodyStart, n - bodyStart)];
                }
                if (rc.location == NSNotFound) {
                    /* 没闭合：当普通文字保留（流式还没到齐） */
                    [out appendAttributedString:
                     [input attributedSubstringFromRange:
                      NSMakeRange(hitLoc, n - hitLoc)]];
                    break;
                }
                NSString *inner = [src substringWithRange:
                                   NSMakeRange(bodyStart, rc.location - bodyStart)];
                inner = [inner stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];

                NSString *label = inner;
                NSString *payload = inner;
                NSRange bar = [inner rangeOfString:@"|"];
                if (bar.location != NSNotFound) {
                    label = [[inner substringToIndex:bar.location]
                             stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
                    payload = [[inner substringFromIndex:bar.location + 1]
                               stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]];
                }
                /* 去掉开头的 ▸ / › / > 之类装饰符
                 * ★ 2026-10-17 深夜补：payload 也要去！
                 *   实测发出去的消息带着「▸ 」，因为只修了 label。
                 *   顺带把 payload 首尾空白也清掉。 */
                while (label.length) {
                    unichar c0 = [label characterAtIndex:0];
                    if (c0 == 0x25B8 || c0 == 0x203A || c0 == '>' ||
                        c0 == 0x2022 || c0 == 0x00B7 || c0 == ' ') {
                        label = [label substringFromIndex:1];
                    } else break;
                }
                {
                    BOOL cut = YES;
                    while (cut && payload.length) {
                        cut = NO;
                        unichar c0 = [payload characterAtIndex:0];
                        if (c0 == 0x25B8 || c0 == 0x203A || c0 == '>' ||
                            c0 == 0x2022 || c0 == 0x00B7 || c0 == ' ' ||
                            c0 == '\t' || c0 == '\n') {
                            payload = [payload substringFromIndex:1];
                            cut = YES;
                        }
                    }
                    payload = [payload stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                }

                NSDictionary *base = [input attributesAtIndex:hitLoc
                                               effectiveRange:NULL];
                NSAttributedString *sug = RenderSuggestion(label, payload, base);
                if (sug) [out appendAttributedString:sug];
                changed = YES;
                i = NSMaxRange(rc);
            } else if (kind == 4) {
                /* ---- ⟦DJ:歌名-歌手⟧ 点歌 ---- */
                NSUInteger bodyStart = hitLoc + kDjOpen.length;
                NSRange rc = [src rangeOfString:kDjClose
                                        options:0
                                          range:NSMakeRange(bodyStart, n - bodyStart)];
                if (rc.location == NSNotFound) {
                    /* 没闭合（流式还没到齐）：原样保留，下一帧再说 */
                    [out appendAttributedString:
                     [input attributedSubstringFromRange:
                      NSMakeRange(hitLoc, n - hitLoc)]];
                    break;
                }
                NSString *inner = [src substringWithRange:
                                   NSMakeRange(bodyStart, rc.location - bodyStart)];
                NSDictionary *base = [input attributesAtIndex:hitLoc
                                               effectiveRange:NULL];
                NSAttributedString *dj = RenderDj(inner, base);
                if (dj) [out appendAttributedString:dj];
                changed = YES;
                i = NSMaxRange(rc);
            } else if (isTpl) {
                /* ---- ⟦FDM:名字|参数⟧ ---- */
                NSUInteger bodyStart = hitLoc + kTplOpen.length;
                NSRange rc = [src rangeOfString:kTplClose
                                        options:0
                                          range:NSMakeRange(bodyStart, n - bodyStart)];
                if (rc.location == NSNotFound) {
                    /* 没闭合：原样保留（可能流式还没到齐） */
                    [out appendAttributedString:
                     [input attributedSubstringFromRange:
                      NSMakeRange(hitLoc, n - hitLoc)]];
                    break;
                }
                NSString *inner = [src substringWithRange:
                                   NSMakeRange(bodyStart, rc.location - bodyStart)];
                NSString *name = nil;
                NSArray<NSString *> *params = nil;
                ParseTplInvocation(inner, &name, &params);

                NSString *html = name.length ? tpls[name] : nil;
                if (html) {
                    NSString *filled = FillParams(html, params);
                    /* ★ 关键：从「标记起点」的 attributes 派生 base，
                     *   这样字号/字体/段落样式全部继承宿主设置 */
                    NSDictionary *base = [input attributesAtIndex:hitLoc
                                                   effectiveRange:NULL];
                    AppendHTML(out, filled, base, 0);
                    changed = YES;
                } else {
                    /* 模板不存在：整块丢掉（不显示 ⟦FDM:xxx⟧ 这种噪音） */
                    changed = YES;
                }
                i = NSMaxRange(rc);
            } else {
                /* ---- ⟦FDM⟧…⟦/FDM⟧ 匿名包裹 ---- */
                NSUInteger bodyStart = hitLoc + kAnonOpen.length;
                NSRange rc = [src rangeOfString:kAnonClose
                                        options:0
                                          range:NSMakeRange(bodyStart, n - bodyStart)];
                if (rc.location == NSNotFound) {
                    /* 没闭合：交给 FDMStrip 当系统提示词删掉 */
                    [out appendAttributedString:
                     [input attributedSubstringFromRange:
                      NSMakeRange(hitLoc, n - hitLoc)]];
                    break;
                }
                NSString *inner = [src substringWithRange:
                                   NSMakeRange(bodyStart, rc.location - bodyStart)];
                NSDictionary *base = [input attributesAtIndex:hitLoc
                                               effectiveRange:NULL];
                AppendHTML(out, inner, base, 0);
                changed = YES;
                i = NSMaxRange(rc);
            }
        }

        if (!changed) return nil;

        /* 吃掉开头/结尾多余换行（标记块前后常带 \n） */
        while (out.length > 0 &&
               [[out string] characterAtIndex:0] == '\n') {
            [out replaceCharactersInRange:NSMakeRange(0, 1) withString:@""];
        }
        while (out.length > 0 &&
               [[out string] characterAtIndex:out.length - 1] == '\n') {
            [out replaceCharactersInRange:NSMakeRange(out.length - 1, 1) withString:@""];
        }

        RegisterSugs(out);      /* ★ 登记建议按钮的 payload 区间 */
        FLOGW(FC_UI, @"[rich] ★ 渲染 %lu → %lu 字（模板池 %lu 项）",
              (unsigned long)src.length, (unsigned long)out.length,
              (unsigned long)tpls.count);
        return out;
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[rich] 渲染异常: %@", e.reason);
        return nil;
    }
}

/* ============ 九、裸标签模式 ============ */

/* AI 天生爱写 HTML（模型训练数据里遍地都是）。
 * 管不住它包不包 ⟦FDM:…⟧ ⇒ 干脆给它一个「直接写就生效」的模式。
 * 安全性靠白名单：只认 b i u s del br c1-9 bg1-9 c#RRGGBB bg#RRGGBB 这几种形态，
 * 代码块里的 <div>、数学里的 a < b 一律原样留着。 */
NSAttributedString *FDMRichRenderBare(NSAttributedString *input) {
    if (!gRichOn || !gBareHTML) return nil;
    if (![input isKindOfClass:[NSAttributedString class]] || input.length < 4) return nil;
    if (!FDMRichMaybeAffected(input.string)) return nil;
    if ([input.string rangeOfString:@"<"].location == NSNotFound) return nil;

    @try {
        NSMutableAttributedString *out =
            [[NSMutableAttributedString alloc] initWithString:@""];
        NSDictionary *base = [input attributesAtIndex:0 effectiveRange:NULL];
        AppendHTML(out, input.string, base, 0);
        if (!out.length) return nil;
        if ([[out string] isEqualToString:input.string]) return nil;
        FLOGW(FC_UI, @"[rich] ★ 裸标签渲染 %lu → %lu 字",
              (unsigned long)input.length, (unsigned long)out.length);
        return out;
    } @catch (NSException *e) {
        return nil;
    }
}

/* ============================================================
 * ★★★ 建议按钮的 payload 传递（2026-10-17 血案第二弹）
 *
 *   问题：我们把 payload 塞进 NSAttributedString 的自定义 attribute，
 *        但**宿主在 setAttributedText 之后又重建了一次**
 *        ⇒ 自定义 attribute 全被清掉 ⇒ 点击时查不到（实测数为 0）。
 *
 *   这跟「抹除后字变小变黑」是同一类坑：
 *     **别指望自定义 attribute 能活着穿过宿主的处理链。**
 *
 *   改用「**按文本内容查表**」：
 *     渲染完成时，扫一遍 payload 区间，存进
 *         gSugByText[最终字符串] = [{range, payload}, ...]
 *     宿主重建 attributedText 时 string 通常不变 ⇒ 用 string 当键可靠。
 *     点击时：拿 label.text → 查表 → 按字符索引匹配 range → 拿 payload。
 *
 *   上限 200 条，超了整体清空（内存友好，且旧消息本来也不需要了）。
 * ============================================================ */
static NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *gSugByText = nil;

/* 对外：按文本内容取建议列表（元素：@{@"range":NSValue, @"payload":NSString}）
 *
 * ★★★ 2026-10-17 血案第三弹：**精确匹配不可靠**
 *
 *   实测：我们登记了 "文本 152 字"，但点上去查表命中数为 0。
 *   原因：宿主把 attributedString 重建之后，label.text 和我们
 *        渲染出的 out.string **不完全一致**（可能多了/少了空白、
 *        或者被截断/换行归一化过）。
 *
 *   ⇒ 改成三级匹配：
 *     ① 精确匹配
 *     ② 去掉所有空白后匹配（宿主常做换行归一化）
 *     ③ 用一个「稳定锚点」子串匹配 —— 建议按钮的 label 文字本身
 *        （因为 label 一定会出现在最终文本里）
 * ============================================================ */
static NSString *StripWS(NSString *s) {
    if (!s.length) return @"";
    NSMutableString *o = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == ' ' || c == '\n' || c == '\t' || c == '\r' || c == 0x00A0) continue;
        [o appendFormat:@"%C", c];
    }
    return o;
}

NSArray<NSDictionary *> *FDMSugsForText(NSString *text) {
    /* ★ 先用注册表（最可靠）：按「显示文字」在当前文本里搜位置 */
    if (gSugRegistry.count && text.length) {
        NSMutableArray *out = [NSMutableArray array];
        int hits = 0, miss = 0;
        for (NSDictionary *d in gSugRegistry) {
            NSString *show = d[@"show"];
            NSString *pl = d[@"payload"];
            if (!show.length || !pl.length) continue;
            NSRange r = [text rangeOfString:show];
            if (r.location == NSNotFound) { miss++; continue; }
            hits++;
            [out addObject:@{ @"range": [NSValue valueWithRange:r], @"payload": pl }];
        }
        {
            static int dbg2 = 0;
            if (dbg2 < 25) {
                dbg2++;
                FLOGW(FC_UI, @"[sug-lookup] 文本%lu字 表%lu条 命中%d 未中%d",
                      (unsigned long)text.length, (unsigned long)gSugRegistry.count,
                      hits, miss);
            }
        }
        if (out.count) return out;
    }
    if (!gSugByText || !text.length) return nil;
    @try {
        /* ① 精确 */
        NSArray *exact = gSugByText[text];
        if (exact.count) return exact;

        /* ② 去空白后比对；命中则把 range 按 text 重新搜一遍 */
        NSString *flat = StripWS(text);
        if (flat.length) {
            for (NSString *k in gSugByText) {
                if (![StripWS(k) isEqualToString:flat]) continue;
                /* 用 text 重新定位各 payload 的显示文字 */
                NSArray<NSDictionary *> *list = gSugByText[k];
                NSMutableArray *fix = [NSMutableArray array];
                for (NSDictionary *d in list) {
                    NSString *pl = d[@"payload"];
                    if (![pl isKindOfClass:[NSString class]] || !pl.length) continue;
                    /* 在 text 里找 payload 的可见部分（label） */
                    NSRange r = [text rangeOfString:pl];
                    if (r.location != NSNotFound) {
                        [fix addObject:@{ @"range": [NSValue valueWithRange:r],
                                          @"payload": pl }];
                    }
                }
                if (fix.count) return fix;
                return list;   /* 实在对不上就原样返回（range 可能偏，但至少能点） */
            }
        }

        /* ③ 锚点匹配：用每条 payload 的可见文字去当前 text 里找 */
        NSMutableArray *byAnchor = [NSMutableArray array];
        for (NSString *k in gSugByText) {
            for (NSDictionary *d in gSugByText[k]) {
                NSString *pl = d[@"payload"];
                if (![pl isKindOfClass:[NSString class]] || pl.length < 2) continue;
                NSRange r = [text rangeOfString:pl];
                if (r.location != NSNotFound) {
                    [byAnchor addObject:@{ @"range": [NSValue valueWithRange:r],
                                           @"payload": pl }];
                }
            }
        }
        if (byAnchor.count) {
            FLOGW(FC_UI, @"[sug] 锚点匹配命中 %lu 条", (unsigned long)byAnchor.count);
            return byAnchor;
        }
    } @catch (NSException *e) { }
    return nil;
}

/* 内部：渲染完成后登记 */
static void RegisterSugs(NSAttributedString *out) {
    if (!out.length) return;
    @try {
        NSMutableArray<NSDictionary *> *list = [NSMutableArray array];
        [out enumerateAttribute:@"FDMSugPayload"
                        inRange:NSMakeRange(0, out.length)
                        options:0
                     usingBlock:^(id v, NSRange r, BOOL *stop) {
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) {
                [list addObject:@{ @"range": [NSValue valueWithRange:r],
                                   @"payload": v }];
            }
        }];
        if (!list.count) return;
        if (!gSugByText) gSugByText = [NSMutableDictionary dictionary];
        if (gSugByText.count > 200) [gSugByText removeAllObjects];
        gSugByText[out.string] = [list copy];
        FLOGW(FC_UI, @"[sug] 已登记 %lu 条建议（文本 %lu 字）",
              (unsigned long)list.count, (unsigned long)out.length);
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[sug] 登记异常: %@", e.reason);
    }
}

/* ============ 十、安装 ============ */

static BOOL gRichInstalled = NO;

void FDMRichTextInstall(void) {
    if (gRichInstalled) return;
    FDMReloadRichCache();
    gRichInstalled = YES;
    FLOGI(FC_UI, @"[rich] 富文本引擎就绪（开关=%d 裸标签=%d）",
          (int)gRichOn, (int)gBareHTML);
}

/* ============================================================
 * v76 诊断导出：让 FDMStrip 能读到两个开关的当前值
 * （排查「渲染被覆盖」时，必须先确认"渲染本身是不是开了"）
 * ============================================================ */
BOOL FDMRichOnFlag(void) {
    FDMReloadRichCache();
    return gRichOn;
}
BOOL FDMRichBareFlag(void) {
    FDMReloadRichCache();
    return gBareHTML;
}
