/* ============================================================
 * FLog —— 统一日志框架（v2 · async-signal-safe 版）
 *
 * ⚠️ v1 的致命缺陷（2026-10-17 主人指出）：
 *     signal handler 里调用 DoFlush()，而 DoFlush 用了
 *     NSMutableArray / NSFileHandle / @try —— 这些全是
 *     **async-signal-UNSAFE**。
 *     崩溃时 malloc 锁往往已经在死掉的那个线程手里，
 *     再进 signal handler 调 Foundation ⇒ **死锁或二次崩溃**
 *     ⇒ 崩溃现场一条日志都写不下来。
 *
 * v2 做法（纯 C + POSIX）：
 *   • 日志先进一块 static char 缓冲区（memcpy，无 malloc）
 *   • 超过 8KB 或每 300ms 用 write(2) 落盘（write 是 signal-safe）
 *   • signal handler 里只做「trylock + write + 重置」，
 *     绝不再碰任何 Foundation 对象
 *   • 另外保留一个 NSMutableArray 环形缓冲，仅供设置页「查看日志」
 *
 * 铁律：
 *   • Hook 内只做内存 append，绝不 IO（这里用缓冲满足）
 *   • 刷盘用 static dispatch_source_t 保活
 *   • 崩溃时尽力 flush
 * ============================================================ */

#import "FLog.h"
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <pthread.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
#include <time.h>
#include <sys/time.h>
#include <errno.h>

/* ---- 关键参数 ---- */
#define CBUF_SIZE     (64 * 1024)     /* C 缓冲：64KB，够 300ms 的量 */
#define FLUSH_BYTES   (8 * 1024)      /* 超过 8KB 立刻落盘 */
#define FLUSH_EVERY   0.3             /* 定时刷盘间隔（秒） */
#define ROTATE_BYTES  (4 * 1024 * 1024)
#define UI_RING_MAX   3000            /* 设置页查看用的环形条数 */

/* ==================== 状态 ==================== */

static NSString      *gDir     = nil;
static NSString      *gLogPath = nil;
static FLogLevel      gLevel   = FLogLevelWarn;
static BOOL           gAllCats = YES;
static NSMutableSet  *gCats    = nil;
static BOOL           gMirror  = NO;
static volatile unsigned long gTotal = 0;

/* ---- C 缓冲（async-signal-safe 区） ---- */
static char            gCBuf[CBUF_SIZE];
static size_t          gCLen = 0;
static int             gFd   = -1;
static pthread_mutex_t gCLock = PTHREAD_MUTEX_INITIALIZER;
static volatile int    gInSignal = 0;

/* ---- UI 环形缓冲（非 signal-safe，仅给设置页看） ---- */
static NSMutableArray<NSString *> *gRing = nil;
static NSUInteger gRingHead = 0;
static pthread_mutex_t gRingLock = PTHREAD_MUTEX_INITIALIZER;

/* ==================== 工具 ==================== */

static inline const char *LvlName(FLogLevel l) {
    switch (l) {
        case FLogLevelError: return "E";
        case FLogLevelWarn:  return "W";
        case FLogLevelInfo:  return "I";
        case FLogLevelDebug: return "D";
        default:             return "T";
    }
}
static BOOL CatAllowed(const char *c) {
    if (gAllCats || !gCats) return YES;
    if (!c) return NO;
    return [gCats containsObject:[NSString stringWithUTF8String:c]];
}

NSString *FLogPath(void) { return gLogPath; }
NSUInteger FLogTotal(void) { return (NSUInteger)gTotal; }
void FLogSetLevel(FLogLevel lv) { gLevel = lv; }
void FLogSetMirrorNSLog(BOOL on) { gMirror = on; }

/* ============================================================
 * ★★★ 日志级别热切换（2026-10-17 深夜）
 *
 *   以前改 log_level 必须：改 fdm-debug.json → 重启 App。
 *   而且那个 json 归 FDMConfig 管，UI 一保存就有可能被回写覆盖。
 *
 *   ⇒ 现在 FLog 自己每 2 秒 stat 一个独立小文件：
 *        Documents/fdm-log.txt     内容就一个字母：E / W / I / D / T
 *     文件 mtime 变了才读，读到的级别立刻生效（不用重启）。
 *     顺手支持：Documents/fdm-cats.txt   逗号分隔的分类白名单
 *
 *   成本：每 2 秒一次 stat(2)，别的不做。7P 上完全无感。
 * ============================================================ */
static void WatchLevelFile(void) {
    static time_t lastMt = 0;
    static time_t lastCatMt = 0;
    @autoreleasepool {
        if (!gDir) return;
        NSFileManager *fm = [NSFileManager defaultManager];

        NSString *lvPath = [gDir stringByAppendingPathComponent:@"fdm-log.txt"];
        NSDictionary *at = [fm attributesOfItemAtPath:lvPath error:NULL];
        if (at) {
            time_t mt = (time_t)[at[NSFileModificationDate] timeIntervalSince1970];
            if (mt != lastMt) {
                lastMt = mt;
                NSString *v = [[NSString stringWithContentsOfFile:lvPath
                                                         encoding:NSUTF8StringEncoding
                                                            error:NULL]
                               stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (v.length) {
                    unichar c = [v characterAtIndex:0];
                    FLogLevel lv = gLevel;
                    if (c == 'E' || c == 'e') lv = FLogLevelError;
                    else if (c == 'W' || c == 'w') lv = FLogLevelWarn;
                    else if (c == 'I' || c == 'i') lv = FLogLevelInfo;
                    else if (c == 'D' || c == 'd') lv = FLogLevelDebug;
                    else if (c == 'T' || c == 't') lv = FLogLevelTrace;
                    gLevel = lv;
                    FLOGW(FC_SYS, @"[log] 级别热切到 %s（来自 fdm-log.txt）", LvlName(lv));
                }
            }
        }

        NSString *catPath = [gDir stringByAppendingPathComponent:@"fdm-cats.txt"];
        NSDictionary *ct = [fm attributesOfItemAtPath:catPath error:NULL];
        if (ct) {
            time_t mt = (time_t)[ct[NSFileModificationDate] timeIntervalSince1970];
            if (mt != lastCatMt) {
                lastCatMt = mt;
                NSString *csv = [NSString stringWithContentsOfFile:catPath
                                                          encoding:NSUTF8StringEncoding
                                                             error:NULL];
                csv = [csv stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                FLogSetCategories(csv);
                FLOGW(FC_SYS, @"[log] 分类过滤 →「%@」", csv.length ? csv : @"(全部)");
            }
        }
    }
}

void FLogSetCategories(NSString *csv) {
    if (!csv.length) { gAllCats = YES; return; }
    gAllCats = NO;
    if (!gCats) gCats = [NSMutableSet set];
    gCats = [[NSMutableSet alloc] init];
    for (NSString *s in [csv componentsSeparatedByString:@","]) {
        NSString *t = [s stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [gCats addObject:t];
    }
}

/* ==================== 核心：写入 C 缓冲 ==================== */

/* 必须在持有 gCLock 时调用 */
static void RawFlushLocked(void) {
    if (gCLen == 0 || gFd < 0) { gCLen = 0; return; }
    ssize_t off = 0;
    while (off < (ssize_t)gCLen) {
        ssize_t w = write(gFd, gCBuf + off, gCLen - off);
        if (w <= 0) break;
        off += w;
    }
    gCLen = 0;
}

/* async-signal-safe：只用 memcpy + write */
static void RawAppend(const char *s, size_t n) {
    if (!s || n == 0) return;

    /* signal 内不要抢锁：trylock 失败就直接放弃（保命优先） */
    if (gInSignal) {
        if (pthread_mutex_trylock(&gCLock) != 0) return;
    } else {
        pthread_mutex_lock(&gCLock);
    }

    if (gCLen + n > CBUF_SIZE) RawFlushLocked();
    if (n <= CBUF_SIZE) {
        memcpy(gCBuf + gCLen, s, n);
        gCLen += n;
        if (gCLen >= FLUSH_BYTES) RawFlushLocked();
    }
    pthread_mutex_unlock(&gCLock);
}

/* ==================== 对外写日志 ==================== */

void FLogWrite(const char *cat, FLogLevel lv, NSString *fmt, ...) {
    if (lv > gLevel) return;
    if (!CatAllowed(cat)) return;

    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        if (!msg) return;

        /* 时间戳 */
        struct timeval tv;
        gettimeofday(&tv, NULL);
        struct tm tmv;
        time_t sec = tv.tv_sec;
        localtime_r(&sec, &tmv);

        char line[1200];
        int n = snprintf(line, sizeof(line),
                         "%02d:%02d:%02d.%03d [%s][%s] %s\n",
                         tmv.tm_hour, tmv.tm_min, tmv.tm_sec,
                         (int)(tv.tv_usec / 1000),
                         LvlName(lv), cat ? cat : "-",
                         msg.UTF8String ?: "");
        if (n <= 0) return;
        if (n >= (int)sizeof(line)) n = (int)sizeof(line) - 1;

        /* ① 落盘缓冲（signal-safe） */
        RawAppend(line, (size_t)n);

        /* ② UI 环形缓冲 */
        NSString *uiLine = [[NSString alloc] initWithBytes:line length:(NSUInteger)n
                                                   encoding:NSUTF8StringEncoding];
        if (uiLine) {
            pthread_mutex_lock(&gRingLock);
            if (gRing) {
                if (gRing.count < UI_RING_MAX) [gRing addObject:uiLine];
                else { gRing[gRingHead] = uiLine; gRingHead = (gRingHead + 1) % UI_RING_MAX; }
            }
            pthread_mutex_unlock(&gRingLock);
        }

        if (gMirror) NSLog(@"[FDM] %s", line);
        gTotal++;
    }
}

/* ==================== 刷盘 ==================== */

void FLogFlush(void) {
    if (gInSignal) return;            /* signal 内不走这条（会动 Foundation） */
    pthread_mutex_lock(&gCLock);
    RawFlushLocked();
    pthread_mutex_unlock(&gCLock);
}

NSString *FLogRecent(NSUInteger maxLines) {
    NSMutableString *m = [NSMutableString string];
    pthread_mutex_lock(&gRingLock);
    if (gRing && gRing.count) {
        NSUInteger total = gRing.count;
        NSUInteger n = maxLines ? MIN(maxLines, total) : total;
        NSUInteger firstIdx = (total < UI_RING_MAX) ? 0 : gRingHead;
        NSUInteger skip = total - n;
        for (NSUInteger i = 0; i < n; i++) {
            NSUInteger idx = (firstIdx + skip + i) % total;
            NSString *l = gRing[idx];
            if (l) [m appendFormat:@"%@", l];      /* 行尾已带 \n */
        }
    }
    pthread_mutex_unlock(&gRingLock);
    return m;
}

/* ==================== 崩溃处理 ==================== */

/* ⚠️ 这里只允许 async-signal-safe 调用：write / signal / raise / _exit */
static void FLogSignalHandler(int sig) {
    gInSignal = 1;

    /* 直接写（trylock 拿不到就裸写，可能部分覆盖但总比没有强） */
    if (pthread_mutex_trylock(&gCLock) == 0) {
        RawFlushLocked();
        pthread_mutex_unlock(&gCLock);
    } else if (gFd >= 0 && gCLen > 0) {
        /* 裸写：不对缓冲做任何修改，只是尽力把已有内容吐出去 */
        ssize_t off = 0;
        while (off < (ssize_t)gCLen) {
            ssize_t w = write(gFd, gCBuf + off, gCLen - off);
            if (w <= 0) break;
            off += w;
        }
    }

    /* 标记崩溃点（也写进日志文件，方便一眼看到） */
    if (gFd >= 0) {
        char note[128];
        int n = snprintf(note, sizeof(note),
                         "\n===== CRASH signal=%d (%s) =====\n",
                         sig,
                         sig == SIGSEGV ? "SIGSEGV" :
                         sig == SIGBUS  ? "SIGBUS"  :
                         sig == SIGABRT ? "SIGABRT" :
                         sig == SIGILL  ? "SIGILL"  :
                         sig == SIGFPE  ? "SIGFPE"  :
                         sig == SIGTRAP ? "SIGTRAP" : "?");
        if (n > 0) write(gFd, note, (size_t)n);
    }

    /* 恢复默认并自杀，让系统生成 .ips 崩溃日志 */
    signal(sig, SIG_DFL);
    raise(sig);
}

static void InstallCrashHandler(void) {
    static const int sigs[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP };
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = FLogSignalHandler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_RESETHAND;      /* 只处理一次 */
        sigaction(sigs[i], &sa, NULL);
    }
}

/* ==================== 初始化 ==================== */

void FLogInit(void) {
    static BOOL once = NO;
    if (once) return;
    once = YES;

    @autoreleasepool {
        NSArray *a = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES);
        gDir = [a firstObject] ?: NSTemporaryDirectory();
        gLogPath = [gDir stringByAppendingPathComponent:@"fdm.log"];

        /* ★ 打开 fd（O_APPEND 保证多线程/崩溃后写入不覆盖） */
        gFd = open([gLogPath fileSystemRepresentation],
                   O_WRONLY | O_CREAT | O_APPEND, 0644);

        gRing = [NSMutableArray arrayWithCapacity:UI_RING_MAX];

        /* ★ 刷盘定时器：static 保活 */
        static dispatch_source_t flusher;
        flusher = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                         dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(flusher,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(FLUSH_EVERY * NSEC_PER_SEC)),
            (uint64_t)(FLUSH_EVERY * NSEC_PER_SEC),
            (uint64_t)(0.05 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(flusher, ^{
            FLogFlush();
            /* 每 2 秒瞄一眼级别文件（0.3s × 7 ≈ 2.1s） */
            static int tick = 0;
            if (++tick >= 7) { tick = 0; WatchLevelFile(); }
        });
        dispatch_resume(flusher);

        InstallCrashHandler();
    }
}
