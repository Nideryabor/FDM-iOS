// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMMusicLogin.m —— 见头文件注释。
#import <Foundation/Foundation.h>

#import "FDMMusicLogin.h"
#import "FDMMusicApi.h"
#import "FLog.h"

/* ============================================================
 * 〇、全局
 * ============================================================ */

static NSString *gUid  = nil;
static NSString *gNick = nil;
static NSString *gLastOp = @"（还没操作过）";
static BOOL      gInstalled = NO;

static void LoginSetOp(NSString *s) {
    gLastOp = [s copy] ?: @"";
    FLOGI(FC_MUSIC, @"[login] %@", gLastOp);
}

static NSString *LoginDir(void) {
    @try {
        NSString *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES).firstObject;
        if (!d.length) d = NSTemporaryDirectory();
        NSString *sub = [d stringByAppendingPathComponent:@"FDMmusic"];
        [[NSFileManager defaultManager] createDirectoryAtPath:sub
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:NULL];
        /* ★ 凭证不进 iCloud/iTunes 备份（iOS 独有的隐私要求） */
        NSURL *u = [NSURL fileURLWithPath:sub];
        [u setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:NULL];
        return sub;
    } @catch (NSException *e) { return NSTemporaryDirectory(); }
}

static NSString *LoginPath(void) {
    return [LoginDir() stringByAppendingPathComponent:@"login.json"];
}

/* ============================================================
 * 一、纯函数：从「用户粘进来的东西」里抠 MUSIC_U
 * ============================================================ */

NSString *FDMMusicLoginExtractU(NSString *raw) {
    if (!raw.length) return nil;

    NSString *s = [raw stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) return nil;

    /* ① / ② 带名字的：交给 Api 的 pickCookie（它已经处理了 "k=v; ..." 形态） */
    NSString *mu = [FDMMusicApi pickCookie:s name:@"MUSIC_U"];
    if (mu.length) return mu;

    /* ③ 纯值：长度够、又没有 = 和 ; ⇒ 就是凭证本身 */
    if (s.length >= 20 &&
        [s rangeOfString:@"="].location == NSNotFound &&
        [s rangeOfString:@";"].location == NSNotFound &&
        [s rangeOfString:@"\n"].location == NSNotFound) {
        return s;
    }
    return nil;
}

/* ============================================================
 * 二、读写
 * ============================================================ */

BOOL FDMMusicLoginSave(NSString *musicU, NSString *uid, NSString *nick) {
    /* ★ 安卓的坑：以前对空凭证直接 return 连日志都不打 ⇒
     *   "提示成功、其实什么都没发生"。这里永远留一句话。 */
    NSString *mu = [musicU stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!mu.length) {
        LoginSetOp(@"保存失败：凭证是空的");
        return NO;
    }

    gUid  = [uid copy];
    gNick = [nick copy];

    /* 立刻注入 Api（后续请求自动带上） */
    [FDMMusicApi setMusicU:mu];

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"musicU"] = mu;
    d[@"uid"]    = gUid ?: @"";
    d[@"nick"]   = gNick ?: @"";
    d[@"at"]     = @([[NSDate date] timeIntervalSince1970]);

    BOOL ok = NO;
    @try {
        NSData *js = [NSJSONSerialization dataWithJSONObject:d
                                                     options:NSJSONWritingPrettyPrinted
                                                       error:NULL];
        ok = js && [js writeToFile:LoginPath() atomically:YES];
    } @catch (NSException *e) {
        LoginSetOp([NSString stringWithFormat:@"保存异常：%@", e.reason]);
        return NO;
    }

    if (ok) {
        LoginSetOp([NSString stringWithFormat:@"已保存登录态（MUSIC_U %lu 字符%@）",
                    (unsigned long)mu.length,
                    gNick.length ? [NSString stringWithFormat:@"，昵称 %@", gNick] : @""]);
    } else {
        LoginSetOp(@"保存失败：写盘失败（权限？）");
    }
    return ok;
}

BOOL FDMMusicLoginClear(void) {
    gUid = nil;
    gNick = nil;
    [FDMMusicApi logout];

    BOOL ok = YES;
    @try {
        NSString *p = LoginPath();
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
            ok = [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
        }
    } @catch (NSException *e) { ok = NO; }

    LoginSetOp(ok ? @"已退出登录（凭证已删除）" : @"退出登录：删除文件失败");
    return ok;
}

void FDMMusicLoginReload(void) {
    @try {
        NSString *p = LoginPath();
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (!d.length) {
            LoginSetOp(@"没有 login.json（未登录）");
            return;
        }
        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        if (![j isKindOfClass:[NSDictionary class]]) {
            LoginSetOp(@"login.json 格式不对，当作未登录");
            return;
        }
        NSDictionary *m = j;
        NSString *mu = m[@"musicU"];
        if (![mu isKindOfClass:[NSString class]] || !mu.length) {
            LoginSetOp(@"login.json 里没有 musicU，当作未登录");
            return;
        }
        gUid  = [m[@"uid"]  isKindOfClass:[NSString class]] ? m[@"uid"]  : nil;
        gNick = [m[@"nick"] isKindOfClass:[NSString class]] ? m[@"nick"] : nil;

        [FDMMusicApi setMusicU:mu];
        LoginSetOp([NSString stringWithFormat:@"从磁盘恢复登录态（%@）",
                    gNick.length ? gNick : @"昵称未知"]);
    } @catch (NSException *e) {
        LoginSetOp([NSString stringWithFormat:@"读 login.json 异常：%@", e.reason]);
    }
}

BOOL FDMMusicLoginLoggedIn(void) { return [FDMMusicApi hasLogin]; }

NSString *FDMMusicLoginSummary(void) {
    if (![FDMMusicApi hasLogin]) return @"未登录（VIP 歌只能试听 30 秒）";
    if (gNick.length) return [NSString stringWithFormat:@"已登录：%@", gNick];
    if (gUid.length)  return [NSString stringWithFormat:@"已登录（uid %@）", gUid];
    return @"已登录";
}

NSString *FDMMusicLoginLastOp(void) { return gLastOp ?: @""; }

NSString *FDMMusicLoginDiag(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"登录：%@\n", FDMMusicLoginSummary()];
    /* ★ 不打印凭证长度/内容本身 —— 诊断串经常被贴到聊天里，
     *   长度也属于指纹信息，一律不露。 */
    [s appendFormat:@"有凭证：%@\n", [FDMMusicApi hasLogin] ? @"是" : @"否"];
    [s appendFormat:@"uid：%@\n", gUid.length ? gUid : @"(空)"];
    [s appendFormat:@"昵称：%@\n", gNick.length ? gNick : @"(空)"];
    [s appendFormat:@"上次操作：%@\n", gLastOp ?: @""];
    [s appendFormat:@"文件存在：%@\n", [[NSFileManager defaultManager]
        fileExistsAtPath:LoginPath()] ? @"是" : @"否"];
    [s appendFormat:@"文件路径：%@", LoginPath()];
    return s;
}

/* ============================================================
 * 三、流程编排
 * ============================================================ */

/** 从登录回调里顺手把 uid/nick 从响应体捞出来（有就存，没有就算了）。 */
static void LoginHarvestProfile(void) {
    /* 注意：这里**不额外发请求**。昵称要等 loginStatus 才有，
     * 但登录成功那一刻界面已经能用了。所以先存凭证，昵称后补。 */
}

void FDMMusicLoginSendCaptcha(NSString *phone, NSString *ctcode, FDMMusicLoginDone done) {
    [FDMMusicApi captchaSent:phone ctcode:ctcode completion:^(BOOL ok, NSString *msg, NSString *jar) {
        LoginSetOp([NSString stringWithFormat:@"发验证码 %@：%@", ok ? @"✓" : @"✗", msg ?: @""]);
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(ok, msg); });
    }];
}

/** 三条登录路共用的收尾：成功就落盘 + 补昵称。 */
static void LoginFinish(BOOL ok, NSString *msg, NSString *jar, FDMMusicLoginDone done) {
    if (!ok) {
        LoginSetOp([NSString stringWithFormat:@"登录失败：%@", msg ?: @""]);
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(NO, msg); });
        return;
    }

    /* 凭证已经由 FDMMusicApi 注入内存了；这里落盘。
     * ★ 从 jar 里抠一次，确保存的是真凭证（不是空串）。 */
    NSString *mu = [FDMMusicApi pickCookie:jar name:@"MUSIC_U"];
    if (!mu.length) mu = [FDMMusicApi pickCookie:[FDMMusicApi lastSetCookie] name:@"MUSIC_U"];

    BOOL saved = NO;
    if (mu.length) {
        saved = FDMMusicLoginSave(mu, nil, nil);
    } else {
        LoginSetOp(@"登录返回成功，但没抠到 MUSIC_U（重定向没跟上？）");
    }
    LoginHarvestProfile();

    /* 成功后顺手查一次昵称（失败也不影响"已登录"这个事实） */
    if (saved) {
        [FDMMusicApi loginStatus:^(BOOL sok, NSString *smsg, NSString *sjar) {
            if (sok && smsg.length) {
                /* smsg 形如 "已登录：周杰伦" */
                NSRange r = [smsg rangeOfString:@"："];
                if (r.location != NSNotFound) {
                    NSString *nick = [smsg substringFromIndex:r.location + 1];
                    if (nick.length) {
                        gNick = nick;
                        /* 重新落盘一次，把昵称带上 */
                        NSString *cur = [FDMMusicApi pickCookie:sjar name:@"MUSIC_U"];
                        if (!cur.length) cur = mu;
                        if (cur.length) FDMMusicLoginSave(cur, gUid, nick);
                        FLOGI(FC_MUSIC, @"[login] 昵称补上：%@", nick);
                    }
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(YES, msg); });
        }];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(saved, saved ? msg
                                                                             : @"登录成功但保存失败"); });
}

void FDMMusicLoginByCaptcha(NSString *phone, NSString *captcha,
                            NSString *ctcode, FDMMusicLoginDone done) {
    [FDMMusicApi loginByCaptcha:phone captcha:captcha ctcode:ctcode
                     completion:^(BOOL ok, NSString *msg, NSString *jar) {
        LoginFinish(ok, msg, jar, done);
    }];
}

void FDMMusicLoginByPassword(NSString *phone, NSString *password,
                             NSString *ctcode, FDMMusicLoginDone done) {
    [FDMMusicApi loginByPassword:phone password:password ctcode:ctcode
                      completion:^(BOOL ok, NSString *msg, NSString *jar) {
        LoginFinish(ok, msg, jar, done);
    }];
}

void FDMMusicLoginByEmail(NSString *email, NSString *password, FDMMusicLoginDone done) {
    [FDMMusicApi loginByEmail:email password:password
                   completion:^(BOOL ok, NSString *msg, NSString *jar) {
        LoginFinish(ok, msg, jar, done);
    }];
}

void FDMMusicLoginByCookie(NSString *rawCookie, FDMMusicLoginDone done) {
    /* ★ 1.14 修：先自己抠一遍（API 层抠不到时会给"没找到 MUSIC_U"，
     *   但界面更需要"纯值形态"也能用）⇒ 这里统一处理，再交给 Api 只做注入。 */
    NSString *mu = FDMMusicLoginExtractU(rawCookie);
    if (!mu.length) {
        LoginSetOp(@"cookie 登录失败：没找到 MUSIC_U");
        dispatch_async(dispatch_get_main_queue(), ^{
            if (done) done(NO, @"没找到 MUSIC_U。要贴的是 MUSIC_U=… 那一段"
                                @"（或整条 cookie）");
        });
        return;
    }

    [FDMMusicApi loginByCookie:rawCookie completion:^(BOOL ok, NSString *msg, NSString *jar) {
        if (ok) {
            BOOL saved = FDMMusicLoginSave(mu, nil, nil);
            LoginSetOp(saved ? @"cookie 登录成功，已保存"
                             : @"cookie 登录成功，但保存失败");
            /* 尝试补昵称 */
            [FDMMusicApi loginStatus:^(BOOL sok, NSString *smsg, NSString *sjar) {
                if (sok) {
                    NSRange r = [smsg rangeOfString:@"："];
                    if (r.location != NSNotFound) {
                        NSString *nick = [smsg substringFromIndex:r.location + 1];
                        if (nick.length) { gNick = nick; FDMMusicLoginSave(mu, gUid, nick); }
                    }
                }
                dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(saved, msg); });
            }];
            return;
        }
        LoginSetOp([NSString stringWithFormat:@"cookie 登录失败：%@", msg ?: @""]);
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(NO, msg); });
    }];
}

void FDMMusicLoginCheck(FDMMusicLoginDone done) {
    [FDMMusicApi loginStatus:^(BOOL ok, NSString *msg, NSString *jar) {
        if (ok) {
            NSRange r = [msg rangeOfString:@"："];
            if (r.location != NSNotFound) {
                NSString *nick = [msg substringFromIndex:r.location + 1];
                if (nick.length) {
                    gNick = nick;
                    NSString *mu = [FDMMusicApi pickCookie:jar name:@"MUSIC_U"];
                    if (mu.length) FDMMusicLoginSave(mu, gUid, nick);
                }
            }
            LoginSetOp([NSString stringWithFormat:@"状态检查：%@", msg ?: @"已登录"]);
        } else {
            LoginSetOp([NSString stringWithFormat:@"状态检查：%@", msg ?: @"无效"]);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(ok, msg); });
    }];
}

void FDMMusicLogout(void) {
    FDMMusicLoginClear();
}

/* ============================================================
 * 四、安装
 * ============================================================ */

void FDMMusicLoginInstall(void) {
    if (gInstalled) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ FDMMusicLoginInstall(); });
        return;
    }
    gInstalled = YES;

    /* ① 纯函数自检（12 条）—— 不过就只装个壳，不碰网络 */
    {
        char err[512] = {0};
        int bad = FDMMusicLoginSelftest(err, sizeof(err));
        if (bad) {
            FLOGE(FC_MUSIC, @"[login] 自检失败 #%d：%s ⇒ cookie 登录这条路停用", bad, err);
            return;
        }
        FLOGI(FC_MUSIC, @"[login] 自检 12 条全过（cookie 抠取三种形态）");
    }

    /* ② 从磁盘恢复（有就自动带上，用户不用重新登录） */
    FDMMusicLoginReload();
}

/* ============================================================
 * 五、自检（纯函数，真机/小窝都能跑）
 * ============================================================ */

static int lg_chk(char *errbuf, int errlen, int no, const char *what, BOOL ok) {
    if (ok) return 1;
    snprintf(errbuf, (size_t)errlen, "#%d %s", no, what);
    return 0;
}

int FDMMusicLoginSelftest(char *errbuf, int errlen) {
    char local[512];
    if (!errbuf) { errbuf = local; errlen = (int)sizeof(local); }
    errbuf[0] = '\0';

    /* 1. 整条 Set-Cookie 形态 */
    NSString *u1 = FDMMusicLoginExtractU(
        @"MUSIC_U=00112233445566778899aabbccddeeff; Path=/; Domain=.music.163.com; HttpOnly");
    if (!lg_chk(errbuf, errlen, 1, "整条 Set-Cookie 抠取",
                [u1 isEqualToString:@"00112233445566778899aabbccddeeff"])) return 1;

    /* 2. 只有一对 k=v */
    NSString *u2 = FDMMusicLoginExtractU(@"MUSIC_U=abcdefghijklmnopqrstuvwxyz");
    if (!lg_chk(errbuf, errlen, 2, "单对 k=v",
                [u2 isEqualToString:@"abcdefghijklmnopqrstuvwxyz"])) return 2;

    /* 3. 纯值形态（≥20 且不含 = 和 ;） */
    NSString *u3 = FDMMusicLoginExtractU(@"abcdefghijklmnopqrstuvwxyz12345");
    if (!lg_chk(errbuf, errlen, 3, "纯值形态",
                [u3 isEqualToString:@"abcdefghijklmnopqrstuvwxyz12345"])) return 3;

    /* 4. 太短的纯值不认（防误判） */
    NSString *u4 = FDMMusicLoginExtractU(@"short");
    if (!lg_chk(errbuf, errlen, 4, "短纯值不该认", u4 == nil)) return 4;

    /* 5. 空串 */
    if (!lg_chk(errbuf, errlen, 5, "空串返回 nil",
                FDMMusicLoginExtractU(@"") == nil &&
                FDMMusicLoginExtractU(nil) == nil)) return 5;

    /* 6. 前后空白要 trim */
    NSString *u6 = FDMMusicLoginExtractU(@"  \n MUSIC_U=zzzzzzzzzzzzzzzzzzzzzz  \n");
    if (!lg_chk(errbuf, errlen, 6, "trim 前后空白",
                [u6 isEqualToString:@"zzzzzzzzzzzzzzzzzzzzzz"])) return 6;

    /* 7. 多 cookie 时只挑 MUSIC_U */
    NSString *u7 = FDMMusicLoginExtractU(@"__csrf=abc; MUSIC_U=target123456789012345; MUSIC_A=other");
    if (!lg_chk(errbuf, errlen, 7, "多 cookie 只挑 MUSIC_U",
                [u7 isEqualToString:@"target123456789012345"])) return 7;

    /* 8. 名字前缀不能被误认（MUSIC_UX 不是 MUSIC_U） */
    NSString *u8 = FDMMusicLoginExtractU(@"MUSIC_UX=notthis123456789012345; MUSIC_U=right123456789012345");
    if (!lg_chk(errbuf, errlen, 8, "MUSIC_UX 不能当 MUSIC_U",
                [u8 isEqualToString:@"right123456789012345"])) return 8;

    /* 9. 只有别的 cookie ⇒ nil */
    NSString *u9 = FDMMusicLoginExtractU(@"__csrf=abcdefghijklmnopqrstuvwxyz");
    if (!lg_chk(errbuf, errlen, 9, "没 MUSIC_U 应返回 nil", u9 == nil)) return 9;

    /* 10. md5（密码登录要用） */
    NSString *m1 = [FDMMusicApi md5Hex:@"123456"];
    if (!lg_chk(errbuf, errlen, 10, "md5(123456)",
                [m1 isEqualToString:@"e10adc3949ba59abbe56e057f20f883e"])) return 10;

    /* 11. md5 空串 */
    NSString *m2 = [FDMMusicApi md5Hex:@""];
    if (!lg_chk(errbuf, errlen, 11, "md5(空)",
                [m2 isEqualToString:@"d41d8cd98f00b204e9800998ecf8427e"])) return 11;

    /* 12. md5 中文 */
    NSString *m3 = [FDMMusicApi md5Hex:@"龙"];
    if (!lg_chk(errbuf, errlen, 12, "md5(龙) 应按 UTF-8",
                m3.length == 32)) return 12;

    return 0;
}
