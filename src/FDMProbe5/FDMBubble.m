// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMBubble.m —— 对话气泡设置（颜色 / 圆角 / 图片底 / 缩放 / 锚点）
//
// ═══════════════════════════════════════════════════════════════════════════
//  宿主结构（字符串 + 类表实锤）
//
//   用户气泡：_TtC13DeepSeek_Chat14UserBubbleView
//            _TtC13DeepSeek_Chat21UserRequestBubbleView
//            ivar: bubbleView  bubbleCorner  baseCornerRadius  maskedCorners
//   AI 气泡：（宿主没有单独的 AI 气泡类 ⇒ 用「非 User* 的 Bubble/Mask 容器」识别）
//
//  ★ 关键发现：宿主自己就有 `bubbleCorner` / `baseCornerRadius` /
//    `maskedCorners` —— 说明圆角是**可配的属性**，不是硬编码。
//    所以我们改圆角不需要重画，只要在 layoutSubviews 之后把值再写一遍。
//
// ═══════════════════════════════════════════════════════════════════════════
//  为什么用「布局后覆写」而不是「hook setter」
//
//   气泡是复用 cell 里的视图，宿主每次配置（configure）都会重设颜色/圆角。
//   如果我们只在 setter 里改一次，下一次 configure 就被覆盖。
//   放在 layoutSubviews 末尾覆写 ⇒ 每次布局都生效、而且只改值不改结构。
//
//   ★ 图片底用「关联 CALayer」而不是加子视图：
//     加子视图会挤掉宿主自己的布局；加 layer 只要 frame 跟着 bounds 走就行。
// ═══════════════════════════════════════════════════════════════════════════
#import "FDMBubble.h"
#import "FLog.h"
#import "FDMConfig.h"
#import "FDMNote.h"      /* FDMRGBAColor */

#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

#include "FDMBubbleStyle.h"

/* ══════════════════════════════════ 配置 ══════════════════════════════════ */

static fdmbubble_style gMine;      /* 我的气泡 */
static fdmbubble_style gTheirs;    /* 对方（AI）气泡 */
static BOOL gOn = NO;
static UIImage *gMineImage = nil;
static UIImage *gTheirsImage = nil;
static BOOL gLoaded = NO;

/* ★★★ 2026-10-24（docs/37）：已画过的锚点弱引用表。
 *   用途 = 巡检兜底。stamp 去重再怎么写都会有漏（cell 复用有太多种组合），
 *   所以每隔一小段时间把「画过的地方」对一遍：
 *   锚点还在树上吗？fill layer 还在吗？frame 还等于 bounds 吗？
 *   不对就修 —— 这就是文档 36 里救活玻璃的 EnsureAttached 思路。
 *   用 NSHashTable weakObjects，锚点释放后自动消失，不会留野指针。 */
static NSHashTable *gAnchors = nil;

/* ApplyStyleTo 定义在后面，巡检也要用 */
static void ApplyStyleTo(UIView *v, fdmbubble_style *st, UIImage *img, BOOL isMine);

/* 巡检（定义在后面，这里先声明，因为 Install 要用） */
static void BubbleEnsureStart(void);
static void BubbleEnsureStop(void);
static void BubbleEnsureAll(void);

/* ══════════════════════════════════ 类别判断 ══════════════════════════════════ */

/* ══════════════════════════════════════════════════════════════════════════
 *  ★★ 2026-10-23 真机血案：原来是 `containsString:@"Bubble"`，
 *     结果 hook 命中「对方 27 个类」——因为宿主里凡是带 Bubble 的都进来了，
 *     其中包含各种容器/背景/图层。
 *
 *     更致命的是往下第 3 步 CollectBubbleTargets：它递归 4 层找「有背景色
 *     或圆角的视图」，然后全刷成配置的底色 ⇒ **整屏被刷蓝**。
 *
 *  ⇒ 现在的原则：
 *     ① 类名用**精确匹配**（不是 containsString）
 *     ② 只改「类名对上的那个视图本身」，**绝不递归子视图**
 *     ③ 默认全部关闭
 * ══════════════════════════════════════════════════════════════════════════ */

/** 用户气泡：只认这几个确切类名。 */
static BOOL IsUserBubbleClass(NSString *cn) {
    if (!cn.length) return NO;
    static NSSet *ok = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        /* ★★★ 2026-10-24（docs/37）修 Bug：
         *   原来这里同时放了 UserBubbleView 和 UserRequestBubbleView。
         *   结果两个类的 layoutSubviews 都会走到**同一个** UserBubbleView 锚点上
         *   （外层找到内层，内层就是自己）⇒ 同一条消息被处理两遍，
         *   日志里 "(0,0 67x46)" 一模一样的打两行，就是它。
         *
         *   ⇒ 只 hook **最外层容器** UserRequestBubbleView，
         *     锚点仍然去它肚子里找 UserBubbleView。
         *     这样每次布局只有一条处理路径。 */
        ok = [NSSet setWithArray:@[
            @"DeepSeek_Chat.UserRequestBubbleView",
            @"_TtC13DeepSeek_Chat21UserRequestBubbleView",
        ]];
    });
    return [ok containsObject:cn];
}

/** AI 气泡：只认最外层 AgentMessageCell（内层 ResponseFragmentView 是文字容器）。 */
static BOOL IsAIBubbleClass(NSString *cn) {
    if (!cn.length) return NO;
    static NSSet *ok = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        /* ★★ 2026-10-23 真机：AI 侧只认 **AgentMessageCell**（最外层 cell）。
         *
         *   原来还挂 ResponseFragmentView —— 但 dump 显示它是**内层文字容器**：
         *     ResponseFragmentView 366x604
         *       PlainTextNodeView 366x604      ← 文字就在这
         *         _UITextContainerView
         *   对它找「气泡本体」只能找到文字视图 ⇒ 一刷就把文字背景刷了。
         *
         *   而真正的外层结构是：
         *     AgentMessageCell 414x711
         *       UIView
         *         AgentMessageView 414x711     ← 这才是气泡本体
         *           UIView 366x687
         *             (文字)
         */
        ok = [NSSet setWithArray:@[
            @"DeepSeek_Chat.AgentMessageCell",
            @"_TtC13DeepSeek_Chat20AgentMessageCell",
        ]];
    });
    return [ok containsObject:cn];
}

/* ══════════════════════════════════ 读配置 ══════════════════════════════════ */

static UIImage *BubbleLoadImage(NSString *file) {
    if (!file.length) return nil;
    @try {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                             NSUserDomainMask, YES).firstObject;
        if (!docs.length) return nil;
        NSString *p = [docs stringByAppendingPathComponent:file];
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (!d.length) return nil;
        return [UIImage imageWithData:d];
    } @catch (NSException *e) {
        return nil;
    }
}

static void BubbleFillStyle(NSString *prefix, fdmbubble_style *s) {
    FDMConfig *c = [FDMConfig shared];
    fdmbubble_style_default(s);

    NSString *g = @"bubble";

    NSString *k = [NSString stringWithFormat:@"%@_fill_on", prefix];
    s->fill_enabled = [c boolFor:g key:k] ? 1 : 0;
    k = [NSString stringWithFormat:@"%@_fill", prefix];
    NSString *hex = [c stringFor:g key:k];
    {
        UIColor *col = FDMRGBAColor(hex.length ? hex : nil, 0);
        CGFloat r = 0, gg = 0, b = 0, a = 0;
        if ([col getRed:&r green:&gg blue:&b alpha:&a]) {
            s->fill_argb = ((unsigned)(a * 255) << 24) |
                           ((unsigned)(r * 255) << 16) |
                           ((unsigned)(gg * 255) << 8) |
                           (unsigned)(b * 255);
        }
    }

    k = [NSString stringWithFormat:@"%@_corner_on", prefix];
    BOOL cornerOn = [c boolFor:g key:k];
    k = [NSString stringWithFormat:@"%@_corner", prefix];
    NSInteger cv = [c intFor:g key:k];
    s->corner = cornerOn ? (double)(cv > 0 ? cv : 0) : 0.0;

    k = [NSString stringWithFormat:@"%@_inset", prefix];
    NSInteger iv = [c intFor:g key:k];
    s->inset = (double)(iv > 0 ? iv : 0);

    k = [NSString stringWithFormat:@"%@_img_on", prefix];
    s->image_enabled = [c boolFor:g key:k] ? 1 : 0;
    k = [NSString stringWithFormat:@"%@_img_scale", prefix];
    s->scale = (FDMBubbleScale)[c intFor:g key:k];
    k = [NSString stringWithFormat:@"%@_img_anchor", prefix];
    s->anchor = (FDMBubbleAnchor)[c intFor:g key:k];
    k = [NSString stringWithFormat:@"%@_img_alpha", prefix];
    NSInteger av = [c intFor:g key:k];
    s->image_alpha = av > 0 ? (double)av / 100.0 : 1.0;
    s->clip_image = 1;

    fdmbubble_style_sanitize(s);
}

static void BubbleReload(void) {
    @try {
        FDMConfig *c = [FDMConfig shared];
        gOn = [c boolFor:@"bubble" key:@"on"] && [c enabledFor:@"bubble"];

        BubbleFillStyle(@"mine", &gMine);
        BubbleFillStyle(@"theirs", &gTheirs);

        NSString *f1 = [c stringFor:@"bubble" key:@"mine_img_file"];
        NSString *f2 = [c stringFor:@"bubble" key:@"theirs_img_file"];
        gMineImage = BubbleLoadImage(f1);
        gTheirsImage = BubbleLoadImage(f2);

        gLoaded = YES;

        char d1[64], d2[64];
        fdmbubble_corner_desc(&gMine, d1, sizeof(d1));
        fdmbubble_corner_desc(&gTheirs, d2, sizeof(d2));
        FLOGI(FC_UI, @"[bubble] 配置 on=%d 我(%s 底=%d 图=%d) 对方(%s 底=%d 图=%d)",
              gOn, d1, gMine.fill_enabled, gMine.image_enabled,
              d2, gTheirs.fill_enabled, gTheirs.image_enabled);
    } @catch (NSException *e) {
        gOn = NO;
        FLOGE(FC_UI, @"[bubble] 读配置异常: %@", e.reason);
    }
}

/* ══════════════════════════════════ 应用 ══════════════════════════════════ */

static NSString *const kImgLayerName = @"fdm.bubble.image";

/**
 * 找「气泡底」——**最多挑一个**。
 *
 * ★★ 真机血案（2026-10-23）：原来的实现递归 4 层，把所有
 *    「有背景色 或 cornerRadius>0.5」的视图全收集起来，然后逐个刷底色
 *    ⇒ 整屏（包括页面背景、容器、图层）都被刷成配置的蓝色。
 *
 * ⇒ 现在的规则（宁可少改，绝不多改）：
 *    ① 候选 = 自己 + 直接子视图（**只有 1 层**，不递归）
 *    ② 必须「有圆角 且 有背景色」（气泡底的必要特征）
 *    ③ 同一层有多个候选时，取**面积最小**的那个 ——
 *       气泡底一定是它们当中最贴合文字的那块，而不是整页背景
 *    ④ 一个都找不到 ⇒ 返回 nil，什么都不改
 */
/* ══════════════════════════════════════════════════════════════════════════
 *  ★ 结构诊断：找不到气泡底时，把容器的完整结构打出来
 *
 *  2026-10-23 真机：日志「我：没找到气泡底」—— hook 明明触发了，
 *  但 FindBubbleBody 的条件（有圆角 + 有底色）一个都没匹配上。
 *  不再猜，直接看它长什么样。
 * ══════════════════════════════════════════════════════════════════════════ */

static int gBubbleDumpN = 0;

__attribute__((unused))
static void DumpBubbleTree(UIView *v, int depth) {
    if (!v || depth > 4) return;
    if (gBubbleDumpN > 80) return;
    gBubbleDumpN++;

    NSString *ind = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2)
                                      withString:@" " startingAtIndex:0];
    CGRect b = v.bounds;

    NSString *bgS = @"nil";
    UIColor *bg = v.backgroundColor;
    if (bg) {
        CGFloat r=0,g=0,bl=0,a=0;
        if ([bg getRed:&r green:&g blue:&bl alpha:&a]) {
            bgS = [NSString stringWithFormat:@"#%02X%02X%02X/%.2f",
                   (int)(r*255),(int)(g*255),(int)(bl*255),a];
        }
    }
    CGFloat layA = v.layer.backgroundColor ? CGColorGetAlpha(v.layer.backgroundColor) : 0;

    FLOGD(FC_UI, @"[bubble-dump] %@%@ %.0fx%.0f r=%.1f bg=%@ layA=%.2f subs=%lu",
          ind, NSStringFromClass([v class]),
          b.size.width, b.size.height, v.layer.cornerRadius,
          bgS, layA, (unsigned long)v.subviews.count);

    for (UIView *sv in v.subviews) DumpBubbleTree(sv, depth + 1);
}

/**
 * 找「气泡本体」——**最多一个**。
 *
 * ══════════════════════════════════════════════════════════════════════════
 *  ★★★ 2026-10-23 真机第六次，这次 dump 出真相了
 *
 *  宿主 DeepSeek 2.6.2 的气泡**根本没有底色和圆角**，它是纯文字浮在背景上：
 *
 *    UserRequestBubbleView  414x228  r=0.0  bg=nil
 *      UserBubbleView       320x228  r=0.0  bg=#000000/0.00   ← 全透明
 *        UIView             288x208  r=0.0  bg=nil
 *          RequestFragmentView 288x832 (文字)
 *
 *  所以我一直在找「有圆角 + 有底色」的视图 —— 一个都不存在 ⇒ 永远找不到。
 *
 *  ⇒ 认知修正：
 *     「改气泡底色」在这个版本上不是「改已有的底」，而是**画出**一个底。
 *     目标视图 = 气泡的**包裹容器**（UserBubbleView / 对应 AI 侧的容器），
 *     给它 backgroundColor + cornerRadius 就得到气泡。
 *
 *  挑选规则（按优先级）：
 *    ① 类名含 "BubbleView"（但不含 "Request"/"Response"，那两个是文字容器）
 *    ② 类名含 "MessageView"（AI 侧的包裹层）
 *    ③ 都没有 ⇒ 取**面积最大**且「内部有文字视图」的直接子视图
 *       （那一定是包住文字的容器，而不是某个零散的小块）
 * ══════════════════════════════════════════════════════════════════════════
 */
static BOOL HasTextInside(UIView *v, int depth) {
    if (!v || depth > 5) return NO;
    if ([v isKindOfClass:[UITextView class]]) return YES;
    for (UIView *sv in v.subviews) {
        if (HasTextInside(sv, depth + 1)) return YES;
    }
    return NO;
}

/**
 * 从 ivar 里取气泡本体。
 *
 * ══════════════════════════════════════════════════════════════════════════
 *  ★★★ 2026-10-23 真机第七次 —— 终于找到根因了
 *
 *  我一直在**视图树**里找气泡，但宿主的 `UserBubbleView` 有这些 ivar：
 *      bubbleView / bubbleCorner / baseCornerRadius / maskedCorners
 *
 *  ⇒ 气泡本体存在 **`bubbleView` 这个 ivar** 里，
 *    它可能不是 addSubview 进来的（或者被我们扫的时候还没挂上），
 *    所以我在子视图里永远只能找到「文字容器」和「折叠按钮」，
 *    找不到真正的气泡 —— 这就是为什么改来改去都不对。
 *
 *  正确做法：**先读 ivar**，读不到再退回视图树搜索。
 * ══════════════════════════════════════════════════════════════════════════
 */
/* ══════════════════════════════════════════════════════════════════════════
 *  ★★★ 2026-10-23 真机第九次（截图）：两个比例问题
 *
 *   ① 右上角出现一个巨大的蓝色方块 —— 那是 `_contentView`（414x419，
 *      整个 cell 的内容区），被我当成气泡刷了。
 *   ② 下面的气泡没包住文字 —— 拿到 `bubbleView` 时它的 bounds 还是
 *      **上一轮的旧尺寸**（layout 还没走完），按它画就小了。
 *
 *  ⇒ 三条硬规则：
 *      A. ivar 白名单**只认 bubble 专属名**，绝不碰 contentView/backgroundView
 *      B. 找到后校验：它必须**包得住内部的文字**（否则是错的对象或没布局完）
 *      C. 布局没走完就跳过本轮，交给下一次 layoutSubviews 重画
 * ══════════════════════════════════════════════════════════════════════════ */

/** 文字在 v 里的「最小包围盒」（在 v 的坐标系里）。找不到返回 CGRectNull。 */
static CGRect TextBoundsIn(UIView *v, UIView *root) {
    CGRect uni = CGRectNull;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:v];
    int guard = 0;
    while (stack.count && guard++ < 300) {
        UIView *x = stack.lastObject;
        [stack removeLastObject];
        if ([x isKindOfClass:[UITextView class]] ||
            [x isKindOfClass:[UILabel class]]) {
            CGRect r = [x convertRect:x.bounds toView:root];
            if (r.size.width > 0.5 && r.size.height > 0.5) {
                uni = CGRectIsNull(uni) ? r : CGRectUnion(uni, r);
            }
        }
        for (UIView *sv in x.subviews) [stack addObject:sv];
    }
    return uni;
}

/**
 * 从 ivar 里取气泡本体（严格白名单 + 尺寸校验）。
 *
 * @param allowLoose 1 = 允许退而求其次（没有 bubble 专属 ivar 时用视图树）
 */
static UIView *BubbleFromIvars(UIView *v) {
    if (!v) return nil;
    Class cls = [v class];

    /* ★ A. 只认 bubble 专属的名字 ——
     *   `_contentView` / `backgroundView` 太通用，会把整个 cell 内容区当成气泡。 */
    static const char *names[] = {
        "bubbleView", "_bubbleView",
        "bubble", "_bubble",
        "bubbleBackgroundView", "_bubbleBackgroundView",
    };

    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        Ivar iv = class_getInstanceVariable(cls, names[i]);
        if (!iv) iv = class_getInstanceVariable(object_getClass(v), names[i]);
        if (!iv) continue;

        @try {
            id obj = object_getIvar(v, iv);
            if (![obj isKindOfClass:[UIView class]]) continue;
            UIView *bv = (UIView *)obj;

            CGRect bb = bv.bounds;
            if (bb.size.width <= 4 || bb.size.height <= 4) continue;

            /* ★ B. 尺寸上限：不能超过容器的 1.5 倍（否则肯定是错的对象）*/
            if (v.bounds.size.width > 1 &&
                bb.size.width > v.bounds.size.width * 1.5) {
                continue;
            }

            /* ★ C. 必须包得住内部文字；包不住 = 没布局完 / 错对象 */
            CGRect tb = TextBoundsIn(bv, bv);
            if (!CGRectIsNull(tb)) {
                if (tb.size.height > bb.size.height + 1.5 ||
                    tb.size.width  > bb.size.width + 1.5) {
                    static int skipN = 0;
                    if (skipN++ < 6) {
                        FLOGD(FC_UI, @"[bubble] ivar.%s 尺寸不对（%.0fx%.0f 装不下文字 %.0fx%.0f）→ 跳过",
                              names[i], bb.size.width, bb.size.height,
                              tb.size.width, tb.size.height);
                    }
                    continue;
                }
            }

            FLOGD(FC_UI, @"[bubble] ivar.%s → %@ %.0fx%.0f ✓",
                  names[i], NSStringFromClass([bv class]),
                  bb.size.width, bb.size.height);
            return bv;
        } @catch (NSException *e) { }
    }
    return nil;
}


/* ══════════════════════════════════════════════════════════════════════════
 *  ★★★ 2026-10-24 真机 dump 之后，锚点全部换成「实测出来的那个」
 *
 *  （下面那套旧的 FindBubbleBody / BubbleFromIvars 保留但不再调用，
 *    留作对照：它代表「靠猜」的那 12 个版本。
 *    真要删的话，连 TextBoundsIn / HasTextInside 一起删。）
 *
 *  之前的 FindBubbleBody 靠一堆启发式（ivar 白名单 / 类名 containsString /
 *  面积最大 / 文字包围盒）去「猜」气泡在哪 —— 猜了 12 个版本全错。
 *
 *  真机 dump（docs/37）给出的答案是确定的，不需要猜：
 *
 *   【用户侧】
 *     UserRequestBubbleView  414x72      ← 整行容器（别碰，铺满会横贯全屏）
 *       └─ UserBubbleView    300.3x72 @x=93.7   ← ★ 这个才是气泡
 *            bg=clear  corner=0
 *            内部 padding 四边对称：左右 16、上下 10
 *            ⇒ 直接铺满它的 bounds 就是正确的气泡，不用再算文字包围盒
 *
 *   【AI 侧】
 *     AgentMessageCell       414x439  bg=#0F0F0F   ← 整行 + 按钮条，别碰
 *       └─ AgentFragmentsView 366x415              ← ★ 这个才是气泡
 *            OperationBar 可见时它会缩小（235 vs 415），
 *            但「文字全在它里面」这条永远成立
 *
 *  实测两种形态都对得上：
 *    ① FragmentsView 366x235 + OperationBar 366x36 @y=243   (235+8+36=279)
 *    ② FragmentsView 366x415 + OperationBar 0x0 (hidden)     (415+0=415)
 *
 *  ⇒ 锚点法：按**精确类名**往下找，找到就用它的 bounds。
 *    找不到就不画（宁可没有，也不要画错）。
 * ══════════════════════════════════════════════════════════════════════════ */

/** 在 root 子树里按精确类名找第一个 view（BFS，最多 6 层）。 */
static UIView *FindByClassName(UIView *root, const char *const *names, int nNames) {
    if (!root) return nil;

    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;

    while (stack.count && guard++ < 400) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];

        const char *cn = class_getName([v class]);
        if (cn) {
            for (int i = 0; i < nNames; i++) {
                if (strcmp(cn, names[i]) == 0) return v;
            }
        }
        for (UIView *sv in v.subviews) [stack addObject:sv];
    }
    return nil;
}

/** 用户侧气泡本体 = UserBubbleView（不含 Request/Response）。 */
static UIView *FindUserBubbleAnchor(UIView *root) {
    static const char *const names[] = {
        "DeepSeek_Chat.UserBubbleView",
        "_TtC13DeepSeek_Chat14UserBubbleView",
    };
    return FindByClassName(root, names, 2);
}

/** AI 侧气泡本体 = AgentFragmentsView。 */
static UIView *FindAIBubbleAnchor(UIView *root) {
    static const char *const names[] = {
        "DeepSeek_Chat.AgentFragmentsView",
        "_TtC13DeepSeek_Chat19AgentFragmentsView",
    };
    return FindByClassName(root, names, 2);
}

/** 按需要选锚点。 */
static UIView *FindBubbleAnchor(UIView *root, BOOL isMine) {
    UIView *a = isMine ? FindUserBubbleAnchor(root) : FindAIBubbleAnchor(root);

    /* 尺寸守卫：太小或太大都不是气泡（防的是「找到但不对」） */
    if (a) {
        CGSize sz = a.bounds.size;
        if (sz.width < 20 || sz.height < 16) return nil;
        if (root.bounds.size.width > 1 &&
            sz.width > root.bounds.size.width + 1) return nil;
    }
    return a;
}

/** 找「气泡本体」——最多一个。 */
__attribute__((unused))
static UIView *FindBubbleBody(UIView *v) {
    if (!v) return nil;

    /* ★ ① 最高优先级：读 ivar（这才是宿主真正的气泡）*/
    UIView *fromIvar = BubbleFromIvars(v);
    if (fromIvar) return fromIvar;

    /* ② 容器自己就是「BubbleView」（不含 Request/Response）
     *    —— 这时它**就是**气泡本体，不要再往里钻 */
    NSString *selfCn = NSStringFromClass([v class]) ?: @"";
    if ([selfCn containsString:@"BubbleView"] &&
        ![selfCn containsString:@"Request"] &&
        ![selfCn containsString:@"Response"]) {
        return v;
    }

    /* ③ AI 侧：类名含 MessageView（AgentMessageView）*/
    for (UIView *sv in v.subviews) {
        NSString *cn = NSStringFromClass([sv class]) ?: @"";
        if ([cn containsString:@"MessageView"] && ![cn containsString:@"Cell"]) {
            UIView *sub = BubbleFromIvars(sv);
            return sub ?: sv;
        }
    }

    /* ④ 再深一层（AgentMessageCell → UIView → AgentMessageView）*/
    for (UIView *sv in v.subviews) {
        for (UIView *ssv in sv.subviews) {
            NSString *cn2 = NSStringFromClass([ssv class]) ?: @"";
            if ([cn2 containsString:@"MessageView"] && ![cn2 containsString:@"Cell"]) {
                return ssv;
            }
        }
    }

    /* ⑤ 兜底：面积最大、且内部有文字的直接子视图 */
    UIView *best = nil;
    CGFloat bestArea = 0;
    for (UIView *sv in v.subviews) {
        if (sv.hidden || sv.alpha < 0.01) continue;
        CGFloat a = sv.bounds.size.width * sv.bounds.size.height;
        if (a <= 0) continue;
        if (!HasTextInside(sv, 0)) continue;
        if (a > bestArea) { best = sv; bestArea = a; }
    }
    if (best) return best;

    /* ⑥ 最后：容器自己（如果它够大且里面有文字）*/
    if ((v.bounds.size.width > 20 && v.bounds.size.height > 20) &&
        HasTextInside(v, 0)) {
        return v;
    }
    return nil;
}

/** 给一个视图挂图片底 layer（幂等）。 */
static void ApplyImageLayer(UIView *v, fdmbubble_style *st, UIImage *img, UIColor *tint) {
    if (!v) return;

    CALayer *old = nil;
    for (CALayer *l in v.layer.sublayers) {
        if ([l.name isEqualToString:kImgLayerName]) { old = l; break; }
    }

    if (!st->image_enabled || !img) {
        if (old) [old removeFromSuperlayer];
        return;
    }

    CALayer *lay = old;
    if (!lay) {
        lay = [CALayer layer];
        lay.name = kImgLayerName;
        lay.zPosition = -1;                 /* 放在内容下面 */
        lay.contentsGravity = kCAGravityResizeAspectFill;
        lay.masksToBounds = st->clip_image ? YES : NO;
        [v.layer insertSublayer:lay atIndex:0];
    }
    lay.frame = v.bounds;
    lay.contents = (id)img.CGImage;
    lay.opacity = (float)st->image_alpha;
    lay.cornerRadius = v.layer.cornerRadius;
    lay.cornerCurve = kCACornerCurveContinuous;

    /* 用纯 C 内核算真实绘制矩形（cover/contain/tile + 9 宫格锚点）。
     * 用 contentsRect 表达锚点：CALayer 的 contentsRect 是 0..1 的相对裁剪窗口，
     * 正好能表达「cover 裁哪边 / contain 贴哪边」的意图。 */
    fdmrect r = fdmbubble_image_rect(img.size.width, img.size.height,
                                     v.bounds.size.width, v.bounds.size.height,
                                     st->scale, st->anchor, st->inset);
    if (r.w > 0.5 && r.h > 0.5 && v.bounds.size.width > 0.5 && v.bounds.size.height > 0.5) {
        CGFloat sx = (r.x - (v.bounds.size.width - r.w) / 2.0);
        CGFloat sy = (r.y - (v.bounds.size.height - r.h) / 2.0);
        CGFloat cw = v.bounds.size.width / r.w;
        CGFloat ch = v.bounds.size.height / r.h;
        CGFloat cx = 0.5 - sx / r.w;
        CGFloat cy = 0.5 - sy / r.h;
        if (cx < 0) cx = 0;
        if (cy < 0) cy = 0;
        if (cx + cw > 1.0) cx = 1.0 - cw;
        if (cy + ch > 1.0) cy = 1.0 - ch;
        if (cw > 0 && ch > 0 && cw <= 1.0 && ch <= 1.0) {
            lay.contentsRect = CGRectMake(cx, cy, cw, ch);
        } else {
            lay.contentsRect = CGRectMake(0, 0, 1, 1);
        }
    } else {
        lay.contentsRect = CGRectMake(0, 0, 1, 1);
    }
    (void)tint;
}

/** 对「我」或「对方」的一个容器应用样式（只改气泡本体一个视图）。 */
static void ApplyStyleTo(UIView *v, fdmbubble_style *st, UIImage *img, BOOL isMine) {
    if (!v || !st) return;
    @try {
        UIView *t = FindBubbleAnchor(v, isMine);
        if (!t) {
            /* ★ 布局可能还没走完（bubbleView 尺寸还在旧值）⇒ 下一帧再试一次。
             *   只重试一次，避免死循环。 */
            static char kRetryKey;
            if (!objc_getAssociatedObject(v, &kRetryKey)) {
                objc_setAssociatedObject(v, &kRetryKey, @YES,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        if (gOn) ApplyStyleTo(v, isMine ? &gMine : &gTheirs,
                                              isMine ? gMineImage : gTheirsImage, isMine);
                    } @catch (NSException *e) { }
                });
            } else {
                static int missN = 0;
                if (missN++ < 3) {
                    FLOGD(FC_UI, @"[bubble] %@：没找到气泡底（已重试）", isMine ? @"我" : @"对方");
                }
            }
            return;
        }
        /* 找到了就清掉重试标记，下次布局若又消失可以再试 */
        {
            static char kRetryKey;
            objc_setAssociatedObject(v, &kRetryKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        /* ★ 登记到巡检表（弱引用，锚点没了自动消失） */
        if (!gAnchors) {
            gAnchors = [NSHashTable weakObjectsHashTable];
        }
        if (![gAnchors containsObject:t]) {
            [gAnchors addObject:t];
        }

        /* ══════════════════════════════════════════════════════════════════
         *  ★★★ 2026-10-23 真机第八次：「里面文字的填充色没了」
         *
         *  根因：直接改 `t.backgroundColor` 会把宿主那一层整个换成纯色，
         *       宿主原本的渐变/半透明/内阴影全丢 ⇒ 文字看起来"悬空"。
         *
         *  ⇒ 只加不改：插入专用 CALayer 当气泡底，
         *     宿主的 backgroundColor / layer.mask 一律不动。
         *     要撤掉就删这一层，瞬间恢复原样。
         * ══════════════════════════════════════════════════════════════════ */
        static NSString *const kFillName = @"fdm.bubble.fill";

        CALayer *fill = nil;
        for (CALayer *l in t.layer.sublayers) {
            if ([l.name isEqualToString:kFillName]) { fill = l; break; }
        }

        if (st->fill_enabled) {
            UIColor *col = [UIColor colorWithRed:((st->fill_argb >> 16) & 0xFF) / 255.0
                                           green:((st->fill_argb >> 8) & 0xFF) / 255.0
                                            blue:(st->fill_argb & 0xFF) / 255.0
                                           alpha:((st->fill_argb >> 24) & 0xFF) / 255.0];

            if (!fill) {
                fill = [CALayer layer];
                fill.name = kFillName;
                [t.layer insertSublayer:fill atIndex:0];
            } else if (fill.superlayer != t.layer) {
                [fill removeFromSuperlayer];
                [t.layer insertSublayer:fill atIndex:0];
            }
            /* ★★ 2026-10-23 真机第十次（截图）：「比例严重失衡，包不住文字」
             *
             *  bubbleView 的 bounds 比文字大很多（含 padding 甚至空白），
             *  直接铺满 ⇒ 气泡显得又宽又空。
             *
             *  ⇒ 气泡底按「**文字包围盒 + 固定 padding**」算，
             *    再夹在 bubbleView 内。这样气泡永远是正好包住文字的形状。 */
            /* ★★ 2026-10-24（docs/37）：锚点本身就是气泡了 ——
             *   用户侧 UserBubbleView 的 padding 四边对称（左右 16 / 上下 10），
             *   AI 侧 AgentFragmentsView 里装的就是全部文字。
             *   所以**直接铺满 bounds** 就是正确结果，不再去量文字包围盒。
             *
             *   上一轮之所以量，是因为拿错了对象（拿 414 宽的整行），
             *   只能靠「文字包围盒 + padding」去补 —— 那是在给错误打补丁。
             *
             *   inset 配置项（正数往内缩）留作微调。 */
            CGRect fr = t.bounds;
            if (st->inset > 0.01) {
                CGRect shrunk = CGRectInset(fr, st->inset, st->inset);
                if (shrunk.size.width >= 8 && shrunk.size.height >= 8) fr = shrunk;
            }

            fill.frame = fr;
            fill.backgroundColor = col.CGColor;
            fill.zPosition = -1;

            double r2 = st->corner > 0.01 ? st->corner : 18.0;
            CGFloat minSide = MIN(fr.size.width, fr.size.height) / 2.0;
            if (r2 > minSide) r2 = minSide;
            fill.cornerRadius = (CGFloat)r2;
            fill.cornerCurve = kCACornerCurveContinuous;
            fill.masksToBounds = YES;

            static int logN2 = 0;
            if (logN2++ < 60) {
                FLOGD(FC_UI, @"[bubble] %@：底色 (%.0f,%.0f %.0fx%.0f) r=%.1f / 容器 %.0fx%.0f",
                      isMine ? @"我" : @"对方",
                      fr.origin.x, fr.origin.y, fr.size.width, fr.size.height, r2,
                      t.bounds.size.width, t.bounds.size.height);
            }
        } else if (fill) {
            [fill removeFromSuperlayer];
        }

        /* 圆角：只在用户显式开了「四角不同」时才动宿主 mask */
        if (st->corner > 0.01 && st->corner_individual) {
            CGFloat minSide = MIN(t.bounds.size.width, t.bounds.size.height) / 2.0;
            CGFloat r0 = MIN(st->corner_tl > 0 ? st->corner_tl : 0, minSide);
            UIBezierPath *bp = [UIBezierPath bezierPathWithRoundedRect:t.bounds
                                                      byRoundingCorners:
                (st->corner_tl > 0 ? UIRectCornerTopLeft : 0) |
                (st->corner_tr > 0 ? UIRectCornerTopRight : 0) |
                (st->corner_bl > 0 ? UIRectCornerBottomLeft : 0) |
                (st->corner_br > 0 ? UIRectCornerBottomRight : 0)
                                                            cornerRadii:CGSizeMake(r0, r0)];
            CAShapeLayer *m = [CAShapeLayer layer];
            m.path = bp.CGPath;
            m.frame = t.bounds;
            t.layer.mask = m;
        }

        /* 图片底 */
        ApplyImageLayer(t, st, img, nil);

    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[bubble] 应用异常: %@", e.reason);
    }
}

/* ══════════════════════════════════ hook ══════════════════════════════════ */

static BOOL gHooked = NO;
static __thread BOOL tInBubble = NO;

/** 通用：hook 一个类的 layoutSubviews，末尾应用样式。 */
/**
 * 气泡布局钩子的「主体」——不区分是 addMethod 还是 setImplementation 路径，
 * 两条路都调这一个，保证行为一致。
 */
static void BubbleLayoutBody(id self) {
        if (!gOn || tInBubble) return;
        @try {
            tInBubble = YES;

            /* ★★★ 2026-10-24（docs/37）修 Bug：**去重键必须含尺寸**
             *
             *   原来的 stamp 只有配置（底色/圆角/开关），**没有尺寸**。
             *   而气泡住在复用 cell 里：
             *
             *     ① 显示 67x46 的短消息 → 画 67x46 的底，stamp=S
             *     ② 滑走，cell 复用给 319x228 的长消息
             *     ③ layoutSubviews 又调 → 配置没变，stamp 还是 S ⇒ **直接 return**
             *     ④ 结果 319x228 的视图上挂着 67x46 的底色
             *
             *   ⇒ 用户看到「点击一些对话又不对了」，就是这个。
             *
             *   现在 stamp 带上锚点的 bounds，尺寸一变就一定重画。
             *   去重本身仍然保留（防闪/掉帧），只是不再误伤复用。 */
            UIView *anchorForStamp = FindBubbleAnchor((UIView *)self,
                                    IsUserBubbleClass(NSStringFromClass([self class])));
            CGRect ab = anchorForStamp ? anchorForStamp.bounds : CGRectZero;

            static char kAppliedKey;
            /* 还要带上**锚点对象地址**：
             *   cell 复用时宿主可能重建 UserBubbleView 对象，
             *   container 不变、尺寸碰巧一样 ⇒ stamp 相同 ⇒ 新锚点没画。
             *   带上地址，锚点一换就一定重画。 */
            NSString *stamp = [NSString stringWithFormat:
                               @"%d|%u|%.1f|%d|%d|%.1fx%.1f|%p",
                               gMine.fill_enabled, gMine.fill_argb, gMine.corner,
                               gMine.image_enabled, gTheirs.fill_enabled,
                               ab.size.width, ab.size.height,
                               (void *)anchorForStamp];
            NSString *prev = objc_getAssociatedObject(self, &kAppliedKey);
            if ([stamp isEqualToString:prev]) return;
            objc_setAssociatedObject(self, &kAppliedKey, stamp,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            NSString *cn = NSStringFromClass([self class]);
            if (IsUserBubbleClass(cn)) {
                ApplyStyleTo((UIView *)self, &gMine, gMineImage, YES);
            } else if (IsAIBubbleClass(cn)) {
                ApplyStyleTo((UIView *)self, &gTheirs, gTheirsImage, NO);
            }
        } @catch (NSException *e) {
        } @finally {
            tInBubble = NO;
        }
}

/**
 * 给「本类原本没有 layoutSubviews」的类用：
 * 自己实现一个，里面手动转发给父类，再跑气泡逻辑。
 */
static void BubbleLayoutHookAdded(id self, SEL _cmd) {
    Class sup = class_getSuperclass([self class]);
    SEL sel = @selector(layoutSubviews);
    IMP supIMP = sup ? class_getMethodImplementation(sup, sel) : NULL;
    if (supIMP) {
        @try { ((void (*)(id, SEL))supIMP)(self, sel); } @catch (NSException *e) { }
    }
    BubbleLayoutBody(self);
}

static void HookLayout(Class cls) {
    if (!cls) return;
    SEL sel = @selector(layoutSubviews);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    /* 用「是否已 Hook」标记防止重复 hook（宿主可能重入） */
    static char kMark;
    if (objc_getAssociatedObject(cls, &kMark)) return;
    objc_setAssociatedObject(cls, &kMark, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    /* ══════════════════════════════════════════════════════════════════════
     *  ★★★ 2026-10-24 加固（docs/36 §2.3 坑 1 / docs/37 血案 3）
     *
     *  `class_getInstanceMethod(cls, sel)` 在 cls **自己不实现**该方法时，
     *  会沿继承链返回**父类的 Method**；接着 method_setImplementation
     *  改的是**父类的方法表** ⇒ 所有子类都会被 hook。
     *
     *  气泡这边目前没炸，是因为 AgentMessageCell / UserRequestBubbleView
     *  恰好自己实现了 layoutSubviews。但宿主一改版就可能不实现 ⇒ 一夜之间
     *  满屏乱画（助手图片那边就是这么炸的）。
     *
     *  ⇒ 先试 class_addMethod：能加成功 = 本类原本没有，加上就完事，
     *    在 hook 里手动转发给父类。
     * ══════════════════════════════════════════════════════════════════════ */
    const char *types = method_getTypeEncoding(m);
    if (class_addMethod(cls, sel, (IMP)BubbleLayoutHookAdded, types)) {
        FLOGI(FC_UI, @"[bubble] %s 本类无 layoutSubviews ⇒ class_addMethod",
              class_getName(cls));
        return;
    }

    IMP orig = method_getImplementation(m);
    IMP mine = imp_implementationWithBlock(^(id self) {
        @try { ((void (*)(id, SEL))orig)(self, sel); } @catch (NSException *e) { }

        BubbleLayoutBody(self);
    });
    method_setImplementation(m, mine);
}

void FDMBubbleInstall(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ FDMBubbleInstall(); });
        return;
    }

    if (!gLoaded) {
        /* ① 内核自检（30 条断言）*/
        char err[512] = {0};
        int bad = fdmbubble_selftest(err, sizeof(err));
        if (bad) {
            FLOGE(FC_UI, @"[bubble] 内核自检失败 #%d\n%s", bad, err);
        } else {
            FLOGI(FC_UI, @"[bubble] 内核 OK（30 组断言：cover/contain/tile × 9 锚点/NaN/极端比例）");
        }
        BubbleReload();
    }

    if (!gOn) {
        FLOGI(FC_UI, @"[bubble] 开关关着，不装 hook");
        BubbleEnsureStop();
        return;
    }
    if (gHooked) {
        FDMBubbleRefreshAll();
        return;
    }
    gHooked = YES;
    BubbleEnsureStart();

    /* ② 按类名找宿主的气泡类（用 objc_getClassList 扫，不硬编码类名）*/
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *buf = (Class *)malloc(sizeof(Class) * (size_t)n);
    if (!buf) return;
    n = objc_getClassList(buf, n);

    int userHits = 0, aiHits = 0;
    for (int i = 0; i < n; i++) {
        const char *nm = class_getName(buf[i]);
        if (!nm) continue;
        NSString *cn = @(nm);
        if (IsUserBubbleClass(cn)) { HookLayout(buf[i]); userHits++; }
        else if (IsAIBubbleClass(cn)) { HookLayout(buf[i]); aiHits++; }
    }
    free(buf);

    FLOGI(FC_UI, @"[bubble] hook 完成：我方 %d 个类 / 对方 %d 个类", userHits, aiHits);
    FDMBubbleRefreshAll();
}

void FDMBubbleReload(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ FDMBubbleReload(); });
        return;
    }
    BubbleReload();
    if (!gOn) {
        FDMBubbleRefreshAll();     /* 关掉时要把已画的清掉 */
        return;
    }
    if (!gHooked) FDMBubbleInstall();
    else FDMBubbleRefreshAll();
}

/* ══════════════════════════════════════════════════════════════════════════
 *  ★★★ 2026-10-24（docs/37）巡检兜底：BubbleEnsureAll
 *
 *  为什么需要它：
 *    `layoutSubviews` + stamp 去重这套，在 cell 复用面前永远有漏网之鱼：
 *      · 锚点对象被重建 ⇒ 新对象上根本没有 fill layer
 *      · 尺寸碰巧一样但内容换了 ⇒ frame 对、但层可能被宿主清掉
 *      · 点击消息触发重新布局，stamp 没变 ⇒ 跳过
 *
 *    所以再加一道「状态对齐」：不看事件，只看**结果对不对**。
 *
 *  它很便宜：只看登记过的锚点（NSHashTable weak），
 *  每个只做「layer 在不在 + frame 等不等于 bounds」两次判断。
 *  ══════════════════════════════════════════════════════════════════════════ */

static NSString *const kFillLayerName = @"fdm.bubble.fill";

static void BubbleEnsureAll(void) {
    if (!gOn || !gAnchors) return;

    NSArray *all = gAnchors.allObjects;
    if (all.count == 0) return;

    int fixed = 0;
    for (UIView *t in all) {
        if (!t) continue;

        /* 锚点必须还在视图树上（否则是回收对象，跳过） */
        if (!t.window) continue;

        /* 找我们那个 fill layer */
        CALayer *fill = nil;
        for (CALayer *l in t.layer.sublayers) {
            if ([l.name isEqualToString:kFillLayerName]) { fill = l; break; }
        }

        if (fill) {
            /* ① frame 必须等于 bounds（复用尺寸变了 / 宿主改了 bounds）*/
            if (!CGRectEqualToRect(fill.frame, t.bounds)) {
                fill.frame = t.bounds;
                fixed++;
            }
            /* ② 圆角不能超过短边一半（极端细长的消息会变成胶囊）*/
            CGFloat maxR = MIN(t.bounds.size.width, t.bounds.size.height) / 2.0;
            if (fill.cornerRadius > maxR + 0.01) {
                fill.cornerRadius = maxR;
                fixed++;
            }
        } else {
            /* ③ ★ layer 压根不在了 —— 宿主重建了锚点对象，或者把 sublayers 清了。
             *   往上找那个「该被 hook 的容器」，让它重新走一遍 ApplyStyleTo。
             *   这才是真正兜住复用的那一步。 */
            NSString *tcn = NSStringFromClass([t class]);
            BOOL anchorIsMine = [tcn containsString:@"User"];

            UIView *cont = t.superview;
            int up = 0;
            while (cont && up++ < 8) {
                NSString *ccn = NSStringFromClass([cont class]);
                if (IsUserBubbleClass(ccn)) {
                    ApplyStyleTo(cont, &gMine, gMineImage, YES);
                    fixed++;
                    break;
                }
                if (IsAIBubbleClass(ccn)) {
                    ApplyStyleTo(cont, &gTheirs, gTheirsImage, NO);
                    fixed++;
                    break;
                }
                cont = cont.superview;
            }
            (void)anchorIsMine;
        }
    }

    if (fixed > 0) {
        static int logN = 0;
        if (logN++ < 8) {
            FLOGD(FC_UI, @"[bubble] 巡检修正 %d 处（复用/尺寸漂移）", fixed);
        }
    }
}

/**
 * 巡检定时器：只在开关打开时跑，1.2s 一次（跟玻璃一个节奏）。
 * 不开新线程，就是主 runloop 上的 NSTimer。
 */
static NSTimer *gEnsureTimer = nil;

static void BubbleEnsureStart(void) {
    if (gEnsureTimer) return;
    gEnsureTimer = [NSTimer scheduledTimerWithTimeInterval:1.2
                                                   repeats:YES
                                                     block:^(NSTimer *tm) {
        BubbleEnsureAll();
    }];
    FLOGI(FC_UI, @"[bubble] 巡检启动（1.2s 一次，兜住 cell 复用）");
}

static void BubbleEnsureStop(void) {
    if (gEnsureTimer) {
        [gEnsureTimer invalidate];
        gEnsureTimer = nil;
    }
}

/** 扫全窗口，已存在的气泡立即重画（不用等宿主下次布局）。 */
void FDMBubbleRefreshAll(void) {
    @try {
        /* 窗口收集统一交给 FDMFindBestWindow（那里处理了弃用告警与多 scene）*/
        extern UIWindow *FDMFindBestWindow(void);
        NSMutableArray *wins = [NSMutableArray array];
        UIWindow *best = FDMFindBestWindow();
        if (best) [wins addObject:best];
        {
            /* 其它 scene 的窗口也一起扫（多窗口 iPad）*/
            if (@available(iOS 13.0, *)) {
                for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                    if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                    for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                        if (w != best) [wins addObject:w];
                    }
                }
            }
        }

        __block int hits = 0;
        for (UIWindow *w in wins) {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
            int guard = 0;
            while (stack.count && guard++ < 4000) {
                UIView *v = stack.lastObject;
                [stack removeLastObject];
                NSString *cn = NSStringFromClass([v class]);
                if (IsUserBubbleClass(cn)) {
                    ApplyStyleTo(v, &gMine, gMineImage, YES);
                    hits++;
                } else if (IsAIBubbleClass(cn)) {
                    ApplyStyleTo(v, &gTheirs, gTheirsImage, NO);
                    hits++;
                }
                for (UIView *sv in v.subviews) [stack addObject:sv];
            }
        }
        FLOGI(FC_UI, @"[bubble] 刷新完成：%d 个气泡容器", hits);
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[bubble] 刷新异常: %@", e.reason);
    }
}
