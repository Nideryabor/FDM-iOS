// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMFileCard —— 「文件快捷选项」模型（纯 C11，零依赖）
//
// 对标安卓 GmFileCardProbe：上传文件后，卡片上出现一排快捷"问法"，
// 点一下就把对应 prompt 发出去（省得每次手打"帮我总结这个文件"）。
//
// ═══════════════════════════════════════════════════════════════════════════
//  为什么配置用 JSON 字符串而不是逐字段开关
//
//  这一项天生是**列表**（用户想加几条就加几条），逐字段开关没法表达。
//  所以设置页给一个多行文本框，内容是一行一条：
//     总结|帮我用要点总结这个文件
//     翻译|把这个文件翻译成中文
//     表格|把这个文件里的数据整理成表格
//  第 1 段 = 按钮文字，第 2 段 = 实际发送的 prompt（`|` 之后可以有 `|`）。
//
//  ⇒ 解析这一块必须**极其宽容**：用户手打，少一个 |、多一个空行、
//    中文逗号、行尾空格……都不该让整个功能失效。
// ═══════════════════════════════════════════════════════════════════════════
#ifndef FDM_FILE_CARD_H
#define FDM_FILE_CARD_H

#ifdef __cplusplus
extern "C" {
#endif

#define FDMFC_MAX_ITEMS   8      /**< 最多保留几条（多了也放不下）*/
#define FDMFC_MAX_LABEL   12     /**< 按钮文字最长几个**字符**（不是字节）*/
#define FDMFC_MAX_PROMPT  2000   /**< prompt 最大字节数 */

typedef struct {
    char *label;      /**< malloc，按钮上显示的字 */
    char *prompt;     /**< malloc，点击后发送的话 */
} fdmfc_item;

typedef struct {
    fdmfc_item *items;
    int count;
    int capacity;
} fdmfc_list;

/** 内置默认三条（用户没配置时用）。返回的 list 需要 fdmfc_free。 */
int fdmfc_defaults(fdmfc_list *out);

/**
 * 从「一行一条」的文本解析。
 * 宽容规则：
 *   · 空行 / 纯空白行 跳过
 *   · 没有 `|` 的行：整行当 label，prompt 为空（调用方应回退到 label）
 *   · label 空白 => 用默认文字「问一下」
 *   · label 超长（>FDMFC_MAX_LABEL 字符）截断
 *   · prompt 为空 => 用 label 代替（至少点了有反应）
 *   · 大小写/全角 `｜` 也当分隔符
 *   · 超过 FDMFC_MAX_ITEMS 条 => 丢掉后面的
 * @return 0 成功；负数内存不足
 */
int fdmfc_parse(const char *text, fdmfc_list *out);

/** 把 list 序列化成「一行一条」的文本（malloc，调用方 free）。 */
char *fdmfc_serialize(const fdmfc_list *list);

/** 释放（可重复调用）。 */
void fdmfc_free(fdmfc_list *list);

/** 校验：去掉空项、去重（label 相同视为同一条）、夹到上限。返回改动条数。 */
int fdmfc_sanitize(fdmfc_list *list);

/** 内置用例自检。@return 0 = 全通过；否则第一个失败用例号。 */
int fdmfc_selftest(char *errbuf, int errlen);

#ifdef __cplusplus
}
#endif

#endif /* FDM_FILE_CARD_H */
