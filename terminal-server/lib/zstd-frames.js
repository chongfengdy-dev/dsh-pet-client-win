'use strict';
// dsh 会话文件（*.jsonl.zstd）解压 —— 多帧 zstd 支持
//
// ⚠️ 这是从 Python 迁到 Node 时最容易踩的坑：
// dsh 写会话日志是"流式 flush"，一个文件里拼了成百上千个**独立 zstd 帧**
// （实测 1.2MB 的文件含 604 帧）。而 Node 内置的 zlib.zstdDecompress /
// createZstdDecompress 只解第一帧 —— 整份文件只返回 208 字节且不报错，
// 表现为"统计恒为 0"这种静默错误。
// Python 的 ZstdDecompressor().stream_reader() 能连续解多帧，所以原
// Python 版没问题。
//
// 解法：按 zstd 魔数（0x28 0xB5 0x2F 0xFD，小端）切分帧，逐帧解压再拼接。
// 魔数误判概率约 2^-32（百万字节文件期望 0.0003 次），且坏帧会被跳过，
// 不会因个别异常毁掉整份统计。
//
// 实测：604 帧 / 1.2MB 文件解压耗时 ~34ms。

const zlib = require('zlib');

const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);

/** 所有 zstd 帧的起始偏移 */
function frameOffsets(buf) {
  const pos = [];
  let i = buf.indexOf(MAGIC);
  while (i >= 0) { pos.push(i); i = buf.indexOf(MAGIC, i + 4); }
  return pos;
}

/** 解压（可能多帧的）zstd buffer，返回完整明文 Buffer；失败返回空 Buffer */
function decompressAll(buf) {
  if (!buf || buf.length === 0) return Buffer.alloc(0);
  const pos = frameOffsets(buf);
  if (pos.length <= 1) {
    try { return zlib.zstdDecompressSync(buf); } catch (e) { return Buffer.alloc(0); }
  }
  const parts = [];
  for (let k = 0; k < pos.length; k++) {
    const from = pos[k];
    const to = k + 1 < pos.length ? pos[k + 1] : buf.length;
    try { parts.push(zlib.zstdDecompressSync(buf.subarray(from, to))); } catch (e) { /* 跳过坏帧 */ }
  }
  return Buffer.concat(parts);
}

module.exports = { decompressAll, frameOffsets };
