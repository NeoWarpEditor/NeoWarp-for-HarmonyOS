#!/usr/bin/env node
/**
 * 增量导入 Scratch 素材库（造型/声音/背景/角色）到 HarmonyOS rawfile。
 *
 * 只做三件事，绝不触碰其余已定制的顶层文件：
 *   1) 从本地 NeoWarp 源码 dist-library-files 复制并 brotli 预解压到 library/
 *      （HarmonyBridge.md5Path() 把 assets.scratch.mit.edu/<md5>.<ext> 映射到 library/<md5>.<ext>）
 *   2) 把新增文件写入 asset-manifest.json（sha256）
 *   3) 更新 offline-manifest.json 的 libraryAssets 统计
 *
 * 用法：node scripts/import_library.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import crypto from 'node:crypto';

const PROJECT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const LIB_SRC = '/workspace/NeoWarpTest/NeoWarp/dist-library-files';
const RW = path.join(PROJECT, 'entry/src/main/resources/rawfile/neowarp');
const LIB_DST = path.join(RW, 'library');
const VERSION = '0.0.1';

function sha256 (buf) {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

if (!fs.existsSync(LIB_SRC)) {
  console.error('[library] 找不到素材源: ' + LIB_SRC);
  process.exit(1);
}

fs.mkdirSync(LIB_DST, { recursive: true });
let imported = 0;
let bytes = 0;

for (const name of fs.readdirSync(LIB_SRC)) {
  if (!name.endsWith('.br')) continue;
  const srcFile = path.join(LIB_SRC, name);
  const targetName = name.slice(0, -3); // 去掉 .br → <md5>.<ext>
  const dstFile = path.join(LIB_DST, targetName);
  try {
    const raw = fs.readFileSync(srcFile);
    const out = zlib.brotliDecompressSync(raw);
    fs.writeFileSync(dstFile, out);
    imported++;
    bytes += out.length;
  } catch (e) {
    console.warn('[library] 解压失败，跳过: ' + name + ' (' + (e.message || e) + ')');
  }
}

/* 更新 asset-manifest.json */
const manifestPath = path.join(RW, 'asset-manifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
for (const name of fs.readdirSync(LIB_DST)) {
  const f = path.join(LIB_DST, name);
  if (fs.statSync(f).isFile()) {
    manifest.files['library/' + name] = sha256(fs.readFileSync(f));
  }
}
manifest.fileCount = Object.keys(manifest.files).length;
manifest.generatedAt = Date.now();
manifest.version = VERSION;
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2), 'utf8');

/* 更新 offline-manifest.json */
const offPath = path.join(RW, 'offline-manifest.json');
const off = JSON.parse(fs.readFileSync(offPath, 'utf8'));
off.libraryAssets = imported;
off.brotliDecompressed = (typeof off.brotliDecompressed === 'number' && isFinite(off.brotliDecompressed) ? off.brotliDecompressed : 0) + imported;
off.version = VERSION;
off.copiedFiles = imported; // 修正原脚本累加溢出为科学计数法的历史问题
off.note = 'Scratch 素材库（造型/声音/背景/角色，svg/wav/png）已从本地 NeoWarp 2.4.0 dist-library-files 内置，brotli 预解压，无需联网下载。';
fs.writeFileSync(offPath, JSON.stringify(off, null, 2), 'utf8');

console.log('[library] 已导入 ' + imported + ' 个素材，' + (bytes / 1024 / 1024).toFixed(1) + 'MB');
console.log('[library] asset-manifest 文件数: ' + manifest.fileCount);
