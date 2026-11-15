#!/usr/bin/env node
/**
 * 离线资源组装：把 NeoWarp 网页版产物装入 HarmonyOS rawfile
 *
 * 用法：
 *   node scripts/prepare_offline.mjs
 *   node scripts/prepare_offline.mjs --source /workspace/NeoWarp --out <rawfile/neowarp>
 *
 * 流程：
 *   1) 优先复用 dist-web（web/build.mjs 产物）；缺失则调用 web/build.mjs；
 *      仍失败则进入 subset 降级模式，直接组装仓库内可离线资产
 *   2) 全量拷贝到 rawfile/neowarp
 *   3) 在每个 HTML 的 </head> 前注入 harmony-bridge.js（必须在 shims 之后）
 *   4) 构建期 Brotli 预解压（*.br → 普通文件），消除运行时解压开销
 *   5) 补齐字体 / Monaco / 图标 / LICENSE
 *   6) 生成 asset-manifest.json（sha256）+ offline-manifest.json
 */

import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PROJECT = path.resolve(__dirname, '..');
const argv = process.argv.slice(2);

function arg (name, fallback) {
  const i = argv.indexOf('--' + name);
  return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : fallback;
}

const SOURCE = path.resolve(arg('source', '/workspace/NeoWarp'));
const OUT = path.resolve(arg('out', path.join(PROJECT, 'entry/src/main/resources/rawfile/neowarp')));
const VERSION = arg('version', '2.3.0');

const CSP = "default-src 'self' data: blob:; script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:; " +
  "style-src 'self' 'unsafe-inline' data:; img-src 'self' data: blob:; font-src 'self' data:; " +
  "media-src 'self' data: blob:; worker-src 'self' blob:; connect-src 'self' data: blob:; " +
  "object-src 'none'; base-uri 'self'";

let copied = 0;
let decompressed = 0;
let injected = 0;

function ensure (dir) { fs.mkdirSync(dir, {recursive: true}); }
function exists (p) { return fs.existsSync(p); }

function copyTree (from, to, filter) {
  if (!exists(from)) return 0;
  let n = 0;
  const walk = (src, dst) => {
    ensure(dst);
    for (const entry of fs.readdirSync(src, {withFileTypes: true})) {
      const s = path.join(src, entry.name);
      const d = path.join(dst, entry.name);
      if (entry.isDirectory()) {
        if (entry.name === 'node_modules' || entry.name === '.git') continue;
        n += walk(s, d);
      } else {
        if (filter && !filter(s)) continue;
        fs.copyFileSync(s, d);
        n++;
      }
    }
    return n;
  };
  const count = walk(from, to);
  copied += count;
  return count;
}

function walkFiles (dir, out = []) {
  if (!exists(dir)) return out;
  for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) walkFiles(p, out);
    else out.push(p);
  }
  return out;
}

function sha256 (file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

/* -------------------------- 1. 取得静态站点 -------------------------- */
let mode = 'full';
let site = path.join(SOURCE, 'dist-web');

if (!exists(site)) {
  console.log('[offline] dist-web 不存在，尝试调用 web/build.mjs …');
  try {
    execFileSync(process.execPath,
      ['web/build.mjs', '--gui', 'dist-renderer-webpack/editor', '--out', 'dist-web', '--version', VERSION],
      {cwd: SOURCE, stdio: ['ignore', 'pipe', 'pipe'], timeout: 180000});
    console.log('[offline] web/build.mjs 构建成功');
  } catch (e) {
    console.log('[offline] web/build.mjs 不可用（' + (e.message || e) + '）→ 进入 subset 降级模式');
    mode = 'subset';
  }
}

/* -------------------------- 2. 全量拷贝 -------------------------- */
ensure(OUT);
// 清理旧产物（保留 assets/harmony-bridge.js 源）
for (const entry of fs.readdirSync(OUT)) {
  if (entry === 'assets') continue;
  fs.rmSync(path.join(OUT, entry), {recursive: true, force: true});
}

if (mode === 'full') {
  copyTree(site, OUT);
} else {
  buildSubset();
}

/* -------------------------- 3. 注入桥接层与 CSP -------------------------- */
const bridgeSrc = path.join(PROJECT, 'entry/src/main/resources/rawfile/neowarp/assets/harmony-bridge.js');
ensure(path.dirname(bridgeSrc));
if (!exists(bridgeSrc)) {
  console.error('[offline] 缺少 assets/harmony-bridge.js，请先创建');
  process.exit(1);
}
// 源站在别处时也要把桥接层复制过去
const bridgeDst = path.join(OUT, 'assets/harmony-bridge.js');
ensure(path.dirname(bridgeDst));
if (path.resolve(bridgeSrc) !== path.resolve(bridgeDst)) fs.copyFileSync(bridgeSrc, bridgeDst);

for (const file of walkFiles(OUT)) {
  if (!file.endsWith('.html')) continue;
  let html = fs.readFileSync(file, 'utf-8');
  if (html.includes('harmony-bridge.js')) continue;
  const rel = path.relative(OUT, file).split(path.sep).join('/');
  const depth = rel.split('/').length - 1;
  const prefix = depth === 0 ? './assets' : '../'.repeat(depth) + 'assets';
  const tags = [
    '<meta http-equiv="Content-Security-Policy" content="' + CSP + '">',
    '<meta name="neowarp-offline" content="harmonyos-api26">',
    '<script src="' + prefix + '/harmony-bridge.js"></script>'
  ].join('\n    ');
  if (/<\/head>/i.test(html)) html = html.replace(/<\/head>/i, '    ' + tags + '\n  </head>');
  else if (/<body[^>]*>/i.test(html)) html = html.replace(/<body([^>]*)>/i, '<head>\n    ' + tags + '\n  </head>\n<body$1>');
  else html = tags + '\n' + html;
  fs.writeFileSync(file, html, 'utf-8');
  injected++;
}

/* -------------------------- 4. Brotli 构建期预解压 -------------------------- */
for (const file of walkFiles(OUT)) {
  if (!file.endsWith('.br')) continue;
  try {
    const raw = zlib.brotliDecompressSync(fs.readFileSync(file));
    fs.writeFileSync(file.slice(0, -3), raw);
    decompressed++;
  } catch (e) {
    console.warn('[offline] 解压失败，保留原文件: ' + path.relative(OUT, file));
  }
}

/* -------------------------- 5. 补齐随包资产 -------------------------- */
const assetPairs = [
  ['font', 'font'],
  ['art', 'art'],
  ['src-renderer/extension-editor/vs', 'assets/monaco/vs'],
  ['web/vendor', 'assets/vendor'],
  // 素材库与扩展画廊：对应 HarmonyBridge 的 tw-library/ → library/、tw-extensions/ → extensions/ 映射
  ['dist-library-files', 'library'],
  ['dist-extensions', 'extensions'],
  ['LICENSE', 'LICENSE'],
  ['README.md', 'NEOWARP_README.md']
];
for (const [from, to] of assetPairs) {
  const src = path.join(SOURCE, from);
  if (!exists(src)) continue;
  const dst = path.join(OUT, to);
  if (fs.statSync(src).isDirectory()) copyTree(src, dst);
  else { ensure(path.dirname(dst)); fs.copyFileSync(src, dst); copied++; }
}

// GPL-3.0 合规说明
ensure(OUT);
fs.writeFileSync(path.join(OUT, 'THIRD_PARTY_NOTICES.txt'), [
  'NeoWarp HarmonyOS Port — third party notices',
  '',
  'This build bundles NeoWarp (GPL-3.0), derived from TurboWarp Desktop.',
  'Upstream components include scratch-gui, scratch-blocks, scratch-vm,',
  'scratch-render, @turbowarp/extensions, monaco-editor (MIT) and others.',
  'Full license text: LICENSE. Corresponding source: /workspace/NeoWarp + this project.',
  '',
  'All assets are bundled locally. No network permission is declared.'
].join('\n'), 'utf-8');

/* -------------- 5b. 解压第 5 步新增的 Brotli 资产 -------------- */
// dist-library-files / dist-extensions 是在第 5 步才复制进来的，
// 必须在生成清单前解压，保证运行时可直接读 <md5>.svg / *.js。
for (const file of walkFiles(OUT)) {
  if (!file.endsWith('.br')) continue;
  const target = file.slice(0, -3);
  if (exists(target)) continue;
  try {
    const raw = zlib.brotliDecompressSync(fs.readFileSync(file));
    fs.writeFileSync(target, raw);
    decompressed++;
  } catch (e) {
    console.warn('[offline] 解压失败，保留原文件: ' + path.relative(OUT, file));
  }
}

/* -------------------------- 6. 生成清单 -------------------------- */
const files = {};
for (const file of walkFiles(OUT)) {
  const rel = path.relative(OUT, file).split(path.sep).join('/');
  if (rel === 'asset-manifest.json' || rel === 'offline-manifest.json') continue;
  files[rel] = sha256(file);
}
fs.writeFileSync(path.join(OUT, 'asset-manifest.json'), JSON.stringify({
  version: VERSION,
  generatedAt: Date.now(),
  fileCount: Object.keys(files).length,
  files
}, null, 2), 'utf-8');

const totalBytes = Object.keys(files).reduce((sum, rel) => sum + fs.statSync(path.join(OUT, rel)).size, 0);
const report = {
  version: VERSION,
  mode,
  source: SOURCE,
  output: OUT,
  builtAt: new Date().toISOString(),
  copiedFiles: copied,
  injectedHtmlFiles: injected,
  brotliDecompressed: decompressed,
  fileCount: Object.keys(files).length,
  totalBytes,
  totalMB: Math.round(totalBytes / 1024 / 1024 * 100) / 100,
  offlineGuarantees: [
    'no ohos.permission.INTERNET in module.json5',
    'Content-Security-Policy connect-src self',
    'harmony-bridge.js rejects external fetch',
    'ArkWeb onInterceptRequest maps all requests to rawfile'
  ],
  libraryAssets: exists(path.join(SOURCE, 'dist-library-files'))
    ? walkFiles(path.join(SOURCE, 'dist-library-files')).length : 0,
  extensionAssets: exists(path.join(SOURCE, 'dist-extensions'))
    ? walkFiles(path.join(SOURCE, 'dist-extensions')).length : 0,
  note: mode === 'subset'
    ? 'dist-web 不可用：已组装仓库内可离线资产子集；GUI webpack bundle 需在 DevEco 构建机执行 npm run webpack:prod + web/build.mjs 后重新运行本脚本补齐。'
    : '完整网页版站点（含 scratch-gui webpack bundle）已内置。'
};
fs.writeFileSync(path.join(OUT, 'offline-manifest.json'), JSON.stringify(report, null, 2), 'utf-8');

console.log('[offline] 模式=' + mode + ' 文件=' + report.fileCount +
  ' 体积=' + report.totalMB + 'MB 注入HTML=' + injected + ' brotli解压=' + decompressed);
console.log('[offline] 输出: ' + OUT);

/* -------------------------- 降级模式：组装子集 -------------------------- */
function buildSubset () {
  // 合并 core 为 nw-core.js（与 web/build.mjs 一致的顺序）
  const coreDir = path.join(SOURCE, 'web/src/core');
  const core = [];
  if (exists(coreDir)) {
    for (const name of fs.readdirSync(coreDir).sort()) {
      if (!name.endsWith('.js')) continue;
      core.push('/* ==== ' + name + ' ==== */\n' + fs.readFileSync(path.join(coreDir, name), 'utf-8'));
    }
  }
  ensure(path.join(OUT, 'assets'));
  fs.writeFileSync(path.join(OUT, 'assets/nw-core.js'), core.join('\n\n'), 'utf-8');

  copyTree(path.join(SOURCE, 'web/src/shims'), path.join(OUT, 'assets/shims'));
  copyTree(path.join(SOURCE, 'web/src/pwa'), OUT);
  copyTree(path.join(SOURCE, 'web/vendor'), path.join(OUT, 'assets/vendor'));

  // 20+ 辅助窗口页面按原名保留
  const renderer = path.join(SOURCE, 'src-renderer');
  if (exists(renderer)) {
    for (const entry of fs.readdirSync(renderer, {withFileTypes: true})) {
      if (!entry.isDirectory()) continue;
      const dir = path.join(renderer, entry.name);
      const html = path.join(dir, entry.name + '.html');
      const target = path.join(OUT, entry.name, 'index.html');
      if (exists(html)) {
        ensure(path.dirname(target));
        fs.copyFileSync(html, target);
        copied++;
      } else {
        const htmls = fs.readdirSync(dir).filter(n => n.endsWith('.html'));
        if (htmls.length > 0) {
          ensure(path.dirname(target));
          fs.copyFileSync(path.join(dir, htmls[0]), target);
          copied++;
        }
      }
    }
  }

  // 主页：列出可用窗口（离线可浏览）
  const windows = exists(OUT)
    ? fs.readdirSync(OUT, {withFileTypes: true})
      .filter(e => e.isDirectory() && exists(path.join(OUT, e.name, 'index.html')))
      .map(e => e.name)
    : [];
  const cards = windows.map(name =>
    '<a class="card" href="' + name + '/index.html"><span class="dot"></span>' + name + '</a>').join('\n');
  fs.writeFileSync(path.join(OUT, 'index.html'), `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>NeoWarp · HarmonyOS 离线版</title>
<style>
:root{color-scheme:dark}*{box-sizing:border-box}
body{margin:0;background:#0f1115;color:#f2f2f7;font:14px/1.5 -apple-system,BlinkMacSystemFont,"HarmonyOS Sans SC",system-ui,sans-serif;padding:32px}
header{display:flex;align-items:center;gap:14px;margin-bottom:28px}
.logo{width:48px;height:48px;border-radius:14px;background:linear-gradient(135deg,#0a84ff,#5e5ce6);display:grid;place-items:center;font-size:24px;font-weight:700}
h1{font-size:20px;margin:0;font-weight:600}
.badge{margin-left:auto;font-size:11px;color:#30d158;border:1px solid rgba(48,209,88,.3);padding:4px 10px;border-radius:8px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));gap:10px}
.card{display:flex;align-items:center;gap:9px;padding:14px;border-radius:12px;background:#1c1e24;color:#f2f2f7;text-decoration:none;border:1px solid rgba(255,255,255,.06)}
.card:hover{background:#262830}
.dot{width:7px;height:7px;border-radius:50%;background:#0a84ff}
footer{margin-top:28px;color:#8e8e93;font-size:12px}
</style></head><body>
<header><div class="logo">N</div><div><h1>NeoWarp · HarmonyOS 离线版</h1><div style="color:#8e8e93;font-size:12px">API 26 · 零网络权限 · 全部资源随包内置</div></div><div class="badge">● 离线</div></header>
<div class="grid">${cards}</div>
<footer>版本 ${VERSION} · 形态：${mode} · 共 ${windows.length} 个本地窗口</footer>
</body></html>`, 'utf-8');
}
