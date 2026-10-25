// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMMusicCrypto —— 网易云 eapi / weapi / linuxapi 加密层（纯 C11，零依赖）
// 见 fdm_music_crypto.h 的说明。🐲
//
// 自带 AES-128 + MD5 的理由：要能在小窝 Linux 上 gcc 编译、与 Java 版逐字节对拍。
// 常数表全部来自 FIPS-197 / RFC 1321，不是"抄来能用就行"的黑盒。
#include "FDMMusicCrypto.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* ══════════════════════════════════════════════════════════════════════════
 *  一、AES-128（FIPS-197）
 * ══════════════════════════════════════════════════════════════════════════ */

static const uint8_t SBOX[256] = {
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
};

static const uint8_t RCON[10] = {
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36,
};

/* GF(2^8) 上乘 2 */
static uint8_t xtime(uint8_t a) {
    return (uint8_t)((a << 1) ^ ((a & 0x80) ? 0x1b : 0x00));
}


/* 密钥扩展：128-bit key → 11 轮 × 16 字节 */
static void aes128_expand_key(const uint8_t key[16], uint8_t rk[176]) {
    memcpy(rk, key, 16);
    for (int i = 4; i < 44; i++) {
        uint8_t t[4];
        memcpy(t, rk + (size_t)(i - 1) * 4, 4);
        if (i % 4 == 0) {
            /* RotWord + SubWord + Rcon */
            uint8_t tmp = t[0];
            t[0] = (uint8_t)(SBOX[t[1]] ^ RCON[i / 4 - 1]);
            t[1] = SBOX[t[2]];
            t[2] = SBOX[t[3]];
            t[3] = SBOX[tmp];
        }
        for (int j = 0; j < 4; j++) {
            rk[i * 4 + j] = (uint8_t)(rk[(size_t)(i - 4) * 4 + j] ^ t[j]);
        }
    }
}

static void add_round_key(uint8_t s[16], const uint8_t *rk) {
    for (int i = 0; i < 16; i++) s[i] ^= rk[i];
}

static void sub_bytes(uint8_t s[16]) {
    for (int i = 0; i < 16; i++) s[i] = SBOX[s[i]];
}

/* 状态按列优先：s[r + 4c] */
static void shift_rows(uint8_t s[16]) {
    uint8_t t = s[1];
    s[1] = s[5];  s[5] = s[9];  s[9] = s[13]; s[13] = t;
    t = s[2];  s[2] = s[10]; s[10] = t;
    t = s[6];  s[6] = s[14]; s[14] = t;
    t = s[15]; s[15] = s[11]; s[11] = s[7]; s[7] = s[3]; s[3] = t;
}

static void mix_columns(uint8_t s[16]) {
    for (int c = 0; c < 4; c++) {
        uint8_t *p = s + c * 4;
        uint8_t a0 = p[0], a1 = p[1], a2 = p[2], a3 = p[3];
        p[0] = (uint8_t)(xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3);
        p[1] = (uint8_t)(a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3);
        p[2] = (uint8_t)(a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3));
        p[3] = (uint8_t)((xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3));
    }
}

void fdm_aes128_encrypt_block(const uint8_t in[16], const uint8_t key[16],
                              uint8_t out[16]) {
    uint8_t rk[176];
    uint8_t s[16];
    aes128_expand_key(key, rk);
    memcpy(s, in, 16);

    add_round_key(s, rk);
    for (int round = 1; round <= 9; round++) {
        sub_bytes(s);
        shift_rows(s);
        mix_columns(s);
        add_round_key(s, rk + round * 16);
    }
    /* 最后一轮没有 MixColumns */
    sub_bytes(s);
    shift_rows(s);
    add_round_key(s, rk + 10 * 16);
    memcpy(out, s, 16);
}

/* PKCS7 填充 + ECB 加密 */
uint8_t *fdm_aes128_ecb_pkcs7(const uint8_t *in, size_t inlen,
                              const uint8_t key[16], size_t *outlen) {
    if (!key || !outlen) return NULL;
    if (!in && inlen) return NULL;

    size_t pad = 16 - (inlen % 16);
    size_t total = inlen + pad;
    uint8_t *buf = (uint8_t *)malloc(total ? total : 16);
    if (!buf) return NULL;

    if (inlen) memcpy(buf, in, inlen);
    memset(buf + inlen, (int)pad, pad);

    uint8_t *out = (uint8_t *)malloc(total ? total : 16);
    if (!out) {
        free(buf);
        return NULL;
    }
    for (size_t off = 0; off < total; off += 16) {
        fdm_aes128_encrypt_block(buf + off, key, out + off);
    }
    free(buf);
    *outlen = total;
    return out;
}

/* PKCS7 填充 + CBC 加密 */
uint8_t *fdm_aes128_cbc_pkcs7(const uint8_t *in, size_t inlen,
                              const uint8_t key[16], const uint8_t iv[16],
                              size_t *outlen) {
    if (!key || !iv || !outlen) return NULL;
    if (!in && inlen) return NULL;

    size_t pad = 16 - (inlen % 16);
    size_t total = inlen + pad;
    uint8_t *buf = (uint8_t *)malloc(total ? total : 16);
    if (!buf) return NULL;

    if (inlen) memcpy(buf, in, inlen);
    memset(buf + inlen, (int)pad, pad);

    uint8_t *out = (uint8_t *)malloc(total ? total : 16);
    if (!out) {
        free(buf);
        return NULL;
    }

    uint8_t prev[16];
    memcpy(prev, iv, 16);
    for (size_t off = 0; off < total; off += 16) {
        uint8_t x[16];
        for (int i = 0; i < 16; i++) x[i] = (uint8_t)(buf[off + (size_t)i] ^ prev[i]);
        fdm_aes128_encrypt_block(x, key, out + off);
        memcpy(prev, out + off, 16);
    }
    free(buf);
    *outlen = total;
    return out;
}

/* ══════════════════════════════════════════════════════════════════════════
 *  二、MD5（RFC 1321）
 * ══════════════════════════════════════════════════════════════════════════ */

#define MD5_F(x, y, z) (((x) & (y)) | (~(x) & (z)))
#define MD5_G(x, y, z) (((x) & (z)) | ((y) & ~(z)))
#define MD5_H(x, y, z) ((x) ^ (y) ^ (z))
#define MD5_I(x, y, z) ((y) ^ ((x) | ~(z)))
#define ROTL32(x, n)   (((x) << (n)) | ((x) >> (32 - (n))))

static const uint32_t MD5_K[64] = {
    0xd76aa478u, 0xe8c7b756u, 0x242070dbu, 0xc1bdceeeu,
    0xf57c0fafu, 0x4787c62au, 0xa8304613u, 0xfd469501u,
    0x698098d8u, 0x8b44f7afu, 0xffff5bb1u, 0x895cd7beu,
    0x6b901122u, 0xfd987193u, 0xa679438eu, 0x49b40821u,
    0xf61e2562u, 0xc040b340u, 0x265e5a51u, 0xe9b6c7aau,
    0xd62f105du, 0x02441453u, 0xd8a1e681u, 0xe7d3fbc8u,
    0x21e1cde6u, 0xc33707d6u, 0xf4d50d87u, 0x455a14edu,
    0xa9e3e905u, 0xfcefa3f8u, 0x676f02d9u, 0x8d2a4c8au,
    0xfffa3942u, 0x8771f681u, 0x6d9d6122u, 0xfde5380cu,
    0xa4beea44u, 0x4bdecfa9u, 0xf6bb4b60u, 0xbebfbc70u,
    0x289b7ec6u, 0xeaa127fau, 0xd4ef3085u, 0x04881d05u,
    0xd9d4d039u, 0xe6db99e5u, 0x1fa27cf8u, 0xc4ac5665u,
    0xf4292244u, 0x432aff97u, 0xab9423a7u, 0xfc93a039u,
    0x655b59c3u, 0x8f0ccc92u, 0xffeff47du, 0x85845dd1u,
    0x6fa87e4fu, 0xfe2ce6e0u, 0xa3014314u, 0x4e0811a1u,
    0xf7537e82u, 0xbd3af235u, 0x2ad7d2bbu, 0xeb86d391u,
};

static const uint8_t MD5_S[64] = {
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
};

static void md5_block(uint32_t st[4], const uint8_t blk[64]) {
    uint32_t m[16];
    for (int i = 0; i < 16; i++) {
        m[i] = (uint32_t)blk[i * 4] |
               ((uint32_t)blk[i * 4 + 1] << 8) |
               ((uint32_t)blk[i * 4 + 2] << 16) |
               ((uint32_t)blk[i * 4 + 3] << 24);
    }
    uint32_t a = st[0], b = st[1], c = st[2], d = st[3];
    for (int i = 0; i < 64; i++) {
        uint32_t f;
        int g;
        if (i < 16) {
            f = MD5_F(b, c, d);
            g = i;
        } else if (i < 32) {
            f = MD5_G(b, c, d);
            g = (5 * i + 1) % 16;
        } else if (i < 48) {
            f = MD5_H(b, c, d);
            g = (3 * i + 5) % 16;
        } else {
            f = MD5_I(b, c, d);
            g = (7 * i) % 16;
        }
        uint32_t tmp = d;
        d = c;
        c = b;
        b = b + ROTL32(a + f + MD5_K[i] + m[g], MD5_S[i]);
        a = tmp;
    }
    st[0] += a;
    st[1] += b;
    st[2] += c;
    st[3] += d;
}

void fdm_md5(const uint8_t *data, size_t len, uint8_t out[16]) {
    uint32_t st[4] = {0x67452301u, 0xefcdab89u, 0x98badcfeu, 0x10325476u};
    size_t full = len / 64;
    for (size_t i = 0; i < full; i++) md5_block(st, data + i * 64);

    /* 尾部 + padding（0x80 + 0… + 64-bit 小端长度） */
    uint8_t tail[128];
    size_t rem = len - full * 64;
    memset(tail, 0, sizeof(tail));
    if (rem) memcpy(tail, data + full * 64, rem);
    tail[rem] = 0x80;
    size_t tail_len = (rem + 1 + 8 <= 64) ? 64 : 128;
    uint64_t bits = (uint64_t)len * 8u;
    for (int i = 0; i < 8; i++) {
        tail[tail_len - 8 + (size_t)i] = (uint8_t)((bits >> (8 * i)) & 0xff);
    }
    md5_block(st, tail);
    if (tail_len == 128) md5_block(st, tail + 64);

    for (int i = 0; i < 4; i++) {
        out[i * 4]     = (uint8_t)(st[i] & 0xff);
        out[i * 4 + 1] = (uint8_t)((st[i] >> 8) & 0xff);
        out[i * 4 + 2] = (uint8_t)((st[i] >> 16) & 0xff);
        out[i * 4 + 3] = (uint8_t)((st[i] >> 24) & 0xff);
    }
}

/* ══════════════════════════════════════════════════════════════════════════
 *  三、编码工具
 * ══════════════════════════════════════════════════════════════════════════ */

char *fdm_hex_lower(const uint8_t *b, size_t n) {
    static const char *H = "0123456789abcdef";
    char *s = (char *)malloc(n * 2 + 1);
    if (!s) return NULL;
    for (size_t i = 0; i < n; i++) {
        s[i * 2] = H[b[i] >> 4];
        s[i * 2 + 1] = H[b[i] & 0x0f];
    }
    s[n * 2] = '\0';
    return s;
}

char *fdm_hex_upper(const uint8_t *b, size_t n) {
    static const char *H = "0123456789ABCDEF";
    char *s = (char *)malloc(n * 2 + 1);
    if (!s) return NULL;
    for (size_t i = 0; i < n; i++) {
        s[i * 2] = H[b[i] >> 4];
        s[i * 2 + 1] = H[b[i] & 0x0f];
    }
    s[n * 2] = '\0';
    return s;
}

void fdm_md5_hex(const char *s, char out[33]) {
    uint8_t d[16];
    if (!s) s = "";
    fdm_md5((const uint8_t *)s, strlen(s), d);
    char *h = fdm_hex_lower(d, 16);
    if (h) {
        memcpy(out, h, 33); /* 含 '\0' */
        free(h);
    } else {
        out[0] = '\0';
    }
}

static const char B64TAB[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

char *fdm_base64_encode(const uint8_t *b, size_t n) {
    size_t olen = ((n + 2) / 3) * 4;
    char *out = (char *)malloc(olen + 1);
    if (!out) return NULL;
    size_t o = 0;
    for (size_t i = 0; i < n; i += 3) {
        size_t rem = n - i;
        uint32_t v = (uint32_t)b[i] << 16;
        if (rem > 1) v |= (uint32_t)b[i + 1] << 8;
        if (rem > 2) v |= (uint32_t)b[i + 2];
        out[o++] = B64TAB[(v >> 18) & 0x3f];
        out[o++] = B64TAB[(v >> 12) & 0x3f];
        out[o++] = (rem > 1) ? B64TAB[(v >> 6) & 0x3f] : '=';
        out[o++] = (rem > 2) ? B64TAB[v & 0x3f] : '=';
    }
    out[o] = '\0';
    return out;
}

static int b64_val(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

uint8_t *fdm_base64_decode(const char *s, size_t *outlen) {
    if (!s || !outlen) return NULL;
    size_t n = strlen(s);
    while (n && (s[n - 1] == '=' || s[n - 1] == '\n' || s[n - 1] == '\r')) n--;
    uint8_t *out = (uint8_t *)malloc(n / 4 * 3 + 4);
    if (!out) return NULL;
    size_t o = 0;
    uint32_t acc = 0;
    int bits = 0;
    for (size_t i = 0; i < n; i++) {
        int v = b64_val(s[i]);
        if (v < 0) continue;
        acc = (acc << 6) | (uint32_t)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[o++] = (uint8_t)((acc >> bits) & 0xff);
        }
    }
    *outlen = o;
    return out;
}

/* ══════════════════════════════════════════════════════════════════════════
 *  四、RSA 回调
 * ══════════════════════════════════════════════════════════════════════════ */

static fdm_rsa_raw_fn g_rsa = NULL;

void fdm_music_set_rsa(fdm_rsa_raw_fn fn) { g_rsa = fn; }

/* ══════════════════════════════════════════════════════════════════════════
 *  五、三个通道
 * ══════════════════════════════════════════════════════════════════════════ */

char *fdm_music_eapi(const char *uri, const char *json) {
    if (!uri) uri = "";
    if (!json) json = "";

    /* digest = md5("nobody" + uri + "use" + json + "md5forencrypt") */
    size_t need = 6 + strlen(uri) + 3 + strlen(json) + 14 + 1;
    char *src = (char *)malloc(need);
    if (!src) return NULL;
    snprintf(src, need, "nobody%suse%smd5forencrypt", uri, json);

    char digest[33];
    fdm_md5_hex(src, digest);
    free(src);

    /* data = uri + SEP + json + SEP + digest */
    size_t dlen = strlen(uri) + strlen(FDM_MUSIC_EAPI_SEP) + strlen(json) +
                  strlen(FDM_MUSIC_EAPI_SEP) + strlen(digest);
    char *data = (char *)malloc(dlen + 1);
    if (!data) return NULL;
    snprintf(data, dlen + 1, "%s%s%s%s%s", uri, FDM_MUSIC_EAPI_SEP, json,
             FDM_MUSIC_EAPI_SEP, digest);

    size_t enc_len = 0;
    uint8_t *enc = fdm_aes128_ecb_pkcs7((const uint8_t *)data, dlen,
                                        (const uint8_t *)FDM_MUSIC_EAPI_KEY,
                                        &enc_len);
    free(data);
    if (!enc) return NULL;
    char *hex = fdm_hex_upper(enc, enc_len);
    free(enc);
    return hex;
}

char *fdm_music_linuxapi(const char *json) {
    if (!json) json = "";
    size_t enc_len = 0;
    uint8_t *enc = fdm_aes128_ecb_pkcs7((const uint8_t *)json, strlen(json),
                                        (const uint8_t *)FDM_MUSIC_LINUX_KEY,
                                        &enc_len);
    if (!enc) return NULL;
    char *hex = fdm_hex_upper(enc, enc_len);
    free(enc);
    return hex;
}

void fdm_music_random_secret(char out[17]) {
    static int seeded = 0;
    if (!seeded) {
        unsigned int seed = (unsigned int)time(NULL) ^ (unsigned int)(uintptr_t)out;
        srand(seed);
        seeded = 1;
    }
    for (int i = 0; i < 16; i++) {
        out[i] = FDM_MUSIC_BASE62[rand() % 62];
    }
    out[16] = '\0';
}

int fdm_music_weapi(const char *json, const char *secret_key,
                    char **out_params, char **out_enc_sec_key) {
    if (!json) json = "";
    if (!out_params || !out_enc_sec_key) return -1;
    *out_params = NULL;
    *out_enc_sec_key = NULL;

    char sk[17];
    if (secret_key && strlen(secret_key) >= 16) {
        memcpy(sk, secret_key, 16);
        sk[16] = '\0';
    } else {
        fdm_music_random_secret(sk);
    }

    /* 第一层：json --(PRESET_KEY, IV)--> Base64 */
    size_t l1 = 0;
    uint8_t *e1 = fdm_aes128_cbc_pkcs7((const uint8_t *)json, strlen(json),
                                       (const uint8_t *)FDM_MUSIC_PRESET_KEY,
                                       (const uint8_t *)FDM_MUSIC_IV, &l1);
    if (!e1) return -2;
    char *b1 = fdm_base64_encode(e1, l1);
    free(e1);
    if (!b1) return -2;

    /* 第二层：Base64 文本 --(secretKey, IV)--> Base64 */
    size_t l2 = 0;
    uint8_t *e2 = fdm_aes128_cbc_pkcs7((const uint8_t *)b1, strlen(b1),
                                       (const uint8_t *)sk,
                                       (const uint8_t *)FDM_MUSIC_IV, &l2);
    free(b1);
    if (!e2) return -2;
    char *params = fdm_base64_encode(e2, l2);
    free(e2);
    if (!params) return -2;

    /* encSecKey = RSA_RAW(reverse(secretKey)) */
    if (!g_rsa) {
        free(params);
        return -3; /* 没注册 RSA 实现 */
    }
    char rev[17];
    for (int i = 0; i < 16; i++) rev[i] = sk[15 - i];
    rev[16] = '\0';

    uint8_t rsa_out[128];
    if (g_rsa((const uint8_t *)rev, 16, rsa_out) != 0) {
        free(params);
        return -4;
    }
    char *enc = fdm_hex_upper(rsa_out, 128);
    if (!enc) {
        free(params);
        return -5;
    }

    *out_params = params;
    *out_enc_sec_key = enc;
    return 0;
}

/* ══════════════════════════════════════════════════════════════════════════
 *  六、自检
 * ══════════════════════════════════════════════════════════════════════════ */

static int chk(char *err, size_t errlen, int no, const char *what,
               const char *got, const char *want) {
    if (got && want && strcmp(got, want) == 0) return 0;
    snprintf(err, errlen, "#%d %s\n  got : %s\n  want: %s", no, what,
             got ? got : "(null)", want ? want : "(null)");
    return no;
}

int fdm_music_selftest(char *errbuf, size_t errlen) {
    char err[512];
    if (!errbuf) {
        errbuf = err;
        errlen = sizeof(err);
    }
    errbuf[0] = '\0';

    /* ── MD5 / RFC 1321 ── */
    {
        char h[33];
        fdm_md5_hex("", h);
        int r = chk(errbuf, errlen, 1, "md5(\"\")", h,
                    "d41d8cd98f00b204e9800998ecf8427e");
        if (r) return r;
        fdm_md5_hex("abc", h);
        r = chk(errbuf, errlen, 2, "md5(\"abc\")", h,
                "900150983cd24fb0d6963f7d28e17f72");
        if (r) return r;
        fdm_md5_hex("message digest", h);
        r = chk(errbuf, errlen, 3, "md5(\"message digest\")", h,
                "f96b697d7cb7938d525a2f31aaf161d0");
        if (r) return r;
        fdm_md5_hex("abcdefghijklmnopqrstuvwxyz", h);
        r = chk(errbuf, errlen, 4, "md5(a..z)", h,
                "c3fcd3d76192e4007dfb496cca67e13b");
        if (r) return r;
    }

    /* ── AES-128 / FIPS-197 附录 C.1 ── */
    {
        const uint8_t key[16] = {0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
                                 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f};
        const uint8_t pt[16] = {0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                                0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff};
        uint8_t ct[16];
        fdm_aes128_encrypt_block(pt, key, ct);
        char *hex = fdm_hex_lower(ct, 16);
        int r = chk(errbuf, errlen, 5, "aes128(fips197 C.1)", hex,
                    "69c4e0d86a7b0430d8cdb78070b4c55a");
        free(hex);
        if (r) return r;
    }

    /* ── AES-128-ECB + PKCS7：「16 字节整块」和「17 字节补两块」 ── */
    {
        const uint8_t key[16] = {0};
        size_t n = 0;
        uint8_t *out = fdm_aes128_ecb_pkcs7(NULL, 0, key, &n);
        if (!out || n != 16) {
            free(out);
            snprintf(errbuf, errlen, "#6 空输入 ECB 应该补一整块（16 字节），得到 %zu", n);
            return 6;
        }
        free(out);

        const uint8_t one[1] = {0x41};
        out = fdm_aes128_ecb_pkcs7(one, 1, key, &n);
        if (!out || n != 16) {
            free(out);
            snprintf(errbuf, errlen, "#7 1 字节输入 ECB 应该得到 16 字节，得到 %zu", n);
            return 7;
        }
        free(out);

        uint8_t sixteen[16] = {0};
        out = fdm_aes128_ecb_pkcs7(sixteen, 16, key, &n);
        if (!out || n != 32) {
            free(out);
            snprintf(errbuf, errlen, "#8 16 字节输入 ECB 应该补成 32 字节，得到 %zu", n);
            return 8;
        }
        free(out);
    }

    /* ── Base64 ── */
    {
        char *b = fdm_base64_encode((const uint8_t *)"hello world", 11);
        int r = chk(errbuf, errlen, 9, "base64(\"hello world\")", b,
                    "aGVsbG8gd29ybGQ=");
        free(b);
        if (r) return r;

        size_t n = 0;
        uint8_t *d = fdm_base64_decode("aGVsbG8gd29ybGQ=", &n);
        if (!d || n != 11 || memcmp(d, "hello world", 11) != 0) {
            free(d);
            snprintf(errbuf, errlen, "#10 base64 解码回环失败");
            return 10;
        }
        free(d);
    }

    /* ── 通道层固定向量（与 Java 版 GmMusicCrypto 的输出逐字节对齐）── */
    {
        char *h = fdm_music_linuxapi("{}");
        int r = chk(errbuf, errlen, 11, "linuxapi(\"{}\")", h,
                    "FA2B50F4B4B3202B91408D3B10E83D55");
        free(h);
        if (r) return r;

        char *e = fdm_music_eapi("/api/x", "{}");
        r = chk(errbuf, errlen, 12, "eapi(\"/api/x\",\"{}\")", e,
                "D491EC3F25D615CBF708BAD78E56B20247525EC1C935138EBF422AA93B56B0DC"
                "D54B693242274186A444FE5A6DD2E94E4BDC10463D74A8B00455DBD9FF59745F"
                "80EB359946722B4CEC3B494F201797F4");
        free(e);
        if (r) return r;
    }

    return 0;
}
