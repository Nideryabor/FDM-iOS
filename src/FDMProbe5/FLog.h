// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用

/* ============================================================
 * FLog —— FDM 统一日志框架
 *
 * 设计目标：既有细粒度日志便于排查，又绝不影响宿主性能/稳定性。
 *
 * 铁律（来自本项目的血泪史）：
 *   • Hook 内只做内存 append，绝不做 IO / 绝不调宿主方法
 *   • 刷盘用 static dispatch_source_t 保活（v0.7 的 bug：局部变量被 ARC 释放）
 *   • 崩溃时信号处理里 flush（尽力而为）
 *   • 单文件 4MB 轮转，不撑爆沙盒
 * ============================================================ */
#ifndef FLOG_H
#define FLOG_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, FLogLevel) {
    FLogLevelError = 0,
    FLogLevelWarn  = 1,
    FLogLevelInfo  = 2,
    FLogLevelDebug = 3,
    FLogLevelTrace = 4,
};

/* 分类（module）—— 常量字符串，方便 grep */
#define FC_MMKV    "mmkv"
#define FC_NET     "net"
#define FC_INJECT  "inject"
#define FC_UI      "ui"
#define FC_CFG     "cfg"
#define FC_HOOK    "hook"
#define FC_SYS     "sys"
#define FC_MUSIC   "music"
#define FC_CALL    "call"

void FLogInit(void);                             /* 在构造函数里调一次 */
void FLogSetLevel(FLogLevel lv);                 /* 默认 Debug */
void FLogSetCategories(NSString *csv);           /* 逗号分隔；空=全部 */
void FLogSetMirrorNSLog(BOOL on);                /* 同时打 NSLog（默认关） */

void FLogWrite(const char *cat, FLogLevel lv, NSString *fmt, ...) NS_FORMAT_FUNCTION(3,4);
void FLogFlush(void);

NSString *FLogRecent(NSUInteger maxLines);       /* 供 UI 查看（最近 N 行） */
NSString *FLogPath(void);                        /* 主日志文件路径 */
NSUInteger FLogTotal(void);                      /* 累计条数 */

#define FLOGE(cat, ...) FLogWrite(cat, FLogLevelError, __VA_ARGS__)
#define FLOGW(cat, ...) FLogWrite(cat, FLogLevelWarn,  __VA_ARGS__)
#define FLOGI(cat, ...) FLogWrite(cat, FLogLevelInfo,  __VA_ARGS__)
#define FLOGD(cat, ...) FLogWrite(cat, FLogLevelDebug, __VA_ARGS__)
#define FLOGT(cat, ...) FLogWrite(cat, FLogLevelTrace, __VA_ARGS__)

#endif /* FLOG_H */
