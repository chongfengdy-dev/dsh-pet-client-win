'use strict';
// 今日会话 token 消耗统计（Node 版）
//
// 原实现是 today-usage.py（Python + zstandard）；win 版改用 Node 内置 zstd
// （Node ≥ 23 的 zlib.zstdDecompress），彻底去掉 Python 依赖 ——
// Windows 上 `python` 常被 Microsoft Store 的 stub 占据（静默无输出），不可靠。
//
// 精确口径：按每条记录的时间戳（time 字段，毫秒）过滤今日，非按文件 mtime。

const fs = require('fs');
const os = require('os');
const path = require('path');

// 会话文件是多帧 zstd，必须用 zstd-frames 解（Node 内置 API 只解第一帧）
const { decompressAll } = require('./zstd-frames');

const SESS_ROOT = path.join(os.homedir(), '.dsh', 'sessions');

// 会话日志改名历史：session.jsonl.zstd → v3（0.1.5）→ v4（0.1.7）。
// 按新→旧顺序取第一个存在的（v4 是完整文件，含全部历史，不会漏算）
const LOG_NAMES = ['session.v4.jsonl.zstd', 'session.v3.jsonl.zstd', 'session.jsonl.zstd'];

function todayStartMs() {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

async function scan() {
  const total = { input: 0, output: 0, cacheRead: 0 };
  const startMs = todayStartMs();
  let scopes;
  try { scopes = fs.readdirSync(SESS_ROOT); } catch (e) { return total; }
  const seen = new Set();

  for (const scope of scopes) {
    const scopeDir = path.join(SESS_ROOT, scope);
    let isDir = false;
    try { isDir = fs.statSync(scopeDir).isDirectory(); } catch (e) { continue; }
    if (!isDir) continue;

    let sids;
    try { sids = fs.readdirSync(scopeDir); } catch (e) { continue; }
    for (const sid of sids) {
      const sessDir = path.join(scopeDir, sid);
      let file = null;
      for (const fn of LOG_NAMES) {
        const p = path.join(sessDir, fn);
        if (fs.existsSync(p)) { file = p; break; }
      }
      if (!file) continue;
      // 只解压今天动过的会话（全量 270+ 文件要 40s+，超时被杀）
      try { if (fs.statSync(file).mtimeMs < startMs) continue; } catch (e) { continue; }

      let text;
      try {
        text = decompressAll(fs.readFileSync(file)).toString('utf8');
      } catch (e) { continue; }

      for (const line of text.split('\n')) {
        const tm = line.match(/"time":(\d+)/);
        if (!tm || Number(tm[1]) < startMs) continue;
        const um = line.match(/"usage":\{[^}]*\}/);
        if (!um) continue;
        const key = um[0];
        if (seen.has(key)) continue;
        seen.add(key);
        const g = (k) => {
          const m = key.match(new RegExp(k + '":(\\d+)'));
          return m ? Number(m[1]) : 0;
        };
        total.input += g('inputTokens');
        total.output += g('outputTokens');
        total.cacheRead += g('cacheReadTokens');
      }
    }
  }
  return total;
}

module.exports = { scan };

if (require.main === module) {
  scan().then((r) => console.log(JSON.stringify(r)))
        .catch((e) => { console.error('[error]', e.message); process.exit(1); });
}
