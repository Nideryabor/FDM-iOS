// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMMiniBar —— 悬浮迷你播放卡（挂在宿主窗口上的浮层，零权限）
//
// 对标安卓 `GmMiniBarView.java`（1051 行）+ `GmMiniBar.java`（293 行）。
//
//   ① 播放页                          ② 搜索页
//   ┌────────────┬───────────────┐    ┌───────────────────────────┐
//   │            │ ≡ 曲名 & 歌手 ✕│    │ [搜点什么…          ] [搜]│
//   │    封面     ├───────────────┤    ├───────────────────────────┤
//   │            │   歌词三行     │    │ ▶ 稻香 · 周杰伦            │
//   ├────────────┴───────────────┤    │ ▶ 晴天 · 周杰伦            │
//   │ 0:00 [━━━●━━━] 4:29        │    │ …（可滚动，点一条就放）      │
//   │  ♪   ◀◀   ▶   ▶▶   ↻   ⇄  │    └───────────────────────────┘
//   └────────────────────────────┘
//
// ★ 三个必须遵守的（都是本项目血泪）
//   1. 挂 window 不挂 VC —— 宿主切页时 window 不换、VC 会换。
//   2. 任何操作都可能被宿主回收 ⇒ 每次 Tick 都检查 superview，掉了就重挂。
//   3. 不在 hook 里做重活：本卡片只由定时器驱动刷新（0.5s 一拍）。
//
// ★ 版权：封面与歌词**只在内存**（NSCache / 字符串），永不落盘。
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import "FDMMusic.h"
#import "FDMMusicModel.h"
#import "FDMMusicApi.h"
#import "FLog.h"

extern UIWindow *FDMFindBestWindow(void);

/* ============================================================
 * 〇、常量
 * ============================================================ */

static const CGFloat kBarW      = 320.0;   /* 对齐安卓 fuckds_bar_w 默认值 */
static const CGFloat kBarH      = 200.0;   /* 对齐安卓 fuckds_bar_h 默认值 */
static const CGFloat kPad       = 10.0;
static const CGFloat kCoverSide = 84.0;

/* 捏合缩放的范围（pt）。安卓那边是 190~600 宽 / 120~640 高，这里同规格。 */
static const CGFloat kBarWMin = 240.0, kBarWMax = 560.0;
static const CGFloat kBarHMin = 150.0, kBarHMax = 560.0;

/* 配色：深色毛玻璃 + 白字（宿主是深色界面时最协调） */
#define COL_TEXT   [UIColor colorWithWhite:1.0 alpha:0.96]
#define COL_DIM    [UIColor colorWithWhite:1.0 alpha:0.55]
#define COL_ACCENT [UIColor colorWithRed:0.36 green:0.78 blue:1.00 alpha:1.0]

/* ============================================================
 * 一、工具
 * ============================================================ */

static NSCache<NSString *, UIImage *> *gCoverCache = nil;

static UIImage *MiniBarLoadCover(NSString *url, void (^done)(UIImage *)) {
    if (!url.length) return nil;
    NSString *u = [FDMMusicApi preferHTTPS:url];
    UIImage *hit = [gCoverCache objectForKey:u];
    if (hit) return hit;

    NSURL *nsu = [NSURL URLWithString:u];
    if (!nsu) return nil;
    /* ★ 只放内存：NSCache 会被系统回收，永不落盘 */
    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithURL:nsu
                                    completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!d.length || e) return;
        UIImage *img = [UIImage imageWithData:d];
        if (!img) return;
        [gCoverCache setObject:img forKey:u];
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(img); });
    }];
    [task resume];
    return nil;
}

static UILabel *MiniBarLabel(UIFont *font, UIColor *color, NSTextAlignment align) {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.font = font;
    l.textColor = color;
    l.textAlignment = align;
    l.backgroundColor = UIColor.clearColor;
    l.numberOfLines = 1;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    return l;
}

static UIButton *MiniBarButton(NSString *title, CGFloat w, CGFloat h, UIColor *bg) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(0, 0, w, h);
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [b setTitleColor:COL_TEXT forState:UIControlStateNormal];
    b.backgroundColor = bg ?: [UIColor colorWithWhite:1.0 alpha:0.10];
    b.layer.cornerRadius = 9.0;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    return b;
}

/* ============================================================
 * 二、迷你卡本体
 * ============================================================ */

@interface FDMMiniBarView : UIView
-(void)refreshAll;
@end

@interface FDMMiniBarView () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@end
@implementation FDMMiniBarView {
    /* --- 顶部（两页共用） --- */
    UILabel     *_title;        /* 曲名 & 歌手 */
    UIButton    *_closeBtn;
    UIButton    *_pageBtn;      /* ♪ / ⇄ 切页 */
    UIPanGestureRecognizer   *_pan;
    UIPinchGestureRecognizer *_pinch;

    /* --- 聚焦（看歌词）模式 --- */
    BOOL         _focusMode;
    BOOL         _pureImage;    /* 聚焦 + 双击 = 只留封面 */
    UIButton    *_backBtn;
    UIView      *_scrim;        /* 聚焦态：封面之上的渐变暗膜 */
    UITapGestureRecognizer *_pureTap;   /* 纯图模式的双击（只在纯图时 enabled） */

    /* --- 四角拖拽缩放 --- */
    UIView      *_handleTL, *_handleTR, *_handleBL, *_handleBR;
    CGRect       _dragBase;
    CGPoint      _dragStart;

    /* --- 播放页 --- */
    UIView      *_playPage;
    UIImageView *_cover;
    UISlider    *_slider;
    UILabel     *_tLeft, *_tRight;
    UIButton    *_btnPrev, *_btnPlay, *_btnNext, *_btnRepeat, *_btnShuffle;
    BOOL        _draggingSlider;

    /* --- 歌词（常态 + 聚焦共用同一个 UITableView）---
     * 常态：右侧窄条，不可滚动，当前行居中
     * 聚焦：铺满整卡，可滚动，自动跟随 + 3 秒手动锁定 */
    UITableView *_lyricTable;
    NSMutableArray<NSDictionary *> *_lyricLines;   /* @{@"t":文字, @"ms":@(毫秒)} */
    long long    _lyricSongId;                     /* 缓存对应的 songId */
    NSInteger    _lyricSrcCount;                   /* 构建时源歌词行数（判断歌词是否后到） */
    NSInteger    _lyricCurRow;                     /* 当前唱到第几行 */
    BOOL         _lyricFollow;                     /* 是否自动跟随当前行 */
    NSTimer     *_lyricUnlockTimer;                /* 手动滚动后 3 秒恢复跟随 */

    /* 缩放时用的基准尺寸 */
    CGFloat      _baseW, _baseH;

    /* --- 搜索页 --- */
    UIView      *_searchPage;
    UITextField *_input;
    UIButton    *_searchBtn;
    UITableView *_table;
    NSArray     *_results;
    NSString    *_lastQuery;
}

/* ---------------- 构造 ---------------- */

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    @try { [self buildAll]; } @catch (NSException *e) {
        FLOGE(FC_UI, @"[minibar] 构建异常: %@", e.reason);
    }
    return self;
}

- (void)buildAll {
    self.backgroundColor = UIColor.clearColor;
    self.layer.cornerRadius = 16.0;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = YES;

    _lyricFollow = YES;
    _lyricCurRow = -1;
    _lyricSongId = -1;
    _baseW = kBarW;
    _baseH = kBarH;

    /* 毛玻璃底（iOS 13+ 可用；宿主是深色，选 dark 变体最稳） */
    UIVisualEffectView *blur =
        [[UIVisualEffectView alloc] initWithEffect:
            [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    blur.frame = self.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:blur];

    /* 一层淡淡的高光边，让它看起来像玻璃而不是纯色块 */
    self.layer.borderWidth = 0.5;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;

    /* ================= 播放页（放在最底层，这样它永远盖不住顶栏按钮）================= */
    _playPage = [[UIView alloc] initWithFrame:CGRectZero];
    [self insertSubview:_playPage atIndex:1];

    _cover = [[UIImageView alloc] initWithFrame:CGRectZero];
    _cover.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    _cover.layer.cornerRadius = 10.0;
    _cover.layer.cornerCurve = kCACornerCurveContinuous;
    _cover.clipsToBounds = YES;
    _cover.contentMode = UIViewContentModeScaleAspectFill;
    [_playPage addSubview:_cover];

    /* 聚焦态的渐变暗膜：压在封面之上、歌词之下，保证白字可读。
     * 用 CAGradientLayer 而不是纯色 —— 纯色会把封面糊成一片。 */
    _scrim = [[UIView alloc] initWithFrame:CGRectZero];
    _scrim.userInteractionEnabled = NO;
    _scrim.hidden = YES;
    {
        CAGradientLayer *gl = [CAGradientLayer layer];
        gl.colors = @[ (id)[UIColor colorWithWhite:0.0 alpha:0.62].CGColor,
                       (id)[UIColor colorWithWhite:0.0 alpha:0.28].CGColor,
                       (id)[UIColor colorWithWhite:0.0 alpha:0.72].CGColor ];
        gl.locations = @[ @0.0, @0.45, @1.0 ];
        gl.startPoint = CGPointMake(0.5, 0.0);
        gl.endPoint = CGPointMake(0.5, 1.0);
        [_scrim.layer addSublayer:gl];
    }
    [_playPage addSubview:_scrim];

    /* ---- 歌词表（常态窄条 / 聚焦全屏，同一个对象）---- */
    _lyricTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _lyricTable.backgroundColor = UIColor.clearColor;
    _lyricTable.separatorStyle = UITableViewCellSeparatorStyleNone;
    _lyricTable.dataSource = self;
    _lyricTable.delegate = self;
    _lyricTable.rowHeight = 26.0;
    _lyricTable.showsVerticalScrollIndicator = NO;
    _lyricTable.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    _lyricTable.contentInset = UIEdgeInsetsMake(0, 0, 0, 0);
    _lyricTable.scrollEnabled = NO;          /* 常态不可滚；聚焦时才开 */
    [_playPage addSubview:_lyricTable];

    /* ---- 进度条 + 时间 ---- */
    _slider = [[UISlider alloc] initWithFrame:CGRectZero];
    _slider.minimumValue = 0;
    _slider.maximumValue = 1;
    _slider.minimumTrackTintColor = COL_ACCENT;
    _slider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.22];
    /* ★ 2026-10-24 主人：「播放条那个按钮你应该也看到了，太大了，稍微小点」
     *   iOS 默认圆点约 28pt，缩到 14pt。
     *   为什么必须自己画图：UISlider 没有暴露 thumb 尺寸的属性，
     *   只能用 setThumbImage: 换一张。 */
    {
        CGFloat d = 14.0;
        UIGraphicsImageRenderer *r =
            [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(d, d)];
        UIImage *dot = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            UIBezierPath *p = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, d, d)];
            [[UIColor colorWithWhite:1.0 alpha:0.94] setFill];
            [p fill];
        }];
        [_slider setThumbImage:dot forState:UIControlStateNormal];
        [_slider setThumbImage:dot forState:UIControlStateHighlighted];
    }
    [_slider addTarget:self action:@selector(onSliderDown) forControlEvents:UIControlEventTouchDown];
    [_slider addTarget:self action:@selector(onSliderUp)
      forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                       UIControlEventTouchCancel];
    [_playPage addSubview:_slider];

    _tLeft  = MiniBarLabel([UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular],
                           COL_DIM, NSTextAlignmentLeft);
    _tRight = MiniBarLabel([UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular],
                           COL_DIM, NSTextAlignmentRight);
    _tLeft.text = @"0:00";
    _tRight.text = @"0:00";
    [_playPage addSubview:_tLeft];
    [_playPage addSubview:_tRight];

    /* ---- 底部按钮（居中）---- */
    _btnPrev    = MiniBarButton(@"◀◀", 44, 30, [UIColor colorWithWhite:1.0 alpha:0.10]);
    _btnPlay    = MiniBarButton(@"▶",  52, 30, [UIColor colorWithWhite:1.0 alpha:0.16]);
    _btnNext    = MiniBarButton(@"▶▶", 44, 30, [UIColor colorWithWhite:1.0 alpha:0.10]);
    _btnRepeat  = MiniBarButton(@"↻",  32, 30, [UIColor colorWithWhite:1.0 alpha:0.10]);
    _btnShuffle = MiniBarButton(@"⇄",  32, 30, [UIColor colorWithWhite:1.0 alpha:0.10]);
    [_btnPrev    addTarget:self action:@selector(onPrev)    forControlEvents:UIControlEventTouchUpInside];
    [_btnPlay    addTarget:self action:@selector(onPlay)    forControlEvents:UIControlEventTouchUpInside];
    [_btnNext    addTarget:self action:@selector(onNext)    forControlEvents:UIControlEventTouchUpInside];
    [_btnRepeat  addTarget:self action:@selector(onRepeat)  forControlEvents:UIControlEventTouchUpInside];
    [_btnShuffle addTarget:self action:@selector(onShuffle) forControlEvents:UIControlEventTouchUpInside];
    for (UIView *b in @[_btnPrev, _btnPlay, _btnNext, _btnRepeat, _btnShuffle])
        [_playPage addSubview:b];

    /* ================= 顶栏（放在 playPage 之后 ⇒ 永远在最上层）================= */
    _title = MiniBarLabel([UIFont systemFontOfSize:13 weight:UIFontWeightSemibold],
                          COL_TEXT, NSTextAlignmentLeft);
    _title.text = @"还没有歌";
    _title.layer.shadowColor = UIColor.blackColor.CGColor;
    _title.layer.shadowOpacity = 0.45f;
    _title.layer.shadowRadius = 2.0f;
    _title.layer.shadowOffset = CGSizeZero;
    [self addSubview:_title];

    _closeBtn = MiniBarButton(@"✕", 28, 28, [UIColor colorWithWhite:1.0 alpha:0.10]);
    [_closeBtn addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_closeBtn];

    _pageBtn = MiniBarButton(@"♪", 28, 28, [UIColor colorWithWhite:1.0 alpha:0.10]);
    [_pageBtn addTarget:self action:@selector(onTogglePage) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_pageBtn];

    /* 聚焦模式的返回键（左上角，单独一个 —— 主人要求）
     * ★ 2026-10-24 修：之前被 _playPage（铺满整卡）盖住了。
     *   现在 _playPage 用 insertSubview:atIndex:1 压在最底，
     *   顶栏三个按钮都在它之后 add ⇒ 不会再被盖。 */
    _backBtn = MiniBarButton(@"‹", 28, 28, [UIColor colorWithWhite:1.0 alpha:0.10]);
    _backBtn.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
    [_backBtn addTarget:self action:@selector(onBack) forControlEvents:UIControlEventTouchUpInside];
    _backBtn.hidden = YES;
    [self addSubview:_backBtn];

    /* ================= 搜索页 ================= */
    _searchPage = [[UIView alloc] initWithFrame:CGRectZero];
    _searchPage.hidden = YES;
    [self addSubview:_searchPage];

    _input = [[UITextField alloc] initWithFrame:CGRectZero];
    _input.textColor = COL_TEXT;
    _input.font = [UIFont systemFontOfSize:13];
    _input.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    _input.layer.cornerRadius = 9.0;
    _input.layer.cornerCurve = kCACornerCurveContinuous;
    _input.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 1)];
    _input.leftViewMode = UITextFieldViewModeAlways;
    _input.returnKeyType = UIReturnKeySearch;
    _input.delegate = self;
    _input.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:@"搜点什么…"
                                        attributes:@{NSForegroundColorAttributeName:
                                                     [UIColor colorWithWhite:1.0 alpha:0.40]}];
    [_searchPage addSubview:_input];

    _searchBtn = MiniBarButton(@"搜", 44, 30, [UIColor colorWithWhite:1.0 alpha:0.16]);
    [_searchBtn addTarget:self action:@selector(onSearch) forControlEvents:UIControlEventTouchUpInside];
    [_searchPage addSubview:_searchBtn];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.backgroundColor = UIColor.clearColor;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = 32.0;
    _table.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [_searchPage addSubview:_table];

    /* ---- 拖动（整卡） ---- */
    _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    _pan.maximumNumberOfTouches = 1;
    _pan.delegate = (id<UIGestureRecognizerDelegate>)self;
    [self addGestureRecognizer:_pan];

    /* ---- 双指捏合缩放 ---- */
    _pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(onPinch:)];
    [self addGestureRecognizer:_pinch];

    /* ---- 歌词手势：单击 / 双击 / 长按 ---- */
    [self installLyricGestures];

    /* ---- 四角拖拽缩放 ---- */
    [self installResizeHandles];
}

/* ============================================================
 * 歌词手势（三个，都在 _lyricTable 上）
 *
 *   单击  → 常态进聚焦 / 聚焦回常态（主人：「不影响单击回到主界面」）
 *   双击  → 聚焦态切「纯图模式」（隐藏歌词 + 蒙版）；纯图态再双击恢复
 *   长按  → 跳到手指那一句（主人：「长按某句歌词跳转到歌曲对应位置」）
 *
 * ⚠️ 单击必须 requireGestureRecognizerToFail:双击，否则双击永远抢不到。
 * ⚠️ 长按和双击都是 2 指事件；这里都用 1 指，靠 minimumPressDuration 区分。
 * ============================================================ */

- (void)installLyricGestures {
    UITapGestureRecognizer *one =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onLyricSingleTap:)];
    one.numberOfTapsRequired = 1;

    UITapGestureRecognizer *two =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onLyricDoubleTap:)];
    two.numberOfTapsRequired = 2;

    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLyricLongPress:)];
    lp.minimumPressDuration = 0.45;
    lp.allowableMovement = 12.0;

    [one requireGestureRecognizerToFail:two];       /* ★ 关键 */
    [one requireGestureRecognizerToFail:lp];

    [_lyricTable addGestureRecognizer:one];
    [_lyricTable addGestureRecognizer:two];
    [_lyricTable addGestureRecognizer:lp];
}

- (void)onLyricSingleTap:(UITapGestureRecognizer *)g {
    /* 纯粹切「常态 ⇄ 聚焦」。
     * 纯图模式下也一样：单击直接回常态（主人要求的"不影响单击回到主界面"）。 */
    if (_pureImage) {
        _pureImage = NO;
        [self setFocusMode:NO];
    } else {
        [self setFocusMode:!_focusMode];
    }
}

- (void)onLyricDoubleTap:(UITapGestureRecognizer *)g {
    /* 只在聚焦态有效：双击切「纯图」 */
    if (!_focusMode) return;
    _pureImage = !_pureImage;
    FLOGI(FC_UI, @"[minibar] %@", _pureImage ? @"双击 → 纯图（隐藏歌词+蒙版）"
                                             : @"双击 → 恢复歌词");
    [UIView animateWithDuration:0.22 animations:^{
        self->_scrim.hidden = self->_pureImage;
        self->_lyricTable.alpha = self->_pureImage ? 0.0 : 1.0;
        self->_title.alpha = self->_pureImage ? 0.0 : 1.0;
        self->_backBtn.alpha = self->_pureImage ? 0.0 : 1.0;
    }];
    if (_pureImage) {
        /* 纯图态手指没有可点的东西了 ⇒ 让整卡拖动照常接管；
         * 但还得能双击恢复：用卡片自己身上的双击（_pureTap）。 */
        _lyricTable.userInteractionEnabled = NO;
        [self installPureImageTapIfNeeded];
        _pureTap.enabled = YES;
    } else {
        _lyricTable.userInteractionEnabled = YES;
        if (_pureTap) _pureTap.enabled = NO;
    }
}

- (void)installPureImageTapIfNeeded {
    /* ★ 2026-10-24 修：原来用一个全屏透明 UIView 接手势，
     *   结果它盖住了四角手柄 ⇒ 纯图模式下拖不动大小。
     *   改成「卡片自己身上的双击手势」，只在纯图模式 enabled。 */
    if (_pureTap) return;
    _pureTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                       action:@selector(onPureImageTap:)];
    _pureTap.numberOfTapsRequired = 2;
    _pureTap.enabled = NO;
    [self addGestureRecognizer:_pureTap];
}

- (void)onPureImageTap:(UITapGestureRecognizer *)g {
    if (!_pureImage) return;
    _pureImage = NO;
    _lyricTable.userInteractionEnabled = YES;
    _pureTap.enabled = NO;
    [UIView animateWithDuration:0.22 animations:^{
        self->_scrim.hidden = NO;
        self->_lyricTable.alpha = 1.0;
        self->_title.alpha = 1.0;
        self->_backBtn.alpha = 1.0;
    }];
    FLOGI(FC_UI, @"[minibar] 双击 → 恢复歌词");
}

- (void)onLyricLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    @try {
        CGPoint p = [g locationInView:_lyricTable];
        NSIndexPath *ip = [_lyricTable indexPathForRowAtPoint:p];
        if (!ip || (NSUInteger)ip.row >= _lyricLines.count) return;

        NSNumber *msN = _lyricLines[(NSUInteger)ip.row][@"ms"];
        long long ms = msN.longLongValue;
        NSString *txt = _lyricLines[(NSUInteger)ip.row][@"t"] ?: @"";

        FLOGI(FC_UI, @"[minibar] 长按歌词第 %ld 行 → 跳到 %.1fs（%@）",
              (long)ip.row, ms / 1000.0, txt);
        FDMMusicAction(3, ms);

        /* 跳完把「自动跟随」打开，省得用户还得再点一次 */
        _lyricFollow = YES;
        [self lyricScrollToCurrent:YES];
    } @catch (NSException *e) { }
}

/* ============================================================
 * 聚焦 ⇄ 常态
 *
 *   ① 常态
 *      [♪ 曲名 ✕]
 *      [封面84] [歌词窄条，当前行居中]
 *      [0:11 ━●── 3:26]     ← 吸附在按钮上方
 *      [◀◀ ❚❚ ▶▶ ↻ ⇄]      ← 居中
 *
 *   ② 聚焦（点歌词进）
 *      [‹ 曲名]            ← _playPage 在最底层，按钮不会被盖
 *      [封面铺满整卡 + 暗膜]
 *      [全歌词，可滚动，当前行居中高亮]
 *      （进度条 + 按钮 全隐藏）
 *
 *   ③ 纯图（聚焦时双击）
 *      [封面铺满]  ← 歌词、暗膜、标题、返回键全隐藏
 *      （单击回常态，双击恢复）
 *
 * ★ 无论哪种形态，进度条都是「贴着按钮行上沿」算的 ——
 *   所以卡片拉长时，多出来的高度**全部给歌词**，不会中间留一片空白。
 * ============================================================ */

- (void)setFocusMode:(BOOL)on {
    if (_focusMode == on) return;
    _focusMode = on;

    BOOL n = !on;    /* 常态 = YES；留着好读 */
    (void)n;

    /* 常态元素：进度条 + 时间 + 五个按钮 + ♪ + ✕ */
    _slider.hidden = on;
    _tLeft.hidden  = on;
    _tRight.hidden = on;
    for (UIButton *b in @[ _btnPrev, _btnPlay, _btnNext, _btnRepeat, _btnShuffle ])
        b.hidden = on;
    _pageBtn.hidden  = on;
    _closeBtn.hidden = on;

    /* 聚焦元素 */
    _backBtn.hidden = !on;
    _scrim.hidden   = !on;
    _lyricTable.scrollEnabled = on;      /* ★ 只有聚焦态能滚歌词 */

    if (on) {
        _pureImage = NO;
        _lyricTable.userInteractionEnabled = YES;
        _lyricTable.alpha = 1.0;
        _title.alpha = 1.0;
        _backBtn.alpha = 1.0;
        _lyricFollow = YES;
    } else {
        _pureImage = NO;
        _scrim.hidden = YES;
        _lyricTable.userInteractionEnabled = YES;
        _lyricTable.alpha = 1.0;
        _title.alpha = 1.0;
        _backBtn.alpha = 1.0;
        [self cancelLyricUnlockTimer];
    }

    /* 聚焦态文本：压在封面上，纯白 + 阴影最稳 */
    if (on) {
        _title.textColor = [UIColor whiteColor];
        _title.layer.shadowOpacity = 0.55f;
    } else {
        _title.textColor = COL_TEXT;
        _title.layer.shadowOpacity = 0.45f;
    }

    [UIView animateWithDuration:0.28
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut |
                                UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        [self setNeedsLayout];
        [self layoutIfNeeded];
    } completion:^(BOOL fin) {
        [self lyricScrollToCurrent:NO];
    }];

    FLOGI(FC_UI, @"[minibar] 布局 → %@", on ? @"聚焦（全歌词）" : @"常态");
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat top = kPad;
    CGFloat barH = 28.0;                      /* 顶栏高度 */
    CGFloat bodyY = top + barH + 8;

    /* ---- 顶栏 ---- */
    _pageBtn.frame  = CGRectMake(kPad, top, barH, barH);
    _backBtn.frame  = CGRectMake(kPad, top, barH, barH);
    _closeBtn.frame = CGRectMake(w - kPad - barH, top, barH, barH);
    if (_focusMode)
        _title.frame = CGRectMake(kPad + barH + 6, top, w - 2 * kPad - barH - 6, barH);
    else
        _title.frame = CGRectMake(kPad + barH + 6, top, w - 2 * kPad - barH * 2 - 12, barH);

    /* ---- 纯图模式的「双击接住层」铺满整张卡 ---- */

    if (_focusMode) {
        /* ================= 聚焦：封面铺满整卡，歌词浮在上面 ================= */
        _playPage.frame = CGRectMake(0, 0, w, h);
        _cover.frame = CGRectMake(0, 0, w, h);
        _cover.layer.cornerRadius = 0;         /* 圆角交给父视图裁剪 */
        _scrim.frame = CGRectMake(0, 0, w, h);
        for (CALayer *l in _scrim.layer.sublayers)
            if ([l isKindOfClass:[CAGradientLayer class]]) l.frame = _scrim.bounds;

        /* 歌词整块铺满（顶栏以下），可滚动 */
        _lyricTable.frame = CGRectMake(0, bodyY, w, h - bodyY - kPad);
        _lyricTable.rowHeight = 30.0;
        _lyricTable.contentInset = UIEdgeInsetsMake(0, 0, h * 0.35, 0);  /* 底部留白，让最后一句能滚到中间 */
    } else {
        /* ================= 常态：进度条贴着按钮上沿，中间全给歌词 ================= */
        CGFloat btnH  = 30.0;
        CGFloat btnY  = h - kPad - btnH;           /* 按钮行（底部） */
        CGFloat slH   = 22.0;
        CGFloat slY   = btnY - 6 - slH;            /* ★ 进度条吸附在按钮上方 */
        CGFloat timeH = 12.0;
        CGFloat timeY = slY + (slH - timeH) * 0.5;

        _playPage.frame = CGRectMake(0, bodyY, w, h - bodyY);
        CGFloat localBtnY = btnY - bodyY;
        CGFloat localSlY  = slY  - bodyY;
        CGFloat localTimeY = timeY - bodyY;

        /* 封面：常态小方块，靠上放（高度不够时按比例缩） */
        CGFloat availH = localSlY - 6;              /* 歌词区可用的高度（相对 playPage） */
        CGFloat coverSide = kCoverSide;
        if (availH < coverSide) coverSide = MAX(36.0, availH);
        _cover.frame = CGRectMake(kPad, 0, coverSide, coverSide);
        _cover.layer.cornerRadius = 10.0;

        /* 歌词窄条：封面右边，垂直居中 */
        CGFloat lx = kPad + coverSide + 10;
        CGFloat lw = w - lx - kPad;
        _lyricTable.frame = CGRectMake(lx, 0, lw, MAX(28.0, availH));
        _lyricTable.rowHeight = 22.0;
        /* 上下各留半屏 inset ⇒ 首行/末行也能滚到中间 */
        CGFloat half = MAX(0.0, (availH - 22.0) * 0.5);
        _lyricTable.contentInset = UIEdgeInsetsMake(half, 0, half, 0);

        /* 进度条 + 时间 */
        _tLeft.frame  = CGRectMake(kPad, localTimeY, 40, timeH);
        _tRight.frame = CGRectMake(w - kPad - 40, localTimeY, 40, timeH);
        _slider.frame = CGRectMake(kPad + 44, localSlY, w - 2 * kPad - 88, slH);

        /* 按钮行：居中 */
        CGFloat wPrev = 44.0, wPlay = 52.0, wNext = 44.0, wRep = 32.0, wShuf = 32.0;
        CGFloat gap   = 8.0;
        CGFloat total = wPrev + wPlay + wNext + wRep + wShuf + gap * 4;
        CGFloat x = (w - total) * 0.5;
        if (x < kPad) x = kPad;

        _btnPrev.frame    = CGRectMake(x, localBtnY, wPrev, btnH); x += wPrev + gap;
        _btnPlay.frame    = CGRectMake(x, localBtnY, wPlay, btnH); x += wPlay + gap;
        _btnNext.frame    = CGRectMake(x, localBtnY, wNext, btnH); x += wNext + gap;
        _btnRepeat.frame  = CGRectMake(x, localBtnY, wRep,  btnH); x += wRep + gap;
        _btnShuffle.frame = CGRectMake(x, localBtnY, wShuf, btnH);

        _lyricTable.frame = CGRectMake(lx, 0, lw, MAX(28.0, localSlY - 6));
    }

    /* ---- 搜索页 ---- */
    _searchPage.frame = CGRectMake(0, bodyY, w, h - bodyY - kPad);
    _input.frame = CGRectMake(kPad, 0, w - 2 * kPad - 44 - 6, 30);
    _searchBtn.frame = CGRectMake(w - kPad - 44, 0, 44, 30);
    _table.frame = CGRectMake(kPad, 36, w - 2 * kPad, MAX(40.0, h - bodyY - kPad - 36));

    /* ---- 四角拖拽手柄（贴内边，别被圆角裁掉）---- */
    {
        CGFloat hs = 22.0, ins = 1.0;
        _handleTL.frame = CGRectMake(ins, ins, hs, hs);
        _handleTR.frame = CGRectMake(w - hs - ins, ins, hs, hs);
        _handleBL.frame = CGRectMake(ins, h - hs - ins, hs, hs);
        _handleBR.frame = CGRectMake(w - hs - ins, h - hs - ins, hs, hs);
    }

    /* 顶栏 + 手柄永远压最上层（_playPage 在 index 1，低调） */
    for (UIView *v in @[ _title, _pageBtn, _backBtn, _closeBtn,
                         _handleTL, _handleTR, _handleBL, _handleBR ])
        [self bringSubviewToFront:v];
}

/* ---------------- 歌词行缓存 + 自动跟随 ---------------- */

/** 从 FDMMusic 拉一份全歌词（songId 变了 或 源行数变了 才重建）。
 *
 * ★★ 2026-10-24 真机 bug：原来只判 `sid == _lyricSongId && _lyricLines`，
 *    结果「歌词还在下载时先建了一次缓存（0 行）」⇒ 之后歌词到手也永远是 0 行，
 *    聚焦态一片空白。必须连**源行数**一起比，源变了就重建。 */
- (void)reloadLyricLines {
    const fdmmusic_queue *q = FDMMusicQueue();
    const fdmmusic_track *t = fdmmusic_current(q);
    long long sid = t ? t->id : -1;
    NSInteger srcCnt = FDMMusicLyricCount();

    if (sid == _lyricSongId && _lyricLines && srcCnt == _lyricSrcCount) return;

    _lyricSongId = sid;
    _lyricSrcCount = srcCnt;
    _lyricLines = [NSMutableArray arrayWithCapacity:(NSUInteger)MAX(srcCnt, 0)];
    for (NSInteger i = 0; i < srcCnt; i++) {
        NSString *txt = nil;
        long long ms = 0;
        if (!FDMMusicLyricAt(i, &txt, &ms)) continue;
        txt = [txt stringByTrimmingCharactersInSet:
               [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!txt.length) txt = @"♪";                    /* 空行给个占位，节奏感还在 */
        [_lyricLines addObject:@{ @"t": txt, @"ms": @(ms) }];
    }
    _lyricCurRow = -1;
    FLOGD(FC_UI, @"[minibar] 歌词缓存重建：%ld 行（songId=%lld 源=%ld）",
          (long)_lyricLines.count, sid, (long)srcCnt);
    [_lyricTable reloadData];
}

- (void)cancelLyricUnlockTimer {
    if (_lyricUnlockTimer) { [_lyricUnlockTimer invalidate]; _lyricUnlockTimer = nil; }
}

/** 手动滚动后 3 秒恢复自动跟随（主人说的「临时锁定」）。 */
- (void)scheduleLyricFollowResume {
    [self cancelLyricUnlockTimer];
    _lyricUnlockTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                         target:self
                                                       selector:@selector(onLyricFollowResume:)
                                                       userInfo:nil
                                                        repeats:NO];
}

- (void)onLyricFollowResume:(NSTimer *)t {
    _lyricUnlockTimer = nil;
    _lyricFollow = YES;
    FLOGD(FC_UI, @"[minibar] 歌词自动跟随恢复");
    [self lyricScrollToCurrent:YES];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)sv {
    if (sv != _lyricTable) return;
    _lyricFollow = NO;                       /* ★ 用户一开始滑就"临时锁定" */
    [self scheduleLyricFollowResume];
    FLOGD(FC_UI, @"[minibar] 用户开始滑歌词 → 暂停跟随 3 秒");
}

- (void)scrollViewDidEndDragging:(UIScrollView *)sv willDecelerate:(BOOL)dec {
    if (sv != _lyricTable) return;
    if (!dec) [self scheduleLyricFollowResume];
}

/** 把当前行滚到中间（这就是「当前句居中」的实现）。 */
- (void)lyricScrollToCurrent:(BOOL)animated {
    if (_lyricLines.count == 0) return;
    NSInteger row = _lyricCurRow;
    if (row < 0 || row >= (NSInteger)_lyricLines.count) return;
    if (!_lyricFollow) return;

    NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:0];
    @try {
        [_lyricTable scrollToRowAtIndexPath:ip
                           atScrollPosition:UITableViewScrollPositionMiddle
                                   animated:animated];
    } @catch (NSException *e) { }
}

/* ---------------- 刷新 ---------------- */

- (void)refreshAll {
    @try {
        const fdmmusic_queue *q = FDMMusicQueue();
        if (!q) return;
        const fdmmusic_track *t = fdmmusic_current(q);

        /* 标题 */
        if (t && t->name) {
            NSString *n = [NSString stringWithUTF8String:t->name];
            NSString *a = t->artist ? [NSString stringWithUTF8String:t->artist] : @"";
            _title.text = a.length ? [NSString stringWithFormat:@"%@ · %@", n, a] : n;
        } else {
            _title.text = @"还没有歌 —— 点 ♪ 搜一首";
        }

        /* 封面 */
        if (t && t->pic) {
            NSString *pic = [NSString stringWithUTF8String:t->pic];
            UIImage *hit = [gCoverCache objectForKey:[FDMMusicApi preferHTTPS:pic]];
            if (hit) {
                _cover.image = hit;
            } else if (![_cover.accessibilityIdentifier isEqualToString:pic]) {
                _cover.accessibilityIdentifier = pic;
                _cover.image = nil;
                MiniBarLoadCover(pic, ^(UIImage *img) {
                    self->_cover.image = img;
                });
            }
        } else {
            _cover.image = nil;
            _cover.accessibilityIdentifier = nil;
        }

        /* 播放键 */
        [_btnPlay setTitle:(q->state == FDMMS_PLAYING) ? @"❚❚" : @"▶"
                  forState:UIControlStateNormal];
        [_btnPlay setTitleColor:(q->state == FDMMS_ERROR) ? [UIColor systemRedColor] : COL_TEXT
                       forState:UIControlStateNormal];

        /* 循环 / 随机 按钮的「亮/暗」表达状态 */
        _btnRepeat.backgroundColor = (q->repeat == FDMMR_OFF)
            ? [UIColor colorWithWhite:1.0 alpha:0.10]
            : [UIColor colorWithRed:0.36 green:0.78 blue:1.00 alpha:0.35];
        [_btnRepeat setTitle:(q->repeat == FDMMR_ONE) ? @"↻1" : @"↻"
                     forState:UIControlStateNormal];
        _btnShuffle.backgroundColor = q->shuffle
            ? [UIColor colorWithRed:0.36 green:0.78 blue:1.00 alpha:0.35]
            : [UIColor colorWithWhite:1.0 alpha:0.10];

        /* 进度 */
        long long dur = t ? t->duration_ms : 0;
        long long pos = q->pos_ms;
        if (dur <= 0) dur = 1;                     /* 防 0 除 */
        if (pos < 0) pos = 0;
        if (pos > dur) pos = dur;

        if (!_draggingSlider) {
            _slider.maximumValue = (float)dur;
            _slider.value = (float)pos;
        }
        char b1[24] = {0}, b2[24] = {0};
        fdmmusic_fmt_time(pos, b1, sizeof(b1));
        fdmmusic_fmt_time(dur, b2, sizeof(b2));
        _tLeft.text = @(b1);
        _tRight.text = @(b2);

        /* ---- 歌词：缓存 + 当前行 ---- */
        [self reloadLyricLines];

        NSInteger newRow = FDMMusicLyricIndexAt(pos);
        BOOL rowChanged = (newRow != _lyricCurRow);
        _lyricCurRow = newRow;

        if (_lyricLines.count) {
            if (rowChanged) {
                /* ★★ 2026-10-24 真机崩溃点：
                 *   reloadRowsAtIndexPaths **收空数组会抛异常**（前奏时 newRow = -1）
                 *   ⇒ 整个宿主 App 一起死。必须判 count。 */
                NSMutableArray *paths = [NSMutableArray array];
                if (newRow >= 0 && newRow < (NSInteger)_lyricLines.count)
                    [paths addObject:[NSIndexPath indexPathForRow:newRow inSection:0]];
                if (paths.count)
                    [_lyricTable reloadRowsAtIndexPaths:paths
                                       withRowAnimation:UITableViewRowAnimationNone];
                [self lyricScrollToCurrent:YES];
            } else {
                /* 同一行也要刷（同句里有高亮进度需求时）—— 这里省掉，只保证首次居中 */
                static BOOL once = NO;
                if (!once) { once = YES; [self lyricScrollToCurrent:NO]; }
            }
        }
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[minibar] 刷新异常: %@", e.reason);
    }
}

/* ---------------- 按钮动作 ---------------- */

- (void)onClose {
    /* 只关本次显示，不动配置（和安卓便签的 ✕ 同语义） */
    FLOGI(FC_UI, @"[minibar] 用户点了 ✕");
    FDMMusicShowMiniBar(NO);
}

- (void)onBack {
    if (_pureImage) _pureImage = NO;
    [self setFocusMode:NO];
}

- (void)onTogglePage {
    if (_focusMode) [self setFocusMode:NO];      /* 先退出聚焦，再切页 */
    _searchPage.hidden = !_searchPage.hidden;
    _playPage.hidden = !_searchPage.hidden;
    [_pageBtn setTitle:_searchPage.hidden ? @"♪" : @"↩" forState:UIControlStateNormal];
    if (_searchPage.hidden) [_input resignFirstResponder];
    [self setNeedsLayout];
}

- (void)onPlay   { FDMMusicAction(0, 0); }
- (void)onNext   { FDMMusicAction(1, 0); }
- (void)onPrev   { FDMMusicAction(2, 0); }
- (void)onRepeat { FDMMusicAction(6, 0); }
- (void)onShuffle{ FDMMusicAction(7, 0); }

- (void)onSliderDown { _draggingSlider = YES; }
- (void)onSliderUp {
    _draggingSlider = NO;
    FDMMusicAction(3, (long long)_slider.value);
}

/* ---------------- 四角拖拽缩放 ----------------
 *
 * 主人 2026-10-24：「改大小还是四个角拖动吧，那样的更自由」
 *（比双指捏合好的地方：想只拉宽 / 只拉高都行，而且一个手指就够）
 *
 * 四个角各自固定**对角**：
 *   左上拖 → 右下不动      右上拖 → 左下不动
 *   左下拖 → 右上不动      右下拖 → 左上不动
 *
 * ⚠️ 用「记录起点 + 总位移」而不是「累加增量」：
 *   累加增量在夹到最小尺寸后，往回拖会有一段"死区"（手感很怪）。
 */
- (UIView *)makeHandle:(int)corner {
    CGFloat hs = 22.0;
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, hs, hs)];
    /* ★★ 2026-10-24 真机 bug：手柄原来用 tag 0~3，但 **UIView 的默认 tag 就是 0**，
     *   而 _playPage / 毛玻璃 的 tag 也全是 0 ⇒ shouldReceiveTouch 把每一次
     *   落在卡片上的触摸都当成"摸到手柄"拒掉 ⇒ **整张卡完全拖不动**。
     *   ⇒ 手柄 tag 改成 1000+corner，和默认值彻底错开。 */
    h.tag = 1000 + corner;
    h.backgroundColor = UIColor.clearColor;
    h.userInteractionEnabled = YES;

    /* 视觉：一个小圆点，不抢戏 */
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(6, 6, 10, 10)];
    dot.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.42];
    dot.layer.cornerRadius = 5.0;
    dot.userInteractionEnabled = NO;
    dot.tag = 0xD07 << 4;        /* 也别用 0：0xD07 之外的默认值会和手柄撞 */
    [h addSubview:dot];

    UIPanGestureRecognizer *p =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onHandlePan:)];
    [h addGestureRecognizer:p];
    return h;
}

- (void)installResizeHandles {
    _handleTL = [self makeHandle:0];
    _handleTR = [self makeHandle:1];
    _handleBL = [self makeHandle:2];
    _handleBR = [self makeHandle:3];
    for (UIView *h in @[ _handleTL, _handleTR, _handleBL, _handleBR ])
        [self addSubview:h];
}

- (void)onHandlePan:(UIPanGestureRecognizer *)g {
    @try {
        UIView *sup = self.superview;
        int corner = (int)g.view.tag - 1000;       /* 0=TL 1=TR 2=BL 3=BR */

        if (g.state == UIGestureRecognizerStateBegan) {
            _dragBase = self.frame;
            _dragStart = [g locationInView:sup ?: self];
            for (UIView *h in @[ _handleTL, _handleTR, _handleBL, _handleBR ]) {
                UIView *d = [h viewWithTag:(0xD07 << 4)];
                d.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.9];
            }
            return;
        }

        if (g.state == UIGestureRecognizerStateChanged) {
            if (!sup) return;
            CGPoint p = [g locationInView:sup];
            CGFloat dx = p.x - _dragStart.x;
            CGFloat dy = p.y - _dragStart.y;

            CGRect b = _dragBase;
            CGFloat minW = kBarWMin, minH = kBarHMin;
            CGFloat maxW = kBarWMax, maxH = kBarHMax;

            if (corner == 0) {           /* 左上：右下角固定 */
                CGFloat nw = b.size.width  - dx;
                CGFloat nh = b.size.height - dy;
                if (nw < minW) nw = minW;
                if (nh < minH) nh = minH;
                if (nw > maxW) nw = maxW;
                if (nh > maxH) nh = maxH;
                b.origin.x = CGRectGetMaxX(_dragBase) - nw;
                b.origin.y = CGRectGetMaxY(_dragBase) - nh;
                b.size.width = nw;
                b.size.height = nh;
            } else if (corner == 1) {    /* 右上：左下角固定 */
                CGFloat nw = b.size.width + dx;
                CGFloat nh = b.size.height - dy;
                if (nw < minW) nw = minW;
                if (nh < minH) nh = minH;
                if (nw > maxW) nw = maxW;
                if (nh > maxH) nh = maxH;
                b.origin.x = _dragBase.origin.x;
                b.origin.y = CGRectGetMaxY(_dragBase) - nh;
                b.size.width = nw;
                b.size.height = nh;
            } else if (corner == 2) {    /* 左下：右上角固定 */
                CGFloat nw = b.size.width  - dx;
                CGFloat nh = b.size.height + dy;
                if (nw < minW) nw = minW;
                if (nh < minH) nh = minH;
                if (nw > maxW) nw = maxW;
                if (nh > maxH) nh = maxH;
                b.origin.x = CGRectGetMaxX(_dragBase) - nw;
                b.origin.y = _dragBase.origin.y;
                b.size.width = nw;
                b.size.height = nh;
            } else {                     /* 右下：左上角固定 */
                CGFloat nw = b.size.width  + dx;
                CGFloat nh = b.size.height + dy;
                if (nw < minW) nw = minW;
                if (nh < minH) nh = minH;
                if (nw > maxW) nw = maxW;
                if (nh > maxH) nh = maxH;
                b.origin.x = _dragBase.origin.x;
                b.origin.y = _dragBase.origin.y;
                b.size.width = nw;
                b.size.height = nh;
            }

            self.frame = b;
            [self setNeedsLayout];
            [self layoutIfNeeded];
            return;
        }

        if (g.state == UIGestureRecognizerStateEnded ||
            g.state == UIGestureRecognizerStateCancelled) {
            for (UIView *h in @[ _handleTL, _handleTR, _handleBL, _handleBR ]) {
                UIView *d = [h viewWithTag:(0xD07 << 4)];
                d.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.42];
            }
            extern void FDMMiniBarSavePosNow(CGRect f, CGSize win);
            if (sup) FDMMiniBarSavePosNow(self.frame, sup.bounds.size);
            [self refreshAll];
        }
    } @catch (NSException *e) { }
}

/* 摸到四角手柄 / 歌词表 / 按钮 / 进度条时，别让「整卡拖动」抢走。
 *
 * ⚠️⚠️ 判断 tag 时**千万不能用 0**（UIView 默认 tag 就是 0，
 *   而 _playPage / 毛玻璃 / 大部分子视图的 tag 全是 0）——
 *   2026-10-24 就是因为 `tag >= 0 && tag <= 3` 把每一次触摸都拒了，
 *   导致整张卡彻底拖不动。手柄统一用 1000~1003。 */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    if (g != _pan) return YES;
    UIView *v = t.view;
    if ([v isKindOfClass:[UIButton class]] || [v isKindOfClass:[UISlider class]]) return NO;

    /* 歌词区：聚焦态要滚歌词（拒绝拖卡）；常态允许拖卡 */
    if ([v isDescendantOfView:_lyricTable]) return !_focusMode;
    if ([v isDescendantOfView:_table])  return NO;    /* 搜索结果列表永远要滚 */
    if ([v isDescendantOfView:_input])  return NO;

    /* 四角手柄（含里面的小圆点） */
    if (v.tag >= 1000 && v.tag <= 1003 && [self.subviews containsObject:v]) return NO;
    if (v.tag == (0xD07 << 4)) return NO;

    return YES;
}

/* ---------------- 双指捏合缩放 ---------------- */

- (void)onPinch:(UIPinchGestureRecognizer *)g {
    @try {
        UIView *sup = self.superview;

        if (g.state == UIGestureRecognizerStateBegan) {
            _baseW = self.bounds.size.width;
            _baseH = self.bounds.size.height;
            return;
        }
        if (g.state == UIGestureRecognizerStateChanged) {
            CGFloat nw = _baseW * g.scale;
            CGFloat nh = _baseH * g.scale;
            nw = MAX(kBarWMin, MIN(kBarWMax, nw));
            nh = MAX(kBarHMin, MIN(kBarHMax, nh));

            /* 以「捏合的中心点」为锚缩放，卡片才不会一边缩一边跑 */
            CGPoint c = [g locationInView:sup ?: self];
            CGRect f = self.frame;
            CGFloat rx = (f.size.width  > 0) ? (c.x - f.origin.x) / f.size.width  : 0.5;
            CGFloat ry = (f.size.height > 0) ? (c.y - f.origin.y) / f.size.height : 0.5;
            f.origin.x = c.x - nw * rx;
            f.origin.y = c.y - nh * ry;
            f.size.width = nw;
            f.size.height = nh;

            if (sup) {
                CGFloat margin = 40.0;
                if (f.origin.x < -nw + margin) f.origin.x = -nw + margin;
                if (f.origin.x > sup.bounds.size.width - margin)
                    f.origin.x = sup.bounds.size.width - margin;
                if (f.origin.y < margin) f.origin.y = margin;
                if (f.origin.y > sup.bounds.size.height - margin)
                    f.origin.y = sup.bounds.size.height - margin;
            }
            self.frame = f;
            [self setNeedsLayout];
            return;
        }
        if (g.state == UIGestureRecognizerStateEnded ||
            g.state == UIGestureRecognizerStateCancelled) {
            extern void FDMMiniBarSavePosNow(CGRect f, CGSize win);
            if (sup) FDMMiniBarSavePosNow(self.frame, sup.bounds.size);
            [self layoutIfNeeded];
            [self refreshAll];
        }
    } @catch (NSException *e) { }
}

/* ---------------- 整卡拖动 ---------------- */

- (void)onPan:(UIPanGestureRecognizer *)g {
    @try {
        UIView *sup = self.superview;
        if (!sup) return;
        /* 松手就存（别等 MiniBarHide —— 用户可能直接杀 App） */
        if (g.state == UIGestureRecognizerStateEnded ||
            g.state == UIGestureRecognizerStateCancelled) {
            extern void FDMMiniBarSavePosNow(CGRect f, CGSize win);
            FDMMiniBarSavePosNow(self.frame, sup.bounds.size);
        }
        CGPoint d = [g translationInView:sup];
        CGRect f = self.frame;
        f.origin.x += d.x;
        f.origin.y += d.y;

        /* 夹紧：允许一半出去，但不许整张消失 */
        CGFloat margin = 40.0;
        CGFloat maxX = sup.bounds.size.width - margin;
        CGFloat maxY = sup.bounds.size.height - margin;
        if (f.origin.x < -f.size.width + margin) f.origin.x = -f.size.width + margin;
        if (f.origin.x > maxX) f.origin.x = maxX;
        if (f.origin.y < margin) f.origin.y = margin;
        if (f.origin.y > maxY) f.origin.y = maxY;

        self.frame = f;
        [g setTranslation:CGPointZero inView:sup];
    } @catch (NSException *e) { }
}

/* ---------------- 搜索 ---------------- */

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [self onSearch];
    return YES;
}

- (void)onSearch {
    NSString *kw = [_input.text stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!kw.length) return;
    if ([kw isEqualToString:_lastQuery] && _results.count) return;
    _lastQuery = kw;
    _title.text = @"搜索中…";

    __weak FDMMiniBarView *weakSelf = self;
    FDMMusicSearch(kw, ^(NSArray *tracks) {
        FDMMiniBarView *me = weakSelf;
        if (!me) return;
        me->_results = tracks ?: @[];
        [me->_table reloadData];
        me->_title.text = me->_results.count
            ? [NSString stringWithFormat:@"找到 %lu 首", (unsigned long)me->_results.count]
            : @"没搜到，换个词试试";
    });
}

/* ---------------- 两个表的 delegate（靠 tv == 谁 区分） ---------------- */

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (tv == _lyricTable) return (NSInteger)_lyricLines.count;
    return (NSInteger)_results.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    /* ---- 歌词表 ---- */
    if (tv == _lyricTable) {
        static NSString *lid = @"fdm-lyric-row";
        UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:lid];
        if (!c) {
            c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:lid];
            c.backgroundColor = UIColor.clearColor;
            c.textLabel.numberOfLines = 1;
            c.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            c.textLabel.layer.shadowColor = UIColor.blackColor.CGColor;
            c.textLabel.layer.shadowRadius = 2.0f;
            c.textLabel.layer.shadowOffset = CGSizeZero;
        }
        if ((NSUInteger)ip.row >= _lyricLines.count) return c;

        NSString *txt = _lyricLines[(NSUInteger)ip.row][@"t"] ?: @"";
        BOOL cur = ((NSInteger)ip.row == _lyricCurRow);
        c.textLabel.text = txt;

        if (cur) {
            c.textLabel.font = [UIFont systemFontOfSize:(_focusMode ? 16.0 : 13.5)
                                                 weight:UIFontWeightSemibold];
            c.textLabel.textColor = [UIColor whiteColor];
            c.textLabel.layer.shadowOpacity = 0.6f;
        } else if (_focusMode) {
            c.textLabel.font = [UIFont systemFontOfSize:14.0];
            c.textLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.58];
            c.textLabel.layer.shadowOpacity = 0.35f;
        } else {
            c.textLabel.font = [UIFont systemFontOfSize:12.0];
            c.textLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.42];
            c.textLabel.layer.shadowOpacity = 0.3f;
        }
        return c;
    }

    /* ---- 搜索表 ---- */
    static NSString *cid = @"fdm-mini-row";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                   reuseIdentifier:cid];
        c.backgroundColor = UIColor.clearColor;
        c.textLabel.font = [UIFont systemFontOfSize:13];
        c.textLabel.textColor = COL_TEXT;
        c.detailTextLabel.font = [UIFont systemFontOfSize:10];
        c.detailTextLabel.textColor = COL_DIM;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        UIView *sel = [[UIView alloc] initWithFrame:c.bounds];
        sel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
        c.selectedBackgroundView = sel;
    }
    if ((NSUInteger)ip.row < _results.count) {
        id o = _results[(NSUInteger)ip.row];
        if ([o isKindOfClass:[FDMMusicTrack class]]) {
            FDMMusicTrack *t = o;
            c.textLabel.text = [NSString stringWithFormat:@"▶ %@", t.name ?: @""];
            c.detailTextLabel.text = t.artist ?: @"";
        }
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:NO];
    if (tv == _lyricTable) return;             /* 歌词的点击交给手势 */

    if ((NSUInteger)ip.row >= _results.count) return;

    /* 把搜索结果整批变成队列，从点的这条开始放 */
    NSUInteger n = _results.count;
    fdmmusic_track *arr = (fdmmusic_track *)calloc(n, sizeof(fdmmusic_track));
    if (!arr) return;
    NSMutableArray *keep = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) {
        id o = _results[i];
        if (![o isKindOfClass:[FDMMusicTrack class]]) continue;
        FDMMusicTrack *t = o;
        NSString *nm = t.name ?: @"", *ar = t.artist ?: @"",
                 *al = t.album ?: @"", *pc = t.picUrl ?: @"";
        [keep addObject:@[nm, ar, al, pc]];      /* 抱住 UTF8String 的内存 */
        arr[i].id = t.songId;
        arr[i].name = (char *)nm.UTF8String;
        arr[i].artist = (char *)ar.UTF8String;
        arr[i].album = (char *)al.UTF8String;
        arr[i].pic = (char *)pc.UTF8String;
        arr[i].duration_ms = t.duration;
        arr[i].fee = (int)t.fee;
    }
    FDMMusicSetQueueRaw(arr, (unsigned long)n, (int)ip.row);
    free(arr);
    (void)keep;

    [self onTogglePage];                  /* 点完回播放页 */
    [self refreshAll];
}
@end

/* ============================================================
 * 三、挂载 / 卸载（对外的四个函数）
 * ============================================================ */

static FDMMiniBarView *gBar = nil;

static NSString *MiniBarPosPath(void) {
    @try {
        NSString *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES).firstObject;
        return [d stringByAppendingPathComponent:@"fdm-minibar-pos.json"];
    } @catch (NSException *e) { return nil; }
}

static void MiniBarSavePos(CGRect f, CGSize win) {
    @try {
        /* ★ 除了位置，尺寸也存 —— 用户捏合缩放后杀 App 不能变回原样。 */
        NSDictionary *j = @{ @"x": @(f.origin.x), @"y": @(f.origin.y),
                             @"w": @(f.size.width), @"h": @(f.size.height),
                             @"sw": @(win.width), @"sh": @(win.height) };
        NSData *d = [NSJSONSerialization dataWithJSONObject:j options:0 error:nil];
        [d writeToFile:MiniBarPosPath() atomically:YES];
    } @catch (NSException *e) { }
}

/** 拖完松手就存（别等 MiniBarHide —— 用户可能直接杀 App）。 */
void FDMMiniBarSavePosNow(CGRect f, CGSize win) { MiniBarSavePos(f, win); }

/* 读存档位置 + 尺寸。
 *
 * ★★ 2026-10-24 真机 bug：老格式的 w/h 存的是**屏幕尺寸**（414x736），
 *   不是卡片尺寸。新代码把它当成卡片尺寸读 ⇒ 卡片被撑到比屏幕还大，
 *   用户看到的就是「一大坨、还调不了大小」。
 *   ⇒ 判定规则：有 sw/sh 字段 = 新格式；没有 = 老格式，尺寸一律用默认值。 */
static CGRect MiniBarLoadFrame(CGSize win) {
    CGRect f = CGRectMake(win.width - kBarW - 12, win.height * 0.55, kBarW, kBarH);
    @try {
        NSData *d = [NSData dataWithContentsOfFile:MiniBarPosPath()];
        if (!d.length) return f;
        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![j isKindOfClass:[NSDictionary class]]) return f;
        NSDictionary *m = j;

        CGFloat x = [m[@"x"] doubleValue], y = [m[@"y"] doubleValue];
        CGFloat bw = kBarW, bh = kBarH;

        BOOL newFormat = (m[@"sw"] != nil && m[@"sh"] != nil);
        if (newFormat) {
            CGFloat ow = [m[@"sw"] doubleValue], oh = [m[@"sh"] doubleValue];
            if (ow > 1 && oh > 1) { x = x / ow * win.width; y = y / oh * win.height; }
            bw = [m[@"w"] doubleValue];
            bh = [m[@"h"] doubleValue];
        } else {
            /* 老格式：只有位置可信。位置当年也是按屏幕比例存的。 */
            FLOGI(FC_UI, @"[minibar] 读到老格式存档 ⇒ 尺寸用默认，位置按比例换算");
        }

        if (bw < kBarWMin || bw > kBarWMax) bw = kBarW;
        if (bh < kBarHMin || bh > kBarHMax) bh = kBarH;

        f = CGRectMake(x, y, bw, bh);
    } @catch (NSException *e) { }
    return f;
}

BOOL FDMMiniBarIsVisible(void) {
    return (gBar != nil && gBar.superview != nil && !gBar.hidden);
}

void FDMMiniBarHide(void) {
    @try {
        if (gBar) {
            if (gBar.superview) MiniBarSavePos(gBar.frame, gBar.superview.bounds.size);
            [gBar removeFromSuperview];
            gBar = nil;
        }
    } @catch (NSException *e) { }
}

void FDMMiniBarShow(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ FDMMiniBarShow(); });
        return;
    }
    @try {
        UIWindow *w = FDMFindBestWindow();
        if (!w) return;
        if (gBar && gBar.superview == w) {
            [gBar refreshAll];
            return;
        }
        if (gBar) [gBar removeFromSuperview];

        if (!gCoverCache) {
            gCoverCache = [[NSCache alloc] init];
            gCoverCache.countLimit = 12;          /* 只放内存，且不贪 */
        }

        CGRect f = MiniBarLoadFrame(w.bounds.size);
        gBar = [[FDMMiniBarView alloc] initWithFrame:f];
        [w addSubview:gBar];

        /* 夹一次：存档里的坐标可能是别的屏幕尺寸下的 */
        CGRect b = gBar.frame;
        CGFloat margin = 40.0;
        if (b.origin.x < -b.size.width + margin) b.origin.x = -b.size.width + margin;
        if (b.origin.x > w.bounds.size.width - margin) b.origin.x = w.bounds.size.width - margin;
        if (b.origin.y < margin) b.origin.y = margin;
        if (b.origin.y > w.bounds.size.height - margin) b.origin.y = w.bounds.size.height - margin;
        gBar.frame = b;
        [gBar layoutIfNeeded];

        [gBar refreshAll];
        FLOGI(FC_UI, @"[minibar] 已挂到 %@ (%.0fx%.0f) 位置 (%.0f,%.0f)",
              NSStringFromClass([w class]), w.bounds.size.width, w.bounds.size.height,
              b.origin.x, b.origin.y);
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[minibar] 挂载异常: %@", e.reason);
    }
}

void FDMMiniBarRefresh(void) {
    if (!gBar) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gBar) [gBar refreshAll];
        });
        return;
    }
    [gBar refreshAll];
}

