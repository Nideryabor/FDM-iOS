// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMMusicCryptoIOS —— 纯 C 加密层在 iOS 侧的「最后一厘米」
//
//   FDMMusicCrypto.c 负责 AES/MD5/Base64（纯 C，已在小窝 Linux 上
//   与 Java 版逐字节对拍通过）。这里只补两件它做不到的事：
//
//   ① RSA 裸加密（1024-bit 模幂）—— 走 Security.framework。
//      关键坑：kSecPaddingNone 要求输入**正好 128 字节**，
//      所以 16 字节 secretKey 必须先左补 0 到 128 字节再喂进去。
//      （左补 0 不改变大端整数的值，等价于 node-forge 的 'NONE' 模式。）
//
//   ② 真机自检 —— 不联网也能确认整条加密链路是对的：
//      启动时跑 fdm_music_selftest() + 一条 RSA 固定向量，
//      日志里出现 [music] crypto ✓ 就说明服务端报文一定能对上。
//
//  ★ 构造函数里不能碰 Foundation（dyld 阶段 ObjC 未就绪）——
//    所以这里只导出函数，由 FDMProbe.m 的 6s 定时器调用。
#import <Foundation/Foundation.h>
#import <Security/Security.h>

#include "FDMMusicCrypto.h"

#import "FLog.h"

#pragma mark - 极简 DER 解析（只为从 SPKI 里抠出 RSAPublicKey）

static BOOL FDMTLV(const uint8_t **pp, const uint8_t *end, uint8_t want_tag,
                   const uint8_t **val, size_t *len) {
    const uint8_t *p = *pp;
    if (!p || p >= end) return NO;
    uint8_t tag = *p++;
    if (tag != want_tag) return NO;
    if (p >= end) return NO;
    size_t l = *p++;
    if (l & 0x80) {
        int n = (int)(l & 0x7f);
        if (n <= 0 || n > 4 || p + n > end) return NO;
        l = 0;
        for (int i = 0; i < n; i++) l = (l << 8) | *p++;
    }
    if (p + l > end) return NO;
    *val = p;
    *len = l;
    *pp = p + l;
    return YES;
}

/**
 * SubjectPublicKeyInfo(DER) → PKCS#1 RSAPublicKey(DER)
 *   SPKI ::= SEQUENCE { AlgorithmIdentifier, BIT STRING }
 *   BIT STRING 的内容去掉首字节（unused bits 计数）就是 RSAPublicKey
 */
static NSData *FDMPKCS1FromSPKI(NSData *spki) {
    if (spki.length < 32) return nil;
    const uint8_t *p = (const uint8_t *)spki.bytes;
    const uint8_t *end = p + spki.length;

    const uint8_t *seq = NULL;
    size_t seqlen = 0;
    if (!FDMTLV(&p, end, 0x30, &seq, &seqlen)) return nil;

    const uint8_t *q = seq;
    const uint8_t *qend = seq + seqlen;

    const uint8_t *alg = NULL;
    size_t alglen = 0;
    if (!FDMTLV(&q, qend, 0x30, &alg, &alglen)) return nil;
    (void)alg;

    const uint8_t *bit = NULL;
    size_t bitlen = 0;
    if (!FDMTLV(&q, qend, 0x03, &bit, &bitlen)) return nil;
    if (bitlen < 2) return nil;
    /* bit[0] 是 unused-bits 计数，RSA 公钥这里恒为 0 */
    return [NSData dataWithBytes:bit + 1 length:bitlen - 1];
}

#pragma mark - RSA

static SecKeyRef gPubKey = NULL;

static SecKeyRef FDMMusicPubKey(void) {
    static int tried = 0;
    if (gPubKey) return gPubKey;
    if (tried) return NULL;
    tried = 1;

    size_t derlen = 0;
    uint8_t *der = fdm_base64_decode(FDM_MUSIC_RSA_PUB_B64, &derlen);
    if (!der) {
        FLOGE(FC_MUSIC, @"[music] 公钥 Base64 解码失败");
        return NULL;
    }
    NSData *spki = [NSData dataWithBytesNoCopy:der length:derlen freeWhenDone:YES];
    NSData *pkcs1 = FDMPKCS1FromSPKI(spki);
    if (!pkcs1) {
        FLOGE(FC_MUSIC, @"[music] SPKI 解析失败（DER 结构不对）");
        return NULL;
    }

    CFErrorRef err = NULL;
    NSDictionary *attrs = @{
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic,
        (__bridge id)kSecAttrKeySizeInBits: @1024,
    };
    gPubKey = SecKeyCreateWithData((__bridge CFDataRef)pkcs1,
                                   (__bridge CFDictionaryRef)attrs, &err);
    if (!gPubKey) {
        FLOGE(FC_MUSIC, @"[music] SecKeyCreateWithData 失败: %@",
              err ? (__bridge id)err : @"(no error)");
        if (err) CFRelease(err);
        return NULL;
    }
    FLOGI(FC_MUSIC, @"[music] RSA 公钥就绪（1024-bit）");
    return gPubKey;
}

/** 裸 RSA：in(≤128B) 左补 0 → SecKeyCreateEncryptedData(kSecPaddingNone) → 128B */
static int FDMRsaRaw(const uint8_t *in, size_t inlen, uint8_t out[128]) {
    SecKeyRef key = FDMMusicPubKey();
    if (!key) return -1;
    if (inlen > 128) return -2;

    uint8_t buf[128];
    memset(buf, 0, sizeof(buf));
    if (inlen) memcpy(buf + (128 - inlen), in, inlen);

    CFErrorRef err = NULL;
    NSData *plain = [NSData dataWithBytesNoCopy:buf
                                         length:128
                                   freeWhenDone:NO];
    /* 用 malloc 的副本，避免 NoCopy 在 block 生命周期上的坑 */
    NSData *copy = [plain copy];
    CFDataRef enc = SecKeyCreateEncryptedData(key, kSecKeyAlgorithmRSAEncryptionRaw,
                                              (__bridge CFDataRef)copy, &err);
    if (!enc) {
        FLOGE(FC_MUSIC, @"[music] RSA 加密失败: %@",
              err ? (__bridge id)err : @"(no error)");
        if (err) CFRelease(err);
        return -3;
    }
    CFIndex n = CFDataGetLength(enc);
    if (n != 128) {
        FLOGE(FC_MUSIC, @"[music] RSA 输出长度异常: %ld", (long)n);
        CFRelease(enc);
        return -4;
    }
    memcpy(out, CFDataGetBytePtr(enc), 128);
    CFRelease(enc);
    return 0;
}

#pragma mark - 对外入口

/** 在 FDMProbe 的 6s 定时器里调用（那时 Foundation 一定就绪了）。 */
void FDMMusicCryptoInstall(void) {
    fdm_music_set_rsa(FDMRsaRaw);

    char err[512] = {0};
    int bad = fdm_music_selftest(err, sizeof(err));
    if (bad) {
        FLOGE(FC_MUSIC, @"[music] crypto 自检失败 #%d\n%s", bad, err);
        return;
    }

    /* RSA 固定向量：与 Java 版 GmMusicCrypto.rsaRawHex("ponmlkjihgfedcba") 一致 */
    static const char *kWant =
        "D15A1683C992095D0C234C19966605C5C5964911268BBEDA8CB8D08D834913E5"
        "9D53B32358903A121B5FCA784C1F5AE44951FD02524DF58ECC98E52CC7CF8689"
        "B42C2E93DDF05B0592512D87F5960467E2F086C018849D76014D323500E30F13"
        "EF4CAFBB0CF5A66731A3F1776C75CA35D0062DAC70A3E33245AFABCF47938487";
    uint8_t got[128];
    if (FDMRsaRaw((const uint8_t *)"ponmlkjihgfedcba", 16, got) != 0) {
        FLOGE(FC_MUSIC, @"[music] RSA 自检：加密失败");
        return;
    }
    char *hex = fdm_hex_upper(got, 128);
    BOOL ok = hex && strcmp(hex, kWant) == 0;
    if (ok) {
        FLOGI(FC_MUSIC, @"[music] crypto ✓（MD5/AES/Base64/RSA 全部与 Java 版一致）");
    } else {
        FLOGE(FC_MUSIC, @"[music] RSA 向量不一致！\n  got : %s\n  want: %s",
              hex ? hex : "(null)", kWant);
    }
    free(hex);
}

/** 给 UI / 调试用：手搓一条 eapi 报文（不联网）。 */
NSString *FDMMusicEapiParams(NSString *uri, NSString *json) {
    char *h = fdm_music_eapi(uri.UTF8String, json.UTF8String);
    if (!h) return nil;
    NSString *s = [NSString stringWithUTF8String:h];
    free(h);
    return s;
}
