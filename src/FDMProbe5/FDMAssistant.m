// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMAssistant.m —— 修改助手图片（AI 回复旁的头像）
//
// ═══════════════════════════════════════════════════════════════════════════
//  宿主结构勘察（2026-10-23 静态）
//
//  宿主里**没有**独立的「AI 头像视图」类（DeepSeek 默认不给 AI 画头像）。
//  能找到的相关类：
//    · ResponseFragmentView        AI 回复的正文容器
//    · AgentMessageCell / MessageCell
//    · UserBubbleView / UserRequestBubbleView  （用户侧，有 avartar 的是侧栏）
//    · SessionListViewController10FooterView.avatar  （侧栏头像，已被 avatar 组占用）
//
//  ⇒ 所以这一项走「**给 AI 气泡加一个头像**」而不是「换宿主的头像图」：
//     在 AI 回复容器的左侧（或右侧，看对齐）插入一个我们自己的 UIImageView，
//     位置由「容器 bounds + 安全边距 + 尺寸」算出来，不碰宿主内部布局。
//
//  ★ 为什么这样做而不是等真机 dump：
//    即使宿主将来真的加了头像视图，我们的做法也仍然有效（多一个头像而已）；
//    而如果只在「找到宿主头像」时生效，那宿主一天没有，这功能就一天是空的。
//    「自己加」是唯一不依赖宿主实现的选择。
//
//  ★ 风险控制
//    · 只在 AI 消息容器上插，绝不碰用户气泡（否则会互相遮挡）
//    · 用 layoutSubviews 末尾定位，不动宿主的 autolayout
//    · 尺寸/偏移都可以在设置里调，真机不对就调数值，不用改代码
// ═══════════════════════════════════════════════════════════════════════════
#import "FDMAssistant.h"
#import "FLog.h"
#import "FDMConfig.h"
#import "FDMNote.h"        /* FDMRGBAColor */

#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

/* ══════════════════════════════════ 配置 ══════════════════════════════════ */

static BOOL gOn = NO;
static BOOL gLoaded = NO;
static UIImage *gImage = nil;
/* ★★★ 2026-10-24 配置精简：尺寸/边距/位置**全部改成实测常量**，不进设置页
 *
 *  依据（docs/37 §2.1 真机 dump）：
 *    AI 正文左边到 AgentMessageView 左边 = 16 + 8 = **24px**（AgentFragmentsView.x = 24）
 *    正文容器顶部 y = 12
 *  ⇒ 头像 22px、x=1、y=12 ⇒ 正好落在缝里，右边缘 23 < 24，一个像素都不压字。
 *
 *  这些数字是被实测钉死的，让用户填只会填错。设置里只留「开关 / 选图 / 圆形」。
 *  （万一将来宿主改版、24px 变了，改这三个常量即可，日志里有「空隙可用 N」可核对。） */
#define kAvatarSize   22.0
#define kAvatarInsetX  1.0
#define kAvatarInsetY 12.0

static BOOL gRound = YES;

static NSString *const kAvatarTag = @"fdm.assistant.avatar";

/* 前向声明：探测函数定义在后面（LayoutAvatar 会调用）*/
static void AssistantProbeHostAvatar(UIView *root);

/* ══════════════════════════════════ 读配置 ══════════════════════════════════ */

static void AssistantLoadImage(NSString *file) {
    gImage = nil;
    if (!file.length) return;
    @try {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                             NSUserDomainMask, YES).firstObject;
        if (!docs.length) return;
        NSString *p = [docs stringByAppendingPathComponent:file];
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (!d.length) {
            FLOGW(FC_UI, @"[assistant] 图片读不出来: %@", p);
            return;
        }
        gImage = [UIImage imageWithData:d];
        if (gImage) {
            FLOGW(FC_UI, @"[assistant] 已加载 %.0fx%.0f",
                  gImage.size.width, gImage.size.height);
        }
    } @catch (NSException *e) { }
}

static void AssistantReload(void) {
    @try {
        FDMConfig *c = [FDMConfig shared];
        gOn = [c boolFor:@"assistant" key:@"on"] && [c enabledFor:@"assistant"];

        NSString *f = [c stringFor:@"assistant" key:@"file"];
        AssistantLoadImage(f);

        gRound = [c boolFor:@"assistant" key:@"round"];

        gLoaded = YES;
        FLOGI(FC_UI, @"[assistant] 配置 on=%d 图=%@ 尺寸=%.0f（固定）位置=(%.0f,%.0f)（实测） %@",
              gOn, gImage ? @"有" : @"无", kAvatarSize, kAvatarInsetX, kAvatarInsetY,
              gRound ? @"圆" : @"方");
    } @catch (NSException *e) {
        gOn = NO;
        FLOGE(FC_UI, @"[assistant] 读配置异常: %@", e.reason);
    }
}

/* ══════════════════════════════════ 判断是不是 AI 容器 ══════════════════════════════════ */

/**
 * ★★★ 2026-10-24（docs/37 的气泡 dump 之后）改精确类名
 *
 *  原来是 `containsString` 一把抓，命中 ResponseFragmentView / AgentMessageCell /
 *  AgentMessageView 三个类 ⇒ **同一条 AI 消息被插了 3 个头像**（重叠在一起）。
 *  而且插在 ResponseFragmentView 里 —— 那是 366 宽的文字容器，
 *  头像 28px 直接压在字上。
 *
 *  真机 dump 给出的结构（docs/37 §2.1）：
 *
 *    AgentMessageView  414x439   ← ★ 唯一锚点，全宽，clip=0
 *      └─ UIView        (16,12) 374x415
 *         └─ UIView     (8,0)  366x415
 *            └─ AgentFragmentsView 366x415   ← 文字全在这（气泡本体）
 *
 *  ⇒ 从 AgentMessageView 左边到文字左边 = 16 + 8 = **24px 空隙**。
 *    头像只要 ≤ 24px 就不会压字；想更大就往右移（可调）。
 *    而且一路 clip=0 ⇒ 头像超出 bounds 也不会被裁。
 */
static BOOL IsAIContainer(NSString *cn) {
    if (!cn.length) return NO;
    static NSSet *ok = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ok = [NSSet setWithArray:@[
            @"DeepSeek_Chat.AgentMessageView",
            @"_TtC13DeepSeek_Chat16AgentMessageView",
        ]];
    });
    return [ok containsObject:cn];
}

/** 文字左边到容器左边的空隙（用于「不压字」的默认尺寸上限）。 */
#define kAIContentInset  24.0

/* ══════════════════════════════════ 头像视图 ══════════════════════════════════ */

/**
 * 量一下「文字左边到容器左边」的空隙，用于日志核对与「不压字」判断。
 * 找不到文字容器就返回 kAIContentInset（dump 实测值）。
 */
static CGFloat AssistantContentInsetFor(UIView *container) {
    if (!container) return kAIContentInset;

    static const char *const names[] = {
        "DeepSeek_Chat.AgentFragmentsView",
        "_TtC13DeepSeek_Chat19AgentFragmentsView",
    };
    NSMutableArray *stack = [NSMutableArray arrayWithObject:container];
    int guard = 0;
    while (stack.count && guard++ < 200) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        const char *cn = class_getName([v class]);
        if (cn) {
            for (int i = 0; i < 2; i++) {
                if (strcmp(cn, names[i]) == 0) {
                    CGRect r = [v convertRect:v.bounds toView:container];
                    return r.origin.x;
                }
            }
        }
        for (UIView *sv in v.subviews) [stack addObject:sv];
    }
    return kAIContentInset;
}

static UIImageView *FindOurAvatar(UIView *v) {
    for (UIView *sv in v.subviews) {
        if ([sv.accessibilityIdentifier isEqualToString:kAvatarTag]) {
            return (UIImageView *)sv;
        }
    }
    return nil;
}

static void LayoutAvatar(UIView *container) {
    if (!container || !gOn) return;

    CGRect b = container.bounds;
    if (b.size.width < 40 || b.size.height < 24) return;

    UIImageView *iv = FindOurAvatar(container);

    /* 没配图 ⇒ 不画（但保留视图对象，配置好后不用重建） */
    if (!gImage) {
        if (iv) iv.hidden = YES;
        return;
    }

    /* 宿主头像探测：仅在 debug 开关打开时跑（默认关，避免每帧扫树） */
    {
        static int probeOn = -1;
        if (probeOn < 0) {
            probeOn = [[FDMConfig shared] boolFor:@"assistant" key:@"probe"] ? 1 : 0;
        }
        if (probeOn) AssistantProbeHostAvatar(container);
    }

    if (!iv) {
        iv = [[UIImageView alloc] initWithFrame:CGRectZero];
        iv.accessibilityIdentifier = kAvatarTag;
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds = YES;
        iv.userInteractionEnabled = NO;
        /* ★ 原来自带一层 alpha=0.001 的白底「防止被布局优化掉」——
         *   没这个必要，反而在某些渲染路径上会透出一点点白边。删掉。 */
        [container addSubview:iv];
        static int logN = 0;
        if (logN++ < 5) {
            FLOGW(FC_UI, @"[assistant] 给 %@ 插入头像（bounds %.0fx%.0f）",
                  NSStringFromClass([container class]),
                  b.size.width, b.size.height);
        }
    }

    iv.hidden = NO;
    if (iv.image != gImage) iv.image = gImage;

    /* ══════════════════════════════════════════════════════════════════════
     *  尺寸：优先用配置值，但**不超过容器高度**。
     *  默认 22 —— 因为文字左边只有 24px 空隙（docs/37 §2.1），
     *  22 能塞进去且留 2px 呼吸，不会压字。
     *  想更大就在设置里调，压到字上是用户自己的选择。
     * ══════════════════════════════════════════════════════════════════════ */
    CGFloat s = kAvatarSize;
    CGFloat maxH = b.size.height - 2.0;
    if (maxH > 0 && s > maxH) s = maxH;
    if (s < 8) s = 8;

    /* 位置：默认贴左上，y 对齐「文字顶部」= 12（dump 实测的 UIView.y） */
    CGFloat x = kAvatarInsetX;
    CGFloat y = kAvatarInsetY;

    /* 夹在容器内（clip=0 虽然不裁，但跑出屏幕外就白画了）*/
    if (x < 0) x = 0;
    if (x + s > b.size.width) x = b.size.width - s;
    if (y < 0) y = 0;
    if (y + s > b.size.height) y = b.size.height - s;

    CGRect f = CGRectMake(x, y, s, s);
    if (!CGRectEqualToRect(iv.frame, f)) iv.frame = f;

    CGFloat r = gRound ? s / 2.0 : 0.0;
    if (iv.layer.cornerRadius != r) {
        iv.layer.cornerRadius = r;
        iv.layer.cornerCurve = kCACornerCurveContinuous;
    }

    /* ── 诊断日志：只在尺寸真的变了时打一行，方便真机核对 ── */
    static char kLogged;
    NSString *sig = [NSString stringWithFormat:@"%.0fx%.0f@%.0f,%.0f/%.0fx%.0f",
                     s, s, x, y, b.size.width, b.size.height];
    if (![sig isEqualToString:objc_getAssociatedObject(container, &kLogged)]) {
        objc_setAssociatedObject(container, &kLogged, sig,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        static int logN2 = 0;
        if (logN2++ < 20) {
            FLOGD(FC_UI, @"[assistant] 头像 %@ 容器 %.0fx%.0f 空隙可用 %.0f",
                  sig, b.size.width, b.size.height,
                  AssistantContentInsetFor(container));
        }
    }
}

static void RemoveAvatar(UIView *container) {
    if (!container) return;
    UIImageView *iv = FindOurAvatar(container);
    if (iv) [iv removeFromSuperview];
}

/* ══════════════════════════════════ hook ══════════════════════════════════ */

static BOOL gHooked = NO;
static __thread BOOL tInAssist = NO;

/* ══════════════════════════════════════════════════════════════════════════
 *  ★★★ 2026-10-24 血案 3：**又踩了 docs/36 的「坑 1」**
 *
 *  症状（真机日志）：
 *    给 UILayoutContainerView 插入头像（bounds 414x736）   ← 整个屏幕！
 *    给 UIView 插入头像（bounds 414x736）
 *    给 UIImageView 插入头像（bounds 414x736）
 *    给 UILabel 插入头像（bounds 208x25）
 *  ⇒ 满屏散落小头像，正是主人说的「重复的多个头像」。
 *
 *  根因：
 *    `class_getInstanceMethod(cls, @selector(layoutSubviews))`
 *    —— 如果 cls **自己没有实现** layoutSubviews（AgentMessageView 就没有），
 *       这个函数会沿继承链往上找，返回的是 **UIView 的 Method**。
 *       接着 `method_setImplementation(m, mine)` 改的是**父类的方法表**，
 *       于是**所有 UIView 子类**的 layoutSubviews 都跑到我们的 hook 里。
 *
 *  正解（docs/36 §2.3 坑 1 已经写过，我这次没照做）：
 *    ① 先 `class_addMethod` —— 能加成功说明本类原本没有，加上即止，
 *       并在 hook 里**手动转发给父类**；
 *    ② 加不成功（本类已有）才 `method_setImplementation`。
 * ══════════════════════════════════════════════════════════════════════════ */

static void HookContainer(Class cls) {
    if (!cls) return;
    static char kMark;
    if (objc_getAssociatedObject(cls, &kMark)) return;
    objc_setAssociatedObject(cls, &kMark, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    SEL sel = @selector(layoutSubviews);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    const char *types = method_getTypeEncoding(m);

    /* hook 主体：先转发，再干活 */
    void (^body)(id, SEL, IMP) = ^(id self, SEL _sel, IMP origIMP) {
        if (origIMP) {
            @try { ((void (*)(id, SEL))origIMP)(self, _sel); } @catch (NSException *e) { }
        }
        if (tInAssist) return;
        @try {
            tInAssist = YES;
            if (gOn) LayoutAvatar((UIView *)self);
            else RemoveAvatar((UIView *)self);
        } @catch (NSException *e) {
        } @finally {
            tInAssist = NO;
        }
    };

    /* ① 先试：只在本类加一个方法 */
    IMP generic = imp_implementationWithBlock(^(id self) {
        /* 这里的 block 没有 origIMP 参数，所以走「转发父类」那条 */
        SEL s2 = @selector(layoutSubviews);
        IMP sup = class_getMethodImplementation(class_getSuperclass([self class]), s2);
        if (sup) {
            @try { ((void (*)(id, SEL))sup)(self, s2); } @catch (NSException *e) { }
        }
        if (tInAssist) return;
        @try {
            tInAssist = YES;
            if (gOn) LayoutAvatar((UIView *)self);
            else RemoveAvatar((UIView *)self);
        } @catch (NSException *e) {
        } @finally {
            tInAssist = NO;
        }
    });

    if (class_addMethod(cls, sel, generic, types)) {
        FLOGI(FC_UI, @"[assistant] %s 本类无 layoutSubviews ⇒ class_addMethod（安全）",
              class_getName(cls));
        return;
    }

    /* ② 本类已有实现 ⇒ 才可以安全替换 */
    IMP orig = method_getImplementation(m);
    IMP mine = imp_implementationWithBlock(^(id self) {
        @try { ((void (*)(id, SEL))orig)(self, sel); } @catch (NSException *e) { }
        if (tInAssist) return;
        @try {
            tInAssist = YES;
            if (gOn) LayoutAvatar((UIView *)self);
            else RemoveAvatar((UIView *)self);
        } @catch (NSException *e) {
        } @finally {
            tInAssist = NO;
        }
    });
    method_setImplementation(m, mine);
    FLOGI(FC_UI, @"[assistant] %s 本类已有 layoutSubviews ⇒ method_setImplementation",
          class_getName(cls));
    (void)body;
}


/* ══════════════════════════════════════════════════════════════════════════
 *  ★★★ 2026-10-24 主人提醒：宿主**自带**助手头像，只是被隐藏了
 *
 *  从主二进制里直接找到的类名（这是石锤，不是猜）：
 *
 *    _TtCC13DeepSeek_Chat16AgentMessageView10AvatarView
 *      ^ _TtCC = Swift 嵌套类，即 AgentMessageView.AvatarView
 *    _TtCC13DeepSeek_Chat16AgentMessageViewP33_C790...15InnerAvatarView
 *      即 AgentMessageView.(私有)InnerAvatarView
 *    DeepSeek_Chat.InnerAvatarView
 *    DeepSeek_Chat.AvatarView
 *
 *  源码路径（调试符号里还在）：
 *    DeepSeek_Chat/AgentAvatarView.swift
 *    .../Cell/Views/AgentAvatarView.swift
 *
 *  ⇒ 跟安卓完全一样：宿主本来就会画头像，「修改助手图片」的正确做法是
 *    **找到那个头像视图，把里面的图换掉**，而不是自己在旁边插一个。
 *
 *  （我之前的判断「宿主没有 AI 头像视图」是错的 ——
 *    这是第二次犯同一个错：气泡那次也是「以为没有，其实在嵌套类里」。）
 *
 *  下面这个 dump 用来确认真机上的实际形态：
 *  是 UIImageView 子类？还是带 imageView 的容器？
 * ══════════════════════════════════════════════════════════════════════════ */

static int gAvatarProbeDone = 0;

static void AssistantProbeAvatarClasses(void) {
    if (gAvatarProbeDone) return;
    gAvatarProbeDone = 1;

    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *buf = (Class *)malloc(sizeof(Class) * (size_t)n);
    if (!buf) return;
    n = objc_getClassList(buf, n);

    int hits = 0;
    for (int i = 0; i < n; i++) {
        const char *nm = class_getName(buf[i]);
        if (!nm) continue;
        if (!strcasestr(nm, "Avatar")) continue;

        hits++;
        Class sup = class_getSuperclass(buf[i]);

        /* 继承链（最多 5 层）*/
        NSMutableString *chain = [NSMutableString string];
        Class c = buf[i];
        int d = 0;
        while (c && d < 5) {
            [chain appendFormat:@"%s%s", class_getName(c), d < 4 ? " → " : ""];
            c = class_getSuperclass(c);
            d++;
        }

        FLOGI(FC_UI, @"[assistant-probe] %s  [super=%s]  isView=%d isImgView=%d",
              nm, sup ? class_getName(sup) : "nil",
              sup && class_getSuperclass(buf[i]) ? 1 : 0,
              [buf[i] isSubclassOfClass:[UIImageView class]] ? 1 : 0);
        FLOGI(FC_UI, @"[assistant-probe]    %@", chain);

        /* ivar 里有没有 image / imageView */
        unsigned int ivn = 0;
        Ivar *ivs = class_copyIvarList(buf[i], &ivn);
        NSMutableString *ivs2 = [NSMutableString string];
        for (unsigned int k = 0; k < ivn && k < 20; k++) {
            const char *in = ivar_getName(ivs[k]);
            const char *it = ivar_getTypeEncoding(ivs[k]);
            if (in) [ivs2 appendFormat:@"%s(%s) ", in, it ? it : "?"];
        }
        if (ivs) free(ivs);
        if (ivs2.length) FLOGI(FC_UI, @"[assistant-probe]    ivars: %@", ivs2);

        if ([buf[i] isSubclassOfClass:[UIView class]]) {
            FLOGW(FC_UI, @"[assistant-probe]    ★ 是 UIView 子类 ⇒ 可以直接处理");
        }
    }
    free(buf);
    FLOGI(FC_UI, @"[assistant-probe] 共 %d 个含 Avatar 的类", hits);
}


/* ══════════════════════════════════════════════════════════════════════════
 *  ★★★ 2026-10-24（主人提醒）探测宿主自带的头像视图
 *
 *  二进制里确认存在的类：
 *    _TtCC13DeepSeek_Chat16AgentMessageView10AvatarView
 *    _TtCC13DeepSeek_Chat16AgentMessageViewP33_...15InnerAvatarView
 *    DeepSeek_Chat.InnerAvatarView / DeepSeek_Chat.AvatarView
 *  源码：Cell/Views/AgentAvatarView.swift
 *
 *  目的：确认它在真机视图树里的位置、尺寸、hidden 状态、里面装了什么。
 *  如果它在（只是被隐藏），那正确做法就是「把它显示出来 + 换图」，
 *  比自己插一个干净得多 —— 位置由宿主自己算，永远不会错位。
 * ══════════════════════════════════════════════════════════════════════════ */

static int gHostAvatarProbeN = 0;

static void AssistantProbeHostAvatar(UIView *root) {
    if (gHostAvatarProbeN > 12) return;
    if (!root) return;

    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count && guard++ < 600) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];

        NSString *cn = NSStringFromClass([v class]);
        if ([cn containsString:@"Avatar"] && ![cn containsString:@"CN"]) {
            if (gHostAvatarProbeN++ < 12) {
                CGRect inRoot = [v convertRect:v.bounds toView:root];

                /* 里面有没有 UIImageView */
                NSMutableString *inner = [NSMutableString string];
                for (UIView *sv in v.subviews) {
                    [inner appendFormat:@"%@(%.0fx%.0f) ",
                     NSStringFromClass([sv class]),
                     sv.bounds.size.width, sv.bounds.size.height];
                }

                FLOGW(FC_UI,
                      @"[host-avatar] %@  frame=%.0f,%.0f %.0fx%.0f  hidden=%d alpha=%.2f  isIV=%d  subs=[%@]",
                      cn, inRoot.origin.x, inRoot.origin.y,
                      inRoot.size.width, inRoot.size.height,
                      v.hidden ? 1 : 0, v.alpha,
                      [v isKindOfClass:[UIImageView class]] ? 1 : 0,
                      inner.length ? inner : @"(空)");

                if ([v isKindOfClass:[UIImageView class]]) {
                    UIImage *img = ((UIImageView *)v).image;
                    FLOGW(FC_UI, @"[host-avatar]   ★ 本身就是 UIImageView，image=%@ contentMode=%ld",
                          img ? [NSString stringWithFormat:@"%.0fx%.0f",
                                 img.size.width, img.size.height] : @"nil",
                          (long)((UIImageView *)v).contentMode);
                }
            }
        }
        for (UIView *sv in v.subviews) [stack addObject:sv];
    }
}


/* ══════════════════════════════════════════════════════════════════════════
 *  ★★★ 2026-10-24 深度勘察：宿主到底有没有那个头像视图类？
 *
 *  主人要求「让宿主自己显示头像，我们只换图」。
 *  那就必须先回答三个问题：
 *
 *   Q1  运行时里有没有这 4 个类？（二进制里有名字 ≠ 运行时一定注册）
 *       注意：Swift 嵌套类的运行时名可能和 nm/strings 里看到的不一样
 *       （`_TtCC13DeepSeek_Chat16AgentMessageView10AvatarView` 是 mangled name，
 *         objc runtime 里注册的会是 demangle 后的 `DeepSeek_Chat.AgentMessageView.AvatarView`）
 *
 *   Q2  消息 cell 里有没有「本该放头像」的空位？
 *       我们已经知道文字左边空 24px（AgentFragmentsView.x = 24）。
 *       如果这 24px 就是给头像留的，那头像位置就完全确定了。
 *
 *   Q3  AgentMessageView 的 ivar 里有没有 avatar 相关的槽位？
 *       如果有但值是 nil ⇒ 宿主确实没创建 ⇒ 得找「为什么」。
 *       如果有且不是 nil 但 hidden ⇒ 只要显示它 + 换图就行。
 * ══════════════════════════════════════════════════════════════════════════ */

static void AssistantDeepProbe(void) {
    static int done = 0;
    if (done) return;
    done = 1;

    FLOGI(FC_UI, @"[probe] ═══ 开始深度勘察 ═══");

    /* ── Q1：runtime 里找所有含 Avatar 且属于 DeepSeek 的类 ── */
    int n = objc_getClassList(NULL, 0);
    Class *buf = (Class *)malloc(sizeof(Class) * (size_t)n);
    if (buf) {
        n = objc_getClassList(buf, n);
        for (int i = 0; i < n; i++) {
            const char *nm = class_getName(buf[i]);
            if (!nm) continue;
            if (!strcasestr(nm, "Avatar")) continue;
            if (!strstr(nm, "DeepSeek")) continue;

            Class sup = class_getSuperclass(buf[i]);
            FLOGI(FC_UI, @"[probe] ★ runtime 类: %s  super=%s  isIV=%d",
                  nm, sup ? class_getName(sup) : "nil",
                  [buf[i] isSubclassOfClass:[UIImageView class]] ? 1 : 0);

            unsigned int ivn = 0;
            Ivar *ivs = class_copyIvarList(buf[i], &ivn);
            NSMutableString *m = [NSMutableString string];
            for (unsigned int k = 0; k < ivn && k < 15; k++) {
                const char *in = ivar_getName(ivs[k]);
                if (in) [m appendFormat:@"%s ", in];
            }
            if (ivs) free(ivs);
            FLOGI(FC_UI, @"[probe]   ivars: %@", m.length ? m : @"(无)");

            /* 所有 selector 里含 image 的 */
            unsigned int mn = 0;
            Method *ms = class_copyMethodList(buf[i], &mn);
            NSMutableString *mm = [NSMutableString string];
            for (unsigned int k = 0; k < mn && k < 40; k++) {
                const char *sn = sel_getName(method_getName(ms[k]));
                if (sn && strcasestr(sn, "image")) [mm appendFormat:@"%s ", sn];
            }
            if (ms) free(ms);
            if (mm.length) FLOGI(FC_UI, @"[probe]   image 方法: %@", mm);
        }
        free(buf);
    }

    /* ── Q2/Q3：AgentMessageView 的完整 ivar 表 ── */
    Class amv = objc_getClass("DeepSeek_Chat.AgentMessageView");
    if (!amv) amv = objc_getClass("_TtC13DeepSeek_Chat16AgentMessageView");
    if (amv) {
        FLOGI(FC_UI, @"[probe] AgentMessageView 找到了: %s", class_getName(amv));
        unsigned int ivn = 0;
        Ivar *ivs = class_copyIvarList(amv, &ivn);
        for (unsigned int k = 0; k < ivn; k++) {
            const char *in = ivar_getName(ivs[k]);
            const char *it = ivar_getTypeEncoding(ivs[k]);
            const char *off = "";
            ptrdiff_t o = ivar_getOffset(ivs[k]);
            (void)off;
            FLOGI(FC_UI, @"[probe]   ivar %s  type=%s  offset=%ld",
                  in ? in : "?", it ? it : "?", (long)o);
        }
        if (ivs) free(ivs);

        /* 所有方法名（找 layout / avatar / image 相关） */
        unsigned int mn = 0;
        Method *ms = class_copyMethodList(amv, &mn);
        NSMutableString *mm = [NSMutableString string];
        for (unsigned int k = 0; k < mn; k++) {
            const char *sn = sel_getName(method_getName(ms[k]));
            if (sn && (strcasestr(sn, "avatar") || strcasestr(sn, "layout")
                       || strcasestr(sn, "image") || strcasestr(sn, "config"))) {
                [mm appendFormat:@"%s ", sn];
            }
        }
        if (ms) free(ms);
        FLOGI(FC_UI, @"[probe]   AgentMessageView 相关方法: %@",
              mm.length ? mm : @"(无)");
    } else {
        FLOGW(FC_UI, @"[probe] ✗ AgentMessageView 类不存在！");
    }

    /* ── 找嵌套类（Swift 嵌套在 runtime 里是扁平名） ── */
    static const char *const cands[] = {
        "DeepSeek_Chat.AgentMessageView.AvatarView",
        "_TtCC13DeepSeek_Chat16AgentMessageView10AvatarView",
        "DeepSeek_Chat.AvatarView",
        "_TtC13DeepSeek_Chat10AvatarView",
        "DeepSeek_Chat.InnerAvatarView",
        "_TtC13DeepSeek_Chat15InnerAvatarView",
        "DeepSeek_Chat.AgentAvatarView",
    };
    for (size_t i = 0; i < sizeof(cands)/sizeof(cands[0]); i++) {
        Class c = objc_getClass(cands[i]);
        if (c) {
            Class sup = class_getSuperclass(c);
            FLOGI(FC_UI, @"[probe] ✓ 存在: %s (super=%s)",
                  cands[i], sup ? class_getName(sup) : "nil");
        } else {
            FLOGW(FC_UI, @"[probe] ✗ 不存在: %s", cands[i]);
        }
    }


    /* ── 补充：把 AvatarView / InnerAvatarView 的所有方法打出来 ── */
    static const char *const avClasses[] = {
        "_TtCC13DeepSeek_Chat16AgentMessageView10AvatarView",
        "_TtCC13DeepSeek_Chat16AgentMessageViewP33_C790DFAF1A3E190F053776F13AB5ECC015InnerAvatarView",
        "DeepSeek_Chat.AgentMessageView",
    };
    for (size_t i = 0; i < 3; i++) {
        Class c = objc_getClass(avClasses[i]);
        if (!c) continue;

        FLOGI(FC_UI, @"[probe2] ═══ %s 全部方法 ═══", avClasses[i]);
        unsigned int mn = 0;
        Method *ms = class_copyMethodList(c, &mn);
        NSMutableString *m = [NSMutableString string];
        for (unsigned int k = 0; k < mn; k++) {
            [m appendFormat:@"%s | ", sel_getName(method_getName(ms[k]))];
        }
        if (ms) free(ms);
        FLOGI(FC_UI, @"[probe2] %@", m.length ? m : @"(无方法)");

        /* 所有 ivar 的类型编码 */
        unsigned int ivn = 0;
        Ivar *ivs = class_copyIvarList(c, &ivn);
        for (unsigned int k = 0; k < ivn; k++) {
            FLOGI(FC_UI, @"[probe2]   ivar %s  type='%s'  off=%ld",
                  ivar_getName(ivs[k]) ? ivar_getName(ivs[k]) : "?",
                  ivar_getTypeEncoding(ivs[k]) ? ivar_getTypeEncoding(ivs[k]) : "?",
                  (long)ivar_getOffset(ivs[k]));
        }
        if (ivs) free(ivs);
    }

    FLOGI(FC_UI, @"[probe] ═══ 深度勘察结束 ═══");
}


/* ══════════════════════════════════════════════════════════════════════════
 *  ★★★ 2026-10-24（主人挖来旧版 1.2.6 之后）真正的移植路径
 *
 *  对比结论（analysis/old-ipa/结论.md）：
 *    旧版 1.2.6 的 AgentMessageView 有 `$__lazy_storage_$_avatar` ⇒ 接好线的
 *    新版 2.6.2 把这个字段删了                       ⇒ 功能移除
 *    但 **AvatarView / InnerAvatarView 两个类还在新版里**（只是没人创建）
 *
 *  ⇒ 所以「移植」不是自己插 UIImageView，
 *    而是 **自己 alloc/init 宿主的 AvatarView，塞进 AgentMessageView**。
 *    这样尺寸、圆角、位置、明暗全部由宿主自己的代码决定 ——
 *    跟官方实现一模一样，不用猜 22px 还是 24px。
 *
 *  现在要探测的是：这个类实例化出来长什么样？
 *    · AvatarView.inner  是什么类型？
 *    · InnerAvatarView.icon 是什么（UIImageView？CALayer？）
 *    · 它的 intrinsicContentSize / 子视图布局是多少？
 * ══════════════════════════════════════════════════════════════════════════ */

// gAVProbeDone 随探测函数一起删掉了

/* ★ 2026-10-24 已删除 AssistantProbeAvatarViewInstance()：
 *   在 2.7.1 上实例化 AvatarView 会 SIGTRAP 崩溃
 *   （Swift 那边大概是 init 里 fatalError 或用 required init）。
 *   证据见 docs/39 与 docs/40。 */

void FDMAssistantInstall(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ FDMAssistantInstall(); });
        return;
    }
    if (!gLoaded) AssistantReload();
    /* ★★ 2026-10-24 血案：2.7.1 上 `alloc/initWithFrame:` AvatarView 直接 SIGTRAP 崩溃
     *   （日志最后一行是 [av-probe] ═══ 尝试实例化 AvatarView ═══ 然后 CRASH signal=5）
     *   ⇒ 这个类大概只在 Swift 内部按特定方式构造，外部 alloc 会撞 fatalError。
     *   ⇒ 所有探测代码只在 probe 开关打开时跑，默认全关。 */
    {
        static int probeOn = -1;
        if (probeOn < 0) {
            probeOn = [[FDMConfig shared] boolFor:@"assistant" key:@"probe"] ? 1 : 0;
        }
        if (probeOn) {
            FLOGW(FC_UI, @"[assistant] ⚠️ probe=on，注意：实例化 AvatarView 会 SIGTRAP");
            AssistantProbeAvatarClasses();
            AssistantDeepProbe();
        }
    }
    if (!gOn) {
        FLOGI(FC_UI, @"[assistant] 开关关着，不装");
        return;
    }
    if (gHooked) {
        FDMAssistantRefreshAll();
        return;
    }
    gHooked = YES;

    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *buf = (Class *)malloc(sizeof(Class) * (size_t)n);
    if (!buf) return;
    n = objc_getClassList(buf, n);

    int hits = 0;
    for (int i = 0; i < n; i++) {
        const char *nm = class_getName(buf[i]);
        if (!nm) continue;
        NSString *cn = @(nm);
        if (IsAIContainer(cn)) {
            HookContainer(buf[i]);
            hits++;
        }
    }
    free(buf);

    FLOGI(FC_UI, @"[assistant] hook 完成：%d 个 AI 容器类", hits);
    FDMAssistantRefreshAll();
}

void FDMAssistantReload(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ FDMAssistantReload(); });
        return;
    }
    AssistantReload();
    if (!gOn) {
        FDMAssistantRefreshAll();     /* 关掉时把已插的删掉 */
        return;
    }
    if (!gHooked) FDMAssistantInstall();
    else FDMAssistantRefreshAll();
}

void FDMAssistantRefreshAll(void) {
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

        int hits = 0;
        for (UIWindow *w in wins) {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
            int guard = 0;
            while (stack.count && guard++ < 4000) {
                UIView *v = stack.lastObject;
                [stack removeLastObject];
                if (IsAIContainer(NSStringFromClass([v class]))) {
                    if (gOn) LayoutAvatar(v);
                    else RemoveAvatar(v);
                    hits++;
                }
                for (UIView *sv in v.subviews) [stack addObject:sv];
            }
        }
        FLOGI(FC_UI, @"[assistant] 刷新完成：%d 个容器（%@）",
              hits, gOn ? @"插入/更新" : @"清理");
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[assistant] 刷新异常: %@", e.reason);
    }
}
