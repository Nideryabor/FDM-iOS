#include "FDMPromptVars.h"
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    char err[512];
    int r = fdmpv_selftest(err, sizeof(err));
    if (r) { printf("SELFTEST FAIL\n%s\n", err); return 1; }
    printf("FDMPromptVars SELFTEST OK（20 条用例）\n");

    fdmpv_snap sn = {0};
    sn.enabled = 1;
    sn.song = "晴天"; sn.artist = "周杰伦"; sn.album = "叶惠美";
    sn.pos_ms = 83000; sn.dur_ms = 269000; sn.playing = 1;
    sn.lyric_on = 1; sn.lyric = "故事的小黄花";
    sn.lyric_prev = "作曲 : 周杰伦"; sn.lyric_next = "从出生那年就飘着";

    const char *tmpl =
        "【音乐变量】下面两行是发消息那一刻我在听的歌：\n"
        "[[正在听：{music}]]\n"
        "[[当前唱到：{lyric}]]\n"
        "上一句：{lyric_prev} / 下一句：{lyric_next}\n"
        "[[专辑：{album}]]\n"
        "[[普通方括号]]";
    char *out = fdmpv_resolve(tmpl, &sn);
    printf("\n--- 有歌 ---\n%s\n", out);
    free(out);

    fdmpv_snap idle = {0};
    idle.enabled = 1;
    out = fdmpv_resolve(tmpl, &idle);
    printf("\n--- 没歌 ---\n%s\n", out);
    free(out);

    fdmpv_snap off = {0};
    out = fdmpv_resolve(tmpl, &off);
    printf("\n--- 开关关 ---\n%s\n", out);
    free(out);
    return 0;
}
