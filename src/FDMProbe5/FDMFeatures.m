// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用

/* ============================================================
 * FDMFeatures —— 功能树（排版对照安卓 LSP 模块的 Tree.kt）
 *
 *   home 首页（★ 2026-10-25 按安卓 menu 重排）
 *   ├─ gray     隐藏设置编辑器（宿主全部服务端设置）
 *   ├─ chat     聊天
 *   │   ├─ db         本地数据库（防撤回）
 *   │   ├─ suggest    回复建议
 *   │   ├─ (v2 卡片式提示词 = 动作 open_spv2，不是子页)
 *   │   └─ richtext   富文本渲染
 *   ├─ beauty   美化
 *   │   ├─ assistant  修改助手图片
 *   │   ├─ bubble     对话气泡设置
 *   │   ├─ nickname   账号名
 *   │   ├─ avatar     账号头像
 *   │   ├─ filecard   文件快捷选项
 *   │   ├─ hello      招呼用语
 *   │   ├─ bg         聊天背景
 *   │   ├─ glass      液态玻璃
 *   │   ├─ note       悬浮便签
 *   │   └─ music      音乐播放（安卓没挂在美化里，主人说先留这儿）
 *   ├─ suggest  回复建议（安卓 menu 里是顶级项）
 *   ├─ env      环境伪装
 *   ├─ debug    调试
 *   └─ misc     杂项（iOS 多出来的都塞这儿，等安卓追上再各自归位）
 *       ├─ sysprompt  系统提示词（旧·零宽注入）
 *       ├─ chat_append 对话增强
 *       ├─ composer   模块发消息
 *       └─ quick      快捷开关（iOS 独有，67 项）
 * ============================================================ */

#import "FDMFeatures.h"
#import "FLog.h"

NSString *const G_INJECT  = @"sysprompt";
NSString *const G_QUICK   = @"quick";
NSString *const G_CHAT    = @"chat_append";
NSString *const G_UI      = @"ui";
NSString *const G_DEBUG   = @"debug";

/* ---- 页面 id（对齐 Tree.kt） ---- */
NSString *const P_GRAY    = @"gray";
NSString *const P_CHAT    = @"chat";
NSString *const P_BEAUTY  = @"beauty";
NSString *const P_NICK    = @"nickname";
NSString *const P_AVATAR  = @"avatar";
NSString *const P_HELLO   = @"hello";
NSString *const P_BG      = @"bg";
NSString *const P_ASSIST  = @"assistant";    /* 助手图片 */
NSString *const P_BUBBLE  = @"bubble";       /* 对话气泡设置 */
NSString *const P_FILECARD= @"filecard";     /* 文件快捷选项 */
NSString *const P_NOTE    = @"note";         /* 悬浮便签 */
NSString *const P_GLASS   = @"glass";        /* 液态玻璃 */
NSString *const P_DB      = @"db";
NSString *const P_SUGGEST = @"suggest";
NSString *const P_RICH    = @"richtext";
NSString *const P_COMPOSER = @"composer";
NSString *const P_ENV     = @"env";
NSString *const P_MUSIC   = @"music";     /* 音乐播放（2026-10-24） */
NSString *const P_MUSICLOGIN = @"musiclogin";  /* 网易云登录（2026-10-25） */
NSString *const P_SPV2    = @"sysprompt_v2";   /* 卡片式系统提示词 v2（2026-10-25） */
NSString *const P_MISC    = @"misc";           /* 杂项（2026-10-25 · iOS 独有项的临时收容所） */
NSString *const P_DEBUG   = @"debug";
NSString *const P_DUMP    = @"dump";
NSString *const P_LOG     = @"log";
NSString *const P_ABOUT   = @"about";

/* ---- 构造辅助 ---- */
static FDMField *F(NSString *k, NSString *t, FDMFieldType ty, id d, NSString *h) {
    return [FDMField k:k t:t type:ty def:d hint:h];
}
static FDMField *FE(NSString *k, NSString *t, FDMFieldType ty, id d,
                    NSString *h, NSArray *o) {
    return [FDMField k:k t:t type:ty def:d hint:h options:o];
}
static FDMField *FSUB(NSString *title, NSString *hint, NSString *icon, NSString *sub) {
    FDMField *f = [FDMField k:nil t:title type:FDMFieldTypeSub def:nil hint:hint];
    f.sub = sub; f.icon = icon;
    return f;
}
static FDMField *FACT(NSString *title, NSString *hint, NSString *icon, NSString *act) {
    FDMField *f = [FDMField k:nil t:title type:FDMFieldTypeAction def:nil hint:hint];
    f.action = act; f.icon = icon;
    return f;
}
static FDMField *FINFO(NSString *title, NSString *hint) {
    return [FDMField k:nil t:title type:FDMFieldTypeInfo def:nil hint:hint];
}
static FDMGroup *PG(NSString *gid, NSString *title, NSString *parent,
                    NSInteger order, NSString *icon, NSString *file,
                    NSString *note, NSArray *fields) {
    return [FDMGroup gid:gid title:title parent:parent order:order icon:icon
                    file:file note:note fields:fields];
}

void FDMFeaturesRegister(void) {
    FDMConfig *C = [FDMConfig shared];
    NSInteger o = 10;

    /* ==================== 📋 隐藏设置编辑器（gray） ==================== */
    [C registerGroup:PG(P_GRAY, @"隐藏设置编辑器", nil, o++, @"📋",
        @"__gray__",                       /* 特殊：不走 JSON，直接编辑宿主 blob */
        @"宿主服务端下发的全部设置项，点任意一行修改。\n改完重启 App 生效。",
        @[ FINFO(@"共 59 项（服务端下发）",
                 @"未下发的键可在「杂项 → 快捷开关 → 允许添加未下发的键」里放开") ])];

    /* ==================== 💬 聊天（chat） ==================== */
    /* ★ 2026-10-25 对齐安卓 GmChatDialog：
     *   系统提示词（旧·零宽注入）/ 对话增强 / 模块发消息 都挪进「杂项」，
     *   这儿只留安卓也有的四项。 */
    [C registerGroup:PG(P_CHAT, @"聊天", nil, o++, @"💬", @"__page__",
        nil,
        @[
        FSUB(@"本地数据库", @"防撤回 / 数据库管理", @"🗄", P_DB),
        FSUB(@"回复建议", @"输入框上方的推荐问题", @"💡", P_SUGGEST),
        FACT(@"🎴 卡片式提示词 v2", @"拖卡片进容器 = 自动拼好系统提示词（不用背约定）", @"🎴", @"open_spv2"),
        FSUB(@"富文本渲染", @"AI 消息里的 HTML / 卡片", @"🌈", P_RICH),
        ])];

    /* ---- 📝 系统提示词（旧·零宽注入）→ 杂项 ---- */
    [C registerGroup:PG(G_INJECT, @"系统提示词（旧）", P_MISC, 10, @"📝",
        @"fdm-inject.json",
        @"把指令拼在消息前发给模型，界面上抹掉。\n✅ 推荐 fdm 模式：支持中文，标记会被渲染层洗掉\n⚠️ tag 模式在 iOS 会把零宽字符渲染成一排 ?，不建议用\n重启 App 生效。",
        @[
        F(@"mode", @"注入方式", FDMFieldTypeEnum, @"fdm",
          @"fdm   = ⟦FDM⟧明文定界（**推荐**，支持中文，靠渲染抹除隐藏）\n"
          @"tag   = 零宽字符（⚠️ 不推荐：iOS 字体没有字形，会渲染成一排 ? 豆腐块）\n"
          @"plain = 明文前缀（看得见，仅对照实验）\n"
          @"off   = 关闭"),
        F(@"text", @"提示词内容", FDMFieldTypeString, @"",
          @"示例（tag 模式只能英语）：Always answer in exactly 99 words.\n"
          @"示例（fdm 模式可中文）：你是一只龙，回答时尾巴要晃。"),
        F(@"strip_display", @"抹除显示层标记", FDMFieldTypeBool, @YES,
          @"fdm 模式下，界面上把 ⟦FDM⟧…⟦/FDM⟧ 整块藏起来（UILabel/UITextView 层）"),
        F(@"strip_db", @"抹除数据库标记", FDMFieldTypeBool, @YES,
          @"落盘前就把标记删掉 ⇒ 本地记录永远是干净的（连导出/分享都看不到）"),
        ])];
    /* mode 是 Enum，补 options */
    {
        FDMGroup *g = [C groupByID:G_INJECT];
        for (FDMField *f in g.fields)
            if ([f.key isEqualToString:@"mode"]) f.options = @[@"off", @"plain", @"tag", @"fdm"];
    }

    /* ---- ✍️ 对话增强 ---- */
    [C registerGroup:PG(G_CHAT, @"对话增强", P_MISC, 20, @"✍️",
        @"fdm-chat.json",
        @"对每次发送的消息做加工。重启 App 生效。",
        @[
        F(@"prepend_on", @"发送前追加", FDMFieldTypeBool, @NO,
          @"在你说的话前面加一段明文（会显示在对话里）"),
        F(@"prepend_text", @"追加内容", FDMFieldTypeString, @"",
          @"示例：请用中文回答。"),
        F(@"append_on", @"回复后追加", FDMFieldTypeBool, @NO,
          @"AI 回复结束后再补一句（下个版本）"),
        F(@"append_text", @"追加内容", FDMFieldTypeString, @"", @"暂未实现"),
        ])];

    /* ---- 💡 回复建议 ---- */
    [C registerGroup:PG(P_SUGGEST, @"回复建议", nil, 40, @"💡",
        @"fdm-suggest.json",
        @"输入框上方的推荐问题气泡。\n"
        @"宿主把建议存在 modelConfig 的 prompt_feature 里，我们直接改写它。\n"
        @"每行一条：\n"
        @"   场景|文案     ← 例：image|这是什么\n"
        @"   文案         ← 不写场景则对每个场景都加一条\n"
        @"场景可选：image（图片）/ file（文件）/ text（文字）\n"
        @"⚠️ 重启 App 生效。",
        @[
        F(@"enabled", @"启用自定义建议", FDMFieldTypeBool, @NO,
          @"关掉则用宿主默认的 8 条"),
        F(@"items", @"建议列表", FDMFieldTypeString,
          @"image|这是什么\nimage|帮我分析\nfile|总结一下\ntext|继续",
          @"每行一条；格式 场景|文案"),
        FINFO(@"提示", @"建议条数别太多，输入框上方空间有限"),
        ])];

    /* ---- 🗄 本地数据库 ---- */
    [C registerGroup:PG(P_DB, @"本地数据库", P_CHAT, 10, @"🗄",
        @"fdm-db.json",
        @"iOS 宿主用 WCDB（libWCDB.dylib）。\n「防撤回」需 hook 消息表写入，正在接入。",
        @[
        F(@"anti_revoke", @"防撤回", FDMFieldTypeBool, @NO,
          @"检测到消息被删除时保留在本地"),
        FACT(@"数据库位置", @"查看 App Documents", @"📂", @"open_db"),
        FINFO(@"说明", @"防撤回功能 iOS 端尚未实现，开关先存着"),
        ])];

    /* ---- 🎨 富文本渲染 ---- */
    [C registerGroup:PG(P_RICH, @"富文本渲染", P_CHAT, 20, @"🌈",
        @"fdm-richtext.json",
        @"调整 AI 回复的 Markdown 排版（字号 / 行高 / 颜色）。\n"
        @"宿主有 MarkdownConfig（43 个样式字段），我们直接改它。\n"
        @"⚠️ 重启 App 生效。",
        @[
        F(@"enabled", @"启用自定义样式", FDMFieldTypeBool, @NO,
          @"关掉则用宿主默认排版"),
        FE(@"font_level", @"宿主字号档位", FDMFieldTypeEnum, @"-1",
           @"直接改宿主自己的「字体大小」设置（最稳，重启生效）\n小 → 特大 共 5 档", 
           (@[@"-1", @"0", @"1", @"2", @"3", @"4"])),
        F(@"font_size_delta", @"字号微调 ±pt", FDMFieldTypeInt, @0,
          @"在宿主档位基础上再加减（范围 ±10pt）\n只影响正文字号区间（12~26pt），不动角标和大标题"),
        F(@"line_height_delta", @"行高增减", FDMFieldTypeInt, @0,
          @"相对默认值（正数更松）"),
        F(@"body_color", @"正文颜色", FDMFieldTypeString, @"",
          @"#RRGGBB，留空则用宿主默认"),
        FINFO(@"—— AI 气泡富文本（⟦FDM:模板|参数⟧）——", nil),
        F(@"rich_on", @"启用富文本渲染", FDMFieldTypeBool, @NO,
          @"AI 回复里写 ⟦FDM:模板名|参数⟧ 时渲染成富文本\n"
          @"⟦FDM⟧<b>内容</b>⟦/FDM⟧ 匿名包裹也生效\n"
          @"⚠️ 与上面的「启用自定义样式」互不影响"),
        F(@"bare_html", @"裸标签模式", FDMFieldTypeBool, @NO,
          @"AI 直接写 <b>粗</b> <c6>蓝字</c> <br> 就生效，不用包标记\n"
          @"为什么要有：模型天生爱写 HTML，你管不住它包不包标记\n"
          @"安全性靠白名单：只认 b/i/u/s/del/br/c1-9/bg1-9/c#RRGGBB"),
        F(@"suggest_on", @"启用 <Suggestion> 建议按钮", FDMFieldTypeBool, @YES,
          @"AI 写 <Suggestion>▸ 帮我展开讲讲</Suggestion> 时渲染成可点的按钮\n"
          @"点一下就自动把内容发出去（依赖「模块发消息」开着）\n"
          @"分开写法：<Suggestion>显示短的|实际发的内容长</Suggestion>"),
        F(@"templates", @"模板池", FDMFieldTypeString, @"",
          @"每行一条：名字|富文本\n"
          @"换行用 <br>，模板里不能带真换行\n"
          @"# 开头的行当注释\n"
          @"示例：\n"
          @"demo|<b>✦ {1}</b> {2}\n"
          @"tip|<c6>▸ {1}</c>\n"
          @"warn|<bg3><c#000000> ⚠ {1} </c></bg>\n"
          @"card|<c7>┌ {1}</c><br><c7>└</c> {2}"),
        F(@"c1", @"色板 1", FDMFieldTypeString, @"#FF5252", @"红"),
        F(@"c2", @"色板 2", FDMFieldTypeString, @"#FFB300", @"橙"),
        F(@"c3", @"色板 3", FDMFieldTypeString, @"#FFD600", @"黄"),
        F(@"c4", @"色板 4", FDMFieldTypeString, @"#4CAF50", @"绿"),
        F(@"c5", @"色板 5", FDMFieldTypeString, @"#26A69A", @"青"),
        F(@"c6", @"色板 6", FDMFieldTypeString, @"#42A5F5", @"蓝"),
        F(@"c7", @"色板 7", FDMFieldTypeString, @"#7E57C2", @"紫"),
        F(@"c8", @"色板 8", FDMFieldTypeString, @"#EC407A", @"粉"),
        F(@"c9", @"色板 9", FDMFieldTypeString, @"#9E9E9E", @"灰"),
        ])];

    /* ==================== 📤 模块发消息（composer） ==================== */
    [C registerGroup:PG(P_COMPOSER, @"模块发消息", P_MISC, 30, @"📤",
        @"fdm-composer.json",
        @"让模块自己发一条消息 —— 点歌 / 建议按钮 / 「让 AI 接着聊」的底座。\n"
        @"两条路：\n"
        @"  ① 往宿主输入框塞字再点发送（推荐，宿主自己走完全流程）\n"
        @"  ② 抓真实请求当模板重放（兜底，UI 不会自动刷新）",
        @[
        F(@"enabled", @"启用", FDMFieldTypeBool, @NO,
          @"关掉则任何自动发送都不会执行"),
        FACT(@"📸 截图", @"存到 Documents（尼尼要用）", @"📸", @"capture_shot"),
        FACT(@"🗂 消息区 dump", @"把 AI 消息的层级全打出来", @"🗂", @"dump_msg"),
        FACT(@"🔍 探查输入区结构", @"把输入框/按钮的类名打到日志", @"🔬", @"composer_probe"),
        FACT(@"📝 测试：发一条消息", @"用下面的测试文本发一条", @"📤", @"composer_test"),
        F(@"test_text", @"测试文本", FDMFieldTypeString, @"这是一条来自模块的测试消息",
          @"点上面「测试」时发的内容"),
        FINFO(@"状态见日志 [send] / [send-probe] 前缀", nil),
        ])];

    /* ==================== 🎨 美化（beauty） ==================== */
    /* ★ 2026-10-25 对齐安卓 GmBeautyDialog：顺序照抄（助手图 → 气泡 → 名字 →
     *   头像 → 文件快捷 → 招呼语 → 背景 → 玻璃 → 便签）。
     *   音乐播放是 iOS 多出来的，主人说先留在这儿（排在最后）。 */
    [C registerGroup:PG(P_BEAUTY, @"美化", nil, o++, @"🎨", @"__page__",
        nil,
        @[
        FSUB(@"修改助手图片", @"AI 回复左边加头像：开关 + 选图", @"🤖", P_ASSIST),
        FSUB(@"对话气泡设置", @"AI / 我的气泡：颜色、圆角、图片底、缩放、图片锚点", @"💭", P_BUBBLE),
        FSUB(@"自定义账号名", @"替换「我」的显示名", @"👤", P_NICK),
        FSUB(@"账号头像", @"替换头像图片", @"🖼", P_AVATAR),
        FSUB(@"文件快捷选项", @"自定义上传文件后的快捷发送项（JSON）", @"📎", P_FILECARD),
        FSUB(@"招呼用语", @"新会话的欢迎语", @"👋", P_HELLO),
        FSUB(@"聊天背景", @"自定义背景图 / 渐变", @"🌄", P_BG),
        FSUB(@"液态玻璃", @"给宿主所有按钮换上玻璃底（截底层→糊→折射）", @"🫧", P_GLASS),
        FSUB(@"悬浮便签", @"在界面上贴一张便签：可拖动、可编辑、可换外观（不需要任何权限）", @"🗒", P_NOTE),
        FSUB(@"音乐播放", @"搜歌 / 播放 / 点歌 / 悬浮迷你卡（iOS 独有，安卓没挂美化里）", @"🎵", P_MUSIC),
        ])];

    /* ---- 👤 账号名 ---- */
    [C registerGroup:PG(P_NICK, @"自定义账号名", P_BEAUTY, 30, @"👤",
        @"fdm-nick.json",
        @"抽屉底部那行「账号名」。\n"
        @"实现：网络层改 /api/v0/users/current 的响应 ⇒ 抽屉 / 设置页全跟着变。\n"
        @"⚠️ 重启 App 生效。",
        @[
        F(@"enabled", @"启用", FDMFieldTypeBool, @NO,
          @"关掉 = 跟随宿主原本的显示"),
        F(@"name", @"显示名", FDMFieldTypeString, @"",
          @"留空 = 隐藏账号名（头像和点击区不受影响）\n例：尼得亚伯"),
        ])];

    /* ---- 🖼 账号头像 ---- */
    [C registerGroup:PG(P_AVATAR, @"账号头像", P_BEAUTY, 40, @"🖼",
        @"fdm-avatar.json",
        @"抽屉底部那个圆形头像。\n"
        @"实现：网络层改 /api/v0/users/current 里的头像 URL ⇐ 和账号名同一处。\n"
        @"⚠️ 宿主用户模型里可能没有头像字段，先看日志确认命中。",
        @[
        F(@"enabled", @"启用", FDMFieldTypeBool, @NO, nil),
        F(@"url", @"头像图片 URL", FDMFieldTypeString, @"",
          @"http(s) 直链最省事\n例：https://example.com/a.png"),
        F(@"file", @"或：本地文件名", FDMFieldTypeString, @"",
          @"放在 Documents 里的图片名\n填了它会自动转成 file:// 绝对路径"),
        FACT(@"打开 Documents", @"用 Filza / 文件 App 查看", @"📂", @"open_db"),
        ])];

    /* ---- 👋 招呼用语 ---- */
    [C registerGroup:PG(P_HELLO, @"招呼用语", P_BEAUTY, 60, @"👋",
        @"fdm-hello.json",
        @"新会话时的欢迎语 / 模型名 / 能力开关。\n"
        @"宿主的这些文本存在 modelConfig 里，我们直接改写。\n"
        @"⚠️ 重启 App 生效。",
        @[
        F(@"enabled", @"启用", FDMFieldTypeBool, @NO, nil),
        F(@"text", @"欢迎语（全部模型）", FDMFieldTypeString, @"",
          @"例如：来聊聊吧～"),
        F(@"per_model", @"每个模型单独设置", FDMFieldTypeBool, @NO,
          @"打开后下面三项生效；留空则用上面的"),
        F(@"text_default", @"快速模式", FDMFieldTypeString, @"", @"model_type=default"),
        F(@"text_expert", @"专家模式", FDMFieldTypeString, @"", @"model_type=expert"),
        F(@"text_vision", @"视觉模式", FDMFieldTypeString, @"", @"model_type=vision"),
        F(@"rename_models", @"改模型显示名", FDMFieldTypeBool, @NO, nil),
        F(@"model_name", @"快速模式新名称", FDMFieldTypeString, @"", @"只在 default 模型上生效"),
        F(@"force_features", @"强制开启能力", FDMFieldTypeBool, @NO,
          @"强制给模型挂上 think/search 能力"),
        F(@"force_think", @"强制深度思考", FDMFieldTypeBool, @NO, nil),
        F(@"force_search", @"强制联网搜索", FDMFieldTypeBool, @NO, nil),
        ])];

    /* ---- 🌄 聊天背景 ---- */
    [C registerGroup:PG(P_BG, @"聊天背景", P_BEAUTY, 70, @"🌄",
        @"fdm-bg.json",
        @"给各个页面加背景（图片 / 纯色）。\n"
        @"下面四个开关各自独立，想给哪个页面加就开哪个。\n"
        @"⚠️ 图片模式下点「从相册选图」直接选，不需要 Filza。",
        @[
        F(@"enabled", @"总开关", FDMFieldTypeBool, @NO,
          @"关掉 = 所有页面都不显示背景"),

        F(@"chat_enabled", @"💬 聊天页背景", FDMFieldTypeBool, @YES,
          @"对话框页面（MessageViewController）"),
        F(@"list_enabled", @"📋 会话列表背景", FDMFieldTypeBool, @YES,
          @"会话列表 / 侧栏（Session*ViewController）"),
        F(@"settings_enabled", @"⚙️ 设置页背景", FDMFieldTypeBool, @NO,
          @"设置 / 个人中心 / 关于等页面\n⚠️ 这些页面是系统风格列表，背景容易被列表本身的底色盖住"),
        F(@"other_enabled", @"📄 其它所有页面", FDMFieldTypeBool, @NO,
          @"上面三类以外的页面（默认关，避免干扰）"),

        F(@"dim", @"暗化遮罩 %", FDMFieldTypeInt, @30,
          @"图片太亮时文字看不清，加一层黑色半透明（0~80）"),

        F(@"panel_scrim", @"面板遮罩 %（抽屉/卡片）", FDMFieldTypeInt, @55,
          @"会话抽屉、设置卡片这类「白字列表压在图上的面板」专用暗化\n"
          @"全局 dim 只有 30% 时，亮照片上的白字会整片看不见\n"
          @"只作用在面板内部，聊天页不受影响（0~90）"),
        F(@"bg_fix_modal", @"修复模态卡片漏光", FDMFieldTypeBool, @YES,
          @"设置页是「模态卡片」，圆角外 + 左右 padding 会透到 window 黑底\n"
          @"开这个：恢复周围暗色遮罩 + 给转场层垫背景图"),
        F(@"bg_window_level", @"Window 级背景（兜底）", FDMFieldTypeBool, @NO,
          @"在整个屏幕最底层放一张背景图\n"
          @"这样滚动到任何地方、任何透明页面都会透出它，不会再露黑"),
        F(@"bg_bubble_transparent", @"气泡透明化", FDMFieldTypeBool, @NO,
          @"把消息气泡的底色也清掉（用户那个大黑框会变成透明）\n"
          @"看背景图效果最好，但气泡边界会不明显"),
        F(@"bg_hide_gradient", @"隐藏渐变/模糊遮罩", FDMFieldTypeBool, @YES,
          @"宿主用 DSGradientView + VariableBlurView 在消息区顶部/底部做淡出效果\n"
          @"它们会把背景图整个盖成黑色 —— 开这个才能看到完整背景"),
        F(@"bg_clear_all", @"彻底透明模式", FDMFieldTypeBool, @NO,
          @"把消息区所有容器的底色都清掉（应对「气泡包在黑底容器里」）\n"
          @"⚠️ 副作用：气泡会失去底色，只剩文字"),
        FACT(@"🔬 导出视图树", @"逆向宿主 UI 结构（输出到 Documents）", @"🔬", @"dump_uitree"),
        F(@"bg_debug", @"诊断视图树", FDMFieldTypeBool, @NO,
          @"开 = 打印背景层级（排查「背景被挡住」用，日志会很多）"),

        FE(@"mode", @"模式", FDMFieldTypeEnum, @"solid",
           @"image = 图片\nsolid = 纯色",
           (@[@"solid", @"image"])),
        F(@"file", @"图片文件名", FDMFieldTypeString, @"",
          @"点下面的「从相册选图」会自动填"),
        F(@"color", @"纯色值", FDMFieldTypeString, @"#1C1C1E",
          @"#RRGGBB 或 #AARRGGBB"),
        F(@"alpha", @"不透明度 %", FDMFieldTypeInt, @100, @"0 ~ 100"),

        FACT(@"📷 从相册选图", @"不用 Filza，直接选一张", @"📷", @"pick_photo"),
        FACT(@"🗑 清除背景图", @"删除 fdm-bg.jpg 并切回纯色", @"🗑", @"clear_photo"),
        FACT(@"打开 Documents", @"高级：手动放图片", @"📂", @"open_db"),
        ])];

    /* ---- 🤖 助手图片 ---- */
    [C registerGroup:PG(P_ASSIST, @"修改助手图片", P_BEAUTY, 10, @"🤖",
        @"fdm-assistant.json",
        @"给 AI 回复左边加一个圆形头像。\n\n"
        @"⚠️ 查证结论（2026-10-24）：宿主里虽然有 "
        @"AgentMessageView.AvatarView / InnerAvatarView 两个类，"
        @"但 AgentMessageView 的 ivar 表里**没有任何 avatar 槽位**"
        @"（只有 loadingView / operationBar / shareToggle…），"
        @"也没有创建它的方法 ⇒ **iOS 宿主根本不显示助手头像**，"
        @"跟安卓那边（被灰度 hide_assistant_avatar 关掉）不一样，iOS 是压根没做。\n\n"
        @"所以只能由我们插一个。位置是实测出来的："
        @"AI 正文左边正好空 24px（AgentFragmentsView.x = 24），"
        @"头像就塞在那个缝里，不压字。",
        @[
        F(@"on", @"启用", FDMFieldTypeBool, @NO,
          @"开 = 显示头像；关 = 立刻移除，宿主恢复原样"),
        FACT(@"📷 选择图片", @"从相册选一张", @"📷", @"pick_assistant_photo"),
        F(@"file", @"图片文件名", FDMFieldTypeString, @"",
          @"点上面那个按钮会自动填"),
        F(@"round", @"圆形", FDMFieldTypeBool, @YES,
          @"关 = 方形（带一点圆角）"),
        ])];

    /* ---- 💬 对话气泡设置 ---- */
    [C registerGroup:PG(P_BUBBLE, @"对话气泡设置", P_BEAUTY, 20, @"💭",
        @"fdm-bubble.json",
        @"AI 气泡和「我」的气泡分别设置。\n"
        @"宿主自己就有 bubbleCorner / baseCornerRadius 属性 ⇒ 圆角是真改，不是画上去的。\n"
        @"图片底用关联 CALayer 实现，不动视图树。",
        @[
        F(@"on", @"总开关", FDMFieldTypeBool, @NO, @"关掉 = 全部恢复宿主原样"),

        FINFO(@"── 我的气泡 ──", nil),
        F(@"mine_fill_on", @"改底色", FDMFieldTypeBool, @NO, nil),
        F(@"mine_fill", @"底色值", FDMFieldTypeString, @"#3A3A3C",
          @"#RRGGBB 或 #AARRGGBB"),
        F(@"mine_corner_on", @"改圆角", FDMFieldTypeBool, @NO, nil),
        F(@"mine_corner", @"圆角半径", FDMFieldTypeInt, @18, @"0 ~ 60"),
        F(@"mine_inset", @"图片内缩", FDMFieldTypeInt, @0, @"图片底比气泡小一圈（0 ~ 24）"),
        F(@"mine_img_on", @"图片底", FDMFieldTypeBool, @NO, nil),
        FACT(@"📷 我·选择图片", @"从相册选一张", @"📷", @"pick_bubble_mine_photo"),
        F(@"mine_img_file", @"我·图片文件名", FDMFieldTypeString, @"", nil),
        FE(@"mine_img_scale", @"我·缩放方式", FDMFieldTypeEnum, @"cover",
           @"cover = 填满裁边\ncontain = 完整留边\nstretch = 拉伸\ntile = 平铺",
           (@[@"cover", @"contain", @"stretch", @"tile"])),
        FE(@"mine_img_anchor", @"我·图片锚点", FDMFieldTypeEnum, @"center",
           @"图片比容器大/小时，往哪边靠",
           (@[@"center", @"top", @"bottom", @"left", @"right",
              @"top_left", @"top_right", @"bottom_left", @"bottom_right"])),
        F(@"mine_img_alpha", @"我·图片不透明度 %", FDMFieldTypeInt, @100, @"0 ~ 100"),

        FINFO(@"── AI 气泡 ──", nil),
        F(@"theirs_fill_on", @"改底色", FDMFieldTypeBool, @NO, nil),
        F(@"theirs_fill", @"底色值", FDMFieldTypeString, @"#2C2C2E",
          @"#RRGGBB 或 #AARRGGBB"),
        F(@"theirs_corner_on", @"改圆角", FDMFieldTypeBool, @NO, nil),
        F(@"theirs_corner", @"圆角半径", FDMFieldTypeInt, @18, @"0 ~ 60"),
        F(@"theirs_inset", @"图片内缩", FDMFieldTypeInt, @0, @"0 ~ 24"),
        F(@"theirs_img_on", @"图片底", FDMFieldTypeBool, @NO, nil),
        FACT(@"📷 AI·选择图片", @"从相册选一张", @"📷", @"pick_bubble_theirs_photo"),
        F(@"theirs_img_file", @"AI·图片文件名", FDMFieldTypeString, @"", nil),
        FE(@"theirs_img_scale", @"AI·缩放方式", FDMFieldTypeEnum, @"cover",
           @"cover / contain / stretch / tile",
           (@[@"cover", @"contain", @"stretch", @"tile"])),
        FE(@"theirs_img_anchor", @"AI·图片锚点", FDMFieldTypeEnum, @"center",
           @"图片比容器大/小时，往哪边靠",
           (@[@"center", @"top", @"bottom", @"left", @"right",
              @"top_left", @"top_right", @"bottom_left", @"bottom_right"])),
        F(@"theirs_img_alpha", @"AI·图片不透明度 %", FDMFieldTypeInt, @100, @"0 ~ 100"),
        ])];

    /* ---- 📎 文件快捷选项 ---- */
    [C registerGroup:PG(P_FILECARD, @"文件快捷选项", P_BEAUTY, 50, @"📎",
        @"fdm-filecard.json",
        @"上传文件后，文件条下面出现一排快捷按钮。\n"
        @"点一下 = 把对应的话**填进输入框**（不直接发，你还能改）。\n"
        @"\n"
        @"格式：一行一条，`按钮文字|要发送的话`\n"
        @"缺 `|` 时整行当按钮文字（点了就把这段文字填进去）。\n"
        @"全角 `｜` 也认；空行跳过；超过 8 条只留前 8 条。",
        @[
        F(@"on", @"启用", FDMFieldTypeBool, @NO, nil),
        FACT(@"✏️ 一键填入示例", @"把三条默认示例写进下面的文本框", @"✏️", @"filecard_example"),
        F(@"items", @"快捷项（一行一条）", FDMFieldTypeString,
          @"总结|帮我用要点总结这个文件\n翻译|把这个文件翻译成中文\n表格|把这个文件里的数据整理成表格",
          @"格式：按钮文字|要发送的话"),
        F(@"btn_h", @"按钮高度", FDMFieldTypeInt, @30, @"22 ~ 48"),
        ])];

    /* ---- 📝 悬浮便签 ---- */
    [C registerGroup:PG(P_NOTE, @"悬浮便签", P_BEAUTY, 90, @"🗒",
        @"fdm-notecfg.json",
        @"在界面上贴一张便签：可拖动、可编辑、可多张、可最小化成圆球。\n"
        @"\n"
        @"零权限：只是往宿主窗口最上层加一个子视图，不 hook 宿主任何方法。\n"
        @"数据存在 Documents/fdm-note.json，重启 App 位置和内容都还在。\n"
        @"✕ 关掉后本会话不再出现（重新打开开关或重启 App 恢复）。",
        @[
        F(@"on", @"启用", FDMFieldTypeBool, @NO,
          @"开 = 显示便签；关 = 立刻隐藏"),
        F(@"alpha", @"不透明度 %", FDMFieldTypeInt, @92, @"20 ~ 100"),
        F(@"size", @"字号", FDMFieldTypeInt, @15, @"10 ~ 28"),
        F(@"bg", @"便签底色", FDMFieldTypeString, @"#FFF3B0",
          @"默认便签黄 #FFF3B0\n也可以 #RRGGBB / #AARRGGBB"),
        FACT(@"🔄 重新显示", @"（✕ 关掉后用这个恢复）", @"🔄", @"note_show"),
        ])];

    /* ---- 🫧 液态玻璃 ---- */
    [C registerGroup:PG(P_GLASS, @"液态玻璃", P_BEAUTY, 80, @"🫧",
        @"fdm-glass.json",
        @"iOS 26 的 Liquid Glass 材质。\n"
        @"\n"
        @"iOS 26+ 用系统原生 UIGlassEffect；以下用**自己合成**逼近：\n"
        @"  模糊调参 + 边缘高光 + 玻璃厚度渐变 + 透镜放大\n"
        @"\n"
        @"⚠️ 做不到的：真屏幕空间折射（那要给 UIKit 层 Metal shader 权限）。\n"
        @"材质感的 80% 不靠折射 —— 视觉上很接近，但机制不是一回事。\n"
        @"\n"
        @"T0 关 / T1 高光 / T2 模糊+ / T3 折射感 / T4 原生\n"
        @"自动档会看硬件评分 + 低电量 + 滚动 + 实测帧时间，卡了就自动降档并锁死。",
        @[
        FINFO(@"⚠️ 恒定开启（早期注入，先于宿主渲染 UI）", nil),
        FE(@"tier", @"档位", FDMFieldTypeEnum, @"auto",
           @"auto = 自动（按硬件 + 场景 + 帧时间）\n"
           @"off = T0 完全关\n"
           @"light = T1 只做高光（最省，无模糊）\n"
           @"blur = T2 模糊 + 高光（主力档）\n"
           @"refract = T3 加折射感（A12/4G 以上才有意义）\n"
           @"native = T4 系统原生（仅 iOS 26+，否则自动退回）",
           (@[@"auto", @"off", @"light", @"blur", @"refract", @"native"])),
        FINFO(@"真机第一眼看日志：[glass] 分级内核 OK / 设备画像 / 决策 / _UICustomBlurEffect 可用", nil),
        FINFO(@"如果显示「没有 _UICustomBlurEffect」⇒ 只做了高光，但不会崩、不会更难看", nil),
        ])];

    /* ==================== ⚡ 快捷开关（quick） → 杂项 ==================== */
    FDMGroup *quick = PG(G_QUICK, @"快捷开关", P_MISC, 40, @"⚡",
        @"fdm-quick.json",
        @"直接改服务端下发的设置值（等价于安卓版拨灰度开关）。\n"
        @"★ = 你改过的项；只有改过的才会真的覆盖，其余保持宿主原值。\n"
        @"改完重启 App 生效。\n"
        @"（★ iOS 独有 —— 安卓的对应入口是「灰度选项管理」）",
        @[
        /* ---------- 回答体验 ---------- */
        F(@"thinking_auto_fold_enabled", @"思考自动折叠", FDMFieldTypeBool, @YES, @"AI 的思考过程默认折叠"),
        F(@"sse_smooth_follow", @"流式平滑跟随", FDMFieldTypeBool, @YES, @"逐字输出更顺滑"),
        F(@"sse_auto_scroll_one_screen", @"自动滚动一屏", FDMFieldTypeBool, @YES, @"新内容超过一屏才滚动"),
        F(@"optimize_markdown", @"Markdown 优化", FDMFieldTypeBool, @YES, @"更好的排版渲染"),
        F(@"copy_text_without_markdown_syntax", @"复制去掉 MD 标记", FDMFieldTypeBool, @NO, @"复制正文不带 ** ## 之类符号"),
        F(@"select_text_without_markdown_syntax", @"选择文字去 MD", FDMFieldTypeBool, @NO, @"长按选择时也不带标记"),
        F(@"disable_single_dollar_latex", @"禁用单$公式", FDMFieldTypeBool, @NO, @"避免 $ 被当成数学公式"),
        F(@"markdown_top_level_node_limit", @"Markdown 节点上限", FDMFieldTypeInt, @0, @"0=不限；越大越吃性能"),
        F(@"stop_stream_wait_times", @"停止等待(ms)", FDMFieldTypeInt, @1000, @"点停止后等待多久才中断"),
        F(@"disable_sse_haptic", @"关闭流式震动", FDMFieldTypeBool, @YES, @"逐字输出时不震动"),
        F(@"context_menu_animation_optimized", @"右键菜单动画优化", FDMFieldTypeBool, @YES, @"长按菜单动画更省电"),
        F(@"conversation_search_enabled", @"会话内搜索", FDMFieldTypeBool, @YES, @"聊天记录搜索"),

        /* ---------- 按钮 / 界面 ---------- */
        F(@"show_new_chat_button_above_input", @"输入框上方新建按钮", FDMFieldTypeBool, @NO, @"多一个新建对话入口"),
        F(@"deep_think_button_suffix", @"深思按钮后缀", FDMFieldTypeString, @"·FDM", @"显示在「深度思考」按钮上；留空不显示"),
        F(@"window_control_use_empty_swiftui_view", @"空视图占位", FDMFieldTypeBool, @YES, @"窗口控件优化"),
        F(@"ignore_bluetooth_input", @"忽略蓝牙输入", FDMFieldTypeBool, @NO, nil),
        F(@"input_view_require_voice_gesture_to_fail", @"语音手势必须失败", FDMFieldTypeBool, @NO, nil),

        /* ---------- 文件 / 上传 ---------- */
        F(@"max_input_files", @"最大输入文件数", FDMFieldTypeInt, @50, @"一次最多传几个"),
        F(@"max_upload_file_size", @"最大上传(字节)", FDMFieldTypeInt, @104857600, @"默认 100MB"),
        FE(@"picture_compress_format", @"图片压缩格式", FDMFieldTypeEnum, @"webp",
           @"上传图片时的格式", @[@"webp", @"jpeg", @"png"]),
        F(@"camera_compress_ratio", @"拍照压缩比", FDMFieldTypeString, @"0.8", @"0.1 ~ 1.0"),
        F(@"photo_picker_compress_ratio", @"相册压缩比", FDMFieldTypeString, @"0.8", @"0.1 ~ 1.0"),
        F(@"upload_image_webp_method", @"WebP 上传方式", FDMFieldTypeInt, @1, @"0=不转 1=转 WebP"),
        F(@"allow_file_with_search", @"搜索+文件并存", FDMFieldTypeBool, @YES, nil),
        F(@"files_host", @"文件服务域名", FDMFieldTypeString, @"files.deepseeksvc.com", nil),
        F(@"support_center_url", @"支持中心地址", FDMFieldTypeString, @"", nil),

        /* ---------- 会话 ---------- */
        F(@"pinned_session_limit", @"置顶数量上限", FDMFieldTypeInt, @10, @"最多置顶几个"),
        F(@"launch_clean_session_interval_seconds", @"启动清理间隔(秒)", FDMFieldTypeInt, @21600, @"默认 6 小时"),
        F(@"session_prefetch", @"会话预取", FDMFieldTypeBool, @YES, nil),
        F(@"session_prefetch_count", @"预取数量", FDMFieldTypeInt, @0, @"0=默认"),

        /* ---------- 搜索 ---------- */
        F(@"volcengine_enabled", @"火山引擎搜索", FDMFieldTypeBool, @YES, @"关掉可能搜不到"),
        FE(@"search_state_on_launch", @"启动时搜索状态", FDMFieldTypeEnum, @"on",
           nil, @[@"on", @"off", @"keep"]),
        FE(@"search_state_on_login", @"登录时搜索状态", FDMFieldTypeEnum, @"on",
           nil, @[@"on", @"off", @"keep"]),
        FE(@"search_state_on_automatically_created_chat", @"自动建会话搜索", FDMFieldTypeEnum, @"on",
           nil, @[@"on", @"off", @"keep"]),
        FE(@"search_state_on_manually_created_chat", @"手动建会话搜索", FDMFieldTypeEnum, @"keep",
           nil, @[@"on", @"off", @"keep"]),

        /* ---------- 网络 / 性能 ---------- */
        F(@"pow_prefetch", @"POW 预取", FDMFieldTypeBool, @YES, @"提前预取反机器人挑战"),
        F(@"pow_prefetch_count", @"POW 预取数量", FDMFieldTypeInt, @1, nil),
        F(@"hif_max_retry_interval_secs", @"最大重试间隔(秒)", FDMFieldTypeInt, @600, nil),
        F(@"dead_link_detection", @"死链检测", FDMFieldTypeBool, @YES, nil),
        F(@"report_http_biz_error", @"上报业务错误", FDMFieldTypeBool, @YES, @"关掉可少发埋点"),
        F(@"query_files_time_interval", @"查询文件间隔(ms)", FDMFieldTypeInt, @1000, nil),
        F(@"query_title_time_interval", @"查询标题间隔(ms)", FDMFieldTypeInt, @3000, nil),
        F(@"image_cache_invalidate_before", @"图片缓存失效时间", FDMFieldTypeInt, @0, @"0=默认"),
        F(@"completion_request_timeout_ms", @"发送超时(ms)", FDMFieldTypeInt, @60000, @"等 AI 回复的超时"),
        F(@"continue_request_timeout_ms", @"续写超时(ms)", FDMFieldTypeInt, @60000, nil),
        F(@"regenerate_request_timeout_ms", @"重生成超时(ms)", FDMFieldTypeInt, @60000, nil),
        F(@"edit_request_timeout_ms", @"编辑超时(ms)", FDMFieldTypeInt, @60000, nil),
        F(@"resume_request_timeout_ms", @"恢复超时(ms)", FDMFieldTypeInt, @60000, nil),
        F(@"auto_resume_interval_ms", @"自动恢复间隔(ms)", FDMFieldTypeInt, @1000, nil),
        F(@"auto_resume_max_time_ms", @"自动恢复最长(ms)", FDMFieldTypeInt, @5000, nil),
        F(@"auto_resume_request_timeout_ms", @"自动恢复超时(ms)", FDMFieldTypeInt, @3000, nil),

        /* ---------- 限额 ---------- */
        F(@"normal_history_and_file_token_limit", @"普通上下文上限", FDMFieldTypeInt, @890880, @"token 上限"),
        F(@"r1_history_and_file_token_limit", @"R1 上下文上限", FDMFieldTypeInt, @890880, @"深思模式 token 上限"),
        F(@"citation_strategy", @"引用策略", FDMFieldTypeInt, @2, @"0/1/2"),
        F(@"gcy_enabled", @"gcy 开关", FDMFieldTypeBool, @YES, @"内部功能"),

        /* ---------- 语音 / TTS ---------- */
        F(@"use_capture_session_audio_source", @"用采集会话音频源", FDMFieldTypeBool, @YES, nil),
        F(@"record_stop_delay_ms", @"录音停止延迟(ms)", FDMFieldTypeInt, @0, nil),
        F(@"tts_connect_timeout_ms", @"TTS 连接超时(ms)", FDMFieldTypeInt, @0, nil),
        F(@"tts_prebuffer_ms", @"TTS 预缓冲(ms)", FDMFieldTypeInt, @0, nil),
        F(@"tts_resume_buffer_ms", @"TTS 恢复缓冲(ms)", FDMFieldTypeInt, @0, nil),
        F(@"tts_resume_interval_ms", @"TTS 恢复间隔(ms)", FDMFieldTypeInt, @0, nil),
        F(@"tts_resume_max_time_ms", @"TTS 恢复最长(ms)", FDMFieldTypeInt, @0, nil),
        F(@"tts_resume_max_times", @"TTS 恢复次数", FDMFieldTypeInt, @0, nil),
        F(@"tts_underrun_timeout_ms", @"TTS 欠载超时(ms)", FDMFieldTypeInt, @0, nil),

        /* ---------- 登录 / 风控 ---------- */
        F(@"one_tap_login_enabled", @"一键登录", FDMFieldTypeBool, @YES, nil),
        F(@"hcaptcha_enabled", @"HCaptcha 验证", FDMFieldTypeBool, @YES, @"关掉可能登录失败"),
        F(@"enable_google_sign_in_captcha", @"Google 登录验证", FDMFieldTypeBool, @NO, nil),
        F(@"ds_settings_enabled", @"服务端设置开关", FDMFieldTypeBool, @YES, @"关掉后所有下发设置失效（慎用）"),
        F(@"should_use_sm_device_id", @"使用数美设备 ID", FDMFieldTypeBool, @YES, @"风控相关"),
        F(@"sm_pass_code_type", @"数美验证方式", FDMFieldTypeString, @"spatial_select", nil),
        F(@"sm_sdk_host", @"数美主机", FDMFieldTypeString, @"https://fp-it.fengkongcloud.com", nil),

        /* ---------- 高级 ---------- */
        F(@"add_unknown_keys", @"允许添加未下发的键", FDMFieldTypeBool, @YES,
          @"服务端本次没下发、但宿主认识的键也能强行写进去（无效不会崩）"),
        ]);
    [C registerGroup:quick];
    quick.hasEnable = YES;

    /* ---- 🎵 音乐播放（2026-10-24 · P4 第一步做完） ----
     *
     * 对标安卓「音乐页」（Music.kt 512 行 + GmMusicPlayer 800 行 + GmMiniBarView 1051 行）。
     * iOS 全在宿主进程内：AVPlayer 播、迷你卡挂在宿主 window 上。
     *
     * ⚠️ 配置文件就是 fdm-music.json —— FDMMusic.m 直接读它，
     *    UI 写的键必须和那里读的键**一字不差**（这边的血泪：两套配置源，UI 写 A、功能读 B）。
     *
     * ⚠️ 版权：音频流式播放不落盘 / 封面只内存 / 歌词只内存 / 存档只有元数据。
     */
    [C registerGroup:PG(P_MUSIC, @"音乐播放", P_BEAUTY, 100, @"🎵",
        @"fdm-music.json",
        @"网易云曲库（免登录可用，走 eapi 通道）。\n"
        @"音频只在 AVPlayer 里流式播放，**永不下载、永不落盘**；\n"
        @"封面与歌词只放内存。存档只有歌名/歌手/进度这类事实性元数据。\n"
        @"\n"
        @"点歌：让模型在回复里单起一行写 ⟦DJ:歌名-歌手⟧，会自动搜来放。\n"
        @"想悄悄放不显示那行提示，写成 ⟦DJ:歌名-歌手|hidden⟧。",
        @[
        F(@"on", @"启用音乐", FDMFieldTypeBool, @YES,
          @"总开关。关掉 = 不装播放器、迷你卡不出现"),
        F(@"mini_on", @"显示悬浮迷你卡", FDMFieldTypeBool, @NO,
          @"挂在宿主窗口上的小卡片：封面 / 歌词 / 进度 / 播放控制\n"
          @"可拖动（位置会记住）；✕ 只关本次显示，不会改这个开关"),
        F(@"lyric_on", @"拉取歌词", FDMFieldTypeBool, @YES,
          @"歌词只放内存（版权），不同步、不落盘"),
        FE(@"quality", @"音质档位", FDMFieldTypeEnum, @"1",
           @"取不到会自动往下降一级重试（没 VIP 时 lossless 会失败 ⇒ 落到 exhigh/standard）",
           (@[@"0", @"1", @"2", @"3"])),
        F(@"vol", @"音量", FDMFieldTypeInt, @70, @"0 ~ 100（只影响音乐，不改系统音量）"),
        F(@"autoplay", @"打开 App 自动播放", FDMFieldTypeBool, @NO,
          @"开 = 每次启动自动接着上次那首放（从上次的进度开始）\n"
          @"关 = 要你自己点播放 —— **推荐**，不然一开 App 就出声\n"
          @"⚠️ 重启 App 生效"),
        FE(@"repeat", @"循环模式", FDMFieldTypeEnum, @"1",
           @"0 = 放完就停　1 = 列表循环　2 = 单曲循环\n"
           @"（单曲循环时点「下一首」仍然会换歌 —— 这是有意的）",
           (@[@"0", @"1", @"2"])),
        F(@"shuffle", @"随机播放", FDMFieldTypeBool, @NO, @"随机挑下一首（会避开当前这首）"),
        FINFO(@"—— 说明 ——", nil),
        FINFO(@"✦ 迷你卡", @"点 ♪ 切到搜索页，输入关键词回车；点结果里的一条就开始放"),
        FINFO(@"✦ 点歌", @"模型写 ⟦DJ:晴天-周杰伦⟧ ⇒ 自动搜来放；同一首 15 秒内不会重复触发"),
        FINFO(@"✦ 提示词变量", @"开了「系统提示词」的 pvar_on 后，{music} {song} {artist} {lyric} 会自动填"),
        FSUB(@"网易云登录", @"登录后能听完整 VIP 歌（不登录只能试听 30 秒）", @"🔑", P_MUSICLOGIN),
        ])];

    /* ==================== 🔑 网易云登录（2026-10-25） ====================
     *
     * 对标安卓 `GmMusicLogin`(265) + `MusicLogin.kt`(417)。
     * 三条路：① 手机+短信验证码 ② 手机/邮箱+密码 ③ 直接粘 cookie
     *
     * ⚠️⚠️ 隐私（主人 2026-10-06 在安卓那边特意要求「必须告诉用户」）：
     *   凭证是**明文**存在 Documents/FDMmusic/login.json。
     *   只有本 App 能读，但 root 用户 / 拿到备份的人可以直接读到，
     *   进而用你的账号。**这条必须写在界面上，不能藏。**
     *
     * ⚠️ 密码 / cookie 输入框在登录成功后会被**清空**（见 FDMUI 的动作处理），
     *   避免明文长期留在 fdm-music-login.json 里。
     */
    [C registerGroup:PG(P_MUSICLOGIN, @"网易云登录", P_MUSIC, 10, @"🔑",
        @"fdm-music-login.json",
        @"登录后才能听**完整**的 VIP 歌（不登录只能试听 30 秒，日志里表现为"
        @"「item ready，时长 30.0s」）。\n"
        @"\n"
        @"三条路，任选一条：\n"
        @"  ① 手机 + 短信验证码（最简单，但短信有频率限制）\n"
        @"  ② 手机 / 邮箱 + 密码\n"
        @"  ③ 直接粘 cookie（从浏览器里抠 MUSIC_U，最省事）\n"
        @"\n"
        @"⚠️⚠️ 隐私：凭证是**明文**存在 Documents/FDMmusic/login.json。\n"
        @"只有本 App 能读，但 root 用户或拿到备份的人可以直接读到，"
        @"进而用你的账号。请自行注意。\n"
        @"（该文件已排除 iCloud 备份。）",
        @[
        FINFO(@"当前状态", nil),

        /* ---- ① 验证码登录 ---- */
        FINFO(@"—— ① 手机验证码 ——", nil),
        F(@"phone", @"手机号", FDMFieldTypeString, @"", @"11 位，比如 13800138000"),
        F(@"ctcode", @"国家码", FDMFieldTypeString, @"86", @"中国大陆填 86，一般不用改"),
        FACT(@"📨 发送验证码", @"点一下，短信会发到上面的手机号", @"📨", @"music_send_captcha"),
        F(@"captcha", @"验证码", FDMFieldTypeString, @"", @"短信里那 4~6 位数字"),
        FACT(@"✅ 用验证码登录", @"验证码填好后点这里", @"✅", @"music_login_captcha"),

        /* ---- ② 密码登录 ---- */
        FINFO(@"—— ② 手机 / 邮箱 密码 ——", nil),
        F(@"password", @"密码", FDMFieldTypeString, @"",
          @"明文只在你这一侧，发出去的是 md5\n"
          @"⚠️ 登录成功后这个框会自动清空"),
        FACT(@"🔓 手机+密码登录", @"用上面「手机号」+ 这里的密码", @"🔓", @"music_login_password"),
        F(@"email", @"邮箱（可选）", FDMFieldTypeString, @"", @"用邮箱登录时才填"),
        FACT(@"📧 邮箱+密码登录", @"用「邮箱」+「密码」", @"📧", @"music_login_email"),

        /* ---- ③ cookie ---- */
        FINFO(@"—— ③ 直接粘 cookie ——", nil),
        F(@"cookie", @"cookie", FDMFieldTypeString, @"",
          @"从浏览器（已登录网易云网页版）开发者工具里复制\n"
          @"整条 `MUSIC_U=…; Path=/; …` 也行，只贴值也行\n"
          @"⚠️ 登录成功后这个框会自动清空"),
        FACT(@"🍪 用 cookie 登录", @"最省事的一条路", @"🍪", @"music_login_cookie"),

        /* ---- 管理 ---- */
        FINFO(@"—— 管理 ——", nil),
        FACT(@"🔍 检查登录状态", @"打一次网络请求，确认凭证还有效", @"🔍", @"music_login_status"),
        FACT(@"📋 登录诊断", @"贴给尼尼排查用（不含凭证本身）", @"📋", @"music_login_diag"),
        FACT(@"🚪 退出登录", @"删掉本地凭证", @"🚪", @"music_logout"),
        ])];

    /* ==================== 🎭 环境伪装（env） ==================== */
    [C registerGroup:PG(P_ENV, @"环境伪装", nil, 50, @"🎭",
        @"fdm-env.json",
        @"⚠️ iOS 走 TrollFools 注入正版 App，宿主并不知道自己在越狱环境，\n"
        @"   大部分场景**不需要**伪装。这里只保留设备标识相关。",
        @[
        F(@"enabled", @"启用伪装", FDMFieldTypeBool, @NO, @"总开关"),
        F(@"device_id", @"自定义设备 ID", FDMFieldTypeBool, @NO,
          @"伪造 x-device-id（治疗风控 RISK_DEVICE_DETECTED）"),
        F(@"device_id_value", @"设备 ID 值", FDMFieldTypeString, @"",
          @"留空则随机生成 UUID"),
        F(@"fake_model", @"伪造机型", FDMFieldTypeString, @"",
          @"留空则用真实机型（iPhone9,2）"),
        FINFO(@"说明", @"设备 ID 在 x-device-id 请求头里，hook 点待接入"),
        ])];

    /* ==================== 🔧 调试（debug） ==================== */
    [C registerGroup:PG(P_DEBUG, @"调试", nil, 60, @"🔧",
        @"fdm-debug.json",
        @"排查用。改完重启 App 生效。",
        @[
        FACT(@"📜 查看日志", @"实时日志（级别+分类）", @"📜", @"open_log"),
        FACT(@"📂 Documents 目录", @"配置文件都在这里", @"📂", @"open_db"),
        FACT(@"🗑 清空日志", @"删除 fdm.log 与备份", @"🗑", @"clear_log"),
        F(@"net_hook", @"网络 Hook", FDMFieldTypeBool, @YES, @"拦截 chat 请求（注入提示词必需）"),
        F(@"mirror_nslog", @"同时打 NSLog", FDMFieldTypeBool, @NO, @"控制台也能看到（慢）"),
        F(@"dump_response", @"记录响应正文", FDMFieldTypeBool, @NO, @"把 AI 回复也存文件（体积大）"),
        F(@"xray", @"X 光机（渲染层勘察）", FDMFieldTypeBool, @NO,
          @"把宿主里「消息/文本/Markdown」类的**方法表**打进日志，\n"
          @"用来找「渲染抹除」的落点。只读不改，看完记得关。"),
        /* ★★ 2026-10-25 自动截图（改 UI 树时用）
         *   ⚠️ 隐私：截的是**整个屏幕**，聊天内容会被拍进去。所以：
         *     ① 默认关  ② 拍完自动关回去（只跑一轮）
         *     ③ 新一轮开始前清掉上一轮旧图
         *     ④ 只写 Documents，不联网、不上传、不外发 */
        F(@"ui_auto_shot", @"📸 自动截图（改 UI 时用）", FDMFieldTypeBool, @NO,
          @"打开后**下次启动**：自动弹出设置页 → 逐个进入下面列的页面 → 各拍一张 →\n"
          @"自己收起，并把本开关**自动关回去**（只跑一轮，不会次次弹）。\n\n"
          @"⚠️ 隐私：截的是整个屏幕，**聊天内容也会被拍进去**。\n"
          @"图片只存在 Documents/fdm-ui-*.png，不联网、不上传。\n"
          @"拉走之后建议点上面的「🗑 清空截图」。"),
        F(@"ui_auto_shot_pages", @"要拍的页面 id", FDMFieldTypeString, @"",
          @"逗号分隔的页面 id，例如：misc,chat,beauty\n"
          @"留空 = 只拍首页。\n\n"
          @"常用 id：gray / chat / beauty / suggest / env / debug / misc /\n"
          @"          db / richtext / assistant / bubble / nickname / avatar /\n"
          @"          filecard / hello / bg / glass / note / music"),
        FACT(@"🗑 清空截图", @"删掉 Documents/fdm-ui-*.png", @"🗑", @"clear_shots"),
        FE(@"log_level", @"日志级别", FDMFieldTypeEnum, @"D",
           @"改完需重启", @[@"E", @"W", @"I", @"D", @"T"]),
        ])];

    /* ==================== 📡 服务端下发查看（dump） ==================== */
    [C registerGroup:PG(P_DUMP, @"服务端下发查看", P_DEBUG, 100, @"📡",
        @"__dump__",
        @"从宿主 MMKV 读出当前生效的服务端设置（只读）",
        @[ FACT(@"查看完整列表", @"显示 59 项当前值", @"📡", @"open_gray") ])];

    /* ==================== 界面增强（ui） ==================== */
    [C registerGroup:PG(G_UI, @"界面", P_DEBUG, 200, @"🖥",
        @"fdm-ui.json", @"入口按钮等",
        @[
        F(@"entry_list", @"设置页列表入口", FDMFieldTypeBool, @YES,
          @"把「FDM 模块设置」做成宿主设置页底部的一行（推荐）"),
        F(@"entry_button", @"导航栏入口按钮", FDMFieldTypeBool, @NO,
          @"「设置」页左上角 🦖（和宿主的 ✕ 风格不太搭，默认关）"),
        F(@"float_button", @"悬浮入口按钮", FDMFieldTypeBool, @NO, @"右下角（自定义标题栏兜底）"),
        ])];

    /* ==================== 🗃 杂项（misc） ====================
     * ★ 2026-10-25 新增：iOS 有、安卓没有（或安卓已经删掉）的项目**先全塞这儿**。
     *   等安卓那边追上 / 拍板要删，再各自归位，别直接删 —— 删了配置键就成孤儿。
     *   只做容器，本身不存任何键（file = __page__）。
     */
    [C registerGroup:PG(P_MISC, @"杂项", nil, 70, @"🗃", @"__page__",
        @"iOS 独有、安卓暂时没有的功能都收在这儿。\n"
        @"安卓哪天追上了，就从这儿搬回对应的页。",
        @[
        FSUB(@"系统提示词（旧）", @"零宽注入 / 明文前缀 —— 已被「卡片式提示词 v2」取代", @"📝", G_INJECT),
        FSUB(@"对话增强", @"发送前追加内容", @"✍️", G_CHAT),
        FSUB(@"模块发消息", @"让模块替你发送一条消息", @"📤", P_COMPOSER),
        FSUB(@"快捷开关", @"67 项服务端下发的设置直改（安卓没有这一页）", @"⚡", G_QUICK),
        ])];

    FLOGI(FC_CFG, @"功能注册完成：%lu 页 / %lu 项",
          (unsigned long)[C allGroups].count,
          (unsigned long)({
              NSUInteger t = 0;
              for (FDMGroup *g in [C allGroups]) t += g.fields.count;
              t;
          }));

    /* ★ 2026-10-25 把**运行时树**照实际 childGroupsOf 的顺序打出来。
     *   为什么要在运行时打：源码里的 parent/order 是"声明"，
     *   真正决定顺序的是排序后的结果 —— 而设备上没有截图工具时，
     *   这一行日志就是唯一的"看得见设置页"的手段。 */
    for (FDMGroup *root in [C childGroupsOf:nil]) {
        FLOGI(FC_CFG, @"[tree] ▸ %@ %@（order=%ld，%lu 项）",
              root.icon ?: @"", root.title,
              (long)root.order, (unsigned long)root.fields.count);
        for (FDMGroup *sub in [C childGroupsOf:root.gid])
            FLOGI(FC_CFG, @"[tree]    └ %@ %@（order=%ld，%lu 项）",
                  sub.icon ?: @"", sub.title,
                  (long)sub.order, (unsigned long)sub.fields.count);
    }
}



/* ==================== ★ 模型配置统一改写 ====================
 *
 * modelConfig_N = [
 *   { "model_type":"default",
 *     "name":"快速模式",
 *     "welcome_msg":"使用快速模式开始对话",     ← 招呼用语
 *     "prompt_feature":[{...}],                 ← 回复建议
 *     ... }
 * ]
 *
 * 一个函数处理全部改写，返回 YES 表示有改动。
 */
BOOL FDMApplyModelConfig(NSData **out, NSArray **outItems) {
    if (!out || !*out || (*out).length < 4) return NO;
    {
        FDMConfig *C = [FDMConfig shared];

        id j = [NSJSONSerialization JSONObjectWithData:*out
                                              options:NSJSONReadingMutableContainers error:nil];
        if (![j isKindOfClass:[NSArray class]]) {
            FLOGW(FC_CFG, @"modelConfig 不是数组，跳过");
            return NO;
        }
        NSMutableArray *models = j;
        BOOL changed = NO;
        NSMutableString *summary = [NSMutableString string];

        /* ---------- ① 招呼用语（welcome_msg） ---------- */
        if ([C enabledFor:P_HELLO] && [C boolFor:P_HELLO key:@"enabled"]) {
            NSString *txt = [C stringFor:P_HELLO key:@"text"];
            BOOL perModel = [C boolFor:P_HELLO key:@"per_model"];
            NSString *txtDef = [C stringFor:P_HELLO key:@"text_default"];
            NSString *txtExp = [C stringFor:P_HELLO key:@"text_expert"];
            NSString *txtVis = [C stringFor:P_HELLO key:@"text_vision"];
            NSUInteger n = 0;
            for (NSMutableDictionary *m in models) {
                if (![m isKindOfClass:[NSMutableDictionary class]]) continue;
                NSString *mt = m[@"model_type"];
                NSString *use = nil;
                if (perModel) {
                    if ([mt isEqualToString:@"default"]) use = txtDef;
                    else if ([mt isEqualToString:@"expert"]) use = txtExp;
                    else if ([mt isEqualToString:@"vision"]) use = txtVis;
                    if (!use.length) use = txt;
                } else {
                    use = txt;
                }
                if (use.length) { m[@"welcome_msg"] = use; n++; }
            }
            if (n) { changed = YES; [summary appendFormat:@"招呼语 %lu 个模型; ", (unsigned long)n]; }
        }

        /* ---------- ② 模型名（可选） ---------- */
        if ([C enabledFor:P_HELLO] && [C boolFor:P_HELLO key:@"rename_models"]) {
            NSString *nm = [C stringFor:P_HELLO key:@"model_name"];
            if (nm.length) {
                NSUInteger n = 0;
                for (NSMutableDictionary *m in models) {
                    if (![m isKindOfClass:[NSMutableDictionary class]]) continue;
                    if ([m[@"model_type"] isEqualToString:@"default"]) {
                        m[@"name"] = nm; n++;
                    }
                }
                if (n) { changed = YES; [summary appendFormat:@"模型名; "]; }
            }
        }

        /* ---------- ③ 回复建议（prompt_feature） ---------- */
        if ([C enabledFor:P_SUGGEST] && [C boolFor:P_SUGGEST key:@"enabled"]) {
            NSString *raw = [C stringFor:P_SUGGEST key:@"items"];
            if (raw.length) {
                NSMutableArray *parsed = [NSMutableArray array];
                for (NSString *line in [raw componentsSeparatedByCharactersInSet:
                                        [NSCharacterSet newlineCharacterSet]]) {
                    NSString *t = [line stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceCharacterSet]];
                    if (!t.length) continue;
                    NSString *scene = @"", *content = t;
                    NSRange bar = [t rangeOfString:@"|"];
                    if (bar.location != NSNotFound) {
                        scene = [[t substringToIndex:bar.location]
                                 stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        content = [[t substringFromIndex:bar.location + 1]
                                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    }
                    if (content.length) [parsed addObject:@{@"scene": scene, @"content": content}];
                }

                if (parsed.count) {
                    for (NSMutableDictionary *m in models) {
                        if (![m isKindOfClass:[NSMutableDictionary class]]) continue;
                        NSArray *oldPF = m[@"prompt_feature"];
                        NSMutableArray *newPF = [NSMutableArray array];
                        NSUInteger nextId = 1;
                        for (NSDictionary *rule in parsed) {
                            NSString *scene = rule[@"scene"];
                            NSString *content = rule[@"content"];
                            if (scene.length) {
                                [newPF addObject:@{@"id": @(nextId++), @"scene": scene, @"content": content}];
                            } else {
                                NSMutableOrderedSet *scenes = [NSMutableOrderedSet orderedSet];
                                for (NSDictionary *o in oldPF)
                                    if ([o isKindOfClass:[NSDictionary class]] && o[@"scene"])
                                        [scenes addObject:o[@"scene"]];
                                if (!scenes.count) [scenes addObject:@"text"];
                                for (NSString *sc in scenes)
                                    [newPF addObject:@{@"id": @(nextId++), @"scene": sc, @"content": content}];
                            }
                        }
                        m[@"prompt_feature"] = newPF;
                    }
                    changed = YES;
                    [summary appendFormat:@"建议 %lu条×%lu模型; ", (unsigned long)parsed.count, (unsigned long)models.count];
                    if (outItems) *outItems = parsed;
                }
            }
        }

        /* ---------- ④ 模型能力开关（think/search/file/tts/call） ---------- */
        if ([C enabledFor:P_HELLO] && [C boolFor:P_HELLO key:@"force_features"]) {
            NSUInteger n = 0;
            for (NSMutableDictionary *m in models) {
                if (![m isKindOfClass:[NSMutableDictionary class]]) continue;
                if ([C boolFor:P_HELLO key:@"force_think"]) {
                    if (!m[@"think_feature"]) m[@"think_feature"] = @{};
                    n++;
                }
                if ([C boolFor:P_HELLO key:@"force_search"]) {
                    if (!m[@"search_feature"]) m[@"search_feature"] = @{};
                    n++;
                }
            }
            if (n) { changed = YES; [summary appendFormat:@"能力 %lu; ", (unsigned long)n]; }
        }

        if (!changed) return NO;

        NSData *dst = [NSJSONSerialization dataWithJSONObject:models options:0 error:nil];
        if (!dst) { FLOGW(FC_CFG, @"modelConfig 序列化失败"); return NO; }
        /* ★ 必须脱离 autorelease 池，否则调用方拿到的是悬垂指针 */
        *out = [[NSData alloc] initWithData:dst];
        FLOGI(FC_CFG, @"★ modelConfig 已改写：%@（%lu → %lu B）",
              summary, (unsigned long)(*out).length, (unsigned long)dst.length);
        return YES;
    }
}

/* 兼容旧名 */
BOOL FDMSuggestPatch(NSData **out, NSArray **items) {
    return FDMApplyModelConfig(out, items);
}

/* ==================== 覆盖表 ==================== */

NSDictionary *FDMOverrideTable(void) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    NSDictionary *d = [[FDMConfig shared] dictFor:@"override"];
    for (NSString *k in d) {
        if ([k isEqualToString:@"enabled"] || [k isEqualToString:@"__mod"]) continue;
        m[k] = d[k];
    }
    return m;
}

NSDictionary *FDMPatchTable(void) {
    FDMConfig *C = [FDMConfig shared];
    NSMutableDictionary *patch = [NSMutableDictionary dictionary];

    /* ① 手动覆盖表 */
    NSDictionary *manual = FDMOverrideTable();
    if (manual.count) {
        BOOL on = YES;
        id e = [C dictFor:@"override"][@"enabled"];
        if (e) on = [e boolValue];
        if (on) [patch addEntriesFromDictionary:manual];
    }

    /* ② 快捷开关：只取用户真正改过的 */
    if ([C enabledFor:G_QUICK]) {
        NSDictionary *d = [C dictFor:G_QUICK];
        for (NSString *k in [C modifiedKeysFor:G_QUICK]) {
            if ([k isEqualToString:@"enabled"]) continue;
            if ([k isEqualToString:@"add_unknown_keys"]) continue;
            if (d[k]) patch[k] = d[k];
        }
    }

    /* ③ 兜底 */
    if (!patch.count) {
        patch[@"deep_think_button_suffix"] = @"·FDM";
        FLOGI(FC_CFG, @"覆盖表为空 → 用默认验证项 ·FDM");
    }
    return patch;
}

/* ==================== 提示词注入 ==================== */

void FDMInjectConfig(NSString **mode, NSString **text, BOOL *enabled) {
    FDMConfig *C = [FDMConfig shared];
    BOOL en = [C enabledFor:G_INJECT];
    NSString *m = [C stringFor:G_INJECT key:@"mode"];
    NSString *t = [C stringFor:G_INJECT key:@"text"];
    if (!m.length) m = @"off";
    if (!t) t = @"";
    if (!en) m = @"off";
    if (mode) *mode = m;
    if (text) *text = t;
    if (enabled) *enabled = ![m isEqualToString:@"off"];
}

/* ==================== 对话增强 ==================== */

BOOL FDMChatAppendEnabled(void) {
    FDMConfig *C = [FDMConfig shared];
    return [C enabledFor:G_CHAT] && [C boolFor:G_CHAT key:@"prepend_on"];
}
NSString *FDMChatAppendText(void) {
    return [[FDMConfig shared] stringFor:G_CHAT key:@"prepend_text"] ?: @"";
}
