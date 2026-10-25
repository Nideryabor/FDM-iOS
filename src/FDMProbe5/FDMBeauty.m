/* ============================================================
 * FDMBeauty.m —— 需要 hook UI 层的美化功能
 *
 *  ① 聊天背景      hook SessionViewController → 插背景层
 *  ② 富文本样式    hook MarkdownConfig init → 改字号/行高/颜色
 *
 * 安全原则（沿用项目铁律）：
 *  • 每个 (类,方法) 各自记原 IMP，沿继承链查找，找不到就安全放弃
 *  • Hook 内不阻塞、不做 IO
 *  • 重入保护
 *  • 全部失败也能原样透传
 * ============================================================ */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "FLog.h"
#import "FDMConfig.h"
#import "FDMFeatures.h"
#include <string.h>

/* ==================== (类,方法) 原 IMP 表 ==================== */

#define BT_MAX 64
typedef struct { Class cls; SEL sel; IMP orig; } BTHook;
static BTHook gBT[BT_MAX];
static int gBTN = 0;
static __thread int gReent = 0;

/* ★ 记录「贴过背景」的 VC（弱引用），配置改了用它批量失效签名 */
static NSHashTable *gBgAppliedVCs = nil;

/* ★ 供 cell layoutSubviews hook 查询：彻底透明模式是否开着 */
BOOL FDMBeautyClearAllOn(void) {
    @try {
        return [[FDMConfig shared] boolFor:P_BG key:@"bg_clear_all"];
    } @catch (NSException *e) { return NO; }
}

/* 前置声明（ForceRefresh 在 RefreshBackground 之前定义） */
void FDMBeautyRefreshBackground(void);
static void BTStripEverything(UIView *root, int depth);
BOOL FDMBeautyClearAllOn(void);

static IMP BTFind(Class cls, SEL sel) {
    for (Class c = cls; c != Nil; c = class_getSuperclass(c))
        for (int i = 0; i < gBTN; i++)
            if (gBT[i].cls == c && sel_isEqual(gBT[i].sel, sel)) return gBT[i].orig;
    return NULL;
}

/* 三个 wrapper 的前向声明（BTOriginalSafe 要拿地址排除自己） */
static void bt_sessionViewDidLoad(id, SEL);
static void bt_sessionLayout(id, SEL);
static void bt_genericHook(id, SEL);

/* ★ 兜底：查不到就向 runtime 要，但必须排除我们自己的实现
 *   （返回 NULL 会让「原实现一次都不跑」⇒ 宿主初始化缺失 ⇒ 崩） */
static IMP BTOriginalSafe(id self, SEL _cmd) {
    IMP o = BTFind(object_getClass(self), _cmd);
    if (o && o != (IMP)bt_sessionViewDidLoad &&
             o != (IMP)bt_sessionLayout &&
             o != (IMP)bt_genericHook) return o;
    @try {
        IMP cand = class_getMethodImplementation(object_getClass(self), _cmd);
        if (cand &&
            cand != (IMP)bt_sessionViewDidLoad &&
            cand != (IMP)bt_sessionLayout &&
            cand != (IMP)bt_genericHook) {
            return cand;
        }
        /* 再往父类找一层 */
        Class sup = class_getSuperclass(object_getClass(self));
        if (sup) {
            cand = class_getMethodImplementation(sup, _cmd);
            if (cand && cand != (IMP)bt_sessionViewDidLoad &&
                cand != (IMP)bt_sessionLayout && cand != (IMP)bt_genericHook)
                return cand;
        }
    } @catch (NSException *e) { }
    return NULL;
}
/* ============================================================
 * BTSwap —— 安全版方法替换
 *
 * ★★ 2026-10-17 的致命 bug（点进对话立刻崩）：
 *   class_getInstanceMethod(c, "viewDidLoad") 会**沿继承链查找**。
 *   如果 Swift 类没有自己重写 viewDidLoad，它返回的是
 *   **UIViewController 上的那个方法**，于是
 *       method_setImplementation(m, imp)
 *   把 **全局 UIViewController.viewDidLoad 换成了我们的函数**！
 *   ⇒ 其他所有页面的 viewDidLoad 走进来，
 *      BTFind 查不到它们（只登记了目标类）→ 返回 NULL
 *      → 原实现一次都没被调用 → 宿主初始化缺失 → 崩得干脆利落。
 *
 *   正确做法：
 *     用 class_addMethod 在**目标类自己身上**加一个覆盖，
 *     加不上（说明它本来就有自己的实现）才 method_setImplementation。
 * ============================================================ */
static IMP BTSwap(Class c, const char *sel, IMP imp) {
    if (!c || !sel || !imp) return NULL;
    @try {
        SEL s = sel_registerName(sel);
        Method m = class_getInstanceMethod(c, s);
        if (!m) return NULL;

        const char *types = method_getTypeEncoding(m);
        if (!types) return NULL;

        /* 问一句：这个类**自己**有没有实现？ */
        BOOL hasOwn = NO;
        unsigned int mc = 0;
        Method *own = class_copyMethodList(c, &mc);
        if (own) {
            for (unsigned int i = 0; i < mc; i++)
                if (sel_isEqual(method_getName(own[i]), s)) { hasOwn = YES; break; }
            free(own);
        }

        IMP old = method_getImplementation(m);

        /* ★★ 关键：old 可能已经是「我们自己的另一个 wrapper」
         *   场景：SessionListViewController 继承 SessionViewController，
         *        父类已被我们换成 bt_sessionViewDidLoad ⇒ 子类查到的 old 就是它
         *        ⇒ 再包一层 ⇒ 调用「原实现」= 调自己 ⇒ 无限递归爆栈
         *   判定：只要 old 是我们任何一个 wrapper，就拒绝这次 hook。 */
        if (old == imp ||
            old == (IMP)bt_sessionViewDidLoad ||
            old == (IMP)bt_sessionLayout ||
            old == (IMP)bt_genericHook) {
            FLOGW(FC_UI, @"[hook] 跳过 %s -%s（原 IMP 已是我们的函数，防递归）",
                  class_getName(c), sel);
            return NULL;
        }

        if (!hasOwn) {
            /* 自己没实现 ⇒ 加一个覆盖，绝不动父类 */
            if (!class_addMethod(c, s, imp, types)) {
                FLOGW(FC_UI, @"[hook] class_addMethod 失败 %s -%s",
                      class_getName(c), sel);
                return NULL;
            }
            FLOGD(FC_UI, @"[hook] +覆盖 %s -%s（原来自父类 %p）",
                  class_getName(c), sel, old);
        } else {
            method_setImplementation(m, imp);
        }

        if (gBTN < BT_MAX) {
            gBT[gBTN].cls = c; gBT[gBTN].sel = s; gBT[gBTN].orig = old; gBTN++;
        }
        return old;
    } @catch (NSException *e) { return NULL; }
}

static NSString *BTDocs(void) {
    static NSString *d = nil;
    if (!d) {
        NSArray *a = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES);
        d = [a firstObject] ?: NSTemporaryDirectory();
    }
    return d;
}

/* ==================== ① 聊天背景 ==================== */


/* 递归把「容器类」子视图的底色清成透明（只清 1 层，别把内容也清了） */
/* ============================================================
 * 递归清理「背景块」
 *
 * ★★ 2026-10-17 第二版：第一版只清了第一层，结果聊天页上半部分
 *   （消息列表区域）还是黑的 —— 因为黑色背景藏在更深层的容器里。
 *
 * 判据（只清背景，绝不动气泡 / 文字）：
 *   ① 颜色不透明（alpha ≈ 1）且面积 ≥ 父视图 70%  → 认为是整块背景
 *   ② 或类名像容器：Scroll/Table/Collection/Container/Background
 *   ③ **跳过** 有内容绘制的：UILabel / UITextView / UIImageView /
 *      UIButton / 带文字或图片的视图
 *   深度限制 6 层，避免极端结构下耗时。
 * ============================================================ */
static BOOL BTIsContentClass(UIView *v) {
    return ([v isKindOfClass:[UILabel class]] ||
            [v isKindOfClass:[UITextView class]] ||
            [v isKindOfClass:[UITextField class]] ||
            [v isKindOfClass:[UIImageView class]] ||
            [v isKindOfClass:[UIButton class]] ||
            [v isKindOfClass:[UIVisualEffectView class]]);
}

/* ============================================================
 * ★★ 2026-10-17 第三版：聊天页消息区还是黑的
 *
 * 前两版的漏洞：
 *   ① 只清了 `view.backgroundColor`，没清 `view.layer.backgroundColor`
 *      SwiftUI 的 _UIHostingView 很多背景是画在 **CALayer** 上的
 *   ② 面积阈值太高（25%），大列表的父容器面积可能刚好不够
 *   ③ 没有「无条件清」的类型白名单
 *
 * 本版策略（三层判定）：
 *   A. 类名含 Scroll/Table/Collection/Container/Hosting/SafeArea
 *      → **无条件**清两层背景（这些一定是容器，不是内容）
 *   B. 面积 ≥ 父视图 40% 且不透明 → 清
 *   C. 其余保持（气泡、文字、图片都在这里）
 *
 * 气泡为什么不会被误清：
 *   气泡是 UIView 带 cornerRadius + backgroundColor，面积通常 < 20%，
 *   且类名不含上面那些关键词 ⇒ 两条都不满足 ⇒ 跳过
 * ============================================================ */
/* ============================================================
 * 清掉一个视图的背景（两层：view.backgroundColor + layer.backgroundColor）
 * @param force  YES = 无条件清（容器类）
 * @param big    面积是否够大（>= 父视图 40%）
 * ============================================================ */
static void BTStripBG(UIView *v, BOOL force, BOOL big) {
    if (!v) return;
    @try {
        UIColor *bg = v.backgroundColor;
        CGFloat r = 0, g = 0, b = 0, a = 0;
        BOOL hasViewBG = (bg != nil);
        if (bg) { [bg getRed:&r green:&g blue:&b alpha:&a]; }

        CALayer *l = v.layer;
        BOOL hasLayerBG = (l.backgroundColor != NULL);

        /* ★ 判定「纯黑/近黑」——这是聊天页上方那块黑的典型特征
         *   气泡一般是深灰 (0.15~0.25) 或浅色，不会被误判 */
        BOOL nearBlack = (hasViewBG && a > 0.85 && r < 0.08 && g < 0.08 && b < 0.08);

        BOOL shouldClear = force || (big && a > 0.05) || (nearBlack && big);

        if (shouldClear) {
            if (hasViewBG && a > 0.05) v.backgroundColor = [UIColor clearColor];
            if (hasLayerBG) l.backgroundColor = NULL;

            /* ★ 2026-10-17 修：滚动视图清完底色后，**超出内容的区域**会变成透明
             *   （设置页往下拉，下面露出一块透明的洞）
             *   解法：给滚动视图本身一个「透传到父视图」的容器
             *   最简单可靠的做法：保留滚动视图自身的 clearColor，
             *   但把一个 UIImageView 塞进它背后 —— 由父视图负责显示背景。
             *   这里做的是：让 tableView/collectionView 的 backgroundView 也透明，
             *   并把它的 superview 背景清掉，这样透下去就是页面背景图。 */
            /* ============================================================
             * ★★ 2026-10-17 第三版：滚动视图不留「洞」
             *
             * 问题：清成透明后滚到内容之外，露出的是更下层（window 黑底）
             *       ⇒ 看起来像「拉上来变透明」。
             *
             * 对比三种做法：
             *   A. 保持不透明   → 背景图被盖住（原问题）
             *   B. 清成 clear   → 露黑（现问题）
             *   C. **用背景图当 backgroundView** → 既有背景又不露黑 ✓
             *
             * 这里做 C 的兜底：如果调用方没能塞进 backgroundView
             * （BTApplyScrollBG 没跑到，或者被宿主重置），
             * 就退而求其次设成「半透明黑」，至少跟整体色调一致，
             * 不会出现刺眼的空洞。
             * ============================================================ */
            UIColor *fallback = [UIColor colorWithWhite:0.0 alpha:0.001];  /* 几乎透明但非空 */
            if ([v isKindOfClass:[UITableView class]]) {
                UITableView *tv = (UITableView *)v;
                if (!tv.backgroundView) tv.backgroundColor = fallback;
            }
            if ([v isKindOfClass:[UICollectionView class]]) {
                UICollectionView *cv = (UICollectionView *)v;
                if (!cv.backgroundView) cv.backgroundColor = fallback;
            }
        }
    } @catch (NSException *e) { }
}

/* ============================================================
 * 视图树诊断：找出谁在挡背景
 *   开 fdm-bg.json 里 "bg_debug": true 生效
 *   只打印「不透明背景」的视图 + 类名 + 面积占比
 * ============================================================ */
/* ============================================================
 * 视图树诊断 v2（2026-10-17 第二轮）
 *
 * v1 的不足：只打了类名 + 面积%，看不出：
 *   • 坐标（哪个块盖住了消息区）
 *   • RGB（黑还是深灰)
 *   • 是不是 UIScrollView（消息列表）
 *
 * v2 打印：类名 @ frame  α  rgb  L(layer有背景)  [SCROLL]
 * ============================================================ */
static void BTDumpTree(UIView *v, int depth, CGSize rootSize) {
    if (!v || depth > 10) return;
    @try {
        CGRect f = v.frame;
        CGFloat areaPct = 0;
        if (rootSize.width > 0 && rootSize.height > 0) {
            areaPct = (f.size.width * f.size.height) /
                      (rootSize.width * rootSize.height) * 100.0;
        }

        UIColor *bg = v.backgroundColor;
        CGFloat r=0,g=0,b=0,a=0;
        BOOL has = (bg != nil);
        if (bg) { [bg getRed:&r green:&g blue:&b alpha:&a]; }
        BOOL hasLayerBG = (v.layer.backgroundColor != NULL);

        /* 只打有颜色的，或者面积大的（省略无关的小透明容器） */
        if ((has && a > 0.03) || hasLayerBG || areaPct > 5.0) {
            NSString *cls = NSStringFromClass([v class]);
            const char *cn = [cls UTF8String];
            NSString *tag = @"";
            if ([v isKindOfClass:[UIScrollView class]])     tag = @"[SCROLL]";
            else if ([v isKindOfClass:[UITableView class]])  tag = @"[TABLE]";
            else if ([v isKindOfClass:[UICollectionView class]]) tag = @"[COLL]";
            else if ([v isKindOfClass:[UILabel class]])      tag = @"[LABLE]";
            else if ([v isKindOfClass:[UIImageView class]])  tag = @"[IMAGE]";

            FLOGW(FC_UI, @"[bgtree] %*s%@ %@"
                  @"f=(%.0f,%.0f %.0fx%.0f) %@"
                  @"α=%.2f rgb=(%.2f,%.2f,%.2f) L:%d",
                  depth * 2, "", tag, cls,
                  f.origin.x, f.origin.y, f.size.width, f.size.height,
                  @"",
                  a, r, g, b, hasLayerBG ? 1 : 0);
            (void)cn;
        }

        for (UIView *sv in [v.subviews copy])
            BTDumpTree(sv, depth + 1, rootSize);
    } @catch (NSException *e) { }
}



/* ============================================================
 * ★★ 「彻底透明」模式（主人 2026-10-17 的判断）
 *
 * 主人的猜测：用户气泡和 AI 气泡被单独包裹在一个**黑底容器**里
 *   ⇒ 整个消息区就是一个大黑块，我们的背景图在最底下永远看不见。
 *
 * 这个模式下不再做任何面积/颜色判断，把消息列表内部的
 *   **所有非内容视图** 的背景（view + layer 两层）全部清成透明。
 *
 * 什么算「内容」——只保留这几种（清了就看不见东西）：
 *   UILabel / UITextView / UITextField / UIImageView / UIButton
 *   / 所有带文字或图片的视图
 *
 * 气泡本身的「底色」是 UIView 的 backgroundColor，它会被清掉 ⇒ 气泡变透明
 *   ⚠️ 这是有代价的：气泡会失去底色，只剩文字。
 *   所以这个模式做成**开关**（bg_clear_all），用户自己决定要不要。
 * ============================================================ */
/* ============================================================
 * ★★ 隐藏宿主的「渐变 / 模糊遮罩」（2026-10-17 真凶）
 *
 * 视图树 dump 实锤：
 *     DeepSeek_Chat.VariableBlurView f=(0,0 414x214)    ← 顶部毛玻璃，盖 214px
 *     DeepSeek_Chat.DSGradientView  f=(0,20 414x82)     ← 黑色渐变
 *     DeepSeek_Chat.DSGradientView  f=(0,-112 414x214)
 *
 * 这两个类的作用：消息滚动到顶部/底部时，用「模糊 + 渐变」做出
 * 「内容淡出」的效果。它们画在 **CALayer 的 gradient / blur** 上，
 * view.backgroundColor 完全是透明的（dump 里 α=0.00）
 * ⇒ 我们清 backgroundColor 永远清不掉它们
 * ⇒ 这就是「聊天页上半部分永远是黑的」的真正原因。
 *
 * 做法：把它们的 alpha 设 0（保留布局，只去掉视觉）。
 *   开关：bg_hide_gradient
 * ============================================================ */
/* ============================================================
 * ★★ 气泡透明化（2026-10-17）
 *
 * 从宿主字符串表挖出的气泡类名：
 *     DeepSeek_Chat.UserRequestBubbleView     ← 用户气泡（截图里那个大黑框）
 *     DeepSeek_Chat.UserBubbleView
 *     DeepSeek_Chat.BaseMessageView / BaseMessageCell
 *     DeepSeek_Chat.RequestFragmentView / ResponseFragmentView
 *     DeepSeek_Chat.AgentMessageCell / UserMessageCell
 *
 * 主人截图里那块巨大的黑框，就是 UserRequestBubbleView 的
 * backgroundColor —— 不是「容器包着气泡」，是**气泡自己**。
 *
 * 做法：把这些视图的底色清掉（含 layer），只留文字。
 *   开关：bg_bubble_transparent（默认关，因为有些人喜欢气泡底色）
 * ============================================================ */
/* ============================================================
 * ★★ 气泡透明化 v2（2026-10-17）
 *
 * v1 的问题（主人实测「有的对话半透明，有的不能」）：
 *   只在「贴背景」那一刻执行一次 ⇒ 只清到当时可见的 6 个 cell。
 *   滚动后新出现的 cell 从没被处理过 ⇒ 那些消息还是不透明。
 *
 * v2 做法：
 *   ① 递归进入每个 cell 内部，清掉**所有非文字视图**的底色
 *      （气泡底色往往在 cell.contentView 的某个子 UIView 上，
 *        类名是纯 UIView，按类名匹配根本抓不到）
 *   ② 给处理过的 cell 打 tag，巡检时只处理「新出现的」
 *   ③ 顺带处理 UIVisualEffectView（毛玻璃）—— 截图里那层灰蒙蒙就是它
 *
 * 返回本次新处理的 cell 数量
 * ============================================================ */

#define BT_CELL_DONE_TAG 0x0D1A0003

/* 递归清掉子树里所有非文字视图的底色 */
static int BTStripSubtreeBG(UIView *root, int depth) {
    if (!root || depth > 10) return 0;
    int n = 0;
    @try {
        for (UIView *sv in [root.subviews copy]) {
            /* 文字/图片类不动（清了就看不见内容） */
            if ([sv isKindOfClass:[UILabel class]] ||
                [sv isKindOfClass:[UITextView class]] ||
                [sv isKindOfClass:[UITextField class]] ||
                [sv isKindOfClass:[UIButton class]]) {
                continue;
            }
            /* 毛玻璃：直接隐藏（这是「灰蒙蒙」的来源） */
            if ([sv isKindOfClass:[UIVisualEffectView class]]) {
                sv.hidden = YES;
                n++;
                continue;
            }
            /* CAGradientLayer 之类：清掉 layer 背景 */
            @try {
                UIColor *bg = sv.backgroundColor;
                CGFloat a = 0;
                if (bg) { [bg getRed:NULL green:NULL blue:NULL alpha:&a]; }
                if (a > 0.01) { sv.backgroundColor = [UIColor clearColor]; n++; }
                if (sv.layer.backgroundColor != NULL) { sv.layer.backgroundColor = NULL; n++; }

                /* sublayers 里的渐变色块 */
                for (CALayer *sub in [sv.layer.sublayers copy]) {
                    if ([sub isKindOfClass:[CAGradientLayer class]] &&
                        sub.frame.size.width > 40 && sub.frame.size.height > 20) {
                        sub.hidden = YES;
                        n++;
                    }
                }
            } @catch (NSException *e) { }

            n += BTStripSubtreeBG(sv, depth + 1);
        }
    } @catch (NSException *e) { }
    return n;
}

/* ============================================================
 * ★★ 滚动视图背景（2026-10-17）
 *
 * 问题（主人反馈）：
 *   「设置页下面没被渲染的拉上来变成透明了」
 *
 * 原因：
 *   我们把 UITableView/UICollectionView 的底色清成透明，
 *   滚动到「内容之外」时露出的就是更下层 —— 但更下层可能是
 *   window 的黑底，而不是我们的背景图 ⇒ 出现一块突兀的透明/黑色。
 *
 * 正确做法：
 *   给滚动视图设置 **backgroundView**（一个 UIImageView），
 *   它固定在滚动视图范围内不动，内容在上面滚动。
 *   这样滚到哪里背景都在，视觉连续。
 *
 *   纯色模式则给 backgroundColor 设成对应颜色。
 * ============================================================ */
/* ============================================================
 * ★★ 滚动视图背景 v2（2026-10-17 · 视图树实锤后重写）
 *
 * 视图树铁证：
 *     进页面时： UITableView bg=#000000/0.00 sl=13
 *                 └ UIImageView f=(0,-56 ...) ★FGIMG   ← y=-56
 *     滚动后：   UITableView bg=#000000/1.00 sl=3
 *
 * ⇒ **UITableView.backgroundView 是插在 scrollView 内容层里的**，
 *   它会跟着 contentOffset 一起滚动（y=-56 就是偏移量）。
 *   滚得越多图跑得越远 ⇒ 露出 table 自己的黑底 ⇒「拉上来变透明」。
 *
 * ⇒ backgroundView 根本不能当「固定背景」用。
 *
 * 正确做法：
 *   把图插到 **滚动视图的祖先层**（固定不动），
 *   并让 table 自己保持透明，让下面的图透上来。
 *
 *   祖先层怎么选：
 *     从 table 的 superview 往上找，直到遇到
 *       ① 不是 UIScrollView（滚动层不能放）
 *       ② 尺寸 ≥ table 的尺寸（能盖住）
 *       ③ 不是 UITableViewWrapperView（那个也是滚动的）
 *   最多找 4 层，找不到就退而用 table 的 superview。
 * ============================================================ */

#define BT_ANCESTOR_IV_TAG 0x0D1A0006
#define BT_DIM_TAG         0x0D1A0001
#define BT_SOLIDBG_TAG     0x0D1A000A   /* 非聊天页的统一不透明底色 */

/* 非聊天页（设置/关于/个性化）的统一底色 —— 和深色模式下的
 * systemBackground(#1C1C1E) 对齐，导航栏也用同一个值，
 * 这样「标题栏 vs 内容区」不会有色差 ⇒ 没有分界线。 */
static UIColor *BTSolidPageColor(void) {
    return [UIColor colorWithRed:0.109 green:0.109 blue:0.118 alpha:1.0];
}
#define BT_BGIV_TAG        0x0D1A0002

/* ★ 前置声明（实现在文件后半段，BTApplyDimIfNeeded 等早于此就要用） */
BOOL BTVcWantsClearNavBar(UIViewController *vc);

static UIView *BTFindFixedAncestor(UIView *scrollView) {
    if (!scrollView) return nil;
    UIView *v = scrollView.superview;
    UIView *best = nil;
    for (int i = 0; i < 4 && v; i++) {
        const char *cn = class_getName([v class]);
        BOOL isScroll = [v isKindOfClass:[UIScrollView class]];
        BOOL isWrapper = (cn && strstr(cn, "Wrapper") != NULL);

        if (!isScroll && !isWrapper) {
            /* 尺寸够不够大 */
            CGSize ss = scrollView.bounds.size;
            CGSize vs = v.bounds.size;
            if (vs.width >= ss.width - 1 && vs.height >= ss.height - 1) {
                return v;                 /* 找到合适的祖先 */
            }
            if (!best) best = v;          /* 记下第一个非滚动的，兜底用 */
        }
        v = v.superview;
    }
    return best ?: scrollView.superview;
}

static void BTApplyScrollBG(UIView *root, UIImage *img, UIColor *solid, int depth) {
    if (!root || depth > 8) return;
    @try {
        for (UIView *sv in [root.subviews copy]) {
            BOOL isScroll = ([sv isKindOfClass:[UITableView class]] ||
                             [sv isKindOfClass:[UICollectionView class]]);

            /* ============================================================
             * ★★ 2026-10-17：只处理「页面级滚动容器」
             *
             * 上一版把背景图贴到所有滚动视图的祖先上，结果连
             *   DeepSeek_Chat.ImageGalleryView（图片选择器）
             *   DeepSeek_Chat.InputAreaView（输入框）
             *   SessionListSearchResultsView（搜索结果）
             * 这些小控件也贴了 —— 它们内部的小 scrollView 祖先就是它们自己，
             * 贴图后整块界面花掉。
             *
             * 判据：面积必须 ≥ 父级页面 60%，才认为是「页面主体滚动区」
             * ============================================================ */
            if (isScroll) {
                CGRect sf = sv.frame;
                CGSize winSize = sv.window.bounds.size;
                CGFloat areaPct = 1.0;
                if (winSize.width > 0 && winSize.height > 0) {
                    areaPct = (sf.size.width * sf.size.height) /
                              (winSize.width * winSize.height);
                }
                /* 排除已知的「功能性子视图」（它们面积可能很大但绝不能贴图） */
                UIView *ancTest = BTFindFixedAncestor(sv);
                const char *ancName = ancTest ? class_getName([ancTest class]) : "";
                BOOL isFunctional =
                    (ancName && (strstr(ancName, "SearchResult") != NULL ||
                                 strstr(ancName, "Gallery") != NULL ||
                                 strstr(ancName, "Input") != NULL ||
                                 strstr(ancName, "Banner") != NULL ||
                                 strstr(ancName, "Panel") != NULL));

                if (areaPct < 0.6 || isFunctional) {
                    /* 小控件 / 功能性子视图：只清自身底色，不贴图 */
                    sv.backgroundColor = [UIColor clearColor];
                    sv.layer.backgroundColor = NULL;
                    BTApplyScrollBG(sv, nil, nil, depth + 1);
                    continue;
                }

                /* ① 先清掉旧方案留下的 backgroundView（它会滚动，必须删） */
                if ([sv isKindOfClass:[UITableView class]]) {
                    UITableView *tv = (UITableView *)sv;
                    if ([tv.backgroundView isKindOfClass:[UIImageView class]] &&
                        tv.backgroundView.tag == 0x0D1A0002) {
                        tv.backgroundView = nil;
                    }
                }
                if ([sv isKindOfClass:[UICollectionView class]]) {
                    UICollectionView *cv = (UICollectionView *)sv;
                    if ([cv.backgroundView isKindOfClass:[UIImageView class]] &&
                        cv.backgroundView.tag == 0x0D1A0002) {
                        cv.backgroundView = nil;
                    }
                }
                /* ② table 自己保持透明，让下面的图透上来 */
                sv.backgroundColor = [UIColor clearColor];
                sv.layer.backgroundColor = NULL;

                /* ③ 在祖先层放图（固定不动） */
                if (img) {
                    UIView *anc = BTFindFixedAncestor(sv);
                    if (anc) {
                        UIImageView *iv = (UIImageView *)[anc viewWithTag:BT_ANCESTOR_IV_TAG];
                        if (!iv) {
                            iv = [[UIImageView alloc] initWithFrame:anc.bounds];
                            iv.tag = BT_ANCESTOR_IV_TAG;
                            iv.contentMode = UIViewContentModeScaleAspectFill;
                            iv.clipsToBounds = YES;
                            iv.userInteractionEnabled = NO;
                            iv.autoresizingMask =
                                UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
                            [anc insertSubview:iv atIndex:0];
                            FLOGW(FC_UI, @"[scroll] 在祖先 %@ 上放固定背景",
                                  NSStringFromClass([anc class]));
                        }
                        iv.frame = anc.bounds;
                        iv.image = img;
                        [anc sendSubviewToBack:iv];
                    }
                } else if (solid) {
                    sv.backgroundColor = solid;
                }
            }
            BTApplyScrollBG(sv, img, solid, depth + 1);
        }
    } @catch (NSException *e) { }
}

/* ============================================================
 * ★★ Window 级背景（2026-10-17 · 兜底方案）
 *
 * 问题（主人反馈）：
 *   「设置页下面没被渲染的拉上来变成透明了」—— 一直是透明，修不好
 *
 * 为什么之前修不好：
 *   我们清掉 tableView 的底色后，滚到内容之外露出的是**更下层**。
 *   而更下层通常是 UIWindow 的黑色底，不是我们的背景图。
 *   给 tableView 设 backgroundView 只能覆盖 tableView 自身范围，
 *   tableFooter 之外的区域、以及各种 inset/safeArea 缝隙仍然会漏。
 *
 * 本方案（最彻底）：
 *   在整个 UIWindow 的**最底层**塞一张全屏 UIImageView。
 *   这样无论哪个页面把自己清成透明、无论滚到哪里，
 *   透出来的永远是这张图，不可能再露黑。
 *
 * 实现要点：
 *   • 加在 window 上（不是 windowScene.windows 的每个 rootVC）
 *   • insertSubview:atIndex:0 + sendSubviewToBack
 *   • 每次巡检刷新一次 frame（转屏 / 分屏）
 *   • 开关：bg_window_level（默认开）
 * ============================================================ */

#define BT_WINIV_TAG 0x0D1A0004

/* ============================================================
 * ★★ Window 级背景 v2（2026-10-17 修正「单图浏览器」）
 *
 * v1 的致命错误：
 *   遍历了 UIWindowScene 的**所有** window 并往里插背景图。
 *   而 scene.windows 里除了主窗口，还有一堆**全屏覆盖层**：
 *     • UIRemoteKeyboardWindow       键盘
 *     • _UITextEffectsWindow         文本特效
 *     • DSLoadinToastWindow          Toast
 *     • 各种 UIWindowLevel 很高的 alert / status 窗口
 *   往这些窗口插全屏图 ⇒ 图盖在最上面 ⇒ App 变成「单图浏览器」。
 *
 *   而且 `insertSubview:atIndex:0` 只是**窗口内**的层级，
 *   不等于「整个屏幕最底」—— 高 level 的窗口天然在上面。
 *
 * v2 严格条件（三条全满足才插）：
 *   ① windowLevel == UIWindowLevelNormal（正常内容窗口）
 *   ② isKeyWindow == YES（当前活跃的那个）
 *   ③ rootViewController 存在且不是系统类
 *
 * 另外不再用 sendSubviewToBack（它会把图推到所有子视图之下，
 * 在某些结构下反而触发重排），只用 insertSubview:atIndex:0 一次。
 * ============================================================ */
__attribute__((unused))
static void BTApplyWindowBackground(UIImage *img, UIColor *solid) {
    if (![NSThread isMainThread]) return;
    @try {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (!w) continue;

                /* ① 只处理正常层级的窗口 */
                if (w.windowLevel != UIWindowLevelNormal) continue;
                /* ② 只处理当前 key window */
                if (!w.isKeyWindow) continue;
                /* ③ rootViewController 必须是宿主自己的 */
                UIViewController *root = w.rootViewController;
                if (!root) continue;
                const char *rc = class_getName([root class]);
                if (rc && (strncmp(rc, "UI", 2) == 0 || strncmp(rc, "_UI", 3) == 0))
                    continue;

                UIImageView *iv = (UIImageView *)[w viewWithTag:BT_WINIV_TAG];

                if (img) {
                    if (!iv) {
                        iv = [[UIImageView alloc] initWithFrame:w.bounds];
                        iv.tag = BT_WINIV_TAG;
                        iv.contentMode = UIViewContentModeScaleAspectFill;
                        iv.clipsToBounds = YES;
                        iv.userInteractionEnabled = NO;
                        iv.autoresizingMask =
                            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                        /* 插在最底（仅窗口内） */
                        [w insertSubview:iv atIndex:0];
                        FLOGW(FC_UI, @"[winbg] 已在 %@ 底层插入背景（level=%.0f）",
                              NSStringFromClass([root class]), (double)w.windowLevel);
                    }
                    iv.frame = w.bounds;
                    iv.image = img;
                    iv.alpha = 1.0;
                    /* ⚠️ 不再调 sendSubviewToBack —— v1 就是它把层级搞乱的 */
                } else if (solid) {
                    w.backgroundColor = solid;
                }
            }
        }
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[winbg] 异常: %@", e.reason);
    }
}

/* ============================================================
 * ★★ 按视图树逆向结果精准修复（2026-10-17 · 第四次）
 *
 * 视图树实锤（设置页是 UIViewController.hosting 的模态卡片）：
 *
 *   UIWindow
 *    └ UITransitionView                          ← 模态转场容器
 *       ├ UIDimmingView  bg=#000000/0.00  LBG    ← ★ 遮罩层被我们清成全透明了
 *       └ UIDropShadowView f=(20,30 374x629) b=(414x696)
 *          │            ↑ frame<bounds ⇒ 带 transform，四角透明
 *          └ UITableView bg=#000000/0.00
 *             ├ UIImageView ★FGIMG   ← 我们的背景（只在这个 table 里）
 *             └ UITableViewWrapperView f=(16,0 382x696)
 *                          ↑ 左右各 16px 不在表格内 ⇒ 漏
 *
 * ⇒ 「拉上来变透明」看到的三个漏点：
 *     ① 卡片圆角外的四个角
 *     ② 表格左右各 16px padding
 *     ③ 表格内容区之外（footer 区域）
 *   全部透到 UIDimmingView（alpha 0）→ UITransitionView → window 黑底
 *
 * 三层修复：
 *   A. 恢复 UIDimmingView 的暗色底（#252528/0.46 是系统原值），
 *      让模态卡片周围自然变暗 —— 这是 iOS 原生行为，不是盖背景
 *   B. 给 UITransitionView 也放一张背景图（覆盖圆角外区域）
 *   C. 给 UITableViewWrapperView 的父级（UITableView）已经有图了，
 *      所以 16px padding 透下去能见到图 ✓（A/B 修好后即可）
 * ============================================================ */

#define BT_TRANSIV_TAG 0x0D1A0005
#define BT_MODAL_SHADOW_TAG 0x0D1A0009   /* ★ 不能和 BT_ANCESTOR_IV_TAG(0x0D1A0006) 撞车 */
#define BT_MODAL_IV_TAG     0x0D1A0007
#define BT_MODAL_DIM_TAG    0x0D1A0008
#define BT_PANEL_SCRIM_TAG  0x0D1A000A

/* ---- 从被 present 的 VC 的 view 往上找「它自己的」模态卡片 ----
 *   ★ 为什么不扫 window：window 里同一时刻可能有多个 UIDropShadowView
 *     （侧边抽屉、Toast、设置卡片都在），按类名扫会误伤抽屉，
 *     给它刷底色等于把整个界面压暗。从 vc.view 往上走 100% 精准。 */
static UIView *BTFindModalCard(UIView *start) {
    for (UIView *p = start; p; p = p.superview) {
        const char *cn = class_getName([p class]);
        if (cn && strstr(cn, "UIDropShadowView") != NULL) return p;
        if ([p isKindOfClass:[UIWindow class]]) break;
    }
    return nil;
}

/* ============================================================
 * ★★ 模态卡片修复 v2（2026-10-17 · 精准版）
 *
 *   旧版三宗罪：
 *     ① 只扫 window.subviews 一层 ⇒ UIDimmingView 在 UITransitionView
 *        下面，永远匹配不到（暗色恢复从写出来就没生效过）
 *     ② 放开 isKeyWindow 后按类名扫 ⇒ 启动时抓到**全屏抽屉容器**
 *        ⇒ 给它刷 0.35 黑 ⇒ 整个界面发暗
 *     ③ 只刷底色 ⇒ 照片模式下卡片里是死黑色，和背景图不连续
 *
 *   新版：从「当前这个 VC」向上找自己的 UIDropShadowView，
 *     ① 恢复兄弟节点 UIDimmingView 的系统暗色（挡住下层列表）
 *     ② 卡片内贴同一张背景图 + 圆角裁剪
 *        ⇒ 左右 16px padding、四角、footer 全部变成连续背景，
 *          不再有「镂空」接缝
 * ============================================================ */
static void BTStyleModalCard(UIViewController *vc, UIImage *img, UIColor *solid) {
    if (![NSThread isMainThread] || !vc) return;
    (void)img; (void)solid;

    UIView *card = BTFindModalCard(vc.view);
    if (!card) return;

    /* 几何判据：全屏容器（抽屉）跳过 */
    UIView *win = card.window;
    if (!win) return;
    CGFloat winH = win.bounds.size.height;
    if (winH > 0 && card.bounds.size.height >= winH - 8) return;

    @try {
        /* ============================================================
         * ★★★ 2026-10-17 最终版：只恢复 UIDimmingView 的暗色
         *
         *   主人反馈「设置完全不透明 / 断连」后复盘：
         *     尼尼之前给卡片刷了实底、贴了第二张图、清了容器底色，
         *     结果把模态卡片的自然观感彻底破坏。
         *
         *   现在只做一件**本来就该做、且已验证有效**的事：
         *     把被我们清成透明的 UIDimmingView 恢复成系统原值
         *     #252528 / 0.46 —— 这是 iOS 模态卡片本来就有的暗色遮罩，
         *     恢复后卡片外的圆角区域自然就是暗的，
         *     不需要任何贴图/实底，也不会「断连」。
         *
         *   卡片本身：完全不碰（保持宿主原样）。
         * ============================================================ */
        UIView *tv = card.superview;
        if (!tv) return;
        for (UIView *sb in [tv.subviews copy]) {
            const char *cn = class_getName([sb class]);
            if (!cn || strstr(cn, "UIDimmingView") == NULL) continue;
            CGFloat a = 0;
            if (sb.backgroundColor) {
                [sb.backgroundColor getRed:NULL green:NULL blue:NULL alpha:&a];
            }
            if (a < 0.40) {
                sb.backgroundColor = [UIColor colorWithRed:0.145 green:0.145
                                                     blue:0.157 alpha:0.46];
                static int once = 0;
                if (!once) {
                    once = 1;
                    FLOGW(FC_UI, @"[modal] 恢复 UIDimmingView 暗色 0.46（卡片本身不碰）");
                }
            }
        }
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[modal] 异常: %@", e.reason);
    }
}

/* 兼容旧调用点（window 级扫描已废弃，保留空实现避免链接错误） */
__attribute__((unused))
static void BTFixModalOverlay(UIWindow *w, UIImage *img) {
    (void)w; (void)img;
}

/* ============================================================
 * ★★ present 探测器（0.2s）
 *
 *   巡检 timer 启动 6 秒后会降频到 3s/轮，而设置页/抽屉是「随手点开」的，
 *   赶上哪一轮完全看运气 ⇒ 视觉上「先透明，1~3 秒才出图」。
 *   所以单独挂一个轻量探测器：只在「最顶层 VC 变了」那一刻补一次。
 *   稳态下每 200ms 只做几次指针比较，开销可以忽略。
 * ============================================================ */
static void BTApplyBackground(UIViewController *vc);
static void BTMaintainModalCards(void);

static uintptr_t gLastTopVC = 0;

static UIViewController *BTCurrentTopVC(void) {
    UIViewController *top = nil;
    @try {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.windowLevel != UIWindowLevelNormal) continue;
                UIViewController *vc = w.rootViewController;
                if (!vc) continue;
                int d = 0;
                while (vc && d++ < 10) {
                    top = vc;
                    if (vc.presentedViewController) vc = vc.presentedViewController;
                    else break;
                }
            }
        }
    } @catch (NSException *e) { }
    return top;
}

static void BTWatchPresented(void) {
    if (![NSThread isMainThread]) return;
    @autoreleasepool {
        UIViewController *top = BTCurrentTopVC();
        uintptr_t addr = (uintptr_t)(__bridge void *)top;
        if (addr == gLastTopVC) return;
        gLastTopVC = addr;
        if (!top) return;

        const char *cn = class_getName([top class]);
        if (!cn || strstr(cn, "DeepSeek") == NULL) return;

        FLOGW(FC_UI, @"[watch] 顶层变化 → %@", NSStringFromClass([top class]));
        if ([[FDMConfig shared] boolFor:P_BG key:@"enabled"] && top.view &&
            top.view.window) {
            @try { BTApplyBackground(top); } @catch (NSException *e) { }
        }
        if ([[FDMConfig shared] boolFor:P_BG key:@"bg_fix_modal"])
            BTMaintainModalCards();
    }
}


/* ============================================================
 * ★★★ 「彻底透明」只许作用于聊天页（2026-10-17 最终定案）
 *
 *   事故记录（重要，别再踩）：
 *     bg_clear_all 是**无差别**清底色的，它把
 *       • 会话抽屉（SessionListCollectionView）
 *       • 设置页（ProfileViewController 的列表）
 *     这类「白字列表」的容器底色也清成 #000000/0.00
 *     ⇒ 白色标题直接画在很亮的照片上，亮处整片「看不见」
 *     ⇒ 主人看到的是「下面的列表项没了」（其实是内容被背景吃掉）
 *
 *   主人明确：气泡融进背景的效果**只在聊天页**要，
 *   抽屉/设置页要的是能看清的列表。
 *
 *   ⇒ 这里加白名单：只有 MessageViewController 才执行清理。
 * ============================================================ */
static BOOL BTVcIsChatPage(UIViewController *vc) {
    if (!vc) return NO;
    const char *cn = class_getName([vc class]);
    if (!cn) return NO;
    return (strstr(cn, "MessageViewController") != NULL);
}

/* 只在聊天页执行「彻底透明」 */
static void BTStripIfChatPage(UIViewController *vc, const char *who) {
    if (!vc || !vc.view) return;
    if (![[FDMConfig shared] boolFor:P_BG key:@"bg_clear_all"]) return;
    if (!BTVcIsChatPage(vc)) return;
    BTStripEverything(vc.view, 0);
    FLOGW(FC_UI, @"[bg] 彻底透明（仅聊天页）%s", who ? who : "");
}


/* ============================================================
 * ★★ 模态卡片「保持器」（2026-10-17 主人反馈「先透明再延迟出图」）
 *
 *   现象：进设置页瞬间图是对的，紧接着**闪一下变透明**，过一会儿才回来。
 *
 *   原因：BTStyleModalCard 只在 BTApplyBackground 里跑，
 *        而 BTApplyBackground 只在该 VC 的「配置签名变化」时执行一次。
 *        之后宿主每一轮 layoutSubviews / cell 复用都会：
 *          • 把我们插入的 dim / 图 移出层级或改回黑色底
 *          • 把底部「帮助与反馈」cell 又设回 hidden
 *        ⇒ 没有任何人再维护它，于是闪一下空、再靠下次巡检慢慢补回来。
 *
 *   修法：每轮巡检都主动找「当前被 present 的页面」，幂等地重刷一遍。
 *        幂等 = 已经对了就只重排层级，不会重复插图（不闪）。
 * ============================================================ */
static UIImage *BTLoadBGImageNow(void) {
    FDMConfig *C = [FDMConfig shared];
    if (![C boolFor:P_BG key:@"enabled"]) return nil;
    NSString *mode = [C stringFor:P_BG key:@"mode"];
    NSString *file = [C stringFor:P_BG key:@"file"];
    if (![mode isEqualToString:@"image"] || !file.length) return nil;
    NSString *p = [BTDocs() stringByAppendingPathComponent:file];
    return [UIImage imageWithContentsOfFile:p];
}

static void BTMaintainModalCards(void) {
    if (![NSThread isMainThread]) return;
    if (![[FDMConfig shared] boolFor:P_BG key:@"bg_fix_modal"]) return;
    static NSTimeInterval last = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - last < 0.25) return;      /* 节流：layout 风暴时不刷爆 */
    last = now;

    UIImage *img = BTLoadBGImageNow();
    @try {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.windowLevel != UIWindowLevelNormal) continue;
                UIViewController *vc = w.rootViewController;
                int d = 0;
                while (vc && d++ < 8) {
                    if (vc.presentedViewController) {
                        BTStyleModalCard(vc.presentedViewController, img, nil);
                        vc = vc.presentedViewController;
                    } else {
                        BTStyleModalCard(vc, img, nil);
                        break;
                    }
                }
            }
        }
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[modal] 保持器异常: %@", e.reason);
    }
}

static int BTStripBubbles(UIView *root, int depth) {
    if (!root || depth > 12) return 0;
    int touched = 0;
    @try {
        for (UIView *sv in [root.subviews copy]) {
            const char *cn = class_getName([sv class]);
            BOOL isCell = NO;
            if (cn) {
                isCell = (strstr(cn, "MessageCell") != NULL ||
                          strstr(cn, "FragmentView") != NULL ||
                          strstr(cn, "BubbleView") != NULL);
            }
            if (isCell) {
                /* ★ 已处理过的跳过（打 tag，避免每轮重复遍历） */
                if (sv.tag == BT_CELL_DONE_TAG) continue;
                int k = BTStripSubtreeBG(sv, 0);
                sv.tag = BT_CELL_DONE_TAG;
                touched++;
                if (touched <= 3)
                    FLOGW(FC_UI, @"[bg] 气泡透明化 %s（清 %d 处）", cn, k);
            }
            touched += BTStripBubbles(sv, depth + 1);
        }
    } @catch (NSException *e) { }
    return touched;
}



static int BTHideGradientMask(UIView *root, int depth) {
    if (!root || depth > 10) return 0;
    int n = 0;
    @try {
        for (UIView *sv in [root.subviews copy]) {
            const char *cn = class_getName([sv class]);
            BOOL hit = NO;
            if (cn) {
                if (strstr(cn, "DSGradientView") != NULL)      hit = YES;
                if (strstr(cn, "VariableBlurView") != NULL)    hit = YES;
                if (strstr(cn, "BackdropSegmentView") != NULL) hit = YES;
                if (strstr(cn, "GradientView") != NULL)        hit = YES;
            }
            if (hit) {
                /* ★ 2026-10-17 修：只在「真的发生变化」时打日志。
                 *   旧版每帧每个命中视图都打一条 ⇒ fdm.log 4MB、
                 *   7P 上 IO 抖动，还会把 [sug] 的关键日志淹掉。 */
                if (sv.alpha != 0.0) {
                    sv.alpha = 0.0;      /* 只去视觉，布局不动 */
                    static int bgLog = 0;
                    if (bgLog < 40) {
                        bgLog++;
                        FLOGW(FC_UI, @"[bg] 隐藏遮罩 %s（累计 %d）", cn, bgLog);
                    }
                }
                sv.hidden = NO;          /* 保持 hidden 状态别动，靠 alpha */
                n++;
            }
            n += BTHideGradientMask(sv, depth + 1);
        }
    } @catch (NSException *e) { }
    return n;
}

/* ============================================================
 * ★★ 保护「危险操作」单元格（2026-10-17 · 主人反馈）
 *
 * 主人：「唯一的区别就是下面那个退出登陆按钮也透明了」
 *
 * 问题：
 *   bg_clear_all 把**所有**非文字视图的底色都清了，
 *   包括设置页底部「退出登录」那个 cell ——
 *   它本来有个卡片底色（红色文字的容器），现在透明了，
 *   看起来像一段漂浮的红字，很难看。
 *
 * 解法：顺着 cell 内部找 UILabel，读文本匹配关键词，
 *   命中就整棵子树跳过（保留原底色）。
 *
 * 关键词覆盖中英日，够用。
 * ============================================================ */
static NSArray<NSString *> *BTDestructiveKeywords(void) {
    static NSArray<NSString *> *kws = nil;
    if (!kws) {
        kws = @[ @"退出", @"登出", @"注销", @"删除账号", @"移除账号",
                 @"Log out", @"Logout", @"Sign Out", @"Sign out",
                 @"Delete Account", @"Delete account",
                 @"ログアウト", @"退会" ];
    }
    return kws;
}

/* 纯 C 递归：找一个子树里有没有「危险操作」文字 */
static BOOL BTFindDestructiveText(UIView *v, int depth) {
    if (!v || depth > 8) return NO;
    @try {
        if ([v isKindOfClass:[UILabel class]]) {
            NSString *t = ((UILabel *)v).text;
            if (t.length) {
                for (NSString *k in BTDestructiveKeywords()) {
                    if ([t rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound)
                        return YES;
                }
            }
        }
        for (UIView *sv in v.subviews) {
            if (BTFindDestructiveText(sv, depth + 1)) return YES;
        }
    } @catch (NSException *e) { }
    return NO;
}

/* 把子树里的 UILabel 全部染成系统红（destructive 色） */
__attribute__((unused))
static void BTPaintDestructiveRed(UIView *v, int depth) {
    if (!v || depth > 8) return;
    @try {
        if ([v isKindOfClass:[UILabel class]]) {
            ((UILabel *)v).textColor = [UIColor systemRedColor];
        }
        for (UIView *sv in v.subviews) BTPaintDestructiveRed(sv, depth + 1);
    } @catch (NSException *e) { }
}

/* ============================================================
 * ★★ 懒渲染修复（2026-10-17 · 主人判断正确）
 *
 * 视图树实锤：
 *     UITableView            bg=#000000/1.00      ← 表格自身黑
 *     UIView f=(0,0 374x57)  bg=#1C1C1E/1.00      ← cell 卡片底
 *     _UICollectionViewListLayoutSectionBackgroundColorDecorationView
 *                                                ← 分组背景（截图那块浅灰）
 *
 * 根因：
 *   UITableView/UICollectionView 的 cell 是**复用**的。
 *   每次 cell 滚入视野，UIKit 会调它的 configure / 重设 appearance，
 *   把 backgroundColor 又设回来 ⇒ 我们之前清的又白清了。
 *
 * 解法：
 *   hook `layoutSubviews` —— 每次 cell 布局（含复用时）都跑一遍清理。
 *   layoutSubviews 本来就会触发，我们只是顺便清个底色，开销可忽略。
 * ============================================================ */

#define BT_MAX_CELLHOOK 8
typedef struct { Class cls; SEL sel; IMP orig; } BTCellHook;
static BTCellHook gCellHooks[BT_MAX_CELLHOOK];
static int gCellHookN = 0;
static __thread int gCellReent = 0;

static IMP BTCellOrig(Class cls, SEL sel) {
    for (Class c = cls; c != Nil; c = class_getSuperclass(c))
        for (int i = 0; i < gCellHookN; i++)
            if (gCellHooks[i].cls == c && sel_isEqual(gCellHooks[i].sel, sel))
                return gCellHooks[i].orig;
    return NULL;
}

/* 前置声明：判定函数定义在后面 */
static BOOL BTViewBelongsToChat(UIView *v);

static void bt_cellLayout(id self, SEL _cmd) {
    IMP o = BTCellOrig(object_getClass(self), _cmd);
    if (o) ((void(*)(id,SEL))o)(self, _cmd);

    if (gCellReent) return;
    /* 开关关着就别动 */
    if (!FDMBeautyClearAllOn()) return;
    /* ★ 只处理聊天页里的 cell（设置页/会话抽屉的 cell 绝不动） */
    if (!BTViewBelongsToChat((UIView *)self)) return;

    /* ============================================================
     * ★★ 2026-10-17 修正「按钮没了」
     *
     * 上一版：BTStripEverything(self, 0) —— **递归清整棵子树**
     *   → 把 UIListContentView 里按钮 / 开关的容器底色也清了
     *   → 按钮看起来「消失」（透明 + 没底色）
     *   → 切后台再回来，宿主重新 configure 才画回来
     *
     * 正确做法：cell 只清 **自己 + contentView** 两层，
     *   绝不递归进 UIListContentView（那里面是真实内容）。
     * ============================================================ */
    gCellReent = 1;
    @try {
        UITableViewCell *cell = (UITableViewCell *)self;
        NSMutableArray<UIView *> *targets = [NSMutableArray array];
        [targets addObject:cell];
        if (cell.contentView) [targets addObject:cell.contentView];

        for (UIView *t in targets) {
            UIColor *bg = t.backgroundColor;
            CGFloat a = 0;
            if (bg) { [bg getRed:NULL green:NULL blue:NULL alpha:&a]; }
            if (a > 0.01) t.backgroundColor = [UIColor clearColor];
            if (t.layer.backgroundColor != NULL) t.layer.backgroundColor = NULL;
        }
    } @catch (NSException *e) { }
    gCellReent = 0;
}

static BOOL BTCellHookInstall(Class c) {
    if (!c) return NO;
    @try {
        SEL sel = sel_registerName("layoutSubviews");
        Method m = class_getInstanceMethod(c, sel);
        if (!m) return NO;
        const char *types = method_getTypeEncoding(m);
        IMP old = method_getImplementation(m);
        /* 防递归：原实现已是我们自己 */
        if (old == (IMP)bt_cellLayout) return NO;

        /* 自己没实现就 addMethod，绝不污染父类 */
        BOOL hasOwn = NO;
        unsigned int mc = 0;
        Method *own = class_copyMethodList(c, &mc);
        if (own) {
            for (unsigned int i = 0; i < mc; i++)
                if (sel_isEqual(method_getName(own[i]), sel)) { hasOwn = YES; break; }
            free(own);
        }
        if (!hasOwn) {
            if (!class_addMethod(c, sel, (IMP)bt_cellLayout, types)) return NO;
        } else {
            method_setImplementation(m, (IMP)bt_cellLayout);
        }
        if (gCellHookN < BT_MAX_CELLHOOK) {
            gCellHooks[gCellHookN].cls = c;
            gCellHooks[gCellHookN].sel = sel;
            gCellHooks[gCellHookN].orig = old;
            gCellHookN++;
        }
        return YES;
    } @catch (NSException *e) { return NO; }
}

/* ============================================================
 * ★★ 2026-10-17：为什么「透明还是没修」
 *
 * 视图树实锤：
 *     刚进页面   UITableView bg=#000000/0.00
 *     滚动之后   UITableView bg=#000000/1.00   ← 又变回黑
 *
 * 尼尼只 hook 了 **cell** 的 layoutSubviews，
 * 但**表格自己**的 backgroundColor 也被重设了
 * （UIKit 在重新布局 / reloadData / 滚动时会把 table 底色设回去）。
 *
 * ⇒ 必须同时 hook UITableView / UICollectionView 自己的 layoutSubviews。
 * ============================================================ */

/* 前置声明：清子树（已在上面声明过） */
BOOL FDMBeautyClearAllOn(void);

/* ============================================================
 * ★★★ 2026-10-17 关键修复：「只清聊天页」必须下沉到 view 级别
 *
 *   日志铁证：
 *     clear_all 处理 MessageViewController（聊天页=1）  ← 只清了它
 *     clear_all 处理 SessionListViewController（聊天页=0）← 没清
 *   但视觉上抽屉/设置页**照样**被清了。
 *
 *   因为真正清底色的不是 BTStripEverything，而是这两个**全局** hook：
 *     • bt_scrollLayout  ← 挂在 UITableView / UICollectionView 本类
 *     • bt_cellLayout    ← 挂在所有 DeepSeek*Cell 类
 *   它们不考虑「这个视图属于哪个页面」，只要 layout 就清。
 *
 *   ⇒ 加一道 view 级判定：沿着 superview 链找到所属 VC，
 *     只有 MessageViewController 才动手。
 *     （其他页面一律原样返回，一个字节都不改）
 * ============================================================ */
static BOOL BTViewBelongsToChat(UIView *v) {
    if (!v) return NO;
    /* 沿 superview 链找 nextResponder 中的 VC */
    for (UIView *p = v; p; p = p.superview) {
        UIResponder *r = p.nextResponder;
        int guard = 0;
        while (r && guard++ < 6) {
            if ([r isKindOfClass:[UIViewController class]]) {
                const char *cn = class_getName([r class]);
                if (cn) {
                    if (strstr(cn, "MessageViewController") != NULL) return YES;
                    /* 明确不是聊天页的容器 → 直接判否，省得再往上找 */
                    if (strstr(cn, "SessionListViewController") != NULL ||
                        strstr(cn, "ProfileViewController") != NULL ||
                        strstr(cn, "SessionViewController") != NULL) return NO;
                }
            }
            r = r.nextResponder;
        }
    }
    return NO;
}

static void bt_scrollLayout(id self, SEL _cmd) {
    IMP o = BTCellOrig(object_getClass(self), _cmd);
    if (o) ((void(*)(id,SEL))o)(self, _cmd);

    if (!FDMBeautyClearAllOn()) return;
    /* ★ 只处理聊天页里的滚动视图（抽屉/设置页的表格绝不动） */
    if (!BTViewBelongsToChat((UIView *)self)) return;

    @try {
        UIView *v = (UIView *)self;
        /* 清自身两层背景 */
        UIColor *bg = v.backgroundColor;
        CGFloat a = 0;
        if (bg) { [bg getRed:NULL green:NULL blue:NULL alpha:&a]; }
        if (a > 0.01) v.backgroundColor = [UIColor clearColor];
        if (v.layer.backgroundColor != NULL) v.layer.backgroundColor = NULL;

        /* 顺便把分组装饰背景也清（_UICollectionViewListLayoutSectionBackgroundColorDecorationView） */
        for (UIView *sv in [v.subviews copy]) {
            const char *cn = class_getName([sv class]);
            if (!cn) continue;
            if (strstr(cn, "BackgroundColorDecoration") != NULL ||
                strstr(cn, "SectionBackground") != NULL) {
                UIColor *b2 = sv.backgroundColor;
                CGFloat a2 = 0;
                if (b2) { [b2 getRed:NULL green:NULL blue:NULL alpha:&a2]; }
                if (a2 > 0.01) sv.backgroundColor = [UIColor clearColor];
                if (sv.layer.backgroundColor != NULL) sv.layer.backgroundColor = NULL;
            }
        }
    } @catch (NSException *e) { }
}

static int BTInstallScrollHooks(void) {
    int n = 0;
    @try {
        Class tbl = [UITableView class];
        Class col = [UICollectionView class];
        SEL sel = sel_registerName("layoutSubviews");

        for (int i = 0; i < 2; i++) {
            Class c = (i == 0) ? tbl : col;
            Method m = class_getInstanceMethod(c, sel);
            if (!m) continue;
            IMP old = method_getImplementation(m);
            if (old == (IMP)bt_scrollLayout) continue;
            if (!class_addMethod(c, sel, (IMP)bt_scrollLayout,
                                 method_getTypeEncoding(m))) {
                /* 已有自己的实现：直接换 */
                method_setImplementation(m, (IMP)bt_scrollLayout);
            }
            if (gCellHookN < BT_MAX_CELLHOOK) {
                gCellHooks[gCellHookN].cls = c;
                gCellHooks[gCellHookN].sel = sel;
                gCellHooks[gCellHookN].orig = old;
                gCellHookN++;
            }
            n++;
        }
        if (n) FLOGW(FC_UI, @"[bg] 滚动容器 layoutSubviews hook：%d 个", n);
    } @catch (NSException *e) { }
    return n;
}

/* 给所有 cell 类装 hook（只装宿主的，跳过系统基类） */
static int BTInstallCellHooks(void) {
    int n = 0;
    @try {
        int total = objc_getClassList(NULL, 0);
        if (total <= 0) return 0;
        __unsafe_unretained Class *list =
            (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)total);
        if (!list) return 0;
        total = objc_getClassList(list, total);
        for (int i = 0; i < total; i++) {
            Class c = list[i];
            if (!c) continue;
            const char *cn = class_getName(c);
            if (!cn) continue;
            /* ★ 严格：只 hook 宿主自己的 cell（名字必须含 DeepSeek） */
            if (!strstr(cn, "DeepSeek")) continue;
            if (!strstr(cn, "Cell")) continue;
            if (BTCellHookInstall(c)) {
                n++;
                if (n <= 6) FLOGW(FC_UI, @"[bg] cell hook → %s", cn);
            }
        }
        free(list);
    } @catch (NSException *e) { }
    return n;
}

static void BTStripEverything(UIView *root, int depth) {
    if (!root || depth > 12) return;

    /* ============================================================
     * ★★ 2026-10-17 「闪一下变透明」的真凶：
     *
     *   BTApplyBackground 的执行顺序是
     *     ① 贴背景图  ② BTStyleModalCard 插 dim 遮罩
     *     ③ BTStripEverything  ← 它把刚插的 dim 也清成透明
     *   ⇒ 视觉上就是「图出来了 → 闪一下没了 → 下次巡检再补回来」
     *
     *   所以这里必须**跳过我们自己的图层**（按 tag 识别）：
     *     背景图 / dim 遮罩 / 模态卡片图 —— 一律不许清。
     * ============================================================ */
    if (root.tag == BT_BGIV_TAG ||
        root.tag == BT_DIM_TAG ||
        root.tag == BT_MODAL_IV_TAG ||
        root.tag == BT_MODAL_DIM_TAG ||
        root.tag == BT_ANCESTOR_IV_TAG ||
        root.tag == BT_PANEL_SCRIM_TAG) {
        return;
    }
    @try {
        for (UIView *sv in [root.subviews copy]) {
            if ([sv isKindOfClass:[UILabel class]] ||
                [sv isKindOfClass:[UITextView class]] ||
                [sv isKindOfClass:[UITextField class]] ||
                [sv isKindOfClass:[UIButton class]]) {
                continue;               /* 文字类不动 */
            }

            /* ★★ 关键：遇到「列表内容视图」就停止递归
             *   UIListContentView 里面是 cell 的真实内容（按钮/开关/图标），
             *   继续往下清会把它们弄成透明 ⇒ 看起来「按钮没了」 */
            {
                const char *ccn = class_getName([sv class]);
                if (ccn && (strstr(ccn, "UIListContentView") != NULL ||
                            strstr(ccn, "ListContentConfiguration") != NULL ||
                            strstr(ccn, "ContentView") != NULL)) {
                    continue;
                }
            }

            /* ============================================================
             * ★★ 2026-10-17 主人纠正：「你还要让他格格不入？」
             *
             * 上一版把「退出登录」cell 整棵跳过、保留黑底，
             * 结果它在一片透明里显得特别突兀 —— 反而更丑。
             *
             * 正确做法：**跟其它 cell 一样透明**，但把文字染成系统红
             *   ⇒ 风格统一 + 仍然有警示感
             * ============================================================ */
            BOOL isDestructive = NO;
            if ([sv isKindOfClass:[UITableViewCell class]] ||
                [sv isKindOfClass:[UICollectionViewCell class]]) {
                isDestructive = BTFindDestructiveText(sv, 0);
            }

            /* 清两层背景（危险操作也清，保持一致）
             * ★ 额外：滚动容器和列表分组背景也要清 */
            @try {
                const char *scn = class_getName([sv class]);
                BOOL isListBG = (scn && (strstr(scn, "BackgroundColorDecoration") != NULL ||
                                         strstr(scn, "SectionBackground") != NULL));
                BOOL isScroll = [sv isKindOfClass:[UIScrollView class]];

                UIColor *bg = sv.backgroundColor;
                CGFloat a = 0;
                if (bg) { [bg getRed:NULL green:NULL blue:NULL alpha:&a]; }

                /* 滚动容器：如果已经有我们的 backgroundView 图就跳过自身，否则清 */
                if (isScroll) {
                    if (a > 0.01) sv.backgroundColor = [UIColor clearColor];
                } else if (isListBG || a > 0.01) {
                    if (a > 0.01) sv.backgroundColor = [UIColor clearColor];
                }
                if (sv.layer.backgroundColor != NULL) sv.layer.backgroundColor = NULL;
            } @catch (NSException *e) { }

            (void)isDestructive;   /* 主人 2026-10-17：退出登录本来就不是红色，别改 */

            BTStripEverything(sv, depth + 1);
        }
    } @catch (NSException *e) { }
}

static void BTClearDeep(UIView *root, CGFloat parentArea, int depth) {
    if (!root || depth > 8) return;
    @try {
        NSArray<UIView *> *snapshot = [root.subviews copy];
        CGFloat myArea = root.bounds.size.width * root.bounds.size.height;

        for (UIView *sv in snapshot) {
            if (BTIsContentClass(sv)) continue;

            const char *cn = class_getName([sv class]);
            BOOL nameLikeBG = NO;
            if (cn) {
                nameLikeBG = (strstr(cn, "Container") != NULL ||
                              strstr(cn, "Background") != NULL ||
                              strstr(cn, "Scroll") != NULL ||
                              strstr(cn, "Table") != NULL ||
                              strstr(cn, "Collection") != NULL ||
                              strstr(cn, "Hosting") != NULL ||
                              strstr(cn, "SafeArea") != NULL);
            }

            CGFloat area = sv.bounds.size.width * sv.bounds.size.height;
            BOOL bigBlock = (myArea > 0 && area >= myArea * 0.40);

            /* A：容器类无条件清；B：大块且不透明清 */
            if (nameLikeBG) {
                BTStripBG(sv, YES, bigBlock);
            } else if (bigBlock) {
                BTStripBG(sv, NO, bigBlock);
            }

            BTClearDeep(sv, area > 0 ? area : myArea, depth + 1);
        }
    } @catch (NSException *e) { }
}

static void BTClearContainerBG(UIView *root) {
    if (!root) return;
    BTClearDeep(root, root.bounds.size.width * root.bounds.size.height, 0);
}

/* ★ 暗化遮罩：图片太亮时文字看不清，加一层黑色半透明
 *   用 tag 找已有的，避免重复插 */
static void BTApplyDimIfNeeded(UIViewController *vc) {
    if (!vc || !vc.view) return;
    @try {
        /* ============================================================
         * ★★★ 2026-10-17 深夜 · 「分界线」真凶就在这里
         *
         *   视图树实锤（设置页）：
         *     UILayoutContainerView 414x696
         *       UIView ★DIM 0.50                      ← 父页面（Root）插的
         *       UITableView 414x696
         *         UIView (0,-56 414x696) 0.50 黑       ← ★ 又插了一个！
         *
         *   设置页的 vc.view **本身就是那张 UITableView**，
         *   我们把压暗罩当子视图插进去 ⇒ 它跟着内容滚，
         *   而且 table 的 bounds.origin.y = -56（导航栏 inset），
         *   于是它只盖住上半截，下面露出来 ⇒ 屏幕上出现
         *   「很黑 / 正常」一条水平分界线（主人实拍）。
         *
         *   ⇒ 两条铁律：
         *     ① vc.view 是滚动容器 ⇒ 绝不在它里面插覆盖层
         *     ② 祖先链上已经有同伴 ⇒ 不重复插（避免双重压暗）
         * ============================================================ */
        {
            /* ① 清掉历史遗留：滚到容器内部的 ★DIM */
            if ([vc.view isKindOfClass:[UIScrollView class]]) {
                NSMutableArray *kill = [NSMutableArray array];
                for (UIView *sv in vc.view.subviews)
                    if (sv.tag == BT_DIM_TAG || sv.tag == BT_BGIV_TAG) [kill addObject:sv];
                for (UIView *k in kill) [k removeFromSuperview];
                if (kill.count)
                    FLOGW(FC_UI, @"[bg] %@ 的 view 是滚动容器：摘掉 %lu 个覆盖层（会滚）",
                          NSStringFromClass([vc class]), (unsigned long)kill.count);
            }
            if ([vc.view isKindOfClass:[UIScrollView class]]) {
                /* 本层不插，交给父页面（它已经有全屏压暗了） */
                return;
            }
        }

        FDMConfig *C = [FDMConfig shared];
        NSInteger pct = [C intFor:P_BG key:@"dim"];      /* 0~80 */
        if (pct < 0) pct = 0;
        if (pct > 80) pct = 80;

        /* ★★★ 2026-10-17 深夜：非聊天页兜底一个最低压暗。
         *   设置页的单元格是 #282828，但**分区标题**（账户/应用/语音/关于）
         *   是系统灰字直接画在壁纸上的 —— 亮壁纸下几乎看不见。
         *   给页面多压一层，标题就回来了（主人实拍的那种"糊在墙上"）。 */
        CGFloat a = pct / 100.0;
        if (!BTVcWantsClearNavBar(vc) && a < 0.50) a = 0.50;

        UIView *old = [vc.view viewWithTag:BT_DIM_TAG];
        if (a <= 0.001) {
            if (old) [old removeFromSuperview];
            return;
        }
        UIView *dim = old;
        if (!dim) {
            dim = [[UIView alloc] initWithFrame:vc.view.bounds];
            dim.tag = BT_DIM_TAG;
            dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            dim.userInteractionEnabled = NO;
            /* ★ 插到 index 1：index 0 是背景图 bgIV，dim 必须压在它**上面**
             *   （旧版插 index 0 会被 sendSubviewToBack 推到背景图下面，等于没效果） */
            [vc.view insertSubview:dim atIndex:vc.view.subviews.count ? 1 : 0];
        }
        dim.frame = vc.view.bounds;
        dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:a];

        /* ★ 修正层级：index 0 = 背景图，index 1 = dim，其余内容依次往后
         *   ⚠️ 绝不能用 bringSubviewToFront / sendSubviewToBack 反复调，
         *      那会把 dim 推到最上盖住整个界面（尼尼踩过这个坑）。 */
        @try {
            static const void *kBgIVKey2 = &kBgIVKey2;
            UIImageView *iv = objc_getAssociatedObject(vc, kBgIVKey2);
            (void)iv;
            /* 直接按「重新插一遍」的方式强制排序 */
            UIView *bgv = [vc.view viewWithTag:BT_BGIV_TAG];
            if (bgv) {
                [vc.view insertSubview:bgv atIndex:0];
                [vc.view insertSubview:dim atIndex:1];
            }
        } @catch (NSException *e) { }
    } @catch (NSException *e) { }
}

static void BTApplyBackground(UIViewController *vc) {
    if (!vc || !vc.view) return;
    FDMConfig *C = [FDMConfig shared];
    if (![C enabledFor:P_BG]) return;
    if (![C boolFor:P_BG key:@"enabled"]) return;

    @try {
        NSString *mode = [C stringFor:P_BG key:@"mode"];
        NSString *colorStr = [C stringFor:P_BG key:@"color"];
        NSString *file = [C stringFor:P_BG key:@"file"];
        NSInteger alpha = [C intFor:P_BG key:@"alpha"];


        NSUInteger rgb = 0;
        if (colorStr.length) {
            NSString *h = [colorStr stringByReplacingOccurrencesOfString:@"#" withString:@""];
            unsigned int v = 0;
            if ([[NSScanner scannerWithString:h] scanHexInt:&v]) rgb = v;
        }
        CGFloat a = (alpha > 0 ? alpha : 100) / 100.0;

        /* ============================================================
         * ★★ v13 方案改动：不再「插入一个子层」
         *
         *   旧做法：insertSubview(bg, atIndex:0)
         *     问题：宿主聊天页的 view 层级很深（SwiftUI 的 HostingView +
         *     多个 ContainingView），我们插在 index 0 的层会被中间那些
         *     不透明的容器整个盖住 ⇒ 用户看到「没效果」。
         *
         *   新做法：**直接改 vc.view.layer.contents**（贴在自己身上）
         *     + 把中间容器都清成透明
         *     优点：不参与子视图堆叠，最底层就是它，躲不掉。
         * ============================================================ */

        CALayer *vl = vc.view.layer;

        /* ★ 诊断：把 frame 打出来，看是不是尺寸不对导致铺不满 */
        FLOGW(FC_UI, @"[bg] 目标 %@ frame=%@ bounds=%@",
              NSStringFromClass([vc class]),
              NSStringFromCGRect(vc.view.frame),
              NSStringFromCGRect(vc.view.bounds));

        if ([mode isEqualToString:@"image"] && file.length) {
            NSString *p = [BTDocs() stringByAppendingPathComponent:file];
            UIImage *img = [UIImage imageWithContentsOfFile:p];
            if (img) {
                /* ============================================================
                 * ★★ 2026-10-17 第四版：改用 UIImageView 子视图
                 *
                 * 为什么不用 layer.contents：
                 *   contents 是 **layer 自身的内容**，子视图永远画在它上面。
                 *   而宿主聊天页里有一个 `UIView α=1.00 15% L:1` 的纯黑块
                 *   （见视图树 dump），加上 SwiftUI 各层自己的 render buffer，
                 *   会把 contents 整个盖掉 ⇒ 看起来「背景没生效」。
                 *
                 * 用真实子视图的好处：
                 *   • 能精确控制层级（插在 index 0，最底）
                 *   • 能 [sendSubviewToBack:] 强行压到最底
                 *   • 布局变化时自动跟随（autoresizingMask）
                 * ============================================================ */
                static const void *kBgIVKey = &kBgIVKey;
                UIImageView *bgIV = objc_getAssociatedObject(vc, kBgIVKey);
                if (!bgIV || ![bgIV isKindOfClass:[UIImageView class]] ||
                    bgIV.superview != vc.view) {
                    [bgIV removeFromSuperview];
                    bgIV = [[UIImageView alloc] initWithFrame:vc.view.bounds];
                    bgIV.contentMode = UIViewContentModeScaleAspectFill;
                    bgIV.clipsToBounds = YES;
                    bgIV.userInteractionEnabled = NO;
                    bgIV.tag = BT_BGIV_TAG;      /* ★ 标记，避免误抓宿主自己的 UIImageView */
                    bgIV.autoresizingMask =
                        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                    if (!vc.view) return;
                    [vc.view insertSubview:bgIV atIndex:0];
                    objc_setAssociatedObject(vc, kBgIVKey, bgIV,
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                bgIV.frame = vc.view.bounds;
                bgIV.image = img;
                bgIV.alpha = a;
                [vc.view sendSubviewToBack:bgIV];      /* 强行压到最底 */

                /* layer.contents 不用了，清掉避免双重绘制 */
                vl.contents = nil;
                vl.backgroundColor = NULL;

                /* ============================================================
                 * ★★★ 2026-10-17 最终分叉：聊天页 / 非聊天页走两套逻辑
                 *
                 *   非聊天页（抽屉、设置、个人中心）只做一件事：**贴背景图**。
                 *   绝不执行任何「清底色 / 找祖先贴图」的遍历 ——
                 *   那正是把白字列表的容器底色清光、导致「列表项消失」的元凶。
                 *
                 *   聊天页才需要「气泡融进背景」那套清理。
                 * ============================================================ */
                vc.view.backgroundColor = [UIColor clearColor];

                if (BTVcIsChatPage(vc)) {
                    BTClearContainerBG(vc.view);
                    BTApplyScrollBG(vc.view, img, nil, 0);
                } else {
                    /* 非聊天页：滚动容器保持透明（不懂它的内部结构），
                     * 但不碰任何子视图的底色 */
                    /* ★ 2026-10-17 深夜：顺手摘掉**误贴进滚动容器**的背景图。
                     *   贴在 UIScrollView 里的图会跟着内容一起滚，
                     *   设置页看起来就像"壁纸在动"（视图树实锤：table 的子视图里有 ★FGIMG）。 */
                    @try {
                        NSMutableArray *stack = [NSMutableArray arrayWithObject:vc.view];
                        int guard = 0, removed = 0;
                        while (stack.count && guard++ < 4000) {
                            UIView *v = stack.lastObject;
                            [stack removeLastObject];
                            for (UIView *sv in [v.subviews copy]) {
                                if ([v isKindOfClass:[UIScrollView class]] &&
                                    (sv.tag == BT_BGIV_TAG || sv.tag == BT_ANCESTOR_IV_TAG)) {
                                    [sv removeFromSuperview];
                                    removed++;
                                    continue;
                                }
                                [stack addObject:sv];
                            }
                        }
                        if (removed)
                            FLOGW(FC_UI, @"[bg] %@ 摘掉 %d 张贴在滚动容器里的背景图",
                                  NSStringFromClass([vc class]), removed);
                    } @catch (NSException *e) { }
                    /* ★★★ 2026-10-17 深夜：「分界线」的正解
                     *
                     *   设置页的 vc.view 就是那张 UITableView，而且**完全透明**
                     *   ⇒ 下面的会话列表（置顶61个对话 / 多巴胺越狱…）直接透上来，
                     *     和上面实心深灰的导航栏拼出一条硬边。
                     *
                     *   ⇒ 给滚动容器铺一个**不透明**的统一底色（背景色不参与滚动，
                     *     也就不存在"跟着内容跑"的问题）。
                     */
                    if ([vc.view isKindOfClass:[UIScrollView class]]) {
                        /* ============================================================
                         * ★★★ 2026-10-17 深夜：**壁纸要留，但只留「那一块」**
                         *
                         *   直接把表格设成透明 ⇒ 露出来的是 Root 的**内容页**
                         *   （会话列表、聊天页），不是壁纸 —— 因为 Root 的
                         *   NavTransition 那层压在我们的 ★FGIMG/★DIM 之上。
                         *
                         *   正解：用 UITableView/UICollectionView 的 **backgroundView**
                         *     · 它不参与滚动（不会出现「会滚的壁纸」）
                         *     · 它在 cell 之下、在下层内容之上（挡住穿帮）
                         *     · frame 按「屏幕坐标换算」，和 Root 那张壁纸**像素级对齐**
                         *       （否则导航栏处和内容处的壁纸会错位，又成一条分界线）
                         * ============================================================ */
                        UIScrollView *sv0 = (UIScrollView *)vc.view;
                        UIView *bgv = [[UIView alloc] initWithFrame:sv0.bounds];
                        bgv.tag = BT_SOLIDBG_TAG;
                        bgv.backgroundColor = BTSolidPageColor();
                        bgv.clipsToBounds = YES;
                        bgv.userInteractionEnabled = NO;

                        /* 壁纸：frame 用「窗口 bounds 换算到表格坐标」⇒ 与 Root 对齐 */
                        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectZero];
                        iv.contentMode = UIViewContentModeScaleAspectFill;
                        iv.image = img;
                        iv.clipsToBounds = YES;
                        iv.userInteractionEnabled = NO;
                        if (sv0.window) {
                            iv.frame = [sv0 convertRect:sv0.window.bounds fromView:sv0.window];
                        } else {
                            iv.frame = CGRectMake(0, -sv0.contentInset.top,
                                                  sv0.bounds.size.width, sv0.bounds.size.height);
                        }

                        /* 压暗：与 Root 那层的 dim 取同一个 alpha ⇒ 导航栏 / 内容区同亮度 */
                        UIView *dimmer = [[UIView alloc] initWithFrame:bgv.bounds];
                        dimmer.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                                  UIViewAutoresizingFlexibleHeight;
                        {
                            FDMConfig *Cd = [FDMConfig shared];
                            NSInteger p2 = [Cd intFor:P_BG key:@"dim"];
                            if (p2 < 0) p2 = 0; if (p2 > 80) p2 = 80;
                            CGFloat da = p2 / 100.0;
                            if (da < 0.50) da = 0.50;      /* 与 BTApplyDimIfNeeded 的地板一致 */
                            dimmer.backgroundColor = [UIColor colorWithWhite:0.0 alpha:da];
                        }
                        [bgv addSubview:iv];
                        [bgv addSubview:dimmer];

                        if ([sv0 isKindOfClass:[UITableView class]])
                            ((UITableView *)sv0).backgroundView = bgv;
                        else if ([sv0 isKindOfClass:[UICollectionView class]])
                            ((UICollectionView *)sv0).backgroundView = bgv;

                        sv0.backgroundColor = [UIColor clearColor];
                        sv0.layer.backgroundColor = NULL;
                        FLOGW(FC_UI, @"[bg] %@ 非聊天页：backgroundView 铺壁纸（对齐 + 压暗 %.2f）",
                              NSStringFromClass([vc class]),
                              ((UIColor *)dimmer.backgroundColor).CGColor ?
                              CGColorGetAlpha(dimmer.backgroundColor.CGColor) : 0.0);
                    }
                    FLOGW(FC_UI, @"[bg] %@ 非聊天页：只贴图，不清理",
                          NSStringFromClass([vc class]));
                }

                /* ★★ 模态卡片漏光修复 v2：从本 VC 向上找自己的卡片
                 *   + 顺带把当前所有被 present 的页面保持住 */
                if ([[FDMConfig shared] boolFor:P_BG key:@"bg_fix_modal"])
                    BTStyleModalCard(vc, img, nil);

                /* ★ 气泡透明化（用户消息那个大黑框） */
                {
                    FDMConfig *Cb = [FDMConfig shared];
                    if ([Cb boolFor:P_BG key:@"bg_bubble_transparent"]) {
                        int b = BTStripBubbles(vc.view, 0);
                        if (b) FLOGW(FC_UI, @"[bg] 共透明化 %d 个气泡视图", b);
                    }
                }

                /* ★ 隐藏渐变/模糊遮罩（这是「上半部分黑」的真凶） */
                {
                    FDMConfig *Cg = [FDMConfig shared];
                    if ([Cg boolFor:P_BG key:@"bg_hide_gradient"]) {
                        int g = BTHideGradientMask(vc.view, 0);
                        if (g) FLOGW(FC_UI, @"[bg] 共隐藏 %d 个渐变/模糊遮罩", g);
                    }
                }

                /* ★ 只对聊天页执行（抽屉/设置页清了会「列表项消失」） */
                {
                    FDMConfig *Ce = [FDMConfig shared];
                    if ([Ce boolFor:P_BG key:@"bg_clear_all"]) {
                        BTStripIfChatPage(vc, "首次");
                        FLOGW(FC_UI, @"[bg] clear_all 处理 %@（聊天页=%d）",
                              NSStringFromClass([vc class]), (int)BTVcIsChatPage(vc));
                    }
                }

                [vc.view sendSubviewToBack:bgIV];      /* 清完再压一次（清过程可能改层级） */

                /* ★ 所有清理动作都做完了，最后再维护模态卡片
                 *   （顺序反了就会被 BTStripEverything 清掉 ⇒ 闪一下透明） */
                if ([[FDMConfig shared] boolFor:P_BG key:@"bg_fix_modal"])
                    BTMaintainModalCards();

                /* ★ 导航栏 / 顶部条：它们挂在 vc.navigationController 上，
                 *   不在 vc.view 的 subviews 里，所以要单独清 */
                @try {
                    UINavigationController *nc = vc.navigationController;
                    if (!nc) nc = (UINavigationController *)vc;
                    UINavigationBar *navBar = [nc isKindOfClass:[UINavigationController class]]
                                              ? nc.navigationBar : nil;
                    if (navBar) {
                        if (BTVcWantsClearNavBar(vc)) {
                            /* 聊天页 / 列表页：透明，让壁纸透上来 */
                            [navBar setBackgroundImage:[UIImage new]
                                         forBarMetrics:UIBarMetricsDefault];
                            [navBar setShadowImage:[UIImage new]];
                            navBar.translucent = YES;
                            navBar.backgroundColor = [UIColor clearColor];
                        } else {
                            /* ★ 其它页面（设置 / 关于 / 个性化…）：恢复系统材质。
                             *   不这么做的话，滚动的行会从标题底下透出来，
                             *   看起来像「设置」被「外观 系统」压住（主人实拍）。
                             *   iOS 15 起真正生效的是 appearance 对象，
                             *   所以两个都设一遍。 */
                            if (@available(iOS 13.0, *)) {
                                UINavigationBarAppearance *ap =
                                    [[UINavigationBarAppearance alloc] init];
                                [ap configureWithDefaultBackground];
                                /* ★ 导航栏保持透明，露出 Root 的壁纸。
                                 *   内容区用 backgroundView 放同一张图、同一压暗，
                                 *   两者像素对齐 ⇒ 没有色差，也没有错位。 */
                                ap.backgroundColor = [UIColor clearColor];
                                ap.shadowColor = [UIColor clearColor];
                                navBar.standardAppearance = ap;
                                navBar.scrollEdgeAppearance = ap;
                                navBar.compactAppearance = ap;
                            }
                            [navBar setBackgroundImage:nil forBarMetrics:UIBarMetricsDefault];
                            [navBar setShadowImage:nil];
                            navBar.translucent = YES;
                            navBar.backgroundColor = nil;
                        }
                    }
                } @catch (NSException *e) { }

                /* ★ 诊断：dump 视图树（只在不透明背景的节点打日志） */
                {
                    FDMConfig *Cd = [FDMConfig shared];
                    if ([Cd boolFor:P_BG key:@"bg_debug"]) {
                        FLOGW(FC_UI, @"[bgtree] ==== %@ 视图树 ====",
                              NSStringFromClass([vc class]));
                        BTDumpTree(vc.view, 0, vc.view.bounds.size);
                        FLOGW(FC_UI, @"[bgtree] ==== 结束 ====");
                    }
                }

                BTApplyDimIfNeeded(vc);
                FLOGW(FC_UI, @"[bg] 背景图已设 %@（%.0f×%.0f, alpha %.2f）",
                      file, img.size.width, img.size.height, a);
                return;
            }
            FLOGW(FC_UI, @"[bg] 背景图不存在: %@", p);
        }

        /* 纯色 / 清除 */
        vl.contents = nil;
        if ([mode isEqualToString:@"solid"] || rgb) {
            CGFloat r = ((rgb >> 16) & 0xFF) / 255.0;
            CGFloat g = ((rgb >> 8) & 0xFF) / 255.0;
            /* ★ 纯色模式下的模态卡片：同样补底色，避免卡片镂空 */
            if ([[FDMConfig shared] boolFor:P_BG key:@"bg_fix_modal"]) {
                UIColor *sc0 = [UIColor colorWithRed:r green:g
                                                blue:((rgb & 0xFF) / 255.0) alpha:a];
                BTStyleModalCard(vc, nil, sc0);
            }
            CGFloat b = (rgb & 0xFF) / 255.0;
            vc.view.backgroundColor = [UIColor colorWithRed:r green:g blue:b alpha:a];
            if (BTVcIsChatPage(vc)) BTClearContainerBG(vc.view);
            FLOGW(FC_UI, @"[bg] 纯色背景已设 #%06lX a=%.2f",
                  (unsigned long)(rgb & 0xFFFFFF), a);
        }
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[bg] 设置异常: %@", e.reason);
    }
}

static void bt_sessionViewDidLoad(id self, SEL _cmd) {
    IMP o = BTOriginalSafe(self, _cmd);
    if (o) ((void(*)(id,SEL))o)(self, _cmd);
    if (gReent) return;
    gReent++;
    @try { BTApplyBackground((UIViewController *)self); } @catch (NSException *e) {}
    gReent--;
}
static void bt_sessionLayout(id self, SEL _cmd) {
    IMP o = BTOriginalSafe(self, _cmd);
    if (o) ((void(*)(id,SEL))o)(self, _cmd);
    if (gReent) return;
    gReent++;
    @try {
        /* 布局变化时重贴一次（转屏 / 分屏）；BTApplyBackground 内部有幂等判断，
         * 同样配置不会重复设 */
        BTApplyBackground((UIViewController *)self);
    } @catch (NSException *e) {}
    gReent--;
}

/* ---- ★ 主动注入：hook 装得晚时，viewDidLoad 早就跑完了
 *      所以要主动遍历当前窗口的 VC 树，找到聊天页立刻贴背景 ---- */
/* ============================================================
 * ★★ 2026-10-17 重构：背景改成**四个独立开关**
 *
 * 旧实现的问题：
 *   `all_pages` 的判断写在了 `if (isChat || isList)` **里面**，
 *   而设置页既不叫 MessageViewController 也不叫 Session*ViewController
 *   ⇒ 根本进不了那个分支 ⇒ all_pages 对设置页完全无效。
 *
 * 新结构（每个开关独立，互不影响）：
 *   chat_enabled      聊天页 MessageViewController     默认开
 *   list_enabled      会话列表 Session*ViewController  默认开
 *   settings_enabled  设置类页面 *Setting* / *Profile*  默认关
 *   other_enabled     其它所有页面                      默认关
 * ============================================================ */
static BOOL BTIsChatPage(NSString *cn) {
    return (strstr(cn.UTF8String, "MessageViewController") != NULL);
}
static BOOL BTIsListPage(NSString *cn) {
    const char *c = cn.UTF8String;
    return (strstr(c, "SessionListViewController") != NULL ||
            strstr(c, "SessionViewController") != NULL);
}
/* ============================================================
 * ★★★ 2026-10-17 深夜：只有「聊天页 / 会话列表页」才该把导航栏透明
 *
 *   主人实拍：设置页标题「设置」上面压着「外观 系统」——
 *   那是滚动上来的行从**透明的**导航栏底下透出来了。
 *
 *   而设置页是 sheet 容器（vc.view 就是 UILayoutContainerView），
 *   容器本身透明 + 导航栏透明 ⇒ 整个页面变成「玻璃」，什么都透。
 * ============================================================ */
BOOL BTVcWantsClearNavBar(UIViewController *vc) {
    if (!vc) return NO;
    NSString *cn = NSStringFromClass([vc class]);
    if (!cn.length) return NO;
    return (BTIsChatPage(cn) || BTIsListPage(cn));
}

static BOOL BTIsSettingsPage(NSString *cn) {
    return (strstr(cn.UTF8String, "Setting") != NULL ||
            strstr(cn.UTF8String, "Profile") != NULL ||
            strstr(cn.UTF8String, "Personalization") != NULL ||
            strstr(cn.UTF8String, "About") != NULL);
}

/* ============================================================
 * ★★ 2026-10-17 修：other_enabled 把系统级窗口也贴了，App 变"单图浏览器"
 *
 * 日志实锤（开了 other_enabled 之后）：
 *     ✓ 已贴 DSLoadinToastWindowViewController     ← Toast 窗口
 *     ✓ 已贴 DSToastViewController                 ← Toast
 *     ✓ 已贴 UIInputWindowController               ← 键盘窗口！
 *     ✓ 已贴 UIEditingOverlayViewController        ← 编辑覆盖层
 *
 * 这些是 UIWindow 级别的覆盖层，贴了背景就会盖住整个 App。
 *
 * 判据：凡是「系统/框架层」的 VC 一律不贴
 *   • 类名以 UI / _UI 开头（UIKit 自己的）
 *   • 含 Window / Toast / Overlay / Input / Loading / Alert / Sheet / Menu
 *   • 已经是 UIWindow 的 rootViewController 且没有子业务 VC
 * ============================================================ */
static BOOL BTIsSystemOverlay(NSString *cn) {
    if (!cn.length) return YES;
    const char *c = cn.UTF8String;
    if (!c) return YES;

    if (strncmp(c, "UI", 2) == 0) return YES;          /* UIInputWindowController 等 */
    if (strncmp(c, "_UI", 3) == 0) return YES;
    if (strncmp(c, "_TtC5UIKit", 10) == 0) return YES;
    if (strncmp(c, "_TtGC5UIKit", 11) == 0) return YES;

    static const char *kw[] = {
        "Window", "Toast", "Overlay", "Alert", "Sheet", "Menu",
        "Loading", "HUD", "Popup", "Tooltip", "Keyboard", "Input",
    };
    for (size_t i = 0; i < sizeof(kw)/sizeof(kw[0]); i++)
        if (strstr(c, kw[i])) return YES;

    return NO;
}

static void BTWalkVC(UIViewController *vc, int depth, int *applied) {
    if (!vc || depth > 8) return;
    @try {
        const char *rawName = class_getName([vc class]);
        if (rawName) {
            NSString *cn = [NSString stringWithUTF8String:rawName] ?: @"";
            FDMConfig *C = [FDMConfig shared];

            /* 容器类不贴（它们没有可见内容，贴了反而怪） */
            BOOL isContainer = ([vc isKindOfClass:[UINavigationController class]] ||
                                [vc isKindOfClass:[UITabBarController class]] ||
                                [vc isKindOfClass:[UISplitViewController class]]);
            /* FDM 自家页面绝不贴 */
            BOOL isOwn = (strncmp(rawName, "FDM", 3) == 0);

            BOOL want = NO;
            if (!isContainer && !isOwn) {
                if (BTIsChatPage(cn)) {
                    want = [C boolFor:P_BG key:@"chat_enabled"];
                } else if (BTIsListPage(cn)) {
                    want = [C boolFor:P_BG key:@"list_enabled"];
                } else if (BTIsSettingsPage(cn)) {
                    want = [C boolFor:P_BG key:@"settings_enabled"];
                } else {
                    /* ★ other_enabled：排除系统级覆盖层，否则 App 会变成"单图浏览器" */
                    want = [C boolFor:P_BG key:@"other_enabled"] && !BTIsSystemOverlay(cn);
                }
            }

            if (want) {
                if (!gBgAppliedVCs) {
                    gBgAppliedVCs = [NSHashTable weakObjectsHashTable];
                }
                [gBgAppliedVCs addObject:vc];
                static const void *kAppliedKey = &kAppliedKey;
                /* ★ 签名必须包含**所有会影响渲染的配置**，否则改了开关不会重贴
                 *   （旧版漏了 bg_hide_gradient / bg_clear_all，改完必须重启） */
                /* ★ 2026-10-17 深夜：把「各页面开关」和 alpha 也纳入签名。
                 *   旧版漏了 alpha / settings_enabled / other_enabled ⇒
                 *   改这些开关**不会重贴**，必须重启 App 才见效（主人踩过）。 */
                NSString *sig = [NSString stringWithFormat:
                                 @"%@|%@|%@|%ld|%ld|%d|%d|%d|%d|%d|%ld",
                                 [C stringFor:P_BG key:@"mode"],
                                 [C stringFor:P_BG key:@"file"],
                                 [C stringFor:P_BG key:@"color"],
                                 (long)[C intFor:P_BG key:@"alpha"],
                                 (long)[C intFor:P_BG key:@"dim"],
                                 (int)[C boolFor:P_BG key:@"bg_hide_gradient"],
                                 (int)[C boolFor:P_BG key:@"bg_clear_all"],
                                 (int)[C boolFor:P_BG key:@"chat_enabled"],
                                 (int)[C boolFor:P_BG key:@"list_enabled"],
                                 (int)[C boolFor:P_BG key:@"settings_enabled"],
                                 (long)[C intFor:P_BG key:@"dim"]];
                NSString *done = objc_getAssociatedObject(vc, kAppliedKey);
                if (![sig isEqualToString:done]) {
                    BTApplyBackground(vc);
                    objc_setAssociatedObject(vc, kAppliedKey, sig,
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    FLOGW(FC_UI, @"[bg] ✓ 已贴 %@", cn);
                } else {
                    /* ============================================================
                     * ★★ 2026-10-17：已贴过的页面**每轮巡检仍要做增量清理**
                     *
                     * 为什么必须这样做（主人实测「有的对话半透明有的不能」）：
                     *   消息 cell 是懒加载的，滚动时才创建。
                     *   只在「贴背景」那一次清理，只能覆盖当时可见的 6 个 cell；
                     *   之后新滚出来的 cell 从没被处理 ⇒ 那些消息还是不透明。
                     *
                     * 增量清理靠 tag 去重，开销很小（只遍历可见 cell）。
                     * ============================================================ */
                    if ([C boolFor:P_BG key:@"bg_bubble_transparent"]) {
                        int b = BTStripBubbles(vc.view, 0);
                        if (b > 0) FLOGW(FC_UI, @"[bg] 增量透明化 %d 个新 cell", b);
                    }
                    if ([C boolFor:P_BG key:@"bg_clear_all"]) {
                        BTStripIfChatPage(vc, "巡检");
                    }
                    if ([C boolFor:P_BG key:@"bg_hide_gradient"]) {
                        BTHideGradientMask(vc.view, 0);
                    }
                    /* ★ 每轮都维护模态卡片 + 面板遮罩（防宿主 layout 冲掉） */
                    BTMaintainModalCards();
                    /* 保证背景图还在最底（宿主有时会重排层级） */
                    UIView *bgv = [vc.view viewWithTag:0x0D1A0002];
                    if (bgv && vc.view.subviews.firstObject != bgv) {
                        [vc.view sendSubviewToBack:bgv];
                    }
                }
                (*applied)++;
            }
        }
        for (UIViewController *ch in vc.childViewControllers) BTWalkVC(ch, depth + 1, applied);
        if (vc.presentedViewController) BTWalkVC(vc.presentedViewController, depth + 1, applied);
        if ([vc isKindOfClass:[UINavigationController class]])
            BTWalkVC(((UINavigationController *)vc).topViewController, depth + 1, applied);
        if ([vc isKindOfClass:[UITabBarController class]])
            BTWalkVC(((UITabBarController *)vc).selectedViewController, depth + 1, applied);
    } @catch (NSException *e) { }
}

/* ============================================================
 * ★★ 2026-10-17：配置改了要**立即生效**（不用重启）
 *
 * 做法：把所有贴过背景的 VC 的「已贴签名」清掉，
 *       下一轮巡检（1.5s 内）发现签名不匹配 ⇒ 自动重贴。
 *
 * 另外还要处理「已经贴过但现在被关掉」的 VC —— 需要把背景图移除。
 * ============================================================ */
static void BTResetAllApplied(void) {
    @try {
        if (!gBgAppliedVCs) return;
        for (UIViewController *vc in gBgAppliedVCs.allObjects) {
            static const void *kAppliedKey = &kAppliedKey;
            objc_setAssociatedObject(vc, kAppliedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        FLOGW(FC_UI, @"[bg] 已重置 %lu 个页面的签名，下一轮巡检会重贴",
              (unsigned long)gBgAppliedVCs.count);
    } @catch (NSException *e) { }
}

void FDMBeautyForceRefresh(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ FDMBeautyForceRefresh(); });
        return;
    }
    BTResetAllApplied();
    FDMBeautyRefreshBackground();
}

void FDMBeautyRefreshBackground(void) {
    /* ★ 必须在主线程：改 view 层级 / 布局引擎只能在主线程，
     *   否则报 "Modifications to the layout engine must not be performed
     *   from a background thread"（第一版就是这么炸的） */
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ FDMBeautyRefreshBackground(); });
        return;
    }
    @try {
        int applied = 0;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                BTWalkVC(w.rootViewController, 0, &applied);
            }
        }
        if (applied) FLOGI(FC_UI, @"[bg] 主动注入：找到 %d 个聊天页并应用背景", applied);
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[bg] 主动注入异常: %@", e.reason);
    }
}

/* ==================== ② 富文本样式 ==================== */

static void BTApplyMarkdownStyle(id cfg) {
    if (!cfg) return;
    FDMConfig *C = [FDMConfig shared];
    if (![C enabledFor:P_RICH]) return;
    if (![C boolFor:P_RICH key:@"enabled"]) return;

    @try {
        NSInteger sizeAdj = [C intFor:P_RICH key:@"font_size_delta"];
        NSInteger lineAdj = [C intFor:P_RICH key:@"line_height_delta"];

        if (sizeAdj != 0) {
            id v = [cfg valueForKey:@"baseBodyFontSize"];
            if (v) {
                double nv = [v doubleValue] + sizeAdj;
                if (nv < 8) nv = 8;
                if (nv > 40) nv = 40;
                [cfg setValue:@(nv) forKey:@"baseBodyFontSize"];
                FLOGI(FC_UI, @"Markdown 字号 %@ → %.1f", v, nv);
            }
        }
        if (lineAdj != 0) {
            id v = [cfg valueForKey:@"baseBodyLineHeight"];
            if (v) {
                double nv = [v doubleValue] + lineAdj;
                if (nv < 10) nv = 10;
                if (nv > 60) nv = 60;
                [cfg setValue:@(nv) forKey:@"baseBodyLineHeight"];
                FLOGI(FC_UI, @"Markdown 行高 %@ → %.1f", v, nv);
            }
        }

        NSString *colorStr = [C stringFor:P_RICH key:@"body_color"];
        if (colorStr.length) {
            NSString *h = [colorStr stringByReplacingOccurrencesOfString:@"#" withString:@""];
            unsigned int rgb = 0;
            if ([[NSScanner scannerWithString:h] scanHexInt:&rgb]) {
                CGFloat r = ((rgb >> 16) & 0xFF) / 255.0;
                CGFloat g = ((rgb >> 8) & 0xFF) / 255.0;
                CGFloat b = (rgb & 0xFF) / 255.0;
                [cfg setValue:[UIColor colorWithRed:r green:g blue:b alpha:1]
                       forKey:@"bodyColor"];
                FLOGI(FC_UI, @"Markdown 正文色 → #%06X", rgb & 0xFFFFFF);
            }
        }
    } @catch (NSException *e) {
        FLOGW(FC_UI, @"Markdown 样式异常（字段名可能变了）: %@", e.reason);
    }
}

static void bt_genericHook(id self, SEL _cmd) {
    IMP o = BTOriginalSafe(self, _cmd);
    if (o) ((void(*)(id,SEL))o)(self, _cmd);
    if (gReent) return;
    gReent++;
    @try { BTApplyMarkdownStyle(self); } @catch (NSException *e) {}
    gReent--;
}

/* ============================================================
 * ③ 字号
 *
 * 两条路，互补：
 *   A. 宿主字号档位（MMKV 直写，零 hook，最稳）
 *        app.fontSize.followSystem       = false
 *        app.fontSize.userPreferredLevel = "0".."4"   (small→xxLarge)
 *      ⇒ 宿主自己的「设置 › 字体大小」那套，改完重启生效
 *
 *   B. 细粒度微调（hook UIFont 工厂方法，±N 点）
 *      只对「正文字号区间」的字体生效（12~26pt），
 *      不动 8pt 的角标、不动 40pt 的大标题 ⇒ 布局不会崩
 * ============================================================ */

/* ---- A. 写 MMKV 档位 ---- */
BOOL FDMApplyFontLevel(void) {
    @try {
        FDMConfig *C = [FDMConfig shared];
        if (![C enabledFor:P_RICH] || ![C boolFor:P_RICH key:@"enabled"]) return NO;
        NSInteger lv = [C intFor:P_RICH key:@"font_level"];   /* -1 = 不改 */
        if (lv < 0 || lv > 4) return NO;

        Class MC = NSClassFromString(@"MMKV");
        if (!MC) { FLOGW(FC_UI, @"[font] 找不到 MMKV 类"); return NO; }

        id mmkv = nil;
        SEL dflt = sel_registerName("defaultMMKV");
        if ([MC respondsToSelector:dflt]) {
            mmkv = ((id(*)(id,SEL))objc_msgSend)(MC, dflt);
        }
        if (!mmkv) { FLOGW(FC_UI, @"[font] 拿不到 MMKV 默认实例"); return NO; }

        /* 关掉「跟随系统」，否则我们的档位会被忽略 */
        SEL setB = sel_registerName("setBool:forKey:");
        if ([mmkv respondsToSelector:setB])
            ((void(*)(id,SEL,BOOL,id))objc_msgSend)(mmkv, setB, NO, @"app.fontSize.followSystem");

        NSString *cur = nil;
        SEL getS = sel_registerName("getStringForKey:");
        if ([mmkv respondsToSelector:getS])
            cur = ((id(*)(id,SEL,id))objc_msgSend)(mmkv, getS, @"app.fontSize.userPreferredLevel");

        NSString *want = [NSString stringWithFormat:@"%ld", (long)lv];
        if ([cur isEqualToString:want]) {
            FLOGI(FC_UI, @"[font] 档位已经是 %@，无需改", want);
            return YES;
        }
        SEL setS = sel_registerName("setString:forKey:");
        if ([mmkv respondsToSelector:setS])
            ((void(*)(id,SEL,id,id))objc_msgSend)(mmkv, setS, want, @"app.fontSize.userPreferredLevel");

        FLOGI(FC_UI, @"[font] ★ 宿主字号档位 %@ → %@（重启 App 生效）", cur ?: @"?", want);
        return YES;
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[font] 写档位异常: %@", e.reason);
        return NO;
    }
}

/* ---- B. UIFont 微调 ---- */
static CGFloat gFontDelta = 0;
static BOOL    gFontHookOn = NO;

/* 只对正文字号区间生效，避免动角标/大标题导致布局崩 */
static inline BOOL SizeInBodyRange(CGFloat s) { return (s >= 12.0 && s <= 26.0); }

static id bt_systemFontOfSize(id self, SEL _cmd, CGFloat size) {
    IMP o = BTOriginalSafe(self, _cmd);
    if (!o) return nil;
    CGFloat s = (gFontHookOn && gFontDelta != 0 && SizeInBodyRange(size)) ? size + gFontDelta : size;
    return ((id(*)(id,SEL,CGFloat))o)(self, _cmd, s);
}
static id bt_boldSystemFontOfSize(id self, SEL _cmd, CGFloat size) {
    IMP o = BTOriginalSafe(self, _cmd);
    if (!o) return nil;
    CGFloat s = (gFontHookOn && gFontDelta != 0 && SizeInBodyRange(size)) ? size + gFontDelta : size;
    return ((id(*)(id,SEL,CGFloat))o)(self, _cmd, s);
}
static id bt_fontWithSize(id self, SEL _cmd, CGFloat size) {
    IMP o = BTOriginalSafe(self, _cmd);
    if (!o) return nil;
    CGFloat s = (gFontHookOn && gFontDelta != 0 && SizeInBodyRange(size)) ? size + gFontDelta : size;
    return ((id(*)(id,SEL,CGFloat))o)(self, _cmd, s);
}
static id bt_fontWithDescriptor(id self, SEL _cmd, UIFontDescriptor *d, CGFloat size) {
    IMP o = BTOriginalSafe(self, _cmd);
    if (!o) return nil;
    CGFloat s = (gFontHookOn && gFontDelta != 0 && SizeInBodyRange(size)) ? size + gFontDelta : size;
    return ((id(*)(id,SEL,id,CGFloat))o)(self, _cmd, d, s);
}

/* 类方法也需要自己的「原 IMP 表」（BTFind 用 object_getClass(self) 查，能对上） */
static void BTInstallFontHooks(void) {
    @try {
        Class UF  = [UIFont class];
        Class meta = object_getClass(UF);

        /* ⚠️ 注意：systemFontOfSize: / boldSystemFontOfSize: / fontWithDescriptor:size:
         *   是**类方法**（挂在 metaclass）；而 fontWithSize: 是**实例方法**。
         *   第一版把 fontWithSize: 也当类方法找 ⇒ 永远找不到，静默少挂一个。 */
        struct { SEL s; IMP imp; BOOL isClass; } tbl[] = {
            { sel_registerName("systemFontOfSize:"),        (IMP)bt_systemFontOfSize,     YES },
            { sel_registerName("boldSystemFontOfSize:"),    (IMP)bt_boldSystemFontOfSize, YES },
            { sel_registerName("fontWithDescriptor:size:"), (IMP)bt_fontWithDescriptor,   YES },
            { sel_registerName("fontWithSize:"),            (IMP)bt_fontWithSize,         NO  },
        };
        int n = 0;
        for (size_t i = 0; i < sizeof(tbl)/sizeof(tbl[0]); i++) {
            Method m = tbl[i].isClass ? class_getClassMethod(UF, tbl[i].s)
                                      : class_getInstanceMethod(UF, tbl[i].s);
            if (!m) { FLOGD(FC_UI, @"[font] 没找到 %s", sel_getName(tbl[i].s)); continue; }
            IMP old = method_getImplementation(m);
            if (old == tbl[i].imp) continue;
            if (gBTN < BT_MAX) {
                gBT[gBTN].cls  = tbl[i].isClass ? meta : UF;
                gBT[gBTN].sel  = tbl[i].s;
                gBT[gBTN].orig = old;
                gBTN++;
            }
            method_setImplementation(m, tbl[i].imp);
            n++;
        }
        FLOGI(FC_UI, @"[font] UIFont hook：%d 处（delta=%.1fpt，仅 12~26pt 生效）", n, gFontDelta);
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[font] UIFont hook 异常: %@", e.reason);
    }
}

/* ==================== 安装 ==================== */

static BOOL gBeautyDone = NO;

void FDMBeautyInstall(void) {
    /* ★★ 必须在主线程：
     *   • method_setImplementation 是线程不安全的
     *   • FDMApplyFontLevel 里操作 MMKV
     *   • BTApplyBackground 改 view 层级
     *   第一版从后台 timer 直接调 ⇒ 偶发死锁/崩，而且死得太早不留崩溃日志。 */
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ FDMBeautyInstall(); });
        return;
    }
    @autoreleasepool {
        if (gBeautyDone) return;
        FLOGI(FC_UI, @"=== FDMBeautyInstall 开始 ===");
        int n = 0;
        FDMConfig *C = [FDMConfig shared];

        /* ---- ① 聊天背景 ---- */
        if ([C enabledFor:P_BG] && [C boolFor:P_BG key:@"enabled"]) {
            /* ★★ 2026-10-17 修正：以前 hook 的是 SessionViewController，
             *   但那是**会话列表页**（左侧抽屉那种），不是聊天页。
             *   真正的聊天页是 MessageViewController。
             *   现在两者都支持，由配置 target 决定：
             *      chat = 只聊天页（默认）
             *      list = 只会话列表
             *      both = 两个都贴 */
            NSString *target = [C stringFor:P_BG key:@"target"];
            if (!target.length) target = @"chat";
            BOOL wantChat = [target isEqualToString:@"chat"] || [target isEqualToString:@"both"];
            BOOL wantList = [target isEqualToString:@"list"] || [target isEqualToString:@"both"];

            const char *chatNames[] = {
                "_TtC13DeepSeek_Chat21MessageViewController",
                "_TtC13DeepSeek_Chat21MessageViewController_hmd_subfix_",
                NULL
            };
            const char *listNames[] = {
                /* ★ 21 字符的 SessionViewController 是「抽屉/侧栏容器」，
                 *   25 字符的 SessionListViewController 才是真正的会话列表。
                 *   两个都挂，才不会「只有一半页面有背景」。 */
                "_TtC13DeepSeek_Chat21SessionViewController",
                "_TtC13DeepSeek_Chat25SessionListViewController",
                "_TtC13DeepSeek_Chat21SessionViewController_hmd_subfix_",
                NULL
            };

            /* ★★ 2026-10-17 决定：**默认不 hook 生命周期**
             *   原因：Swift 的 UIViewController 继承链 + class_addMethod 组合
             *   极易踩到「原 IMP 指向自己」的无限递归，且崩在宿主内部很难查。
             *   改用「定时巡检」：每 1.5s 扫一次窗口 VC 树，发现聊天页就贴上。
             *   代价是最多 1.5s 延迟，换来零崩溃风险。
             *   想要 hook 模式可在 fdm-bg.json 里设 "hook_mode": true */
            BOOL useHook = ([C stringFor:P_BG key:@"hook_mode"] != nil) &&
                           [C boolFor:P_BG key:@"hook_mode"];
            if (!useHook) {
                FLOGW(FC_UI, @"[bg] 使用巡检模式（不 hook 生命周期，零风险）");
                wantChat = NO; wantList = NO;
            }

            if (wantChat && useHook) {
                for (int i = 0; chatNames[i]; i++) {
                    Class c = objc_getClass(chatNames[i]);
                    if (!c) { FLOGW(FC_UI, @"  [bg] ✗ 找不到类 %s（类名长度可能写错了）", chatNames[i]); continue; }
                    if (BTSwap(c, "viewDidLoad", (IMP)bt_sessionViewDidLoad)) n++;
                    if (BTSwap(c, "viewDidLayoutSubviews", (IMP)bt_sessionLayout)) n++;
                    FLOGW(FC_UI, @"  [bg] 聊天页 hook → %s", chatNames[i]);
                }
            }
            if (wantList && useHook) {
                for (int i = 0; listNames[i]; i++) {
                    Class c = objc_getClass(listNames[i]);
                    if (!c) { FLOGW(FC_UI, @"  [bg] ✗ 找不到类 %s（类名长度可能写错了）", listNames[i]); continue; }
                    if (BTSwap(c, "viewDidLoad", (IMP)bt_sessionViewDidLoad)) n++;
                    if (BTSwap(c, "viewDidLayoutSubviews", (IMP)bt_sessionLayout)) n++;
                    FLOGW(FC_UI, @"  [bg] 列表页 hook → %s", listNames[i]);
                }
            }
        }

        /* ---- ①b 字号（MMKV 档位 + UIFont 微调） ---- */
        if ([C enabledFor:P_RICH] && [C boolFor:P_RICH key:@"enabled"]) {
            /* A. 宿主档位（MMKV 直写） */
            FDMApplyFontLevel();

            /* B. 细粒度微调 */
            NSInteger delta = [C intFor:P_RICH key:@"font_size_delta"];
            if (delta != 0) {
                if (delta > 10) delta = 10;
                if (delta < -10) delta = -10;
                gFontDelta = (CGFloat)delta;
                gFontHookOn = YES;
                BTInstallFontHooks();
            }
        }

        /* ---- ② 富文本样式（Swift 类，历史遗留，保留不影响） ---- */
        if ([C enabledFor:P_RICH] &&
            ([C boolFor:P_RICH key:@"enabled"] || [C intFor:P_RICH key:@"font_size_delta"] != 0 ||
             [C intFor:P_RICH key:@"line_height_delta"] != 0)) {
            int total = objc_getClassList(NULL, 0);
            __unsafe_unretained Class *list =
                (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)(total > 0 ? total : 1));
            if (list) {
                total = objc_getClassList(list, total);
                for (int i = 0; i < total; i++) {
                    const char *cn = class_getName(list[i]);
                    if (!cn) continue;
                    if (!strstr(cn, "MarkdownConfig")) continue;
                    if (BTSwap(list[i], "init", (IMP)bt_genericHook)) {
                        n++;
                        FLOGI(FC_UI, @"  富文本样式 hook → %s", cn);
                    }
                }
                free(list);
            }
        }

        gBeautyDone = YES;
        /* ★ 装 cell layoutSubviews hook（懒渲染修复：cell 复用会重设底色） */
        if ([C enabledFor:P_BG] && [C boolFor:P_BG key:@"bg_clear_all"]) {
            int ch = BTInstallCellHooks();
            FLOGW(FC_UI, @"[bg] cell 复用 hook：%d 个类", ch);
            n += ch;

            int sh = BTInstallScrollHooks();
            n += sh;
        }

        FLOGI(FC_UI, @"=== FDMBeautyInstall 结束（%d 处）===", n);

        /* ============================================================
         * ★★ 背景：巡检模式（2026-10-17 改）
         *
         * 为什么不再 hook 生命周期：
         *   Swift 的 MessageViewController / SessionListViewController 之间有继承，
         *   一旦给子类 class_addMethod，class_getInstanceMethod 会拿到父类那个
         *   （已被我们替换成 bt_sessionViewDidLoad）⇒ 「原实现」指向自己
         *   ⇒ 无限递归爆栈 ⇒ 点进对话瞬间崩，而且崩在宿主内部极难定位。
         *
         * 巡检方案：
         *   每 1.5s 扫一次所有窗口的 VC 树，发现目标页就贴背景（带 VC 级去重）。
         *   跑 60 秒后自动停。代价 = 最多 1.5s 延迟，换来零崩溃风险。
         * ============================================================ */
        if ([C enabledFor:P_BG] && [C boolFor:P_BG key:@"enabled"]) {
            FDMBeautyRefreshBackground();      /* 先立刻贴一次 */

            /* ============================================================
             * ★★ 2026-10-17：巡检改成**持续运行**（分两档频率）
             *
             * 为什么不能只跑 60 秒：
             *   消息 cell 是懒加载的，用户可能几分钟后才滚到新消息。
             *   巡检一停，新 cell 就永远不透明了 ⇒ 「有的对话能半透明，有的不能」。
             *
             * 两档：
             *   前 60 秒（tick<40）：1.5 秒一轮 —— 进页面时快速铺好
             *   之后：3 秒一轮 —— 低频兜底，几乎不耗电
             *   上限 1200 轮（约 1 小时），之后停（避免长期驻留耗电）
             * ============================================================ */
            __block int tick = 0;
            static dispatch_source_t t = nil;
            if (t) dispatch_source_cancel(t);
            t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                       dispatch_get_main_queue());
            /* ★ 常驻 present 探测器：0.2s，只在顶层 VC 变化时干活 */
            {
                static dispatch_source_t wp = nil;
                if (wp) dispatch_source_cancel(wp);
                wp = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            dispatch_get_main_queue());
                dispatch_source_set_timer(wp,
                    dispatch_time(DISPATCH_TIME_NOW, 200ull * NSEC_PER_MSEC),
                    200ull * NSEC_PER_MSEC, 80ull * NSEC_PER_MSEC);
                dispatch_source_set_event_handler(wp, ^{ BTWatchPresented(); });
                dispatch_resume(wp);
                FLOGW(FC_UI, @"[watch] present 探测器已启动（0.2s）");
            }

            /* ★ 前段用 0.3s 快速铺（避免「先透明再上背景」的观感），
             *   跑满 20 轮后由事件处理器切到 1.5s */
            dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0),
                                      300ull * NSEC_PER_MSEC, 100ull * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(t, ^{
                @autoreleasepool {
                    tick++;
                    FDMBeautyRefreshBackground();

                    /* 跑满 20 轮（约 6 秒）后切到 1.5s 档 */
                    if (tick == 20) {
                        dispatch_source_set_timer(t,
                            dispatch_time(DISPATCH_TIME_NOW, 0),
                            1500ull * NSEC_PER_MSEC, 300ull * NSEC_PER_MSEC);
                    }
                    /* 跑满 40 轮后切到低频档 */
                    if (tick == 40) {
                        dispatch_source_set_timer(t,
                            dispatch_time(DISPATCH_TIME_NOW, 0),
                            3000ull * NSEC_PER_MSEC, 500ull * NSEC_PER_MSEC);
                        FLOGW(FC_UI, @"[bg] 巡检切到低频档（3s/轮）");
                    }
                    if (tick >= 1200) {
                        FLOGW(FC_UI, @"[bg] 巡检结束（%d 次）", tick);
                        dispatch_source_cancel(t);
                        t = nil;
                    }
                }
            });
            dispatch_resume(t);
        }
    }
}

/* 供主探针调用（延迟重试）：0=还没准备好，1=已处理 */
int FDMBeautyInstallRetry(int attempt) {
    if (gBeautyDone) return 1;
    FDMConfig *C = [FDMConfig shared];
    BOOL needBG    = [C enabledFor:P_BG] && [C boolFor:P_BG key:@"enabled"];
    BOOL needRich  = [C enabledFor:P_RICH] &&
                     ([C boolFor:P_RICH key:@"enabled"] ||
                      [C intFor:P_RICH key:@"font_size_delta"] != 0);
    if (!needBG && !needRich) { gBeautyDone = YES; return 1; }   /* 不需要，标记完成 */

    if (needBG &&
        !objc_getClass("_TtC13DeepSeek_Chat21MessageViewController") &&
        !objc_getClass("_TtC13DeepSeek_Chat21SessionViewController")) return 0;
    FDMBeautyInstall();
    return 1;
}
