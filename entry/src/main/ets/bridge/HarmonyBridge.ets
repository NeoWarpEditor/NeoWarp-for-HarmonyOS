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
  // 缓存保存原始字节，按 MIME 以文本或二进制方式返回，避免二进制资源被 UTF-8 解码破坏
  private cache: Map<string, Uint8Array> = new Map<string, Uint8Array>();
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
        'gui/gui.html',
        'gui/index.js'
      ];
      for (const path of hot) {
        const full: string = RAWFILE_ROOT + path;
        try {
          const bytes = this.context.resourceManager.getRawFileContentSync(full);
          this.putCache(full, new Uint8Array(bytes));
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
    let bytes: Uint8Array | undefined = this.cache.get(full);
    if (bytes === undefined) {
      try {
        const raw = this.context.resourceManager.getRawFileContentSync(full);
        bytes = new Uint8Array(raw);
        this.putCache(full, bytes);
      } catch (_e) {
        return this.emptyResponse();
      }
    }
    const mime: string = this.mimeOf(relative);
    const response = new WebResourceResponse();
    response.setResponseMimeType(mime);
    response.setResponseHeader([
      { headerKey: 'Content-Security-Policy', headerValue: OFFLINE_CSP },
      { headerKey: 'Cache-Control', headerValue: 'public, max-age=31536000, immutable' },
      { headerKey: 'X-NeoWarp-Offline', headerValue: '1' }
    ]);
    if (this.isTextAsset(relative)) {
      // 文本资源：按 UTF-8 解码为字符串（索引 HTML/JS/CSS/JSON/SVG 等）
      response.setResponseEncoding('utf-8');
      response.setResponseData(this.textFromBytes(bytes));
    } else {
      // 二进制资源：直接传 ArrayBuffer，保持字节原样（PNG/JPG/WEBP/字体/音频/WASM/ZIP）
      // 若误用 UTF-8 解码，0x89PNG 等字节会被替换字符破坏，导致所有图片/图标/声音加载失败。
      response.setResponseData(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
    }
    response.setResponseCode(200);
    response.setReasonMessage('OK');
    response.setResponseIsReady(true);
    return response;
  }

  /** 判定是否文本资源；除明确文本类型外一律按二进制处理，避免任何编码损坏 */
  private isTextAsset(path: string): boolean {
    const lower: string = path.toLowerCase();
    if (lower.endsWith('.br') || lower.endsWith('.gz') || lower.endsWith('.zst')) return false;
    const textExt: string[] = [
      '.html', '.htm', '.js', '.mjs', '.cjs', '.css', '.json', '.json5',
      '.svg', '.txt', '.webmanifest', '.map', '.xml', '.md', '.ts', '.tsx'
    ];
    for (const ext of textExt) {
      if (lower.endsWith(ext)) return true;
    }
    return false;
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
    const lower: string = path.toLowerCase().split('?')[0];
    if (lower.endsWith('.html') || lower.endsWith('.htm')) return 'text/html';
    if (lower.endsWith('.js') || lower.endsWith('.mjs') || lower.endsWith('.cjs')) return 'application/javascript';
    if (lower.endsWith('.css')) return 'text/css';
    if (lower.endsWith('.json') || lower.endsWith('.webmanifest')) return 'application/json';
    if (lower.endsWith('.xml')) return 'application/xml';
    if (lower.endsWith('.txt') || lower.endsWith('.md')) return 'text/plain';
    if (lower.endsWith('.svg')) return 'image/svg+xml';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.ico')) return 'image/x-icon';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    if (lower.endsWith('.avif')) return 'image/avif';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.ogg') || lower.endsWith('.oga')) return 'audio/ogg';
    if (lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.woff')) return 'font/woff';
    if (lower.endsWith('.woff2')) return 'font/woff2';
    if (lower.endsWith('.ttf')) return 'font/ttf';
    if (lower.endsWith('.otf')) return 'font/otf';
    if (lower.endsWith('.eot')) return 'application/vnd.ms-fontobject';
    if (lower.endsWith('.wasm')) return 'application/wasm';
    if (lower.endsWith('.zip') || lower.endsWith('.sb3') || lower.endsWith('.sb2')) return 'application/zip';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    return 'application/octet-stream';
  }

  private putCache(key: string, value: Uint8Array): void {
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
