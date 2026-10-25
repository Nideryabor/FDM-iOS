import com.nidyaber.fuckdsmanger.music.GmMusicCrypto;

public class CryptoVec {
    static void p(String k, String v) { System.out.println(k + "=" + v); }
    public static void main(String[] a) throws Exception {
        String IV = "0102030405060708";
        String PRESET = "0CoJUm6Qyw8W8jud";
        String SK = "abcdefghijklmnop";

        p("md5_empty", GmMusicCrypto.md5Hex(""));
        p("md5_abc", GmMusicCrypto.md5Hex("abc"));
        p("linuxapi_empty_obj", GmMusicCrypto.linuxapi("{}"));
        p("eapi_slash_x", GmMusicCrypto.eapi("/api/x", "{}"));

        String json1 = "{\"a\":1}";
        String inner1 = GmMusicCrypto.aesBase64(json1, PRESET, IV, "CBC");
        String params1 = GmMusicCrypto.aesBase64(inner1, SK, IV, "CBC");
        p("inner1", inner1);
        p("params1", params1);
        p("enc1", GmMusicCrypto.rsaRawHex(new StringBuilder(SK).reverse().toString()));

        String json2 = "{\"phone\":\"13800000000\",\"countrycode\":\"86\",\"password\":\"x\"}";
        String SK2 = "0123456789ABCDEF";
        String inner2 = GmMusicCrypto.aesBase64(json2, PRESET, IV, "CBC");
        String params2 = GmMusicCrypto.aesBase64(inner2, SK2, IV, "CBC");
        p("inner2", inner2);
        p("params2", params2);
        p("enc2", GmMusicCrypto.rsaRawHex(new StringBuilder(SK2).reverse().toString()));

        // 17 字节（跨块）的 ECB，验证 padding 不是"只在末尾补 0"
        p("aes_ecb_17", GmMusicCrypto.aesHexUpper("0123456789abcdefg", "0123456789abcdef", null, "ECB"));
        // 边界：16 字节整块 ⇒ 应该补出一整块
        p("aes_ecb_16", GmMusicCrypto.aesHexUpper("0123456789abcdef", "0123456789abcdef", null, "ECB"));
        // CBC 17 字节
        p("aes_cbc_17", GmMusicCrypto.aesBase64("0123456789abcdefg", "0123456789abcdef", IV, "CBC"));
        // 中文 UTF-8
        p("aes_cbc_cn", GmMusicCrypto.aesBase64("晴天", "0123456789abcdef", IV, "CBC"));
    }
}
