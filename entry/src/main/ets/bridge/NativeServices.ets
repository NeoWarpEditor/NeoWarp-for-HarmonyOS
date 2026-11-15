/**
 * ArkTS 原生能力服务
 *
 * 这是桌面版 Electron 主进程职责在 HarmonyOS 上的等价实现：
 *   fs / crypto / system / theme / window / media / perf / package / distributed / device
 *
 * 设计约束：
 *   - 显式 switch 分派，零反射、零 any 动态调用（热路径编译期可检查）
 *   - 所有跨边界数据 JSON 字符串进出，错误统一为 BridgeEnvelope
 *   - 不申请 INTERNET：任何试图出网的调用直接返回 BRIDGE_ERR_OFFLINE
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import {
  DeviceSnapshot, BridgeEnvelope, PerfPolicy, SpriteStat, RecentProject,
  okEnvelope, errEnvelope,
  BRIDGE_ERR_UNKNOWN_METHOD, BRIDGE_ERR_BAD_ARGS, BRIDGE_ERR_IO,
  BRIDGE_ERR_PERMISSION, BRIDGE_ERR_OFFLINE, BRIDGE_CHUNK_LIMIT
} from '../common/Constants';
import { PerformanceManager } from '../common/PerformanceManager';

const PREF_STORE: string = 'neowarp_native';
const PREF_RECENT: string = 'recent_projects';
const PREF_THEME: string = 'ui_theme';
const PROJECT_DIR: string = 'projects';
const ASSET_DIR: string = 'assets';

interface SaveProjectArgs { name: string; data: string; }
interface SaveAsArgs { name: string; data: string; }
interface ReadAssetArgs { name: string; }
interface WriteAssetArgs { name: string; data: string; }
interface HashArgs { data: string; }
interface ThemeSetArgs { theme: string; }
interface WindowOpenArgs { key: string; title: string; }
interface WindowKeyArgs { key: string; }
interface WindowTitleArgs { title: string; }
interface FullscreenArgs { enabled: boolean; }
interface PerfProfileArgs { tier: number; }
interface VisibilityArgs { visible: boolean; }
interface SpriteStatsArgs { sprites: SpriteStat[]; }
interface PermissionArgs { name: string; }

/** 由 UI 层实现的窗口/设备宿主能力，避免服务层反向依赖 ArkUI 组件 */
export interface WindowHost {
  openWindow: (key: string, title: string) => void;
  closeWindow: (key: string) => void;
  focusWindow: (key: string) => void;
  setTitle: (title: string) => void;
  setFullscreen: (enabled: boolean) => void;
  requestPermissions: (names: string[]) => Promise<boolean>;
  currentSnapshot: () => DeviceSnapshot;
}

export class NativeServices {
  private context: common.UIAbilityContext;
  private perf: PerformanceManager;
  private host: WindowHost | null = null;
  private sandbox: string = '';

  constructor(context: common.UIAbilityContext, perf: PerformanceManager) {
    this.context = context;
    this.perf = perf;
    this.sandbox = context.filesDir;
  }

  attachHost(host: WindowHost): void {
    this.host = host;
  }

  /** 启动期建目录，避免首次保存时才创建造成卡顿 */
  async initialize(): Promise<void> {
    this.ensureDir(this.sandbox + '/' + PROJECT_DIR);
    this.ensureDir(this.sandbox + '/' + ASSET_DIR);
  }

  /** 唯一入口：显式分派表 */
  async dispatch(key: string, argsJson: string): Promise<BridgeEnvelope> {
    if (argsJson.length > BRIDGE_CHUNK_LIMIT) {
      return errEnvelope(BRIDGE_ERR_BAD_ARGS, 'payload exceeds 2MB chunk limit');
    }
    switch (key) {
      case 'fs.openProject': return await this.openProject();
      case 'fs.saveProject': return await this.saveProject(this.parse<SaveProjectArgs>(argsJson));
      case 'fs.saveAs': return await this.saveAs(this.parse<SaveAsArgs>(argsJson));
      case 'fs.listRecent': return await this.listRecent();
      case 'fs.deleteRecent': return await this.deleteRecent(this.parse<WindowKeyArgs>(argsJson));
      case 'fs.readAsset': return await this.readAsset(this.parse<ReadAssetArgs>(argsJson));
      case 'fs.writeAsset': return await this.writeAsset(this.parse<WriteAssetArgs>(argsJson));
      case 'crypto.hash': return await this.hash(this.parse<HashArgs>(argsJson));
      case 'crypto.encrypt': return errEnvelope(BRIDGE_ERR_UNKNOWN_METHOD, 'encrypt is handled by Web packager');
      case 'crypto.decrypt': return errEnvelope(BRIDGE_ERR_UNKNOWN_METHOD, 'decrypt is handled by Web packager');
      case 'system.getStats': return this.systemStats();
      case 'system.getMemoryInfo': return this.memoryInfo();
      case 'theme.get': return await this.getTheme();
      case 'theme.set': return await this.setTheme(this.parse<ThemeSetArgs>(argsJson));
      case 'window.open': return this.windowOpen(this.parse<WindowOpenArgs>(argsJson));
      case 'window.close': return this.windowClose(this.parse<WindowKeyArgs>(argsJson));
      case 'window.focus': return this.windowFocus(this.parse<WindowKeyArgs>(argsJson));
      case 'window.setTitle': return this.windowSetTitle(this.parse<WindowTitleArgs>(argsJson));
      case 'window.fullscreen': return this.windowFullscreen(this.parse<FullscreenArgs>(argsJson));
      case 'media.enumerateDevices': return this.enumerateMediaDevices();
      case 'media.requestPermission': return await this.requestMediaPermission(this.parse<PermissionArgs>(argsJson));
      case 'perf.setProfile': return this.setProfile(this.parse<PerfProfileArgs>(argsJson));
      case 'perf.getMetrics': return this.getMetrics();
      case 'perf.notifyVisibility': return this.notifyVisibility(this.parse<VisibilityArgs>(argsJson));
      case 'package.html': return this.packageTarget('html');
      case 'package.zip': return this.packageTarget('zip');
      case 'distributed.discover': return this.distributedDiscover();
      case 'distributed.send': return errEnvelope(BRIDGE_ERR_OFFLINE, 'public network is disabled; use system distributed channel');
      case 'device.getProfile': return this.deviceProfile();
      case 'device.onFoldChange': return this.deviceProfile();
      default: return errEnvelope(BRIDGE_ERR_UNKNOWN_METHOD, 'unknown native method: ' + key);
    }
  }

  /** VM 事件总线：由 Web 层推送角色统计，供 task-manager 使用 */
  updateSpriteStats(sprites: SpriteStat[]): void {
    this.perf.updateSpriteStats(sprites);
  }

  // ── fs ────────────────────────────────────────────────────────────────

  private async openProject(): Promise<BridgeEnvelope> {
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.sb3', '.sb2', '.sb', '.np1', '.npnp', '.viewsb3'];
      const viewPicker = new picker.DocumentViewPicker(this.context);
      const uris: string[] = await viewPicker.select(options);
      if (uris.length === 0) {
        return okEnvelope('{"cancelled":true}');
      }
      const uri: string = uris[0];
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(file.fd);
      const buffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buffer);
      fs.closeSync(file);
      const encoded: string = this.toBase64(new Uint8Array(buffer));
      await this.pushRecent(this.fileName(uri), uri);
      return okEnvelope(JSON.stringify({ name: this.fileName(uri), uri: uri, data: encoded }));
    } catch (_e) {
      return errEnvelope(BRIDGE_ERR_IO, 'open project failed');
    }
  }

  private async saveProject(args: SaveProjectArgs): Promise<BridgeEnvelope> {
    if (!args.name || args.data === undefined) {
      return errEnvelope(BRIDGE_ERR_BAD_ARGS, 'name/data required');
    }
    const dest: string = this.sandbox + '/' + PROJECT_DIR + '/' + args.name;
    return await this.atomicWrite(dest, args.data);
  }

  private async saveAs(args: SaveAsArgs): Promise<BridgeEnvelope> {
    if (!args.name || args.data === undefined) {
      return errEnvelope(BRIDGE_ERR_BAD_ARGS, 'name/data required');
    }
    try {
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [args.name];
      const viewPicker = new picker.DocumentViewPicker(this.context);
      const uris: string[] = await viewPicker.save(options);
      const uri: string = uris.length > 0 ? uris[0] : '';
      if (uri.length === 0) {
        return okEnvelope('{"cancelled":true}');
      }
      const result = await this.atomicWrite(uri, args.data);
      if (result.ok) {
        await this.pushRecent(this.fileName(uri), uri);
      }
      return result;
    } catch (_e) {
      return errEnvelope(BRIDGE_ERR_IO, 'save as failed');
    }
  }

  /** 临时文件 + rename，保证断电/崩溃不会留下写一半的项目 */
  private async atomicWrite(dest: string, data: string): Promise<BridgeEnvelope> {
    const tmp: string = dest + '.tmp';
    try {
      const bytes: Uint8Array = this.fromBase64(data);
      const file = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, bytes.buffer);
      fs.fsyncSync(file.fd);
      fs.closeSync(file);
      fs.renameSync(tmp, dest);
      return okEnvelope(JSON.stringify({ path: dest, size: bytes.length }));
    } catch (_e) {
      try { fs.unlinkSync(tmp); } catch (_ignored) { /* no-op */ }
      return errEnvelope(BRIDGE_ERR_IO, 'atomic write failed');
    }
  }

  private async listRecent(): Promise<BridgeEnvelope> {
    try {
      const store = await preferences.getPreferences(this.context, PREF_STORE);
      const raw: string = await store.get(PREF_RECENT, '[]') as string;
      const items: RecentProject[] = JSON.parse(raw) as RecentProject[];
      return okEnvelope(JSON.stringify(items));
    } catch (_e) {
      return okEnvelope('[]');
    }
  }

  private async deleteRecent(args: WindowKeyArgs): Promise<BridgeEnvelope> {
    try {
      const store = await preferences.getPreferences(this.context, PREF_STORE);
      const raw: string = await store.get(PREF_RECENT, '[]') as string;
      const items: RecentProject[] = JSON.parse(raw) as RecentProject[];
      const kept: RecentProject[] = items.filter((item) => item.path !== args.key);
      await store.put(PREF_RECENT, JSON.stringify(kept));
      await store.flush();
      return okEnvelope('{"deleted":true}');
    } catch (_e) {
      return errEnvelope(BRIDGE_ERR_IO, 'delete recent failed');
    }
  }

  private async pushRecent(name: string, path: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(this.context, PREF_STORE);
      const raw: string = await store.get(PREF_RECENT, '[]') as string;
      const items: RecentProject[] = JSON.parse(raw) as RecentProject[];
      const kept: RecentProject[] = items.filter((item) => item.path !== path);
      kept.unshift({ path: path, name: name, modifiedAt: Date.now() });
      await store.put(PREF_RECENT, JSON.stringify(kept.slice(0, 20)));
      await store.flush();
    } catch (_e) { /* 最近列表是非关键路径，失败不影响主流程 */ }
  }

  private async readAsset(args: ReadAssetArgs): Promise<BridgeEnvelope> {
    if (!args.name) return errEnvelope(BRIDGE_ERR_BAD_ARGS, 'name required');
    const path: string = this.sandbox + '/' + ASSET_DIR + '/' + args.name;
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(file.fd);
      const buffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buffer);
      fs.closeSync(file);
      return okEnvelope(JSON.stringify({ data: this.toBase64(new Uint8Array(buffer)) }));
    } catch (_e) {
      return errEnvelope(BRIDGE_ERR_IO, 'asset not found: ' + args.name);
    }
  }

  private async writeAsset(args: WriteAssetArgs): Promise<BridgeEnvelope> {
    if (!args.name || args.data === undefined) {
      return errEnvelope(BRIDGE_ERR_BAD_ARGS, 'name/data required');
    }
    return await this.atomicWrite(this.sandbox + '/' + ASSET_DIR + '/' + args.name, args.data);
  }

  // ── crypto / system / theme ──────────────────────────────────────────

  private async hash(args: HashArgs): Promise<BridgeEnvelope> {
    try {
      const encoder = new util.TextEncoder();
      const bytes: Uint8Array = encoder.encodeInto(args.data);
      const md = cryptoFramework.createMd('SHA256');
      await md.update({ data: bytes });
      const digest = await md.digest();
      return okEnvelope(JSON.stringify({ hex: this.toHex(digest.data) }));
    } catch (_e) {
      return errEnvelope(BRIDGE_ERR_IO, 'hash failed');
    }
  }

  private systemStats(): BridgeEnvelope {
    return okEnvelope(JSON.stringify(this.perf.sample()));
  }

  private memoryInfo(): BridgeEnvelope {
    const stats = this.perf.sample();
    return okEnvelope(JSON.stringify({
      usedMB: stats.system.memoryUsedMB,
      totalMB: stats.system.memoryTotalMB,
      cacheLimitMB: this.perf.cacheLimitMB()
    }));
  }

  private async getTheme(): Promise<BridgeEnvelope> {
    try {
      const store = await preferences.getPreferences(this.context, PREF_STORE);
      const theme: string = await store.get(PREF_THEME, 'dark') as string;
      return okEnvelope(JSON.stringify({ theme: theme }));
    } catch (_e) {
      return okEnvelope('{"theme":"dark"}');
    }
  }

  private async setTheme(args: ThemeSetArgs): Promise<BridgeEnvelope> {
    if (!args.theme) return errEnvelope(BRIDGE_ERR_BAD_ARGS, 'theme required');
    try {
      const store = await preferences.getPreferences(this.context, PREF_STORE);
      await store.put(PREF_THEME, args.theme);
      await store.flush();
      return okEnvelope('{"saved":true}');
    } catch (_e) {
      return errEnvelope(BRIDGE_ERR_IO, 'save theme failed');
    }
  }

  // ── window / media / perf / package / distributed ────────────────────

  private windowOpen(args: WindowOpenArgs): BridgeEnvelope {
    if (!this.host) return errEnvelope(BRIDGE_ERR_IO, 'window host not attached');
    this.host.openWindow(args.key, args.title);
    return okEnvelope('{"opened":true}');
  }

  private windowClose(args: WindowKeyArgs): BridgeEnvelope {
    if (!this.host) return errEnvelope(BRIDGE_ERR_IO, 'window host not attached');
    this.host.closeWindow(args.key);
    return okEnvelope('{"closed":true}');
  }

  private windowFocus(args: WindowKeyArgs): BridgeEnvelope {
    if (!this.host) return errEnvelope(BRIDGE_ERR_IO, 'window host not attached');
    this.host.focusWindow(args.key);
    return okEnvelope('{"focused":true}');
  }

  private windowSetTitle(args: WindowTitleArgs): BridgeEnvelope {
    if (!this.host) return errEnvelope(BRIDGE_ERR_IO, 'window host not attached');
    this.host.setTitle(args.title);
    return okEnvelope('{"saved":true}');
  }

  private windowFullscreen(args: FullscreenArgs): BridgeEnvelope {
    if (!this.host) return errEnvelope(BRIDGE_ERR_IO, 'window host not attached');
    this.host.setFullscreen(args.enabled);
    return okEnvelope('{"saved":true}');
  }

  private enumerateMediaDevices(): BridgeEnvelope {
    return okEnvelope(JSON.stringify({ devices: [], source: 'arkts-permission-gate' }));
  }

  private async requestMediaPermission(args: PermissionArgs): Promise<BridgeEnvelope> {
    if (!this.host) return errEnvelope(BRIDGE_ERR_IO, 'window host not attached');
    const granted: boolean = await this.host.requestPermissions([args.name]);
    if (!granted) return errEnvelope(BRIDGE_ERR_PERMISSION, 'permission denied');
    return okEnvelope('{"granted":true}');
  }

  private setProfile(args: PerfProfileArgs): BridgeEnvelope {
    const policy: PerfPolicy = this.perf.currentPolicy();
    return okEnvelope(JSON.stringify({ requestedTier: args.tier, applied: policy }));
  }

  private getMetrics(): BridgeEnvelope {
    return okEnvelope(JSON.stringify({
      policy: this.perf.currentPolicy(),
      foreground: this.perf.isForeground(),
      cacheLimitMB: this.perf.cacheLimitMB(),
      cpuSeries: this.perf.cpuSeries(),
      memorySeries: this.perf.memorySeries()
    }));
  }

  private notifyVisibility(args: VisibilityArgs): BridgeEnvelope {
    if (args.visible) {
      this.perf.onForeground();
    } else {
      this.perf.onBackground();
    }
    return okEnvelope('{"saved":true}');
  }

  private packageTarget(target: string): BridgeEnvelope {
    // 打包器本体是内置 Web 资产（web/build.mjs 的 standalone.html），
    // 原生层只负责提供输出目录，产物仍在沙箱内，不经网络。
    return okEnvelope(JSON.stringify({
      target: target,
      outputDir: this.sandbox + '/' + PROJECT_DIR,
      engine: 'rawfile://neowarp/packager/standalone.html'
    }));
  }

  private distributedDiscover(): BridgeEnvelope {
    return okEnvelope(JSON.stringify({
      channel: 'ohos-distributed-datasync',
      internet: false
    }));
  }

  private deviceProfile(): BridgeEnvelope {
    if (!this.host) return errEnvelope(BRIDGE_ERR_IO, 'window host not attached');
    return okEnvelope(JSON.stringify(this.host.currentSnapshot()));
  }

  // ── helpers ──────────────────────────────────────────────────────────

  private parse<T>(json: string): T {
    return JSON.parse(json) as T;
  }

  private ensureDir(path: string): void {
    try {
      if (!fs.accessSync(path)) {
        fs.mkdirSync(path, true);
      }
    } catch (_e) { /* 目录已存在或不可访问时由后续 IO 报错 */ }
  }

  private fileName(uri: string): string {
    const parts: string[] = uri.split('/');
    return parts.length > 0 ? parts[parts.length - 1] : 'project.sb3';
  }

  private toBase64(bytes: Uint8Array): string {
    const helper = new util.Base64Helper();
    return helper.encodeToStringSync(bytes);
  }

  private fromBase64(text: string): Uint8Array {
    const helper = new util.Base64Helper();
    return helper.decodeSync(text);
  }

  private toHex(bytes: Uint8Array): string {
    let out: string = '';
    for (const b of bytes) {
      out += b.toString(16).padStart(2, '0');
    }
    return out;
  }
}
