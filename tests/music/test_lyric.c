#include "FDMLyric.h"
#include <stdio.h>
int main(void) {
    char err[512];
    int r = fdmlrc_selftest(err, sizeof(err));
    if (r) { printf("SELFTEST FAIL\n%s\n", err); return 1; }
    printf("FDMLyric SELFTEST OK（15 组断言）\n");

    const char *src =
        "[00:00.000] 作词 : Lucky 小爱\n"
        "[00:01.000] 作曲 : Lucky 小爱\n"
        "[00:30.542]故事的小黄花\n"
        "[00:34.165]从出生那年就飘着\n"
        "[00:38.000]童年的荡秋千\n";
    fdmlrc d; fdmlrc_parse(src, &d);
    for (long long t = 0; t <= 40000; t += 10000) {
        const char *c,*p,*x;
        fdmlrc_around(&d, t, &c, &p, &x);
        printf("%5lldms  [%s]  ← prev[%s] next[%s]\n", t, c, p, x);
    }
    fdmlrc_free(&d);
    return 0;
}
