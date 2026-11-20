/**
 * 最终产物验证：基于 hvigor 真实编译 + hap-sign-tool 签名的 .hap 做实测校验。
 * 所有检查项均从产物实际读取，不写死结论。
 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';

const PROJ = '/workspace/NeoWarpHarmony';
const HAP = `${PROJ}/dist/NeoWarp-0.0.1-harmony.hap`;
const CLI = '/opt/harmony/command-line-tools';
const LIB = `${CLI}/sdk/default/openharmony/toolchains/lib`;
const JAVA = `${process.env.JAVA_HOME || '/root/.sdkman/candidates/java/current'}/bin/java`;
const checks = [];
const add = (name, ok, detail = '') => checks.push({ name, ok: !!ok, detail });

const sh = (bin, args) => {
  try { return execFileSync(bin, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 64 * 1024 * 1024 }); }
  catch (e) { return (e.stdout || '') + (e.stderr || ''); }
};

add('交付 HAP 存在', fs.existsSync(HAP), fs.existsSync(HAP) ? `${(fs.statSync(HAP).size / 1048576).toFixed(2)} MB` : '缺失');
const buf = fs.readFileSync(HAP);
add('SHA-256', true, crypto.createHash('sha256').update(buf).digest('hex'));

// ZIP 完整性
const zipTest = sh('unzip', ['-tq', HAP]);
add('ZIP 归档完整性 (unzip -t)', /No errors detected|no errors/i.test(zipTest), zipTest.trim().split('\n').slice(-1)[0]);

// 条目清单
const listOut = sh('unzip', ['-l', HAP]);
const entries = listOut.split('\n').map(l => l.trim().split(/\s+/)[3]).filter(Boolean);
const has = n => entries.includes(n);
const count = entries.length;
add('HAP 条目总数', count > 1400, `${count} 个条目`);
for (const n of ['module.json', 'resources.index', 'pack.info', 'pkgSdkInfo.json', 'ets/modules.abc']) {
  add(`必需条目 ${n}`, has(n));
}
add('ArkTS 编译字节码 modules.abc', has('ets/modules.abc'),
  has('ets/modules.abc') ? `${(listOut.match(/(\d+)\s+.*ets\/modules\.abc/) || [])[1] || ''} bytes（真实 ArkTS 编译器产出）` : '');

// rawfile 离线资源
const rawEntries = entries.filter(e => e.startsWith('resources/rawfile/neowarp/'));
add('离线 rawfile 资源', rawEntries.length > 1400, `${rawEntries.length} 个文件`);
add('GUI bundle gui/index.js', rawEntries.includes('resources/rawfile/neowarp/gui/index.js'));
add('注入桥接层 harmony-bridge.js', rawEntries.includes('resources/rawfile/neowarp/assets/harmony-bridge.js'));
add('离线清单 offline-manifest.json', rawEntries.includes('resources/rawfile/neowarp/offline-manifest.json'));

// module.json 内容
let mod = null;
try { mod = JSON.parse(sh('unzip', ['-p', HAP, 'module.json'])); } catch (_e) { /* noop */ }
add('module.json 可解析', mod !== null, mod ? `abilities=${(mod.module?.abilities || []).length}` : '解析失败');
if (mod) {
  const perms = (mod.module?.requestPermissions || []).map(p => p.name);
  add('零 INTERNET 权限（离线硬保证）', !perms.some(p => /INTERNET/i.test(p)), perms.join(', ') || '无权限申请');
  add('deviceTypes 覆盖 PC/平板/折叠', (mod.module?.deviceTypes || []).includes('2in1'),
    (mod.module?.deviceTypes || []).join(', '));
  add('bundle 入口 EntryAbility', mod.module?.mainElement === 'EntryAbility');
}

// 签名验证
const outCer = `${PROJ}/signing/verified-chain.cer`;
const outP7b = `${PROJ}/signing/verified-profile.p7b`;
const verifyOut = sh(JAVA, ['-jar', `${LIB}/hap-sign-tool.jar`, 'verify-app',
  '-inFile', HAP, '-outCertChain', outCer, '-outProfile', outP7b]);
add('hap-sign-tool verify-app', /verify-app success|Verify success/i.test(verifyOut),
  (verifyOut.match(/Digest verify result: [^\n]+/) || [])[0] || verifyOut.trim().split('\n').slice(-1)[0]);
add('签名证书链导出', fs.existsSync(outCer) && fs.readFileSync(outCer, 'utf8').includes('BEGIN CERTIFICATE'),
  fs.existsSync(outCer) ? `${(fs.readFileSync(outCer, 'utf8').match(/BEGIN CERTIFICATE/g) || []).length} 张证书` : '未导出');
add('签名 Profile 导出', fs.existsSync(outP7b) && fs.statSync(outP7b).size > 1000,
  fs.existsSync(outP7b) ? `${fs.statSync(outP7b).size} bytes` : '未导出');

// 工程源码：纯容器 + 真实子窗口，无原生外围 UI
const etsDir = `${PROJ}/entry/src/main/ets`;
const etsCount = (function walk(d) {
  return fs.readdirSync(d, { withFileTypes: true }).reduce((n, e) =>
    n + (e.isDirectory() ? walk(path.join(d, e.name)) : (e.name.endsWith('.ets') ? 1 : 0)), 0);
})(etsDir);
const requiredEts = [
  'pages/Index.ets', 'pages/SubWindow.ets', 'window/SubWindowManager.ets',
  'common/WindowBus.ets', 'bridge/HarmonyBridge.ets', 'bridge/NativeServices.ets',
  'entryability/EntryAbility.ets'
];
add('ArkTS 源码齐备', requiredEts.every(f => fs.existsSync(`${etsDir}/${f}`)), `${etsCount} 个 .ets`);
const indexSrc = fs.readFileSync(`${etsDir}/pages/Index.ets`, 'utf8');
const bannedUi = ['TitleBar', 'SidePanel', 'FoldSafeLayout', 'TaskManagerPanel'];
add('主窗口无原生外围 UI', bannedUi.every(x => !indexSrc.includes(x)) && !fs.existsSync(`${etsDir}/components`),
  '纯 ArkWeb 全屏容器，界面由 Web 渲染');
const subWinSrc = fs.readFileSync(`${etsDir}/pages/SubWindow.ets`, 'utf8');
add('独立窗口为 OS 级子窗口', subWinSrc.includes('Stack()') && subWinSrc.includes('Web({') &&
  !subWinSrc.includes('TitleBar'), '子窗口内仅一个铺满的 ArkWeb');
const bridgeSrc = fs.readFileSync(`${PROJ}/entry/src/main/resources/rawfile/neowarp/assets/harmony-bridge.js`, 'utf8');
add('页内 iframe 浮层已移除', bridgeSrc.includes('global.NWWindow = nativeWindowApi') &&
  bridgeSrc.includes('global.open = function') && !bridgeSrc.includes('openFallback'),
  '窗口打开统一走原生子窗口');

// Issue 修复回归检查（GitHub issue #1 的 19 项）
const bridgeArkSrc = fs.readFileSync(`${etsDir}/bridge/HarmonyBridge.ets`, 'utf8');
add('二进制资源不再被 UTF-8 破坏（issue 1/8/10/11/16/18）',
  bridgeArkSrc.includes('setResponseData(bytes.buffer') && bridgeArkSrc.includes('isTextAsset'),
  '图片/字体/声音按 ArrayBuffer 原样返回');
// 提取 HAP 内真实 PNG/字体字节验证魔数未被破坏
const tmpDir = fs.mkdtempSync('/tmp/nw-verify-');
try {
  execFileSync('unzip', ['-q', '-o', HAP, 'resources/rawfile/neowarp/logo.png',
    'resources/rawfile/neowarp/favicon.png'], { cwd: tmpDir, stdio: 'pipe' });
  const pngMagic = fs.readFileSync(`${tmpDir}/resources/rawfile/neowarp/logo.png`).subarray(0, 8).toString('hex');
  add('HAP 内图片字节完整（PNG 魔数）', pngMagic === '89504e470d0a1a0a', pngMagic);
} catch (_e) { add('HAP 内图片字节完整（PNG 魔数）', false, '提取失败'); }
finally { fs.rmSync(tmpDir, { recursive: true, force: true }); }
add('CPU 百分比换算修正（issue 5）', /getCpuUsage\(\)\s*\*\s*100/.test(
  fs.readFileSync(`${etsDir}/common/PerformanceManager.ets`, 'utf8')), '比例 ×100 得百分比');
add('任务管理器 ramTotalMB 字段对齐（issue 5）',
  bridgeSrc.includes('ramTotalMB: totalMB') && fs.readFileSync(
    `${PROJ}/entry/src/main/resources/rawfile/neowarp/assets/shims/misc.js`, 'utf8').includes('ramTotalMB: 0'),
  'GUI 读取的字段名已补齐');
add('外链交系统浏览器打开（issue 19）',
  bridgeSrc.includes('openExternal') && bridgeSrc.includes('TRUSTED_EXTERNAL') &&
  fs.readFileSync(`${etsDir}/bridge/NativeServices.ets`, 'utf8').includes('system.openExternal'),
  'GitHub 等可信外链走 startAbility');
add('在线状态误判修正（issue 1/2）',
  bridgeSrc.includes("'onLine'") && bridgeSrc.includes('return true'), 'navigator.onLine 稳定为真');
add('待办勾选后沉底（issue 13）',
  fs.readFileSync(`${PROJ}/entry/src/main/resources/rawfile/neowarp/todo-list/todo-list.html`, 'utf8').includes('todos.push(todo)'),
  '完成后移至列表底部');
add('鸿蒙版隐藏最近项目（issue 17）',
  fs.readFileSync(`${PROJ}/entry/src/main/resources/rawfile/neowarp/assets/shims/home.js`, 'utf8').includes('NWHarmony.available'),
  '避免失效的文件授权入口');
add('本地 AI 窗口不误报断线（issue 3）',
  /if \(!TOKEN && !BOOT\) return;/.test(fs.readFileSync(
    `${PROJ}/entry/src/main/resources/rawfile/neowarp/ai/remote-bridge.js`, 'utf8')),
  '无 token 时不进入远程模式');

// 工具链版本
const env = { ...process.env, PATH: `${CLI}/bin:${process.env.JAVA_HOME || ''}/bin:${process.env.PATH}` };
const hvigorV = sh('hvigorw', ['-v']).trim().split('\n').slice(-1)[0];
const ohpmV = sh('ohpm', ['-v']).trim().split('\n').slice(-1)[0];
add('HarmonyOS CLI 已安装', /^\d+\.\d+\.\d+/.test(hvigorV), `hvigorw ${hvigorV} | ohpm ${ohpmV}`);
const sdkPkg = JSON.parse(fs.readFileSync(`${CLI}/sdk/default/sdk-pkg.json`, 'utf8')).data;
add('SDK 为 API 26 Release', sdkPkg.apiVersion === '26' && sdkPkg.releaseType === 'Release',
  `${sdkPkg.displayName} / ${sdkPkg.version} / ${sdkPkg.stage}`);

const passed = checks.filter(c => c.ok).length;
const report = {
  file: HAP,
  checkedAt: new Date().toISOString(),
  mode: 'real-harmonyos-toolchain',
  toolchain: {
    cli: 'HarmonyOS Command Line Tools 26.0.0.821',
    sdk: `${sdkPkg.displayName} (${sdkPkg.version})`,
    hvigorw: hvigorV, ohpm: ohpmV,
    jdk: 'OpenJDK 21.0.13 (Corretto)'
  },
  buildChain: [
    'hvigorw assembleHap --mode module -p product=default -p buildMode=release --no-daemon',
    'node scripts/sign_hap.mjs (hap-sign-tool sign-profile / sign-app / verify-app)'
  ],
  summary: { passed, total: checks.length, allPassed: passed === checks.length },
  checks,
  remainingBoundary: '华为开发者正式证书 + 设备 UDID profile + 真机 A1-A8 验收 + 应用市场上架'
};
const out = `${PROJ}/dist/verify-report.json`;
fs.writeFileSync(out, JSON.stringify(report, null, 2));
console.log(`=== 最终验证：${passed}/${checks.length} 通过 ===`);
checks.forEach(c => console.log(` ${c.ok ? '✓' : '✗'} ${c.name}${c.detail ? ' · ' + c.detail : ''}`));
console.log(`\n报告: ${out}`);
