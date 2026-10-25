// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMMusic.m —— 见头文件注释。
//
// 老老实实的三条铁律（照抄安卓 + 本项目血泪）：
//   1. 任何 UI 操作都回主线程；任何网络都不在主线程等。
//   2. 全部对外接口 **不许崩**：@try 兜住，出错就静默 + 一行日志。
//   3. 存档不每秒写 —— 只在「切歌 / 暂停 / 退出」这种拐点上写。
//      （每秒写盘 = 安卓那边 GmMusicPlayer 踩过的发热 + 卡顿）
#import <AVFoundation/AVFoundation.h>

#import "FDMMusic.h"
#import "FDMMusicModel.h"
#import "FDMMusicApi.h"
#import "FDMLyric.h"
#import "FLog.h"

/* ============================================================
 * 〇、全局
 * ============================================================ */

@class FDMMusicItemWatch;      /* 前向声明（类定义在下面） */

static fdmmusic_queue gQ;                 /* 队列 + 状态 + 偏好 */
static BOOL      gReady = NO;             /* Install 过了 */
static BOOL      gModelInited = NO;
static AVPlayer *gPlayer = nil;
static id        gTimeObs = nil;      /* 周期观察者 token */
static id        gEndObs  = nil;      /* 播完通知 token */
static FDMMusicItemWatch *gItemObs = nil;   /* item.status 观察者 */
static BOOL      gSessionConfigured = NO;
static BOOL      gMiniOn = NO;            /* 迷你卡开关（配置） */
static BOOL      gAutoPlay = NO;           /* 启动自动播放（配置，v75 新增） */
static BOOL      gOpen = NO;              /* 用户是否要迷你卡 */
static BOOL      gInstalled = NO;
static dispatch_source_t gTickTimer = nil;
static int       gTickCount = 0;
static CFAbsoluteTime gCfgAt = 0;
static BOOL      gCfgOn = YES;
static BOOL      gLyricOn = YES;
static BOOL      gSaving = NO;

/* 歌词（只在内存） */
static fdmlrc    gLrcDoc;
static BOOL      gLrcDocReady = NO;
static long long gLrcSongId = -1;

/* ============================================================
 * 一、路径 / 存档
 * ============================================================ */

static NSString *MusicDocs(void) {
    @try {
        NSString *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES).firstObject;
        return d.length ? d : NSTemporaryDirectory();
    } @catch (NSException *e) { return NSTemporaryDirectory(); }
}

static NSString *MusicDir(void) {
    NSString *d = [MusicDocs() stringByAppendingPathComponent:@(FDMMUSIC_DIR_HINT)];
    @try {
        [[NSFileManager defaultManager] createDirectoryAtPath:d
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
    } @catch (NSException *e) { }
    return d;
}

static NSString *StatePath(void) {
    return [MusicDir() stringByAppendingPathComponent:@(FDMMUSIC_STATE_FILE)];
}

static void MusicLoadState(void) {
    @try {
        NSString *p = StatePath();
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (!d.length) {
            FLOGI(FC_MUSIC, @"[music] 没有存档，从空队列开始");
            return;
        }
        NSString *js = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (!js.length) return;
        int rc = fdmmusic_from_json(&gQ, js.UTF8String);
        FLOGI(FC_MUSIC, @"[music] 存档读了 %d 首（rc=%d idx=%d）",
              (int)gQ.count, rc, gQ.idx);
    } @catch (NSException *e) {
        FLOGE(FC_MUSIC, @"[music] 存档读失败: %@", e.reason);
    }
}

void FDMMusicSaveState(void) {
    if (!gModelInited || gSaving) return;
    gSaving = YES;
    @try {
        char *js = fdmmusic_to_json(&gQ);
        if (js) {
            NSString *s = [NSString stringWithUTF8String:js];
            free(js);
            if (s.length) {
                [s writeToFile:StatePath()
                    atomically:YES
                      encoding:NSUTF8StringEncoding
                         error:NULL];
            }
        }
    } @catch (NSException *e) {
        FLOGE(FC_MUSIC, @"[music] 存档写失败: %@", e.reason);
    }
    gSaving = NO;
}

/* ============================================================
 * 二、配置（Documents/fdm-music.json，5 秒 TTL）
 * ============================================================ */

static void MusicReloadCfg(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gCfgAt > 0 && now - gCfgAt < 5.0) return;
    gCfgAt = now;
    @try {
        NSString *p = [MusicDocs() stringByAppendingPathComponent:@"fdm-music.json"];
        NSData *d = [NSData dataWithContentsOfFile:p];
        id j = nil;
        if (d.length) j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];

        BOOL on = YES, mini = NO, ly = YES, autoplay = NO;
        if ([j isKindOfClass:[NSDictionary class]]) {
            NSDictionary *m = j;
            if (m[@"on"])       on   = [m[@"on"] boolValue];
            if (m[@"mini_on"])  mini = [m[@"mini_on"] boolValue];
            if (m[@"lyric_on"]) ly   = [m[@"lyric_on"] boolValue];
            /* ★ v75：自动播放改成正式配置项（原来藏在 fdm-debug.json 里当调试开关，
             *   主人每次开 App 都被自动放歌，还找不到地方关）。 */
            if (m[@"autoplay"]) autoplay = [m[@"autoplay"] boolValue];
            /* 这几个是偏好的「初始值」，只在第一次启动（还没存档）时生效 */
            if (m[@"vol"] && gQ.vol == 70)          gQ.vol     = fdmmusic_clamp_vol([m[@"vol"] intValue]);
            if (m[@"quality"])                       gQ.quality = [m[@"quality"] intValue];
            if (m[@"repeat"])                        gQ.repeat  = [m[@"repeat"] intValue];
            if (m[@"shuffle"])                       gQ.shuffle = [m[@"shuffle"] boolValue] ? 1 : 0;
        }
        gCfgOn = on;
        gLyricOn = ly;
        gMiniOn = mini;
        gAutoPlay = autoplay;
    } @catch (NSException *e) { }
}

/* ============================================================
 * 三、歌词（只内存）
 * ============================================================ */

static void MusicDropLyric(void) {
    if (gLrcDocReady) { fdmlrc_free(&gLrcDoc); gLrcDocReady = NO; }
    gLrcSongId = -1;
}

static void MusicFetchLyric(long long songId) {
    if (!gLyricOn) return;
    if (gLrcSongId == songId) return;
    MusicDropLyric();
    gLrcSongId = songId;
    [FDMMusicApi lyric:songId completion:^(NSString *lrc, NSString *tlrc, NSError *err) {
        if (err || !lrc.length) return;
        /* ★ 只放内存，绝不落盘（版权） */
        if (gLrcDocReady) { fdmlrc_free(&gLrcDoc); gLrcDocReady = NO; }
        if (fdmlrc_parse(lrc.UTF8String, &gLrcDoc) == 0) gLrcDocReady = YES;
        FLOGD(FC_MUSIC, @"[music] 歌词到手 %lld（%@）", songId,
              gLrcDocReady ? @"已解析" : @"解析失败");   /* 铁律 6：别用 %s 传中文 */
    }];
}

NSString *FDMMusicLyricLine(long long pos_ms, int which) {
    if (!gLrcDocReady) return nil;
    const char *cur = NULL, *prev = NULL, *next = NULL;
    fdmlrc_around(&gLrcDoc, pos_ms, &cur, &prev, &next);
    const char *p = (which == 1) ? prev : (which == 2) ? next : cur;
    if (!p || !*p) return nil;
    return [NSString stringWithUTF8String:p];
}

long long FDMMusicJumpLyric(long long pos_ms, int which) {
    if (!gLrcDocReady) return -1;
    return fdmlrc_line_ms(&gLrcDoc, pos_ms, which);
}

/* ── 全歌词列表（聚焦态用）──
 * ⚠️ 这几个函数返回的指针指向 gLrcDoc 内部，**切歌时整个文档会被 free**。
 *   调用方（迷你卡）必须在切歌时把缓存清掉，否则会读到已释放内存。
 *   约定：缓存键 = 当前曲的 songId，变了就重建。 */

NSInteger FDMMusicLyricCount(void) {
    if (!gLrcDocReady) return 0;
    return (NSInteger)gLrcDoc.count;
}

BOOL FDMMusicLyricAt(NSInteger index, NSString **text, long long *ms) {
    if (!gLrcDocReady || index < 0 || (size_t)index >= gLrcDoc.count) return NO;
    const fdmlrc_line *ln = &gLrcDoc.lines[(size_t)index];
    if (text) *text = ln->text ? [NSString stringWithUTF8String:ln->text] : @"";
    if (ms) *ms = ln->ms;
    return YES;
}

NSInteger FDMMusicLyricIndexAt(long long pos_ms) {
    if (!gLrcDocReady || !gLrcDoc.count) return -1;
    NSInteger idx = -1;
    for (size_t i = 0; i < gLrcDoc.count; i++) {
        if (gLrcDoc.lines[i].ms <= pos_ms) idx = (NSInteger)i;
        else break;
    }
    return idx;
}

/* ============================================================
 * 三·五、播放状态快照（给 {music} / {lyric} 变量供数）
 *
 * 为什么用「快照」而不是让 provider 直接读 gQ：
 *   provider 会在**发消息那一刻**被调，那是网络 hook 线程 ——
 *   而 gQ 只在主线程改。主线程每秒刷几次不可变字典，
 *   读的人拿到的是完整快照，既不用加锁也不会读到半个状态。
 * ============================================================ */

static NSDictionary *gSnap = nil;

static NSString *ms_ns(const char *p) {
    if (!p || !*p) return @"";
    NSString *s = [NSString stringWithUTF8String:p];
    return s ?: @"";
}

static void MusicUpdateSnapshot(void) {
    if (![NSThread isMainThread]) return;
    @try {
        const fdmmusic_track *t = fdmmusic_current(&gQ);

        /* ★★ 2026-10-25 v77 修（主人报的 bug）：
         *   「播放条没内容但是提示词里面塞了红色高跟鞋」
         *
         *   病根：这里只判 `t != NULL`，而队列是**持久化**的
         *   ⇒ 上次听过的歌名一直留在快照里
         *   ⇒ {music} 变量明明没在播也在往里塞歌名
         *
         *   正确语义：**只有真的在出声（或正在缓冲）才给数据**。
         *   停了 / 暂停了 / 没播过 ⇒ song/artist/lyric 全空，
         *   {music} 会被替换成空串，提示词里就不会出现幽灵歌名。 */
        BOOL active = (gQ.state == FDMMS_PLAYING || gQ.state == FDMMS_LOADING);
        BOOL hasCur = (t != NULL) && active;

        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"song"]   = hasCur ? ms_ns(t->name)   : @"";
        d[@"artist"] = hasCur ? ms_ns(t->artist) : @"";
        d[@"album"]  = hasCur ? ms_ns(t->album)  : @"";
        d[@"pos"]    = @(hasCur ? gQ.pos_ms : 0);
        d[@"dur"]    = @(hasCur ? t->duration_ms : 0);
        d[@"playing"] = @(gQ.state == FDMMS_PLAYING);

        NSString *c = nil, *p = nil, *x = nil;
        if (hasCur) {
            c = FDMMusicLyricLine(gQ.pos_ms, 0);
            p = FDMMusicLyricLine(gQ.pos_ms, 1);
            x = FDMMusicLyricLine(gQ.pos_ms, 2);
        }
        d[@"lyric"]      = c ?: @"";
        d[@"lyric_prev"] = p ?: @"";
        d[@"lyric_next"] = x ?: @"";
        gSnap = [d copy];
    } @catch (NSException *e) { }
}

/* ============================================================
 * 四、音频会话
 *
 * ⚠️ 宿主自己有语音输入 / TTS，会在它需要录音时把 category 改成
 *    playAndRecord。我们**只在第一次播放时**设一次 playback，
 *    之后永不改、也永不"恢复" —— 宿主自己会覆盖成它要的。
 *    这样最不打扰，也不会出现「放歌把语音输入弄哑」的血案。
 * ============================================================ */

static void MusicConfigureSessionOnce(void) {
    if (gSessionConfigured) return;
    gSessionConfigured = YES;
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        NSError *e = nil;
        [s setCategory:AVAudioSessionCategoryPlayback error:&e];
        if (e) FLOGW(FC_MUSIC, @"[music] 会话 category 设置失败: %@", e.localizedDescription);
        e = nil;
        [s setActive:YES error:&e];
        if (e) FLOGW(FC_MUSIC, @"[music] 会话激活失败: %@", e.localizedDescription);
    } @catch (NSException *ex) { }
}

/* ============================================================
 * 五、播放核心
 * ============================================================ */

static void MusicApplyVolume(void) {
    @try {
        if (gPlayer) gPlayer.volume = (float)fdmmusic_clamp_vol(gQ.vol) / 100.0f;
    } @catch (NSException *e) { }
}

static void MusicTearDownPlayer(void) {
    @try {
        if (gTimeObs && gPlayer) {
            [gPlayer removeTimeObserver:gTimeObs];
        }
        gTimeObs = nil;
        if (gPlayer) {
            [gPlayer pause];
            /* ⚠️ 不要调 replaceCurrentItemWithPlayerItem:nil（参数是 nonnull，
             *    编译期就报错）。直接放掉引用，ARC 会收尸。 */
            gPlayer = nil;
        }
    } @catch (NSException *e) { }
}

/* 迷你卡刷新（弱依赖：FDMMiniBar.m 提供实现） */
extern void FDMMiniBarRefresh(void);

/* ============================================================
 * 四·五、AVPlayerItem 观察者
 *
 * 为什么要有：真机上「没声音」有五种可能（403 / ATS / 格式不支持 /
 * 地址过期 / 会话没激活）。唯一的区分办法就是读 item.status 和 item.error。
 * ============================================================ */

@interface FDMMusicItemWatch : NSObject
-(instancetype)initWithItem:(AVPlayerItem *)item;
-(void)stop;
@end

@implementation FDMMusicItemWatch {
    AVPlayerItem *_item;
    BOOL _stopped;
}

-(instancetype)initWithItem:(AVPlayerItem *)item {
    self = [super init];
    if (!self) return nil;
    _item = item;
    @try {
        [item addObserver:self forKeyPath:@"status"
                  options:NSKeyValueObservingOptionNew
                  context:NULL];
    } @catch (NSException *e) { }
    return self;
}

-(void)stop {
    if (_stopped) return;
    _stopped = YES;
    @try { [_item removeObserver:self forKeyPath:@"status"]; } @catch (NSException *e) { }
    _item = nil;
}

-(void)dealloc {
    [self stop];
}

-(void)observeValueForKeyPath:(NSString *)kp ofObject:(id)obj
                      change:(NSDictionary *)ch context:(void *)ctx {
    if (![kp isEqualToString:@"status"]) return;
    AVPlayerItem *i = (AVPlayerItem *)obj;
    @try {
        if (i.status == AVPlayerItemStatusFailed) {
            FLOGE(FC_MUSIC, @"[music] ✗ item failed: %@",
                  i.error.localizedDescription ?: @"(无描述)");
        } else if (i.status == AVPlayerItemStatusReadyToPlay) {
            double dur = CMTimeGetSeconds(i.duration);
            if (dur < 0 || dur > 1e9) dur = 0;
            FLOGI(FC_MUSIC, @"[music] item ready，时长 %.1fs", dur);
        } else {
            FLOGD(FC_MUSIC, @"[music] item status=unknown");
        }
    } @catch (NSException *e) { }
}
@end

static void MusicPlayItem(NSString *url, const fdmmusic_track *t) {
    MusicTearDownPlayer();
    MusicConfigureSessionOnce();

    NSURL *u = [NSURL URLWithString:url];
    if (!u) {
        gQ.state = FDMMS_ERROR;
        FLOGE(FC_MUSIC, @"[music] 播放地址不合法");
        return;
    }

    @try {
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:u];
        gPlayer = [AVPlayer playerWithPlayerItem:item];
        gPlayer.automaticallyWaitsToMinimizeStalling = YES;
        MusicApplyVolume();

        /* ★ 盯着 item 的 status：failed 时 error 里就写着真正的原因
         *   （403 / ATS / 格式不支持 / 地址过期）。
         *   没有这一行，真机上只能看到「没声音」，什么都查不出来。 */
        if (gItemObs) { [gItemObs stop]; gItemObs = nil; }
        gItemObs = [[FDMMusicItemWatch alloc] initWithItem:item];

        /* 周期观察：0.5s 更新进度（只在内存，不写盘） */
        __weak AVPlayer *weakP = gPlayer;
        gTimeObs = [gPlayer addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.5, 600)
                                                        queue:dispatch_get_main_queue()
                                                   usingBlock:^(CMTime time) {
            AVPlayer *p = weakP;
            if (!p) return;
            double sec = CMTimeGetSeconds(time);
            if (sec >= 0 && sec < 1e9) gQ.pos_ms = (long long)(sec * 1000.0);
            if (p.timeControlStatus == AVPlayerTimeControlStatusPlaying) {
                if (gQ.state != FDMMS_PLAYING) {
                    gQ.state = FDMMS_PLAYING;
                    FLOGI(FC_MUSIC, @"[music] 状态 → PLAYING");
                }
            }
            /* ★★ 2026-10-24 真机 bug：原来只在「state 刚变成 PLAYING」那一拍刷 UI，
             *   之后再也不刷 ⇒ 进度条/时间/歌词全冻住，看着像没在放。
             *   正确做法：**每一拍都刷**（0.5 秒一次，纯内存操作，很便宜）。 */
            FDMMiniBarRefresh();
            MusicUpdateSnapshot();      /* 给 {music}/{lyric} 变量供数 */
        }];

        /* 播完自动接（token 要留着，下次先拆 —— 不然通知会越攒越多） */
        if (gEndObs) {
            [[NSNotificationCenter defaultCenter] removeObserver:gEndObs];
            gEndObs = nil;
        }
        gEndObs = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                                     object:item
                                                                      queue:[NSOperationQueue mainQueue]
                                                                 usingBlock:^(NSNotification *n) {
            extern void FDMMusicNext(void);
            FLOGI(FC_MUSIC, @"[music] 一首放完了，自动接下一首");
            FDMMusicNext();
        }];

        [gPlayer play];
        gQ.state = FDMMS_LOADING;

        /* 玩家一开播就把「取地址成功」写进日志 —— 但 %s 传中文会变乱码
         * （铁律 6 的现场版：NSLog 的 %s 按系统编码解释，UTF-8 中文全成 Ã…）
         * ⇒ 统一转成 NSString 用 %@ */
        NSString *qn = @(fdmmusic_quality_name(gQ.quality));
        NSString *nm = [NSString stringWithUTF8String:(t && t->name) ? t->name : ""];
        FLOGI(FC_MUSIC, @"[music] ▶ %@（音质 %@）", nm ?: @"", qn);

        if (t) MusicFetchLyric(t->id);
        FDMMusicEnsureCover();      /* 存档不带 pic ⇒ 这里兜底去查 */
        FDMMiniBarRefresh();
    } @catch (NSException *e) {
        gQ.state = FDMMS_ERROR;
        FLOGE(FC_MUSIC, @"[music] 播放异常: %@", e.reason);
    }
}

/* 取地址 → 播。quality 失败就降级重试（最多降 3 档） */
static void MusicResolveAndPlay(long long songId, int tryQuality) {
    const fdmmusic_track *t = fdmmusic_current(&gQ);
    if (!t) { gQ.state = FDMMS_STOPPED; return; }

    gQ.state = FDMMS_LOADING;
    FDMMiniBarRefresh();

    NSString *level = @(fdmmusic_quality_name(tryQuality));
    [FDMMusicApi songUrl:songId level:level
              completion:^(NSString *url, long long br, NSString *type,
                           NSInteger fee, NSError *err) {
        if (!err && url.length) {
            NSString *https = [FDMMusicApi preferHTTPS:url];
            MusicPlayItem(https, fdmmusic_current(&gQ));
            return;
        }

        /* 失败：要么没 VIP，要么这首没这个档 —— 降一档再试 */
        int next = fdmmusic_quality_downgrade(tryQuality);
        if (next != tryQuality) {
            FLOGW(FC_MUSIC, @"[music] %lld 取地址失败（%s），降级到 %s 重试",
                  songId, fdmmusic_quality_name(tryQuality),
                  fdmmusic_quality_name(next));
            MusicResolveAndPlay(songId, next);
        } else {
            gQ.state = FDMMS_ERROR;
            FLOGE(FC_MUSIC, @"[music] %lld 全部档位都取不到播放地址", songId);
            FDMMiniBarRefresh();
        }
    }];
}

static void MusicStartAt(int index) {
    if (index < 0 || (size_t)index >= gQ.count) {
        gQ.state = FDMMS_STOPPED;
        FDMMiniBarRefresh();
        return;
    }
    gQ.idx = index;
    gQ.pos_ms = 0;
    MusicDropLyric();

    const fdmmusic_track *t = &gQ.items[index];
    {
        /* ★ 铁律 6：日志里的字符串永远 %@ 包着，绝不 %s 传 UTF-8 中文。
         *   2026-10-24 真机现场：%s 打出来是 "Á∫¢Ëâ≤È´òË∑üÈûã"（Latin-1 误解 UTF-8）。 */
        NSString *nm = [NSString stringWithUTF8String:(t->name ? t->name : "")];
        FLOGI(FC_MUSIC, @"[music] 切到第 %d 首：%@", index, nm ?: @"");
    }
    MusicResolveAndPlay(t->id, gQ.quality);
    FDMMiniBarRefresh();
}

/* ============================================================
 * 六、对外控制接口
 * ============================================================ */

void FDMMusicPlayIndex(int index) {
    dispatch_async(dispatch_get_main_queue(), ^{
        MusicStartAt(index);
        FDMMusicSaveState();
    });
}

void FDMMusicTogglePlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (gQ.state == FDMMS_PLAYING) {
                [gPlayer pause];
                gQ.state = FDMMS_PAUSED;
                FDMMusicSaveState();
            } else if (gQ.state == FDMMS_PAUSED && gPlayer) {
                MusicConfigureSessionOnce();
                [gPlayer play];
                gQ.state = FDMMS_PLAYING;
            } else if (gQ.count > 0) {
                MusicStartAt(gQ.idx < 0 ? 0 : gQ.idx);
            }
            FDMMiniBarRefresh();
        } @catch (NSException *e) { }
    });
}

void FDMMusicPause(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (gPlayer && gQ.state == FDMMS_PLAYING) {
                [gPlayer pause];
                gQ.state = FDMMS_PAUSED;
                FDMMusicSaveState();
                FDMMiniBarRefresh();
            }
        } @catch (NSException *e) { }
    });
}

void FDMMusicResume(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (gPlayer && gQ.state == FDMMS_PAUSED) {
                MusicConfigureSessionOnce();
                [gPlayer play];
                gQ.state = FDMMS_PLAYING;
                FDMMiniBarRefresh();
            }
        } @catch (NSException *e) { }
    });
}

void FDMMusicNext(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        int k = fdmmusic_next_index(&gQ, 0);
        if (k < 0) {
            /* 到尾巴了：停，但队列留着 */
            [gPlayer pause];
            gQ.state = FDMMS_STOPPED;
            gQ.pos_ms = 0;
            FDMMusicSaveState();
            FDMMiniBarRefresh();
            return;
        }
        MusicStartAt(k);
        FDMMusicSaveState();
    });
}

void FDMMusicPrev(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        int k = fdmmusic_prev_index(&gQ);
        if (k < 0) return;
        MusicStartAt(k);
        FDMMusicSaveState();
    });
}

void FDMMusicSeek(long long pos_ms) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!gPlayer) return;
            long long p = (pos_ms < 0) ? 0 : pos_ms;
            gQ.pos_ms = p;
            [gPlayer seekToTime:CMTimeMakeWithSeconds((double)p / 1000.0, 600)
              toleranceBefore:kCMTimeZero
                 toleranceAfter:kCMTimeZero];
            FDMMiniBarRefresh();
        } @catch (NSException *e) { }
    });
}

void FDMMusicSetVolume(int vol) {
    gQ.vol = fdmmusic_clamp_vol(vol);
    dispatch_async(dispatch_get_main_queue(), ^{
        MusicApplyVolume();
        FDMMiniBarRefresh();
    });
}

void FDMMusicSetRepeat(int repeat) {
    if (repeat < FDMMR_OFF) repeat = FDMMR_ALL;
    if (repeat > FDMMR_ONE) repeat = FDMMR_OFF;
    gQ.repeat = repeat;
    FLOGI(FC_MUSIC, @"[music] 循环模式 → %d", repeat);
    FDMMiniBarRefresh();
    FDMMusicSaveState();
}

void FDMMusicToggleShuffle(void) {
    gQ.shuffle = gQ.shuffle ? 0 : 1;
    FLOGI(FC_MUSIC, @"[music] 随机 → %d", gQ.shuffle);
    FDMMiniBarRefresh();
    FDMMusicSaveState();
}

void FDMMusicAction(int action, long long arg) {
    switch (action) {
        case 0: FDMMusicTogglePlay(); break;
        case 1: FDMMusicNext(); break;
        case 2: FDMMusicPrev(); break;
        case 3: FDMMusicSeek(arg); break;
        case 4: FDMMusicSetVolume((int)arg); break;
        case 5: FDMMusicPlayIndex((int)arg); break;
        case 6: FDMMusicSetRepeat(fdmmusic_repeat_next(gQ.repeat)); break;
        case 7: FDMMusicToggleShuffle(); break;
        default: break;
    }
}

int FDMMusicSetQueueRaw(const fdmmusic_track *items, unsigned long n, int start) {
    if (!items || n == 0 || !gModelInited) return -1;
    /* ⚠️ 必须同步：调用方（迷你卡的表格回调）返回后就会 free(items)。
     *    所以这里不做 dispatch_async —— 直接在主线程当场深拷贝。 */
    if (![NSThread isMainThread]) {
        FLOGW(FC_MUSIC, @"[music] SetQueueRaw 不在主线程，拒绝（避免用已释放的内存）");
        return -1;
    }
    int rc = fdmmusic_set_queue(&gQ, items, (size_t)n, start);
    if (rc != 0) {
        FLOGE(FC_MUSIC, @"[music] 入队失败");
        return rc;
    }
    FLOGI(FC_MUSIC, @"[music] 入队 %lu 首，从第 %d 首开始", n, start);
    MusicStartAt(start);
    FDMMusicSaveState();
    return 0;
}


/* ============================================================
 * 七、供数（{music} / {lyric} / 点歌）
 * ============================================================ */

BOOL FDMMusicActive(void) { return fdmmusic_is_active(&gQ); }

const fdmmusic_queue *FDMMusicQueue(void) { return &gQ; }

void FDMMusicNowPlaying(NSString **song, NSString **artist) {
    BOOL active = (gQ.state == FDMMS_PLAYING || gQ.state == FDMMS_LOADING);
    const fdmmusic_track *t = active ? fdmmusic_current(&gQ) : NULL;
    if (song)   *song   = (t && t->name)   ? [NSString stringWithUTF8String:t->name]   : nil;
    if (artist) *artist = (t && t->artist) ? [NSString stringWithUTF8String:t->artist] : nil;
}

/* ============================================================
 * 七·五、封面补拉
 *
 * ★ 2026-10-24 真机 bug：`state.json` **故意不存 pic**（版权红线：封面只放内存），
 *   所以从存档恢复的队列 pic 全是空串 ⇒ 迷你卡一片灰，没有封面。
 *   解法：没有 pic 就按 songId 查一次 songDetail 补回来 —— **只放内存，永不落盘**。
 *   已经拉过的 id 记在 gCoverTried 里，避免疯狂重查。
 * ============================================================ */

static long long gCoverTriedId = -1;

void FDMMusicEnsureCover(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ FDMMusicEnsureCover(); });
        return;
    }
    const fdmmusic_track *t = fdmmusic_current(&gQ);
    if (!t) return;
    if (t->pic && t->pic[0]) return;               /* 已经有封面地址了 */
    if (gCoverTriedId == t->id) return;            /* 这个 id 刚查过 */
    gCoverTriedId = t->id;

    long long sid = t->id;
    FLOGD(FC_MUSIC, @"[music] 队列里没有封面地址（存档不存 pic）⇒ 查详情补 %lld", sid);
    [FDMMusicApi songDetail:@[ @(sid) ]
                 completion:^(NSArray *tracks, NSError *err) {
        if (err || !tracks.count) {
            gCoverTriedId = -1;
            return;
        }
        id o = tracks.firstObject;
        if (![o isKindOfClass:[FDMMusicTrack class]]) { gCoverTriedId = -1; return; }
        FDMMusicTrack *x = o;
        if (!x.picUrl.length) { gCoverTriedId = -1; return; }

        /* 补进队列（只内存）。注意：可能这时已经切歌了，要按 id 找 */
        int at = fdmmusic_find(&gQ, sid);
        if (at >= 0) {
            char *p = strdup(x.picUrl.UTF8String);
            if (p) {
                free(gQ.items[at].pic);
                gQ.items[at].pic = p;
                FLOGD(FC_MUSIC, @"[music] 封面地址补上了（队列第 %d 首）", at);
            }
        }
        FDMMiniBarRefresh();
    }];
}

NSString *FDMMusicNowPlayingLine(void) {
    /* ★ v77：没在播就不给（否则提示词里会塞"幽灵歌名"） */
    if (gQ.state != FDMMS_PLAYING && gQ.state != FDMMS_LOADING) return nil;
    const fdmmusic_track *t = fdmmusic_current(&gQ);
    if (!t || !t->name) return nil;
    NSString *n = [NSString stringWithUTF8String:t->name];
    NSString *a = t->artist ? [NSString stringWithUTF8String:t->artist] : @"";
    if (!a.length) return [NSString stringWithFormat:@"%@", n];
    return [NSString stringWithFormat:@"%@ - %@", n, a];
}

void FDMMusicSearch(NSString *keyword, void (^done)(NSArray *tracks)) {
    if (!keyword.length) { if (done) done(@[]); return; }
    [FDMMusicApi search:keyword limit:20 offset:0 completion:^(NSArray *tracks, NSError *err) {
        if (done) done(err ? @[] : (tracks ?: @[]));
    }];
}

void FDMMusicPlayByKeyword(NSString *keyword, void (^completion)(BOOL ok, NSString *msg)) {
    if (!keyword.length) {
        if (completion) completion(NO, @"空关键词");
        return;
    }
    /* 「歌名-歌手」→ 搜索关键词就用原文（网易云对 ' - ' 很宽容，安卓同款做法） */
    NSString *kw = [keyword stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    FLOGI(FC_MUSIC, @"[music] 点歌：%@", kw);

    [FDMMusicApi search:kw limit:10 offset:0 completion:^(NSArray *tracks, NSError *err) {
        if (err || !tracks.count) {
            FLOGW(FC_MUSIC, @"[music] 点歌搜不到：%@", kw);
            if (completion) completion(NO, @"搜不到这首歌");
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            /* 搜索结果整批进队列，从第一首开始放（安卓约定：搜不到就用默认第一首） */
            size_t n = tracks.count;
            fdmmusic_track *arr = (fdmmusic_track *)calloc(n, sizeof(fdmmusic_track));
            if (!arr) { if (completion) completion(NO, @"内存不足"); return; }

            NSMutableArray *keep = [NSMutableArray array];   /* 持有 UTF8 指针的宿主 */
            for (size_t i = 0; i < n; i++) {
                FDMMusicTrack *t = tracks[i];
                if (![t isKindOfClass:[FDMMusicTrack class]]) continue;
                NSString *nm = t.name ?: @"";
                NSString *ar = t.artist ?: @"";
                NSString *al = t.album ?: @"";
                NSString *pc = t.picUrl ?: @"";
                [keep addObject:@[nm, ar, al, pc]];
                arr[i].id = t.songId;
                arr[i].name = (char *)nm.UTF8String;
                arr[i].artist = (char *)ar.UTF8String;
                arr[i].album = (char *)al.UTF8String;
                arr[i].pic = (char *)pc.UTF8String;
                arr[i].duration_ms = t.duration;
                arr[i].fee = (int)t.fee;
            }
            fdmmusic_set_queue(&gQ, arr, n, 0);
            free(arr);
            (void)keep;

            MusicStartAt(0);
            FDMMusicSaveState();
            if (!gOpen) FDMMusicShowMiniBar(YES);

            FDMMusicTrack *first = tracks.firstObject;
            if (completion)
                completion(YES, [NSString stringWithFormat:@"%@ - %@",
                                 first.name ?: @"", first.artist ?: @""]);
        });
    }];
}

/* ============================================================
 * 八、迷你卡的开关（真正的 UI 在 FDMMiniBar.m）
 * ============================================================ */

extern void FDMMiniBarShow(void);
extern void FDMMiniBarHide(void);
extern BOOL FDMMiniBarIsVisible(void);

void FDMMusicShowMiniBar(BOOL on) {
    gOpen = on;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (on) FDMMiniBarShow();
        else    FDMMiniBarHide();
    });
}

BOOL FDMMusicMiniBarVisible(void) { return FDMMiniBarIsVisible(); }

/* ============================================================
 * 九、巡检
 * ============================================================ */

void FDMMusicTick(void) {
    if (!gReady) return;
    MusicReloadCfg();
    MusicUpdateSnapshot();

    /* 每 10 拍（约 5 秒）巡一次迷你卡的挂载（宿主切页后 window 可能换掉） */
    gTickCount++;
    if ((gTickCount % 10) == 0) {
        if (gOpen && !FDMMiniBarIsVisible()) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (gOpen) FDMMiniBarShow(); });
        }
    }

    /* 每 60 拍（约 30 秒）落一次进度，避免每秒写盘 */
    if ((gTickCount % 60) == 0 && gQ.count > 0 && gQ.state != FDMMS_STOPPED) {
        FDMMusicSaveState();
    }
}

/* ============================================================
 * 十、安装
 * ============================================================ */

void FDMMusicReload(void) {
    gCfgAt = 0;
    MusicReloadCfg();
    MusicApplyVolume();
    FDMMiniBarRefresh();
}

void FDMMusicInstall(void) {
    if (gInstalled) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ FDMMusicInstall(); });
        return;
    }
    gInstalled = YES;
    gReady = YES;

    /* ① 内核自检（47 条断言）—— 失败就整个不启用，宁可没音乐也不崩 */
    {
        char err[512] = {0};
        int bad = fdmmusic_selftest(err, sizeof(err));
        if (bad) {
            FLOGE(FC_MUSIC, @"[music] 内核自检失败 #%d：%s ⇒ 音乐功能停用", bad, err);
            gReady = NO;
            return;
        }
        FLOGI(FC_MUSIC, @"[music] 内核自检 47 条全过");
    }

    /* ② 队列 + 偏好 + 存档 */
    fdmmusic_init(&gQ);
    gModelInited = YES;
    MusicReloadCfg();
    MusicLoadState();
    if (!gCfgOn) {
        FLOGI(FC_MUSIC, @"[music] 配置里关着（on=false），不启用");
        gReady = NO;
        return;
    }

    /* ③ 迷你卡：配置开着就挂 */
    if (gMiniOn) {
        gOpen = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gOpen) FDMMiniBarShow();
        });
    }

    /* ④ 把「此刻在听什么」接给提示词变量引擎
     *    （引擎 FDMPromptVars.c 早就移植好并过了 20 条断言，
     *      但一直没人给它供数 —— 所以 {music}/{lyric} 之前永远是空的） */
    extern void FDMPromptVarsSetProvider(NSDictionary *(^provider)(void));
    extern void FDMPromptVarsReload(void);
    FDMPromptVarsSetProvider(^NSDictionary *(void) {
        return gSnap ?: @{};
    });
    FDMPromptVarsReload();
    MusicUpdateSnapshot();

    /* ⑤ 巡检定时器（2 秒一拍）
     *    只干三件轻活：读配置 / 刷快照 / 看迷你卡还在不在。
     *    ⚠️ 铁律 1：定时器里绝不做 IO、绝不等网络。 */
    if (!gTickTimer) {
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_main_queue());
        if (t) {
            dispatch_source_set_timer(t,
                                      dispatch_time(DISPATCH_TIME_NOW, 2ull * NSEC_PER_SEC),
                                      2ull * NSEC_PER_SEC,
                                      300ull * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(t, ^{ FDMMusicTick(); });
            dispatch_resume(t);
            gTickTimer = t;
        }
    }

    /* ⑥ 自动播放（★ v75：从"调试开关"升级成正式配置项）
     *
     * 原来这个开关藏在 Documents/fdm-debug.json 的 `music_autoplay` 里 ——
     * 那是我调试播放链路时用的，主人根本找不到地方关，还每次开 App 都被自动放歌。
     *
     * 现在：设置 → 美化 → 音乐播放 → 「打开 App 自动播放」（默认关）。
     * 语义：开 ⇒ 接着上次那首放（用存档里的 idx），不从头开始。 */
    if (gAutoPlay && gQ.count > 0) {
        FLOGI(FC_MUSIC, @"[music] 自动播放已开 ⇒ 3 秒后播第 %d 首（存档里的）",
              gQ.idx < 0 ? 0 : gQ.idx);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            /* 用存档里的 idx 而不是 0 —— 「接着上次放」比「从头放」合理 */
            int at = gQ.idx;
            if (at < 0 || (size_t)at >= gQ.count) at = 0;
            MusicStartAt(at);
        });
    } else if (gQ.count > 0) {
        FLOGI(FC_MUSIC, @"[music] 自动播放关着（要自己点播放）");
    }

    FLOGI(FC_MUSIC, @"[music] ✓ 安装完成（%d 首 / 音量 %d / 音质 %s / 迷你卡 %@ / 自动播放 %@）",
          (int)gQ.count, gQ.vol, fdmmusic_quality_name(gQ.quality),
          gMiniOn ? @"开" : @"关", gAutoPlay ? @"开" : @"关");
}
