#include "FDMBubbleStyle.h"
#include <stdio.h>

int main(void) {
    char err[512];
    int r = fdmbubble_selftest(err, sizeof(err));
    if (r) { printf("SELFTEST FAIL\n%s\n", err); return 1; }
    printf("FDMBubbleStyle SELFTEST OK（30 组断言）\n\n");

    printf("200x200 图片 -> 300x200 容器：\n");
    printf("%-10s %-22s %-22s\n", "锚点", "cover", "contain");
    const char *names[] = {"center","top","bottom","left","right","tl","tr","bl","br"};
    for (int a = 0; a <= 8; a++) {
        fdmrect c = fdmbubble_image_rect(200,200,300,200,FDMBubbleScaleCover,(FDMBubbleAnchor)a,0);
        fdmrect t = fdmbubble_image_rect(200,200,300,200,FDMBubbleScaleContain,(FDMBubbleAnchor)a,0);
        printf("%-10s (%5.0f,%4.0f %3.0fx%3.0f) (%5.0f,%4.0f %3.0fx%3.0f)\n", names[a],
               c.x,c.y,c.w,c.h, t.x,t.y,t.w,t.h);
    }
    return 0;
}
