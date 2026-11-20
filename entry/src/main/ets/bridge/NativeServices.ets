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
import { connection } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import {
  DeviceSnapshot, BridgeEnvelope, PerfPolicy, SpriteStat, RecentProject,
  okEnvelope, errEnvelope,
  BRIDGE_ERR_UNKNOWN_METHOD, BRIDGE_ERR_BAD_ARGS, BRIDGE_ERR_IO,
  BRIDGE_ERR_PERMISSION, BRIDGE_ERR_OFFLINE, BRIDGE_CHUNK_LIMIT
} from '../common/Constants';
import { PerformanceManager } from '../common/PerformanceManager';
import { WindowBus } from '../common/WindowBus';
import { CollabServer, CollabStartOptions, CollabCallbacks } from '../collab/CollabServer';
import { CollabClient, CollabJoinOptions, CollabClientCallbacks } from '../collab/CollabClient';

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
interface WindowOpenArgs { key: string; title: string; url: string; width: number; height: number; }
interface WindowKeyArgs { key: string; }
interface WindowTitleArgs { key: string; title: string; }
interface FullscreenArgs { enabled: boolean; }
interface PerfProfileArgs { tier: number; }
interface VisibilityArgs { visible: boolean; }
interface SpriteStatsArgs { sprites: SpriteStat[]; }
interface PermissionArgs { name: string; }
interface BusPublishArgs { data: string; }
interface OpenExternalArgs { url: string; }
interface CollabHostArgs { password: string; port: number; permissions: string; hostName: string; hostAvatar: string; }
interface CollabJoinArgs { ip: string; port: number; password: string; nickname: string; avatar: string; }
interface CollabPushArgs { project: string; target: string; }
interface CollabChatArgs { text: string; }
interface CollabDiscoverArgs { port: number; }

/** 由 UI 层实现的窗口/设备宿主能力，避免服务层反向依赖 ArkUI 组件 */
export interface WindowHost {
  openWindow: (key: string, title: string, url: string, width: number, height: number) => void;
  closeWindow: (key: string) => void;
  focusWindow: (key: string) => void;
  setTitle: (key: string, title: string) => void;
  setFullscreen: (enabled: boolean) => void;
  hasWindow: (key: string) => boolean;
  publish: (data: string) => void;
  requestPermissions: (names: string[]) => Promise<boolean>;
  currentSnapshot: () => DeviceSnapshot;
  openExternal: (url: string) => Promise<boolean>;
}

export class NativeServices {
  private context: common.UIAbilityContext;
  private perf: PerformanceManager;
  private host: WindowHost | null = null;
  private sandbox: string = '';
  private collabServer: CollabServer | null = null;
  private collabClient: CollabClient | null = null;
  private collabIsHost: boolean = false;

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
      case 'window.has': return this.windowHas(this.parse<WindowKeyArgs>(argsJson));
      case 'bus.publish': return this.busPublish(this.parse<BusPublishArgs>(argsJson));
      case 'collab.startHost': return await this.collabStartHost(this.parse<CollabHostArgs>(argsJson));
      case 'collab.endHost': return this.collabEnd();
      case 'collab.getInfo': return this.collabGetInfo();
      case 'collab.getMembers': return this.collabGetMembers();
      case 'collab.getOnlineCount': return this.collabGetOnlineCount();
      case 'collab.pushProject': return this.collabPushProject(this.parse<CollabPushArgs>(argsJson));
      case 'collab.sendChat': return this.collabSendChat(this.parse<CollabChatArgs>(argsJson));
      case 'collab.isRunning': return this.collabIsRunning();
      case 'collab.join': return await this.collabJoin(this.parse<CollabJoinArgs>(argsJson));
      case 'collab.leave': return this.collabLeave();
      case 'collab.sendProject': return this.collabSendProject(this.parse<CollabPushArgs>(argsJson));
      case 'collab.getLocalIP': return await this.collabGetLocalIP();
      case 'collab.discover': return await this.collabDiscover(this.parse<CollabDiscoverArgs>(argsJson));
      case 'system.openExternal': return await this.openExternal(this.parse<OpenExternalArgs>(argsJson));
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
    const width: number = args.width > 0 ? args.width : 980;
    const height: number = args.height > 0 ? args.height : 700;
    this.host.openWindow(args.key, args.title, args.url, width, height);
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
    this.host.setTitle(args.key, args.title);
    return okEnvelope('{"saved":true}');
  }

  private windowFullscreen(args: FullscreenArgs): BridgeEnvelope {
    if (!this.host) return errEnvelope(BRIDGE_ERR_IO, 'window host not attached');
    this.host.setFullscreen(args.enabled);
    return okEnvelope('{"saved":true}');
  }

  private windowHas(args: WindowKeyArgs): BridgeEnvelope {
    const exists: boolean = this.host !== null && this.host.hasWindow(args.key);
    return okEnvelope(exists ? '{"exists":true}' : '{"exists":false}');
  }

  /** Web 侧 BroadcastChannel 消息的原生镜像：转发到所有真实窗口 */
  private busPublish(args: BusPublishArgs): BridgeEnvelope {
    const script: string =
      'if (window.NWHarmony && window.NWHarmony.onBusMessage) {' +
      'window.NWHarmony.onBusMessage(' + args.data + ');' +
      '}';
    WindowBus.get().broadcast(script);
    return okEnvelope('{"published":true}');
  }

  /* ===================== 局域网协作（复刻桌面版信令协议） ===================== */

  /** 把协作事件广播到所有 ArkWeb 窗口，Web 侧 NW.rpc.emit('collab', ...) 接收 */
  private emitCollab(event: string, data: Object): void {
    const script: string =
      'if (window.NW && window.NW.rpc && window.NW.rpc.emit) {' +
      'window.NW.rpc.emit("collab",' + JSON.stringify(event) + ',' + JSON.stringify(data) + ');' +
      '}';
    WindowBus.get().broadcast(script);
  }

  private collabCallbacks(): CollabCallbacks {
    const self = this;
    const cb: CollabCallbacks = {
      onClientJoin: (username: string, avatar: string): void => {
        const d: Record<string, Object> = { 'username': username, 'avatar': avatar };
        self.emitCollab('member-joined', d);
      },
      onClientLeave: (username: string): void => {
        const d: Record<string, Object> = { 'username': username };
        self.emitCollab('member-left', d);
      },
      onChatMessage: (msg: string): void => {
        self.emitCollab('chat', JSON.parse(msg) as Record<string, Object>);
      },
      onProjectRequest: (username: string): void => {
        const d: Record<string, Object> = { 'username': username };
        self.emitCollab('project-request', d);
      },
      onProjectUpdate: (msg: string): void => {
        self.emitCollab('project-update', JSON.parse(msg) as Record<string, Object>);
      }
    };
    return cb;
  }

  private async collabStartHost(args: CollabHostArgs): Promise<BridgeEnvelope> {
    this.collabEndInternal();
    const opts: CollabStartOptions = {
      password: args.password || '',
      port: args.port > 0 ? args.port : 8080,
      permissions: args.permissions || '{}',
      hostName: args.hostName || '主机',
      hostAvatar: args.hostAvatar || '🏠'
    };
    const srv = new CollabServer();
    const ok: boolean = await srv.start(opts, this.collabCallbacks());
    if (!ok) return errEnvelope(BRIDGE_ERR_IO, '端口被占用或无法监听');
    this.collabServer = srv;
    this.collabIsHost = true;
    return okEnvelope(JSON.stringify(srv.getInfo()));
  }

  private collabEnd(): BridgeEnvelope {
    this.collabEndInternal();
    return okEnvelope('{"ended":true}');
  }

  private collabEndInternal(): void {
    if (this.collabServer !== null) {
      this.collabServer.end();
      this.collabServer = null;
    }
    if (this.collabClient !== null) {
      this.collabClient.leave();
      this.collabClient = null;
    }
    this.collabIsHost = false;
  }

  private collabGetInfo(): BridgeEnvelope {
    if (this.collabServer !== null) return okEnvelope(JSON.stringify(this.collabServer.getInfo()));
    return okEnvelope('{"ok":false}');
  }

  private collabGetMembers(): BridgeEnvelope {
    if (this.collabServer !== null) return okEnvelope(JSON.stringify({ members: this.collabServer.getMembers() }));
    return okEnvelope('{"members":[]}');
  }

  private collabGetOnlineCount(): BridgeEnvelope {
    const n: number = this.collabServer !== null ? this.collabServer.getOnlineCountTotal()
      : (this.collabClient !== null && this.collabClient.isConnected() ? 2 : 0);
    return okEnvelope(JSON.stringify({ onlineCount: n }));
  }

  private collabPushProject(args: CollabPushArgs): BridgeEnvelope {
    if (this.collabServer === null) return errEnvelope(BRIDGE_ERR_IO, 'not hosting');
    this.collabServer.broadcastProject(args.project, args.target || '');
    return okEnvelope('{"pushed":true}');
  }

  private collabSendChat(args: CollabChatArgs): BridgeEnvelope {
    if (this.collabServer !== null) {
      this.collabServer.broadcastChatFromHost(args.text);
      return okEnvelope('{"sent":true}');
    }
    if (this.collabClient !== null && this.collabClient.isConnected()) {
      this.collabClient.sendChat(args.text);
      return okEnvelope('{"sent":true}');
    }
    return errEnvelope(BRIDGE_ERR_IO, 'no active collaboration');
  }

  private collabIsRunning(): BridgeEnvelope {
    const running: boolean = (this.collabServer !== null && this.collabServer.isRunning()) ||
      (this.collabClient !== null && this.collabClient.isConnected());
    return okEnvelope(running ? '{"running":true}' : '{"running":false}');
  }

  private clientCallbacks(): CollabClientCallbacks {
    const self = this;
    const cb: CollabClientCallbacks = {
      onConnected: (msg: string): void => {
        const d: Record<string, Object> = {};
        self.emitCollab('joined', d);
      },
      onMessage: (msg: string): void => {
        // 把服务器消息原样推给 Web，由 collab bridge 按 type 分派
        self.emitCollab('server-message', JSON.parse(msg) as Record<string, Object>);
      },
      onDisconnected: (reason: string): void => {
        const d: Record<string, Object> = { 'reason': reason };
        self.emitCollab('left', d);
      }
    };
    return cb;
  }

  private async collabJoin(args: CollabJoinArgs): Promise<BridgeEnvelope> {
    this.collabEndInternal();
    const opts: CollabJoinOptions = {
      ip: args.ip,
      port: args.port > 0 ? args.port : 8080,
      password: args.password || '',
      nickname: args.nickname || '协作者',
      avatar: args.avatar || '🙂'
    };
    const client = new CollabClient();
    const ok: boolean = await client.join(opts, this.clientCallbacks());
    if (!ok) return errEnvelope(BRIDGE_ERR_IO, '无法连接主机');
    this.collabClient = client;
    this.collabIsHost = false;
    return okEnvelope('{"joined":true}');
  }

  private collabLeave(): BridgeEnvelope {
    if (this.collabClient !== null) {
      this.collabClient.leave();
      this.collabClient = null;
    }
    return okEnvelope('{"left":true}');
  }

  private collabSendProject(args: CollabPushArgs): BridgeEnvelope {
    if (this.collabClient === null || !this.collabClient.isConnected()) {
      return errEnvelope(BRIDGE_ERR_IO, 'not joined');
    }
    this.collabClient.sendProject(args.project);
    return okEnvelope('{"sent":true}');
  }

  /** 获取本机局域网 IP（用于主机显示邀请地址） */
  private async collabGetLocalIP(): Promise<BridgeEnvelope> {
    try {
      const net: connection.NetHandle = await connection.getDefaultNet();
      const props: connection.ConnectionProperties = await connection.getConnectionProperties(net);
      let ip: string = '';
      for (const link of props.linkAddresses) {
        const raw: string = link.address.address;
        // 取 IPv4 且非回环
        if (raw.length > 0 && raw.indexOf(':') < 0 && raw !== '127.0.0.1') {
          ip = raw;
          break;
        }
      }
      const result: Record<string, Object> = { 'ip': ip.length > 0 ? ip : '127.0.0.1' };
      return okEnvelope(JSON.stringify(result));
    } catch (_e) {
      return okEnvelope('{"ip":"127.0.0.1"}');
    }
  }

  /** 局域网发现：TCP 探测指定 IP 段的 /discover（简化：Web 侧提供候选 IP 列表） */
  private async collabDiscover(args: CollabDiscoverArgs): Promise<BridgeEnvelope> {
    // 真机局域网扫描受权限与性能限制，这里返回本机信息；
    // 跨设备协作以手动输入主机 IP 为主（与桌面版手动加入一致）。
    const info = this.collabServer !== null ? this.collabServer.getInfo() : null;
    return okEnvelope(JSON.stringify({ rooms: info ? [info] : [] }));
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

  /**
   * 用系统浏览器打开受信任外链（主页 GitHub 等）。
   * 仅允许 http(s)，离线站点内容本身不依赖网络；这只是把链接交给系统。
   */
  private async openExternal(args: OpenExternalArgs): Promise<BridgeEnvelope> {
    const url: string = args && args.url ? args.url : '';
    if (!/^https?:\/\//i.test(url)) {
      return errEnvelope(BRIDGE_ERR_BAD_ARGS, 'only http(s) links allowed');
    }
    if (this.host === null) {
      return errEnvelope(BRIDGE_ERR_IO, 'window host not attached');
    }
    const opened: boolean = await this.host.openExternal(url);
    return opened ? okEnvelope('{"opened":true}') : errEnvelope(BRIDGE_ERR_IO, 'no browser available');
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
