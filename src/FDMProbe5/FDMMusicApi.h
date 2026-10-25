// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMMusicApi —— 网易云 API 客户端（iOS 侧，eapi 通道，免登录即可用）
//
// 与 `mod-src/.../music/GmMusicApi.java` 一一对应，接口路径 / 参数名 /
// 报文格式 / 请求头字段全部来自 NeteaseCloudMusicApi 4.32.0：
//   util/request.js · module/search.js · module/song_url_v1.js
//   module/song_detail.js · module/song_lyric.js
//
// ★ 与 Java 版唯一的结构差异：**异步**。
//   Java 用 HttpURLConnection 阻塞跑，iOS 绝不能阻塞主线程 ——
//   所有接口都是 completion 回调，且回调固定投递到主线程。
//
// ★ 协议活性已在小窝验证过（2026-10-23，Java 版真发请求）：
//   搜索 / 播放地址(standard/exhigh/lossless) / 歌词 / 详情 全部 code=200。
//   也就是说这里只要加密层对、报文格式对，接口就能通。
#ifndef FDM_MUSIC_API_H
#define FDM_MUSIC_API_H

#import <Foundation/Foundation.h>

/** 一首歌（跨接口归一化后的扁平结构） */
@interface FDMMusicTrack : NSObject
@property (nonatomic) long long songId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *album;
@property (nonatomic, copy) NSString *picUrl;
@property (nonatomic) long long duration;   // 毫秒
@property (nonatomic) NSInteger fee;        // 0 免费 / 1 VIP / 8 低音质免费
@end

typedef NS_ENUM(NSInteger, FDMMusicOsMode) {
    FDMMusicOsModePC = 0,
    FDMMusicOsModeAndroid = 1,
    FDMMusicOsModeIPhone = 2,   // 默认
};

typedef void (^FDMMusicTracksCb)(NSArray<FDMMusicTrack *> *tracks, NSError *error);
typedef void (^FDMMusicUrlCb)(NSString *url, long long br, NSString *type,
                              NSInteger fee, NSError *error);
typedef void (^FDMMusicLyricCb)(NSString *lrc, NSString *tlrc, NSError *error);

@interface FDMMusicApi : NSObject

/** 客户端伪装档位（os 参数与 UA 必须成对，见 Java 版注释）。 */
+ (void)setOsMode:(FDMMusicOsMode)mode;
+ (FDMMusicOsMode)osMode;

/** 登录态：MUSIC_U（从别的客户端 / 浏览器 cookie 里抠出来即可）。 */
+ (void)setMusicU:(NSString *)musicU;
+ (void)setMusicA:(NSString *)musicA;
+ (BOOL)hasLogin;

/** 把 http:// 换成 https://（宿主 ATS 只放行 https）。 */
+ (NSString *)preferHTTPS:(NSString *)url;

/** 上一次业务接口返回的 code（-1 = 还没请求过）。 */
+ (NSInteger)lastCode;

/** 设备 ID（一次进程内固定）。 */
+ (NSString *)deviceId;

/* ── 业务接口（全部异步，回调在主线程）── */

/** 搜索单曲。内部会补一次 songDetail 把封面补齐（搜索接口不给 picUrl）。 */
+ (void)search:(NSString *)keyword
         limit:(NSInteger)limit
        offset:(NSInteger)offset
    completion:(FDMMusicTracksCb)completion;

/** 播放地址。level: standard / higher / exhigh / lossless */
+ (void)songUrl:(long long)songId
          level:(NSString *)level
     completion:(FDMMusicUrlCb)completion;

/** 歌曲详情（封面 / 时长 / 歌手）。 */
+ (void)songDetail:(NSArray<NSNumber *> *)songIds
        completion:(FDMMusicTracksCb)completion;

/** 歌词。 */
+ (void)lyric:(long long)songId completion:(FDMMusicLyricCb)completion;

/* ── 自检 ── */

/**
 * 打一次真实搜索（关键词 "晴天"，3 条），把结果写进日志。
 * 真机上只要看到 [music] 搜索 ✓ 就说明：加密 → 请求头 → 网络 → JSON 全通。
 * @param keyword 传 nil 用默认值
 */
+ (void)networkSelfTest:(NSString *)keyword;

/* ============================================================
 * 登录（weapi 通道 · 2026-10-25）
 *
 * ★ 为什么登录走 weapi 而不是 eapi：
 *   NeteaseCloudMusicApi 的 `util/request.js` 里，登录系列接口用的是 weapi 分支。
 *   eapi 分支的 uri 要加 `/api/` 前缀并做 AES-ECB；weapi 是
 *   `POST music.163.com/weapi/<uri 去掉 /api/>`，body = `params=…&encSecKey=…`。
 *
 * ★ 为什么必须**手动跟重定向**：
 *   登录经常先回 302，而 `Set-Cookie: MUSIC_U=…` 就在那一跳上。
 *   自动跟随 ⇒ 只拿得到最终响应的头 ⇒ 凭证丢了（症状：提示成功、其实没登录）。
 *
 * ⚠️⚠️ 隐私：本模块把凭证以**明文**存在
 *   `Documents/FDMmusic/login.json`（只有本 App 能读）。
 *   root 用户 / 拿到备份的人可以直接读到，进而用你的账号。**界面必须告诉用户。**
 * ============================================================ */

/** 上一次响应的 Set-Cookie（逐跳累积，每条一行）。 */
+ (NSString *)lastSetCookie;

/** 从罐子里挑一个 cookie 值（等价安卓 GmMusicApi.pickCookie）。 */
+ (NSString *)pickCookie:(NSString *)jar name:(NSString *)name;

/** 回调：(ok, msg, cookieJar) —— msg 是给界面直接显示的一句话。 */
typedef void (^FDMMusicLoginCb)(BOOL ok, NSString *msg, NSString *jar);

/** ① 发短信验证码。@param ctcode 国家码，传 nil 用 "86" */
+ (void)captchaSent:(NSString *)phone
             ctcode:(NSString *)ctcode
         completion:(FDMMusicLoginCb)completion;

/** ② 手机 + 验证码登录。 */
+ (void)loginByCaptcha:(NSString *)phone
               captcha:(NSString *)captcha
                ctcode:(NSString *)ctcode
            completion:(FDMMusicLoginCb)completion;

/** ③ 手机 + 密码登录。@param password **明文**（内部做 md5） */
+ (void)loginByPassword:(NSString *)phone
               password:(NSString *)password
                 ctcode:(NSString *)ctcode
             completion:(FDMMusicLoginCb)completion;

/** ④ 邮箱 + 密码登录。 */
+ (void)loginByEmail:(NSString *)email
            password:(NSString *)password
          completion:(FDMMusicLoginCb)completion;

/** ⑤ 直接粘 cookie（最省事的一条路）。会自动从中抠 MUSIC_U / MUSIC_A。 */
+ (void)loginByCookie:(NSString *)rawCookie completion:(FDMMusicLoginCb)completion;

/** ⑥ 查当前登录状态（需要已有 MUSIC_U）。 */
+ (void)loginStatus:(FDMMusicLoginCb)completion;

/** ⑦ 退出：清内存态（磁盘上的 login.json 由 FDMMusicLogin 负责）。 */
+ (void)logout;

/** ⑧ 明文 md5（给密码登录用；也导出方便离线单测）。 */
+ (NSString *)md5Hex:(NSString *)s;

@end

#endif /* FDM_MUSIC_API_H */
