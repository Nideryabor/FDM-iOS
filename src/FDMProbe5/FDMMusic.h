// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMMusic —— iOS 版音乐播放器（宿主进程内，AVPlayer）
//
// 对标安卓 `bridge/GmMusicPlayer.java`（800 行）+ `GmMusicLogin`（265 行）里
// **播放与登录态**的部分；纯逻辑已经在 FDMMusicModel.c 里单测过了，这里只做：
//   ① AVPlayer 播/停/跳/音量/循环
//   ② 音质失败自动降级重试（lossless → exhigh → higher → standard）
//   ③ 歌词拉取（**只放内存**，永不落盘）
//   ④ state.json 存档（只存事实性元数据）
//   ⑤ 给点歌 / {music} 变量提供「此刻在放什么」
//
// ★ 与安卓最大的结构差异
//     安卓：播放器跑在**模块自己的进程**（MusicService），迷你条在宿主进程，靠广播说话。
//     iOS ：没有独立进程 —— 全在宿主进程里，直接读内存，**不需要任何广播**。
//           代价：宿主被杀 = 停播（安卓也一样，只是解耦一点）。
//
// ★ 版权红线（与安卓一致，务必遵守）
//     音频流式播放不落盘 / 封面只内存 / 歌词只内存 / 存档只有元数据。
#ifndef FDM_MUSIC_H
#define FDM_MUSIC_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/** 装到主线程调用（内部会自检 47 条断言 + 读存档）。 */
void FDMMusicInstall(void);

/** 配置改了就调它（音量/音质/循环/开关）。 */
void FDMMusicReload(void);

/** 巡检：进度刷新 + 迷你卡挂载 + 自动接下一首兜底。由 FDMProbe 的定时器驱动。 */
void FDMMusicTick(void);

/** 是否正在出声/缓冲。 */
BOOL FDMMusicActive(void);

/* ── 播放控制（都可在任意线程调，内部切主线程） ── */

/** 播放队列第 index 首。 */
void FDMMusicPlayIndex(int index);

/** 播/暂停切换。 */
void FDMMusicTogglePlay(void);
void FDMMusicPause(void);
void FDMMusicResume(void);
void FDMMusicNext(void);
void FDMMusicPrev(void);
void FDMMusicSeek(long long pos_ms);
void FDMMusicSetVolume(int vol);
void FDMMusicSetRepeat(int repeat);
void FDMMusicToggleShuffle(void);

/* ── 点歌 / 变量供数 ── */

/** 「正在听：歌名 - 歌手」，没在放则 nil。给 {music} 变量用。 */
NSString *FDMMusicNowPlayingLine(void);

/** 当前曲名/歌手（任一可为 nil）。 */
void FDMMusicNowPlaying(NSString **song, NSString **artist);

/** 当前歌词里 pos_ms 附近的那一句（which: 0=当前 1=上一句 2=下一句）。没在放则 nil。 */
NSString *FDMMusicLyricLine(long long pos_ms, int which);

/**
 * 取「某一句歌词」的时间戳（点歌词跳转用）。
 * @param which 0=当前 1=上一句 2=下一句
 * @return 毫秒；没有这一句返回 -1
 */
long long FDMMusicJumpLyric(long long pos_ms, int which);

/* ── 给「全歌词列表」用的接口（聚焦态滚动 / 长按跳转）── */

/** 歌词总行数（没歌词返回 0）。 */
NSInteger FDMMusicLyricCount(void);

/** 第 index 行的文字和时间戳。返回 NO = 没有这一行。 */
BOOL FDMMusicLyricAt(NSInteger index, NSString **text, long long *ms);

/** pos_ms 时刻对应的行号（-1 = 前奏，还没唱）。 */
NSInteger FDMMusicLyricIndexAt(long long pos_ms);

/**
 * 点歌：按「歌名-歌手」搜索并**播第一首**。
 * 安卓的约定：搜不到就用默认结果第一首；这里一样，搜到空则回调 NO。
 * @param completion 主线程回调（可能被调多次？不，只调一次）
 */
void FDMMusicPlayByKeyword(NSString *keyword, void (^completion)(BOOL ok, NSString *msg));

/** 迷你卡显示/隐藏（对应安卓的音乐页那个开关）。 */
void FDMMusicShowMiniBar(BOOL on);
BOOL FDMMusicMiniBarVisible(void);

// /** 把「此刻在听什么」接给变量引擎用的封面兜底（存档不存 pic）。 */
void FDMMusicEnsureCover(void);

/** 把「队列里第一首」的状态同步进 state.json（退出前也会调）。 */
void FDMMusicSaveState(void);

/* ── 给迷你卡用的内部接口（不要在别处调） ── */

#import "FDMMusicModel.h"

/** 只读队列快照（迷你卡画界面用，别改它）。 */
const fdmmusic_queue *FDMMusicQueue(void);

/**
 * 迷你卡的统一动作入口（省得面板直接摸 AVPlayer）。
 * @param action 0=播/暂停 1=下一首 2=上一首 3=跳转(arg=ms)
 *               4=音量(arg=0..100) 5=播放第 arg 首 6=切循环 7=切随机
 */
void FDMMusicAction(int action, long long arg);

/** 迷你卡要拿去搜歌用（返回的 tracks 是 FDMMusicTrack 数组，主线程回调）。 */
void FDMMusicSearch(NSString *keyword, void (^done)(NSArray *tracks));

/**
 * 整批设队列并开始播（迷你卡点搜索结果用）。
 * ⚠️ 必须在主线程调用 —— 内部会**同步**深拷贝 items，返回后调用方即可释放。
 * @return 0 成功
 */
int FDMMusicSetQueueRaw(const fdmmusic_track *items, unsigned long n, int start);

#endif /* FDM_MUSIC_H */

