'use strict';
// DeepSeek 开放平台 userToken 读取（Chromium 系浏览器 localStorage / LevelDB）
//
// 背景：HUD 的「今日用量/花费」走 platform.deepseek.com 的网页私有接口，
// 需要网页登录态的 userToken；该 token 存在浏览器 Local Storage 的 LevelDB 里。
//
// 历史：WSL 版用 Python + plyvel（fetch-platform-token.py）；plyvel 在 Windows
// 上没有 wheel（PyPI 仅提供 manylinux 构建，源码编译需 VS Build Tools + 自行
// 编译 LevelDB），故 win 版改用 Node 的 classic-level（自带 win32-x64 预编译）。
// 2026-10-10 实测：读取结果与 plyvel 版 sha256 指纹完全一致，耗时 ~190ms。
//
// 读取要点：浏览器运行中会对 LevelDB 加 LOCK，故先把目录拷到临时位置再读
// （与 plyvel 版同一策略）；拷贝时跳过被占用的文件。

const fs = require('fs');
const os = require('os');
const path = require('path');

const TARGET_KEY = '_https://platform.deepseek.com\x00\x01userToken';

// 常见 Chromium 系浏览器（相对各自的数据根目录）
const BROWSERS = [
  'CentBrowser', 'Chrome', 'Edge', 'BraveSoftware/Brave-Browser',
  'Vivaldi', 'Opera Software/Opera Stable', '360Chrome/Chrome', 'Chromium',
];

let ClassicLevel = null;
try {
  ({ ClassicLevel } = require('classic-level'));
} catch (e) {
  // 未安装（npm i classic-level）时不影响服务启动，只在真正读取时报错
}

/** 浏览器数据根目录：Windows = %LOCALAPPDATA%；WSL = 枚举 /mnt/c/Users/<用户>/AppData/Local */
function browserDataRoots() {
  if (process.platform === 'win32') {
    const local = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
    return [local];
  }
  const roots = [];
  try {
    for (const d of fs.readdirSync('/mnt/c/Users', { withFileTypes: true })) {
      if (!d.isDirectory() || d.name.startsWith('.')) continue;
      if (['Public', 'Default', 'Default User', 'All Users'].includes(d.name)) continue;
      roots.push(path.join('/mnt/c/Users', d.name, 'AppData', 'Local'));
    }
  } catch (e) { /* 非 WSL 环境：无 /mnt/c，忽略 */ }
  return roots;
}

/** 所有候选 leveldb 目录 */
function candidateDirs() {
  const out = [];
  for (const root of browserDataRoots()) {
    for (const b of BROWSERS) {
      out.push(path.join(root, b, 'User Data', 'Default', 'Local Storage', 'leveldb'));
    }
  }
  return out;
}

/** 拷贝 leveldb 目录到临时位置（浏览器持锁时无法直接打开） */
function snapshotDir(src) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-ls-'));
  for (const name of fs.readdirSync(src)) {
    try {
      const p = path.join(src, name);
      if (fs.statSync(p).isFile()) fs.copyFileSync(p, path.join(tmp, name));
    } catch (e) { /* 被占用 / 无权限的文件跳过 */ }
  }
  return tmp;
}

/** 从单个 leveldb 目录读 userToken；读不到返回 null */
async function readTokenFrom(dir) {
  if (!ClassicLevel) throw new Error('classic-level 未安装（在该目录执行 npm i classic-level）');
  if (!fs.existsSync(dir)) return null;
  const tmp = snapshotDir(dir);
  const db = new ClassicLevel(tmp, { createIfMissing: false });
  try {
    await db.open();
    for await (const [k, v] of db.iterator()) {
      if (k === TARGET_KEY) {
        // 值格式：\x01{"value":"<token>","__version":"0"}
        const obj = JSON.parse(String(v).slice(1));
        return obj.value || null;
      }
    }
    return null;
  } finally {
    try { await db.close(); } catch (e) { /* ignore */ }
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (e) { /* ignore */ }
  }
}

/** 遍历所有候选浏览器，返回第一个可用的 userToken（找不到返回 null） */
async function fetchPlatformToken() {
  for (const dir of candidateDirs()) {
    try {
      const token = await readTokenFrom(dir);
      if (token) return token;
    } catch (e) { /* 单个候选失败不阻塞其他 */ }
  }
  return null;
}

module.exports = { fetchPlatformToken, readTokenFrom, candidateDirs, TARGET_KEY };

// 直接运行：默认打印 token；--write 时写回 ../platform-token.json
if (require.main === module) {
  fetchPlatformToken().then((t) => {
    if (!t) { console.error('[error] 未找到已登录 platform.deepseek.com 的浏览器'); process.exit(1); }
    if (process.argv.includes('--write')) {
      const f = path.join(__dirname, '..', 'platform-token.json');
      let old = {};
      try { old = JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) { /* 新文件 */ }
      old.userToken = t;
      old.note = '自动获取自本机浏览器 localStorage（Node / classic-level）';
      fs.writeFileSync(f, JSON.stringify(old, null, 2), 'utf8');
      console.log('[ok] token 已更新到', f);
    } else {
      console.log(t);
    }
  }).catch((e) => { console.error('[error]', e.message); process.exit(1); });
}
