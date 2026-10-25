// 对拍测试：C 版 FDMMusicCrypto vs Java 版 GmMusicCrypto
//   gcc -O2 -Wall -o test_crypto test_crypto.c fdm_music_crypto.c -lcrypto
//
// 期望值全部由 `java CryptoVec`（真跑 GmMusicCrypto.java）打印出来，
// 手抄进下面的表里 —— 不是"C 自己跟自己比"。
#define OPENSSL_SUPPRESS_DEPRECATED 1
#include "FDMMusicCrypto.h"

#include <openssl/evp.h>
#include <openssl/x509.h>
#include <openssl/rsa.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_fail = 0;

static void eq(const char *what, const char *got, const char *want) {
    int ok = got && want && strcmp(got, want) == 0;
    printf("%s %-22s %s\n", ok ? "  ok  " : " FAIL ", what,
           ok ? "" : (got ? got : "(null)"));
    if (!ok) {
        printf("        want: %s\n", want ? want : "(null)");
        g_fail++;
    }
}

/* ── Linux 侧 RSA：openssl，RSA_NO_PADDING，输入左补 0 到 128 字节 ── */
static RSA *g_pub = NULL;

static void load_pub(void) {
    size_t derlen = 0;
    uint8_t *der = fdm_base64_decode(FDM_MUSIC_RSA_PUB_B64, &derlen);
    if (!der) {
        fprintf(stderr, "base64 decode pub key failed\n");
        return;
    }
    const unsigned char *p = der;
    EVP_PKEY *pk = d2i_PUBKEY(NULL, &p, (long)derlen);
    free(der);
    if (!pk) {
        fprintf(stderr, "d2i_PUBKEY failed\n");
        return;
    }
    g_pub = EVP_PKEY_get1_RSA(pk);
    EVP_PKEY_free(pk);
}

static int openssl_rsa_raw(const uint8_t *in, size_t inlen, uint8_t out[128]) {
    if (!g_pub) return -1;
    if (inlen > 128) return -2;
    uint8_t buf[128];
    memset(buf, 0, sizeof(buf));
    memcpy(buf + (128 - inlen), in, inlen);
    int n = RSA_public_encrypt(128, buf, out, g_pub, RSA_NO_PADDING);
    return n == 128 ? 0 : -3;
}

static char *aes_hex_upper(const char *text, const char *key, const char *iv,
                           int cbc) {
    size_t n = 0;
    uint8_t *e = cbc ? fdm_aes128_cbc_pkcs7((const uint8_t *)text, strlen(text),
                                            (const uint8_t *)key,
                                            (const uint8_t *)iv, &n)
                     : fdm_aes128_ecb_pkcs7((const uint8_t *)text, strlen(text),
                                            (const uint8_t *)key, &n);
    if (!e) return NULL;
    char *h = fdm_hex_upper(e, n);
    free(e);
    return h;
}

static char *aes_b64(const char *text, const char *key, const char *iv) {
    size_t n = 0;
    uint8_t *e = fdm_aes128_cbc_pkcs7((const uint8_t *)text, strlen(text),
                                      (const uint8_t *)key, (const uint8_t *)iv,
                                      &n);
    if (!e) return NULL;
    char *b = fdm_base64_encode(e, n);
    free(e);
    return b;
}

int main(void) {
    char err[512];
    int r = fdm_music_selftest(err, sizeof(err));
    if (r) {
        printf("SELFTEST FAIL #%d\n%s\n", r, err);
        return 1;
    }
    printf("SELFTEST OK（MD5 RFC1321 / AES FIPS-197 / 通道固定向量）\n\n");

    load_pub();
    fdm_music_set_rsa(openssl_rsa_raw);

    printf("── 与 Java GmMusicCrypto 对拍 ──\n");

    char h[33];
    fdm_md5_hex("", h);
    eq("md5(\"\")", h, "d41d8cd98f00b204e9800998ecf8427e");
    fdm_md5_hex("abc", h);
    eq("md5(\"abc\")", h, "900150983cd24fb0d6963f7d28e17f72");

    char *t;
    t = fdm_music_linuxapi("{}");
    eq("linuxapi({})", t, "FA2B50F4B4B3202B91408D3B10E83D55");
    free(t);

    t = fdm_music_eapi("/api/x", "{}");
    eq("eapi(/api/x,{})", t,
       "D491EC3F25D615CBF708BAD78E56B20247525EC1C935138EBF422AA93B56B0DC"
       "D54B693242274186A444FE5A6DD2E94E4BDC10463D74A8B00455DBD9FF59745F"
       "80EB359946722B4CEC3B494F201797F4");
    free(t);

    /* 两次 AES-CBC 的中间层（把 weapi 拆开对拍，错在哪一层一眼看出） */
    const char *IV = "0102030405060708";
    const char *PRESET = "0CoJUm6Qyw8W8jud";

    t = aes_b64("{\"a\":1}", PRESET, IV);
    eq("inner1", t, "U7nqija8yGUt9t6SPGXNjQ==");
    free(t);

    t = aes_b64("U7nqija8yGUt9t6SPGXNjQ==", "abcdefghijklmnop", IV);
    eq("params1", t, "Ho/4Pu1bYyrzwcnXPnTcXm1Gb04eSzwGSNb4NI3YqZY=");
    free(t);

    t = aes_b64("{\"phone\":\"13800000000\",\"countrycode\":\"86\",\"password\":\"x\"}",
                PRESET, IV);
    eq("inner2", t,
       "zkelmeLJ1ing8Gx1kSiGZEsYkQnWg6Eef6TzBOf02g/Qw9P2YBrN1Jb8GafguN9qmgNlnDROlyHwZ8t7aI6rng==");
    free(t);

    t = aes_b64("zkelmeLJ1ing8Gx1kSiGZEsYkQnWg6Eef6TzBOf02g/Qw9P2YBrN1Jb8GafguN9qmgNlnDROlyHwZ8t7aI6rng==",
                "0123456789ABCDEF", IV);
    eq("params2", t,
       "j5g+72VMyD1mNRw+GhikcAu7j3FQhxJxM+GYKQg2LwII/hABf8XCuovav8mGGX+DLSP7OuH1i7IMTHftVJK5hA0+Fm5tGVHFhxwLd9INlnCHHcFqWlKmPs8GXaoTbV7X");
    free(t);

    /* padding 边界：16 字节要补整整一块 */
    t = aes_hex_upper("0123456789abcdefg", "0123456789abcdef", NULL, 0);
    eq("aes_ecb_17", t,
       "72727E881EDCFD0100A718687909B56533320F82A2CF52CB0E27A5A7177AB405");
    free(t);

    t = aes_hex_upper("0123456789abcdef", "0123456789abcdef", NULL, 0);
    eq("aes_ecb_16", t,
       "72727E881EDCFD0100A718687909B565377222E061A924C591CD9C27EA163ED4");
    free(t);

    t = aes_b64("0123456789abcdefg", "0123456789abcdef", IV);
    eq("aes_cbc_17", t, "/ydWwxWOw3Wiz+t9zYkBFSWiTYftGNBkhWTuxYTfQ3E=");
    free(t);

    t = aes_b64("晴天", "0123456789abcdef", IV);
    eq("aes_cbc_cn", t, "6PYNYpWAVoy5dfnu4blt0Q==");
    free(t);

    /* ── weapi 全链（固定 secretKey）── */
    char *params = NULL, *enc = NULL;
    int rc = fdm_music_weapi("{\"a\":1}", "abcdefghijklmnop", &params, &enc);
    printf("  weapi rc=%d\n", rc);
    eq("weapi.params1", params,
       "Ho/4Pu1bYyrzwcnXPnTcXm1Gb04eSzwGSNb4NI3YqZY=");
    eq("weapi.enc1", enc,
       "D15A1683C992095D0C234C19966605C5C5964911268BBEDA8CB8D08D834913E5"
       "9D53B32358903A121B5FCA784C1F5AE44951FD02524DF58ECC98E52CC7CF8689"
       "B42C2E93DDF05B0592512D87F5960467E2F086C018849D76014D323500E30F13"
       "EF4CAFBB0CF5A66731A3F1776C75CA35D0062DAC70A3E33245AFABCF47938487");
    free(params);
    free(enc);

    params = enc = NULL;
    rc = fdm_music_weapi("{\"phone\":\"13800000000\",\"countrycode\":\"86\",\"password\":\"x\"}",
                         "0123456789ABCDEF", &params, &enc);
    printf("  weapi2 rc=%d\n", rc);
    eq("weapi.params2", params,
       "j5g+72VMyD1mNRw+GhikcAu7j3FQhxJxM+GYKQg2LwII/hABf8XCuovav8mGGX+DLSP7OuH1i7IMTHftVJK5hA0+Fm5tGVHFhxwLd9INlnCHHcFqWlKmPs8GXaoTbV7X");
    eq("weapi.enc2", enc,
       "76B7934417BC7E2C67D6F91CE791B7B5E0097C20CBF92FD92E28E732C2A4A8F3"
       "9F32BB5994988CC3C9D3E4E70F7976FCE22C6DE0A6FA903EB7198C5AE8DA9C11"
       "D1DA84E1792EBE1EA7FCE9EE7C6D6A6E6CB9AAE484A023A0C5C46842D8D96D66"
       "01156201A48F8BBBF51E4EC34E598DE36BB70A80BE3A6A223751A8C27B749269");
    free(params);
    free(enc);

    printf("\n%s（fail=%d）\n", g_fail ? "有失败" : "全部一致 ✅", g_fail);
    return g_fail ? 1 : 0;
}
