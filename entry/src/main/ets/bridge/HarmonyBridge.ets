/**
 * ArkWeb ⇄ ArkTS 双向桥
 *
 * 正向：javaScriptProxy 注入 window.HarmonyNative.invoke(ns, method, argsJson)
 *       → NativeServices.dispatch（显式 switch，零反射）
 * 反向：runJavaScript 调用 window.NWHost.emit(ns, name, data)
 *       → 复用仓库既有 web/src/core/30-host.js 的事件总线
 *
 * 离线拦截：所有请求映射到 rawfile/neowarp/**；
 * 任何非本地 http(s) 请求直接返回空响应（渲染层二次阻断出网）。
 */

import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { NativeServices } from './NativeServices';
import { PerformanceManager } from '../common/PerformanceManager';
import { WindowBus } from '../common/WindowBus';
import {
  DeviceSnapshot, TaskStats, SpriteStat,
  ALLOWED_BRIDGE_METHODS, OFFLINE_CSP, RAWFILE_ROOT,
  errEnvelope, BRIDGE_ERR_UNKNOWN_METHOD, BRIDGE_ERR_OFFLINE
} from '../common/Constants';

const CACHE_LIMIT: number = 96;
const TEXT_TYPES: string[] = [
  '.html', '.js', '.css', '.json', '.svg', '.txt', '.webmanifest', '.map', '.wasm'
];

interface AssetManifest {
  version: string;
  generatedAt: number;
  files: Record<string, string>;
}

export class HarmonyBridge {
  private controller: webview.WebviewController;
  private services: NativeServices;
  private perf: PerformanceManager;
  private context: common.UIAbilityContext;
  private cache: Map<string, string> = new Map<string, string>();
  private manifest: AssetManifest | null = null;
  private snapshot: DeviceSnapshot | null = null;

  constructor(
    controller: webview.WebviewController,
    context: common.UIAbilityContext,
    services: NativeServices,
    perf: PerformanceManager
  ) {
    this.controller = controller;
    this.context = context;
    this.services = services;
    this.perf = perf;
  }

  /** javaScriptProxy 暴露的唯一方法（asyncMethodList: ['invoke']） */
  async invoke(ns: string, method: string, argsJson: string): Promise<string> {
    const key: string = ns + '.' + method;
    if (!ALLOWED_BRIDGE_METHODS.includes(key)) {
      return JSON.stringify(errEnvelope(BRIDGE_ERR_UNKNOWN_METHOD, 'method not whitelisted: ' + key));
    }
    const args: string = argsJson === undefined || argsJson === null ? '{}' : argsJson;
    const envelope = await this.services.dispatch(key, args);
    return JSON.stringify(envelope);
  }

  /** 反向事件推送：Web 侧 NWHost.emit 已由 30-host.js 注册 */
  emit(ns: string, name: string, jsonData: string): void {
    const payload: string = jsonData.length > 0 ? jsonData : 'null';
    const script: string =
      'if (window.NWHost && window.NWHost.emit) {' +
      'window.NWHost.emit(' + JSON.stringify(ns) + ',' + JSON.stringify(name) + ',' + payload + ');' +
      '}';
    this.controller.runJavaScript(script).catch((_e: Object) => {
      // Web 层尚未就绪时丢弃事件，下一次采样会补偿
    });
  }

  /** 折叠/窗口尺寸变化：只重排布局，不重建 Web 组件 */
  notifyDeviceChange(snapshot: DeviceSnapshot): void {
    this.snapshot = snapshot;
    this.emit('device', 'profile', JSON.stringify(snapshot));
    this.perf.applyForm(snapshot.form);
  }

  notifyThemeChange(theme: string): void {
    this.emit('desktop', 'theme', JSON.stringify({ theme: theme, accent: '#5E5CE6' }));
  }

  notifyVisibility(visible: boolean): void {
    // 编辑器可能位于任一子窗口，前后台挂起事件需要广播到所有 ArkWeb
    const payload: string = JSON.stringify({ visible: visible });
    // 直接调用 rpc.emit，避免经 NWHost.emit 包装造成二次广播放大
    const script: string =
      'if (window.NW && window.NW.rpc && window.NW.rpc.emit) {' +
      'window.NW.rpc.emit("native", "visibility", ' + payload + ');' +
      '}';
    WindowBus.get().broadcast(script);
  }

  /** task-manager 数据推送：采样在 ArkTS/TaskPool，Web 层只负责绘制 */
  pushTaskStats(stats: TaskStats): void {
    this.emit('native', 'taskStats', JSON.stringify(stats));
  }

  updateSpriteStats(sprites: SpriteStat[]): void {
    this.services.updateSpriteStats(sprites);
  }

  /** 启动期预热：读资源清单 + 缓存热文件，消除首帧 IO 抖动 */
  async warmup(): Promise<void> {
    try {
      const raw = this.context.resourceManager.getRawFileContentSync(RAWFILE_ROOT + 'asset-manifest.json');
      const text: string = this.textFromBytes(new Uint8Array(raw));
      this.manifest = JSON.parse(text) as AssetManifest;
      const hot: string[] = [
        'index.html',
        'assets/nw-core.js',
        'assets/harmony-bridge.js',
        'gui/index.html',
        'gui/index.js'
      ];
      for (const path of hot) {
        const full: string = RAWFILE_ROOT + path;
        try {
          const bytes = this.context.resourceManager.getRawFileContentSync(full);
          this.putCache(full, this.textFromBytes(new Uint8Array(bytes)));
        } catch (_ignored) { /* 可选热文件不存在时跳过 */ }
      }
    } catch (_e) {
      this.manifest = null;
    }
  }

  assetCount(): number {
    return this.manifest !== null ? Object.keys(this.manifest.files).length : 0;
  }

  /**
   * 离线请求拦截。返回 null 表示交给 ArkWeb 默认处理（仅本地 file/resource）。
   * 返回空响应表示拒绝（外部网络请求）。
   */
  intercept(request: WebResourceRequest): WebResourceResponse | null {
    const url: string = request.getRequestUrl();
    if (this.isExternal(url)) {
      return this.emptyResponse();
    }
    if (this.isAssetMd5(url)) {
      return this.respondAsset(this.md5Path(url));
    }
    const relative: string = this.toRawPath(url);
    if (relative.length === 0) {
      return null;
    }
    return this.respondAsset(relative);
  }

  private isExternal(url: string): boolean {
    if (url.startsWith('http://') || url.startsWith('https://') || url.startsWith('wss://') || url.startsWith('ws://')) {
      // 本地素材 CDN 的 md5 请求重定向到内置资源，其余一律拒绝
      return !this.isAssetMd5(url);
    }
    return false;
  }

  private isAssetMd5(url: string): boolean {
    return url.includes('assets.scratch.mit.edu') || url.includes('cdn.assets.scratch.mit.edu');
  }

  private md5Path(url: string): string {
    const parts: string[] = url.split('/');
    const last: string = parts.length > 0 ? parts[parts.length - 1] : '';
    const clean: string = last.split('?')[0];
    return 'library/' + clean;
  }

  /** URL → rawfile 相对路径（统一去掉 query/hash 与 tw-* scheme 前缀） */
  private toRawPath(url: string): string {
    let path: string = url;
    const schemeEnd: number = path.indexOf('://');
    if (schemeEnd >= 0) {
      path = path.substring(schemeEnd + 3);
    }
    const rawIndex: number = path.indexOf(RAWFILE_ROOT);
    if (rawIndex >= 0) {
      path = path.substring(rawIndex + RAWFILE_ROOT.length);
    }
    const queryIndex: number = path.indexOf('?');
    if (queryIndex >= 0) {
      path = path.substring(0, queryIndex);
    }
    const hashIndex: number = path.indexOf('#');
    if (hashIndex >= 0) {
      path = path.substring(0, hashIndex);
    }
    if (path.startsWith('tw-library/')) {
      path = 'library/' + path.substring('tw-library/'.length);
    } else if (path.startsWith('tw-extensions/')) {
      path = 'extensions/' + path.substring('tw-extensions/'.length);
    } else if (path.startsWith('tw-')) {
      const slash: number = path.indexOf('/');
      path = slash >= 0 ? path.substring(slash + 1) : path;
    }
    if (path.length === 0 || path === '/') {
      path = 'index.html';
    }
    return path;
  }

  private respondAsset(relative: string): WebResourceResponse | null {
    const full: string = RAWFILE_ROOT + relative;
    let content: string | undefined = this.cache.get(full);
    if (content === undefined) {
      try {
        const bytes = this.context.resourceManager.getRawFileContentSync(full);
        content = this.textFromBytes(new Uint8Array(bytes));
        this.putCache(full, content);
      } catch (_e) {
        return this.emptyResponse();
      }
    }
    const response = new WebResourceResponse();
    response.setResponseMimeType(this.mimeOf(relative));
    response.setResponseEncoding('utf-8');
    response.setResponseData(content as string);
    response.setResponseHeader([
      { headerKey: 'Content-Security-Policy', headerValue: OFFLINE_CSP },
      { headerKey: 'Cache-Control', headerValue: 'public, max-age=31536000, immutable' },
      { headerKey: 'X-NeoWarp-Offline', headerValue: '1' }
    ]);
    response.setResponseCode(200);
    response.setReasonMessage('OK');
    response.setResponseIsReady(true);
    return response;
  }

  private emptyResponse(): WebResourceResponse {
    const response = new WebResourceResponse();
    response.setResponseMimeType('text/plain');
    response.setResponseEncoding('utf-8');
    response.setResponseData('');
    response.setResponseHeader([
      { headerKey: 'Content-Security-Policy', headerValue: OFFLINE_CSP },
      { headerKey: 'X-NeoWarp-Blocked', headerValue: 'offline-only' }
    ]);
    response.setResponseCode(204);
    response.setReasonMessage('No Content');
    response.setResponseIsReady(true);
    return response;
  }

  private mimeOf(path: string): string {
    if (path.endsWith('.html')) return 'text/html';
    if (path.endsWith('.js')) return 'application/javascript';
    if (path.endsWith('.css')) return 'text/css';
    if (path.endsWith('.json') || path.endsWith('.webmanifest')) return 'application/json';
    if (path.endsWith('.svg')) return 'image/svg+xml';
    if (path.endsWith('.png')) return 'image/png';
    if (path.endsWith('.jpg') || path.endsWith('.jpeg')) return 'image/jpeg';
    if (path.endsWith('.webp')) return 'image/webp';
    if (path.endsWith('.wav')) return 'audio/wav';
    if (path.endsWith('.mp3')) return 'audio/mpeg';
    if (path.endsWith('.woff2')) return 'font/woff2';
    if (path.endsWith('.ttf')) return 'font/ttf';
    if (path.endsWith('.wasm')) return 'application/wasm';
    return 'application/octet-stream';
  }

  private putCache(key: string, value: string): void {
    if (this.cache.size >= CACHE_LIMIT) {
      const first: string | undefined = this.cache.keys().next().value;
      if (first !== undefined) {
        this.cache.delete(first);
      }
    }
    this.cache.set(key, value);
  }

  private textFromBytes(bytes: Uint8Array): string {
    const decoder = new util.TextDecoder('utf-8');
    return decoder.decodeWithStream(bytes, { stream: false });
  }
}
