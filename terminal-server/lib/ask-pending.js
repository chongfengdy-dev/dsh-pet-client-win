'use strict';
// 会话状态检测（Node 版）：提问未决 / 审批未决 / 回复完成
//
// 原实现是 ask-pending.py（Python + zstandard）；win 版改用 Node 内置 zstd，
// 去掉 Python 依赖。判定逻辑与原 Python 版逐条对齐：
//   1. ask_user_question 提问未决：tool/call 精确匹配 name + callId 配对 + answered 集合防重试
//   2. approval/asked 审批未决：asked > decided（最近 10 分钟内）
//   3. 回复完成（绿闪）：最后一个 turn/end(completed) 的区间内出现过 user/message
//      —— dsh 0.1.2 起 turn 事件行无 turn 号，故按顺序配对区间（2026-09-06 修复口径）
// 时间窗：只认最近 10 分钟内的未决（历史遗留不提醒）。

const fs = require('fs');
const os = require('os');
const path = require('path');

// 会话文件是多帧 zstd，必须用 zstd-frames 解（Node 内置 API 只解第一帧）
const { decompressAll } = require('./zstd-frames');

const SESS_ROOT = path.join(os.homedir(), '.dsh', 'sessions');
const LOG_NAMES = ['session.v4.jsonl.zstd', 'session.v3.jsonl.zstd', 'session.jsonl.zstd'];
const CALLID_RE = /"callId":"([^"]+)"/;
const TIME_RE = /"time":(\d+)/;
const ASK_WINDOW_MS = 10 * 60 * 1000;   // 10 分钟窗口

/** mtime 最新的会话文件（找不到返回 null） */
function latestSessionFile() {
  let best = null;
  let bestMt = 0;
  let scopes;
  try { scopes = fs.readdirSync(SESS_ROOT); } catch (e) { return null; }
  for (const scope of scopes) {
    const sp = path.join(SESS_ROOT, scope);
    let isDir = false;
    try { isDir = fs.statSync(sp).isDirectory(); } catch (e) { continue; }
    if (!isDir) continue;
    let sids;
    try { sids = fs.readdirSync(sp); } catch (e) { continue; }
    for (const sid of sids) {
      // 会话日志改名历史：session.jsonl.zstd → v3（0.1.5）→ v4（0.1.7）
      for (const fn of LOG_NAMES) {
        const f = path.join(sp, sid, fn);
        let mt;
        try { mt = fs.statSync(f).mtimeMs; } catch (e) { continue; }
        if (mt > bestMt) { bestMt = mt; best = f; }
      }
    }
  }
  return best;
}

async function detect() {
  const file = latestSessionFile();
  if (!file) return { asking: false, done: false };

  const now = Date.now();
  const called = new Map();      // callId -> 最近 call 时间
  const answered = new Set();    // 出现过 result → 已答
  let askAsked = 0;
  let askDecided = 0;
  let lastUserMsg = null;        // 最后 user/message 时间
  let turnActive = false;        // 是否处于 turn/start..turn/end 区间
  let curHasUser = false;        // 当前区间内是否出现过 user/message
  let lastCompletedEnd = null;   // 最后一个 completed turn/end: [time, hasUser]

  let text;
  try {
    text = decompressAll(fs.readFileSync(file)).toString('utf8');
  } catch (e) {
    return { asking: false, done: false };
  }

  for (const line of text.split('\n')) {
    if (line.indexOf('"name":"ask_user_question"') >= 0) {
      const m = line.match(CALLID_RE);
      if (m) {
        const tm = line.match(TIME_RE);
        called.set(m[1], tm ? Number(tm[1]) : 0);
      }
    } else if (line.indexOf('"tool/result"') >= 0) {
      const m = line.match(CALLID_RE);
      if (m) answered.add(m[1]);
    } else if (line.indexOf('"approval/asked"') >= 0) {
      const tm = line.match(TIME_RE);
      if (tm && now - Number(tm[1]) <= ASK_WINDOW_MS) askAsked++;
    } else if (line.indexOf('"approval/decided"') >= 0) {
      const tm = line.match(TIME_RE);
      if (tm && now - Number(tm[1]) <= ASK_WINDOW_MS) askDecided++;
    } else if (line.indexOf('"type":"turn/start"') >= 0) {
      turnActive = true;
      curHasUser = false;
    } else if (line.indexOf('"type":"user/message"') >= 0) {
      const tm = line.match(TIME_RE);
      if (tm) {
        lastUserMsg = Number(tm[1]);
        if (turnActive) curHasUser = true;
      }
    } else if (line.indexOf('"type":"turn/end"') >= 0) {
      const tm = line.match(TIME_RE);
      if (tm && line.indexOf('"kind":"completed"') >= 0) {
        lastCompletedEnd = [Number(tm[1]), curHasUser];
      }
      turnActive = false;
      curHasUser = false;
    }
  }

  let askPending = false;
  for (const [cid, t] of called) {
    if (now - t <= ASK_WINDOW_MS && !answered.has(cid)) { askPending = true; break; }
  }
  const approvalPending = askAsked > askDecided;

  let done = false;
  let doneAt = null;
  // 回复完成：最后一个 turn/end(completed) 存在、其区间内有 user/message（用户提问触发），
  // 且该轮之后没有更新的 user/message（新提问未完成前不算旧轮完成）
  if (lastCompletedEnd && lastCompletedEnd[1]) {
    const t = lastCompletedEnd[0];
    if (lastUserMsg === null || lastUserMsg <= t) { done = true; doneAt = t; }
  }
  return { asking: askPending || approvalPending, done, doneAt };
}

module.exports = { detect, latestSessionFile };

if (require.main === module) {
  detect().then((r) => console.log(JSON.stringify(r)))
        .catch(() => console.log(JSON.stringify({ asking: false, done: false })));
}
