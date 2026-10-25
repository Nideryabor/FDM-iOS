import com.nidyaber.fuckdsmanger.music.*;
import java.util.*;

public class MusicSmoke {
    static void p(Object o) { System.out.println(o); }

    public static void main(String[] a) throws Exception {
        // 0) 纯算法自检：固定向量
        p("== crypto ==");
        p("md5(\"\")      = " + GmMusicCrypto.md5Hex(""));
        p("md5(\"abc\")   = " + GmMusicCrypto.md5Hex("abc"));
        p("linuxapi({})  = " + GmMusicCrypto.linuxapi("{}"));
        p("eapi(/api/x,{}) = " + GmMusicCrypto.eapi("/api/x", "{}"));
        String[] w = GmMusicCrypto.weapi("{\"a\":1}");
        p("weapi.params  len=" + w[0].length());
        p("weapi.encSecKey len=" + w[1].length() + " head=" + w[1].substring(0, 16));

        // 1) 搜索
        p("\n== search ==");
        List<Map<String,Object>> songs = GmMusicApi.search("晴天", 3, 0);
        p("count=" + songs.size() + " code=" + GmMusicApi.lastCode());
        for (Map<String,Object> s : songs) p("  " + s.get("id") + " | " + s.get("name") + " | " + s.get("artist") + " | " + s.get("album") + " | pic=" + (String.valueOf(s.get("picUrl")).length()>40 ? "yes" : "no") + " | dt=" + s.get("duration"));

        if (!songs.isEmpty()) {
            long id = ((Number) songs.get(0).get("id")).longValue();
            // 2) 播放地址
            p("\n== songUrl(" + id + ") ==");
            for (String lv : new String[]{"standard","exhigh","lossless"}) {
                Map<String,Object> u = GmMusicApi.songUrl(id, lv);
                String url = (String) u.get("url");
                p("  " + lv + ": code=" + u.get("code") + " br=" + u.get("br") + " type=" + u.get("type") + " fee=" + u.get("fee") + " url=" + (url==null||url.isEmpty()?"(空)":url.substring(0, Math.min(70,url.length()))+"…"));
            }
            // 3) 歌词
            p("\n== lyric(" + id + ") ==");
            Map<String,Object> ly = GmMusicApi.lyric(id);
            String lrc = (String) ly.get("lrc");
            p("  code=" + ly.get("code") + " lrcLen=" + lrc.length() + " tlrcLen=" + String.valueOf(ly.get("tlrc")).length());
            p("  head: " + lrc.substring(0, Math.min(80, lrc.length())).replace("\n","\\n"));
            // 4) detail
            p("\n== songDetail ==");
            for (Map<String,Object> d : GmMusicApi.songDetail(Arrays.asList(id)))
                p("  " + d.get("name") + " / " + d.get("artist") + " pic=" + (String.valueOf(d.get("picUrl")).length()>40?"yes":"no"));
        }
    }
}
