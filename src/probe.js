/* ============================================================
 * FDM iOS 探针 v0.1  —— 只读侦察，不改任何行为
 * 目的：回答静态分析定不下来的 4 个疑点
 *   1. 设置的本地持久化存在哪（MMKV 哪个实例 / 哪个键）
 *   2. mmkvWithID: 的实例名是什么
 *   3. LazySettingReader 的读取源
 *   4. _appRemoteSettings 对应哪个键
 *
 * 用法（任选）：
 *   A) frida -U -f com.deepseek.chat -l probe.js     ← 推荐，spawn 起（能抓全）
 *   B) frida -U -n "DeepSeek Chat" -l probe.js       ← attach（会漏启动期的读写）
 *
 * 日志同时：① console 输出 ② 追加到 App 沙盒 Documents/fdm-probe.log（Filza 可读）
 * ============================================================ */
'use strict';

const TAG      = 'FDM';
const LOGFILE  = 'fdm-probe.log';
const MARK     = { settings: 0, mmkv: 0, defaults: 0 };

/* ---------- 输出：console + 沙盒文件 ---------- */
let _writer = null;
function fileLog(line) {
    try {
        if (!_writer) {
            const NSFileManager = ObjC.classes.NSFileManager;
            const dir = ObjC.classes.NSFileManager.defaultManager()
                .URLsForDirectory_inDomains_(9 /* NSDocumentDirectory */, 1)
                .objectAtIndex_(0).path().toString();
            const path = dir + '/' + LOGFILE;
            const NSFileHandle = ObjC.classes.NSFileHandle;
            if (!NSFileManager.defaultManager().fileExistsAtPath_(path)) {
                NSFileManager.defaultManager()
                    .createFileAtPath_contents_attributes_(path, NULL, NULL);
            }
            _writer = NSFileHandle.fileHandleForWritingAtPath_(path);
            _writer.seekToEndOfFile();
            fileLog('\n=== FDM probe v0.1 @ ' + new Date().toISOString() + ' ===');
        }
        const data = ObjC.classes.NSString.stringWithString_(line + '\n')
            .dataUsingEncoding_(4 /* NSUTF8StringEncoding */);
        _writer.writeData_(data);
    } catch (e) { /* 文件日志失败不影响 console */ }
}
function log(s) {
    const line = '[' + TAG + '] ' + s;
    console.log(line);
    fileLog(line);
}

/* ---------- 值的安全字符串化 ---------- */
function s(v) {
    try {
        if (v === null || v === undefined) return String(v);
        if (v instanceof ObjC.Object) {
            const d = v.description();
            const t = d ? d.toString() : '<obj>';
            return t.length > 300 ? t.slice(0, 300) + '…' : t;
        }
        return String(v);
    } catch (e) { return '<' + e.message + '>'; }
}
function instName(self) {
    try { return self.mmapID().toString(); } catch (e) { return '?'; }
}

/* ---------- 关键：只关心这些键（减少噪音） ---------- */
const HOT = [
    'kv_settings_', 'kv_remote_settings_', 'app.', 'ds_settings_',
    'voice_input_enabled', 'optimize_markdown', 'sse_smooth_follow',
    'remoteSettings', 'serverValues', 'prompt', 'welcome_msg',
];
function isHot(k) {
    const t = String(k);
    return HOT.some(h => t.indexOf(h) >= 0);
}

/* ---------- ① MMKV ---------- */
function hookMMKV() {
    const MMKV = ObjC.classes.MMKV;
    if (!MMKV) { log('!! MMKV 类还没加载，稍后重试'); return false; }
    log('MMKV 类已加载，开始挂钩');

    // 实例创建（★ 只此一处，静态已确认全二进制仅 1 个调用点）
    try {
        const m = MMKV['+ mmkvWithID:'];
        if (m) {
            const orig = m.implementation;
            m.implementation = ObjC.implement(m, function (handle, sel, mid) {
                const name = new ObjC.Object(mid).toString();
                log('★ MMKV 实例创建 mmkvWithID: ' + name);
                return orig(handle, sel, mid);
            });
        }
    } catch (e) { log('mmkvWithID 挂钩失败: ' + e.message); }

    // 读
    [['- stringForKey:', 1], ['- objectForKey:', 1], ['- dataForKey:', 1],
     ['- boolForKey:', 1], ['- int64ForKey:', 1], ['- containsKey:', 1]].forEach(function (p) {
        const meth = MMKV[p[0]];
        if (!meth) return;
        const orig = meth.implementation;
        const sel = p[0];
        meth.implementation = ObjC.implement(meth, function (handle, s, key) {
            const k = new ObjC.Object(key).toString();
            const r = orig(handle, s, key);
            if (isHot(k)) log('MMKV 读 [' + instName(new ObjC.Object(handle)) + '] ' + k + ' = ' + s(r));
            return r;
        });
    });

    // 写
    [['- setString:forKey:', 2], ['- setObject:forKey:', 2], ['- setData:forKey:', 2],
     ['- setBool:forKey:', 2], ['- setInt64:forKey:', 2]].forEach(function (p) {
        const meth = MMKV[p[0]];
        if (!meth) return;
        const orig = meth.implementation;
        const isSet = p[1] === 2;
        meth.implementation = ObjC.implement(meth, function (handle, s, a1, a2) {
            const key = new ObjC.Object(isSet ? a2 : a1).toString();
            const val = isSet ? new ObjC.Object(a1) : new ObjC.Object(a2);
            const inst = instName(new ObjC.Object(handle));
            if (isHot(key)) log('★ MMKV 写 [' + inst + '] ' + key + ' <= ' + s(val) + '   <<< (' + p[0] + ')');
            else MARK.mmkv++;
            return orig(handle, s, a1, a2);
        });
    });

    // 枚举
    try {
        const alk = MMKV['- allKeys'];
        if (alk) {
            const orig = alk.implementation;
            Object.defineProperty(alk, 'implementation', {
                value: ObjC.implement(alk, function (handle, s) {
                    const r = orig(handle, s);
                    try {
                        const arr = new ObjC.Object(r);
                        const n = arr.count();
                        log('★ MMKV allKeys [' + instName(new ObjC.Object(handle)) + '] 共 ' + n + ' 个键');
                        for (let i = 0; i < n && i < 400; i++) {
                            const k = arr.objectAtIndex_(i).toString();
                            log('    keys[' + i + '] = ' + k);
                        }
                    } catch (e) { log('  allKeys 展开失败: ' + e.message); }
                    return r;
                })
            });
        }
    } catch (e) { log('allKeys 挂钩失败: ' + e.message); }

    try {
        const rm = MMKV['- removeValuesForKeys:'];
        if (rm) {
            const orig = rm.implementation;
            rm.implementation = ObjC.implement(rm, function (handle, s, keys) {
                log('★ MMKV removeValuesForKeys: ' + s(new ObjC.Object(keys)).slice(0, 400));
                return orig(handle, s, keys);
            });
        }
    } catch (e) {}

    return true;
}

/* ---------- ② NSUserDefaults（便宜的兜底） ---------- */
function hookDefaults() {
    try {
        const UD = ObjC.classes.NSUserDefaults;
        const set = UD['- setObject:forKey:'];
        if (set) {
            const orig = set.implementation;
            set.implementation = ObjC.implement(set, function (h, sel, obj, key) {
                const k = new ObjC.Object(key).toString();
                if (isHot(k)) log('★ NSUserDefaults 写 ' + k + ' <= ' + s(new ObjC.Object(obj)));
                return orig(h, sel, obj, key);
            });
        }
    } catch (e) { log('NSUserDefaults 挂钩失败: ' + e.message); }
}

/* ---------- ③ 枚举宿主自己的类（找覆盖层入口） ---------- */
function enumClasses() {
    const pats = /Setting|MMKV|KVStorage|RemoteSettings|Poller/;
    let n = 0;
    ObjC.enumerateLoadedClassesSync().forEach(function (m) {
        const name = m.split('/').pop();
        if (!pats.test(name)) return;
        n++;
        let sels = '';
        try {
            sels = ObjC.classes[name].$ownMethods.join(' ');
        } catch (e) { sels = '<无法枚举>'; }
        log('CLASS ' + name + (sels ? '\n      own: ' + sels.slice(0, 800) : ''));
    });
    log('共匹配 ' + n + ' 个类');
}

/* ---------- 启动 ---------- */
log('=== FDM 探针启动 v0.1 ===');
setTimeout(function () {
    enumClasses();
    const ok = hookMMKV();
    if (!ok) setTimeout(hookMMKV, 800);
    hookDefaults();
}, 300);

/* 周期性汇报（可用来确认探针活着） */
setInterval(function () {
    log('心跳 · MMKV 写(非热点) ' + MARK.mmkv + ' 次');
}, 20000);
