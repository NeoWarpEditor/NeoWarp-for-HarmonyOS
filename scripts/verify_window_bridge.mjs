/**
 * Web 侧窗口桥接层行为验证（无需真机）
 *
 * 在 Node 的 vm 里加载真实的 harmony-bridge.js，注入 HarmonyNative 桩，
 * 断言：独立窗口全部走原生子窗口桥、不再创建 iframe 浮层、跨窗口 RPC 被镜像广播。
 */

import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const BRIDGE = path.resolve(HERE, '../entry/src/main/resources/rawfile/neowarp/assets/harmony-bridge.js');
const src = fs.readFileSync(BRIDGE, 'utf-8');

const calls = [];
const createdElements = [];
const dispatched = [];

class FakeEvent {
  constructor(type, init) {
    this.type = type;
    this.data = init ? init.data : undefined;
  }
}

const channel = {
  __nwMirrored: false,
  postMessage(data) { this.last = data; return true; },
  addEventListener() {},
  dispatchEvent(event) { dispatched.push(event); return true; }
};

const NW = {
  util: {},
  routes: {
    'editor': { url: 'gui/gui.html', title: 'NeoWarp', newTab: true },
    'desktop-settings': { url: 'desktop-settings/desktop-settings.html', title: '设置', width: 1020, height: 720 },
    'task-manager': { url: 'task-manager/task-manager.html', title: '任务管理器', newTab: true }
  },
  rpc: {
    id: 'w-test',
    on() {},
    emit() {},
    initChannel() { return channel; },
    channelPost() { return true; }
  }
};

const host = {
  register() {},
  emit() {},
  trackFrame() {},
  untrackFrame() {},
  announce() {}
};

const sandbox = {
  console,
  setTimeout,
  clearTimeout,
  setInterval,
  clearInterval,
  TextEncoder,
  Uint8Array,
  ArrayBuffer,
  atob: (s) => Buffer.from(s, 'base64').toString('binary'),
  btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
  MessageEvent: FakeEvent,
  CustomEvent: FakeEvent,
  NW,
  NWHost: host,
  HarmonyNative: {
    invoke(ns, method, payload) {
      calls.push({ ns, method, args: JSON.parse(payload || '{}') });
      return Promise.resolve(JSON.stringify({ ok: true, data: '{}' }));
    }
  },
  navigator: {},
  location: {
    origin: 'resource://rawfile',
    href: 'resource://rawfile/neowarp/index.html',
    search: '',
    hash: ''
  },
  localStorage: { setItem() {}, getItem() { return null; } },
  document: {
    readyState: 'complete',
    documentElement: { setAttribute() {} },
    head: { appendChild() {} },
    body: { appendChild() {} },
    createElement(tag) {
      createdElements.push(tag);
      return { style: {}, setAttribute() {}, appendChild() {}, classList: { add() {} } };
    }
  },
  addEventListener() {},
  dispatchEvent() {},
  open() { return null; },
  close() {},
  innerWidth: 1280,
  innerHeight: 800
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;

vm.runInNewContext(src, sandbox, { filename: 'harmony-bridge.js' });

const checks = [];
const add = (name, ok, detail) => checks.push({ name, ok, detail });
const windowOpenCalls = () => calls.filter(c => c.ns === 'window' && c.method === 'open');

// 1. NWWindow.open → 原生 window.open 桥
sandbox.NWWindow.open({
  key: 'desktop-settings',
  url: 'desktop-settings/desktop-settings.html',
  title: '设置',
  width: 1020,
  height: 720
});
const settingsCall = windowOpenCalls().find(c => c.args.key === 'desktop-settings');
add('NWWindow.open 走真实子窗口桥', !!settingsCall,
  settingsCall ? `${settingsCall.args.key} → ${settingsCall.args.url} (${settingsCall.args.width}x${settingsCall.args.height})` : '未触发');
add('NWWindow.has 反映已打开窗口', sandbox.NWWindow.has('desktop-settings') === true, 'has=true');

// 2. window.open 新标签页 → 也变成真实子窗口，且返回 truthy 阻止整页跳转
const ret = sandbox.open('gui/gui.html', '_blank');
const editorCall = windowOpenCalls().find(c => c.args.url === 'gui/gui.html');
add('window.open 新标签页转为真实子窗口', !!editorCall && !!ret,
  editorCall ? `路由反查 key=${editorCall.args.key}，返回 truthy=${!!ret}` : '未触发');
add('编辑器路由被正确识别', !!editorCall && editorCall.args.key === 'editor',
  editorCall ? String(editorCall.args.key) : '-');

// 3. 没有任何 iframe 浮层
add('未创建 iframe 页内小窗', createdElements.filter(t => t === 'iframe').length === 0,
  `createElement 调用: [${createdElements.join(', ') || '无'}]`);

// 4. BroadcastChannel 消息被镜像到原生总线
channel.postMessage({ __nw: 1, ch: 1, t: 'evt', ns: 'desktop', n: 'theme', d: { theme: 'dark' }, from: 'w-test' });
const busCalls = calls.filter(c => c.ns === 'bus' && c.method === 'publish');
add('跨窗口 RPC 镜像到原生总线', busCalls.length > 0 && !!busCalls[0].args.data,
  busCalls.length ? `bus.publish x${busCalls.length}` : '未触发');

// 5. 原生转发回来的消息能重新喂回通道监听器
const before = dispatched.length;
sandbox.NWHarmony.onBusMessage({ __nw: 1, ch: 1, t: 'evt', ns: 'desktop', n: 'theme', d: {}, from: 'w-other' });
add('原生转发消息可被本地通道接收', dispatched.length === before + 1,
  `dispatchEvent 调用 ${dispatched.length - before} 次`);

// 6. 子窗口被系统关闭后清单同步
sandbox.NWHarmony.onWindowClosed('desktop-settings');
add('窗口关闭事件同步清单', sandbox.NWHarmony.available === true && sandbox.NWWindow.has('desktop-settings') === false,
  'has=false');

// 7. 其它窗口打开的窗口，状态能广播同步到本窗口
sandbox.NWHarmony.onWindowState('another-window', true);
add('跨窗口窗口清单同步', sandbox.NWWindow.has('another-window') === true, 'onWindowState → has=true');
sandbox.NWHarmony.onWindowState('another-window', false);
add('跨窗口关闭同步', sandbox.NWWindow.has('another-window') === false, 'has=false');

// 7. 桥接层可用且未新增界面元素
add('桥接层在鸿蒙环境可用', sandbox.NWHarmony.available === true, 'NWHarmony.available=true');

const passed = checks.filter(c => c.ok).length;
const report = {
  verifiedAt: new Date().toISOString(),
  bridge: BRIDGE,
  passed,
  total: checks.length,
  nativeCalls: calls.map(c => `${c.ns}.${c.method}`),
  checks
};
fs.writeFileSync(path.resolve(HERE, '../dist/window-bridge-report.json'), JSON.stringify(report, null, 2));
console.log(`窗口桥接行为验证：${passed}/${checks.length}`);
checks.forEach(c => console.log(`  ${c.ok ? '✓' : '✗'} ${c.name} — ${c.detail}`));
if (passed !== checks.length) process.exit(1);
