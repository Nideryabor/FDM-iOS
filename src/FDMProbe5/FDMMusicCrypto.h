// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// ═══════════════════════════════════════════════════════════════════════════
//  FDMMusicCrypto —— 网易云 eapi / weapi / linuxapi 加密层（纯 C11，零依赖）
//
//  这是 `mod-src/src/com/nidyaber/fuckdsmanger/music/GmMusicCrypto.java`
//  的逐行等价移植。算法与常量 100% 对齐 NeteaseCloudMusicApi 4.32.0 的
//  `util/crypto.js`。
//
//  ★ 为什么不用 CommonCrypto？
//    因为要能**在小窝 Linux 上 gcc 编译 + 与 Java 版逐字节对拍**。
//    自己带一份 AES-128 / MD5，编译目标换成 iOS 也是同一份代码 ⇒ 行为绝对一致。
//    （CommonCrypto 的 AES 当然也对，但没法在 Linux 上跑对拍。）
//
//  ★ RSA 不在这里实现 —— 1024-bit 模幂太重，而且 iOS 有 Security.framework。
//    通过 fdm_rsa_raw_fn 回调注入：
//      iOS  : SecKeyCreateEncryptedData(kSecPaddingNone)，输入左补 0 到 128 字节
//      Linux: RSA_public_encrypt(RSA_NO_PADDING)
//
// ═══════════════════════════════════════════════════════════════════════════
#ifndef FDM_MUSIC_CRYPTO_H
#define FDM_MUSIC_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── 常量（与 util/crypto.js 逐字一致）──
#define FDM_MUSIC_IV         "0102030405060708"
#define FDM_MUSIC_PRESET_KEY "0CoJUm6Qyw8W8jud"
#define FDM_MUSIC_LINUX_KEY  "rFgB&h#%2?^eDg:Q"
#define FDM_MUSIC_EAPI_KEY   "e82ckenh8dichen8"
#define FDM_MUSIC_EAPI_SEP   "-36cd479b6b5-"
#define FDM_MUSIC_BASE62     "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

// RSA 公钥（1024-bit，util/crypto.js 的 publicKey），已去掉 PEM 头尾
#define FDM_MUSIC_RSA_PUB_B64 \
    "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7cl" \
    "FSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMld" \
    "czhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB"

/* ══════════════════════════ 基础原语 ══════════════════════════ */

/** MD5 → 小写 hex（32 字符 + '\0'）。out 至少 33 字节。 */
void fdm_md5_hex(const char *s, char out[33]);

/** MD5 裸摘要（16 字节）。 */
void fdm_md5(const uint8_t *data, size_t len, uint8_t out[16]);

/**
 * AES-128 ECB + PKCS7（等价 CryptoJS AES.encrypt(text, key, {mode: ECB})）。
 * 返回 malloc 的缓冲区，调用方 free；失败返回 NULL。
 */
uint8_t *fdm_aes128_ecb_pkcs7(const uint8_t *in, size_t inlen,
                              const uint8_t key[16], size_t *outlen);

/**
 * AES-128 CBC + PKCS7（iv 16 字节）。
 * 返回 malloc 的缓冲区，调用方 free；失败返回 NULL。
 */
uint8_t *fdm_aes128_cbc_pkcs7(const uint8_t *in, size_t inlen,
                              const uint8_t key[16], const uint8_t iv[16],
                              size_t *outlen);

/** 单块 AES-128 加密（ECB，不做 padding，in/out 都是 16 字节）。 */
void fdm_aes128_encrypt_block(const uint8_t in[16], const uint8_t key[16],
                              uint8_t out[16]);

/** 小写 hex → 字符串（调用方 free）。 */
char *fdm_hex_lower(const uint8_t *b, size_t n);

/** 大写 hex → 字符串（调用方 free）。 */
char *fdm_hex_upper(const uint8_t *b, size_t n);

/** Base64 编码（调用方 free）。 */
char *fdm_base64_encode(const uint8_t *b, size_t n);

/** 标准 Base64 解码；返回 malloc 缓冲，*outlen 为长度，失败 NULL。 */
uint8_t *fdm_base64_decode(const char *s, size_t *outlen);

/* ══════════════════════════ RSA 回调 ══════════════════════════ */

/**
 * 裸 RSA（无 padding）：把 in（≤128 字节）当大端整数，算 m^e mod n，输出 128 字节大端。
 * 对应 node-forge 的 publicKey.encrypt(str, 'NONE')。
 *
 * iOS 侧：Security.framework 实现（见 FDMMusicCrypto_iOS.m）
 * Linux 测试：OpenSSL 实现（见 test_crypto.c）
 */
typedef int (*fdm_rsa_raw_fn)(const uint8_t *in, size_t inlen, uint8_t out[128]);

/** 注册 RSA 实现；传 NULL 表示卸载（之后 weapi 会返回 NULL）。 */
void fdm_music_set_rsa(fdm_rsa_raw_fn fn);

/* ══════════════════════════ 三个通道 ══════════════════════════ */

/**
 * eapi：AES-128-ECB(key=e82ckenh8dichen8) of
 *       `${uri}-36cd479b6b5-${json}-36cd479b6b5-${md5("nobody"+uri+"use"+json+"md5forencrypt")}`
 * 输出 **大写 HEX**（调用方 free）。
 * @param uri 形如 "/api/search/get"（原始 uri，不是 /eapi/… 那个）
 */
char *fdm_music_eapi(const char *uri, const char *json);

/** linuxapi：AES-128-ECB(key=rFgB&h#%2?^eDg:Q) → 大写 HEX（调用方 free）。 */
char *fdm_music_linuxapi(const char *json);

/**
 * weapi：两次 AES-128-CBC + 反转 secretKey 的裸 RSA。
 * @param secret_key 16 字节的随机串；传 NULL 则内部用 rand() 生成
 *                   （测试时传固定值即可对拍）
 * @param out_params     输出 params（Base64 文本，调用方 free）
 * @param out_enc_sec_key 输出 encSecKey（256 字符 HEX，调用方 free）
 * @return 0 成功，负数失败
 */
int fdm_music_weapi(const char *json, const char *secret_key,
                    char **out_params, char **out_enc_sec_key);

/**
 * 生成 16 字节 secretKey（与 Java 版同分布：BASE62 上均匀取）。
 * out 至少 17 字节。
 */
void fdm_music_random_secret(char out[17]);

/* ══════════════════════════ 自检 ══════════════════════════ */

/**
 * 跑内置测试向量（FIPS-197 AES / RFC 1321 MD5 / CryptoJS 对齐）。
 * @return 0 全部通过；否则返回第一个失败的用例编号
 */
int fdm_music_selftest(char *errbuf, size_t errlen);

#ifdef __cplusplus
}
#endif

#endif /* FDM_MUSIC_CRYPTO_H */
