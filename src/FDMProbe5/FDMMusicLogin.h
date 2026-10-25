// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMMusicLogin —— 网易云登录态的存取 + 登录流程编排
//
// 对标安卓 `bridge/GmMusicLogin.java`（265 行）+ `MusicLogin.kt`（417 行）里
// **除了 Compose UI 之外**的全部逻辑。
//
// ══════════════════════════════════════════════════════════════════════════
//  ⚠️⚠️ 隐私：本文件是**明文**的
//
//  凭证（MUSIC_U）存在 `Documents/FDMmusic/login.json`，**没有加密**。
//  只有本 App 自己能读（iOS 沙盒），但：root 用户 / 拿到 iTunes 备份的人
//  可以直接读到，进而用你的账号。**界面上必须明确告诉用户这一条**。
//
//  （iOS 的 Documents 还会被 iTunes/iCloud 备份带走，
//    所以这里额外设了 NSURLIsExcludedFromBackupKey —— 不进备份。）
// ══════════════════════════════════════════════════════════════════════════
//
// ★ 与安卓的差异
//    安卓：凭证写在宿主私有目录 `/data/data/<宿主>/files/FDMmusic/login.json`
//    iOS ：写在 `Documents/FDMmusic/login.json`（同一套语义），
//          额外排除 iCloud 备份（安卓没这个需求，但 iOS 必须做）。
#ifndef FDM_MUSIC_LOGIN_H
#define FDM_MUSIC_LOGIN_H

#import <Foundation/Foundation.h>

/** 安装：读磁盘上的 login.json → 注入 FDMMusicApi。主线程调。 */
void FDMMusicLoginInstall(void);

/** 重新从磁盘读一遍（设置页改完配置调）。 */
void FDMMusicLoginReload(void);

/* ── 读写 ── */

/**
 * 存一份登录态（并立刻注入 Api，后续请求自动带上）。
 * @param musicU 凭证
 * @param uid    用户 id（可空，仅界面显示）
 * @param nick   昵称（可空，仅界面显示）
 * @return YES = 真写盘了
 */
BOOL FDMMusicLoginSave(NSString *musicU, NSString *uid, NSString *nick);

/** 清掉磁盘上的凭证 + 内存态。 */
BOOL FDMMusicLoginClear(void);

/** 当前有没有登录（内存判断，不读盘）。 */
BOOL FDMMusicLoginLoggedIn(void);

/** 给界面显示的一行摘要（"已登录：xxx" / "未登录" / "凭证已失效"）。 */
NSString *FDMMusicLoginSummary(void);

/** 诊断串（排查时贴给尼尼用；不含凭证本身）。 */
NSString *FDMMusicLoginDiag(void);

/** 上次操作的结果（★ 安卓踩过：save 对空凭证直接 return 不打日志 ⇒
 *  "提示成功、其实什么都没发生"，查起来像见鬼。这里永远留一句话）。 */
NSString *FDMMusicLoginLastOp(void);

/* ── 流程编排（都是异步，回调在主线程）── */

typedef void (^FDMMusicLoginDone)(BOOL ok, NSString *msg);

/** 发验证码。 */
void FDMMusicLoginSendCaptcha(NSString *phone, NSString *ctcode, FDMMusicLoginDone done);

/** 验证码登录（成功后自动落盘）。 */
void FDMMusicLoginByCaptcha(NSString *phone, NSString *captcha,
                            NSString *ctcode, FDMMusicLoginDone done);

/** 密码登录（成功后自动落盘）。 */
void FDMMusicLoginByPassword(NSString *phone, NSString *password,
                             NSString *ctcode, FDMMusicLoginDone done);

/** 邮箱登录（成功后自动落盘）。 */
void FDMMusicLoginByEmail(NSString *email, NSString *password, FDMMusicLoginDone done);

/** 直接粘 cookie（最省事；成功后自动落盘）。 */
void FDMMusicLoginByCookie(NSString *rawCookie, FDMMusicLoginDone done);

/** 查一次真实登录状态（会打网络）。 */
void FDMMusicLoginCheck(FDMMusicLoginDone done);

/** 退出登录。 */
void FDMMusicLogout(void);

/* ── 单测友好的纯函数 ── */

/**
 * 从一段「用户粘进来的东西」里抠 MUSIC_U。
 * 支持三种形态：
 *   ① `MUSIC_U=abc; Path=/; ...`   （整条 Set-Cookie）
 *   ② `MUSIC_U=abc`                 （只有一对）
 *   ③ `abc...`                      （纯值，长度 ≥ 20 且不含 = 和 ;）
 * @return 抠到返回凭证，否则返回 nil
 */
NSString *FDMMusicLoginExtractU(NSString *raw);

/** 内置断言。@return 0 全过；否则第一个失败用例号 */
int FDMMusicLoginSelftest(char *errbuf, int errlen);

#endif /* FDM_MUSIC_LOGIN_H */
